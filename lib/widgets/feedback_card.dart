import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../engine/feedback_v2.dart';

/// 错因反馈卡片 — 主因（必选）+ 辅因（可选）
///
/// ⚠️ 状态由父组件管理（_PracticeScreenState），
/// 卡片本身只渲染 UI 并回调，不维护内部状态。
class FeedbackCard extends StatelessWidget {
  final String? mainCause;
  final String? minorCause;
  final ValueChanged<String?> onMainCauseChanged;
  final ValueChanged<String?> onMinorCauseChanged;

  const FeedbackCard({
    super.key,
    this.mainCause,
    this.minorCause,
    required this.onMainCauseChanged,
    required this.onMinorCauseChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final labels = kCauseLabels.entries.toList();

    return Container(
      color: AppColors.lightBg,
      child: Column(
        children: [
          // 内容区：可滚动，滚到底后下滑自然翻页
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.error_outline, color: AppColors.wrong, size: 22),
                      const SizedBox(width: 8),
                      Text('错因分析', style: t.headlineMedium?.copyWith(fontSize: 20)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // 主因（必选）
                  Text('主因（必选）', style: t.titleMedium),
                  const SizedBox(height: 8),
                  ...labels.map((e) => _CauseButton(
                    label: e.key,
                    hint: e.value,
                    selected: mainCause == e.key,
                    color: AppColors.wrong,
                    onTap: () => onMainCauseChanged(mainCause == e.key ? null : e.key),
                  )),
                  const SizedBox(height: 20),
                  // 辅因（可选）
                  Text('辅因（可选）', style: t.titleMedium),
                  const SizedBox(height: 8),
                  ...labels.map((e) => _CauseButton(
                    label: e.key,
                    hint: e.value,
                    selected: minorCause == e.key,
                    color: AppColors.secondary,
                    onTap: () => onMinorCauseChanged(minorCause == e.key ? null : e.key),
                  )),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          // 底部提交提示
          Container(
            padding: const EdgeInsets.only(bottom: 20),
            child: Center(
              child: Text(
                mainCause == null ? '请先选择主因' : '下滑提交反馈 ➡',
                style: TextStyle(
                  color: mainCause == null ? AppColors.lightTextMuted.withValues(alpha: 0.5) : AppColors.lightTextMuted,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CauseButton extends StatelessWidget {
  final String label;
  final String hint;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _CauseButton({
    required this.label,
    required this.hint,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.1) : AppColors.lightSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? color : AppColors.lightDivider,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? color : Colors.transparent,
                  border: Border.all(
                    color: selected ? color : AppColors.lightTextMuted,
                    width: 2,
                  ),
                ),
                child: selected
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(hint, style: TextStyle(fontSize: 12, color: AppColors.lightTextMuted)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
