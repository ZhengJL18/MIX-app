/// 对应 `ref/hermes-agent/tools/patch_parser.py`（像素级复刻）。
///
// 字符串拼接风格忠实 Python 源码（f-string 直译），read 闭包因捕获变量无法
// 转为函数声明 —— 文件级抑制风格提示。
// ignore_for_file: prefer_interpolation_to_compose_strings, prefer_null_aware_operators, prefer_function_declarations_over_variables, prefer_conditional_assignment

/// V4A 补丁格式解析器，由 codex、cline 和其他编码 agent 使用。
///
/// V4A 格式：
///     *** Begin Patch
///     *** Update File: path/to/file.py
///     @@ optional context hint @@
///      context line（空格前缀）
///     -removed line（减号前缀）
///     +added line（加号前缀）
///     *** Add File: path/to/new.py
///     +new file content
///     +line 2
///     *** Delete File: path/to/old.py
///     *** Move File: old/path.py -> new/path.py
///     *** End Patch
library;

import 'file_operations.dart';
import 'fuzzy_match.dart';
import 'sequence_matcher.dart';

/// V4A 操作类型。
enum OperationType {
  add('add'),
  update('update'),
  delete('delete'),
  move('move');

  const OperationType(this.value);
  final String value;
}

/// 补丁 hunk 中的单行。
class HunkLine {
  final String prefix; // ' ', '-', or '+'
  final String content;

  HunkLine(this.prefix, this.content);
}

/// 文件内的一组更改。
class Hunk {
  String? contextHint;
  List<HunkLine> lines;

  Hunk({this.contextHint, List<HunkLine>? lines}) : lines = lines ?? [];
}

/// V4A 补丁中的单个操作。
class PatchOperation {
  OperationType operation;
  String filePath;
  String? newPath; // move 操作用
  List<Hunk> hunks;
  String? content; // add file 操作用

  PatchOperation({
    required this.operation,
    required this.filePath,
    this.newPath,
    List<Hunk>? hunks,
    this.content,
  }) : hunks = hunks ?? [];
}

