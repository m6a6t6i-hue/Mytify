import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'audio_player.dart';
import 'design.dart';
import 'devices.dart';
import 'ingest.dart';
import 'mini_player.dart';
import 'visualizer.dart';
import 'intro.dart';
import 'library_index.dart';
import 'metadata_ui.dart';
import 'model.dart';
import 'player_ui.dart';
import 'playlists.dart';
import 'queue.dart';
import 'radio.dart';
import 'repository.dart';
import 'shell_desktop.dart';
import 'shell_mobile.dart';
import 'downloads_ui.dart';
import 'sources_ui.dart';
import 'transfer.dart';
import 'ui_prefs.dart';
import 'widgets.dart';
import 'l10n.dart';
export 'design.dart' show accent, background, panel, secondaryText;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Android plays the Winyl intro in Flutter; PC shows it in index.html.
  introOnStart = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  runApp(const MytifyApp());
}

ThemeData mytifyTheme() => ThemeData(
  brightness: palette.brightness,
  useMaterial3: true,
  scaffoldBackgroundColor: background,
  canvasColor: background,
  dividerColor: softBorder,
  splashFactory: InkRipple.splashFactory,
  colorScheme: ColorScheme.fromSeed(
    seedColor: accent,
    brightness: palette.brightness,
  ).copyWith(
    primary: accent,
    onPrimary: onAccent,
    secondary: accent,
    surface: panel,
    onSurface: primaryText,
    onSurfaceVariant: secondaryText,
    outline: softBorder,
    outlineVariant: softBorder,
    surfaceContainerHighest: elevated,
    surfaceContainerHigh: elevated,
    surfaceContainer: panel,
  ),
  fontFamily: 'Arial',
  textTheme: TextTheme(
    bodyMedium: TextStyle(color: primaryText, fontSize: 14),
    bodySmall: TextStyle(color: secondaryText, fontSize: 12),
  ),
  iconTheme: IconThemeData(color: primaryText, size: 22),
  tooltipTheme: TooltipThemeData(
    waitDuration: const Duration(milliseconds: 500),
    decoration: BoxDecoration(
      color: elevated,
      borderRadius: BorderRadius.circular(6),
    ),
    textStyle: TextStyle(color: primaryText, fontSize: 12),
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: background,
    height: 64,
    indicatorColor: Colors.transparent,
    labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    labelTextStyle: WidgetStateProperty.resolveWith(
      (states) => TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: states.contains(WidgetState.selected) ? primaryText : secondaryText,
      ),
    ),
    iconTheme: WidgetStateProperty.resolveWith(
      (states) => IconThemeData(
        size: 24,
        color: states.contains(WidgetState.selected) ? primaryText : secondaryText,
      ),
    ),
  ),
  sliderTheme: SliderThemeData(
    trackHeight: 3,
    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
    overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
    inactiveTrackColor: softBorder,
    activeTrackColor: accent,
    thumbColor: primaryText,
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      foregroundColor: onAccent,
      backgroundColor: accent,
      textStyle: const TextStyle(fontFamily: 'Arial', fontWeight: FontWeight.w700),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.control)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: primaryText,
      textStyle: const TextStyle(fontFamily: 'Arial', fontWeight: FontWeight.w600),
      side: BorderSide(color: softBorder),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.control)),
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      foregroundColor: primaryText,
      textStyle: const TextStyle(fontFamily: 'Arial', fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.control)),
    ),
  ),
  bottomSheetTheme: BottomSheetThemeData(
    backgroundColor: panel,
    surfaceTintColor: Colors.transparent,
    dragHandleColor: primaryText.withValues(alpha: .33),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
  ),
  dialogTheme: DialogThemeData(
    backgroundColor: panel,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.panel)),
  ),
  popupMenuTheme: PopupMenuThemeData(
    color: elevated,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  ),
  appBarTheme: AppBarTheme(
    backgroundColor: background,
    surfaceTintColor: Colors.transparent,
  ),
  snackBarTheme: SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: elevated,
    contentTextStyle: TextStyle(color: primaryText),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: elevated,
    isDense: true,
    hintStyle: TextStyle(color: secondaryText),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(Rad.control),
      borderSide: BorderSide.none,
    ),
  ),
  scrollbarTheme: ScrollbarThemeData(
    thumbColor: WidgetStateProperty.all(primaryText.withValues(alpha: .25)),
    thickness: WidgetStateProperty.all(6),
    radius: const Radius.circular(3),
  ),
  listTileTheme: ListTileThemeData(
    iconColor: secondaryText,
    textColor: primaryText,
  ),
);

/// Scheme changes rebuild MaterialApp's theme here and every widget below.
final appearance = ValueNotifier(0);

class MytifyApp extends StatelessWidget {
  final LibraryRepository? repository;
  const MytifyApp({super.key, this.repository});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: appearance,
    builder: (context, _, home) => MaterialApp(
      title: 'Mytify',
      debugShowCheckedModeBanner: false,
      theme: mytifyTheme(),
      home: home,
    ),
    child: LibraryScreen(repository: repository),
  );
}

/// Applies a colour scheme now and on the next start.
void applyPalette(Palette p) {
  palette = p;
  appearance.value++;
  WidgetsBinding.instance.addPostFrameCallback((_) => rebuildEverything());
}

@immutable
class Nav {
  final String page;
  final String? arg;
  const Nav(this.page, [this.arg]);
  @override
  bool operator ==(Object other) =>
      other is Nav && other.page == page && other.arg == arg;
  @override
  int get hashCode => Object.hash(page, arg);
  String get key => '$page:${arg ?? ''}';
  static const home = Nav('home'), search = Nav('search');
  bool get isRoot => page == 'home' || page == 'search' || page == 'library' || page == 'radio';
}

class LibraryScreen extends StatefulWidget {
  final LibraryRepository? repository;
  const LibraryScreen({super.key, this.repository});
  @override
  State<LibraryScreen> createState() => LibraryScreenState();
}

/// Single source of truth for library, playback, queue, likes and navigation.
class LibraryScreenState extends State<LibraryScreen> {
  late final repository = widget.repository ?? createRepository();
  late final player = NativeAudioPlayer(repository);
  final queue = PlaybackQueue();
  final prefs = UiPrefs();
  final searchText = TextEditingController();
  final searchFocus = FocusNode(debugLabel: 'search');
  final pageStorage = PageStorageBucket();
  final List<StreamSubscription<dynamic>> subscriptions = [];
  LibraryIndex index = LibraryIndex.empty;
  List<Track> get tracks => index.tracks;
  List<MusicPlaylist> playlists = [];
  List<LibrarySource> librarySources = [];
  /// Network protocols this build really supports; the UI offers nothing else.
  List<String> networkProtocols = const [];
  /// Offline copies of network tracks (status, menus, confirmation).
  late final DownloadState downloads = DownloadState(this);

