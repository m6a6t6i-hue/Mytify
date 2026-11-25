import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'cover_tint.dart';
import 'design.dart';
import 'library_index.dart';
import 'main.dart';
import 'model.dart';
import 'widgets.dart';

/// Rebuilds on every player snapshot (position, state, device).
class PlayerListener extends StatelessWidget {
  final LibraryScreenState app;
  final Widget Function(BuildContext, AudioSnapshot) builder;
  const PlayerListener({super.key, required this.app, required this.builder});
  @override
  Widget build(BuildContext context) => StreamBuilder<AudioSnapshot>(
    stream: app.player.stream.snapshot,
    initialData: app.player.state,
    builder: (context, snap) => builder(context, snap.data ?? app.player.state),
  );
}

class TransportControls extends StatelessWidget {
  final LibraryScreenState app;
  final double play, icon, gap;
  final bool showModes;
  const TransportControls({
    super.key,
    required this.app,
    this.play = 40,
    this.icon = 22,
    this.gap = Sp.s,
    this.showModes = true,
  });
  @override
  Widget build(BuildContext context) {
    final has = app.current != null;
    final box = icon + 18;
    // Scales down instead of overflowing on very narrow screens or large text.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showModes) ...[
          IconAction(
            Icons.shuffle_rounded,
            app.queue.shuffled ? 'Wyłącz losowanie' : 'Losowa kolejność',
            has ? () => unawaited(app.toggleShuffle()) : null,
            active: app.queue.shuffled,
            size: icon - 2,
            box: box,
            color: app.queue.shuffled ? accent : secondaryText,
          ),
          SizedBox(width: gap),
        ],
        IconAction(
          Icons.skip_previous_rounded,
          'Poprzedni utwór',
          has ? () => unawaited(app.previousTrack()) : null,
          size: icon + 4,
          box: box,
        ),
        SizedBox(width: gap),
        PlayButton(
          playing: app.playing,
          size: play,
          onPressed: has || app.tracks.isNotEmpty
              ? () => unawaited(app.togglePlay())
              : null,
        ),
        SizedBox(width: gap),
        IconAction(
          Icons.skip_next_rounded,
          'Następny utwór',
          has ? () => unawaited(app.nextTrack()) : null,
          size: icon + 4,
          box: box,
        ),
        if (showModes) ...[
          SizedBox(width: gap),
          IconAction(
            Icons.repeat_rounded,
            app.queue.repeat ? 'Wyłącz powtarzanie' : 'Powtarzaj kolejkę',
            () => unawaited(app.toggleRepeat()),
            active: app.queue.repeat,
            size: icon - 2,
            box: box,
            color: app.queue.repeat ? accent : secondaryText,
          ),
        ],
      ],
    ),
    );
  }
}

class DeviceButton extends StatelessWidget {
  final LibraryScreenState app;
  final double size;
  const DeviceButton({super.key, required this.app, this.size = 20});
  @override
  Widget build(BuildContext context) {
    final remote = app.outputDevice != 'auto';
    final name = app.player.state.output?['name']?.toString();
    return IconAction(
      remote ? Icons.speaker_group_rounded : Icons.speaker_group_outlined,
      remote && name != null ? 'Odtwarzanie: $name' : 'Połącz z urządzeniem',
      app.showDevices,
      active: remote,
      size: size,
      color: remote ? accent : secondaryText,
    );
  }
}