/// 解析 V4A 格式补丁。
///
/// 返回 `(operations, error_message)`：
/// - 成功：`(operation_list, null)`
/// - 失败：`([], 错误描述)`
(List<PatchOperation>, String?) parseV4aPatch(String patchContent) {
  // 分割为行，容忍 CRLF 补丁体：剥离每行尾随 ``\r``。没有它，CRLF 编码补丁的
  // 每个 HunkLine.content 内部保留 ``\r``，向 LF 目标文件注入游离回车（且锚定的
  // ``...\s*$`` Begin/End 标记因尾随 ``\r`` 失败匹配）。
  final lines = patchContent.split('\n').map((ln) {
    return ln.endsWith('\r') ? ln.substring(0, ln.length - 1) : ln;
  }).toList();
  final operations = <PatchOperation>[];

  // 找补丁边界。标记必须独占整行且在第 0 列：内容行如 "+*** End Patch" 或
  // " *** End Patch"（如讲补丁格式的文档）不得截断补丁或重置起始边界。
  int? startIdx;
  int? endIdx;
  final beginMarker = RegExp(r'^\*\*\*\s*Begin\s+Patch\s*$');
  final endMarker = RegExp(r'^\*\*\*\s*End\s+Patch\s*$');
  for (var i = 0; i < lines.length; i++) {
    if (beginMarker.hasMatch(lines[i])) {
      startIdx = i;
    } else if (endMarker.hasMatch(lines[i])) {
      endIdx = i;
      break;
    }
  }

  if (startIdx == null) {
    // 尝试无显式 begin 标记解析。
    startIdx = -1;
  }

  endIdx ??= lines.length;

  // 解析边界之间的操作。
  var i = startIdx + 1;
  PatchOperation? currentOp;
  Hunk? currentHunk;

  while (i < endIdx) {
    final line = lines[i];

    final updateMatch = RegExp(r'\*\*\*\s*Update\s+File:\s*(.+)').firstMatch(line);
    final addMatch = RegExp(r'\*\*\*\s*Add\s+File:\s*(.+)').firstMatch(line);
    final deleteMatch = RegExp(r'\*\*\*\s*Delete\s+File:\s*(.+)').firstMatch(line);
    final moveMatch = RegExp(r'\*\*\*\s*Move\s+File:\s*(.+?)\s*->\s*(.+)').firstMatch(line);

    if (updateMatch != null) {
      if (currentOp != null) {
        if (currentHunk != null && currentHunk.lines.isNotEmpty) {
          currentOp.hunks.add(currentHunk);
        }
        operations.add(currentOp);
      }
      currentOp = PatchOperation(
        operation: OperationType.update,
        filePath: updateMatch.group(1)!.trim(),
      );
      currentHunk = null;
    } else if (addMatch != null) {
      if (currentOp != null) {
        if (currentHunk != null && currentHunk.lines.isNotEmpty) {
          currentOp.hunks.add(currentHunk);
        }
        operations.add(currentOp);
      }
      currentOp = PatchOperation(
        operation: OperationType.add,
        filePath: addMatch.group(1)!.trim(),
      );
      currentHunk = Hunk();
    } else if (deleteMatch != null) {
      if (currentOp != null) {
        if (currentHunk != null && currentHunk.lines.isNotEmpty) {
          currentOp.hunks.add(currentHunk);
        }
        operations.add(currentOp);
      }
      currentOp = PatchOperation(
        operation: OperationType.delete,
        filePath: deleteMatch.group(1)!.trim(),
      );
      operations.add(currentOp);
      currentOp = null;
      currentHunk = null;
    } else if (moveMatch != null) {
      if (currentOp != null) {
        if (currentHunk != null && currentHunk.lines.isNotEmpty) {
          currentOp.hunks.add(currentHunk);
        }
        operations.add(currentOp);
      }
      currentOp = PatchOperation(
        operation: OperationType.move,
        filePath: moveMatch.group(1)!.trim(),
        newPath: moveMatch.group(2)!.trim(),
      );
      operations.add(currentOp);
      currentOp = null;
      currentHunk = null;
    } else if (line.startsWith('@@')) {
      if (currentOp != null) {
        if (currentHunk != null && currentHunk.lines.isNotEmpty) {
          currentOp.hunks.add(currentHunk);
        }
        final hintMatch = RegExp(r'@@\s*(.+?)\s*@@').firstMatch(line);
        final hint = hintMatch != null ? hintMatch.group(1) : null;
        currentHunk = Hunk(contextHint: hint);
      }
    } else if (currentOp != null && line.isNotEmpty) {
      if (currentHunk == null) {
        currentHunk = Hunk();
      }
      if (line.startsWith('+')) {
        currentHunk.lines.add(HunkLine('+', line.substring(1)));
      } else if (line.startsWith('-')) {
        currentHunk.lines.add(HunkLine('-', line.substring(1)));
      } else if (line.startsWith(' ')) {
        currentHunk.lines.add(HunkLine(' ', line.substring(1)));
      } else if (line.startsWith('\\')) {
        // "\ No newline at end of file" 标记 —— 跳过。
      } else {
        // 视为 context 行（隐式空格前缀）。
        currentHunk.lines.add(HunkLine(' ', line));
      }
    }

    i++;
  }

  // 别忘了最后一个操作。
  if (currentOp != null) {
    if (currentHunk != null && currentHunk.lines.isNotEmpty) {
      currentOp.hunks.add(currentHunk);
    }
    operations.add(currentOp);
  }

  // 验证解析结果。
  if (operations.isEmpty) {
    // 空补丁不是错误 —— 调用者拿到 [] 可自行决定。
    return (operations, null);
  }

  final parseErrors = <String>[];
  for (final op in operations) {
    if (op.filePath.isEmpty) {
      parseErrors.add('Operation with empty file path');
    }
    if (op.operation == OperationType.update && op.hunks.isEmpty) {
      parseErrors.add("UPDATE '${op.filePath}': no hunks found");
    }
    if (op.operation == OperationType.move && (op.newPath == null || op.newPath!.isEmpty)) {
      parseErrors.add("MOVE '${op.filePath}': missing destination path (expected 'src -> dst')");
    }
  }

  if (parseErrors.isNotEmpty) {
    return (<PatchOperation>[], 'Parse error: ${parseErrors.join('; ')}');
  }

  return (operations, null);
}

