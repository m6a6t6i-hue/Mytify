import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mytify/audio_settings.dart';
import 'package:mytify/ingest.dart';
import 'package:mytify/main.dart';
import 'package:mytify/player_ui.dart';
import 'package:mytify/repository_android.dart';
import 'package:mytify/shell_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Android method channel stands in for the PC engine; ingest answers like a PC with no drive.
class DesktopRepo extends AndroidLibraryRepository implements IngestRepository {
  final ingestCalls = <String>[];
  @override
  Future<dynamic> ingest(Map<String, dynamic> request) async {
    ingestCalls.add(request['action'] as String);
    return switch (request['action']) {
      'drives' || 'inputs' || 'sessions' => [],
      'state' => {'running': false, 'stage': ''},
      'folders' => {'recordings': r'C:\dane\recordings', 'cd': r'C:\dane\cd-imports'},
      _ => {},
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
    await tester.tap(find.text('Import').first);
    await settle(tester);
    expect(app.route, const Nav('import'));
    expect(find.byType(IngestView), findsOneWidget);
    expect(find.byType(Sidebar), findsOneWidget);
    expect(find.byType(PlayerBar), findsOneWidget);
    expect(find.text('Nie wykryto napędu'), findsOneWidget);
    expect(repo.ingestCalls.toSet().difference({'drives', 'inputs', 'sessions', 'state', 'folders'}), isEmpty);
    expect(commands.where((c) => c['action'] == 'pause'), isEmpty);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
