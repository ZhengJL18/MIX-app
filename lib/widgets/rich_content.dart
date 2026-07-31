import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import '../theme/app_colors.dart';

/// 富文本渲染 — 支持 Markdown 文本 + LaTeX 公式（$...$ 或 $$...$$）
///
/// 把内容按 `$...$` 拆分成普通文本段和公式段交替渲染。
/// 题目/答案/解析里的 `\frac`、`\sum` 等 LaTeX 会被正确渲染。
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
    if (segments.length == 1) {
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
          if (seg.isFormula) {
            return WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Math.tex(
                  seg.text,
                  textStyle: style?.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ) ?? const TextStyle(
                    color: AppColors.primary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
          }
          return TextSpan(text: seg.text);
        }).toList(),
      ),
      style: style,
      textAlign: textAlign,
    );
  }

  /// 按 `$...$`（或 `$$...$$`）拆分出公式段
  List<_Segment> _splitByFormula(String src) {
    final result = <_Segment>[];
    final regex = RegExp(r'\$\$(.+?)\$\$|\$(.+?)\$', dotAll: true);
    var last = 0;

    for (final m in regex.allMatches(src)) {
      if (m.start > last) {
        result.add(_Segment(src.substring(last, m.start), false));
      }
      final formula = m.group(1) ?? m.group(2) ?? '';
      result.add(_Segment(formula, true));
      last = m.end;
    }
    if (last < src.length) {
      result.add(_Segment(src.substring(last), false));
    }
    if (result.isEmpty) result.add(_Segment(src, false));
    return result;
  }
}

class _Segment {
  final String text;
  final bool isFormula;
  _Segment(this.text, this.isFormula);
}
