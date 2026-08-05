/// 对应 `ref/hermes-agent/tools/fuzzy_match.py`（像素级复刻）。
///
/// 文件操作的模糊匹配模块。
///
/// 实现多策略匹配链，稳健地查找并替换文本，容纳 LLM 生成代码中常见的
/// 空白、缩进和转义差异。
///
/// 9 层策略链（受 OpenCode 启发），按顺序尝试：
/// 1. exact —— 直接字符串比较
/// 2. line_trimmed —— 每行剥离首尾空白
/// 3. whitespace_normalized —— 多个空格/tab 折叠为单个空格
/// 4. indentation_flexible —— 完全忽略缩进差异
/// 5. escape_normalized —— `\\n` 字面量转为真实换行
/// 6. trimmed_boundary —— 只修剪首/尾行空白
/// 7. unicode_normalized —— 智能引号/破折号等 Unicode 归一化
/// 8. block_anchor —— 首+末行锚定，中间用相似度
/// 9. context_aware —— 50% 行相似度阈值
///
/// 多重出现经 replace_all 标志处理。
library;

import 'sequence_matcher.dart';

/// 匹配结果位置对 `(start, end)`。
typedef MatchSpan = (int, int);

/// 相似度策略集合：基于相似度而非精确内容，replace_all 下拒绝。
const Set<String> _similarityStrategies = {'block_anchor', 'context_aware'};

const Map<String, String> _unicodeMap = {
  '“': '"', '”': '"', // smart double quotes
  '‘': "'", '’': "'", // smart single quotes
  '—': '--', '–': '-', // em/en dashes
  '…': '...', ' ': ' ', // ellipsis and non-breaking space
  // Unicode minus sign —— 模型对使用印刷负号的文件内容打 ASCII '-'。
  '−': '-',
  // 空格分隔族（Zs）超越 NBSP。带印刷间距（en/em/thin 空格、法文窄 NBSP、
  // CJK 表意空格）的文件通过精确策略永远不匹配模型的 ASCII-space old_string，
  // 落入相似度 context_aware 回退 —— 可能选错区域并在替换时压平文件 Unicode。
  ' ': ' ', ' ': ' ', // en/em quad
  ' ': ' ', ' ': ' ', // en/em space
  ' ': ' ', ' ': ' ', ' ': ' ', // three/four/six-per-em
  ' ': ' ', ' ': ' ', // figure/punctuation space
  ' ': ' ', ' ': ' ', // thin/hair space
  ' ': ' ', // narrow no-break space
  ' ': ' ', // medium mathematical space
  '　': ' ', // ideographic (CJK full-width) space
};

String _unicodeNormalize(String text) {
  for (final e in _unicodeMap.entries) {
    text = text.replaceAll(e.key, e.value);
  }
  return text;
}

/// 请求的编辑是否已存在于文件（对齐 upstream tools/fuzzy_match.py
/// `is_already_applied`）。生产轨迹显示最常见的 patch 失败是重发一个已落地的
/// 编辑（old==new，或 old 已消失而 new 原样存在）—— 模型的意图是"让文件包含
/// 这段文本"，而它已经包含了。调用者用它把这类错误转成显式成功形状的 no-op，
/// 让模型继续而不是重读重打。
///
/// 刻意保守：
/// - new_string 必须非平凡（strip 后 >= 8 字符）—— 微小目标碰巧匹配不能掩盖
///   真正的打字错误编辑；
/// - new_string 必须**精确**出现在 content（不做模糊 —— 近似存在不能证明
///   编辑已落地）；
/// - 当 old != new 时，old_string 必须已消失（仍在说明编辑至多半落地）。
bool isAlreadyApplied(String content, String oldString, String newString) {
  if (newString.isEmpty || newString.trim().length < 8) {
    return false;
  }
  if (!content.contains(newString)) {
    return false;
  }
  if (oldString == newString) {
    return true;
  }
  return !content.contains(oldString);
}

