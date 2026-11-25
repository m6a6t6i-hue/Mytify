import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'model.dart';

abstract interface class LibraryChangesRepository {
  Stream<void> get changes;
}

abstract interface class TransferRepository {
  bool get receivesTransfers;
  Future<dynamic> transfer(Map<String, dynamic> request);
}

class TransferScreen extends StatefulWidget {
  final TransferRepository repository;
  final VoidCallback onLibraryChanged;
  const TransferScreen({
    super.key,
    required this.repository,
    required this.onLibraryChanged,
  });
  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  Map<String, dynamic> state = {};
  Map<String, dynamic>? manifest;
  String? error, peer, qrText;
  Uint8List? qr;
  final selected = <String>{}, playlists = <String>{};
  final link = TextEditingController();
  bool busy = false, polling = false, wasDownloading = false;
  Timer? timer;
  bool get receiver => widget.repository.receivesTransfers;
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    link.dispose();
    super.dispose();
  }

  void accept(dynamic value) {
    if (!mounted || value is! Map) return;
    final next = Map<String, dynamic>.from(value);
    final q = next['qr'] as String?;
    final was = wasDownloading;
    wasDownloading = ['queued', 'downloading'].contains(next['state']);
    if (was && !wasDownloading) widget.onLibraryChanged();
    setState(() {
      state = next;
      if (q != qrText) {
        qrText = q;
        qr = q == null ? null : base64Decode(q);
      }
      final peers = (state['peers'] as List?) ?? [];
      if (peer == null && peers.isNotEmpty) peer = peers.last['id'] as String;
    });
  }

  Future<void> refresh() async {
    if (polling || busy) return;
    polling = true;
    try {
      accept(await widget.repository.transfer({'action': 'status'}));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      polling = false;
    }
  }

  Future<void> action(
    Map<String, dynamic> request, {
    bool status = true,
  }) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await widget.repository.transfer(request);
      if (status) accept(value);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> discard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Usunąć niedokończone pobranie?'),
        content: const Text(
          'Usuniemy pliki częściowe. Utwory już dodane do biblioteki pozostaną w telefonie.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Usuń pobranie'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await action({'action': 'discard'});
  }

  Future<void> pair(String value) async {
    if (value.trim().isEmpty) return;
    setState(() {
      peer = null;
      manifest = null;
      selected.clear();
      playlists.clear();
    });
    await action({'action': 'pair', 'link': value.trim()});
    link.clear();
    if (error == null) await load();
  }

  Future<void> scan() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final value = await widget.repository.transfer({'action': 'scan'});
      if (mounted) setState(() => busy = false);
      if (value is String && value.isNotEmpty) await pair(value);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  Future<void> load() async {
    if (peer == null || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final m = Map<String, dynamic>.from(
        await widget.repository.transfer({'action': 'manifest', 'id': peer})
            as Map,
      );
      if (mounted) {
        setState(() {
          manifest = m;
          selected.clear();
          playlists.clear();
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> deleteCopies() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Usunąć kopie z telefonu?'),
        content: const Text(
          'Usuniemy pliki pobrane z tego PC. Oryginały na komputerze i muzyka z innych źródeł pozostaną.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Usuń kopie'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await action({'action': 'deleteCopies', 'id': peer});
      widget.onLibraryChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final peers = (state['peers'] as List?) ?? [];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            receiver ? 'Muzyka z PC' : 'Połącz telefon',
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -.8,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            receiver
                ? 'Zeskanuj kod z Mytify na komputerze i wybierz albumy. Pobrane utwory działają bez PC i Wi-Fi.'
                : 'Na telefonie: Ustawienia, potem Z komputera. Oba urządzenia muszą być w tej samej sieci.',
            style: const TextStyle(color: secondaryText, height: 1.5),
          ),
          const SizedBox(height: 22),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: SelectableText(
                error!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          if (!receiver) ...[
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => action({
                          'action': state['enabled'] == true
                              ? 'renew'
                              : 'start',
                        }),
                  icon: const Icon(Icons.qr_code_rounded),
                  label: Text(
                    state['enabled'] == true
                        ? 'Nowy kod QR'
                        : 'Włącz parowanie',
                  ),
                ),
                if (state['enabled'] == true)
                  OutlinedButton(
                    onPressed: busy ? null : () => action({'action': 'stop'}),
                    child: const Text('Wyłącz transfer'),
                  ),
              ],
            ),
            if (state['enabled'] == true) ...[
              const SizedBox(height: 18),
              if ((state['addresses'] as List?)?.isNotEmpty == true)
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue:
                      ((state['addresses'] as List).contains(
                                Uri.tryParse(state['pairUri'] as String? ?? '')
                                    ?.queryParameters['host'],
                              )
                              ? Uri.tryParse(state['pairUri'] as String? ?? '')
                                    ?.queryParameters['host']
                              : state['addresses'][0])
                          as String?,
                  decoration: const InputDecoration(
                    labelText: 'Adres PC w Twojej sieci',
                  ),
                  items: [
                    for (final a in state['addresses'] as List)
                      DropdownMenuItem(value: a as String, child: Text(a)),
                  ],
                  onChanged: busy
                      ? null
                      : (v) => action({'action': 'renew', 'host': v}),
                ),
              const SizedBox(height: 16),
              if (qr != null)
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.memory(
                        qr!,
                        semanticLabel: 'Kod QR do sparowania telefonu',
                      ),
                    ),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'Kod wygasł lub został użyty. Wygeneruj nowy kod QR.',
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                'Kod jest jednorazowy i ważny przez 2 minuty.',
                style: TextStyle(color: secondaryText, fontSize: 12),
              ),
              if (state['pairUri'] != null)
                TextButton.icon(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: state['pairUri'] as String),
                  ),
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Kopiuj dane parowania'),
                ),
              Text(
                'Transfer: port ${state['port']}. Jeśli Windows zapyta o dostęp do sieci, zezwól dla sieci prywatnej.',
                style: const TextStyle(color: secondaryText, fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
            const Text(
              'Sparowane telefony',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            for (final p in peers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.smartphone_rounded, color: accent),
                title: Text(p['name'] as String),
                trailing: TextButton(
                  onPressed: busy
                      ? null
                      : () => action({'action': 'revoke', 'id': p['id']}),
                  child: const Text('Cofnij dostęp'),
                ),
              ),
          ] else ...[
            FilledButton.icon(
              onPressed: busy ? null : scan,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Skanuj kod z PC'),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Wklej dane parowania'),
              children: [
                TextField(
                  controller: link,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Dane skopiowane z Mytify na PC',
                  ),
                ),
                TextButton(
                  onPressed: busy ? null : () => pair(link.text),
                  child: const Text('Połącz z komputerem'),
                ),
              ],
            ),
            if (peers.isNotEmpty) ...[
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: ValueKey(peer),
                initialValue: peers.any((p) => p['id'] == peer) ? peer : null,
                decoration: const InputDecoration(labelText: 'Twój komputer'),
                items: [
                  for (final p in peers)
                    DropdownMenuItem(
                      value: p['id'] as String,
                      child: Text(
                        '${p['name']} · ${p['host']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (v) {
                        setState(() {
                          peer = v;
                          manifest = null;
                          selected.clear();
                          playlists.clear();
                        });
                      },
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: busy ? null : load,
                icon: const Icon(Icons.library_music_outlined),
                label: const Text('Pokaż muzykę z PC'),
              ),
              TextButton(
                onPressed: busy ? null : deleteCopies,
                child: const Text('Usuń kopie z tego PC z telefonu'),
              ),
            ],
            if (state['state'] != 'idle' && state['state'] != null) ...[
              const SizedBox(height: 18),
              AmbientSurface(
                active: state['state'] == 'downloading',
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${state['done'] ?? 0} / ${state['total'] ?? 0} utworów',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        (state['name'] as String?) ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: (state['totalBytes'] as num? ?? 0) > 0
                            ? ((state['doneBytes'] as num? ?? 0) /
                                      (state['totalBytes'] as num))
                                  .clamp(0.0, 1.0)
                            : 0,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${((state['doneBytes'] as num? ?? 0) / 1048576).toStringAsFixed(1)} / ${((state['totalBytes'] as num? ?? 0) / 1048576).toStringAsFixed(1)} MB',
                        style: const TextStyle(
                          color: secondaryText,
                          fontSize: 12,
                        ),
                      ),
                      if ((state['error'] as String?)?.isNotEmpty == true)
                        Text(
                          state['error'] as String,
                          style: const TextStyle(color: Colors.orangeAccent),
                        ),
                      if (state['state'] == 'complete')
                        const Text(
                          'Gotowe. Muzyka działa offline.',
                          style: TextStyle(color: accent),
                        ),
                      if (['downloading', 'queued'].contains(state['state']))
                        TextButton(
                          onPressed: () => action({'action': 'pause'}),
                          child: const Text('Wstrzymaj'),
                        )
                      else if (state['state'] == 'paused')
                        FilledButton(
                          onPressed: busy
                              ? null
                              : () => action({'action': 'resume'}),
                          child: const Text('Wznów pobieranie'),
                        ),
                      if (state['state'] == 'paused')
                        TextButton(
                          onPressed: busy ? null : discard,
                          child: const Text('Usuń niedokończone pobranie'),
                        ),
                      for (final w in (state['warnings'] as List? ?? []))
                        Text(
                          '$w',
                          style: const TextStyle(
                            color: Colors.orangeAccent,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            if (manifest != null) ...music(),
          ],
        ],
      ),
    );
  }

  List<Widget> music() {
    final tracks = (manifest!['tracks'] as List)
        .map((t) => Track.fromJson(Map<String, dynamic>.from(t as Map)))
        .toList();
    final groups = <String, List<Track>>{};
    for (final t in tracks) {
      groups.putIfAbsent(t.albumKey, () => []).add(t);
    }
    final lists = (manifest!['playlists'] as List?) ?? [];
    final chosen = {...selected};
    for (final p in lists) {
      if (playlists.contains(p['id'])) {
        chosen.addAll((p['ids'] as List).cast<String>());
      }
    }
    final bytes = tracks
        .where((t) => chosen.contains(t.id))
        .fold<int>(0, (a, t) => a + t.size);
    return [
      const SizedBox(height: 24),
      Text(
        'Albumy na PC · ${groups.length}',
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
      ),
      if (tracks.isEmpty)
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Na PC nie ma dostępnych plików. Dodaj muzykę lub podłącz źródło.',
          ),
        ),
      TextButton(
        onPressed: busy
            ? null
            : () => setState(() {
                if (selected.length == tracks.length) {
                  selected.clear();
                } else {
                  selected.addAll(tracks.map((t) => t.id));
                }
              }),
        child: Text(
          selected.length == tracks.length
              ? 'Odznacz wszystkie'
              : 'Zaznacz wszystkie',
        ),
      ),
      for (final group in groups.values)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: group.every((t) => selected.contains(t.id)),
          tristate: true,
          title: Text(
            group.first.displayAlbum,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${group.first.displayArtist} · ${collectionCount(group.length, 'utwór', 'utwory', 'utworów')}',
          ),
          secondary: const Icon(Icons.album_outlined, color: accent),
          onChanged: busy
              ? null
              : (v) => setState(() {
                  if (v == true) {
                    group.sort(albumOrder);
                    selected.addAll(group.map((t) => t.id));
                  } else {
                    selected.removeAll(group.map((t) => t.id));
                  }
                }),
        ),
      if (lists.isNotEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 20),
          child: Text(
            'Playlisty',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
        ),
      for (final p in lists)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: playlists.contains(p['id']),
          title: Text(p['name'] as String),
          subtitle: Text('${collectionCount((p['ids'] as List).length, 'utwór', 'utwory', 'utworów')}'),
          onChanged: busy
              ? null
              : (v) => setState(() {
                  if (v == true) {
                    playlists.add(p['id'] as String);
                  } else {
                    playlists.remove(p['id']);
                  }
                }),
        ),
      const SizedBox(height: 16),
      Text(
        'Wybrano ${collectionCount(chosen.length, 'utwór', 'utwory', 'utworów')} · ${(bytes / 1048576).toStringAsFixed(1)} MB',
        style: const TextStyle(color: secondaryText),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed:
            busy ||
                (selected.isEmpty && playlists.isEmpty) ||
                ['queued', 'downloading', 'paused'].contains(state['state'])
            ? null
            : () => action({
                'action': 'startDownload',
                'id': peer,
                'ids': selected.toList(),
                'playlists': playlists.toList(),
              }),
        icon: const Icon(Icons.download_rounded),
        label: Text('Pobierz na telefon'),
      ),
      const SizedBox(height: 8),
      const Text(
        'Oryginalne pliki, bez konwersji. Każdy plik jest sprawdzany sumą SHA-256.',
        style: TextStyle(color: secondaryText, fontSize: 12, height: 1.5),
      ),
    ];
  }
}