/// 计数 *text* 中 *pattern* 的非重叠出现次数。
int _countOccurrences(String text, String pattern) {
  var count = 0;
  var start = 0;
  while (true) {
    final pos = text.indexOf(pattern, start);
    if (pos == -1) {
      break;
    }
    count++;
    start = pos + 1;
  }
  return count;
}

/// 验证所有操作而不写任何文件。
///
/// 返回错误字符串列表；空列表表示所有操作有效，apply 阶段可安全继续。
///
/// 对 UPDATE 操作，hunks 按顺序模拟，使后续 hunks 针对前序 hunk 之后的内容验证
/// （匹配 apply 顺序）。
List<String> _validateOperations(List<PatchOperation> operations, FileOperations fileOps) {
  final errors = <String>[];
  var realChangeCount = 0;

  // 虚拟文件系统 overlay，使操作间状态（尤其 MOVE 创建的、后续 UPDATE 目标
  // 的目标）正确验证。路径 → 待定内容；null 标记路径被移走/删除。
  final pendingContent = <String, String>{};
  final removedPaths = <String>{};

  String? Function(String) read = (path) {
    if (removedPaths.contains(path) && !pendingContent.containsKey(path)) {
      return 'file not found';
    }
    if (pendingContent.containsKey(path)) {
      return null;
    }
    final r = fileOps.readFileRaw(path);
    return r.error;
  };

  for (final op in operations) {
    if (op.operation != OperationType.update) {
      realChangeCount++;
    }
    if (op.operation == OperationType.update) {
      final readErr = read(op.filePath);
      if (readErr != null) {
        errors.add('${op.filePath}: $readErr');
        continue;
      }

      final pending = pendingContent[op.filePath];
      var simulated = pending ?? fileOps.readFileRaw(op.filePath).content;

      for (var hunkIndex = 0; hunkIndex < op.hunks.length; hunkIndex++) {
        final hunk = op.hunks[hunkIndex];
        final searchLines = hunk.lines
            .where((l) => l.prefix == ' ' || l.prefix == '-')
            .map((l) => l.content)
            .toList();
        final removedLines = hunk.lines
            .where((l) => l.prefix == '-')
            .map((l) => l.content)
            .toList();
        final addedLines = hunk.lines
            .where((l) => l.prefix == '+')
            .map((l) => l.content)
            .toList();
        if (removedLines.isEmpty && addedLines.isEmpty) {
          // 模型偶尔在真实更改之间发惰性锚点 hunk。忽略，不毒化原子补丁。
          continue;
        }
        realChangeCount++;
        if (searchLines.isEmpty) {
          // 仅添加 hunk：验证 context hint 唯一性。
          if (hunk.contextHint != null && hunk.contextHint!.isNotEmpty) {
            final occurrences = _countOccurrences(simulated, hunk.contextHint!);
            if (occurrences == 0) {
              errors.add(
                  "${op.filePath}: addition-only hunk context hint "
                  "'${hunk.contextHint}' not found");
            } else if (occurrences > 1) {
              errors.add(
                  "${op.filePath}: addition-only hunk context hint "
                  "'${hunk.contextHint}' is ambiguous "
                  '($occurrences occurrences)');
            }
          }
          continue;
        }

        final searchPattern = searchLines.join('\n');
        final replaceLines = hunk.lines
            .where((l) => l.prefix == ' ' || l.prefix == '+')
            .map((l) => l.content)
            .toList();
        final replacement = replaceLines.join('\n');

        final (newSimulated, count, _, matchError) = fuzzyFindAndReplace(
          simulated,
          searchPattern,
          replacement,
          replaceAll: false,
        );
        if (count == 0) {
          final label =
              hunk.contextHint != null && hunk.contextHint!.isNotEmpty
                  ? "'${hunk.contextHint}'"
                  : '(no hint)';
          var msg =
              '${op.filePath}: hunk ${hunkIndex + 1} $label not found'
              '${matchError != null ? ' — $matchError' : ''}';
          msg += formatNoMatchHint(matchError, count, searchPattern, simulated);
          errors.add(msg);
        } else {
          // 推进模拟，使后续 hunks 正确验证。
          simulated = newSimulated;
        }
      }
      pendingContent[op.filePath] = simulated;
    } else if (op.operation == OperationType.delete) {
      final readErr = read(op.filePath);
      if (readErr != null) {
        errors.add('${op.filePath}: file not found for deletion');
      } else {
        removedPaths.add(op.filePath);
        pendingContent.remove(op.filePath);
      }
    } else if (op.operation == OperationType.move) {
      if (op.newPath == null || op.newPath!.isEmpty) {
        errors.add('${op.filePath}: MOVE operation missing destination path');
        continue;
      }
      final srcErr = read(op.filePath);
      if (srcErr != null) {
        errors.add('${op.filePath}: source file not found for move');
      }
      final dstErr = read(op.newPath!);
      if (dstErr == null) {
        errors.add(
            '${op.newPath}: destination already exists — move would overwrite');
      }
      if (srcErr == null && dstErr != null) {
        final srcContent = pendingContent[op.filePath] ??
            fileOps.readFileRaw(op.filePath).content;
        pendingContent[op.newPath!] = srcContent;
        pendingContent.remove(op.filePath);
        removedPaths.add(op.filePath);
      }
    }
    // ADD：父目录创建由 write_file 处理；无需预检查。
  }

  if (errors.isEmpty && realChangeCount == 0) {
    errors.add('Patch contains no changes (only context lines were provided)');
  }

  return errors;
}

