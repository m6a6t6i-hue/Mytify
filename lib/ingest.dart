import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'model.dart';
import 'widgets.dart';

abstract interface class IngestRepository {
  Future<dynamic> ingest(Map<String, dynamic> request);
}

/// What the Audio CD tab shows. Each state comes from the engine or from an
/// action the user started here, never from a guess.
enum CdState { searching, noDrive, drive, noDisc, unsupported, readError, reading, ready, importing, done, failed }

String _readable(Object e) => '$e'
    .replaceFirst('Exception: ', '')
    .replaceFirst('Bad state: ', '')
    .replaceFirst('FormatException: ', '');

String _clock(num ms) {
  final s = ms.toInt() ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

String _markTime(num ms) => '${_clock(ms)}.${(ms.toInt() % 1000).toString().padLeft(3, '0')}';

/// Import from physical media. Lives as long as the app, so leaving the view or
/// switching tabs keeps the form, the read disc and a running job.
class IngestState extends ChangeNotifier {
  final IngestRepository repository;
  final LibraryRepository library;

  /// Called before level check and recording (pauses playback). Never on open.
  final Future<void> Function() beforeCapture;

  /// Called after files were added to the library.
  final Future<void> Function() onLibraryChanged;

  IngestState({
    required this.repository,
    required this.library,
    required this.beforeCapture,
    required this.onLibraryChanged,
  });

  int tab = 0;
  Map<String, dynamic> status = const {};
  List<Map<String, dynamic>>? drives;
  List<Map<String, dynamic>> inputs = [], sessions = [];
  Map<String, dynamic> folders = const {};
  String? drive, input, session;
  int rate = 48000;
  bool searching = false, reading = false, busy = false;

  /// Message from reading the disc (no disc, data disc, read error).
  String? cdProblem;

  /// Last action error, shown next to the action.
  String? error;
  Map<String, dynamic>? toc;
  List<bool> picked = [];

  /// Job started from this view: rip, monitor, record, export.
  String? job;
  final album = TextEditingController(),
      artist = TextEditingController(),
      label = TextEditingController(text: 'Winyl, strona A'),
      marks = TextEditingController();
  List<TextEditingController> titles = [];
  int _views = 0;
  Timer? _timer;
  bool _polling = false, _disposed = false;

  bool get running => status['running'] == true;
  String get stage => status['stage'] as String? ?? '';
  bool get recording => running && status['recording'] == true;
  bool get monitoring => running && stage == 'monitor';
  bool get ripping => running && stage == 'ripping';
  bool get exporting => running && stage == 'exporting';
  bool get capturing => monitoring || recording;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<dynamic> api(String action, [Map<String, dynamic> args = const {}]) =>
      repository.ingest({'action': action, ...args});

  /// The view became visible: list hardware. Starts nothing and changes no routing.
  void attach() {
    // After the current build: listeners elsewhere (toolbar status) must not rebuild mid-frame.
    if (_views++ == 0) scheduleMicrotask(() => unawaited(refresh()));
  }

  void detach() {
    if (_views > 0) _views--;
  }

  void setTab(int value) {
    tab = value;
    _changed();
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || !running) return;
    final period = capturing
        ? const Duration(milliseconds: 120)
        : Duration(milliseconds: _views > 0 ? 500 : 1000);
    _timer = Timer(period, () => unawaited(poll()));
  }

  Future<void> refresh() async {
    searching = true;
    error = null;
    _changed();
    try {
      final d = await api('drives') as List;
      final i = await api('inputs') as List;
      final s = await api('sessions') as List;
      final st = await api('state') as Map;
      Map<String, dynamic> f = const {};
      try {
        f = Map<String, dynamic>.from(await api('folders') as Map);
      } catch (_) {}
      drives = [
        for (final v in d)
          v is Map ? Map<String, dynamic>.from(v) : {'id': '$v', 'name': null},
      ];
      inputs = [for (final v in i) Map<String, dynamic>.from(v as Map)];
      sessions = [for (final v in s) Map<String, dynamic>.from(v as Map)];
      status = Map<String, dynamic>.from(st);
      folders = f;
      if (!drives!.any((x) => x['id'] == drive)) drive = drives!.firstOrNull?['id'] as String?;
      if (!inputs.any((x) => x['id'] == input)) input = inputs.firstOrNull?['id'] as String?;
      _fixRate();
      if (session != null && !sessions.any((x) => x['id'] == session)) session = null;
    } catch (e) {
      drives ??= const [];
      error = _readable(e);
    } finally {
      searching = false;
      _changed();
      _schedule();
    }
  }

  Map<String, dynamic>? get selectedInput => inputs.where((d) => d['id'] == input).firstOrNull;
  List<int> get rates => (selectedInput?['rates'] as List? ?? const []).cast<int>();

  /// Channels of the selected input; while measuring, what the engine really opened.
  int get channels {
    final live = (status['peaks'] as List?)?.length ?? 0;
    if (capturing && live > 0) return live;
    return ((selectedInput?['channels'] as num?)?.toInt() ?? 2).clamp(1, 2);
  }

  void _fixRate() {
    final r = rates;
    if (r.isNotEmpty && !r.contains(rate)) rate = r.contains(48000) ? 48000 : r.first;
  }

  void selectInput(String? id) {
    input = id;
    _fixRate();
    _changed();
  }

  void selectRate(int value) {
    rate = value;
    _changed();
  }

  void selectDrive(String? id) {
    drive = id;
    toc = null;
    cdProblem = null;
    _changed();
  }

  Future<void> poll() async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      final wasRunning = running;
      status = Map<String, dynamic>.from(await api('state') as Map);
      if (wasRunning && !running) await _finished();
    } catch (e) {
      error = _readable(e);
    } finally {
      _polling = false;
      _changed();
      _schedule();
    }
  }

  Future<void> _finished() async {
    try {
      sessions = [for (final v in await api('sessions') as List) Map<String, dynamic>.from(v as Map)];
    } catch (_) {}
    if (job == 'record') {
      final id = status['session'] as String?;
      if (id != null && sessions.any((s) => s['id'] == id)) selectSession(id);
    }
    if ((job == 'rip' || job == 'export') && (status['files'] as List? ?? const []).isNotEmpty) {
      await onLibraryChanged();
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    error = null;
    _changed();
    try {
      await action();
    } catch (e) {
      error = _readable(e);
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> _start(String name, String action, Map<String, dynamic> args) async {
    status = Map<String, dynamic>.from(await api(action, args) as Map);
    job = name;
    _changed();
    _schedule();
  }

  // ------------------------------------------------------------------ Audio CD

  CdState get cd {
    if (job == 'rip') {
      if (ripping) return CdState.importing;
      if (stage == 'error') return CdState.failed;
      if (stage == 'finished' || stage == 'cancelled') return CdState.done;
    }
    if (drives == null || (searching && drives!.isEmpty)) return CdState.searching;
    if (drives!.isEmpty) return CdState.noDrive;
    if (reading) return CdState.reading;
    if (toc != null) return CdState.ready;
    final p = cdProblem;
    if (p != null) {
      if (p.contains('Brak płyty')) return CdState.noDisc;
      if (p.contains('danymi') || p.contains('tabel') || p.contains('Nieprawidłow')) {
        return CdState.unsupported;
      }
      return CdState.readError;
    }
    return CdState.drive;
  }

  String driveName(Map<String, dynamic> d) {
    final name = d['name'] as String?;
    return name == null || name.isEmpty ? 'Napęd ${d['id']}' : '$name (${d['id']})';
  }

  List<Map<String, dynamic>> get tracks => [
    for (final t in toc?['tracks'] as List? ?? const []) Map<String, dynamic>.from(t as Map),
  ];

  /// Track length from the table of contents (75 sectors per second).
  int trackMs(Map<String, dynamic> t) {
    final start = (t['start'] as num?)?.toInt(), end = (t['end'] as num?)?.toInt();
    return start == null || end == null ? 0 : (end - start) * 1000 ~/ 75;
  }

  void _setTitles(List<String> value) {
    for (final c in titles) {
      c.dispose();
    }
    titles = [for (final s in value) TextEditingController(text: s)];
  }

  Future<void> readCd() async {
    if (drive == null || reading) return;
    reading = true;
    cdProblem = null;
    toc = null;
    error = null;
    _changed();
    try {
      final value = Map<String, dynamic>.from(await api('toc', {'drive': drive}) as Map);
      toc = value;
      final n = (value['tracks'] as List).length;
      _setTitles(List.generate(n, (i) => 'Utwór ${i + 1}'));
      picked = List.filled(n, true);
    } catch (e) {
      cdProblem = _readable(e);
    } finally {
      reading = false;
      _changed();
    }
  }

  void pick(int i, bool value) {
    picked[i] = value;
    _changed();
  }

  void pickAll(bool value) {
    picked = List.filled(picked.length, value);
    _changed();
  }

  /// MusicBrainz lookup by disc id; the caller shows the choice.
  Future<List<ReleaseCandidate>> releases() async => [
    for (final v in await api('disc', {'id': toc!['discId']}) as List)
      ReleaseCandidate.fromJson(Map<String, dynamic>.from(v as Map)),
  ];

  Future<ReleaseInfo> release(String id) => library.releaseDetails(id);

  /// Discs of [info] whose track count matches the read disc.
  List<int> matchingDiscs(ReleaseInfo info) => info.tracks
      .map((t) => t.discNumber)
      .toSet()
      .where((n) => info.tracks.where((t) => t.discNumber == n).length == tracks.length)
      .toList();

  void applyRelease(ReleaseInfo info, int disc) {
    album.text = info.release.title;
    artist.text = info.release.artist;
    _setTitles(info.tracks.where((t) => t.discNumber == disc).map((t) => t.title).toList());
    _changed();
  }

  Future<void> rip() => _act(() async {
    await _start('rip', 'rip', {
      'drive': drive,
      'discId': toc!['discId'],
      'album': album.text,
      'artist': artist.text,
      'titles': [for (final t in titles) t.text],
      'tracks': [
        for (var i = 0; i < tracks.length; i++)
          if (picked[i]) tracks[i]['number'],
      ],
    });
  });

  Future<void> stop() => _act(() async {
    await api('stop');
    await poll();
  });

  void nextDisc() {
    job = null;
    toc = null;
    cdProblem = null;
    album.clear();
    artist.clear();
    _setTitles([]);
    picked = [];
    _changed();
  }

  // ------------------------------------------------------------- Vinyl, tape

  Future<void> _stopCapture() async {
    if (!running) return;
    await api('stop');
    for (var i = 0; i < 30 && running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      status = Map<String, dynamic>.from(await api('state') as Map);
    }
  }

  Future<void> monitor() => _act(() async {
    await beforeCapture();
    await _start('monitor', 'monitor', {'id': input, 'rate': rate});
  });

  Future<void> record() => _act(() async {
    if (monitoring) await _stopCapture();
    await beforeCapture();
    await _start('record', 'record', {'id': input, 'rate': rate, 'label': label.text});
  });

  Future<void> mark() => _act(() async {
    await api('mark');
    await poll();
  });

  Future<void> openFolder() => _act(() async {
    await api('openFolder');
  });

  void selectSession(String id) {
    final s = sessions.firstWhere((s) => s['id'] == id);
    session = id;
    final points = [for (final m in (s['markers'] as List? ?? const []).cast<num>()) if (m > 0) m];
    marks.text = points.map(_markTime).join('\n');
    _setTitles(List.generate(points.length + 1, (i) => 'Utwór ${i + 1}'));
    _changed();
  }

  Map<String, dynamic>? get selectedSession => sessions.where((s) => s['id'] == session).firstOrNull;

  List<int> parseMarks() {
    final out = <int>[];
    for (final value in marks.text.split(RegExp(r'[,;\n]'))) {
      final text = value.trim();
      if (text.isEmpty) continue;
      final p = text.split(':');
      final seconds = p.length == 1
          ? double.parse(p[0])
          : p.length == 2
          ? int.parse(p[0]) * 60 + double.parse(p[1])
          : int.parse(p[0]) * 3600 + int.parse(p[1]) * 60 + double.parse(p[2]);
      if (!seconds.isFinite || seconds < 0) throw const FormatException('Nieprawidłowy czas znacznika');
      out.add((seconds * 1000).round());
    }
    return out;
  }

  Future<void> analyze() => _act(() async {
    final points = (await api('analyze', {'id': session}) as List).cast<num>();
    marks.text = points.map(_markTime).join('\n');
    _setTitles(List.generate(points.length + 1, (i) => 'Utwór ${i + 1}'));
  });

  Future<void> applyMarks() => _act(() async {
    final points = parseMarks();
    _setTitles(List.generate(points.length + 1, (i) => i < titles.length ? titles[i].text : 'Utwór ${i + 1}'));
  });

  Future<void> recover() => _act(() async {
    await api('recover', {'id': session});
    sessions = [for (final v in await api('sessions') as List) Map<String, dynamic>.from(v as Map)];
  });

  Future<void> export() => _act(() async {
    await _start('export', 'export', {
      'id': session,
      'album': album.text,
      'artist': artist.text,
      'markers': parseMarks(),
      'titles': [for (final t in titles) t.text],
    });
  });

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final c in [album, artist, label, marks, ...titles]) {
      c.dispose();
    }
    super.dispose();
  }
}

