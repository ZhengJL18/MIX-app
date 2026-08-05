/// 对应 `ref/hermes-agent/tools/registry.py`（像素级复刻）。
///
/// 所有 hermes-agent 工具的中央注册中心。
///
/// 每个工具文件在模块层调用 `registry.register()` 声明其 schema、handler、
/// toolset 成员身份和可用性检查。`model_tools.dart` 查询注册中心而不是维护
/// 自己的平行数据结构。
///
/// 导入链（循环导入安全）：
///     tools/registry.dart  （不依赖 model_tools 或工具文件）
///            ^
///     tools/*.dart  （模块层从 tools/registry.dart import）
///            ^
///     model_tools.dart  （import tools/registry.dart + 所有工具模块）
///            ^
///     run_agent.dart, cli.dart, batch_runner.dart 等
///
/// ## Python → Dart 适配说明
/// - **AST 扫描发现**（`discover_builtin_tools`）：Python 用 `ast.parse` 扫描
///   `tools/*.py` 找顶层 `registry.register()` 再 `importlib`。Dart 无运行时
///   动态 import，工具模块在编译期被聚合文件 import、顶层 `register()` 调用在
///   库加载时执行（Dart 顶层 final 惰性求值）→ 语义等价，发现机制适配为静态。
/// - **threading.Lock**：Dart 单 isolate 内是事件循环单线程，无共享内存并发，
///   `_check_fn_cache_lock` / `self._lock` 简化为无锁（保留方法结构）。
/// - **`sys._getframe` / `handler.__globals__["__name__"]`**：Dart 无调用栈
///   反射，`_caller_module()` 恒返回 `''`、`_plugin_owner_of()` 恒返回 `null`；
///   无插件系统时行为与 Python 单进程等同。
/// - **`_run_async` 桥接**：Python 为同步/异步双态做桥接；Dart async 原生，
///   `dispatch` 对 handler 统一 `await`（同步返回值 await 无害）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'budget_config.dart';

/// 工具 handler 签名：`handler(args, **kwargs) -> str | dict`。
/// 普通结果必须是 JSON 字符串（用 [toolError]/[toolResult] 构造）；唯一结构化
/// 例外是 `{"_multimodal": True, "content": [...]}` 多模态信封。
typedef ToolHandler = FutureOr<dynamic> Function(
  Map<String, dynamic> args, [
  Map<String, dynamic>? kwargs,
]);

/// 顶层可注入的工具错误净化器，对应 Python `model_tools._sanitize_tool_error`
/// 的函数内懒 import（避免 registry → model_tools 循环依赖）。
/// `model_tools.dart` 复刻时赋值；未赋值时用 [defaultSanitizeToolError] 兜底。
String Function(String)? sanitizeToolError;

/// 内置兜底净化器（对齐 Python _sanitize_tool_error：剥角色标签/fence/CDATA +
/// 截断 + [TOOL_ERROR] 前缀）。model_tools 库加载后会被更完整的实现替换。
String defaultSanitizeToolError(String raw) {
  final roleTagRe = RegExp(
    r'</?(?:tool_call|function_call|result|response|output|input|system|assistant|user)>',
    caseSensitive: false,
  );
  const maxLen = 2000;
  var s = raw.replaceAll(roleTagRe, '');
  s = s.replaceAll(RegExp(r'^\s*```(?:json|xml|html|markdown)?\s*',
      multiLine: true), '');
  s = s.replaceAll(RegExp(r'\s*```\s*$', multiLine: true), '');
  s = s.replaceAll(RegExp(r'<!\[CDATA\[.*?\]\]>', dotAll: true), '');
  if (s.length > maxLen) {
    s = '${s.substring(0, maxLen - 3)}...';
  }
  return '[TOOL_ERROR] $s';
}


