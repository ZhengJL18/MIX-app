import 'dart:io';

import '../db/database_helper.dart';
import '../repository/subject_repository.dart';
import 'ai_service.dart';

/// 学生状态摘要引擎 —— 把数据库状态压缩成"人读的画像"喂给 Agent。
///
/// 设计原则（黑板讨论第 2/3 轮钉死）：
/// 1. 不做实时摘要：画像缓存为文件，不是每出一道题现算。
/// 2. 学科画像（0号文件）：LLM 生成，**做错才重写**；做对只走程序计数。
/// 3. 近况：practice_records 派生的滚动日志，查询时 LIMIT 20，不落盘。
/// 4. 教学记忆（学生为什么错/下次怎么教）只由 Agent 写，活在 0号文件内。
///
/// 出题侧（PromptBuilder v2）吃 0号文件 + 近20题日志，而不是裸数字四维。
class StudentPortraitService {
  StudentPortraitService({AiService? aiService})
      : _ai = aiService ?? MockAiService();

  final AiService _ai;
  final SubjectRepository _subjectRepo = SubjectRepository();

  static const String _libraryRoot = '/data/data/com.mix.mix_app/files/subject_library';
  static const String _profileName = '0_profile.md';

  // ── 文件布局 ──
  Future<Directory> _subjectDir(int subjectId) async {
    final dir = Directory('$_libraryRoot/$subjectId');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _profileFile(int subjectId) async {
    final dir = await _subjectDir(subjectId);
    return File('${dir.path}/$_profileName');
  }

  /// 取学科画像（0号文件）文本。不存在则用 LLM 初始化。
  Future<String> ensureProfile({
    required int userId,
    required int subjectId,
  }) async {
    final file = await _profileFile(subjectId);
    if (await file.exists()) {
      final content = await file.readAsString();
      if (content.trim().isNotEmpty) return content;
    }

    // 未配置真实 AI 时不落盘（避免把 mock 文本持久化成永久画像，
    // 用户之后配置 AI 时 0号文件已是假货）。
    if (_ai is MockAiService) {
      return '（尚未配置 AI 接口，暂无可用的学科画像）';
    }

    // 无画像 → 首建：读原始状态 → LLM 凝练成首版 0号文件
    final subject = await _subjectRepo.getSubjectById(subjectId);
    final name = subject?['name'] as String? ?? '(未知科目)';
    final raw = await _collectRaw(userId: userId, subjectId: subjectId, subjectName: name);
    final prompt = _buildInitPrompt(subjectName: name, raw: raw);
    final profile = await _generate(prompt);
    await file.writeAsString(profile, flush: true);
    return profile;
  }

  /// 近 20 题滚动日志（主题 + 对错 + 主因），跨题去重后拼成清单。
  /// 这是"近况画像"，从 practice_records 派生，不落盘。
  Future<String> recentLog({
    required int userId,
    required int subjectId,
  }) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery('''
      SELECT q.content AS theme, pr.correct, pr.main_cause,
             pr.created_at AS at
      FROM practice_records pr
      JOIN questions q ON q.id = pr.question_id
      JOIN knowledge_points kp ON kp.id = q.kp_id
      WHERE pr.user_id = ? AND kp.subject_id = ?
      ORDER BY pr.created_at DESC
      LIMIT 20
    ''', [userId, subjectId]);

    // 最近 10 题的对错计数（含重复做同一主题）
    var correct = 0, wrong = 0;
    for (final r in rows.take(10)) {
      if ((r['correct'] as int) == 1) {
        correct++;
      } else {
        wrong++;
      }
    }

    // 去重（同一主题题可能被反复做）：保留最近的题
    final seen = <String>{};
    final lines = <String>[];
    for (final r in rows) {
      final theme = (r['theme'] as String? ?? '').trim();
      if (theme.isEmpty || seen.contains(theme)) continue;
      seen.add(theme);
      final ok = (r['correct'] as int) == 1;
      final mark = ok ? '✅' : '❌';
      final cause = r['main_cause'] == null ? '' : '（${r['main_cause']}）';
      lines.add('$mark $theme$cause');
    }

    final buf = StringBuffer('## 近况（最近${rows.length}题）\n');
    if (rows.isEmpty) {
      buf.writeln('暂无做题记录');
    } else {
      buf.writeln('近10题：对 $correct 错 $wrong');
      for (final l in lines.take(10)) {
        buf.writeln(l);
      }
    }
    return buf.toString();
  }

