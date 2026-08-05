/// 对应 `ref/hermes-agent/tools/schema_sanitizer.py`（像素级复刻）。
///
/// 为广泛 LLM 后端兼容性清洗工具 JSON schema。
///
/// 部分本地推理后端（尤其 llama.cpp 的 ``json-schema-to-grammar`` 转换器，用于
/// 构建 GBNF 工具调用解析器）对接受的 JSON Schema 形状严格。OpenAI/Anthropic/
/// 多数云 provider 静默接受的 schema 会让 llama.cpp 使整个请求失败，报：
///
///     HTTP 400: Unable to generate parser for this template.
///     Automatic parser generation failed: JSON schema conversion failed:
///     Unrecognized schema: "object"
///
/// 本模块遍历最终工具 schema 树（MCP 级归一化和任何每工具动态重建之后），在
/// 深拷贝上就地修复已知敌意结构。刻意保守：只修改 LLM 后端反正不能用的形状。
library;

/// Anthropic（及其背后的 Bedrock/Vertex/Azure）拒绝属性键不匹配此模式的工具
/// 输入 schema。Cloudflare 的 flat API MCP 有 61 个此类键（如
/// ``issue_class~neq`` 和 ``meta.<field>[<operator>]``）—— tools 数组任意一处
/// 坏键使整个请求 400。
final RegExp _propKeyRe = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');
final RegExp _propKeyBadChars = RegExp(r'[^a-zA-Z0-9_.-]');

/// 确定性映射任意属性键到合规键。
String sanitizePropertyKey(String key) {
  final bad = _propKeyBadChars;
  var new_ = key.replaceAll(bad, '_');
  if (new_.length > 64) {
    new_ = new_.substring(0, 64);
  }
  return new_.isEmpty ? 'param' : new_;
}

/// 返回一个 properties dict 的 `{original_key: conforming_key}`。
///
/// 恒等条目省略。确定性：键按插入顺序处理，冲突用数字后缀去重，因此模型可见
/// schema 和 dispatch 时反向映射（独立从 registry 原始 schema 计算）始终一致。
Map<String, String> _renamePropertyKeys(Map<String, dynamic> props, String path) {
  final renames = <String, String>{};
  final taken = props.keys.where((k) => _propKeyRe.hasMatch(k)).toSet();
  for (final key in props.keys) {
    if (_propKeyRe.hasMatch(key)) {
      continue;
    }
    var base = sanitizePropertyKey(key);
    var candidate = base;
    var i = 2;
    while (taken.contains(candidate)) {
      final suffix = '_$i';
      candidate = base.length > 64 - suffix.length
          ? base.substring(0, 64 - suffix.length) + suffix
          : base + suffix;
      i++;
    }
    taken.add(candidate);
    renames[key] = candidate;
  }
  return renames;
}

/// 把模型发出的参数中的净化属性键映射回 wire 名。
///
/// ``paramsSchema`` 是 registry 的 ORIGINAL（未净化）参数 schema。递归进
/// object 类型值和 array items，使嵌套重命名键也被恢复。未知键原样通过。
dynamic unrenameToolArgs(dynamic paramsSchema, dynamic args) {
  if (paramsSchema is! Map<String, dynamic> || args is! Map<String, dynamic>) {
    return args;
  }
  final props = paramsSchema['properties'];
  if (props is! Map<String, dynamic>) {
    return args;
  }
  final reverse = <String, String>{};
  _renamePropertyKeys(props, '<unrename>').forEach((k, v) {
    reverse[v] = k;
  });
  final out = <String, dynamic>{};
  for (final e in args.entries) {
    final key = e.key;
    final orig = reverse[key] ?? key;
    final value = e.value;
    final subschema = props[orig];
    dynamic newValue = value;
    if (subschema is Map<String, dynamic>) {
      if (value is Map<String, dynamic>) {
        newValue = unrenameToolArgs(subschema, value);
      } else if (value is List && subschema['items'] is Map<String, dynamic>) {
        newValue = [
          for (final item in value)
            item is Map<String, dynamic> ? unrenameToolArgs(subschema['items'], item) : item,
        ];
      }
    }
    out[orig] = newValue;
  }
  return out;
}

