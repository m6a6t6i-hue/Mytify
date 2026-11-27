import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mytify/cleanup.dart';
import 'package:mytify/cover_tint.dart';
import 'package:mytify/library_index.dart';
import 'package:mytify/model.dart';

Track t(String id, String title, {String artist = 'Zespół', String album = 'Album', int ms = 200000, String format = 'mp3', int bits = 0, int rate = 44100, int number = 1, int disc = 0, String? cover = 'c'}) => Track(
  id: id,
  title: title,
  artist: artist,
  album: album,
  albumArtist: '',
  fileName: '$id.$format',
  format: format,
  size: 1000,
  durationMs: ms,
  sampleRate: rate,
  bitDepth: bits,
  trackNumber: number,
  discNumber: disc,
  cover: cover,
);

void main() {
  test('duplicates: same artist and title within 3 s, best copy first', () {
    final groups = findDuplicates([
      t('a', 'Ballada', ms: 200000),
      t('b', 'BALLADA!', ms: 201500, format: 'flac', bits: 16),
      t('c', 'Ballada', ms: 260000),
      t('d', 'Ballada (Remastered)', ms: 200000),
      t('e', 'Ballada', artist: 'Inny', ms: 200000),
    ]);
    expect(groups.length, 1);
    expect(groups.single.map((x) => x.id), ['b', 'a']);
  });

  test('album issues come from the catalog only', () {
    final ok = AlbumGroup('k', 'Album', 'Zespół', [t('a', 'Raz'), t('b', 'Dwa', number: 2)]);
    expect(albumIssues(ok), isEmpty);
    final bad = AlbumGroup('k2', 'Bez albumu', 'Nieznany wykonawca', [
      t('a', 'Raz', artist: '', album: '', number: 0, cover: null),
      t('b', 'Dwa', artist: '', album: '', number: 0, cover: null),
    ]);
    expect(albumIssues(bad), ['bez nazwy albumu', 'bez wykonawcy', 'bez okładki', 'bez numerów utworów']);
    final repeated = AlbumGroup('k3', 'Album', 'Zespół', [t('a', 'Raz'), t('b', 'Dwa')]);
    expect(albumIssues(repeated), ['powtórzone numery']);
    // Two discs number from 1 each; a second copy of a song is a duplicate, not a gap.
    final discs = AlbumGroup('k4', 'Album', 'Zespół', [t('a', 'Raz', disc: 1), t('b', 'Dwa', disc: 2)]);
    expect(albumIssues(discs), isEmpty);
    final copies = AlbumGroup('k5', 'Album', 'Zespół', [t('a', 'Raz'), t('a2', 'Raz', format: 'flac'), t('b', 'Dwa', number: 2)]);
    expect(albumIssues(copies), isEmpty);
  });

  test('cover palette: vivid hues of the picture, none for grey covers', () {
    List<int> image(List<(int, int, int)> colors, int each) => [
      for (final (r, g, b) in colors)
        for (var i = 0; i < each; i++) ...[r, g, b, 255],
    ];
    final p = CoverTint.paletteOf(image([(220, 30, 30), (30, 60, 220), (240, 200, 20), (128, 128, 128)], 144))!;
    expect(p.length, 3);
    final hues = [for (final c in p) HSVColor.fromColor(c).hue];
    expect(hues.any((h) => h < 15 || h > 345), isTrue);
    expect(hues.any((h) => (h - 228).abs() < 15), isTrue);
    expect(hues.any((h) => (h - 51).abs() < 15), isTrue);
    expect(CoverTint.paletteOf(image([(120, 120, 120), (20, 20, 20)], 288)), isNull);
    // One hue only: neighbours complete the set.
    expect(CoverTint.paletteOf(image([(20, 200, 80)], 576))!.length, 3);
  });
}
