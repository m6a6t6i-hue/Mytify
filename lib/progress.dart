import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'test_env.dart' if (dart.library.io) 'test_env_io.dart';

/// Progress bar that never looks dead. The fill glides to every new value, a soft
/// sheen runs over it while the work goes on, and with no known value a band
/// sweeps across. Still when the system asks for less motion.
class LiveProgress extends StatefulWidget {
  final double? value;
  final double height;
  final Color? color;
  final Color? background;

  /// Work is going on (sheen). Off for finished or waiting parts.
  final bool active;
  final bool glow;
  const LiveProgress({super.key, this.value, this.height = 6, this.color, this.background, this.active = true, this.glow = false});

  @override
  State<LiveProgress> createState() => _LiveProgressState();
}

class _LiveProgressState extends State<LiveProgress> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1700));

  bool get _moving => widget.active && !inFlutterTest && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  void _sync() {
    if (_moving) {
      if (!_c.isAnimating) unawaited(_c.repeat());
    } else if (_c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(LiveProgress old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? accent;
    final h = widget.height;
    return ClipRRect(
      borderRadius: BorderRadius.circular(h),
      child: SizedBox(
        height: h,
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            final bg = ColoredBox(color: widget.background ?? elevated);
            if (widget.value == null) {
              return AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  final t = _moving ? Curves.easeInOut.transform(_c.value) : .35;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      bg,
                      Positioned(
                        left: (t * 1.4 - .4) * w,
                        width: .4 * w,
                        top: 0,
                        bottom: 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [color.withValues(alpha: 0), color, color.withValues(alpha: 0)]),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            }
            return TweenAnimationBuilder<double>(
              tween: Tween(end: widget.value!.clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) {
                final fill = v * w;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    bg,
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: fill,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [color.withValues(alpha: .72), color]),
                          boxShadow: widget.glow ? [BoxShadow(color: color.withValues(alpha: .5), blurRadius: 8)] : null,
                        ),
                      ),
                    ),
                    // Sheen over the filled part: the work is alive even between updates.
                    if (_moving && fill > 2)
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: fill,
                        child: ClipRect(
                          child: AnimatedBuilder(
                            animation: _c,
                            builder: (context, _) {
                              final band = (w * .22).clamp(24.0, 160.0);
                              return Stack(
                                children: [
                                  Positioned(
                                    left: _c.value * (fill + band) - band,
                                    width: band,
                                    top: 0,
                                    bottom: 0,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: .38), Colors.white.withValues(alpha: 0)],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}
