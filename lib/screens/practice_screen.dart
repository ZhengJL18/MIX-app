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

        // 连续流：每道题 3 个阶段页（题目 → 趣味评价 → 答案解析），
        // 全部连成一条 PageView。下滑从题目自然翻到答案，再翻到下一题题目。
        // 每题 3 页：questionIndex * 3 + 0(题目) / +1(趣味) / +2(答案)
        final totalPages = questions.length * 3;

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
                  itemCount: totalPages,
                  // 预渲染相邻页（前3后5缓存），滑动不卡顿
                  allowImplicitScrolling: true,
                  itemBuilder: (context, page) {
                    final qIdx = page ~/ 3;
                    final phase = page % 3;
                    final q = qIdx < questions.length ? questions[qIdx] : null;
                    if (q == null) return const SizedBox.shrink();

                    final state = _state(qIdx);
                    final answered = state != _AnswerState.unanswered;

                    final Widget content;
                    switch (phase) {
                      case 0: // 题目页
                        content = _FullPage(
                          child: QuestionCard(
                            question: q,
                            selectedOption: _selectedOptions[qIdx],
                            onOptionSelected: (opt) => _onOptionSelected(qIdx, opt),
                            compact: true,
                          ),
                        );
                      case 1: // 趣味评价页
                        content = _FullPage(
                          child: FunResultCard(
                            type: state == _AnswerState.correct
                                ? FunResultType.correct
                                : state == _AnswerState.wrong
                                    ? FunResultType.wrong
                                    : FunResultType.skip,
                          ),
                        );
                      case 2: // 答案+解析页（未作答显示趣味评价替代）
                      default:
                        if (!answered) {
                          // 未作答：滑过趣味页直接到下一题题目（不展示答案）
                          content = _FullPage(
                            child: Center(
                              child: Text(
                                '还没做题呢，下滑跳过本题 ➡',
                                style: TextStyle(color: AppColors.lightTextMuted, fontSize: 14),
                              ),
                            ),
                          );
                        } else {
                          content = _FullPage(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AnswerCard(
                                  question: q,
                                  selectedOption: _selectedOptions[qIdx],
                                  isCorrect: state == _AnswerState.correct,
                                ),
                                if (state == _AnswerState.wrong && _hasOptions(q['options'])) ...[
                                  const SizedBox(height: 8),
                                  FeedbackCard(
                                    mainCause: _mainCauses[qIdx],
                                    minorCause: _minorCauses[qIdx],
                                    onMainCauseChanged: (c) => setState(() => _mainCauses[qIdx] = c),
                                    onMinorCauseChanged: (c) => setState(() => _minorCauses[qIdx] = c),
                                  ),
                                ],
                              ],
                            ),
                          );
                        }
                    }

                    // 作答状态/选中选项变化 → key 变 → 强制重建该页。
                    // 否则 allowImplicitScrolling 预渲染的页面保持"未作答"旧版本，
                    // 滑到时显示的趣味评价/答案与当前作答不符。
                    return KeyedSubtree(
                      key: ValueKey('p$page-$state-${_selectedOptions[qIdx]}'),
                      child: content,
                    );
                  },
                  onPageChanged: (page) {
                    final qIdx = page ~/ 3;
                    // 切题：移动游标，触发后台预生成下一批
                    appState.moveCursor(qIdx);
                    // 离开一题的答案页（phase 2）进入下一题 → 提交该题
                    if (page % 3 == 0 && page > 0) {
                      final prevIdx = page ~/ 3 - 1;
                      if (_state(prevIdx) != _AnswerState.unanswered) {
                        _submit(prevIdx);
                      }
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

/// 一页容器 — 内容可溢出，但页内手势滚动禁用（避免跟 PageView 翻页抢手势）。
///
/// 手指滑动统一交给外层垂直 PageView 翻页（默认行为）；
/// 内容超出屏幕时右侧出现滚动条，长内容只能拖动滚动条查看。
class _FullPage extends StatefulWidget {
  final Widget child;
  const _FullPage({required this.child});

  @override
  State<_FullPage> createState() => _FullPageState();
}

class _FullPageState extends State<_FullPage> {
  final ScrollController _ctrl = ScrollController();
  bool _scrollable = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_checkScrollable);
  }

  void _checkScrollable() {
    if (!_ctrl.hasClients) return;
    final canScroll = _ctrl.position.maxScrollExtent > 0;
    if (canScroll != _scrollable) setState(() => _scrollable = canScroll);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_checkScrollable);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.lightBg,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) {
          final canScroll = n.metrics.maxScrollExtent > 0;
          if (canScroll != _scrollable) setState(() => _scrollable = canScroll);
          return false;
        },
        child: RawScrollbar(
          controller: _ctrl,
          // 内容超高才显示滚动条；拖动滚动条是页内唯一滚动方式
          thumbVisibility: _scrollable,
          interactive: true,
          child: SingleChildScrollView(
            controller: _ctrl,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            child: widget.child,
          ),
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
