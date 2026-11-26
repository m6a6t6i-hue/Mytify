import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'audio_settings.dart';
import 'cleanup.dart';
import 'cover_tint.dart';
import 'design.dart';
import 'downloads_ui.dart';
import 'ingest.dart';
import 'library_index.dart';
import 'links.dart';
import 'main.dart';
import 'model.dart';
import 'player_ui.dart';
import 'playlists.dart';
import 'track_table.dart';
import 'widgets.dart';
import 'l10n.dart';

Widget pageFor(LibraryScreenState app, Nav nav) {
  if (app.loading) return const Center(child: CircularProgressIndicator());
  if (app.startupError != null) {
    return EmptyState(
      icon: Icons.error_outline_rounded,
      text: app.startupError!,
      action: tr('Spróbuj ponownie'),
      onAction: () => unawaited(app.loadLibrary()),
    );
  }
  return switch (nav.page) {
    'search' => SearchPage(app: app),
    'library' => LibraryPage(app: app, filter: nav.arg ?? 'albums'),
    'album' => AlbumPage(app: app, albumKey: nav.arg!),
    'artist' => ArtistPage(app: app, artistKey: nav.arg!),
    'playlist' || 'liked' || 'recent' => CollectionPage(app: app, nav: nav),
    'settings' when nav.arg == 'sources' => SourcesPage(app: app),
    'settings' when nav.arg == 'import' && app.desktopMode && app.canDigitize => IngestView(state: app.ingest),
    'settings' => SettingsPage(app: app, section: nav.arg),
    'sources' => SourcesPage(app: app),
    'import' when app.canDigitize && !app.isPhone => IngestView(
      state: app.ingest,
      padding: app.desktopMode ? const EdgeInsets.fromLTRB(Sp.xl, Sp.xl, Sp.xl, Sp.xxl) : const EdgeInsets.all(Sp.l),
    ),
    'import' => SourcesPage(app: app),
    'downloads' => DownloadsPage(app: app),
    'cleanup' => CleanupPage(app: app),
    'transfer' when app.canTransfer => app.transferScreen(),
    _ => HomePage(app: app),
  };
}

String pageTitle(LibraryScreenState app, Nav nav) => switch (nav.page) {
  'search' => tr('Szukaj'),
  'library' => tr('Biblioteka'),
  'album' => app.index.albumByKey[nav.arg]?.title ?? tr('Album'),
  'artist' => app.index.artistByKey[nav.arg]?.name ?? tr('Artysta'),
  'playlist' => app.playlistById(nav.arg)?.name ?? tr('Playlista'),
  'liked' => tr('Polubione'),
  'recent' => tr('Ostatnio dodane'),
  'settings' => settingsTitle(nav.arg) ?? tr('Ustawienia'),
  'downloads' => tr('Pobrane'),
  'cleanup' => tr('Porządki'),
  'sources' => tr('Źródła muzyki'),
  'import' => tr('Płyty CD i winyle'),
  'transfer' => app.isPhone ? tr('Przesyłanie muzyki') : tr('Połącz telefon'),
  _ => tr('Start'),
};

EdgeInsets pagePadding(LibraryScreenState app) =>
    EdgeInsets.symmetric(horizontal: app.desktopMode ? Sp.xl : Sp.l);

// ============================================================== Home

class HomePage extends StatelessWidget {
  final LibraryScreenState app;
  const HomePage({super.key, required this.app});
  @override
  Widget build(BuildContext context) {
    final index = app.index;
    if (index.tracks.isEmpty) {
      return EmptyState(
        icon: Icons.library_music_outlined,
        text: tr('Biblioteka jest pusta'),
        action: tr('Dodaj muzykę'),
        onAction: () => app.showAddMusic(),
      );
    }
    final desktop = app.desktopMode;
    final h = app.prefs.history;
    final recentAlbums = h.recentAlbums(index, limit: 16);
    final added = index.albums.take(16).toList();
    final top = h.topTracks(index, limit: desktop ? 8 : 5);
    final artists = h.topArtists(index);
    final pinnedAlbums = app.prefs
        .list('pins')
        .where((p) => p.startsWith('album:'))
        .map((p) => index.albumByKey[p.substring(6)])
        .whereType<AlbumGroup>()
        .toList();
    final card = desktop ? 188.0 : 148.0;
    final sections = <Widget>[
      if (desktop && app.current != null) _ContinueHero(app: app),
      if (!desktop && app.current != null) HomePlayer(app: app),
      _Shortcuts(app: app),
      if (recentAlbums.isNotEmpty) ...[
        SectionHeader(tr('Ostatnio słuchane'), padding: _hp(desktop)),
        _albumShelf(app, recentAlbums, card),
      ],
      SectionHeader(
        tr('Ostatnio dodane'),
        padding: _hp(desktop),
        onMore: () => app.go(const Nav('recent')),
      ),
      _albumShelf(app, added, card),
      if (top.isNotEmpty) ...[
        SectionHeader(tr('Najczęściej słuchane'), padding: _hp(desktop)),
        _TopTracks(app: app, tracks: top),
      ],
      if (pinnedAlbums.isNotEmpty) ...[
        SectionHeader(tr('Przypięte'), padding: _hp(desktop)),
        _albumShelf(app, pinnedAlbums, card),
      ],
      if (app.playlists.isNotEmpty) ...[
        SectionHeader(
          tr('Playlisty'),
          padding: _hp(desktop),
          onMore: () => app.go(const Nav('library', 'playlists')),
        ),
        Shelf(
          itemCount: app.orderedPlaylists.length,
          height: card + 14,
          textHeight: cardText,
          itemWidth: card,
          padding: EdgeInsets.symmetric(horizontal: desktop ? Sp.l : Sp.s),
          gap: 0,
          itemBuilder: (context, i) => _playlistCard(app, app.orderedPlaylists[i], card),
        ),
      ],
      if (artists.isNotEmpty) ...[
        SectionHeader(
          tr('Ulubieni artyści'),
          padding: _hp(desktop),
          onMore: () => app.go(const Nav('library', 'artists')),
        ),
        Shelf(
          itemCount: artists.length,
          height: card + 14,
          textHeight: cardText,
          itemWidth: card,
          padding: EdgeInsets.symmetric(horizontal: desktop ? Sp.l : Sp.s),
          gap: 0,
          itemBuilder: (context, i) => _artistCard(app, artists[i], card),
        ),
      ],
      const SizedBox(height: Sp.xxl),
    ];
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (!desktop && n.depth == 0) {
          final size = MediaQuery.sizeOf(context);
          final threshold = homeArtSize(size) + 100;
          final visible = n.metrics.pixels < threshold;
          if (visible != app.homePlayerVisible) {
            app.refresh(() => app.homePlayerVisible = visible);
          }
        }
        return false;
      },
      child: ListView(
        key: const PageStorageKey('home'),
        padding: EdgeInsets.only(top: desktop ? Sp.l : 0),
        children: sections,
      ),
    );
  }

  static EdgeInsets _hp(bool desktop) =>
      EdgeInsets.fromLTRB(desktop ? Sp.xl : Sp.l, 20, Sp.s, Sp.xs);
}

/// Two title lines plus a subtitle line, scaled with system text size.
const cardText = 52.0;

Widget _albumShelf(LibraryScreenState app, List<AlbumGroup> albums, double card) => Shelf(
  itemCount: albums.length,
  height: card + 14,
  textHeight: cardText,
  itemWidth: card,
  gap: 0,
  padding: EdgeInsets.symmetric(horizontal: app.desktopMode ? Sp.l : Sp.s),
  itemBuilder: (context, i) => albumCard(app, albums[i], card),
);

Widget albumCard(LibraryScreenState app, AlbumGroup a, double size) {
  final current = app.current?.albumKey == a.key;
  return CollectionCard(
    cover: a.art.cover,
    title: a.title,
    subtitle: a.artist,
    size: size,
    current: current,
    playing: current && app.playing,
    onOpen: () => app.go(Nav('album', a.key)),
    onPlay: app.desktopMode ? () => unawaited(app.playAlbum(a)) : null,
    onMenu: (at) => unawaited(app.albumMenu(a, at: at)),
  );
}

Widget _playlistCard(LibraryScreenState app, MusicPlaylist p, double size) {
  final list = app.index.playlistTracks(p);
  return CollectionCard(
    cover: null,
    placeholder: PlaylistArt(tracks: list, size: size - Sp.l),
    title: p.name,
    subtitle: trackCount(list.length),
    size: size,
    onOpen: () => app.go(Nav('playlist', p.id)),
    onPlay: app.desktopMode && list.isNotEmpty ? () => unawaited(app.playTracks(list)) : null,
    onMenu: (at) => unawaited(app.playlistMenu(p, at: at)),
  );
}

Widget _artistCard(LibraryScreenState app, ArtistGroup a, double size) => CollectionCard(
  cover: a.art?.cover,
  title: a.name,
  subtitle: a.albums.isEmpty ? trackCount(a.tracks.length) : albumCount(a.albums.length),
  size: size,
  circle: true,
  onOpen: () => app.go(Nav('artist', a.key)),
);

