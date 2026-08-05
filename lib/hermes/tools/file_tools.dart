/// 对应 `ref/hermes-agent/tools/file_tools.py`（像素级复刻）。
///
/// LLM agent 文件操作工具：read_file / write_file / patch / search_files。
///
/// ## Dart 适配（Android 沙盒）
/// - `_get_file_ops` → 共享 [LocalFileOperations] 实例（cwd = App documents）。
/// - 路径解析（TERMINAL_CWD、容器后端、file_state 锁、dedup tracker、redact、
///   staleness 警告）在 App 沙盒无多 agent 并发 → 保留核心守卫
///   （write deny / read block / V4A traversal），文件状态跟踪简化。
/// - 结构化文档提取（docx/xlsx/ipynb）：无 Python lib，跳过 → 走二进制守卫。
/// - schema 与错误消息逐字保留。
library;

import 'dart:async';
import 'dart:convert';

import 'binary_extensions.dart';
import 'file_operations.dart';
import 'file_safety.dart';
import 'registry.dart';

/// 共享文件操作实例（Android App 沙盒 = documents 目录）。
LocalFileOperations? _fileOps;

LocalFileOperations _getFileOps() {
  return _fileOps ??= LocalFileOperations();
}

/// 供测试/外部注入 cwd 与外部访问开关。
void configureFileTools({String? cwd, bool allowExternal = false}) {
  _fileOps = LocalFileOperations(cwd: cwd, allowExternalAccess: allowExternal);
}

/// 读取当前外部访问开关（main.dart 启动时按权限设置）。
bool get fileToolsAllowExternal =>
    _fileOps?.allowExternalAccess ?? false;

/// 读文件大小守卫上限（字符）。
const int _defaultMaxReadChars = 100000;
int? _maxReadCharsCached;
int _getMaxReadChars() {
  _maxReadCharsCached ??= _defaultMaxReadChars;
  return _maxReadCharsCached!;
}

/// 把带行号内容修剪到字符预算。
///
/// 返回 (kept_text, lines_kept, truncated)。内容已适配预算时原样返回。
(String, int, bool) _truncateToCharBudget(String content, int maxChars) {
  if (content.length <= maxChars) {
    return (content, content.isEmpty ? 0 : content.split('\n').length, false);
  }

  final lines = content.split('\n');
  final kept = <String>[];
  var running = 0;
  for (final line in lines) {
    final addition = line.length + (kept.isNotEmpty ? 1 : 0);
    if (running + addition > maxChars) {
      break;
    }
    kept.add(line);
    running += addition;
  }

  if (kept.isEmpty) {
    // 首行单独超预算。按码点边界钳制而非什么都不发。
    kept.add(lines.first.length > maxChars ? lines.first.substring(0, maxChars) : lines.first);
  }

  return (kept.join('\n'), kept.length, true);
}

/// 阻塞设备路径（读取会挂起进程）。纯路径检查，无 I/O。
const Set<String> _blockedDevicePaths = {
  '/dev/zero', '/dev/random', '/dev/urandom', '/dev/full',
  '/dev/stdin', '/dev/tty', '/dev/console',
  '/dev/stdout', '/dev/stderr',
  '/dev/fd/0', '/dev/fd/1', '/dev/fd/2',
};

/// 阻塞 `/proc/*` 敏感路径（泄漏进程 env/cmdline/内存布局，issue #4427）。
const List<String> _procSensitiveSuffixes = [
  '/environ',
  '/cmdline',
  '/maps',
  '/smaps',
  '/smaps_rollup',
  '/numa_maps',
  '/mem',
  '/auxv',
  '/pagemap',
];

bool _isBlockedDevice(String path) {
  final expanded = path.startsWith('~') ? path : path;
  if (expanded.startsWith('/dev')) {
    return _blockedDevicePaths.contains(expanded);
  }
  // /proc/self/fd/0-2 和 /proc/<pid>/fd/0-2 是 stdio 别名。
  if (expanded.startsWith('/proc/') &&
      (expanded.endsWith('/fd/0') ||
          expanded.endsWith('/fd/1') ||
          expanded.endsWith('/fd/2'))) {
    return true;
  }
  // /proc/*/environ、/cmdline、/maps 族、/mem、/auxv、/pagemap 可泄漏宿主
  // 进程秘密、命令行参数和内存布局（ASLR bypass）。
  if (expanded.startsWith('/proc/')) {
    for (final suffix in _procSensitiveSuffixes) {
      if (expanded.endsWith(suffix)) {
        return true;
      }
    }
  }
  return false;
}

