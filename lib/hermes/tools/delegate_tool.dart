/// delegate_task 工具：agent 派子任务给子 agent 并行处理。
///
/// 子 agent 用独立 LLM 调用 + 工具执行，返回结果给主 agent。
/// 通过全局 [delegateHandler] 由 ChatScreen 提供（复用 JailerAgent）。
library;

import 'registry.dart';

/// ChatScreen 注册的子 agent 执行回调：给定任务，返回子 agent 的结果。
/// [depth] 当前代理层数（0 = 主代理）；子代理在 depth+1 层执行。
Future<String> Function(String task, List<String>? toolsets, int depth)?
    delegateHandler;

/// 最大代理层数（4 层代理 = 3 层子代理）。
const int maxAgentDepth = 3;

/// 当前正在执行的代理层数（串行模型下由子代理运行前设置）。
/// 不靠 LLM 传参（LLM 不会传内部字段），由 _runSubAgent/_runDepartment 维护。
int currentAgentDepth = 0;

/// delegate_task 工具 handler。
Future<String> _handleDelegate(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  final handler = delegateHandler;
  if (handler == null) {
    return toolError('delegate_task: 子 agent 执行器未注册');
  }
  final task = args['task'] as String? ?? '';
  if (task.isEmpty) {
    return toolError('delegate_task: missing task');
  }
  final toolsets = (args['toolsets'] as List?)?.whereType<String>().toList();
  final depth = currentAgentDepth;
  // 层数上限：达到 maxAgentDepth 的子代理不能再委派。
  if (depth >= maxAgentDepth) {
    return toolError('delegate_task: 已达最大代理层数（3 层子代理），'
        '请直接在子任务内完成，不要继续委派。');
  }
  try {
    return await handler(task, toolsets, depth);
  } catch (e) {
    return toolError('delegate_task failed: $e');
  }
}

const Map<String, dynamic> _delegateSchema = {
  'name': 'delegate_task',
  'description':
      'Delegate a sub-task to a sub-agent that runs independently with its own '
      'LLM turns and tool access, then returns a summary. Use for tasks that '
      'can run in parallel with your main work, or that benefit from a fresh '
      'context (research, refactoring a separate file, drafting code). '
      'The sub-agent result is returned as text.',
  'parameters': {
    'type': 'object',
    'properties': {
      'task': {
        'type': 'string',
        'description': 'A self-contained task description for the sub-agent',
      },
      'toolsets': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Optional toolsets the sub-agent may use (file, web, git)',
      },
    },
    'required': ['task'],
  },
};

/// 注册 delegate_task 工具。
void registerDelegateTool() {
  registry.register(
    name: 'delegate_task',
    toolset: 'delegate',
    schema: _delegateSchema,
    handler: _handleDelegate,
    isAsync: true,
    emoji: '🤖',
  );
}