// ---------------------------------------------------------------------------
// check_fn TTL 缓存
//
// check_fn callables（如 terminal_tool.check_terminal_requirements）探测外部
// 状态（Docker daemon、Modal SDK、playwright 二进制）。对长驻 CLI/gateway 进程，
// 每次 get_definitions() 都调用是纯浪费 —— 外部状态以人类时间尺度变化。结果
// 缓存约 30s，使环境变量翻转或实时凭证文件变化在一两个 turn 内传播，无需显式
// 失效。
//
// 瞬时失败抑制（issue #21658 / #5304）：这些探测会抖动。一个在负载下超时的
// `subprocess.run([docker, "version"], timeout=5)` 单次返回 False，会静默地从
// 当下构建的任意 agent（最显眼是 delegate_task 子代理）剥离整个 terminal+file
// toolset —— 然后子代理报告 "Tool read_file does not exist"。为吸收这种抖动而
// 不固定一个永久过期的 "available" 判定，我们记住每次检查返回 True 的最后时间，
// 当新探测在该次成功的短宽限窗口内失败时，提供 last-good True 而不是缓存失败。
// 持续超过宽限窗口的失败正常生效，因此真正下线的后端会停止广告其工具。
// ---------------------------------------------------------------------------

const double _checkFnTtlSeconds = 30.0;
/// 成功后持续多久的后续瞬时失败被视为抖动（提供 last-good True）而非真实中断。
/// 保持短，使真正下线的后端在一两个 turn 内被反映。
const double _checkFnFailureGraceSeconds = 60.0;
const int _checkFnCacheMax = 512;
/// 键 `(checkFn, scope)` → `(monotonic 时间戳, 布尔判定)`。
final Map<(bool Function(), String?), (double, bool)> _checkFnCache = {};
/// 每个 check_fn 最近一次 True 的单调时间戳。
final Map<(bool Function(), String?), double> _checkFnLastGood = {};
/// 无 multiplex 时进程级缓存，scope 为 null；有 profile 覆盖时用 profile 路径。
String? checkFnCacheScope() => null;
const String _checkFnCacheBypass = '';

/// 单调时钟源，对应 `time.monotonic()`。Dart 无标准单调时钟 API，用 Stopwatch。
final Stopwatch _monotonic = Stopwatch()..start();
double _monotonicNow() => _monotonic.elapsedMicroseconds / 1e6;

/// 过期陈旧条目并封顶按 profile 维度的缓存增长。
void _pruneCheckFnCaches(double now) {
  _checkFnCache.removeWhere((_, tsBool) => now - tsBool.$1 >= _checkFnTtlSeconds);
  _checkFnLastGood.removeWhere(
    (_, ts) => now - ts >= _checkFnFailureGraceSeconds,
  );
  while (_checkFnCache.length >= _checkFnCacheMax) {
    _checkFnCache.remove(_checkFnCache.keys.first);
  }
  while (_checkFnLastGood.length >= _checkFnCacheMax) {
    _checkFnLastGood.remove(_checkFnLastGood.keys.first);
  }
}

/// 返回 `bool(fn())`，跨调用 TTL 缓存。
///
/// 异常被吞掉作为 False。`_checkFnFailureGraceSeconds` 内、距离上次 True 的瞬时
/// False/异常被抑制（返回 last-good True 且不缓存该失败，因此下次调用重新探测）
/// —— 防止抖动的外部检查（Docker daemon 忙、socket 争用、探测超时）在会话中
/// 静默剥离工具。
bool _checkFnCached(bool Function() fn) {
  final now = _monotonicNow();
  final scope = checkFnCacheScope();
  if (scope == _checkFnCacheBypass) {
    try {
      return fn();
    } catch (_) {
      return false;
    }
  }
  final cacheKey = (fn, scope);
  _pruneCheckFnCaches(now);
  final cached = _checkFnCache[cacheKey];
  if (cached != null) {
    final (ts, value) = cached;
    if (now - ts < _checkFnTtlSeconds) {
      return value;
    }
  }

  var raised = false;
  var value = false;
  try {
    value = fn();
  } catch (_) {
    raised = true;
  }

  _pruneCheckFnCaches(now);
  if (value) {
    _checkFnLastGood[cacheKey] = now;
    _checkFnCache[cacheKey] = (now, true);
    return true;
  }

  final lastGood = _checkFnLastGood[cacheKey];
  if (lastGood != null && now - lastGood < _checkFnFailureGraceSeconds) {
    // 近期成功 → 将此失败视为抖动。提供 last-good True 且不缓存失败，使下次
    // 调用重新探测而非把过期判定固定到完整 TTL。
    _jlog(
      'check_fn ${fn.runtimeType} failed '
      '(${raised ? 'raised' : 'returned False'}) within '
      '${_checkFnFailureGraceSeconds.toInt()}s of last success; '
      'treating as transient and keeping tool(s) available',
    );
    return true;
  }

  // 无近期成功（或宽限已过）—— 正常承认失败。记录以便安静模式下（子代理）
  // 的可诊断工具丢失可查。
  _jlog(
    'check_fn ${fn.runtimeType} '
    '${raised ? 'raised' : 'returned False'}; '
    'dependent tools will be unavailable this turn',
  );
  _checkFnCache[cacheKey] = (now, false);
  return false;
}

