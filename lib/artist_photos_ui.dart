import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'l10n.dart';
import 'library_index.dart';
import 'main.dart';
import 'model.dart';
import 'widgets.dart';

/// Artists the photo applies to: single names, the way the core looks them up.
bool soloArtist(String name) {
  final l = name.toLowerCase();
  if (const ['various artists', 'różni wykonawcy', 'va', 'various'].contains(l.trim())) return false;
  return name.trim().isNotEmpty && ![', ', ' feat. ', ' feat ', ' ft. ', ' & ', ' x ', ' vs. ', ' with ', '; ', ' / '].any(l.contains);
}

/// "Porządki" tab: where artist photos come from and fetching the missing ones.
class ArtistPhotosPanel extends StatefulWidget {
  final LibraryScreenState app;
  const ArtistPhotosPanel({super.key, required this.app});
  @override
  State<ArtistPhotosPanel> createState() => _ArtistPhotosPanelState();
}

class _ArtistPhotosPanelState extends State<ArtistPhotosPanel> {
  LibraryScreenState get app => widget.app;
  ArtistPhotoRepository get repo => app.repository as ArtistPhotoRepository;
  String? folder;
  Map<String, dynamic> status = const {};
  String? error;
  Timer? _poll;

  bool get running => status['running'] == true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final f = await repo.artistPhotoFolder();
      final st = await repo.artistPhotoStatus();
      if (!mounted) return;
      setState(() {
        folder = f;
        status = st;
      });
      if (running) _watch();
    } catch (e) {
      if (mounted) setState(() => error = trMessage('$e'));
    }
  }

  void _watch() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 700), (_) async {
      try {
        final st = await repo.artistPhotoStatus();
        if (!mounted) return;
        setState(() => status = st);
        if (st['running'] != true) {
          _poll?.cancel();
          await app.loadArtistPhotos();
        }
      } catch (_) {}
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => error = null);
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = trMessage('$e'));
    }
  }

  Future<void> _pick() => _run(() async {
    final path = await repo.pickArtistPhotoFolder();
    if (path == null) return;
    await repo.setArtistPhotoFolder(path);
    setState(() => folder = path);
    status = await repo.artistPhotoStatus();
    _watch();
  });

  Future<void> _clear() => _run(() async {
    await repo.setArtistPhotoFolder(null);
    setState(() => folder = null);
    _watch();
  });

  Future<void> _download() => _run(() async {
    final st = await repo.refreshArtistPhotos(download: true);
    setState(() => status = st);
    _watch();
  });

  @override
  Widget build(BuildContext context) {
    final artists = [for (final a in app.index.artists) if (soloArtist(a.name)) a];
    final withPhoto = artists.where((a) => app.artistPhotos.containsKey(a.key)).toList();
    final without = artists.where((a) => !app.artistPhotos.containsKey(a.key)).toList();
    final done = (status['done'] as num? ?? 0).toInt(), total = (status['total'] as num? ?? 0).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('Zdjęcia wykonawców: {0} z {1}.', [withPhoto.length, artists.length]),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: Sp.xs),
        Text(
          tr('Mytify bierze zdjęcie z folderu zdjęć (Amorphis.jpg albo Amorphis/artist.jpg) albo z folderu wykonawcy obok muzyki (Muzyka/Amorphis/artist.jpg, jak Plex i Jellyfin). Brakujące może pobrać z Deezera, a potem z Wikimedia Commons; pobrane zapisuje w folderze zdjęć, a bez niego jako artist.jpg w folderze wykonawcy. Istniejących plików nie nadpisuje.'),
          style: Txt.meta.copyWith(height: 1.45),
        ),
        const SizedBox(height: Sp.l),
        Text(tr('Folder ze zdjęciami wykonawców'), style: Ctl.label),
        const SizedBox(height: Sp.xs),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: Sp.m, vertical: 10),
                decoration: BoxDecoration(color: elevated, borderRadius: BorderRadius.circular(Rad.control)),
                child: Text(
                  folder ?? tr('Nie ustawiono (tylko foldery wykonawców obok muzyki)'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ctl.fieldText.copyWith(color: folder == null ? secondaryText : null),
                ),
              ),
            ),
            const SizedBox(width: Sp.s),
            OutlinedButton(style: Ctl.outlined, onPressed: running ? null : () => unawaited(_pick()), child: Text(tr('Wybierz folder'))),
            if (folder != null) IconAction(Icons.close_rounded, tr('Nie używaj folderu zdjęć'), running ? null : () => unawaited(_clear()), color: secondaryText),
          ],
        ),
        const SizedBox(height: Sp.xs),
        Text(tr('Może być na NAS: wybierz go w Sieci albo wpisz ścieżkę \\\\NAS\\udział\\folder w oknie wyboru.'), style: Ctl.label),
        const SizedBox(height: Sp.l),
        if (running) ...[
          LinearProgressIndicator(value: total > 0 ? (done / total).clamp(0, 1).toDouble() : null),
          const SizedBox(height: Sp.xs),
          Text(
            [
              if ('${status['step'] ?? ''}'.isNotEmpty) trMessage('${status['step']}'),
              if (total > 0) '$done / $total',
            ].join(' · '),
            style: Ctl.label,
          ),
          const SizedBox(height: Sp.s),
          OutlinedButton(style: Ctl.outlined, onPressed: () => unawaited(_run(repo.cancelArtistPhotos)), child: Text(tr('Zatrzymaj'))),
        ] else ...[
          FilledButton.icon(
            style: Ctl.filled,
            onPressed: without.isEmpty ? null : () => unawaited(_download()),
            icon: const Icon(Icons.person_search_rounded, size: 18),
            label: Text(tr('Pobierz brakujące zdjęcia ({0})', [without.length])),
          ),
          if ((status['downloaded'] as num? ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(top: Sp.s),
              child: Text(tr('Pobrano: {0}.', [status['downloaded']]), style: Ctl.label),
            ),
          if (status['error'] != null) Padding(padding: const EdgeInsets.only(top: Sp.s), child: Text(trMessage('${status['error']}'), style: Txt.meta.copyWith(color: dangerText))),
        ],
        if (error != null) Padding(padding: const EdgeInsets.only(top: Sp.s), child: Text(error!, style: Txt.meta.copyWith(color: dangerText))),
        if (without.isNotEmpty) ...[
          SectionHeader(tr('Bez zdjęcia'), padding: const EdgeInsets.only(top: Sp.xl, bottom: Sp.s)),
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              for (final a in without.take(60))
                ActionChip(
                  avatar: Artwork(a.art?.cover, size: 22, circle: true),
                  label: Text(a.name),
                  onPressed: () => app.go(Nav('artist', a.key)),
                ),
              if (without.length > 60) Chip(label: Text(tr('i {0} więcej', [without.length - 60]))),
            ],
          ),
        ],
      ],
    );
  }
}

/// Number of single artists without a photo (for the tab label).
int artistsWithoutPhoto(LibraryScreenState app) => [
  for (final ArtistGroup a in app.index.artists)
    if (soloArtist(a.name) && !app.artistPhotos.containsKey(a.key)) a,
].length;
