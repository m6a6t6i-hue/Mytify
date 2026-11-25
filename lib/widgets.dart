import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'cover_widget.dart';
import 'design.dart';
import 'library_index.dart';
import 'model.dart';

bool isDesktopLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 840;

class Artwork extends StatelessWidget {
  final String? cover;
  final double size;
  final double radius;
  final bool circle;
  const Artwork(
    this.cover, {
    super.key,
    required this.size,
    this.radius = Rad.cover,
    this.circle = false,
  });
  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final image = CoverImage(
      cover,
      width: size,
      height: size,
      cacheWidth: (size * dpr).ceil().clamp(32, 1400),
    );
    return SizedBox(
      width: size,
      height: size,
      child: circle
          ? ClipOval(child: image)
          : ClipRRect(borderRadius: BorderRadius.circular(radius), child: image),
    );
  }
}

class HoverBuilder extends StatefulWidget {
  final Widget Function(BuildContext, bool hovered) builder;
  final MouseCursor cursor;
  const HoverBuilder({
    super.key,
    required this.builder,
    this.cursor = MouseCursor.defer,
  });
  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.cursor,
    onEnter: (_) => setState(() => hovered = true),
    onExit: (_) => setState(() => hovered = false),
    child: widget.builder(context, hovered),
  );
}

class IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;
  final double size, box;
  final Color? color;
  const IconAction(
    this.icon,
    this.tooltip,
    this.onPressed, {
    super.key,
    this.active = false,
    this.size = 20,
    this.box = 36,
    this.color,
  });
  @override
  Widget build(BuildContext context) => Pressable(
    enabled: onPressed != null,
    scale: .86,
    child: IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    iconSize: size,
    padding: EdgeInsets.zero,
    constraints: BoxConstraints.tightFor(width: box, height: box),
    color: color ?? (active ? accent : primaryText),
    disabledColor: secondaryText.withValues(alpha: .4),
    style: IconButton.styleFrom(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Rad.control),
      ),
    ),
    icon: Icon(icon),
  ),
  );
}

class LikeButton extends StatelessWidget {
  final bool liked;
  final VoidCallback? onPressed;
  final double size, box;
  const LikeButton({
    super.key,
    required this.liked,
    required this.onPressed,
    this.size = 20,
    this.box = 36,
  });
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: liked ? 'Usuń z polubionych' : 'Polub',
    onPressed: onPressed,
    padding: EdgeInsets.zero,
    constraints: BoxConstraints.tightFor(width: box, height: box),
    icon: TweenAnimationBuilder<double>(
      key: ValueKey(liked),
      tween: Tween(begin: liked ? .6 : 1, end: 1),
      duration: motion(context, const Duration(milliseconds: 320)),
      curve: Curves.elasticOut,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Icon(
        liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        size: size,
        color: liked ? accent : secondaryText,
      ),
    ),
  );
}

class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onMore;
  final EdgeInsets padding;
  const SectionHeader(
    this.title, {
    super.key,
    this.onMore,
    this.padding = const EdgeInsets.fromLTRB(Sp.l, Sp.xl, Sp.s, Sp.s),
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Txt.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (onMore != null)
          TextButton(
            onPressed: onMore,
            style: TextButton.styleFrom(foregroundColor: secondaryText),
            child: const Text('Zobacz wszystkie'),
          ),
      ],
    ),
  );
}

/// Horizontal row of cards with desktop wheel support.
class Shelf extends StatefulWidget {
  final int itemCount;
  final double height, itemWidth, gap, textHeight;
  final EdgeInsets padding;
  final Widget Function(BuildContext, int) itemBuilder;
  const Shelf({
    super.key,
    required this.itemCount,
    required this.height,
    this.textHeight = 0,
    required this.itemWidth,
    required this.itemBuilder,
    this.gap = Sp.m,
    this.padding = const EdgeInsets.symmetric(horizontal: Sp.l),
  });
  @override
  State<Shelf> createState() => _ShelfState();
}