/// 极简日志输出到 stderr，对应 Python `logging` 模块（默认 handler 输出 stderr）。
void _jlog(String message) => stderr.writeln(message);

/// 丢弃所有缓存的 check_fn 结果。配置变化影响工具可用性后调用
/// （如 `hermes tools enable`）。
void invalidateCheckFnCache() {
  _checkFnCache.clear();
  _checkFnLastGood.clear();
}

/// 单个已注册工具的元数据。
class ToolEntry {
  final String name;
  final String toolset;
  final Map<String, dynamic> schema;
  final ToolHandler handler;
  final bool Function()? checkFn;
  final List<String> requiresEnv;
  final bool isAsync;
  final String description;
  final String emoji;
  final num? maxResultSizeChars;
  /// 可选零参 callable，返回在 get_definitions() 时应用的 schema 覆盖字典。
  /// 用于依赖运行时配置的字段（如 delegate_task 的 description 必须反映用户当前
  /// 的 delegation.max_concurrent_children / max_spawn_depth，以免告诉模型错误
  /// 的限制）。callable 在每次 get_definitions() 时被调用；结果浅合并到基础
  /// schema 之上、在 `{"type": "function", ...}` 包装之前。
  /// 类型 `Object? Function()` 忠实于 Python `Callable`（返回任意值，运行时
  /// 以 `is Map` 检查）。
  final Object? Function()? dynamicSchemaOverrides;

  ToolEntry({
    required this.name,
    required this.toolset,
    required this.schema,
    required this.handler,
    this.checkFn,
    required this.requiresEnv,
    required this.isAsync,
    required this.description,
    required this.emoji,
    this.maxResultSizeChars,
    this.dynamicSchemaOverrides,
  });
}

/// 插件模块命名空间覆盖内置工具失败时抛出的错误。
class ToolPermissionError implements Exception {
  final String message;
  ToolPermissionError(this.message);
  @override
  String toString() => message;
}

/// 收集工具文件中工具 schema + handler 的单例注册中心。
class ToolRegistry {
  final Map<String, ToolEntry> _tools = {};
  /// 持久映射：插件模块命名空间 -> 内置工具覆盖的 operator 选择。
  /// 插件加载时填充，永不清除，使插件的覆盖授权绑定到定义 handler 的代码，
  /// 与 register() 调用发生的时间无关。
  final Map<String, bool> _pluginOverridePolicy = {};
  final Map<String, bool Function()> _toolsetChecks = {};
  final Map<String, String> _toolsetAliases = {};
  /// 单调递增的代数计数器。每次变更（register / deregister /
  /// registerToolsetAlias / MCP 刷新）时递增。外部调用者（如 getToolDefinitions）
  /// 可据此 memoize：以代数为键的缓存条目在代数不变期间有效。
  int _generation = 0;

  /// 当前代数。外部调用者可据此做 schema 缓存失效。
  int get generation => _generation;

  /// 返回注册表条目和工具集检查的一致快照。
  (List<ToolEntry>, Map<String, bool Function()>) _snapshotState() {
    return (List.of(_tools.values), Map.of(_toolsetChecks));
  }

  /// 返回已注册工具条目的稳定快照。
  List<ToolEntry> _snapshotEntries() => _snapshotState().$1;

