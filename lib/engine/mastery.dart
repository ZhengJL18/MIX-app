import 'dart:math' as math;
import '../config/config.dart';

/// 对应设计文档 3.1 综合掌握度。
///
/// [state] 需包含 complexity/understand/redundancy/coverage 四个 0~1 的键。
/// [weights] 需包含 w_complexity/w_understand/w_redundancy/w_coverage 四个键
/// （直接取自 subjects 表某一行）。
double compositeMastery(Map<String, dynamic> state, Map<String, dynamic> weights) {
  final complexity =
      ((state['complexity'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);
  final understand =
      ((state['understand'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);
  final redundancy =
      ((state['redundancy'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);
  final coverage =
      ((state['coverage'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);

  double raw =
      ((weights['w_complexity'] as num?)?.toDouble() ?? 0.4) * complexity +
          ((weights['w_understand'] as num?)?.toDouble() ?? 0.3) * understand +
          ((weights['w_redundancy'] as num?)?.toDouble() ?? 0.1) * redundancy +
          ((weights['w_coverage'] as num?)?.toDouble() ?? 0.2) * coverage;

  final worst = [complexity, understand, redundancy, coverage].reduce(math.min);
  // 短板惩罚：当最弱维度 < 0.5 时压制 raw。
  // 公式等价于 raw × (0.5 + worst)，分母硬编码 0.5 与设计文档一致，
  // 不与 weaknessThreshold 耦合以避免误改常量导致公式崩塌。
  if (worst < EngineConstants.weaknessThreshold) {
    raw *= (0.5 + worst);
  }
  return raw;
}

/// 对应设计文档 3.2 艾宾浩斯衰减。
///
/// effective = raw * e^(-daysSinceReview / S)
/// [base]/[power] 来自 subjects.ebbinghaus_base / ebbinghaus_power。
double effectiveMastery({
  required double raw,
  required double daysSinceReview,
  required int reviewCount,
  double base = 30,
  double power = 3,
}) {
  // 防护：负数天数（系统时间回拨）视为刚复习完
  final days = math.max(0, daysSinceReview);

  double s = math.max(base * math.pow(raw, power), EngineConstants.sMin) *
      math.pow(1.3, math.min(reviewCount, EngineConstants.reviewCountCap));

  if (reviewCount == 1) {
    s = math.min(
        s * EngineConstants.firstReviewMultiplier,
        EngineConstants.firstReviewCapDays);
  }
  if (days == 0) return raw;
  return raw * math.exp(-days / s);
}

/// 便捷封装：从 last_review_at (ISO8601, 可为 null) 推出距今天数。
/// 从未复习过（null）返回一个大数（999天），确保首次接触有高优先级而非与"刚复习过"混淆。
double daysSince(String? lastReviewAt) {
  if (lastReviewAt == null) return 999.0;
  final last = DateTime.tryParse(lastReviewAt);
  if (last == null) return 999.0;
  final diff = DateTime.now().toUtc().difference(last.toUtc());
  return diff.inSeconds / 86400.0;
}
