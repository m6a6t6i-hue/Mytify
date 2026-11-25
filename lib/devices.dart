import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'main.dart';
import 'model.dart';
import 'player_ui.dart';
import 'widgets.dart';

/// Kind of output, derived from the id the engine gives it.
enum DeviceKind { local, airplay, dlna, test }

DeviceKind kindOf(String id) => id.startsWith('airplay:')
    ? DeviceKind.airplay
    : id.startsWith('dlna:')
    ? DeviceKind.dlna
    : id.startsWith('test-')
    ? DeviceKind.test
    : DeviceKind.local;

IconData deviceIcon(String id, String name) {
  final n = name.toLowerCase();
  return switch (kindOf(id)) {
    DeviceKind.airplay => Icons.airplay_rounded,
    DeviceKind.dlna => n.contains('yamaha') ? Icons.speaker_rounded : Icons.speaker_group_rounded,
    DeviceKind.test => Icons.science_outlined,
    DeviceKind.local when id == 'auto' => isPhoneOutput ? Icons.smartphone_rounded : Icons.computer_rounded,
    _ => n.contains('słuchaw') || n.contains('headphone') || n.contains('headset')
        ? Icons.headphones_rounded
        : Icons.speaker_outlined,
  };
}

bool isPhoneOutput = false;

/// Splits "Salon · Yamaha / MusicCast (DLNA)" into a name and a short description.
(String, String?) deviceLabel(AudioDevice d) {
  if (d.id == 'auto') {
    return (isPhoneOutput ? 'Ten telefon' : 'Ten komputer', isPhoneOutput ? null : 'Domyślne wyjście systemu');
  }
  final parts = d.name.split(' · ');
  final kind = switch (kindOf(d.id)) {
    DeviceKind.airplay => 'AirPlay',
    DeviceKind.dlna => d.name.toLowerCase().contains('yamaha') ? 'MusicCast' : 'DLNA',
    DeviceKind.test => 'Bez dźwięku',
    DeviceKind.local => null,
  };
  return (parts.first.trim(), kind);
}

/// Output devices as the app sees them. One state for the player popover and
/// Settings → Audio, so both always show the same device, volume and mute.
class OutputDevices extends ChangeNotifier {
  final LibraryScreenState app;
  OutputDevices(this.app);
  List<AudioDevice> devices = [];
  bool searching = false, searched = false;
  String? connecting, error;

  /// Discovery only lists devices; it never switches the output.
  Future<void> refresh() async {
    if (searching) return;
    searching = true;
    error = null;
    notifyListeners();
    try {
      devices = await app.player.devices();
      searched = true;
    } catch (_) {
      error = 'Nie udało się wyszukać urządzeń';
    } finally {
      searching = false;
      notifyListeners();
    }
  }

  /// First visit of a view that lists devices.
  void ensure() {
    if (!searched && !searching) unawaited(refresh());
  }

  Future<void> choose(String id) async {
    if (id == app.player.state.selectedDevice || connecting != null) return;
    connecting = id;
    error = null;
    notifyListeners();
    try {
      await app.player.selectDevice(id);
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '');
    } finally {
      connecting = null;
      notifyListeners();
    }
  }

  Future<void> command(Map<String, dynamic> action) async {
    try {
      await app.player.command(action);
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '');
      notifyListeners();
    }
  }
}

/// Desktop: popover above the player bar. Mobile: bottom sheet.
Future<void> showDevicePicker(LibraryScreenState app, {Offset? at}) {
  isPhoneOutput = app.isPhone;
  final context = app.context;
  if (!app.desktopMode) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheet) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .8),
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewPaddingOf(sheet).bottom),
          child: DevicePanel(app: app),
        ),
      ),
    );
  }
  final size = MediaQuery.sizeOf(context);
  final right = at == null ? Sp.l : (size.width - at.dx - 40).clamp(Sp.l, size.width - 360);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Zamknij',
    barrierColor: Colors.transparent,
    transitionDuration: motion(context, Dur.standard),
    pageBuilder: (context, _, _) => Stack(
      children: [
        Positioned(
          right: right.toDouble(),
          bottom: 96,
          width: 360,
          child: Material(
            color: elevated,
            elevation: 6,
            shadowColor: Colors.black54,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Rad.panel),
              side: const BorderSide(color: softBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: size.height - 140),
              child: DevicePanel(app: app),
            ),
          ),
        ),
      ],
    ),
    transitionBuilder: (context, a, _, child) => FadeTransition(
      opacity: a,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, .03), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );
}

class DevicePanel extends StatefulWidget {
  final LibraryScreenState app;
  const DevicePanel({super.key, required this.app});
  @override
  State<DevicePanel> createState() => _DevicePanelState();
}

class _DevicePanelState extends State<DevicePanel> {
  final pin = TextEditingController();
  int _errorSerial = 0;

  LibraryScreenState get app => widget.app;
  OutputDevices get out => app.outputs;

