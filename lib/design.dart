import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

// Design tokens shared by Android and Windows. Green marks state, not decoration.
const accent = Color(0xff00e676);
const background = Color(0xff0c0d0f);
const panel = Color(0xff181a1d);
const elevated = Color(0xff24272b);
const primaryText = Color(0xfff4f5f6);
const secondaryText = Color(0xff9b9fa6);
const softBorder = Color(0xff2b2e33);
const hoverFill = Color(0x0fffffff);
const selectedFill = Color(0x1a00e676);
const onAccent = Color(0xff04140b);

abstract final class Sp {
  static const xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 24.0, xxl = 32.0;
}

abstract final class Rad {
  static const cover = 8.0, coverSmall = 6.0, panel = 14.0, control = 8.0;
}

abstract final class Dur {
  static const hover = Duration(milliseconds: 120),
      tap = Duration(milliseconds: 100),
      standard = Duration(milliseconds: 200),
      screen = Duration(milliseconds: 300),
      shared = Duration(milliseconds: 360),
      ambient = Duration(milliseconds: 700);
}

Duration motion(BuildContext context, Duration value) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : value;

abstract final class Txt {
  static const display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w800,
    letterSpacing: -.8,
    height: 1.12,
  );
  static const title = TextStyle(
    fontSize: 21,
    fontWeight: FontWeight.w700,
    letterSpacing: -.4,
  );
  static const item = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);
  static const itemDesktop = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500);
  static const sub = TextStyle(fontSize: 13, color: secondaryText);
  static const meta = TextStyle(fontSize: 12, color: secondaryText);
}

String collectionCount(int count, String one, String few, String many) {
  final ending = count == 1
      ? one
      : count % 10 >= 2 &&
            count % 10 <= 4 &&
            (count % 100 < 12 || count % 100 > 14)
      ? few
      : many;
  return '$count $ending';
}

class MytifyBrand extends StatelessWidget {
  final double size;
  const MytifyBrand({super.key, this.size = 32});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ClipOval(
        child: Image.asset(
          'assets/mytify-brand.png',
          width: size,
          height: size,
        ),
      ),
      const SizedBox(width: 10),
      Flexible(
        child: Text(
          'Mytify',
          maxLines: 1,
          overflow: TextOverflow.fade,
          softWrap: false,
          style: TextStyle(
            fontSize: size * .8,
            fontWeight: FontWeight.w800,
            letterSpacing: -1,
          ),
        ),
      ),
    ],
  );
}

// Activity animation, deliberately not a spectrum or an audio level meter.
// Stop tickers for pause, background, reduced motion and off-screen TickerMode.
class PlaybackMotion extends StatefulWidget {
  final bool active;
  final Widget Function(BuildContext, double) builder;
  const PlaybackMotion({
    super.key,
    required this.active,
    required this.builder,
  });
  @override
  State<PlaybackMotion> createState() => _PlaybackMotionState();
}

class _PlaybackMotionState extends State<PlaybackMotion>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  bool resumed = true;
  bool reduced = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reduced = MediaQuery.disableAnimationsOf(context);
    sync();
  }

  @override
  void didUpdateWidget(PlaybackMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    resumed = state == AppLifecycleState.resumed;
    sync();
  }

  void sync() {
    if (widget.active &&
        resumed &&
        !reduced &&
        TickerMode.valuesOf(context).enabled) {
      if (!controller.isAnimating) controller.repeat();
    } else {
      controller.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) =>
        widget.builder(context, reduced ? 0 : controller.value),
  );
}

class PlayingBars extends StatelessWidget {
  final bool playing;
  final double size;
  const PlayingBars({super.key, required this.playing, this.size = 22});
  @override
  Widget build(BuildContext context) => Semantics(
    label: playing ? 'Odtwarzanie w toku' : 'Odtwarzanie wstrzymane',
    child: RepaintBoundary(
      child: PlaybackMotion(
        active: playing,
        builder: (context, phase) => SizedBox(
          width: size,
          height: size,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(
              4,
              (i) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.2),
                  child: Container(
                    height: playing
                        ? size *
                              (.28 +
                                  .68 *
                                      (math.sin(
                                                phase * math.pi * 12 + i * 1.7,
                                              ) *
                                              .5 +
                                          .5))
                        : size * .24,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class AmbientSurface extends StatelessWidget {
  final bool active;
  final Widget child;
  final BorderRadius borderRadius;
  const AmbientSurface({
    super.key,
    required this.active,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(26)),
  });
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: borderRadius,
    child: Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: PlaybackMotion(
              active: active,
              builder: (context, phase) =>
                  CustomPaint(painter: _AmbientPainter(phase, active)),
            ),
          ),
        ),
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                border: Border.all(
                  color: active ? accent.withValues(alpha: .25) : softBorder,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _AmbientPainter extends CustomPainter {
  final double phase;
  final bool active;
  _AmbientPainter(this.phase, this.active);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = panel);
    final x = .65 + math.sin(phase * math.pi * 2) * .3;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: Alignment(x, -.7 + math.cos(phase * math.pi * 2) * .4),
          radius: 1.15,
          colors: [
            Color(active ? 0xff163a28 : 0xff1d2124),
            panel,
          ],
        ).createShader(rect),
    );
    final path = Path()
      ..moveTo(size.width * .3, 0)
      ..cubicTo(
        size.width * x,
        size.height * .3,
        size.width * .5,
        size.height * .9,
        size.width,
        size.height * .7,
      );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = accent.withValues(alpha: active ? .09 : .035),
    );
  }

  @override
  bool shouldRepaint(_AmbientPainter old) =>
      old.phase != phase || old.active != active;
}

class MotionTile extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  const MotionTile({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
  });
  @override
  State<MotionTile> createState() => _MotionTileState();
}

class _MotionTileState extends State<MotionTile> {
  bool hovered = false, pressed = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => hovered = true),
    onExit: (_) => setState(() {
      hovered = false;
      pressed = false;
    }),
    child: AnimatedScale(
      scale: MediaQuery.disableAnimationsOf(context)
          ? 1
          : pressed
          ? .97
          : 1,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Dur.tap,
      curve: Curves.easeOutCubic,
      child: Material(
        color: hovered ? hoverFill : Colors.transparent,
        borderRadius: widget.borderRadius,
        child: InkWell(
          onTap: widget.onTap,
          onHighlightChanged: (v) {
            if (mounted) setState(() => pressed = v);
          },
          borderRadius: widget.borderRadius,
          child: widget.child,
        ),
      ),
    ),
  );
}

class PlayButton extends StatelessWidget {
  final bool playing;
  final VoidCallback? onPressed;
  final double size;
  const PlayButton({
    super.key,
    required this.playing,
    required this.onPressed,
    this.size = 58,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    enabled: onPressed != null,
    label: playing ? 'Wstrzymaj' : 'Odtwórz',
    onTap: onPressed,
    excludeSemantics: true,
    child: MotionTile(
      onTap: null,
      borderRadius: BorderRadius.circular(size),
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 280),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: onPressed == null ? elevated : accent,
        ),
        child: IconButton(
          tooltip: playing ? 'Wstrzymaj' : 'Odtwórz',
          onPressed: onPressed,
          color: onAccent,
          iconSize: size * .58,
          icon: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 220),
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              key: ValueKey(playing),
            ),
          ),
        ),
      ),
    ),
  );
}
