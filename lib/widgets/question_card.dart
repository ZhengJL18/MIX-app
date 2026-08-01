import 'dart:convert';

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'rich_content.dart';

/// 题目卡片 — 展示题干 + 选择题选项单选。
///
/// 选项选中状态由父级（PracticeScreen）持有，这里只渲染并回调，
/// 父级根据所选选项与正确答案比对完成自动判卷。
class QuestionCard extends StatelessWidget {
  final Map<String, dynamic> question;
  final String? selectedOption;
  final ValueChanged<String?> onOptionSelected;

  const QuestionCard({
    super.key,
    required this.question,
    this.selectedOption,
    required this.onOptionSelected,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final options = _parseOptions(question['options']);

    return Container(
      color: AppColors.lightBg,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '单选题',
                  style: TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // 题干
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichContent(
                    content: question['content'] as String? ?? '',
                    style: t.bodyLarge?.copyWith(fontSize: 18, height: 1.7),
                  ),
                  SizedBox(height: 24),
                  // 选项
                  if (options.isNotEmpty) ...[
                    Text('请选择答案', style: TextStyle(color: AppColors.lightTextMuted, fontSize: 13)),
                    const SizedBox(height: 12),
                    for (var i = 0; i < options.length; i++)
                      _OptionButton(
                        label: String.fromCharCode('A'.codeUnitAt(0) + i),
                        option: options[i],
                        selected: selectedOption == options[i],
                        onTap: () => onOptionSelected(
                          selectedOption == options[i] ? null : options[i],
                        ),
                      ),
                  ] else ...[
                    Text(
                      '（该题暂无选项，下滑查看答案后继续下一题）',
                      style: TextStyle(color: AppColors.lightTextMuted, fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 从数据库 options 字段（JSON 数组字符串）解析选项列表。
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

/// 单个选项按钮
class _OptionButton extends StatelessWidget {
  final String label;
  final String option;
  final bool selected;
  final VoidCallback onTap;

  const _OptionButton({
    required this.label,
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.primaryLight : AppColors.lightSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.lightDivider,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? AppColors.primary : Colors.transparent,
                  border: Border.all(
                    color: selected ? AppColors.primary : AppColors.lightTextMuted,
                    width: 2,
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: selected ? Colors.white : AppColors.lightTextMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: RichContent(
                  content: option,
                  style: TextStyle(color: AppColors.lightText, fontSize: 15, height: 1.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
