import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'model.dart';
import 'cover_widget.dart';

Future<bool?> editMusicMetadata(
  BuildContext context,
  LibraryRepository repository,
  List<Track> tracks, {
  bool online = false,
  bool album = false,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => online
      ? ReleaseFinder(repository: repository, tracks: tracks)
      : MetadataEditor(repository: repository, tracks: tracks, album: album),
);

class MetadataEditor extends StatefulWidget {
  final LibraryRepository repository;
  final List<Track> tracks;
  final bool album;
  const MetadataEditor({
    super.key,
    required this.repository,
    required this.tracks,
    required this.album,
  });
  @override
  State<MetadataEditor> createState() => _MetadataEditorState();
}

class _MetadataEditorState extends State<MetadataEditor> {
  final form = GlobalKey<FormState>();
  late final TextEditingController title,
      artist,
      album,
      albumArtist,
      number,
      disc;
  bool busy = false;
  String? error;
  CoverChoice? chosen;
  bool removeCover = false;
  @override
  void initState() {
    super.initState();
    final t = widget.tracks.first;
    title = TextEditingController(text: t.title);
    artist = TextEditingController(text: t.artist);
    album = TextEditingController(text: t.album);
    albumArtist = TextEditingController(text: t.albumArtist);
    number = TextEditingController(text: '${t.trackNumber}');
    disc = TextEditingController(text: '${t.discNumber}');
  }

  @override
  void dispose() {
    for (final c in [title, artist, album, albumArtist, number, disc]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> cover() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.repository.chooseCover();
      if (mounted && result != null) {
        setState(() {
          chosen = result;
          removeCover = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final patch = <String, dynamic>{
        'album': album.text.trim(),
        'albumArtist': albumArtist.text.trim(),
        'source': 'manual',
        if (!widget.album) ...{
          'title': title.text.trim(),
          'artist': artist.text.trim(),
          'trackNumber': int.parse(number.text),
          'discNumber': int.parse(disc.text),
        },
        if (chosen != null) 'cover': chosen!.hash,
        if (removeCover) 'cover': '',
      };
      await widget.repository.editMetadata(
        widget.tracks.map((t) => MetadataEdit(t.id, patch)).toList(),
      );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> reset() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Przywrócić dane z plików?'),
        content: Text(
          'Własne poprawki i wybrane okładki zostaną cofnięte. Pliki na dysku zostaną bez zmian.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Przywróć'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.repository.resetMetadata(
        widget.tracks.map((t) => t.id).toList(),
      );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Widget field(
    String label,
    TextEditingController c, {
    bool required = false,
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      controller: c,
      enabled: !busy,
      decoration: InputDecoration(labelText: label),
      keyboardType: numeric ? TextInputType.number : null,
      validator: (v) {
        if (required && (v ?? '').trim().isEmpty) {
          return 'Wpisz tytuł';
        }
        if (numeric) {
          final n = int.tryParse(v ?? '');
          if (n == null || n < 0 || n > 9999) {
            return 'Wpisz liczbę od 0 do 9999';
          }
        }
        if ((v ?? '').length > 500) {
          return 'Maksymalnie 500 znaków';
        }
        return null;
      },
    ),
  );
  @override
  Widget build(BuildContext context) {
    final uri = removeCover ? null : chosen?.uri ?? widget.tracks.first.cover;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text(widget.album ? 'Edytuj album' : 'Edytuj utwór'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!widget.album) ...[
                    field('Tytuł', title, required: true),
                    field('Wykonawca', artist),
                  ],
                  field('Album', album),
                  field('Wykonawca albumu', albumArtist),
                  if (!widget.album)
                    Row(
                      children: [
                        Expanded(
                          child: field('Numer utworu', number, numeric: true),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: field('Numer płyty', disc, numeric: true),
                        ),
                      ],
                    ),
                  Row(
                    children: [
                      if (uri != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 14),
                          child: CoverImage(uri, width: 72, height: 72),
                        ),
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: busy ? null : cover,
                              icon: const Icon(Icons.image_outlined),
                              label: const Text('Wybierz okładkę'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => setState(() {
                                      removeCover = true;
                                      chosen = null;
                                    }),
                              child: const Text('Usuń okładkę'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: LinearProgressIndicator(),
                    ),
                  if (widget.tracks.any((t) => t.edited))
                    TextButton(
                      onPressed: busy ? null : reset,
                      child: const Text('Przywróć dane z plików'),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context, false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: busy ? null : save,
            child: const Text('Zapisz poprawki'),
          ),
        ],
      ),
    );
  }
}

class ReleaseFinder extends StatefulWidget {
  final LibraryRepository repository;
  final List<Track> tracks;
  const ReleaseFinder({
    super.key,
    required this.repository,
    required this.tracks,
  });
  @override
  State<ReleaseFinder> createState() => _ReleaseFinderState();
}

class _ReleaseFinderState extends State<ReleaseFinder> {
  late final TextEditingController album, artist;
  List<ReleaseCandidate> results = [];
  ReleaseInfo? detail;
  CoverChoice? cover;
  String? error, coverError;
  bool busy = false,
      searched = false,
      applyAlbum = true,
      applyTitles = false,
      applyCover = false,
      overwrite = false;
  List<int> mapping = [];
  @override
  void initState() {
    super.initState();
    final t = widget.tracks.first;
    album = TextEditingController(text: t.album);
    artist = TextEditingController(
      text: t.albumArtist.isEmpty ? t.artist : t.albumArtist,
    );
  }

  @override
  void dispose() {
    album.dispose();
    artist.dispose();
    super.dispose();
  }

  Future<void> search() async {
    setState(() {
      busy = true;
      error = null;
      detail = null;
      cover = null;
    });
    try {
      final r = await widget.repository.findReleases(album.text, artist.text);
      if (mounted) {
        setState(() {
          results = r;
          searched = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> select(ReleaseCandidate candidate) async {
    setState(() {
      busy = true;
      error = null;
      cover = null;
      coverError = null;
      applyCover = false;
      applyTitles = false;
    });
    try {
      final r = await widget.repository.releaseDetails(candidate.id);
      final assignments = suggestTrackMapping(widget.tracks, r.tracks);
      if (mounted) {
        setState(() {
          detail = r;
          mapping = assignments;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> fetchCover() async {
    setState(() {
      busy = true;
      coverError = null;
    });
    try {
      final r = await widget.repository.downloadCover(detail!.release.id);
      if (mounted) {
        setState(() {
          cover = r;
          applyCover = r != null;
          coverError = r == null
              ? 'Dla tego wydania nie znaleziono przedniej okładki.'
              : null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => coverError = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  List<MetadataEdit> get edits {
    if (detail == null) {
      return [];
    }
    final r = detail!;
    final list = <MetadataEdit>[];
    for (var i = 0; i < widget.tracks.length; i++) {
      final t = widget.tracks[i];
      if (t.edited && !overwrite) {
        continue;
      }
      final patch = <String, dynamic>{};
      if (applyAlbum) {
        patch.addAll({
          'album': r.release.title,
          'albumArtist': r.release.artist,
        });
      }
      if (applyTitles && mapping[i] >= 0) {
        final song = r.tracks[mapping[i]];
        patch.addAll({
          'title': song.title,
          'artist': song.artist,
          'trackNumber': song.trackNumber,
          'discNumber': song.discNumber,
        });
      }
      if (applyCover && cover != null) {
        patch['cover'] = cover!.hash;
      }
      if (patch.isNotEmpty) {
        patch.addAll({'source': 'MusicBrainz', 'releaseId': r.release.id});
        list.add(MetadataEdit(t.id, patch));
      }
    }
    return list;
  }

  Future<void> apply() async {
    final changes = edits;
    if (changes.isEmpty) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.repository.editMetadata(changes);
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Widget check(String label, bool value, ValueChanged<bool?> update) =>
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: value,
        onChanged: busy ? null : update,
        controlAffinity: ListTileControlAffinity.leading,
      );
  @override
  Widget build(BuildContext context) {
    final info = detail;
    final screen = MediaQuery.sizeOf(context);
    return PopScope(
      canPop: !busy,
      child: Dialog(
        child: SizedBox(
          width: math.min(900, screen.width - 40),
          height: math.min(760, screen.height - 48),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        info == null
                            ? 'Znajdź wydanie albumu'
                            : 'Sprawdź propozycje',
                        style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Zamknij dopasowanie',
                      onPressed: busy
                          ? null
                          : () => Navigator.pop(context, false),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (busy) const LinearProgressIndicator(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  children: [
                    if (info == null) ...[
                      const Text(
                        'Wpisane nazwy trafią do MusicBrainz. Katalog zmieni się dopiero po zapisaniu.',
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: album,
                        enabled: !busy,
                        decoration: const InputDecoration(
                          labelText: 'Nazwa albumu',
                        ),
                        onSubmitted: busy ? null : (_) => search(),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: artist,
                        enabled: !busy,
                        decoration: const InputDecoration(
                          labelText: 'Wykonawca (opcjonalnie)',
                        ),
                        onSubmitted: busy ? null : (_) => search(),
                      ),
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.icon(
                          onPressed: busy ? null : search,
                          icon: const Icon(Icons.search),
                          label: const Text('Szukaj w MusicBrainz'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (searched && results.isEmpty && !busy)
                        const Text(
                          'Brak wydań. Spróbuj krótszej nazwy lub usuń wykonawcę.',
                        ),
                      ...results.map(
                        (r) => Card(
                          child: ListTile(
                            isThreeLine: true,
                            title: Text(r.title),
                            subtitle: Text(
                              '${r.description}\nTrafność wyszukiwania: ${r.score}/100',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: busy ? null : () => select(r),
                          ),
                        ),
                      ),
                    ] else ...[
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => setState(() => detail = null),
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Inne wydania'),
                      ),
                      Text(
                        info.release.title,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(info.release.description),
                      if (info.release.barcode.isNotEmpty)
                        Text('Kod kreskowy: ${info.release.barcode}'),
                      const SizedBox(height: 6),
                      SelectableText(
                        'MusicBrainz: ${info.release.id}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Twoja biblioteka: ${collectionCount(widget.tracks.length, 'utwór', 'utwory', 'utworów')} · wydanie: ${collectionCount(info.tracks.length, 'utwór', 'utwory', 'utworów')}',
                      ),
                      if (widget.tracks.length != info.tracks.length)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'Liczba utworów się różni. Sprawdź dopasowanie.',
                            style: TextStyle(color: Colors.amber),
                          ),
                        ),
                      check(
                        'Uzupełnij nazwę i wykonawcę albumu',
                        applyAlbum,
                        (v) => setState(() => applyAlbum = v!),
                      ),
                      const Text(
                        'Nazwa i wykonawca albumu powyżej.',
                      ),
                      const Divider(),
                      Wrap(
                        spacing: 16,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (cover != null)
                            CoverImage(cover!.uri, width: 110, height: 110),
                          OutlinedButton.icon(
                            onPressed: busy ? null : fetchCover,
                            icon: const Icon(Icons.image_search),
                            label: const Text('Pobierz okładkę z CAA'),
                          ),
                        ],
                      ),
                      if (coverError != null)
                        Text(
                          coverError!,
                          style: const TextStyle(color: Colors.amber),
                        ),
                      if (cover != null)
                        check(
                          'Zastosuj pobraną okładkę',
                          applyCover,
                          (v) => setState(() => applyCover = v!),
                        ),
                      const Divider(),
                      check(
                        'Uzupełnij tytuły i wykonawców utworów',
                        applyTitles,
                        (v) => setState(() => applyTitles = v!),
                      ),
                      if (applyTitles) ...[
                        const Text(
                          'Wybierz odpowiadającą ścieżkę. Bez dopasowania tytuł zostaje.',
                        ),
                        const SizedBox(height: 12),
                        ...widget.tracks.indexed.map((pair) {
                          final i = pair.$1;
                          final local = pair.$2;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${local.discNumber}.${local.trackNumber}  ${local.title} · ${local.displayArtist}',
                                ),
                                Text(
                                  local.fileName,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                const SizedBox(height: 6),
                                DropdownButtonFormField<int>(
                                  key: ValueKey(
                                    '${info.release.id}-$i-${mapping[i]}',
                                  ),
                                  initialValue: mapping[i],
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: 'Dopasowanie ${i + 1}',
                                  ),
                                  items: [
                                    const DropdownMenuItem(
                                      value: -1,
                                      child: Text('Zachowaj obecne dane'),
                                    ),
                                    ...info.tracks.indexed.map(
                                      (s) => DropdownMenuItem(
                                        value: s.$1,
                                        child: Text(
                                          '${s.$2.position}  ${s.$2.title} · ${s.$2.artist}',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: busy
                                      ? null
                                      : (v) => setState(() => mapping[i] = v!),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                      if (widget.tracks.any((t) => t.edited))
                        check(
                          'Zastąp także własne poprawki',
                          overwrite,
                          (v) => setState(() => overwrite = v!),
                        ),
                      Text(
                        'Zmiany: ${edits.length} z ${widget.tracks.length}. Własne poprawki są chronione.',
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Dane: MusicBrainz · Okładki: Cover Art Archive',
                        style: TextStyle(fontSize: 11),
                      ),
                    ],
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Text(
                          error!,
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => Navigator.pop(context, false),
                      child: const Text('Anuluj'),
                    ),
                    const Spacer(),
                    if (info != null)
                      Flexible(
                        child: FilledButton(
                          onPressed: busy || edits.isEmpty ? null : apply,
                          child: const Text('Zapisz wybrane propozycje'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
