import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// TikTok 式上下滑动容器 — 单指内容滚动优先，双指全局翻页
///
/// 手势策略：
/// - 单指：PageView 正常处理。页面内容可滚（SingleChildScrollView）时先滚内容，
///   滚到底后继续下滑自然翻页（Flutter 嵌套滚动默认行为）。
/// - 双指：强制全局翻页，无视页内滚动。检测到第二根手指落下时，
///   立即把 PageView 替换成手动翻页 Stack（中止已开始的单指滚动），
///   双手跟手拖动，放手按位移翻页或回弹。
///
/// 为什么用 Listener 检测双指：Listener 不参与手势竞技场，
/// 不会抢 PageView 的单指手势；只负责在指针层追踪数量。
class SwipeableStack extends StatefulWidget {
  final List<Widget> pages;
  final int initialIndex;
  final ValueChanged<int>? onPageChanged;

  /// 双指翻页的位移阈值（页面高度比例，0~1）
  final double twoFingerThreshold;

  const SwipeableStack({
    super.key,
    required this.pages,
    this.initialIndex = 0,
    this.onPageChanged,
    this.twoFingerThreshold = 0.3,
  });

  @override
  State<SwipeableStack> createState() => _SwipeableStackState();
}

class _SwipeableStackState extends State<SwipeableStack>
    with SingleTickerProviderStateMixin {
  late PageController _pageCtrl;
  int _currentIndex = 0;

  // ── 双指翻页状态 ──
  final Map<int, Offset> _pointerPos = {};
  bool _twoFingerMode = false;
  double _twoFingerDy = 0;

  late final AnimationController _twCtrl;
  Animation<double>? _twAnim;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.pages.length - 1);
    _pageCtrl = PageController(initialPage: _currentIndex);
    _twCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _twCtrl.addListener(() {
      final v = _twAnim?.value ?? _twoFingerDy;
      if (v != _twoFingerDy) {
        setState(() => _twoFingerDy = v);
      }
    });
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _twCtrl.dispose();
    super.dispose();
  }

  bool get _canGoUp => _currentIndex > 0;
  bool get _canGoDown => _currentIndex < widget.pages.length - 1;

  /// 双指模式或收尾动画中 → 显示手动翻页 Stack
  bool get _showManualStack => _twoFingerMode || _twCtrl.isAnimating;

  // ── 指针追踪 ──

  void _onPointerDown(PointerDownEvent e) {
    _pointerPos[e.pointer] = e.position;
    if (_pointerPos.length >= 2 && !_twoFingerMode && !_twCtrl.isAnimating) {
      // 第二根手指落下 → 进入双指模式
      // 用 PageView 当前真实页（可能是拖动中的小数）取整
      final p = _pageCtrl.page;
      if (p != null) _currentIndex = p.round().clamp(0, widget.pages.length - 1);
      _twoFingerMode = true;
      _twoFingerDy = 0;
      setState(() {});
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    final prev = _pointerPos[e.pointer];
    if (prev == null) return;
    final deltaY = e.position.dy - prev.dy;
    _pointerPos[e.pointer] = e.position;
    if (_twoFingerMode) {
      // 两根手指各自移动都会触发 → 取均值，避免位移翻倍
      setState(() => _twoFingerDy += deltaY / _pointerPos.length);
    }
  }

  void _onPointerEnd(PointerEvent e) {
    if (!_pointerPos.containsKey(e.pointer)) return;
    _pointerPos.remove(e.pointer);
    if (_pointerPos.length < 2 && _twoFingerMode) {
      _finishTwoFingerSwipe();
      _twoFingerMode = false;
      setState(() {});
    }
  }

  void _finishTwoFingerSwipe() {
    final h = MediaQuery.of(context).size.height;
    final ratio = _twoFingerDy / h;
    final startDy = _twoFingerDy;

    int targetIndex = _currentIndex;
    if (ratio > widget.twoFingerThreshold) {
      targetIndex++;
    } else if (ratio < -widget.twoFingerThreshold) {
      targetIndex--;
    }
    targetIndex = targetIndex.clamp(0, widget.pages.length - 1);

    final targetDy = targetIndex > _currentIndex
        ? h
        : targetIndex < _currentIndex
            ? -h
            : 0.0;

    _twoFingerMode = false;
    if (startDy == targetDy) {
      _twoFingerDy = 0;
      setState(() {});
      return;
    }

    _twAnim = Tween<double>(begin: startDy, end: targetDy).animate(
      CurvedAnimation(parent: _twCtrl, curve: Curves.easeOutCubic),
    );
    _twCtrl.forward(from: 0).then((_) {
      _twoFingerDy = 0;
      if (targetIndex != _currentIndex) {
        _currentIndex = targetIndex;
        _pageCtrl.jumpToPage(targetIndex);
        widget.onPageChanged?.call(targetIndex);
      }
      setState(() {});
    });
  }

  void _onPageChanged(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
    widget.onPageChanged?.call(index);
  }

  // ── 构建 ──

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: _showManualStack ? _buildManualStack() : _buildPageView(),
    );
  }

  Widget _buildPageView() {
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

  /// 双指模式的手动翻页层
  Widget _buildManualStack() {
    final h = MediaQuery.of(context).size.height;
    final dy = _twoFingerDy;
    const peek = 16.0;

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 下一页：双指下滑（dy>0）时从下方进入
          if (_canGoDown && dy > 0)
            Positioned(
              top: h + dy - peek,
              left: 0,
              right: 0,
              height: h + peek,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                child: widget.pages[_currentIndex + 1],
              ),
            ),
          // 上一页：双指上滑（dy<0）时从上方进入
          if (_canGoUp && dy < 0)
            Positioned(
              top: dy - h + peek,
              left: 0,
              right: 0,
              height: h + peek,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
                child: widget.pages[_currentIndex - 1],
              ),
            ),
          // 当前页跟手移动（AbsorbPointer 防止页内滚动干扰双指翻页）
          Transform.translate(
            offset: Offset(0, dy),
            child: AbsorbPointer(child: widget.pages[_currentIndex]),
          ),
        ],
      ),
    );
  }
}

/// 单指 TikTok 风格物理参数（内容滚动优先的翻页手感）
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
