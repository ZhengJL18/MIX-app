import 'dart:convert';

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'rich_content.dart';

/// 答案内容块 — 展示判卷结果 + 答案 + 解析 + 系数。
///
/// 注意：这是可嵌入滚动容器的内容块，本身不管理滚动。
/// 选择题：父级传入判卷结果，这里展示对错横幅。
/// 非选择题（历史遗留无选项题）：保留手动"答对/答错"按钮兜底。
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
    final hasOptions = _parseOptions(question['options']).isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 判卷结果（选择题）
        if (hasOptions) ...[
          _ResultBanner(
            answered: selectedOption != null,
            isCorrect: isCorrect,
            selected: selectedOption,
            answer: answer,
          ),
          SizedBox(height: 16),
        ],
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
                  SizedBox(width: 6),
                  Text('参考答案',
                      style: TextStyle(
                        color: AppColors.primary, fontWeight: FontWeight.w600, fontSize: 15,
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
              color: AppColors.lightTextMuted,
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
              Text('出题参考系数：', style: TextStyle(fontSize: 11, color: AppColors.lightTextMuted)),
            ],
          ),
          SizedBox(height: 4),
          Row(
            children: [
              _CoefChip('复杂度', cplx, AppColors.primary),
              SizedBox(width: 6),
              _CoefChip('理解', und, AppColors.secondary),
              SizedBox(width: 6),
              _CoefChip('冗余', red, AppColors.accent),
              SizedBox(width: 6),
              _CoefChip('覆盖', cov, AppColors.lightTextMuted),
            ],
          ),
        ],
      ],
    );
  }

  static List<String> _parseOptions(dynamic raw) {
    if (raw == null) return const [];
    if (raw is List) return raw.map((e) => e.toString()).toList();
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
    } catch (_) {}
    return const [];
  }
}

/// 判卷结果横幅
class _ResultBanner extends StatelessWidget {
  final bool answered;
  final bool isCorrect;
  final String? selected;
  final String answer;

  const _ResultBanner({
    required this.answered,
    required this.isCorrect,
    required this.selected,
    required this.answer,
  });

  @override
  Widget build(BuildContext context) {
    final Color color;
    final IconData icon;
    final String title;
    if (!answered) {
      color = AppColors.lightTextMuted;
      icon = Icons.help_outline;
      title = '未作答';
    } else if (isCorrect) {
      color = AppColors.correct;
      icon = Icons.check_circle;
      title = '回答正确！';
    } else {
      color = AppColors.wrong;
      icon = Icons.cancel;
      title = '回答错误';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              SizedBox(width: 8),
              Text(title,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 15)),
            ],
          ),
          if (answered && !isCorrect) ...[
            SizedBox(height: 6),
            Text('你的答案：$selected',
                style: TextStyle(color: AppColors.lightText, fontSize: 13)),
            SizedBox(height: 2),
            Text('正确答案：$answer',
                style: TextStyle(color: AppColors.lightText, fontSize: 13)),
          ],
          if (answered && isCorrect) ...[
            SizedBox(height: 6),
            Text('你的答案：$selected',
                style: TextStyle(color: AppColors.lightText, fontSize: 13)),
          ],
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