/// 应用 V4A 补丁操作，使用文件操作接口。
///
/// 两阶段 validate-then-apply：
/// - Phase 1：验证所有操作，不写任何东西。有验证错误立即返回，无文件系统更改。
/// - Phase 2：应用所有操作。此处失败（如验证与应用间竞态）带 `git diff` 提示报告。
///
/// 返回含所有操作结果的 PatchResult。
PatchResult applyV4aOperations(List<PatchOperation> operations, FileOperations fileOps) {
  // ---- Phase 1: validate ----
  final validationErrors = _validateOperations(operations, fileOps);
  if (validationErrors.isNotEmpty) {
    return PatchResult(
      success: false,
      error: 'Patch validation failed (no files were modified):\n' +
          validationErrors.map((e) => '  • $e').join('\n'),
    );
  }

  // ---- Phase 2: apply ----
  final filesModified = <String>[];
  final filesCreated = <String>[];
  final filesDeleted = <String>[];
  final allDiffs = <String>[];
  final lspBlocks = <String>[];
  final errors = <String>[];

  for (final op in operations) {
    try {
      if (op.operation == OperationType.add) {
        final (ok, diff, lsp) = _applyAdd(op, fileOps);
        if (ok) {
          filesCreated.add(op.filePath);
          allDiffs.add(diff);
          if (lsp != null) {
            lspBlocks.add(lsp);
          }
        } else {
          errors.add('Failed to add ${op.filePath}: $diff');
        }
      } else if (op.operation == OperationType.delete) {
        final (ok, diff) = _applyDelete(op, fileOps);
        if (ok) {
          filesDeleted.add(op.filePath);
          allDiffs.add(diff);
        } else {
          errors.add('Failed to delete ${op.filePath}: $diff');
        }
      } else if (op.operation == OperationType.move) {
        final (ok, diff) = _applyMove(op, fileOps);
        if (ok) {
          filesModified.add('${op.filePath} -> ${op.newPath}');
          allDiffs.add(diff);
        } else {
          errors.add('Failed to move ${op.filePath}: $diff');
        }
      } else if (op.operation == OperationType.update) {
        final (ok, diff, lsp) = _applyUpdate(op, fileOps);
        if (ok) {
          filesModified.add(op.filePath);
          allDiffs.add(diff);
          if (lsp != null) {
            lspBlocks.add(lsp);
          }
        } else {
          errors.add('Failed to update ${op.filePath}: $diff');
        }
      }
    } catch (e) {
      errors.add('Error processing ${op.filePath}: $e');
    }
  }

  // 对所有修改/创建文件跑 lint（对应 Python `hasattr(file_ops, '_check_lint')`）。
  final lintResults = <String, Map<String, dynamic>>{};
  for (final f in [...filesModified, ...filesCreated]) {
    if (fileOps is LocalFileOperations) {
      final lr = fileOps.checkLintFile(f);
      lintResults[f] = lr.toDict();
    }
  }

  final combinedDiff = allDiffs.join('\n');
  final combinedLsp = lspBlocks.isNotEmpty ? lspBlocks.join('\n\n') : null;

  if (errors.isNotEmpty) {
    return PatchResult(
      success: false,
      diff: combinedDiff,
      filesModified: filesModified,
      filesCreated: filesCreated,
      filesDeleted: filesDeleted,
      lint: lintResults.isNotEmpty ? lintResults : null,
      lspDiagnostics: combinedLsp,
      error: 'Apply phase failed (state may be inconsistent — run `git diff` to assess):\n' +
          errors.map((e) => '  • $e').join('\n'),
    );
  }

  return PatchResult(
    success: true,
    diff: combinedDiff,
    filesModified: filesModified,
    filesCreated: filesCreated,
    filesDeleted: filesDeleted,
    lint: lintResults.isNotEmpty ? lintResults : null,
    lspDiagnostics: combinedLsp,
  );
}

