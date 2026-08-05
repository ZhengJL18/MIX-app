/// 对应 `ref/hermes-agent/agent/retry_utils.py`（像素级复刻，核心）。
///
/// 抖动指数退避 —— 防止多个会话同时重试打到同一限流 provider 造成惊群。
library;

import 'dart:math';

Random _rng = Random();

/// 计算抖动指数退避延迟。
///
/// [attempt] 1-based 重试次数。
/// 返回秒数：min(base * 2^(attempt-1), max_delay) + jitter。
/// jitter 均匀分布在 [0, jitter_ratio * delay]，去相关并发重试。
double jitteredBackoff(
  int attempt, {
  double baseDelay = 5.0,
  double maxDelay = 120.0,
  double jitterRatio = 0.5,
}) {
  final exponent = max(0, attempt - 1);
  double delay;
  if (exponent >= 63 || baseDelay <= 0) {
    delay = maxDelay;
  } else {
    delay = min(baseDelay * pow(2, exponent), maxDelay).toDouble();
  }
  final jitter = _rng.nextDouble() * (jitterRatio * delay);
  return delay + jitter;
}

/// 解析 Retry-After 值为非负秒数（支持数字/HTTP-date/headers map）。
double? parseRetryAfterSeconds(dynamic valueOrHeaders) {
  dynamic raw = valueOrHeaders;
  if (raw != null && raw is! String && raw is! int && raw is! double) {
    // headers map。
    final getter = raw.get;
    if (getter is Function) {
      try {
        var v = getter('Retry-After');
        v ??= getter('retry-after');
        raw = v;
      } catch (_) {
        return null;
      }
    } else {
      return null;
    }
  }
  if (raw == null) {
    return null;
  }
  if (raw is bool) {
    return null;
  }
  if (raw is int || raw is double) {
    return max(0.0, raw.toDouble());
  }
  final text = raw.toString().trim();
  if (text.isEmpty) {
    return null;
  }
  final num = double.tryParse(text);
  if (num != null) {
    return max(0.0, num);
  }
  // HTTP-date 形式：RFC 7231，解析为秒数（复杂，App 场景罕见，返回 null）。
  return null;
}
