import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/question_card.dart';
import '../widgets/answer_card.dart';
import '../widgets/feedback_card.dart';
import '../widgets/swipeable_stack.dart';
import '../widgets/rich_content.dart';
import '../engine/feedback_v2.dart';

/// 刷题页 — TikTok 式下滑刷题，全单选题自动判卷。
///
/// 每题 3 个固定页面槽位：
///   0: 题目（选项单选）→ 1: 答案（自动判卷结果）→ 2: 反馈页（答错才显示）
/// Page 2 的 onPageChanged 触发提交并加载下一题；未选答案 / 未选主因会被
/// 拦截回跳，不产生错误记录。
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key});

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

/// 单题答题状态机
enum _AnswerState { unanswered, correct, wrong }

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

  /// 非选择题兜底手动判卷
  void _onCorrect() => setState(() => _currentAnswer = _AnswerState.correct);
  void _onWrong() => setState(() => _currentAnswer = _AnswerState.wrong);

  /// 提交 + 下一题。校验失败回跳对应页并提示，不提交。
  Future<void> _onAdvance() async {
    if (_submitting) return;

    // 未选答案：回跳题目页
    if (_currentAnswer == _AnswerState.unanswered) {
      _pageCtrl.animateToPage(0,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先在题目页选择一个答案'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }

    // 答错但没选主因：回跳反馈页
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

    _currentAnswer = _AnswerState.unanswered;
    _selectedOption = null;
    _mainCause = null;
    _minorCause = null;
    _streamingText = '';
    appState.loadNextQuestion(onStream: _onStream);
    _pageCtrl.jumpToPage(0);
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

        // 三页构建
        final pages = <Widget>[
          // Page 0 — 题目（单选）
          QuestionCard(
            question: q,
            selectedOption: _selectedOption,
            onOptionSelected: _onOptionSelected,
          ),

          // Page 1 — 答案 + 判卷结果
          AnswerCard(
            question: q,
            selectedOption: _selectedOption,
            isCorrect: _currentAnswer == _AnswerState.correct,
            onCorrect: _onCorrect,
            onWrong: _onWrong,
          ),

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
            // 答对 → 空白占位，直接滑过去
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
                  controller: _pageCtrl,
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
