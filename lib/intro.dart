import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'intro_geometry.dart';

/// Set in main() on Android only. PC shows the same animation as SVG in
/// web/index.html while the UI loads, so Flutter must not play it twice.
bool introOnStart = false;

const _bg = Color(0xff0c0d0f);
const _accent = Color(0xff00e676);
const _text = Color(0xfff4f5f6);
const _disc = Color(0xff1e2225);
const _groove = Color(0xff41484c);
const _shine = Color(0xff7b8689);

Path _parse(String d) {
  final path = Path();
  final tokens = RegExp(r'[MLQZ]|-?\d*\.?\d+').allMatches(d).map((m) => m[0]!).toList();
  var i = 0;
  double n() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    switch (tokens[i++]) {
      case 'M':
        path.moveTo(n(), n());
      case 'L':
        path.lineTo(n(), n());
      case 'Q':
        path.quadraticBezierTo(n(), n(), n(), n());
      case 'Z':
        path.close();
    }
  }
  return path;
}

final _mark = _parse(introMarkPath);
final _letters = _parse(introTextPath);

double _seg(double ms, double a, double b) => ((ms - a) / (b - a)).clamp(0.0, 1.0);
double _easeOut(double t) => 1 - math.pow(1 - t, 3).toDouble();
double _smooth(double t) => t * t * (3 - 2 * t);

/// One frame of the "Mytify Winyl" intro at [ms] (0 to 1000).
/// Timing follows the supplied SVG exactly.
class IntroPainter extends CustomPainter {
  final double ms;
  IntroPainter(this.ms);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);
    // Uniform scale of the 640 x 420 reference, never stretched per axis.
    final k = math.min(size.width / 520, size.height / 420).clamp(.35, 1.8);
    canvas.save();
    canvas.translate(size.width / 2 - 320 * k, size.height / 2 - 210 * k);
    canvas.scale(k);

    final appear = _easeOut(_seg(ms, 0, 220));
    final grow = .94 + .06 * _easeOut(_seg(ms, 0, 630));
    final label = _smooth(_seg(ms, 352, 917));
    final fade = 1 - label;

    canvas.save();
    canvas.translate(320, 169);
    canvas.scale(grow);
    canvas.drawCircle(Offset.zero, 84, Paint()..color = _disc.withValues(alpha: appear));
    if (fade > 0) {
      final groove = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .65
        ..color = _groove.withValues(alpha: .65 * fade * appear);
      for (final r in const [43.0, 51.0, 59.0, 67.0, 75.0]) {
        canvas.drawCircle(Offset.zero, r, groove);
      }
      final shine = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _shine.withValues(alpha: .34 * fade * appear);
      final turn = 150 * _easeOut(_seg(ms, 0, 889)) * math.pi / 180;
      const start = -27.997 * math.pi / 180, sweep = 40.0 * math.pi / 180;
      for (final r in const [52.0, 60.0, 68.0, 76.0]) {
        canvas.drawArc(Rect.fromCircle(center: Offset.zero, radius: r), start + turn, sweep, false, shine);
      }
    }
    canvas.drawCircle(Offset.zero, 15 + 69 * label, Paint()..color = _accent.withValues(alpha: appear));
    final mark = _smooth(_seg(ms, 593, 963));
    if (mark > 0) {
      canvas.save();
      canvas.translate(-84, -84);
      canvas.scale(.168);
      canvas.drawPath(_mark, Paint()..color = _bg.withValues(alpha: mark));
      canvas.restore();
    }
    canvas.restore();

    final word = _easeOut(_seg(ms, 722, 1000));
    if (word > 0) {
      canvas.translate(0, 7 * (1 - word));
      canvas.drawPath(_letters, Paint()..color = _text.withValues(alpha: word));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(IntroPainter old) => old.ms != ms;
}

/// Start screen overlay. Plays once (max 1000 ms), holds the final logo only
/// while the library is still loading, then fades away. Tap skips it.
class StartupIntro extends StatefulWidget {
  final bool ready;
  final VoidCallback onDone;
  const StartupIntro({super.key, required this.ready, required this.onDone});
  @override
  State<StartupIntro> createState() => _StartupIntroState();
}

class _StartupIntroState extends State<StartupIntro> with SingleTickerProviderStateMixin {
  late final AnimationController motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..addStatusListener((_) => _maybeLeave());
  bool leaving = false;
  Timer? fallback;

  @override
  void initState() {
    super.initState();
    // Never keep the logo forever, even if loading hangs: the app has its own states.
    fallback = Timer(const Duration(seconds: 6), _leave);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      motion.value = 1;
    } else if (!motion.isAnimating && motion.value == 0) {
      motion.forward();
    }
  }

  @override
  void didUpdateWidget(StartupIntro old) {
    super.didUpdateWidget(old);
    _maybeLeave();
  }

  void _maybeLeave() {
    if (widget.ready && motion.isCompleted) _leave();
  }

  void _leave() {
    if (leaving || !mounted) return;
    motion.stop();
    setState(() => leaving = true);
  }

  @override
  void dispose() {
    fallback?.cancel();
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: leaving ? 0 : 1,
    duration: const Duration(milliseconds: 240),
    curve: Curves.easeOut,
    onEnd: () {
      if (leaving) widget.onDone();
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _leave,
      child: Semantics(
        label: 'Mytify',
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: motion,
            builder: (context, _) => CustomPaint(
              painter: IntroPainter(motion.value * 1000),
              size: Size.infinite,
            ),
          ),
        ),
      ),
    ),
  );
}
