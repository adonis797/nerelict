import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 赛博朋克 2077 风格的网页加载进度条。
///
/// - 已加载部分：霓虹青 → 洋红渐变，带外发光与沿进度流动的高光；
/// - 进度未知：一段霓虹光带在轨道上来回扫描；
/// - 加载结束后淡出，不留下一条静止的亮线。
class NeonProgressBar extends StatefulWidget {
  const NeonProgressBar({
    super.key,
    required this.value,
    this.visible = true,
    this.height = 3,
  });

  /// 0~1 的加载进度；null 表示进度未知。
  final double? value;
  final bool visible;
  final double height;

  @override
  State<NeonProgressBar> createState() => _NeonProgressBarState();
}

class _NeonProgressBarState extends State<NeonProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    return AnimatedOpacity(
      opacity: widget.visible ? 1 : 0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      child: SizedBox(
        height: h + 9,
        width: double.infinity,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
            if (w <= 0) return const SizedBox.shrink();
            return AnimatedBuilder(
              animation: _anim,
              builder: (context, _) {
                final t = _anim.value;
                final value = widget.value;
                final determinate = value != null && value >= 0;
                const top = 4.0;
                final track = Container(
                  decoration: BoxDecoration(
                    color: kNeonCyan.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(h),
                    border: Border.all(
                      color: kNeonCyan.withValues(alpha: 0.16),
                      width: 0.5,
                    ),
                  ),
                );

                final children = <Widget>[
                  Positioned(left: 0, right: 0, top: top, height: h, child: track),
                ];

                if (determinate) {
                  final ratio = value.clamp(0.0, 1.0);
                  final filled = (w * ratio).clamp(0.0, w);
                  if (filled > 0) {
                    children
                      ..add(Positioned(
                        left: 0,
                        top: top,
                        height: h,
                        width: filled,
                        child: _fill(h, shimmer: t, width: filled),
                      ))
                      // 头部亮点：像扫描头一样悬在进度末端
                      ..add(Positioned(
                        left: (filled - 3).clamp(0.0, w),
                        top: top - 2.5,
                        width: 6,
                        height: h + 5,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(3),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: kNeonCyan.withValues(alpha: 0.9),
                                blurRadius: 10,
                                spreadRadius: 1,
                              ),
                              BoxShadow(
                                color: kNeonMagenta.withValues(alpha: 0.55),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                        ),
                      ));
                  }
                } else {
                  // 不确定进度：光带从左侧滑到右侧，带一点加速度感
                  final eased = Curves.easeInOutCubic.transform(
                    (t * 1.35) % 1.0,
                  );
                  final segWidth = (w * 0.34).clamp(24.0, w);
                  final left = (w + segWidth) * eased - segWidth;
                  children.add(Positioned(
                    left: left.clamp(-segWidth, w),
                    top: top,
                    height: h,
                    width: segWidth,
                    child: _fill(h, shimmer: t, width: segWidth),
                  ));
                }

                return Stack(clipBehavior: Clip.none, children: children);
              },
            );
          },
        ),
      ),
    );
  }

  /// 霓虹渐变实体 + 沿进度移动的高光。
  Widget _fill(double h, {required double shimmer, required double width}) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: <Color>[kNeonCyan, Color(0xFF7C5CFF), kNeonMagenta],
          stops: <double>[0.0, 0.55, 1.0],
        ),
        borderRadius: BorderRadius.circular(h),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: kNeonCyan.withValues(alpha: 0.55),
            blurRadius: 8,
            spreadRadius: 0.5,
          ),
          BoxShadow(
            color: kNeonMagenta.withValues(alpha: 0.38),
            blurRadius: 14,
            spreadRadius: 0.5,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(h),
        child: Stack(
          children: <Widget>[
            // 流动高光：一条比进度区更亮的窄带缓慢掠过
            Positioned(
              left: (width * shimmer) - width,
              top: 0,
              bottom: 0,
              width: width < 8 ? width : width * 0.8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: <Color>[
                      Colors.white.withValues(alpha: 0.0),
                      Colors.white.withValues(alpha: 0.55),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