class _ContinueHero extends StatelessWidget {
  final LibraryScreenState app;
  const _ContinueHero({required this.app});
  @override
  Widget build(BuildContext context) {
    final t = app.current!;
    final album = app.index.albumByKey[t.albumKey];
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.xl, 0, Sp.xl, Sp.s),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Rad.panel),
        child: AmbientBackdrop(
          cover: t.cover,
          strength: .7,
          child: Padding(
            padding: const EdgeInsets.all(Sp.xl),
            child: Row(
              children: [
                GestureDetector(
                  onTap: album == null ? null : () => app.go(Nav('album', album.key)),
                  child: Artwork(t.cover, size: 152),
                ),
                const SizedBox(width: Sp.xl),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app.playing ? tr('Teraz odtwarzane') : tr('Kontynuuj słuchanie'), style: Txt.meta.copyWith(color: primaryText.withValues(alpha: .7))),
                      const SizedBox(height: Sp.s),
                      Text(album?.title ?? t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.display),
                      const SizedBox(height: Sp.xs),
                      Text('${t.title} · ${t.displayArtist}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.sub.copyWith(color: primaryText.withValues(alpha: .8))),
                      const SizedBox(height: Sp.l),
                      Row(
                        children: [
                          PlayButton(playing: app.playing, size: 48, onPressed: () => unawaited(app.togglePlay())),
                          const SizedBox(width: Sp.m),
                          if (album != null && album.tracks.length > 1)
                            TextButton(
                              onPressed: () => app.go(Nav('album', album.key)),
                              child: Text(tr('Otwórz album')),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Shortcuts extends StatelessWidget {
  final LibraryScreenState app;
  const _Shortcuts({required this.app});
  @override
  Widget build(BuildContext context) {
    final liked = app.index.liked();
    Widget chip(Widget lead, String label, String? sub, VoidCallback onTap) => Expanded(
      child: Material(
        color: panel,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Row(
              children: [
                lead,
                const SizedBox(width: Sp.m),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      if (sub != null) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.meta),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final desktop = app.desktopMode;
    return Padding(
      padding: EdgeInsets.fromLTRB(desktop ? Sp.xl : Sp.l, desktop ? Sp.s : Sp.l, desktop ? Sp.xl : Sp.l, 0),
      child: Row(
        children: [
          chip(
            const LikedArt(size: 56),
            tr('Polubione'),
            trackCount(liked.length),
            () => app.go(const Nav('liked')),
          ),
          const SizedBox(width: Sp.s),
          chip(
            Container(
              width: 56,
              height: 56,
              color: elevated,
              child: Icon(Icons.shuffle_rounded, color: accent),
            ),
            tr('Losowo'),
            tr('Cała biblioteka'),
            () => unawaited(app.playTracks(app.tracks, shuffle: true)),
          ),
        ],
      ),
    );
  }
}

class _TopTracks extends StatelessWidget {
  final LibraryScreenState app;
  final List<Track> tracks;
  const _TopTracks({required this.app, required this.tracks});
  @override
  Widget build(BuildContext context) {
    final desktop = app.desktopMode;
    Widget row(Track t) => TrackRow(
      app: app,
      track: t,
      list: tracks,
      showCover: true,
      showArtist: true,
      selectable: false,
    );
    if (!desktop) {
      return Column(children: [for (final t in tracks) row(t)]);
    }
    final half = (tracks.length / 2).ceil();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.l),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Column(children: [for (final t in tracks.take(half)) row(t)])),
          const SizedBox(width: Sp.l),
          Expanded(child: Column(children: [for (final t in tracks.skip(half)) row(t)])),
        ],
      ),
    );
  }
}

// ============================================================== Track row

/// One row for every track list. Desktop: select / double-click play / drag.
class TrackRow extends StatelessWidget {
  final LibraryScreenState app;
  final Track track;
  final List<Track> list;
  final int? number;
  final bool showCover, showArtist, showAlbum, selectable, draggable;
  final MusicPlaylist? playlist;
  const TrackRow({
    super.key,
    required this.app,
    required this.track,
    required this.list,
    this.number,
    this.showCover = false,
    this.showArtist = true,
    this.showAlbum = false,
    this.selectable = true,
    this.draggable = true,
    this.playlist,
  });

  @override
  Widget build(BuildContext context) {
    final t = track;
    final desktop = app.desktopMode;
    final current = app.current?.id == t.id;
    final isSelected = selectable && app.selected.contains(t.id);
    final dim = !t.available;
    final titleStyle = TextStyle(
      fontSize: desktop ? 14 : 15.5,
      fontWeight: FontWeight.w500,
      color: current ? accent : (dim ? secondaryText : primaryText),
    );
    final lead = SizedBox(
      width: desktop ? 36 : 32,
      child: current
          ? Center(child: PlayingBars(playing: app.playing, size: 14))
          : number == null
          ? null
          : Text(
              '$number',
              textAlign: TextAlign.center,
              style: Txt.meta.copyWith(fontSize: desktop ? 13 : 14, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
    );
    final more = IconAction(
      Icons.more_horiz_rounded,
      tr('Więcej'),
      () => unawaited(app.trackMenu(t, playlist: playlist, within: list)),
      size: 20,
      box: desktop ? 32 : 44,
      color: secondaryText,
    );
    final table = desktop && showAlbum;
    final compact = table && compactTable(app.prefs);
    final artistColumn = table && visibleColumns(app.prefs).any((c) => c.key == 'artist');
    final content = table
        ? Row(
            children: [
              lead,
              if (showCover && !compact) ...[
                Artwork(t.cover, size: 40, radius: Rad.coverSmall),
                const SizedBox(width: Sp.m),
              ] else
                const SizedBox(width: Sp.s),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
                    if (!compact && !artistColumn)
                      Text(
                        dim ? tr('{0} · niedostępny', [t.displayArtist]) : t.displayArtist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Txt.meta.copyWith(fontSize: 12.5),
                      ),
                  ],
                ),
              ),
              ...tableCells(app, t),
              Opacity(
                opacity: t.liked ? 1 : 0,
                child: LikeButton(liked: t.liked, onPressed: () => unawaited(app.toggleLike(t)), size: 16, box: 32),
              ),
              more,
            ],
          )
        : Row(
      children: [
        if (number != null || !showCover) lead,
        if (showCover) ...[
          if (number != null) const SizedBox(width: Sp.xs),
          Artwork(t.cover, size: desktop ? 40 : 48, radius: Rad.coverSmall),
          const SizedBox(width: Sp.m),
        ] else
          const SizedBox(width: Sp.s),
        Expanded(
          flex: 5,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
              if (showArtist && (!desktop || showCover || !showAlbum))
                Text(
                  dim ? tr('{0} · niedostępny', [t.displayArtist]) : t.displayArtist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Txt.meta.copyWith(fontSize: desktop ? 12.5 : 13.5),
                ),
            ],
          ),
        ),
        if (desktop && showAlbum)
          Expanded(
            flex: 4,
            child: Text(t.displayAlbum, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.meta.copyWith(fontSize: 13)),
          ),
        if (desktop && selectable)
          Opacity(
            opacity: t.liked ? 1 : .0,
            child: LikeButton(liked: t.liked, onPressed: () => unawaited(app.toggleLike(t)), size: 16, box: 32),
          ),
        SizedBox(
          width: desktop ? 52 : 44,
          child: Text(
            t.durationMs > 0 ? clock(t.durationMs) : '',
            textAlign: TextAlign.right,
            style: Txt.meta.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
        const SizedBox(width: Sp.xs),
        more,
      ],
    );
    final height = compact ? 34.0 : desktop ? (showCover ? 52.0 : 40.0) : 60.0;
    Widget row = HoverBuilder(
      builder: (context, hovered) => AnimatedContainer(
        duration: motion(context, Dur.hover),
        height: height,
        padding: EdgeInsets.symmetric(horizontal: desktop ? Sp.s : Sp.xs),
        decoration: BoxDecoration(
          color: isSelected
              ? hoverFill
              : hovered && desktop
              ? hoverFill
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: content,
      ),
    );
    if (!desktop) {
      return InkWell(
        onTap: () => unawaited(app.playTracks(list, start: t)),
        onLongPress: () => unawaited(app.trackMenu(t, playlist: playlist, within: list)),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: Sp.s), child: row),
      );
    }
    row = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: selectable
          ? () {
              final keys = HardwareKeyboard.instance;
              app.selectTrack(t, list, toggle: keys.isControlPressed, range: keys.isShiftPressed);
            }
          : null,
      onDoubleTap: () => unawaited(app.playTracks(list, start: t)),
      onSecondaryTapUp: (d) {
        if (selectable && !app.selected.contains(t.id)) app.selectTrack(t, list);
        unawaited(app.trackMenu(t, at: d.globalPosition, playlist: playlist, within: list));
      },
      child: row,
    );
    if (!selectable || !draggable) return row;
    return Draggable<List<Track>>(
      data: app.selected.contains(t.id) && app.selected.length > 1 ? app.selectedTracks : [t],
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: elevated,
        borderRadius: BorderRadius.circular(8),
        elevation: 6,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            app.selected.contains(t.id) && app.selected.length > 1 ? trackCount(app.selected.length) : t.title,
            style: TextStyle(fontSize: 13, color: primaryText),
          ),
        ),
      ),
      child: row,
    );
  }
}

