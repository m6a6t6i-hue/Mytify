import 'package:flutter_test/flutter_test.dart';
import 'package:mytify/audio_models.dart';
import 'package:mytify/equalizer.dart';

void main() {
  test('presets have ten bands within range and are recognised', () {
    for (final (name, values) in eqPresets) {
      expect(values.length, 10, reason: name);
      expect(values.every((v) => v.abs() <= eqMax), isTrue, reason: name);
      expect(eqPresetName(values), name);
    }
    expect(eqPresetName([1, 0, 0, 0, 0, 0, 0, 0, 0, 0]), isNull);
  });

  test('equalizer state comes from the engine, absent where unsupported', () {
    expect(eqFrom(const AudioSnapshot()), isNull);
    final e = eqFrom(const AudioSnapshot(equalizer: {'enabled': true, 'gains': [3, -2]}))!;
    expect(e.$1, isTrue);
    expect(e.$2, [3, -2, 0, 0, 0, 0, 0, 0, 0, 0]);
  });
}