/// 查找并替换文本，使用日益模糊的匹配策略链。
///
/// 返回 `(new_content, match_count, strategy_name, error_message)`：
/// - 成功：`(modified_content, 替换数, 用到的策略, null)`
/// - 失败：`(original_content, 0, null, 错误描述)`
(String, int, String?, String?) fuzzyFindAndReplace(
  String content,
  String oldString,
  String newString, {
  bool replaceAll = false,
}) {
  if (oldString.isEmpty) {
    return (content, 0, null, 'old_string cannot be empty');
  }

  if (oldString.trim().isEmpty) {
    // 纯空白 old_string 平凡匹配（空行、空格串等），且重复时要么在 replace_all
    // 下批量替换，要么引发难诊断的歧义错误。它从来不是有意义锚点 —— 拒绝它
    // 使调用者提供真实上下文。
    return (content, 0, null,
        'old_string is only whitespace — provide non-blank text to match');
  }

  if (oldString == newString) {
    return (content, 0, null, 'old_string and new_string are identical');
  }

  // 按顺序尝试每个匹配策略。
  final strategies = <(String, List<MatchSpan> Function(String, String))>[
    ('exact', _strategyExact),
    ('line_trimmed', _strategyLineTrimmed),
    ('whitespace_normalized', _strategyWhitespaceNormalized),
    ('indentation_flexible', _strategyIndentationFlexible),
    ('escape_normalized', _strategyEscapeNormalized),
    ('trimmed_boundary', _strategyTrimmedBoundary),
    ('unicode_normalized', _strategyUnicodeNormalized),
    ('block_anchor', _strategyBlockAnchor),
    ('context_aware', _strategyContextAware),
  ];

  for (final (strategyName, strategyFn) in strategies) {
    final matches = strategyFn(content, oldString);

    if (matches.isNotEmpty) {
      // 该策略找到匹配。
      if (matches.length > 1 && !replaceAll) {
        return (content, 0, null,
            'Found ${matches.length} matches for old_string. '
            'Provide more context to make it unique, or use replace_all=True.');
      }

      // replace_all + 相似度策略会覆盖每个近似匹配块而非精确块 —— 拒绝并让
      // 调用者把 old_string 收窄到精确策略能精确匹配的文本。
      if (replaceAll &&
          matches.length > 1 &&
          _similarityStrategies.contains(strategyName)) {
        return (content, 0, null,
            'Found ${matches.length} approximate matches via the '
            "'$strategyName' strategy; replace_all only applies to exact "
            'matches. Provide the precise text (whitespace included) so an '
            'exact/line-trimmed match can be made.');
      }

      // 转义漂移守卫：当匹配到的策略不是 `exact` 时，我们经某种归一化匹配。
      // 若 new_string 含 shell/JSON 风格转义序列（\' 或 \"）会字面写入文件，
      // 但文件匹配区域无此类序列，这几乎确定是工具调用序列化漂移 —— 模型打了
      // 撇号/引号而传输加了多余反斜杠。原样写 new_string 会损坏文件。
      if (strategyName != 'exact') {
        final driftErr = _detectEscapeDrift(content, matches, oldString, newString);
        if (driftErr != null) {
          return (content, 0, null, driftErr);
        }
      }

      // 执行替换。当匹配策略不是 `exact` 时，文件缩进可能不同于 LLM 发送的
      // old_string/new_string —— 例如 LLM 用 2 空格缩进而文件是 4 空格。按缩进
      // 差位移 new_string，使替换匹配文件实际缩进样式。
      final effectiveNew = _maybeUnescapeNewString(newString, content, matches);
      // Unicode 保留守卫：策略 7（unicode_normalized）匹配时文件有 Unicode
      // 字符（em-dashes、smart quotes、ellipsis）而 LLM 的 old/new_string 是
      // ASCII 等价物。原样写 new_string 会静默损坏文件 Unicode。
      if (strategyName == 'unicode_normalized') {
        final preserved = _preserveUnicodeInReplacement(
          content,
          matches,
          oldString,
          effectiveNew,
        );
        return (
          _applyReplacements(
            content,
            matches,
            preserved,
            oldString: strategyName != 'exact' ? oldString : null,
          ),
          matches.length,
          strategyName,
          null,
        );
      }
      final newContent = _applyReplacements(
        content,
        matches,
        effectiveNew,
        oldString: strategyName != 'exact' ? oldString : null,
      );
      return (newContent, matches.length, strategyName, null);
    }
  }

  // 无策略找到匹配。
  return (content, 0, null, 'Could not find a match for old_string in the file');
}

/// 检测 new_string 中的工具调用转义漂移工件。
///
/// 寻找 ``\\'`` 或 ``\\"`` 序列同时存在于 old_string 和 new_string（即模型把它
/// 们当"要保留的上下文"复制粘贴）但文件匹配区域没有。该模式指示传输层在
/// 撇号/引号周围插入虚假 shell 风格转义 —— 原样写 new_string 会把 ``\\'``
/// 字面插入源代码。
///
/// 检测到漂移返回错误字符串，否则 null。
String? _detectEscapeDrift(
  String content,
  List<MatchSpan> matches,
  String oldString,
  String newString,
) {
  // 廉价预检查：new_string 不含可疑转义序列则立即退出。守卫对常见正确情形免费。
  if (!newString.contains("\\'") && !newString.contains('\\"')) {
    return null;
  }

  // 聚合文件匹配区域 —— 即 new_string 将替换的部分。若可疑转义已存在其中，
  // 模型确实在保留它们（对某些语言/转义字符串有效）；接受补丁。
  final matchedRegions = matches.map((m) => content.substring(m.$1, m.$2)).join();

  for (final suspect in ["\\'", '\\"']) {
    if (newString.contains(suspect) &&
        oldString.contains(suspect) &&
        !matchedRegions.contains(suspect)) {
      final plain = suspect.substring(1); // "'" or '"'
      return 'Escape-drift detected: old_string and new_string contain '
          'the literal sequence $suspect but the matched region of '
          'the file does not. This is almost always a tool-call '
          'serialization artifact where an apostrophe or quote got '
          'prefixed with a spurious backslash. Re-read the file with '
          'read_file and pass old_string/new_string without '
          "backslash-escaping $plain characters.";
    }
  }
  return null;
}