  /// 当 *toolset* 中至少一个工具会被暴露时返回 True。
  ///
  /// 镜像 getDefinitions 的逐工具过滤，使 doctor、banner 等工具集级表面与运行时
  /// 暴露一致。混合工具集（如 ``terminal`` 加桌面专属 ``read_terminal``）不得
  /// 仅由第一个注册的 check_fn 门控。
  bool _toolsetHasExposableTools(
    String toolset,
    List<ToolEntry> entries,
  ) {
    final checkResults = <bool Function(), bool>{};
    for (final entry in entries) {
      if (entry.toolset != toolset) {
        continue;
      }
      if (entry.checkFn == null) {
        return true;
      }
      if (!checkResults.containsKey(entry.checkFn)) {
        checkResults[entry.checkFn!] = _checkFnCached(entry.checkFn!);
      }
      if (checkResults[entry.checkFn!]!) {
        return true;
      }
    }
    return false;
  }

  /// 按名称返回已注册工具条目，或 None。
  ToolEntry? getEntry(String name) => _tools[name];

  /// 返回注册中心中已排序去重的 toolset 名称。
  List<String> getRegisteredToolsetNames() {
    final names = _snapshotEntries().map((e) => e.toolset).toSet().toList();
    names.sort();
    return names;
  }

  /// 返回某 toolset 下已排序的工具名称。
  List<String> getToolNamesForToolset(String toolset) {
    final names = _snapshotEntries()
        .where((e) => e.toolset == toolset)
        .map((e) => e.name)
        .toList();
    names.sort();
    return names;
  }

  /// 为规范 toolset 名称注册显式别名。
  void registerToolsetAlias(String alias, String toolset) {
    final existing = _toolsetAliases[alias];
    if (existing != null && existing != toolset) {
      // logger.warning("Toolset alias collision: '%s' (%s) overwritten by %s", ...)
    }
    _toolsetAliases[alias] = toolset;
    _generation++;
  }

  /// 返回 `{alias: canonical_toolset}` 映射的快照。
  Map<String, String> getRegisteredToolsetAliases() => Map.of(_toolsetAliases);

  /// 返回别名的规范 toolset 名，或 None。
  String? getToolsetAliasTarget(String alias) => _toolsetAliases[alias];

  // ------------------------------------------------------------------
  // Registration
  // ------------------------------------------------------------------

  /// 将插件模块命名空间绑定到其内置工具覆盖的 operator 选择。
  /// 每个插件加载时调用一次。持久：永不清除，使该模块后续（甚至线程化/延迟的）
  /// register() 调用仍被同一策略门控。
  void registerPluginOverridePolicy(String moduleNamespace, bool allowed) {
    _pluginOverridePolicy[moduleNamespace] = allowed;
  }

  /// 返回定义 *handler* 的插件模块命名空间；若 handler 不是定义在已加载插件
  /// 模块中则返回 None。
  ///
  /// 授权绑定到 handler 定义处（Python `__globals__["__name__"]`，定义时固定，
  /// 不会随调用点/线程/时机漂移）。lambda 和嵌套函数继承定义模块的 globals。
  /// 内置/MCP handler 在插件命名空间之外，返回 null（行为不变）。
  ///
  /// Dart 适配：无 `__globals__` 反射，恒返回 null（Jailer 无插件覆盖系统）。
  String? _pluginOwnerOf(ToolHandler handler) => null;

  /// 最佳努力获取调用者的模块名（Python 用 `sys._getframe(2)`）。
  /// Dart 适配：无调用栈反射，恒返回 `''`。
  String _callerModule() => '';

