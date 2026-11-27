import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'main.dart';
import 'model.dart';
import 'l10n.dart';

/// Readable text of a failed operation: no class names or stack traces.
String readableError(Object e) {
  final text = switch (e) {
    PlatformException(:final message) => message ?? '',
    StateError(:final message) => message,
    _ => e.toString(),
  };
  return text
      .replaceFirst(RegExp(r'^(Exception|Error|Bad state|JSError|TypeError): ?'), '')
      .trim()
      .ifEmptyThen(tr('Operacja nie powiodła się.'));
}

extension on String {
  String ifEmptyThen(String other) => isEmpty ? other : this;
}

/// Entries of "Dodaj źródło". Only protocols that really work here are listed.
List<({String protocol, String label, IconData icon})> networkKinds(List<String> protocols) => [
  if (protocols.contains('smb')) (protocol: 'smb', label: tr('Folder sieciowy SMB'), icon: Icons.lan_outlined),
  if (protocols.contains('webdav')) (protocol: 'webdav', label: tr('WebDAV (HTTPS)'), icon: Icons.cloud_outlined),
  if (protocols.contains('subsonic'))
    (protocol: 'subsonic', label: tr('Serwer muzyczny OpenSubsonic / Navidrome'), icon: Icons.dns_outlined),
];

Future<void> showNetworkSourceForm(LibraryScreenState app, {LibrarySource? source, String protocol = 'smb'}) async {
  final context = app.context;
  final form = NetworkSourceForm(app: app, source: source, protocol: source?.protocol ?? protocol);
  if (app.desktopMode) {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: panel,
        insetPadding: const EdgeInsets.all(Sp.xl),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: form),
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: panel,
      builder: (_) => form,
    );
  }
}

class NetworkSourceForm extends StatefulWidget {
  final LibraryScreenState app;
  final LibrarySource? source;
  final String protocol;
  const NetworkSourceForm({super.key, required this.app, this.source, required this.protocol});
  @override
  State<NetworkSourceForm> createState() => _NetworkSourceFormState();
}

enum _Status { idle, connecting, ok, failed }

class _NetworkSourceFormState extends State<NetworkSourceForm> {
  final name = TextEditingController();
  final url = TextEditingController();
  final host = TextEditingController();
  final share = TextEditingController();
  final folder = TextEditingController();
  final user = TextEditingController();
  final password = TextEditingController();
  final domain = TextEditingController();
  bool more = false, hasPassword = false, loading = false, saving = false, hidden = true;
  _Status status = _Status.idle;
  String statusText = '';
  Map<String, dynamic> original = const {};

  LibraryScreenState get app => widget.app;
  bool get server => widget.protocol == 'subsonic';
  bool get dav => widget.protocol == 'webdav' || server;

  /// Conversion is offered only where a mobile network exists, and is off by default.
  bool get mobileQuality => server && !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  String qualityWifi = 'original', qualityMobile = 'original';
  String? get id => widget.source?.id;

  @override
  void initState() {
    super.initState();
    if (id != null) {
      loading = true;
      unawaited(
        app.repository.sourceSettings(id!).then((s) {
          if (!mounted) return;
          setState(() {
            original = s;
            name.text = s['name'] as String? ?? '';
            url.text = s['url'] as String? ?? '';
            host.text = s['host'] as String? ?? '';
            share.text = s['share'] as String? ?? '';
            folder.text = s['folder'] as String? ?? '';
            user.text = s['user'] as String? ?? '';
            domain.text = s['domain'] as String? ?? '';
            more = domain.text.isNotEmpty;
            qualityWifi = s['qualityWifi'] as String? ?? 'original';
            qualityMobile = s['qualityMobile'] as String? ?? 'original';
            hasPassword = s['hasPassword'] == true;
            loading = false;
          });
        }).catchError((Object e) {
          if (mounted) setState(() {loading = false; status = _Status.failed; statusText = readableError(e);});
        }),
      );
    }
  }

