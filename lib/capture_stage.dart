import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'l10n.dart';
import 'progress.dart';

const _hot = Color(0xffff4d4d);
const _warm = Color(0xffffc233);

/// Peak (0..1, may exceed 1) as a 0..1 meter position over -60..0 dBFS.
double meterPosition(double peak) {
  if (peak <= 0) return 0;
  final db = 20 * math.log(peak) / math.ln10;
  return ((db + 60) / 60).clamp(0.0, 1.0);
}

/// LED-style stereo meters that move every frame: the bars rise at once and fall
/// smoothly, peak caps hold for a moment and then drop, lit segments glow. Values
/// come from polling (about 8 per second); the motion between them is interpolated.
class LevelMeters extends StatefulWidget {
  final List<double> peaks;
  final bool live;
  final double height;
  final int segments;
  const LevelMeters({super.key, required this.peaks, this.live = true, this.height = 14, this.segments = 48});
  @override
  State<LevelMeters> createState() => _LevelMetersState();
}

class _LevelMetersState extends State<LevelMeters> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _shown = [0.0, 0.0], _target = [0.0, 0.0], _cap = [0.0, 0.0], _capVelocity = [0.0, 0.0];
  final _capHeld = [Duration.zero, Duration.zero];
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    _take();
  }

  @override
  void didUpdateWidget(LevelMeters old) {
    super.didUpdateWidget(old);
    // Only a new reading moves the bars (a rebuild with the same values does not).
    if (old.live != widget.live || !listEquals(old.peaks, widget.peaks)) _take();
  }

  void _take() {
    final p = widget.peaks;
    for (var c = 0; c < 2; c++) {
      final v = widget.live ? meterPosition(p.isEmpty ? 0 : p[math.min(c, p.length - 1)]) : 0.0;
      _target[c] = v;
      // Instant attack: a new peak shows in the very next frame.
      if (v > _shown[c]) _shown[c] = v;
      if (v > _cap[c]) {
        _cap[c] = v;
        _capVelocity[c] = 0;
        _capHeld[c] = _last;
      }
    }
    final settled = [for (var c = 0; c < 2; c++) (_shown[c] - _target[c]).abs() <= .001 && _cap[c] <= _shown[c] + .001].every((x) => x);
    if (!_ticker.isActive && !settled) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration now) {
    final dt = _last == Duration.zero ? 1 / 60 : (now - _last).inMicroseconds / 1e6;
    _last = now;
    var moving = false;
    for (var c = 0; c < 2; c++) {
      // Fast attack, slow release (about 1.5 of the scale per second).
      if (_target[c] > _shown[c]) {
        _shown[c] += (_target[c] - _shown[c]) * math.min(1, dt * 30);
      } else {
        _shown[c] = math.max(_target[c], _shown[c] - dt * 1.5);
      }
      if (_shown[c] >= _cap[c]) {
        _cap[c] = _shown[c];
        _capHeld[c] = now;
        _capVelocity[c] = 0;
      } else if ((now - _capHeld[c]).inMilliseconds > 700) {
        _capVelocity[c] += dt * 2.2;
        _cap[c] = math.max(_shown[c], _cap[c] - _capVelocity[c] * dt);
      }
      moving |= (_shown[c] - _target[c]).abs() > .001 || _cap[c] > _shown[c] + .001;
    }
    if (!moving) {
      // Settled on the last reading: no frames until the next one.
      for (var c = 0; c < 2; c++) {
        _shown[c] = _cap[c] = _target[c];
      }
      _ticker.stop();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mono = widget.peaks.length == 1;
    final rows = mono ? 1 : 2;
    return Semantics(
      label: tr('Poziom'),
      value: widget.live ? '${(_shown[0] * 100).round()}%' : tr('wyłączony'),
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size(double.infinity, widget.height * rows + 6 * (rows - 1)),
          painter: _MeterPainter(
            levels: mono ? [_shown[0]] : [_shown[0], _shown[1]],
            caps: mono ? [_cap[0]] : [_cap[0], _cap[1]],
            segments: widget.segments,
            rowHeight: widget.height,
            accent: accent,
            off: elevated,
          ),
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  final List<double> levels, caps;
  final int segments;
  final double rowHeight;
  final Color accent, off;
  _MeterPainter({required this.levels, required this.caps, required this.segments, required this.rowHeight, required this.accent, required this.off});

  Color _colorAt(double x) => x > .9 ? _hot : x > .75 ? _warm : Color.lerp(accent, _warm, (x / .75).clamp(0, 1) * .35)!;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 3.0;
    final w = (size.width - gap * (segments - 1)) / segments;
    final glow = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    final fill = Paint();
    for (var r = 0; r < levels.length; r++) {
      final top = r * (rowHeight + 6);
      final lit = (levels[r] * segments).floor();
      final cap = (caps[r] * segments).ceil() - 1;
      for (var i = 0; i < segments; i++) {
        final x = i * (w + gap);
        final rect = RRect.fromRectAndRadius(Rect.fromLTWH(x, top, w, rowHeight), const Radius.circular(2));
        final color = _colorAt(i / segments);
        if (i < lit) {
          glow.color = color.withValues(alpha: .55);
          canvas.drawRRect(rect.inflate(1), glow);
          fill.color = color;
        } else if (i == cap && cap > 0) {
          fill.color = Colors.white.withValues(alpha: .92);
        } else {
          fill.color = off;
        }
        canvas.drawRRect(rect, fill);
      }
    }
  }

  @override
  bool shouldRepaint(_MeterPainter o) => true;
}

/// Soft light behind the stage that breathes with the level.
class _Glow extends StatelessWidget {
  final double level;
  final Color color;
  const _Glow({required this.level, required this.color});
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: level),
    duration: const Duration(milliseconds: 180),
    builder: (context, v, _) => DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-.55, -.4),
          radius: .9 + v * .5,
          colors: [color.withValues(alpha: .10 + v * .22), color.withValues(alpha: 0)],
        ),
      ),
    ),
  );
}

