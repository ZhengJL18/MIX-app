/// 提示词翻译器：将 0~1 四维系数翻译成 AI 能理解的具象描述。
///
/// 职责：不修改数据，只做"数字 → 自然语言"的映射。
/// Dart 版供 Flutter 运行时使用；同名 Python 脚本（prompt_translator.py）
/// 提供完全一致的逻辑，可独立运行或集成到数据 pipeline。
class PromptTranslator {
  PromptTranslator({
    required this.complexity,
    required this.understand,
    required this.redundancy,
    required this.coverage,
  });

  final double complexity;   // 步骤复杂度 0~1
  final double understand;   // 理解难度 0~1
  final double redundancy;   // 信息冗余度 0~1
  final double coverage;     // 知识覆盖率 0~1

  /// 返回所有维度的完整描述，适合拼入 system prompt。
  String describeAll() {
    return [
      _dimLine('处理步骤复杂度', complexity, _complexityLevel),
      _dimLine('概念理解难度', understand, _understandLevel),
      _dimLine('信息冗余度', redundancy, _redundancyLevel),
      _dimLine('知识覆盖率', coverage, _coverageLevel),
    ].join('\n');
  }

  /// 返回四维摘要（紧凑单行）
  String summary() {
    return '复杂度${complexity.toStringAsFixed(2)} · '
        '理解${understand.toStringAsFixed(2)} · '
        '冗余${redundancy.toStringAsFixed(2)} · '
        '覆盖${coverage.toStringAsFixed(2)}';
  }

  String _dimLine(String label, double value, String Function(double) levelFn) {
    return '- $label：${value.toStringAsFixed(2)}（${levelFn(value)}）';
  }

  /// ── 复杂度（处理步骤数量、嵌套深度） ──
  static String _complexityLevel(double v) {
    if (v >= 0.85) return '极高：需要 5 个以上关键推理节点，涉及多步嵌套、中间结果传递或分支处理，学生必须能维护完整的解题链';
    if (v >= 0.65) return '较高：需要 3-4 个关键步骤，涉及中等程度的逻辑嵌套或中间计算';
    if (v >= 0.40) return '中等：2-3 步可解，步骤链短，不需要长时间的工作记忆维持';
    if (v >= 0.20) return '较低：1-2 步直接推理，几乎不需要中间状态';
    return '极低：单步直接得出，无嵌套无分支';
  }

  /// ── 理解难度（概念抽象程度、公式复杂度） ──
  static String _understandLevel(double v) {
    if (v >= 0.85) return '极高：需要深层概念理解，涉及抽象定理、多步推导证明或跨章节知识迁移';
    if (v >= 0.65) return '较高：需要理解核心定理的适用条件，涉及公式变形或中等推理';
    if (v >= 0.40) return '中等：需要基本概念理解，套用标准公式即可解答';
    if (v >= 0.20) return '较低：只需识别概念和直接应用定义';
    return '极低：考查基本术语认知，无需深度理解';
  }

  /// ── 冗余度（干扰信息密度、无关条件比例） ──
  static String _redundancyLevel(double v) {
    if (v >= 0.85) return '极高：题目包含大量无关条件/干扰信息，学生需要从噪声中筛选关键数据';
    if (v >= 0.65) return '较高：包含中等程度干扰项，部分条件多余但不过分隐蔽';
    if (v >= 0.40) return '中等：少数干扰信息，大部分条件直接有用';
    if (v >= 0.20) return '较低：题干简洁，几乎无冗余信息';
    return '极低：条件极少且全部直接相关';
  }

  /// ── 覆盖率（跨知识点综合程度） ──
  static String _coverageLevel(double v) {
    if (v >= 0.85) return '极高：需要综合运用多个章节/模块的知识点，跨领域联系';
    if (v >= 0.65) return '较高：涉及该章节内 2-3 个知识点的综合运用';
    if (v >= 0.40) return '中等：主要考查当前知识点，可能涉及前置依赖概念';
    if (v >= 0.20) return '较低：聚焦单一知识点，不涉及知识迁移';
    return '极低：考查单一子概念的最基础层面';
  }
}
