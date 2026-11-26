import 'package:flutter_test/flutter_test.dart';
import 'package:mytify/design.dart';
import 'package:mytify/l10n.dart';
import 'package:mytify/l10n_en.dart';

void main() {
  tearDown(() => lang = 'pl');

  test('Polish stays as written, English comes from the dictionary', () {
    expect(tr('Dodano do kolejki: {0}', ['3 utwory']), 'Dodano do kolejki: 3 utwory');
    lang = 'en';
    expect(tr('Dodano do kolejki: {0}', ['x']), 'Added to queue: x');
    expect(tr('Tekst bez tłumaczenia'), 'Tekst bez tłumaczenia');
  });

  test('English plurals and engine messages with a variable part', () {
    lang = 'en';
    expect(collectionCount(1, 'utwór', 'utwory', 'utworów'), '1 track');
    expect(collectionCount(3, 'utwór', 'utwory', 'utworów'), '3 tracks');
    expect(trMessage('Odczyt ścieżki 3 z 12'), 'Reading track 3 of 12');
    expect(trMessage('Brak płyty w napędzie.'), 'No disc in the drive.');
    expect(trMessage('coś zupełnie innego'), 'coś zupełnie innego');
  });

  test('every translation keeps the placeholders of the Polish text', () {
    final ph = RegExp(r'\{\d+\}');
    for (final e in enStrings.entries) {
      expect(ph.allMatches(e.value).map((m) => m[0]).toSet(), ph.allMatches(e.key).map((m) => m[0]).toSet(), reason: e.key);
    }
  });
}
