import 'package:flutter_test/flutter_test.dart';
import 'package:mytify/model.dart';

Track track(
  String id,
  String album, {
  String artist = 'Everything will echo',
  String albumArtist = '',
}) => Track(
  id: id,
  title: id,
  artist: artist,
  album: album,
  albumArtist: albumArtist,
  fileName: '$id.flac',
  format: 'FLAC',
  size: 100,
);
void main() {
  test(
    'screen regression: mixed title case keeps eight songs in one album',
    () {
      final tracks = List.generate(
        8,
        (i) => track(
          '$i',
          i.isEven
              ? 'The duck knows where the river will flow'
              : 'the duck knows where the river will flow',
        ),
      );
      expect(tracks.map((t) => t.albumKey).toSet(), hasLength(1));
      expect(tracks, hasLength(8));
    },
  );
  test(
    'spacing and album artist case normalize while raw tags stay intact',
    () {
      final a = track(
        'a',
        '  The  duck\u00a0knows ',
        albumArtist: 'Everything will ECHO',
      );
      final b = track(
        'b',
        'the duck knows',
        artist: 'Guest',
        albumArtist: ' everything   will echo ',
      );
      expect(a.albumKey, b.albumKey);
      expect(a.album, '  The  duck\u00a0knows ');
    },
  );
  test('different artists and meaningful titles remain separate', () {
    expect(
      track('a', 'Greatest Hits', artist: 'Queen').albumKey,
      isNot(track('b', 'Greatest Hits', artist: 'ABBA').albumKey),
    );
    expect(track('a', 'Lód').albumKey, isNot(track('b', 'Lod').albumKey));
    expect(track('a', 'A-B').albumKey, isNot(track('b', 'AB').albumKey));
  });
  test(
    'blank albums do not collapse; blank album artist falls back to artist',
    () {
      expect(track('a', ' ').albumKey, isNot(track('b', '').albumKey));
      expect(
        track('a', 'Album', albumArtist: ' ').albumKey,
        track('b', 'album').albumKey,
      );
    },
  );
}
