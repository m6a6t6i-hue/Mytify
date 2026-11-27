import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mytify/audio_settings.dart';
import 'package:mytify/ingest.dart';
import 'package:mytify/artist_photos_ui.dart';
import 'package:mytify/main.dart';
import 'package:mytify/metadata_models.dart';
import 'package:mytify/mini_player.dart';
import 'package:mytify/player_ui.dart';
import 'package:mytify/repository_android.dart';
import 'package:mytify/shell_desktop.dart';
import 'package:mytify/visualizer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Android method channel stands in for the PC engine; ingest answers like a PC with no drive.
class DesktopRepo extends AndroidLibraryRepository implements IngestRepository {
  final ingestCalls = <String>[];
  final windowCalls = <Map<String, dynamic>>[];
  @override
  bool get hasWindow => true;
  @override
  Future<void> windowAction(Map<String, dynamic> action) async => windowCalls.add(action);
  @override
  Future<dynamic> ingest(Map<String, dynamic> request) async {
    ingestCalls.add(request['action'] as String);
    return switch (request['action']) {
      'drives' || 'inputs' || 'sessions' || 'media' || 'disc' => [],
      'state' => {'running': false, 'stage': ''},
      'folders' => {'recordings': r'C:\dane\recordings', 'cd': r'C:\dane\cd-imports'},
      _ => {},
    };
  }
}

/// A PC with Spotify playing: one app, a Spotify album, a recording that ends.
class AppRecordingRepo extends DesktopRepo {
  final requests = <Map<String, dynamic>>[];
  Map<String, dynamic> state = {'running': false, 'stage': ''};
  bool recorded = false;
  static const release = ReleaseCandidate(
    id: '0e8f1c2a-0000-4000-8000-000000000001',
    title: 'Album',
    artist: 'Zespół',
    date: '2001-02-03',
    country: 'XW',
    format: 'Digital Media',
    label: '',
    barcode: '',
    disambiguation: '',
    trackCount: 2,
    score: 100,
  );

  void finishRecording() {
    recorded = true;
    state = {'running': false, 'stage': 'finished', 'recording': false, 'session': 's1', 'ended': 'length', 'files': []};
  }

  @override
  Future<dynamic> ingest(Map<String, dynamic> request) async {
    requests.add(request);
    ingestCalls.add(request['action'] as String);
    return switch (request['action']) {
      'apps' => [
        {'id': 'chrome', 'name': 'Chrome', 'pid': 7, 'playing': false},
        {'id': 'spotify', 'name': 'Spotify', 'pid': 42, 'playing': true},
      ],
      'spotifyAlbum' => {
        'id': '6dVIqQ8qmQ5GBnJ9shOYGE',
        'title': 'Album',
        'artist': 'Zespół',
        'date': '2001-02-03',
        'trackCount': 2,
        'tracks': [
          {'title': 'Pierwszy - Remastered', 'artist': 'Zespół', 'durationMs': 60000},
          {'title': 'Drugi', 'artist': 'Zespół', 'durationMs': 90000},
        ],
      },
      'record' => state = {'running': true, 'stage': 'recording', 'recording': true, 'session': 's1', 'step': ''},
      'export' => state = {'running': true, 'stage': 'exporting'},
      'state' => state,
      'sessions' => [
        if (recorded) {'id': 's1', 'label': 'Zespół · Album', 'durationMs': 165000, 'app': 'spotify', 'markers': []},
      ],
      'waveform' => {'rate': 44100, 'frames': 44100 * 165, 'perPoint': 44100, 'peaks': List.filled(330, 0.5)},
      'align' => [61000],
      _ => super.ingest(request),
    };
  }