class TrackListHeader extends StatelessWidget {
  final LibraryScreenState app;
  final bool numbered, showAlbum;
  final String? sort;
  final bool descending;
  final void Function(String key)? onSort;
  const TrackListHeader({
    super.key,
    required this.app,
    this.numbered = true,
    this.showAlbum = false,
    this.sort,
    this.descending = false,
    this.onSort,
  });
  @override
  Widget build(BuildContext context) {
    Widget head(String label, String key, {int flex = 0, TextAlign align = TextAlign.left, double? width}) {
      final active = sort == key;
      final text = Row(
        mainAxisAlignment: align == TextAlign.right ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: Txt.meta.copyWith(color: active ? primaryText : secondaryText, fontWeight: FontWeight.w600))),
          if (active) Icon(descending ? Icons.arrow_drop_down_rounded : Icons.arrow_drop_up_rounded, size: 18, color: primaryText),
        ],
      );
      final child = onSort == null ? text : InkWell(onTap: () => onSort!(key), child: text);
      if (width != null) return SizedBox(width: width, child: child);
      return Expanded(flex: flex, child: child);
    }

    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: Sp.s),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: softBorder))),
      child: Row(
        children: [
          SizedBox(width: 36, child: Text(numbered ? '#' : '', textAlign: TextAlign.center, style: Txt.meta)),
          const SizedBox(width: Sp.s),
          head(tr('Tytuł'), 'title', flex: 5),
          if (showAlbum) head(tr('Album'), 'album', flex: 4),
          const SizedBox(width: 32),
          head(tr('Czas'), 'duration', width: 52, align: TextAlign.right),
          const SizedBox(width: 36),
        ],
      ),
    );
  }
}

// ============================================================== Library

class LibraryPage extends StatefulWidget {
  final LibraryScreenState app;
  final String filter;
  const LibraryPage({super.key, required this.app, required this.filter});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final filterText = TextEditingController();
  bool filtering = false;

  @override
  void dispose() {
    filterText.dispose();
    super.dispose();
  }

  LibraryScreenState get app => widget.app;

  static final tabs = [
    ('all', tr('Wszystkie')),
    ('albums', tr('Albumy')),
    ('artists', tr('Artyści')),
    ('tracks', tr('Utwory')),
    ('playlists', tr('Playlisty')),
    ('downloaded', tr('Pobrane')),
  ];

  static final sorts = {
    'albums': [('added', tr('Ostatnio dodane')), ('title', tr('Tytuł')), ('artist', tr('Artysta')), ('played', tr('Ostatnio słuchane')), ('plays', tr('Najczęściej słuchane'))],
    'tracks': [('added', tr('Ostatnio dodane')), ('title', tr('Tytuł')), ('artist', tr('Artysta')), ('album', tr('Album')), ('duration', tr('Długość')), ('played', tr('Ostatnio słuchane')), ('plays', tr('Najczęściej słuchane'))],
    'artists': [('name', tr('Nazwa')), ('albums', tr('Liczba albumów'))],
    'playlists': [('name', tr('Nazwa')), ('size', tr('Liczba utworów'))],
  };

  String get filter => !app.desktopMode || widget.filter != 'all' ? widget.filter : 'albums';
  String sortFor(String f) => app.prefs.get('sort.$f', sorts[f]?.first.$1 ?? 'added');
  bool descFor(String f) => app.prefs.get('desc.$f', false);
  String viewFor(String f) => app.prefs.get('view.$f', f == 'tracks' ? 'list' : 'grid');

  bool _match(String text) {
    final words = LibraryIndex.terms(filterText.text);
    if (words.isEmpty) return true;
    final key = searchKey(text);
    return words.every(key.contains);
  }

  Object? _albumsKey, _tracksKey;
  List<AlbumGroup> _albumsCache = const [];
  List<Track> _tracksCache = const [];

  List<AlbumGroup> _albums() {
    final h = app.prefs.history;
    final s = sortFor('albums');
    final key = Object.hash(identityHashCode(app.index), s, filterText.text, h.revision);
    if (key == _albumsKey) return _albumsCache;
    final index = app.index;
    final list = filterText.text.trim().isEmpty ? List.of(index.albums) : index.searchAlbums(filterText.text);
    final last = <String, int>{}, count = <String, int>{};
    if (s == 'played' || s == 'plays') {
      for (final a in list) {
        last[a.key] = a.tracks.fold(0, (m, t) => (h.lastPlayed[t.id] ?? 0) > m ? h.lastPlayed[t.id]! : m);
        count[a.key] = a.tracks.fold(0, (m, t) => m + h.count(t.id));
      }
    }
    int cmp(AlbumGroup a, AlbumGroup b) => switch (s) {
      'title' => index.albumTitleKey[a.key]!.compareTo(index.albumTitleKey[b.key]!),
      'artist' => index.albumArtistKey[a.key]!.compareTo(index.albumArtistKey[b.key]!),
      'played' => last[b.key]!.compareTo(last[a.key]!),
      'plays' => count[b.key]!.compareTo(count[a.key]!),
      _ => b.addedAt.compareTo(a.addedAt),
    };
    list.sort(cmp);
    _albumsKey = key;
    return _albumsCache = list;
  }

  List<Track> _tracks() {
    final h = app.prefs.history;
    final s = sortFor('tracks');
    final desc = descFor('tracks');
    final key = Object.hash(identityHashCode(app.index), s, desc, filterText.text, h.revision);
    if (key == _tracksKey) return _tracksCache;
    final index = app.index;
    final list = filterText.text.trim().isEmpty ? List.of(index.tracks) : index.searchTracks(filterText.text);
    int cmp(Track a, Track b) => switch (s) {
      'title' => index.titleKey[a.id]!.compareTo(index.titleKey[b.id]!),
      'artist' => index.artistAlbumKey[a.id]!.compareTo(index.artistAlbumKey[b.id]!),
      'album' => index.albumNameKey[a.id]!.compareTo(index.albumNameKey[b.id]!) != 0
          ? index.albumNameKey[a.id]!.compareTo(index.albumNameKey[b.id]!)
          : albumOrder(a, b),
      'duration' => a.durationMs.compareTo(b.durationMs),
      'played' => (h.lastPlayed[b.id] ?? 0).compareTo(h.lastPlayed[a.id] ?? 0),
      'plays' => h.count(b.id).compareTo(h.count(a.id)),
      _ => b.addedAt.compareTo(a.addedAt),
    };
    if (desc) {
      list.sort((a, b) => cmp(b, a));
    } else {
      list.sort(cmp);
    }
    _tracksKey = key;
    return _tracksCache = list;
  }

  List<ArtistGroup> _artists() {
    final list = app.index.artists.where((a) => a.albums.isNotEmpty && _match(a.name)).toList();
    if (sortFor('artists') == 'albums') list.sort((a, b) => b.albums.length.compareTo(a.albums.length));
    return list;
  }

  List<MusicPlaylist> _playlists() {
    final list = app.orderedPlaylists.where((p) => _match(p.name)).toList();
    if (sortFor('playlists') == 'size') list.sort((a, b) => b.ids.length.compareTo(a.ids.length));
    return list;
  }

  void _setSort(String f, String key) => app.refresh(() {
    if (sortFor(f) == key) {
      app.prefs.set('desc.$f', !descFor(f));
    } else {
      app.prefs.set('sort.$f', key);
      app.prefs.set('desc.$f', false);
    }
  });

