import 'package:flutter/material.dart';
import '../theme/app_palette.dart';
import 'rich_content.dart';

/// 答案内容块 — 展示参考答案 + 解析 + 系数。
///
/// 注意：这是可嵌入滚动容器的内容块，本身不管理滚动。
/// 按用户要求不标注"回答正确/错误"，只展示正确答案与解析。
class AnswerCard extends StatelessWidget {
  final Map<String, dynamic> question;
  final String? selectedOption;
  final bool isCorrect;

  const AnswerCard({
    super.key,
    required this.question,
    this.selectedOption,
    required this.isCorrect,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final answer = question['answer'] as String? ?? '';
    final explanation = question['explanation'] as String? ?? '';
    final cplx = question['cplx_coef'];
    final und = question['und_coef'];
    final red = question['red_coef'];
    final cov = question['cov_coef'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 参考答案
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.appPalette.primaryLight,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.appPalette.primary.withValues(alpha: 0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lightbulb_outline, color: context.appPalette.primary, size: 18),
                  SizedBox(width: 6),
                  Text('参考答案',
                      style: TextStyle(
                        color: context.appPalette.primary, fontWeight: FontWeight.w600, fontSize: 15,
                      )),
                ],
              ),
              const SizedBox(height: 8),
              RichContent(
                content: answer,
                style: t.bodyLarge?.copyWith(height: 1.6),
              ),
            ],
          ),
        ),
        // 解析
        if (explanation.isNotEmpty) ...[
          SizedBox(height: 16),
          Text('解析', style: t.titleMedium?.copyWith(fontSize: 15)),
          SizedBox(height: 6),
          RichContent(
            content: explanation,
            style: TextStyle(
              color: context.appPalette.textMuted,
              height: 1.5,
              fontSize: 14,
            ),
          ),
        ],
        // 四维系数
        if (cplx != null || und != null || red != null || cov != null) ...[
          SizedBox(height: 12),
          Row(
            children: [
              Text('出题参考系数：', style: TextStyle(fontSize: 11, color: context.appPalette.textMuted)),
            ],
          ),
          SizedBox(height: 4),
          Row(
            children: [
              _CoefChip('复杂度', cplx, context.appPalette.primary),
              SizedBox(width: 6),
              _CoefChip('理解', und, context.appPalette.secondary),
              SizedBox(width: 6),
              _CoefChip('冗余', red, context.appPalette.accent),
              SizedBox(width: 6),
              _CoefChip('覆盖', cov, context.appPalette.textMuted),
            ],
          ),
        ],
      ],
    );
  }
}

class _CoefChip extends StatelessWidget {
  final String label;
  final dynamic value;
  final Color color;

  const _CoefChip(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    if (value == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text('$label ${value.toStringAsFixed(2)}',
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500)),
    );
  }
}
