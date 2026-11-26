import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'l10n.dart';

/// One colour scheme of the whole app. Green marks state, not decoration.
class Palette {
  final String id, name;
  final Brightness brightness;
  final Color accent, background, panel, elevated, primaryText, secondaryText, softBorder, hoverFill, selectedFill, onAccent;

  /// Error text and its background tint, readable on this background.
  final Color danger, warning;
  const Palette({
    required this.id,
    required this.name,
    this.brightness = Brightness.dark,
    required this.accent,
    required this.background,
    required this.panel,
    required this.elevated,
    required this.primaryText,
    required this.secondaryText,
    required this.softBorder,
    required this.hoverFill,
    required this.selectedFill,
    required this.onAccent,
    this.danger = const Color(0xffff8a8a),
    this.warning = const Color(0xffffb454),
  });
  bool get light => brightness == Brightness.light;
}

const palettes = [
  Palette(
    id: 'mytify',
    name: 'Mytify',
    accent: Color(0xff00e676),
    background: Color(0xff0c0d0f),
    panel: Color(0xff181a1d),
    elevated: Color(0xff24272b),
    primaryText: Color(0xfff4f5f6),
    secondaryText: Color(0xff9b9fa6),
    softBorder: Color(0xff2b2e33),
    hoverFill: Color(0x0fffffff),
    selectedFill: Color(0x1a00e676),
    onAccent: Color(0xff04140b),
  ),
  Palette(
    id: 'oled',
    name: 'Czerń OLED',
    accent: Color(0xff00e676),
    background: Color(0xff000000),
    panel: Color(0xff0e0f10),
    elevated: Color(0xff1a1b1d),
    primaryText: Color(0xfff4f5f6),
    secondaryText: Color(0xff9b9fa6),
    softBorder: Color(0xff222325),
    hoverFill: Color(0x12ffffff),
    selectedFill: Color(0x1a00e676),
    onAccent: Color(0xff04140b),
  ),
  Palette(
    id: 'ocean',
    name: 'Ocean',
    accent: Color(0xff38bdf8),
    background: Color(0xff0a0f16),
    panel: Color(0xff121a24),
    elevated: Color(0xff1b2633),
    primaryText: Color(0xfff1f5f9),
    secondaryText: Color(0xff93a1b3),
    softBorder: Color(0xff243242),
    hoverFill: Color(0x0fffffff),
    selectedFill: Color(0x1f38bdf8),
    onAccent: Color(0xff04121c),
  ),
  Palette(
    id: 'amethyst',
    name: 'Ametyst',
    accent: Color(0xffb388ff),
    background: Color(0xff0e0c14),
    panel: Color(0xff18151f),
    elevated: Color(0xff24202d),
    primaryText: Color(0xfff5f3f8),
    secondaryText: Color(0xffa39cb0),
    softBorder: Color(0xff2e2939),
    hoverFill: Color(0x0fffffff),
    selectedFill: Color(0x1fb388ff),
    onAccent: Color(0xff160a2a),
  ),
  Palette(
    id: 'amber',
    name: 'Bursztyn',
    accent: Color(0xffffb454),
    background: Color(0xff0f0d0a),
    panel: Color(0xff1b1814),
    elevated: Color(0xff27231d),
    primaryText: Color(0xfff7f4ef),
    secondaryText: Color(0xffaaa093),
    softBorder: Color(0xff332d25),
    hoverFill: Color(0x0fffffff),
    selectedFill: Color(0x1fffb454),
    onAccent: Color(0xff241504),
    warning: Color(0xffffd59a),
  ),
  Palette(
    id: 'raspberry',
    name: 'Malina',
    accent: Color(0xffff5c8a),
    background: Color(0xff0f0b0d),
    panel: Color(0xff1c1619),
    elevated: Color(0xff282024),
    primaryText: Color(0xfff8f3f5),
    secondaryText: Color(0xffaa9aa1),
    softBorder: Color(0xff34292e),
    hoverFill: Color(0x0fffffff),
    selectedFill: Color(0x1fff5c8a),
    onAccent: Color(0xff2a0612),
    danger: Color(0xffffb4b4),
  ),
  Palette(
    id: 'light',
    name: 'Jasny',
    brightness: Brightness.light,
    accent: Color(0xff00a152),
    background: Color(0xfff6f7f8),
    panel: Color(0xffffffff),
    elevated: Color(0xffeceef1),
    primaryText: Color(0xff15171a),
    secondaryText: Color(0xff5c636c),
    softBorder: Color(0xffdde1e6),
    hoverFill: Color(0x0f000000),
    selectedFill: Color(0x1a00a152),
    onAccent: Color(0xffffffff),
    danger: Color(0xffc62828),
    warning: Color(0xffb26a00),
  ),
];

