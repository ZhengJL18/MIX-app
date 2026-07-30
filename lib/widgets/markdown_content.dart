import 'package:flutter/material.dart';

/// Markdown 块级类型
enum _BlockType { text, h1, h2, h3, code, math, quote, bullet, ordered, hr }

/// Markdown 块
class _Block {
  final _BlockType type;
  final String content;
  final int indent;
  _Block(this.type, this.content, [this.indent = 0]);
}

/// MIX Markdown 渲染管线 — 手写解析，不依赖 flutter_markdown。
///
/// 支持：
/// - ### 标题 (h1/h2/h3)
/// - **加粗**、*斜体*
/// - `行内代码`、```代码块```
/// - $$ 块级公式 $$、$ 行内公式$
/// - - 无序列表、1. 有序列表
/// - 引用块 >
/// - --- 分割线
///
/// 为什么不直接用 flutter_markdown？
/// 1. 体积大，拖慢冷启动
/// 2. 不支持我们需要的流式增量渲染
/// 3. 公式渲染需要额外引入包
class MarkdownContent extends StatelessWidget {
  const MarkdownContent({
    super.key,
    required this.content,
    this.textColor,
    this.fontSize = 16,
    this.codeColor = const Color(0xFFFF8C42),
  });

  final String content;
  final Color? textColor;
  final double fontSize;
  final Color codeColor;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final defaultText = isDark ? Colors.white : const Color(0xFF3A3A3A);
    final effectiveText = textColor ?? defaultText;
    final bg = isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5ECD7);

    final blocks = _parseBlocks(content);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks.map((block) => _buildBlock(block, effectiveText, codeColor, fontSize, bg, isDark)).toList(),
    );
  }

  // ── 块级解析 ──

  List<_Block> _parseBlocks(String md) {
    final blocks = <_Block>[];
    final lines = md.split('\n');
    String? codeAccum;

    for (final raw in lines) {
      // 代码块
      if (raw.trimLeft().startsWith('```')) {
        if (codeAccum != null) {
          blocks.add(_Block(_BlockType.code, codeAccum.trim()));
          codeAccum = null;
        } else {
          codeAccum = '';
        }
        continue;
      }
      if (codeAccum != null) {
        codeAccum += raw + '\n';
        continue;
      }

      final line = raw.trimLeft();

      // 分割线
      if (RegExp(r'^-{3,}$').hasMatch(line)) {
        blocks.add(_Block(_BlockType.hr, ''));
        continue;
      }

      // 标题
      if (line.startsWith('### ')) { blocks.add(_Block(_BlockType.h3, line.substring(4))); continue; }
      if (line.startsWith('## ')) { blocks.add(_Block(_BlockType.h2, line.substring(3))); continue; }
      if (line.startsWith('# ')) { blocks.add(_Block(_BlockType.h1, line.substring(2))); continue; }

      // 引用
      if (line.startsWith('> ')) { blocks.add(_Block(_BlockType.quote, line.substring(2))); continue; }

      // 列表
      if (RegExp(r'^-\s').hasMatch(line)) { blocks.add(_Block(_BlockType.bullet, line.substring(2).trimLeft())); continue; }
      if (RegExp(r'^\d+[.)]\s').hasMatch(line)) { blocks.add(_Block(_BlockType.ordered, line.replaceFirst(RegExp(r'^\d+[.)]\s'), ''))); continue; }

      // 空行
      if (line.isEmpty) continue;

      blocks.add(_Block(_BlockType.text, line));
    }

    if (codeAccum != null) {
      blocks.add(_Block(_BlockType.code, codeAccum.trim()));
    }

    return blocks;
  }

  // ── 行内解析 → InlineSpan ──

  List<InlineSpan> _parseInline(String text, Color textColor, Color codeColor, double fontSize) {
    // 解析顺序：公式(双$) > 代码 > 加粗 > 公式(单$) > 斜体 > 普通文本
    final spans = <InlineSpan>[];
    int i = 0;
    String buf = '';

    void flush() {
      if (buf.isNotEmpty) {
        spans.add(TextSpan(text: buf));
        buf = '';
      }
    }

    while (i < text.length) {
      // 块级公式 $$
      if (text.startsWith('\$\$', i)) {
        final end = text.indexOf('\$\$', i + 2);
        flush();
        if (end != -1) {
          final formula = text.substring(i + 2, end);
          spans.add(WidgetSpan(child: _FormulaChip(formula, codeColor)));
          i = end + 2;
          continue;
        }
      }

      // 行内公式 $
      if (text[i] == '\$' && i + 1 < text.length && text[i + 1] != '\$') {
        final end = text.indexOf('\$', i + 1);
        if (end != -1 && (end == text.length - 1 || text[end + 1] != '\$')) {
          flush();
          spans.add(WidgetSpan(child: _FormulaChip(text.substring(i + 1, end), codeColor)));
          i = end + 1;
          continue;
        }
      }

      // 代码 `
      if (text[i] == '`') {
        final end = text.indexOf('`', i + 1);
        if (end != -1) {
          flush();
          spans.add(WidgetSpan(child: _InlineCode(text.substring(i + 1, end), codeColor)));
          i = end + 1;
          continue;
        }
      }

      // 加粗 **
      if (i + 1 < text.length && text[i] == '*' && text[i + 1] == '*') {
        final end = text.indexOf('**', i + 2);
        if (end != -1) {
          flush();
          spans.add(TextSpan(text: text.substring(i + 2, end), style: TextStyle(fontWeight: FontWeight.bold)));
          i = end + 2;
          continue;
        }
      }

      // 斜体 *
      if (text[i] == '*' && (i == 0 || text[i - 1] != '*')) {
        final end = text.indexOf('*', i + 1);
        if (end != -1 && text[end + 1] != '*') {
          flush();
          spans.add(TextSpan(text: text.substring(i + 1, end), style: TextStyle(fontStyle: FontStyle.italic)));
          i = end + 1;
          continue;
        }
      }

      buf += text[i];
      i++;
    }
    flush();
    return spans;
  }

  // ── 块级渲染 ──

  Widget _buildBlock(_Block block, Color textColor, Color codeColor, double fontSize, Color bg, bool isDark) {
    final padding = EdgeInsets.only(bottom: _blockSpacing(block.type));

    switch (block.type) {
      case _BlockType.h1:
        return Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: SelectableText(block.content, style: TextStyle(fontSize: fontSize + 6, fontWeight: FontWeight.bold, color: textColor)),
        );
      case _BlockType.h2:
        return Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 6),
          child: SelectableText(block.content, style: TextStyle(fontSize: fontSize + 3, fontWeight: FontWeight.bold, color: textColor)),
        );
      case _BlockType.h3:
        return Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: SelectableText(block.content, style: TextStyle(fontSize: fontSize + 1, fontWeight: FontWeight.w600, color: textColor)),
        );
      case _BlockType.code:
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFD8D0C0)),
            ),
            child: SelectableText(block.content, style: TextStyle(
              fontFamily: 'monospace', fontSize: fontSize - 2, height: 1.5,
              color: codeColor,
            )),
          ),
        );
      case _BlockType.math:
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F3460).withValues(alpha: 0.3) : const Color(0xFFFFF3E0).withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(block.content, style: TextStyle(fontSize: fontSize, fontFamily: 'monospace', color: codeColor, height: 1.4)),
          ),
        );
      case _BlockType.quote:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 12),
          child: Container(
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: codeColor.withValues(alpha: 0.5), width: 3)),
            ),
            child: _buildInline(block.content, textColor.withValues(alpha: 0.85), codeColor, fontSize),
          ),
        );
      case _BlockType.bullet:
        return Padding(
          padding: EdgeInsets.only(bottom: 4, left: 8 + block.indent * 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('• ', style: TextStyle(color: codeColor, fontSize: fontSize)),
              Expanded(child: _buildInline(block.content, textColor, codeColor, fontSize)),
            ],
          ),
        );
      case _BlockType.ordered:
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 24, child: Text('•', style: TextStyle(color: codeColor, fontSize: fontSize * 0.8))),
              Expanded(child: _buildInline(block.content, textColor, codeColor, fontSize)),
            ],
          ),
        );
      case _BlockType.hr:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Divider(color: isDark ? Colors.white12 : const Color(0xFFD8D0C0)),
        );
      case _BlockType.text:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _buildInline(block.content, textColor, codeColor, fontSize),
        );
    }
  }

  Widget _buildInline(String text, Color textColor, Color codeColor, double fontSize) {
    return SelectableText.rich(
      TextSpan(
        style: TextStyle(fontSize: fontSize, height: 1.6, color: textColor),
        children: _parseInline(text, textColor, codeColor, fontSize),
      ),
    );
  }

  double _blockSpacing(_BlockType t) {
    switch (t) {
      case _BlockType.h1: return 12;
      case _BlockType.h2: return 10;
      case _BlockType.h3: return 8;
      case _BlockType.hr: return 4;
      default: return 0;
    }
  }
}

/// 公式小标签
class _FormulaChip extends StatelessWidget {
  final String formula;
  final Color color;
  const _FormulaChip(this.formula, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text('\$$formula\$', style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: color)),
    );
  }
}

/// 行内代码标签
class _InlineCode extends StatelessWidget {
  final String code;
  final Color color;
  const _InlineCode(this.code, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(code, style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: color)),
    );
  }
}
