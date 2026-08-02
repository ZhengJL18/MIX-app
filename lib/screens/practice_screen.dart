import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/question_card.dart';
import '../widgets/answer_card.dart';
import '../widgets/feedback_card.dart';
import '../widgets/fun_result_card.dart';
import '../widgets/rich_content.dart';
import '../engine/feedback_v2.dart';

/// 刷题页 — 题目连续流（TikTok 式上下滑）。
///
/// 每道题占一页，页内纵向滚动展示：题目(选项) → 趣味结果 → 答案+解析。
/// 下滑自然切到下一题；AppState 维护多题队列（前3后5缓存），
/// 后台持续预生成，滑动零等待。无"下一题"按钮。
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key});

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

/// 单题答题状态
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
  final PageController _pageCtrl = PageController();
  bool _started = false;

  /// 按题号记录作答状态（题 index → 状态）
  final Map<int, _AnswerState> _answerStates = {};
  final Map<int, String?> _selectedOptions = {};
  final Map<int, String?> _mainCauses = {};
  final Map<int, String?> _minorCauses = {};

  /// AI 现场生成题目的流式文本（实时显示）
  String _streamingText = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = context.read<AppState>();
      if (appState.questions.isEmpty && !_started) {
        _started = true;
        appState.loadNextQuestion(onStream: _onStream).then((_) {
          if (mounted) appState.ensureLoadedAround(0);
        });
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

  _AnswerState _state(int idx) => _answerStates[idx] ?? _AnswerState.unanswered;

  void _onOptionSelected(int idx, String? option) {
    final appState = context.read<AppState>();
    final q = idx < appState.questions.length ? appState.questions[idx] : null;
    if (q == null) return;
    setState(() {
      _selectedOptions[idx] = option;
      if (option == null) {
        _answerStates[idx] = _AnswerState.unanswered;
      } else {
        final answer = (q['answer'] as String? ?? '').trim();
        _answerStates[idx] = option.trim() == answer
            ? _AnswerState.correct
            : _AnswerState.wrong;
      }
    });
  }

  /// 提交作答（切走该题或选完错因后）。
  Future<void> _submit(int idx) async {
    final appState = context.read<AppState>();
    final q = idx < appState.questions.length ? appState.questions[idx] : null;
    if (q == null) return;
    final state = _state(idx);
    if (state == _AnswerState.unanswered) return; // 未作答不提交

    final mainCause = _mainCauses[idx];
    final minorCause = _minorCauses[idx];
    String? mainDim;
    String? minorDim;
    if (state == _AnswerState.wrong) {
      if (mainCause != null) mainDim = mapCauseLabelToDim(mainCause);
      if (minorCause != null) minorDim = mapCauseLabelToDim(minorCause);
      if (mainDim == null) return; // 答错必须选主因
    }

    await appState.submitAnswer(
      correct: state == _AnswerState.correct,
      question: q,
      mainCause: mainDim,
      minorCause: minorDim,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final questions = appState.questions;

        // 加载中（首题生成中）
        if (questions.isEmpty && appState.loadingNext) {
          return _LoadingView(streamingText: _streamingText);
        }
        // 错误
        if (questions.isEmpty && appState.lastError != null) {
          return _ErrorView(
            message: appState.lastError!,
            onRetry: () {
              appState.loadNextQuestion(onStream: _onStream);
            },
          );
        }
        // 空
        if (questions.isEmpty) {
          return Center(
            child: Text('暂无题目', style: TextStyle(color: AppColors.lightTextMuted, fontSize: 16)),
          );
        }

        // 用队列长度做 PageView。每页一道题的完整内容（纵向滚动）。
        return Container(
          color: AppColors.lightBg,
          child: Column(
            children: [
              const _StatusBar(),
              Expanded(
                child: PageView.builder(
                  controller: _pageCtrl,
                  scrollDirection: Axis.vertical,
                  physics: const _TikTokPhysics(),
                  itemCount: questions.length,
                  // 预渲染相邻页（前3后5缓存），滑动不卡顿
                  allowImplicitScrolling: true,
                  itemBuilder: (context, idx) {
                    return _QuestionPage(
                      key: ValueKey('q-$idx'),
                      question: questions[idx],
                      answerState: _state(idx),
                      selectedOption: _selectedOptions[idx],
                      mainCause: _mainCauses[idx],
                      minorCause: _minorCauses[idx],
                      hasOptions: _hasOptions(questions[idx]['options']),
                      onOptionSelected: (opt) => _onOptionSelected(idx, opt),
                      onMainCauseChanged: (c) => setState(() => _mainCauses[idx] = c),
                      onMinorCauseChanged: (c) => setState(() => _minorCauses[idx] = c),
                      onAdvance: () {
                        // 滑动离开本题 → 提交（若已作答）
                        if (_state(idx) != _AnswerState.unanswered) {
                          _submit(idx);
                        }
                      },
                    );
                  },
                  onPageChanged: (page) {
                    // 切题：移动游标，触发后台预生成下一批
                    appState.moveCursor(page);
                    if (page > 0) _submit(page - 1); // 提交上一题
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

/// 一道题的完整页：题目(选项) → 趣味结果 → 答案+解析（纵向滚动）。
class _QuestionPage extends StatelessWidget {
  final Map<String, dynamic> question;
  final _AnswerState answerState;
  final String? selectedOption;
  final String? mainCause;
  final String? minorCause;
  final bool hasOptions;
  final ValueChanged<String?> onOptionSelected;
  final ValueChanged<String?> onMainCauseChanged;
  final ValueChanged<String?> onMinorCauseChanged;
  final VoidCallback onAdvance;

  const _QuestionPage({
    super.key,
    required this.question,
    required this.answerState,
    required this.selectedOption,
    required this.mainCause,
    required this.minorCause,
    required this.hasOptions,
    required this.onOptionSelected,
    required this.onMainCauseChanged,
    required this.onMinorCauseChanged,
    required this.onAdvance,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final answered = answerState != _AnswerState.unanswered;

    return Container(
      color: AppColors.lightBg,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 题目 + 选项（compact 嵌入滚动容器）
            QuestionCard(
              question: question,
              selectedOption: selectedOption,
              onOptionSelected: onOptionSelected,
              compact: true,
            ),
            const SizedBox(height: 20),
            // 趣味结果（未作答 = skip，作答 = 对/错）
            FunResultCard(
              type: answerState == _AnswerState.correct
                  ? FunResultType.correct
                  : answerState == _AnswerState.wrong
                      ? FunResultType.wrong
                      : FunResultType.skip,
              compact: true,
            ),
            const SizedBox(height: 20),
            // 答案 + 解析（已作答才显示）
            if (answered) ...[
              AnswerCard(
                question: question,
                selectedOption: selectedOption,
                isCorrect: answerState == _AnswerState.correct,
              ),
              // 做错 → 错因反馈
              if (answerState == _AnswerState.wrong && hasOptions) ...[
                const SizedBox(height: 8),
                FeedbackCard(
                  mainCause: mainCause,
                  minorCause: minorCause,
                  onMainCauseChanged: onMainCauseChanged,
                  onMinorCauseChanged: onMinorCauseChanged,
                ),
              ],
            ],
            const SizedBox(height: 24),
            Center(
              child: Text(
                answered ? '下滑继续下一题 ➡' : '下滑跳过本题 ➡',
                style: const TextStyle(color: Color(0xFFA09080), fontSize: 13),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
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
          CircularProgressIndicator(color: AppColors.primary),
          const SizedBox(height: 16),
          Text(
            'AI 正在生成题目...',
            style: TextStyle(color: AppColors.lightTextMuted, fontSize: 14),
          ),
          if (streamingText.isNotEmpty) ...[
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: RichContent(
                  content: streamingText,
                  style: TextStyle(color: AppColors.lightTextMuted, fontSize: 13, height: 1.5),
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
            child: Text('刷题 · 连续流',
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

/// 轻量翻页手感
class _TikTokPhysics extends PageScrollPhysics {
  const _TikTokPhysics({super.parent});

  @override
  _TikTokPhysics applyTo(ScrollPhysics? ancestor) {
    return _TikTokPhysics(parent: ancestor);
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    return offset * 0.95;
  }

  @override
  double get dragStartDistanceMotionThreshold => 4.0;
}