/// 返回一行的前导空白前缀（空格/tab）。
String _leadingWhitespace(String line) {
  var i = 0;
  while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
    i++;
  }
  return line.substring(0, i);
}

/// 返回 ``text`` 中第一个有非空白内容的行。
///
/// 无此类行（text 为空或全空白）返回 null。
String? _firstMeaningfulLine(String text) {
  for (final line in text.split('\n')) {
    if (line.trim().isNotEmpty) {
      return line;
    }
  }
  return null;
}

/// 调整 ``new_string`` 使缩进匹配 ``file_region``。
///
/// 非精确模糊匹配后使用：LLM 发送的 old_string/new_string 缩进可能与文件实际
/// 不同（如工具参数 2 空格 vs 磁盘 4 空格）。模糊策略成功匹配，但原样写
/// ``new_string`` 会损坏文件缩进。
///
/// 方法：
/// 1. 对 new_string 每非空行，计算相对 old_string 最浅非空行的缩进（LLM 基础
///    缩进）。
/// 2. 锚定到文件实际基础缩进（file_region 首非空行的前导空白）。
/// 3. 重新输出每非空行为 ``file_base + (line_indent - llm_base)``。
///
/// 空行和比 LLM 基础缩进少的行直接锚定到文件基础缩进。
///
/// 无操作情形（原样返回 new_string）：
/// - file_region 或 old_string 无有意义行
/// - LLM 基础缩进等于文件基础缩进
/// - new_string 为空
String _reindentReplacement(String fileRegion, String oldString, String newString) {
  if (newString.isEmpty) {
    return newString;
  }

  final oldFirst = _firstMeaningfulLine(oldString);
  final fileFirst = _firstMeaningfulLine(fileRegion);
  if (oldFirst == null || fileFirst == null) {
    return newString;
  }

  final oldIndent = _leadingWhitespace(oldFirst);
  final fileIndent = _leadingWhitespace(fileFirst);

  if (oldIndent == fileIndent) {
    return newString;
  }

  // 重新缩进 new_string 每行。策略：用文件基础缩进前缀替换 LLM 基础缩进前缀，
  // 保留 LLM 额外添加的缩进。与 Roo Code 相同方法（multi-search-replace.ts:
  // 466-500）。保留 LLM 预期的行间*相对*嵌套，同时锚定到文件实际缩进样式。
  final outLines = <String>[];
  for (final line in newString.split('\n')) {
    if (line.trim().isEmpty) {
      // 空行：空白保持不动。
      outLines.add(line);
      continue;
    }
    final lineIndent = _leadingWhitespace(line);
    if (lineIndent.startsWith(oldIndent)) {
      // 常见情形：行有 LLM 基础缩进（可能加额外）。基础前缀换成文件基础前缀。
      final remainder = line.substring(oldIndent.length);
      outLines.add(fileIndent + remainder);
    } else {
      // 行比 LLM 基础缩进少 —— 例如 new_string 开头 dedent。锚定到文件基础。
      // 只去空格/tab（Python lstrip(" \t")），不去 NBSP/表意空格等 Unicode 空白。
      outLines.add(fileIndent + line.replaceFirst(RegExp(r'^[ \t]+'), ''));
    }
  }
  return outLines.join('\n');
}

/// 条件性地在 new_string 中取消转义 ``\\t``/``\\r``。
///
/// LLM 频繁在 JSON 工具调用参数中发送两字符序列 ``\\t``（反斜杠+t）和 ``\\r``
/// （反斜杠+r），本意是真实 tab 或 carriage-return 字节。原样写会以字面反斜杠
/// 字母对损坏 tab 缩进文件。
///
/// 仅在文件*匹配区域*实际含对应控制字符时对每个序列应用取消转义 —— 即仅当
/// 我们替换的文件区域含真实 tab 字节时才把 ``\\t`` -> tab。合法含字面两字符串
/// ``"\\t"`` 的文件（如定义 ``sep = "\\t"`` 的 Python 源码行）匹配区域是反斜杠+t
/// 而非 tab，因此保留 new_string。
///
/// ``\\n`` 刻意排除：newline 经 JSON 正确序列化，改写 backslash-n 损坏字符串
/// 字面量转义序列的频率远高于帮助。
String _maybeUnescapeNewString(
  String newString,
  String content,
  List<MatchSpan> matches,
) {
  // 廉价预检查 —— newString 不含可疑序列则退出。保持常见情形免费。
  if (!newString.contains('\\t') && !newString.contains('\\r')) {
    return newString;
  }

  final matchedRegions = matches.map((m) => content.substring(m.$1, m.$2)).join();
  var out = newString;
  if (out.contains('\\t') && matchedRegions.contains('\t')) {
    out = out.replaceAll('\\t', '\t');
  }
  if (out.contains('\\r') && matchedRegions.contains('\r')) {
    out = out.replaceAll('\\r', '\r');
  }
  return out;
}

