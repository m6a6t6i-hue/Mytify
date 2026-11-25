import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'audio_player.dart';
import 'transfer.dart';
import 'design.dart';
import 'playback_card.dart';
export 'design.dart' show accent, background, panel, secondaryText;
import 'ingest.dart';
import 'audio_settings.dart';

import 'model.dart';
import 'cover_widget.dart';
import 'now_playing.dart';
import 'playlists.dart';
import 'metadata_ui.dart';
import 'queue.dart';
import 'repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MytifyApp());
}

class MytifyApp extends StatelessWidget {
  final LibraryRepository? repository;
  const MytifyApp({super.key, this.repository});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Mytify',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: background,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: accent,
            brightness: Brightness.dark,
          ).copyWith(
            primary: accent,
            onPrimary: const Color(0xff052512),
            surface: panel,
            secondary: accent,
            onSurface: const Color(0xfff3f8f4),
            outline: softBorder,
          ),
      fontFamily: 'Arial',
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xff0b120e),
        indicatorColor: accent.withValues(alpha: .13),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: states.contains(WidgetState.selected)
                ? accent
                : secondaryText,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? accent
                : secondaryText,
          ),
        ),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 4,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
        inactiveTrackColor: softBorder,
        activeTrackColor: accent,
        thumbColor: accent,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: const Color(0xff062715),
          backgroundColor: accent,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xffe3ede6),
          side: const BorderSide(color: softBorder),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    home: LibraryScreen(repository: repository),
  );
}

