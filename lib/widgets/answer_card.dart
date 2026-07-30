import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// 答案卡片 — 显示答案 + 解析 + 答对/答错按钮
class AnswerCard extends StatelessWidget {
  final Map<String, dynamic> question;
  final VoidCallback onCorrect;
  final VoidCallback onWrong;

  const AnswerCard({
    super.key,
    required this.question,
    required this.onCorrect,
    required this.onWrong,
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

    return Container(
      color: AppColors.lightBg,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 参考答案
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.lightbulb_outline, color: AppColors.primary, size: 18),
                    const SizedBox(width: 6),
                    Text('参考答案', style: TextStyle(
                      color: AppColors.primary, fontWeight: FontWeight.w600, fontSize: 15,
                    )),
                  ],
                ),
                const SizedBox(height: 8),
                Text(answer, style: t.bodyLarge?.copyWith(height: 1.6)),
              ],
            ),
          ),
          // 解析
          if (explanation.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('解析', style: t.titleMedium?.copyWith(fontSize: 15)),
            const SizedBox(height: 6),
            Text(explanation, style: TextStyle(
              color: AppColors.lightTextMuted, height: 1.5, fontSize: 14,
            )),
          ],
          // 四维系数
          if (cplx != null || und != null || red != null || cov != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _CoefChip('复杂度', cplx, AppColors.primary),
                const SizedBox(width: 6),
                _CoefChip('理解', und, AppColors.secondary),
                const SizedBox(width: 6),
                _CoefChip('冗余', red, AppColors.accent),
                const SizedBox(width: 6),
                _CoefChip('覆盖', cov, AppColors.lightTextMuted),
              ],
            ),
          ],
          const Spacer(),
          // 对错按钮
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: onCorrect,
                    icon: const Icon(Icons.check, size: 20),
                    label: const Text('答对了', style: TextStyle(fontSize: 16)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.correct,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: onWrong,
                    icon: const Icon(Icons.close, size: 20),
                    label: const Text('答错了', style: TextStyle(fontSize: 16)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.wrong,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
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
