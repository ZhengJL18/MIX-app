/// 对应 `ref/hermes-agent/tools/todo_tool.py`（像素级复刻）。
///
/// 内存 todo 列表。每个 AIAgent 一个实例。
///
/// 条目有序（列表位置即优先级）。每项：
/// - id：唯一字符串标识（agent 自选）
/// - content：任务描述
/// - status：pending | in_progress | completed | cancelled
library;

import 'dart:convert';

import 'registry.dart';

/// 合法状态。
const Set<String> validStatuses = {
  'pending',
  'in_progress',
  'completed',
  'cancelled',
};

/// 条目数上限（防重放/超大列表无限增长注入块）。
const int maxTodoItems = 256;

/// 单条内容字符上限。
const int maxTodoContentChars = 2000;

/// 内存 todo 列表。
class TodoStore {
  final List<Map<String, String>> _items = [];

  /// 写 todos。返回写入后的完整列表。
  ///
  /// [merge] false = 整个替换；true = 按 id 更新已有 + 追加新。
  List<Map<String, String>> write(
    List<Map<String, dynamic>> todos, {
    bool merge = false,
  }) {
    if (!merge) {
      // 替换模式：全新列表。
      _items.clear();
      _items.addAll(_dedupeById(todos).map(_validate));
    } else {
      // 合并模式：按 id 更新已有，追加新的。
      final existing = {
        for (final item in _items) item['id']!: item,
      };
      for (final t in _dedupeById(todos)) {
        final itemId = (t['id'] as String? ?? '').trim();
        if (itemId.isEmpty) {
          continue; // 无 id 不能合并。
        }
        if (existing.containsKey(itemId)) {
          // 只更新 LLM 提供的字段。
          final content = t['content'];
          if (content is String && content.isNotEmpty) {
            existing[itemId]!['content'] = _capContent(content.trim());
          }
          final status = t['status'];
          if (status is String && status.isNotEmpty) {
            final s = status.trim().toLowerCase();
            if (validStatuses.contains(s)) {
              existing[itemId]!['status'] = s;
            }
          }
        } else {
          // 新条目：完整校验后追加。
          final validated = _validate(t);
          existing[validated['id']!] = validated;
          _items.add(validated);
        }
      }
      // 重建 _items 保持已有顺序。
      final seen = <String>{};
      final rebuilt = <Map<String, String>>[];
      for (final item in _items) {
        final current = existing[item['id']] ?? item;
        if (!seen.contains(current['id'])) {
          rebuilt.add(current);
          seen.add(current['id']!);
        }
      }
      _items
        ..clear()
        ..addAll(rebuilt);
    }
    // 条数上限（列表顺序即优先级，保留高优先级头部）。
    if (_items.length > maxTodoItems) {
      _items.removeRange(maxTodoItems, _items.length);
    }
    return read();
  }

  /// 返回当前列表副本。
  List<Map<String, String>> read() => [for (final i in _items) Map.of(i)];

  bool get hasItems => _items.isNotEmpty;

  /// 渲染用于压缩后注入的 todo 列表（仅 pending/in_progress）。
  ///
  /// 返回人类可读字符串，或空列表返回 null。
  String? formatForInjection() {
    if (_items.isEmpty) {
      return null;
    }
    const markers = {
      'completed': '[x]',
      'in_progress': '[>]',
      'pending': '[ ]',
      'cancelled': '[~]',
    };
    // 只注入 pending/in_progress（completed/cancelled 会让模型压缩后重做已完成工作）。
    final active = _items.where((i) {
      final s = i['status'];
      return s == 'pending' || s == 'in_progress';
    }).toList();
    if (active.isEmpty) {
      return null;
    }
    final lines = active
        .map((i) => '${markers[i['status']] ?? '[ ]'} ${i['content']}')
        .toList();
    return 'Current todos:\n${lines.join('\n')}';
  }