/// "Import": Audio CD and vinyl or tape, inside the normal app layout.
class IngestView extends StatefulWidget {
  final IngestState state;
  final EdgeInsets padding;
  const IngestView({super.key, required this.state, this.padding = const EdgeInsets.fromLTRB(Sp.xl, Sp.xl, Sp.xl, Sp.xxl)});
  @override
  State<IngestView> createState() => _IngestViewState();
}

class _IngestViewState extends State<IngestView> {
  IngestState get s => widget.state;
  bool help = false;

  @override
  void initState() {
    super.initState();
    s.attach();
  }

  @override
  void dispose() {
    s.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: s,
    builder: (context, _) => ListView(
      key: const PageStorageKey('import'),
      padding: widget.padding,
      children: [
        const Text('Import', style: Txt.display),
        const SizedBox(height: Sp.l),
        TextTabs(
          labels: const ['Audio CD', 'Winyl i kaseta'],
          index: s.tab,
          onChanged: s.setTab,
          busy: [s.ripping, s.capturing || s.exporting],
        ),
        const SizedBox(height: Sp.xl),
        if (s.tab == 0) ..._cd() else ..._analog(),
      ],
    ),
  );

  // ---------------------------------------------------------------- shared bits

  Widget _error(String text) => Padding(
    padding: const EdgeInsets.only(top: Sp.m),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline_rounded, size: 18, color: Color(0xffff8a8a)),
        const SizedBox(width: Sp.s),
        Expanded(child: SelectableText(text, style: const TextStyle(fontSize: 13.5, color: Color(0xffffb4b4)))),
      ],
    ),
  );

  Widget _warning(String text) => Padding(
    padding: const EdgeInsets.only(top: Sp.s),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xffffb454)),
        const SizedBox(width: Sp.s),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5, color: Color(0xffffd59a)))),
      ],
    ),
  );

  Widget _field(TextEditingController c, String label, {bool enabled = true}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Ctl.label),
      const SizedBox(height: Sp.xs),
      TextField(controller: c, enabled: enabled, style: Ctl.fieldText, decoration: Ctl.field()),
    ],
  );

  Widget _panel(Widget child) => Container(
    padding: const EdgeInsets.all(Sp.xl),
    decoration: BoxDecoration(
      color: panel,
      borderRadius: BorderRadius.circular(Rad.panel),
      border: Border.all(color: softBorder),
    ),
    child: child,
  );

  Widget _dropdown<T>({
    required T? value,
    required List<(T, String)> items,
    required ValueChanged<T?>? onChanged,
    String? semantics,
  }) => DropdownButtonFormField<T>(
    key: ValueKey('$semantics:$value:${items.length}'),
    initialValue: items.any((i) => i.$1 == value) ? value : null,
    isExpanded: true,
    isDense: true,
    style: Ctl.fieldText.copyWith(color: primaryText),
    decoration: Ctl.field(),
    dropdownColor: elevated,
    items: [
      for (final (v, label) in items)
        DropdownMenuItem(value: v, child: Text(label, overflow: TextOverflow.ellipsis)),
    ],
    onChanged: onChanged,
  );

  // ------------------------------------------------------------------ Audio CD

  Widget _steps(CdState st) {
    final step = switch (st) {
      CdState.ready => 1,
      CdState.importing || CdState.done || CdState.failed => 2,
      _ => 0,
    };
    final finished = st == CdState.done;
    Widget dot(int i, String label) {
      final done = i < step || (finished && i == step);
      final on = i == step;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on || done ? accent : elevated,
            ),
            child: done
                ? const Icon(Icons.check_rounded, size: 16, color: onAccent)
                : Text('${i + 1}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: on ? onAccent : secondaryText)),
          ),
          const SizedBox(width: Sp.s),
          Text(label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: on ? primaryText : secondaryText)),
        ],
      );
    }

    Widget link() => Container(width: 32, height: 1, margin: const EdgeInsets.symmetric(horizontal: Sp.m), color: softBorder);
    return Semantics(
      label: 'Etap ${step + 1} z 3',
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: Sp.s,
        children: [dot(0, 'Napęd'), link(), dot(1, 'Utwory'), link(), dot(2, 'Zapis')],
      ),
    );
  }

  Widget _empty({required IconData icon, required String title, required String text, Widget? action}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Sp.xl),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 56, color: secondaryText),
        const SizedBox(width: Sp.xl),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: Sp.s),
              Text(text, style: const TextStyle(fontSize: 14, color: secondaryText)),
              if (action != null) ...[const SizedBox(height: Sp.l), action],
            ],
          ),
        ),
      ],
    ),
  );

  List<Widget> _cd() {
    final st = s.cd;
    final idle = !s.busy && !s.running;
    return [
      _steps(st),
      const SizedBox(height: Sp.l),
      switch (st) {
        CdState.searching => _empty(
          icon: Icons.album_outlined,
          title: 'Szukam napędów',
          text: 'To potrwa chwilę.',
          action: const SizedBox(width: 120, child: LinearProgressIndicator()),
        ),
        CdState.noDrive => _empty(
          icon: Icons.album_outlined,
          title: 'Nie wykryto napędu',
          text: 'Podłącz napęd USB i odśwież listę.',
          action: FilledButton(style: Ctl.filled, onPressed: s.searching ? null : () => unawaited(s.refresh()), child: const Text('Odśwież')),
        ),
        CdState.importing => _ripProgress(),
        CdState.done => _ripDone(),
        CdState.failed => _ripFailed(),
        _ => _driveAndTracks(st, idle),
      },
      if (s.error != null) _error(s.error!),
      const SizedBox(height: Sp.xl),
      const Collapsible(
        title: 'Obsługiwane płyty',
        child: Text(
          'Płyty Audio CD (CD-DA), odczyt cyfrowy bez strat. Płyty ze ścieżkami danych '
          '(CD-Extra, CD-ROM), DVD i Blu-ray nie są obsługiwane.\n'
          'Każdy fragment jest odczytywany co najmniej dwa razy i porównywany, rozbieżności trafiają do raportu. '
          'To nie jest weryfikacja AccurateRip.',
          style: TextStyle(fontSize: 13.5, color: secondaryText, height: 1.45),
        ),
      ),
    ];
  }

  Widget _driveRow(bool idle) => Row(
    children: [
      Expanded(
        child: _dropdown<String>(
          semantics: 'drive',
          value: s.drive,
          items: [for (final d in s.drives ?? const <Map<String, dynamic>>[]) (d['id'] as String, s.driveName(d))],
          onChanged: idle && !s.reading ? s.selectDrive : null,
        ),
      ),
      const SizedBox(width: Sp.s),
      s.searching
          ? const SizedBox(width: 36, height: 36, child: Padding(padding: EdgeInsets.all(9), child: CircularProgressIndicator(strokeWidth: 2)))
          : IconAction(Icons.refresh_rounded, 'Odśwież listę napędów', idle && !s.reading ? () => unawaited(s.refresh()) : null, color: secondaryText),
    ],
  );

  Widget _driveAndTracks(CdState st, bool idle) {
    final problem = switch (st) {
      CdState.noDisc => 'Brak płyty w napędzie. Włóż płytę Audio CD i wybierz Odczytaj.',
      CdState.unsupported => '${s.cdProblem} Zobacz „Obsługiwane płyty”.',
      CdState.readError => s.cdProblem,
      _ => null,
    };
    final tracks = s.tracks;
    final chosen = s.picked.where((p) => p).length;
    final total = [for (var i = 0; i < tracks.length; i++) if (s.picked[i]) s.trackMs(tracks[i])].fold(0, (a, b) => a + b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Napęd', style: Ctl.label),
        const SizedBox(height: Sp.xs),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: _driveRow(idle)),
        const SizedBox(height: Sp.m),
        if (st == CdState.reading)
          const Row(
            children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: Sp.s),
              Text('Odczytuję spis utworów…', style: TextStyle(fontSize: 13.5)),
            ],
          )
        else if (st != CdState.ready)
          FilledButton(style: Ctl.filled, onPressed: idle && s.drive != null ? () => unawaited(s.readCd()) : null, child: const Text('Odczytaj')),
        if (problem != null)
          st == CdState.noDisc ? _warning(problem) : _error(problem),
        if (st == CdState.ready) ...[
          const SectionTitle('Utwory'),
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('${trackCount(tracks.length)} · ${_clock(tracks.fold(0, (a, t) => a + s.trackMs(t)))}', style: const TextStyle(fontSize: 13.5)),
              const SizedBox(width: Sp.s),
              OutlinedButton(style: Ctl.outlined, onPressed: idle ? () => unawaited(_recognize()) : null, child: const Text('Rozpoznaj w MusicBrainz')),
              TextButton(style: Ctl.text, onPressed: idle ? s.readCd : null, child: const Text('Odczytaj ponownie')),
            ],
          ),
          const SizedBox(height: Sp.l),
          LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 640;
              final a = _field(s.album, 'Album', enabled: idle), b = _field(s.artist, 'Wykonawca albumu', enabled: idle);
              return wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: Sp.l), Expanded(child: b)])
                  : Column(children: [a, const SizedBox(height: Sp.m), b]);
            },
          ),
          const SizedBox(height: Sp.l),
          Row(
            children: [
              Checkbox(
                tristate: true,
                value: chosen == tracks.length ? true : chosen == 0 ? false : null,
                onChanged: idle ? (_) => s.pickAll(chosen != tracks.length) : null,
              ),
              Text('Zaznaczone: $chosen z ${tracks.length}', style: Ctl.label),
            ],
          ),
          for (var i = 0; i < tracks.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.xs),
              child: Row(
                children: [
                  Checkbox(value: s.picked[i], onChanged: idle ? (v) => s.pick(i, v ?? false) : null),
                  SizedBox(
                    width: 28,
                    child: Text('${tracks[i]['number'] ?? i + 1}', textAlign: TextAlign.right, style: Ctl.label),
                  ),
                  const SizedBox(width: Sp.m),
                  Expanded(
                    child: TextField(
                      controller: s.titles[i],
                      enabled: idle,
                      style: Ctl.fieldText,
                      decoration: Ctl.field(),
                    ),
                  ),
                  const SizedBox(width: Sp.m),
                  SizedBox(
                    width: 52,
                    child: Text(_clock(s.trackMs(tracks[i])), textAlign: TextAlign.right, style: Ctl.label),
                  ),
                ],
              ),
            ),
          const SectionTitle('Zapis'),
          const InfoRow('Format', 'FLAC bez strat, 16 bit / 44,1 kHz, z opisem albumu'),
          if (s.folders['cd'] != null) InfoRow('Folder', '${s.folders['cd']}'),
          const SizedBox(height: Sp.m),
          FilledButton.icon(
            style: Ctl.filled,
            onPressed: idle && chosen > 0 ? () => unawaited(s.rip()) : null,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(chosen == tracks.length ? 'Importuj' : 'Importuj zaznaczone ($chosen)'),
          ),
          if (chosen > 0)
            Padding(
              padding: const EdgeInsets.only(top: Sp.s),
              child: Text('Do odczytu: ${_clock(total)} muzyki.', style: Ctl.label),
            ),
        ],
      ],
    );
  }

  Future<void> _recognize() async {
    try {
      final list = await s.releases();
      if (!mounted) return;
      if (list.isEmpty) {
        s.error = 'Nie znaleziono tej płyty w MusicBrainz. Wpisz nazwy ręcznie.';
        setState(() {});
        return;
      }
      final selected = await showDialog<ReleaseCandidate>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Wybierz wydanie'),
          children: [
            for (final r in list)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, r),
                child: ListTile(title: Text(r.title), subtitle: Text(r.description)),
              ),
          ],
        ),
      );
      if (selected == null) return;
      final info = await s.release(selected.id);
      final discs = s.matchingDiscs(info);
      if (discs.isEmpty) {
        s.error = 'Liczba utworów wydania nie pasuje do płyty. Wybierz inne wydanie lub wpisz nazwy ręcznie.';
        setState(() {});
        return;
      }
      int? disc = discs.first;
      if (discs.length > 1 && mounted) {
        disc = await showDialog<int>(
          context: context,
          builder: (c) => SimpleDialog(
            title: const Text('Który krążek?'),
            children: [
              for (final n in discs)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(c, n),
                  child: Text('Płyta $n · ${info.tracks.firstWhere((t) => t.discNumber == n).title}…'),
                ),
            ],
          ),
        );
      }
      if (disc != null) s.applyRelease(info, disc);
    } catch (e) {
      s.error = _readable(e);
      if (mounted) setState(() {});
    }
  }

  Widget _ripProgress() {
    final done = (s.status['done'] as num? ?? 0).toDouble();
    final total = (s.status['total'] as num? ?? 0).toDouble();
    final files = (s.status['files'] as List? ?? const []).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(total > 0 ? 'Importowanie: ${(done * 100 / total).clamp(0, 100).round()}%' : 'Importowanie', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: Sp.m),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: LinearProgressIndicator(value: total > 0 ? (done / total).clamp(0, 1) : null),
        ),
        const SizedBox(height: Sp.s),
        Text('Gotowe pliki: $files', style: Ctl.label),
        for (final w in s.status['warnings'] as List? ?? const []) _warning('$w'),
        const SizedBox(height: Sp.l),
        OutlinedButton(style: Ctl.outlined, onPressed: s.busy ? null : () => unawaited(s.stop()), child: const Text('Zatrzymaj i zachowaj gotowe pliki')),
      ],
    );
  }

  Widget _ripDone() {
    final files = (s.status['files'] as List? ?? const []);
    final cancelled = s.stage == 'cancelled';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          files.isEmpty
              ? 'Import zatrzymany, nic nie zapisano'
              : '${cancelled ? 'Import zatrzymany. ' : ''}Dodano do biblioteki: ${trackCount(files.length)}',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        for (final w in s.status['warnings'] as List? ?? const []) _warning('$w'),
        const SizedBox(height: Sp.m),
        for (final f in files) Text('$f', style: Ctl.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: Sp.l),
        FilledButton(style: Ctl.filled, onPressed: s.nextDisc, child: const Text('Importuj kolejną płytę')),
      ],
    );
  }

  Widget _ripFailed() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Import przerwany', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      _error('${s.status['error'] ?? 'Nieznany błąd'}'),
      if ((s.status['files'] as List? ?? const []).isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Sp.s),
          child: Text('Zachowano gotowe pliki: ${(s.status['files'] as List).length}', style: Ctl.label),
        ),
      const SizedBox(height: Sp.l),
      FilledButton(style: Ctl.filled, onPressed: s.nextDisc, child: const Text('Spróbuj ponownie')),
    ],
  );

  // -------------------------------------------------------------- Vinyl, tape

  List<Widget> _analog() => [
    LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 760;
        final input = _input(), rec = _recording();
        return _panel(
          wide
              ? IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: input),
                      const Padding(padding: EdgeInsets.symmetric(horizontal: Sp.xl), child: VerticalDivider(width: 1, color: softBorder)),
                      Expanded(child: rec),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [input, const Padding(padding: EdgeInsets.symmetric(vertical: Sp.xl), child: Divider(height: 1, color: softBorder)), rec],
                ),
        );
      },
    ),
    if (s.error != null) _error(s.error!),
    const SizedBox(height: Sp.l),
    _export(),
  ];

  Widget _input() {
    final idle = !s.busy && !s.running;
    final rates = s.rates;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Wejście', style: Ctl.section)),
            IconAction(Icons.help_outline_rounded, help ? 'Ukryj pomoc' : 'Jak podłączyć gramofon lub magnetofon', () => setState(() => help = !help), color: secondaryText),
          ],
        ),
        if (help)
          Container(
            margin: const EdgeInsets.only(top: Sp.s),
            padding: const EdgeInsets.all(Sp.m),
            decoration: BoxDecoration(color: elevated, borderRadius: BorderRadius.circular(Rad.control)),
            child: const Text(
              'Gramofon: przez przedwzmacniacz PHONO do wejścia liniowego karty dźwiękowej albo gramofon z wyjściem USB. '
              'Magnetofon: z wyjścia LINE OUT do wejścia liniowego.\n'
              'Ustaw poziom na najgłośniejszym fragmencie płyty: szczyty od -12 do -6 dBFS, bez przesterowań.',
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
          ),
        const SizedBox(height: Sp.m),
        const Text('Urządzenie wejściowe', style: Ctl.label),
        const SizedBox(height: Sp.xs),
        if (s.inputs.isEmpty && !s.searching)
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Nie wykryto wejścia audio. Podłącz interfejs USB lub włącz wejście w ustawieniach dźwięku Windows.',
                  style: TextStyle(fontSize: 13.5),
                ),
              ),
              IconAction(Icons.refresh_rounded, 'Odśwież listę wejść', () => unawaited(s.refresh()), color: secondaryText),
            ],
          )
        else
          Row(
            children: [
              Expanded(
                child: _dropdown<String>(
                  semantics: 'input',
                  value: s.input,
                  items: [for (final d in s.inputs) (d['id'] as String, '${d['name']}')],
                  onChanged: idle ? s.selectInput : null,
                ),
              ),
              const SizedBox(width: Sp.s),
              s.searching
                  ? const SizedBox(width: 36, height: 36, child: Padding(padding: EdgeInsets.all(9), child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconAction(Icons.refresh_rounded, 'Odśwież listę wejść', idle ? () => unawaited(s.refresh()) : null, color: secondaryText),
            ],
          ),
        const SizedBox(height: Sp.s),
        Collapsible(
          title: 'Zaawansowane',
          card: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Częstotliwość nagrania', style: Ctl.label),
              const SizedBox(height: Sp.xs),
              if (rates.length > 1)
                _dropdown<int>(
                  semantics: 'rate',
                  value: s.rate,
                  items: [for (final r in rates) (r, '${(r / 1000).toString().replaceAll('.', ',')} kHz')],
                  onChanged: idle ? (v) => s.selectRate(v ?? s.rate) : null,
                )
              else
                Text(rates.isEmpty ? 'Po wybraniu wejścia' : '${(rates.first / 1000).toString().replaceAll('.', ',')} kHz', style: Ctl.fieldText),
              const SizedBox(height: Sp.m),
              const Text('Format nagrania', style: Ctl.label),
              const SizedBox(height: Sp.xs),
              const Text('WAV 24 bit, bez odszumiania i normalizacji', style: Ctl.fieldText),
              const SizedBox(height: Sp.m),
              const Text('Folder nagrań', style: Ctl.label),
              const SizedBox(height: Sp.xs),
              Row(
                children: [
                  Expanded(
                    child: Text('${s.folders['recordings'] ?? 'Folder danych aplikacji'}', style: Ctl.fieldText, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                  IconAction(Icons.folder_open_outlined, 'Otwórz folder nagrań', s.busy ? null : () => unawaited(s.openFolder()), color: secondaryText),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: Sp.xl, color: softBorder),
        const Text('Poziom wejścia', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: Sp.m),
        _meters(),
        const SizedBox(height: Sp.m),
        if (s.monitoring)
          OutlinedButton(style: Ctl.outlined, onPressed: s.busy ? null : () => unawaited(s.stop()), child: const Text('Zakończ podgląd'))
        else
          OutlinedButton(
            style: Ctl.outlined,
            onPressed: idle && s.input != null ? () => unawaited(s.monitor()) : null,
            child: const Text('Sprawdź poziom'),
          ),
      ],
    );
  }

  Widget _meters() {
    final live = s.capturing;
    final peaks = [for (final p in s.status['peaks'] as List? ?? const []) (p as num).toDouble()];
    final n = s.channels;
    final clips = (s.status['clips'] as num? ?? 0).toInt();
    final dropouts = (s.status['dropouts'] as num? ?? 0).toInt();
    Widget meter(String name, double peak) {
      final db = peak > 0 ? 20 * math.log(peak) / math.ln10 : -90.0;
      final fill = live ? ((db + 60) / 60).clamp(0.0, 1.0) : 0.0;
      final color = db > -1 ? const Color(0xffff5252) : db > -6 ? const Color(0xffffb454) : accent;
      return Padding(
        padding: const EdgeInsets.only(bottom: Sp.s),
        child: Row(
          children: [
            SizedBox(width: 16, child: Text(name, style: Ctl.label)),
            Expanded(
              child: Semantics(
                label: 'Poziom kanału $name',
                value: live ? '${db.toStringAsFixed(1)} dBFS' : 'wyłączony',
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(color: elevated, borderRadius: BorderRadius.circular(4)),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: fill,
                    child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 76,
              child: Text(
                live ? (db <= -89 ? '−∞ dBFS' : '${db.toStringAsFixed(1)} dBFS') : '',
                textAlign: TextAlign.right,
                style: Ctl.label.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (n == 1)
          meter('M', peaks.firstOrNull ?? 0)
        else ...[
          meter('L', peaks.elementAtOrNull(0) ?? 0),
          meter('R', peaks.elementAtOrNull(1) ?? 0),
        ],
        if (!live) const Text('Podgląd wyłączony', style: Ctl.label),
        if (live && clips > 0) _error('Przesterowanie: ${collectionCount(clips, 'próbka', 'próbki', 'próbek')}. Zmniejsz poziom na przedwzmacniaczu lub w Windows.'),
        if (live && dropouts > 0) _warning('Utracone próbki: $dropouts. Zamknij inne programy korzystające z wejścia.'),
      ],
    );
  }

  Widget _recording() {
    final frames = (s.status['frames'] as num? ?? 0).toDouble();
    final hz = (s.status['rate'] as num? ?? s.rate).toDouble();
    final ms = s.recording ? frames * 1000 / (hz > 0 ? hz : s.rate) : 0.0;
    final markers = (s.status['markers'] as List? ?? const []).cast<num>();
    final idle = !s.busy && !s.running;
    final state = s.recording
        ? 'Nagrywanie'
        : s.monitoring
        ? 'Podgląd poziomu, nic nie jest zapisywane'
        : s.job == 'record' && s.stage == 'error'
        ? 'Nagranie przerwane'
        : s.job == 'record' && (s.stage == 'finished' || s.stage == 'cancelled')
        ? 'Nagranie zapisane'
        : 'Nagranie nie zostało rozpoczęte';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Nagranie', style: Ctl.section),
        const SizedBox(height: Sp.m),
        _field(s.label, 'Nazwa nagrania', enabled: idle || s.monitoring),
        const SizedBox(height: Sp.xl),
        Center(
          child: Text(
            _clock(ms),
            style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w300, fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s.recording) ...[
                Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xffff5252), shape: BoxShape.circle)),
                const SizedBox(width: Sp.s),
              ],
              Flexible(child: Text(state, style: Ctl.label, textAlign: TextAlign.center)),
            ],
          ),
        ),
        if (s.job == 'record' && s.stage == 'error' && s.status['error'] != null) _error('${s.status['error']}'),
        const SizedBox(height: Sp.l),
        Center(
          child: s.recording
              ? Wrap(
                  spacing: Sp.s,
                  runSpacing: Sp.s,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      style: Ctl.filled,
                      onPressed: s.busy ? null : () => unawaited(s.stop()),
                      icon: const Icon(Icons.stop_rounded, size: 18),
                      label: const Text('Stop'),
                    ),
                    OutlinedButton.icon(
                      style: Ctl.outlined,
                      onPressed: s.busy ? null : () => unawaited(s.mark()),
                      icon: const Icon(Icons.flag_outlined, size: 18),
                      label: const Text('Znacznik utworu'),
                    ),
                  ],
                )
              : FilledButton.icon(
                  style: Ctl.filled,
                  onPressed: (idle || s.monitoring) && !s.busy && s.input != null ? () => unawaited(s.record()) : null,
                  icon: const Icon(Icons.fiber_manual_record, size: 14, color: Color(0xffff3b30)),
                  label: const Text('Nagraj'),
                ),
        ),
        if (s.recording && markers.isNotEmpty) ...[
          const SizedBox(height: Sp.m),
          Text('Znaczniki: ${markers.map(_clock).join(', ')}', style: Ctl.label, textAlign: TextAlign.center),
        ],
      ],
    );
  }

  Widget _export() {
    final available = s.sessions.isNotEmpty && !s.recording;
    final selected = s.selectedSession;
    final idle = !s.busy && !s.running;
    final exportDone = s.job == 'export' && !s.running && (s.stage == 'finished' || s.stage == 'cancelled');
    return Collapsible(
      key: ValueKey('export:$available'),
      title: 'Podział i eksport',
      trailing: available ? null : 'Dostępne po nagraniu',
      enabled: available,
      initiallyOpen: available && s.session != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Nagranie', style: Ctl.label),
          const SizedBox(height: Sp.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: _dropdown<String>(
              semantics: 'session',
              value: s.session,
              items: [
                for (final x in s.sessions)
                  (
                    x['id'] as String,
                    '${x['label'] ?? 'Nagranie'} · ${_clock(x['durationMs'] as num? ?? 0)}${x['partial'] == true ? ' · przerwane' : ''}',
                  ),
              ],
              onChanged: idle
                  ? (v) {
                      if (v != null) s.selectSession(v);
                    }
                  : null,
            ),
          ),
          if (selected != null && selected['partial'] == true) ...[
            _warning('Nagranie zostało przerwane. Odzyskaj je, aby podzielić i dodać do biblioteki.'),
            const SizedBox(height: Sp.m),
            FilledButton(style: Ctl.filled, onPressed: idle ? () => unawaited(s.recover()) : null, child: const Text('Odzyskaj nagranie')),
          ] else if (selected != null) ...[
            const SizedBox(height: Sp.l),
            Row(
              children: [
                const Expanded(child: Text('Początki utworów', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                TextButton(style: Ctl.text, onPressed: idle ? () => unawaited(s.analyze()) : null, child: const Text('Zaproponuj według ciszy')),
              ],
            ),
            const SizedBox(height: Sp.xs),
            TextField(
              controller: s.marks,
              enabled: idle,
              minLines: 3,
              maxLines: 8,
              style: Ctl.fieldText,
              decoration: Ctl.field(hint: 'm:ss, jeden w wierszu. Pierwszy utwór zaczyna się w 0:00.'),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(style: Ctl.text, onPressed: idle ? () => unawaited(s.applyMarks()) : null, child: const Text('Zastosuj znaczniki')),
            ),
            const SizedBox(height: Sp.s),
            LayoutBuilder(
              builder: (context, box) {
                final a = _field(s.album, 'Album', enabled: idle), b = _field(s.artist, 'Wykonawca albumu', enabled: idle);
                return box.maxWidth >= 640
                    ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: Sp.l), Expanded(child: b)])
                    : Column(children: [a, const SizedBox(height: Sp.m), b]);
              },
            ),
            const SizedBox(height: Sp.m),
            for (var i = 0; i < s.titles.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: Sp.xs),
                child: Row(
                  children: [
                    SizedBox(width: 28, child: Text('${i + 1}.', textAlign: TextAlign.right, style: Ctl.label)),
                    const SizedBox(width: Sp.m),
                    Expanded(child: TextField(controller: s.titles[i], enabled: idle, style: Ctl.fieldText, decoration: Ctl.field())),
                  ],
                ),
              ),
            const SizedBox(height: Sp.m),
            const Text('Każdy utwór trafi do biblioteki jako FLAC. Oryginalne nagranie WAV zostaje.', style: Ctl.label),
            const SizedBox(height: Sp.m),
            if (s.exporting) ...[
              LinearProgressIndicator(
                value: (s.status['total'] as num? ?? 0) > 0
                    ? ((s.status['done'] as num? ?? 0) / (s.status['total'] as num)).clamp(0, 1).toDouble()
                    : null,
              ),
              const SizedBox(height: Sp.s),
              OutlinedButton(style: Ctl.outlined, onPressed: s.busy ? null : () => unawaited(s.stop()), child: const Text('Zatrzymaj eksport')),
            ] else
              FilledButton.icon(
                style: Ctl.filled,
                onPressed: idle && s.titles.isNotEmpty ? () => unawaited(s.export()) : null,
                icon: const Icon(Icons.library_add_outlined, size: 18),
                label: const Text('Dodaj do biblioteki'),
              ),
            if (exportDone)
              Padding(
                padding: const EdgeInsets.only(top: Sp.m),
                child: Text(
                  'Dodano do biblioteki: ${trackCount((s.status['files'] as List? ?? const []).length)}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            if (s.job == 'export' && s.stage == 'error' && s.status['error'] != null) _error('${s.status['error']}'),
          ],
        ],
      ),
    );
  }
}