  @override
  Future<List<ReleaseCandidate>> findReleases(String album, String artist) async => [release];
  @override
  Future<ReleaseInfo> releaseDetails(String id) async => const ReleaseInfo(release, [
    ReleaseSong(title: 'Pierwszy', artist: 'Zespół', discNumber: 1, trackNumber: 1, durationMs: 59000),
    ReleaseSong(title: 'Drugi', artist: 'Zespół', discNumber: 1, trackNumber: 2, durationMs: 91000),
  ]);
  @override
  Future<CoverChoice?> downloadCover(String id) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('app recording: Spotify link, MusicBrainz names, Spotify lengths, cut and saved as MP3 320', () async {
    final repo = AppRecordingRepo();
    final s = IngestState(repository: repo, library: repo, beforeCapture: () async {}, onLibraryChanged: () async {});
    await s.refresh();
    expect(s.app, 'spotify');
    s.spotifyLink.text = 'https://open.spotify.com/album/6dVIqQ8qmQ5GBnJ9shOYGE';
    await s.loadSpotify();
    expect(s.error, isNull);
    expect(s.vinylForm.album.text, 'Album');
    expect([for (final t in s.tracklist!.tracks) t.title], ['Pierwszy', 'Drugi']);
    expect(s.vinylForm.releaseId, AppRecordingRepo.release.id);
    // Lengths are Spotify's: that is what the app plays.
    expect(s.albumMs, 150000);
    // The expected songs can be tweaked before recording: they drive the cuts and tags.
    expect([for (final t in s.appTracks) t.length.text], ['1:00', '1:30']);
    s.appTracks[1].title.text = 'Drugi (wersja)';
    s.appTracks[1].length.text = '1:31';
    expect(s.albumMs, 151000);
    expect(parseClock('1:02:03'), 3723000);
    expect(parseClock('245'), 245000);
    expect(parseClock('4:x'), 0);
    expect(plainAlbumTitle('Queen of Time (Deluxe Edition)'), 'Queen of Time');
    expect(plainAlbumTitle('Abbey Road - Remastered 2019'), 'Abbey Road');
    expect(plainAlbumTitle('Help!'), 'Help!');
    expect(sameName(' Amorphis\u00a0'), sameName('amorphis'));
    expect(soloArtist('Amorphis'), isTrue);
    expect(soloArtist('Amorphis, Hellscore'), isFalse);
    await s.recordApp();
    final record = repo.requests.lastWhere((r) => r['action'] == 'record');
    expect(record['app'], 'spotify');
    expect(record['waitForSound'], isTrue);
    expect(record['maxMs'], 166000);
    // The stage names the song being recorded now, from the lengths.
    s.status = {'running': true, 'recording': true, 'stage': 'recording', 'rate': 44100, 'frames': 0, 'step': 'Czekam na dźwięk z aplikacji. Włącz album od pierwszego utworu.'};
    expect(s.recordStage().waiting, isTrue);
    expect(s.recordStage().title, 'Włącz album w: Spotify');
    s.status = {'running': true, 'recording': true, 'stage': 'recording', 'rate': 44100, 'frames': 44100 * 70, 'step': ''};
    final now = s.recordStage();
    expect(now.kicker, 'Teraz zgrywane');
    expect(now.title, 'Drugi (wersja)');
    expect(now.subtitle, startsWith('Utwór 2 z 2'));
    expect(now.track, closeTo(10000 / 91000, 1e-6));
    expect(now.total, '2:31');
    repo.finishRecording();
    await s.poll();
    for (var i = 0; i < 100 && !repo.requests.any((r) => r['action'] == 'export'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(repo.requests.firstWhere((r) => r['action'] == 'align')['durations'], [60000, 91000]);
    final export = repo.requests.lastWhere((r) => r['action'] == 'export');
    expect(export['mp3Only'], isTrue);
    expect(export['mp3Kbps'], 320);
    expect(export['titles'], ['Pierwszy', 'Drugi (wersja)']);
    expect(export['markers'], [61000]);
    expect(export['endMs'], 61000 + 91000 + 1500);
    expect(export['restore'], {'declick': false, 'speed': 1});
    s.dispose();
  });
  const channel = MethodChannel('pl.mytify/library');
  const events = MethodChannel('pl.mytify/import');
  late Map<String, dynamic> audio;
  late List<Map<String, dynamic>> commands;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    commands = [];
    audio = {
      'available': true,
      'playing': false,
      'completed': false,
      'buffering': false,
      'repeat': false,
      'shuffled': false,
      'queueIds': ['hash'],
      'currentId': 'hash',
      'index': 0,
      'errorSerial': 0,
      'revision': 1,
      'underrunFrames': 0,
      'renderedFrames': 0,
      'volume': 80,
      'positionMs': 1200,
      'durationMs': 60000,
      'selectedDevice': 'auto',
    };
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'audioCommand') {
        final c = Map<String, dynamic>.from(call.arguments as Map);
        commands.add(c);
        if (c['action'] == 'volume') audio = {...audio, 'volume': c['value']};
      }
      return jsonEncode(switch (call.method) {
        'load' => [
          {
            'id': 'hash',
            'title': 'Światło',
            'artist': 'Łódź',
            'album': 'Album',
            'fileName': 'song.flac',
            'format': 'FLAC',
            'durationMs': 60000,
            'sampleRate': 44100,
            'bitDepth': 16,
          },
        ],
        'sources' => [
          {'id': 's1', 'name': 'Muzyka', 'path': r'C:\Muzyka', 'kind': 'folder', 'state': 'online', 'files': 1, 'availableFiles': 1, 'lastScan': 1, 'protocol': 'local'},
        ],
        'audioDevices' => [
          {'id': 'auto', 'name': 'Domyślne urządzenie systemu'},
          {'id': 'dlna:fake', 'name': 'Salon · Yamaha / MusicCast (DLNA)'},
        ],
        'audioState' || 'audioCommand' => audio,
        _ => null,
      });
    });
  });

  Future<LibraryScreenState> start(WidgetTester tester, {Size size = const Size(1440, 900), DesktopRepo? repo}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MytifyApp(repository: repo ?? DesktopRepo()));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    return tester.state<LibraryScreenState>(find.byType(LibraryScreen));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('sources: one sidebar entry, adding lives inside the sources view', (tester) async {
    final app = await start(tester);
    final sidebar = find.byType(Sidebar);
    expect(find.descendant(of: sidebar, matching: find.text('Dodaj źródło')), findsNothing);
    expect(find.descendant(of: sidebar, matching: find.text('Źródła muzyki')), findsOneWidget);
    await tester.tap(find.descendant(of: sidebar, matching: find.text('Źródła muzyki')));
    await settle(tester);
    expect(app.route, const Nav('sources'));
    final add = find.widgetWithText(FilledButton, 'Dodaj źródło');
    expect(add, findsOneWidget);
    await tester.tap(add);
    await settle(tester);
    expect(find.text('Muzyka na urządzeniu'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    // The old settings route lands in the same view.
    app.go(const Nav('settings', 'sources'));
    await settle(tester);
    expect(find.widgetWithText(FilledButton, 'Dodaj źródło'), findsOneWidget);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('right panel hides in settings and import, then comes back', (tester) async {
    final app = await start(tester);
    expect(find.byType(SidePanel), findsOneWidget);
    app.go(const Nav('settings', 'audio'));
    await settle(tester);
    expect(find.byType(SidePanel), findsNothing);
    app.go(const Nav('import'));
    await settle(tester);
    expect(find.byType(SidePanel), findsNothing);
    app.go(Nav.home);
    await settle(tester);
    expect(find.byType(SidePanel), findsOneWidget);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('audio settings: inline output, no modal, opening changes nothing', (tester) async {
    final app = await start(tester);
    app.go(const Nav('settings', 'audio'));
    await settle(tester);
    expect(find.byType(AudioSettingsView), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Wyjście'), findsOneWidget);
    expect(find.text('Urządzenie odtwarzania'), findsOneWidget);
    expect(find.text('Diagnostyka dźwięku'), findsOneWidget);
    expect(find.text('Protokoły i zgodność'), findsOneWidget);
    expect(commands.where((c) => c['action'] == 'device' || c['action'] == 'volume'), isEmpty);
    // Mute from settings is the same state the player bar shows.
    await tester.tap(find.descendant(of: find.byType(AudioSettingsView), matching: find.byTooltip('Wycisz')));
    await settle(tester);
    expect(app.volume, 0);
    expect(find.descendant(of: find.byType(PlayerBar), matching: find.byTooltip('Przywróć dźwięk')), findsWidgets);
    expect(commands.last['action'], 'volume');
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('receiver volume stays disabled until actually read, with no command on open', (tester) async {
    audio = {
      ...audio,
      'selectedDevice': 'dlna:fake',
      'volumeAvailable': false,
      'output': {'name': 'Yamaha', 'backend': 'DLNA', 'sampleRate': 0, 'sampleFormat': 'FLAC', 'channels': 2},
    };
    final app = await start(tester);
    app.go(const Nav('settings', 'audio'));
    await settle(tester);
    Slider slider() => tester.widget<Slider>(find.descendant(of: find.byType(AudioSettingsView), matching: find.byType(Slider)));
    expect(slider().onChanged, isNull);
    audio = {...audio, 'volumeAvailable': true, 'volume': 33};
    await settle(tester);
    expect(slider().value, 33);
    expect(slider().onChanged, isNotNull);
    expect(commands.where((c) => c['action'] == 'device' || c['action'] == 'volume'), isEmpty);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('import opens in the normal layout without starting anything', (tester) async {
    final repo = DesktopRepo();
    final app = await start(tester, repo: repo);
    app.go(const Nav('settings', 'audio'));
    await settle(tester);
    await tester.tap(find.text('Importuj muzykę').first);
    await settle(tester);
    expect(app.route, const Nav('import'));
    expect(find.byType(IngestView), findsOneWidget);
    expect(find.byType(Sidebar), findsOneWidget);
    expect(find.byType(PlayerBar), findsOneWidget);
    expect(find.text('Nie wykryto napędu'), findsOneWidget);
    expect(repo.ingestCalls.toSet().difference({'drives', 'inputs', 'apps', 'sessions', 'state', 'folders', 'media'}), isEmpty);
    expect(commands.where((c) => c['action'] == 'pause'), isEmpty);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('mini player floats and comes back to the full app', (tester) async {
    final repo = DesktopRepo();
    await start(tester, repo: repo);
    await tester.tap(find.byTooltip('Mini odtwarzacz (Ctrl+M)'));
    await settle(tester);
    expect(repo.windowCalls.last, {'action': 'mode', 'mode': 'mini'});
    expect(find.byType(FloatingPlayer), findsOneWidget);
    expect(find.byType(Sidebar), findsNothing);
    expect(find.text('Światło'), findsOneWidget);
    await tester.tap(find.byTooltip('Pełna aplikacja (dwuklik)'));
    await settle(tester);
    expect(repo.windowCalls.last, {'action': 'mode', 'mode': 'normal'});
    expect(find.byType(Sidebar), findsOneWidget);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('visualization goes full screen and Esc restores the window', (tester) async {
    final repo = DesktopRepo();
    await start(tester, repo: repo);
    await tester.tap(find.byTooltip('Wizualizacja (Ctrl+Shift+V)'));
    await settle(tester);
    expect(find.byType(VisualizerScreen), findsOneWidget);
    expect(repo.windowCalls.last, {'action': 'mode', 'mode': 'fullscreen'});
    expect(find.text('Plazma'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(find.text('Wstęgi'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await settle(tester);
    expect(find.byType(VisualizerScreen), findsNothing);
    expect(repo.windowCalls.last, {'action': 'mode', 'mode': 'normal'});
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
