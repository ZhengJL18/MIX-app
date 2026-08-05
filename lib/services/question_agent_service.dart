import 'dart:convert';

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
        .then((id) => _nextPool[kpId] = id)
        .whenComplete(() => _inFlight.remove(kpId));
    _inFlight[kpId] = future;
  }

  /// 主代理：读各科画像摘要，决策科目 + 知识点，返回 (subjectId, kpId)。
  Future<(int, int)> _plan(int userId, AiSettings settings) async {
    final subjects = await _subjectRepo.getAllSubjects();
    if (subjects.isEmpty) {
      throw StateError('请先在「科目管理」创建科目和知识点');
    }

    // 节俭上下文：只读各科摘要（首节能力概况 + 近10题对错），不读全文
    final summaries = <String>[];
    for (final subj in subjects) {
      final s = await _portrait.profileSummary(
        userId: userId,
        subjectId: subj['id'] as int,
      );
      summaries.add(s);
    }
    final summaryBlock = summaries.join('\n');

    final prompt = '''
你是学习规划代理。根据以下各科的画像摘要，决定学生当前最该练哪个科目、哪个知识点。

【各科画像摘要】
$summaryBlock

要求：输出 JSON（不要任何其他文字），格式：
{"subject_id": <科目id>, "kp_id": <知识点id>, "reason": "<一句话理由>"}

选科依据：最近没练的科目、画像里薄弱的知识点、近况里做错的题。
''';

    final planner = JailerAgent(
      llm: OpenAiLlmClient(
        config: LlmConfig(
          baseUrl: settings.baseUrl,
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
    if (subjectId == null || kpId == null) {
      // LLM 没按格式返回 → 兜底：随机选一个科目 + 该科第一个知识点
      final subj = subjects.first;
      final sId = subj['id'] as int;
      final kps = await _kpRepo.getKpsBySubject(sId);
      if (kps.isEmpty) throw StateError('科目下没有知识点');
      return (sId, kps.first['id'] as int);
    }
    return (subjectId, kpId);
  }

  /// 子代理：读该科画像全文 + 近20题，出一题（Markdown）。
  Future<int> _generateAndStore(
    int userId,
    int subjectId,
    int kpId,
    AiSettings settings,
  ) async {
    final subject = await _subjectRepo.getSubjectById(subjectId);
    if (subject == null) throw StateError('科目 $subjectId 不存在');
    final kpName = await _kpRepo.getKpName(kpId) ?? '(未知知识点)';

    final profile = await _portrait.ensureProfile(userId: userId, subjectId: subjectId);
    final recent = await _portrait.recentLog(userId: userId, subjectId: subjectId);

    final prompt = '''
你是「${subject['name']}」老师，为学生出一道单选题。

【学生学科画像】
$profile

【学生近况】
$recent

本次考察知识点：$kpName

要求：
1. 针对画像中的薄弱点与易错模式出题。
2. 难度匹配学生当前水平（参考画像中的推荐难度）。
3. 不要重复近况中已出现过的题型/考点。
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
          baseUrl: settings.baseUrl,
          apiKey: settings.apiKey,
          model: settings.model,
        ),
      ),
      systemPrompt: '你是出题代理，严格按要求的 Markdown 格式出题。',
      toolDefinitionsProvider: () => const [],
      maxIterations: 3,
    );

    final result = await generator.runConversation(prompt);
    final text = result.finalResponse ?? '';
    if (text.trim().isEmpty) {
      throw Exception('出题代理返回为空');
    }

    // 用现有解析器把 Markdown 解析成 GeneratedQuestion
    final parsed = AnthropicAiService.parseMarkdownResponse(text);
    var options = parsed.options;
    var correctAnswer = parsed.correctAnswer;
    if (options.isEmpty) {
      correctAnswer = parsed.correctAnswer.isNotEmpty
          ? parsed.correctAnswer
          : parsed.content.trim();
      options = [correctAnswer, '以上都不是', '无法确定', '选项 D'];
    }

    return _questionRepo.insertQuestion(
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