/// 返回 ``tools`` 的副本，每个工具的参数 schema 已净化。
///
/// 输入是 OpenAI 格式工具列表：
/// ``[{"type": "function", "function": {"name": ..., "parameters": {...}}}]``
///
/// 返回列表是深拷贝 —— 调用者可安全修改而不影响原始 registry 条目。
List<Map<String, dynamic>> sanitizeToolSchemas(List<Map<String, dynamic>> tools) {
  if (tools.isEmpty) {
    return tools;
  }
  return [for (final tool in tools) _sanitizeSingleTool(tool)];
}

Map<String, dynamic> _deepCopyMap(Map<String, dynamic> m) {
  final out = <String, dynamic>{};
  for (final e in m.entries) {
    out[e.key] = _deepCopy(e.value);
  }
  return out;
}

/// 递归深拷贝（对应 Python copy.deepcopy）。不用 JSON 往返 —— 值含 NaN/
/// Infinity/超大 int 时 jsonEncode 会抛，且丢类型。
dynamic _deepCopy(dynamic v) {
  if (v is Map) {
    return _deepCopyMap(Map<String, dynamic>.from(v));
  }
  if (v is List) {
    return [for (final item in v) _deepCopy(item)];
  }
  return v; // 标量（num/bool/String/null）不可变，直接复用。
}

/// 深拷贝并净化单个 OpenAI 格式工具条目。
Map<String, dynamic> _sanitizeSingleTool(Map<String, dynamic> tool) {
  final out = _deepCopyMap(tool);
  final fn = out['function'];
  if (fn is! Map<String, dynamic>) {
    return out;
  }

  final params = fn['parameters'];
  // 缺失/非 dict 参数 → 替换为最小有效形状。
  if (params is! Map<String, dynamic>) {
    fn['parameters'] = {'type': 'object', 'properties': <String, dynamic>{}};
    return out;
  }

  fn['parameters'] = _sanitizeNode(params, path: fn['name'] ?? '<tool>');
  // 递归后，保证顶层是带 properties 的 object。
  final top = fn['parameters'];
  if (top is! Map<String, dynamic>) {
    fn['parameters'] = {'type': 'object', 'properties': <String, dynamic>{}};
  } else {
    if (top['type'] != 'object') {
      top['type'] = 'object';
    }
    if (top['properties'] is! Map<String, dynamic>) {
      top['properties'] = <String, dynamic>{};
    }
  }
  // 最终遍：折叠上面递归清洗器留下的可空 anyOf/oneOf 联合（它只处理数组形式
  // ``type: [X, "null"]``）。保留 ``nullable: true`` 提示，使运行时参数强制
  // （model_tools._schema_allows_null）仍能把模型发出的 ``"null"`` 串映射到
  // Python None。
  fn['parameters'] = stripNullableUnions(fn['parameters'], keepNullableHint: true);
  // 剥离严格后端（OpenAI 的 Codex 端点）拒绝的顶层组合器。嵌套组合器保留。
  fn['parameters'] = _stripTopLevelCombinators(
    fn['parameters'],
    path: fn['name'] ?? '<tool>',
  );
  fn['parameters'] = _stripRefSiblings(fn['parameters']);
  return out;
}

/// 严格 JSON Schema 校验器在 ``$ref`` 旁拒绝的兄弟关键字。
const Set<String> _refForbiddenSiblings = {'default'};

/// 从携带 ``$ref`` 的节点丢弃禁止兄弟关键字。
dynamic _stripRefSiblings(dynamic node) {
  if (node is List) {
    return [for (final item in node) _stripRefSiblings(item)];
  }
  if (node is! Map<String, dynamic>) {
    return node;
  }
  final out = <String, dynamic>{
    for (final e in node.entries) e.key: _stripRefSiblings(e.value),
  };
  if (out.containsKey(r'$ref')) {
    for (final key in _refForbiddenSiblings) {
      out.remove(key);
    }
  }
  return out;
}