  /// 作答后更新：做错 → 读旧画像 + 本题详情 + 近况 → LLM 全量重写 0号文件。
  /// 做对 → 什么都不做（近况由 SQL 派生自动反映，不花 token）。
  Future<void> onAnswered({
    required int userId,
    required int subjectId,
    required bool correct,
    required Map<String, dynamic> question,
    String? mainCause,
    String? minorCause,
  }) async {
    if (correct) return; // 做对走程序计数，不调 LLM
    if (_ai is MockAiService) return; // 未配置真实 AI，重写没有意义

    final subject = await _subjectRepo.getSubjectById(subjectId);
    if (subject == null) return;
    final subjectName = subject['name'] as String? ?? '(未知科目)';

    final oldProfile = await ensureProfile(userId: userId, subjectId: subjectId);
    final recent = await recentLog(userId: userId, subjectId: subjectId);
    final qContent = (question['content'] as String? ?? '').trim();
    final qAnswer = (question['answer'] as String? ?? '').trim();
    final qExplanation = (question['explanation'] as String? ?? '').trim();

    final prompt = '''
你是一位资深学科老师。以下是学生刚做错的一道题。

科目：$subjectName

【旧画像】
$oldProfile

【学生近况】
$recent

【本次做错的题】
题目：$qContent
正确答案：$qAnswer
${qExplanation.isNotEmpty ? '解析：$qExplanation' : ''}
主因：${mainCause ?? '未填写'}
${minorCause != null ? '辅因：$minorCause' : ''}

请基于以上信息，重写这份【学科画像】。要求：
1. 这是学生状态摘要，不是答案分析。聚焦：学生当前掌握程度、薄弱点、易错模式、下一步该练什么。
2. 更新"易错模式"，把本次错误的原因（如果信息足够）纳入。
3. 用一条"教学记忆"记录你观察到的最有价值的新认知：学生为什么会错、下次该用什么方式教。教学记忆只保留最有价值的 2~3 条，旧的若仍有效可保留，重复的删掉。
4. 保持 Markdown 结构（# 标题 / ## 小节 / - 列表），控制在 500~1000 token。
5. 不要虚构数据，只基于给定信息推断。

请直接输出完整的新画像 Markdown，不要任何前言。
''';

    final profile = await _generate(prompt);
    await (await _profileFile(subjectId)).writeAsString(profile, flush: true);
  }

  // ── 私有 ──

  /// 汇总原始状态数据，供 LLM 首建画像。
  Future<String> _collectRaw({
    required int userId,
    required int subjectId,
    required String subjectName,
  }) async {
    final db = await DatabaseHelper.instance.database;
    final states = await db.rawQuery('''
      SELECT kp_user_state.*, knowledge_points.name AS kp_name
      FROM kp_user_state
      JOIN knowledge_points ON knowledge_points.id = kp_user_state.kp_id
      WHERE kp_user_state.user_id = ? AND knowledge_points.subject_id = ?
    ''', [userId, subjectId]);

    final buf = StringBuffer('科目：$subjectName\n\n知识点状态：\n');
    for (final s in states) {
      buf.writeln('- ${s['kp_name']}: '
          '复杂度${(s['complexity'] as num).toStringAsFixed(2)} '
          '理解${(s['understand'] as num).toStringAsFixed(2)} '
          '冗余${(s['redundancy'] as num).toStringAsFixed(2)} '
          '覆盖${(s['coverage'] as num).toStringAsFixed(2)} '
          '复习${s['review_count']}次');
    }
    buf.writeln();
    buf.writeln(await recentLog(userId: userId, subjectId: subjectId));
    return buf.toString();
  }

  String _buildInitPrompt({required String subjectName, required String raw}) {
    return '''
你是一位资深学科老师。请基于以下学生的原始学习数据，为「$subjectName」生成一份学科画像（学生状态摘要）。

【原始数据】
$raw

请直接输出完整画像 Markdown，结构如下（控制在 500~1000 token）：
# 学科画像 · $subjectName
## 一、能力概况
## 二、知识点掌握
## 三、薄弱点与易错模式
## 四、教学记忆
## 五、推荐路径

只基于给定数据推断，不要虚构。
''';
  }

  /// 统一的 LLM 调用（画像生成/重写都走这里）。
  ///
  /// 复用 AiService.generateQuestion，但画像不是题目：parseMarkdownResponse
  /// 找不到 `## 题目` 节时会把整段文本原样放进 content，这里直接取它。
  Future<String> _generate(String prompt) async {
    final generated = await _ai.generateQuestion(prompt);
    final text = generated.content.trim();
    if (text.isEmpty) {
      throw Exception('画像生成返回为空');
    }
    return text;
  }
}
