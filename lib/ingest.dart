import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'capture_stage.dart';
import 'errors.dart';
import 'model.dart';
import 'l10n.dart';

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

/// Name compared the way people read it: case, spacing and non-breaking spaces ignored.
String sameName(String s) => s.replaceAll(RegExp(r'[\s\u00a0\u202f]+'), ' ').trim().toLowerCase();

/// Album title without edition notes ("(Deluxe Edition)", "- Remastered 2011").
String plainAlbumTitle(String title) {
  const notes = r'deluxe|edition|remaster|expanded|anniversary|bonus|version|edycja';
  var t = title.replaceAll(RegExp('\\s*[\\(\\[][^\\)\\]]*($notes)[^\\)\\]]*[\\)\\]]', caseSensitive: false), '');
  t = t.replaceAll(RegExp('\\s+-\\s+[^-]*($notes).*\$', caseSensitive: false), '');
  return t.trim().isEmpty ? title : t.trim();
}

/// "4:05", "1:02:03" or "245" (seconds) → milliseconds; 0 when it is not a length.
int parseClock(String text) {
  final parts = text.trim().replaceAll(',', '.').split(':');
  if (parts.isEmpty || parts.length > 3 || parts.any((p) => p.trim().isEmpty)) return 0;
  var seconds = 0.0;
  for (final p in parts) {
    final v = double.tryParse(p.trim());
    if (v == null || v < 0) return 0;
    seconds = seconds * 60 + v;
  }
  return (seconds * 1000).round();
}

/// One expected song of an app recording: title and length, both editable.
class AppTrack {
  final TextEditingController title, length;
  final String artist;

  /// Vinyl and tape: on the side being recorded.
  bool picked = true;
  AppTrack(String name, int ms, this.artist)
    : title = TextEditingController(text: name),
      length = TextEditingController(text: ms > 0 ? ingestClock(ms) : '');
  int get ms => parseClock(length.text);
  void dispose() {
    title.dispose();
    length.dispose();
  }
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

/// Album, artist, tracks, cover and release of one import.
class IngestForm {
  final album = TextEditingController(), artist = TextEditingController();
  List<TrackField> tracks = [];
  CoverChoice? cover;
  bool various = false;
  String releaseId = '', date = '';

  void setTracks(List<String> titles, [List<String> artists = const []]) {
    // Fields on screen still hold these until the next frame (a second album loaded
    // while the first one's list is shown).
    disposeLater([for (final c in tracks) ...[c.title, c.artist]]);
    tracks = [for (var i = 0; i < titles.length; i++) TrackField(titles[i], i < artists.length ? artists[i] : '')];
  }

  void clear() {
    album.clear();
    artist.clear();
    releaseId = '';
    date = '';
    cover = null;
    various = false;
  }

  List<String> get titles => [for (final t in tracks) t.title.text];
  List<String> get artists => [for (final t in tracks) various ? t.artist.text : ''];