class LibraryScreen extends StatefulWidget {
  final LibraryRepository? repository;
  const LibraryScreen({super.key, this.repository});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final repository = widget.repository ?? createRepository();
  late final player = NativeAudioPlayer(repository);
  final queue = PlaybackQueue();
  final search = TextEditingController();
  bool _homePastPlayer = false;
  int _homeVisit = 0;
  final List<StreamSubscription<dynamic>> subscriptions = [];
  List<Track> tracks = [];
  List<MusicPlaylist> playlistPreviews = [];
  List<LibrarySource> librarySources = [];
  Timer? _searchDebounce, _libraryRefresh;
  int _searchGeneration = 0;
  Set<String>? _searchIds;
  bool cancelling = false;
  String page = 'home';
  String? albumKey, startupError;
  String? _openedTrackId;
  bool loading = true, importing = false, playing = false;
  ImportProgress progress = const ImportProgress(0, 0, '');
  ImportReport? lastImport;
  int playGeneration = 0;
  double volume = 80;
  bool _adjustingVolume = false, _volumeAvailable = true;
  String _outputDevice = "auto";
  double? seekingTo;
  bool _audioVolumeInitialized = false;

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
        if (mounted) message('Nie udało się odtworzyć pliku: $error');
      }),
    );
    subscriptions.add(player.stream.snapshot.listen(syncNativeAudio));
    unawaited(player.start());
    unawaited(loadLibrary());
  }

  @override
  void dispose() {
    playGeneration++;
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(player.dispose());
    _searchDebounce?.cancel();
    _libraryRefresh?.cancel();
    unawaited(repository.dispose());
    _libraryRefresh?.cancel();
    search.dispose();
    super.dispose();
  }

  void syncNativeAudio(AudioSnapshot state) {
    if (!mounted) {
      return;
    }
    final byId = {for (final track in tracks) track.id: track};
    final items = state.queueIds
        .where(byId.containsKey)
        .map((id) => byId[id]!)
        .toList();
    final current = items.indexWhere((t) => t.id == state.currentId);
    final changed =
        !listEquals(
          queue.items.map((t) => t.id).toList(),
          items.map((t) => t.id).toList(),
        ) ||
        queue.current?.id != state.currentId ||
        queue.shuffled != state.shuffled ||
        queue.repeat != state.repeat ||
        !_audioVolumeInitialized ||
        _outputDevice != state.selectedDevice ||
        _volumeAvailable != state.volumeAvailable ||
        (!_adjustingVolume && (volume - state.volume).abs() > .5);
    if (changed) {
      setState(() {
        final previous = queue.current?.id;
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
        if (previous != state.currentId) {
          seekingTo = null;
        }
        _outputDevice = state.selectedDevice;
        _volumeAvailable = state.volumeAvailable;
        if (!_audioVolumeInitialized || !_adjustingVolume) {
          volume = state.volume;
          _audioVolumeInitialized = true;
        }
      });
    }
  }

  Future<void> audioOperation(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (e) {
      message('Odtwarzanie: $e');
    }
  }

  Future<void> commitSeek(double value) async {
    try {
      await player.seek(Duration(milliseconds: value.round()));
    } catch (e) {
      message('Przewijanie: $e');
    } finally {
      if (mounted) {
        setState(() => seekingTo = null);
      }
    }
  }

  Future<void> metadataFor(
    List<Track> selected, {
    bool online = false,
    bool album = false,
  }) async {
    if (importing || selected.isEmpty) {
      return;
    }
    final changed = await editMusicMetadata(
      context,
      repository,
      selected,
      online: online,
      album: album,
    );
    if (changed != true || !mounted) {
      return;
    }
    final wasAlbum = albumKey != null;
    await loadLibrary();
    if (!mounted) {
      return;
    }
    final ids = selected.map((t) => t.id).toSet();
    final updated = tracks.where((t) => ids.contains(t.id)).toList();
    setState(() {
      albumKey = wasAlbum && updated.map((t) => t.albumKey).toSet().length == 1
          ? updated.first.albumKey
          : null;
    });
    if (search.text.trim().isNotEmpty) {
      changeSearch(search.text);
    }
    message('Zapisano zmiany w katalogu. Pliki pozostają bez zmian.');
  }

  Future<void> loadLibrary() async {
    try {
      final loaded = await repository.load();
      final sources = await repository.sources();
      if (repository is PlaylistRepository) {
        try {
          playlistPreviews = await (repository as PlaylistRepository)
              .playlists();
        } catch (_) {
          /* optional section; library stays available */
        }
      }
      loaded.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      final previous = queue.current?.id;
      queue.refresh(loaded);
      if (previous != null &&
          (queue.current?.id != previous ||
              queue.current?.available == false)) {
        playGeneration++;
        _openedTrackId = null;
        await player.stop();
      }
      if (mounted) {
        setState(() {
          tracks = loaded;
          librarySources = sources;
          loading = false;
          startupError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          startupError = 'Nie można otworzyć biblioteki: $e';
          loading = false;
        });
      }
    }
  }

  void changeSearch(String value) {
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    setState(() {
      _searchIds = null;
      if (value.trim().isNotEmpty && (page == 'sources' || page == 'import')) {
        page = 'tracks';
        albumKey = null;
      }
    });
    if (value.trim().isEmpty) return;
    _searchDebounce = Timer(const Duration(milliseconds: 180), () async {
      try {
        final ids = await repository.searchIds(value);
        if (mounted && generation == _searchGeneration) {
          setState(() => _searchIds = ids.toSet());
        }
      } catch (e) {
        if (mounted && generation == _searchGeneration) {
          message('Wyszukiwanie: $e');
        }
      }
    });
  }

  void message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
    );
  }

  void navigate(String next) => setState(() {
    if (next == 'home') {
      _homeVisit++;
      _homePastPlayer = false;
    }
    page = next;
    albumKey = null;
    search.clear();
    _searchIds = null;
    _searchGeneration++;
    _searchDebounce?.cancel();
  });

  Future<void> runOperation(
    Future<ImportReport> Function(void Function(ImportProgress)) action, {
    bool showAlbums = false,
  }) async {
    if (importing || startupError != null) return;
    setState(() {
      importing = true;
      cancelling = false;
      progress = const ImportProgress(0, 0, 'Przygotowanie');
    });
    try {
      final report = await action((value) {
        if (mounted) setState(() => progress = value);
      });
      await loadLibrary();
      if (!mounted) return;
      if (!report.cancelled ||
          report.added + report.updated + report.unchanged > 0) {
        setState(() {
          lastImport = report;
          if (showAlbums) {
            page = 'albums';
            albumKey = null;
            search.clear();
            _searchIds = null;
            _searchGeneration++;
          }
        });
        await showImportReport(report);
      }
    } catch (e) {
      message('Operacja nie powiodła się: $e');
    } finally {
      if (mounted) {
        setState(() {
          importing = false;
          cancelling = false;
        });
      }
    }
  }

  Future<void> importMusic(bool folder) => runOperation(
    (update) => repository.importAudio(folder: folder, onProgress: update),
    showAlbums: true,
  );
  Future<void> scanSources([String? id]) => runOperation(
    (update) => repository.rescan(sourceId: id, onProgress: update),
  );
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
      message('Nie udało się przerwać operacji: $e');
    }
  }

  Future<void> forgetSource(LibrarySource source) async {
    if (importing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Odłączyć źródło?'),
        content: Text(
          'Źródło „${source.name}” zostanie usunięte z katalogu. Pliki i foldery na dysku pozostaną bez zmian.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Anuluj'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Odłącz źródło'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await repository.forgetSource(source.id);
      await loadLibrary();
    } catch (e) {
      message('Nie udało się odłączyć źródła: $e');
    }
  }

  Future<void> showImportReport(ImportReport report) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        report.cancelled ? 'Operacja przerwana' : 'Operacja zakończona',
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Dodano: ${report.added}\nZaktualizowano: ${report.updated}\nBez zmian: ${report.unchanged}\nDodatkowe lokalizacje: ${report.duplicates}\nNowe braki: ${report.missing}\nNiedostępne źródła: ${report.offlineSources}\nInne pliki pominięte: ${report.ignored}',
              ),
              if (report.errors.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  'Uwagi: ${report.errors.length}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ...report.errors
                    .take(30)
                    .map(
                      (e) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SelectableText(e),
                      ),
                    ),
                if (report.errors.length > 30)
                  Text('Pozostałych uwag: ${report.errors.length - 30}'),
              ],
              const SizedBox(height: 18),
              const Text(
                'Oryginalne pliki pozostały bez zmian.',
                style: TextStyle(color: secondaryText),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Gotowe'),
        ),
      ],
    ),
  );

  List<Track> get visibleTracks {
    var result = tracks;
    if (page == 'liked') result = result.where((t) => t.liked).toList();
    if (albumKey != null) {
      result = result.where((t) => t.albumKey == albumKey).toList()
        ..sort(albumOrder);
    }
    return _searchIds == null
        ? filterTracks(result, search.text)
        : result.where((t) => _searchIds!.contains(t.id)).toList();
  }

  Future<void> startTrack(Track selected, List<Track> selection) async {
    if (!selected.available) {
      message(
        'Ten plik jest niedostępny. Podłącz źródło lub wskaż folder ponownie.',
      );
      return;
    }
    queue.replace(selection.where((t) => t.available).toList(), selected.id);
    await playCurrent();
  }

  Future<void> playSelection(List<Track> selection) async {
    final selected = selection.where((t) => t.available).firstOrNull;
    if (selected == null) {
      message('W tej kolekcji nie ma obecnie dostępnych plików.');
      return;
    }
    await startTrack(selected, selection);
  }

  Future<void> playCurrent() async {
    final track = queue.current;
    if (track == null) {
      return;
    }
    final generation = ++playGeneration;
    try {
      final ids = queue.items.map((t) => t.id).toList();
      if (listEquals(ids, player.state.queueIds)) {
        await player.jump(track.id);
      } else {
        await player.openQueue(ids, queue.index);
      }
      if (mounted && generation == playGeneration) {
        _openedTrackId = track.id;
      }
    } catch (e) {
      if (mounted && generation == playGeneration) {
        message('Nie można uruchomić odtwarzania: $e');
      }
    }
  }

  Future<void> togglePlay() async {
    if (queue.current == null) {
      await playSelection(visibleTracks);
      return;
    }
    if (!queue.current!.available) {
      message('Źródło jest niedostępne. Podłącz je i wykonaj skan.');
      return;
    }
    if (_openedTrackId != queue.current!.id || player.state.currentId == null) {
      await playCurrent();
      return;
    }
    await audioOperation(player.playOrPause);
  }

  Future<void> nextTrack() => audioOperation(player.next);
  Future<void> previousTrack() => audioOperation(player.previous);

  Future<void> toggleLike(Track track) async {
    try {
      await repository.setLiked(track.id, !track.liked);
      await loadLibrary();
    } catch (e) {
      message('Nie udało się zapisać polubienia: $e');
    }
  }

  Future<void> removeTrack(Track track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Usunąć z Mytify?'),
        content: Text(
          'Utwór „${track.title}” zniknie z biblioteki. Pliki na dysku pozostaną bez zmian. Możesz przywrócić utwór, wybierając jego plik ponownie w imporcie.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Anuluj'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Usuń z biblioteki'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      if (queue.current?.id == track.id) {
        playGeneration++;
        _openedTrackId = null;
        await player.stop();
      }
      await repository.remove(track.id);
      queue.remove(track.id);
      await loadLibrary();
    } catch (e) {
      message('Nie udało się usunąć wpisu: $e');
    }
  }

  Widget cover(Track? track, double size) {
    final image = CoverImage(
      track?.cover,
      width: size,
      height: size,
      cacheWidth: (size * 2).ceil(),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 300),
        child: SizedBox(
          key: ValueKey('${track?.id}:${track?.cover}'),
          width: size,
          height: size,
          child: image,
        ),
      ),
    );
  }

  Widget coverPlaceholder(double size) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xff164b30), Color(0xff102419)],
      ),
    ),
    child: Center(
      child: Icon(
        Icons.album_outlined,
        size: size * .35,
        color: accent.withValues(alpha: .7),
      ),
    ),
  );

  Widget navButton(String key, IconData icon, String title) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
    child: Material(
      color: page == key ? const Color(0xff123921) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        dense: true,
        leading: Icon(icon, size: 21),
        title: Text(title),
        selected: page == key,
        selectedTileColor: const Color(0xff123921),
        selectedColor: accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        onTap: () => navigate(key),
      ),
    ),
  );

  Widget searchField() => TextField(
    controller: search,
    onChanged: changeSearch,
    decoration: InputDecoration(
      hintText: 'Szukaj w swojej muzyce',
      prefixIcon: const Icon(Icons.search_rounded),
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
      suffixIcon: search.text.isEmpty
          ? null
          : IconButton(
              tooltip: 'Wyczyść wyszukiwanie',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                search.clear();
                _searchIds = null;
                _searchGeneration++;
                _searchDebounce?.cancel();
              }),
            ),
    ),
  );

  void showDevices() => showDialog<void>(
    context: context,
    builder: (_) => AudioSettings(player: player),
  );

  Future<void> openPlaylists() async {
    if (repository is! PlaylistRepository) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaylistScreen(
          repository: repository as PlaylistRepository,
          tracks: tracks,
          onPlay: (selection) {
            Navigator.of(context).pop();
            unawaited(playSelection(selection));
          },
        ),
      ),
    );
    if (mounted) await loadLibrary();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 850;
      final short = constraints.maxHeight < 500;
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (desktop)
                      Container(
                        width: 218,
                        decoration: const BoxDecoration(
                          color: Color(0xff0b100d),
                          border: Border(right: BorderSide(color: softBorder)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Padding(
                              padding: EdgeInsets.fromLTRB(22, 30, 12, 30),
                              child: MytifyBrand(size: 35),
                            ),
                            Expanded(
                              child: ListView(
                                children: [
                                  if (repository is TransferRepository)
                                    navButton(
                                      'transfer',
                                      Icons.phonelink_rounded,
                                      'Połącz telefon',
                                    ),
                                  navButton(
                                    'home',
                                    Icons.home_rounded,
                                    'Start',
                                  ),
                                  navButton(
                                    'albums',
                                    Icons.library_music_outlined,
                                    'Albumy',
                                  ),
                                  navButton(
                                    'tracks',
                                    Icons.music_note_rounded,
                                    'Utwory',
                                  ),
                                  if (repository is PlaylistRepository)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                      ),
                                      child: ListTile(
                                        leading: const Icon(
                                          Icons.queue_music_rounded,
                                          size: 21,
                                        ),
                                        title: const Text('Playlisty'),
                                        onTap: openPlaylists,
                                      ),
                                    ),
                                  navButton(
                                    'liked',
                                    Icons.favorite_border_rounded,
                                    'Polubione',
                                  ),
                                  navButton(
                                    'sources',
                                    Icons.folder_open_outlined,
                                    'Źródła',
                                  ),
                                  const Padding(
                                    padding: EdgeInsets.all(20),
                                    child: Divider(color: softBorder),
                                  ),
                                  navButton(
                                    'import',
                                    Icons.add_circle_outline_rounded,
                                    'Dodaj muzykę',
                                  ),
                                ],
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                'TWOJE PLIKI. TWOJE ZASADY.\nMytify 0.9.0',
                                style: TextStyle(
                                  color: secondaryText,
                                  fontSize: 10,
                                  height: 2,
                                  letterSpacing: .7,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment(.65, -1.1),
                            radius: 1.4,
                            colors: [Color(0xff0c3520), background],
                            stops: [0, .7],
                          ),
                        ),
                        child: Column(
                          children: [
                            Padding(
                              padding: EdgeInsets.fromLTRB(
                                desktop ? 30 : 18,
                                short ? 6 : 18,
                                desktop ? 30 : 18,
                                short ? 6 : 12,
                              ),
                              child: desktop
                                  ? Row(
                                      children: [
                                        Expanded(
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 560,
                                            ),
                                            child: searchField(),
                                          ),
                                        ),
                                        const SizedBox(width: 24),
                                        const Icon(
                                          Icons.offline_bolt_outlined,
                                          size: 17,
                                          color: accent,
                                        ),
                                        const SizedBox(width: 7),
                                        const Text(
                                          'Twoja muzyka. Lokalnie.',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: secondaryText,
                                          ),
                                        ),
                                      ],
                                    )
                                  : Column(
                                      children: [
                                        if (!short) ...[
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              const MytifyBrand(),
                                              IconButton(
                                                tooltip:
                                                    'Odtwarzaj na urządzeniu',
                                                onPressed: showDevices,
                                                icon: const Icon(
                                                  Icons.cast_rounded,
                                                  color: secondaryText,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 16),
                                        ],
                                        searchField(),
                                      ],
                                    ),
                            ),
                            if (importing)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      progress.total == 0
                                          ? progress.name
                                          : '${progress.done} / ${progress.total} · ${progress.name}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: LinearProgressIndicator(
                                            value: progress.total == 0
                                                ? null
                                                : progress.done /
                                                      progress.total,
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: cancelling
                                              ? null
                                              : cancelImport,
                                          child: Text(
                                            cancelling
                                                ? 'Przerywanie…'
                                                : 'Zatrzymaj po bieżącym pliku',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            Expanded(
                              child: AnimatedSwitcher(
                                duration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 220),
                                switchInCurve: Curves.easeOutCubic,
                                layoutBuilder: (current, previous) => Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    for (final old in previous)
                                      ExcludeSemantics(
                                        child: ExcludeFocus(
                                          child: TickerMode(
                                            enabled: false,
                                            child: IgnorePointer(child: old),
                                          ),
                                        ),
                                      ),
                                    ?current,
                                  ],
                                ),
                                child: KeyedSubtree(
                                  key: ValueKey(
                                    '$page:$albumKey:${search.text.isNotEmpty}',
                                  ),
                                  child: content(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (constraints.maxWidth >= 1200 &&
                        page == 'home' &&
                        albumKey == null &&
                        search.text.trim().isEmpty &&
                        queue.current != null)
                      SizedBox(
                        width: 338,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(8, 24, 20, 24),
                          child: PlaybackCard(
                            player: player,
                            trackById: (id) =>
                                tracks.where((t) => t.id == id).firstOrNull,
                            onError: message,
                            onQueue: showQueue,
                            onDevices: showDevices,
                            onLike: (t) => unawaited(toggleLike(t)),
                            expanded: true,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              AnimatedSize(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child:
                    !desktop &&
                        page == 'home' &&
                        albumKey == null &&
                        search.text.trim().isEmpty &&
                        queue.current != null &&
                        !_homePastPlayer
                    ? const SizedBox(width: double.infinity)
                    : playerBar(desktop),
              ),
            ],
          ),
        ),
        bottomNavigationBar: desktop
            ? null
            : NavigationBar(
                height: short ? 64 : 72,
                selectedIndex: [
                  'home',
                  'albums',
                  'sources',
                  'liked',
                  'import',
                ].indexOf(page).clamp(0, 4),
                onDestinationSelected: (i) => navigate(
                  ['home', 'albums', 'sources', 'liked', 'import'][i],
                ),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: 'Start',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.library_music_outlined),
                    label: 'Biblioteka',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.folder_open_outlined),
                    label: 'Źródła',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.favorite_border_rounded),
                    label: 'Polubione',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.add_circle_outline_rounded),
                    label: 'Dodaj',
                  ),
                ],
              ),
      );
    },
  );

  Widget homeScreen() {
    final mobile = MediaQuery.sizeOf(context).width < 850;
    final playerCard = SliverPadding(
      padding: EdgeInsets.fromLTRB(20, mobile ? 8 : 0, 20, 24),
      sliver: SliverToBoxAdapter(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: PlaybackCard(
              player: player,
              trackById: (id) => tracks.where((t) => t.id == id).firstOrNull,
              onError: message,
              onQueue: showQueue,
              onExpand: showNowPlaying,
              onLike: (t) => unawaited(toggleLike(t)),
            ),
          ),
        ),
      ),
    );
    final albums = tracks.map((t) => t.albumKey).toSet().length;
    final liked = tracks.where((t) => t.liked).toList();
    return NotificationListener<ScrollNotification>(
      onNotification: (event) {
        if (event.depth == 0 && page == 'home') {
          final past = event.metrics.pixels > 240;
          if (past != _homePastPlayer && mounted) {
            setState(() => _homePastPlayer = past);
          }
        }
        return false;
      },
      child: CustomScrollView(
        key: PageStorageKey('home:$_homeVisit'),
        slivers: [
          if (mobile && queue.current != null) playerCard,
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 22),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Twoja muzyka.',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      height: 1.06,
                      letterSpacing: -1.2,
                    ),
                  ),
                  const Text(
                    'Zawsze z Tobą.',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      height: 1.12,
                      letterSpacing: -1.2,
                      color: accent,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    [
                      collectionCount(
                        tracks.length,
                        'utwór',
                        'utwory',
                        'utworów',
                      ),
                      collectionCount(albums, 'album', 'albumy', 'albumów'),
                      if (playlistPreviews.isNotEmpty)
                        collectionCount(
                          playlistPreviews.length,
                          'playlista',
                          'playlisty',
                          'playlist',
                        ),
                      if (tracks.any((t) => !t.available))
                        'Dostępne: ${tracks.where((t) => t.available).length}',
                    ].join(' · '),
                    style: const TextStyle(color: secondaryText, fontSize: 13),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: () => playSelection(tracks),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Odtwórz bibliotekę'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final available =
                              tracks.where((t) => t.available).toList()
                                ..shuffle();
                          if (available.isNotEmpty) {
                            await playSelection(available);
                            await audioOperation(() => player.shuffle(true));
                          }
                        },
                        icon: const Icon(Icons.shuffle_rounded, size: 20),
                        label: const Text('Losowo'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => navigate('import'),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Dodaj muzykę'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (!mobile &&
              queue.current != null &&
              MediaQuery.sizeOf(context).width < 1200)
            playerCard,
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 20, 14),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Twoje albumy',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.6,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => navigate('albums'),
                    child: const Text('Pokaż wszystkie'),
                  ),
                ],
              ),
            ),
          ),
          albumGrid(tracks),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 30, 24, 32),
            sliver: SliverToBoxAdapter(
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => navigate('liked'),
                    icon: const Icon(
                      Icons.favorite_border_rounded,
                      color: accent,
                    ),
                    label: Text('Polubione · ${liked.length}'),
                  ),
                  if (repository is PlaylistRepository)
                    OutlinedButton.icon(
                      onPressed: openPlaylists,
                      icon: const Icon(Icons.queue_music_rounded),
                      label: const Text('Twoje playlisty'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () => navigate('sources'),
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('Zarządzaj źródłami'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget content() {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (startupError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: accent, size: 44),
              const SizedBox(height: 20),
              SelectableText(startupError!),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: loadLibrary,
                child: const Text('Spróbuj ponownie'),
              ),
            ],
          ),
        ),
      );
    }
    if (page == 'transfer' && repository is TransferRepository) {
      return TransferScreen(
        repository: repository as TransferRepository,
        onLibraryChanged: () => unawaited(loadLibrary()),
      );
    }
    if (page == 'import') return importScreen();
    if (page == 'sources') return sourcesScreen();
    if (tracks.isEmpty) return emptyLibrary();
    if (page == 'home' && albumKey == null && search.text.trim().isEmpty) {
      return homeScreen();
    }
    final selection = visibleTracks;
    final searching = search.text.trim().isNotEmpty;
    final title = searching
        ? 'Wyniki wyszukiwania'
        : albumKey != null && selection.isNotEmpty
        ? selection.first.displayAlbum
        : switch (page) {
            'home' => 'Twoja muzyka',
            'liked' => 'Polubione',
            'tracks' => 'Wszystkie utwory',
            _ => 'Albumy',
          };
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (albumKey != null)
                  TextButton.icon(
                    onPressed: () => setState(() => albumKey = null),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Wszystkie albumy'),
                  ),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  '${selection.length} utworów · dostępnych: ${selection.where((t) => t.available).length}',
                  style: const TextStyle(color: secondaryText),
                ),
                if (albumKey != null && selection.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 20,
                    runSpacing: 18,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      cover(selection.first, 130),
                      SizedBox(
                        width: (MediaQuery.sizeOf(context).width - 56)
                            .clamp(0, 500)
                            .toDouble(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              selection.first.albumArtist.isEmpty
                                  ? selection.first.displayArtist
                                  : selection.first.albumArtist,
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: () => playSelection(selection),
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Odtwórz album'),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: importing
                                      ? null
                                      : () => metadataFor(
                                          selection,
                                          online: true,
                                        ),
                                  icon: const Icon(
                                    Icons.auto_fix_high_outlined,
                                  ),
                                  label: const Text('Znajdź dane i okładkę'),
                                ),
                                TextButton(
                                  onPressed: importing
                                      ? null
                                      : () =>
                                            metadataFor(selection, album: true),
                                  child: const Text('Edytuj album'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
                if (page == 'home' && !searching)
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.icon(
                          onPressed: selection.isEmpty
                              ? null
                              : () => playSelection(selection),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Odtwórz bibliotekę'),
                        ),
                        if (repository is PlaylistRepository)
                          OutlinedButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => PlaylistScreen(
                                  repository: repository as PlaylistRepository,
                                  tracks: tracks,
                                  onPlay: (selection) {
                                    Navigator.of(context).pop();
                                    unawaited(playSelection(selection));
                                  },
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.queue_music),
                            label: const Text('Playlisty'),
                          ),
                        OutlinedButton.icon(
                          onPressed: () => navigate('import'),
                          icon: const Icon(Icons.add),
                          label: const Text('Dodaj muzykę'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (selection.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                'Brak pasujących utworów.',
                style: TextStyle(color: secondaryText),
              ),
            ),
          )
        else if (!searching &&
            albumKey == null &&
            (page == 'home' || page == 'albums'))
          albumGrid(selection)
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            sliver: SliverList.builder(
              itemCount: selection.length,
              itemBuilder: (context, i) => trackRow(selection[i], selection),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget albumGrid(List<Track> selection) {
    final groups = <String, List<Track>>{};
    for (final track in selection) {
      groups.putIfAbsent(track.albumKey, () => []).add(track);
    }
    final albums = groups.values.toList();
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final columns = (constraints.crossAxisExtent / 190).floor().clamp(
            2,
            6,
          );
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 18,
              crossAxisSpacing: 12,
              mainAxisExtent:
                  (constraints.crossAxisExtent - 12 * (columns - 1)) / columns +
                  20 +
                  MediaQuery.textScalerOf(context).scale(40),
            ),
            itemCount: albums.length,
            itemBuilder: (context, i) {
              final album = albums[i]..sort(albumOrder);
              final art =
                  album.where((t) => t.cover != null).firstOrNull ??
                  album.first;
              return MotionTile(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => albumKey = album.first.albumKey),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: LayoutBuilder(
                    builder: (context, bounds) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Stack(
                          children: [
                            AnimatedContainer(
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 300),
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: queue.current?.albumKey == art.albumKey
                                      ? accent
                                      : Colors.transparent,
                                  width: 1.5,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: CoverImage(
                                  art.cover,
                                  width: bounds.maxWidth - 7,
                                  height: bounds.maxWidth - 7,
                                  cacheWidth: (bounds.maxWidth * 2).ceil(),
                                ),
                              ),
                            ),
                            Positioned(
                              right: 8,
                              top: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xcc080d0b),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  art.format.toUpperCase(),
                                  style: const TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            if (queue.current?.albumKey == art.albumKey)
                              Positioned(
                                left: 12,
                                bottom: 12,
                                child: PlayingBars(playing: playing),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          album.first.displayAlbum,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          album.first.albumArtist.isEmpty
                              ? album.first.displayArtist
                              : album.first.albumArtist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: secondaryText,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget trackRow(Track track, List<Track> selection) => ListTile(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    selected: queue.current?.id == track.id,
    selectedTileColor: const Color(0xff163323),
    selectedColor: accent,
    leading: cover(track, 44),
    title: Text(
      track.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: track.available ? null : secondaryText),
    ),
    subtitle: Text(
      track.available
          ? track.displayArtist
          : '${track.displayArtist} · Niedostępny',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    onTap: () => startTrack(track, selection),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (MediaQuery.sizeOf(context).width > 550)
          Text(
            durationLabel(track.durationMs),
            style: const TextStyle(color: secondaryText, fontSize: 12),
          ),
        IconButton(
          tooltip: track.liked ? 'Usuń z polubionych' : 'Dodaj do polubionych',
          onPressed: () => toggleLike(track),
          icon: Icon(
            track.liked ? Icons.favorite : Icons.favorite_border,
            size: 20,
            color: track.liked ? accent : secondaryText,
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Opcje utworu',
          onSelected: (value) {
            if (value == 'details') {
              showDetails(track);
            } else if (value == 'edit') {
              unawaited(metadataFor([track]));
            } else {
              unawaited(removeTrack(track));
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Edytuj dane utworu')),
            PopupMenuItem(value: 'details', child: Text('Informacje o pliku')),
            PopupMenuItem(value: 'remove', child: Text('Usuń z Mytify')),
          ],
        ),
      ],
    ),
  );

  Widget emptyLibrary() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(26),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xff123921),
            ),
            child: const Icon(
              Icons.library_music_outlined,
              color: accent,
              size: 56,
            ),
          ),
          const SizedBox(height: 26),
          const Text(
            'Tu zaczyna się Twoja kolekcja.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: -.8,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Wskaż swoją muzykę na dysku. Albumy, okładki i polubione\npozostaną w katalogu — także po odłączeniu źródła.',
            textAlign: TextAlign.center,
            style: TextStyle(color: secondaryText, height: 1.6),
          ),
          const SizedBox(height: 26),
          FilledButton.icon(
            onPressed: () => navigate('import'),
            icon: const Icon(Icons.add),
            label: const Text('Dodaj swoją muzykę'),
          ),
        ],
      ),
    ),
  );

  Widget sourcesScreen() => SingleChildScrollView(
    padding: const EdgeInsets.all(28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Źródła muzyki',
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Foldery i pliki pozostają w swoich lokalizacjach.',
          style: TextStyle(color: secondaryText),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: importing ? null : () => navigate('import'),
              icon: const Icon(Icons.add),
              label: const Text('Dodaj źródło'),
            ),
            OutlinedButton.icon(
              onPressed: importing || librarySources.isEmpty
                  ? null
                  : () => scanSources(),
              icon: const Icon(Icons.refresh),
              label: const Text('Skanuj wszystkie'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (librarySources.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 36),
            child: Text('Nie dodano jeszcze żadnego źródła.'),
          ),
        ...librarySources.map((source) {
          final offline = source.state == 'offline' || source.state == 'error';
          final label = switch (source.state) {
            'offline' => 'Źródło niedostępne',
            'error' => 'Nie można odczytać źródła',
            'partial' => 'Wymaga ponownego skanu',
            'scanning' => 'Skanowanie…',
            _ => 'Dostępne',
          };
          final path = source.path.startsWith(r'\\?\')
              ? source.path.substring(4)
              : source.path;
          return Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: panel,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      offline
                          ? Icons.folder_off_outlined
                          : Icons.folder_open_outlined,
                      color: offline ? secondaryText : accent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        source.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (path.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: SelectableText(
                      path,
                      style: const TextStyle(
                        color: secondaryText,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                Text(
                  '$label · dostępne lokalizacje: ${source.availableFiles} / ${source.files}',
                  style: TextStyle(
                    color: offline ? secondaryText : accent,
                    fontSize: 12,
                  ),
                ),
                if (source.lastScan > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Ostatni skan: ${DateTime.fromMillisecondsSinceEpoch(source.lastScan).toLocal().toString().split('.').first}',
                      style: const TextStyle(
                        color: secondaryText,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: importing
                          ? null
                          : () => scanSources(source.id),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Skanuj ponownie'),
                    ),
                    if (source.kind == 'folder')
                      TextButton.icon(
                        onPressed: importing
                            ? null
                            : () => relinkSource(source.id),
                        icon: const Icon(Icons.drive_file_move_outline),
                        label: const Text('Wskaż folder ponownie'),
                      ),
                    TextButton(
                      onPressed: importing ? null : () => forgetSource(source),
                      child: const Text('Odłącz źródło'),
                    ),
                  ],
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: 12),
        const Text(
          'Zmiany w folderach wykryjesz przyciskiem „Skanuj ponownie”. Niedostępne źródło zachowuje albumy i polubienia w katalogu.',
          style: TextStyle(color: secondaryText, height: 1.5),
        ),
      ],
    ),
  );

  Future<void> openIngest(bool cd) async {
    await player.command({'action': 'pause'});
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => IngestScreen(
          library: repository,
          repository: repository as IngestRepository,
          cd: cd,
        ),
      ),
    );
    await loadLibrary();
  }

  Widget importScreen() => SingleChildScrollView(
    padding: const EdgeInsets.all(28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (repository is TransferRepository) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.phonelink_rounded, color: accent),
            title: Text(
              (repository as TransferRepository).receivesTransfers
                  ? 'Z komputera'
                  : 'Połącz telefon',
            ),
            subtitle: const Text('Albumy i playlisty · kopie offline'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => navigate('transfer'),
          ),
          const SizedBox(height: 18),
        ],
        const Text(
          'Dodaj muzykę',
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Wybierz źródło swojej kolekcji.',
          style: TextStyle(color: secondaryText),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: panel,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.folder_open, color: accent, size: 34),
              const SizedBox(height: 12),
              const Text(
                'Pliki i foldery',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Text(
                repository.storageDescription,
                style: const TextStyle(color: secondaryText, height: 1.5),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: importing ? null : () => importMusic(true),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Wybierz folder'),
                  ),
                  OutlinedButton.icon(
                    onPressed: importing ? null : () => importMusic(false),
                    icon: const Icon(Icons.audio_file_outlined),
                    label: const Text('Wybierz pliki'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                defaultTargetPlatform == TargetPlatform.android
                    ? 'MP3 · FLAC · WAV · AAC · OGG · OPUS\nPozostałe kodeki zależą od urządzenia. Import nie zmienia plików.'
                    : 'MP3 · FLAC · WAV · M4A (AAC-LC / ALAC) · OGG Vorbis\nOPUS, APE i WavPack: katalogowanie bez odtwarzania w tej wersji.',
                style: TextStyle(color: secondaryText, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        if (defaultTargetPlatform != TargetPlatform.android)
          OutlinedButton.icon(
            onPressed: importing ? null : migrateLegacy,
            icon: const Icon(Icons.move_to_inbox_outlined),
            label: const Text('Przenieś bibliotekę z wersji 0.1'),
          ),
        const SizedBox(height: 24),
        const Text(
          'Z fizycznej kolekcji',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Text(
          repository is IngestRepository
              ? 'Nagraj lub odczytaj kolekcję na komputerze. Zachowaj oryginał i dodaj opisane utwory do biblioteki.'
              : 'Nagrywanie winylu/kasety i odczyt Audio CD są dostępne na PC. Na telefon dodasz gotowe pliki FLAC lub WAV.',
          style: const TextStyle(color: secondaryText),
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.album_outlined),
          title: const Text('Płyta Audio CD'),
          subtitle: const Text('Odczyt cyfrowy, dane albumu i FLAC'),
          onTap: repository is IngestRepository && !importing
              ? () => openIngest(true)
              : null,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.radio_outlined),
          title: const Text('Winyl, kaseta lub inne urządzenie'),
          subtitle: const Text('Podłączenie, nagranie, podział i opis utworów'),
          onTap: repository is IngestRepository && !importing
              ? () => openIngest(false)
              : null,
        ),
        if (lastImport != null)
          TextButton.icon(
            onPressed: () => showImportReport(lastImport!),
            icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('Ostatni wynik importu'),
          ),
      ],
    ),
  );

  Widget playerBar(bool desktop) {
    final current = queue.current;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xff0b120e),
        border: Border(top: BorderSide(color: softBorder)),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: desktop ? 22 : 14,
        vertical: 12,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              cover(current, desktop ? 52 : 42),
              const SizedBox(width: 12),
              Expanded(
                flex: desktop ? 3 : 1,
                child: InkWell(
                  onTap: current == null ? null : showNowPlaying,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current?.title ?? 'Wybierz utwór',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        current?.displayArtist ??
                            'Twoja muzyka czeka w bibliotece',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: secondaryText,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (desktop)
                IconButton(
                  tooltip: 'Losowa kolejność',
                  color: queue.shuffled ? accent : secondaryText,
                  onPressed: current == null
                      ? null
                      : () => audioOperation(
                          () => player.shuffle(!queue.shuffled),
                        ),
                  icon: const Icon(Icons.shuffle, size: 20),
                ),
              if (desktop)
                IconButton(
                  tooltip: 'Poprzedni utwór',
                  onPressed: current == null ? null : previousTrack,
                  icon: const Icon(Icons.skip_previous),
                ),
              PlayButton(
                playing: playing,
                size: desktop ? 48 : 44,
                onPressed: current == null && tracks.isEmpty
                    ? null
                    : togglePlay,
              ),
              IconButton(
                tooltip: 'Następny utwór',
                onPressed: current == null ? null : nextTrack,
                icon: const Icon(Icons.skip_next),
              ),
              if (desktop)
                IconButton(
                  tooltip: 'Powtarzaj kolejkę',
                  color: queue.repeat ? accent : secondaryText,
                  onPressed: () =>
                      audioOperation(() => player.repeat(!queue.repeat)),
                  icon: const Icon(Icons.repeat, size: 20),
                ),
              if (desktop) const Spacer(flex: 1),
              StreamBuilder<AudioSnapshot>(
                stream: player.stream.snapshot,
                initialData: player.state,
                builder: (context, snapshot) {
                  final audio = snapshot.data ?? player.state;
                  return IconButton(
                    tooltip: audio.selectedDevice == 'auto'
                        ? 'Odtwarzaj na urządzeniu'
                        : 'Odtwarzanie: ${audio.output?['name'] ?? audio.selectedDevice}',
                    color: audio.selectedDevice == 'auto' ? null : accent,
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => AudioSettings(player: player),
                    ),
                    icon: const Icon(Icons.speaker_group_outlined, size: 22),
                  );
                },
              ),
              IconButton(
                tooltip: 'Kolejka odtwarzania',
                onPressed: showQueue,
                icon: const Icon(Icons.queue_music, size: 22),
              ),
              if (desktop) ...[
                const SizedBox(width: 12),
                const Icon(
                  Icons.volume_up_outlined,
                  size: 18,
                  color: secondaryText,
                ),
                SizedBox(
                  width: 100,
                  child: Slider(
                    value: volume,
                    max: 100,
                    label: '${volume.round()}%',
                    onChanged: !_volumeAvailable
                        ? null
                        : (v) {
                            setState(() {
                              volume = v;
                              _adjustingVolume = true;
                            });
                            unawaited(player.setVolume(v));
                          },
                    onChangeEnd: !_volumeAvailable
                        ? null
                        : (v) async {
                            await audioOperation(() => player.commitVolume(v));
                            if (mounted) {
                              setState(() => _adjustingVolume = false);
                            }
                          },
                  ),
                ),
              ],
            ],
          ),
          if (current != null)
            StreamBuilder<Duration>(
              stream: player.stream.position,
              initialData: player.state.position,
              builder: (context, snapshot) {
                final position = snapshot.data ?? Duration.zero;
                final duration = player.state.duration;
                final max = duration.inMilliseconds.toDouble();
                return Row(
                  children: [
                    Text(
                      durationLabel(position.inMilliseconds),
                      style: const TextStyle(
                        fontSize: 11,
                        color: secondaryText,
                      ),
                    ),
                    Expanded(
                      child: SizedBox(
                        height: 26,
                        child: Slider(
                          value:
                              (seekingTo ?? position.inMilliseconds.toDouble())
                                  .clamp(0, max > 0 ? max : 1),
                          max: max > 0 ? max : 1,
                          onChanged: max <= 0
                              ? null
                              : (v) => setState(() => seekingTo = v),
                          onChangeEnd: max <= 0
                              ? null
                              : (v) => unawaited(commitSeek(v)),
                        ),
                      ),
                    ),
                    Text(
                      durationLabel(duration.inMilliseconds),
                      style: const TextStyle(
                        fontSize: 11,
                        color: secondaryText,
                      ),
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  void showNowPlaying() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => NowPlaying(
        player: player,
        trackById: (id) => tracks.where((t) => t.id == id).firstOrNull,
        onQueue: showQueue,
        onDevices: showDevices,
        onLike: (t) => unawaited(toggleLike(t)),
        onError: message,
      ),
    );
  }

  void showQueue() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 0, 22, 14),
              child: Text(
                'Kolejka odtwarzania',
                style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
              ),
            ),
            if (queue.items.isEmpty)
              const Expanded(
                child: Center(
                  child: Text('Odtwórz album lub utwór, aby utworzyć kolejkę.'),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: queue.items.length,
                  itemBuilder: (context, i) {
                    final track = queue.items[i];
                    return ListTile(
                      selected: i == queue.index,
                      leading: cover(track, 42),
                      title: Text(track.title),
                      subtitle: Text(track.displayArtist),
                      onTap: () {
                        queue.index = i;
                        Navigator.pop(context);
                        unawaited(playCurrent());
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  void showDetails(Track track) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Informacje o pliku'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  track.title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                SelectableText(
                  '${track.displayArtist}\n${track.displayAlbum}\nOpis: ${track.edited ? 'poprawki w Mytify (${track.metadataSource})' : 'tagi w pliku'}\n\nPlik: ${track.fileName}\nFormat: ${track.format}\nRozmiar: ${(track.size / 1024 / 1024).toStringAsFixed(1)} MB\nCzęstotliwość źródła: ${track.sampleRate == 0 ? 'brak danych' : '${track.sampleRate} Hz'}\nGłębia źródła: ${track.bitDepth == 0 ? 'brak danych' : '${track.bitDepth} bit'}\n\nSHA-256:\n${track.id}',
                ),
                const SizedBox(height: 18),
                Text(
                  defaultTargetPlatform == TargetPlatform.android
                      ? 'Odtwarzanie Media3 / Android. Wyjście wybierzesz w panelu multimediów telefonu. Bit-perfect niepotwierdzone.'
                      : 'Natywne odtwarzanie Rust / WASAPI. Aktualne wyjście sprawdzisz w ustawieniach dźwięku. Bit-perfect niepotwierdzone.',
                  style: const TextStyle(color: secondaryText, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zamknij'),
          ),
        ],
      ),
    );
  }
}