/// Desktop bottom bar: track | transport + seek | device, volume, panels.
class PlayerBar extends StatelessWidget {
  final LibraryScreenState app;
  final bool panelOpen;
  final String panelTab;
  final void Function(String tab) onPanel;
  const PlayerBar({
    super.key,
    required this.app,
    required this.panelOpen,
    required this.panelTab,
    required this.onPanel,
  });
  @override
  Widget build(BuildContext context) => Container(
    height: 88,
    decoration: const BoxDecoration(
      color: background,
      border: Border(top: BorderSide(color: softBorder)),
    ),
    padding: const EdgeInsets.symmetric(horizontal: Sp.l),
    child: LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final side = (w * .28).clamp(180.0, 360.0);
        final compact = w < 980;
        final t = app.current;
        return Row(
          children: [
            SizedBox(
              width: side,
              child: t == null
                  ? const SizedBox()
                  : Row(
                      children: [
                        Tooltip(
                          message: 'Teraz odtwarzane',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(Rad.coverSmall),
                            onTap: () => onPanel('now'),
                            child: AnimatedSwitcher(
                              duration: motion(context, Dur.standard),
                              child: Artwork(
                                t.cover,
                                key: ValueKey(t.cover),
                                size: 56,
                                radius: Rad.coverSmall,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: Sp.m),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              InkWell(
                                onTap: () => app.go(Nav('artist', LibraryIndex.artistKeyOf(t.displayArtist))),
                                child: Text(
                                  t.displayArtist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Txt.meta,
                                ),
                              ),
                            ],
                          ),
                        ),
                        LikeButton(liked: t.liked, onPressed: () => unawaited(app.toggleLike(t)), size: 18, box: 32),
                      ],
                    ),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TransportControls(app: app, showModes: w > 720),
                      const SizedBox(height: 2),
                      PlayerListener(
                        app: app,
                        builder: (context, s) => SeekBar(
                          position: s.position,
                          duration: t == null ? Duration.zero : s.duration,
                          onSeek: t == null ? null : (d) => unawaited(app.seek(d)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              width: side,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DeviceButton(app: app),
                  IconAction(
                    app.volume <= 0
                        ? Icons.volume_off_rounded
                        : app.volume < 50
                        ? Icons.volume_down_rounded
                        : Icons.volume_up_rounded,
                    app.volume <= 0 ? 'Przywróć dźwięk' : 'Wycisz',
                    app.volumeAvailable ? () => unawaited(app.toggleMute()) : null,
                    color: secondaryText,
                  ),
                  if (!compact)
                    SizedBox(
                      width: 96,
                      child: Slider(
                        value: app.volume.clamp(0.0, 100.0),
                        max: 100,
                        onChanged: app.volumeAvailable ? app.setVolumeLive : null,
                        onChangeEnd: app.volumeAvailable
                            ? (v) => unawaited(app.commitVolume(v))
                            : null,
                      ),
                    ),
                  IconAction(
                    Icons.queue_music_rounded,
                    'Kolejka',
                    () => onPanel('queue'),
                    active: panelOpen && panelTab == 'queue',
                    color: panelOpen && panelTab == 'queue' ? accent : secondaryText,
                  ),
                  if (!compact)
                    IconAction(
                      Icons.view_sidebar_outlined,
                      panelOpen ? 'Zamknij panel' : 'Otwórz panel',
                      () => onPanel(''),
                      active: panelOpen,
                      color: panelOpen ? accent : secondaryText,
                    ),
                  IconAction(
                    Icons.open_in_full_rounded,
                    'Pełny ekran (F11)',
                    t == null ? null : app.openNowPlaying,
                    color: secondaryText,
                    size: 18,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// Right panel on desktop: now playing, queue, track details.
class SidePanel extends StatelessWidget {
  final LibraryScreenState app;
  final String tab;
  final ValueChanged<String> onTab;
  final VoidCallback onClose;
  const SidePanel({
    super.key,
    required this.app,
    required this.tab,
    required this.onTab,
    required this.onClose,
  });
  @override
  Widget build(BuildContext context) {
    final t = app.current;
    return ColoredBox(
      color: background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.s),
              child: Row(
                children: [
                  for (final (key, label) in const [
                    ('now', 'Odtwarzane'),
                    ('queue', 'Kolejka'),
                    ('info', 'Informacje'),
                  ])
                    Flexible(
                      child: Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: TextButton(
                        onPressed: () => onTab(key),
                        style: TextButton.styleFrom(
                          foregroundColor: tab == key ? primaryText : secondaryText,
                          backgroundColor: tab == key ? hoverFill : null,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          minimumSize: const Size(0, 32),
                        ),
                        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    ),
                  const Spacer(),
                  IconAction(Icons.close_rounded, 'Zamknij panel', onClose, size: 18, color: secondaryText),
                ],
              ),
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: motion(context, Dur.standard),
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.expand,
                children: [...previous, ?current],
              ),
              child: KeyedSubtree(
                key: ValueKey(tab),
                child: switch (tab) {
                  'queue' => QueueList(app: app),
                  'info' => t == null
                      ? const EmptyState(icon: Icons.info_outline_rounded, text: 'Nic nie jest odtwarzane')
                      : PlayerListener(
                          app: app,
                          builder: (context, s) => SingleChildScrollView(
                            padding: const EdgeInsets.all(Sp.l),
                            child: TrackFacts(track: t, snapshot: s),
                          ),
                        ),
                  _ => NowPlayingPanel(app: app),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NowPlayingPanel extends StatelessWidget {
  final LibraryScreenState app;
  const NowPlayingPanel({super.key, required this.app});
  @override
  Widget build(BuildContext context) {
    final t = app.current;
    if (t == null) {
      return const EmptyState(icon: Icons.music_note_rounded, text: 'Nic nie jest odtwarzane');
    }
    final album = app.index.albumByKey[t.albumKey];
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSwitcher(
              duration: motion(context, Dur.shared),
              child: Artwork(t.cover, key: ValueKey(t.cover), size: box.maxWidth - Sp.xxl),
            ),
            const SizedBox(height: Sp.l),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.title),
                      const SizedBox(height: Sp.xs),
                      InkWell(
                        onTap: () => app.go(Nav('artist', LibraryIndex.artistKeyOf(t.displayArtist))),
                        child: Text(t.displayArtist, style: Txt.sub),
                      ),
                      if (album != null && t.album.isNotEmpty)
                        InkWell(
                          onTap: () => app.go(Nav('album', album.key)),
                          child: Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(t.album, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.meta),
                          ),
                        ),
                    ],
                  ),
                ),
                LikeButton(liked: t.liked, onPressed: () => unawaited(app.toggleLike(t))),
              ],
            ),
            const SizedBox(height: Sp.l),
            Wrap(
              spacing: Sp.s,
              runSpacing: Sp.s,
              children: [
                for (final label in [
                  formatLabel(t),
                  ?qualityLabel([t]),
                  if (t.sampleRate > 0) sampleRateLabel(t.sampleRate),
                  ?bitDepthLabel(t),
                ])
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      border: Border.all(color: softBorder),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(label, style: Txt.meta),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TrackFacts extends StatelessWidget {
  final Track track;
  final AudioSnapshot snapshot;
  const TrackFacts({super.key, required this.track, required this.snapshot});
  @override
  Widget build(BuildContext context) {
    final t = track;
    final live = snapshot.currentId == t.id;
    final out = snapshot.output;
    final rows = <(String, String)>[
      ('Format', formatLabel(t)),
      if (bitrateLabel(t) != null) ('Bitrate', bitrateLabel(t)!),
      ('Częstotliwość', sampleRateLabel(t.sampleRate)),
      if (bitDepthLabel(t) != null) ('Głębia bitowa', bitDepthLabel(t)!),
      ('Długość', t.durationMs > 0 ? clock(t.durationMs) : 'brak danych'),
      ('Rozmiar', '${(t.size / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB'),
      ('Plik', t.fileName),
      ('Opis', t.edited ? 'poprawki w Mytify' : 'tagi w pliku'),
      if (live && out?['name'] != null) ('Wyjście', out!['name'].toString()),
      if (live && (out?['sampleRate'] as num? ?? 0) > 0)
        ('Sygnał wyjściowy', sampleRateLabel((out!['sampleRate'] as num).toInt())),
      if (live && snapshot.source?['resampled'] == true) ('Konwersja', 'zmiana częstotliwości'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 120, child: Text(k, style: Txt.meta)),
                Expanded(child: SelectableText(v, style: const TextStyle(fontSize: 13))),
              ],
            ),
          ),
      ],
    );
  }
}

class TrackInfoDialog extends StatelessWidget {
  final Track track;
  final AudioSnapshot snapshot;
  const TrackInfoDialog({super.key, required this.track, required this.snapshot});
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(track.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.title),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(child: TrackFacts(track: track, snapshot: snapshot)),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Zamknij')),
    ],
  );
}

class QueueList extends StatelessWidget {
  final LibraryScreenState app;
  final ScrollController? controller;
  const QueueList({super.key, required this.app, this.controller});
  @override
  Widget build(BuildContext context) {
    final items = app.queue.items;
    final at = app.queue.index;
    if (items.isEmpty) {
      return const EmptyState(icon: Icons.queue_music_rounded, text: 'Kolejka jest pusta');
    }
    final upcoming = items.length - at - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.s, Sp.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  upcoming > 0 ? 'Następne: ${trackCount(upcoming)}' : 'To ostatni utwór',
                  style: Txt.meta,
                ),
              ),
              if (upcoming > 0)
                TextButton(
                  onPressed: () => unawaited(app.clearUpcoming()),
                  style: TextButton.styleFrom(foregroundColor: secondaryText),
                  child: const Text('Wyczyść'),
                ),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            scrollController: controller,
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.only(bottom: Sp.l),
            itemCount: items.length,
            onReorderItem: (from, to) => unawaited(app.moveInQueue(from, to)),
            itemBuilder: (context, i) {
              final t = items[i];
              final current = i == at;
              final past = i < at;
              return Material(
                key: ValueKey(t.id),
                color: current ? selectedFill : Colors.transparent,
                child: InkWell(
                  onTap: current ? app.openNowPlaying : () => unawaited(app.jumpTo(t.id)),
                  onSecondaryTapUp: (d) => unawaited(app.trackMenu(t, at: d.globalPosition)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Sp.s, vertical: 6),
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: i,
                          enabled: !current,
                          child: SizedBox(
                            width: 28,
                            child: Icon(
                              Icons.drag_indicator_rounded,
                              size: 18,
                              color: current ? Colors.transparent : secondaryText.withValues(alpha: .5),
                            ),
                          ),
                        ),
                        Opacity(
                          opacity: past ? .5 : 1,
                          child: Artwork(t.cover, size: 40, radius: Rad.coverSmall),
                        ),
                        const SizedBox(width: Sp.m),
                        Expanded(
                          child: Opacity(
                            opacity: past ? .5 : 1,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: current ? accent : primaryText,
                                  ),
                                ),
                                Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.meta),
                              ],
                            ),
                          ),
                        ),
                        if (current)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: Sp.s),
                            child: PlayingBars(playing: app.playing, size: 14),
                          )
                        else
                          IconAction(
                            Icons.close_rounded,
                            'Usuń z kolejki',
                            () => unawaited(app.removeFromQueue(t.id)),
                            size: 16,
                            box: 32,
                            color: secondaryText,
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

void showQueueSheet(LibraryScreenState app) => showModalBottomSheet<void>(
  context: app.context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .72,
    child: StatefulBuilder(
      builder: (context, setLocal) => PlayerListener(
        app: app,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.s),
              child: Text('Kolejka', style: Txt.title),
            ),
            Expanded(child: QueueList(app: app)),
          ],
        ),
      ),
    ),
  ),
);

