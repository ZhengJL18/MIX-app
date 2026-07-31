import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// 上下滑动容器 — 基于 PageView，简单可靠
///
/// 手势策略：
/// - 单指：PageView 标准垂直翻页。页面内容可滚（SingleChildScrollView）时
///   先滚内容，滚到底后继续滑动自然翻页（Flutter 嵌套滚动默认行为）。
/// - 不拦截指针：不用 Listener/AbsorbPointer，保证页面内按钮（答对/答错等）
///   正常可点。
class SwipeableStack extends StatefulWidget {
  final List<Widget> pages;
  final int initialIndex;
  final ValueChanged<int>? onPageChanged;

  /// 外部 PageController（可选）。传入后由外部控制跳页，
  /// 便于在"校验失败回跳"等场景强制回到某一页。
  final PageController? controller;

  const SwipeableStack({
    super.key,
    required this.pages,
    this.initialIndex = 0,
    this.onPageChanged,
    this.controller,
  });

  @override
  State<SwipeableStack> createState() => _SwipeableStackState();
}

class _SwipeableStackState extends State<SwipeableStack> {
  late PageController _pageCtrl;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.pages.length - 1);
    _pageCtrl = widget.controller ?? PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    // 外部传入的 controller 由外部负责释放
    if (widget.controller == null) _pageCtrl.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
    widget.onPageChanged?.call(index);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: PageView(
        controller: _pageCtrl,
        scrollDirection: Axis.vertical,
        physics: const _TikTokPhysics(),
        onPageChanged: _onPageChanged,
        children: widget.pages,
      ),
    );
  }
}

/// 轻量的翻页手感
class _TikTokPhysics extends PageScrollPhysics {
  const _TikTokPhysics({super.parent});

  @override
  _TikTokPhysics applyTo(ScrollPhysics? ancestor) {
    return _TikTokPhysics(parent: ancestor);
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    // 轻微阻尼，有"重量感"但双向一致
    return offset * 0.95;
  }

  @override
  double get dragStartDistanceMotionThreshold => 4.0;

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    if (position.outOfRange) {
      return SpringSimulation(
        SpringDescription.withDampingRatio(
          mass: 1,
          stiffness: 300,
          ratio: 0.8,
        ),
        position.pixels,
        position.pixels.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
        velocity,
        tolerance: Tolerance(velocity: 1.0),
      );
    }
    return super.createBallisticSimulation(position, velocity);
  }
}
