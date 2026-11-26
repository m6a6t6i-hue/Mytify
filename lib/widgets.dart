import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'cover_widget.dart';
import 'audio_player.dart';
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
      color: Color.lerp(panel, accent, .18),
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

class _SeekBarState extends State<SeekBar>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  double? dragging, hover;
  final _EqMotion eq = _EqMotion();
  late final ticker = createTicker(_tick);
  Duration last = Duration.zero;
  bool reduced = false, resumed = true;
  LevelFeed? _feed;

  bool get _live => !widget.thin && widget.duration > Duration.zero;
  VisualizerStyle get _style => widget.compact ? VisualizerStyle.compact : VisualizerStyle.regular;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    eq.spin = widget.playing && _live ? 1 : 0;
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
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    resumed = state == AppLifecycleState.resumed;
    _sync();
  }

  /// Runs only while playing or while the picture is still fading out. Minimised,
  /// hidden or reduced motion: no ticker and no polling, a static line instead.
  void _sync() {
    final playing = widget.playing && _live;
    final allowed = _live && resumed && !reduced;
    final wanted = playing && allowed;
    if (wanted && _feed == null) {
      _feed = LevelFeed.current?..attach();
    } else if (!wanted && _feed != null) {
      _feed!.detach();
      _feed = null;
    }
    if (!allowed) {
      if (ticker.isActive) ticker.stop();
      eq
        ..amp = 0
        ..spin = reduced ? 0 : eq.spin
        ..changed();
      return;
    }
    if (wanted || eq.amp > 0 || eq.spin > 0) {
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
    final playing = widget.playing && _live;
    eq.step(dt, playing, playing ? _feed?.bands : null, _style);
    if (!playing && eq.amp <= 0 && eq.spin <= 0) ticker.stop();
  }

  @override
  void dispose() {
    _feed?.detach();
    WidgetsBinding.instance.removeObserver(this);
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
                color: primaryText.withValues(alpha: .16),
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
                      style: _style,
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

/// Look and timing of the equalizer drawn in the seek bar. One definition for
/// PC and Android; [regular] and [compact] differ only in size.
class VisualizerStyle {
  /// Bar thickness, distance between bars and full bar height, in logical pixels.
  final double barWidth, step, maxHeight;

  /// Outer part of each half of a bar that fades to transparent at the tip.
  final double tipFade;

  /// Part of the whole seek bar width faded at both ends of the bars.
  final double edgeFade;

  /// Opacity of a bar's solid middle.
  final double opacity;

  /// Rise time constant, full-height fall time, and the fade on play and pause.
  final Duration attack, decay, fade;

  /// Loudness range shown, in dB below the running peak of the music.
  final double range;

  /// Opacity of the fine dotted line under quiet bars (0 = none).
  final double dotOpacity;

  const VisualizerStyle({
    required this.barWidth,
    required this.step,
    required this.maxHeight,
    this.tipFade = .38,
    this.edgeFade = .10,
    this.opacity = .95,
    this.attack = const Duration(milliseconds: 30),
    this.decay = const Duration(milliseconds: 380),
    this.fade = const Duration(milliseconds: 200),
    this.range = 36,
    this.dotOpacity = .42,
  });

  // 80% of the previous 2.8 / 2.2 px bars.
  static const regular = VisualizerStyle(barWidth: 2.24, step: 5.5, maxHeight: 26);
  static const compact = VisualizerStyle(barWidth: 1.76, step: 4.5, maxHeight: 18);
}

/// State of the seek bar equalizer. Heights come only from real band levels of
/// the output ([LevelFeed]); without them the bar is a plain static progress line.
class _EqMotion extends ChangeNotifier {
  /// Displayed band heights 0..1, low to high frequency.
  List<double> levels = const [];

  /// Visibility of the bars (0 = progress line only) and record rotation speed.
  double amp = 0, spin = 0, angle = 0;

  /// Running peak in dB, so quiet and loud recordings both fill the bar.
  double peak = -40;

  /// Running peak per band, so quiet high frequencies still move.
  List<double> bandPeak = const [];

  void changed() => notifyListeners();

  void step(double dt, bool playing, List<double>? bands, VisualizerStyle style) {
    final fade = style.fade.inMicroseconds / 1e6;
    final hasData = bands != null && bands.isNotEmpty;
    amp = (amp + (playing && hasData ? dt : -dt) / fade).clamp(0.0, 1.0);
    // 33 1/3 rpm, slowing down like a turntable when paused.
    spin = (spin + (playing ? dt : -dt) / .45).clamp(0.0, 1.0);
    angle += dt * 3.49 * spin * spin * (3 - 2 * spin);
    if (bands != null && bands.isNotEmpty) {
      if (levels.length != bands.length) {
        levels = List.filled(bands.length, 0.0);
        bandPeak = List.filled(bands.length, -60.0);
      }
      final loudest = bands.reduce((a, b) => a > b ? a : b);
      peak = loudest > peak ? loudest : math.max(-40.0, peak - dt * 4);
      final floor = peak - style.range;
      final rise = 1 - math.exp(-dt * 1e6 / style.attack.inMicroseconds);
      final fall = dt * 1e6 / style.decay.inMicroseconds;
      for (var i = 0; i < bands.length; i++) {
        // Half the height follows the whole mix, half the band's own recent peak,
        // capped 30 dB below the mix so hiss is not blown up into bars.
        final own = bands[i] > bandPeak[i] ? bands[i] : math.max(peak - 30, bandPeak[i] - dt * 3);
        bandPeak[i] = own;
        final global = ((bands[i] - floor) / style.range).clamp(0.0, 1.0);
        final local = ((bands[i] - (own - 24)) / 24).clamp(0.0, 1.0);
        final x = global * .55 + local * .45;
        final target = math.pow(x, 1.6).toDouble();
        final cur = levels[i];
        levels[i] = target > cur ? cur + (target - cur) * rise : math.max(target, cur - fall);
      }
    }
    // Paused or no data: the last picture only fades, it is not updated.
    notifyListeners();
  }

  /// Height 0..1 at [t] (0 = left end, 1 = thumb), smooth between bands.
  double at(double t) {
    if (levels.isEmpty) return 0;
    final p = t.clamp(0.0, 1.0) * (levels.length - 1);
    final i = p.floor(), f = p - i;
    final a = levels[i], b = levels[math.min(i + 1, levels.length - 1)];
    final w = (1 - math.cos(f * math.pi)) / 2;
    return a + (b - a) * w;
  }
}

double _smooth(double edge, double x) {
  if (edge <= 0) return 1;
  final t = (x / edge).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Equalizer bars or progress line, remaining line and the record thumb.
class _WavePainter extends CustomPainter {
  final _EqMotion eq;
  final double value, thumb;
  final bool known, active, compact;
  final Color color;
  final VisualizerStyle style;
  _WavePainter({
    required this.eq,
    required this.value,
    required this.known,
    required this.active,
    required this.color,
    required this.thumb,
    required this.compact,
    required this.style,
  }) : super(repaint: eq);

  @override
  void paint(Canvas canvas, Size size) {
    final r = thumb / 2;
    final cy = size.height / 2;
    final x = r + value * math.max(0.0, size.width - 2 * r);
    final line = compact ? 3.0 : 4.0;
    final rest = Paint()
      ..color = softBorder
      ..strokeWidth = line
      ..strokeCap = StrokeCap.round;
    if (!known) {
      canvas.drawLine(Offset(line / 2, cy), Offset(size.width - line / 2, cy), rest);
      return;
    }
    if (size.width - line / 2 > x) {
      canvas.drawLine(Offset(x, cy), Offset(size.width - line / 2, cy), rest);
    }

    // Played part: the progress line while paused or without audio data,
    // cross-fading into bars while playing. No line runs through the bars.
    final amp = eq.amp * eq.amp * (3 - 2 * eq.amp);
    final end = x - r - 3;
    if (end > line / 2) {
      if (amp < 1) {
        canvas.drawLine(
          Offset(line / 2, cy),
          Offset(end, cy),
          Paint()
            ..color = color.withValues(alpha: color.a * (1 - amp))
            ..strokeWidth = line
            ..strokeCap = StrokeCap.round,
        );
      }
      if (amp > 0) {
        final edge = math.min(style.edgeFade * size.width, end / 2);
        // Short fade towards the record so the bars reach it.
        final near = math.min(edge * .3, end / 4);
        final paint = Paint()
          ..strokeWidth = style.barWidth
          ..strokeCap = StrokeCap.round;
        final dot = Paint()..color = color.withValues(alpha: color.a * style.dotOpacity * amp);
        final tip = style.tipFade / 2;
        for (var bx = style.barWidth / 2 + 1; bx <= end; bx += style.step) {
          final h = style.maxHeight * eq.at(bx / end) * amp;
          final fadeIn = _smooth(edge, bx);
          if (h < 3) {
            // Quiet band: a fine dotted line keeps the bar continuous up to the record.
            if (style.dotOpacity > 0 && fadeIn > .05) {
              canvas.drawCircle(Offset(bx, cy), style.barWidth * .42 * fadeIn, dot);
            }
            if (h < 1) continue;
          }
          final alpha = style.opacity * fadeIn * _smooth(near, end - bx);
          if (alpha < .02) continue;
          final solid = color.withValues(alpha: color.a * alpha);
          final clear = color.withValues(alpha: 0);
          final top = Offset(bx, cy - h / 2), bottom = Offset(bx, cy + h / 2);
          paint.shader = ui.Gradient.linear(top, bottom, [clear, solid, solid, clear], [0, tip, 1 - tip, 1]);
          canvas.drawLine(top, bottom, paint);
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
      ..color = elevated;
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
      old.thumb != thumb ||
      old.style != style;
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
                      color: e.destructive ? dangerText : secondaryText,
                    ),
                    const SizedBox(width: Sp.m),
                  ],
                  Expanded(
                    child: Text(
                      e.label,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: e.destructive ? dangerText : null,
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
              Divider(height: 12, color: softBorder)
            else
              ListTile(
                minTileHeight: 52,
                enabled: e.onTap != null || e.children != null,
                leading: e.icon == null
                    ? null
                    : Icon(
                        e.icon,
                        color: e.destructive
                            ? dangerText
                            : secondaryText,
                      ),
                title: Text(
                  e.label,
                  style: TextStyle(
                    color: e.destructive ? dangerText : null,
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

/// Section heading with a hairline to the right ("Wyjście ———").
class SectionTitle extends StatelessWidget {
  final String text;
  final EdgeInsets padding;
  const SectionTitle(this.text, {super.key, this.padding = const EdgeInsets.only(top: Sp.xl, bottom: Sp.m)});
  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      children: [
        Semantics(header: true, child: Text(text, style: Ctl.section)),
        const SizedBox(width: Sp.m),
        Expanded(child: Divider(height: 1, color: softBorder)),
      ],
    ),
  );
}

/// Label and value in one line; the value is selectable for bug reports.
class InfoRow extends StatelessWidget {
  final String label, value;
  final Color? color;
  const InfoRow(this.label, this.value, {super.key, this.color});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 200, child: Text(label, style: Ctl.label)),
        Expanded(child: SelectableText(value, style: TextStyle(fontSize: 13.5, color: color))),
      ],
    ),
  );
}

/// Header that opens and closes its content in place, as a quiet card.
class Collapsible extends StatefulWidget {
  final String title;
  final String? trailing;
  final Widget child;
  final bool initiallyOpen, enabled, card;
  final ValueChanged<bool>? onChanged;
  const Collapsible({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.initiallyOpen = false,
    this.enabled = true,
    this.card = true,
    this.onChanged,
  });
  @override
  State<Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<Collapsible> {
  late bool open = widget.initiallyOpen;
  @override
  Widget build(BuildContext context) {
    final shown = open && widget.enabled;
    final header = InkWell(
      borderRadius: BorderRadius.circular(widget.card ? Rad.panel : Rad.control),
      onTap: widget.enabled
          ? () {
              setState(() => open = !open);
              widget.onChanged?.call(open);
            }
          : null,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: widget.card ? Sp.l : Sp.xs, vertical: widget.card ? Sp.m : Sp.s),
        child: Row(
          children: [
            AnimatedRotation(
              turns: shown ? .25 : 0,
              duration: motion(context, Dur.standard),
              child: Icon(Icons.chevron_right_rounded, size: 20, color: widget.enabled ? primaryText : secondaryText),
            ),
            const SizedBox(width: Sp.s),
            Expanded(
              child: Text(
                widget.title,
                style: TextStyle(
                  fontSize: widget.card ? 15 : 13.5,
                  fontWeight: FontWeight.w600,
                  color: widget.enabled ? primaryText : secondaryText,
                ),
              ),
            ),
            if (widget.trailing != null) Text(widget.trailing!, style: Ctl.label),
          ],
        ),
      ),
    );
    final body = AnimatedSize(
      duration: motion(context, Dur.standard),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: shown
          ? Padding(
              padding: EdgeInsets.fromLTRB(widget.card ? Sp.xl + Sp.l : Sp.xl + Sp.xs, 0, widget.card ? Sp.l : 0, widget.card ? Sp.l : Sp.s),
              child: widget.child,
            )
          : const SizedBox(width: double.infinity),
    );
    final content = Semantics(
      expanded: shown,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [header, body]),
    );
    if (!widget.card) return content;
    return Container(
      margin: const EdgeInsets.only(bottom: Sp.m),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(Rad.panel),
        border: Border.all(color: softBorder),
      ),
      child: Material(type: MaterialType.transparency, child: content),
    );
  }
}

/// Text tabs with an underline under the active one.
class TextTabs extends StatelessWidget {
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  /// Optional small marker per tab (e.g. work running there).
  final List<bool>? busy;
  const TextTabs({super.key, required this.labels, required this.index, required this.onChanged, this.busy});
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: softBorder))),
    child: Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Semantics(
            selected: i == index,
            button: true,
            child: InkWell(
              onTap: () => onChanged(i),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(Rad.control)),
              child: AnimatedContainer(
                duration: motion(context, Dur.standard),
                padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.l, Sp.m - 2),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: i == index ? accent : Colors.transparent, width: 2)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: i == index ? primaryText : secondaryText,
                      ),
                    ),
                    if (busy != null && busy![i]) ...[
                      const SizedBox(width: Sp.s),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(color: Color(0xffff5252), shape: BoxShape.circle),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// A few live level bars (mini player). Same real data and timing as the seek bar;
/// nothing is drawn while paused or without data.
class LevelBars extends StatefulWidget {
  final bool playing;
  final int count;
  final double width, height;
  final Color? _color;
  Color get color => _color ?? accent;
  const LevelBars({super.key, required this.playing, this.count = 4, this.width = 16, this.height = 14, Color? color}) : _color = color;
  @override
  State<LevelBars> createState() => _LevelBarsState();
}

class _LevelBarsState extends State<LevelBars> with SingleTickerProviderStateMixin {
  final eq = _EqMotion();
  late final ticker = createTicker(_tick);
  Duration last = Duration.zero;
  LevelFeed? feed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(LevelBars old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final want = widget.playing && !MediaQuery.disableAnimationsOf(context);
    if (want && feed == null) {
      feed = LevelFeed.current?..attach();
    } else if (!want && feed != null) {
      feed!.detach();
      feed = null;
    }
    if ((want || eq.amp > 0) && !ticker.isActive) {
      last = Duration.zero;
      ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - last).inMicroseconds / 1e6).clamp(0.0, .1);
    last = elapsed;
    eq.step(dt, widget.playing, widget.playing ? feed?.bands : null, VisualizerStyle.compact);
    if (!widget.playing && eq.amp <= 0) ticker.stop();
  }

  @override
  void dispose() {
    feed?.detach();
    ticker.dispose();
    eq.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: widget.width,
      height: widget.height,
      child: CustomPaint(painter: _BarsPainter(eq, widget.count, widget.color)),
    ),
  );
}

class _BarsPainter extends CustomPainter {
  final _EqMotion eq;
  final int count;
  final Color color;
  _BarsPainter(this.eq, this.count, this.color) : super(repaint: eq);
  @override
  void paint(Canvas canvas, Size size) {
    if (eq.amp <= 0 || count < 1) return;
    final step = size.width / count;
    final paint = Paint()
      ..color = color.withValues(alpha: color.a * eq.amp)
      ..strokeWidth = math.min(2.4, step * .55)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final h = size.height * eq.at(count == 1 ? 0 : (i + .5) / count) * eq.amp;
      if (h < 1) continue;
      final x = step * (i + .5);
      canvas.drawLine(Offset(x, size.height - h), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.eq != eq || old.count != count || old.color != color;
}
