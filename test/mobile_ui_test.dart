import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytify/main.dart';
import 'package:mytify/now_playing.dart';
import 'package:mytify/playback_card.dart';
import 'package:mytify/repository_android.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pl.mytify/library');
  const events = MethodChannel('pl.mytify/import');
  var trackTitle = 'Światło';
  var trackArtist = 'Łódź';
  setUp(() {
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
  testWidgets('Rapid navigation keeps the home feed and player usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MytifyApp(repository: AndroidLibraryRepository()));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Dodaj').last);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.tap(find.text('Start').last);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.byType(PlaybackCard), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final fixture in [
    (const Size(320, 700), 1.0),
    (const Size(360, 800), 1.3),
    (const Size(412, 915), 1.3),
  ]) {
    testWidgets(
      'Home player is fully visible above library ${fixture.$1} text ${fixture.$2}',
      (tester) async {
        trackTitle = 'Cathedral of dawn';
        trackArtist = 'Everything will echo';
        tester.view.physicalSize = fixture.$1;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = fixture.$2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          MytifyApp(repository: AndroidLibraryRepository()),
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        final card = find.byType(PlaybackCard);
        final cardBounds = tester.getRect(card);
        expect(
          cardBounds.top,
          greaterThanOrEqualTo(
            tester.getRect(find.byType(TextField).first).bottom,
          ),
        );
        expect(
          cardBounds.bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(NavigationBar)).top),
        );
        expect(
          find
              .descendant(of: card, matching: find.byType(Slider))
              .hitTestable(),
          findsOneWidget,
        );
        expect(
          find
              .descendant(of: card, matching: find.byTooltip('Odtwórz'))
              .hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'Tapping Start brings the player back to the top after browsing',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MytifyApp(repository: AndroidLibraryRepository()),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final before = tester.getTopLeft(find.byType(PlaybackCard)).dy;
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackCard).hitTestable(), findsNothing);
      await tester.tap(find.text('Start').last);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byType(PlaybackCard)).dy,
        closeTo(before, 1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final size in [
    const Size(360, 800),
    const Size(320, 700),
    const Size(780, 360),
  ]) {
    testWidgets('Mobile navigation and player ${size.width}x${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MytifyApp(repository: AndroidLibraryRepository()),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Dodaj').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Wybierz folder'), findsOneWidget);
      expect(find.text('Przenieś bibliotekę z wersji 0.1'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Światło').last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(NowPlaying), findsOneWidget);
      expect(find.byTooltip('Poprzedni utwór'), findsOneWidget);
      expect(find.byTooltip('Losowa kolejność'), findsOneWidget);
      expect(find.byTooltip('Powtarzaj kolejkę'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