/// Scheme in use. Changed only through the settings, which rebuild the whole app.
Palette palette = palettes.first;

Palette paletteById(String? id) => palettes.firstWhere((p) => p.id == id, orElse: () => palettes.first);

Color get accent => palette.accent;
Color get background => palette.background;
Color get panel => palette.panel;
Color get elevated => palette.elevated;
Color get primaryText => palette.primaryText;
Color get secondaryText => palette.secondaryText;
Color get softBorder => palette.softBorder;
Color get hoverFill => palette.hoverFill;
Color get selectedFill => palette.selectedFill;
Color get onAccent => palette.onAccent;
Color get dangerText => palette.danger;
Color get warningText => palette.warning;

/// Desktop sidebar: a step darker than the background in dark schemes.
Color get sidebarTone => palette.light ? const Color(0xffeef0f2) : Color.lerp(palette.background, palette.panel, .3)!;

/// Rebuilds and repaints every widget after the scheme changed (const widgets included).
void rebuildEverything() {
  void visit(Element e) {
    e.markNeedsBuild();
    if (e is RenderObjectElement) e.renderObject.markNeedsPaint();
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
}

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
  static TextStyle get sub => TextStyle(fontSize: 13, color: secondaryText);
  static TextStyle get meta => TextStyle(fontSize: 12, color: secondaryText);
}

String collectionCount(int count, String one, String few, String many) {
  // English: one or many, from the dictionary entries of the Polish forms.
  if (lang == 'en') return '$count ${tr(count == 1 ? one : many)}';
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
    label: playing ? tr('Odtwarzanie w toku') : tr('Odtwarzanie wstrzymane'),
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

/// Primary play control with a real play/pause morph and press feedback.
class PlayButton extends StatefulWidget {
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
  State<PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<PlayButton>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: Dur.standard,
    value: widget.playing ? 1 : 0,
  );

  @override
  void didUpdateWidget(PlayButton old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing) {
      controller.duration = motion(context, Dur.standard);
      widget.playing ? controller.forward() : controller.reverse();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    enabled: widget.onPressed != null,
    label: widget.playing ? tr('Wstrzymaj') : tr('Odtwórz'),
    onTap: widget.onPressed,
    excludeSemantics: true,
    child: Pressable(
      enabled: widget.onPressed != null,
      child: AnimatedContainer(
        duration: motion(context, Dur.standard),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.onPressed == null ? elevated : accent,
        ),
        child: IconButton(
          tooltip: widget.playing ? tr('Wstrzymaj') : tr('Odtwórz'),
          onPressed: widget.onPressed,
          color: onAccent,
          iconSize: widget.size * .5,
          icon: AnimatedIcon(
            icon: AnimatedIcons.play_pause,
            progress: CurvedAnimation(parent: controller, curve: Curves.easeInOutCubic),
          ),
        ),
      ),
    ),
  );
}

/// Short spring-like squash on press. Never delays the action itself.
class Pressable extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final double scale;
  const Pressable({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = .9,
  });
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool down = false;
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: widget.enabled ? (_) => setState(() => down = true) : null,
    onPointerUp: (_) => setState(() => down = false),
    onPointerCancel: (_) => setState(() => down = false),
    child: AnimatedScale(
      scale: down ? widget.scale : 1,
      duration: motion(context, down ? Dur.tap : Dur.shared),
      curve: down ? Curves.easeOut : Curves.elasticOut,
      child: widget.child,
    ),
  );
}

/// Standard 36 px controls for settings and import screens.
abstract final class Ctl {
  static const height = 36.0;
  static final filled = FilledButton.styleFrom(
    minimumSize: const Size(0, height),
    padding: const EdgeInsets.symmetric(horizontal: Sp.l),
    textStyle: const TextStyle(fontFamily: 'Arial', fontSize: 13.5, fontWeight: FontWeight.w700),
  );
  static final outlined = OutlinedButton.styleFrom(
    minimumSize: const Size(0, height),
    padding: const EdgeInsets.symmetric(horizontal: Sp.l),
    textStyle: const TextStyle(fontFamily: 'Arial', fontSize: 13.5, fontWeight: FontWeight.w600),
  );
  static final text = TextButton.styleFrom(
    minimumSize: const Size(0, height),
    padding: const EdgeInsets.symmetric(horizontal: Sp.m),
    textStyle: const TextStyle(fontFamily: 'Arial', fontSize: 13.5, fontWeight: FontWeight.w600),
  );
  static InputDecoration field({String? hint}) => InputDecoration(
    isDense: true,
    hintText: hint,
    contentPadding: const EdgeInsets.symmetric(horizontal: Sp.m, vertical: 10),
  );
  static const fieldText = TextStyle(fontSize: 13.5);
  static TextStyle get label => TextStyle(fontSize: 13, color: secondaryText);
  static const section = TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -.2);
}
