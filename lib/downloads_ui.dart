import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'main.dart';
import 'model.dart';
import 'sources_ui.dart';
import 'widgets.dart';

String sizeLabel(num bytes) {
  if (bytes >= 1e9) return '${(bytes / 1e9).toStringAsFixed(1).replaceAll('.', ',')} GB';
  if (bytes >= 1e6) return '${(bytes / 1e6).toStringAsFixed(0)} MB';
  return '${(bytes / 1e3).toStringAsFixed(0)} kB';
}

/// Offline copies seen from the app: menus, confirmation with space, live status.
class DownloadState extends ChangeNotifier {
  final LibraryScreenState app;
  DownloadState(this.app);

  Map<String, dynamic> status = const {};
  Timer? _timer;
  int _active = 0;

  List<Map<String, dynamic>> get items => [for (final i in status['items'] as List? ?? const []) Map<String, dynamic>.from(i as Map)];
  Set<String> get kept => {for (final k in status['kept'] as List? ?? const []) k as String};
  Set<String> get pending => {for (final i in items) i['id'] as String};
  bool get paused => status['paused'] == true;

  Future<void> refresh() async {
    try {
      status = await app.repository.downloads('status');
    } catch (_) {
      return;
    }
    final active = items.where((i) => i['state'] == 'queued' || i['state'] == 'running').length;
    // Something finished: the library shows the new offline copies.
    if (active < _active) unawaited(app.loadLibrary());
    _active = active;
    _timer?.cancel();
    if (active > 0) _timer = Timer(const Duration(seconds: 2), () => unawaited(refresh()));
    notifyListeners();
  }

  Future<void> _call(String action, [Map<String, dynamic> args = const {}]) async {
    try {
      await app.repository.downloads(action, args);
    } catch (e) {
      app.message(readableError(e));
    }
    await refresh();
  }

  /// "Pobierz offline": shows the size and free space before anything starts.
  Future<void> download(List<Track> tracks, {String? title}) async {
    final ids = [for (final t in tracks) if (t.remote && !t.offline) t.id];
    if (ids.isEmpty) {
      app.message('Wszystko jest już pobrane.');
      return;
    }
    Map<String, dynamic> e;
    try {
      e = await app.repository.downloads('estimate', {'ids': ids});
    } catch (x) {
      app.message(readableError(x));
      return;
    }
    final count = (e['count'] as num?)?.toInt() ?? 0;
    final bytes = (e['bytes'] as num?)?.toDouble() ?? 0;
    final unknown = (e['unknown'] as num?)?.toInt() ?? 0;
    final free = (e['free'] as num?)?.toDouble();
    if (free != null && bytes > free) {
      app.message('Za mało miejsca: potrzeba ${sizeLabel(bytes)}, wolne ${sizeLabel(free)}.');
      return;
    }
    if (!app.mounted) return;
    final ok = await confirm(
      app.context,
      title: title ?? 'Pobrać offline?',
      message: [
        '${trackCount(count)}, ${unknown > 0 ? 'co najmniej ' : ''}${sizeLabel(bytes)}.',
        if (free != null) 'Wolne miejsce: ${sizeLabel(free)}.',
        if (unknown > 0) 'Serwer nie podał rozmiaru części plików.',
      ].join('\n'),
      action: 'Pobierz',
      destructive: false,
    );
    if (!ok) return;
    await _call('add', {'ids': ids});
    app.message('Pobieranie: ${trackCount(count)}');
  }

  Future<void> remove(List<Track> tracks) async {
    final ids = [for (final t in tracks) if (t.offline || pending.contains(t.id)) t.id];
    if (ids.isEmpty) return;
    await _call('remove', {'ids': ids});
    await app.loadLibrary();
    app.message('Usunięto pobrane kopie. Oryginały na serwerze zostały bez zmian.');
  }

  Future<void> keep(MusicPlaylist p, bool value) => _call('keep', {'playlist': p.id, 'keep': value});
  Future<void> pause(bool value) => _call('pause', {'paused': value});
  Future<void> cancel(String id) => _call('cancel', {'ids': [id]});
  Future<void> retry(String id) => _call('add', {'ids': [id]});
  Future<void> cellular(bool value) => _call('cellular', {'cellular': value});