  @override
  Widget build(BuildContext context) {
    final desktop = app.desktopMode;
    final f = filter;
    final pad = pagePadding(app);
    final coverSize = desktop ? app.prefs.number('coverSize', 184).clamp(140, 240).toDouble() : 168.0;
    final view = viewFor(f);
    final slivers = <Widget>[];
    switch (f) {
      case 'albums':
        final list = _albums();
        slivers.add(view == 'grid' ? _albumGrid(list, coverSize) : _albumList(list));
        if (list.isEmpty) slivers.add(_none());
      case 'artists':
        final list = _artists();
        slivers.add(view == 'grid'
            ? _grid(list.length, coverSize, (i) => _artistCard(app, list[i], coverSize))
            : SliverList.builder(
                itemCount: list.length,
                itemBuilder: (context, i) => _listTile(
                  Artwork(list[i].art?.cover, size: 52, circle: true),
                  list[i].name,
                  albumCount(list[i].albums.length),
                  () => app.go(Nav('artist', list[i].key)),
                ),
              ));
        if (list.isEmpty) slivers.add(_none());
      case 'tracks':
        final list = _tracks();
        app.visibleList = list;
        app.visiblePlaylist = null;
        if (desktop) {
          slivers.add(SliverPersistentHeader(
            pinned: true,
            delegate: _HeaderDelegate(
              ColoredBox(
                color: background,
                child: Padding(
                  padding: pad,
                  child: TrackTableHeader(
                    app: app,
                    sort: sortFor('tracks'),
                    descending: descFor('tracks'),
                    onSort: (k) => _setSort('tracks', k),
                  ),
                ),
              ),
            ),
          ));
        }
        slivers.add(SliverPadding(
          padding: desktop ? pad : EdgeInsets.zero,
          sliver: SliverList.builder(
            itemCount: list.length,
            itemBuilder: (context, i) => TrackRow(
              app: app,
              track: list[i],
              list: list,
              showCover: true,
              showAlbum: desktop,
            ),
          ),
        ));
        if (list.isEmpty) slivers.add(_none());
      case 'downloaded':
        // Offline copies on this device; they play without any network.
        final list = _tracks().where((t) => t.offline).toList();
        app.visibleList = list;
        app.visiblePlaylist = null;
        slivers.add(SliverToBoxAdapter(
          child: Padding(
            padding: pad.copyWith(bottom: Sp.s),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => app.go(const Nav('downloads')),
                icon: const Icon(Icons.download_for_offline_outlined, size: 18),
                label: Text(tr('Kolejka i miejsce')),
              ),
            ),
          ),
        ));
        slivers.add(SliverPadding(
          padding: desktop ? pad : EdgeInsets.zero,
          sliver: SliverList.builder(
            itemCount: list.length,
            itemBuilder: (context, i) => TrackRow(app: app, track: list[i], list: list, showCover: true, showAlbum: desktop),
          ),
        ));
        if (list.isEmpty) {
          slivers.add(SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(Sp.xl),
              child: Text(tr('Brak pobranych utworów. Wybierz „Pobierz offline” w menu utworu, albumu lub playlisty.'), style: Txt.sub, textAlign: TextAlign.center),
            ),
          ));
        }
      case 'playlists':
        final list = _playlists();
        slivers.add(view == 'grid'
            ? _grid(list.length + 1, coverSize, (i) => i == 0 ? _likedCard(coverSize) : _playlistCard(app, list[i - 1], coverSize))
            : SliverList.builder(
                itemCount: list.length + 1,
                itemBuilder: (context, i) => i == 0 ? _likedTile() : _playlistTile(list[i - 1]),
              ));
      default:
        slivers.addAll(_everything());
    }
    return CustomScrollView(
      key: PageStorageKey('library:$f'),
      slivers: [
        SliverToBoxAdapter(child: _header(f, desktop, pad)),
        ...slivers,
        const SliverToBoxAdapter(child: SizedBox(height: Sp.xxl)),
      ],
    );
  }

  Widget _header(String f, bool desktop, EdgeInsets pad) {
    final options = sorts[f];
    return Padding(
      padding: pad.copyWith(top: desktop ? Sp.xl : Sp.s, bottom: Sp.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (desktop)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.m),
              child: Text(
                switch (f) { 'artists' => tr('Artyści'), 'tracks' => tr('Utwory'), 'playlists' => tr('Playlisty'), 'downloaded' => tr('Pobrane'), _ => tr('Albumy') },
                style: Txt.display,
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (key, label) in tabs)
                  if ((!desktop || key != 'all') &&
                      (key != 'downloaded' || app.networkProtocols.isNotEmpty || app.index.tracks.any((t) => t.offline)))
                    Padding(
                      padding: const EdgeInsets.only(right: Sp.s),
                      child: _FilterChip(
                        label: label,
                        selected: key == f,
                        onTap: () => app.replaceRoute(Nav('library', key)),
                      ),
                    ),
              ],
            ),
          ),
          if (f != 'all')
            Padding(
              padding: const EdgeInsets.only(top: Sp.s),
              child: Row(
                children: [
                  if (options != null)
                    PopupMenuButton<String>(
                      tooltip: tr('Sortowanie'),
                      initialValue: sortFor(f),
                      onSelected: (k) => _setSort(f, k),
                      itemBuilder: (_) => [for (final (k, l) in options) PopupMenuItem(value: k, height: 36, child: Text(l))],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: Sp.s),
                        child: Row(
                          children: [
                            Icon(Icons.swap_vert_rounded, size: 18, color: secondaryText),
                            const SizedBox(width: Sp.xs),
                            Text(options.firstWhere((o) => o.$1 == sortFor(f), orElse: () => options.first).$2, style: Txt.sub),
                          ],
                        ),
                      ),
                    ),
                  const Spacer(),
                  if (filtering || desktop)
                    SizedBox(
                      width: desktop ? 220 : 160,
                      height: 36,
                      child: TextField(
                        controller: filterText,
                        autofocus: filtering && !desktop,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(fontSize: 13.5),
                        decoration: InputDecoration(
                          hintText: tr('Filtruj'),
                          prefixIcon: const Icon(Icons.filter_list_rounded, size: 18),
                          prefixIconConstraints: const BoxConstraints(minWidth: 34),
                          suffixIcon: filterText.text.isEmpty
                              ? null
                              : IconAction(Icons.close_rounded, tr('Wyczyść'), () => setState(filterText.clear), size: 16, box: 32),
                          contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                      ),
                    )
                  else
                    IconAction(Icons.search_rounded, tr('Filtruj'), () => setState(() => filtering = true), color: secondaryText, box: 44),
                  if (f != 'tracks') ...[
                    const SizedBox(width: Sp.xs),
                    IconAction(
                      viewFor(f) == 'grid' ? Icons.view_list_rounded : Icons.grid_view_rounded,
                      viewFor(f) == 'grid' ? tr('Widok listy') : tr('Widok siatki'),
                      () => app.refresh(() => app.prefs.set('view.$f', viewFor(f) == 'grid' ? 'list' : 'grid')),
                      color: secondaryText,
                      box: desktop ? 36 : 44,
                    ),
                  ],
                  if (desktop && f != 'tracks' && viewFor(f) == 'grid')
                    SizedBox(
                      width: 110,
                      child: Tooltip(
                        message: tr('Rozmiar okładek'),
                        child: Slider(
                          value: app.prefs.number('coverSize', 184).clamp(140, 240).toDouble(),
                          min: 140,
                          max: 240,
                          onChanged: (v) => app.refresh(() => app.prefs.set('coverSize', v)),
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

  Widget _none() => SliverToBoxAdapter(
    child: Padding(
      padding: EdgeInsets.all(Sp.xxl),
      child: Center(child: Text(tr('Brak wyników'), style: Txt.sub)),
    ),
  );

  Widget _grid(int count, double size, Widget Function(int) item) => SliverPadding(
    padding: EdgeInsets.symmetric(horizontal: app.desktopMode ? Sp.l : Sp.s),
    sliver: SliverLayoutBuilder(
      builder: (context, c) {
        final columns = (c.crossAxisExtent / size).floor().clamp(2, 12);
        final w = c.crossAxisExtent / columns;
        return SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: w + 14 + MediaQuery.textScalerOf(context).scale(cardText),
          ),
          itemCount: count,
          itemBuilder: (context, i) => LayoutBuilder(builder: (context, b) => SizedBox(width: b.maxWidth, child: _sized(item(i), b.maxWidth))),
        );
      },
    ),
  );

  // Cards take their size from the cell, so the grid adapts to window width.
  Widget _sized(Widget card, double width) {
    if (card is CollectionCard) {
      return CollectionCard(
        cover: card.cover,
        title: card.title,
        subtitle: card.subtitle,
        size: width,
        circle: card.circle,
        current: card.current,
        playing: card.playing,
        onOpen: card.onOpen,
        onPlay: card.onPlay,
        onMenu: card.onMenu,
        placeholder: card.placeholder is PlaylistArt
            ? PlaylistArt(tracks: (card.placeholder! as PlaylistArt).tracks, size: width - Sp.l)
            : card.placeholder is LikedArt
            ? LikedArt(size: width - Sp.l)
            : card.placeholder,
      );
    }
    return card;
  }

  Widget _albumGrid(List<AlbumGroup> list, double size) =>
      _grid(list.length, size, (i) => albumCard(app, list[i], size));

  Widget _albumList(List<AlbumGroup> list) => SliverList.builder(
    itemCount: list.length,
    itemBuilder: (context, i) {
      final a = list[i];
      return _listTile(
        Artwork(a.art.cover, size: 52, radius: Rad.coverSmall),
        a.title,
        '${a.artist} · ${trackCount(a.tracks.length)}',
        () => app.go(Nav('album', a.key)),
        current: app.current?.albumKey == a.key,
        onMenu: (at) => unawaited(app.albumMenu(a, at: at)),
      );
    },
  );

  Widget _listTile(Widget lead, String title, String sub, VoidCallback onTap, {bool current = false, void Function(Offset)? onMenu, Widget? trailing}) => InkWell(
    onTap: onTap,
    onLongPress: onMenu == null ? null : () => onMenu(Offset.zero),
    onSecondaryTapUp: onMenu == null ? null : (d) => onMenu(d.globalPosition),
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: app.desktopMode ? Sp.xl : Sp.l, vertical: 6),
      child: Row(
        children: [
          lead,
          const SizedBox(width: Sp.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: current ? accent : primaryText)),
                const SizedBox(height: 2),
                Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.meta.copyWith(fontSize: 13)),
              ],
            ),
          ),
          if (current) PlayingBars(playing: app.playing, size: 14),
          ?trailing,
        ],
      ),
    ),
  );

  Widget _likedCard(double size) => CollectionCard(
    cover: null,
    placeholder: LikedArt(size: size - Sp.l),
    title: tr('Polubione'),
    subtitle: trackCount(app.index.liked().length),
    size: size,
    onOpen: () => app.go(const Nav('liked')),
    onPlay: app.desktopMode && app.index.liked().isNotEmpty ? () => unawaited(app.playTracks(app.index.liked())) : null,
  );

  Widget _likedTile() => _listTile(
    const LikedArt(size: 52),
    tr('Polubione'),
    trackCount(app.index.liked().length),
    () => app.go(const Nav('liked')),
    trailing: Padding(
      padding: EdgeInsets.only(left: Sp.s),
      child: Icon(Icons.push_pin_rounded, size: 16, color: accent),
    ),
  );

  Widget _playlistTile(MusicPlaylist p) {
    final list = app.index.playlistTracks(p);
    return _listTile(
      PlaylistArt(tracks: list, size: 52),
      p.name,
      trackCount(list.length),
      () => app.go(Nav('playlist', p.id)),
      onMenu: (at) => unawaited(app.playlistMenu(p, at: at)),
      trailing: app.prefs.pinned('playlist:${p.id}')
          ? Padding(padding: EdgeInsets.only(left: Sp.s), child: Icon(Icons.push_pin_rounded, size: 16, color: secondaryText))
          : null,
    );
  }

  List<Widget> _everything() {
    final pins = app.prefs.list('pins');
    final pinnedAlbums = pins.where((p) => p.startsWith('album:')).map((p) => app.index.albumByKey[p.substring(6)]).whereType<AlbumGroup>();
    final albums = _albums();
    return [
      SliverToBoxAdapter(child: _likedTile()),
      for (final p in _playlists()) SliverToBoxAdapter(child: _playlistTile(p)),
      for (final a in pinnedAlbums)
        SliverToBoxAdapter(
          child: _listTile(
            Artwork(a.art.cover, size: 52, radius: Rad.coverSmall),
            a.title,
            a.artist,
            () => app.go(Nav('album', a.key)),
            onMenu: (at) => unawaited(app.albumMenu(a, at: at)),
            trailing: Padding(padding: EdgeInsets.only(left: Sp.s), child: Icon(Icons.push_pin_rounded, size: 16, color: secondaryText)),
          ),
        ),
      SliverToBoxAdapter(child: SectionHeader(tr('Albumy'), padding: const EdgeInsets.fromLTRB(Sp.l, Sp.l, Sp.s, Sp.xs), onMore: () => app.replaceRoute(const Nav('library', 'albums')))),
      _albumList(albums.take(30).toList()),
    ];
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
    color: selected ? primaryText : elevated,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: AnimatedContainer(
        duration: motion(context, Dur.standard),
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          label,
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: selected ? background : primaryText),
        ),
      ),
    ),
  );
}