  /// One state for the player's device popover and Settings → Audio.
  late final OutputDevices outputs = OutputDevices(this);
  IngestState? _ingest;

  /// Audio CD and vinyl import. Kept for the whole session so leaving the view
  /// keeps the form and a running job.
  IngestState get ingest => _ingest ??= IngestState(
    repository: repository as IngestRepository,
    library: repository,
    beforeCapture: () async {
      if (player.state.playing) await player.command({'action': 'pause'});
    },
    onLibraryChanged: loadLibrary,
  );
  Timer? _libraryRefresh;
  bool cancelling = false;
  String? startupError;
  String? _openedTrackId;
  bool loading = true, importing = false, playing = false;

  /// PC: logos of stations come through the core; null on Android (loaded directly).
  String? radioLogoBase;

  // Waiting for sound: a start command still in flight (a station's address being
  // opened, a NAS file being reached) or the engine still filling its buffer.
  int _starting = 0;
  bool _buffering = false;
  bool get connecting => _starting > 0 || _buffering;

  /// Runs a command that should end in sound; the play buttons spin meanwhile.
  Future<void> starting(Future<void> Function() op) async {
    if (mounted) setState(() => _starting++);
    try {
      await op();
    } finally {
      if (mounted) setState(() => _starting--);
    }
  }
  /// Start animation runs once per app start, never on resume or navigation.
  bool showIntro = introOnStart;
  ImportProgress progress = const ImportProgress(0, 0, '');
  ImportReport? lastImport;
  int playGeneration = 0;
  double volume = 80;
  bool adjustingVolume = false, volumeAvailable = true;
  double? _volumeBeforeMute;
  String outputDevice = 'auto';
  bool _audioVolumeInitialized = false;

  // Navigation: browser-like history on desktop, one stack per tab on mobile.
  bool desktopMode = true;
  Nav _route = Nav.home;
  final List<Nav> _back = [], _forward = [];
  int tab = 0;
  final List<List<Nav>> _stacks = [
    [Nav.home],
    [Nav.search],
    [const Nav('library', 'all')],
    [const Nav('radio')],
  ];
  bool homePlayerVisible = true;
  /// Bumped on every navigation; keys page transitions so rapid toggles never collide.
  int navSerial = 0;

  // Desktop selection in track tables.
  final Set<String> selected = {};
  String? selectionAnchor;

  // Listening history accounting.
  String? _histId;
  int _histMs = 0;
  bool _histCounted = false;
  DateTime _histStamp = DateTime.now();

  Nav get route => desktopMode ? _route : _stacks[tab].last;
  bool get canGoBack => desktopMode ? _back.isNotEmpty : _stacks[tab].length > 1;
  bool get canGoForward => desktopMode && _forward.isNotEmpty;
  Track? get current => queue.current;
  String get query => searchText.text;