  void dispose() {
    album.dispose();
    artist.dispose();
    for (final t in tracks) {
      t.dispose();
    }
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

  /// Called with the album artist after an import (to fetch their photo).
  final Future<void> Function(List<String> artists)? onImported;

  /// Adds a folder to the library as a source (the chosen music folder).
  final Future<void> Function(String folder)? addSource;

  /// Called after albums were moved into the music folder (artist photos follow).
  final Future<void> Function()? onMoved;

  IngestState({
    required this.repository,
    required this.library,
    required this.beforeCapture,
    required this.onLibraryChanged,
    this.onImported,
    this.addSource,
    this.onMoved,
  });

  /// Music folder for imports (PC): `path`, `available`, `inLibrary` and `stored`
  /// (albums made earlier that still sit in the app data).
  Map<String, dynamic> musicFolder = const {};
  String? get musicPath => musicFolder['path'] as String?;
  int get storedAlbums => (musicFolder['stored'] as num? ?? 0).toInt();
  bool get moving => running && stage == 'moving';

  Future<void> loadMusicFolder() async {
    try {
      musicFolder = Map<String, dynamic>.from(await api('importFolder') as Map);
    } catch (_) {}
    _changed();
  }

  Future<void> chooseMusicFolder() => _act(() async {
    final paths = (await api('pickFolder') as Map)['paths'] as List? ?? const [];
    if (paths.isEmpty) return;
    await _setMusicFolder('${paths.first}');
  });

  Future<void> clearMusicFolder() => _act(() => _setMusicFolder(null));

  Future<void> _setMusicFolder(String? path) async {
    musicFolder = Map<String, dynamic>.from(await api('setImportFolder', {'path': path}) as Map);
    _changed();
    // The music folder is part of the library right away.
    final add = addSource;
    if (path != null && musicFolder['available'] == true && musicFolder['inLibrary'] != true && add != null) {
      await add(path);
      await loadMusicFolder();
    }
  }

  /// Albums made earlier move from the app data into the music folder layout.
  Future<void> moveStored() => _act(() => _start('move', 'relocate', {}));

  int tab = tabApp;
  Map<String, dynamic> status = const {};
  List<Map<String, dynamic>>? drives;
  List<Map<String, dynamic>> inputs = [], sessions = [];

  /// Programs with sound now (PC), for recording one app.
  List<Map<String, dynamic>> apps = [];
  String? app;

  /// Album read from a Spotify link for the app recording (name, artist, tracks, lengths).
  Map<String, dynamic>? spotify;
  final spotifyLink = TextEditingController();

  /// After an app recording: split by the album's lengths, tag and save without asking.
  bool autoSave = true;
  bool _appRecording = false, _vinylRecording = false;

  /// Where the app album's description came from.
  String? appDescribed;
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

  /// Disc of a multi-disc release.
  int? disc, discs;

  /// Album form of each tab, so a read CD and a recording never mix.
  final cdForm = IngestForm(), vinylForm = IngestForm();
  IngestForm get form => tab == 0 ? cdForm : vinylForm;

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
  final label = TextEditingController(text: tr('Winyl, strona A')),
      discogs = TextEditingController(),
      searchAlbum = TextEditingController(),
      searchArtist = TextEditingController();

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

  /// Whole job, 0..1, live from the core (every track and file), else done of total.
  double? get progress {
    final p = status['progress'] as num?;
    if (p != null) return p.toDouble().clamp(0, 1);
    final done = (status['done'] as num? ?? 0).toDouble(), total = (status['total'] as num? ?? 0).toDouble();
    return total > 0 ? (done / total).clamp(0, 1) : null;
  }

  /// Current part (track being saved, file being copied), 0..1.
  double get part => (status['part'] as num? ?? 0).toDouble().clamp(0, 1);
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

  /// Tabs: [tabCd], [tabVinyl] (audio input), [tabApp]. Shown as App, CD, Vinyl.
  static const tabCd = 0, tabVinyl = 1, tabApp = 2;

  void setTab(int value) {
    tab = value;
    _changed();
    // The app list changes as programs start and close.
    if (value == tabApp && !running) unawaited(refresh());
  }

  /// Recording from one app (else from an audio input).
  bool get appSource => tab == tabApp;

  void setAppSource(bool value) => setTab(value ? tabApp : tabVinyl);

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
      try {
        apps = [for (final v in await api('apps') as List) Map<String, dynamic>.from(v as Map)];
      } catch (_) {
        apps = [];
      }
      if (!apps.any((x) => x['id'] == app)) {
        app = (apps.where((x) => x['id'] == 'spotify').firstOrNull ?? apps.where((x) => x['playing'] == true).firstOrNull ?? apps.firstOrNull)?['id'] as String?;
      }
      Map<String, dynamic> f = const {};
      try {
        f = Map<String, dynamic>.from(await api('folders') as Map);
        musicFolder = Map<String, dynamic>.from(await api('importFolder') as Map);
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

  void selectApp(String? id) {
    app = id;
    _changed();
  }

  bool get appSession => selectedSession?['app'] != null;

  /// Total length of the album from the link (0 when some length is unknown).
  /// Expected songs of the app recording (from the link or typed), editable.
  final appTracks = <AppTrack>[];

  void addAppTrack() {
    appTracks.add(AppTrack('', 0, vinylForm.artist.text.trim()));
    _changed();
  }

  void removeAppTrack(int i) {
    final t = appTracks.removeAt(i);
    disposeLater([t.title, t.length]);
    _changed();
  }

  void _fillAppTracks(List<ReleaseSong> songs) {
    // The fields on screen still hold the old controllers until the next frame.
    disposeLater([for (final t in appTracks) ...[t.title, t.length]]);
    appTracks
      ..clear()
      ..addAll([for (final x in songs) AppTrack(x.title, x.durationMs, x.artist)]);
  }

  /// The edited list becomes the track list the recording is cut and tagged by.
  void _syncAppTracks() {
    if (appTracks.isEmpty) return;
    final albumArtist = sameName(tracklist?.release.artist ?? vinylForm.artist.text);
    final release =
        tracklist?.release ??
        ReleaseCandidate(
          id: '',
          title: vinylForm.album.text.trim(),
          artist: vinylForm.artist.text.trim(),
          date: vinylForm.date,
          country: '',
          format: '',
          label: '',
          barcode: '',
          disambiguation: '',
          trackCount: appTracks.length,
          score: 0,
        );
    tracklist = ReleaseInfo(release, [
      for (var i = 0; i < appTracks.length; i++)
        ReleaseSong(
          title: appTracks[i].title.text.trim().isEmpty ? tr('Utwór {0}', [i + 1]) : appTracks[i].title.text.trim(),
          // The album's own artist is not a per-track artist (no compilation).
          artist: sameName(appTracks[i].artist) == albumArtist ? (tracklist?.release.artist ?? vinylForm.artist.text.trim()) : appTracks[i].artist,
          discNumber: 1,
          trackNumber: i + 1,
          durationMs: appTracks[i].ms,
        ),
    ]);
    // An app plays the whole album; a vinyl or tape side holds the ticked tracks.
    tracklistPicked = [for (final t in appTracks) appSource || t.picked];
    final first = tracklistPicked.indexOf(true);
    firstTrack = first < 0 ? 1 : first + 1;
  }

  void pickAppTrack(int i, bool value) {
    appTracks[i].picked = value;
    _changed();
  }

  int get albumMs {
    if (appTracks.isNotEmpty) {
      return appTracks.any((t) => t.ms <= 0) ? 0 : appTracks.fold(0, (a, t) => a + t.ms);
    }
    final t = tracklist?.tracks ?? const <ReleaseSong>[];
    if (t.isEmpty || t.any((x) => x.durationMs <= 0)) return 0;
    return t.fold(0, (a, x) => a + x.durationMs);
  }

  /// Reads the album behind a Spotify link and finds it in MusicBrainz for full tags.
  /// The track lengths stay Spotify's: they are what the app plays.
  Future<void> loadSpotify() => _act(() async {
    final (info, found) = await _spotifyRelease(spotifyLink.text);
    spotify = info;
    final title = info['title'] as String? ?? '', artist = info['artist'] as String? ?? '';
    _useTracklist(found);
    tracklistPicked = [for (final _ in found.tracks) true];
    firstTrack = 1;
    _fillAppTracks(found.tracks);
    final cover = info['cover'];
    if (cover is Map) {
      vinylForm.cover = CoverChoice.fromJson(Map<String, dynamic>.from(cover));
    } else if (found.release.id.isNotEmpty) {
      try {
        vinylForm.cover = await library.downloadCover(found.release.id);
      } catch (_) {}
    }
    label.text = [artist, title].where((x) => x.isNotEmpty).join(' · ');
    appDescribed = found.release.id.isNotEmpty
        ? tr('Opis z MusicBrainz: {0}', [[found.release.title, found.release.date, found.release.country].where((x) => x.isNotEmpty).join(' · ')])
        : tr('MusicBrainz nie zna tego wydania. Tytuły ze Spotify.');
  });

  /// CD from a Spotify link: names, tracks and cover only (the disc decides the audio).
  final cdSpotifyLink = TextEditingController();

  Future<void> loadSpotifyCd() => _act(() async {
    final (info, found) = await _spotifyRelease(cdSpotifyLink.text);
    final n = found.release.id.isNotEmpty ? matchingDisc(found) : null;
    final songs = n != null ? found.tracks.where((t) => t.discNumber == n).toList() : found.tracks;
    final own = cdForm.tracks.length;
    cdForm.album.text = found.release.title;
    cdForm.artist.text = found.release.artist;
    final titles = [for (var i = 0; i < own; i++) i < songs.length ? songs[i].title : cdForm.tracks[i].title.text];
    final artists = [for (var i = 0; i < own; i++) i < songs.length && sameName(songs[i].artist) != sameName(found.release.artist) ? songs[i].artist : ''];
    cdForm.setTracks(own == 0 ? [for (final x in songs) x.title] : titles, artists);
    cdForm.various = artists.any((a) => a.isNotEmpty && !sameName(a).contains(sameName(found.release.artist)));
    cdForm.releaseId = found.release.id;
    cdForm.date = found.release.date.isNotEmpty ? found.release.date : '${info['date'] ?? ''}';
    final cover = info['cover'];
    if (cover is Map) cdForm.cover = CoverChoice.fromJson(Map<String, dynamic>.from(cover));
    described = own > 0 && songs.length != own
        ? tr('Spotify: {0} utworów, płyta: {1}. Sprawdź tytuły.', [songs.length, own])
        : tr('Opis ze Spotify: {0}', [[found.release.artist, found.release.title].where((x) => x.isNotEmpty).join(' · ')]);
  });

  /// The album behind a Spotify link, found in MusicBrainz for full tags when possible.
  /// Track lengths stay Spotify's: they are what the app plays.
  Future<(Map<String, dynamic>, ReleaseInfo)> _spotifyRelease(String url) async {
    final info = Map<String, dynamic>.from(await api('spotifyAlbum', {'url': url.trim()}) as Map);
    final title = info['title'] as String? ?? '';
    final artist = info['artist'] as String? ?? '';
    final songs = [
      for (final t in info['tracks'] as List? ?? const [])
        (title: '${(t as Map)['title']}', artist: '${t['artist'] ?? ''}', ms: (t['durationMs'] as num? ?? 0).toInt()),
    ];
    final count = (info['trackCount'] as num? ?? songs.length).toInt();
    ReleaseInfo? found;
    try {
      // "Queen of Time (Deluxe Edition)" is "Queen of Time" in MusicBrainz.
      final plain = plainAlbumTitle(title);
      final candidates = [
        ...await library.findReleases(title, artist),
        if (plain != title) ...await library.findReleases(plain, artist),
      ];
      final same = candidates.where((c) => count == 0 || c.trackCount == count).toList()
        ..sort((a, b) => (b.format.contains('Digital') ? 1 : 0).compareTo(a.format.contains('Digital') ? 1 : 0));
      if (same.isNotEmpty) found = await library.releaseDetails(same.first.id);
    } catch (_) {
      /* MusicBrainz unavailable: Spotify's names are used */
    }
    if (found != null && songs.length == found.tracks.length) {
      found = ReleaseInfo(found.release, [
        for (var i = 0; i < songs.length; i++)
          ReleaseSong(
            title: found.tracks[i].title,
            artist: found.tracks[i].artist,
            discNumber: found.tracks[i].discNumber,
            trackNumber: found.tracks[i].trackNumber,
            durationMs: songs[i].ms > 0 ? songs[i].ms : found.tracks[i].durationMs,
          ),
      ]);
    }
    found ??= ReleaseInfo(
      ReleaseCandidate(
        id: '',
        title: title,
        artist: artist,
        date: info['date'] as String? ?? '',
        country: '',
        format: 'Spotify',
        label: '',
        barcode: '',
        disambiguation: '',
        trackCount: count,
        score: 0,
      ),
      [
        for (var i = 0; i < songs.length; i++)
          ReleaseSong(title: songs[i].title, artist: songs[i].artist, discNumber: 1, trackNumber: i + 1, durationMs: songs[i].ms),
      ],
    );
    return (info, found);
  }

  Future<void> monitorApp() => _act(() async {
    await beforeCapture();
    await _start('monitor', 'monitor', {'app': app});
  });

  /// Records the app from its first sound until the album's length (when known) or
  /// 8 s of silence.
  Future<void> recordApp() => _act(() async {
    if (monitoring) await _stopCapture();
    await beforeCapture();
    tab = tabApp;
    _syncAppTracks();
    final total = albumMs;
    await _start('record', 'record', {
      'app': app,
      'rate': 44100,
      'label': label.text.trim().isEmpty ? tr('Nagranie z aplikacji') : label.text.trim(),
      'autoStop': 8,
      'waitForSound': true,
      if (total > 0) 'maxMs': total + 15000,
    });
    _appRecording = true;
  });

  /// Cuts placed by the album's lengths (or by silence without a list), then saved.
  Future<void> _splitAppRecording() async {
    _syncAppTracks();
    if (tracklist != null && albumMs > 0) {
      await applyTracklist();
      if (error == null && autoSave && markers.length == vinylForm.tracks.length - 1) await export();
    } else {
      await analyze();
    }
  }

  // ------------------------------------------------------------- Capture stage

  /// Expected songs of the recording: the app list, or the picked side of a record.
  List<({String title, String artist, int ms})> get expectedSongs {
    if (appTracks.isNotEmpty) {
      // App: the whole album; vinyl and tape: the ticked side.
      return [
        for (var i = 0; i < appTracks.length; i++)
          if (appSource || appTracks[i].picked)
            (title: appTracks[i].title.text.trim().isEmpty ? tr('Utwór {0}', [i + 1]) : appTracks[i].title.text.trim(), artist: appTracks[i].artist, ms: appTracks[i].ms),
      ];
    }
    final t = tracklist?.tracks ?? const <ReleaseSong>[];
    return [
      for (var i = 0; i < t.length; i++)
        if (i < tracklistPicked.length && tracklistPicked[i]) (title: t[i].title, artist: t[i].artist, ms: t[i].durationMs),
    ];
  }

  String get _appName => '${apps.where((a) => a['id'] == app).firstOrNull?['name'] ?? app ?? ''}';

  /// What the stage shows while recording: with known lengths, the song being
  /// recorded now and how much of it is done.
  StageInfo recordStage() {
    final frames = (status['frames'] as num? ?? 0).toDouble();
    final hz = (status['rate'] as num? ?? rate).toDouble();
    final ms = (frames * 1000 / (hz > 0 ? hz : 44100)).round();
    final album = [vinylForm.artist.text.trim(), vinylForm.album.text.trim()].where((x) => x.isNotEmpty).join(' · ');
    if (step.isNotEmpty) {
      return StageInfo(
        kicker: tr('Czekam na dźwięk'),
        title: appSource ? tr('Włącz album w: {0}', [_appName]) : trMessage(step),
        subtitle: tr('Nagrywanie ruszy samo od pierwszego dźwięku.'),
        time: ingestClock(0),
        waiting: true,
        rec: true,
      );
    }
    final songs = expectedSongs;
    final known = songs.isNotEmpty && songs.every((x) => x.ms > 0);
    if (!known) {
      return StageInfo(
        kicker: paused ? tr('Pauza') : tr('Nagrywanie'),
        title: label.text.trim().isEmpty ? tr('Nagranie') : label.text.trim(),
        subtitle: album,
        time: ingestClock(ms),
        paused: paused,
        rec: true,
      );
    }
    final total = songs.fold(0, (a, x) => a + x.ms);
    var i = 0, from = 0;
    while (i < songs.length - 1 && ms >= from + songs[i].ms) {
      from += songs[i].ms;
      i++;
    }
    final song = songs[i];
    return StageInfo(
      kicker: paused ? tr('Pauza') : tr('Teraz zgrywane'),
      title: song.title,
      subtitle: [tr('Utwór {0} z {1}', [i + 1, songs.length]), if (song.artist.isNotEmpty) song.artist else if (album.isNotEmpty) album].join(' · '),
      track: ((ms - from) / song.ms).clamp(0, 1).toDouble(),
      overall: (ms / total).clamp(0, 1).toDouble(),
      time: ingestClock(ms),
      total: ingestClock(total),
      parts: [for (final x in songs) x.ms.toDouble()],
      current: i,
      paused: paused,
      rec: true,
    );
  }

  /// Saving the split tracks into the library.
  StageInfo exportStage() {
    final done = (status['done'] as num? ?? 0).toInt();
    final total = (status['total'] as num? ?? 0).toInt();
    final titles = vinylForm.titles;
    final i = done.clamp(0, titles.isEmpty ? 0 : titles.length - 1);
    final overall = progress;
    // After the last track: tags and the library, shown as such.
    final finishing = total > 0 && done >= total;
    return StageInfo(
      kicker: tr('Zapisuję do biblioteki'),
      title: finishing || titles.isEmpty ? trMessage(step) : titles[i],
      subtitle: [
        if (total > 0 && !finishing) tr('Utwór {0} z {1}', [(done + 1).clamp(1, total), total]),
        appSession ? tr('MP3 320 kb/s') : 'FLAC',
      ].join(' · '),
      track: part,
      overall: overall,
      time: overall == null ? '' : '${(overall * 100).floor()}%',
      parts: _withSaving(_exportLengths(total), .9),
      current: finishing ? total : done,
    );
  }

  /// Track lengths of the export (from the markers), so the timeline moves with the core.
  List<double> _exportLengths(int total) {
    final len = (sessions.where((x) => x['id'] == session).firstOrNull?['durationMs'] as num? ?? 0).toInt();
    final cuts = [0, ...markers.where((m) => m > 0 && m < len), len];
    if (len <= 0 || cuts.length - 1 != total) return [for (var k = 0; k < total; k++) 1.0];
    return [for (var k = 1; k < cuts.length; k++) (cuts[k] - cuts[k - 1]).toDouble()];
  }

  /// The last stretch of the timeline: tags and the library after the audio part.
  static List<double> _withSaving(List<double> parts, double audioShare) {
    final sum = parts.fold(0.0, (a, b) => a + b);
    return sum <= 0 ? parts : [...parts, sum * (1 - audioShare) / audioShare];
  }

  /// Reading a CD: the track being read now, its percentage and the whole disc.
  StageInfo ripStage() {
    final done = (status['done'] as num? ?? 0).toDouble();
    final number = (status['track'] as num? ?? 0).toInt();
    final from = (status['trackFrom'] as num? ?? 0).toDouble();
    final len = (status['trackLen'] as num? ?? 0).toDouble();
    final chosen = [
      for (var i = 0; i < tracks.length; i++)
        if (i >= picked.length || picked[i]) (i, tracks[i]),
    ];
    final at = chosen.indexWhere((c) => c.$2['number'] == number);
    final album = [cdForm.artist.text.trim(), cdForm.album.text.trim()].where((x) => x.isNotEmpty).join(' · ');
    final overall = progress;
    final saving = (status['files'] as List? ?? const []).isNotEmpty && number == 0;
    if (number == 0 || at < 0) {
      return StageInfo(
        kicker: saving ? tr('Zapisuję do biblioteki') : tr('Przygotowanie'),
        title: trMessage(step),
        subtitle: album,
        track: saving ? part : null,
        overall: overall,
        time: overall == null ? '' : '${(overall * 100).floor()}%',
        parts: saving ? _withSaving([for (final c in chosen) trackMs(c.$2).toDouble()], .95) : const [],
        current: chosen.length,
      );
    }
    final index = chosen[at].$1;
    final title = index < cdForm.tracks.length ? cdForm.tracks[index].title.text.trim() : '';
    return StageInfo(
      kicker: tr('Teraz zgrywane'),
      title: title.isEmpty ? tr('Ścieżka {0}', [number]) : title,
      subtitle: [tr('Utwór {0} z {1}', [at + 1, chosen.length]), if (album.isNotEmpty) album, if (step.isNotEmpty && !step.startsWith('Odczyt ścieżki')) trMessage(step)].join(' · '),
      track: len > 0 ? ((done - from) / len).clamp(0, 1).toDouble() : null,
      overall: overall,
      time: overall == null ? '' : '${(overall * 100).floor()}%',
      parts: _withSaving([for (final c in chosen) trackMs(c.$2).toDouble()], .95),
      current: at,
    );
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
      if (id != null && sessions.any((s) => s['id'] == id)) {
        await selectSession(id);
        if (_appRecording && stage != 'error') await _splitAppRecording();
        // Vinyl with an album list and no markers set by hand: cut by the lengths
        // (snapped to the gaps between songs), then saved or left to check.
        if (_vinylRecording && stage != 'error' && markers.isEmpty && appTracks.any((t) => t.picked)) await _splitAppRecording();
      }
      _appRecording = false;
      _vinylRecording = false;
    }
    if (job == 'move') {
      await onLibraryChanged();
      await loadMusicFolder();
      final moved = onMoved;
      if (moved != null) unawaited(moved());
    }
    if ((job == 'rip' || job == 'export') && (status['files'] as List? ?? const []).isNotEmpty) {
      await onLibraryChanged();
      final f = job == 'rip' ? cdForm : vinylForm;
      final artists = {
        if (!f.various && f.artist.text.trim().isNotEmpty) f.artist.text.trim(),
        for (final a in f.artists) if (a.trim().isNotEmpty) a.trim(),
      }.toList();
      final imported = onImported;
      if (imported != null && artists.isNotEmpty) unawaited(imported(artists));
    }
    // Side B continues the numbering of side A; an app album is complete in one go.
    if (job == 'export' && !appSession) firstTrack += (status['files'] as List? ?? const []).length;
    // Batch: the disc was ejected; the next one is read when it appears.
    if (job == 'rip' && serial && stage == 'finished') {
      inserted = null;
      final d = drive;
      if (d != null) _media = {..._media, d: false};
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
    return name == null || name.isEmpty ? tr('Napęd {0}', [d['id']]) : '$name (${d['id']})';
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

  void _clearDescription() {
    cdForm.clear();
    disc = null;
    discs = null;
    candidates = [];
    described = null;
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
      cdForm.setTracks(List.generate(n, (i) => tr('Utwór {0}', [i + 1])));
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
        described = tr('Ta płyta ma kilka wydań w MusicBrainz. Wybierz swoje.');
      } else {
        _fromCdText(tr('Nie ma tej płyty w MusicBrainz.'));
      }
    } catch (e) {
      _fromCdText(tr('MusicBrainz niedostępny: {0}.', [readableIngestError(e)]));
    } finally {
      describing = false;
      _changed();
    }
  }

  void _fromCdText(String why) {
    final t = toc?['cdText'];
    if (t is Map && ((t['album'] as String? ?? '').isNotEmpty || (t['titles'] as List? ?? const []).any((x) => '$x'.isNotEmpty))) {
      cdForm.album.text = t['album'] as String? ?? '';
      cdForm.artist.text = t['artist'] as String? ?? '';
      final titles = [for (final x in t['titles'] as List) '$x'];
      final artists = [for (final x in t['artists'] as List) '$x'];
      cdForm.setTracks(
        [for (var i = 0; i < cdForm.tracks.length; i++) i < titles.length && titles[i].isNotEmpty ? titles[i] : tr('Utwór {0}', [i + 1])],
        artists,
      );
      cdForm.various = artists.toSet().where((a) => a.isNotEmpty).length > 1;
      described = tr('{0} Opis z CD-Text zapisanego na płycie.', [why]);
    } else {
      described = tr('{0} Wpisz nazwy ręcznie.', [why]);
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
      described = tr('Wydanie „{0}” ma inną liczbę utworów niż płyta. Wybierz inne albo wpisz nazwy.', [r.title]);
      _changed();
      return;
    }
    final songs = info.tracks.where((t) => t.discNumber == n).toList();
    cdForm.album.text = info.release.title;
    cdForm.artist.text = info.release.artist;
    cdForm.setTracks([for (final s in songs) s.title], [for (final s in songs) s.artist == info.release.artist ? '' : s.artist]);
    cdForm.various = songs.any((s) => s.artist.isNotEmpty && s.artist != info.release.artist);
    cdForm.releaseId = info.release.id;
    cdForm.date = info.release.date;
    final all = info.tracks.map((t) => t.discNumber).toSet();
    disc = all.length > 1 ? n : null;
    discs = all.length > 1 ? all.length : null;
    candidates = [];
    described = tr('Opis z MusicBrainz: {0}{1}', [[info.release.title, info.release.date, info.release.country, info.release.label].where((x) => x.isNotEmpty).join(' · '), disc != null ? tr(' · płyta {0} z {1}', [disc, discs]) : '']);
    _changed();
    try {
      cdForm.cover = await library.downloadCover(r.id);
    } catch (_) {
      cdForm.cover = null;
    }
    _changed();
  }

  Future<void> chooseCoverFile() => _act(() async {
    final c = await library.chooseCover();
    if (c != null) form.cover = c;
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
    form.various = value;
    _changed();
  }

  Future<void> rip() => _act(() async {
    await _start('rip', 'rip', {
      'drive': drive,
      'discId': toc!['discId'],
      'album': cdForm.album.text,
      'artist': cdForm.artist.text,
      'titles': cdForm.titles,
      'artists': cdForm.artists,
      'tracks': [
        for (var i = 0; i < tracks.length; i++)
          if (picked[i]) tracks[i]['number'],
      ],
      'date': cdForm.date,
      'releaseId': cdForm.releaseId,
      'disc': ?disc,
      'discs': ?discs,
      'cover': ?cdForm.cover?.hash,
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
    cdForm.setTracks([]);
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
  bool get readyForBatch => toc != null && !describing && candidates.isEmpty && cdForm.releaseId.isNotEmpty;

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
    _vinylRecording = true;
  });

  /// Next side of the same album: label and numbering continue.
  Future<void> recordSideB() async {
    final text = label.text;
    final a = tr('strona A'), b = tr('strona B');
    label.text = text.contains(a) ? text.replaceFirst(a, b) : tr('{0}, strona B', [text]);
    // The other side: the tracks not recorded yet.
    if (appTracks.isNotEmpty && appTracks.any((t) => t.picked) && appTracks.any((t) => !t.picked)) {
      for (final t in appTracks) {
        t.picked = !t.picked;
      }
    }
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
    final old = [for (final t in vinylForm.tracks) (t.title.text, t.artist.text)];
    vinylForm.setTracks(
      [for (var i = 0; i < n; i++) i < old.length ? old[i].$1 : tr('Utwór {0}', [i + 1])],
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
    if (searchResults.isEmpty) error = tr('Nic nie znaleziono w MusicBrainz.');
  });

  Future<void> loadTracklist(ReleaseCandidate r) => _act(() async {
    _useTracklist(await library.releaseDetails(r.id));
    try {
      vinylForm.cover = await library.downloadCover(r.id);
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
    vinylForm.album.text = info.release.title;
    vinylForm.artist.text = info.release.artist;
    vinylForm.releaseId = info.release.id.startsWith('discogs:') ? '' : info.release.id;
    vinylForm.date = info.release.date;
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
      throw StateError(tr('Lista nie ma czasów wszystkich utworów. Ustaw znaczniki ręcznie.'));
    } else {
      final points = (await api('align', {'id': session, 'durations': [for (final s in songs) s.durationMs]}) as List).cast<num>();
      setMarkers([for (final p in points) p.toInt()]);
    }
    final own = sameName(info.release.artist);
    bool other(ReleaseSong s) => s.artist.trim().isNotEmpty && sameName(s.artist) != own;
    vinylForm.setTracks([for (final s in songs) s.title], [for (final s in songs) other(s) ? s.artist : '']);
    // A guest on some tracks ("Amorphis, Hellscore") keeps the album the band's own; only
    // tracks without the album artist make it a compilation.
    vinylForm.various = own.isNotEmpty && songs.any((s) => other(s) && !sameName(s.artist).contains(own));
    final picked = [for (var i = 0; i < info.tracks.length; i++) if (tracklistPicked[i]) i];
    if (picked.isNotEmpty) firstTrack = picked.first + 1;
  });

  Future<void> export() => _act(() async {
    final fromApp = appSession;
    // The last track ends with its length, not with whatever the app played next.
    final picked = [for (var i = 0; i < (tracklist?.tracks.length ?? 0); i++) if (tracklistPicked[i]) tracklist!.tracks[i]];
    final last = picked.length == vinylForm.tracks.length ? picked.lastOrNull?.durationMs ?? 0 : 0;
    final endMs = fromApp && last > 0 ? (markers.lastOrNull ?? 0) + last + 1500 : 0;
    await _start('export', 'export', {
      if (fromApp) 'mp3Only': true,
      if (fromApp) 'mp3Kbps': 320,
      if (endMs > 0) 'endMs': endMs,
      'id': session,
      'album': vinylForm.album.text,
      'artist': vinylForm.artist.text,
      'markers': markers,
      'titles': vinylForm.titles,
      'artists': vinylForm.artists,
      'firstTrack': firstTrack,
      if (tracklist != null) 'totalTracks': tracklist!.tracks.length,
      'date': vinylForm.date,
      'releaseId': vinylForm.releaseId,
      'cover': ?vinylForm.cover?.hash,
      'mp3': mp3,
      'restore': fromApp
          ? {'declick': false, 'speed': 1}
          : {
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
    for (final c in [label, discogs, searchAlbum, searchArtist, firstTrackField, spotifyLink, cdSpotifyLink]) {
      c.dispose();
    }
    for (final t in appTracks) {
      t.dispose();
    }
    cdForm.dispose();
    vinylForm.dispose();
    super.dispose();
  }
}