class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  _HeaderDelegate(this.child);
  @override
  double get minExtent => 34;
  @override
  double get maxExtent => 34;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => child;
  @override
  bool shouldRebuild(_HeaderDelegate old) => true;
}

// ============================================================== Album

class AlbumPage extends StatelessWidget {
  final LibraryScreenState app;
  final String albumKey;
  const AlbumPage({super.key, required this.app, required this.albumKey});
  @override
  Widget build(BuildContext context) {
    final a = app.index.albumByKey[albumKey];
    if (a == null) return EmptyState(icon: Icons.album_outlined, text: tr('Tego albumu nie ma już w bibliotece'));
    final desktop = app.desktopMode;
    app.visibleList = a.tracks;
    app.visiblePlaylist = null;
    final discs = a.tracks.map((t) => t.discNumber).toSet();
    final multiDisc = discs.length > 1;
    final meta = [
      if (!desktop) tr('Album'),
      trackCount(a.tracks.length),
      if (a.durationMs > 0) longDuration(a.durationMs),
      ?a.quality,
    ].join(' · ');
    final pinId = 'album:${a.key}';
    final actions = Row(
      children: [
        PlayButton(
          playing: app.playing && app.current?.albumKey == a.key,
          size: desktop ? 48 : 52,
          onPressed: a.available
              ? () => unawaited(app.current?.albumKey == a.key ? app.togglePlay() : app.playAlbum(a))
              : null,
        ),
        const SizedBox(width: Sp.s),
        IconAction(Icons.shuffle_rounded, tr('Odtwórz losowo'), a.available ? () => unawaited(app.playAlbum(a, shuffle: true)) : null, box: desktop ? 40 : 48, color: secondaryText),
        IconAction(
          app.prefs.pinned(pinId) ? Icons.push_pin_rounded : Icons.push_pin_outlined,
          app.prefs.pinned(pinId) ? tr('Odepnij') : tr('Przypnij'),
          () => app.togglePin(pinId),
          box: desktop ? 40 : 48,
          color: app.prefs.pinned(pinId) ? accent : secondaryText,
        ),
        IconAction(Icons.queue_rounded, tr('Dodaj do kolejki'), () => unawaited(app.enqueue(a.tracks)), box: desktop ? 40 : 48, color: secondaryText),
        Builder(
          builder: (context) => IconAction(
            Icons.more_horiz_rounded,
            tr('Więcej'),
            () {
              final box = context.findRenderObject() as RenderBox?;
              final at = box?.localToGlobal(box.size.bottomLeft(Offset.zero));
              unawaited(app.albumMenu(a, at: at));
            },
            box: desktop ? 40 : 48,
            color: secondaryText,
          ),
        ),
      ],
    );
    final header = desktop
        ? Padding(
            padding: const EdgeInsets.fromLTRB(Sp.xl, Sp.xl, Sp.xl, Sp.l),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Artwork(a.art.cover, size: 232),
                const SizedBox(width: Sp.xl),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr('Album'), style: Txt.meta),
                      const SizedBox(height: Sp.xs),
                      Text(a.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.display.copyWith(fontSize: 30)),
                      const SizedBox(height: Sp.s),
                      InkWell(
                        onTap: () => app.go(Nav('artist', a.artistKey)),
                        child: Text(a.artist, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(height: Sp.xs),
                      Text(meta, style: Txt.meta.copyWith(fontSize: 13)),
                      const SizedBox(height: Sp.l),
                      actions,
                    ],
                  ),
                ),
              ],
            ),
          )
        : LayoutBuilder(
            builder: (context, c) => Padding(
              padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.s),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: Artwork(a.art.cover, size: (c.maxWidth * .62).clamp(140.0, 280.0))),
                  const SizedBox(height: Sp.l),
                  Text(a.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: Txt.display.copyWith(fontSize: 24)),
                  const SizedBox(height: Sp.xs),
                  InkWell(
                    onTap: () => app.go(Nav('artist', a.artistKey)),
                    child: Text(a.artist, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 2),
                  Text(meta, style: Txt.meta.copyWith(fontSize: 13)),
                  const SizedBox(height: Sp.s),
                  actions,
                ],
              ),
            ),
          );
    final rows = <Widget>[];
    int? lastDisc;
    for (final t in a.tracks) {
      if (multiDisc && t.discNumber != lastDisc) {
        lastDisc = t.discNumber;
        rows.add(Padding(
          padding: EdgeInsets.fromLTRB(desktop ? Sp.l : Sp.l, Sp.l, 0, Sp.xs),
          child: Text(tr('Płyta {0}', [t.discNumber]), style: Txt.meta.copyWith(fontWeight: FontWeight.w600)),
        ));
      }
      rows.add(TrackRow(
        app: app,
        track: t,
        list: a.tracks,
        number: t.trackNumber > 0 ? t.trackNumber : a.tracks.indexOf(t) + 1,
        showArtist: !a.singleArtist || albumGroupingPart(t.displayArtist) != albumGroupingPart(a.artist),
      ));
    }
    return CustomScrollView(
      key: PageStorageKey('album:$albumKey'),
      slivers: [
        SliverToBoxAdapter(child: AmbientBackdrop(cover: a.art.cover, strength: .55, child: header)),
        if (desktop)
          SliverToBoxAdapter(
            child: Padding(padding: pagePadding(app), child: TrackListHeader(app: app)),
          ),
        SliverPadding(
          padding: desktop ? pagePadding(app) : EdgeInsets.zero,
          sliver: SliverList.list(children: rows),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: Sp.xxl)),
      ],
    );
  }
}

// ============================================================== Artist

