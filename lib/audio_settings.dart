import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'model.dart';
import 'audio_player.dart';

class AudioSettings extends StatefulWidget {
  final NativeAudioPlayer player;
  const AudioSettings({super.key, required this.player});
  @override
  State<AudioSettings> createState() => _AudioSettingsState();
}

class _AudioSettingsState extends State<AudioSettings> {
  List<AudioDevice> devices = [];
  final pin = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await widget.player.devices();
      if (mounted) {
        setState(() => devices = value);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> choose(String id) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.player.selectDevice(id);
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<AudioSnapshot>(
    stream: widget.player.stream.snapshot,
    initialData: widget.player.state,
    builder: (context, snap) {
      final state = snap.data ?? widget.player.state;
      final output = state.output, source = state.source;
      final options = [...devices];
      if (!options.any((d) => d.id == state.selectedDevice)) {
        options.insert(
          0,
          AudioDevice(
            state.selectedDevice,
            'Zapisane urządzenie (obecnie niedostępne)',
          ),
        );
      }
      return PopScope(
        canPop: !busy,
        child: AlertDialog(
          title: const Text('Diagnostyka dźwięku'),
          content: SizedBox(
            width: 580,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    defaultTargetPlatform == TargetPlatform.android
                        ? 'Telefon, AirPlay lub amplituner w tej samej sieci Wi-Fi. Słuchawki i Bluetooth wybierzesz w panelu systemowym.'
                        : 'Komputer, AirPlay lub amplituner w tej samej sieci. Zmiana wyjścia może na chwilę przerwać odsłuch.',
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    key: ValueKey(state.selectedDevice),
                    initialValue: state.selectedDevice,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Wyjście audio',
                    ),
                    items: options
                        .map(
                          (d) => DropdownMenuItem(
                            value: d.id,
                            child: Text(
                              d.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: busy
                        ? null
                        : (v) {
                            if (v != null) {
                              choose(v);
                            }
                          },
                  ),
                  TextButton.icon(
                    onPressed: busy ? null : refresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Odśwież urządzenia'),
                  ),
                  Text(
                    state.selectedDevice.startsWith('airplay:')
                        ? 'Poziom sygnału aplikacji. Głośność amplitunera bez zmian.'
                        : state.volumeAvailable
                        ? 'Głośność'
                        : 'Odbiornik nie udostępnia odczytu głośności. Użyj jego pilota.',
                  ),
                  Slider(
                    value: state.volume.clamp(0, 100),
                    max: 100,
                    label: '${state.volume.round()}%',
                    onChanged: busy || !state.volumeAvailable
                        ? null
                        : (v) => widget.player.setVolume(v),
                    onChangeEnd: busy || !state.volumeAvailable
                        ? null
                        : (v) async {
                            try {
                              await widget.player.commitVolume(v);
                            } catch (e) {
                              if (mounted) {
                                setState(() => error = '$e');
                              }
                            }
                          },
                  ),
                  if (state.pairingRequired) ...[
                    const Text(
                      'Wpisz PIN wyświetlony przez odbiornik AirPlay.',
                    ),
                    TextField(
                      controller: pin,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      decoration: const InputDecoration(
                        labelText: 'PIN AirPlay',
                      ),
                    ),
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () async {
                              try {
                                await widget.player.repository.audioCommand({
                                  'action': 'pin',
                                  'value': pin.text.trim(),
                                });
                              } catch (e) {
                                if (mounted) setState(() => error = '$e');
                              }
                            },
                      child: const Text('Połącz'),
                    ),
                  ],
                  if (state.selectedDevice.startsWith('dlna:') &&
                      (state.output?['name'] as String? ?? '')
                          .toLowerCase()
                          .contains('yamaha'))
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              try {
                                await widget.player.repository.audioCommand({
                                  'action': 'receiverPower',
                                });
                              } catch (e) {
                                if (mounted) setState(() => error = '$e');
                              }
                            },
                      child: const Text('Włącz Yamahę z trybu czuwania'),
                    ),
                  if (output != null) ...[
                    Text(
                      output['name'] as String,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    if (output['testSink'] == true)
                      const Text(
                        'Wyjście testowe, bez dźwięku',
                        style: TextStyle(color: Colors.amber),
                      ),
                    Text(
                      defaultTargetPlatform == TargetPlatform.android &&
                              state.selectedDevice == 'auto'
                          ? 'Media3 / AudioTrack · parametry wyjścia ustala Android'
                          : state.selectedDevice.startsWith('dlna:')
                          ? 'Oryginalny plik, dekoduje odbiornik DLNA'
                          : '${output['backend']}\n${output['sampleRate']} Hz · ${output['sampleFormat']} · ${output['channels']} kanały',
                    ),
                    const SizedBox(height: 12),
                  ] else
                    const Text(
                      'Wyjście zostanie otwarte przy pierwszym odtwarzaniu.',
                    ),
                  if (source != null &&
                      (source['sampleRate'] as num? ?? 0) > 0) ...[
                    const Divider(),
                    Text(
                      'Źródło: ${source['sampleRate']} Hz · ${source['channels']} kanały · ${(source['bitDepth'] as num? ?? 0) > 0 ? '${source['bitDepth']} bit' : 'kodek stratny / brak głębi'}',
                    ),
                    if (source['resampled'] == true)
                      const Text('Konwersja częstotliwości filtrem sinc.'),
                  ],
                  const SizedBox(height: 14),
                  const Text(
                    'DLNA: oryginalny plik, odbiornik musi obsługiwać format. AirPlay: stereo 16 bit / 44,1 kHz z opóźnieniem. MusicCast: jeden odbiornik przez DLNA, grupy w aplikacji Yamahy.',
                    style: TextStyle(fontSize: 12),
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Diagnostyka odtwarzania'),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${defaultTargetPlatform == TargetPlatform.android ? 'Licznik niedoborów niedostępny na Androidzie' : 'Niedobory bufora: ${state.underrunFrames} próbek'}\n${state.buffering
                              ? 'Trwa buforowanie'
                              : state.playing
                              ? 'Odtwarzanie'
                              : state.completed
                              ? 'Koniec kolejki'
                              : 'Pauza / gotowość'}${state.error == null ? '' : '\nOstatni błąd: ${state.error}'}',
                        ),
                      ),
                    ],
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  if (busy) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('Zamknij'),
            ),
          ],
        ),
      );
    },
  );
}