/// 在替换字符串中保留文件中的 Unicode 字符。
///
/// 策略 7（unicode_normalized）匹配时文件有 Unicode 字符（em-dashes、smart
/// quotes、ellipsis、non-breaking spaces）而 LLM 的 old/new_string 是 ASCII
/// 等价物。原样写 new_string 会静默损坏文件 Unicode —— em-dashes 变两个连字符、
/// smart quotes 变直引号。
///
/// 通过 diff old_string→new_string 并只对文件原始文本应用实际编辑来对齐替换与
/// 文件实际 Unicode，未变部分保留原字符。
String _preserveUnicodeInReplacement(
  String content,
  List<MatchSpan> matches,
  String oldString,
  String newString,
) {
  // 聚合文件匹配区域。
  final fileRegion = matches.map((m) => content.substring(m.$1, m.$2)).join();

  // 双方归一化供比较。
  final normOld = _unicodeNormalize(oldString);
  final normFile = _unicodeNormalize(fileRegion);

  // 归一化形式不匹配，策略不应触发 —— 回退直接替换。
  if (normOld != normFile) {
    return newString;
  }

  // 为 old_string 和 file_region 从归一化空间构建位置映射回原始空间。
  // UNICODE_MAP 替换可扩展字符（em-dash → '--'），因此归一化位置不 1:1 映射
  // 原始位置。复用模块级 _buildOrigToNormMap，然后反转（同 _mapPositionsNormToOrig
  // 的反转）得到 norm→orig 查找。
  final fileOrigToNorm = _buildOrigToNormMap(fileRegion);
  final fileNormToOrig = <int, int>{};
  for (var origPos = 0; origPos < fileOrigToNorm.length - 1; origPos++) {
    final np = fileOrigToNorm[origPos];
    fileNormToOrig.putIfAbsent(np, () => origPos);
  }

  // Diff norm_old → new_string 找实际编辑。
  // opcodes 的 i*/j* 索引是码点索引（Python str 索引）——含 emoji 时与
  // Dart UTF-16 偏移不同，substring 前必须转换。
  final sm = SequenceMatcher(normOld, newString);
  final opcodes = sm.getOpcodes();
  final fileCpToUtf16 = _buildCodePointToUtf16(fileRegion);
  final newCpToUtf16 = _buildCodePointToUtf16(newString);

  // 对 file_region 应用编辑，未变区间保留 Unicode。
  final resultParts = <String>[];
  for (final (tag, i1, i2, j1, j2) in opcodes) {
    if (tag == 'equal') {
      // 保留此区间的原始 file_region 文本。
      final origStart = fileNormToOrig[i1] ?? 0;
      var origEnd = origStart;
      while (origEnd < fileRegion.length && fileOrigToNorm[origEnd] < i2) {
        origEnd++;
      }
      resultParts.add(fileRegion.substring(
        fileCpToUtf16[origStart],
        fileCpToUtf16[origEnd],
      ));
    } else if (tag == 'replace') {
      resultParts.add(newString.substring(newCpToUtf16[j1], newCpToUtf16[j2]));
    } else if (tag == 'delete') {
      // 跳过已删部分。
    } else if (tag == 'insert') {
      resultParts.add(newString.substring(newCpToUtf16[j1], newCpToUtf16[j2]));
    }
  }

  return resultParts.join();
}

/// 在给定位置应用替换。
///
/// [oldString] 非 null 表示匹配来自非精确模糊策略；替换前 [newString] 重新缩进
/// 以匹配文件实际缩进。
String _applyReplacements(
  String content,
  List<MatchSpan> matches,
  String newString, {
  String? oldString,
}) {
  // 按位置降序排序匹配 —— 从尾到头替换，保留较早匹配的位置。
  final sortedMatches = [...matches]..sort((x, y) => y.$1.compareTo(x.$1));

  var result = content;
  for (final (start, end) in sortedMatches) {
    String adjusted;
    if (oldString != null) {
      final fileRegion = content.substring(start, end);
      adjusted = _reindentReplacement(fileRegion, oldString, newString);
    } else {
      adjusted = newString;
    }
    result = result.substring(0, start) + adjusted + result.substring(end);
  }

  return result;
}

// =============================================================================
// Matching Strategies
// =============================================================================

/// 策略 1：精确字符串匹配。
List<MatchSpan> _strategyExact(String content, String pattern) {
  final matches = <MatchSpan>[];
  var start = 0;
  while (true) {
    final pos = content.indexOf(pattern, start);
    if (pos == -1) {
      break;
    }
    matches.add((pos, pos + pattern.length));
    // 越过整个匹配而非单字符，使自重叠模式（如 "aa" in "aaaa"）产生非重叠
    // 区间，匹配 str.replace() 语义。前进 1 会产生重叠匹配，在 replace_all=True
    // 下（反向顺序应用过期偏移）损坏文件。
    start = pos + pattern.length;
  }
  return matches;
}

/// 策略 2：逐行空白修剪匹配。
///
/// 匹配前修剪每行首尾空白。
List<MatchSpan> _strategyLineTrimmed(String content, String pattern) {
  // 修剪每行规范化 pattern 和 content。
  final patternLines = pattern.split('\n').map((l) => l.trim()).toList();
  final patternNormalized = patternLines.join('\n');

  final contentLines = content.split('\n');
  final contentNormalizedLines = contentLines.map((l) => l.trim()).toList();

  // 从归一化位置构建回原始位置的映射。
  return _findNormalizedMatches(
    content,
    contentLines,
    contentNormalizedLines,
    pattern,
    patternNormalized,
  );
}

