import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'audio_player.dart';
import 'cover_tint.dart';
import 'design.dart';
import 'main.dart';
import 'model.dart';
import 'player_ui.dart';
import 'widgets.dart';

/// Full screen scenes. Order matches uMode in shaders/visualizer.frag.
const visualizerScenes = ['Plazma', 'Wstęgi', 'Wir', 'Retro'];

/// Mytify colours of the scenes: teal, green, violet.
const mytifyPalette = [Color(0xff00c7bd), Color(0xff00e676), Color(0xff6b3dfa)];

/// Colours the scene shows now; eases towards [target] when the track changes.
class ScenePalette {
  List<Color> target = mytifyPalette, shown = mytifyPalette;
  void step(double dt) {
    final k = 1 - math.exp(-dt / .8);
    shown = [for (var i = 0; i < 3; i++) Color.lerp(shown[i], target[i], k)!];
  }
}

/// Loudness features from real band levels: bass, mids, highs, overall energy and a
/// beat pulse on bass onsets. Without data every value falls to zero.
class AudioFeatures {
  double bass = 0, mid = 0, high = 0, energy = 0, beat = 0;
  double _peak = -40, _slowBass = 0, _sinceBeat = 1;
  List<double> _bandPeak = const [];
  bool live = false;

  static double _avg(List<double> v, int from, int to) {
    var s = 0.0;
    for (var i = from; i < to; i++) {
      s += v[i];
    }
    return s / (to - from);
  }

  void step(double dt, List<double>? bands) {
    live = bands != null && bands.length >= 8;
    double tb = 0, tm = 0, th = 0;
    if (live) {
      final b = bands!;
      final loudest = b.reduce((a, c) => a > c ? a : c);
      _peak = loudest > _peak ? loudest : math.max(-40.0, _peak - dt * 4);
      if (_bandPeak.length != b.length) _bandPeak = List.filled(b.length, -60.0);
      const range = 28.0;
      final floor = _peak - range;
      // Mix of the whole-song level and each band's own recent peak, then lifted,
      // so quiet passages and thin high frequencies still move the picture.
      final norm = <double>[];
      for (var i = 0; i < b.length; i++) {
        _bandPeak[i] = b[i] > _bandPeak[i] ? b[i] : math.max(_peak - 30, _bandPeak[i] - dt * 3);
        final global = ((b[i] - floor) / range).clamp(0.0, 1.0);
        final local = ((b[i] - (_bandPeak[i] - 20)) / 20).clamp(0.0, 1.0);
        norm.add(math.pow(global * .5 + local * .5, .75).toDouble());
      }
      final n = norm.length;
      tb = _avg(norm, 0, n * 8 ~/ 40);
      tm = _avg(norm, n * 8 ~/ 40, n * 24 ~/ 40);
      th = _avg(norm, n * 24 ~/ 40, n);
    }
    double follow(double cur, double target) {
      final rate = target > cur ? 1 - math.exp(-dt / .025) : 1 - math.exp(-dt / .2);
      return cur + (target - cur) * rate;
    }

    bass = follow(bass, tb);
    mid = follow(mid, tm);
    high = follow(high, th);
    energy = follow(energy, (tb * .5 + tm * .35 + th * .15));
    _slowBass += (bass - _slowBass) * (1 - math.exp(-dt / .5));
    _sinceBeat += dt;
    if (live && bass - _slowBass > .07 && _sinceBeat > .22) {
      beat = 1;
      _sinceBeat = 0;
    }
    beat *= math.exp(-dt / .18);
  }
}

class VisualizerScreen extends StatefulWidget {
  final LibraryScreenState app;

  /// Opened by idle time on PC: any key, click or mouse move closes it.
  final bool screensaver;
  const VisualizerScreen({super.key, required this.app, this.screensaver = false});
  @override
  State<VisualizerScreen> createState() => _VisualizerScreenState();
}