const List<String> _topLevelForbiddenKeys = ['allOf', 'anyOf', 'oneOf', 'enum', 'not'];

/// 从函数参数 schema 顶层丢弃组合器关键字。
dynamic _stripTopLevelCombinators(dynamic params, {String path = '<tool>'}) {
  if (params is! Map<String, dynamic>) {
    return params;
  }
  final out = Map<String, dynamic>.from(params);
  for (final key in _topLevelForbiddenKeys) {
    out.remove(key);
  }
  return out;
}

/// 折叠 ``anyOf`` / ``oneOf`` 可空联合到非空分支。
///
/// MCP/Pydantic 可选字段通常到达为：:
///
///     {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null}
///
/// Anthropic 的工具输入 schema 校验器拒绝 null 分支。工具可选性已由父 object
/// 的 ``required`` 数组表示，因此把联合折叠到单一非空变体。
///
/// 外层联合节点上的元数据（``title``、``description``、``default``、
/// ``examples``）带到替换变体。
dynamic stripNullableUnions(dynamic schema, {bool keepNullableHint = true}) {
  if (schema is List) {
    return [
      for (final item in schema)
        stripNullableUnions(item, keepNullableHint: keepNullableHint),
    ];
  }
  if (schema is! Map<String, dynamic>) {
    return schema;
  }

  final stripped = <String, dynamic>{
    for (final e in schema.entries)
      e.key: stripNullableUnions(e.value, keepNullableHint: keepNullableHint),
  };
  for (final key in ['anyOf', 'oneOf']) {
    final variants = stripped[key];
    if (variants is! List) {
      continue;
    }
    final nonNull = variants
        .where((item) =>
            item is! Map<String, dynamic> || item['type'] != 'null')
        .toList();
    // 只在确实丢了一个 null 分支且恰有一个非空分支存活时折叠（否则联合有意义，
    // 保持不动）。
    if (nonNull.length == 1 && nonNull.length != variants.length) {
      final replacement = nonNull.first is Map<String, dynamic>
          ? Map<String, dynamic>.from(nonNull.first as Map<String, dynamic>)
          : <String, dynamic>{};
      if (keepNullableHint) {
        replacement.putIfAbsent('nullable', () => true);
      }
      for (final metaKey in ['title', 'description', 'default', 'examples']) {
        if (stripped.containsKey(metaKey) &&
            !replacement.containsKey(metaKey)) {
          // ``default`` 在严格后端与 ``$ref`` 同层非法。
          if (metaKey == 'default' && replacement.containsKey(r'$ref')) {
            continue;
          }
          replacement[metaKey] = stripped[metaKey];
        }
      }
      return stripNullableUnions(replacement, keepNullableHint: keepNullableHint);
    }
  }
  return stripped;
}

