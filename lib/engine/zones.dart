import 'dart:math' as math;
import '../config/config.dart';

double sigmoid(double x) => 1 / (1 + math.exp(-x));

double gaussian(double x, {required double mu, required double sigma}) {
  return math.exp(-math.pow(x - mu, 2) / (2 * math.pow(sigma, 2)));
}

/// 对应设计文档 3.3：返回四个区的概率分布（归一化后总和 = 1）。
/// 顺序固定为 [攻坚, 复习, 维护, 安全]，与 [Zones.all] 一致。
Map<String, double> zoneWeights(double mastery) {
  final raw = <String, double>{
    Zones.breakthrough: sigmoid((0.5 - mastery) / 0.07),
    Zones.review: gaussian(mastery, mu: 0.6, sigma: 0.06),
    Zones.maintenance:
        sigmoid((mastery - 0.7) / 0.05) * (1 - sigmoid((mastery - 0.9) / 0.05)),
    Zones.safe: sigmoid((mastery - 0.9) / 0.05),
  };
  final total = raw.values.fold<double>(0, (a, b) => a + b);
  return raw.map((k, v) => MapEntry(k, v / total));
}

/// 确定性采样：同状态同输出。
///
/// Dart 的 `Random` 不接受任意 seed 对象，这里用 (mastery 四舍五入到 3 位小数,
/// questionIndex) 的整数哈希组合作为种子，与 Python `hash((round(mastery,3), question_index))`
/// 语义等价（同输入 -> 同输出，不要求与 Python 数值完全一致，只要求本端可重现）。
String pickZone(double mastery, int questionIndex) {
  final weights = zoneWeights(mastery);
  final roundedMastery = (mastery * 1000).round();
  final seed = _combineHash(roundedMastery, questionIndex);
  final rng = math.Random(seed);

  final keys = Zones.all;
  final cumulative = <double>[];
  double acc = 0;
  for (final k in keys) {
    acc += weights[k]!;
    cumulative.add(acc);
  }
  final r = rng.nextDouble() * acc; // acc 应该 ≈ 1.0，防御性乘一下防止浮点误差
  for (var i = 0; i < keys.length; i++) {
    if (r <= cumulative[i]) return keys[i];
  }
  return keys.last;
}

int _combineHash(int a, int b) {
  // 简单可重现的整数组合哈希（避免依赖 Object.hash 的跨版本差异）
  int h = 17;
  h = h * 31 + a;
  h = h * 31 + b;
  return h & 0x7fffffff;
}
