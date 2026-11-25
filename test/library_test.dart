import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytify/model.dart';
import 'package:mytify/queue.dart';

Track track(
  String id, {
  String album = 'Album',
  String artist = 'Wykonawca',
  String albumArtist = '',
  int disc = 1,
  int number = 1,
  bool available = true,
}) => Track(
  id: id,
  title: id,
  artist: artist,
  album: album,
  albumArtist: albumArtist,
  fileName: '$id.flac',
  format: 'FLAC',
  size: 100,
  discNumber: disc,
  trackNumber: number,
  available: available,
);

void main() {
  ReleaseSong song(int disc, int number) => ReleaseSong(
    title: 'Propozycja',
    artist: 'Wykonawca',
    discNumber: disc,
    trackNumber: number,
    durationMs: 1000,
  );
  test('dopasowanie wydania korzysta z numerów płyt i utworów, a nie indeksu listy', () {
    expect(
      suggestTrackMapping(
        [track('a', disc: 2, number: 1), track('b', disc: 1, number: 2)],
        [song(1, 2), song(2, 1)],
      ),
      [1, 0],
    );
  });
  test('niejednoznaczne i brakujące numery nie przypisują cudzych tytułów', () {
    expect(
      suggestTrackMapping(
        [track('a'), track('b'), track('c', number: 0)],
        [song(1, 1), song(1, 2), song(1, 3)],
      ),
      [-1, -1, -1],
    );
    expect(suggestTrackMapping([track('a')], [song(1, 1), song(1, 1)]), [-1]);
  });
  test('niepełny album proponuje tylko istniejące jednoznaczne pozycje', () {
    expect(
      suggestTrackMapping(
        [track('a', number: 3), track('b', disc: 2, number: 8)],
        [song(1, 1), song(1, 3), song(2, 1)],
      ),
      [1, -1],
    );
  });

  test('kolejka pomija pliki offline w obu kierunkach', () {
    final q = PlaybackQueue()
      ..replace([track('a'), track('b', available: false), track('c')], 'a');
    expect(q.next(), isTrue);
    expect(q.current!.id, 'c');
    expect(q.previous(), isTrue);
    expect(q.current!.id, 'a');
    q.repeat = true;
    q.refresh([
      track('a', available: false),
      track('b', available: false),
      track('c', available: false),
    ]);
    expect(q.next(), isFalse);
    expect(q.previous(), isFalse);
  });
  test(
    'skan odświeża dostępność, zachowuje wybór i usuwa zapomniane wpisy',
    () {
      final q = PlaybackQueue()
        ..replace([track('a'), track('b'), track('c')], 'b');
      q.refresh([track('b', available: false), track('c')]);
      expect(q.current!.id, 'b');
      expect(q.current!.available, isFalse);
      expect(q.items.map((t) => t.id), ['b', 'c']);
      q.toggleShuffle(random: Random(3));
      q.toggleShuffle();
      expect(q.items.map((t) => t.id), ['b', 'c']);
      expect(q.next(), isTrue);
      expect(q.current!.id, 'c');
    },
  );
  test('wyszukiwanie polskich nazw bez znaków diakrytycznych, także po kilku polach', () {
    final t = track('Światło', artist: 'Łódź');
    expect(filterTracks([t], 'lodz swiatlo'), [t]);
    expect(filterTracks([t], 'inne'), isEmpty);
  });
  test('kompilacja grupuje różnych wykonawców przez album artist', () {
    final a = track('a', artist: 'A', albumArtist: 'Various Artists');
    final b = track('b', artist: 'B', albumArtist: 'Various Artists');
    expect(a.albumKey, b.albumKey);
    expect(
      track('x', album: '').albumKey,
      isNot(track('y', album: '').albumKey),
    );
  });
  test('kolejność wielopłytowego albumu uwzględnia dysk przed utworem', () {
    final items = [
      track('b', disc: 2, number: 1),
      track('a', disc: 1, number: 9),
    ];
    items.sort(albumOrder);
    expect(items.map((t) => t.id), ['a', 'b']);
  });
  test('kolejka jest snapshotem wyboru i zatrzymuje się na końcu', () {
    final original = [track('a'), track('b')];
    final q = PlaybackQueue()..replace(original, 'a');
    original.clear();
    expect(q.next(), isTrue);
    expect(q.current!.id, 'b');
    expect(q.next(), isFalse);
    expect(q.current!.id, 'b');
    q.repeat = true;
    expect(q.next(), isTrue);
    expect(q.current!.id, 'a');
  });
  test('shuffle i powrót do kolejności zachowują bieżący utwór', () {
    final q = PlaybackQueue()
      ..replace([track('a'), track('b'), track('c')], 'b');
    q.toggleShuffle(random: Random(7));
    expect(q.current!.id, 'b');
    q.toggleShuffle();
    expect(q.current!.id, 'b');
    expect(q.items.map((t) => t.id), ['a', 'b', 'c']);
  });
  test('usuwanie bieżącego i ostatniego nie zostawia złego indeksu', () {
    final q = PlaybackQueue()..replace([track('a'), track('b')], 'b');
    q.remove('b');
    expect(q.current!.id, 'a');
    q.remove('a');
    expect(q.current, isNull);
    expect(q.next(), isFalse);
  });
  test('odrzuca wybrany utwór spoza kolejki', () {
    expect(
      () => PlaybackQueue().replace([track('a')], 'b'),
      throwsArgumentError,
    );
  });
  test('roundtrip katalogu zachowuje pola i polubienie', () {
    final original = track('test').withLiked(true);
    expect(Track.fromJson(original.toJson()).toJson(), original.toJson());
  });
}
