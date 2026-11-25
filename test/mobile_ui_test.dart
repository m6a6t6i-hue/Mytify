import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytify/main.dart';
import 'package:mytify/player_ui.dart';
import 'package:mytify/shell_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mytify/repository_android.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pl.mytify/library');
  const events = MethodChannel('pl.mytify/import');
  var trackTitle = 'Światło';
  var trackArtist = 'Łódź';
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    trackTitle = 'Światło';
    trackArtist = 'Łódź';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => jsonEncode(switch (call.method) {
            'load' => [
              {
                'id': 'hash',
                'title': trackTitle,
                'artist': trackArtist,
                'album': 'Album',
                'fileName': 'song.flac',
                'format': 'FLAC',
                'durationMs': 60000,
                'sampleRate': 44100,
                'bitDepth': 16,
                'liked': true,
              },
            ],
            'sources' => [],
            'audioState' || 'audioCommand' => {
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
            },
            _ => null,
          }),
        );
  });
  Future<void> start(WidgetTester tester, Size size, {double text = 1}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = text;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(MytifyApp(repository: AndroidLibraryRepository()));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  for (final fixture in [
    (const Size(320, 700), 1.0),
    (const Size(360, 800), 1.3),
    (const Size(412, 915), 1.3),
  ]) {
    testWidgets(
      'Home player is fully visible without scrolling ${fixture.$1} text ${fixture.$2}',
      (tester) async {
        trackTitle = 'Cathedral of dawn over the quiet river';
        trackArtist = 'Everything will echo';
        await start(tester, fixture.$1, text: fixture.$2);
        final player = find.byType(HomePlayer);
        expect(player, findsOneWidget);
        final bounds = tester.getRect(player);
        expect(bounds.bottom, lessThanOrEqualTo(tester.getRect(find.byType(NavigationBar)).top));
        expect(find.descendant(of: player, matching: find.byTooltip('Odtwórz')).hitTestable(), findsOneWidget);
        expect(find.descendant(of: player, matching: find.byTooltip('Losowa kolejność')).hitTestable(), findsOneWidget);
        expect(find.byType(MiniPlayer), findsNothing, reason: 'never both players at once');
        expect(find.text('Gotowe do słuchania'), findsNothing);
        expect(find.text('Twoja muzyka.'), findsNothing);
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets('Mini-player replaces the home player after scrolling', (tester) async {
    await start(tester, const Size(360, 480));
    expect(find.byType(MiniPlayer), findsNothing);
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.byType(MiniPlayer), findsOneWidget);
    await tester.tap(find.text('Start').last);
    await tester.pumpAndSettle();
    expect(find.byType(MiniPlayer), findsNothing);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final size in [const Size(360, 800), const Size(320, 700), const Size(780, 360)]) {
    testWidgets('Three-tab navigation and full player ${size.width}x${size.height}', (tester) async {
      await start(tester, size);
      expect(find.text('Szukaj'), findsWidgets);
      expect(find.text('Źródła'), findsNothing);
      expect(find.text('Dodaj'), findsNothing);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Biblioteka').last);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.tap(find.text('Szukaj').last);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.tap(find.text('Biblioteka').last);
      await tester.pumpAndSettle();
      expect(find.text('Albumy'), findsWidgets);
      expect(find.text('Polubione'), findsWidgets);
      await tester.tap(find.byTooltip('Dodaj muzykę'));
      await tester.pumpAndSettle();
      expect(find.text('Muzyka na urządzeniu'), findsOneWidget);
      expect(find.text('Importuj Audio CD'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Światło').first);
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingScreen), findsOneWidget);
      expect(find.byTooltip('Poprzedni utwór'), findsOneWidget);
      expect(find.byTooltip('Losowa kolejność'), findsOneWidget);
      expect(find.byTooltip('Powtarzaj kolejkę'), findsOneWidget);
      await finish(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('Search finds tracks as you type', (tester) async {
    await start(tester, const Size(390, 844));
    await tester.tap(find.text('Szukaj').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'swiat');
    await tester.pumpAndSettle();
    expect(find.text('Najlepszy wynik'), findsOneWidget);
    expect(find.text('Światło'), findsWidgets);
    await tester.enterText(find.byType(TextField).first, 'zzzz');
    await tester.pumpAndSettle();
    expect(find.textContaining('Nic nie pasuje'), findsOneWidget);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final size in [const Size(1440, 900), const Size(1000, 700), const Size(860, 600)]) {
    testWidgets('Desktop layout ${size.width}x${size.height}', (tester) async {
      await start(tester, size);
      expect(find.byType(Sidebar), findsOneWidget);
      expect(find.byType(PlayerBar), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.byTooltip('Albumy').evaluate().isEmpty ? find.text('Albumy').first : find.byTooltip('Albumy'));
      await tester.pumpAndSettle();
      expect(find.text('Album'), findsWidgets);
      await tester.tap(find.byTooltip('Wstecz (Alt+←)'));
      await tester.pumpAndSettle();
      expect(find.text('Ostatnio dodane'), findsWidgets);
      await finish(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }
}