/// Rings spreading from a red dot: waiting for the first sound.
class _Waiting extends StatefulWidget {
  const _Waiting();
  @override
  State<_Waiting> createState() => _WaitingState();
}

class _WaitingState extends State<_Waiting> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 64,
    height: 64,
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => CustomPaint(painter: _RingsPainter(_c.value)),
    ),
  );
}

class _RingsPainter extends CustomPainter {
  final double t;
  _RingsPainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (var k = 0; k < 3; k++) {
      final p = (t + k / 3) % 1;
      canvas.drawCircle(
        c,
        8 + p * (size.width / 2 - 8),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = _hot.withValues(alpha: (1 - p) * .7),
      );
    }
    canvas.drawCircle(c, 7, Paint()..color = _hot);
  }

  @override
  bool shouldRepaint(_RingsPainter o) => o.t != t;
}

/// A record turning while it is recorded (used when there is no cover yet).
class SpinningDisc extends StatefulWidget {
  final bool spinning;
  final double size;
  const SpinningDisc({super.key, required this.spinning, this.size = 112});
  @override
  State<SpinningDisc> createState() => _SpinningDiscState();
}

class _SpinningDiscState extends State<SpinningDisc> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(SpinningDisc old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.spinning) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.size,
    height: widget.size,
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => CustomPaint(painter: _DiscPainter(_c.value, accent)),
    ),
  );
}