/// Full-screen player for both platforms. Esc / back closes it.
class NowPlayingScreen extends StatefulWidget {
  final LibraryScreenState app;
  const NowPlayingScreen({super.key, required this.app});
  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  bool chrome = true;
  Timer? idle;

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _wake();
    }
  }

  void _wake() {
    if (!chrome) setState(() => chrome = true);
    idle?.cancel();
    if (isDesktopLayout(context)) {
      idle = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => chrome = false);
      });
    }
  }

  @override
  void dispose() {
    idle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return PlayerListener(
      app: app,
      builder: (context, s) {
        final t = app.index.byId[s.currentId] ?? app.current;
        final desktop = isDesktopLayout(context);
        final size = MediaQuery.sizeOf(context);
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
            const SingleActivator(LogicalKeyboardKey.f11): () => Navigator.maybePop(context),
            const SingleActivator(LogicalKeyboardKey.space): () => unawaited(app.togglePlay()),
          },
          child: Focus(
            autofocus: true,
            child: MouseRegion(
              onHover: (_) => _wake(),
              child: Scaffold(
                backgroundColor: background,
                body: AmbientBackdrop(
                  cover: t?.cover,
                  child: SafeArea(
                    child: t == null
                        ? const EmptyState(icon: Icons.music_note_rounded, text: 'Nic nie jest odtwarzane')
                        : GestureDetector(
                            onVerticalDragEnd: desktop
                                ? null
                                : (d) {
                                    if ((d.primaryVelocity ?? 0) > 500) Navigator.maybePop(context);
                                  },
                            child: desktop
                                ? _desktop(context, app, t, s, size)
                                : _mobile(context, app, t, s, size),
                          ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _top(BuildContext context, LibraryScreenState app, Track t) => Row(
    children: [
      IconAction(Icons.keyboard_arrow_down_rounded, 'Zamknij', () => Navigator.maybePop(context), size: 28, box: 48),
      Expanded(
        child: Text(
          t.album.isEmpty ? '' : t.album,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Txt.meta.copyWith(color: primaryText.withValues(alpha: .8)),
        ),
      ),
      IconAction(
        Icons.more_horiz_rounded,
        'Więcej',
        () => unawaited(app.trackMenu(t, at: const Offset(9999, 60))),
        size: 24,
        box: 48,
      ),
    ],
  );

  Widget _titleRow(LibraryScreenState app, Track t, double fontSize) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800, letterSpacing: -.5, height: 1.15),
            ),
            const SizedBox(height: Sp.xs),
            Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.sub.copyWith(fontSize: 16, color: primaryText.withValues(alpha: .75))),
          ],
        ),
      ),
      LikeButton(liked: t.liked, onPressed: () => unawaited(app.toggleLike(t)), size: 26, box: 48),
    ],
  );

  Widget _mobile(BuildContext context, LibraryScreenState app, Track t, AudioSnapshot s, Size size) {
    if (size.width > size.height) {
      final art = (size.height - 96).clamp(96.0, size.width * .4);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.l),
        child: Column(
          children: [
            _top(context, app, t),
            Expanded(
              child: Row(
                children: [
                  Artwork(t.cover, size: art, radius: 10),
                  const SizedBox(width: Sp.xl),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _titleRow(app, t, 20),
                          const SizedBox(height: Sp.s),
                          SeekBar(position: s.position, duration: s.duration, onSeek: (d) => unawaited(app.seek(d))),
                          TransportControls(app: app, play: 56, icon: 26, gap: Sp.m),
                          Row(
                            children: [
                              DeviceButton(app: app, size: 22),
                              const Spacer(),
                              IconAction(Icons.queue_music_rounded, 'Kolejka', () => showQueueSheet(app), color: secondaryText),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final art = (size.width - Sp.xxl).clamp(120.0, size.height - 420 < 120 ? 120.0 : size.height - 420);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.l),
      child: Column(
        children: [
          _top(context, app, t),
          const Spacer(),
          Hero(
            tag: 'artwork',
            child: AnimatedSwitcher(
              duration: motion(context, Dur.shared),
              child: Artwork(t.cover, key: ValueKey(t.cover), size: art, radius: 10),
            ),
          ),
          const Spacer(),
          _titleRow(app, t, 22),
          const SizedBox(height: Sp.l),
          SeekBar(position: s.position, duration: s.duration, onSeek: (d) => unawaited(app.seek(d))),
          const SizedBox(height: Sp.s),
          TransportControls(app: app, play: 68, icon: 28, gap: Sp.m),
          const SizedBox(height: Sp.l),
          Row(
            children: [
              DeviceButton(app: app, size: 22),
              const Spacer(),
              IconAction(Icons.info_outline_rounded, 'Informacje o utworze', () => app.showTrackInfo(t), color: secondaryText),
              IconAction(Icons.queue_music_rounded, 'Kolejka', () => showQueueSheet(app), color: secondaryText),
            ],
          ),
          const SizedBox(height: Sp.s),
        ],
      ),
    );
  }

  Widget _desktop(BuildContext context, LibraryScreenState app, Track t, AudioSnapshot s, Size size) {
    final art = (size.height * .52).clamp(200.0, 560.0);
    return Padding(
      padding: const EdgeInsets.all(Sp.xl),
      child: Column(
        children: [
          AnimatedOpacity(
            opacity: chrome ? 1 : 0,
            duration: motion(context, Dur.standard),
            child: _top(context, app, t),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: art + 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSwitcher(
                      duration: motion(context, Dur.shared),
                      child: Artwork(t.cover, key: ValueKey(t.cover), size: art, radius: 10),
                    ),
                    const SizedBox(height: Sp.xl),
                    _titleRow(app, t, 30),
                  ],
                ),
              ),
            ),
          ),
          AnimatedOpacity(
            opacity: chrome ? 1 : 0,
            duration: motion(context, Dur.standard),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                children: [
                  SeekBar(position: s.position, duration: s.duration, onSeek: (d) => unawaited(app.seek(d))),
                  const SizedBox(height: Sp.s),
                  TransportControls(app: app, play: 56, icon: 26, gap: Sp.m),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mobile mini-player: one line, play/pause, device, thin progress. Swipe changes track.
class MiniPlayer extends StatelessWidget {
  final LibraryScreenState app;
  const MiniPlayer({super.key, required this.app});
  @override
  Widget build(BuildContext context) {
    final t = app.current;
    if (t == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.s, 0, Sp.s, Sp.xs),
      child: Material(
        color: elevated,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: app.openNowPlaying,
          child: GestureDetector(
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -350) unawaited(app.nextTrack());
              if (v > 350) unawaited(app.previousTrack());
            },
            child: SizedBox(
              height: 64,
              child: Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(Sp.s, Sp.s, Sp.xs, Sp.s),
                      child: Row(
                        children: [
                          Hero(
                            tag: 'artwork',
                            child: AnimatedSwitcher(
                              duration: motion(context, Dur.standard),
                              child: Artwork(t.cover, key: ValueKey(t.cover), size: 44, radius: Rad.coverSmall),
                            ),
                          ),
                          const SizedBox(width: Sp.m),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                                Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.meta.copyWith(fontSize: 13)),
                              ],
                            ),
                          ),
                          DeviceButton(app: app, size: 22),
                          IconButton(
                            tooltip: app.playing ? 'Wstrzymaj' : 'Odtwórz',
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              unawaited(app.togglePlay());
                            },
                            icon: AnimatedSwitcher(
                              duration: motion(context, Dur.standard),
                              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                              child: Icon(
                                app.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                key: ValueKey(app.playing),
                                size: 30,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  PlayerListener(
                    app: app,
                    builder: (context, s) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Sp.s),
                      child: SeekBar(position: s.position, duration: s.duration, showTimes: false, thin: true),
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

double homeArtSize(Size size) {
  final cap = size.height * .36;
  return (size.width - Sp.xxl).clamp(120.0, cap < 120 ? 120.0 : cap);
}

/// Large player at the top of mobile Home.
class HomePlayer extends StatelessWidget {
  final LibraryScreenState app;
  const HomePlayer({super.key, required this.app});
  @override
  Widget build(BuildContext context) {
    final t = app.current;
    if (t == null) return const SizedBox.shrink();
    final size = MediaQuery.sizeOf(context);
    final art = homeArtSize(size);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: GestureDetector(
              onTap: app.openNowPlaying,
              child: AnimatedSwitcher(
                duration: motion(context, Dur.shared),
                child: Artwork(t.cover, key: ValueKey(t.cover), size: art, radius: 10),
              ),
            ),
          ),
          const SizedBox(height: Sp.l),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: app.openNowPlaying,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -.4, height: 1.15)),
                      const SizedBox(height: 2),
                      Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.sub.copyWith(fontSize: 15)),
                    ],
                  ),
                ),
              ),
              LikeButton(liked: t.liked, onPressed: () => unawaited(app.toggleLike(t)), size: 24, box: 48),
            ],
          ),
          const SizedBox(height: Sp.s),
          PlayerListener(
            app: app,
            builder: (context, s) => SeekBar(position: s.position, duration: s.duration, onSeek: (d) => unawaited(app.seek(d))),
          ),
          const SizedBox(height: Sp.xs),
          Center(child: TransportControls(app: app, play: 60, icon: 26, gap: Sp.m)),
        ],
      ),
    );
  }
}