/// 递归净化 JSON-Schema 片段。
///
/// - 裸字符串 schema 值（"object"、"string"、...）替换为 ``{"type": <value>}``。
/// - 给缺失的 object 类型节点注入 ``properties: {}``。
/// - 归一化 ``type: [X, "null"]`` 数组为单一 ``type: X``（保留 ``nullable: true``
///   提示），多类型数组如 ``["number", "string"]`` 归一化为单类型 schema 的
///   ``anyOf``，使无分支被丢弃。
/// - 递归进 ``properties``、``items``、``additionalProperties``、``anyOf``、
///   ``oneOf``、``allOf`` 和 ``$defs`` / ``definitions``。
dynamic _sanitizeNode(dynamic node, {required String path}) {
  // 畸形：schema 位置持有裸字符串如 "object"。
  if (node is String) {
    if (const {
          'object', 'string', 'number', 'integer', 'boolean', 'array', 'null',
        }.contains(node)) {
      return node != 'object'
          ? {'type': node}
          : {'type': 'object', 'properties': <String, dynamic>{}};
    }
    // 其他任何游离字符串不是 schema —— 用宽容 object schema 替换而非传播
    // 后端会拒绝的东西。
    return {'type': 'object', 'properties': <String, dynamic>{}};
  }

  if (node is List) {
    return [
      for (var i = 0; i < node.length; i++) _sanitizeNode(node[i], path: '$path[$i]'),
    ];
  }

  if (node is! Map<String, dynamic>) {
    return node;
  }

  // 提前计算属性键重命名，使 ``required`` 分支无论 dict 迭代顺序都能重映射
  // （``required`` 在源 dict 中可先于 ``properties``）。
  Map<String, String> propRenames = {};
  if (node['properties'] is Map<String, dynamic>) {
    propRenames = _renamePropertyKeys(
      node['properties'] as Map<String, dynamic>,
      '$path.properties',
    );
  }

  final out = <String, dynamic>{};
  for (final e in node.entries) {
    final key = e.key;
    final value = e.value;
    // JSON Schema ``type`` 数组（如 ``["number", "string"]``，MCP 工具 schema 常
    // 见）被数个工具调用后端拒绝。
    if (key == 'type' && value is List) {
      final hasNull = value.contains('null');
      final nonNull = value.whereType<String>().where((t) => t != 'null').toList();
      if (nonNull.length == 1) {
        out['type'] = nonNull.first;
        if (hasNull) {
          out.putIfAbsent('nullable', () => true);
        }
        continue;
      }
      if (nonNull.length >= 2) {
        // 作为联合保留所有分支而非丢弃。
        out['anyOf'] = [for (final t in nonNull) {'type': t}];
        if (hasNull) {
          out.putIfAbsent('nullable', () => true);
        }
        continue;
      }
      // 无可用的非空类型：全 null 数组 → type: "null"；否则空/垃圾数组 → object
      // 回退。
      out['type'] = hasNull ? 'null' : 'object';
      continue;
    }

    if ((key == 'properties' || key == r'$defs' || key == 'definitions') &&
        value is Map<String, dynamic>) {
      final renames = key == 'properties' ? propRenames : <String, String>{};
      final newProps = <String, dynamic>{};
      for (final subEntry in value.entries) {
        final outK = renames[subEntry.key] ?? subEntry.key;
        newProps[outK] = _sanitizeNode(
          subEntry.value,
          path: '$path.$key.$outK',
        );
      }
      out[key] = newProps;
    } else if (key == 'items' || key == 'additionalProperties') {
      if (value is bool) {
        // 保留 bool ``additionalProperties`` —— 它是有效形式且被广泛接受。
        out[key] = value;
      } else {
        out[key] = _sanitizeNode(value, path: '$path.$key');
      }
    } else if ((key == 'anyOf' || key == 'oneOf' || key == 'allOf') &&
        value is List) {
      out[key] = [
        for (var i = 0; i < value.length; i++)
          _sanitizeNode(value[i], path: '$path.$key[$i]'),
      ];
    } else if (key == 'required' ||
        key == 'enum' ||
        key == 'examples' ||
        key == 'dependentRequired') {
      // schema "兄弟" 关键字，值不是 schema。
      if (key == 'required' && propRenames.isNotEmpty && value is List) {
        out[key] = [
          for (final r in value)
            r is String ? (propRenames[r] ?? r) : r,
        ];
      } else {
        out[key] = _deepCopy(value);
      }
    } else {
      out[key] = (value is Map<String, dynamic> || value is List)
          ? _sanitizeNode(value, path: '$path.$key')
          : value;
    }
  }

  // 无 properties 的 object 节点：注入空 properties dict。
  if (out['type'] == 'object' && out['properties'] is! Map<String, dynamic>) {
    out['properties'] = <String, dynamic>{};
  }

  // 剪除 properties 中不存在的 ``required`` 条目（防畸形 MCP schema）。
  if (out['type'] == 'object' && out['required'] is List) {
    final props = out['properties'];
    final valid = <dynamic>[];
    for (final r in out['required'] as List) {
      if (r is String && props is Map<String, dynamic> && props.containsKey(r)) {
        valid.add(r);
      }
    }
    if (valid.isEmpty) {
      out.remove('required');
    } else if (valid.length != (out['required'] as List).length) {
      out['required'] = valid;
    }
  }

  return out;
}

