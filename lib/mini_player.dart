import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'main.dart';
import 'player_ui.dart';
import 'widgets.dart';
import 'l10n.dart';

/// Floating mini player on the desktop: 244×82 ("mini") or 196×44 ("nano"),
/// borderless and on top. Drag anywhere to move, double click to open the full app.
class FloatingPlayer extends StatefulWidget {
  final LibraryScreenState app;
  final bool nano;
  const FloatingPlayer({super.key, required this.app, required this.nano});
  @override
  State<FloatingPlayer> createState() => _FloatingPlayerState();
}

class _FloatingPlayerState extends State<FloatingPlayer> {
  bool hover = false;
  LibraryScreenState get app => widget.app;

  void _drag() => unawaited(app.repository.windowAction({'action': 'drag'}));

  Widget _button(IconData icon, String tip, VoidCallback? onTap, {double size = 18, double box = 26, Color? color}) =>
      IconAction(icon, tip, onTap, size: size, box: box, color: onTap == null ? secondaryText.withValues(alpha: .5) : color ?? primaryText);

  Widget _play(bool playing, bool enabled, double d) => Tooltip(
    message: playing ? tr('Pauza') : tr('Odtwarzaj'),
    child: Material(
      color: enabled ? accent : elevated,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? () => unawaited(app.togglePlay()) : null,
        child: SizedBox(
          width: d,
          height: d,
          child: app.connecting
              ? Padding(padding: EdgeInsets.all(d * .26), child: CircularProgressIndicator(strokeWidth: 2, color: onAccent))
              : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: d * .62, color: enabled ? onAccent : secondaryText),
        ),
      ),
    ),
  );

  Widget _progress(double value) => LayoutBuilder(
    builder: (context, box) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) {
        final s = app.player.state;
        if (s.duration <= Duration.zero) return;
        unawaited(app.seek(s.duration * (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)));
      },
      child: SizedBox(
        height: 6,
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Container(
            height: 2,
            color: elevated,
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(widthFactor: value.clamp(0.0, 1.0), child: Container(color: accent)),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = app.current;
    final pinned = app.prefs.get<bool>('mini.pin', true);
    return Material(
      color: panel,
      child: MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => _drag(),
          onDoubleTap: () => app.setFloating(null),
          child: PlayerListener(
            app: app,
            builder: (context, s) {
              final enabled = t != null;
              final progress = s.duration > Duration.zero ? s.position.inMilliseconds / s.duration.inMilliseconds : 0.0;
              final title = Text(
                t?.title ?? tr('Wybierz utwór'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: widget.nano ? 11.5 : 12.5, fontWeight: FontWeight.w700),
              );
              final artist = Text(
                t?.displayArtist ?? 'Mytify',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: widget.nano ? 10.5 : 11, color: secondaryText),
              );
              final tools = [
                if (hover)
                  _button(
                    pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                    pinned ? tr('Nie trzymaj na wierzchu') : tr('Zawsze na wierzchu'),
                    () => app.setFloatingPin(!pinned),
                    size: 13,
                    box: 20,
                    color: pinned ? accent : secondaryText,
                  ),
                if (hover)
                  _button(
                    widget.nano ? Icons.unfold_more_rounded : Icons.unfold_less_rounded,
                    widget.nano ? tr('Większy mini odtwarzacz') : tr('Najmniejszy odtwarzacz'),
                    () => app.setFloating(widget.nano ? 'mini' : 'nano'),
                    size: 13,
                    box: 20,
                    color: secondaryText,
                  ),
                _button(Icons.open_in_full_rounded, tr('Pełna aplikacja (dwuklik)'), () => app.setFloating(null), size: 13, box: 20, color: secondaryText),
              ];
              if (widget.nano) {
                return Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(6, 4, 4, 0),
                        child: Row(
                          children: [
                            if (t != null) Artwork(t.cover, size: 30, radius: 4) else const SizedBox(width: 30),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [title, artist],
                              ),
                            ),
                            _play(s.playing, enabled, 24),
                            const SizedBox(width: 2),
                            ...hover ? tools.skip(1) : tools,
                          ],
                        ),
                      ),
                    ),
                    _progress(progress),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 7, 6, 0),
                      child: Row(
                        children: [
                          if (t != null) Artwork(t.cover, size: 54, radius: 6) else const SizedBox(width: 54),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, artist])),
                                    ...tools,
                                  ],
                                ),
                                const Spacer(),
                                Row(
                                  children: [
                                    LevelBars(playing: s.playing, width: 18, height: 14),
                                    const Spacer(),
                                    _button(Icons.skip_previous_rounded, tr('Poprzedni'), enabled ? () => unawaited(app.previousTrack()) : null),
                                    const SizedBox(width: 4),
                                    _play(s.playing, enabled, 28),
                                    const SizedBox(width: 4),
                                    _button(Icons.skip_next_rounded, tr('Następny'), enabled ? () => unawaited(app.nextTrack()) : null),
                                    const Spacer(),
                                    const SizedBox(width: 18),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _progress(progress),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
