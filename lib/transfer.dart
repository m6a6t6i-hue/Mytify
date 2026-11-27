import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'progress.dart';
import 'design.dart';
import 'model.dart';
import 'l10n.dart';

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

  /// Phone only: this phone shares its own music with another phone.
  bool sharing = false;
  Timer? timer;
  bool get receiver => widget.repository.receivesTransfers;

  /// Shows the sharing side: the PC always, a phone in "Udostępnij".
  bool get sender => !receiver || sharing;

  Future<dynamic> _call(Map<String, dynamic> request) => receiver && sharing
      ? widget.repository.transfer({'action': 'share', 'request': request})
      : widget.repository.transfer(request);

  void _mode(bool share) {
    if (share == sharing || busy) return;
    // Leaving the sharing side closes the phone's server.
    if (sharing) unawaited(_call({'action': 'stop'}).catchError((Object _) => null));
    setState(() {
      sharing = share;
      state = {};
      qr = null;
      qrText = null;
      error = null;
      if (share) peer = null;
    });
    unawaited(refresh());
  }
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    if (sharing) unawaited(_call({'action': 'stop'}).catchError((Object _) => null));
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
      if (!sender && peer == null && peers.isNotEmpty) peer = peers.last['id'] as String;
    });
  }

  Future<void> refresh() async {
    if (polling || busy) return;
    polling = true;
    try {
      accept(await _call({'action': 'status'}));
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
      final value = await _call(request);
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
        title: Text(tr('Usunąć niedokończone pobranie?')),
        content: Text(
          tr('Usuniemy pliki częściowe. Utwory już dodane do biblioteki pozostaną w telefonie.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Anuluj')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Usuń pobranie')),
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
        title: Text(tr('Usunąć kopie z telefonu?')),
        content: Text(
          tr('Usuniemy pliki pobrane z tego urządzenia. Oryginały i muzyka z innych źródeł zostaną.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(tr('Anuluj')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr('Usuń kopie')),
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
            !receiver ? tr('Połącz telefon') : sharing ? tr('Udostępnij telefonowi') : tr('Z komputera lub telefonu'),
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -.8,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            !receiver
                ? tr('Na telefonie: Ustawienia, potem Z komputera lub telefonu. Oba urządzenia muszą być w tej samej sieci.')
                : sharing
                ? tr('Na drugim telefonie: Ustawienia, Z komputera lub telefonu, Skanuj kod.')
                : tr('Zeskanuj kod Mytify z komputera albo z drugiego telefonu i wybierz albumy. Pobrane utwory działają bez sieci.'),
            style: TextStyle(color: secondaryText, height: 1.5),
          ),
          if (receiver) ...[
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, icon: Icon(Icons.download_rounded), label: Text(tr('Odbierz'))),
                ButtonSegment(value: true, icon: Icon(Icons.upload_rounded), label: Text(tr('Udostępnij'))),
              ],
              selected: {sharing},
              showSelectedIcon: false,
              onSelectionChanged: busy ? null : (v) => _mode(v.first),
            ),
          ],
          const SizedBox(height: 22),
          if (busy) const LiveProgress(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: SelectableText(
                trMessage(error!),
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          if (sender) ...[
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
                        ? tr('Nowy kod QR')
                        : tr('Włącz parowanie'),
                  ),
                ),
                if (state['enabled'] == true)
                  OutlinedButton(
                    onPressed: busy ? null : () => action({'action': 'stop'}),
                    child: Text(tr('Wyłącz transfer')),
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
                  decoration: InputDecoration(
                    labelText: receiver ? tr('Adres telefonu w Twojej sieci') : tr('Adres PC w Twojej sieci'),
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
                        semanticLabel: tr('Kod QR do sparowania'),
                      ),
                    ),
                  ),
                )
              else
                Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    tr('Kod wygasł lub został użyty. Wygeneruj nowy kod QR.'),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                tr('Kod jest jednorazowy i ważny przez 2 minuty.'),
                style: TextStyle(color: secondaryText, fontSize: 12),
              ),
              if (state['pairUri'] != null)
                TextButton.icon(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: state['pairUri'] as String),
                  ),
                  icon: const Icon(Icons.copy_rounded),
                  label: Text(tr('Kopiuj dane parowania')),
                ),
              if (!receiver)
                Text(
                  tr('Transfer: port {0}. Jeśli Windows zapyta o dostęp do sieci, zezwól dla sieci prywatnej.', [state['port']]),
                  style: TextStyle(color: secondaryText, fontSize: 12),
                ),
            ],
            const SizedBox(height: 24),
            Text(
              receiver ? tr('Telefony z dostępem') : tr('Sparowane telefony'),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            for (final p in peers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.smartphone_rounded, color: accent),
                title: Text(p['name'] as String),
                trailing: TextButton(
                  onPressed: busy
                      ? null
                      : () => action({'action': 'revoke', 'id': p['id']}),
                  child: Text(tr('Cofnij dostęp')),
                ),
              ),
          ] else ...[
            FilledButton.icon(
              onPressed: busy ? null : scan,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(tr('Skanuj kod')),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(tr('Wklej dane parowania')),
              children: [
                TextField(
                  controller: link,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: tr('Dane skopiowane z drugiego urządzenia'),
                  ),
                ),
                TextButton(
                  onPressed: busy ? null : () => pair(link.text),
                  child: Text(tr('Połącz')),
                ),
              ],
            ),
            if (peers.isNotEmpty) ...[
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: ValueKey(peer),
                initialValue: peers.any((p) => p['id'] == peer) ? peer : null,
                decoration: InputDecoration(labelText: tr('Urządzenie')),
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
                label: Text(tr('Pokaż muzykę')),
              ),
              TextButton(
                onPressed: busy ? null : deleteCopies,
                child: Text(tr('Usuń z telefonu kopie z tego urządzenia')),
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
                        tr('{0} / {1} utworów', [state['done'] ?? 0, state['total'] ?? 0]),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        (state['name'] as String?) ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 10),
                      LiveProgress(
                        value: (state['totalBytes'] as num? ?? 0) > 0
                            ? ((state['doneBytes'] as num? ?? 0) / (state['totalBytes'] as num)).clamp(0.0, 1.0).toDouble()
                            : null,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr('{0} / {1} MB', [((state['doneBytes'] as num? ?? 0) / 1048576).toStringAsFixed(1), ((state['totalBytes'] as num? ?? 0) / 1048576).toStringAsFixed(1)]),
                        style: TextStyle(
                          color: secondaryText,
                          fontSize: 12,
                        ),
                      ),
                      if ((state['error'] as String?)?.isNotEmpty == true)
                        Text(
                          trMessage(state['error'] as String),
                          style: const TextStyle(color: Colors.orangeAccent),
                        ),
                      if (state['state'] == 'complete')
                        Text(
                          tr('Gotowe. Muzyka działa offline.'),
                          style: TextStyle(color: accent),
                        ),
                      if (['downloading', 'queued'].contains(state['state']))
                        TextButton(
                          onPressed: () => action({'action': 'pause'}),
                          child: Text(tr('Wstrzymaj')),
                        )
                      else if (state['state'] == 'paused')
                        FilledButton(
                          onPressed: busy
                              ? null
                              : () => action({'action': 'resume'}),
                          child: Text(tr('Wznów pobieranie')),
                        ),
                      if (state['state'] == 'paused')
                        TextButton(
                          onPressed: busy ? null : discard,
                          child: Text(tr('Usuń niedokończone pobranie')),
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
        tr('Albumy · {0}', [groups.length]),
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
      ),
      if (tracks.isEmpty)
        Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            tr('Na tym urządzeniu nie ma plików do pobrania.'),
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
              ? tr('Odznacz wszystkie')
              : tr('Zaznacz wszystkie'),
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
            '${group.first.displayArtist} · ${collectionCount(group.length, tr('utwór'), 'utwory', tr('utworów'))}',
          ),
          secondary: Icon(Icons.album_outlined, color: accent),
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
        Padding(
          padding: EdgeInsets.only(top: 20),
          child: Text(
            tr('Playlisty'),
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
        ),
      for (final p in lists)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: playlists.contains(p['id']),
          title: Text(p['name'] as String),
          subtitle: Text(collectionCount((p['ids'] as List).length, tr('utwór'), 'utwory', tr('utworów'))),
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
        tr('Wybrano {0} · {1} MB', [collectionCount(chosen.length, tr('utwór'), 'utwory', tr('utworów')), (bytes / 1048576).toStringAsFixed(1)]),
        style: TextStyle(color: secondaryText),
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
        label: Text(tr('Pobierz na telefon')),
      ),
      const SizedBox(height: 8),
      Text(
        tr('Oryginalne pliki, bez konwersji.'),
        style: TextStyle(color: secondaryText, fontSize: 12, height: 1.5),
      ),
    ];
  }
}