  /// 注册一个工具。每个工具文件在模块导入时调用。
  ///
  /// `override=true` 是插件打算替换现有内置工具实现（如把默认浏览器工具换成
  /// headed-Chrome CDP 后端）的显式选择。没有它，会遮蔽不同 toolset 已有工具的
  /// 注册会被拒绝，以防意外覆盖。
  void register({
    required String name,
    required String toolset,
    required Map<String, dynamic> schema,
    required ToolHandler handler,
    bool Function()? checkFn,
    List<String>? requiresEnv,
    bool isAsync = false,
    String description = '',
    String emoji = '',
    num? maxResultSizeChars,
    Object? Function()? dynamicSchemaOverrides,
    bool override = false,
  }) {
    final existing = _tools[name];
    if (existing != null && existing.toolset != toolset) {
      if (override) {
        final owner = _pluginOwnerOf(handler);
        if (owner != null && !(_pluginOverridePolicy[owner] ?? false)) {
          throw ToolPermissionError(
            "Plugin module $owner cannot override built-in "
            "tool $name without operator opt-in (allow_tool_override).",
          );
        }
        // 显式选择（或非插件调用者）：替换工具。
      } else {
        // 拒绝所有跨 toolset 遮蔽，包括 MCP-to-MCP 冲突。合法的 MCP 重连/刷新
        // 在相同规范 toolset 内重新注册，仍被允许。
        return;
      }
    }
    _tools[name] = ToolEntry(
      name: name,
      toolset: toolset,
      schema: schema,
      handler: handler,
      checkFn: checkFn,
      requiresEnv: requiresEnv ?? const [],
      isAsync: isAsync,
      description: description.isNotEmpty
          ? description
          : (schema['description'] as String? ?? ''),
      emoji: emoji,
      maxResultSizeChars: maxResultSizeChars,
      dynamicSchemaOverrides: dynamicSchemaOverrides,
    );
    // 可用性现在按工具派生（_toolsetHasExposableTools），此映射不再门控 toolset。
    // 仍被 getToolsetRequirements -> TOOLSET_REQUIREMENTS["checkFn"] 消费，banner
    // 读取（仅存在性，从不调用）把已不可用的 toolset 分类为 lazy-init vs disabled。
    if (checkFn != null && !_toolsetChecks.containsKey(toolset)) {
      _toolsetChecks[toolset] = checkFn;
    }
    _generation++;
  }

  /// 从注册中心移除一个工具。
  ///
  /// 也清理 toolset 检查，若同 toolset 无其余工具。用于 MCP 动态工具发现
  /// 在服务器发送 `notifications/tools/list_changed` 时的 nuke-and-repave。
  ///
  /// 由 register(override=true) 强制执行的同一 operator 选择策略门控。否则插件
  /// 可完全绕过该门：先 deregister 一个不属于它的工具，再在空槽上调用普通
  /// register() —— register() 只在存在 existing 条目时运行 override 检查，先
  /// 移除它则完全跳过检查。MCP toolset（`mcp-*`）豁免：动态工具发现合法地
  /// 每次刷新 nuke-and-repave 自己的工具，无插件覆盖概念。
  void deregister(String name) {
    final entry = _tools[name];
    if (entry == null) {
      return;
    }
    if (!entry.toolset.startsWith('mcp-')) {
      final callerMod = _callerModule();
      final owner = _pluginOwnerOf(entry.handler);
      // 所有权检查：绑定到插件包根（`hermes_plugins.{name}`）而非精确模块串。
      final callerRoot = callerMod.split('.').take(2).join('.');
      final ownerRoot = owner == null || owner.isEmpty
          ? ''
          : owner.split('.').take(2).join('.');
      final samePlugin = owner != null && callerRoot == ownerRoot;
      if (callerMod.startsWith('hermes_plugins.') &&
          !samePlugin &&
          !(_pluginOverridePolicy[callerRoot] ?? false)) {
        throw ToolPermissionError(
          "Plugin module $callerMod cannot deregister tool "
          "$name (toolset ${entry.toolset}) without operator "
          'opt-in (allow_tool_override).',
        );
      }
    }
    _tools.remove(name);
    // 若这是该 toolset 最后一个工具，丢弃 toolset 检查和别名。
    final toolsetStillExists =
        _tools.values.any((e) => e.toolset == entry.toolset);
    if (!toolsetStillExists) {
      _toolsetChecks.remove(entry.toolset);
      _toolsetAliases.removeWhere((_, target) => target == entry.toolset);
    }
    _generation++;
  }

  // ------------------------------------------------------------------
  // Schema retrieval
  // ------------------------------------------------------------------

