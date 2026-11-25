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
  Widget build(BuildContext context) => IconButton(
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

/// Exact seek bar. Unknown duration shows a disabled, empty track.
class SeekBar extends StatefulWidget {
  final Duration position, duration;
  final ValueChanged<Duration>? onSeek;
  final bool showTimes, thin;
  final Color? color;
  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    this.onSeek,
    this.showTimes = true,
    this.thin = false,
    this.color,
  });
  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? dragging, hover;
  @override
  Widget build(BuildContext context) {
    final total = widget.duration.inMilliseconds;
    final known = total > 0;
    final enabled = known && widget.onSeek != null;
    final value = !known
        ? 0.0
        : (dragging ??
                  widget.position.inMilliseconds.clamp(0, total) / total)
              .toDouble();
    final color = widget.color ?? accent;
    Widget bar = LayoutBuilder(
      builder: (context, box) {
        double at(double dx) => (dx / box.maxWidth).clamp(0.0, 1.0);
        final active = dragging != null || hover != null;
        final track = SizedBox(
          height: widget.thin ? 3 : 20,
          child: Stack(
            alignment: Alignment.centerLeft,
            clipBehavior: Clip.none,
            children: [
              AnimatedContainer(
                duration: motion(context, Dur.hover),
                height: widget.thin ? 3 : (active ? 5 : 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              FractionallySizedBox(
                widthFactor: value,
                child: AnimatedContainer(
                  duration: motion(context, Dur.hover),
                  height: widget.thin ? 3 : (active ? 5 : 3),
                  decoration: BoxDecoration(
                    color: enabled || widget.thin ? color : secondaryText,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              if (!widget.thin && enabled && active)
                Positioned(
                  left: value * box.maxWidth - 6,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      color: primaryText,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              if (!widget.thin && enabled && (hover != null || dragging != null))
                Positioned(
                  left: ((dragging ?? hover)! * box.maxWidth - 22).clamp(
                    0.0,
                    math.max(0.0, box.maxWidth - 44),
                  ),
                  top: -26,
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
        if (!enabled || widget.thin) return track;
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
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            known ? clock(shown) : '--:--',
            style: Txt.meta.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
        Expanded(child: bar),
        SizedBox(
          width: 44,
          child: Text(
            known ? clock(total) : '--:--',
            textAlign: TextAlign.right,
            style: Txt.meta.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
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
        padding: const EdgeInsets.only(bottom: Sp.l),
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