  @override
  void initState() {
    super.initState();
    _errorSerial = app.player.state.errorSerial;
    out.addListener(_changed);
    // Looking for devices never changes the current output.
    unawaited(out.refresh());
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

  @override
  Widget build(BuildContext context) => PlayerListener(
    app: app,
    builder: (context, s) {
      if (s.errorSerial != _errorSerial && s.error != null && out.connecting == null) {
        _errorSerial = s.errorSerial;
        out.error = s.error;
      }
      final devices = out.devices, searching = out.searching, connecting = out.connecting, error = out.error;
      final selected = s.selectedDevice;
      final all = [...devices];
      if (!all.any((d) => d.id == selected)) {
        all.insert(0, AudioDevice(selected, s.output?['name']?.toString() ?? 'Zapisane urządzenie'));
      }
      final current = all.firstWhere((d) => d.id == selected);
      final others = all.where((d) => d.id != selected).toList();
      final currentMissing = !searching && !devices.any((d) => d.id == selected);
      final yamaha = kindOf(selected) == DeviceKind.dlna &&
          '${current.name} ${s.output?['name'] ?? ''}'.toLowerCase().contains('yamaha');
      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.l),
        children: [
          Row(
            children: [
              const Expanded(child: Text('Połącz z urządzeniem', style: Txt.title)),
              if (searching)
                const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else
                IconAction(Icons.refresh_rounded, 'Odśwież', () => unawaited(out.refresh()), color: secondaryText, box: 40),
            ],
          ),
          const SizedBox(height: Sp.s),
          const Text('Aktualne urządzenie', style: Txt.meta),
          _DeviceTile(
            device: current,
            active: true,
            status: connecting == selected
                ? 'Łączenie…'
                : s.pairingRequired
                ? 'Wymaga PIN'
                : currentMissing
                ? 'Niedostępne'
                : s.buffering
                ? 'Buforowanie'
                : s.playing
                ? 'Odtwarza'
                : 'Połączono',
            onTap: null,
          ),
          if (s.pairingRequired) ...[
            const SizedBox(height: Sp.s),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: pin,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    autofocus: true,
                    decoration: const InputDecoration(hintText: 'PIN z ekranu odbiornika', counterText: ''),
                    onSubmitted: (v) => unawaited(out.command({'action': 'pin', 'value': v.trim()})),
                  ),
                ),
                const SizedBox(width: Sp.s),
                FilledButton(
                  onPressed: () => unawaited(out.command({'action': 'pin', 'value': pin.text.trim()})),
                  child: const Text('Połącz'),
                ),
              ],
            ),
          ],
          if (yamaha)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => unawaited(out.command({'action': 'receiverPower'})),
                icon: const Icon(Icons.power_settings_new_rounded, size: 18),
                label: const Text('Włącz amplituner'),
              ),
            ),
          const SizedBox(height: Sp.s),
          Row(
            children: [
              IconAction(
                s.volume <= 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                s.volume <= 0 ? 'Przywróć dźwięk' : 'Wycisz',
                s.volumeAvailable ? () => unawaited(app.toggleMute()) : null,
                color: secondaryText,
              ),
              Expanded(
                child: Slider(
                  value: app.volume.clamp(0.0, 100.0),
                  max: 100,
                  onChanged: s.volumeAvailable ? app.setVolumeLive : null,
                  onChangeEnd: s.volumeAvailable ? (v) => unawaited(app.commitVolume(v)) : null,
                ),
              ),
            ],
          ),
          if (!s.volumeAvailable)
            const Padding(
              padding: EdgeInsets.only(left: 44),
              child: Text('Głośność ustawisz na odbiorniku', style: Txt.meta),
            ),
          if (error != null)
            Container(
              margin: const EdgeInsets.only(top: Sp.s),
              padding: const EdgeInsets.all(Sp.m),
              decoration: BoxDecoration(
                color: const Color(0x22ff6b6b),
                borderRadius: BorderRadius.circular(Rad.control),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline_rounded, size: 18, color: Color(0xffff8a8a)),
                  const SizedBox(width: Sp.s),
                  Expanded(child: Text(error!, style: const TextStyle(fontSize: 13))),
                ],
              ),
            ),
          const SizedBox(height: Sp.m),
          const Divider(height: 1, color: softBorder),
          const SizedBox(height: Sp.m),
          const Text('Dostępne urządzenia', style: Txt.meta),
          if (!searching && others.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Sp.m),
              child: Text('Nie znaleziono innych urządzeń w tej sieci', style: Txt.sub),
            ),
          for (final d in others)
            _DeviceTile(
              device: d,
              active: false,
              status: connecting == d.id ? 'Łączenie…' : null,
              onTap: connecting == null ? () => unawaited(out.choose(d.id)) : null,
            ),
          if (searching && others.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Sp.m),
              child: Text('Szukam urządzeń…', style: Txt.sub),
            ),
          if (app.isPhone)
            const Padding(
              padding: EdgeInsets.only(top: Sp.s),
              child: Text('Słuchawki i głośniki Bluetooth wybierzesz w panelu multimediów Androida.', style: Txt.meta),
            ),
        ],
      );
    },
  );
}

class _DeviceTile extends StatelessWidget {
  final AudioDevice device;
  final bool active;
  final String? status;
  final VoidCallback? onTap;
  const _DeviceTile({required this.device, required this.active, required this.status, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final (name, kind) = deviceLabel(device);
    final sub = [?kind, ?status].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Rad.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: Sp.xs),
        child: Row(
          children: [
            AnimatedContainer(
              duration: motion(context, Dur.standard),
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: active ? selectedFill : hoverFill,
                borderRadius: BorderRadius.circular(Rad.control),
              ),
              child: Icon(deviceIcon(device.id, device.name), color: active ? accent : primaryText, size: 22),
            ),
            const SizedBox(width: Sp.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: active ? accent : primaryText),
                  ),
                  if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.meta),
                ],
              ),
            ),
            if (status == 'Łączenie…')
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            else if (active)
              const Icon(Icons.check_circle_rounded, color: accent, size: 20),
          ],
        ),
      ),
    );
  }
}
