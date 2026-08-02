import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/feedback_v2.dart';
import '../engine/selection.dart';
import '../data/preset_data.dart';
import '../repository/kp_repository.dart';
import '../repository/kp_state_repository.dart';
import '../repository/practice_repository.dart';
import '../repository/question_repository.dart';
import '../repository/subject_repository.dart';
import '../services/ai_service.dart';
import '../services/pregeneration_service.dart';

/// 单机版固定用户 id = 1。
/// TODO: 多用户时改为从本地 SharedPreferences/uuid 生成，或对接账号系统。
const int kLocalUserId = 1;

class AppState extends ChangeNotifier {
  AppState({AiService? aiService})
      : _aiService = aiService ?? MockAiService() {
    _pregen = PregenerationService(aiService: _aiService);
    // 启动时加载用户保存的 AI 配置，避免重启后静默降级成示例题
    _loadSavedAiConfig();
  }

  final SubjectRepository subjectRepo = SubjectRepository();
  final KpRepository kpRepo = KpRepository();
  final KpStateRepository kpStateRepo = KpStateRepository();
  final QuestionRepository questionRepo = QuestionRepository();
  final PracticeRepository practiceRepo = PracticeRepository();
  final SelectionEngine selectionEngine = SelectionEngine();

  AiService _aiService;
  late PregenerationService _pregen;

  int _questionIndex = 0;
  int? _currentSubjectId;
  int? _currentKpId;
  Map<String, dynamic>? _currentQuestion;
  bool _loadingNext = false;
  String? _lastError;

  // ── 多题队列（连续流） ──
  final List<Map<String, dynamic>> _questions = [];
  int _cursor = 0;

  /// 已加载题目队列（供刷题连续流渲染）。
  List<Map<String, dynamic>> get questions => _questions;

  /// 当前游标（当前展示的题在队列中的位置）。
  int get cursor => _cursor;

  /// 当前题目 = 队列游标处的题（兼容旧引用）。
  @override
  Map<String, dynamic>? get currentQuestion =>
      _questions.isNotEmpty && _cursor < _questions.length
          ? _questions[_cursor]
          : null;

  int get questionIndex => _questionIndex;
  int? get currentSubjectId => _currentSubjectId;
  int? get currentKpId => _currentKpId;
  bool get loadingNext => _loadingNext;
  String? get lastError => _lastError;

  /// 允许运行期切换 AI 服务实现（例如用户在设置里填入了真实 API Key）。
  void configureAiService(AiService service) {
    _aiService = service;
    _pregen = PregenerationService(aiService: _aiService);
  }

  /// 启动时从 SharedPreferences 读取用户配置的真实 AI 服务。
  /// 未配置（或配置不完整）时保持 MockAiService 兜底。
  Future<void> _loadSavedAiConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getString('api_key') ?? '';
      final model = prefs.getString('ai_model') ?? '';
      final vendor = prefs.getString('ai_vendor') ?? '';
      if (key.isEmpty || model.isEmpty || vendor.isEmpty) return;

      final preset = kAiVendors.where((v) => v.id == vendor).firstOrNull;
      final base = preset?.baseUrl ?? prefs.getString('ai_base_url') ?? '';
      if (base.isEmpty) return;

