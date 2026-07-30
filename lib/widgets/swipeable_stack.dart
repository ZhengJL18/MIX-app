import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// TikTok 式上下滑动容器 — 基于 PageView 实现
///
/// PageView 自动处理与内部 ScrollView 的手势冲突。
/// ⚠️ 不使用 viewportFraction（会导致 Expanded 崩溃），
/// peeking 效果由外层 PageView 的 physics 和 padding 实现。
class SwipeableStack extends StatefulWidget {
  final List<Widget> pages;
  final int initialIndex;
  final ValueChanged<int>? onPageChanged;

  const SwipeableStack({
    super.key,
    required this.pages,
    this.initialIndex = 0,
    this.onPageChanged,
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
    _pageCtrl = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
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
        children: widget.pages.map((page) => ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: page,
        )).toList(),
      ),
    );
  }
}

/// TikTok 风格物理参数
class _TikTokPhysics extends PageScrollPhysics {
  const _TikTokPhysics({super.parent});

  @override
  _TikTokPhysics applyTo(ScrollPhysics? ancestor) {
    return _TikTokPhysics(parent: ancestor);
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    return offset * 0.92;
  }

  @override
  double get dragStartDistanceMotionThreshold => 8.0;

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    if (position.outOfRange) {
      return SpringSimulation(
        SpringDescription.withDampingRatio(
          mass: 1,
          stiffness: 250,
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