class ArtistPage extends StatelessWidget {
  final LibraryScreenState app;
  final String artistKey;
  const ArtistPage({super.key, required this.app, required this.artistKey});
  @override
  Widget build(BuildContext context) {
    final a = app.index.artistByKey[artistKey];
    if (a == null) return EmptyState(icon: Icons.person_outline_rounded, text: tr('Brak tego artysty w bibliotece'));
    final desktop = app.desktopMode;
    final h = app.prefs.history;
    final top = List.of(a.tracks)..sort((x, y) => h.count(y.id).compareTo(h.count(x.id)));
    final popular = top.take(desktop ? 10 : 5).toList();
    app.visibleList = popular;
    app.visiblePlaylist = null;
    final card = desktop ? 184.0 : 148.0;
    return ListView(
      key: PageStorageKey('artist:$artistKey'),
      children: [
        AmbientBackdrop(
          cover: a.art?.cover,
          strength: .5,
          child: Padding(
            padding: EdgeInsets.fromLTRB(desktop ? Sp.xl : Sp.l, desktop ? Sp.xl : Sp.s, Sp.l, Sp.l),
            child: Row(
              children: [
                Artwork(a.art?.cover, size: desktop ? 160 : 112, circle: true),
                const SizedBox(width: Sp.l),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.display.copyWith(fontSize: desktop ? 30 : 24)),
                      const SizedBox(height: Sp.xs),
                      Text([if (a.albums.isNotEmpty) albumCount(a.albums.length), trackCount(a.tracks.length)].join(' · '), style: Txt.meta.copyWith(fontSize: 13)),
                      const SizedBox(height: Sp.m),
                      Row(
                        children: [
                          PlayButton(playing: false, size: 48, onPressed: () => unawaited(app.playTracks(a.albums.expand((x) => x.tracks).followedBy(a.tracks).toList()))),
                          const SizedBox(width: Sp.s),
                          IconAction(Icons.shuffle_rounded, tr('Odtwórz losowo'), () => unawaited(app.playTracks(a.tracks, shuffle: true)), box: 44, color: secondaryText),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (popular.isNotEmpty) ...[
          SectionHeader(tr('Utwory'), padding: HomePage._hp(desktop)),
          Padding(
            padding: desktop ? pagePadding(app) : EdgeInsets.zero,
            child: Column(children: [for (final t in popular) TrackRow(app: app, track: t, list: popular, showCover: true, showArtist: false)]),
          ),
        ],
        if (a.albums.isNotEmpty) ...[
          SectionHeader(tr('Albumy'), padding: HomePage._hp(desktop)),
          _albumShelf(app, a.albums, card),
        ],
        const SizedBox(height: Sp.xxl),
      ],
    );
  }
}

// ============================================================== Playlist / Liked / Recent

class CollectionPage extends StatelessWidget {
  final LibraryScreenState app;
  final Nav nav;
  const CollectionPage({super.key, required this.app, required this.nav});
  @override
  Widget build(BuildContext context) {
    final desktop = app.desktopMode;
    final playlist = nav.page == 'playlist' ? app.playlistById(nav.arg) : null;
    if (nav.page == 'playlist' && playlist == null) {
      return EmptyState(icon: Icons.queue_music_rounded, text: tr('Tej playlisty już nie ma'));
    }
    final List<Track> list = switch (nav.page) {
      'liked' => app.index.liked(),
      'recent' => (List.of(app.tracks)..sort((a, b) => b.addedAt.compareTo(a.addedAt))).take(200).toList(),
      _ => app.index.playlistTracks(playlist!),
    };
    app.visibleList = list;
    app.visiblePlaylist = playlist;
    final title = pageTitle(app, nav);
    final art = switch (nav.page) {
      'liked' => LikedArt(size: desktop ? 200 : 168),
      _ => PlaylistArt(tracks: list, size: desktop ? 200 : 168),
    };
    final total = list.fold(0, (m, t) => m + t.durationMs);
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (desktop) Text(nav.page == 'playlist' ? tr('Playlista') : tr('Kolekcja'), style: Txt.meta),
        const SizedBox(height: Sp.xs),
        GestureDetector(
          onDoubleTap: playlist == null ? null : () => unawaited(app.renamePlaylist(playlist)),
          child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.display.copyWith(fontSize: desktop ? 30 : 24)),
        ),
        const SizedBox(height: Sp.xs),
        Text([trackCount(list.length), if (total > 0) longDuration(total)].join(' · '), style: Txt.meta.copyWith(fontSize: 13)),
        const SizedBox(height: Sp.m),
        Row(
          children: [
            PlayButton(playing: false, size: desktop ? 48 : 52, onPressed: list.isEmpty ? null : () => unawaited(app.playTracks(list))),
            const SizedBox(width: Sp.s),
            IconAction(Icons.shuffle_rounded, tr('Odtwórz losowo'), list.isEmpty ? null : () => unawaited(app.playTracks(list, shuffle: true)), box: 44, color: secondaryText),
            if (playlist != null)
              Builder(
                builder: (context) => IconAction(Icons.more_horiz_rounded, tr('Więcej'), () {
                  final box = context.findRenderObject() as RenderBox?;
                  unawaited(app.playlistMenu(playlist, at: box?.localToGlobal(box.size.bottomLeft(Offset.zero))));
                }, box: 44, color: secondaryText),
              ),
          ],
        ),
      ],
    );
    final header = Padding(
      padding: EdgeInsets.fromLTRB(desktop ? Sp.xl : Sp.l, desktop ? Sp.xl : Sp.s, Sp.l, Sp.l),
      child: desktop
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [art, const SizedBox(width: Sp.xl), Expanded(child: info)],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Center(child: art), const SizedBox(height: Sp.l), info],
            ),
    );
    final empty = list.isEmpty
        ? SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(Sp.xxl),
              child: Text(
                switch (nav.page) {
                  'liked' => tr('Polub utwory sercem, a pojawią się tutaj.'),
                  'playlist' => desktop ? tr('Przeciągnij utwory na tę playlistę w panelu bocznym albo użyj menu utworu.') : tr('Dodaj utwory z menu utworu.'),
                  _ => tr('Brak utworów'),
                },
                textAlign: TextAlign.center,
                style: Txt.sub,
              ),
            ),
          )
        : null;
    final reorderable = playlist != null && desktop;
    return CustomScrollView(
      key: PageStorageKey(nav.key),
      slivers: [
        SliverToBoxAdapter(child: AmbientBackdrop(cover: list.where((t) => t.cover != null).firstOrNull?.cover, strength: .45, child: header)),
        if (desktop && list.isNotEmpty)
          SliverToBoxAdapter(child: Padding(padding: pagePadding(app), child: TrackTableHeader(app: app, numbered: true))),
        ?empty,
        if (reorderable)
          SliverPadding(
            padding: desktop ? pagePadding(app) : EdgeInsets.zero,
            sliver: SliverReorderableList(
              itemCount: list.length,
              onReorderItem: (from, to) => unawaited(app.movePlaylistItem(playlist, from, to)),
              itemBuilder: (context, i) => ReorderableDragStartListener(
                key: ValueKey(list[i].id),
                index: i,
                child: TrackRow(app: app, track: list[i], list: list, number: i + 1, showCover: true, showAlbum: true, playlist: playlist, draggable: false),
              ),
            ),
          )
        else
          SliverPadding(
            padding: desktop ? pagePadding(app) : EdgeInsets.zero,
            sliver: SliverList.builder(
              itemCount: list.length,
              itemBuilder: (context, i) => TrackRow(app: app, track: list[i], list: list, number: desktop ? i + 1 : null, showCover: true, showAlbum: desktop, playlist: playlist),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: Sp.xxl)),
      ],
    );
  }
}

// ============================================================== Search

class SearchPage extends StatefulWidget {
  final LibraryScreenState app;
  const SearchPage({super.key, required this.app});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  bool allTracks = false;
  LibraryScreenState get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.searchText.addListener(_changed);
  }

  @override
  void dispose() {
    app.searchText.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() => allTracks = false);
  }

  void _remember() => app.prefs.rememberSearch(app.query);

  @override
  Widget build(BuildContext context) {
    final desktop = app.desktopMode;
    final q = app.query.trim();
    final field = desktop
        ? null
        : Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.s),
            child: TextField(
              controller: app.searchText,
              focusNode: app.searchFocus,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _remember(),
              decoration: InputDecoration(
                hintText: tr('Utwory, albumy, artyści'),
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: q.isEmpty ? null : IconAction(Icons.close_rounded, tr('Wyczyść'), app.searchText.clear, size: 18, box: 44),
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          );
    if (q.isEmpty) {
      final recent = app.prefs.list('searches');
      return ListView(
        children: [
          ?field,
          if (desktop) Padding(padding: EdgeInsets.fromLTRB(Sp.xl, Sp.xl, Sp.xl, Sp.s), child: Text(tr('Szukaj'), style: Txt.display)),
          if (recent.isNotEmpty) ...[
            SectionHeader(tr('Ostatnie wyszukiwania'), padding: EdgeInsets.fromLTRB(desktop ? Sp.xl : Sp.l, Sp.l, Sp.s, Sp.xs)),
            for (final r in recent)
              ListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: desktop ? Sp.xl : Sp.l),
                leading: const Icon(Icons.history_rounded),
                title: Text(r),
                onTap: () {
                  app.searchText.text = r;
                  app.searchText.selection = TextSelection.collapsed(offset: r.length);
                },
              ),
          ] else
            Padding(
              padding: const EdgeInsets.all(Sp.xxl),
              child: Text(desktop ? tr('Wpisz, czego szukasz. Ctrl+F przenosi tu kursor.') : tr('Wpisz tytuł, album lub artystę.'), textAlign: TextAlign.center, style: Txt.sub),
            ),
        ],
      );
    }
    final tracks = app.index.searchTracks(q);
    final albums = app.index.searchAlbums(q);
    final artists = app.index.searchArtists(q).where((a) => a.albums.isNotEmpty || a.tracks.isNotEmpty).toList();
    final words = LibraryIndex.terms(q);
    final playlists = app.orderedPlaylists.where((p) => words.every(searchKey(p.name).contains)).toList();
    app.visibleList = tracks;
    app.visiblePlaylist = null;
    final pad = EdgeInsets.fromLTRB(desktop ? Sp.xl : Sp.l, 20, Sp.s, Sp.xs);
    final card = desktop ? 184.0 : 148.0;
    if (tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty) {
      return ListView(children: [
        ?field,
        Padding(
          padding: const EdgeInsets.all(Sp.xxl),
          child: Text(tr('Nic nie pasuje do „{0}”', [q]), textAlign: TextAlign.center, style: Txt.sub),
        ),
      ]);
    }
    final shown = allTracks ? tracks : tracks.take(desktop ? 8 : 6).toList();
    Widget? best;
    final exactArtist = artists.where((a) => searchKey(a.name) == searchKey(q)).firstOrNull;
    if (exactArtist != null) {
      best = _best(exactArtist.art?.cover, exactArtist.name, tr('Artysta'), () { _remember(); app.go(Nav('artist', exactArtist.key)); }, circle: true);
    } else if (albums.isNotEmpty) {
      final a = albums.first;
      best = _best(a.art.cover, a.title, tr('Album · {0}', [a.artist]), () { _remember(); app.go(Nav('album', a.key)); }, onPlay: () => unawaited(app.playAlbum(a)));
    } else if (tracks.isNotEmpty) {
      final t = tracks.first;
      best = _best(t.cover, t.title, tr('Utwór · {0}', [t.displayArtist]), () { _remember(); unawaited(app.playTracks(tracks, start: t)); });
    }
    return ListView(
      key: const PageStorageKey('search-results'),
      children: [
        ?field,
        if (best != null) ...[
          SectionHeader(tr('Najlepszy wynik'), padding: pad),
          best,
        ],
        if (tracks.isNotEmpty) ...[
          SectionHeader(tr('Utwory'), padding: pad, onMore: tracks.length > shown.length ? () => setState(() => allTracks = true) : null),
          Padding(
            padding: desktop ? pagePadding(app) : EdgeInsets.zero,
            child: Column(
              children: [
                for (final t in shown)
                  TrackRow(app: app, track: t, list: tracks, showCover: true, showAlbum: desktop),
              ],
            ),
          ),
        ],
        if (albums.isNotEmpty) ...[
          SectionHeader(tr('Albumy'), padding: pad),
          _albumShelf(app, albums.take(20).toList(), card),
        ],
        if (artists.isNotEmpty) ...[
          SectionHeader(tr('Artyści'), padding: pad),
          Shelf(
            itemCount: artists.length > 20 ? 20 : artists.length,
            height: card + 14,
            textHeight: cardText,
            itemWidth: card,
            gap: 0,
            padding: EdgeInsets.symmetric(horizontal: desktop ? Sp.l : Sp.s),
            itemBuilder: (context, i) => _artistCard(app, artists[i], card),
          ),
        ],
        if (playlists.isNotEmpty) ...[
          SectionHeader(tr('Playlisty'), padding: pad),
          Shelf(
            itemCount: playlists.length,
            height: card + 14,
            textHeight: cardText,
            itemWidth: card,
            gap: 0,
            padding: EdgeInsets.symmetric(horizontal: desktop ? Sp.l : Sp.s),
            itemBuilder: (context, i) => _playlistCard(app, playlists[i], card),
          ),
        ],
        const SizedBox(height: Sp.xxl),
      ],
    );
  }

  Widget _best(String? cover, String title, String sub, VoidCallback onTap, {bool circle = false, VoidCallback? onPlay}) => Padding(
    padding: EdgeInsets.symmetric(horizontal: app.desktopMode ? Sp.xl : Sp.l),
    child: Material(
      color: panel,
      borderRadius: BorderRadius.circular(Rad.panel),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Sp.l),
          child: Row(
            children: [
              Artwork(cover, size: 88, circle: circle),
              const SizedBox(width: Sp.l),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.title),
                    const SizedBox(height: Sp.xs),
                    Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.sub),
                  ],
                ),
              ),
              if (onPlay != null) PlayButton(playing: false, size: 44, onPressed: onPlay),
            ],
          ),
        ),
      ),
    ),
  );
}

