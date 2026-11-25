import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytify/model.dart';
import 'package:mytify/playlists.dart';

class Store implements PlaylistRepository {
  List<MusicPlaylist> data = [];
  @override
  Future<List<MusicPlaylist>> playlists() async => data;
  @override
  Future<void> savePlaylist(String? id, String name, List<String> ids) async {
    data = [MusicPlaylist(id ?? 'new', name, List.of(ids))];
  }

  @override
  Future<void> deletePlaylist(String id) async {
    data = [];
  }
}

void main() {
  const track = Track(
    id: 'hash',
    title: 'Światło',
    artist: 'Łódź',
    album: 'Album',
    albumArtist: '',
    fileName: 'a.flac',
    format: 'FLAC',
    size: 100,
  );
  testWidgets('phone creates persistent playlist from selected music', (
    tester,
  ) async {
    final store = Store();
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistScreen(
          repository: store,
          tracks: const [track],
          onPlay: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nowa playlista'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Do auta');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.tap(find.text('Zapisz'));
    await tester.pumpAndSettle();
    expect(store.data.single.name, 'Do auta');
    expect(store.data.single.ids, ['hash']);
    expect(find.text('Do auta'), findsOneWidget);
  });
  testWidgets('phone plays saved order and deleting playlist keeps tracks', (
    tester,
  ) async {
    final store = Store()
      ..data = [
        const MusicPlaylist('p', 'Drive', ['hash']),
      ];
    List<Track>? played;
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistScreen(
          repository: store,
          tracks: const [track],
          onPlay: (t) => played = t,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Odtwórz playlistę'));
    expect(played?.single.id, 'hash');
    await tester.tap(find.byTooltip('Usuń playlistę'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Usuń'));
    await tester.pumpAndSettle();
    expect(store.data, isEmpty);
    expect(track.title, 'Światło');
  });
  testWidgets('playlist validates empty name before saving', (tester) async {
    final store = Store();
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistScreen(
          repository: store,
          tracks: const [track],
          onPlay: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nowa playlista'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zapisz'));
    await tester.pumpAndSettle();
    expect(find.text('Podaj nazwę playlisty.'), findsOneWidget);
    expect(store.data, isEmpty);
  });
}
