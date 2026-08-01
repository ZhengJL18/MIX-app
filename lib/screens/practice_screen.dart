import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/question_card.dart';
import '../widgets/answer_card.dart';
import '../widgets/feedback_card.dart';
import '../widgets/fun_result_card.dart';
import '../widgets/swipeable_stack.dart';
import '../widgets/rich_content.dart';
import '../engine/feedback_v2.dart';

/// 刷题页 — TikTok 式下滑刷题，全单选题自动判卷 + 趣味化反馈。
///
/// 页面结构随作答状态动态变化：
/// - 未作答（下滑跳过）：2 页 —— 题目 → 趣味「还没做题」页
/// - 做对 / 做错：3 页 —— 题目 → 趣味结果页 → 答案+解析（做错含错因反馈）
///
/// 下滑最后一页触发提交或跳过；答错但未选主因会被拦截回跳。
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key});

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

/// 单题答题状态机
enum _AnswerState { unanswered, correct, wrong }

/// 判断题目是否带选项（选择题）。
bool _hasOptions(dynamic raw) {
  if (raw == null) return false;
  if (raw is List) return raw.isNotEmpty;
  try {
    final decoded = jsonDecode(raw as String);
    return decoded is List && decoded.isNotEmpty;
  } catch (_) {
    return false;
  }
}

class _PracticeScreenState extends State<PracticeScreen> {
  _AnswerState _currentAnswer = _AnswerState.unanswered;
  String? _selectedOption;
  String? _mainCause;
  String? _minorCause;
  bool _submitting = false;

  /// AI 现场生成题目的流式文本（实时显示）
  String _streamingText = '';

  final PageController _pageCtrl = PageController();

