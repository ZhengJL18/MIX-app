import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../db/database_helper.dart';
import '../hermes/agent/agent.dart';
import '../hermes/llm/openai_llm.dart';
import '../models/ai_settings.dart';
import '../repository/kp_repository.dart';
import '../repository/question_repository.dart';
import '../repository/subject_repository.dart';
import 'ai_service.dart';
import 'student_portrait_service.dart';

/// 主/子代理出题调度器。
///
/// 取代旧的数值选科选点（selection.dart）+ 单次出题（prompt_builder）。
/// 结构：
///   planner JailerAgent   读各科画像摘要(节俭) → 决策科目+知识点
///   generator JailerAgent 读该科画像全文+近20题 → 出一题(Markdown)
///
/// 两个都是完整 agent 循环，但编排由本 service 控制：
/// 先跑 planner 拿结构化决策，再跑 generator 出题，最后落库。
class QuestionAgentService {
  QuestionAgentService({
    QuestionRepository? questionRepo,
    SubjectRepository? subjectRepo,
    KpRepository? kpRepo,
    StudentPortraitService? portraitService,
  })  : _questionRepo = questionRepo ?? QuestionRepository(),
        _subjectRepo = subjectRepo ?? SubjectRepository(),
        _kpRepo = kpRepo ?? KpRepository(),
        _portrait = portraitService ?? StudentPortraitService();

  final QuestionRepository _questionRepo;
  final SubjectRepository _subjectRepo;
  final KpRepository _kpRepo;
  final StudentPortraitService _portrait;

  /// kpId → 已生成好的下一题（预生成缓存）。
  final Map<int, int> _nextPool = {};

  /// kpId → 正在生成中的 Future（避免重复触发）。
  final Map<int, Future<void>> _inFlight = {};

  /// B: 近期出过题的 kpId 序列（新→旧），planner 据此避免连续选同一 kp。
  final List<int> _recentKpIds = [];
  static const int _recentKpMax = 6;

  /// 出题成功 → 记录该 kp 到近期序列（B 层轮换）。
  void _rememberKp(int kpId) {
    _recentKpIds.remove(kpId);
    _recentKpIds.insert(0, kpId);
    if (_recentKpIds.length > _recentKpMax) _recentKpIds.removeLast();
  }

  /// 取下一题：预生成池有货直接取；没有则跑完整 planner→generator 出题。
  Future<int> nextQuestionId(int userId, {void Function(String)? onStream}) async {
    final settings = await AiSettings.load();
    if (settings == null || !settings.isComplete) {
      throw Exception('尚未配置 AI 接口，请先在「AI 设置」填入 API Key');
    }

    // 1. 决策：主代理读各科摘要，选科目 + 知识点
    final (subjectId, kpId) = await _plan(userId, settings);

    // 2. 预生成池优先
    final pooled = _nextPool.remove(kpId);
    if (pooled != null) {
      _triggerPregenerate(userId, subjectId, kpId, settings);
      return pooled;
    }

    // 3. 现场生成 + 后台预生成下一题
    final id = await _generateAndStore(userId, subjectId, kpId, settings);
    _triggerPregenerate(userId, subjectId, kpId, settings);
    return id;
  }

  void _triggerPregenerate(int userId, int subjectId, int kpId, AiSettings settings) {
    if (_nextPool.containsKey(kpId)) return;
    if (_inFlight.containsKey(kpId)) return;
    final future = _generateAndStore(userId, subjectId, kpId, settings)
        .then((id) {
      _nextPool[kpId] = id;
    }, onError: (e) {
      // 预生成失败静默记录，不反复触发（避免无限重试烧钱/卡死）
      debugPrint('[QuestionAgent] 预生成失败 kp=$kpId: $e');
    }).whenComplete(() => _inFlight.remove(kpId));
    _inFlight[kpId] = future;
  }

