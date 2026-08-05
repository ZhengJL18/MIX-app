/// 全局默认参数常量。
///
/// 对应设计文档 `config.py`：所有"可改参数"的默认值都集中在这里，
/// 真正生效的数值仍然来自 SQLite `subjects` 表（每个科目可独立覆盖）。
/// 这里的常量只在新建科目 / 数据库升级填充默认行时使用。
class DefaultWeights {
  // 科目默认权重
  static const double importance = 0.4;
  static const double wComplexity = 0.4;
  static const double wUnderstand = 0.3;
  static const double wRedundancy = 0.1;
  static const double wCoverage = 0.2;
  static const double targetMastery = 0.9;
  static const double masteryInitial = 0.3;

  // 艾宾浩斯公式参数
  static const double ebbinghausBase = 30;
  static const double ebbinghausPower = 3;

  // 反馈参数
  static const double fbCorrectBonus = 0.3;
  static const double fbMainPenalty = 0.2;
  static const double fbMinorPenalty = 0.05;
}

class EngineConstants {
  /// S 的下限（约 7 小时半衰期），防止 barely-encoded 记忆瞬间归零
  static const double sMin = 0.3;

  /// review_count 的加速上限，防止 1.3^n 指数爆炸
  static const int reviewCountCap = 20;

  /// 首次复习翻倍系数与上限（天）
  static const double firstReviewMultiplier = 2.0;
  static const double firstReviewCapDays = 3.0;

  /// 短板惩罚阈值
  static const double weaknessThreshold = 0.5;

  /// 连续正确加速：streak >= streakCap 时封顶
  static const int streakCorrectCap = 4;
  static const double streakBonusPerStep = 0.15;
}

/// 错因维度
class CauseDims {
  static const String complexity = 'complexity';
  static const String understand = 'understand';
  static const String redundancy = 'redundancy';
  static const String coverage = 'coverage';

  static const List<String> all = [complexity, understand, redundancy, coverage];
}
