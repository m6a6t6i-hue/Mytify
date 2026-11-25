import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'model.dart';

abstract interface class IngestRepository {
  Future<dynamic> ingest(Map<String, dynamic> request);
}

class IngestScreen extends StatefulWidget {
  final LibraryRepository library;
  final IngestRepository repository;
  final bool cd;
  const IngestScreen({
    super.key,
    required this.library,
    required this.repository,
    this.cd = false,
  });
  @override
  State<IngestScreen> createState() => _IngestScreenState();
}

class _IngestScreenState extends State<IngestScreen> {
  Map<String, dynamic> status = {};
  List<dynamic> inputs = [], drives = [], sessions = [];
  String? input, drive, session, error;
  int rate = 48000, tab = 0;
  Map<String, dynamic>? toc;
  bool busy = false, polling = false;
  Timer? timer;
  final album = TextEditingController(),
      artist = TextEditingController(),
      label = TextEditingController(text: 'Winyl, strona A'),
      marks = TextEditingController();
  List<TextEditingController> titles = [];
  bool get running => status['running'] == true;
  @override
  void initState() {
    super.initState();
    tab = widget.cd ? 0 : 1;
    refresh();
    timer = Timer.periodic(const Duration(milliseconds: 500), (_) => poll());
  }

  @override
  void dispose() {
    timer?.cancel();
    for (final c in [album, artist, label, marks, ...titles]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<dynamic> api(String action, [Map<String, dynamic> args = const {}]) =>
      widget.repository.ingest({'action': action, ...args});
  Future<void> task(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() async {
    await task(() async {
      final d = await api('drives') as List;
      final i = await api('inputs') as List;
      final s = await api('sessions') as List;
      final st = await api('state') as Map;
      if (mounted) {
        setState(() {
          drives = d;
          inputs = i;
          sessions = s;
          status = Map<String, dynamic>.from(st);
          drive ??= d.firstOrNull as String?;
          input ??= i.firstOrNull?['id'] as String?;
          if (i.isNotEmpty) {
            final rates = (i.first['rates'] as List).cast<int>();
            if (rates.isNotEmpty && !rates.contains(rate)) rate = rates.first;
          }
        });
      }
    });
  }

  Future<void> poll() async {
    if (polling || !mounted) return;
    polling = true;
    try {
      final st = Map<String, dynamic>.from(await api('state') as Map);
      final ended = running && st['running'] != true;
      if (mounted) setState(() => status = st);
      if (ended) {
        final s = await api('sessions') as List;
        if (mounted) setState(() => sessions = s);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      polling = false;
    }
  }

  void setTitles(List<String> value) {
    for (final c in titles) {
      c.dispose();
    }
    titles = value.map((s) => TextEditingController(text: s)).toList();
  }

  String markTime(num ms) =>
      '${clock(ms)}.${(ms.toInt() % 1000).toString().padLeft(3, '0')}';
  String clock(num ms) {
    final s = ms.toInt() ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> readCd() => task(() async {
    final value = Map<String, dynamic>.from(
      await api('toc', {'drive': drive}) as Map,
    );
    if (mounted) {
      setState(() {
        toc = value;
        setTitles(
          List.generate(
            (value['tracks'] as List).length,
            (i) => 'Utwór ${i + 1}',
          ),
        );
      });
    }
  });
  Future<void> recognize() => task(() async {
    final list = (await api('disc', {'id': toc!['discId']}) as List)
        .map(
          (v) => ReleaseCandidate.fromJson(Map<String, dynamic>.from(v as Map)),
        )
        .toList();
    if (!mounted) return;
    if (list.isEmpty) {
      setState(
        () =>
            error = 'Brak wydania w MusicBrainz. Możesz wpisać nazwy ręcznie.',
      );
      return;
    }
    final selected = await showDialog<ReleaseCandidate>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Wybierz wydanie płyty'),
        children: list
            .map(
              (r) => SimpleDialogOption(
                onPressed: () => Navigator.pop(c, r),
                child: ListTile(
                  title: Text(r.title),
                  subtitle: Text(r.description),
                ),
              ),
            )
            .toList(),
      ),
    );
    if (selected == null) return;
    final info = await widget.library.releaseDetails(selected.id);
    final discs = info.tracks
        .map((t) => t.discNumber)
        .toSet()
        .where(
          (n) =>
              info.tracks.where((t) => t.discNumber == n).length ==
              (toc!['tracks'] as List).length,
        )
        .toList();
    if (discs.isEmpty) {
      throw StateError(
        'Liczba ścieżek wydania nie pasuje do tej płyty. Wybierz inne wydanie lub wpisz nazwy ręcznie.',
      );
    }
    int? disc = discs.first;
    if (discs.length > 1 && mounted) {
      disc = await showDialog<int>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Który krążek?'),
          children: discs
              .map(
                (n) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(c, n),
                  child: Text(
                    'Płyta $n · ${info.tracks.firstWhere((t) => t.discNumber == n).title}…',
                  ),
                ),
              )
              .toList(),
        ),
      );
    }
    if (disc == null || !mounted) return;
    setState(() {
      album.text = info.release.title;
      artist.text = info.release.artist;
      setTitles(
        info.tracks
            .where((t) => t.discNumber == disc)
            .map((t) => t.title)
            .toList(),
      );
    });
  });
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
      if (!seconds.isFinite || seconds < 0) {
        throw const FormatException('Nieprawidłowy czas');
      }
      out.add((seconds * 1000).round());
    }
    return out;
  }

  void selectSession(String id) {
    final s = sessions.firstWhere((s) => s['id'] == id);
    session = id;
    final points = (s['markers'] as List? ?? [])
        .cast<num>()
        .where((m) => m > 0)
        .toList();
    marks.text = points.map((n) => markTime(n)).join('\n');
    setTitles(List.generate(points.length + 1, (i) => 'Utwór ${i + 1}'));
  }

  Widget field(TextEditingController c, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      enabled: !running && !busy,
      decoration: InputDecoration(labelText: title),
    ),
  );
  Widget card(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    ),
  );
  Widget names() => Column(
    children: [
      field(album, 'Album'),
      field(artist, 'Wykonawca albumu'),
      for (var i = 0; i < titles.length; i++)
        field(titles[i], '${i + 1}. Tytuł utworu'),
    ],
  );
  Widget cd() => Column(
    children: [
      card('1. Włóż płytę Audio CD', [
        const Text(
          'Odczyt cyfrowy bezpośrednio z napędu. Płyty CD-Extra i z danymi nie są obsługiwane.',
        ),
        const SizedBox(height: 16),
        if (drives.isEmpty)
          const Text(
            'Nie wykryto napędu optycznego. Podłącz napęd USB i odśwież.',
          ),
        if (drives.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: drive,
            decoration: const InputDecoration(labelText: 'Napęd'),
            items: drives
                .map(
                  (d) => DropdownMenuItem(value: d as String, child: Text(d)),
                )
                .toList(),
            onChanged: running || busy
                ? null
                : (v) => setState(() {
                    drive = v;
                    toc = null;
                  }),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          children: [
            OutlinedButton(
              onPressed: running || busy ? null : refresh,
              child: const Text('Odśwież napędy'),
            ),
            FilledButton(
              onPressed: running || busy || drive == null ? null : readCd,
              child: const Text('Odczytaj płytę'),
            ),
          ],
        ),
      ]),
      if (toc != null)
        card('2. Sprawdź tytuły i wydanie', [
          Text(
            '${collectionCount((toc!['tracks'] as List).length, 'utwór', 'utwory', 'utworów')} · stereo 16 bit / 44,1 kHz',
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: running || busy ? null : recognize,
            child: const Text('Rozpoznaj wydanie w MusicBrainz'),
          ),
          const SizedBox(height: 16),
          names(),
          const Text(
            'Każdy odczyt jest porównywany co najmniej dwa razy. Rozbieżności trafią do raportu. To nie jest weryfikacja AccurateRip.',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: running || busy
                ? null
                : () => task(() async {
                    await api('rip', {
                      'drive': drive,
                      'discId': toc!['discId'],
                      'album': album.text,
                      'artist': artist.text,
                      'titles': titles.map((t) => t.text).toList(),
                    });
                    await poll();
                  }),
            icon: const Icon(Icons.download),
            label: const Text('Importuj jako FLAC'),
          ),
        ]),
    ],
  );
  Widget analog() {
    final selected = inputs.where((d) => d['id'] == input).firstOrNull;
    final rates = (selected?['rates'] as List? ?? [48000]).cast<int>();
    final frames = (status['frames'] as num? ?? 0).toDouble();
    final hz = (status['rate'] as num? ?? rate).toDouble();
    final peak = (status['peak'] as num? ?? 0).toDouble();
    final db = peak > 0 ? 20 * math.log(peak) / math.ln10 : -90.0;
    return Column(
      children: [
        card('1. Podłącz i sprawdź poziom', [
          const Text(
            'Gramofon przez przedwzmacniacz PHONO lub USB, magnetofon z LINE OUT. Ustaw poziom na najgłośniejszym fragmencie: szczyty od -12 do -6 dBFS.',
          ),
          const SizedBox(height: 16),
          if (inputs.isEmpty)
            const Text(
              'Nie wykryto obsługiwanego wejścia mono/stereo. Podłącz interfejs USB lub włącz wejście w ustawieniach Windows.',
            ),
          if (inputs.isNotEmpty)
            DropdownButtonFormField<String>(
              key: ValueKey(input),
              initialValue: input,
              decoration: const InputDecoration(labelText: 'Wejście audio'),
              isExpanded: true,
              items: inputs
                  .map(
                    (d) => DropdownMenuItem(
                      value: d['id'] as String,
                      child: Text(
                        d['name'] as String,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: running || busy
                  ? null
                  : (v) => setState(() {
                      input = v;
                      final r =
                          (inputs.firstWhere((d) => d['id'] == v)['rates']
                                  as List)
                              .cast<int>();
                      if (r.isNotEmpty && !r.contains(rate)) rate = r.first;
                    }),
            ),
          const SizedBox(height: 12),
          if (rates.isNotEmpty)
            DropdownButtonFormField<int>(
              key: ValueKey('$input-$rate'),
              initialValue: rates.contains(rate) ? rate : rates.first,
              decoration: const InputDecoration(
                labelText: 'Częstotliwość nagrania',
              ),
              items: rates
                  .map(
                    (r) => DropdownMenuItem(
                      value: r,
                      child: Text('${r / 1000} kHz'),
                    ),
                  )
                  .toList(),
              onChanged: running || busy
                  ? null
                  : (v) => setState(() => rate = v ?? rate),
            ),
          const SizedBox(height: 16),
          Text(
            '${db.toStringAsFixed(1)} dBFS · przesterowane próbki: ${status['clips'] ?? 0} · utracone próbki: ${status['dropouts'] ?? 0}',
            style: TextStyle(color: db > -1 ? Colors.redAccent : null),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: peak.clamp(0, 1),
            color: peak > .99 ? Colors.redAccent : null,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton(
                onPressed: running || busy ? null : refresh,
                child: const Text('Odśwież wejścia'),
              ),
              OutlinedButton(
                onPressed: running || busy || input == null
                    ? null
                    : () => task(() async {
                        await api('monitor', {'id': input, 'rate': rate});
                        await poll();
                      }),
                child: const Text('Sprawdź poziom'),
              ),
            ],
          ),
        ]),
        card('2. Nagraj stronę A lub B', [
          field(label, 'Nazwa nagrania / strona'),
          const Text(
            'Nagranie zapisuje się jako WAV 24 bit, bez odszumiania i normalizacji.',
          ),
          const SizedBox(height: 16),
          Text(
            clock(frames * 1000 / (hz > 0 ? hz : rate)),
            style: const TextStyle(fontSize: 36),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: running || busy || input == null
                    ? null
                    : () => task(() async {
                        await api('record', {
                          'id': input,
                          'rate': rate,
                          'label': label.text,
                        });
                        await poll();
                      }),
                icon: const Icon(Icons.fiber_manual_record),
                label: const Text('Rozpocznij nagranie'),
              ),
              OutlinedButton(
                onPressed: status['recording'] == true && !busy
                    ? () => task(() async {
                        await api('mark');
                        await poll();
                      })
                    : null,
                child: Text(
                  'Znacznik utworu (${(status['markers'] as List? ?? []).length})',
                ),
              ),
              if (running)
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => task(() async {
                          await api('stop');
                          await poll();
                        }),
                  child: const Text('Zatrzymaj i zachowaj'),
                ),
            ],
          ),
        ]),
        card('3. Podziel i dodaj do biblioteki', [
          const Text(
            'Eksport tworzy osobne utwory FLAC. Oryginał WAV zostaje.',
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: busy
                ? null
                : () => task(() async {
                    await api('openFolder');
                  }),
            child: const Text('Otwórz folder nagrań'),
          ),
          if (sessions.isEmpty)
            const Text('Po nagraniu pojawi się tutaj strona do podziału.'),
          if (sessions.isNotEmpty)
            DropdownButtonFormField<String>(
              key: ValueKey(session),
              initialValue: session,
              decoration: const InputDecoration(
                labelText: 'Zachowane nagranie',
              ),
              isExpanded: true,
              items: sessions
                  .map(
                    (s) => DropdownMenuItem(
                      value: s['id'] as String,
                      child: Text(
                        '${s['label'] ?? s['id']} · ${clock(s['durationMs'] as num? ?? 0)}${s['partial'] == true ? ' · do odzyskania' : ''}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: running || busy
                  ? null
                  : (v) => setState(() => selectSession(v!)),
            ),
          if (session != null) ...[
            const SizedBox(height: 12),
            if (sessions.firstWhere((s) => s['id'] == session)['partial'] ==
                true)
              FilledButton(
                onPressed: running || busy
                    ? null
                    : () => task(() async {
                        await api('recover', {'id': session});
                        await refresh();
                      }),
                child: const Text('Odzyskaj przerwane nagranie'),
              )
            else ...[
              OutlinedButton(
                onPressed: running || busy
                    ? null
                    : () => task(() async {
                        final points = (await api('analyze', {
                          'id': session,
                        }) as List).cast<num>();
                        if (mounted) {
                          setState(() {
                            marks.text = points
                                .map((n) => markTime(n))
                                .join('\n');
                            setTitles(
                              List.generate(
                                points.length + 1,
                                (i) => 'Utwór ${i + 1}',
                              ),
                            );
                          });
                        }
                      }),
                child: const Text('Zaproponuj podział według ciszy'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: marks,
                enabled: !running && !busy,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText:
                      'Początki kolejnych utworów (m:ss), jeden w wierszu',
                  helperText: 'Pierwszy utwór zaczyna się w 0:00. Każdy znacznik rozpoczyna następny.',
                ),
              ),
              TextButton(
                onPressed: running || busy
                    ? null
                    : () => task(() async {
                        final points = parseMarks();
                        if (mounted) {
                          setState(
                            () => setTitles(
                              List.generate(
                                points.length + 1,
                                (i) => i < titles.length
                                    ? titles[i].text
                                    : 'Utwór ${i + 1}',
                              ),
                            ),
                          );
                        }
                      }),
                child: const Text('Zastosuj poprawione znaczniki'),
              ),
              names(),
              FilledButton.icon(
                onPressed: running || busy
                    ? null
                    : () => task(() async {
                        await api('export', {
                          'id': session,
                          'album': album.text,
                          'artist': artist.text,
                          'markers': parseMarks(),
                          'titles': titles.map((t) => t.text).toList(),
                        });
                        await poll();
                      }),
                icon: const Icon(Icons.library_add),
                label: const Text('Eksportuj FLAC do biblioteki'),
              ),
            ],
          ],
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !running,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Z fizycznej kolekcji'),
        automaticallyImplyLeading: !running,
        actions: [
          if (!running)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Gotowe'),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 850),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 12,
                  children: [
                    ChoiceChip(
                      label: const Text('Audio CD'),
                      selected: tab == 0,
                      onSelected: running || busy
                          ? null
                          : (_) => setState(() => tab = 0),
                    ),
                    ChoiceChip(
                      label: const Text('Winyl / kaseta'),
                      selected: tab == 1,
                      onSelected: running || busy
                          ? null
                          : (_) => setState(() => tab = 1),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (busy) const LinearProgressIndicator(),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                if (status['error'] != null)
                  card('Operacja przerwana', [
                    SelectableText(status['error'] as String),
                  ]),
                if (running || ((status['files'] as List? ?? []).isNotEmpty))
                  card(
                    running ? 'Trwa ${status['stage']}' : 'Zachowano pliki',
                    [
                      if ((status['total'] as num? ?? 0) > 0)
                        LinearProgressIndicator(
                          value:
                              ((status['done'] as num? ?? 0) /
                                      (status['total'] as num))
                                  .clamp(0, 1),
                        ),
                      if (status['stage'] == 'ripping' ||
                          status['stage'] == 'exporting')
                        Text(
                          '${status['done'] ?? 0} / ${status['total'] ?? 0}',
                        ),
                      for (final w in status['warnings'] as List? ?? [])
                        Text('$w', style: const TextStyle(color: Colors.amber)),
                      for (final f in status['files'] as List? ?? [])
                        SelectableText('$f'),
                      if (running)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => task(() async {
                                  await api('stop');
                                  await poll();
                                }),
                          child: const Text(
                            'Zatrzymaj i zachowaj ukończone pliki',
                          ),
                        ),
                    ],
                  ),
                if (tab == 0) cd() else analog(),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