  /// 主代理：读各科**知识点级状态**，决策科目 + 知识点，返回 (subjectId, kpId)。
  Future<(int, int)> _plan(int userId, AiSettings settings) async {
    final subjects = await _subjectRepo.getAllSubjects();
    if (subjects.isEmpty) {
      throw StateError('请先在「科目管理」创建科目和知识点');
    }

    // 知识点级状态（实时算，排除"还没开始/已经学完"占位符）。
    // 这是难度体系对接的关键：planner 必须能看到每个真知识点练没练过，
    // 才能选到该练的，而不是盯着第一个占位符。
    final statuses = <String>[];
    for (final subj in subjects) {
      final s = await _portrait.subjectKpStatus(userId, subj['id'] as int);
      statuses.add(s);
    }
    final statusBlock = statuses.join('\n');

    // B: 近期已出题的 kp（避免连续刷同一知识点）
    final recentKpNames = <String>[];
    for (final kpId in _recentKpIds) {
      final n = await _kpRepo.getKpName(kpId);
      if (n != null && n.isNotEmpty) recentKpNames.add(n);
    }
    final recentKpBlock = recentKpNames.isEmpty
        ? '（暂无）'
        : recentKpNames.join('、');

    final prompt = '''
你是学习规划代理。根据以下各科目的知识点级状态，决定学生当前最该练哪个科目、哪个知识点。

【各科目知识点状态】
$statusBlock

【近期刚出过题的知识点】（请避免连续选到它们）
$recentKpBlock

要求：输出 JSON（不要任何其他文字），格式：
{"subject_id": <科目id>, "kp_id": <知识点id>, "reason": "<一句话理由>"}

选点依据（按优先级）：
1. 优先选"未练"的知识点（学生还没碰过的新知识点）。
2. 其次选近期做错的（练习中"对M错K"里 K>0 的）。
3. 不要选已经全对很多题的知识点（太简单）。
4. 尽量避免与【近期刚出过题的知识点】重复 —— 换科目/换知识点练。
''';

    final planner = JailerAgent(
      llm: OpenAiLlmClient(
        config: LlmConfig(
          baseUrl: settings.chatBaseUrl,
          apiKey: settings.apiKey,
          model: settings.model,
        ),
      ),
      systemPrompt: '你是学习规划代理，只输出 JSON。',
      toolDefinitionsProvider: () => const [],
      maxIterations: 3,
    );

    final result = await planner.runConversation(prompt);
    final text = result.finalResponse ?? '';
    final json = _extractJson(text);

    final subjectId = (json['subject_id'] as num?)?.toInt();
    final kpId = (json['kp_id'] as num?)?.toInt();
    // 校验：返回的 kp 必须是存在的真知识点（排除占位符）。
    // LLM 瞎编 / 没按格式返回时，fallback 到第一个科目里第一个未练的真知识点。
    final candidate = await _validateKp(subjectId, kpId);
    if (candidate != null) return candidate;
    return _fallbackKp(userId);
  }

  /// 校验 planner 返回的 (subjectId, kpId)：必须是真知识点（非占位符）。
  Future<(int, int)?> _validateKp(int? subjectId, int? kpId) async {
    if (subjectId == null || kpId == null) return null;
    final kp = await _kpRepo.getKpById(kpId);
    if (kp == null) return null;
    final name = kp['name'] as String? ?? '';
    if (name == '还没开始' || name == '已经学完') return null;
    // kp 必须属于该科目
    if ((kp['subject_id'] as num).toInt() != subjectId) return null;
    return (subjectId, kpId);
  }

  /// 兜底：按科目顺序找第一个"未练的真知识点"；全练过则避开近期 kp。
  Future<(int, int)> _fallbackKp(int userId) async {
    final subjects = await _subjectRepo.getAllSubjects();
    final db = await DatabaseHelper.instance.database;

    // 第一优先：未练的真知识点（天然轮换）
    for (final subj in subjects) {
      final sId = subj['id'] as int;
      final kps = await _kpRepo.getKpsBySubject(sId);
      for (final kp in kps) {
        final name = kp['name'] as String? ?? '';
        if (name == '还没开始' || name == '已经学完') continue;
        final kid = kp['id'] as int;
        final rows = await db.rawQuery('''
          SELECT COUNT(*) AS c FROM practice_records pr
          JOIN questions q ON q.id = pr.question_id
          WHERE pr.user_id = ? AND q.kp_id = ?
        ''', [userId, kid]);
        final cnt = rows.isEmpty ? 0 : (rows.first['c'] as int? ?? 0);
        if (cnt == 0) return (sId, kid); // 第一个未练的真知识点
      }
    }

    // 全练过了 → 收集所有真知识点，避开近期已出题的，选没被近期宠幸的
    final candidates = <(int, int, String)>[]; // (subjectId, kpId, name)
    for (final subj in subjects) {
      final sId = subj['id'] as int;
      final kps = await _kpRepo.getKpsBySubject(sId);
      for (final kp in kps) {
        final name = kp['name'] as String? ?? '';
        if (name == '还没开始' || name == '已经学完') continue;
        candidates.add((sId, kp['id'] as int, name));
      }
    }
    if (candidates.isEmpty) throw StateError('没有可用知识点');
    // 优先选不在近期序列里的
    for (final c in candidates) {
      if (!_recentKpIds.contains(c.$2)) return (c.$1, c.$2);
    }
    // 全在近期里 → 取最近最少出的那个
    final first = candidates.first;
    return (first.$1, first.$2);
  }

