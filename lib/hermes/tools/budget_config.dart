/// 对应 `ref/hermes-agent/tools/budget_config.py`（像素级复刻）。
///
/// 工具结果持久化的可配置预算常量。
/// 每工具解析优先级：pinned > config overrides > registry > default。
library;

import 'dart:math';

import 'registry.dart';

/// 阈值永不可被覆盖的工具。
/// read_file=inf 防止无限 persist->read->persist 循环。
const Map<String, double> pinnedThresholds = {
  'read_file': double.infinity,
};

/// 与 tool_result_storage.py 当前硬编码值一致的默认值。
/// 此处是唯一事实来源；tool_result_storage.dart 导入这些常量。
const int defaultResultSizeChars = 100000;
const int defaultTurnBudgetChars = 200000;
const int defaultPreviewSizeChars = 1500;

/// 不可变预算常量，对应 3 层工具结果持久化系统：
/// Layer 2（每结果）：resolveThreshold(toolName) -> 字符阈值。
/// Layer 3（每 turn）：turnBudget -> 单个 assistant turn 内所有工具结果的字符预算。
/// Preview：previewSize -> 持久化后内联片段大小。
class BudgetConfig {
  final int defaultResultSize;
  final int turnBudget;
  final int previewSize;
  final Map<String, int> toolOverrides;

  const BudgetConfig({
    this.defaultResultSize = defaultResultSizeChars,
    this.turnBudget = defaultTurnBudgetChars,
    this.previewSize = defaultPreviewSizeChars,
    this.toolOverrides = const {},
  });

  /// 解析一个工具的持久化阈值。
  ///
  /// 优先级：pinned -> toolOverrides -> registry 每工具 -> default。
  ///
  /// registry 每工具值被 `defaultResultSize` 封顶，因此缩小的上下文预算
  /// （小模型）确实约束注册了大固定 `max_result_size_chars` 的工具
  /// （web/terminal/x_search 都注册 100K）。默认预算下这是空操作（两者都等于
  /// 100K）；缩小预算时它阻止每工具 registry 值把上限重新抬高超过模型窗口。
  num resolveThreshold(String toolName) {
    if (pinnedThresholds.containsKey(toolName)) {
      return pinnedThresholds[toolName]!;
    }
    if (toolOverrides.containsKey(toolName)) {
      return toolOverrides[toolName]!;
    }
    final registryValue = registry.getMaxResultSize(
      toolName,
      default_: defaultResultSize,
    );
    if (registryValue == double.infinity) {
      return registryValue;
    }
    return min(registryValue, defaultResultSize);
  }
}

/// 默认配置 —— 与当前硬编码行为完全一致。
const BudgetConfig defaultBudget = BudgetConfig();

/// 预算按模型上下文窗口缩放时使用的 token<->char 换算。
/// 刻意保守（较小的除数 = 每 token 更多字符 = 更大的字符预算）会 UNDER-protect
/// 小模型，因此与估算器（agent/model_metadata.py）一样使用粗略的每 token 4 字符。
const int _charsPerToken = 4;

/// 单个工具结果在超过持久化/截断前允许占据模型窗口的比例，以及整个 turn 的
/// 工具输出可能占据的比例。工具输出不是窗口里唯一的东西（系统提示、工具 schema、
/// 对话历史、模型自身回复都在竞争），所以这些保持远低于 1.0。
const double _perResultWindowFraction = 0.15;
const double _perTurnWindowFraction = 0.30;

/// 下限，即使一个极小但被接受的模型也能得到可用的 preview/result 而不是 0 字符预算。
const int _minResultSizeChars = 8000;
const int _minTurnBudgetChars = 16000;

/// 返回缩放到活动模型上下文窗口的 BudgetConfig。
///
/// 固定默认值（100K result / 200K turn 字符）对大（200K+ token）模型正确，但
/// 对小模型不敏感：在 65K-token 模型上，单个工具结果按 100K 字符阈值持久化，
/// 或 200K 字符 turn 预算（~50K token），本身就可能接近或超过整个窗口，并迫使
/// 一个超大请求。
///
/// 缩放使大模型与今天字节级一致（比例值被钳制到现有默认值作为上限），同时按比例
/// 缩小小模型的预算到其窗口，下限保证可用的 preview 始终存活。
BudgetConfig budgetForContextWindow(int? contextLength) {
  if (contextLength == null || contextLength <= 0) {
    return defaultBudget;
  }

  final windowChars = contextLength * _charsPerToken;
  var perResult = (windowChars * _perResultWindowFraction).toInt();
  var perTurn = (windowChars * _perTurnWindowFraction).toInt();

  // 钳制：永不超过历史默认（大模型不变），永不低于下限（小模型保持可用）。
  perResult = max(
    _minResultSizeChars,
    min(perResult, defaultResultSizeChars),
  );
  perTurn = max(
    _minTurnBudgetChars,
    min(perTurn, defaultTurnBudgetChars),
  );

  return BudgetConfig(
    defaultResultSize: perResult,
    turnBudget: perTurn,
    previewSize: defaultPreviewSizeChars,
  );
}