/// V4A 路径头含 `..` traversal 时拒绝。
String? _rejectV4aTraversal(String v4aPath) {
  final parts = v4aPath.replaceAll('\\', '/').split('/');
  if (parts.contains('..')) {
    return toolError(
      "V4A patch header contains '..' traversal: '$v4aPath'. "
      "Use the agent's cwd-relative path (no '..') or an absolute "
      "path in '*** Update File:' / '*** Add File:' / "
      "'*** Delete File:' / '*** Move File:' headers.",
    );
  }
  return null;
}

/// 从 V4A patch 提取文件路径（Update/Add/Delete/Move 头）。
List<String> _extractV4aPaths(String patch) {
  final paths = <String>[];
  final headerRe = RegExp(r'^\*\*\*\s*(?:Update|Add|Delete)\s+File:\s*(.+)$', multiLine: true);
  for (final m in headerRe.allMatches(patch)) {
    paths.add(m.group(1)!.trim());
  }
  final moveRe = RegExp(r'^\*\*\*\s*Move\s+File:\s*(.+?)\s*->\s*(.+)$', multiLine: true);
  for (final m in moveRe.allMatches(patch)) {
    paths.add(m.group(1)!.trim());
    paths.add(m.group(2)!.trim());
  }
  return paths;
}

/// read_file 工具：分页 + 行号。
String readFileTool({
  required String path,
  dynamic offset = 1,
  dynamic limit = 500,
}) {
  try {
    final (offsetN, limitN) = normalizeReadPagination(offset, limit);

    // 设备路径守卫。
    if (_isBlockedDevice(path)) {
      return toolError(
        "Cannot read '$path': this is a device file that would "
        'block or produce infinite output.',
      );
    }

    // 二进制扩展名守卫。
    if (hasBinaryExtension(path)) {
      return toolError(
        "Cannot read binary file '$path'. "
        'Use vision_analyze for images, or terminal to inspect binary files.',
      );
    }

    // Hermes 内部路径守卫（读拒绝）。只做路径检查，不读文件（避免大文件双重读）。
    final absPath = _absPath(path);
    final blockError = getReadBlockError(absPath);
    if (blockError != null) {
      return toolError(blockError);
    }

    final fileOps = _getFileOps();
    final result = fileOps.readFile(path, offset: offsetN, limit: limitN);

    final resultDict = result.toDict();
    // 字符预算截断。
    final contentLen = (resultDict['content'] as String? ?? '').length;
    final maxChars = _getMaxReadChars();
    if (contentLen > maxChars) {
      final content = resultDict['content'] as String;
      final (trimmed, linesKept, _) = _truncateToCharBudget(content, maxChars);
      final nextOffset = offsetN + linesKept;
      resultDict['content'] = trimmed;
      resultDict['truncated'] = true;
      resultDict['truncated_by'] = 'bytes';
      resultDict['next_offset'] = nextOffset;
      resultDict['hint'] = 'Output truncated at the $maxChars-char read budget '
          'after $linesKept line(s) (showing lines $offsetN-'
          '${offsetN + linesKept - 1} of ${result.totalLines}). Use offset=$nextOffset to continue.';
    }

    return jsonEncode(resultDict);
  } catch (e) {
    return toolError('$e');
  }
}

String _absPath(String path) {
  if (path.startsWith('/') || RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path)) {
    return path;
  }
  return _getFileOps().resolveForTool(path);
}

/// write_file 工具。
String writeFileTool({
  required String path,
  required String content,
  bool crossProfile = false,
}) {
  final sensitiveErr = getWriteDeniedError(path);
  if (sensitiveErr != null) {
    return toolError(sensitiveErr);
  }
  if (!crossProfile) {
    final crossWarning = getCrossProfileWarning(path);
    if (crossWarning != null) {
      return toolError(crossWarning);
    }
  }
  try {
    final fileOps = _getFileOps();
    final result = fileOps.writeFile(path, content);
    final resultDict = result.toDict();
    // 报告实际写入的绝对路径。
    resultDict['resolved_path'] = _absPath(path);
    if (result.error == null) {
      resultDict['files_modified'] = [_absPath(path)];
    }
    return jsonEncode(resultDict);
  } catch (e) {
    return toolError('$e');
  }
}

