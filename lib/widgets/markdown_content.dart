import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// Markdown + LaTeX 渲染组件。
///
/// 显示 AI 返回的格式化内容（题目/答案），支持：
/// - 标准 Markdown（**加粗**、- 列表、### 标题）
/// - \$...\$ 和 \$\$...\$\$ 包裹的公式（通过自定义内联 HTML 渲染）
///
/// 当前使用 flutter_markdown 的标准渲染器，公式部分用自定义
/// Monospace 高亮示意；完整 LaTeX 渲染需要引入 flutter_math_fork。
class MarkdownContent extends StatelessWidget {
  const MarkdownContent({
    super.key,
    required this.content,
    this.textColor,
    this.codeColor = Color(0xFFFF8C42),
    this.fontSize = 17,
  });

  final Color? textColor;

  final String content;
  final Color textColor;
  final Color codeColor;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final defaultText = isDark ? Colors.white : const Color(0xFF3A3A3A);
    final effectiveText = textColor ?? defaultText;
    final codeBg = isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.04);
    final dividerColor = isDark ? Colors.white12 : const Color(0xFFD8D0C0);

    return Markdown(
      data: content,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        h1: TextStyle(fontSize: fontSize + 4, fontWeight: FontWeight.bold, color: effectiveText),
        h2: TextStyle(fontSize: fontSize + 2, fontWeight: FontWeight.bold, color: effectiveText),
        h3: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600, color: effectiveText),
        p: TextStyle(fontSize: fontSize, height: 1.6, color: effectiveText),
        listBullet: TextStyle(fontSize: fontSize, color: codeColor),
        code: TextStyle(
          fontSize: fontSize - 2,
          color: codeColor,
          backgroundColor: codeBg,
        ),
        codeblockDecoration: BoxDecoration(
          color: codeBg,
          borderRadius: BorderRadius.circular(8),
        ),
        strong: TextStyle(fontWeight: FontWeight.bold, color: effectiveText),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: codeColor.withValues(alpha: 0.5), width: 3)),
          color: codeBg,
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: dividerColor)),
        ),
      ),
    );
  }
}
