import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'audio_models.dart';
import 'design.dart';
import 'devices.dart';
import 'main.dart';
import 'l10n.dart';

const eqBands = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
const eqMax = 12.0;

/// Presets in dB per band (31 Hz ... 16 kHz). The engine lowers the input by the
/// largest boost, so presets never clip.
const eqPresets = <(String, List<double>)>[
  ('Płasko', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  ('Bas', [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
  ('Rock', [4, 3, 1, -1, -2, -1, 1, 3, 4, 4]),
  ('Metal', [4, 3, 0, -2, -3, 0, 2, 4, 5, 4]),
  ('Klasyka', [3, 2, 1, 0, 0, 0, -1, 1, 2, 3]),
  ('Jazz', [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
  ('Pop', [-1, 1, 3, 4, 3, 0, -1, -1, 0, 1]),
  ('Elektronika', [5, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
  ('Hip-hop', [5, 4, 1, 2, -1, -1, 1, 0, 1, 2]),
  ('Akustyczna', [3, 2, 1, 1, 2, 1, 2, 2, 2, 1]),
  ('Wokal', [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
  ('Cicho nocą', [5, 3, 1, 0, 0, 0, 0, 1, 3, 4]),
];

String eqBandLabel(int hz) => hz >= 1000 ? '${hz ~/ 1000}k' : '$hz';

/// Name of the preset matching [gains], or null for own settings.
String? eqPresetName(List<double> gains) {
  for (final (name, values) in eqPresets) {
    var same = true;
    for (var i = 0; i < 10; i++) {
      if ((values[i] - (i < gains.length ? gains[i] : 0)).abs() > .05) same = false;
    }
    if (same) return name;
  }
  return null;
}

/// Equalizer settings from the player state; null when this platform has none.
(bool, List<double>)? eqFrom(AudioSnapshot s) {
  final e = s.equalizer;
  if (e == null) return null;
  final g = [for (final v in e['gains'] as List? ?? const []) (v as num).toDouble()];
  while (g.length < 10) {
    g.add(0);
  }
  return (e['enabled'] == true, g.take(10).toList());
}

class EqualizerPanel extends StatefulWidget {
  final LibraryScreenState app;
  final AudioSnapshot snapshot;
  const EqualizerPanel({super.key, required this.app, required this.snapshot});
  @override
  State<EqualizerPanel> createState() => _EqualizerPanelState();
}

class _EqualizerPanelState extends State<EqualizerPanel> {
  bool enabled = false;
  List<double> gains = List.filled(10, 0);
  bool _dirty = false;
  Timer? _send;
  DateTime _sentAt = DateTime(0);

  @override
  void initState() {
    super.initState();
    final e = eqFrom(widget.snapshot);
    if (e != null) {
      enabled = e.$1;
      gains = [...e.$2];
    }
  }

  @override
  void didUpdateWidget(EqualizerPanel old) {
    super.didUpdateWidget(old);
    // Follow the engine unless the user is changing something right now.
    final e = eqFrom(widget.snapshot);
    if (e != null && !_dirty && DateTime.now().difference(_sentAt) > const Duration(seconds: 1)) {
      enabled = e.$1;
      gains = [...e.$2];
    }
  }

  @override
  void dispose() {
    _send?.cancel();
    if (_dirty) unawaited(_commit());
    super.dispose();
  }

  Future<void> _commit() async {
    _send?.cancel();
    _dirty = false;
    _sentAt = DateTime.now();
    await widget.app.player
        .command({'action': 'equalizer', 'enabled': enabled, 'gains': gains})
        .catchError((Object e) => widget.app.message(tr('Nie udało się zmienić korektora: {0}', [e])));
  }

  /// While dragging, send at most every 120 ms so the sound follows the finger.
  void _changed({bool now = false}) {
    _dirty = true;
    setState(() {});
    if (now) {
      unawaited(_commit());
      return;
    }
    _send ??= Timer(const Duration(milliseconds: 120), () {
      _send = null;
      unawaited(_commit());
    });
  }

  @override
  Widget build(BuildContext context) {
    final preset = eqPresetName(gains);
    final selected = widget.snapshot.selectedDevice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('Korektor'), style: TextStyle(fontSize: 14.5)),
          subtitle: Text(enabled ? (preset == null ? tr('Własne ustawienia') : tr(preset)) : tr('Wyłączony'), style: Txt.meta),
          value: enabled,
          onChanged: (v) {
            enabled = v;
            _changed(now: true);
          },
        ),
        if (kindOf(selected) == DeviceKind.dlna)
          Padding(
            padding: EdgeInsets.only(bottom: Sp.s),
            child: Text(tr('Odbiornik DLNA sam dekoduje plik, korektor działa tylko przy grze na tym urządzeniu i przez AirPlay.'), style: Ctl.label),
          ),
        Wrap(
          spacing: Sp.s,
          runSpacing: Sp.s,
          children: [
            for (final (name, values) in eqPresets)
              ChoiceChip(
                label: Text(tr(name)),
                selected: enabled && preset == name,
                onSelected: (_) {
                  enabled = true;
                  gains = [...values];
                  _changed(now: true);
                },
              ),
          ],
        ),
        const SizedBox(height: Sp.l),
        Opacity(
          opacity: enabled ? 1 : .45,
          child: SizedBox(
            height: 220,
            child: Row(
              children: [
                for (var i = 0; i < 10; i++)
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          '${gains[i] > 0 ? '+' : ''}${gains[i].toStringAsFixed(gains[i] == gains[i].roundToDouble() ? 0 : 1)}',
                          style: Ctl.label.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                        Expanded(
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                              ),
                              child: Slider(
                                value: gains[i].clamp(-eqMax, eqMax),
                                min: -eqMax,
                                max: eqMax,
                                divisions: 48,
                                semanticFormatterCallback: (v) => tr('{0} Hz: {1} dB', [eqBandLabel(eqBands[i]), v.toStringAsFixed(1)]),
                                onChanged: enabled
                                    ? (v) {
                                        gains[i] = (v * 2).round() / 2;
                                        _changed();
                                      }
                                    : null,
                                onChangeEnd: enabled ? (_) => _changed(now: true) : null,
                              ),
                            ),
                          ),
                        ),
                        Text(eqBandLabel(eqBands[i]), style: Ctl.label),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            style: Ctl.text,
            onPressed: enabled && preset != 'Płasko'
                ? () {
                    gains = List.filled(10, 0);
                    _changed(now: true);
                  }
                : null,
            child: Text(tr('Wyzeruj')),
          ),
        ),
      ],
    );
  }
}