class _VisualizerScreenState extends State<VisualizerScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// Loaded once per app run; a failed load falls back to the simple painter.
  static ui.FragmentProgram? _program;
  ui.FragmentShader? shader;
  late final ticker = createTicker(_tick);
  StreamSubscription<Object?>? _player;
  final features = AudioFeatures();
  final palette = ScenePalette();
  String? _paletteFor;
  Offset? _firstPointer;
  final time = ValueNotifier<double>(0);
  Duration last = Duration.zero;
  double sceneTime = 0, noDataFor = 0;
  LevelFeed? feed;
  late bool controls = !widget.screensaver;
  bool resumed = true;
  Timer? hide;
  late int scene = (widget.app.prefs.get<int>('viz.scene', 0)).clamp(0, visualizerScenes.length - 1);
  late bool coverColors = widget.app.prefs.get<bool>('viz.cover', true);

  LibraryScreenState get app => widget.app;
  bool get phone => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_program != null) {
      shader = _program!.fragmentShader();
    } else {
      unawaited(
        ui.FragmentProgram.fromAsset('shaders/visualizer.frag').then((p) {
          _program = p;
          if (mounted) setState(() => shader = p.fragmentShader());
        }, onError: (Object _) {}),
      );
    }
    app.visualizerOpen = true;
    _player = app.player.stream.snapshot.listen((_) => _sync());
    if (phone) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
      unawaited(app.repository.keepScreenOn(true));
    } else if (app.canFloat) {
      unawaited(app.repository.windowAction({'action': 'mode', 'mode': 'fullscreen'}));
    }
    if (!widget.screensaver) _poke();
    _sync();
  }

  /// Cover colours of the current track, or the Mytify palette.
  void _updatePalette() {
    final cover = coverColors ? app.current?.cover : null;
    if (cover == _paletteFor) return;
    _paletteFor = cover;
    if (cover == null) {
      palette.target = mytifyPalette;
      return;
    }
    unawaited(CoverTint.palette(cover).then((p) {
      if (mounted && _paletteFor == cover) palette.target = p ?? mytifyPalette;
    }));
  }

  void _toggleCoverColors() {
    setState(() => coverColors = !coverColors);
    app.prefs.set('viz.cover', coverColors);
    _updatePalette();
    _poke();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    resumed = state == AppLifecycleState.resumed;
    _sync();
  }

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// Runs while playing and visible; paused, hidden or minimised freezes the picture.
  void _sync() {
    if (!mounted) return;
    _updatePalette();
    final playing = app.player.state.playing;
    final want = playing && resumed;
    if (want && feed == null) {
      feed = LevelFeed.current?..attach();
    } else if (!want && feed != null) {
      feed!.detach();
      feed = null;
    }
    if (want || features.energy > .01 || features.beat > .01) {
      if (!ticker.isActive) {
        last = Duration.zero;
        ticker.start();
      }
    } else if (ticker.isActive) {
      ticker.stop();
    }
    setState(() {});
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - last).inMicroseconds / 1e6).clamp(0.0, .1);
    last = elapsed;
    final bands = feed?.bands;
    features.step(dt, bands);
    palette.step(dt);
    noDataFor = bands == null ? noDataFor + dt : 0;
    // Louder music moves the scene faster. Without data only a slow, even drift.
    final speed = features.live ? .15 + 1.6 * features.energy + .8 * features.beat : (app.player.state.playing ? .05 : 0.0);
    sceneTime += dt * (_reduced ? speed * .25 : speed);
    time.value = sceneTime;
    if (!app.player.state.playing && features.energy <= .01 && features.beat <= .01) ticker.stop();
  }

  void _poke() {
    if (widget.screensaver) return _close();
    hide?.cancel();
    if (!controls) setState(() => controls = true);
    hide = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => controls = false);
    });
  }

  void _scene(int delta) {
    setState(() => scene = (scene + delta) % visualizerScenes.length);
    app.prefs.set('viz.scene', scene);
    _poke();
  }

  bool _closing = false;
  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    app.visualizerOpen = false;
    hide?.cancel();
    feed?.detach();
    unawaited(_player?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    ticker.dispose();
    time.dispose();
    if (phone) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      unawaited(app.repository.keepScreenOn(false));
    } else if (app.canFloat) {
      unawaited(app.repository.windowAction({'action': 'mode', 'mode': 'normal'}));
    }
    super.dispose();
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (widget.screensaver) {
      _close();
      return KeyEventResult.handled;
    }
    final k = e.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (k == LogicalKeyboardKey.escape) {
      _close();
    } else if (k == LogicalKeyboardKey.space) {
      unawaited(app.togglePlay());
    } else if (ctrl && k == LogicalKeyboardKey.arrowRight) {
      unawaited(app.nextTrack());
    } else if (ctrl && k == LogicalKeyboardKey.arrowLeft) {
      unawaited(app.previousTrack());
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _scene(1);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _scene(-1);
    } else {
      return KeyEventResult.ignored;
    }
    _poke();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final t = app.current;
    final s = app.player.state;
    return Focus(
      autofocus: true,
      onKeyEvent: _key,
      child: MouseRegion(
        cursor: controls ? SystemMouseCursors.basic : SystemMouseCursors.none,
        onHover: (e) {
          // The screensaver ignores a tiny jitter of the mouse, any real move closes it.
          if (widget.screensaver) {
            final first = _firstPointer ??= e.position;
            if ((e.position - first).distance > 12) _close();
            return;
          }
          _poke();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (widget.screensaver) return _close();
            if (controls) {
              hide?.cancel();
              setState(() => controls = false);
            } else {
              _poke();
            }
          },
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v.abs() > 300) _scene(v < 0 ? 1 : -1);
          },
          child: Material(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _ScenePainter(shader: shader, time: time, features: features, scene: scene, palette: palette),
                  ),
                ),
                AnimatedOpacity(
                  opacity: controls ? 1 : 0,
                  duration: motion(context, Dur.standard),
                  child: IgnorePointer(
                    ignoring: !controls,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(Sp.l),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Image.asset('assets/mytify-icon.png', width: 22, height: 22),
                                const SizedBox(width: Sp.s),
                                const Text('Mytify', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                                const Spacer(),
                                IconAction(Icons.chevron_left_rounded, 'Poprzednia wizualizacja (←)', () => _scene(-1), color: secondaryText),
                                SizedBox(
                                  width: 84,
                                  child: Text(visualizerScenes[scene], textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                                ),
                                IconAction(Icons.chevron_right_rounded, 'Następna wizualizacja (→)', () => _scene(1), color: secondaryText),
                                const SizedBox(width: Sp.s),
                                IconAction(
                                  Icons.palette_outlined,
                                  coverColors ? 'Kolory okładki: włączone' : 'Kolory okładki: wyłączone',
                                  _toggleCoverColors,
                                  active: coverColors,
                                  color: coverColors ? accent : secondaryText,
                                ),
                                const SizedBox(width: Sp.s),
                                IconAction(Icons.close_rounded, 'Zamknij wizualizację (Esc)', _close, color: primaryText),
                              ],
                            ),
                            const Spacer(),
                            if (s.playing && noDataFor > 1.5)
                              Padding(
                                padding: EdgeInsets.only(bottom: Sp.m),
                                child: Text(
                                  'Brak danych o dźwięku z tego wyjścia: obraz nie reaguje na muzykę.',
                                  style: TextStyle(fontSize: 12.5, color: secondaryText),
                                ),
                              ),
                            _bottom(t, s.playing),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottom(Track? t, bool playing) => LayoutBuilder(
    builder: (context, box) {
      final narrow = box.maxWidth < 560;
      final info = Row(
        children: [
          if (t != null) Artwork(t.cover, size: 44, radius: 6),
          const SizedBox(width: Sp.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t?.title ?? 'Wybierz utwór', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                if (t != null) Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.meta),
              ],
            ),
          ),
          if (!narrow) TransportControls(app: app, play: 44, icon: 22, gap: Sp.xs),
        ],
      );
      return Container(
        constraints: const BoxConstraints(maxWidth: 720),
        padding: const EdgeInsets.all(Sp.m),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .45),
          borderRadius: BorderRadius.circular(Rad.panel),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            info,
            if (narrow) ...[
              const SizedBox(height: Sp.s),
              TransportControls(app: app, play: 52, icon: 24, gap: Sp.s),
            ],
            PlayerListener(app: app, builder: (context, s) => trackSeek(app, s, compact: true, timesBelow: false)),
          ],
        ),
      );
    },
  );
}