// ============================================================== Settings

String? settingsTitle(String? section) => switch (section) {
  'sources' => tr('Źródła muzyki'),
  'import' => tr('Płyty CD i winyle'),
  'audio' => tr('Audio'),
  'look' => tr('Wygląd i język'),
  'phone' => tr('Telefon i komputer'),
  'about' => tr('Informacje'),
  _ => null,
};

class SettingsPage extends StatelessWidget {
  final LibraryScreenState app;
  final String? section;
  const SettingsPage({super.key, required this.app, this.section});

  /// Desktop keeps sources and the phone link in the sidebar, so they are not repeated here.
  List<(String, IconData, String)> get sections => [
    if (!app.desktopMode) ('sources', Icons.folder_open_outlined, tr('Źródła muzyki')),
    ('audio', Icons.volume_up_outlined, tr('Audio')),
    // Adding music is one place (sources). Import here means digitizing CD and vinyl.
    if (app.canDigitize && !app.isPhone) ('import', Icons.album_outlined, tr('Płyty CD i winyle')),
    ('cleanup', Icons.cleaning_services_outlined, tr('Porządki w bibliotece')),
    ('look', Icons.palette_outlined, tr('Wygląd i język')),
    if (app.canTransfer && !app.desktopMode) ('phone', Icons.phonelink_rounded, app.isPhone ? tr('Przesyłanie muzyki') : tr('Połącz telefon')),
    ('about', Icons.info_outline_rounded, tr('Informacje')),
  ];

  /// One route per destination: sources and import are their own views.
  void open(String key) {
    if (key == 'sources') {
      app.go(const Nav('sources'));
    } else if (key == 'cleanup') {
      app.go(const Nav('cleanup'));
    } else if (key == 'import' && app.canDigitize && !app.isPhone) {
      app.go(const Nav('import'));
    } else if (key == 'phone' && !app.desktopMode) {
      app.go(const Nav('transfer'));
    } else if (app.desktopMode) {
      app.replaceRoute(Nav('settings', key));
    } else {
      app.go(Nav('settings', key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = app.desktopMode;
    if (!desktop) {
      if (section != null) return ListView(padding: const EdgeInsets.all(Sp.l), children: _content(context, section!));
      return ListView(
        children: [
          for (final (key, icon, label) in sections)
            ListTile(
              minTileHeight: 56,
              leading: Icon(icon),
              title: Text(label),
              trailing: Icon(Icons.chevron_right_rounded, color: secondaryText),
              onTap: () => open(key),
            ),
        ],
      );
    }
    final current = section ?? 'audio';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 240,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xl, Sp.s, Sp.l),
            children: [
              Padding(padding: EdgeInsets.fromLTRB(Sp.s, 0, 0, Sp.l), child: Text(tr('Ustawienia'), style: Txt.display)),
              for (final (key, icon, label) in sections)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: ListTile(
                    dense: true,
                    selected: key == current,
                    selectedColor: primaryText,
                    selectedTileColor: hoverFill,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.control)),
                    leading: Icon(icon, size: 20),
                    title: Text(label, style: const TextStyle(fontSize: 13.5)),
                    onTap: () => open(key),
                  ),
                ),
            ],
          ),
        ),
        VerticalDivider(width: 1, color: softBorder),
        Expanded(
          child: current == 'phone' && app.canTransfer
              ? app.transferScreen()
              : ListView(
                  key: PageStorageKey('settings:$current'),
                  padding: const EdgeInsets.fromLTRB(Sp.xxl, Sp.xl, Sp.xxl, Sp.xxl),
                  children: [
                    Text(settingsTitle(current) ?? '', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -.5)),
                    const SizedBox(height: Sp.xl),
                    ..._content(context, current),
                  ],
                ),
        ),
      ],
    );
  }

  List<Widget> _content(BuildContext context, String s) => switch (s) {
    'sources' => [SourcesList(app: app)],
    'import' => _import(),
    'audio' => [AudioSettingsView(app: app)],
    'look' => _look(),
    'phone' => [SizedBox(height: 600, child: app.transferScreen())],
    _ => _about(),
  };

  Widget _row(String title, String? sub, {Widget? trailing, VoidCallback? onTap, IconData? icon}) => ListTile(
    contentPadding: EdgeInsets.zero,
    minTileHeight: 52,
    leading: icon == null ? null : Icon(icon),
    title: Text(title, style: const TextStyle(fontSize: 14.5)),
    subtitle: sub == null ? null : Text(sub, style: Txt.meta),
    trailing: trailing,
    onTap: onTap,
  );

  List<Widget> _import() => [
    _row(tr('Audio CD'), tr('Odczyt cyfrowy, opis z MusicBrainz, FLAC'), icon: Icons.album_outlined, onTap: () => app.openIngest(true)),
    _row(tr('Winyl i kaseta'), tr('Nagranie, podział i opis utworów'), icon: Icons.radio_outlined, onTap: () => app.openIngest(false)),
  ];

  List<Widget> _look() => [
    SectionTitle(tr('Język')),
    Wrap(
      spacing: Sp.s,
      children: [
        for (final (code, name) in languages)
          ChoiceChip(label: Text(name), selected: lang == code, onSelected: (_) => app.setLanguage(code)),
      ],
    ),
    SectionTitle(tr('Kolory')),
    Wrap(
      spacing: Sp.m,
      runSpacing: Sp.m,
      children: [for (final p in palettes) _PaletteSwatch(palette: p, selected: p == palette, onTap: () => app.setPalette(p))],
    ),
    if (app.desktopMode) ...[
      SectionTitle(tr('Biblioteka')),
      Text(tr('Rozmiar okładek w siatce'), style: Txt.meta),
      Slider(
        value: app.prefs.number('coverSize', 184).clamp(140, 240).toDouble(),
        min: 140,
        max: 240,
        divisions: 10,
        label: '${app.prefs.number('coverSize', 184).round()}',
        onChanged: (v) => app.refresh(() => app.prefs.set('coverSize', v)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(tr('Kompaktowa tabela utworów'), style: TextStyle(fontSize: 14.5)),
        subtitle: Text(tr('Niższe wiersze, bez okładek. Kolumny wybierzesz prawym przyciskiem na nagłówku tabeli.'), style: Txt.meta),
        value: compactTable(app.prefs),
        onChanged: (v) => app.refresh(() => app.prefs.set('density', v ? 'compact' : 'normal')),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(tr('Zwinięty panel boczny'), style: TextStyle(fontSize: 14.5)),
        value: app.prefs.get('sidebarCollapsed', false),
        onChanged: (v) => app.refresh(() => app.prefs.set('sidebarCollapsed', v)),
      ),
    ],
    SectionTitle(tr('Wizualizacje')),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(tr('Kolory okładki'), style: TextStyle(fontSize: 14.5)),
      subtitle: Text(tr('Plazma, wstęgi i wir biorą barwy z okładki grającego albumu.'), style: Txt.meta),
      value: app.prefs.get<bool>('viz.cover', true),
      onChanged: (v) => app.refresh(() => app.prefs.set('viz.cover', v)),
    ),
    if (app.canFloat)
      _row(
        tr('Wygaszacz z wizualizacją'),
        tr('Gdy gra muzyka, a komputer nie jest używany. Ruch myszy lub klawisz zamyka.'),
        trailing: DropdownButton<int>(
          value: const [0, 2, 5, 10, 20].contains(app.screensaverMinutes) ? app.screensaverMinutes : 0,
          underline: const SizedBox.shrink(),
          dropdownColor: elevated,
          items: [
            for (final m in const [0, 2, 5, 10, 20])
              DropdownMenuItem(value: m, child: Text(m == 0 ? tr('Wyłączony') : tr('Po {0} min', [m]), style: const TextStyle(fontSize: 13.5))),
          ],
          onChanged: (v) => app.refresh(() => app.prefs.set('screensaver', v ?? 0)),
        ),
      ),
  ];

  List<Widget> _about() => [
    _row('Mytify', tr('Wersja {0}', ['0.21']), icon: Icons.info_outline_rounded),
    _row(tr('Autor'), tr('Mateusz Kanik'), icon: Icons.person_outline_rounded),
    _row(
      tr('Strona'),
      'kanik.dev',
      icon: Icons.language_rounded,
      trailing: Icon(Icons.open_in_new_rounded, size: 18, color: secondaryText),
      onTap: () => unawaited(openLink('https://kanik.dev').catchError((_) => app.message(tr('Nie można otworzyć strony.')))),
    ),
    _row(tr('Biblioteka'), '${trackCount(app.tracks.length)} · ${albumCount(app.index.albums.length)}', icon: Icons.library_music_outlined),
    if (app.desktopMode) _row(tr('Skróty klawiaturowe'), null, icon: Icons.keyboard_outlined, onTap: () => showShortcuts(app.context)),
  ];
}