/// 应用 add 文件操作。
///
/// 返回 `(success, diff_or_error, lsp_diagnostics)`。第三元素携带来自
/// WriteResult.lsp_diagnostics 的格式化 `<diagnostics>` 块，使 V4A 补丁可表面
/// LSP 层语义诊断。
(bool, String, String?) _applyAdd(PatchOperation op, FileOperations fileOps) {
  // 从 hunks 提取内容（所有 + 行）。
  final contentLines = <String>[];
  for (final hunk in op.hunks) {
    for (final line in hunk.lines) {
      if (line.prefix == '+') {
        contentLines.add(line.content);
      }
    }
  }

  final content = contentLines.join('\n');

  final result = fileOps.writeFile(op.filePath, content);
  if (result.error != null) {
    return (false, result.error!, null);
  }

  final diff = '--- /dev/null\n+++ b/${op.filePath}\n' +
      contentLines.map((l) => '+$l').join('\n');

  return (true, diff, result.lspDiagnostics);
}

/// 应用 delete 文件操作。
(bool, String) _applyDelete(PatchOperation op, FileOperations fileOps) {
  // 删前读以产生真实 unified diff。验证已确认存在；此守卫防竞态。
  final readResult = fileOps.readFileRaw(op.filePath);
  if (readResult.error != null) {
    return (false, 'Cannot delete ${op.filePath}: file not found');
  }

  final result = fileOps.deleteFile(op.filePath);
  if (result.error != null) {
    return (false, result.error!);
  }

  final removedLines = _splitKeepEnds(readResult.content);
  final diff = unifiedDiff(
    removedLines,
    const <String>[],
    fromfile: 'a/${op.filePath}',
    tofile: '/dev/null',
  ).join();
  return (true, diff.isNotEmpty ? diff : '# Deleted: ${op.filePath}');
}

/// 对应 Python `str.rstrip('\n')` —— 剥离尾部换行。
String _rstripNewlines(String s) {
  var end = s.length;
  while (end > 0 && s.codeUnitAt(end - 1) == 0x0A) {
    end--;
  }
  return s.substring(0, end);
}

List<String> _splitKeepEnds(String s) {
  final lines = <String>[];
  var start = 0;
  while (true) {
    final nl = s.indexOf('\n', start);
    if (nl == -1) {
      if (start < s.length) {
        lines.add(s.substring(start));
      }
      break;
    }
    lines.add(s.substring(start, nl + 1));
    start = nl + 1;
  }
  return lines;
}

/// 应用 move 文件操作。
(bool, String) _applyMove(PatchOperation op, FileOperations fileOps) {
  final result = fileOps.moveFile(op.filePath, op.newPath!);
  if (result.error != null) {
    return (false, result.error!);
  }
  return (true, '# Moved: ${op.filePath} -> ${op.newPath}');
}