  String _capContent(String content) {
    if (content.length > maxTodoContentChars) {
      return '${content.substring(0, maxTodoContentChars)}...';
    }
    return content;
  }

  Map<String, String> _validate(Map<String, dynamic> item) {
    final id = (item['id'] as String? ?? '').trim();
    final content = (item['content'] as String? ?? '').trim();
    var status = (item['status'] as String? ?? '').trim().toLowerCase();
    if (!validStatuses.contains(status)) {
      status = 'pending';
    }
    return {
      'id': id.isEmpty ? '?' : id,
      'content': content.isEmpty ? '(empty)' : _capContent(content),
      'status': status,
    };
  }

  List<Map<String, dynamic>> _dedupeById(List<Map<String, dynamic>> todos) {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final t in todos) {
      final id = (t['id'] as String? ?? '').trim();
      if (id.isNotEmpty && seen.contains(id)) {
        continue;
      }
      if (id.isNotEmpty) {
        seen.add(id);
      }
      result.add(t);
    }
    return result;
  }
}

/// todo 工具单入口。读或写取决于参数。
///
/// [todos] 提供则写；null 则读当前列表。
/// [merge] true 按 id 更新，false 整个替换。
String todoTool({
  List<dynamic>? todos,
  bool merge = false,
  TodoStore? store,
}) {
  if (store == null) {
    return toolError('TodoStore not initialized');
  }

  List<Map<String, String>> items;
  if (todos != null) {
    // LLM 有时把 todos 发成 JSON 字符串而非列表。
    List<Map<String, dynamic>> list;
    if (todos.every((t) => t is String)) {
      try {
        final parsed = jsonDecode(todos.first as String);
        list = parsed is List
            ? parsed.whereType<Map<String, dynamic>>().toList()
            : <Map<String, dynamic>>[];
      } catch (_) {
        return toolError('todos must be a list of objects, got unparseable string');
      }
    } else {
      list = todos.whereType<Map<String, dynamic>>().toList();
    }
    items = store.write(list, merge: merge);
  } else {
    items = store.read();
  }

  var pending = 0, inProgress = 0, completed = 0, cancelled = 0;
  for (final i in items) {
    switch (i['status']) {
      case 'pending':
        pending++;
        break;
      case 'in_progress':
        inProgress++;
        break;
      case 'completed':
        completed++;
        break;
      case 'cancelled':
        cancelled++;
        break;
    }
  }

  return jsonEncode({
    'todos': items,
    'summary': {
      'total': items.length,
      'pending': pending,
      'in_progress': inProgress,
      'completed': completed,
      'cancelled': cancelled,
    },
  });
}

/// todo 工具 schema。
const Map<String, dynamic> todoSchema = {
  'name': 'todo',
  'description':
      'Manage a task list (todo). Items have id, content, and status '
      '(pending/in_progress/completed/cancelled). List order is priority. '
      "Provide 'todos' to write (merge=false replaces the whole list, "
      "merge=true updates by id), or omit to read the current list.",
  'parameters': {
    'type': 'object',
    'properties': {
      'todos': {
        'type': 'array',
        'description': 'List of {id, content, status} items to write',
        'items': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
            'content': {'type': 'string'},
            'status': {
              'type': 'string',
              'enum': ['pending', 'in_progress', 'completed', 'cancelled'],
            },
          },
        },
      },
      'merge': {
        'type': 'boolean',
        'description': 'If true, update existing items by id; if false, replace the entire list',
        'default': false,
      },
    },
  },
};

/// 全局 todo store（AIAgent 共享）。
TodoStore? todoStore;

/// 注册 todo 工具。
void registerTodoTool() {
  todoStore = TodoStore();
  registry.register(
    name: 'todo',
    toolset: 'todo',
    schema: todoSchema,
    handler: (args, [kwargs]) {
      return todoTool(
        todos: args['todos'] as List?,
        merge: args['merge'] == true,
        store: todoStore,
      );
    },
    checkFn: () => true,
    emoji: '📋',
  );
}