/// 策略 3：多个空白折叠为单个空格。
List<MatchSpan> _strategyWhitespaceNormalized(String content, String pattern) {
  final whitespaceRe = RegExp(r'[ \t]+');
  String normalize(String s) => s.replaceAll(whitespaceRe, ' ');

  final patternNormalized = normalize(pattern);
  final contentNormalized = normalize(content);

  // 在归一化中找，映射回原始。
  final matchesInNormalized = _strategyExact(contentNormalized, patternNormalized);
  if (matchesInNormalized.isEmpty) {
    return [];
  }

  // 把位置映射回原始 content。
  return _mapNormalizedPositions(content, contentNormalized, matchesInNormalized);
}

/// 策略 4：完全忽略缩进差异。
///
/// 匹配前剥离每行所有前导空白。
List<MatchSpan> _strategyIndentationFlexible(String content, String pattern) {
  final contentLines = content.split('\n');
  final contentStrippedLines = contentLines.map((l) => l.trimLeft()).toList();
  final patternLines = pattern.split('\n').map((l) => l.trimLeft()).toList();

  return _findNormalizedMatches(
    content,
    contentLines,
    contentStrippedLines,
    pattern,
    patternLines.join('\n'),
  );
}

/// 策略 5：转义序列转成实际字符。
///
/// 处理 `\\n` -> newline、`\\t` -> tab 等。
List<MatchSpan> _strategyEscapeNormalized(String content, String pattern) {
  String unescape(String s) => s
      .replaceAll('\\n', '\n')
      .replaceAll('\\t', '\t')
      .replaceAll('\\r', '\r');

  final patternUnescaped = unescape(pattern);
  if (patternUnescaped == pattern) {
    // 无可转换转义，跳过此策略。
    return [];
  }

  return _strategyExact(content, patternUnescaped);
}

/// 策略 6：只修剪首行和末行的空白。
///
/// 模式边界有空白差异时有用。
List<MatchSpan> _strategyTrimmedBoundary(String content, String pattern) {
  final patternLines = pattern.split('\n');
  if (patternLines.isEmpty) {
    return [];
  }

  // 只修剪首和末行。
  patternLines[0] = patternLines[0].trim();
  if (patternLines.length > 1) {
    patternLines[patternLines.length - 1] = patternLines[patternLines.length - 1].trim();
  }

  final modifiedPattern = patternLines.join('\n');
  final contentLines = content.split('\n');

  // 搜索 content 中匹配块。
  final matches = <MatchSpan>[];
  final patternLineCount = patternLines.length;

  for (var i = 0; i <= contentLines.length - patternLineCount; i++) {
    final blockLines = contentLines.sublist(i, i + patternLineCount);

    // 修剪此块首末行。
    final checkLines = [...blockLines];
    checkLines[0] = checkLines[0].trim();
    if (checkLines.length > 1) {
      checkLines[checkLines.length - 1] = checkLines[checkLines.length - 1].trim();
    }

    if (checkLines.join('\n') == modifiedPattern) {
      // 找到匹配 —— 计算原始位置。
      final (startPos, endPos) = _calculateLinePositions(
        contentLines,
        i,
        i + patternLineCount,
        content.length,
      );
      matches.add((startPos, endPos));
    }
  }

  return matches;
}

/// 构建映射每个原始字符索引到其归一化索引的列表。
///
/// 因 UNICODE_MAP 替换可扩展字符（em-dash → '--'、ellipsis → '...'），归一化串
/// 可长于原始串。此映射让我们把归一化串中的位置转回原始串对应位置。
///
/// 返回长度 ``len(original) + 1`` 的列表；条目 ``i`` 是字符 ``i`` 映射到的
/// 归一化索引。
List<int> _buildOrigToNormMap(String original) {
  final result = <int>[];
  var normPos = 0;
  for (final char in original.runes) {
    result.add(normPos);
    final c = String.fromCharCode(char);
    final repl = _unicodeMap[c];
    normPos += repl != null ? repl.length : 1;
  }
  result.add(normPos); // 哨兵：最后一个字符后一位
  return result;
}

/// 返回 `original` 的码点索引 → UTF-16 偏移映射。
/// `list[k]` = 第 k 个码点（0-based）在原 UTF-16 串中的 code unit 偏移。
/// 含 emoji/CJK 扩展 B（代理对）时两者不同；BMP 字符相同。
List<int> _buildCodePointToUtf16(String original) {
  final result = <int>[];
  var utf16 = 0;
  for (final r in original.runes) {
    result.add(utf16);
    utf16 += r > 0xFFFF ? 2 : 1;
  }
  result.add(utf16); // 哨兵：串尾 UTF-16 长度
  return result;
}

