/// 对应 `ref/hermes-agent/tools/tool_output_limits.py`（像素级复刻）。
///
/// 可配置的工具输出截断限制。
///
/// Ported from anomalyco/opencode PR #23770（``feat(truncate): allow
/// configuring tool output truncation limits``）。
///
/// OpenCode 硬编码 ``MAX_LINES = 2000`` 和 ``MAX_BYTES = 50 * 1024`` 作为
/// 工具输出截断阈值。Hermes-agent 在两处也有相同硬编码常量：
///
/// * ``tools/terminal_tool.py`` — ``MAX_OUTPUT_CHARS = 50000``
///   （terminal stdout/stderr 上限）
/// * ``tools/file_operations.py`` — ``MAX_LINES = 2000`` /
///   ``MAX_LINE_LENGTH = 2000``（read_file 分页上限 + 每行上限）
///
/// 本模块把这些值集中在单一 config 段（config.yaml 的 ``tool_output``）后面，
/// 使高级用户无需改源码即可调节。现有硬编码数字仍作为默认值，config 键缺失时
/// 行为不变。
///
/// 限制读取器是防御性的：任何错误（缺失 config 文件、无效值类型等）回退到内置
/// 默认值，因此工具不会因畸形 config 而失败。
///
/// ## Dart 适配
/// Python 版从 config.yaml 的 ``tool_output`` 段读取；Dart 版通过可注入的
/// [loadToolOutputSection] 钩子提供 config 源（默认返回空 map → 全部用默认值）。
/// 进程生命周期缓存同 Python 版 `_cached_limits`。
library;

/// 硬编码默认值 —— 与既有值一致，因此不设 ``tool_output`` 的用户行为不变。
const int defaultMaxBytes = 50000; // terminal_tool.MAX_OUTPUT_CHARS
const int defaultMaxLines = 2000; // file_operations.MAX_LINES
const int defaultMaxLineLength = 2000; // file_operations.MAX_LINE_LENGTH

/// 模块级缓存 —— 首次调用时填充。避免每次工具调用都做 config 文件 I/O。
Map<String, int>? _cachedLimits;

/// config 源钩子：返回 config.yaml 的 ``tool_output`` 段（map）。
/// 复刻 hermes_cli/config.py 的 `load_config()['tool_output']` 时赋值。
Map<String, dynamic> Function() loadToolOutputSection = () => const {};

/// 返回 ``value`` 为正 int，任何问题都返回 ``default``。
int _coercePositiveInt(Object? value, int default_) {
  final iv = int.tryParse(value.toString());
  if (iv == null) {
    return default_;
  }
  if (iv <= 0) {
    return default_;
  }
  return iv;
}

/// 返回解析后的工具输出限制，从 config 读取 ``tool_output``。
///
/// 键：``max_bytes``、``max_lines``、``max_line_length``。缺失或无效条目回退到
/// ``DEFAULT_*`` 常量。本函数从不抛出。
///
/// 结果在进程生命周期内缓存，避免每次工具调用重复磁盘 I/O。config 变化后需
/// 重新读取的测试调用 [resetToolOutputLimitsCache]。
Map<String, int> getToolOutputLimits() {
  if (_cachedLimits != null) {
    return _cachedLimits!;
  }
  Map<String, dynamic> section;
  try {
    final cfg = loadToolOutputSection();
    section = cfg['tool_output'] is Map<String, dynamic>
        ? cfg['tool_output'] as Map<String, dynamic>
        : <String, dynamic>{};
  } catch (_) {
    section = <String, dynamic>{};
  }

  _cachedLimits = {
    'max_bytes': _coercePositiveInt(section['max_bytes'], defaultMaxBytes),
    'max_lines': _coercePositiveInt(section['max_lines'], defaultMaxLines),
    'max_line_length': _coercePositiveInt(
      section['max_line_length'],
      defaultMaxLineLength,
    ),
  };
  return _cachedLimits!;
}

/// 重置缓存限制 —— 用于测试或 config 热重载后。
void resetToolOutputLimitsCache() {
  _cachedLimits = null;
}

/// 只关心字节上限的 terminal 工具调用者快捷方式。
int getMaxBytes() => getToolOutputLimits()['max_bytes']!;

/// 只关心行上限的 file-ops 调用者快捷方式。
int getMaxLines() => getToolOutputLimits()['max_lines']!;

/// 只关心每行上限的 file-ops 调用者快捷方式。
int getMaxLineLength() => getToolOutputLimits()['max_line_length']!;
