import 'dart:async';
import 'package:flutter/material.dart';
import '../config/config.dart';
import '../models/message_block.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// 文本气泡 — 流式渲染 + Markdown + 闪烁光标
class StreamingTextBubble extends StatefulWidget {
  final TextBlock block;
  final bool isUser;

  const StreamingTextBubble({super.key, required this.block, this.isUser = false});

  @override
  State<StreamingTextBubble> createState() => _StreamingTextBubbleState();
}

class _StreamingTextBubbleState extends State<StreamingTextBubble>
    with TickerProviderStateMixin {
  late AnimationController _cursorController;
  late Animation<double> _cursorOpacity;
  int _version = 0;

  @override
  void initState() {
    super.initState();
    _cursorController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _cursorOpacity = Tween<double>(begin: 0, end: 1).animate(_cursorController);
  }

  @override
  void dispose() {
    _cursorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF16213E) : const Color(0xFFFEF9EF);
    final userBg = const Color(0xFFFF8C42).withValues(alpha: 0.12);
    final borderColor = isDark ? Colors.white10 : const Color(0xFFE0D8C8);

    return Align(
      alignment: widget.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.88),
        margin: widget.isUser
            ? const EdgeInsets.only(bottom: 8, left: 40)
            : const EdgeInsets.only(bottom: 8, right: 40),
        child: Column(
          crossAxisAlignment: widget.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // 角色标签
            Padding(
              padding: EdgeInsets.only(
                left: widget.isUser ? 0 : 4,
                right: widget.isUser ? 4 : 0,
                bottom: 4,
              ),
              child: Text(
                widget.isUser ? '你' : 'MIX',
                style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white24 : const Color(0xFFB0A090),
                ),
              ),
            ),
            // 气泡
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: widget.block.isError
                    ? Colors.red.withValues(alpha: 0.1)
                    : (widget.isUser ? userBg : bgColor),
                borderRadius: BorderRadius.circular(16).copyWith(
                  bottomRight: widget.isUser ? const Radius.circular(4) : null,
                  bottomLeft: !widget.isUser ? const Radius.circular(4) : null,
                ),
                border: widget.isUser ? null : Border.all(color: borderColor, width: 0.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Markdown 内容
                  if (widget.block.content.isNotEmpty)
                    MarkdownBody(
                      data: widget.block.content,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(
                          fontSize: 15, height: 1.6,
                          color: isDark ? Colors.white : const Color(0xFF3A3A3A),
                        ),
                        h1: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : const Color(0xFF3A3A3A)),
                        h2: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : const Color(0xFF3A3A3A)),
                        h3: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white : const Color(0xFF3A3A3A)),
                        code: TextStyle(
                          fontSize: 13, fontFamily: 'monospace',
                          color: const Color(0xFFFF8C42),
                          backgroundColor: isDark
                              ? Colors.white.withValues(alpha: 0.08)
                              : Colors.black.withValues(alpha: 0.05),
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.black.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        blockquoteDecoration: BoxDecoration(
                          border: Border(left: BorderSide(
                            color: const Color(0xFFFF8C42).withValues(alpha: 0.5), width: 3)),
                        ),
                        strong: TextStyle(fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : const Color(0xFF3A3A3A)),
                      ),
                    ),
                  // 流式光标
                  if (widget.block.isStreaming)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: FadeTransition(
                        opacity: _cursorOpacity,
                        child: Container(
                          width: 8, height: 16,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF8C42),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 由父组件调用，触发刷新
  void refresh() {
    if (mounted) setState(() { _version++; });
  }
}

/// 工具调用卡片 — 三态动画 + 可折叠
class ToolCallCard extends StatefulWidget {
  final ToolCallBlock block;

  const ToolCallCard({super.key, required this.block});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  IconData get _icon {
    if (widget.block.isRunning) return Icons.auto_awesome;
    if (widget.block.isError) return Icons.error_outline;
    return Icons.check_circle_outline;
  }

  Color get _iconColor {
    if (widget.block.isRunning) return const Color(0xFFFF8C42);
    if (widget.block.isError) return Colors.red;
    return Colors.green;
  }

  Color _borderColor(bool isDark) {
    if (widget.block.isRunning) return const Color(0xFFFF8C42).withValues(alpha: 0.3);
    if (widget.block.isError) return Colors.red.withValues(alpha: 0.3);
    return Colors.green.withValues(alpha: 0.3);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF16213E) : const Color(0xFFFEF9EF);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () {
          if (widget.block.resultSummary != null) {
            setState(() => widget.block.toggleExpanded());
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _borderColor(isDark)),
          ),
          child: Row(
            children: [
              // 图标
              widget.block.isRunning
                  ? FadeTransition(
                      opacity: _pulseController,
                      child: Icon(_icon, size: 18, color: _iconColor),
                    )
                  : Icon(_icon, size: 18, color: _iconColor),
              const SizedBox(width: 10),
              // 内容
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.block.toolLabel,
                      style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white70 : const Color(0xFF3A3A3A),
                      ),
                    ),
                    if (widget.block.isRunning)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('执行中...',
                            style: TextStyle(fontSize: 12,
                                color: isDark ? Colors.white38 : const Color(0xFFB0A090))),
                      ),
                    if (widget.block.isSuccess && widget.block.expanded && widget.block.resultSummary != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(widget.block.resultSummary!,
                            style: TextStyle(fontSize: 12,
                                color: isDark ? Colors.white54 : const Color(0xFF8A7A6A))),
                      ),
                    if (widget.block.isError && widget.block.errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(widget.block.errorMessage!,
                            style: const TextStyle(fontSize: 12, color: Colors.red)),
                      ),
                  ],
                ),
              ),
              if (widget.block.resultSummary != null && !widget.block.isRunning)
                Icon(
                  widget.block.expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16, color: isDark ? Colors.white38 : const Color(0xFFB0A090),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 状态信息条
class StatusBar extends StatefulWidget {
  final StatusBlock block;

  const StatusBar({super.key, required this.block});

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 500),
    );
    if (widget.block.autoDismiss) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          _fadeController.forward().then((_) {
            if (mounted) setState(() => _visible = false);
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return FadeTransition(
      opacity: 1.0 - _fadeController.value,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Icon(
              widget.block.isWarning ? Icons.warning_amber : Icons.info_outline,
              size: 14,
              color: widget.block.isWarning
                  ? Colors.orange
                  : (isDark ? Colors.white38 : const Color(0xFFB0A090)),
            ),
            const SizedBox(width: 8),
            Text(
              widget.block.text,
              style: TextStyle(
                fontSize: 13,
                color: widget.block.isWarning
                    ? Colors.orange
                    : (isDark ? Colors.white38 : const Color(0xFFB0A090)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