  @override
  void dispose() {
    for (final c in [name, url, host, share, folder, user, password, domain]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> config() => {
    'protocol': widget.protocol,
    'name': name.text.trim(),
    if (dav) 'url': url.text.trim(),
    if (mobileQuality) 'qualityWifi': qualityWifi,
    if (mobileQuality) 'qualityMobile': qualityMobile,
    if (!dav) 'host': host.text.trim(),
    if (!dav) 'share': share.text.trim(),
    'folder': folder.text.trim(),
    'user': user.text.trim(),
    'domain': domain.text.trim(),
    // Empty while editing keeps the stored password.
    if (password.text.isNotEmpty || id == null) 'password': password.text,
  };

  Future<void> test() async {
    setState(() {status = _Status.connecting; statusText = tr('Łączenie…');});
    try {
      final result = await app.repository.testSource(config(), id: id);
      if (!mounted) return;
      setState(() {
        status = _Status.ok;
        statusText = result.message ??
            (result.folders.isEmpty ? tr('Połączono.') : tr('Połączono. Podfoldery: {0}.', [result.folders.length]));
      });
    } catch (e) {
      if (mounted) setState(() {status = _Status.failed; statusText = readableError(e);});
    }
  }

  Future<void> pickFolder() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => _FolderPicker(app: app, config: config(), id: id, start: folder.text),
    );
    if (chosen != null && mounted) setState(() => folder.text = chosen);
  }

  Future<void> save() async {
    setState(() {saving = true; status = _Status.connecting; statusText = tr('Łączenie…');});
    try {
      // Save only what works: the same login and folder check as the test button.
      await app.repository.testSource(config(), id: id);
      final saved = await app.repository.saveSource(config(), id: id);
      final moved = id == null ||
          (dav && original['url'] != url.text.trim()) ||
          original['host'] != host.text.trim() ||
          original['share'] != share.text.trim() ||
          original['folder'] != folder.text.trim();
      if (!mounted) return;
      Navigator.of(context).pop();
      await app.loadLibrary();
      if (moved) unawaited(app.scanSources(saved));
    } catch (e) {
      if (mounted) setState(() {saving = false; status = _Status.failed; statusText = readableError(e);});
    }
  }

  Widget field(TextEditingController c, String label, {String? hint, bool secret = false, Widget? suffix, TextInputType? type}) => Padding(
    padding: const EdgeInsets.only(bottom: Sp.m),
    child: TextField(
      controller: c,
      obscureText: secret && hidden,
      autocorrect: false,
      enableSuggestions: !secret,
      keyboardType: type,
      onChanged: (_) {
        if (status != _Status.idle && status != _Status.connecting) setState(() => status = _Status.idle);
      },
      decoration: InputDecoration(labelText: label, hintText: hint, suffixIcon: suffix, border: const OutlineInputBorder()),
    ),
  );