  /// 返回请求工具名的 OpenAI 格式工具 schema。
  ///
  /// 只包含 `check_fn()` 返回 True（或无 check_fn）的工具。`check_fn()` 结果经
  /// [_checkFnCached] 缓存约 30s，摊销重复探测（check_terminal_requirements 探测
  /// modal/docker，浏览器检查探测 playwright 等）；TTL 选择使环境变量变化
  /// （`hermes tools enable foo`）仍近实时生效，而无需每次调用强制全量缓存刷新。
  List<Map<String, dynamic>> getDefinitions(
    Set<String> toolNames, {
    bool quiet = false,
  }) {
    final result = <Map<String, dynamic>>[];
    // TTL 之上的每次调用缓存 —— 处理同一 definitions pass 内重复探测相同
    // check_fn 而不重复读 TTL 时钟。
    final checkResults = <bool Function(), bool>{};
    final entriesByName = {
      for (final e in _snapshotEntries()) e.name: e,
    };
    final sortedNames = toolNames.toList()..sort();
    for (final name in sortedNames) {
      final entry = entriesByName[name];
      if (entry == null) {
        continue;
      }
      if (entry.checkFn != null) {
        if (!checkResults.containsKey(entry.checkFn)) {
          checkResults[entry.checkFn!] = _checkFnCached(entry.checkFn!);
        }
        if (checkResults[entry.checkFn!] != true) {
          if (!quiet) {
            // logger.debug("Tool %s unavailable (check failed)", name)
          }
          continue;
        }
      }
      // 确保 schema 总有 "name" 字段 —— 用 entry.name 兜底。
      final schemaWithName = {...entry.schema, 'name': entry.name};
      // 应用运行时动态覆盖。调用方（model_tools.getToolDefinitions）已将其
      // memo 键到 config.yaml mtime + size，因此 delegation.* 变化自动失效缓存。
      if (entry.dynamicSchemaOverrides != null) {
        try {
          final overrides = entry.dynamicSchemaOverrides!();
          if (overrides is Map<String, dynamic>) {
            schemaWithName.addAll(overrides);
          }
        } catch (_) {
          // logger.warning("dynamic_schema_overrides for tool %s raised %s; using static schema", ...)
        }
      }
      result.add({'type': 'function', 'function': schemaWithName});
    }
    return result;
  }

  // ------------------------------------------------------------------
  // Dispatch
  // ------------------------------------------------------------------

  /// 强制工具管线支持的结果形状。
  ///
  /// 正常工具结果是字符串。唯一结构化例外是 agent executor 消费的多模态信封。
  /// 返回其他任何值作为字符串错误，使 logging/hooks/budgeting/persistence 不会
  /// 收到无法安全切片或量大小的值。
  dynamic _normalizeHandlerResult(String name, dynamic result) {
    if (result is String) {
      return result;
    }
    if (result is Map<String, dynamic> &&
        result['_multimodal'] == true &&
        result['content'] is List) {
      return result;
    }
    final resultType = result.runtimeType.toString();
    return toolError(
      'Tool handler returned unsupported result type: $resultType',
      extra: {
        'error_type': 'tool_result_contract',
        'tool': name,
        'result_type': resultType,
      },
    );
  }

  /// 按名称执行工具 handler。
  ///
  /// * Dart async 原生，handler 统一 await（对应 Python 的 `_run_async()` 桥接）。
  /// * Handler 结果在离开注册中心前被规范化为字符串或支持的多模态信封。
  /// * 所有异常被捕获并作为 `{"error": "..."}` 返回，保证错误格式一致。
  Future<dynamic> dispatch(
    String name,
    Map<String, dynamic> args, {
    Map<String, dynamic> kwargs = const {},
  }) async {
    final entry = getEntry(name);
    if (entry == null) {
      return toolError('Unknown tool: $name');
    }
    try {
      final result = await entry.handler(args, kwargs);
      return _normalizeHandlerResult(name, result);
    } catch (e) {
      // 经过净化器，使异常字符串中的 framing tokens / CDATA / fences 不会作为
      // 结构性噪音到达模型。
      final raw = 'Tool execution failed: ${e.runtimeType}: $e';
      String sanitized;
      try {
        // model_tools 库加载/首次 handleFunctionCall 时接线；未接线时用内置
        // 兜底（剥角色标签 + 截断），保证直接 dispatch 也有净化。
        sanitized = (sanitizeToolError ?? defaultSanitizeToolError)(raw);
      } catch (_) {
        sanitized = raw; // 防御：绝不让净化器阻塞错误传播
      }
      return toolError(sanitized);
    }
  }