/// 把归一化串中的 (start, end) 位置转换为原始位置。
///
/// 返回值是**码点索引**（对齐 Python str 索引）；调用方需经
/// [_buildCodePointToUtf16] 转 UTF-16 偏移后才能 substring。当前调用方
/// [_strategyUnicodeNormalized] 返回前已转换。
List<MatchSpan> _mapPositionsNormToOrig(
  List<int> origToNorm,
  List<MatchSpan> normMatches,
) {
  // 反转映射：norm_pos -> 拥有该 norm_pos 的第一个原始位置。
  final normToOrigStart = <int, int>{};
  for (var origPos = 0; origPos < origToNorm.length - 1; origPos++) {
    final normPos = origToNorm[origPos];
    normToOrigStart.putIfAbsent(normPos, () => origPos);
  }

  final results = <MatchSpan>[];
  final origLen = origToNorm.length - 1; // 原始字符数

  for (final (normStart, normEnd) in normMatches) {
    if (!normToOrigStart.containsKey(normStart)) {
      continue;
    }
    final origStart = normToOrigStart[normStart]!;

    // 向前走到 origToNorm[origEnd] >= normEnd。
    var origEnd = origStart;
    while (origEnd < origLen && origToNorm[origEnd] < normEnd) {
      origEnd++;
    }

    results.add((origStart, origEnd));
  }

  return results;
}

/// 策略 7：Unicode 归一化。
///
/// 在 *content* 和 *pattern* 两边把 smart quotes、em/en-dashes、ellipsis 和
/// non-breaking spaces 归一化为 ASCII 等价物，然后对归一化副本运行 exact 和
/// line_trimmed 匹配。
///
/// 位置经 ``_buildOrigToNormMap`` 映射回*原始*串 —— 必要因为部分 UNICODE_MAP
/// 替换把单个字符扩展成多个 ASCII 字符，使朴素位置拷贝不正确。
List<MatchSpan> _strategyUnicodeNormalized(String content, String pattern) {
  // 两边归一化。任一方（或双方）可带 unicode 变体 —— 如 content 有 em-dash
  // 应匹配 LLM 的 ASCII '--'，或反之。仅在双方都不变时跳过。
  final normPattern = _unicodeNormalize(pattern);
  final normContent = _unicodeNormalize(content);
  if (normContent == content && normPattern == pattern) {
    return [];
  }

  var normMatches = _strategyExact(normContent, normPattern);
  if (normMatches.isEmpty) {
    normMatches = _strategyLineTrimmed(normContent, normPattern);
  }

  if (normMatches.isEmpty) {
    return [];
  }

  final origToNorm = _buildOrigToNormMap(content);
  final codePointSpans = _mapPositionsNormToOrig(origToNorm, normMatches);
  // 码点索引 → UTF-16 偏移（Dart substring 需要）。
  final cpToUtf16 = _buildCodePointToUtf16(content);
  return [
    for (final (s, e) in codePointSpans)
      (cpToUtf16[s], cpToUtf16[e]),
  ];
}

/// 策略 8：按首末行锚定匹配。
///
/// 用宽松阈值和 unicode 归一化调整。
List<MatchSpan> _strategyBlockAnchor(String content, String pattern) {
  // 比较双方归一化，同时保留原始 content 用于偏移计算。
  final normPattern = _unicodeNormalize(pattern);
  final normContent = _unicodeNormalize(content);

  final patternLines = normPattern.split('\n');
  if (patternLines.length < 2) {
    return [];
  }

  final firstLine = patternLines.first.trim();
  final lastLine = patternLines.last.trim();

  // 用归一化行做匹配逻辑。
  final normContentLines = normContent.split('\n');
  // 但用原始行计算 start/end 位置防止索引偏移。
  final origContentLines = content.split('\n');

  final patternLineCount = patternLines.length;

  final potentialMatches = <int>[];
  for (var i = 0; i <= normContentLines.length - patternLineCount; i++) {
    if (normContentLines[i].trim() == firstLine &&
        normContentLines[i + patternLineCount - 1].trim() == lastLine) {
      potentialMatches.add(i);
    }
  }

  final matches = <MatchSpan>[];
  final candidateCount = potentialMatches.length;

  // 阈值逻辑：唯一匹配 0.50，多候选 0.70。此前值（0.10 / 0.30）危险地宽松 ——
  // 10% 中间段相似度可能匹配完全不相关的块。
  final threshold = candidateCount == 1 ? 0.50 : 0.70;

  for (final i in potentialMatches) {
    double similarity;
    if (patternLineCount <= 2) {
      similarity = 1.0;
    } else {
      // 比较归一化中间段。
      final contentMiddle =
          normContentLines.sublist(i + 1, i + patternLineCount - 1).join('\n');
      final patternMiddle = patternLines.sublist(1, patternLineCount - 1).join('\n');
      similarity = SequenceMatcher(contentMiddle, patternMiddle).ratio();
    }

    if (similarity >= threshold) {
      // 用 ORIGINAL 行计算位置，确保文件中的正确字符偏移。
      final (startPos, endPos) = _calculateLinePositions(
        origContentLines,
        i,
        i + patternLineCount,
        content.length,
      );
      matches.add((startPos, endPos));
    }
  }

  return matches;
}

