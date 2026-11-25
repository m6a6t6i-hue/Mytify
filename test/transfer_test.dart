import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytify/transfer.dart';

class TransferFake implements TransferRepository {
  @override
  final bool receivesTransfers;
  final calls = <Map<String, dynamic>>[];
  Map<String, dynamic> state;
  TransferFake(this.receivesTransfers)
    : state = receivesTransfers
          ? {
              'state': 'idle',
              'peers': [
                {'id': 'pc', 'name': 'Mój PC', 'host': '192.168.1.3'},
              ],
            }
          : {
              'enabled': false,
              'peers': [],
              'addresses': ['192.168.1.3'],
            };
  @override
  Future<dynamic> transfer(Map<String, dynamic> request) async {
    calls.add(request);
    switch (request['action']) {
      case 'start':
        state = {
          'enabled': true,
          'port': 47479,
          'qr': base64Encode(File('test/fixtures/cover.png').readAsBytesSync()),
          'pairUri': 'mytify://pair?v=1&host=192.168.1.3',
          'addresses': ['192.168.1.3'],
          'peers': [
            {'id': 'phone', 'name': 'Telefon'},
          ],
        };
      case 'stop':
        state = {
          'enabled': false,
          'peers': [],
          'addresses': ['192.168.1.3'],
        };
      case 'manifest':
        return {
          'tracks': [
            {
              'id': 'track',
              'title': 'Światło',
              'artist': 'Łódź',
              'album': 'Moja płyta',
              'albumArtist': 'Łódź',
              'fileName': 'song.flac',
              'format': 'FLAC',
              'size': 1048576,
            },
          ],
          'playlists': [
            {
              'id': 'list',
              'name': 'W drodze',
              'ids': ['track'],
            },
          ],
        };
      case 'startDownload':
        state = {
          ...state,
          'state': 'downloading',
          'total': 1,
          'done': 0,
          'totalBytes': 1048576,
          'doneBytes': 0,
        };
      case 'resume':
        state = {...state, 'state': 'downloading'};
      case 'pause':
        state = {...state, 'state': 'paused'};
    }
    return state;
  }
}

void main() {
  testWidgets('PC pairing is opt-in, QR renders, and access can be stopped', (
    tester,
  ) async {
    final repo = TransferFake(false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransferScreen(repository: repo, onLibraryChanged: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(repo.calls.where((c) => c['action'] == 'start'), isEmpty);
    await tester.tap(find.text('Włącz parowanie'));
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel('Kod QR do sparowania telefonu'),
      findsOneWidget,
    );
    expect(find.text('Telefon'), findsOneWidget);
    await tester.tap(find.text('Wyłącz transfer'));
    await tester.pumpAndSettle();
    expect(repo.calls.where((c) => c['action'] == 'stop'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Phone selects real album and playlist before downloading', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = TransferFake(true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransferScreen(repository: repo, onLibraryChanged: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pokaż muzykę z PC'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Moja płyta'));
    await tester.tap(find.text('Moja płyta'));
    await tester.pump();
    await tester.ensureVisible(find.text('W drodze'));
    await tester.tap(find.text('W drodze'));
    await tester.pump();
    final button = find.widgetWithText(FilledButton, 'Pobierz na telefon');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final sent = repo.calls.singleWhere((c) => c['action'] == 'startDownload');
    expect(sent['ids'], ['track']);
    expect(sent['playlists'], ['list']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Paused job offers explicit resume without starting automatically',
    (tester) async {
      final repo = TransferFake(true);
      repo.state = {
        ...repo.state,
        'state': 'paused',
        'done': 1,
        'total': 2,
        'doneBytes': 100,
        'totalBytes': 200,
        'error': 'Przerwane połączenie',
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransferScreen(repository: repo, onLibraryChanged: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.calls.where((c) => c['action'] == 'resume'), isEmpty);
      await tester.ensureVisible(find.text('Wznów pobieranie'));
      await tester.tap(find.text('Wznów pobieranie'));
      await tester.pump();
      expect(repo.calls.where((c) => c['action'] == 'resume'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