/// patch 工具：replace 模式或 V4A 模式。
String patchTool({
  String mode = 'replace',
  String? path,
  String? oldString,
  String? newString,
  bool replaceAll = false,
  String? patch,
  bool crossProfile = false,
}) {
  // 检查敏感路径（replace 显式 path + V4A 提取路径）。
  final pathsToCheck = <String>[];
  if (path != null) {
    pathsToCheck.add(path);
  }
  if (mode == 'patch' && patch != null) {
    for (final v4aPath in _extractV4aPaths(patch)) {
      final err = _rejectV4aTraversal(v4aPath);
      if (err != null) {
        return err;
      }
      pathsToCheck.add(v4aPath);
    }
  }
  for (final p in pathsToCheck) {
    final sensitiveErr = getWriteDeniedError(p);
    if (sensitiveErr != null) {
      return toolError(sensitiveErr);
    }
    if (!crossProfile) {
      final crossWarning = getCrossProfileWarning(p);
      if (crossWarning != null) {
        return toolError(crossWarning);
      }
    }
  }
  try {
    final fileOps = _getFileOps();
    final PatchResult result;
    if (mode == 'patch') {
      result = fileOps.patchV4a(patch ?? '');
    } else {
      if (path == null || oldString == null || newString == null) {
        return toolError(
            "patch: mode='replace' requires 'path', 'old_string', and 'new_string'.");
      }
      result = fileOps.patchReplace(
        path,
        oldString,
        newString,
        replaceAll: replaceAll,
      );
    }
    final resultDict = result.toDict();
    if (resultDict['success'] == true) {
      resultDict['resolved_path'] = _absPath(path ?? '');
    }
    return jsonEncode(resultDict);
  } catch (e) {
    return toolError('$e');
  }
}

/// search_files 工具。
String searchFileTool({
  required String pattern,
  String target = 'content',
  String path = '.',
  String? fileGlob,
  dynamic limit = 50,
  dynamic offset = 0,
  String outputMode = 'content',
  int context = 0,
}) {
  try {
    final (offsetN, limitN) = normalizeSearchPagination(offset, limit);
    // grep/find 别名映射。
    final targetMap = {'grep': 'content', 'find': 'files'};
    final resolvedTarget = targetMap[target] ?? target;

    final blockError = getReadBlockError(path);
    if (blockError != null) {
      return toolError(blockError);
    }

    final fileOps = _getFileOps();
    final result = fileOps.search(
      pattern,
      path: path,
      target: resolvedTarget,
      fileGlob: fileGlob,
      limit: limitN,
      offset: offsetN,
      outputMode: outputMode,
      context: context,
    );
    final resultDict = result.toDict(densify: true);
    final resultJson = jsonEncode(resultDict);
    // 截断时给显式 next offset 提示。
    if (resultDict['truncated'] == true) {
      final nextOffset = offsetN + limitN;
      return '$resultJson\n\n[Hint: Results truncated. Use offset=$nextOffset to see more, or narrow with a more specific pattern or file_glob.]';
    }
    return resultJson;
  } catch (e) {
    return toolError('$e');
  }
}

// =============================================================================
// Schemas + Registry（逐字复刻）
// =============================================================================

const Map<String, dynamic> readFileSchema = {
  'name': 'read_file',
  'description':
      "Read a text file with line numbers and pagination. Use this instead of cat/head/tail in terminal. Output format: 'LINE_NUM|CONTENT'. Suggests similar filenames if not found. Use offset and limit for large files. Reads exceeding ~100K characters are truncated on a line boundary and return a next_offset; continue with offset to read the rest. Jupyter notebooks (.ipynb), Word documents (.docx), and Excel workbooks (.xlsx) are auto-extracted to readable text. NOTE: Cannot read images or other binary files — use vision_analyze for images.",
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Path to the file to read (absolute, relative, or ~/path)',
      },
      'offset': {
        'type': 'integer',
        'description': 'Line number to start reading from (1-indexed, default: 1)',
        'default': 1,
        'minimum': 1,
      },
      'limit': {
        'type': 'integer',
        'description': 'Maximum number of lines to read (default: 500, max: 2000)',
        'default': 500,
        'maximum': 2000,
      },
    },
    'required': ['path'],
  },
};