class _DiscPainter extends CustomPainter {
  final double turn;
  final Color label;
  _DiscPainter(this.turn, this.label);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xff0c0c0e));
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7
      ..color = Colors.white.withValues(alpha: .07);
    for (var g = r * .42; g < r * .96; g += 2.6) {
      canvas.drawCircle(c, g, groove);
    }
    // Two light sheens turning with the record make the motion visible.
    final sheen = Paint()
      ..shader = SweepGradient(
        transform: GradientRotation(turn * 2 * math.pi),
        colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: .16), Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: .10), Colors.white.withValues(alpha: 0)],
        stops: const [0, .08, .18, .5, .58, .68],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawCircle(c, r * .96, sheen);
    canvas.drawCircle(c, r * .36, Paint()..color = label);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(turn * 2 * math.pi);
    canvas.drawRect(Rect.fromLTWH(-r * .22, -r * .03, r * .44, r * .06), Paint()..color = Colors.black.withValues(alpha: .25));
    canvas.restore();
    canvas.drawCircle(c, r * .04, Paint()..color = const Color(0xff0c0c0e));
  }

  @override
  bool shouldRepaint(_DiscPainter o) => o.turn != turn || o.label != label;
}

/// Blinking dot of a running recording.
class _RecDot extends StatefulWidget {
  final bool paused;
  const _RecDot({required this.paused});
  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: widget.paused ? const AlwaysStoppedAnimation(.35) : Tween(begin: .35, end: 1.0).animate(_c),
    child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: _hot, shape: BoxShape.circle)),
  );
}

/// What the stage shows: one consistent picture for recording from an input or an
/// app, reading a CD and saving tracks.
class StageInfo {
  /// Small line above the title ("Teraz zgrywane", "Czekam na dźwięk").
  final String kicker;
  final String title;
  final String subtitle;

  /// Progress of the current track and of everything (0..1), when known.
  final double? track, overall;

  /// "2:31" and "47:12" (total may be empty).
  final String time, total;

  /// Lengths of all tracks (for the timeline) and the current one.
  final List<double> parts;
  final int current;

  /// "Minęło 2:14 · zostało ok. 3:30" for jobs that run faster than real time.
  final String eta;
  final bool waiting, paused, rec;
  const StageInfo({
    required this.kicker,
    required this.title,
    this.subtitle = '',
    this.track,
    this.overall,
    this.time = '',
    this.total = '',
    this.parts = const [],
    this.current = -1,
    this.eta = '',
    this.waiting = false,
    this.paused = false,
    this.rec = false,
  });
}

/// The focused view while music is being captured: cover, the track now being
/// recorded and its percentage in the middle, lively meters, time and a timeline.
class CaptureStage extends StatelessWidget {
  final StageInfo info;
  final Widget cover;
  final List<double> peaks;
  final bool meters;
  final List<Widget> actions;
  final List<Widget> below;
  const CaptureStage({
    super.key,
    required this.info,
    required this.cover,
    required this.peaks,
    this.meters = true,
    this.actions = const [],
    this.below = const [],
  });

