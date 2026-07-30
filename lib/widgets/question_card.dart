import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// 题目卡片 — 纯展示题干
/// 多题型支持：根据 type 字段渲染不同交互组件
class QuestionCard extends StatelessWidget {
  final Map<String, dynamic> question;
  final int questionIndex;

  const QuestionCard({
    super.key,
    required this.question,
    this.questionIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final type = question['type'] as String? ?? 'text';

    return Container(
      color: AppColors.lightBg,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部信息
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '第 ${questionIndex + 1} 题',
                  style: TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _typeLabel(type),
                style: TextStyle(color: AppColors.lightTextMuted, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // 题干
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                question['content'] as String? ?? '',
                style: t.bodyLarge?.copyWith(fontSize: 18, height: 1.7),
              ),
            ),
          ),
          // 根据题型渲染交互区
          _QuestionInteractions(type: type, question: question),
        ],
      ),
    );
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'multiple_choice': return '选择题';
      case 'fill_blank': return '填空题';
      case 'true_false': return '判断题';
      case 'matching': return '匹配题';
      case 'ordering': return '排序题';
      default: return '问答题';
    }
  }
}

class _QuestionInteractions extends StatelessWidget {
  final String type;
  final Map<String, dynamic> question;

  const _QuestionInteractions({required this.type, required this.question});

  @override
  Widget build(BuildContext context) {
    switch (type) {
      case 'multiple_choice':
        return _ChoiceInteraction(question: question);
      case 'true_false':
        return _TrueFalseInteraction();
      case 'fill_blank':
        return _FillBlankInteraction();
      case 'matching':
        return _MatchingInteraction(question: question);
      case 'ordering':
        return _OrderingInteraction(question: question);
      default:
        return _TextInteraction();
    }
  }
}

// ─── 选择题选项 ───

class _ChoiceInteraction extends StatefulWidget {
  final Map<String, dynamic> question;
  const _ChoiceInteraction({required this.question});

  @override
  State<_ChoiceInteraction> createState() => _ChoiceInteractionState();
}

class _ChoiceInteractionState extends State<_ChoiceInteraction> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final options = (widget.question['options'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];

    return Column(
      children: options.map((opt) {
        final isSelected = _selected == opt;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GestureDetector(
            onTap: () => setState(() => _selected = opt),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.primaryLight : AppColors.lightSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.lightDivider,
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: isSelected ? AppColors.primary : AppColors.lightTextMuted,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(opt)),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ─── 判断题 ───

class _TrueFalseInteraction extends StatefulWidget {
  const _TrueFalseInteraction();

  @override
  State<_TrueFalseInteraction> createState() => _TrueFalseInteractionState();
}

class _TrueFalseInteractionState extends State<_TrueFalseInteraction> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _selected = '正确'),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 20),
              decoration: BoxDecoration(
                color: _selected == '正确' ? AppColors.correct.withValues(alpha: 0.1) : AppColors.lightSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _selected == '正确' ? AppColors.correct : AppColors.lightDivider,
                  width: 2,
                ),
              ),
              child: Center(
                child: Text('✅ 正确', style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _selected == '正确' ? AppColors.correct : AppColors.lightTextMuted,
                )),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _selected = '错误'),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 20),
              decoration: BoxDecoration(
                color: _selected == '错误' ? AppColors.wrong.withValues(alpha: 0.1) : AppColors.lightSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _selected == '错误' ? AppColors.wrong : AppColors.lightDivider,
                  width: 2,
                ),
              ),
              child: Center(
                child: Text('❌ 错误', style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _selected == '错误' ? AppColors.wrong : AppColors.lightTextMuted,
                )),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── 填空题 ───

class _FillBlankInteraction extends StatelessWidget {
  const _FillBlankInteraction();

  @override
  Widget build(BuildContext context) {
    return TextField(
      decoration: InputDecoration(
        hintText: '输入你的答案...',
        filled: true,
        fillColor: AppColors.lightSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.lightDivider),
        ),
        contentPadding: const EdgeInsets.all(16),
      ),
      maxLines: 3,
    );
  }
}

// ─── 匹配题 ───

class _MatchingInteraction extends StatelessWidget {
  final Map<String, dynamic> question;
  const _MatchingInteraction({required this.question});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Text('请在答案页查看匹配题答案',
        style: TextStyle(color: AppColors.lightTextMuted, fontSize: 14)),
    );
  }
}

// ─── 排序题 ───

class _OrderingInteraction extends StatelessWidget {
  final Map<String, dynamic> question;
  const _OrderingInteraction({required this.question});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Text('请在答案页查看排序题答案',
        style: TextStyle(color: AppColors.lightTextMuted, fontSize: 14)),
    );
  }
}

// ─── 问答题 ───

class _TextInteraction extends StatelessWidget {
  const _TextInteraction();

  @override
  Widget build(BuildContext context) {
    return TextField(
      decoration: InputDecoration(
        hintText: '输入你的回答...',
        filled: true,
        fillColor: AppColors.lightSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.lightDivider),
        ),
        contentPadding: const EdgeInsets.all(16),
      ),
      maxLines: 4,
    );
  }
}
