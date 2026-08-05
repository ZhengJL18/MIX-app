/// 对应 `ref/hermes-agent/agent/iteration_budget.py`（像素级复刻）。
///
/// 每 agent 迭代预算 —— 线程安全 consume/refund 计数器。
///
/// 每个 AIAgent 实例（父或子 agent）持有 IterationBudget；父上限来自
/// ``max_iterations``（默认 500），子 agent 上限来自
/// ``delegation.max_iterations``（默认 50）。
library;

/// agent 的迭代计数器。
///
/// Dart 单 isolate 无共享内存并发，Python 的 threading.Lock 简化为无锁。
class IterationBudget {
  final int maxTotal;
  int _used = 0;

  IterationBudget(this.maxTotal);

  /// 尝试消耗一次迭代。允许返回 True。
  bool consume() {
    if (_used >= maxTotal) {
      return false;
    }
    _used++;
    return true;
  }

  /// 归还一次迭代（如 execute_code turn）。
  void refund() {
    if (_used > 0) {
      _used--;
    }
  }

  int get used => _used;

  int get remaining => maxTotal - _used < 0 ? 0 : maxTotal - _used;
}