  @override
  Widget build(BuildContext context) {
    final level = peaks.isEmpty ? 0.0 : meterPosition(peaks.reduce(math.max));
    final pct = info.track;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Rad.panel),
      child: Container(
        decoration: BoxDecoration(color: panel, border: Border.all(color: softBorder)),
        child: Stack(
          children: [
            Positioned.fill(child: _Glow(level: info.waiting || info.paused ? 0 : level, color: info.rec ? _hot : accent)),
            Padding(
              padding: const EdgeInsets.all(Sp.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      AnimatedScale(
                        scale: 1 + (info.waiting || info.paused ? 0 : level * .04),
                        duration: const Duration(milliseconds: 120),
                        child: SizedBox(
                          width: 112,
                          height: 112,
                          child: info.waiting ? const Center(child: _Waiting()) : ClipRRect(borderRadius: BorderRadius.circular(8), child: cover),
                        ),
                      ),
                      const SizedBox(width: Sp.xl),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (info.rec) ...[_RecDot(paused: info.paused), const SizedBox(width: Sp.s)],
                                Flexible(
                                  child: Text(
                                    info.kicker.toUpperCase(),
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.4, color: info.rec ? _hot : accent),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: Sp.xs),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 380),
                              transitionBuilder: (child, a) => FadeTransition(
                                opacity: a,
                                child: SlideTransition(position: Tween(begin: const Offset(0, .35), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
                              ),
                              child: Text(
                                info.title,
                                key: ValueKey(info.title),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -.6, height: 1.12),
                              ),
                            ),
                            if (info.subtitle.isNotEmpty) ...[
                              const SizedBox(height: Sp.xs),
                              Text(info.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: secondaryText)),
                            ],
                          ],
                        ),
                      ),
                      if (pct != null) ...[
                        const SizedBox(width: Sp.l),
                        TweenAnimationBuilder<double>(
                          tween: Tween(end: pct.clamp(0, 1)),
                          duration: const Duration(milliseconds: 300),
                          builder: (context, v, _) => Text(
                            '${(v * 100).floor()}%',
                            style: TextStyle(fontSize: 52, fontWeight: FontWeight.w300, letterSpacing: -1.5, fontFeatures: const [ui.FontFeature.tabularFigures()], color: primaryText),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (pct != null) ...[
                    const SizedBox(height: Sp.l),
                    _Bar(value: pct, color: info.rec ? _hot : accent, height: 6, active: !info.paused && !info.waiting),
                  ],
                  if (meters) ...[
                    const SizedBox(height: Sp.l),
                    LevelMeters(peaks: peaks, live: !info.paused),
                  ],
                  const SizedBox(height: Sp.l),
                  Row(
                    children: [
                      Expanded(
                        child: info.parts.length > 1
                            ? _Timeline(parts: info.parts, current: info.current, overall: info.overall ?? 0, active: !info.paused && !info.waiting)
                            : info.overall != null
                            ? _Bar(value: info.overall, color: secondaryText, height: 3, active: !info.paused && !info.waiting)
                            : const SizedBox(),
                      ),
                      const SizedBox(width: Sp.l),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: info.time, style: TextStyle(fontWeight: FontWeight.w600, color: primaryText)),
                            if (info.total.isNotEmpty) TextSpan(text: ' / ${info.total}', style: TextStyle(color: secondaryText)),
                          ],
                        ),
                        style: const TextStyle(fontSize: 15, fontFeatures: [ui.FontFeature.tabularFigures()]),
                      ),
                    ],
                  ),
                  if (info.eta.isNotEmpty) ...[
                    const SizedBox(height: Sp.m),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.schedule_rounded, size: 16, color: secondaryText),
                        const SizedBox(width: 6),
                        Text(
                          info.eta,
                          style: TextStyle(fontSize: 14, color: secondaryText, fontFeatures: const [ui.FontFeature.tabularFigures()]),
                        ),
                      ],
                    ),
                  ],
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: Sp.xl),
                    Wrap(spacing: Sp.s, runSpacing: Sp.s, alignment: WrapAlignment.center, children: actions),
                  ],
                  ...below,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  final double? value;
  final Color color;
  final double height;
  final bool active;
  const _Bar({required this.value, required this.color, required this.height, this.active = true});
  @override
  Widget build(BuildContext context) => LiveProgress(value: value, color: color, height: height, active: active, glow: true);
}

class _Timeline extends StatelessWidget {
  final List<double> parts;
  final int current;
  final double overall;
  final bool active;
  const _Timeline({required this.parts, required this.current, required this.overall, this.active = true});
  @override
  Widget build(BuildContext context) {
    final sum = math.max(parts.fold(0.0, (a, b) => a + b), 1.0);
    final fills = <double>[];
    var start = 0.0;
    for (final p in parts) {
      final from = start / sum, to = (start += p) / sum;
      fills.add(((overall - from) / math.max(to - from, 1e-9)).clamp(0.0, 1.0));
    }
    return SizedBox(
      height: 8,
      child: Row(
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              flex: math.max(1, (parts[i] / sum * 1000).round()),
              child: _Bar(value: fills[i], color: i == current ? _hot : accent, height: 8, active: active && i == current && fills[i] < 1),
            ),
          ],
        ],
      ),
    );
  }
}
