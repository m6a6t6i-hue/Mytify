// Visual review screenshots. Run with SCREENSHOTS=1 flutter test --update-goldens test/screenshots_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mytify/audio_player.dart';
import 'package:mytify/ingest.dart';
import 'package:mytify/intro.dart';
import 'package:mytify/main.dart';
import 'package:mytify/repository_android.dart';
import 'package:mytify/visualizer.dart';
import 'package:mytify/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

const covers = [
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAATUlEQVR4nGN4EctyO5z7fKDQYW+pba6Kq+w051kYTDK2YMAq2qprz4BVtFLNjQGraK6iHwNW0QTpUAasoiGisQxYRT34Uhiwitpw5gAAP6w+9grXS1sAAAAASUVORK5CYII=',
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAATUlEQVR4nGNgmHacoW8vQ/sWhobVDBWLGApnMmRNYExuZ8Aqyhhdy4BVlDGkhAGrKKNvNgNWUUbXJAasoox2kQxYRRnNAxiwijIZuAMACo06cGT7cYIAAAAASUVORK5CYII=',
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAS0lEQVR4nG3IIQqAUBBF0Tvj2gWDYBAMBsEgGASDwcXNzNcNvBMP39u1x9vt7fI6vQ6r3Woz5OZqyM3FkJszyI0J5MYIcmMAudHzA/5yZsyySyqLAAAAAElFTkSuQmCC',
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAATElEQVR4nGPImumXPNEzttM1vNExsNLWq9DCJdPELtGAAauoRaQOA1ZRo0ANBqyi2p7KDFhFVR3lGbCKyltKM2AVlTQUZ8AqKqwlDADh2DPERHhEQwAAAABJRU5ErkJggg==',
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAATUlEQVR4nGN4755/37v4fEDF/tDa9VFN8+Pa+pO7GzImMGAVLcidyoBVNKFoFgNW0YCyeQxYRR2qFzNgFTVoWMGAVVShdS0DVlHBrk0Ak5Vd6Mrfu5oAAAAASUVORK5CYII=',
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAATklEQVR4nGPQ0DAwNra2s3P38goKDY1LTMzMySmtqGhkwCra3NzDgFW0r28GA1bRWbMWM2AVXbp0PQNW0Y0bdzFgFd2z5xgDVtETJy4BAPhYW/AQ3TYXAAAAAElFTkSuQmCC',
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAATUlEQVR4nGNotnhTa/KswvBhsd6dPO3rGRoXk1XPxCkdZ8AqGil3iAGraIj0Xgason4S2xmwinqKbmLAKuoitJYBq6g9/woGrKJWPIsBv2lRqDSutLoAAAAASUVORK5CYII=',
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAATUlEQVR4nGP4z5D3jy3tH0/8P6HwvxIBf+U8/6o4/tW2YsAq+sfQmAGr6B9zbQason9sVRiwiv52lmXAKvrbU5QBq+hvfz4GrKK/w9gB53RYTG198+AAAAAASUVORK5CYII=',
];

final albums = [
  ('Cathedral of Dawn', 'Everything Will Echo', 0, ['The last sunset over us', 'Where the pines remember', 'The weight of the river', 'Sunlight on stone', 'Cathedral of dawn', 'Quiet harbour']),
  ('Nocne pociągi', 'Łódź Ensemble', 1, ['Peron 4', 'Światło nad torami', 'Wagon restauracyjny', 'Ostatni przystanek']),
  ('Glass Animals Live', 'Northern Shore', 2, ['Opening', 'Heat Waves', 'Gooey']),
  ('Field Recordings', 'Mira Holt', 3, ['Morning', 'Rain on tin', 'Birch forest', 'Night insects', 'Thunder']),
  ('Kwadrans', 'Zespół Ciszy', 4, ['Pierwszy', 'Drugi', 'Trzeci']),
  ('Monochrome', 'Atlas Lane', 5, ['Grey', 'Silver', 'Black', 'White']),
  ('Violet Hour', 'Neon Saints', 6, ['Violet', 'Hour', 'After']),
  ('Signal Fire', 'Coastline', 7, ['Signal', 'Fire', 'Smoke', 'Ash']),
];

