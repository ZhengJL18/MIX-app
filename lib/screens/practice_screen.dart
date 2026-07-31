import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/question_card.dart';
import '../widgets/answer_card.dart';
import '../widgets/feedback_card.dart';
import '../widgets/swipeable_stack.dart';
import '../engine/feedback_v2.dart';

/// 刷题页 — TikTok 式下滑刷题
///
/// 每题 3 个固定页面槽位：
///   0: 题目 → 1: 答案+✅❌ → 2:  反馈页（答错才显示，答对/跳过则空白占位）
/// Page 2 的 onPageChanged 触发提交并加载下一题。
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key});

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

/// 单题答题状态机
enum _AnswerState { unanswered, correct, wrong }

class _PracticeScreenState extends State<PracticeScreen> {
  _AnswerState _currentAnswer = _AnswerState.unanswered;
  String? _mainCause;
  String? _minorCause;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = context.read<AppState>();
      if (appState.currentQuestion == null && !appState.loadingNext) {
        appState.loadNextQuestion();
      }
    });
  }

  Map<String, dynamic>? get _q => context.read<AppState>().currentQuestion;

  void _onCorrect() {
    setState(() => _currentAnswer = _AnswerState.correct);
  }

  void _onWrong() {
    setState(() => _currentAnswer = _AnswerState.wrong);
  }

  /// 用户滑过了提示/答题结束 → 提交+下一题
  Future<void> _onAdvance() async {
    if (_submitting) return;
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

    _currentAnswer = _AnswerState.unanswered;
    _mainCause = null;
    _minorCause = null;
    appState.loadNextQuestion();
    _submitting = false;
  }

  /// 反馈页主因/辅因变更回调
  void _onMainCauseChanged(String? cause) => setState(() => _mainCause = cause);
  void _onMinorCauseChanged(String? cause) => setState(() => _minorCause = cause);

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final q = appState.currentQuestion;

        // 加载中
        if (appState.loadingNext && q == null) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
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

        // 三页构建
        final pages = <Widget>[
          // Page 0 — 题目
          QuestionCard(question: q),

          // Page 1 — 答案 + ✅❌
          AnswerCard(question: q, onCorrect: _onCorrect, onWrong: _onWrong),

          // Page 2 — 反馈页（答错才显示内容）
          Builder(builder: (_) {
            if (_currentAnswer == _AnswerState.wrong) {
              return FeedbackCard(
                mainCause: _mainCause,
                minorCause: _minorCause,
                onMainCauseChanged: _onMainCauseChanged,
                onMinorCauseChanged: _onMinorCauseChanged,
              );
            }
            // 答对/跳过 → 空白占位，直接滑过去
            return const _AutoAdvancePage();
          }),
        ];

        return Container(
          color: AppColors.lightBg,
          child: Column(
            children: [
              const _StatusBar(),
              Expanded(
                child: SwipeableStack(
                  key: ValueKey(appState.questionIndex),
                  pages: pages,
                  onPageChanged: (pageIdx) {
                    // 滑到最后一页 → 提交 + 加载下一题
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

/// 空白占位页 — 直接让下滑通过
class _AutoAdvancePage extends StatelessWidget {
  const _AutoAdvancePage();

  @override
  Widget build(BuildContext context) {
    return Container(color: AppColors.lightBg);
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
            child: const Text('刷题模式',
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