  @override
  void initState() {
    super.initState();
    if (repository is LibraryChangesRepository) {
      subscriptions.add(
        (repository as LibraryChangesRepository).changes.listen((_) {
          _libraryRefresh?.cancel();
          _libraryRefresh = Timer(const Duration(milliseconds: 150), () {
            if (mounted) unawaited(loadLibrary());
          });
        }),
      );
    }
    subscriptions.add(
      player.stream.playing.listen((v) {
        if (mounted) setState(() => playing = v);
      }),
    );
    subscriptions.add(
      player.stream.error.listen((error) {
        if (!mounted) return;
        message(
          isRadio(player.state.currentId)
              ? tr('Radio: {0}', [trMessage(error)])
              : tr('Nie udało się odtworzyć pliku: {0}', [error]),
        );
      }),
    );
    subscriptions.add(player.stream.snapshot.listen(syncNativeAudio));
    if (repository is RadioRepository) {
      unawaited(
        (repository as RadioRepository).radioLogoBase().then((v) {
          if (mounted && v != null) setState(() => radioLogoBase = v);
        }).catchError((Object _) {}),
      );
    }
    unawaited(prefs.load().then((_) {
      final p = paletteById(prefs.get<String>('palette', 'mytify'));
      final l = prefs.get<String>('lang', 'pl');
      if (l != lang) {
        lang = l;
        unawaited(repository.setLanguage(l).catchError((Object _) {}));
      }
      if (p != palette || l != 'pl') applyPalette(p);
      if (mounted) setState(() {});
    }));
    unawaited(player.start());
    // NAS shares are reached while the intro plays, so a first tap on a cloud track works.
    unawaited(loadLibrary().then((_) => connectSources(quietly: true)));
    // PC app: notice an inserted Audio CD and offer to import it.
    if (canDigitize && canFloat) ingest.watchDiscs();
    if (canFloat) {
      _screensaver = Timer.periodic(const Duration(seconds: 20), (_) => unawaited(_checkScreensaver()));
    }
    unawaited(
      repository.networkProtocols().then((v) {
        if (mounted) setState(() => networkProtocols = v);
        if (v.isNotEmpty) unawaited(downloads.refresh());
      }).catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    playGeneration++;
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(player.dispose());
    _libraryRefresh?.cancel();
    _screensaver?.cancel();
    unawaited(repository.dispose());
    prefs.dispose();
    _ingest?.dispose();
    outputs.dispose();
    searchText.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- playback

  void syncNativeAudio(AudioSnapshot state) {
    if (!mounted) return;
    if (state.buffering != _buffering) setState(() => _buffering = state.buffering);
    _account(state);
    final onAir = state.radio;
    if (onAir != null) {
      final title = (onAir['title'] as String?)?.trim();
      if (title != null && title.isNotEmpty && state.playing) recordHeard(title, onAir['name'] as String? ?? '');
    }
    final items = onAir != null
        ? [radioTrack(onAir, radioLogoUri, favorite: isFavoriteStation(onAir['id'] as String? ?? ''))]
        : state.queueIds
        .map((id) => index.byId[id])
        .whereType<Track>()
        .toList();
    final current = items.indexWhere((t) => t.id == state.currentId);
    final changed =
        !listEquals(
          queue.items.map((t) => t.id).toList(),
          items.map((t) => t.id).toList(),
        ) ||
        queue.current?.id != state.currentId ||
        (onAir != null && (queue.current?.title != items.first.title || queue.current?.cover != items.first.cover || queue.current?.liked != items.first.liked)) ||
        queue.shuffled != state.shuffled ||
        queue.repeat != state.repeat ||
        !_audioVolumeInitialized ||
        outputDevice != state.selectedDevice ||
        volumeAvailable != state.volumeAvailable ||
        (!adjustingVolume && (volume - state.volume).abs() > .5);
    if (!changed) return;
    setState(() {
      if (items.isEmpty) {
        queue.replace([], '');
      } else {
        queue.replace(
          items,
          current >= 0 ? items[current].id : items.first.id,
        );
      }
      queue.shuffled = state.shuffled;
      queue.repeat = state.repeat;
      _openedTrackId = state.currentId;
      outputDevice = state.selectedDevice;
      volumeAvailable = state.volumeAvailable;
      if (!_audioVolumeInitialized || !adjustingVolume) {
        volume = state.volume;
        _audioVolumeInitialized = true;
      }
    });
  }

  void _account(AudioSnapshot s) {
    final now = DateTime.now();
    // Stations are not tracks: they do not enter the listening history.
    final id = isRadio(s.currentId) ? null : s.currentId;
    if (id != _histId) {
      _histId = id;
      _histMs = 0;
      _histCounted = false;
      if (id != null && s.playing) {
        prefs.history.started(id);
        prefs.saveHistory();
      }
    } else if (s.playing) {
      final delta = now.difference(_histStamp).inMilliseconds;
      if (delta > 0 && delta < 5000) _histMs += delta;
      final total = s.duration.inMilliseconds;
      final needed = math.min(30000, math.max(5000, total ~/ 2));
      if (!_histCounted && id != null && _histMs >= needed) {
        _histCounted = true;
        prefs.history.counted(id);
        unawaited(repository.played(id).catchError((Object _) {}));
        if (prefs.history.recent.firstOrNull != id) prefs.history.started(id);
        prefs.saveHistory();
      }
    }
    _histStamp = now;
  }

  Future<void> audioOperation(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (e) {
      message(tr('Odtwarzanie: {0}', [e]));
    }
  }

  Future<void> seek(Duration position) async {
    final track = queue.current;
    // Right after launch the queue is restored but the engine has nothing
    // loaded yet: start the track first, then jump to the chosen point.
    if (track != null &&
        (player.state.currentId == null || _openedTrackId != track.id)) {
      await playTracks(queue.items, start: track);
      try {
        await player.stream.snapshot
            .firstWhere((s) => s.currentId == track.id && s.duration > Duration.zero)
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    await audioOperation(() => player.seek(position));
  }

  Future<void> playTracks(
    List<Track> list, {
    Track? start,
    bool shuffle = false,
  }) async {
    final ids = {for (final t in list) t.id};
    final fresh = await _reachable(start != null && !ids.contains(start.id) ? [start, ...list] : list);
    list = [for (final t in fresh) if (ids.contains(t.id)) t];
    if (start != null) start = index.byId[start.id] ?? start;
    final playable = <Track>[];
    final seen = <String>{};
    for (final t in list) {
      if (t.available && seen.add(t.id)) playable.add(t);
    }
    if (playable.isEmpty) {
      message(tr('Te pliki są teraz niedostępne. Podłącz źródło muzyki.'));
      return;
    }
    if (start != null && !start.available) {
      message(tr('Ten plik jest niedostępny. Podłącz źródło lub wskaż folder ponownie.'));
      return;
    }
    final first = shuffle
        ? playable[math.Random().nextInt(playable.length)]
        : (start ?? playable.first);
    final generation = ++playGeneration;
    try {
      await starting(() => _openTracks(playable, first, shuffle));
      if (mounted && generation == playGeneration) _openedTrackId = first.id;
    } catch (e) {
      if (mounted && generation == playGeneration) {
        message(tr('Nie można uruchomić odtwarzania: {0}', [trMessage(readableError(e))]));
      }
    }
  }

  Future<void> _openTracks(List<Track> playable, Track first, bool shuffle) async {
    {
      final ids = playable.map((t) => t.id).toList();
      if (listEquals(ids, player.state.queueIds) && !shuffle) {
        await player.jump(first.id);
        if (!player.state.playing) await player.play();
      } else {
        await player.openQueue(ids, ids.indexOf(first.id));
      }
      if (shuffle) await player.shuffle(true);
    }
  }

  Future<void> playAlbum(AlbumGroup album, {bool shuffle = false}) =>
      playTracks(album.tracks, shuffle: shuffle);

  Future<void> togglePlay() async {
    final track = queue.current;
    if (track == null) {
      final recent = prefs.history.recentAlbums(index, limit: 1).firstOrNull;
      if (recent != null) return playAlbum(recent);
      return playTracks(tracks);
    }
    // Tapping the spinning button gives up waiting.
    if (connecting) return audioOperation(() => player.command({'action': 'pause'}));
    if (isRadio(track.id)) return player.state.playing ? audioOperation(player.playOrPause) : starting(() => audioOperation(player.playOrPause));
    if (!track.available && track.remote && !track.offline) {
      return playTracks(queue.items, start: track);
    }
    if (!track.available) {
      message(tr('Źródło jest niedostępne. Podłącz je i wykonaj skan.'));
      return;
    }
    if (_openedTrackId != track.id || player.state.currentId == null) {
      return playTracks(queue.items, start: track);
    }
    if (player.state.playing) return audioOperation(player.playOrPause);
    await starting(() => audioOperation(player.playOrPause));
  }

  Future<void> nextTrack() => starting(() => audioOperation(player.next));
  Future<void> previousTrack() => starting(() => audioOperation(player.previous));
  Future<void> toggleShuffle() =>
      audioOperation(() => player.shuffle(!queue.shuffled));
  Future<void> toggleRepeat() =>
      audioOperation(() => player.repeat(!queue.repeat));

  void setVolumeLive(double v) {
    setState(() {
      volume = v;
      adjustingVolume = true;
    });
    unawaited(player.setVolume(v));
  }

  Future<void> commitVolume(double v) async {
    await audioOperation(() => player.commitVolume(v));
    if (mounted) setState(() => adjustingVolume = false);
  }

  Future<void> toggleMute() async {
    if (!volumeAvailable) return;
    if (volume > 0) {
      _volumeBeforeMute = volume;
      setState(() => volume = 0);
      await commitVolume(0);
    } else {
      final v = _volumeBeforeMute ?? 60;
      setState(() => volume = v);
      await commitVolume(v);
    }
  }

  Future<void> nudgeVolume(double delta) async {
    if (!volumeAvailable) return;
    final v = (volume + delta).clamp(0.0, 100.0);
    setState(() => volume = v);
    await commitVolume(v);
  }

  Future<void> _rearrange(List<String> ids) async {
    final currentId = queue.current?.id;
    if (currentId == null || !ids.contains(currentId)) return;
    await audioOperation(() => player.rearrange(ids, currentId));
  }

  Future<void> playNext(List<Track> list) async {
    final add = list.where((t) => t.available).map((t) => t.id).toList();
    if (add.isEmpty) return;
    if (queue.current == null) return playTracks(list);
    final ids = queue.items.map((t) => t.id).where((id) => !add.contains(id) || id == queue.current!.id).toList();
    final at = ids.indexOf(queue.current!.id) + 1;
    ids.insertAll(at, add.where((id) => id != queue.current!.id));
    await _rearrange(ids);
    message(list.length == 1 ? tr('Zagra jako następny') : tr('Zagrają jako następne'));
  }

  /// Tracks dropped onto the queue: inserted before [at] (or at the end), never before
  /// the current track, without duplicates.
  Future<void> insertInQueue(List<Track> list, int? at) async {
    final add = list.where((t) => t.available).map((t) => t.id).toList();
    if (add.isEmpty) return;
    if (queue.current == null) return playTracks(list);
    final current = queue.current!.id;
    final ids = queue.items.map((t) => t.id).toList();
    var target = (at ?? ids.length).clamp(ids.indexOf(current) + 1, ids.length);
    for (final id in add) {
      final i = ids.indexOf(id);
      if (id == current) continue;
      if (i >= 0) {
        ids.removeAt(i);
        if (i < target) target--;
      }
    }
    ids.insertAll(target, add.where((id) => id != current));
    await _rearrange(ids);
    message(list.length == 1 ? tr('Dodano do kolejki') : tr('Dodano do kolejki: {0}', [trackCount(add.length)]));
  }

  Future<void> enqueue(List<Track> list) async {
    final add = list.where((t) => t.available).map((t) => t.id).toList();
    if (add.isEmpty) return;
    if (queue.current == null) return playTracks(list);
    final ids = queue.items.map((t) => t.id).toList();
    ids.addAll(add.where((id) => !ids.contains(id)));
    await _rearrange(ids);
    message(tr('Dodano do kolejki'));
  }

  Future<void> removeFromQueue(String id) async {
    if (id == queue.current?.id) return;
    await _rearrange(queue.items.map((t) => t.id).where((i) => i != id).toList());
  }

  Future<void> clearUpcoming() async {
    final c = queue.current;
    if (c == null) return;
    final ids = queue.items.map((t) => t.id).toList();
    await _rearrange(ids.take(ids.indexOf(c.id) + 1).toList());
  }

  Future<void> moveInQueue(int from, int to) async {
    final ids = queue.items.map((t) => t.id).toList();
    if (from < 0 || from >= ids.length) return;
    final id = ids.removeAt(from);
    ids.insert(to.clamp(0, ids.length), id);
    await _rearrange(ids);
  }

  Future<void> jumpTo(String id) => starting(() => audioOperation(() => player.jump(id)));

  // ---------------------------------------------------------------- library

  Future<void> loadLibrary() async {
    try {
      final loaded = await repository.load();
      final sources = await repository.sources();
      if (repository is PlaylistRepository) {
        try {
          playlists = await (repository as PlaylistRepository).playlists();
        } catch (_) {
          /* optional section; library stays available */
        }
      }
      final previous = queue.current?.id;
      queue.refresh(loaded);
      if (previous != null &&
          (queue.current?.id != previous || queue.current?.available == false)) {
        playGeneration++;
        _openedTrackId = null;
        await player.stop();
      }
      if (mounted) {
        setState(() {
          index = LibraryIndex.build(loaded);
          librarySources = sources;
          loading = false;
          startupError = null;
          selected.removeWhere((id) => !index.byId.containsKey(id));
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          startupError = tr('Nie można otworzyć biblioteki: {0}', [e]);
          loading = false;
        });
      }
    }
  }

  void message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(trMessage(text)), duration: const Duration(seconds: 4)),
      );
  }

  Future<void> toggleLike(Track track) async {
    if (isRadio(track.id)) {
      final s = stationFor(track.id);
      if (s != null) await toggleFavoriteStation(s);
      return;
    }
    final next = !track.liked;
    setState(() {
      index = LibraryIndex.build([
        for (final t in tracks) t.id == track.id ? t.withLiked(next) : t,
      ]);
      queue.refresh(index.tracks);
    });
    try {
      await repository.setLiked(track.id, next);
    } catch (e) {
      message(tr('Nie udało się zapisać polubienia: {0}', [e]));
      await loadLibrary();
    }
  }

  Future<void> likeCurrent() async {
    final c = queue.current;
    if (c != null) await toggleLike(c);
  }

  Future<void> removeTracks(List<Track> list) async {
    if (list.isEmpty) return;
    final ok = await confirm(
      context,
      title: list.length == 1 ? tr('Usunąć z biblioteki?') : tr('Usunąć {0}?', [trackCount(list.length)]),
      message:
          tr('Wpisy znikną z Mytify. Pliki na dysku pozostaną bez zmian i możesz dodać je ponownie.'),
      action: tr('Usuń z biblioteki'),
    );
    if (!ok || !mounted) return;
    try {
      for (final track in list) {
        if (queue.current?.id == track.id) {
          playGeneration++;
          _openedTrackId = null;
          await player.stop();
        }
        await repository.remove(track.id);
        queue.remove(track.id);
      }
      selected.clear();
      await loadLibrary();
    } catch (e) {
      message(tr('Nie udało się usunąć wpisu: {0}', [e]));
    }
  }

  /// Opens the metadata editor; true when something was saved.
  Future<bool> metadataFor(
    List<Track> list, {
    bool online = false,
    bool album = false,
  }) async {
    if (importing || list.isEmpty) return false;
    final changed = await editMusicMetadata(
      context,
      repository,
      list,
      online: online,
      album: album,
    );
    if (changed != true || !mounted) return false;
    final before = route;
    await loadLibrary();
    if (!mounted) return true;
    if (before.page == 'album' && !index.albumByKey.containsKey(before.arg)) {
      final updated = index.byId[list.first.id];
      if (updated != null) replaceRoute(Nav('album', updated.albumKey));
    }
    message(tr('Zapisano zmiany.'));
    return true;
  }

  // ---------------------------------------------------------------- playlists

  PlaylistRepository? get playlistRepo =>
      repository is PlaylistRepository ? repository as PlaylistRepository : null;

  List<MusicPlaylist> get orderedPlaylists {
    final pins = prefs.list('pins');
    final list = List.of(playlists);
    list.sort((a, b) {
      final pa = pins.contains('playlist:${a.id}') ? 0 : 1;
      final pb = pins.contains('playlist:${b.id}') ? 0 : 1;
      if (pa != pb) return pa.compareTo(pb);
      return searchKey(a.name).compareTo(searchKey(b.name));
    });
    return list;
  }

  MusicPlaylist? playlistById(String? id) =>
      playlists.where((p) => p.id == id).firstOrNull;

  Future<void> _savePlaylist(String? id, String name, List<String> ids) async {
    final repo = playlistRepo;
    if (repo == null) return;
    try {
      await repo.savePlaylist(id, name, ids);
      playlists = await repo.playlists();
      if (mounted) setState(() {});
    } catch (e) {
      message(tr('Playlista: {0}', [e]));
    }
  }

  Future<void> createPlaylist([List<Track> initial = const []]) async {
    final name = await askName(context, title: tr('Nowa playlista'), action: tr('Utwórz'));
    if (name == null) return;
    final before = playlists.map((p) => p.id).toSet();
    final ids = <String>[];
    for (final t in initial) {
      if (!ids.contains(t.id)) ids.add(t.id);
    }
    await _savePlaylist(null, name, ids);
    final created = playlists.where((p) => !before.contains(p.id)).firstOrNull;
    if (created != null && initial.isEmpty) go(Nav('playlist', created.id));
    if (created != null && initial.isNotEmpty) message(tr('Utworzono „{0}”', [name]));
  }

  Future<void> renamePlaylist(MusicPlaylist p) async {
    final name = await askName(context, title: tr('Zmień nazwę'), initial: p.name);
    if (name != null && name != p.name) await _savePlaylist(p.id, name, p.ids);
  }

  Future<void> deletePlaylist(MusicPlaylist p) async {
    final ok = await confirm(
      context,
      title: tr('Usunąć playlistę?'),
      message: tr('„{0}” zniknie z Mytify. Utwory zostaną w bibliotece.', [p.name]),
      action: tr('Usuń playlistę'),
    );
    if (!ok) return;
    try {
      await playlistRepo?.deletePlaylist(p.id);
      playlists = await playlistRepo?.playlists() ?? playlists;
      if (route == Nav('playlist', p.id)) back();
      if (mounted) setState(() {});
    } catch (e) {
      message(tr('Playlista: {0}', [e]));
    }
  }

  Future<void> addToPlaylist(MusicPlaylist p, List<Track> list) async {
    final ids = List.of(p.ids);
    var added = 0;
    for (final t in list) {
      if (!ids.contains(t.id)) {
        ids.add(t.id);
        added++;
      }
    }
    if (added == 0) {
      message(tr('Te utwory już są w „{0}”', [p.name]));
      return;
    }
    await _savePlaylist(p.id, p.name, ids);
    message(tr('Dodano do „{0}”', [p.name]));
  }

  Future<void> removeFromPlaylist(MusicPlaylist p, List<Track> list) async {
    final remove = list.map((t) => t.id).toSet();
    await _savePlaylist(p.id, p.name, p.ids.where((id) => !remove.contains(id)).toList());
  }

  Future<void> movePlaylistItem(MusicPlaylist p, int from, int to) async {
    final ids = List.of(p.ids);
    final id = ids.removeAt(from);
    ids.insert(to.clamp(0, ids.length), id);
    final i = playlists.indexWhere((x) => x.id == p.id);
    if (i >= 0) setState(() => playlists[i] = MusicPlaylist(p.id, p.name, ids));
    await _savePlaylist(p.id, p.name, ids);
  }

  void togglePin(String id) => setState(() => prefs.togglePin(id));

  // ---------------------------------------------------------------- menus

  List<MenuEntry> _playlistTargets(List<Track> list) => [
    if (playlistRepo != null)
      MenuEntry(
        tr('Nowa playlista'),
        icon: Icons.add_rounded,
        onTap: () => unawaited(createPlaylist(list)),
      ),
    for (final p in orderedPlaylists)
      MenuEntry(p.name, icon: Icons.queue_music_rounded, onTap: () => unawaited(addToPlaylist(p, list))),
  ];

  Future<void> trackMenu(
    Track t, {
    Offset? at,
    MusicPlaylist? playlist,
    List<Track>? within,
  }) {
    if (isRadio(t.id)) return radioMenu(t);
    final many = selected.length > 1 && selected.contains(t.id) && desktopMode;
    final list = many
        ? selected.map((id) => index.byId[id]).whereType<Track>().toList()
        : [t];
    final album = index.albumByKey[t.albumKey];
    return showActions(context, at: at, title: many ? trackCount(list.length) : t.title, [
      MenuEntry(
        tr('Odtwórz'),
        icon: Icons.play_arrow_rounded,
        onTap: () => unawaited(
          many ? playTracks(list) : playTracks(within ?? [t], start: t),
        ),
      ),
      MenuEntry(tr('Odtwórz jako następny'), icon: Icons.playlist_play_rounded, onTap: () => unawaited(playNext(list))),
      MenuEntry(tr('Dodaj do kolejki'), icon: Icons.queue_rounded, onTap: () => unawaited(enqueue(list))),
      if (playlistRepo != null)
        MenuEntry(tr('Dodaj do playlisty'), icon: Icons.playlist_add_rounded, children: _playlistTargets(list)),
      if (!many)
        MenuEntry(
          t.liked ? tr('Usuń z polubionych') : tr('Polub'),
          icon: t.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          shortcut: desktopMode && t.id == queue.current?.id ? tr('Ctrl+L') : null,
          onTap: () => unawaited(toggleLike(t)),
        ),
      ...downloads.entries(list),
      MenuEntry.divider,
      if (!many && album != null && album.tracks.length > 1)
        MenuEntry(tr('Przejdź do albumu'), icon: Icons.album_outlined, onTap: () => go(Nav('album', album.key))),
      if (!many)
        MenuEntry(
          tr('Przejdź do artysty'),
          icon: Icons.person_outline_rounded,
          onTap: () => go(Nav('artist', LibraryIndex.artistKeyOf(t.displayArtist))),
        ),
      if (!many)
        MenuEntry(tr('Informacje o utworze'), icon: Icons.info_outline_rounded, onTap: () => showTrackInfo(t)),
      MenuEntry(tr('Edytuj informacje'), icon: Icons.edit_outlined, onTap: importing ? null : () => unawaited(metadataFor(list))),
      MenuEntry.divider,
      if (playlist != null)
        MenuEntry(tr('Usuń z tej playlisty'), icon: Icons.remove_circle_outline_rounded, onTap: () => unawaited(removeFromPlaylist(playlist, list))),
      MenuEntry(tr('Usuń z biblioteki'), icon: Icons.delete_outline_rounded, destructive: true, onTap: () => unawaited(removeTracks(list))),
    ]);
  }

  Future<void> albumMenu(AlbumGroup a, {Offset? at}) {
    final pinId = 'album:${a.key}';
    return showActions(context, at: at, title: a.title, [
      MenuEntry(tr('Odtwórz'), icon: Icons.play_arrow_rounded, onTap: () => unawaited(playAlbum(a))),
      MenuEntry(tr('Odtwórz losowo'), icon: Icons.shuffle_rounded, onTap: () => unawaited(playAlbum(a, shuffle: true))),
      MenuEntry(tr('Odtwórz jako następny'), icon: Icons.playlist_play_rounded, onTap: () => unawaited(playNext(a.tracks))),
      MenuEntry(tr('Dodaj do kolejki'), icon: Icons.queue_rounded, onTap: () => unawaited(enqueue(a.tracks))),
      if (playlistRepo != null)
        MenuEntry(tr('Dodaj do playlisty'), icon: Icons.playlist_add_rounded, children: _playlistTargets(a.tracks)),
      MenuEntry(
        prefs.pinned(pinId) ? tr('Odepnij') : tr('Przypnij'),
        icon: Icons.push_pin_outlined,
        onTap: () => togglePin(pinId),
      ),
      ...downloads.entries(a.tracks, title: tr('Pobrać album offline?')),
      MenuEntry.divider,
      MenuEntry(tr('Przejdź do artysty'), icon: Icons.person_outline_rounded, onTap: () => go(Nav('artist', a.artistKey))),
      MenuEntry(tr('Znajdź dane i okładkę'), icon: Icons.auto_fix_high_outlined, onTap: importing ? null : () => unawaited(metadataFor(a.tracks, online: true))),
      MenuEntry(tr('Edytuj album'), icon: Icons.edit_outlined, onTap: importing ? null : () => unawaited(metadataFor(a.tracks, album: true))),
    ]);
  }

  Future<void> playlistMenu(MusicPlaylist p, {Offset? at}) {
    final list = index.playlistTracks(p);
    final pinId = 'playlist:${p.id}';
    return showActions(context, at: at, title: p.name, [
      MenuEntry(tr('Odtwórz'), icon: Icons.play_arrow_rounded, onTap: list.isEmpty ? null : () => unawaited(playTracks(list))),
      MenuEntry(tr('Odtwórz losowo'), icon: Icons.shuffle_rounded, onTap: list.isEmpty ? null : () => unawaited(playTracks(list, shuffle: true))),
      MenuEntry(tr('Odtwórz jako następny'), icon: Icons.playlist_play_rounded, onTap: list.isEmpty ? null : () => unawaited(playNext(list))),
      MenuEntry(tr('Dodaj do kolejki'), icon: Icons.queue_rounded, onTap: list.isEmpty ? null : () => unawaited(enqueue(list))),
      MenuEntry(prefs.pinned(pinId) ? tr('Odepnij') : tr('Przypnij'), icon: Icons.push_pin_outlined, onTap: () => togglePin(pinId)),
      MenuEntry(tr('Zmień nazwę'), icon: Icons.edit_outlined, onTap: () => unawaited(renamePlaylist(p))),
      ...downloads.entries(list, title: tr('Pobrać playlistę offline?')),
      if (list.any((t) => t.remote))
        MenuEntry(
          downloads.kept.contains(p.id) ? tr('Nie utrzymuj offline') : tr('Utrzymuj offline'),
          icon: Icons.offline_pin_outlined,
          onTap: () => unawaited(downloads.keep(p, !downloads.kept.contains(p.id))),
        ),
      MenuEntry.divider,
      MenuEntry(tr('Usuń playlistę'), icon: Icons.delete_outline_rounded, destructive: true, onTap: () => unawaited(deletePlaylist(p))),
    ]);
  }

  void showTrackInfo(Track t) => isRadio(t.id)
      ? unawaited(radioMenu(t))
      : showDialog<void>(
    context: context,
    builder: (_) => TrackInfoDialog(track: t, snapshot: player.state),
  );

  // ---------------------------------------------------------------- selection

  /// Tracks currently listed in the main view (Ctrl+A, Delete, keyboard play).
  List<Track> visibleList = const [];
  MusicPlaylist? visiblePlaylist;

  void refresh([VoidCallback? change]) => setState(change ?? () {});

  void selectTrack(Track t, List<Track> list, {bool toggle = false, bool range = false}) {
    setState(() {
      if (range && selectionAnchor != null) {
        final a = list.indexWhere((x) => x.id == selectionAnchor);
        final b = list.indexWhere((x) => x.id == t.id);
        if (a >= 0 && b >= 0) {
          if (!toggle) selected.clear();
          for (var i = math.min(a, b); i <= math.max(a, b); i++) {
            selected.add(list[i].id);
          }
          return;
        }
      }
      if (toggle) {
        selected.contains(t.id) ? selected.remove(t.id) : selected.add(t.id);
      } else {
        selected
          ..clear()
          ..add(t.id);
      }
      selectionAnchor = t.id;
    });
  }

  void selectAll() => setState(() => selected
    ..clear()
    ..addAll(visibleList.map((t) => t.id)));

  List<Track> get selectedTracks =>
      visibleList.where((t) => selected.contains(t.id)).toList();

  Future<void> deleteSelection() async {
    final list = selectedTracks;
    if (list.isEmpty) return;
    final p = visiblePlaylist;
    if (p != null) {
      await removeFromPlaylist(p, list);
      setState(selected.clear);
    } else {
      await removeTracks(list);
    }
  }

  // ---------------------------------------------------------------- navigation

  void go(Nav next) {
    if (next == route) return;
    setState(() {
      navSerial++;
      selected.clear();
      selectionAnchor = null;
      if (desktopMode) {
        _back.add(_route);
        if (_back.length > 100) _back.removeAt(0);
        _forward.clear();
        _route = next;
      } else if (next.isRoot) {
        final t = switch (next.page) { 'home' => 0, 'search' => 1, 'radio' => 3, _ => 2 };
        tab = t;
        if (next.page == 'library') {
          _stacks[2] = [next];
        }
      } else {
        _stacks[tab].add(next);
      }
    });
  }

  void replaceRoute(Nav next) => setState(() {
      navSerial++;
    if (desktopMode) {
      _route = next;
    } else {
      _stacks[tab][_stacks[tab].length - 1] = next;
    }
  });

  void back() {
    if (!canGoBack) return;
    setState(() {
      navSerial++;
      selected.clear();
      if (desktopMode) {
        _forward.add(_route);
        _route = _back.removeLast();
      } else {
        _stacks[tab].removeLast();
      }
    });
  }

  void forward() {
    if (!canGoForward) return;
    setState(() {
      navSerial++;
      selected.clear();
      _back.add(_route);
      _route = _forward.removeLast();
    });
  }

  void selectTab(int t) {
    setState(() {
      navSerial++;
      if (tab == t && _stacks[t].length > 1) {
        _stacks[t] = [_stacks[t].first];
      }
      tab = t;
      if (t == 0) homePlayerVisible = true;
    });
  }

  void focusSearch() {
    if (desktopMode) {
      searchFocus.requestFocus();
      searchText.selection = TextSelection(baseOffset: 0, extentOffset: searchText.text.length);
    } else {
      selectTab(1);
      searchFocus.requestFocus();
    }
  }

  void onSearchChanged(String value) {
    if (desktopMode && value.trim().isNotEmpty && route.page != 'search') {
      go(Nav.search);
    } else {
      setState(() {});
    }
  }

  // ---------------------------------------------------------------- import & sources

  Future<bool>? _connecting;

  /// Reaches the network sources now (with a short limit) and reloads the library.
  /// True when every network source answered.
  Future<bool> connectSources({bool quietly = false, Duration limit = const Duration(seconds: 8)}) {
    final repo = repository;
    if (repo is! SourceProbe || !librarySources.any((s) => s.network)) return Future.value(true);
    return _connecting ??= () async {
      var ok = false;
      try {
        await (repo as SourceProbe).probeSources().timeout(limit);
        ok = true;
      } catch (_) {
        /* too slow or unreachable: reported below */
      } finally {
        _connecting = null;
      }
      await loadLibrary();
      final down = [for (final s in librarySources) if (s.network && s.state == 'offline') s.name];
      if (!ok || down.isNotEmpty) {
        final names = down.isEmpty ? tr('źródła sieciowe') : down.join(', ');
        message(
          quietly
              ? tr('Nie udało się połączyć z: {0}. Spróbuję ponownie, gdy włączysz utwór.', [names])
              : tr('{0} nie odpowiada. Sprawdź, czy NAS jest włączony i w tej samej sieci.', [names]),
        );
        return false;
      }
      return true;
    }();
  }

  /// Network tracks that look unavailable may only be waiting for their source:
  /// connect first (the play button spins), then use the fresh state.
  Future<List<Track>> _reachable(List<Track> list) async {
    final network = list.any((t) => t.remote && !t.offline);
    // Right after start the NAS is still being reached: wait for that answer first.
    final pending = _connecting;
    if (network && pending != null) {
      await starting(() => pending);
      list = [for (final t in list) index.byId[t.id] ?? t];
    }
    if (!list.any((t) => t.remote && !t.available && !t.offline)) return list;
    await starting(() => connectSources());
    return [for (final t in list) index.byId[t.id] ?? t];
  }

  Future<void> runOperation(
    Future<ImportReport> Function(void Function(ImportProgress)) action, {
    bool showAlbums = false,
  }) async {
    if (importing || startupError != null) return;
    setState(() {
      importing = true;
      cancelling = false;
      progress = ImportProgress(0, 0, tr('Przygotowanie'));
    });
    try {
      final report = await action((value) {
        if (mounted) setState(() => progress = value);
      });
      await loadLibrary();
      if (!mounted) return;
      if (!report.cancelled || report.added + report.updated + report.unchanged > 0) {
        setState(() => lastImport = report);
        if (showAlbums && report.added > 0) go(const Nav('library', 'albums'));
        showImportSummary(report);
      }
    } catch (e) {
      message(tr('Operacja nie powiodła się: {0}', [e]));
    } finally {
      if (mounted) {
        setState(() {
          importing = false;
          cancelling = false;
        });
      }
    }
  }

  void showImportSummary(ImportReport r) {
    final parts = [
      if (r.added > 0) tr('dodano {0}', [trackCount(r.added)]),
      if (r.updated > 0) tr('zaktualizowano {0}', [r.updated]),
      if (r.missing > 0) tr('brakuje {0}', [r.missing]),
    ];
    final text = r.cancelled
        ? tr('Import przerwany')
        : parts.isEmpty
        ? tr('Biblioteka jest aktualna')
        : tr('Gotowe: {0}', [parts.join(', ')]);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(seconds: 6),
          action: r.errors.isEmpty
              ? null
              : SnackBarAction(
                  label: tr('Szczegóły'),
                  textColor: accent,
                  onPressed: () => showImportReport(r),
                ),
        ),
      );
  }

  Future<void> showImportReport(ImportReport report) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(report.cancelled ? tr('Import przerwany') : tr('Wynik importu'), style: Txt.title),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr('Dodano: {0}\nZaktualizowano: {1}\nBez zmian: {2}\nDodatkowe lokalizacje: {3}\nNowe braki: {4}\nNiedostępne źródła: {5}\nPominięte pliki: {6}', [report.added, report.updated, report.unchanged, report.duplicates, report.missing, report.offlineSources, report.ignored]),
                style: const TextStyle(height: 1.6),
              ),
              if (report.errors.isNotEmpty) ...[
                const SizedBox(height: Sp.l),
                Text(tr('Uwagi: {0}', [report.errors.length]), style: Txt.item),
                const SizedBox(height: Sp.s),
                ...report.errors.take(30).map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: Sp.s),
                    child: SelectableText(e, style: Txt.sub),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Zamknij'))),
      ],
    ),
  );

  Future<void> importMusic(bool folder) => runOperation(
    (update) => repository.importAudio(folder: folder, onProgress: update),
    showAlbums: true,
  );
  Future<void> scanSources([String? id]) =>
      runOperation((update) => repository.rescan(sourceId: id, onProgress: update));
  Future<void> relinkSource(String id) =>
      runOperation((update) => repository.relink(id, onProgress: update));
  Future<void> migrateLegacy() => runOperation(
    (update) => repository.migrateLegacy(onProgress: update),
    showAlbums: true,
  );

  Future<void> cancelImport() async {
    setState(() => cancelling = true);
    try {
      await repository.cancelImport();
    } catch (e) {
      message(tr('Nie udało się przerwać operacji: {0}', [e]));
    }
  }

  Future<void> forgetSource(LibrarySource source) async {
    if (importing) return;
    final ok = await confirm(
      context,
      title: tr('Odłączyć źródło?'),
      message: source.network
          ? tr('„{0}” zniknie z katalogu, a zapisane hasło zostanie usunięte. Pliki na serwerze zostaną bez zmian.', [source.name])
          : tr('„{0}” zniknie z katalogu. Pliki i foldery na dysku zostaną bez zmian.', [source.name]),
      action: tr('Odłącz'),
    );
    if (!ok) return;
    try {
      await repository.forgetSource(source.id);
      await loadLibrary();
    } catch (e) {
      message(tr('Nie udało się odłączyć źródła: {0}', [e]));
    }
  }

  bool get canDigitize => repository is IngestRepository;
  bool get canTransfer => repository is TransferRepository;
  bool get isPhone => defaultTargetPlatform == TargetPlatform.android && !kIsWeb;

  /// Import from physical media opens in the normal layout. Nothing starts here.
  void openIngest(bool cd) {
    if (!canDigitize || isPhone) return;
    ingest.setTab(cd ? 0 : 1);
    go(const Nav('import'));
  }

  List<MenuEntry> addMusicEntries() => [
    // Greyed-out entries need a reason next to them.
    if (importing) MenuEntry(tr('Trwa skanowanie. Nowe źródło dodasz po jego zakończeniu.'), icon: Icons.hourglass_top_rounded),
    MenuEntry(
      tr('Muzyka na urządzeniu'),
      icon: Icons.create_new_folder_outlined,
      shortcut: desktopMode ? tr('Ctrl+Shift+O') : null,
      onTap: importing ? null : () => unawaited(importMusic(true)),
    ),
    MenuEntry(
      tr('Pojedyncze pliki'),
      icon: Icons.audio_file_outlined,
      shortcut: desktopMode ? tr('Ctrl+O') : null,
      onTap: importing ? null : () => unawaited(importMusic(false)),
    ),
    if (networkKinds(networkProtocols).isNotEmpty) ...[
      MenuEntry.divider,
      for (final k in networkKinds(networkProtocols))
        MenuEntry(
          k.label,
          icon: k.icon,
          onTap: importing ? null : () => unawaited(showNetworkSourceForm(this, protocol: k.protocol)),
        ),
    ],
    if (canDigitize && !isPhone) ...[
      MenuEntry.divider,
      MenuEntry(tr('Importuj Audio CD'), icon: Icons.album_outlined, onTap: () => openIngest(true)),
      MenuEntry(tr('Nagraj winyl lub kasetę'), icon: Icons.radio_outlined, onTap: () => openIngest(false)),
    ],
  ];

  void showAddMusic({Offset? at}) =>
      unawaited(showActions(context, addMusicEntries(), at: at, title: tr('Dodaj źródło')));

  Future<void> editSource(LibrarySource source) => showNetworkSourceForm(this, source: source);

  void showDevices({Offset? at}) => unawaited(showDevicePicker(this, at: at));

  /// Floating mini player: 'mini' (244×82), 'nano' (196×44); null is the full app.
  String? floating;
  late final bool _hasWindow = () {
    try {
      return repository.hasWindow;
    } catch (_) {
      return false;
    }
  }();

  /// The desktop window can float as a mini player and go full screen.
  bool get canFloat => !isPhone && _hasWindow;

  void setFloating(String? mode) {
    if (!canFloat) return;
    if (mode != null) prefs.set('mini.size', mode);
    setState(() => floating = mode);
    unawaited(repository.windowAction({'action': 'mode', 'mode': mode ?? 'normal'}));
  }

  void toggleFloating() => setFloating(floating == null ? prefs.get<String>('mini.size', 'mini') : null);

  void setFloatingPin(bool value) {
    prefs.set('mini.pin', value);
    setState(() {});
    unawaited(repository.windowAction({'action': 'pin', 'value': value}));
  }

  /// Full screen visualization reacting to the music (PC and Android).
  void setLanguage(String code) {
    prefs.set('lang', code);
    lang = code;
    unawaited(repository.setLanguage(code).catchError((Object _) {}));
    applyPalette(palette);
  }

  void setPalette(Palette p) {
    prefs.set('palette', p.id);
    applyPalette(p);
  }

  bool visualizerOpen = false;
  Timer? _screensaver;

  /// Minutes of system-wide inactivity during playback before the visualizer covers
  /// the screen (PC). 0 turns it off.
  int get screensaverMinutes => prefs.get<int>('screensaver', 0);

  Future<void> _checkScreensaver() async {
    final minutes = screensaverMinutes;
    if (minutes <= 0 || visualizerOpen || !player.state.playing || !mounted) return;
    final idle = await repository.systemIdleMs().catchError((Object _) => null);
    if (idle != null && idle >= minutes * 60000 && mounted && !visualizerOpen && player.state.playing) {
      openVisualizer(screensaver: true);
    }
  }

  void openVisualizer({bool screensaver = false}) {
    if (floating != null) setFloating(null);
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: motion(context, Dur.screen),
        reverseTransitionDuration: motion(context, Dur.standard),
        pageBuilder: (_, _, _) => VisualizerScreen(app: this, screensaver: screensaver),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  void openNowPlaying() {
    if (queue.current == null) return;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: motion(context, Dur.screen),
        reverseTransitionDuration: motion(context, Dur.standard),
        pageBuilder: (_, _, _) => NowPlayingScreen(app: this),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: SlideTransition(
            position: Tween(begin: const Offset(0, .04), end: Offset.zero).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget transferScreen() => TransferScreen(
    repository: repository as TransferRepository,
    onLibraryChanged: () => unawaited(loadLibrary()),
  );

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 840;
      if (desktop != desktopMode) {
        desktopMode = desktop;
      }
      if (floating != null) return FloatingPlayer(app: this, nano: floating == 'nano');
      final shell = PageStorage(
        bucket: pageStorage,
        child: desktop ? DesktopShell(app: this) : MobileShell(app: this),
      );
      if (!showIntro) return shell;
      return Stack(
        fit: StackFit.expand,
        children: [
          shell,
          StartupIntro(
            ready: !loading,
            onDone: () => setState(() => showIntro = false),
          ),
        ],
      );
    },
  );
}