      final url = base.endsWith('/chat/completions') ? base : '$base/chat/completions';
      configureAiService(OpenAiCompatibleAiService(baseUrl: url, model: model, apiKey: key));
    } catch (e) {
      debugPrint('[AppState] 加载 AI 配置失败: $e');
    }
  }

  /// 三层筛选 + 出题：选科目 -> 选知识点 -> 取/生成题目，追加到队列。
  ///
  /// [onStream] 可选：AI 现场生成时实时回调累积文本，UI 可流式渲染。
  Future<void> loadNextQuestion({
    void Function(String accumulated)? onStream,
  }) async {
    _loadingNext = true;
    _lastError = null;
    notifyListeners();
    try {
      final question = await _generateOne(onStream: onStream);
      if (question != null) {
        _questions.add(question);
      }
    } catch (e) {
      _lastError = _friendlyError(e);
    } finally {
      _loadingNext = false;
      notifyListeners();
    }
  }

  /// 生成一道题（选科目/知识点 + 取/生成题目）。
  Future<Map<String, dynamic>?> _generateOne({
    void Function(String accumulated)? onStream,
  }) async {
    final subjects = await subjectRepo.getAllSubjects();
    if (subjects.isEmpty) {
      _lastError = '请先在"科目管理"中创建至少一个科目和知识点';
      return null;
    }
    final subjectId = await selectionEngine.selectSubject(kLocalUserId);
    final kpId =
        await selectionEngine.selectKp(kLocalUserId, subjectId, _questionIndex);
    final questionId =
        await _pregen.nextQuestionId(kLocalUserId, kpId, subjectId, onStream: onStream);
    final question = await questionRepo.getById(questionId);

    _currentSubjectId = subjectId;
    _currentKpId = kpId;
    _questionIndex += 1;
    return question;
  }

  /// 移动游标到 [index]。同时保证前后有足够题目（前3后5缓存），
  /// 不足时后台补齐。
  Future<void> moveCursor(int index) async {
    if (index < 0 || index >= _questions.length) return;
    _cursor = index;
    notifyListeners();
    await ensureLoadedAround(index);
  }

  /// 保证 [index] 前后有足够题目：前 3 后 5。
  /// 不足时后台生成补齐（AI 出题慢，尽量提前生成）。
  Future<void> ensureLoadedAround(int index) async {
    // 尾部不足 → 后台补足到 index+5
    while (_questions.length < index + 5) {
      await loadNextQuestion();
    }
  }

  /// 把异常转成用户能看懂的错误提示。
  static String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('科目') || s.contains('知识点')) {
      return '还没有可用的科目/知识点，请先在「科目管理」创建';
    }
    if (s.contains('SocketException') || s.contains('Connection refused')) {
      return '网络连接失败，请检查网络后重试';
    }
    if (s.contains('401') || s.contains('403') || s.contains('API Key') || s.contains('api_key')) {
      return 'AI 接口认证失败，请检查「AI 设置」中的 API Key';
    }
    if (s.contains('429')) return 'AI 请求过于频繁，请稍后再试';
    if (s.contains('timeout') || s.contains('Timed out')) return 'AI 响应超时，请重试';
    return '出题失败：$s';
  }

  /// 提交作答结果：写 practice_records + 按 3.4 公式更新 kp_user_state。
  ///
  /// [question] 必传：多题队列下可能不是当前题。
  Future<void> submitAnswer({
    required bool correct,
    required Map<String, dynamic> question,
    String? mainCause,
    String? minorCause,
  }) async {
    final kpId = _currentKpId;
    final subjectId = _currentSubjectId;
    if (kpId == null || subjectId == null || question == null) return;

    await practiceRepo.insertRecord(
      userId: kLocalUserId,
      questionId: question['id'] as int,
      correct: correct,
      mainCause: mainCause,
      minorCause: minorCause,
    );

    final subject = await subjectRepo.getSubjectById(subjectId);
    if (subject == null) return;
    final state = await kpStateRepo.getOrCreateState(
      userId: kLocalUserId,
      kpId: kpId,
      subject: subject,
    );

    final updated = applyFeedbackV2(
      state: state,
      subject: subject,
      correct: correct,
      mainCause: mainCause,
      minorCause: minorCause,
    );
    await kpStateRepo.updateState(state['id'] as int, {
      'complexity': updated['complexity'],
      'understand': updated['understand'],
      'redundancy': updated['redundancy'],
      'coverage': updated['coverage'],
      'streak_correct': updated['streak_correct'],
      'streak_wrong': updated['streak_wrong'],
      'review_count': updated['review_count'],
      'last_review_at': updated['last_review_at'],
    });
    notifyListeners();
  }
}