class _ShelfState extends State<Shelf> {
  final controller = ScrollController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: widget.height + MediaQuery.textScalerOf(context).scale(widget.textHeight),
    child: Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent &&
            controller.hasClients &&
            event.scrollDelta.dx == 0) {
          final p = controller.position;
          final target = (p.pixels + event.scrollDelta.dy).clamp(
            p.minScrollExtent,
            p.maxScrollExtent,
          );
          if (target != p.pixels) {
            GestureBinding.instance.pointerSignalResolver.register(
              event,
              (_) => controller.jumpTo(target),
            );
          }
        }
      },
      child: ListView.separated(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        itemCount: widget.itemCount,
        separatorBuilder: (_, _) => SizedBox(width: widget.gap),
        itemBuilder: (context, i) => SizedBox(
          width: widget.itemWidth,
          child: widget.itemBuilder(context, i),
        ),
      ),
    ),
  );
}

/// Album, playlist or artist tile. Play appears on hover without moving layout.
class CollectionCard extends StatelessWidget {
  final String? cover;
  final String title;
  final String? subtitle;
  final double size;
  final bool circle, current, playing;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;
  final void Function(Offset)? onMenu;
  final Widget? placeholder;
  const CollectionCard({
    super.key,
    required this.cover,
    required this.title,
    required this.size,
    required this.onOpen,
    this.subtitle,
    this.onPlay,
    this.onMenu,
    this.circle = false,
    this.current = false,
    this.playing = false,
    this.placeholder,
  });
  @override
  Widget build(BuildContext context) => HoverBuilder(
    cursor: SystemMouseCursors.click,
    builder: (context, hovered) => GestureDetector(
      onTap: onOpen,
      onSecondaryTapUp: onMenu == null
          ? null
          : (d) => onMenu!(d.globalPosition),
      onLongPressStart: onMenu == null
          ? null
          : (d) => onMenu!(d.globalPosition),
      child: Semantics(
        button: true,
        label: subtitle == null ? title : '$title, $subtitle',
        child: AnimatedContainer(
          duration: motion(context, Dur.hover),
          padding: const EdgeInsets.all(Sp.s),
          decoration: BoxDecoration(
            color: hovered ? hoverFill : Colors.transparent,
            borderRadius: BorderRadius.circular(Rad.panel - 2),
          ),
          child: Column(
            crossAxisAlignment: circle
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  placeholder ??
                      Artwork(
                        cover,
                        size: size - Sp.l,
                        circle: circle,
                        radius: Rad.cover,
                      ),
                  if (current)
                    Positioned(
                      left: Sp.s,
                      bottom: Sp.s,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: background.withValues(alpha: .8),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: PlayingBars(playing: playing, size: 14),
                      ),
                    ),
                  if (onPlay != null)
                    Positioned(
                      right: Sp.s,
                      bottom: Sp.s,
                      child: AnimatedOpacity(
                        opacity: hovered ? 1 : 0,
                        duration: motion(context, Dur.standard),
                        child: AnimatedSlide(
                          offset: hovered ? Offset.zero : const Offset(0, .25),
                          duration: motion(context, Dur.standard),
                          curve: Curves.easeOutCubic,
                          child: IgnorePointer(
                            ignoring: !hovered,
                            child: Material(
                              color: accent,
                              shape: const CircleBorder(),
                              elevation: 4,
                              child: IconButton(
                                tooltip: 'Odtwórz',
                                onPressed: onPlay,
                                color: onAccent,
                                icon: const Icon(Icons.play_arrow_rounded),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Sp.s),
              Text(
                title,
                maxLines: 2,
                textAlign: circle ? TextAlign.center : TextAlign.start,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                  color: current ? accent : primaryText,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Txt.meta,
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class LikedArt extends StatelessWidget {
  final double size;
  final bool circle;
  const LikedArt({super.key, required this.size, this.circle = false});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: const Color(0xff16332a),
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(Rad.cover),
    ),
    alignment: Alignment.center,
    child: Icon(Icons.favorite_rounded, color: accent, size: size * .36),
  );
}

/// 2x2 mosaic for playlists, built from real artwork only.
class PlaylistArt extends StatelessWidget {
  final List<Track> tracks;
  final double size;
  const PlaylistArt({super.key, required this.tracks, required this.size});
  @override
  Widget build(BuildContext context) {
    final covers = <String>[];
    for (final t in tracks) {
      if (t.cover != null && !covers.contains(t.cover)) covers.add(t.cover!);
      if (covers.length == 4) break;
    }
    if (covers.length < 4) {
      return Artwork(covers.firstOrNull, size: size);
    }
    final half = size / 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Rad.cover),
      child: SizedBox(
        width: size,
        height: size,
        child: Wrap(
          children: [
            for (final c in covers) Artwork(c, size: half, radius: 0),
          ],
        ),
      ),
    );
  }
}

/// Exact seek bar. The played part is a decorative, animated waveform with a
/// spinning record as the thumb. Unknown duration shows a disabled, empty track.
class SeekBar extends StatefulWidget {
  final Duration position, duration;
  final ValueChanged<Duration>? onSeek;
  final bool showTimes, thin, playing, compact, timesBelow;
  final int seed;
  final Color? color;
  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    this.onSeek,
    this.showTimes = true,
    this.thin = false,
    this.playing = false,
    this.compact = false,
    this.timesBelow = true,
    this.seed = 0,
    this.color,
  });
  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> with SingleTickerProviderStateMixin {
  double? dragging, hover;
  final _EqMotion eq = _EqMotion();
  late final ticker = createTicker(_tick);
  Duration last = Duration.zero;
  bool reduced = false;

  bool get _live => !widget.thin && widget.duration > Duration.zero;

  @override
  void initState() {
    super.initState();
    eq
      ..seed = widget.seed
      ..amp = widget.playing && _live ? 1 : 0
      ..settle();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reduced = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(SeekBar old) {
    super.didUpdateWidget(old);
    eq.seed = widget.seed;
    _sync();
  }

  /// Runs only while playing or while the bars are still fading to the line.
  void _sync() {
    final playing = widget.playing && _live;
    if (reduced) {
      if (ticker.isActive) ticker.stop();
      eq
        ..amp = playing ? 1 : 0
        ..settle();
      return;
    }
    if ((playing || eq.amp > 0) && _live) {
      if (!ticker.isActive) {
        last = Duration.zero;
        ticker.start();
      }
    } else if (ticker.isActive) {
      ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - last).inMicroseconds / 1e6).clamp(0.0, .1);
    last = elapsed;
    eq.step(dt, widget.playing && _live);
    if (!widget.playing && eq.amp <= 0) ticker.stop();
  }

  @override
  void dispose() {
    ticker.dispose();
    eq.dispose();
    super.dispose();
  }

  double get _height => widget.compact ? 26 : 38;
  double get _thumb => widget.compact ? 22 : 32;

  @override
  Widget build(BuildContext context) {
    final total = widget.duration.inMilliseconds;
    final known = total > 0;
    final enabled = known && widget.onSeek != null;
    final value = !known
        ? 0.0
        : (dragging ?? widget.position.inMilliseconds.clamp(0, total) / total)
              .toDouble();
    final color = widget.color ?? accent;
    if (widget.thin) {
      return SizedBox(
        height: 3,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            FractionallySizedBox(
              widthFactor: value,
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final r = _thumb / 2;
    Widget bar = LayoutBuilder(
      builder: (context, box) {
        final span = math.max(1.0, box.maxWidth - 2 * r);
        double at(double dx) => ((dx - r) / span).clamp(0.0, 1.0);
        final active = dragging != null || hover != null;
        final track = SizedBox(
          height: _height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _WavePainter(
                      eq: eq,
                      value: value,
                      known: known,
                      active: active,
                      color: enabled ? color : secondaryText,
                      thumb: _thumb,
                      compact: widget.compact,
                    ),
                  ),
                ),
              ),
              if (enabled && active)
                Positioned(
                  left: (r + (dragging ?? hover)! * span - 22).clamp(
                    0.0,
                    math.max(0.0, box.maxWidth - 44),
                  ),
                  top: -24,
                  child: Container(
                    width: 44,
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    decoration: BoxDecoration(
                      color: elevated,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      clock(((dragging ?? hover)! * total).round()),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
            ],
          ),
        );
        if (!enabled) return track;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (e) => setState(() => hover = at(e.localPosition.dx)),
          onExit: (_) => setState(() => hover = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => setState(() => dragging = at(d.localPosition.dx)),
            onTapUp: (_) => _commit(total),
            onTapCancel: () => setState(() => dragging = null),
            onHorizontalDragStart: (d) =>
                setState(() => dragging = at(d.localPosition.dx)),
            onHorizontalDragUpdate: (d) =>
                setState(() => dragging = at(d.localPosition.dx)),
            onHorizontalDragEnd: (_) => _commit(total),
            child: Semantics(
              slider: true,
              label: 'Postęp utworu',
              value: clock(widget.position.inMilliseconds),
              child: track,
            ),
          ),
        );
      },
    );
    if (!widget.showTimes) return bar;
    final shown = dragging == null
        ? widget.position.inMilliseconds
        : (dragging! * total).round();
    final style = Txt.meta.copyWith(
      fontSize: 12,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final left = Text(known ? clock(shown) : '--:--', style: style);
    final right = Text(
      known ? clock(total) : '--:--',
      textAlign: TextAlign.right,
      style: style,
    );
    if (widget.timesBelow) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          bar,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(children: [left, const Spacer(), right]),
          ),
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: 44, child: left),
        const SizedBox(width: Sp.xs),
        Expanded(child: bar),
        const SizedBox(width: Sp.xs),
        SizedBox(width: 44, child: right),
      ],
    );
  }

  void _commit(int total) {
    final v = dragging;
    setState(() => dragging = null);
    if (v != null && widget.onSeek != null) {
      widget.onSeek!(Duration(milliseconds: (v * total).round()));
    }
  }
}

double _hash(int seed, int x, int y) {
  var h = (seed * 0x27d4eb2d) ^ (x * 0x165667b1) ^ (y * 0x2f6b4c3d);
  h = (h ^ (h >> 15)) * 0x85ebca6b & 0xffffffff;
  h = (h ^ (h >> 13)) * 0xc2b2ae35 & 0xffffffff;
  h ^= h >> 16;
  return (h & 0xffffff) / 0x1000000;
}

/// Smooth 2D value noise: not periodic, so the bars never repeat a cycle.
double _noise(int seed, double x, double y) {
  final xi = x.floor(), yi = y.floor();
  final fx = x - xi, fy = y - yi;
  final u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy);
  final a = _hash(seed, xi, yi), b = _hash(seed, xi + 1, yi);
  final c = _hash(seed, xi, yi + 1), d = _hash(seed, xi + 1, yi + 1);
  return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v;
}

/// Live state of the decorative equalizer. Bars behave like a level meter:
/// a beat with uneven accents, noisy bands, fast attack and slow release.
/// It is driven by the clock, not by the audio signal.
class _EqMotion extends ChangeNotifier {
  static const _max = 360;
  final List<double> levels = List.filled(_max, 0);
  double time = 0, amp = 0, angle = 0;
  int seed = 0, bars = 160;

  double _target(int i) {
    final t = time;
    final x = i.toDouble();
    final body = .55 * _noise(seed, x / 7, t * 1.1) +
        .30 * _noise(seed + 1, x / 2.6, t * 2.7) +
        .15 * _noise(seed + 2, x * .9, t * 6.3);
    final shape = math.pow(body, 1.5).toDouble();
    final bpm = 92 + 44 * _hash(seed, 7, 7);
    final period = 60 / bpm;
    final beat = (t / period).floor();
    final since = t - beat * period;
    final roll = _hash(seed, beat, 3);
    final accent = roll < .14 ? .15 : .45 + .55 * roll;
    final pulse = accent * math.exp(-since / .16);
    final reach = _noise(seed + 3, x / 16, t * .35);
    return (.06 + .62 * shape + .48 * pulse * (.35 + .65 * reach)).clamp(0.0, 1.0);
  }

  void settle() {
    for (var i = 0; i < _max; i++) {
      levels[i] = _target(i);
    }
    notifyListeners();
  }

  void step(double dt, bool playing) {
    time += dt;
    amp = (amp + (playing ? dt : -dt) / .45).clamp(0.0, 1.0);
    final eased = amp * amp * (3 - 2 * amp);
    // 33 1/3 rpm, slowing down with the fade like a turntable.
    angle += dt * 3.49 * eased;
    final rise = 1 - math.exp(-dt * 28), fall = 1 - math.exp(-dt * 7);
    final n = math.min(bars, _max);
    for (var i = 0; i < n; i++) {
      final target = _target(i);
      final cur = levels[i];
      levels[i] = cur + (target - cur) * (target > cur ? rise : fall);
    }
    notifyListeners();
  }
}

/// Equalizer bars, remaining line and the record thumb.
class _WavePainter extends CustomPainter {
  final _EqMotion eq;
  final double value, thumb;
  final bool known, active, compact;
  final Color color;
  _WavePainter({
    required this.eq,
    required this.value,
    required this.known,
    required this.active,
    required this.color,
    required this.thumb,
    required this.compact,
  }) : super(repaint: eq);

  @override
  void paint(Canvas canvas, Size size) {
    final r = thumb / 2;
    final cy = size.height / 2;
    final x = r + value * math.max(0.0, size.width - 2 * r);
    final line = compact ? 3.0 : 4.0;
    final rest = Paint()
      ..color = const Color(0xff34373c)
      ..strokeWidth = line
      ..strokeCap = StrokeCap.round;
    if (!known) {
      canvas.drawLine(Offset(line / 2, cy), Offset(size.width - line / 2, cy), rest);
      return;
    }
    if (size.width - line / 2 > x) {
      canvas.drawLine(Offset(x, cy), Offset(size.width - line / 2, cy), rest);
    }

    // Played part: a green line that grows into equalizer bars while playing.
    final amp = eq.amp * eq.amp * (3 - 2 * eq.amp);
    final end = x - r - 3;
    if (end > line / 2) {
      final paint = Paint()
        ..color = color
        ..strokeCap = StrokeCap.round;
      final spine = line + (1.6 - line) * amp;
      canvas.drawLine(Offset(line / 2, cy), Offset(end, cy), paint..strokeWidth = spine);
      if (amp > 0) {
        final step = compact ? 4.5 : 5.5;
        final width = compact ? 2.2 : 2.8;
        final maxH = compact ? 18.0 : 26.0;
        paint.strokeWidth = width;
        eq.bars = (end / step).ceil() + 1;
        var i = 0;
        for (var bx = width / 2 + 1; bx <= end && i < eq.levels.length; bx += step, i++) {
          final h = maxH * eq.levels[i] * amp;
          if (h <= spine) continue;
          canvas.drawLine(Offset(bx, cy - h / 2), Offset(bx, cy + h / 2), paint);
        }
      }
    }

    // Record thumb.
    final c = Offset(x, cy);
    canvas.drawCircle(
      c.translate(0, 1.5),
      r,
      Paint()
        ..color = Colors.black.withValues(alpha: .45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(c, r, Paint()..color = const Color(0xff1b1d21));
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..color = const Color(0xff2c2f34);
    for (final f in const [.86, .72, .58]) {
      canvas.drawCircle(c, r * f, groove);
    }
    canvas.drawCircle(
      c,
      r - .4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .7
        ..color = active ? color.withValues(alpha: .7) : const Color(0xff3d4146),
    );
    canvas.drawCircle(c, r * .36, Paint()..color = color);
    canvas.drawCircle(
      c + Offset(math.cos(eq.angle), math.sin(eq.angle)) * r * .09,
      r * .11,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.eq != eq ||
      old.value != value ||
      old.known != known ||
      old.active != active ||
      old.color != color ||
      old.thumb != thumb;
}

String clock(int ms) {
  if (ms < 0) ms = 0;
  final s = ms ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

String longDuration(int ms) {
  final minutes = (ms / 60000).round();
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} godz. ${minutes % 60} min';
}

String trackCount(int n) => collectionCount(n, 'utwór', 'utwory', 'utworów');
String albumCount(int n) => collectionCount(n, 'album', 'albumy', 'albumów');

class MenuEntry {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool destructive;
  final String? shortcut;
  final List<MenuEntry>? children;
  const MenuEntry(
    this.label, {
    this.icon,
    this.onTap,
    this.destructive = false,
    this.shortcut,
    this.children,
  });
  static const divider = MenuEntry('');
  bool get isDivider => label.isEmpty;
}

/// Desktop: anchored popup menu. Mobile: compact bottom sheet.
Future<void> showActions(
  BuildContext context,
  List<MenuEntry> entries, {
  Offset? at,
  String? title,
}) async {
  if (isDesktopLayout(context) && at != null) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      at & const Size(1, 1),
      Offset.zero & overlay.size,
    );
    final chosen = await showMenu<MenuEntry>(
      context: context,
      position: position,
      color: elevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      items: [
        for (final e in entries)
          if (e.isDivider)
            const PopupMenuDivider(height: 8)
          else
            PopupMenuItem<MenuEntry>(
              value: e,
              height: 36,
              enabled: e.onTap != null || e.children != null,
              child: Row(
                children: [
                  if (e.icon != null) ...[
                    Icon(
                      e.icon,
                      size: 18,
                      color: e.destructive ? const Color(0xffff6b6b) : secondaryText,
                    ),
                    const SizedBox(width: Sp.m),
                  ],
                  Expanded(
                    child: Text(
                      e.label,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: e.destructive ? const Color(0xffff6b6b) : null,
                      ),
                    ),
                  ),
                  if (e.shortcut != null)
                    Text(e.shortcut!, style: Txt.meta),
                  if (e.children != null)
                    const Icon(Icons.chevron_right_rounded, size: 18),
                ],
              ),
            ),
      ],
    );
    if (chosen == null || !context.mounted) return;
    if (chosen.children != null) {
      await showActions(context, chosen.children!, at: at + const Offset(24, 8));
    } else {
      chosen.onTap?.call();
    }
    return;
  }
  final chosen = await showModalBottomSheet<MenuEntry>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: panel,
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .75,
      ),
      child: ListView(
        shrinkWrap: true,
        // Keeps the last entry above the system navigation bar.
        padding: EdgeInsets.only(bottom: Sp.l + MediaQuery.viewPaddingOf(context).bottom),
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.xl, 0, Sp.xl, Sp.s),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Txt.item,
              ),
            ),
          for (final e in entries)
            if (e.isDivider)
              const Divider(height: 12, color: softBorder)
            else
              ListTile(
                minTileHeight: 52,
                enabled: e.onTap != null || e.children != null,
                leading: e.icon == null
                    ? null
                    : Icon(
                        e.icon,
                        color: e.destructive
                            ? const Color(0xffff6b6b)
                            : secondaryText,
                      ),
                title: Text(
                  e.label,
                  style: TextStyle(
                    color: e.destructive ? const Color(0xffff6b6b) : null,
                  ),
                ),
                trailing: e.children == null
                    ? null
                    : const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pop(context, e),
              ),
        ],
      ),
    ),
  );
  if (chosen == null || !context.mounted) return;
  if (chosen.children != null) {
    await showActions(context, chosen.children!, title: chosen.label);
  } else {
    chosen.onTap?.call();
  }
}