// =============================================================================
// 反应式剥离 —— 仅当 llama.cpp 拒绝 schema 时调用
// =============================================================================

const Set<String> _stripOnRecoveryKeys = {'pattern', 'format'};

/// 从工具 schema 剥离 ``pattern`` 和 ``format`` JSON Schema 关键字。
///
/// 这是*反应式*清洗器，仅当 llama.cpp 的 ``json-schema-to-grammar`` 转换器以
/// HTTP 400 语法解析错误拒绝工具 schema 时调用。llama.cpp 的正则引擎只支持
/// ECMAScript 正则小子集（字面量、``.``、``[...]``、``|``、``*``、``+``、
/// ``?``、``{n,m}``）—— 拒绝 ``\d``、``\w``、``\s`` 转义类和大部分 ``format``
/// 值。云 provider（OpenAI、Anthropic、OpenRouter、Gemini）接受这些关键字并
/// 依赖它们作提示提示，因此默认 schema 保留，按需才剥离。
///
/// 返回 ``(tools, stripped_count)``。
(int, List<Map<String, dynamic>>) stripPatternAndFormat(
  List<Map<String, dynamic>> tools,
) {
  if (tools.isEmpty) {
    return (0, tools);
  }

  var stripped = 0;

  void walk(dynamic node) {
    if (node is Map<String, dynamic>) {
      final isSchemaNode = node.containsKey('type') ||
          node.containsKey('anyOf') ||
          node.containsKey('oneOf') ||
          node.containsKey('allOf');
      for (final key in node.keys.toList()) {
        if (isSchemaNode && _stripOnRecoveryKeys.contains(key)) {
          node.remove(key);
          stripped++;
          continue;
        }
        walk(node[key]);
      }
    } else if (node is List) {
      for (final item in node) {
        walk(item);
      }
    }
  }

  for (final tool in tools) {
    final fn = tool['function'];
    if (fn is Map<String, dynamic>) {
      final params = fn['parameters'];
      if (params is Map<String, dynamic>) {
        walk(params);
        continue;
      }
    }
    final params = tool['parameters'];
    if (params is Map<String, dynamic>) {
      walk(params);
    }
  }

  return (stripped, tools);
}

/// 剥离字符串值含正斜杠的 ``enum`` 关键字。
///
/// xAI 的 ``/v1/responses`` 和 ``/v1/chat/completions`` 端点把工具 schema 编译
/// 到拒绝含 ``/`` 的 ``enum`` 值的语法（请求在任何 token 发出前以 HTTP 400
/// "Invalid arguments passed to the model" 失败）。最常见被 MCP 派生工具命中，
/// 其 enum 列表 HuggingFace 模型 ID（``Qwen/Qwen3.5-0.8B``、
/// ``openai/gpt-oss-20b``）或 owner/name 环境 ID。
///
/// 返回 ``(tools, stripped_count)``。
(int, List<Map<String, dynamic>>) stripSlashEnum(
  List<Map<String, dynamic>> tools,
) {
  if (tools.isEmpty) {
    return (0, tools);
  }

  var stripped = 0;

  void walk(dynamic node) {
    if (node is Map<String, dynamic>) {
      final enumVal = node['enum'];
      if (enumVal is List &&
          enumVal.any((v) => v is String && v.contains('/'))) {
        node.remove('enum');
        stripped++;
      }
      for (final v in node.values) {
        walk(v);
      }
    } else if (node is List) {
      for (final item in node) {
        walk(item);
      }
    }
  }

  for (final tool in tools) {
    final fn = tool['function'];
    if (fn is Map<String, dynamic>) {
      final params = fn['parameters'];
      if (params is Map<String, dynamic>) {
        walk(params);
        continue;
      }
    }
    final params = tool['parameters'];
    if (params is Map<String, dynamic>) {
      walk(params);
    }
  }

  return (stripped, tools);
}