const Map<String, dynamic> writeFileSchema = {
  'name': 'write_file',
  'description':
      "Write content to a file, completely replacing existing content. Use this instead of echo/cat heredoc in terminal. Creates parent directories automatically. OVERWRITES the entire file — use 'patch' for targeted edits. Auto-runs syntax checks on .py/.json/.yaml/.toml and other linted languages; only NEW errors introduced by this write are surfaced (pre-existing errors are filtered out).",
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description':
            "Path to the file to write (will be created if it doesn't exist, overwritten if it does)",
      },
      'content': {
        'type': 'string',
        'description': 'Complete content to write to the file',
      },
      'cross_profile': {
        'type': 'boolean',
        'description':
            "Opt out of the cross-profile soft guard. Defaults to false. Set true ONLY after explicit user direction to edit another Hermes profile's skills/plugins/cron/memories — by default these writes are blocked with a warning because they affect a different profile than the one this session is running under.",
        'default': false,
      },
    },
    'required': ['path', 'content'],
  },
};

const Map<String, dynamic> patchSchema = {
  'name': 'patch',
  'description':
      'Targeted find-and-replace edits in files. Use this instead of sed/awk in terminal. '
      'Uses fuzzy matching (9 strategies) so minor whitespace/indentation differences won\'t break it. '
      'Returns a unified diff. Auto-runs syntax checks after editing.\n\n'
      "REPLACE MODE (mode='replace', default): find a unique string and replace it. "
      'REQUIRED PARAMETERS: mode, path, old_string, new_string.\n'
      "PATCH MODE (mode='patch'): apply V4A multi-file patches for bulk changes. "
      'REQUIRED PARAMETERS: mode, patch.',
  'parameters': {
    'type': 'object',
    'properties': {
      'mode': {
        'type': 'string',
        'enum': ['replace', 'patch'],
        'description':
            "'replace' (default): requires path + old_string + new_string. 'patch': requires patch content only.",
        'default': 'replace',
      },
      'path': {
        'type': 'string',
        'description': "REQUIRED when mode='replace'. File path to edit.",
      },
      'old_string': {
        'type': 'string',
        'description':
            "REQUIRED when mode='replace'. Exact text to find and replace. Must be unique in the file unless replace_all=true. Include surrounding context lines to ensure uniqueness.",
      },
      'new_string': {
        'type': 'string',
        'description':
            "REQUIRED when mode='replace'. Replacement text. Pass empty string '' to delete the matched text.",
      },
      'replace_all': {
        'type': 'boolean',
        'description': 'Replace all occurrences instead of requiring a unique match (default: false)',
        'default': false,
      },
      'patch': {
        'type': 'string',
        'description':
            "REQUIRED when mode='patch'. V4A format patch content. Format:\n*** Begin Patch\n*** Update File: path/to/file\n@@ context hint @@\n context line\n-removed line\n+added line\n*** End Patch",
      },
      'cross_profile': {
        'type': 'boolean',
        'description':
            "Opt out of the cross-profile soft guard. Defaults to false. Set true ONLY after explicit user direction to edit another Hermes profile's skills/plugins/cron/memories.",
        'default': false,
      },
    },
    'required': ['mode'],
  },
};