  /// 上一题的 questionIndex，用于检测新题加载完成时重置到第 0 页
  int _lastQuestionIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = context.read<AppState>();
      if (appState.currentQuestion == null && !appState.loadingNext) {
        appState.loadNextQuestion(onStream: _onStream);
      }
    });
  }

  /// 新题真正加载完成（questionIndex 变化）后，重置回第 0 页。
  /// 不能在 _nextQuestion 里立即 jumpToPage(0) —— 那时新题还没生成，
  /// 旧题的 PageView 还在，直接跳会造成翻页错乱（bug：回弹/累积多页）。
  void _handleQuestionIndexChanged(int newIndex) {
    if (newIndex == _lastQuestionIndex) return;
    _lastQuestionIndex = newIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageCtrl.hasClients) {
        _pageCtrl.jumpToPage(0);
      }
    });
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _onStream(String accumulated) {
    if (!mounted) return;
    setState(() => _streamingText = accumulated);
  }

  Map<String, dynamic>? get _q => context.read<AppState>().currentQuestion;

  /// 选项变化 → 立即自动判卷
  void _onOptionSelected(String? option) {
    final q = _q;
    if (q == null) return;
    setState(() {
      _selectedOption = option;
      if (option == null) {
        _currentAnswer = _AnswerState.unanswered;
      } else {
        final answer = (q['answer'] as String? ?? '').trim();
        _currentAnswer = option.trim() == answer
            ? _AnswerState.correct
            : _AnswerState.wrong;
      }
    });
  }

  /// 已作答 → 提交并进入下一题（由答案页的「下一题」按钮触发）。
  Future<void> _onAdvance() async {
    if (_submitting) return;

    // 未作答不应走到这里（skip 由 onPageChanged 处理）
    if (_currentAnswer == _AnswerState.unanswered) {
      _nextQuestion(skip: true);
      return;
    }

    // 答错但没选主因：回跳反馈区（最后一页），不提交
    if (_currentAnswer == _AnswerState.wrong && _mainCause == null) {
      _pageCtrl.animateToPage(2,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先选择错误主因，帮助系统更精准地调整出题'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    _submitting = true;
    final appState = context.read<AppState>();
    final q = _q;
    if (q == null) {
      _submitting = false;
      return;
    }

    String? mainDim;
    String? minorDim;
    if (_currentAnswer == _AnswerState.wrong) {
      if (_mainCause != null) mainDim = mapCauseLabelToDim(_mainCause!);
      if (_minorCause != null) minorDim = mapCauseLabelToDim(_minorCause!);
    }

    await appState.submitAnswer(
      correct: _currentAnswer == _AnswerState.correct,
      mainCause: mainDim,
      minorCause: minorDim,
    );

    _nextQuestion(skip: false);
    _submitting = false;
  }

  void _nextQuestion({required bool skip}) {
    _currentAnswer = _AnswerState.unanswered;
    _selectedOption = null;
    _mainCause = null;
    _minorCause = null;
    _streamingText = '';
    context.read<AppState>().loadNextQuestion(onStream: _onStream);
    // 不在此处 jumpToPage(0)：新题未加载时旧 PageView 还在，
    // 直接跳会造成翻页错乱。由 _handleQuestionIndexChanged 在新题
    // 加载完成后统一重置。
  }

  /// 反馈页主因/辅因变更回调
  void _onMainCauseChanged(String? cause) => setState(() => _mainCause = cause);
  void _onMinorCauseChanged(String? cause) => setState(() => _minorCause = cause);

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        // 新题加载完成 → 重置回第 0 页（不能提前 jump，见 _nextQuestion 注释）
        _handleQuestionIndexChanged(appState.questionIndex);

        final q = appState.currentQuestion;

        // 加载中（AI 现场生成时显示流式内容）
        if (appState.loadingNext && q == null) {
          return _LoadingView(streamingText: _streamingText);
        }
        // 错误（无科目等）
        if (appState.lastError != null && q == null) {
          return _ErrorView(
            message: appState.lastError!,
            onRetry: () => appState.loadNextQuestion(),
          );
        }
        // 无题目
        if (q == null) {
          return const Center(
            child: Text('暂无题目', style: TextStyle(color: Color(0xFF8B7355), fontSize: 16)),
          );
        }

        final hasOptions = _hasOptions(q['options']);
        final answered = _currentAnswer != _AnswerState.unanswered;

        // 动态页面：
        // - 选择题未作答：2 页（题目→趣味skip），滑到趣味页 = 跳过
        // - 选择题已作答：3 页（题目→趣味结果→答案+解析），答案页停留展示，
        //   点「下一题」按钮或滑到趣味页再滑才进入下一题
        // - 非选择题（历史无选项题）：2 页（题目→答案+手动判卷），不做趣味
        final pages = <Widget>[
          // Page 0 — 题目
          QuestionCard(
            question: q,
            selectedOption: _selectedOption,
            onOptionSelected: _onOptionSelected,
          ),

          // Page 1 — 非选择题直接给答案（否则趣味结果页）
          if (!hasOptions)
            _AnswerDetailPage(
              question: q,
              selectedOption: _selectedOption,
              isCorrect: _currentAnswer == _AnswerState.correct,
              mainCause: _mainCause,
              minorCause: _minorCause,
              onMainCauseChanged: _onMainCauseChanged,
              onMinorCauseChanged: _onMinorCauseChanged,
              onNext: _onAdvance,
            )
          else
            FunResultCard(
              type: _currentAnswer == _AnswerState.correct
                  ? FunResultType.correct
                  : _currentAnswer == _AnswerState.wrong
                      ? FunResultType.wrong
                      : FunResultType.skip,
            ),

          // Page 2 — 选择题已作答时的答案+解析（做错含错因反馈）
          if (hasOptions && answered)
            _AnswerDetailPage(
              question: q,
              selectedOption: _selectedOption,
              isCorrect: _currentAnswer == _AnswerState.correct,
              mainCause: _mainCause,
              minorCause: _minorCause,
              onMainCauseChanged: _onMainCauseChanged,
              onMinorCauseChanged: _onMinorCauseChanged,
              onNext: _onAdvance,
            ),
        ];

        return Container(
          color: AppColors.lightBg,
          child: Column(
            children: [
              const _StatusBar(),
              Expanded(
                child: SwipeableStack(
                  key: ValueKey(appState.questionIndex),
                  controller: _pageCtrl,
                  pages: pages,
                  onPageChanged: (pageIdx) {
                    // 只有未作答时滑到趣味 skip 页才跳过；
                    // 已作答答案页用「下一题」按钮进入，不自动提交
                    if (_currentAnswer == _AnswerState.unanswered &&
                        pageIdx >= pages.length - 1) {
                      _nextQuestion(skip: true);
                    }
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 答案+解析页（第 3 页）— 做对显示答案解析，做错额外含错因反馈。
///
/// 页面底部有「下一题」按钮（[onNext]），用户在答案页停留看完后
/// 点按钮进入下一题。已作答时不再"滑到即提交"。
class _AnswerDetailPage extends StatelessWidget {
  final Map<String, dynamic> question;
  final String? selectedOption;
  final bool isCorrect;
  final String? mainCause;
  final String? minorCause;
  final ValueChanged<String?> onMainCauseChanged;
  final ValueChanged<String?> onMinorCauseChanged;
  final VoidCallback onNext;

  const _AnswerDetailPage({
    required this.question,
    required this.selectedOption,
    required this.isCorrect,
    required this.mainCause,
    required this.minorCause,
    required this.onMainCauseChanged,
    required this.onMinorCauseChanged,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final hasOptions = _hasOptions(question['options']);

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnswerCard(
                  question: question,
                  selectedOption: selectedOption,
                  isCorrect: isCorrect,
                ),
                // 做错 → 错因反馈（主因必选）
                if (!isCorrect && hasOptions) ...[
                  const SizedBox(height: 8),
                  FeedbackCard(
                    mainCause: mainCause,
                    minorCause: minorCause,
                    onMainCauseChanged: onMainCauseChanged,
                    onMinorCauseChanged: onMinorCauseChanged,
                  ),
                ],
                const SizedBox(height: 24),
                // 「下一题」按钮 — 明确进入下一题，避免滑到即提交导致解析一闪而过
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: onNext,
                    icon: const Icon(Icons.arrow_downward, size: 18),
                    label: const Text('下一题', style: TextStyle(fontSize: 15)),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// AI 生成题目时的加载视图 — 有流式文本时实时渲染
class _LoadingView extends StatelessWidget {
  final String streamingText;
  const _LoadingView({required this.streamingText});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.lightBg,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: AppColors.primary),
          const SizedBox(height: 16),
          const Text(
            'AI 正在生成题目...',
            style: TextStyle(color: Color(0xFF8B7355), fontSize: 14),
          ),
          if (streamingText.isNotEmpty) ...[
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: RichContent(
                  content: streamingText,
                  style: const TextStyle(color: Color(0xFF8B7355), fontSize: 13, height: 1.5),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── 顶部状态栏 ───

class _StatusBar extends StatelessWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      color: AppColors.lightSurface,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text('刷题模式 · 单选题',
                style: TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ─── 错误视图 ───

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.info_outline, size: 48, color: Color(0xFF8B7355)),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF8B7355))),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