class _ScenePainter extends CustomPainter {
  final ui.FragmentShader? shader;
  final ValueNotifier<double> time;
  final AudioFeatures features;
  final int scene;
  final ScenePalette palette;
  _ScenePainter({required this.shader, required this.time, required this.features, required this.scene, required this.palette}) : super(repaint: time);

  @override
  void paint(Canvas canvas, Size size) {
    final f = features;
    final s = shader;
    if (s == null) {
      // Fallback when the GPU program is unavailable: soft glow driven by the same features.
      final c = size.center(Offset.zero);
      canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xff030609));
      for (var i = 0; i < 3; i++) {
        final a = time.value * (.3 + i * .17) + i * 2.1;
        final p = c + Offset(math.cos(a), math.sin(a * 1.3)) * size.shortestSide * (.18 + i * .07);
        final r = size.shortestSide * (.35 + f.bass * .25);
        canvas.drawCircle(
          p,
          r,
          Paint()
            ..shader = ui.Gradient.radial(p, r, [
              palette.shown[i].withValues(alpha: .25 + f.energy * .4),
              Colors.transparent,
            ]),
        );
      }
      return;
    }
    s
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, time.value)
      ..setFloat(3, f.bass)
      ..setFloat(4, f.mid)
      ..setFloat(5, f.high)
      ..setFloat(6, f.energy)
      ..setFloat(7, f.beat)
      ..setFloat(8, scene.toDouble());
    for (var i = 0; i < 3; i++) {
      final c = palette.shown[i];
      s
        ..setFloat(9 + i * 3, c.r)
        ..setFloat(10 + i * 3, c.g)
        ..setFloat(11 + i * 3, c.b);
    }
    canvas.drawRect(Offset.zero & size, Paint()..shader = s);
  }

  @override
  bool shouldRepaint(_ScenePainter old) => old.shader != shader || old.scene != scene;
}