List<Map<String, dynamic>> library() {
  final out = <Map<String, dynamic>>[];
  var n = 0;
  for (final (album, artist, c, titles) in albums) {
    for (var i = 0; i < titles.length; i++) {
      n++;
      out.add({
        'id': n.toRadixString(16).padLeft(64, '0'),
        'title': titles[i],
        'artist': artist,
        'albumArtist': artist,
        'album': album,
        'fileName': '${titles[i]}.flac',
        'format': c.isEven ? 'flac' : 'mp3',
        'size': 30000000,
        'durationMs': 150000 + i * 23000,
        'trackNumber': i + 1,
        'discNumber': 1,
        'sampleRate': c.isEven ? 96000 : 44100,
        'bitDepth': c.isEven ? 24 : 0,
        'addedAt': 1700000000000 + c * 1000000,
        'cover': covers[c],
        'liked': i % 3 == 0,
      });
    }
  }
  return out;
}

Future<void> loadFonts() async {
  var dir = File(Platform.resolvedExecutable).parent;
  Directory? fonts;
  for (var i = 0; i < 8 && fonts == null; i++) {
    final candidate = Directory('${dir.path}/material_fonts');
    final cache = Directory('${dir.path}/bin/cache/artifacts/material_fonts');
    if (candidate.existsSync()) fonts = candidate;
    if (cache.existsSync()) fonts = cache;
    dir = dir.parent;
  }
  final root = Platform.environment['FLUTTER_ROOT'];
  if (fonts == null && root != null) fonts = Directory('$root/bin/cache/artifacts/material_fonts');
  if (fonts == null || !fonts.existsSync()) return;
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      final file = File('${fonts!.path}/$f');
      if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }
  await family('Arial', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto-Black.ttf']);
  await family('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

/// PC-like repository for screenshots: digitization and real-looking levels come from fixtures.
class ShotRepo extends AndroidLibraryRepository implements IngestRepository {
  List<dynamic> drives = [];
  List<dynamic> inputs = [];
  Map<String, dynamic> state = {'running': false, 'stage': ''};
  @override
  bool get hasAudioLevels => true;
  @override
  bool get hasWindow => true;
  @override
  Future<void> windowAction(Map<String, dynamic> action) async {}
  @override
  Future<List<double>?> audioLevels() async => shotBands;
  @override
  Future<dynamic> ingest(Map<String, dynamic> r) async => switch (r['action']) {
    'drives' => drives,
    'inputs' => inputs,
    'sessions' => [],
    'state' => state,
    'folders' => {'recordings': r'C:\Users\mat\AppData\Local\Mytify\recordings', 'cd': r'C:\Users\mat\AppData\Local\Mytify\cd-imports'},
    'toc' => {
      'discId': 'shot',
      'tracks': [for (var i = 0; i < 9; i++) {'number': i + 1, 'start': i * 75 * 230, 'end': (i + 1) * 75 * 230 - 75 * (i * 7 % 40)}],
    },
    _ => {},
  };
}

/// Fixed spectrum shaped like music (dBFS per band), only for screenshots.
final shotBands = [for (var i = 0; i < 40; i++) -18.0 - 14 * (i / 40) + 9 * (i % 7 == 2 ? 1 : 0) - 6 * ((i * 5) % 3)];

void main() {
  final enabled = Platform.environment['SCREENSHOTS'] == '1';
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pl.mytify/library');
  const events = MethodChannel('pl.mytify/import');
  final tracks = library();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(events, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => jsonEncode(switch (call.method) {
        'load' => tracks,
        'sources' => [
          {'id': 's1', 'name': 'Muzyka', 'path': '/storage/Muzyka', 'kind': 'folder', 'state': 'online', 'files': 24, 'availableFiles': 24, 'lastScan': 1, 'protocol': 'local'},
          {'id': 's2', 'name': 'Jazz na NAS', 'path': r'\\nas\music\Jazz', 'kind': 'smb', 'state': 'offline', 'files': 1840, 'availableFiles': 0, 'lastScan': 1, 'protocol': 'smb', 'address': r'\\nas\music\Jazz'},
        ],
        'networkProtocols' => ['smb'],
        'sourceSettings' => {'protocol': 'smb', 'name': 'Jazz na NAS', 'host': 'nas', 'share': 'music', 'folder': 'Jazz', 'user': 'mat', 'domain': '', 'hasPassword': true},
        'playlists' => [
          {'id': 'p1', 'name': 'Na drogę', 'ids': [for (final t in tracks.take(9)) t['id']]},
          {'id': 'p2', 'name': 'Wieczór', 'ids': [for (final t in tracks.skip(10).take(7)) t['id']]},
        ],
        'audioDevices' => [
          {'id': 'auto', 'name': 'Domyślne urządzenie systemu'},
          {'id': 'dlna:uuid-1', 'name': 'Salon · Yamaha / MusicCast (DLNA)'},
          {'id': 'airplay:abc', 'name': 'Kuchnia · AirPlay 2'},
        ],
        'audioState' || 'audioCommand' => {
          'available': true,
          'playing': true,
          'completed': false,
          'buffering': false,
          'repeat': false,
          'shuffled': false,
          'queueIds': [for (final t in tracks.take(6)) t['id']],
          'currentId': tracks.first['id'],
          'index': 0,
          'errorSerial': 0,
          'revision': 1,
          'underrunFrames': 0,
          'renderedFrames': 0,
          'volume': 70,
          'positionMs': 71000,
          'durationMs': 208000,
          'selectedDevice': 'auto',
        },
        _ => null,
      }),
    );
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        await precacheImage((e.widget as Image).image, e);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
  }

  Future<void> open(WidgetTester tester, Size size) async {
    await loadFonts();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MytifyApp(repository: AndroidLibraryRepository()));
    await settle(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('mobile screens', (tester) async {
    await open(tester, const Size(390, 844));
    await shot(tester, 'm1_home');
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await shot(tester, 'm2_home_scrolled');
    await tester.tap(find.text('Biblioteka').last);
    await settle(tester);
    await tester.tap(find.text('Albumy').first);
    await shot(tester, 'm3_library_albums');
    await tester.tap(find.text('Signal Fire').first);
    await shot(tester, 'm4_album');
    await tester.tap(find.text('Szukaj').last);
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'sun');
    await shot(tester, 'm5_search');
    await tester.tap(find.text('Start').last);
    await settle(tester);
    await tester.tap(find.byTooltip('Połącz z urządzeniem').first);
    await shot(tester, 'm7_devices');
    await tester.tapAt(const Offset(20, 20));
    await settle(tester);
    await tester.tap(find.text('The last sunset over us').first);
    await shot(tester, 'm6_now_playing');
    await tester.tap(find.byTooltip('Zamknij').evaluate().isEmpty ? find.byIcon(Icons.keyboard_arrow_down_rounded).first : find.byTooltip('Zamknij').first);
    await settle(tester);
    await tester.tap(find.text('Biblioteka').last);
    await settle(tester);
    // Second tap returns the tab to its root page, where the plus lives.
    await tester.tap(find.text('Biblioteka').last);
    await settle(tester);
    await tester.tap(find.byTooltip('Dodaj źródło'));
    await shot(tester, 'm8_add_source');
    await tester.tap(find.text('Folder sieciowy SMB'));
    await shot(tester, 'm9_smb_form');
    await close(tester);
  }, skip: !enabled, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final size in [const Size(1440, 900), const Size(1024, 700)]) {
    testWidgets('desktop screens ${size.width.round()}', (tester) async {
      final w = size.width.round();
      await open(tester, size);
      await shot(tester, 'd${w}_1_home');
      await tester.tap(find.byTooltip('Albumy').evaluate().isEmpty ? find.text('Albumy').first : find.byTooltip('Albumy'));
      await shot(tester, 'd${w}_4_albums');
      await tester.tap(find.text('Signal Fire').first);
      await shot(tester, 'd${w}_2_album');
      await tester.tap(find.byTooltip('Utwory').evaluate().isEmpty ? find.text('Utwory').first : find.byTooltip('Utwory'));
      await shot(tester, 'd${w}_3_tracks');
      await tester.tap(find.byTooltip('Kolejka'));
      await shot(tester, 'd${w}_5_queue');
      await tester.tap(find.byTooltip('Połącz z urządzeniem').last);
      await shot(tester, 'd${w}_6_devices');
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      await tester.tap(find.byTooltip('Ustawienia (Ctrl+,)'));
      await shot(tester, 'd${w}_7_settings');
      await tester.tap(find.text('Źródła muzyki').first);
      await settle(tester);
      await tester.tap(find.byTooltip('Opcje źródła').last);
      await settle(tester);
      await tester.tap(find.text('Edytuj połączenie'));
      await shot(tester, 'd${w}_8_smb_edit');
      await close(tester);
    }, skip: !enabled, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  for (final (size, ratio) in [
    for (final size in [const Size(1366, 768), const Size(1920, 1080)])
      for (final ratio in [1.0, 1.25, 1.5, 2.0]) (size, ratio),
  ]) {
    final tag = 'p${size.width.round()}_${(ratio * 100).round()}';
    testWidgets('panels $tag', (tester) async {
      await loadFonts();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = ratio;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = ShotRepo();
      await tester.pumpWidget(MytifyApp(repository: repo));
      await settle(tester);
      final app = tester.state<LibraryScreenState>(find.byType(LibraryScreen));
      await shot(tester, '${tag}_1_playing');
      app.go(const Nav('sources'));
      await shot(tester, '${tag}_2_sources');
      app.go(const Nav('settings', 'audio'));
      await settle(tester);
      if (find.text('Diagnostyka dźwięku').evaluate().isNotEmpty) {
        await tester.tap(find.text('Diagnostyka dźwięku'));
      }
      await shot(tester, '${tag}_3_audio');
      app.go(const Nav('import'));
      await shot(tester, '${tag}_4_cd_none');
      repo.drives = [
        {'id': 'E:', 'name': 'ASUS SDRW-08U9M-U'},
      ];
      unawaited(app.ingest.refresh().then((_) => app.ingest.readCd()));
      await shot(tester, '${tag}_5_cd_tracks');
      repo.inputs = [
        {'id': 'usb', 'name': 'Mikrofon (USB Audio CODEC)', 'rates': [44100, 48000, 96000], 'channels': 2},
      ];
      app.ingest.setTab(1);
      // Level check state as the engine reports it; the fixture does not pause playback.
      repo.state = {'running': true, 'stage': 'monitor', 'channels': 2, 'peaks': [0.32, 0.27], 'clips': 0, 'dropouts': 0, 'rate': 48000};
      unawaited(app.ingest.refresh());
      await shot(tester, '${tag}_6_vinyl');
      await close(tester);
    }, skip: !enabled, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets('mini player', (tester) async {
    await loadFonts();
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MytifyApp(repository: ShotRepo()));
    await settle(tester);
    final app = tester.state<LibraryScreenState>(find.byType(LibraryScreen));
    for (final (mode, size) in [('mini', const Size(244, 82)), ('nano', const Size(196, 44))]) {
      for (final ratio in [1.0, 2.0]) {
        app.setFloating(mode);
        tester.view.physicalSize = size * ratio;
        tester.view.devicePixelRatio = ratio;
        await shot(tester, 'mini_${mode}_${(ratio * 100).round()}');
      }
    }
    app.setFloating(null);
    await close(tester);
  }, skip: !enabled, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  for (final (name, size, ratio, platform) in [
    ('pc', const Size(1920, 1080), 1.0, TargetPlatform.windows),
    ('phone', const Size(1080, 2400), 2.75, TargetPlatform.android),
  ]) {
    testWidgets('visualizer $name', (tester) async {
      await loadFonts();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = ratio;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MytifyApp(repository: ShotRepo()));
      await settle(tester);
      final app = tester.state<LibraryScreenState>(find.byType(LibraryScreen));
      app.openVisualizer();
      // Shader programs load asynchronously.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      for (var i = 0; i < visualizerScenes.length; i++) {
        for (var k = 0; k < 30; k++) {
          await tester.pump(const Duration(milliseconds: 33));
        }
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/viz_${name}_${i}_${visualizerScenes[i]}.png'));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await close(tester);
    }, skip: !enabled, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets('intro frames', (tester) async {
    await loadFonts();
    for (final (name, size) in [('i_phone', const Size(390, 844)), ('i_pc', const Size(960, 630))]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      for (final ms in [120, 450, 700, 1000]) {
        await tester.pumpWidget(
          MaterialApp(home: CustomPaint(painter: IntroPainter(ms.toDouble()), size: Size.infinite)),
        );
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$ms.png'));
      }
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }, skip: !enabled);

  testWidgets('seek bar playing and paused', (tester) async {
    await loadFonts();
    LevelFeed.current = LevelFeed(() async => shotBands);
    tester.view.physicalSize = const Size(840, 220);
    tester.view.devicePixelRatio = 2;
    Widget bar(bool playing) => MaterialApp(
      theme: mytifyTheme(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SeekBar(
            position: const Duration(seconds: 84),
            duration: const Duration(seconds: 162),
            playing: playing,
            seed: 7,
            onSeek: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(bar(true));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/w_seek_playing.png'));
    await tester.pumpWidget(bar(false));
    await tester.pump(const Duration(milliseconds: 200));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/w_seek_fading.png'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/w_seek_paused.png'));
    await tester.pumpWidget(const SizedBox());
    LevelFeed.current = null;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }, skip: !enabled);
}