/// 应用 update 文件操作。
///
/// 返回 `(success, diff_or_error, lsp_diagnostics)` —— 第三元素理由见 _applyAdd。
(bool, String, String?) _applyUpdate(PatchOperation op, FileOperations fileOps) {
  // 读当前内容 —— 原始，无行号前缀或逐行截断。
  final readResult = fileOps.readFileRaw(op.filePath);
  if (readResult.error != null) {
    return (false, 'Cannot read file: ${readResult.error}', null);
  }

  var currentContent = readResult.content;

  // 应用每个 hunk。
  var newContent = currentContent;

  for (final hunk in op.hunks) {
    // 从 context 和 removed 行构建搜索模式。
    final searchLines = <String>[];
    final replaceLines = <String>[];

    for (final line in hunk.lines) {
      if (line.prefix == ' ') {
        searchLines.add(line.content);
        replaceLines.add(line.content);
      } else if (line.prefix == '-') {
        searchLines.add(line.content);
      } else if (line.prefix == '+') {
        replaceLines.add(line.content);
      }
    }

    if (searchLines.isNotEmpty && searchLines.join('\n') == replaceLines.join('\n')) {
      continue;
    }
    if (searchLines.isNotEmpty) {
      final searchPattern = searchLines.join('\n');
      final replacement = replaceLines.join('\n');

      var (newContent_, count, _, error) = fuzzyFindAndReplace(
        newContent,
        searchPattern,
        replacement,
        replaceAll: false,
      );
      newContent = newContent_;

      if (error != null && count == 0) {
        // 有 context hint 则尝试。
        if (hunk.contextHint != null && hunk.contextHint!.isNotEmpty) {
          final hintPos = newContent.indexOf(hunk.contextHint!);
          if (hintPos != -1) {
            // 在 hint 附近窗口搜索。
            final windowStart = hintPos - 500 < 0 ? 0 : hintPos - 500;
            final windowEnd = hintPos + 2000 < newContent.length
                ? hintPos + 2000
                : newContent.length;
            final window = newContent.substring(windowStart, windowEnd);

            final (windowNew, count2, _, error2) = fuzzyFindAndReplace(
              window,
              searchPattern,
              replacement,
              replaceAll: false,
            );

            if (count2 > 0) {
              newContent = newContent.substring(0, windowStart) +
                  windowNew +
                  newContent.substring(windowEnd);
              error = null; // 对应 Python 闭包变量重赋值。
            }
          }
        }
        if (error != null) {
          var errMsg = 'Could not apply hunk: $error';
          errMsg += formatNoMatchHint(error, 0, searchPattern, newContent);
          return (false, errMsg, null);
        }
      }
    } else {
      // 仅添加 hunk（无 context 或 removed 行）。
      // 在 context hint 指示的位置插入，或文件末尾。
      final insertText = replaceLines.join('\n');
      if (hunk.contextHint != null && hunk.contextHint!.isNotEmpty) {
        final occurrences = _countOccurrences(newContent, hunk.contextHint!);
        if (occurrences == 0) {
          newContent = _rstripNewlines(newContent) + '\n' + insertText + '\n';
        } else if (occurrences > 1) {
          return (false,
              "Addition-only hunk: context hint '${hunk.contextHint}' is ambiguous "
              '($occurrences occurrences) — provide a more unique hint',
              null);
        } else {
          final hintPos = newContent.indexOf(hunk.contextHint!);
          final eol = newContent.indexOf('\n', hintPos);
          if (eol != -1) {
            newContent = newContent.substring(0, eol + 1) +
                insertText +
                '\n' +
                newContent.substring(eol + 1);
          } else {
            newContent = newContent + '\n' + insertText;
          }
        }
      } else {
        newContent = _rstripNewlines(newContent) + '\n' + insertText + '\n';
      }
    }
  }

  // 写新内容。
  final writeResult = fileOps.writeFile(op.filePath, newContent);
  if (writeResult.error != null) {
    return (false, writeResult.error!, null);
  }

  // 生成 diff。
  final diff = unifiedDiff(
    _splitKeepEnds(currentContent),
    _splitKeepEnds(newContent),
    fromfile: 'a/${op.filePath}',
    tofile: 'b/${op.filePath}',
  ).join();

  return (true, diff, writeResult.lspDiagnostics);
}
