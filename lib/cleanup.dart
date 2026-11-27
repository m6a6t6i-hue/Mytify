import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'artist_photos_ui.dart';
import 'design.dart';
import 'library_index.dart';
import 'main.dart';
import 'model.dart';
import 'widgets.dart';
import 'l10n.dart';

/// Title and artist reduced to letters and digits: "Ballada (Remastered 2011)" and
/// "ballada" stay different on purpose, only case, accents and punctuation are ignored.
String duplicateKey(Track t) {
  String norm(String v) => searchKey(v).replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  return '${norm(t.displayArtist)}|${norm(t.title)}';
}

/// Same recording more than once: same artist and title, lengths within 3 s.
/// Best copy first (lossless, then bit depth, sample rate, size).
List<List<Track>> findDuplicates(List<Track> tracks) {
  final groups = <String, List<Track>>{};
  for (final t in tracks) {
    if (t.title.trim().isEmpty) continue;
    (groups[duplicateKey(t)] ??= []).add(t);
  }
  final out = <List<Track>>[];
  for (final g in groups.values.where((g) => g.length > 1)) {
    g.sort((a, b) => a.durationMs.compareTo(b.durationMs));
    var cluster = <Track>[g.first];
    void flush() {
      if (cluster.length > 1) out.add([...cluster]..sort(betterCopy));
    }

    for (final t in g.skip(1)) {
      final last = cluster.last;
      final close = t.durationMs == 0 || last.durationMs == 0 || (t.durationMs - last.durationMs).abs() <= 3000;
      if (close) {
        cluster.add(t);
      } else {
        flush();
        cluster = [t];
      }
    }
    flush();
  }
  out.sort((a, b) => a.first.displayArtist.toLowerCase().compareTo(b.first.displayArtist.toLowerCase()));
  return out;
}

int betterCopy(Track a, Track b) {
  // Plain arithmetic: the PC app runs as JavaScript, where bit shifts are 32-bit.
  double score(Track t) => (t.available ? 4e12 : 0) + (lossless(t.format) ? 2e12 : 0) + t.bitDepth * 1e9 + t.sampleRate * 1e3;
  final s = score(b).compareTo(score(a));
  return s != 0 ? s : b.size.compareTo(a.size);
}

/// What an album is missing, from the catalog itself (no guessing).
List<String> albumIssues(AlbumGroup a) => [
  if (a.tracks.every((t) => t.album.trim().isEmpty)) tr('bez nazwy albumu'),
  if (a.tracks.every((t) => t.artist.trim().isEmpty && t.albumArtist.trim().isEmpty)) tr('bez wykonawcy'),
  if (a.tracks.every((t) => t.cover == null)) tr('bez okładki'),
  if (a.tracks.length > 1 && a.tracks.any((t) => t.trackNumber == 0)) tr('bez numerów utworów'),
  if (a.tracks.length > 1 && a.tracks.map((t) => t.trackNumber).where((n) => n > 0).toSet().length < a.tracks.where((t) => t.trackNumber > 0).length)
    tr('powtórzone numery'),
];

class CleanupPage extends StatefulWidget {
  final LibraryScreenState app;
  const CleanupPage({super.key, required this.app});
  @override
  State<CleanupPage> createState() => _CleanupPageState();
}

class _CleanupPageState extends State<CleanupPage> {
  LibraryScreenState get app => widget.app;
  int tab = 0;
  bool fixing = false;

  /// Albums the user chose to leave as they are in this session.
  final skipped = <String>{};