  Widget quality(String label, String value, ValueChanged<String> onChanged) => Padding(
    padding: const EdgeInsets.only(bottom: Sp.m),
    child: DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      items: [
        DropdownMenuItem(value: 'original', child: Text(tr('Oryginalna (bez kompresji)'))),
        DropdownMenuItem(value: 'saver', child: Text(tr('Oszczędzanie transferu (MP3 192 kb/s)'))),
      ],
      onChanged: (v) => onChanged(v ?? 'original'),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final editing = id != null;
    final busy = saving || status == _Status.connecting;
    final color = switch (status) {
      _Status.ok => accent,
      _Status.failed => dangerText,
      _ => secondaryText,
    };
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(Sp.xl, Sp.l, Sp.xl, Sp.xl + MediaQuery.viewInsetsOf(context).bottom + MediaQuery.viewPaddingOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            server
                ? (editing ? tr('Edytuj serwer muzyczny') : tr('Serwer muzyczny'))
                : dav
                ? (editing ? tr('Edytuj WebDAV') : tr('WebDAV'))
                : (editing ? tr('Edytuj folder sieciowy') : tr('Folder sieciowy SMB')),
            style: Txt.title,
          ),
          const SizedBox(height: 4),
          Text(
            server
                ? tr('OpenSubsonic, np. Navidrome.')
                : dav
                ? tr('Folder przez HTTPS, np. NAS z WebDAV.')
                : tr('Udział NAS-a lub komputera w sieci.'),
            style: Txt.sub,
          ),
          const SizedBox(height: Sp.l),
          if (loading)
            const Padding(padding: EdgeInsets.all(Sp.xl), child: Center(child: CircularProgressIndicator()))
          else ...[
            if (dav)
              field(
                url,
                tr('Adres serwera'),
                hint: server ? 'https://music.example.com' : 'https://nas.example.com:5006/music',
                type: TextInputType.url,
              )
            else ...[
              field(host, tr('Adres serwera'), hint: tr('np. nas.local lub 192.168.1.20'), type: TextInputType.url),
              field(share, tr('Udział'), hint: tr('np. music')),
            ],
            if (!server)
            field(
              folder,
              tr('Folder (opcjonalnie)'),
              hint: tr('cały udział'),
              suffix: IconButton(tooltip: tr('Wybierz folder'), icon: const Icon(Icons.folder_open_outlined), onPressed: busy ? null : pickFolder),
            ),
            field(user, tr('Użytkownik')),
            field(
              password,
              editing && hasPassword ? tr('Hasło (bez zmian)') : tr('Hasło'),
              secret: true,
              suffix: IconButton(
                tooltip: hidden ? tr('Pokaż hasło') : tr('Ukryj hasło'),
                icon: Icon(hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => hidden = !hidden),
              ),
            ),
            if (mobileQuality) ...[
              quality(tr('Jakość przez Wi-Fi'), qualityWifi, (v) => setState(() => qualityWifi = v)),
              quality(tr('Jakość w sieci komórkowej'), qualityMobile, (v) => setState(() => qualityMobile = v)),
            ],
            if (server && url.text.trim().startsWith('http://'))
              Padding(
                padding: EdgeInsets.only(bottom: Sp.m),
                child: Text(tr('Połączenie bez HTTPS nie jest szyfrowane. Używaj go tylko w sieci domowej.'), style: Txt.meta),
              ),
            if (more) ...[
              if (!dav) field(domain, tr('Domena (jeśli wymagana)')),
              field(name, tr('Nazwa w bibliotece'), hint: tr('domyślnie nazwa folderu')),
            ] else
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () => setState(() => more = true), child: Text(tr('Więcej opcji'))),
              ),
            AnimatedSize(
              duration: motion(context, Dur.standard),
              child: status == _Status.idle
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(bottom: Sp.m),
                      child: Row(
                        children: [
                          if (status == _Status.connecting)
                            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          else
                            Icon(status == _Status.ok ? Icons.check_circle_rounded : Icons.error_outline_rounded, size: 18, color: color),
                          const SizedBox(width: Sp.s),
                          Expanded(child: Text(statusText, style: Txt.meta.copyWith(color: color))),
                        ],
                      ),
                    ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Sp.s,
              runSpacing: Sp.s,
              children: [
                TextButton(onPressed: saving ? null : () => Navigator.of(context).pop(), child: Text(tr('Anuluj'))),
                OutlinedButton(onPressed: busy ? null : test, child: Text(tr('Sprawdź połączenie'))),
                FilledButton(onPressed: busy ? null : save, child: Text(editing ? tr('Zapisz') : tr('Dodaj i skanuj'))),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FolderPicker extends StatefulWidget {
  final LibraryScreenState app;
  final Map<String, dynamic> config;
  final String? id;
  final String start;
  const _FolderPicker({required this.app, required this.config, required this.id, required this.start});
  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  late List<String> path = widget.start.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
  List<String>? folders;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    setState(() {folders = null; error = null;});
    try {
      final list = await widget.app.repository.browseSource(widget.config, path.join('/'), id: widget.id);
      if (mounted) setState(() => folders = list);
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    }
  }

  void open(List<String> next) {
    path = next;
    unawaited(load());
  }

  @override
  Widget build(BuildContext context) {
    final share = widget.config['share'] as String? ?? Uri.tryParse(widget.config['url'] as String? ?? '')?.host ?? '';
    return AlertDialog(
      backgroundColor: panel,
      title: Text(path.isEmpty ? share : path.last, maxLines: 1, overflow: TextOverflow.ellipsis),
      contentPadding: const EdgeInsets.symmetric(vertical: Sp.s),
      content: SizedBox(
        width: 420,
        height: 360,
        child: error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(Sp.l), child: Text(error!, textAlign: TextAlign.center, style: Txt.sub)))
            : folders == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                children: [
                  if (path.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.arrow_upward_rounded),
                      title: Text(tr('W górę')),
                      onTap: () => open(path.sublist(0, path.length - 1)),
                    ),
                  if (folders!.isEmpty) Padding(padding: EdgeInsets.all(Sp.l), child: Text(tr('Brak podfolderów.'), style: Txt.sub)),
                  for (final f in folders!)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(f, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => open([...path, f]),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Anuluj'))),
        FilledButton(
          onPressed: error != null ? null : () => Navigator.of(context).pop(path.join('/')),
          child: Text(tr('Wybierz ten folder')),
        ),
      ],
    );
  }
}