  /// Menu entries for tracks that live on network sources.
  List<MenuEntry> entries(List<Track> tracks, {String? title}) {
    final remote = tracks.where((t) => t.remote).toList();
    if (remote.isEmpty) return const [];
    final missing = remote.where((t) => !t.offline && !pending.contains(t.id)).toList();
    final local = remote.where((t) => t.offline || pending.contains(t.id)).toList();
    return [
      if (missing.isNotEmpty)
        MenuEntry('Pobierz offline', icon: Icons.download_for_offline_outlined, onTap: () => unawaited(download(missing, title: title))),
      if (local.isNotEmpty)
        MenuEntry('Usuń pobranie', icon: Icons.file_download_off_outlined, onTap: () => unawaited(remove(local))),
    ];
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// "Pobrane": what is on this device, what is in progress, and how much space it takes.
class DownloadsPage extends StatefulWidget {
  final LibraryScreenState app;
  const DownloadsPage({super.key, required this.app});
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  DownloadState get d => widget.app.downloads;

  @override
  void initState() {
    super.initState();
    d.addListener(_changed);
    unawaited(d.refresh());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    d.removeListener(_changed);
    super.dispose();
  }

  String _state(Map<String, dynamic> i) {
    final done = (i['done'] as num?)?.toDouble() ?? 0;
    final total = (i['total'] as num?)?.toDouble() ?? 0;
    return switch (i['state']) {
      'running' => total > 0 ? 'Pobieranie ${(done * 100 / total).clamp(0, 100).round()}%' : 'Pobieranie',
      'failed' => (i['error'] as String?)?.isNotEmpty == true ? i['error'] as String : 'Nie udało się',
      _ => (i['error'] as String?)?.isNotEmpty == true ? 'Czeka: ${i['error']}' : 'W kolejce',
    };
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final pad = app.desktopMode ? const EdgeInsets.symmetric(horizontal: Sp.xl) : const EdgeInsets.symmetric(horizontal: Sp.l);
    final offline = app.index.tracks.where((t) => t.offline).toList();
    final used = (d.status['used'] as num?)?.toDouble() ?? 0;
    final free = (d.status['free'] as num?)?.toDouble();
    final items = d.items;
    final phone = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return ListView(
      padding: pad.copyWith(top: Sp.l, bottom: Sp.xxl + MediaQuery.viewPaddingOf(context).bottom),
      children: [
        if (app.desktopMode) const Padding(padding: EdgeInsets.only(bottom: Sp.m), child: Text('Pobrane', style: Txt.display)),
        Text(
          '${trackCount(offline.length)} offline · ${sizeLabel(used)}${free != null ? ' · wolne ${sizeLabel(free)}' : ''}',
          style: Txt.sub,
        ),
        const SizedBox(height: Sp.m),
        Wrap(
          spacing: Sp.s,
          runSpacing: Sp.s,
          children: [
            if (items.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => unawaited(d.pause(!d.paused)),
                icon: Icon(d.paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 18),
                label: Text(d.paused ? 'Wznów pobieranie' : 'Wstrzymaj pobieranie'),
              ),
            OutlinedButton.icon(
              onPressed: () => app.go(const Nav('library', 'downloaded')),
              icon: const Icon(Icons.library_music_outlined, size: 18),
              label: const Text('Pokaż pobrane utwory'),
            ),
          ],
        ),
        if (phone)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: d.status['cellular'] == true,
            onChanged: (v) => unawaited(d.cellular(v)),
            title: const Text('Pobieraj przez sieć komórkową'),
            subtitle: const Text('Domyślnie tylko przez Wi-Fi.', style: Txt.meta),
          ),
        const SizedBox(height: Sp.l),
        if (items.isEmpty)
          const Text('Nic nie czeka na pobranie.', style: Txt.sub)
        else ...[
          SectionHeader(d.paused ? 'Wstrzymane' : 'Kolejka'),
          for (final i in items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: i['state'] == 'running'
                  ? SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        value: ((i['total'] as num?) ?? 0) > 0 ? ((i['done'] as num) / (i['total'] as num)).clamp(0, 1).toDouble() : null,
                      ),
                    )
                  : Icon(i['state'] == 'failed' ? Icons.error_outline_rounded : Icons.schedule_rounded, color: secondaryText),
              title: Text(i['title'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(_state(i), maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.meta),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (i['state'] == 'failed') IconAction(Icons.refresh_rounded, 'Spróbuj ponownie', () => unawaited(d.retry(i['id'] as String))),
                  IconAction(Icons.close_rounded, 'Anuluj', () => unawaited(d.cancel(i['id'] as String))),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
