import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'model.dart';

export 'ingest_view.dart';

abstract interface class IngestRepository {
  Future<dynamic> ingest(Map<String, dynamic> request);
}

/// What the Audio CD tab shows. Each state comes from the engine or from an
/// action the user started here, never from a guess.
enum CdState { searching, noDrive, drive, noDisc, unsupported, readError, reading, ready, importing, done, failed }

String readableIngestError(Object e) => '$e'
    .replaceFirst('Exception: ', '')
    .replaceFirst('Bad state: ', '')
    .replaceFirst('FormatException: ', '')
    .replaceFirst('Unsupported operation: ', '');

String ingestClock(num ms) {
  final s = ms.toInt() ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

String markTime(num ms) => '${ingestClock(ms)}.${(ms.toInt() % 1000 ~/ 100)}';

/// One track row of the form: title and (for compilations) its own artist.
class TrackField {
  final TextEditingController title, artist;
  TrackField(String t, [String a = ''])
    : title = TextEditingController(text: t),
      artist = TextEditingController(text: a);
  void dispose() {
    title.dispose();
    artist.dispose();
  }
}

/// Recording waveform: min/max pairs and how many frames each point covers.
class Waveform {
  final int rate, frames, perPoint;
  final List<double> peaks;
  const Waveform(this.rate, this.frames, this.perPoint, this.peaks);
  int get durationMs => frames * 1000 ~/ rate;
  factory Waveform.fromJson(Map<String, dynamic> j) => Waveform(
    (j['rate'] as num).toInt(),
    (j['frames'] as num).toInt(),
    (j['perPoint'] as num).toInt(),
    [for (final v in j['peaks'] as List) (v as num).toDouble()],
  );
}

/// Import from physical media. Lives as long as the app, so leaving the view or
/// switching tabs keeps the form, the read disc and a running job.
class IngestState extends ChangeNotifier {
  final IngestRepository repository;
  final LibraryRepository library;

  /// Called before level check and recording (pauses playback). Never on open.
  final Future<void> Function() beforeCapture;

  /// Called after files were added to the library.
  final Future<void> Function() onLibraryChanged;

  IngestState({
    required this.repository,
    required this.library,
    required this.beforeCapture,
    required this.onLibraryChanged,
  });

  int tab = 0;
  Map<String, dynamic> status = const {};
  List<Map<String, dynamic>>? drives;
  List<Map<String, dynamic>> inputs = [], sessions = [];
  Map<String, dynamic> folders = const {};
  String? drive, input, session;
  int rate = 48000;
  bool searching = false, reading = false, busy = false;

  /// Message from reading the disc (no disc, data disc, read error).
  String? cdProblem;

  /// Last action error, shown next to the action.
  String? error;

  /// Short note about where the album description came from.
  String? described;
  Map<String, dynamic>? toc;
  List<bool> picked = [];

  /// Several MusicBrainz releases share this disc: the user picks one.
  List<ReleaseCandidate> candidates = [];
  bool describing = false;

  /// Description applied from a release (release id, date, disc, cover hash).
  String releaseId = '', date = '';
  int? disc, discs;
  CoverChoice? cover;
  bool variousArtists = false;

  // Save options.
  bool mp3 = false, eject = false, serial = false;

  /// Manual read offset (samples); null = remembered or found automatically.
  int? manualOffset;

  /// Drive with a disc that appeared while Mytify runs (for the "Wykryto płytę" prompt).
  String? inserted;
  Map<String, bool> _media = {};
  Timer? _watch;

  /// Job started from this view: rip, monitor, record, export.
  String? job;
  final album = TextEditingController(),
      artist = TextEditingController(),
      label = TextEditingController(text: 'Winyl, strona A'),
      discogs = TextEditingController(),
      searchAlbum = TextEditingController(),
      searchArtist = TextEditingController();
  List<TrackField> tracksForm = [];

  // Vinyl split editor.
  List<int> markers = [];
  Waveform? waveform;
  int cursorMs = 0;
  bool autoStop = true;
  bool declick = false, hum = false;
  double speed = 0;
  /// Number of the first exported track (side B continues the album).
  final firstTrackField = TextEditingController(text: '1');
  int get firstTrack => (int.tryParse(firstTrackField.text) ?? 1).clamp(1, 99);
  set firstTrack(int value) => firstTrackField.text = '$value';

  /// Tracklist from MusicBrainz or Discogs for the current side.
  ReleaseInfo? tracklist;
  List<bool> tracklistPicked = [];
  List<ReleaseCandidate> searchResults = [];

  int _views = 0;
  Timer? _timer;
  bool _polling = false, _disposed = false;

  bool get running => status['running'] == true;
  String get stage => status['stage'] as String? ?? '';
  bool get recording => running && status['recording'] == true;
  bool get paused => recording && status['paused'] == true;
  bool get monitoring => running && stage == 'monitor';
  bool get ripping => running && stage == 'ripping';
  bool get exporting => running && stage == 'exporting';
  bool get capturing => monitoring || recording;
  String get step => status['step'] as String? ?? '';

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void changed() => _changed();

  Future<dynamic> api(String action, [Map<String, dynamic> args = const {}]) =>
      repository.ingest({'action': action, ...args});

  /// The view became visible: list hardware. Starts nothing and changes no routing.
  void attach() {
    // After the current build: listeners elsewhere (toolbar status) must not rebuild mid-frame.
    if (_views++ == 0) scheduleMicrotask(() => unawaited(refresh()));
  }

  void detach() {
    if (_views > 0) _views--;
  }

  void setTab(int value) {
    tab = value;
    _changed();
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || !running) return;
    final period = capturing
        ? const Duration(milliseconds: 120)
        : Duration(milliseconds: _views > 0 ? 500 : 1000);
    _timer = Timer(period, () => unawaited(poll()));
  }

  /// Watches optical drives for a newly inserted disc (PC). Cheap media check every 3 s.
  void watchDiscs() {
    _watch ??= Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_checkMedia()));
  }

  Future<void> _checkMedia() async {
    if (_disposed || running || reading) return;
    try {
      final list = [for (final v in await api('media') as List) Map<String, dynamic>.from(v as Map)];
      final now = {for (final d in list) d['id'] as String: d['media'] == true};
      String? fresh;
      for (final e in now.entries) {
        if (e.value && _media[e.key] == false) fresh = e.key;
        if (!e.value && inserted == e.key) inserted = null;
      }
      final first = _media.isEmpty;
      _media = now;
      if (first || fresh == null) {
        if (!first) _changed();
        return;
      }
      inserted = fresh;
      _changed();
      // Waiting for the next disc of a batch, or the CD tab is open: read it straight away.
      if (!running && (serial || (_views > 0 && tab == 0 && job == null))) {
        await useInserted();
      }
    } catch (_) {}
  }

  void dismissInserted() {
    inserted = null;
    _changed();
  }

  /// Starts with the disc that was just inserted.
  Future<void> useInserted() async {
    final id = inserted;
    if (id == null) return;
    inserted = null;
    if (drives == null || !drives!.any((d) => d['id'] == id)) await refresh();
    final batch = serial;
    nextDisc(keepOptions: true);
    drive = id;
    await readCd();
    // Batch: an unambiguous description imports without asking; otherwise the form waits.
    if (batch && readyForBatch) await rip();
  }

  Future<void> refresh() async {
    searching = true;
    error = null;
    _changed();
    try {
      final d = await api('drives') as List;
      final i = await api('inputs') as List;
      final s = await api('sessions') as List;
      final st = await api('state') as Map;
      Map<String, dynamic> f = const {};
      try {
        f = Map<String, dynamic>.from(await api('folders') as Map);
      } catch (_) {}
      drives = [
        for (final v in d)
          v is Map ? Map<String, dynamic>.from(v) : {'id': '$v', 'name': null},
      ];
      inputs = [for (final v in i) Map<String, dynamic>.from(v as Map)];
      sessions = [for (final v in s) Map<String, dynamic>.from(v as Map)];
      status = Map<String, dynamic>.from(st);
      folders = f;
      if (!drives!.any((x) => x['id'] == drive)) drive = drives!.firstOrNull?['id'] as String?;
      if (!inputs.any((x) => x['id'] == input)) input = inputs.firstOrNull?['id'] as String?;
      _fixRate();
      if (session != null && !sessions.any((x) => x['id'] == session)) session = null;
    } catch (e) {
      drives ??= const [];
      error = readableIngestError(e);
    } finally {
      searching = false;
      _changed();
      _schedule();
    }
  }

  Map<String, dynamic>? get selectedInput => inputs.where((d) => d['id'] == input).firstOrNull;
  List<int> get rates => (selectedInput?['rates'] as List? ?? const []).cast<int>();

  /// Channels of the selected input; while measuring, what the engine really opened.
  int get channels {
    final live = (status['peaks'] as List?)?.length ?? 0;
    if (capturing && live > 0) return live;
    return ((selectedInput?['channels'] as num?)?.toInt() ?? 2).clamp(1, 2);
  }

  void _fixRate() {
    final r = rates;
    if (r.isNotEmpty && !r.contains(rate)) rate = r.contains(48000) ? 48000 : r.first;
  }

  void selectInput(String? id) {
    input = id;
    _fixRate();
    _changed();
  }

  void selectRate(int value) {
    rate = value;
    _changed();
  }

  void selectDrive(String? id) {
    drive = id;
    toc = null;
    cdProblem = null;
    _changed();
  }

  Future<void> poll() async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      final wasRunning = running;
      status = Map<String, dynamic>.from(await api('state') as Map);
      if (wasRunning && !running) await _finished();
    } catch (e) {
      error = readableIngestError(e);
    } finally {
      _polling = false;
      _changed();
      _schedule();
    }
  }

  Future<void> _finished() async {
    try {
      sessions = [for (final v in await api('sessions') as List) Map<String, dynamic>.from(v as Map)];
    } catch (_) {}
    if (job == 'record') {
      final id = status['session'] as String?;
      if (id != null && sessions.any((s) => s['id'] == id)) await selectSession(id);
    }
    if ((job == 'rip' || job == 'export') && (status['files'] as List? ?? const []).isNotEmpty) {
      await onLibraryChanged();
    }
    if (job == 'export') firstTrack += (status['files'] as List? ?? const []).length;
    // Batch: the disc was ejected; the next one is read when it appears.
    if (job == 'rip' && serial && stage == 'finished') {
      inserted = null;
      _media = {..._media, if (drive != null) drive!: false};
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    error = null;
    _changed();
    try {
      await action();
    } catch (e) {
      error = readableIngestError(e);
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> _start(String name, String action, Map<String, dynamic> args) async {
    status = Map<String, dynamic>.from(await api(action, args) as Map);
    job = name;
    _changed();
    _schedule();
  }

  // ------------------------------------------------------------------ Audio CD

  CdState get cd {
    if (job == 'rip') {
      if (ripping) return CdState.importing;
      if (stage == 'error') return CdState.failed;
      if (stage == 'finished' || stage == 'cancelled') return CdState.done;
    }
    if (drives == null || (searching && drives!.isEmpty)) return CdState.searching;
    if (drives!.isEmpty) return CdState.noDrive;
    if (reading) return CdState.reading;
    if (toc != null) return CdState.ready;
    final p = cdProblem;
    if (p != null) {
      if (p.contains('Brak płyty')) return CdState.noDisc;
      if (p.contains('danymi') || p.contains('tabel') || p.contains('Nieprawidłow')) {
        return CdState.unsupported;
      }
      return CdState.readError;
    }
    return CdState.drive;
  }

  String driveName(Map<String, dynamic> d) {
    final name = d['name'] as String?;
    return name == null || name.isEmpty ? 'Napęd ${d['id']}' : '$name (${d['id']})';
  }

  List<Map<String, dynamic>> get tracks => [
    for (final t in toc?['tracks'] as List? ?? const []) Map<String, dynamic>.from(t as Map),
  ];

  /// Track length from the table of contents (75 sectors per second).
  int trackMs(Map<String, dynamic> t) {
    final start = (t['start'] as num?)?.toInt(), end = (t['end'] as num?)?.toInt();
    return start == null || end == null ? 0 : (end - start) * 1000 ~/ 75;
  }

  /// Offset the engine remembers for this drive (from the last read), if any.
  int? get savedOffset => (toc?['offset'] as num?)?.toInt();

  void _setTracks(List<String> titles, [List<String> artists = const []]) {
    for (final c in tracksForm) {
      c.dispose();
    }
    tracksForm = [for (var i = 0; i < titles.length; i++) TrackField(titles[i], i < artists.length ? artists[i] : '')];
  }

  void _clearDescription() {
    album.clear();
    artist.clear();
    releaseId = '';
    date = '';
    disc = null;
    discs = null;
    cover = null;
    candidates = [];
    described = null;
    variousArtists = false;
  }

  Future<void> readCd() async {
    if (drive == null || reading) return;
    reading = true;
    cdProblem = null;
    toc = null;
    error = null;
    _clearDescription();
    _changed();
    try {
      final value = Map<String, dynamic>.from(await api('toc', {'drive': drive}) as Map);
      toc = value;
      final n = (value['tracks'] as List).length;
      _setTracks(List.generate(n, (i) => 'Utwór ${i + 1}'));
      picked = List.filled(n, true);
    } catch (e) {
      cdProblem = readableIngestError(e);
    } finally {
      reading = false;
      _changed();
    }
    if (toc != null) await describe();
  }

  /// Fills the album from MusicBrainz by disc id; several pressings are offered to
  /// choose from; without a match the CD-Text on the disc is used.
  Future<void> describe() async {
    if (toc == null) return;
    describing = true;
    candidates = [];
    _changed();
    try {
      final list = [
        for (final v in await api('disc', {'id': toc!['discId']}) as List)
          ReleaseCandidate.fromJson(Map<String, dynamic>.from(v as Map)),
      ];
      if (list.length == 1) {
        await chooseRelease(list.first);
      } else if (list.length > 1) {
        candidates = list;
        described = 'Ta płyta ma kilka wydań w MusicBrainz. Wybierz swoje.';
      } else {
        _fromCdText('Nie ma tej płyty w MusicBrainz.');
      }
    } catch (e) {
      _fromCdText('MusicBrainz niedostępny: ${readableIngestError(e)}.');
    } finally {
      describing = false;
      _changed();
    }
  }

  void _fromCdText(String why) {
    final t = toc?['cdText'];
    if (t is Map && ((t['album'] as String? ?? '').isNotEmpty || (t['titles'] as List? ?? const []).any((x) => '$x'.isNotEmpty))) {
      album.text = t['album'] as String? ?? '';
      artist.text = t['artist'] as String? ?? '';
      final titles = [for (final x in t['titles'] as List) '$x'];
      final artists = [for (final x in t['artists'] as List) '$x'];
      _setTracks(
        [for (var i = 0; i < tracksForm.length; i++) i < titles.length && titles[i].isNotEmpty ? titles[i] : 'Utwór ${i + 1}'],
        artists,
      );
      variousArtists = artists.toSet().where((a) => a.isNotEmpty).length > 1;
      described = '$why Opis z CD-Text zapisanego na płycie.';
    } else {
      described = '$why Wpisz nazwy ręcznie.';
    }
  }

  /// Disc of a multi-disc release whose track count and lengths match the read disc.
  int? matchingDisc(ReleaseInfo info) {
    final own = [for (final t in tracks) trackMs(t)];
    int? best;
    var bestError = double.infinity;
    for (final n in info.tracks.map((t) => t.discNumber).toSet()) {
      final songs = info.tracks.where((t) => t.discNumber == n).toList();
      if (songs.length != own.length) continue;
      var e = 0.0;
      for (var i = 0; i < own.length; i++) {
        if (songs[i].durationMs > 0) e += (songs[i].durationMs - own[i]).abs();
      }
      if (e < bestError) {
        bestError = e;
        best = n;
      }
    }
    return best;
  }

  Future<void> chooseRelease(ReleaseCandidate r) async {
    final info = await library.releaseDetails(r.id);
    final n = matchingDisc(info);
    if (n == null) {
      described = 'Wydanie „${r.title}” ma inną liczbę utworów niż płyta. Wybierz inne albo wpisz nazwy.';
      _changed();
      return;
    }
    final songs = info.tracks.where((t) => t.discNumber == n).toList();
    album.text = info.release.title;
    artist.text = info.release.artist;
    _setTracks([for (final s in songs) s.title], [for (final s in songs) s.artist == info.release.artist ? '' : s.artist]);
    variousArtists = songs.any((s) => s.artist.isNotEmpty && s.artist != info.release.artist);
    releaseId = info.release.id;
    date = info.release.date;
    final all = info.tracks.map((t) => t.discNumber).toSet();
    disc = all.length > 1 ? n : null;
    discs = all.length > 1 ? all.length : null;
    candidates = [];
    described = 'Opis z MusicBrainz: ${[info.release.title, info.release.date, info.release.country, info.release.label].where((x) => x.isNotEmpty).join(' · ')}'
        '${disc != null ? ' · płyta $disc z $discs' : ''}';
    _changed();
    try {
      cover = await library.downloadCover(r.id);
    } catch (_) {
      cover = null;
    }
    _changed();
  }

  Future<void> chooseCoverFile() => _act(() async {
    final c = await library.chooseCover();
    if (c != null) cover = c;
  });

  void pick(int i, bool value) {
    picked[i] = value;
    _changed();
  }

  void pickAll(bool value) {
    picked = List.filled(picked.length, value);
    _changed();
  }

  void setVarious(bool value) {
    variousArtists = value;
    _changed();
  }

  Future<void> rip() => _act(() async {
    await _start('rip', 'rip', {
      'drive': drive,
      'discId': toc!['discId'],
      'album': album.text,
      'artist': artist.text,
      'titles': [for (final t in tracksForm) t.title.text],
      'artists': [for (final t in tracksForm) variousArtists ? t.artist.text : ''],
      'tracks': [
        for (var i = 0; i < tracks.length; i++)
          if (picked[i]) tracks[i]['number'],
      ],
      'date': date,
      'releaseId': releaseId,
      'disc': ?disc,
      'discs': ?discs,
      'cover': ?cover?.hash,
      'mp3': mp3,
      'eject': eject || serial,
      'offset': manualOffset,
    });
  });

  Future<void> stop() => _act(() async {
    await api('stop');
    await poll();
  });

  Future<void> ejectDisc() => _act(() async {
    await api('eject', {'drive': drive});
    toc = null;
  });

  Future<void> openFolder([String? path]) => _act(() async {
    if (path == null) {
      await api('openFolder');
    } else {
      await api('openPath', {'path': path});
    }
  });

  /// Back to an empty form for the next disc. Save options stay.
  void nextDisc({bool keepOptions = true}) {
    job = null;
    toc = null;
    cdProblem = null;
    _clearDescription();
    _setTracks([]);
    picked = [];
    if (!keepOptions) {
      mp3 = false;
      eject = false;
      serial = false;
    }
    _changed();
  }

  /// A batch is waiting for the next disc.
  bool get waitingForDisc => serial && job == 'rip' && !running && stage == 'finished';

  /// Unambiguous description: the batch may import without asking.
  bool get readyForBatch => toc != null && !describing && candidates.isEmpty && releaseId.isNotEmpty;

  // ------------------------------------------------------------- Vinyl, tape

  Future<void> _stopCapture() async {
    if (!running) return;
    await api('stop');
    for (var i = 0; i < 30 && running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      status = Map<String, dynamic>.from(await api('state') as Map);
    }
  }

  Future<void> monitor() => _act(() async {
    await beforeCapture();
    await _start('monitor', 'monitor', {'id': input, 'rate': rate});
  });

  Future<void> record() => _act(() async {
    if (monitoring) await _stopCapture();
    await beforeCapture();
    await _start('record', 'record', {
      'id': input,
      'rate': rate,
      'label': label.text,
      if (autoStop) 'autoStop': 8,
    });
  });

  /// Next side of the same album: label and numbering continue.
  Future<void> recordSideB() async {
    final text = label.text;
    label.text = text.contains('strona A') ? text.replaceFirst('strona A', 'strona B') : '$text, strona B';
    await record();
  }

  Future<void> pause(bool value) => _act(() async {
    status = Map<String, dynamic>.from(await api('pause', {'value': value}) as Map);
  });

  Future<void> mark() => _act(() async {
    await api('mark');
    await poll();
  });

  Map<String, dynamic>? get selectedSession => sessions.where((s) => s['id'] == session).firstOrNull;

  Future<void> selectSession(String id) async {
    final s = sessions.firstWhere((s) => s['id'] == id);
    session = id;
    markers = [for (final m in (s['markers'] as List? ?? const []).cast<num>()) if (m > 0) m.toInt()];
    _syncTitles();
    waveform = null;
    cursorMs = 0;
    _changed();
    if (s['partial'] == true) return;
    try {
      waveform = Waveform.fromJson(Map<String, dynamic>.from(await api('waveform', {'id': id, 'points': 3000}) as Map));
    } catch (e) {
      error = readableIngestError(e);
    }
    _changed();
  }

  /// One title per track: markers split the recording into markers + 1 tracks.
  void _syncTitles() {
    final n = markers.length + 1;
    final old = [for (final t in tracksForm) (t.title.text, t.artist.text)];
    _setTracks(
      [for (var i = 0; i < n; i++) i < old.length ? old[i].$1 : 'Utwór ${i + 1}'],
      [for (var i = 0; i < n; i++) i < old.length ? old[i].$2 : ''],
    );
  }

  void setMarkers(List<int> value) {
    final duration = waveform?.durationMs ?? 1 << 62;
    final sorted = value.where((m) => m > 500 && m < duration - 500).toSet().toList()..sort();
    // Keep at least 1 s between track starts.
    final clean = <int>[];
    for (final m in sorted) {
      if (clean.isEmpty || m - clean.last >= 1000) clean.add(m);
    }
    markers = clean;
    _syncTitles();
    _changed();
  }

  void addMarker(int ms) => setMarkers([...markers, ms]);
  void removeMarker(int index) => setMarkers([...markers]..removeAt(index));
  void moveMarker(int index, int ms) {
    final next = [...markers];
    next[index] = ms;
    // Moving must not reorder: clamp between neighbours.
    final lo = index > 0 ? next[index - 1] + 1000 : 1000;
    final hi = index + 1 < next.length ? next[index + 1] - 1000 : (waveform?.durationMs ?? ms) - 1000;
    next[index] = ms.clamp(lo, hi < lo ? lo : hi);
    markers = next;
    _changed();
  }

  void setCursor(int ms) {
    cursorMs = ms;
    _changed();
  }

  Future<void> preview(int ms) => _act(() async {
    await api('preview', {'id': session, 'positionMs': ms, 'seconds': 4});
  });

  Future<void> stopPreview() => _act(() async {
    await api('previewStop');
  });

  Future<void> analyze() => _act(() async {
    final points = (await api('analyze', {'id': session}) as List).cast<num>();
    setMarkers([for (final p in points) p.toInt()]);
  });

  Future<void> recover() => _act(() async {
    await api('recover', {'id': session});
    sessions = [for (final v in await api('sessions') as List) Map<String, dynamic>.from(v as Map)];
    if (session != null) await selectSession(session!);
  });

  Future<void> searchTracklist() => _act(() async {
    searchResults = await library.findReleases(searchAlbum.text, searchArtist.text);
    if (searchResults.isEmpty) error = 'Nic nie znaleziono w MusicBrainz.';
  });

  Future<void> loadTracklist(ReleaseCandidate r) => _act(() async {
    _useTracklist(await library.releaseDetails(r.id));
    try {
      cover = await library.downloadCover(r.id);
    } catch (_) {}
  });

  Future<void> loadDiscogs() => _act(() async {
    _useTracklist(await library.discogsRelease(discogs.text));
  });

  /// Side of a vinyl position: "A1" → "A".
  static String side(ReleaseSong s) {
    final m = RegExp(r'^([A-Za-z]+)').firstMatch(s.number);
    return m == null ? '' : m.group(1)!.toUpperCase();
  }

  void _useTracklist(ReleaseInfo info) {
    tracklist = info;
    searchResults = [];
    album.text = info.release.title;
    artist.text = info.release.artist;
    releaseId = info.release.id.startsWith('discogs:') ? '' : info.release.id;
    date = info.release.date;
    // Default to the side this recording is labelled with, else the first side.
    final sides = [for (final s in info.tracks) side(s)];
    final named = RegExp(r'strona ([A-Za-z])', caseSensitive: false).firstMatch(label.text)?.group(1)?.toUpperCase();
    final want = sides.contains(named) ? named : sides.firstWhere((x) => x.isNotEmpty, orElse: () => '');
    tracklistPicked = [for (final s in sides) want == null || want.isEmpty || s == want];
    _changed();
  }

  void pickTracklist(int i, bool value) {
    tracklistPicked[i] = value;
    _changed();
  }

  /// Places markers from the picked tracks' lengths and fills their names.
  Future<void> applyTracklist() => _act(() async {
    final info = tracklist;
    if (info == null) return;
    final songs = [for (var i = 0; i < info.tracks.length; i++) if (tracklistPicked[i]) info.tracks[i]];
    if (songs.length < 2) {
      setMarkers([]);
    } else if (songs.any((s) => s.durationMs <= 0)) {
      throw StateError('Lista nie ma czasów wszystkich utworów. Ustaw znaczniki ręcznie.');
    } else {
      final points = (await api('align', {'id': session, 'durations': [for (final s in songs) s.durationMs]}) as List).cast<num>();
      setMarkers([for (final p in points) p.toInt()]);
    }
    _setTracks([for (final s in songs) s.title], [for (final s in songs) s.artist == info.release.artist ? '' : s.artist]);
    variousArtists = songs.any((s) => s.artist.isNotEmpty && s.artist != info.release.artist);
    final picked = [for (var i = 0; i < info.tracks.length; i++) if (tracklistPicked[i]) i];
    if (picked.isNotEmpty) firstTrack = picked.first + 1;
  });

  Future<void> export() => _act(() async {
    await _start('export', 'export', {
      'id': session,
      'album': album.text,
      'artist': artist.text,
      'markers': markers,
      'titles': [for (final t in tracksForm) t.title.text],
      'artists': [for (final t in tracksForm) variousArtists ? t.artist.text : ''],
      'firstTrack': firstTrack,
      if (tracklist != null) 'totalTracks': tracklist!.tracks.length,
      'date': date,
      'releaseId': releaseId,
      'cover': ?cover?.hash,
      'mp3': mp3,
      'restore': {
        'declick': declick,
        if (hum) 'hum': 50,
        'speed': 1 + speed / 100,
      },
    });
  });

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _watch?.cancel();
    for (final c in [album, artist, label, discogs, searchAlbum, searchArtist, firstTrackField]) {
      c.dispose();
    }
    for (final t in tracksForm) {
      t.dispose();
    }
    super.dispose();
  }
}
