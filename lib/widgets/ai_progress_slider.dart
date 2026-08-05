import 'package:flutter/material.dart';
import '../theme/app_palette.dart';

/// 带 AI 档位的 snap-to-stop 可拖动进度条
///
/// 滑块在档位间吸附，松手弹簧动画归位到最近档位。
/// 上方小字实时显示当前档位描述。
class AiProgressSlider extends StatefulWidget {
  /// 档位标签列表（如 ["还没开始","函数与极限","导数与微分",...,"已经学完"]）
  final List<String> stops;

  /// 初始选中的档位索引（-1 表示"尚未添加"状态）
  final int initialStop;

  /// 档位变化回调
  final ValueChanged<int>? onStopChanged;

  /// 科目名，用于上方显示 "学到：xxx"
  final String subjectName;

  const AiProgressSlider({
    super.key,
    required this.stops,
    this.initialStop = -1,
    this.onStopChanged,
    required this.subjectName,
  });

  @override
  State<AiProgressSlider> createState() => _AiProgressSliderState();
}

class _AiProgressSliderState extends State<AiProgressSlider>
    with SingleTickerProviderStateMixin {
  late int _currentStop;
  double _sliderValue = 0;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _currentStop = widget.initialStop;
    _enabled = _currentStop >= 0;
    if (_enabled && _currentStop < widget.stops.length) {
      _sliderValue = _currentStop / (widget.stops.length - 1);
    }
  }

  void _toggleEnabled() {
    setState(() {
      _enabled = !_enabled;
      if (!_enabled) {
        _currentStop = -1;
        _sliderValue = 0;
        widget.onStopChanged?.call(-1);
      } else if (widget.stops.isNotEmpty) {
        _currentStop = 0;
        _sliderValue = 0;
        widget.onStopChanged?.call(0);
      }
    });
  }

  String get _currentLabel {
    if (!_enabled || _currentStop < 0) return '尚未添加';
    if (_currentStop >= widget.stops.length) return '已经学完';
    return widget.stops[_currentStop];
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 科目名 + 勾选框
          Row(
            children: [
              GestureDetector(
                onTap: _toggleEnabled,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: _enabled ? context.appPalette.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _enabled ? context.appPalette.primary : context.appPalette.divider,
                      width: 2,
                    ),
                  ),
                  child: _enabled
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Text(widget.subjectName, style: textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 4),
          // 当前进度描述小字
          Padding(
            padding: const EdgeInsets.only(left: 34),
            child: Text(
              '📍 学到：$_currentLabel',
              style: textTheme.labelLarge?.copyWith(
                color: _enabled ? context.appPalette.primary : context.appPalette.textMuted,
                fontSize: 13,
              ),
            ),
          ),
          // 进度条
          if (_enabled && widget.stops.length > 1) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 34),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final totalWidth = constraints.maxWidth;
                  final stopCount = widget.stops.length;
                  final segmentWidth = totalWidth / (stopCount - 1);

                  return GestureDetector(
                    onPanStart: (d) => _onPan(d.localPosition.dx, totalWidth),
                    onPanUpdate: (d) => _onPan(d.localPosition.dx, totalWidth),
                    onPanEnd: (_) => _snapToNearest(totalWidth),
                    child: SizedBox(
                      height: 40,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // 背景条
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 17,
                            child: Container(
                              height: 6,
                              decoration: BoxDecoration(
                                color: context.appPalette.divider,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                          // 已填充部分
                          Positioned(
                            left: 0,
                            top: 17,
                            width: _sliderValue * totalWidth,
                            child: Container(
                              height: 6,
                              decoration: BoxDecoration(
                                color: context.appPalette.primary,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                          // 档位标记点 + 标签
                          ...List.generate(stopCount, (i) {
                            final isAtOrBefore = _sliderValue * (stopCount - 1) >= i;
                            return Positioned(
                              left: i * segmentWidth - 3,
                              top: 14,
                              child: Column(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: isAtOrBefore
                                          ? context.appPalette.primary
                                          : context.appPalette.divider,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  SizedBox(
                                    width: segmentWidth > 40 ? segmentWidth : 60,
                                    child: Text(
                                      widget.stops[i],
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: _sliderValue * (stopCount - 1) >= i
                                            ? context.appPalette.primary
                                            : context.appPalette.textMuted,
                                        fontWeight: _sliderValue * (stopCount - 1) >= i
                                            ? FontWeight.w600
                                            : FontWeight.normal,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                          // 拖动手柄
                          Positioned(
                            left: _sliderValue * totalWidth - 10,
                            top: 10,
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: context.appPalette.primary.withValues(alpha: 0.3),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                                border: Border.all(
                                  color: context.appPalette.primary,
                                  width: 2.5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _onPan(double dx, double totalWidth) {
    if (totalWidth <= 0) return;
    final fraction = (dx / totalWidth).clamp(0.0, 1.0);
    setState(() {
      _sliderValue = fraction;
      _currentStop = (_sliderValue * (widget.stops.length - 1)).round();
    });
  }

  void _snapToNearest(double totalWidth) {
    final stopIndex = (_sliderValue * (widget.stops.length - 1)).round();
    setState(() {
      _currentStop = stopIndex.clamp(0, widget.stops.length - 1);
      _sliderValue = _currentStop / (widget.stops.length - 1);
    });
    widget.onStopChanged?.call(_currentStop);
  }

}
