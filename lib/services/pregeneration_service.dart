import '../engine/prompt_builder.dart';
import '../repository/kp_state_repository.dart';
import '../repository/question_repository.dart';
import '../repository/subject_repository.dart';
import 'ai_service.dart';

/// 对应设计文档 5.2"提前一题生成"：
///
///   用户做第 N 道题 -> 后台调用 AI 生成第 N+1 道 -> questions 表 + next_pool
///   用户切下一题 -> 直接从 next_pool 取出（零延迟） -> 后台生成第 N+2 道
///
/// next_pool 深度固定为 1（[EngineConstants.pregenDepth]），
/// 用内存 Map 维护"下一题"，每个 kpId 一个槽位即可满足单知识点连续做题场景；
/// 若用户中途切换知识点，直接退化为同步生成（体验上偶尔等待一次，可接受）。
class PregenerationService {
  PregenerationService({
    AiService? aiService,
    QuestionRepository? questionRepo,
    SubjectRepository? subjectRepo,
    KpStateRepository? kpStateRepo,
    PromptBuilder? promptBuilder,
  })  : _ai = aiService ?? MockAiService(),
        _questionRepo = questionRepo ?? QuestionRepository(),
        _subjectRepo = subjectRepo ?? SubjectRepository(),
        _kpStateRepo = kpStateRepo ?? KpStateRepository(),
        _promptBuilder = promptBuilder ?? PromptBuilder();

  final AiService _ai;
  final QuestionRepository _questionRepo;
  final SubjectRepository _subjectRepo;
  final KpStateRepository _kpStateRepo;
  final PromptBuilder _promptBuilder;

  /// kpId -> 已经生成好、还没被取走的下一题 questionId
  final Map<int, int> _nextPool = {};

  /// kpId -> 正在后台生成的 Future（避免重复触发）
  final Map<int, Future<void>> _inFlight = {};

  /// 取下一题：若 next_pool 里已有，直接返回并立刻触发下一次后台生成；
  /// 若没有（首次进入该知识点，或来不及生成），同步生成一次再返回。
  Future<int> nextQuestionId(int userId, int kpId, int subjectId) async {
    final pooled = _nextPool.remove(kpId);
    if (pooled != null) {
      _triggerPregenerate(userId, kpId, subjectId);
      return pooled;
    }

    // 冷启动：优先用未做过的种子题，避免第一题就等 AI
    final seed = await _questionRepo.getUnusedSeedQuestion(kpId, userId);
    if (seed != null) {
      _triggerPregenerate(userId, kpId, subjectId);
      return seed['id'] as int;
    }

    final id = await _generateAndStore(userId, kpId, subjectId);
    _triggerPregenerate(userId, kpId, subjectId);
    return id;
  }

  void _triggerPregenerate(int userId, int kpId, int subjectId) {
    if (_nextPool.containsKey(kpId)) return; // 已有存货
    if (_inFlight.containsKey(kpId)) return; // 已在生成中

    final future = _generateAndStore(userId, kpId, subjectId).then((id) {
      _nextPool[kpId] = id;
    }).whenComplete(() {
      _inFlight.remove(kpId);
    });
    _inFlight[kpId] = future;
  }

  Future<int> _generateAndStore(int userId, int kpId, int subjectId) async {
    final subject = await _subjectRepo.getSubjectById(subjectId);
    if (subject == null) throw StateError('科目 $subjectId 不存在');

    final state = await _kpStateRepo.getOrCreateState(userId: userId, kpId: kpId, subject: subject);
    final prompt = await _promptBuilder.buildPrompt(kpId: kpId, subject: subject, state: state);
    final generated = await _ai.generateQuestion(prompt);

    return _questionRepo.insertQuestion(
      kpId: kpId,
      content: generated.content,
      answer: generated.answer,
      cplxCoef: generated.cplxCoef,
      undCoef: generated.undCoef,
      redCoef: generated.redCoef,
      covCoef: generated.covCoef,
      isSeed: false,
    );
  }
}