void showShortcuts(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(tr('Skróty klawiaturowe'), style: Txt.title),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          children: [
            for (final (k, v) in [
              (tr('Spacja'), tr('Odtwórz / wstrzymaj')),
              (tr('Ctrl + → / ←'), tr('Następny / poprzedni utwór')),
              (tr('Ctrl + ↑ / ↓'), tr('Głośniej / ciszej')),
              (tr('Ctrl + F'), tr('Szukaj')),
              (tr('Ctrl + O'), tr('Dodaj pliki')),
              (tr('Ctrl + Shift + O'), tr('Dodaj folder')),
              (tr('Ctrl + L'), tr('Polub bieżący utwór')),
              (tr('Ctrl + N'), tr('Nowa playlista')),
              (tr('Ctrl + ,'), tr('Ustawienia')),
              (tr('Ctrl + A'), tr('Zaznacz wszystkie utwory')),
              (tr('Enter'), tr('Odtwórz zaznaczony utwór')),
              (tr('Delete'), tr('Usuń zaznaczone')),
              (tr('F11'), tr('Pełny ekran odtwarzacza')),
              (tr('Alt + ← / →'), tr('Wstecz / dalej')),
              (tr('Esc'), tr('Zamknij panel lub okno')),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [SizedBox(width: 170, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))), Expanded(child: Text(v, style: Txt.sub))]),
              ),
          ],
        ),
      ),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Zamknij')))],
  ),
);

/// "Źródła muzyki": browsing and managing sources. "Dodaj źródło" creates one.
class SourcesPage extends StatelessWidget {
  final LibraryScreenState app;
  const SourcesPage({super.key, required this.app});
  @override
  Widget build(BuildContext context) => ListView(
    key: const PageStorageKey('sources'),
    padding: app.desktopMode ? const EdgeInsets.fromLTRB(Sp.xl, Sp.xl, Sp.xl, Sp.xxl) : const EdgeInsets.all(Sp.l),
    children: [
      if (app.desktopMode) Padding(padding: EdgeInsets.only(bottom: Sp.l), child: Text(tr('Źródła muzyki'), style: Txt.display)),
      SourcesList(app: app),
    ],
  );
}

class SourcesList extends StatelessWidget {
  final LibraryScreenState app;
  const SourcesList({super.key, required this.app});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _items());

  List<Widget> _items() => [
    Wrap(
      spacing: Sp.s,
      runSpacing: Sp.s,
      children: [
        Builder(
          builder: (context) => FilledButton.icon(
            style: Ctl.filled,
            onPressed: app.importing
                ? null
                : () {
                    final box = context.findRenderObject() as RenderBox?;
                    app.showAddMusic(at: box?.localToGlobal(box.size.bottomLeft(Offset.zero)));
                  },
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(tr('Dodaj źródło')),
          ),
        ),
        OutlinedButton.icon(
          style: Ctl.outlined,
          onPressed: app.importing || app.librarySources.isEmpty ? null : () => unawaited(app.scanSources()),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(tr('Skanuj wszystkie')),
        ),
      ],
    ),
    const SizedBox(height: Sp.l),
    if (app.librarySources.isEmpty) Text(tr('Nie dodano jeszcze żadnego źródła.'), style: Txt.sub),
    // The download folder is managed by Mytify itself, not a source to scan or edit.
    for (final source in app.librarySources)
      if (source.kind != 'downloads') _source(source),
    if (app.networkProtocols.isNotEmpty)
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.download_for_offline_outlined, color: secondaryText),
        title: Text(tr('Pobrane i miejsce')),
        subtitle: Text(tr('Kopie offline, kolejka pobierania, zajęte miejsce'), style: Txt.meta),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => app.go(const Nav('downloads')),
      ),
    if (app.lastImport != null) SectionTitle(tr('Więcej')),
    if (app.lastImport != null)
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.receipt_long_outlined, color: secondaryText),
        title: Text(tr('Ostatni wynik importu')),
        onTap: () => unawaited(app.showImportReport(app.lastImport!)),
      ),
  ];

  Widget _source(LibrarySource source) {
    final offline = source.state == 'offline' || source.state == 'error';
    final problem = switch (source.state) {
      'offline' => source.network ? tr('Źródło niedostępne') : tr('Niedostępne'),
      'error' => tr('Nie można odczytać'),
      'partial' => tr('Wymaga ponownego skanu'),
      'scanning' => tr('Skanowanie'),
      _ => null,
    };
    final path = source.address.isNotEmpty
        ? source.address
        : source.path.startsWith(r'\\?\')
        ? source.path.substring(4)
        : source.path;
    return Container(
      margin: const EdgeInsets.only(bottom: Sp.s),
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.s, Sp.m),
      decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(Rad.panel)),
      child: Row(
        children: [
          Icon(
            source.protocol == 'subsonic'
                ? Icons.dns_outlined
                : source.protocol == 'webdav'
                ? (offline ? Icons.cloud_off_outlined : Icons.cloud_outlined)
                : source.network
                ? (offline ? Icons.portable_wifi_off_rounded : Icons.lan_outlined)
                : (offline ? Icons.folder_off_outlined : Icons.folder_outlined),
            color: offline ? warningText : secondaryText,
          ),
          const SizedBox(width: Sp.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(source.name, style: Txt.item),
                if (path.isNotEmpty) Text(path, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.meta),
                const SizedBox(height: 2),
                Text(
                  [trackCount(source.files), ?problem].join(' · '),
                  style: Txt.meta.copyWith(color: problem == null ? secondaryText : warningText),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: tr('Opcje źródła'),
            icon: Icon(Icons.more_horiz_rounded, color: secondaryText),
            enabled: !app.importing,
            onSelected: (v) {
              if (v == 'scan') {
                unawaited(app.scanSources(source.id));
              } else if (v == 'edit') {
                unawaited(app.editSource(source));
              } else if (v == 'relink') {
                unawaited(app.relinkSource(source.id));
              } else {
                unawaited(app.forgetSource(source));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'scan', height: 36, child: Text(tr('Skanuj ponownie'))),
              if (source.network) PopupMenuItem(value: 'edit', height: 36, child: Text(tr('Edytuj połączenie'))),
              if (source.kind == 'folder') PopupMenuItem(value: 'relink', height: 36, child: Text(tr('Wskaż folder ponownie'))),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'forget', height: 36, child: Text(tr('Odłącz źródło'), style: TextStyle(color: dangerText))),
            ],
          ),
        ],
      ),
    );
  }

}

/// One colour scheme as a small preview: background, panel, text lines and accent.
class _PaletteSwatch extends StatelessWidget {
  final Palette palette;
  final bool selected;
  final VoidCallback onTap;
  const _PaletteSwatch({required this.palette, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Semantics(
      selected: selected,
      button: true,
      label: tr(p.name),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Rad.panel),
        child: Container(
          width: 132,
          padding: const EdgeInsets.all(Sp.s),
          decoration: BoxDecoration(
            color: p.background,
            borderRadius: BorderRadius.circular(Rad.panel),
            border: Border.all(color: selected ? p.accent : p.softBorder, width: selected ? 2 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 44,
                padding: const EdgeInsets.all(Sp.s),
                decoration: BoxDecoration(color: p.panel, borderRadius: BorderRadius.circular(Rad.control)),
                child: Row(
                  children: [
                    Container(width: 20, height: 20, decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle)),
                    const SizedBox(width: Sp.s),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(height: 5, width: 48, color: p.primaryText),
                          const SizedBox(height: 4),
                          Container(height: 4, width: 32, color: p.secondaryText),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Sp.s),
              Row(
                children: [
                  Expanded(child: Text(tr(p.name), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.primaryText))),
                  if (selected) Icon(Icons.check_circle_rounded, size: 16, color: p.accent),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
