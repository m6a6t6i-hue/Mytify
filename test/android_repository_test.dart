import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytify/repository_android.dart';
import 'package:mytify/model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pl.mytify/library');
  const events = MethodChannel('pl.mytify/import');
  final calls = <MethodCall>[];
  late AndroidLibraryRepository repo;
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return jsonEncode(switch (call.method) {
            'load' => [
              {'id': 'hash', 'title': 'Łódź', 'artist': 'Żółw', 'liked': true},
            ],
            'import' => {'added': 2, 'duplicates': 1, 'cancelled': false},
            'rescan' => {'cancelled': true},
            'audioState' || 'audioCommand' => {
              'available': true,
              'playing': true,
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
              'durationMs': 4000,
              'selectedDevice': 'auto',
            },
            _ => null,
          });
        });
    repo = AndroidLibraryRepository();
  });
  tearDown(() async {
    await repo.dispose();
  });
  test('Completed background downloads notify the library', () async {
    final changed = expectLater(repo.changes, emits(null));
    ServicesBinding.instance.channelBuffers.push(
      'pl.mytify/library',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('libraryChanged'),
      ),
      (_) {},
    );
    await changed;
  });
  test('UTF8 metadata and likes', () async {
    expect((await repo.load()).single.title, 'Łódź');
    expect((await repo.load()).single.liked, true);
    expect(await repo.searchIds('lodz zolw'), ['hash']);
  });
  test('import and cancellation native reports', () async {
    final r = await repo.importAudio(folder: true, onProgress: (_) {});
    expect(r.added, 2);
    expect(r.duplicates, 1);
    expect(calls.last.arguments, {'folder': true});
    expect(
      (await repo.rescan(sourceId: 'folder', onProgress: (_) {})).cancelled,
      true,
    );
    expect(calls.last.arguments, {'id': 'folder'});
  });
  test('Media3 queue and seek state', () async {
    final s = await repo.audioCommand({'action': 'seek', 'positionMs': 1200});
    expect(s.queueIds, ['hash']);
    expect(s.position, const Duration(milliseconds: 1200));
    expect(calls.last.arguments, {'action': 'seek', 'positionMs': 1200});
  });
  test('metadata patch serialized without paths', () async {
    await repo.editMetadata([
      const MetadataEdit('hash', {'title': 'Nowy'}),
    ]);
    expect(jsonDecode(calls.last.arguments as String), [
      {
        'id': 'hash',
        'patch': {'title': 'Nowy'},
      },
    ]);
  });
}