  // ------------------------------------------------------------------
  // Query helpers
  // ------------------------------------------------------------------

  /// 返回每工具最大结果大小，或 *default*（或全局默认）。
  num getMaxResultSize(String name, {num? default_}) {
    final entry = getEntry(name);
    if (entry != null && entry.maxResultSizeChars != null) {
      return entry.maxResultSizeChars!;
    }
    if (default_ != null) {
      return default_;
    }
    return defaultResultSizeChars;
  }

  /// 返回全部已注册工具名的排序列表。
  List<String> getAllToolNames() {
    final names = _snapshotEntries().map((e) => e.name).toList();
    names.sort();
    return names;
  }

  /// 返回工具的原始 schema dict，绕过 check_fn 过滤。
  ///
  /// 对 token 估算和内省有用，此时可用性不重要 —— 只要 schema 内容。
  Map<String, dynamic>? getSchema(String name) => getEntry(name)?.schema;

  /// 返回工具所属的 toolset，或 None。
  String? getToolsetForTool(String name) => getEntry(name)?.toolset;

  /// 返回工具 emoji，未设置则返回 *default*。
  String getEmoji(String name, {String default_ = '⚡'}) {
    final entry = getEntry(name);
    return (entry != null && entry.emoji.isNotEmpty) ? entry.emoji : default_;
  }

  /// 返回 `{tool_name: toolset_name}`，覆盖每个已注册工具。
  Map<String, String> getToolToToolsetMap() {
    return {for (final e in _snapshotEntries()) e.name: e.toolset};
  }

  /// 检查 toolset 是否有至少一个可暴露的工具。
  ///
  /// 当每工具检查抛出意外异常（如网络错误、缺失 import、坏配置）时返回 False
  /// 而不是崩溃。
  bool isToolsetAvailable(String toolset) {
    final (entries, _) = _snapshotState();
    return _toolsetHasExposableTools(toolset, entries);
  }

  /// 返回 `{toolset: available_bool}`，覆盖每个 toolset。
  Map<String, bool> checkToolsetRequirements() {
    final (entries, _) = _snapshotState();
    final toolsets = entries.map((e) => e.toolset).toSet().toList()..sort();
    return {
      for (final toolset in toolsets)
        toolset: _toolsetHasExposableTools(toolset, entries),
    };
  }

  /// 返回用于 UI 展示的 toolset 元数据。
  Map<String, Map<String, dynamic>> getAvailableToolsets() {
    final toolsets = <String, Map<String, dynamic>>{};
    final (entries, _) = _snapshotState();
    for (final entry in entries) {
      final ts = entry.toolset;
      if (!toolsets.containsKey(ts)) {
        toolsets[ts] = {
          'available': _toolsetHasExposableTools(ts, entries),
          'tools': <String>[],
          'description': '',
          'requirements': <String>[],
        };
      }
      (toolsets[ts]!['tools'] as List<String>).add(entry.name);
      for (final env in entry.requiresEnv) {
        final reqs = toolsets[ts]!['requirements'] as List<String>;
        if (!reqs.contains(env)) {
          reqs.add(env);
        }
      }
    }
    return toolsets;
  }

  /// 构建 TOOLSET_REQUIREMENTS 兼容 dict（向后兼容）。
  Map<String, Map<String, dynamic>> getToolsetRequirements() {
    final result = <String, Map<String, dynamic>>{};
    final (entries, toolsetChecks) = _snapshotState();
    for (final entry in entries) {
      final ts = entry.toolset;
      if (!result.containsKey(ts)) {
        result[ts] = {
          'name': ts,
          'env_vars': <String>[],
          'check_fn': toolsetChecks[ts],
          'setup_url': null,
          'tools': <String>[],
        };
      }
      final tools = result[ts]!['tools'] as List<String>;
      if (!tools.contains(entry.name)) {
        tools.add(entry.name);
      }
      final envVars = result[ts]!['env_vars'] as List<String>;
      for (final env in entry.requiresEnv) {
        if (!envVars.contains(env)) {
          envVars.add(env);
        }
      }
    }
    return result;
  }