  /// 子代理：读该科画像全文 + 近况 + 该知识点实时统计，出一题（Markdown）。
  ///
  /// 防重复（三层，成本可控）：
  /// - A: prompt 注入该知识点最近 [antiRepeatHistory] 题摘要，命令不重复
  /// - C: 生成后脚本 Jaccard 判重，重复则重生成（最多 1 次，校验零 token）
  Future<int> _generateAndStore(
    int userId,
    int subjectId,
    int kpId,
    AiSettings settings,
  ) async {
    // 生成（最多 3 次：首生成 + 判重后的 2 次重生成）
    // 重试时注入更多历史，强制模型避开已重复的模板。
    for (var attempt = 0; attempt < 3; attempt++) {
      final historyLimit = attempt == 0 ? 8 : 8 + attempt * 8; // 8 / 16 / 24
      final parsed = await _generateOnce(
        userId,
        subjectId,
        kpId,
        settings,
        historyLimit: historyLimit,
      );
      if (parsed == null) break; // 生成失败，用已抛的错

      // C: 脚本判重 —— 只对重复的题花重生成的钱，校验本身免费
      final isDup = await _isDuplicate(kpId, parsed.content);
      if (!isDup) {
        var options = parsed.options;
        var correctAnswer = parsed.correctAnswer;
        if (options.isEmpty) {
          correctAnswer = parsed.correctAnswer.isNotEmpty
              ? parsed.correctAnswer
              : parsed.content.trim();
          options = [correctAnswer, '以上都不是', '无法确定', '选项 D'];
        }
        final qid = await _questionRepo.insertQuestion(
          kpId: kpId,
          content: parsed.content,
          answer: correctAnswer,
          options: options,
          explanation: parsed.explanation,
          cplxCoef: parsed.cplxCoef,
          undCoef: parsed.undCoef,
          redCoef: parsed.redCoef,
          covCoef: parsed.covCoef,
          isSeed: false,
        );
        _rememberKp(kpId);
        return qid;
      }
      // 重复 → 下一轮重生成（generator prompt 会注入更多历史，避开已出现的）
    }
    throw Exception('出题代理连续生成重复题目');
  }

