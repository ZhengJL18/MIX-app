import 'package:flutter/foundation.dart' show debugPrint;

import '../engine/progress_engine.dart';
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
/// 结构：
///   代码螺旋选点(5阶段进度) → 决策科目+知识点
///   generator JailerAgent 读该科画像全文+近20题 → 出一题(Markdown)
///
/// 编排由本 service 控制：选点(代码) → generator 出题 → 落库。
/// 防重复：prompt 硬性禁止与近况重复（移除代码判重，遇重复手动刷新）。
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

  final ProgressEngine _progressEngine = ProgressEngine();

  final QuestionRepository _questionRepo;
  final SubjectRepository _subjectRepo;
  final KpRepository _kpRepo;
  final StudentPortraitService _portrait;

  /// kpId → 已生成好的下一题（预生成缓存）。
  final Map<int, int> _nextPool = {};

  /// kpId → 正在生成中的 Future（避免重复触发）。
  final Map<int, Future<void>> _inFlight = {};

  /// 近期出过题的 kpId 序列（新→旧），planner 据此避免连续选同一知识点/科目。
  final List<int> _recentKpIds = [];
  static const int _recentKpMax = 6;

  /// 出题成功 → 记录该 kp 到近期序列（科目/知识点轮换）。
  void _rememberKp(int kpId) {
    _recentKpIds.remove(kpId);
    _recentKpIds.insert(0, kpId);
    if (_recentKpIds.length > _recentKpMax) _recentKpIds.removeLast();
  }

  /// 螺旋计数：练满 [SpiralRules.reviewEvery] 道新题，插入 1 道旧知识点回顾。
  int _newQuestionCount = 0;

  /// 螺旋选点：聚焦"距离达标最近"的知识点；每练 N 新回 1 旧。
  /// 返回 (subjectId, kpId)。
  Future<(int, int)> _spiralSelect(int userId) async {
    final subjects = await _subjectRepo.getAllSubjects();
    final engine = ProgressEngine();

    // 收集所有科目的真知识点进度
    final all = <(int, int, String, KpProgress)>[]; // (subjectId, kpId, name, progress)
    for (final subj in subjects) {
      final progresses = await engine.subjectProgresses(userId, subj['id'] as int);
      for (final (kid, name, p) in progresses) {
        all.add((subj['id'] as int, kid, name, p));
      }
    }
    if (all.isEmpty) throw StateError('请先创建科目和知识点');

    // 螺旋回顾：练满 N 新，回 1 旧（选最近练过、非当前聚焦的知识点）
    if (_newQuestionCount >= SpiralRules.reviewEvery) {
      _newQuestionCount = 0;
      final reviewCandidates = all
          .where((e) => e.$4.totalDone > 0 && e.$4.stage > 0) // 练过且非S0
          .toList();
      if (reviewCandidates.isNotEmpty) {
        // 选最近回顾时间最久远的（复习队列）
        reviewCandidates.sort((a, b) {
          final at = a.$4.lastReviewAt ?? '';
          final bt = b.$4.lastReviewAt ?? '';
          return at.compareTo(bt); // 字符串 ISO 时间可比较
        });
        final pick = reviewCandidates.first;
        return (pick.$1, pick.$2);
      }
    }

    // 正常聚焦：选"距达标最近"的知识点（remainingToReach 最小，优先未达标的）
    final active = all.where((e) => !e.$4.reached).toList();
    if (active.isEmpty) {
      // 全达标 → 任意挑一个练（螺旋更高圈）
      final pick = all.first;
      return (pick.$1, pick.$2);
    }
    active.sort((a, b) {
      // 先比"还差几题"（接近达标的优先），差题数相同比进度
      final ra = a.$4.remainingToReach;
      final rb = b.$4.remainingToReach;
      if (ra != rb) return ra.compareTo(rb);
      return b.$4.progress.compareTo(a.$4.progress);
    });
    final pick = active.first;
    _newQuestionCount++;
    return (pick.$1, pick.$2);
  }

  /// 取下一题：预生成池有货直接取；没有则跑完整 planner→generator 出题。
  Future<int> nextQuestionId(int userId, {void Function(String)? onStream}) async {
    final settings = await AiSettings.load();
    if (settings == null || !settings.isComplete) {
      throw Exception('尚未配置 AI 接口，请先在「AI 设置」填入 API Key');
    }

    // 1. 决策：主代理读各科知识点级状态，选科目 + 知识点
    final (subjectId, kpId) = await _plan(userId, settings);

    // 2. 预生成池优先
    final pooled = _nextPool.remove(kpId);
    if (pooled != null) {
      _triggerPregenerate(userId, subjectId, kpId, settings);
      return pooled;
    }

    // 3. 现场生成（带流式回调）+ 后台预生成下一题
    final id = await _generateAndStore(
      userId,
      subjectId,
      kpId,
      settings,
      onStream: onStream,
    );
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

  /// 选点：代码螺旋选点（聚焦接近达标 + 练4回1），返回 (subjectId, kpId)。
  /// 不再依赖 LLM 猜 —— 5 阶段进度是确定性数据，代码直接算。
  Future<(int, int)> _plan(int userId, AiSettings settings) async {
    return _spiralSelect(userId);
  }

  /// 子代理：读该科画像全文 + 近况 + 该知识点实时统计，出一题（Markdown）。
  Future<int> _generateAndStore(
    int userId,
    int subjectId,
    int kpId,
    AiSettings settings, {
    void Function(String accumulated)? onStream,
  }) async {
    // 流式累积缓冲（onDelta 增量 → 累积后回传 UI）
    final streamBuf = StringBuffer();
    final subject = await _subjectRepo.getSubjectById(subjectId);
    if (subject == null) throw StateError('科目 $subjectId 不存在');
    final kpName = await _kpRepo.getKpName(kpId) ?? '(未知知识点)';

    final profile = await _portrait.ensureProfile(userId: userId, subjectId: subjectId);
    final recent = await _portrait.recentLog(userId: userId, subjectId: subjectId);
    // 该知识点的实时做题统计 —— 校准难度的权威依据（画像可能过时）
    final kpStats = await _portrait.kpPracticeStats(userId, kpId);
    // 5 阶段螺旋进度：当前阶段 + 阶段难度（难度随阶段爬升）
    final progress = await _progressEngine.getProgress(userId, kpId);
    final stageName = SpiralRules.stageNames[progress.stage];
    final stageDiff = SpiralRules.stageDifficulty[progress.stage] ?? '基础概念入门题';

    final prompt = '''
你是「${subject['name']}」老师，为学生出一道单选题。

本次考察知识点：$kpName

【该知识点当前阶段】（难度权威依据）
$stageName（第${progress.stage}阶段，本阶段已练${progress.stageTotal}题对${progress.stageCorrect}）
本题必须出「$stageDiff」

【该知识点实时做题情况】
$kpStats

【学生学科画像】
$profile

【学生近况】
$recent

要求：
1. 难度严格按当前阶段出：
   - 第0/1阶段 → 基础概念/基础计算
   - 第2阶段 → 综合应用（含变式）
   - 第3阶段 → 易错陷阱
   - 第4阶段 → 跨知识点综合
   不要低于当前阶段的难度，也无需高于太多。
2. 针对画像中的薄弱点与易错模式出题。
3. 【硬性】「学生近况」里列出的题目都是已经做过的，你的题**严禁与其中任何一题重复或高度相似**（换数字/换字母不算新题）。必须换考点或换题型。
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
      // 真流式：LLM 逐字生成实时回传 UI。
      // onDelta 是增量，onStream 语义是累积 → 用 buffer 累积后回传。
      onDelta: (delta) {
        if (onStream == null) return;
        streamBuf.write(delta);
        debugPrint('[Generator] stream len=${streamBuf.length}');
        onStream(streamBuf.toString());
      },
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
    _rememberKp(kpId); // 科目/知识点轮换：记录刚出的 kp
    return qid;
  }
}
