/// 对应 `ref/hermes-agent/tools/ansi_strip.py`（像素级复刻）。
///
/// 从子进程输出剥离 ANSI 转义序列。
///
/// 被 terminal_tool、code_execution_tool、process_registry 用来在返回给模型前
/// 清洗命令输出。这防止 ANSI 码进入模型上下文 —— 模型把转义序列复制进文件写入
/// 的根因。
///
/// 覆盖完整 ECMA-48 规范：CSI（含私有模式 ``?`` 前缀、冒号分隔参数、中间字节）、
/// OSC（BEL 和 ST 终止符）、DCS/SOS/PM/APC 字符串序列、nF 多字节转义、Fp/Fe/Fs
/// 单字节转义，以及 8-bit C1 控制字符。
library;

final RegExp _ansiEscapeRe = RegExp(
  r'\x1b'
  r'(?:'
      r'\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]' // CSI sequence
      r'|\][\s\S]*?(?:\x07|\x1b\\)' // OSC (BEL or ST terminator)
      r'|[PX^_][\s\S]*?(?:\x1b\\)' // DCS/SOS/PM/APC strings
      r'|[\x20-\x2f]+[\x30-\x7e]' // nF escape sequences
      r'|[\x30-\x7e]' // Fp/Fe/Fs single-byte
  r')'
  r'|\x9b[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]' // 8-bit CSI
  r'|\x9d[\s\S]*?(?:\x07|\x9c)' // 8-bit OSC
  r'|[\x80-\x9f]', // Other 8-bit C1 controls
  dotAll: true,
);

/// 快速路径检查 —— 无类转义字节时跳过完整正则。
final RegExp _hasEscape = RegExp(r'[\x1b\x80-\x9f]');

/// C0 控制字符（减去 tab/newline/carriage-return，单独处理）加 DEL。
/// 这些在 strip_ansi() 中存活 —— 它只移除良构转义*序列* —— 但当回显到终端时
/// 仍危险或乱码（BEL 响铃、backspace/DEL 覆盖、NUL 在部分终端截断）。
final RegExp _controlCharsRe = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]');

/// sanitize_display_text 的快速路径检查 —— 任何 C0 控制（除 tab/newline）、CR、
/// DEL、ESC 或 C1 字节触发慢路径。
final RegExp _hasControl = RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]');

/// 从文本移除 ANSI 转义序列。
///
/// 无 ESC 或 C1 字节时原样返回输入（快速路径）。可安全调用任何字符串 ——
/// 干净文本以可忽略开销通过。
String stripAnsi(String text) {
  if (text.isEmpty || !_hasEscape.hasMatch(text)) {
    return text;
  }
  return text.replaceAll(_ansiEscapeRe, '');
}

/// 在回显到终端前净化存储/不受信任的文本。
///
/// 移除 ANSI/ECMA-48 转义序列和裸控制字符，只保留 newline 和 tab
/// （carriage return 规范化为 newline，使 ``\r``-覆盖欺骗无法隐藏内容）。
///
/// 在终端 UI 重新渲染对话历史或其他持久化文本时使用（如 ``/resume`` 回顾）：
/// 带内嵌转义到达的消息 —— 粘贴内容、gateway 来源文本、或模型输出回显注入的
/// 工具结果 —— 重放时绝不能清屏、改窗口标题、移光标或重排相邻 UI。Rich 的
/// ``Text()`` 不会中和裸转义字节，因此净化必须在显示前发生。
/// 镜像 openai/codex#31494（``sanitize_user_text``）。
String sanitizeDisplayText(String text) {
  if (text.isEmpty || !_hasControl.hasMatch(text)) {
    return text;
  }
  text = stripAnsi(text);
  if (text.contains('\r')) {
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }
  return text.replaceAll(_controlCharsRe, '');
}
