/// clarify 工具：agent 在任务不明确时主动向用户提问澄清。
///
/// 通过全局 [clarifyHandler] 回调与 UI 交互：UI 弹问题+选项，用户选择后
/// 答案回传给 agent，agent 继续。
library;

import 'dart:async';

import 'registry.dart';

/// UI 注册的澄清回调：给定问题与选项，返回用户答案。
/// 由 ChatScreen 注册（弹出选择对话框）。
Future<String> Function(String question, List<String> choices, bool multiSelect)?
    clarifyHandler;

/// clarify 工具 handler：暂停等待用户输入。
Future<String> _handleClarify(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  final handler = clarifyHandler;
  if (handler == null) {
    return toolError('clarify: 界面未提供澄清回调');
  }
  final question = args['question'] as String? ?? '';
  final choices = (args['choices'] as List?)?.whereType<String>().toList() ?? const [];
  final multi = args['multi_select'] == true;
  try {
    return await handler(question, choices, multi);
  } catch (e) {
    return toolError('clarify: $e');
  }
}

const Map<String, dynamic> _clarifySchema = {
  'name': 'clarify',
  'description':
      'Ask the user a clarifying question when a task is ambiguous. '
      'Provide a clear question and 2-4 choices. The user answers, and the '
      'answer is returned so you can continue. Use this when you need info '
      'only the user knows (preferences, scope, decisions).',
  'parameters': {
    'type': 'object',
    'properties': {
      'question': {'type': 'string', 'description': 'The question to ask the user'},
      'choices': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': '2-4 answer choices (optional; free text if empty)',
      },
      'multi_select': {
        'type': 'boolean',
        'description': 'Whether multiple choices can be selected',
      },
    },
    'required': ['question'],
  },
};

/// 注册 clarify 工具。
void registerClarifyTool() {
  registry.register(
    name: 'clarify',
    toolset: 'clarify',
    schema: _clarifySchema,
    handler: _handleClarify,
    isAsync: true,
    emoji: '❓',
  );
}
