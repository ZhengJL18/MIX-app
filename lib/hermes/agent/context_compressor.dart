/// 对应 `ref/hermes-agent/agent/context_compressor.py`（像素级复刻，核心逻辑）。
///
/// 上下文压缩：长对话时用 LLM 摘要中间段，防止上下文爆掉（手机内存刚需）。
///
/// ## 算法（对齐 Hermes compress）
/// 1. 修剪旧工具结果（廉价预遍，无 LLM 调用）。
/// 2. 保护头消息（system prompt + 首批用户消息）。
/// 3. 按 token 预算找尾边界（~20K token 近期上下文）。
/// 4. 中间轮次用 LLM 总结（手机版用主 LLM，Hermes 用 aux LLM）。
///
/// ## Dart 适配
/// - 消息结构：Hermes 处理 Anthropic parts/图片；手机 App OpenAI 文本消息，
///   简化为 role/content 文本。
/// - token 估算：Hermes 用 model_metadata；手机版粗略 4 chars/token（同预算
///   估算器注释）。
/// - 图片剥离/skill 标记：App 无图片/技能，省略。
library;

/// 粗略 token 估算：每 token 约 4 字符。
int estimateTokens(String text) {
  return (text.length / 4).ceil();
}

/// 消息 token 估算。
int estimateMessagesTokens(List<Map<String, dynamic>> messages) {
  var total = 0;
  for (final m in messages) {
    final content = m['content'];
    if (content is String) {
      total += estimateTokens(content);
    }
  }
  return total;
}

/// 上下文压缩器。
class ContextCompressor {
  /// 模型上下文窗口（token）。
  final int contextLength;

  /// 压缩阈值百分比（Hermes 默认 0.75）。
  final double thresholdPercent;

  /// 压缩时保护的头消息数（system prompt 外）。
  final int protectFirstN;

  /// 尾部保留的 token 预算（Hermes tail_token_budget）。
  final int tailTokenBudget;

  /// 摘要 LLM 调用器：传入中间消息，返回摘要文本。
  final Future<String> Function(List<Map<String, dynamic>> middleMessages)
      summarizer;

  /// 已压缩次数（protect_first_n 衰减用）。
  int compressionCount = 0;

  /// 最近两次压缩节省比例（防抖动）。
  final List<double> _recentSavings = [];

  /// 测试辅助：模拟一次低节省压缩（防抖动判定用）。
  void simulateLowSavings() {
    _recentSavings.add(0.05);
    if (_recentSavings.length > 4) {
      _recentSavings.removeAt(0);
    }
  }

  ContextCompressor({
    required this.contextLength,
    this.thresholdPercent = 0.75,
    this.protectFirstN = 3,
    this.tailTokenBudget = 20000,
    required this.summarizer,
  });

  /// 压缩阈值（token）。地板：不低于 context 的阈值百分比值。
  int get thresholdTokens {
    final pct = contextLength * thresholdPercent;
    // MINIMUM_CONTEXT_LENGTH 地板（Hermes ~1000 token 小窗口处理）。
    return pct.toInt() < 1000 ? 1000 : pct.toInt();
  }

  /// 是否应压缩。
  bool shouldCompress(int? promptTokens) {
    final tokens = promptTokens ?? 0;
    if (tokens < thresholdTokens) {
      return false;
    }
    // 防抖动：最近两次压缩各省 <10% 则跳过。
    if (_recentSavings.length >= 2 &&
        _recentSavings.skip(_recentSavings.length - 2).every((s) => s < 0.10)) {
      return false;
    }
    return true;
  }

  /// 有效保护头大小（首次压缩后衰减为仅 system prompt）。
  int _effectiveProtectFirstN() {
    return compressionCount == 0 ? protectFirstN : 0;
  }

  int _protectHeadSize(List<Map<String, dynamic>> messages) {
    var head = 0;
    if (messages.isNotEmpty && messages.first['role'] == 'system') {
      head = 1;
    }
    return head + _effectiveProtectFirstN();
  }

  /// 压缩对话：修剪旧工具结果 + 保护头尾 + 中间 LLM 摘要。
  ///
  /// 返回压缩后的消息列表。中间段被 `{role: user, content: <summary>}` 替换。
  Future<List<Map<String, dynamic>>> compress(
    List<Map<String, dynamic>> messages,
  ) async {
    if (messages.length <= _protectHeadSize(messages) + 3) {
      return messages; // 消息太少，不值得压缩。
    }

    // 1. 修剪旧工具结果：保留最近 10 条 tool 消息。
    final pruned = <Map<String, dynamic>>[];
    var recentToolResults = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m['role'] == 'tool') {
        if (recentToolResults >= 10) {
          continue; // 丢弃过旧的工具结果。
        }
        recentToolResults++;
      }
      pruned.insert(0, m);
    }
    final working = pruned;

    final headSize = _protectHeadSize(working);
    if (working.length <= headSize + 3) {
      return working;
    }

    // 2. 找尾边界：从尾部累计 token 直到 tailTokenBudget。
    var tailTokens = 0;
    var tailStart = working.length;
    for (var i = working.length - 1; i >= headSize; i--) {
      tailTokens += estimateMessagesTokens([working[i]]);
      tailStart = i;
      if (tailTokens >= tailTokenBudget) {
        break;
      }
    }
    // 尾至少保留 3 条。
    if (working.length - tailStart < 3) {
      tailStart = working.length - 3;
    }

    // 3. 中间段（headSize..tailStart）总结。
    final middle = working.sublist(headSize, tailStart);
    if (middle.isEmpty) {
      return working;
    }

    String summary;
    try {
      summary = await summarizer(middle);
    } catch (_) {
      return working; // 摘要失败 → 保持原样（fail-safe）。
    }
    if (summary.trim().isEmpty) {
      return working;
    }

    // 4. 重组：head + [summary 消息] + tail。
    final head = working.sublist(0, headSize);
    final tail = working.sublist(tailStart);
    final beforeTokens = estimateMessagesTokens(working);
    final result = <Map<String, dynamic>>[
      ...head,
      {
        'role': 'user',
        'content':
            '[Compressed summary of earlier conversation]\n\n$summary',
      },
      ...tail,
    ];
    final afterTokens = estimateMessagesTokens(result);
    final savings = beforeTokens > 0
        ? (beforeTokens - afterTokens) / beforeTokens
        : 0.0;
    _recentSavings.add(savings);
    if (_recentSavings.length > 4) {
      _recentSavings.removeAt(0);
    }
    compressionCount++;
    return result;
  }
}