  /// 返回 `(available_toolsets, unavailable_info)`，像旧函数一样。
  (List<String>, List<Map<String, dynamic>>) checkToolAvailability({
    bool quiet = false,
  }) {
    final available = <String>[];
    final unavailable = <Map<String, dynamic>>[];
    final (entries, _) = _snapshotState();
    final toolsets = entries.map((e) => e.toolset).toSet().toList()..sort();
    for (final ts in toolsets) {
      final tsEntries = entries.where((e) => e.toolset == ts).toList();
      if (_toolsetHasExposableTools(ts, entries)) {
        available.add(ts);
      } else {
        unavailable.add({
          'name': ts,
          'env_vars': tsEntries.isEmpty ? const <String>[] : tsEntries.first.requiresEnv,
          'tools': tsEntries.map((e) => e.name).toList(),
        });
      }
    }
    return (available, unavailable);
  }
}

/// 模块级单例。
final ToolRegistry registry = ToolRegistry();

// ---------------------------------------------------------------------------
// 工具响应序列化辅助
// ---------------------------------------------------------------------------
// 每个工具 handler 必须返回 JSON 字符串。这些辅助消除跨工具文件数百处重复的
// `json.dumps({"error": msg}, ensure_ascii=False)` 样板。
//
// 用法：
//   import 'package:jailer/tools/registry.dart';
//   return toolError('something went wrong');
//   return toolError('not found', extra: {'code': 404});
//   return toolResult({'success': true, 'data': payload});
//   return toolResult({'items': items});   // 直接传 dict

/// 返回工具 handler 的 JSON 错误字符串。
///
/// `toolError('file not found')` → `{"error": "file not found"}`
/// `toolError('bad input', extra: {'success': false})` → `{"error": "bad input", "success": false}`
String toolError(String message, {Map<String, dynamic>? extra}) {
  final result = <String, dynamic>{'error': message};
  if (extra != null && extra.isNotEmpty) {
    result.addAll(extra);
  }
  return jsonEncode(result);
}

/// 返回工具 handler 的 JSON 结果字符串。
///
/// 接受位置 dict 参数 *或* kwargs（不同时）。
///
/// `toolResult({'success': true, 'count': 42})` → `{"success": true, "count": 42}`
/// `toolResult({'key': 'value'})` → `{"key": "value"}`
String toolResult(Map<String, dynamic>? data, [Map<String, dynamic>? kwargs]) {
  if (data != null) {
    return jsonEncode(data);
  }
  return jsonEncode(kwargs ?? {});
}

// ---------------------------------------------------------------------------
// 内置工具发现（Dart 适配）
// ---------------------------------------------------------------------------
// Python 版：
//   1. `_module_registers_tools(path)`：ast.parse 扫描 tools/*.py 是否含顶层
//      `registry.register(...)` 调用（文本预过滤 registry+register 避免 parse 成本）。
//   2. `discover_builtin_tools()`：glob tools/*.py（排除 __init__/registry/mcp_tool），
//      stat 缓存 (mtime_ns, size) 判据，import 判定通过的模块 → 工具自注册。
//
// Dart 无运行时动态 import 与 AST 解析 Python 的能力。等价适配：
//   每个工具文件（lib/jailer/tools/*.dart）在模块顶层调用 `register(...)`；
//   `builtin_tools.dart`（聚合文件）import 所有工具模块，使顶层注册在库加载时
//   发生。`discoverBuiltinTools()` 返回已注册工具模块名，保持 API 形状。

/// 已知的内置工具模块名（对应 Python 的 `tools.<stem>`）。
const List<String> _builtinToolModuleNames = <String>[];

/// 导入内置自注册工具模块并返回其模块名。
///
/// Dart 适配：工具模块被编译期聚合 import（见文件头注释），顶层 `register()`
/// 在库加载时已执行；本函数返回已知模块名以保持 API 形状。
List<String> discoverBuiltinTools([String? toolsDir]) {
  return List.of(_builtinToolModuleNames);
}
