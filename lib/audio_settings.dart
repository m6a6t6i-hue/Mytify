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
import 'l10n.dart';

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
          all.insert(0, AudioDevice(selected, s.output?['name']?.toString() ?? tr('Zapisane urządzenie')));
        }
        final missing = out.searched && !out.devices.any((d) => d.id == selected);
        String name(AudioDevice d) {
          final (n, kind) = deviceLabel(d);
          final suffix = [?kind, if (d.id == selected && missing) tr('niedostępne')].join(', ');
          return suffix.isEmpty ? n : '$n ($suffix)';
        }

        final yamaha = kindOf(selected) == DeviceKind.dlna &&
            '${s.output?['name'] ?? ''} ${all.firstWhere((d) => d.id == selected).name}'.toLowerCase().contains('yamaha');
        final muted = app.volume <= 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(tr('Wyjście'), padding: EdgeInsets.only(bottom: Sp.s)),
            _labelled(
              tr('Urządzenie odtwarzania'),
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
                      : IconAction(Icons.refresh_rounded, tr('Odśwież listę urządzeń'), () => unawaited(out.refresh()), color: secondaryText),
                ],
              ),
            ),
            if (out.connecting != null) Padding(padding: EdgeInsets.only(left: 200), child: Text(tr('Łączenie…'), style: Ctl.label)),
            if (s.pairingRequired)
              _labelled(
                tr('PIN AirPlay'),
                narrow: narrow,
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: pin,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                        style: Ctl.fieldText,
                        decoration: Ctl.field(hint: tr('PIN z ekranu odbiornika')).copyWith(counterText: ''),
                        onSubmitted: (v) => unawaited(out.command({'action': 'pin', 'value': v.trim()})),
                      ),
                    ),
                    const SizedBox(width: Sp.s),
                    FilledButton(
                      style: Ctl.filled,
                      onPressed: () => unawaited(out.command({'action': 'pin', 'value': pin.text.trim()})),
                      child: Text(tr('Połącz')),
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
                    label: Text(tr('Włącz amplituner')),
                  ),
                ),
              ),
            _labelled(
              tr('Głośność'),
              narrow: narrow,
              Row(
                children: [
                  IconAction(
                    muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    muted ? tr('Przywróć dźwięk') : tr('Wycisz'),
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
                child: Text(tr('Ten odbiornik nie udostępnia głośności. Użyj jego pilota.'), style: Ctl.label),
              )
            else if (kindOf(selected) == DeviceKind.airplay)
              Padding(
                padding: EdgeInsets.only(left: narrow ? 0 : 200),
                child: Text(tr('Poziom sygnału wysyłanego z Mytify. Głośność odbiornika bez zmian.'), style: Ctl.label),
              ),
            if (out.error != null)
              Padding(
                padding: EdgeInsets.only(left: narrow ? 0 : 200, top: Sp.s),
                child: Text(trMessage(out.error!), style: TextStyle(fontSize: 13.5, color: dangerText)),
              ),
            if (s.equalizer != null) ...[
              SectionTitle(tr('Barwa dźwięku')),
              EqualizerPanel(app: app, snapshot: s),
            ],
            SectionTitle(tr('Zaawansowane')),
            Collapsible(title: tr('Diagnostyka dźwięku'), child: _diagnostics(s)),
            Collapsible(title: tr('Protokoły i zgodność'), child: _protocols()),
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
          tr('Stan'),
          !s.available
              ? tr('Odtwarzacz niedostępny')
              : s.buffering
              ? tr('Buforowanie')
              : s.playing
              ? tr('Odtwarzanie')
              : s.completed
              ? tr('Koniec kolejki')
              : s.currentId != null
              ? tr('Pauza')
              : tr('Nic nie jest odtwarzane'),
        ),
        if (active) ...[
          InfoRow(tr('Wyjście'), '${o['name'] ?? ''}'),
          if (o['testSink'] == true) InfoRow(tr('Uwaga'), tr('Wyjście testowe, bez dźwięku'), color: warningText),
          if (kind == DeviceKind.dlna)
            InfoRow(tr('Dekodowanie'), tr('Odbiornik DLNA, z oryginalnego pliku'))
          else if (android && kind == DeviceKind.local)
            InfoRow(tr('Silnik'), tr('Media3 / AudioTrack, format wyjścia wybiera Android'))
          else ...[
            if ('${o['backend'] ?? ''}'.isNotEmpty) InfoRow(tr('Silnik'), '${o['backend']}'),
            if (rate > 0) InfoRow(tr('Częstotliwość wyjścia'), sampleRateLabel(rate)),
            if (format.isNotEmpty) InfoRow(tr('Format próbek'), format),
            if (channels > 0) InfoRow(tr('Kanały'), '$channels'),
          ],
          if (srcRate > 0)
            InfoRow(
              tr('Źródło'),
              [
                sampleRateLabel(srcRate),
                bits > 0 ? tr('{0} bit', [bits]) : tr('kodek stratny'),
                if (srcChannels > 0) collectionCount(srcChannels, tr('kanał'), tr('kanały'), tr('kanałów')),
              ].join(' · '),
            ),
          if (src?['resampled'] == true) InfoRow(tr('Konwersja częstotliwości'), tr('Tak, filtr sinc')),
        ],
        if (!android && s.available) InfoRow(tr('Niedobory bufora'), tr('{0} próbek od uruchomienia', [s.underrunFrames])),
        if (s.error != null) InfoRow(tr('Ostatni błąd'), s.error!),
        if (!active) ...[
          Divider(height: Sp.l, color: softBorder),
          Text(tr('Parametry wyjścia i źródła są widoczne podczas odtwarzania.'), style: Ctl.label),
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
          tr('DLNA i Yamaha MusicCast'),
          tr('Odbiornik sam dekoduje plik. Grupy MusicCast ustawisz w aplikacji Yamahy.'),
        ),
        item(
          'AirPlay',
          tr('Stereo 16 bit / 44,1 kHz bez strat, kilka sekund opóźnienia.'),
        ),
        if (android)
          item(
            tr('Ten telefon'),
            tr('Głośnik, słuchawki albo Bluetooth, według Androida.'),
          )
        else
          item(
            tr('Ten komputer'),
            tr('Windows WASAPI, tryb współdzielony.'),
          ),
      ],
    );
  }
}
