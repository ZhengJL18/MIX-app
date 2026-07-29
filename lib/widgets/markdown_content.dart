import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

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
    this.textColor = Colors.white,
    this.codeColor = const Color(0xFFFF8C42),
    this.fontSize = 17,
  });

  final String content;
  final Color textColor;
  final Color codeColor;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Markdown(
      data: content,
      selectable: true, // 允许用户选中复制
      styleSheet: MarkdownStyleSheet(
        h1: TextStyle(fontSize: fontSize + 4, fontWeight: FontWeight.bold, color: textColor),
        h2: TextStyle(fontSize: fontSize + 2, fontWeight: FontWeight.bold, color: textColor),
        h3: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600, color: textColor),
        p: TextStyle(fontSize: fontSize, height: 1.6, color: textColor),
        listBullet: TextStyle(fontSize: fontSize, color: codeColor),
        code: TextStyle(
          fontSize: fontSize - 2,
          color: codeColor,
          backgroundColor: Colors.white.withValues(alpha: 0.05),
        ),
        codeblockDecoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        strong: TextStyle(fontWeight: FontWeight.bold, color: textColor),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: codeColor.withValues(alpha: 0.5), width: 3)),
          color: Colors.white.withValues(alpha: 0.03),
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: Colors.white12)),
        ),
      ),
      // 自定义内联代码高亮（公式用 \$...\$ 包裹后走 code 样式）
      inlineSyntaxes: [
        // 让 \(\和\) 和 $$...$$ 也被识别为内联代码块
        md.InlineCodeSyntax(),
      ],
    );
  }
}
