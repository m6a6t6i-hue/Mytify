import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mytify/library_index.dart';
import 'package:mytify/main.dart';
import 'package:mytify/model.dart';
import 'package:mytify/repository_android.dart';
import 'package:mytify/views.dart';
import 'package:shared_preferences/shared_preferences.dart';

const size = 20000;

Map<String, dynamic> raw(int i) => {
  'id': i.toRadixString(16).padLeft(64, '0'),
  'title': 'Utwór $i ${['Światło', 'Rzeka', 'Noc', 'Łąka'][i % 4]}',
  'artist': 'Wykonawca ${(i ~/ 12) % 700}',
  'albumArtist': 'Wykonawca ${(i ~/ 12) % 700}',
  'album': 'Album ${i ~/ 12}',
  'fileName': 'track$i.flac',
  'format': i.isEven ? 'flac' : 'mp3',
  'size': 9000000,
  'durationMs': 120000 + i % 200000,
  'trackNumber': i % 12 + 1,
  'discNumber': 1,
  'sampleRate': 44100,
  'bitDepth': 16,
  'addedAt': 1700000000000 + i * 1000,
  'cover': null,
  'liked': i % 9 == 0,
};

void main() {
  test('Index, search and sort keys stay fast with $size tracks', () {
    final tracks = List.generate(size, (i) => Track.fromJson(raw(i)));
    final watch = Stopwatch()..start();
    final index = LibraryIndex.build(tracks);
    final build = watch.elapsedMilliseconds;
    watch.reset();
    final first = index.searchTracks('rzeka 1');
    final firstSearch = watch.elapsedMilliseconds;
    watch.reset();
    final again = index.searchTracks('swiatlo wykonawca 12');
    final search = watch.elapsedMilliseconds;
    watch.reset();
    final sorted = List.of(tracks)
      ..sort((a, b) => index.titleKey[a.id]!.compareTo(index.titleKey[b.id]!));
    final sort = watch.elapsedMilliseconds;
    debugPrint('index $build ms, first search $firstSearch ms, search $search ms, sort $sort ms');
    expect(index.albums.length, (size / 12).ceil());
    expect(first, isNotEmpty);
    expect(again, isNotEmpty);
    expect(sorted.length, size);
    // Generous limits for debug-mode CI runners; real builds are AOT-compiled.
    expect(build, lessThan(3000));
    expect(search, lessThan(400));
    expect(sort, lessThan(1500));
  });

  testWidgets('Track table renders only visible rows with $size tracks', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final tracks = [for (var i = 0; i < size; i++) raw(i)];
    final encoded = jsonEncode(tracks);
    const channel = MethodChannel('pl.mytify/library');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('pl.mytify/import'),
      (_) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => switch (call.method) {
        'load' => encoded,
        'sources' || 'playlists' || 'audioDevices' => '[]',
        _ => 'null',
      },
    );
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MytifyApp(repository: AndroidLibraryRepository()));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.tap(find.text('Utwory').first);
    await tester.pumpAndSettle();
    final rows = find.byType(TrackRow).evaluate().length;
    expect(rows, greaterThan(5));
    expect(rows, lessThan(80), reason: 'list must be lazy');
    final watch = Stopwatch()..start();
    for (var i = 0; i < 10; i++) {
      await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -3000));
      await tester.pump();
    }
    debugPrint('10 large scroll steps: ${watch.elapsedMilliseconds} ms');
    await tester.tap(find.text('Tytuł').first);
    await tester.pumpAndSettle();
    expect(find.byType(TrackRow).evaluate().length, lessThan(80));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
