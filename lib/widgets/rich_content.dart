import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import '../theme/app_colors.dart';

/// 富文本渲染 — 支持 Markdown 文本 + LaTeX 公式。
///
/// 识别四种常见公式分隔符并交替渲染普通文本与公式段：
/// - `$$...$$` 块级公式（display mode）
/// - `\[ ... \]` 块级公式（display mode）
/// - `$...$` 行内公式
/// - `\( ... \)` 行内公式
///
/// 公式解析失败时用 [errorBuilder] 回退显示原始 LaTeX，避免整段布局崩溃。
class RichContent extends StatelessWidget {
  final String content;
  final TextStyle? style;
  final TextAlign? textAlign;

  const RichContent({
    super.key,
    required this.content,
    this.style,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    if (content.isEmpty) return const SizedBox.shrink();

    final segments = _splitByFormula(content);
    if (segments.isEmpty || segments.every((s) => !s.isFormula)) {
      // 没有公式，纯文本
      return Text(
        content,
        style: style,
        textAlign: textAlign,
      );
    }

    return Text.rich(
      TextSpan(
        children: segments.map((seg) {
          if (!seg.isFormula) {
            return TextSpan(text: seg.text);
          }
          return WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: _SafeMath(
                tex: seg.text,
                displayMode: seg.displayMode,
                style: style,
              ),
            ),
          );
        }).toList(),
      ),
      style: style,
      textAlign: textAlign,
    );
  }

  /// 按公式分隔符拆分内容，返回文本段与公式段交替的列表。
  ///
  /// 匹配优先级：`$$...$$` / `\[...\]` / `$...$` / `\(...\)`。
  /// 未被识别为公式的 `$`（如货币符号、孤立半括号）原样保留在文本段。
  /// 另外：不含分隔符的裸 LaTeX（如 `\frac{1}{2}`）也会被识别为公式。
  List<_Segment> _splitByFormula(String src) {
    final result = <_Segment>[];
    final regex = RegExp(
      r'\$\$(.+?)\$\$|\\\[(.+?)\\\]|\$(.+?)\$|\\\((.+?)\\\)',
      dotAll: true,
    );
    var last = 0;

    void addText(String text) {
      final trimmed = text.trim();
      // 裸 LaTeX 特征检测：整段是单个强数学命令表达式时按公式渲染
      if (_looksLikeBareLatex(trimmed)) {
        result.add(_Segment(trimmed, true, false));
      } else {
        result.add(_Segment(text, false, false));
      }
    }

    for (final m in regex.allMatches(src)) {
      if (m.start > last) {
        addText(src.substring(last, m.start));
      }
      // 按分组判断是哪种分隔符
      if (m.group(1) != null) {
        result.add(_Segment(m.group(1)!, true, true)); // $$
      } else if (m.group(2) != null) {
        result.add(_Segment(m.group(2)!, true, true)); // \[ \]
      } else if (m.group(3) != null) {
        result.add(_Segment(m.group(3)!, true, false)); // $
      } else if (m.group(4) != null) {
        result.add(_Segment(m.group(4)!, true, false)); // \( \)
      }
      last = m.end;
    }
    if (last < src.length) {
      addText(src.substring(last));
    }
    if (result.isEmpty) {
      return [_Segment(src, false, false)];
    }
    return result;
  }

  /// 判断一段文本是否是"裸 LaTeX"（无 $ 分隔符，但明显是数学公式）。
  ///
  /// 保守策略：
  /// - 只命中强数学命令（\frac、\sqrt、\int、\sum 等）
  /// - 段内不含中文（避免"解：\frac{...}"这类中英混排被整体当公式）
  /// - 长度有上限（避免整段长文被误判）
  bool _looksLikeBareLatex(String text) {
    if (text.isEmpty || text.length > 120) return false;
    // 含中文 → 不当作纯公式
    if (RegExp(r'[一-鿿]').hasMatch(text)) return false;
    // 强数学命令：有这些基本可以断定是 LaTeX 公式
    if (RegExp(r'\\(?:frac|dfrac|sqrt|int|sum|prod|lim|infty|pi|alpha|beta|gamma|delta|theta|lambda|mu|sigma|omega|times|div|cdot|pm|leq|geq|neq|approx|to|rightarrow|left|right|begin|partial|log|ln|sin|cos|tan)').hasMatch(text)) {
      return true;
    }
    return false;
  }
}

/// 公式渲染的兜底封装 — 解析失败时显示原始 LaTeX，不让布局崩。
class _SafeMath extends StatelessWidget {
  final String tex;
  final bool displayMode;
  final TextStyle? style;

  const _SafeMath({
    required this.tex,
    required this.displayMode,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    final mathStyle = style?.copyWith(
          color: AppColors.primary,
          fontWeight: FontWeight.w600,
        ) ??
        const TextStyle(
          color: AppColors.primary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        );

    try {
      return Math.tex(
        tex,
        mathStyle: displayMode ? MathStyle.display : MathStyle.text,
        textStyle: mathStyle,
        // 解析失败回退显示原始公式，保证内容可见、布局不崩
        onErrorFallback: (_) => Text(
          tex,
          style: mathStyle,
          textAlign: TextAlign.center,
        ),
      );
    } catch (_) {
      // 极少数情况下 Math.tex 构造即抛错，直接回退原文
      return Text(tex, style: mathStyle);
    }
  }
}

class _Segment {
  final String text;
  final bool isFormula;
  final bool displayMode;
  _Segment(this.text, this.isFormula, this.displayMode);
}
