/// 对应 `ref/hermes-agent/agent/memory_manager.py`（像素级复刻，核心逻辑）。
///
/// 协调内置 provider（MemoryStore）+ 至多一个外部 provider。
///
/// ## Dart 适配
/// - 后台线程/外部 provider/会话生命周期钩子：手机 App 单 isolate，省略。
///   聚焦核心：内存注入 + 工具路由 + 状态。
/// - Hermes 的记忆注入 = MemoryStore 的 systemPromptSnapshot 进 system prompt
///   （每会话加载一次），非每 turn 检索。prefetchAll 简化为返回快照。
library;

import 'memory_tool.dart';
import 'registry.dart';

/// 协调记忆提供者的管理器（手机版：内置 MemoryStore 单 provider）。
class MemoryManager {
  /// 内置记忆存储。
  MemoryStore store;

  MemoryManager({required this.store});

  /// 构建注入 system prompt 的记忆块（memory + user）。
  ///
  /// 用**冻结快照**（formatForSystemPrompt 语义）：load 时的状态，会话中写入
  /// 不影响 —— 保持 system prompt 跨 turn 稳定，保住 prefix cache
  /// （Hermes 设计：新记忆下个会话生效）。空块跳过。
  String buildSystemPromptMemory() {
    final parts = <String>[];
    final mem = store.formatForSystemPrompt('memory');
    final user = store.formatForSystemPrompt('user');
    if (mem != null) parts.add(mem);
    if (user != null) parts.add(user);
    return parts.join('\n\n');
  }

  /// 预取记忆上下文（简化：返回全部记忆快照）。
  ///
  /// Hermes 按 query 检索相关记忆；手机版 App 记忆量小（2200+1375 字符上限），
  /// 直接返回全部即可，模型自己筛。query 保留用于未来检索实现。
  String prefetchAll(String query) {
    return buildSystemPromptMemory();
  }

  /// 路由工具调用到记忆 store（对应 provider.handle_tool_call）。
  String handleToolCall(String toolName, Map<String, dynamic> args) {
    if (toolName == 'memory') {
      return memoryTool(
        action: args['action'] as String?,
        target: args['target'] as String? ?? 'memory',
        content: args['content'] as String?,
        oldText: args['old_text'] as String?,
        operations: (args['operations'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList(),
        store: store,
      );
    }
    return toolError("No memory provider handles tool '$toolName'");
  }

  /// 会话结束/新 turn 钩子（手机版：重置合并失败计数）。
  void onTurnStart() {
    store.resetConsolidationFailures();
  }

  /// 当前记忆状态（调试/展示用）。
  Map<String, dynamic> state() => store.toDict();
}