/// 策略 9（最后手段）：锚定逐行相似度。
///
/// 只考虑首末行都紧密匹配模式首末行的块（锚定预过滤），然后要求每条非空模式行
/// 与对齐内容行高度相似（>=0.80）。锚定过滤使这不会成为每次 miss 的 O(file ×
/// pattern) 扫描，而全行要求阻止单条巧合行匹配静默替换无关块（旧 50%-of-lines
/// 阈值接受半垃圾模式并破坏不匹配行）。
List<MatchSpan> _strategyContextAware(String content, String pattern) {
  final patternLines = pattern.split('\n');
  final contentLines = content.split('\n');

  if (patternLines.isEmpty) {
    return [];
  }

  final patternLineCount = patternLines.length;
  if (patternLineCount > contentLines.length) {
    return [];
  }

  // 锚定预过滤：仅当块首末行强匹配模式首末行时才是候选。这是避免对文件每个
  // 窗口打分的廉价门。
  final firstPat = patternLines.first.trim();
  final lastPat = patternLines.last.trim();
  const anchorThreshold = 0.80;

  double sim(String a, String b) {
    if (a == b) {
      return 1.0;
    }
    return SequenceMatcher(a, b).ratio();
  }

  final matches = <MatchSpan>[];
  for (var i = 0; i <= contentLines.length - patternLineCount; i++) {
    final blockLines = contentLines.sublist(i, i + patternLineCount);

    // 先廉价锚点检查 —— 不评分内部即跳过非候选窗口。
    if (sim(firstPat, blockLines.first.trim()) < anchorThreshold) {
      continue;
    }
    if (sim(lastPat, blockLines.last.trim()) < anchorThreshold) {
      continue;
    }

    // 候选：要求每条非空模式行紧密匹配其对齐内容行。一条垃圾行即不合格。
    var allMatch = true;
    for (var k = 0; k < patternLineCount; k++) {
      final pStripped = patternLines[k].trim();
      if (pStripped.isEmpty) {
        continue; // 空模式行不约束匹配。
      }
      if (sim(pStripped, blockLines[k].trim()) < 0.80) {
        allMatch = false;
        break;
      }
    }

    if (allMatch) {
      final (startPos, endPos) = _calculateLinePositions(
        contentLines,
        i,
        i + patternLineCount,
        content.length,
      );
      matches.add((startPos, endPos));
    }
  }

  return matches;
}

// =============================================================================
// Helper Functions
// =============================================================================

/// 从行索引计算开始和结束字符位置。
///
/// [contentLines] 无换行符的行列表；[startLine] 起始行索引（0-based）；
/// [endLine] 结束行索引（exclusive，0-based）；[contentLength] 原始 content 串
/// 总长。返回原始 content 中的 (start_pos, end_pos)。
(int, int) _calculateLinePositions(
  List<String> contentLines,
  int startLine,
  int endLine,
  int contentLength,
) {
  var startPos = 0;
  for (var i = 0; i < startLine; i++) {
    startPos += contentLines[i].length + 1;
  }
  var endPos = 0;
  for (var i = 0; i < endLine; i++) {
    endPos += contentLines[i].length + 1;
  }
  endPos -= 1;
  endPos = endPos < contentLength ? endPos : contentLength;
  return (startPos, endPos);
}

/// 在归一化 content 中找匹配并映射回原始位置。
List<MatchSpan> _findNormalizedMatches(
  String content,
  List<String> contentLines,
  List<String> contentNormalizedLines,
  String pattern,
  String patternNormalized,
) {
  final patternNormLines = patternNormalized.split('\n');
  final numPatternLines = patternNormLines.length;

  final matches = <MatchSpan>[];

  for (var i = 0; i <= contentNormalizedLines.length - numPatternLines; i++) {
    // 检查此块是否匹配。
    final block = contentNormalizedLines
        .sublist(i, i + numPatternLines)
        .join('\n');

    if (block == patternNormalized) {
      // 找到匹配 —— 计算原始位置。
      final (startPos, endPos) = _calculateLinePositions(
        contentLines,
        i,
        i + numPatternLines,
        content.length,
      );
      matches.add((startPos, endPos));
    }
  }

  return matches;
}