  Future<void> _fixAll(List<AlbumGroup> albums) async {
    setState(() => fixing = true);
    try {
      for (final a in albums) {
        if (!mounted) return;
        final changed = await app.metadataFor(a.tracks, online: true);
        if (!changed) {
          // Closed without saving: stop here, the rest waits for later.
          break;
        }
      }
    } finally {
      if (mounted) setState(() => fixing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = app.desktopMode;
    final duplicates = findDuplicates(app.tracks);
    final photos = app.repository is ArtistPhotoRepository;
    final albums = [
      for (final a in app.index.albums)
        if (!skipped.contains(a.key) && albumIssues(a).isNotEmpty) a,
    ];
    return ListView(
      key: const PageStorageKey('cleanup'),
      padding: desktop ? const EdgeInsets.fromLTRB(Sp.xl, Sp.xl, Sp.xl, Sp.xxl) : const EdgeInsets.all(Sp.l),
      children: [
        if (desktop) ...[Text(tr('Porządki w bibliotece'), style: Txt.display), const SizedBox(height: Sp.l)],
        TextTabs(
          labels: [
            tr('Duplikaty ({0})', [duplicates.length]),
            tr('Albumy z brakami ({0})', [albums.length]),
            if (photos) tr('Zdjęcia wykonawców ({0})', [artistsWithoutPhoto(app)]),
          ],
          index: tab,
          onChanged: (v) => setState(() => tab = v),
        ),
        const SizedBox(height: Sp.l),
        if (tab == 0)
          ..._duplicates(duplicates)
        else if (tab == 1)
          ..._albums(albums)
        else if (photos)
          ArtistPhotosPanel(app: app),
      ],
    );
  }

  List<Widget> _duplicates(List<List<Track>> groups) {
    if (groups.isEmpty) {
      return [EmptyState(icon: Icons.check_circle_outline_rounded, text: tr('Brak duplikatów: każdy utwór jest w bibliotece raz.'))];
    }
    final extra = groups.fold(0, (n, g) => n + g.length - 1);
    return [
      Text(
        tr('Ten sam wykonawca, tytuł i długość (do 3 s różnicy). Pierwsza jest najlepsza kopia.'),
        style: Txt.meta,
      ),
      const SizedBox(height: Sp.m),
      Wrap(
        spacing: Sp.s,
        children: [
          OutlinedButton(
            style: Ctl.outlined,
            onPressed: () => unawaited(app.removeTracks([for (final g in groups) ...g.skip(1)])),
            child: Text(tr('Zostaw najlepsze kopie (usuń {0})', [extra])),
          ),
        ],
      ),
      const SizedBox(height: Sp.m),
      for (final g in groups) ...[
        SectionTitle('${g.first.displayArtist} · ${g.first.title}'),
        for (var i = 0; i < g.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Artwork(g[i].cover, size: 40, radius: Rad.coverSmall),
            title: Text(g[i].displayAlbum, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                if (i == 0) tr('najlepsza kopia'),
                g[i].format.toUpperCase(),
                if (g[i].bitDepth > 0 && g[i].sampleRate > 0) tr('{0} bit / {1} kHz', [g[i].bitDepth, (g[i].sampleRate / 1000).toString().replaceAll('.', ',')]),
                if (g[i].durationMs > 0) clock(g[i].durationMs),
                if (!g[i].available) tr('niedostępny'),
                g[i].fileName,
              ].where((x) => x.isNotEmpty).join(' · '),
              style: Txt.meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconAction(Icons.play_arrow_rounded, tr('Odtwórz'), () => unawaited(app.playTracks([g[i]])), color: secondaryText),
                IconAction(Icons.delete_outline_rounded, tr('Usuń z biblioteki'), () => unawaited(app.removeTracks([g[i]])), color: secondaryText),
              ],
            ),
          ),
      ],
    ];
  }

  List<Widget> _albums(List<AlbumGroup> albums) {
    if (albums.isEmpty) {
      return [EmptyState(icon: Icons.check_circle_outline_rounded, text: tr('Wszystkie albumy mają nazwę, wykonawcę, okładkę i numery utworów.'))];
    }
    return [
      Text(
        tr('Opis i okładka z MusicBrainz. Każdy album zatwierdzasz sam.'),
        style: Txt.meta,
      ),
      const SizedBox(height: Sp.m),
      FilledButton.icon(
        style: Ctl.filled,
        onPressed: fixing || app.importing ? null : () => unawaited(_fixAll(albums)),
        icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
        label: Text(fixing ? tr('Poprawianie…') : tr('Popraw po kolei ({0})', [albums.length])),
      ),
      const SizedBox(height: Sp.m),
      for (final a in albums)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Artwork(a.art.cover, size: 48, radius: Rad.coverSmall),
          title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${a.artist} · ${trackCount(a.tracks.length)} · ${albumIssues(a).join(', ')}', style: Txt.meta, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => app.go(Nav('album', a.key)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                style: Ctl.text,
                onPressed: fixing || app.importing ? null : () => unawaited(app.metadataFor(a.tracks, online: true)),
                child: Text(tr('Znajdź w MusicBrainz')),
              ),
              IconAction(Icons.visibility_off_outlined, tr('Pomiń do końca sesji'), () => setState(() => skipped.add(a.key)), color: secondaryText),
            ],
          ),
        ),
    ];
  }
}