  /// 单次生成一道题并解析。返回 null 表示失败（错误已抛）。
  Future<GeneratedQuestion?> _generateOnce(
    int userId,
    int subjectId,
    int kpId,
    AiSettings settings, {
    int historyLimit = 8,
  }) async {
    final subject = await _subjectRepo.getSubjectById(subjectId);
    if (subject == null) throw StateError('科目 $subjectId 不存在');
    final kpName = await _kpRepo.getKpName(kpId) ?? '(未知知识点)';

    final profile = await _portrait.ensureProfile(userId: userId, subjectId: subjectId);
    final recent = await _portrait.recentLog(userId: userId, subjectId: subjectId);
    // 该知识点的实时做题统计 —— 校准难度的权威依据（画像可能过时）
    final kpStats = await _portrait.kpPracticeStats(userId, kpId);
    // A: 该知识点最近已出过的题（防重复，注入摘要；重试时注入更多）
    final recentQ =
        await _questionRepo.recentQuestionContents(kpId, limit: historyLimit);
    final recentQBlock = recentQ.isEmpty
        ? '（暂无）'
        : recentQ
            .map((c) => '- ${_summaryOf(c, 40)}')
            .join('\n');

    final prompt = '''
你是「${subject['name']}」老师，为学生出一道单选题。

本次考察知识点：$kpName

【该知识点最近已出过的题】（禁止重复以下任何一题的题干或考点）
$recentQBlock

【该知识点实时做题情况】（难度校准的首要依据）
$kpStats

【学生学科画像】
$profile

【学生近况】
$recent

要求：
1. 难度必须根据"该知识点实时做题情况"校准：
   - 若已练多题全对 → 难度显著提升，出综合性/含陷阱/易错变形的题，别出送分题。
   - 若已练且做错 → 针对错的点出同类题巩固。
   - 若尚未练习 → 出该知识点的基础概念题，先建立掌握。
2. 针对画像中的薄弱点与易错模式出题。
3. 【硬性】题干与【最近已出过的题】任何一题都不得重复或高度相似，
   换数字/换字母不算新题，必须换考点或换题型。
4. 必须包含 4 个选项（A/B/C/D），且只有一个正确选项，干扰项合理。

请严格按以下 Markdown 格式返回：
## 题目
[题干]

## 选项
A. [选项A]
B. [选项B]
C. [选项C]
D. [选项D]

## 答案
[A/B/C/D 单个大写字母]

## 解析
[简要解析，说明为什么选它]

## 系数
- 复杂度：X.XX
- 理解难度：X.XX
- 冗余度：X.XX
- 覆盖率：X.XX
''';

    final generator = JailerAgent(
      llm: OpenAiLlmClient(
        config: LlmConfig(
          baseUrl: settings.chatBaseUrl,
          apiKey: settings.apiKey,
          model: settings.model,
        ),
      ),
      systemPrompt: '你是出题代理，严格按要求的 Markdown 格式出题。',
      toolDefinitionsProvider: () => const [],
      maxIterations: 3,
    );

    final result = await generator.runConversation(prompt);
    if (!result.completed || result.error != null) {
      throw Exception(result.finalResponse ?? '出题代理失败');
    }
    final text = result.finalResponse ?? '';
    if (text.trim().isEmpty) {
      throw Exception('出题代理返回为空');
    }

    // 用现有解析器把 Markdown 解析成 GeneratedQuestion
    final parsed = AnthropicAiService.parseMarkdownResponse(text);
    if (parsed.content.trim().isEmpty) {
      throw Exception('出题代理返回无题干');
    }
    return parsed;
  }

  /// C: 相似度判重。纯脚本，零 token。
  ///
  /// 只对**高度重复**（几乎逐字相同）判重，阈值 0.85。
  /// 为什么不用低阈值：Jaccard 字符二元组对"换数字/换系数的同模板题"
  /// 极其敏感（lim (x²-1)/(x-1) 换 2→3 集合几乎一样），低阈值会把
  /// 考点相同但数值不同的正常题误判为重复 → 每道题都重生成 → 卡死。
  /// 换数字的同模板题在刷题场景可接受，用户烦的是"同一道题原样出现"。
  Future<bool> _isDuplicate(int kpId, String content) async {
    final all = await _questionRepo.recentQuestionContents(kpId, limit: 100);
    if (all.isEmpty) return false;
    final target = _charset(content);
    if (target.length < 8) return false; // 题干太短，没法可靠判重
    for (final c in all) {
      final set = _charset(c);
      if (set.length < 8) continue;
      final inter = target.intersection(set).length;
      final union = target.union(set).length;
      if (union > 0 && inter / union > 0.85) return true;
    }
    return false;
  }

  /// 题干 → 去空白字符的二元组集合（Jaccard 用）。
  Set<String> _charset(String s) {
    final cleaned = s
        .replaceAll(RegExp(r'[{}\\\\]'), '')
        .replaceAll(RegExp(r'\s+'), '');
    if (cleaned.length < 2) return {};
    final set = <String>{};
    for (var i = 0; i < cleaned.length - 1; i++) {
      set.add(cleaned.substring(i, i + 2));
    }
    return set;
  }

  /// 题干压缩成一句话摘要（防重复清单注入用，控制 token）。
  String _summaryOf(String content, int maxLen) {
    // 去掉 LaTeX 标记/空白，取前 maxLen 字符
    final cleaned = content
        .replaceAll(RegExp(r'\\[a-zA-Z]+'), '')
        .replaceAll(RegExp(r'[{}\\\\]'), '')
        .replaceAll(RegExp(r'\s+'), '')
        .trim();
    return cleaned.length <= maxLen ? cleaned : '${cleaned.substring(0, maxLen)}…';
  }

  /// 从 agent 输出里提取 JSON（容忍 ```json 包裹 / 前后杂文字）。
  Map<String, dynamic> _extractJson(String text) {
    final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    final raw = fenced?.group(1) ?? text;
    try {
      final decoded = jsonDecode(raw.trim());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    // 兜底：找第一个 { 到最后一个 } 的区间
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final decoded = jsonDecode(raw.substring(start, end + 1));
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    return {};
  }
}