Future<String?> askName(
  BuildContext context, {
  required String title,
  String initial = '',
  String action = 'Zapisz',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: Txt.title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(hintText: 'Nazwa'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Anuluj'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: Text(action),
        ),
      ],
    ),
  ).then((v) => v == null || v.isEmpty ? null : v);
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
  bool destructive = true,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: Txt.title),
        content: SizedBox(width: 380, child: Text(message, style: Txt.sub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: const Color(0xffe5484d),
                    foregroundColor: Colors.white,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ==
    true;

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;
  const EmptyState({
    super.key,
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(Sp.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: secondaryText),
          const SizedBox(height: Sp.m),
          Text(text, textAlign: TextAlign.center, style: Txt.sub),
          if (action != null) ...[
            const SizedBox(height: Sp.l),
            FilledButton(onPressed: onAction, child: Text(action!)),
          ],
        ],
      ),
    ),
  );
}

/// Debounced callback used by local search.
class Debouncer {
  final Duration delay;
  Timer? _timer;
  Debouncer(this.delay);
  void call(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void dispose() => _timer?.cancel();
}

String formatLabel(Track t) => t.format.toUpperCase();

String? bitrateLabel(Track t) {
  if (t.durationMs <= 0 || t.size <= 0) return null;
  final kbps = (t.size * 8 / t.durationMs).round();
  return '$kbps kb/s';
}

String sampleRateLabel(int hz) => hz <= 0
    ? 'brak danych'
    : hz % 1000 == 0
    ? '${hz ~/ 1000} kHz'
    : '${(hz / 1000).toStringAsFixed(1).replaceAll('.', ',')} kHz';

String? bitDepthLabel(Track t) =>
    lossless(t.format) && t.bitDepth > 0 ? '${t.bitDepth} bit' : null;
