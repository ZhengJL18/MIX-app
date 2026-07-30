import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../widgets/error_cause_dialog.dart';
import '../widgets/markdown_content.dart';
import 'stats_screen.dart';
import 'subject_management_screen.dart';

/// 刷题页 — 嵌入 PageView 中
///
/// 流程：看题思考 → 点"提交" → 显示答案+解析 → 自评"我答对了/我答错了" → 错因(如错)
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key});

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen> {
  bool _showAnswer = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<AppState>();
      if (state.currentQuestion == null) {
        state.loadNextQuestion();
      }
    });
  }

  Color _textMain(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? Colors.white : const Color(0xFF3A3A3A);
  Color _textMuted(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? Colors.white54 : const Color(0xFF8A7A6A);
  Color _textDim(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? Colors.white24 : const Color(0xFFC0B8A8);
  Color _surface(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? const Color(0xFF16213E) : const Color(0xFFFEF9EF);
  Color _bg(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? const Color(0xFF1A1A2E) : const Color(0xFFF5ECD7);
  Color _cardBg(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? const Color(0xFF0F3460) : const Color(0xFFF0E8D8);
  Color _divider(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? Colors.white12 : const Color(0xFFD8D0C0);
  Color _iconMuted(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? Colors.white38 : const Color(0xFFB0A090);

  /// 用户自评：答对 or 答错
  Future<void> _selfRate(BuildContext context, bool correct) async {
    final appState = context.read<AppState>();
    String? mainCause;
    String? minorCause;

    if (!correct) {
      final result = await showDialog<ErrorCauseResult>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const ErrorCauseDialog(),
      );
      if (result == null) return;
      mainCause = result.mainCause;
      minorCause = result.minorCause;
    }

    await appState.submitAnswer(
        correct: correct, mainCause: mainCause, minorCause: minorCause);
    setState(() => _showAnswer = false);
    await appState.loadNextQuestion();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final question = appState.currentQuestion;

        if (appState.loadingNext && question == null) {
          return Center(
              child: CircularProgressIndicator(color: const Color(0xFFFF8C42)));
        }
        if (appState.lastError != null) {
          return _ErrorView(
            message: appState.lastError!,
            retrying: _retrying,
            onRetry: () {
              _retrying = true;
              appState.loadNextQuestion().whenComplete(() {
                if (mounted) setState(() => _retrying = false);
              });
            },
          );
        }
        if (question == null) {
          return Center(
              child: Text('暂无题目',
                  style: TextStyle(color: _textMuted(context), fontSize: 16)));
        }

        return Container(
          color: _bg(context),
          child: Column(
            children: [
              _buildHeader(appState),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarkdownContent(
                        content: question['content'] as String? ?? '',
                        textColor: _textMain(context),
                        fontSize: 17,
                      ),
                      if (_showAnswer) ...[
                        const SizedBox(height: 24),
                        Divider(color: _divider(context)),
                        const SizedBox(height: 12),
                        const Text('参考答案',
                            style: TextStyle(
                                color: Color(0xFFFF8C42),
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: _cardBg(context),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: MarkdownContent(
                            content: question['answer'] as String? ?? '',
                            textColor: _textMain(context),
                            fontSize: 16,
                          ),
                        ),
                        if (question['cplx_coef'] != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            '复杂度${_fmt(question['cplx_coef'])} · '
                            '理解${_fmt(question['und_coef'])} · '
                            '冗余${_fmt(question['red_coef'])} · '
                            '覆盖率${_fmt(question['cov_coef'])}',
                            style: TextStyle(
                                color: _textDim(context), fontSize: 12),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              _buildBottomBar(appState),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(AppState appState) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: _surface(context),
      child: Row(
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFF8C42).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text('刷题模式',
                style: TextStyle(color: Color(0xFFFF8C42), fontSize: 14)),
          ),
          const Spacer(),
          Text('第 ${appState.questionIndex} 题',
              style: TextStyle(color: _textMuted(context), fontSize: 14)),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_horiz,
                color: _iconMuted(context), size: 20),
            color: _surface(context),
            onSelected: (value) {
              if (value == 'stats') {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const StatsScreen(),
                ));
              } else if (value == 'subjects') {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SubjectManagementScreen(),
                ));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'subjects', child: Text('科目管理')),
              PopupMenuItem(value: 'stats', child: Text('学习统计')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(AppState appState) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        children: [
          if (!_showAnswer)
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF8C42),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => setState(() => _showAnswer = true),
                child: const Text('提交 / 看答案',
                    style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFFFF6B6B)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: appState.loadingNext
                          ? null
                          : () => _selfRate(context, false),
                      child: const Text('我答错了',
                          style: TextStyle(
                              color: Color(0xFFFF6B6B), fontSize: 16)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4ECDC4),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: appState.loadingNext
                          ? null
                          : () => _selfRate(context, true),
                      child: const Text('我答对了',
                          style: TextStyle(color: Colors.white, fontSize: 16)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _fmt(dynamic v) {
    if (v == null) return '-';
    return (v as num).toStringAsFixed(2);
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry, required this.retrying});
  final String message;
  final VoidCallback onRetry;
  final bool retrying;

  bool get _noSubject => message.contains('没有科目') || message.contains('科目管理') || message.contains('创建');

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white70 : const Color(0xFF5A5A5A);
    final iconColor = isDark ? Colors.white24 : const Color(0xFFB0A090);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline, size: 48, color: iconColor),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: textColor)),
            const SizedBox(height: 16),
            if (_noSubject)
              ElevatedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('去科目管理创建'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF8C42),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SubjectManagementScreen()),
                  );
                },
              )
            else
              OutlinedButton(
                onPressed: retrying ? null : onRetry,
                child: Text(retrying ? '加载中...' : '重试'),
              ),
          ],
        ),
      ),
    );
  }
}
