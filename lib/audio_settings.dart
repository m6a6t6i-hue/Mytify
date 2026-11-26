import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'devices.dart';
import 'equalizer.dart';
import 'main.dart';
import 'model.dart';
import 'player_ui.dart';
import 'widgets.dart';

/// Settings → Audio: output, volume and mute in place, details folded below.
/// Uses the same state as the player's device popover. Opening it changes nothing.
class AudioSettingsView extends StatefulWidget {
  final LibraryScreenState app;
  const AudioSettingsView({super.key, required this.app});
  @override
  State<AudioSettingsView> createState() => _AudioSettingsViewState();
}

class _AudioSettingsViewState extends State<AudioSettingsView> {
  final pin = TextEditingController();
  LibraryScreenState get app => widget.app;
  OutputDevices get out => app.outputs;
  bool get android => defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    out.addListener(_changed);
    out.ensure();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    out.removeListener(_changed);
    pin.dispose();
    super.dispose();
  }

  Widget _labelled(String label, Widget control, {bool narrow = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Sp.s),
    child: narrow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text(label, style: Ctl.label), const SizedBox(height: Sp.xs), control],
          )
        : Row(
            children: [
              SizedBox(width: 200, child: Text(label, style: const TextStyle(fontSize: 14))),
              Expanded(child: control),
            ],
          ),
  );

  @override
  Widget build(BuildContext context) => PlayerListener(
    app: app,
    builder: (context, s) => LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < 560;
        final selected = s.selectedDevice;
        final all = [...out.devices];
        if (!all.any((d) => d.id == selected)) {
          all.insert(0, AudioDevice(selected, s.output?['name']?.toString() ?? 'Zapisane urządzenie'));
        }
        final missing = out.searched && !out.devices.any((d) => d.id == selected);
        String name(AudioDevice d) {
          final (n, kind) = deviceLabel(d);
          final suffix = [?kind, if (d.id == selected && missing) 'niedostępne'].join(', ');
          return suffix.isEmpty ? n : '$n ($suffix)';
        }

        final yamaha = kindOf(selected) == DeviceKind.dlna &&
            '${s.output?['name'] ?? ''} ${all.firstWhere((d) => d.id == selected).name}'.toLowerCase().contains('yamaha');
        final muted = app.volume <= 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionTitle('Wyjście', padding: EdgeInsets.only(bottom: Sp.s)),
            _labelled(
              'Urządzenie odtwarzania',
              narrow: narrow,
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('out:$selected:${all.length}'),
                      initialValue: selected,
                      isExpanded: true,
                      isDense: true,
                      style: Theme.of(context).textTheme.bodyMedium!.merge(Ctl.fieldText).copyWith(color: primaryText),
                      dropdownColor: elevated,
                      decoration: Ctl.field(),
                      items: [
                        for (final d in all)
                          DropdownMenuItem(
                            value: d.id,
                            child: Row(
                              children: [
                                Icon(deviceIcon(d.id, d.name), size: 18, color: secondaryText),
                                const SizedBox(width: Sp.s),
                                Expanded(child: Text(name(d), overflow: TextOverflow.ellipsis)),
                              ],
                            ),
                          ),
                      ],
                      // Only an explicit choice switches the output.
                      onChanged: out.connecting == null
                          ? (v) {
                              if (v != null) unawaited(out.choose(v));
                            }
                          : null,
                    ),
                  ),
                  const SizedBox(width: Sp.s),
                  out.searching || out.connecting != null
                      ? const SizedBox(
                          width: 36,
                          height: 36,
                          child: Padding(padding: EdgeInsets.all(9), child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : IconAction(Icons.refresh_rounded, 'Odśwież listę urządzeń', () => unawaited(out.refresh()), color: secondaryText),
                ],
              ),
            ),
            if (out.connecting != null) Padding(padding: EdgeInsets.only(left: 200), child: Text('Łączenie…', style: Ctl.label)),
            if (s.pairingRequired)
              _labelled(
                'PIN AirPlay',
                narrow: narrow,
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: pin,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                        style: Ctl.fieldText,
                        decoration: Ctl.field(hint: 'PIN z ekranu odbiornika').copyWith(counterText: ''),
                        onSubmitted: (v) => unawaited(out.command({'action': 'pin', 'value': v.trim()})),
                      ),
                    ),
                    const SizedBox(width: Sp.s),
                    FilledButton(
                      style: Ctl.filled,
                      onPressed: () => unawaited(out.command({'action': 'pin', 'value': pin.text.trim()})),
                      child: const Text('Połącz'),
                    ),
                  ],
                ),
              ),
            if (yamaha)
              Padding(
                padding: EdgeInsets.only(left: narrow ? 0 : 200),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: Ctl.text,
                    onPressed: () => unawaited(out.command({'action': 'receiverPower'})),
                    icon: const Icon(Icons.power_settings_new_rounded, size: 18),
                    label: const Text('Włącz amplituner'),
                  ),
                ),
              ),
            _labelled(
              'Głośność',
              narrow: narrow,
              Row(
                children: [
                  IconAction(
                    muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    muted ? 'Przywróć dźwięk' : 'Wycisz',
                    s.volumeAvailable ? () => unawaited(app.toggleMute()) : null,
                    active: muted,
                    color: muted ? accent : secondaryText,
                  ),
                  Expanded(
                    child: Slider(
                      value: app.volume.clamp(0.0, 100.0),
                      max: 100,
                      label: '${app.volume.round()}%',
                      semanticFormatterCallback: (v) => '${v.round()}%',
                      onChanged: s.volumeAvailable ? app.setVolumeLive : null,
                      onChangeEnd: s.volumeAvailable ? (v) => unawaited(app.commitVolume(v)) : null,
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      s.volumeAvailable ? '${app.volume.round()}%' : '',
                      textAlign: TextAlign.right,
                      style: Ctl.label.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                ],
              ),
            ),
            if (!s.volumeAvailable)
              Padding(
                padding: EdgeInsets.only(left: narrow ? 0 : 200),
                child: Text('Ten odbiornik nie udostępnia głośności. Użyj jego pilota.', style: Ctl.label),
              )
            else if (kindOf(selected) == DeviceKind.airplay)
              Padding(
                padding: EdgeInsets.only(left: narrow ? 0 : 200),
                child: Text('Poziom sygnału wysyłanego z Mytify. Głośność odbiornika bez zmian.', style: Ctl.label),
              ),
            if (out.error != null)
              Padding(
                padding: EdgeInsets.only(left: narrow ? 0 : 200, top: Sp.s),
                child: Text(out.error!, style: TextStyle(fontSize: 13.5, color: dangerText)),
              ),
            if (s.equalizer != null) ...[
              const SectionTitle('Barwa dźwięku'),
              EqualizerPanel(app: app, snapshot: s),
            ],
            const SectionTitle('Zaawansowane'),
            Collapsible(title: 'Diagnostyka dźwięku', child: _diagnostics(s)),
            Collapsible(title: 'Protokoły i zgodność', child: _protocols()),
          ],
        );
      },
    ),
  );

  Widget _diagnostics(AudioSnapshot s) {
    final active = s.currentId != null && s.output != null;
    final o = s.output ?? const <String, dynamic>{}, src = s.source;
    final rate = (o['sampleRate'] as num?)?.toInt() ?? 0;
    final channels = (o['channels'] as num?)?.toInt() ?? 0;
    final format = o['sampleFormat']?.toString() ?? '';
    final srcRate = (src?['sampleRate'] as num?)?.toInt() ?? 0;
    final bits = (src?['bitDepth'] as num?)?.toInt() ?? 0;
    final srcChannels = (src?['channels'] as num?)?.toInt() ?? 0;
    final kind = kindOf(s.selectedDevice);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InfoRow(
          'Stan',
          !s.available
              ? 'Odtwarzacz niedostępny'
              : s.buffering
              ? 'Buforowanie'
              : s.playing
              ? 'Odtwarzanie'
              : s.completed
              ? 'Koniec kolejki'
              : s.currentId != null
              ? 'Pauza'
              : 'Nic nie jest odtwarzane',
        ),
        if (active) ...[
          InfoRow('Wyjście', '${o['name'] ?? ''}'),
          if (o['testSink'] == true) InfoRow('Uwaga', 'Wyjście testowe, bez dźwięku', color: warningText),
          if (kind == DeviceKind.dlna)
            const InfoRow('Dekodowanie', 'Odbiornik DLNA, z oryginalnego pliku')
          else if (android && kind == DeviceKind.local)
            const InfoRow('Silnik', 'Media3 / AudioTrack, format wyjścia wybiera Android')
          else ...[
            if ('${o['backend'] ?? ''}'.isNotEmpty) InfoRow('Silnik', '${o['backend']}'),
            if (rate > 0) InfoRow('Częstotliwość wyjścia', sampleRateLabel(rate)),
            if (format.isNotEmpty) InfoRow('Format próbek', format),
            if (channels > 0) InfoRow('Kanały', '$channels'),
          ],
          if (srcRate > 0)
            InfoRow(
              'Źródło',
              [
                sampleRateLabel(srcRate),
                bits > 0 ? '$bits bit' : 'kodek stratny',
                if (srcChannels > 0) collectionCount(srcChannels, 'kanał', 'kanały', 'kanałów'),
              ].join(' · '),
            ),
          if (src?['resampled'] == true) const InfoRow('Konwersja częstotliwości', 'Tak, filtr sinc'),
        ],
        if (!android && s.available) InfoRow('Niedobory bufora', '${s.underrunFrames} próbek od uruchomienia'),
        if (s.error != null) InfoRow('Ostatni błąd', s.error!),
        if (!active) ...[
          Divider(height: Sp.l, color: softBorder),
          Text('Parametry wyjścia i źródła są widoczne podczas odtwarzania.', style: Ctl.label),
        ],
      ],
    );
  }

  Widget _protocols() {
    Widget item(String title, String text) => Padding(
      padding: const EdgeInsets.only(bottom: Sp.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: Sp.xs),
          Text(text, style: TextStyle(fontSize: 13, color: secondaryText, height: 1.45)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        item(
          'DLNA i Yamaha MusicCast',
          'Odbiornik dostaje oryginalny plik i sam go dekoduje, więc musi obsługiwać jego format. '
              'MusicCast działa jako pojedynczy odbiornik DLNA, grupy ustawisz w aplikacji Yamahy.',
        ),
        item(
          'AirPlay',
          'Mytify wysyła dźwięk stereo 16 bit / 44,1 kHz bez strat. Odbiornik gra z kilkusekundowym opóźnieniem, '
              'dlatego wizualizacja w pasku postępu jest wtedy statyczna.',
        ),
        if (android)
          item(
            'Ten telefon',
            'Odtwarzanie przez Media3. Dźwięk idzie tam, gdzie wskaże Android: głośnik, słuchawki albo Bluetooth. '
                'Wybierzesz je w „Połącz z urządzeniem” → Bluetooth i słuchawki.',
          )
        else
          item(
            'Ten komputer',
            'Dekodowanie w silniku Mytify, wyjście przez Windows WASAPI w trybie współdzielonym. '
                'Bufor odtwarzania mieści około 3 sekund zdekodowanego dźwięku.',
          ),
      ],
    );
  }
}
