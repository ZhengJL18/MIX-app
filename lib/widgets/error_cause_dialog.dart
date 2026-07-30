import 'package:flutter/material.dart';
import '../config/config.dart';

class ErrorCauseResult {
  final String mainCause;
  final String? minorCause;
  const ErrorCauseResult({required this.mainCause, this.minorCause});
}

/// 做错后弹出的四选项错因标注：先选一个主因，再选一个辅因（辅因可跳过）。
/// 对应设计文档第六节表格。
class ErrorCauseDialog extends StatefulWidget {
  const ErrorCauseDialog({super.key});

  static const Map<String, ({String label, List<String> subOptions})> options = {
    CauseDims.complexity: (
      label: 'A. 步骤型错误',
      subOptions: ['步骤遗漏', '顺序错误', '中间计算错'],
    ),
    CauseDims.understand: (
      label: 'B. 理解型错误',
      subOptions: ['概念理解错', '公式记错', '原理不理解'],
    ),
    CauseDims.redundancy: (
      label: 'C. 干扰型错误',
      subOptions: ['被无关信息干扰', '漏关键条件'],
    ),
    CauseDims.coverage: (
      label: 'D. 边界型错误',
      subOptions: ['不知道用哪个知识点', '边界不清晰'],
    ),
  };

  @override
  State<ErrorCauseDialog> createState() => _ErrorCauseDialogState();
}

class _ErrorCauseDialogState extends State<ErrorCauseDialog> {
  String? _mainCause;
  String? _minorCause;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('这道题错在哪里？'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('主因（必选）',
                style: TextStyle(fontWeight: FontWeight.bold)),
            RadioGroup<String>(
              groupValue: _mainCause,
              onChanged: (v) => setState(() {
                _mainCause = v;
                if (_minorCause == v) _minorCause = null;
              }),
              child: Column(
                children: [
                  for (final entry in ErrorCauseDialog.options.entries)
                    RadioListTile<String>(
                      dense: true,
                      title: Text(entry.value.label),
                      subtitle:
                          Text(entry.value.subOptions.join(' / ')),
                      value: entry.key,
                    ),
                ],
              ),
            ),
            const Divider(),
            const Text('辅因（可选）',
                style: TextStyle(fontWeight: FontWeight.bold)),
            RadioGroup<String>(
              groupValue: _minorCause,
              onChanged: (v) => setState(() => _minorCause = v),
              child: Column(
                children: [
                  for (final entry in ErrorCauseDialog.options.entries)
                    RadioListTile<String>(
                      dense: true,
                      title: Text(entry.value.label),
                      value: entry.key,
                      enabled: entry.key != _mainCause,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _mainCause == null
              ? null
              : () => Navigator.of(context).pop(
                    ErrorCauseResult(
                        mainCause: _mainCause!,
                        minorCause: _minorCause),
                  ),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