const Map<String, dynamic> searchFilesSchema = {
  'name': 'search_files',
  'description':
      "Search file contents or find files by name. Use this instead of grep/rg/find/ls in terminal. Ripgrep-backed, faster than shell equivalents.\n\nContent search (target='content'): Regex search inside files. Output modes: full matches with line numbers, file paths only, or match counts.\n\nFile search (target='files'): Find files by glob pattern (e.g., '*.py', '*config*'). Also use this instead of ls — results sorted by modification time.",
  'parameters': {
    'type': 'object',
    'properties': {
      'pattern': {
        'type': 'string',
        'description': "Regex pattern for content search, or glob pattern (e.g., '*.py') for file search",
      },
      'target': {
        'type': 'string',
        'enum': ['content', 'files'],
        'description': "'content' searches inside file contents, 'files' searches for files by name",
        'default': 'content',
      },
      'path': {
        'type': 'string',
        'description': 'Directory or file to search in (default: current working directory)',
        'default': '.',
      },
      'file_glob': {
        'type': 'string',
        'description': "Filter files by pattern in grep mode (e.g., '*.py' to only search Python files)",
      },
      'limit': {
        'type': 'integer',
        'description': 'Maximum number of results to return (default: 50)',
        'default': 50,
      },
      'offset': {
        'type': 'integer',
        'description': 'Skip first N results for pagination (default: 0)',
        'default': 0,
      },
      'output_mode': {
        'type': 'string',
        'enum': ['content', 'files_only', 'count'],
        'description':
            "Output format for grep mode: 'content' shows matching lines with line numbers, 'files_only' lists file paths, 'count' shows match counts per file",
        'default': 'content',
      },
      'context': {
        'type': 'integer',
        'description': 'Number of context lines before and after each match (grep mode only)',
        'default': 0,
      },
    },
    'required': ['pattern'],
  },
};

/// handler 们。
FutureOr<dynamic> _handleReadFile(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) {
  return readFileTool(
    path: args['path'] as String? ?? '',
    offset: args['offset'] ?? 1,
    limit: args['limit'] ?? 500,
  );
}

FutureOr<dynamic> _handleWriteFile(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) {
  if (args['path'] is! String) {
    return toolError(
      "write_file: missing required field 'path'. Re-emit the tool call with both 'path' and 'content' set.",
    );
  }
  if (!args.containsKey('content')) {
    return toolError(
      "write_file: missing required field 'content'. The tool call included a path but no content argument — this is almost always a dropped-arg bug under context pressure. Re-emit the tool call with the full content payload.",
    );
  }
  if (args['content'] is! String) {
    return toolError(
      "write_file: 'content' must be a string, got ${args['content'].runtimeType}.",
    );
  }
  return writeFileTool(
    path: args['path'] as String,
    content: args['content'] as String,
    crossProfile: args['cross_profile'] == true,
  );
}

FutureOr<dynamic> _handlePatch(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) {
  return patchTool(
    mode: args['mode'] as String? ?? 'replace',
    path: args['path'] as String?,
    oldString: args['old_string'] as String?,
    newString: args['new_string'] as String?,
    replaceAll: args['replace_all'] == true,
    patch: args['patch'] as String?,
    crossProfile: args['cross_profile'] == true,
  );
}

FutureOr<dynamic> _handleSearchFiles(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) {
  final targetMap = {'grep': 'content', 'find': 'files'};
  final rawTarget = args['target'] as String? ?? 'content';
  return searchFileTool(
    pattern: args['pattern'] as String? ?? '',
    target: targetMap[rawTarget] ?? rawTarget,
    path: args['path'] as String? ?? '.',
    fileGlob: args['file_glob'] as String?,
    limit: args['limit'] ?? 50,
    offset: args['offset'] ?? 0,
    outputMode: args['output_mode'] as String? ?? 'content',
    context: args['context'] as int? ?? 0,
  );
}

bool _checkFileReqs() => true;

/// 注册 file 工具集（对应 file_tools.py 模块层注册）。
void registerFileTools() {
  registry.register(
    name: 'read_file',
    toolset: 'file',
    schema: readFileSchema,
    handler: _handleReadFile,
    checkFn: _checkFileReqs,
    emoji: '📖',
    maxResultSizeChars: 100000,
  );
  registry.register(
    name: 'write_file',
    toolset: 'file',
    schema: writeFileSchema,
    handler: _handleWriteFile,
    checkFn: _checkFileReqs,
    emoji: '✍️',
    maxResultSizeChars: 100000,
  );
  registry.register(
    name: 'patch',
    toolset: 'file',
    schema: patchSchema,
    handler: _handlePatch,
    checkFn: _checkFileReqs,
    emoji: '🔧',
    maxResultSizeChars: 100000,
  );
  registry.register(
    name: 'search_files',
    toolset: 'file',
    schema: searchFilesSchema,
    handler: _handleSearchFiles,
    checkFn: _checkFileReqs,
    emoji: '🔎',
    maxResultSizeChars: 100000,
  );
}
