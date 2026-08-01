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

  /// 非选择题兜底手动判卷（历史无选项题）
  void _onCorrect() => setState(() => _currentAnswer = _AnswerState.correct);
  void _onWrong() => setState(() => _currentAnswer = _AnswerState.wrong);

  /// 滑过最后一页：未作答=跳过，已作答=提交。
  Future<void> _onAdvance() async {
    if (_submitting) return;

    // 未作答 → 跳过本题，不记录
    if (_currentAnswer == _AnswerState.unanswered) {
      _nextQuestion(skip: true);
      return;
    }

    // 答错但没选主因：回跳反馈区（最后一页）
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
    _pageCtrl.jumpToPage(0);
  }

  /// 反馈页主因/辅因变更回调
  void _onMainCauseChanged(String? cause) => setState(() => _mainCause = cause);
  void _onMinorCauseChanged(String? cause) => setState(() => _minorCause = cause);

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) {
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

        // 动态页面：
        // - 选择题：未作答 2 页（题目→趣味skip），已作答 3 页（题目→趣味结果→答案）
        // - 非选择题（历史无选项题）：2 页（题目→答案+手动判卷按钮），不做趣味skip
        final pages = <Widget>[
          // Page 0 — 题目
          QuestionCard(
            question: q,
            selectedOption: _selectedOption,
            onOptionSelected: _onOptionSelected,
          ),

          // Page 1 — 非选择题直接给答案+手动按钮（否则趣味结果页）
          if (!hasOptions)
            _AnswerDetailPage(
              question: q,
              selectedOption: _selectedOption,
              isCorrect: _currentAnswer == _AnswerState.correct,
              mainCause: _mainCause,
              minorCause: _minorCause,
              onMainCauseChanged: _onMainCauseChanged,
              onMinorCauseChanged: _onMinorCauseChanged,
              onCorrect: _onCorrect,
              onWrong: _onWrong,
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
          if (hasOptions && _currentAnswer != _AnswerState.unanswered)
            _AnswerDetailPage(
              question: q,
              selectedOption: _selectedOption,
              isCorrect: _currentAnswer == _AnswerState.correct,
              mainCause: _mainCause,
              minorCause: _minorCause,
              onMainCauseChanged: _onMainCauseChanged,
              onMinorCauseChanged: _onMinorCauseChanged,
              onCorrect: _onCorrect,
              onWrong: _onWrong,
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
                    // 滑到最后一页 → 提交或跳过
                    if (pageIdx >= pages.length - 1) {
                      _onAdvance();
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
class _AnswerDetailPage extends StatelessWidget {
  final Map<String, dynamic> question;
  final String? selectedOption;
  final bool isCorrect;
  final String? mainCause;
  final String? minorCause;
  final ValueChanged<String?> onMainCauseChanged;
  final ValueChanged<String?> onMinorCauseChanged;
  final VoidCallback onCorrect;
  final VoidCallback onWrong;

  const _AnswerDetailPage({
    required this.question,
    required this.selectedOption,
    required this.isCorrect,
    required this.mainCause,
    required this.minorCause,
    required this.onMainCauseChanged,
    required this.onMinorCauseChanged,
    required this.onCorrect,
    required this.onWrong,
  });

  @override
  Widget build(BuildContext context) {
    // 有 options 是选择题（自动判卷）；无 options 是历史非选择题（保留手动按钮）
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
                  onCorrect: onCorrect,
                  onWrong: onWrong,
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
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    '下滑进入下一题 ➡',
                    style: const TextStyle(color: Color(0xFFA09080), fontSize: 13),
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