/// 把归一化串中的位置映射回原始。
///
/// 这是对空白归一化有效的 best-effort 映射。
List<MatchSpan> _mapNormalizedPositions(
  String original,
  String normalized,
  List<MatchSpan> normalizedMatches,
) {
  if (normalizedMatches.isEmpty) {
    return [];
  }

  // 从归一化构建字符映射到原始：orig_to_norm[i] = normalized 中的位置。
  final origToNorm = <int>[];
  var origIdx = 0;
  var normIdx = 0;

  while (origIdx < original.length && normIdx < normalized.length) {
    if (original.codeUnitAt(origIdx) == normalized.codeUnitAt(normIdx)) {
      origToNorm.add(normIdx);
      origIdx++;
      normIdx++;
    } else if ((original[origIdx] == ' ' || original[origIdx] == '\t') &&
        normalized[normIdx] == ' ') {
      // 原始有空格/tab，归一化折叠为空格。
      origToNorm.add(normIdx);
      origIdx++;
      // 尚未前进 normIdx —— 等所有空白消费完。
      if (origIdx < original.length &&
          original[origIdx] != ' ' &&
          original[origIdx] != '\t') {
        normIdx++;
      }
    } else if (original[origIdx] == ' ' || original[origIdx] == '\t') {
      // 原始中有多余空白。
      origToNorm.add(normIdx);
      origIdx++;
    } else {
      // 不匹配 —— 按我们的归一化不应发生。
      origToNorm.add(normIdx);
      origIdx++;
    }
  }

  // 填充剩余。
  while (origIdx < original.length) {
    origToNorm.add(normalized.length);
    origIdx++;
  }

  // 反转映射：每个归一化位置，找原始范围。
  final normToOrigStart = <int, int>{};
  final normToOrigEnd = <int, int>{};
  for (var origPos = 0; origPos < origToNorm.length; origPos++) {
    final normPos = origToNorm[origPos];
    normToOrigStart.putIfAbsent(normPos, () => origPos);
    normToOrigEnd[normPos] = origPos;
  }

  // 映射匹配。
  final originalMatches = <MatchSpan>[];
  for (final (normStart, normEnd) in normalizedMatches) {
    // 找原始 start。
    late int origStart;
    if (normToOrigStart.containsKey(normStart)) {
      origStart = normToOrigStart[normStart]!;
    } else {
      // 找最近的。
      origStart = origToNorm.indexWhere((n) => n >= normStart);
    }

    // 找原始 end。
    late int origEnd;
    if (normToOrigEnd.containsKey(normEnd - 1)) {
      origEnd = normToOrigEnd[normEnd - 1]! + 1;
    } else {
      origEnd = origStart + (normEnd - normStart);
    }

    // 展开包含被归一化的尾随空白，但仅当归一化匹配本身以空白结束。
    // 当匹配以非空格字符结束时，原始中的第一个空白是词边界，不得消费。
    if (normEnd < normalized.length && normalized[normEnd - 1] == ' ') {
      while (origEnd < original.length &&
          (original[origEnd] == ' ' || original[origEnd] == '\t')) {
        origEnd++;
      }
    }

    originalMatches.add((origStart, origEnd < original.length ? origEnd : original.length));
  }

  return originalMatches;
}

/// 找 content 中最相似于 old_string 的行，用于 "did you mean?" 反馈。
///
/// 返回带上下文的最近匹配行格式化字符串，无有用匹配返回空串。
String findClosestLines(
  String oldString,
  String content, {
  int contextLines = 2,
  int maxResults = 3,
}) {
  if (oldString.isEmpty || content.isEmpty) {
    return '';
  }

  final oldLines = oldString.split('\n');
  final contentLines = content.split('\n');

  if (oldLines.isEmpty || contentLines.isEmpty) {
    return '';
  }

  // 用 old_string 首行作为搜索锚点。
  var anchor = oldLines.first.trim();
  if (anchor.isEmpty) {
    // 首行为空则试第二行。
    final candidates = oldLines.where((l) => l.trim().isNotEmpty).toList();
    if (candidates.isEmpty) {
      return '';
    }
    anchor = candidates.first.trim();
  }

  // 按与锚点相似度给 content 每行打分。
  final scored = <(double, int)>[];
  for (var i = 0; i < contentLines.length; i++) {
    final stripped = contentLines[i].trim();
    if (stripped.isEmpty) {
      continue;
    }
    final ratio = SequenceMatcher(anchor, stripped).ratio();
    if (ratio > 0.3) {
      scored.add((ratio, i));
    }
  }

  if (scored.isEmpty) {
    return '';
  }

  // 取最高匹配。
  scored.sort((x, y) => y.$1.compareTo(x.$1));
  final top = scored.take(maxResults).toList();

  final parts = <String>[];
  final seenRanges = <(int, int)>{};
  for (final (_, lineIdx) in top) {
    final start = lineIdx - contextLines < 0 ? 0 : lineIdx - contextLines;
    var end = lineIdx + oldLines.length + contextLines;
    // Python: min(len(content_lines), ...) —— clamp 防越界。
    if (end > contentLines.length) {
      end = contentLines.length;
    }
    final key = (start, end);
    if (seenRanges.contains(key)) {
      continue;
    }
    seenRanges.add(key);
    final snippet = [
      for (var j = 0; j < end - start; j++)
        '${(start + j + 1).toString().padLeft(4)}| ${contentLines[start + j]}',
    ].join('\n');
    parts.add(snippet);
  }

  if (parts.isEmpty) {
    return '';
  }

  return parts.join('\n---\n');
}

/// 对普通 no-match 错误返回 '\n\nDid you mean...' 片段。
///
/// 门控使提示只在实际 "old_string not found" 失败时触发。歧义匹配
/// （"Found N matches"）、转义漂移、identical-strings 错误都有
/// ``match_count == 0`` 但 "did you mean?" 片段会误导 —— 那些因无关原因失败。
///
/// 无有用可附加内容返回空串。
String formatNoMatchHint(
  String? error,
  int matchCount,
  String oldString,
  String content,
) {
  if (matchCount != 0) {
    return '';
  }
  if (error == null || !error.startsWith('Could not find')) {
    return '';
  }
  final hint = findClosestLines(oldString, content);
  if (hint.isEmpty) {
    return '';
  }
  return '\n\nDid you mean one of these sections?\n$hint';
}
