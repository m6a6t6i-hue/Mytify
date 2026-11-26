import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'cover_widget.dart';
import 'design.dart';
import 'ingest.dart';
import 'model.dart';
import 'widgets.dart';
import 'l10n.dart';

const _red = Color(0xffff5252);

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
        Text(tr('Płyty CD i winyle'), style: Txt.display),
        const SizedBox(height: Sp.l),
        TextTabs(
          labels: [tr('Audio CD'), tr('Winyl i kaseta')],
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
        Icon(Icons.error_outline_rounded, size: 18, color: dangerText),
        const SizedBox(width: Sp.s),
        Expanded(child: SelectableText(trMessage(text), style: TextStyle(fontSize: 13.5, color: dangerText))),
      ],
    ),
  );

  Widget _warning(String text) => Padding(
    padding: const EdgeInsets.only(top: Sp.s),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_rounded, size: 18, color: warningText),
        const SizedBox(width: Sp.s),
        Expanded(child: Text(trMessage(text), style: TextStyle(fontSize: 13.5, color: warningText))),
      ],
    ),
  );

  Widget _note(String text, {IconData icon = Icons.info_outline_rounded}) => Padding(
    padding: const EdgeInsets.only(top: Sp.s),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: secondaryText),
        const SizedBox(width: Sp.s),
        Expanded(child: Text(trMessage(text), style: Ctl.label)),
      ],
    ),
  );

  Widget _field(TextEditingController c, String label, {bool enabled = true, String? hint}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Ctl.label),
      const SizedBox(height: Sp.xs),
      TextField(controller: c, enabled: enabled, style: Ctl.fieldText, decoration: Ctl.field(hint: hint)),
    ],
  );

  Widget _twoFields(Widget a, Widget b) => LayoutBuilder(
    builder: (context, box) => box.maxWidth >= 640
        ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: Sp.l), Expanded(child: b)])
        : Column(children: [a, const SizedBox(height: Sp.m), b]),
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

  Widget _check(String label, bool value, ValueChanged<bool>? onChanged, {String? sub}) => InkWell(
    borderRadius: BorderRadius.circular(Rad.control),
    onTap: onChanged == null ? null : () => onChanged(!value),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: sub == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Checkbox(value: value, onChanged: onChanged == null ? null : (v) => onChanged(v ?? false)),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: sub == null ? 0 : 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 13.5)),
                  if (sub != null) Text(sub, style: Ctl.label),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
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
    style: Theme.of(context).textTheme.bodyMedium!.merge(Ctl.fieldText).copyWith(color: primaryText),
    decoration: Ctl.field(),
    dropdownColor: elevated,
    items: [
      for (final (v, label) in items)
        DropdownMenuItem(value: v, child: Text(label, overflow: TextOverflow.ellipsis)),
    ],
    onChanged: onChanged,
  );

  Widget _cover(CoverChoice? cover, {double size = 72}) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: SizedBox(
      width: size,
      height: size,
      child: cover == null
          ? Container(color: elevated, child: Icon(Icons.album_outlined, color: secondaryText))
          : CoverImage(cover.uri, width: size, height: size),
    ),
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
            decoration: BoxDecoration(shape: BoxShape.circle, color: on || done ? accent : elevated),
            child: done
                ? Icon(Icons.check_rounded, size: 16, color: onAccent)
                : Text('${i + 1}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: on ? onAccent : secondaryText)),
          ),
          const SizedBox(width: Sp.s),
          Text(label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: on ? primaryText : secondaryText)),
        ],
      );
    }

    Widget link() => Container(width: 32, height: 1, margin: const EdgeInsets.symmetric(horizontal: Sp.m), color: softBorder);
    return Semantics(
      label: tr('Etap {0} z 3', [step + 1]),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: Sp.s,
        children: [dot(0, tr('Napęd')), link(), dot(1, tr('Utwory')), link(), dot(2, tr('Zapis'))],
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
              Text(text, style: TextStyle(fontSize: 14, color: secondaryText)),
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
      if (s.waitingForDisc)
        _empty(
          icon: Icons.album_outlined,
          title: tr('Włóż następną płytę'),
          text: tr('Tryb seryjny: płyta zostanie odczytana i opisana sama. Gdy opis jest jednoznaczny, import ruszy bez pytania.'),
          action: OutlinedButton(style: Ctl.outlined, onPressed: () => setState(() => s.serial = false), child: Text(tr('Zakończ tryb seryjny'))),
        )
      else
        switch (st) {
          CdState.searching => _empty(
            icon: Icons.album_outlined,
            title: tr('Szukam napędów'),
            text: tr('To potrwa chwilę.'),
            action: const SizedBox(width: 120, child: LinearProgressIndicator()),
          ),
          CdState.noDrive => _empty(
            icon: Icons.album_outlined,
            title: tr('Nie wykryto napędu'),
            text: tr('Podłącz napęd USB i odśwież listę.'),
            action: FilledButton(style: Ctl.filled, onPressed: s.searching ? null : () => unawaited(s.refresh()), child: Text(tr('Odśwież'))),
          ),
          CdState.importing => _ripProgress(),
          CdState.done => _ripDone(),
          CdState.failed => _ripFailed(),
          _ => _driveAndTracks(st, idle),
        },
      if (s.error != null) _error(s.error!),
      const SizedBox(height: Sp.xl),
      Collapsible(
        title: tr('Obsługiwane płyty'),
        child: Text(
          tr('Płyty Audio CD (CD-DA), odczyt cyfrowy bez strat. Płyty ze ścieżkami danych (CD-Extra, CD-ROM), DVD i Blu-ray nie są obsługiwane.\nKażdy fragment jest odczytywany co najmniej dwa razy i porównywany. Wynik jest sprawdzany w bazach AccurateRip i CTDB, gdy płyta tam jest. Przerwy między utworami są dołączane do poprzedniego utworu.'),
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
          : IconAction(Icons.refresh_rounded, tr('Odśwież listę napędów'), idle && !s.reading ? () => unawaited(s.refresh()) : null, color: secondaryText),
      IconAction(Icons.eject_rounded, tr('Wysuń płytę'), idle && s.drive != null && !s.reading ? () => unawaited(s.ejectDisc()) : null, color: secondaryText),
    ],
  );

  Widget _driveAndTracks(CdState st, bool idle) {
    final problem = switch (st) {
      CdState.noDisc => tr('Brak płyty w napędzie. Włóż płytę Audio CD.'),
      CdState.unsupported => tr('{0} Zobacz „Obsługiwane płyty”.', [s.cdProblem]),
      CdState.readError => s.cdProblem,
      _ => null,
    };
    final tracks = s.tracks;
    final chosen = s.picked.where((p) => p).length;
    final total = [for (var i = 0; i < tracks.length; i++) if (s.picked[i]) s.trackMs(tracks[i])].fold(0, (a, b) => a + b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('Napęd'), style: Ctl.label),
        const SizedBox(height: Sp.xs),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: _driveRow(idle)),
        const SizedBox(height: Sp.m),
        if (st == CdState.reading)
          Row(
            children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: Sp.s),
              Text(tr('Odczytuję spis utworów…'), style: TextStyle(fontSize: 13.5)),
            ],
          )
        else if (st != CdState.ready)
          FilledButton(style: Ctl.filled, onPressed: idle && s.drive != null ? () => unawaited(s.readCd()) : null, child: Text(tr('Odczytaj'))),
        if (problem != null) st == CdState.noDisc ? _note(problem, icon: Icons.album_outlined) : _error(problem),
        if (st == CdState.ready) ..._ready(idle, tracks, chosen, total),
      ],
    );
  }

  List<Widget> _ready(bool idle, List<Map<String, dynamic>> tracks, int chosen, int total) {
    final verdicts = _verdicts();
    return [
      SectionTitle(tr('Utwory')),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: idle ? () => unawaited(s.chooseCoverFile()) : null,
            borderRadius: BorderRadius.circular(6),
            child: Tooltip(message: tr('Zmień okładkę'), child: _cover(s.cdForm.cover)),
          ),
          const SizedBox(width: Sp.l),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${trackCount(tracks.length)} · ${ingestClock(tracks.fold(0, (a, t) => a + s.trackMs(t)))}', style: const TextStyle(fontSize: 13.5)),
                if (s.describing)
                  Padding(
                    padding: EdgeInsets.only(top: Sp.s),
                    child: Row(
                      children: [
                        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: Sp.s),
                        Text(tr('Szukam płyty w MusicBrainz…'), style: Ctl.label),
                      ],
                    ),
                  )
                else if (s.described != null)
                  _note(s.described!),
                Wrap(
                  spacing: Sp.s,
                  children: [
                    TextButton(style: Ctl.text, onPressed: idle && !s.describing ? () => unawaited(s.describe()) : null, child: Text(tr('Szukaj opisu ponownie'))),
                    TextButton(style: Ctl.text, onPressed: idle ? () => unawaited(s.readCd()) : null, child: Text(tr('Odczytaj ponownie'))),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      if (s.candidates.isNotEmpty) ...[
        const SizedBox(height: Sp.s),
        for (final r in s.candidates)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.album_outlined, color: secondaryText),
            title: Text('${r.artist} · ${r.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text([r.date, r.country, r.label, r.format, r.disambiguation].where((x) => x.isNotEmpty).join(' · '), style: Ctl.label),
            trailing: TextButton(style: Ctl.text, onPressed: idle ? () => unawaited(s.chooseRelease(r)) : null, child: Text(tr('Wybierz'))),
          ),
      ],
      const SizedBox(height: Sp.l),
      _twoFields(_field(s.cdForm.album, tr('Album'), enabled: idle), _field(s.cdForm.artist, tr('Wykonawca albumu'), enabled: idle)),
      const SizedBox(height: Sp.s),
      _check(tr('Różni wykonawcy (składanka)'), s.cdForm.various, idle ? s.setVarious : null),
      Row(
        children: [
          Checkbox(
            tristate: true,
            value: chosen == tracks.length ? true : chosen == 0 ? false : null,
            onChanged: idle ? (_) => s.pickAll(chosen != tracks.length) : null,
          ),
          Text(tr('Zaznaczone: {0} z {1}', [chosen, tracks.length]), style: Ctl.label),
        ],
      ),
      for (var i = 0; i < tracks.length && i < s.cdForm.tracks.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: Sp.xs),
          child: Row(
            children: [
              Checkbox(value: s.picked[i], onChanged: idle ? (v) => s.pick(i, v ?? false) : null),
              SizedBox(width: 28, child: Text('${tracks[i]['number'] ?? i + 1}', textAlign: TextAlign.right, style: Ctl.label)),
              const SizedBox(width: Sp.m),
              Expanded(flex: 3, child: TextField(controller: s.cdForm.tracks[i].title, enabled: idle, style: Ctl.fieldText, decoration: Ctl.field())),
              if (s.cdForm.various) ...[
                const SizedBox(width: Sp.s),
                Expanded(flex: 2, child: TextField(controller: s.cdForm.tracks[i].artist, enabled: idle, style: Ctl.fieldText, decoration: Ctl.field(hint: tr('Wykonawca')))),
              ],
              const SizedBox(width: Sp.m),
              SizedBox(width: 52, child: Text(ingestClock(s.trackMs(tracks[i])), textAlign: TextAlign.right, style: Ctl.label)),
              if (verdicts.isNotEmpty) SizedBox(width: 120, child: _verdict(verdicts[tracks[i]['number']])),
            ],
          ),
        ),
      SectionTitle(tr('Zapis')),
      InfoRow(tr('Format'), tr('FLAC bez strat, 16 bit / 44,1 kHz, z okładką, opisem i ReplayGain')),
      if (s.folders['cd'] != null) InfoRow(tr('Folder'), '${s.folders['cd']}'),
      _check(tr('Kopia MP3 192 kb/s na telefon'), s.mp3, idle ? (v) => setState(() => s.mp3 = v) : null, sub: tr('Osobny folder MP3 obok plików FLAC.')),
      _check(tr('Wysuń płytę po imporcie'), s.eject || s.serial, idle && !s.serial ? (v) => setState(() => s.eject = v) : null),
      _check(
        tr('Tryb seryjny'),
        s.serial,
        idle ? (v) => setState(() => s.serial = v) : null,
        sub: tr('Po imporcie płyta się wysuwa. Następna jest odczytywana sama i importowana, gdy opis jest jednoznaczny.'),
      ),
      Collapsible(
        title: tr('Przesunięcie odczytu'),
        card: false,
        trailing: s.manualOffset != null
            ? tr('{0}{1} (ręcznie)', [s.manualOffset! >= 0 ? '+' : '', s.manualOffset])
            : s.savedOffset != null
            ? tr('{0}{1} (zapamiętane)', [s.savedOffset! >= 0 ? '+' : '', s.savedOffset])
            : tr('wykrywane automatycznie'),
        child: _OffsetField(state: s, enabled: idle),
      ),
      const SizedBox(height: Sp.m),
      FilledButton.icon(
        style: Ctl.filled,
        onPressed: idle && chosen > 0 ? () => unawaited(s.rip()) : null,
        icon: const Icon(Icons.download_rounded, size: 18),
        label: Text(chosen == tracks.length ? tr('Importuj') : tr('Importuj zaznaczone ({0})', [chosen])),
      ),
      if (chosen > 0) Padding(padding: const EdgeInsets.only(top: Sp.s), child: Text(tr('Do odczytu: {0} muzyki.', [ingestClock(total)]), style: Ctl.label)),
    ];
  }

  /// Verification per track number from the running or finished import.
  Map<Object?, Map<String, dynamic>> _verdicts() => {
    for (final v in s.status['verdicts'] as List? ?? const []) (v as Map)['track']: Map<String, dynamic>.from(v),
  };

  bool get _hasAr => ((s.status['discCheck'] as Map?)?['accuraterip'] as num? ?? 0) > 0;

  Widget _verdict(Map<String, dynamic>? v) {
    if (v == null) return const SizedBox.shrink();
    final ar = (v['accuraterip'] as num? ?? 0).toInt();
    final best = (v['accurateripBest'] as num? ?? 0).toInt();
    final ctdb = (v['ctdb'] as num? ?? 0).toInt();
    final (icon, color, text) = ar > 0 || ctdb > 0
        ? (Icons.verified_rounded, accent, [if (ar > 0) 'AR $ar', if (ctdb > 0) tr('CTDB {0}', [ctdb])].join(' · '))
        : best > 0
        ? (Icons.error_outline_rounded, _red, 'niezgodny')
        : (Icons.help_outline_rounded, secondaryText, _hasAr ? tr('brak w bazie') : tr('bez weryfikacji'));
    return Tooltip(
      message: tr('CRC {0} · AccurateRip v1 {1} · v2 {2}{3}', [v['crc'], v['v1'], v['v2'], (v['retriedSectors'] as num? ?? 0) > 0 ? tr(' · powtórzone sektory: {0}', [v['retriedSectors']]) : '']),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: Sp.xs),
          Flexible(child: Text(text, style: TextStyle(fontSize: 12.5, color: color), overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  Widget _ripProgress() {
    final done = (s.status['done'] as num? ?? 0).toDouble();
    final total = (s.status['total'] as num? ?? 0).toDouble();
    final files = (s.status['files'] as List? ?? const []).length;
    final offset = s.status['offset'];
    final verdicts = _verdicts();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(total > 0 ? tr('Importowanie: {0}%', [(done * 100 / total).clamp(0, 100).round()]) : tr('Importowanie'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: Sp.xs),
        Text(trMessage(s.step), style: Ctl.label),
        const SizedBox(height: Sp.m),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: LinearProgressIndicator(value: total > 0 ? (done / total).clamp(0, 1) : null),
        ),
        const SizedBox(height: Sp.s),
        Text(
          [
            tr('Gotowe pliki: {0}', [files]),
            if (offset != null) tr('przesunięcie {0}{1} ({2})', [(offset as num) >= 0 ? '+' : '', offset, trMessage('${s.status['offsetSource']}')]),
          ].join(' · '),
          style: Ctl.label,
        ),
        for (final v in verdicts.values)
          Padding(
            padding: const EdgeInsets.only(top: Sp.xs),
            child: SizedBox(width: 360, child: Row(children: [Text(tr('Ścieżka {0}', [v['track']]), style: Ctl.label), const Spacer(), _verdict(v)])),
          ),
        for (final w in s.status['warnings'] as List? ?? const []) _warning('$w'),
        const SizedBox(height: Sp.l),
        OutlinedButton(style: Ctl.outlined, onPressed: s.busy ? null : () => unawaited(s.stop()), child: Text(tr('Zatrzymaj i zachowaj gotowe pliki'))),
      ],
    );
  }

  Widget _ripDone() {
    final files = (s.status['files'] as List? ?? const []);
    final cancelled = s.stage == 'cancelled';
    final verdicts = _verdicts().values.toList();
    final ok = verdicts.where((v) => (v['accuraterip'] as num? ?? 0) > 0 || (v['ctdb'] as num? ?? 0) > 0).length;
    final bad = verdicts.where((v) => (v['accuraterip'] as num? ?? 0) == 0 && (v['accurateripBest'] as num? ?? 0) > 0 && (v['ctdb'] as num? ?? 0) == 0).length;
    final folder = s.status['folder'] as String? ?? '';
    final disc = s.status['discCheck'] as Map?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          files.isEmpty ? tr('Import zatrzymany, nic nie zapisano') : tr('{0}Dodano do biblioteki: {1}', [cancelled ? tr('Import zatrzymany. ') : '', trackCount(files.length)]),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        if (verdicts.isNotEmpty) ...[
          const SizedBox(height: Sp.s),
          if (ok == verdicts.length)
            _note(tr('Wszystkie ścieżki zgodne z bazami AccurateRip lub CTDB.'), icon: Icons.verified_rounded)
          else if (bad > 0)
            _warning(tr('Niezgodne z bazą: {0}. Przetrzyj płytę i zaimportuj te ścieżki ponownie.', [bad]))
          else
            _note(tr('Zweryfikowane w bazach: {0} z {1}. Reszty płyty nie ma w bazach, więc nie da się jej sprawdzić.', [ok, verdicts.length])),
          if (disc?['ctdbConfidence'] != null && (disc!['ctdbConfidence'] as num) > 0) _note(tr('Cała płyta zgodna z CTDB (pewność {0}).', [disc['ctdbConfidence']]), icon: Icons.verified_rounded),
          if (s.status['offset'] != null) _note(tr('Przesunięcie odczytu: {0}{1} próbek ({2}).', [(s.status['offset'] as num) >= 0 ? '+' : '', s.status['offset'], trMessage('${s.status['offsetSource']}')])),
        ],
        for (final w in s.status['warnings'] as List? ?? const []) _warning('$w'),
        const SizedBox(height: Sp.m),
        for (final f in files) Text('$f'.split(RegExp(r'[\\/]')).last, style: Ctl.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: Sp.l),
        Wrap(
          spacing: Sp.s,
          runSpacing: Sp.s,
          children: [
            FilledButton(style: Ctl.filled, onPressed: () => s.nextDisc(), child: Text(tr('Importuj kolejną płytę'))),
            if (folder.isNotEmpty)
              OutlinedButton.icon(
                style: Ctl.outlined,
                onPressed: () => unawaited(s.openFolder(folder)),
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: Text(tr('Otwórz folder z raportem')),
              ),
          ],
        ),
      ],
    );
  }

  Widget _ripFailed() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(tr('Import przerwany'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      _error('${s.status['error'] ?? tr('Nieznany błąd')}'),
      if ((s.status['files'] as List? ?? const []).isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Sp.s),
          child: Text(tr('Zachowano gotowe pliki: {0}', [(s.status['files'] as List).length]), style: Ctl.label),
        ),
      const SizedBox(height: Sp.l),
      FilledButton(style: Ctl.filled, onPressed: () => s.nextDisc(), child: Text(tr('Spróbuj ponownie'))),
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
                      Padding(padding: EdgeInsets.symmetric(horizontal: Sp.xl), child: VerticalDivider(width: 1, color: softBorder)),
                      Expanded(child: rec),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [input, Padding(padding: EdgeInsets.symmetric(vertical: Sp.xl), child: Divider(height: 1, color: softBorder)), rec],
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
            Expanded(child: Text(tr('Wejście'), style: Ctl.section)),
            IconAction(Icons.help_outline_rounded, help ? tr('Ukryj pomoc') : tr('Jak podłączyć gramofon lub magnetofon'), () => setState(() => help = !help), color: secondaryText),
          ],
        ),
        if (help)
          Container(
            margin: const EdgeInsets.only(top: Sp.s),
            padding: const EdgeInsets.all(Sp.m),
            decoration: BoxDecoration(color: elevated, borderRadius: BorderRadius.circular(Rad.control)),
            child: Text(
              tr('Gramofon: przez przedwzmacniacz PHONO do wejścia liniowego karty dźwiękowej albo gramofon z wyjściem USB. Magnetofon: z wyjścia LINE OUT do wejścia liniowego.\nUstaw poziom na najgłośniejszym fragmencie płyty: szczyty od -12 do -6 dBFS, bez przesterowań.'),
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
          ),
        const SizedBox(height: Sp.m),
        Text(tr('Urządzenie wejściowe'), style: Ctl.label),
        const SizedBox(height: Sp.xs),
        if (s.inputs.isEmpty && !s.searching)
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('Nie wykryto wejścia audio. Podłącz interfejs USB lub włącz wejście w ustawieniach dźwięku Windows.'),
                  style: TextStyle(fontSize: 13.5),
                ),
              ),
              IconAction(Icons.refresh_rounded, tr('Odśwież listę wejść'), () => unawaited(s.refresh()), color: secondaryText),
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
                  : IconAction(Icons.refresh_rounded, tr('Odśwież listę wejść'), idle ? () => unawaited(s.refresh()) : null, color: secondaryText),
            ],
          ),
        const SizedBox(height: Sp.s),
        Collapsible(
          title: tr('Zaawansowane'),
          card: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('Częstotliwość nagrania'), style: Ctl.label),
              const SizedBox(height: Sp.xs),
              if (rates.length > 1)
                _dropdown<int>(
                  semantics: 'rate',
                  value: s.rate,
                  items: [for (final r in rates) (r, tr('{0} kHz', [(r / 1000).toString().replaceAll('.', ',')]))],
                  onChanged: idle ? (v) => s.selectRate(v ?? s.rate) : null,
                )
              else
                Text(rates.isEmpty ? tr('Po wybraniu wejścia') : tr('{0} kHz', [(rates.first / 1000).toString().replaceAll('.', ',')]), style: Ctl.fieldText),
              const SizedBox(height: Sp.m),
              Text(tr('Format nagrania'), style: Ctl.label),
              const SizedBox(height: Sp.xs),
              Text(tr('WAV 24 bit, bez obróbki (obróbka tylko przy eksporcie kopii)'), style: Ctl.fieldText),
              const SizedBox(height: Sp.m),
              Text(tr('Folder nagrań'), style: Ctl.label),
              const SizedBox(height: Sp.xs),
              Row(
                children: [
                  Expanded(child: Text('${s.folders['recordings'] ?? tr('Folder danych aplikacji')}', style: Ctl.fieldText, maxLines: 2, overflow: TextOverflow.ellipsis)),
                  IconAction(Icons.folder_open_outlined, tr('Otwórz folder nagrań'), s.busy ? null : () => unawaited(s.openFolder()), color: secondaryText),
                ],
              ),
            ],
          ),
        ),
        Divider(height: Sp.xl, color: softBorder),
        Text(tr('Poziom wejścia'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: Sp.m),
        _meters(),
        const SizedBox(height: Sp.m),
        if (s.monitoring)
          OutlinedButton(style: Ctl.outlined, onPressed: s.busy ? null : () => unawaited(s.stop()), child: Text(tr('Zakończ podgląd')))
        else
          OutlinedButton(style: Ctl.outlined, onPressed: idle && s.input != null ? () => unawaited(s.monitor()) : null, child: Text(tr('Sprawdź poziom'))),
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
      final color = db > -1 ? _red : db > -6 ? warningText : accent;
      return Padding(
        padding: const EdgeInsets.only(bottom: Sp.s),
        child: Row(
          children: [
            SizedBox(width: 16, child: Text(name, style: Ctl.label)),
            Expanded(
              child: Semantics(
                label: tr('Poziom kanału {0}', [name]),
                value: live ? tr('{0} dBFS', [db.toStringAsFixed(1)]) : tr('wyłączony'),
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
                live ? (db <= -89 ? tr('−∞ dBFS') : tr('{0} dBFS', [db.toStringAsFixed(1)])) : '',
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
        if (!live) Text(tr('Podgląd wyłączony'), style: Ctl.label),
        if (live && clips > 0) _error(tr('Przesterowanie: {0}. Zmniejsz poziom na przedwzmacniaczu lub w Windows.', [collectionCount(clips, tr('próbka'), tr('próbki'), tr('próbek'))])),
        if (live && dropouts > 0) _warning(tr('Utracone próbki: {0}. Zamknij inne programy korzystające z wejścia.', [dropouts])),
      ],
    );
  }

  Widget _recording() {
    final frames = (s.status['frames'] as num? ?? 0).toDouble();
    final hz = (s.status['rate'] as num? ?? s.rate).toDouble();
    final ms = s.recording ? frames * 1000 / (hz > 0 ? hz : s.rate) : 0.0;
    final markers = (s.status['markers'] as List? ?? const []).cast<num>();
    final idle = !s.busy && !s.running;
    final endedBySilence = s.job == 'record' && !s.running && s.status['ended'] == 'silence';
    final state = s.paused
        ? tr('Pauza, nic nie jest zapisywane')
        : s.recording
        ? tr('Nagrywanie')
        : s.monitoring
        ? tr('Podgląd poziomu, nic nie jest zapisywane')
        : s.job == 'record' && s.stage == 'error'
        ? tr('Nagranie przerwane')
        : endedBySilence
        ? tr('Strona zakończona: wykryto ciszę')
        : s.job == 'record' && (s.stage == 'finished' || s.stage == 'cancelled')
        ? tr('Nagranie zapisane')
        : tr('Nagranie nie zostało rozpoczęte');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('Nagranie'), style: Ctl.section),
        const SizedBox(height: Sp.m),
        _field(s.label, tr('Nazwa nagrania'), enabled: idle || s.monitoring),
        _check(tr('Zakończ po ciszy na końcu strony'), s.autoStop, idle || s.monitoring ? (v) => setState(() => s.autoStop = v) : null, sub: tr('8 s ciszy po co najmniej 30 s nagrania.')),
        const SizedBox(height: Sp.l),
        Center(
          child: Text(
            ingestClock(ms),
            style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w300, fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s.recording && !s.paused) ...[
                Container(width: 8, height: 8, decoration: const BoxDecoration(color: _red, shape: BoxShape.circle)),
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
                      label: Text(tr('Stop')),
                    ),
                    OutlinedButton.icon(
                      style: Ctl.outlined,
                      onPressed: s.busy ? null : () => unawaited(s.pause(!s.paused)),
                      icon: Icon(s.paused ? Icons.fiber_manual_record : Icons.pause_rounded, size: 18),
                      label: Text(s.paused ? tr('Wznów') : tr('Pauza')),
                    ),
                    OutlinedButton.icon(
                      style: Ctl.outlined,
                      onPressed: s.busy || s.paused ? null : () => unawaited(s.mark()),
                      icon: const Icon(Icons.flag_outlined, size: 18),
                      label: Text(tr('Znacznik utworu')),
                    ),
                  ],
                )
              : Wrap(
                  spacing: Sp.s,
                  runSpacing: Sp.s,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      style: Ctl.filled,
                      onPressed: (idle || s.monitoring) && !s.busy && s.input != null ? () => unawaited(s.record()) : null,
                      icon: const Icon(Icons.fiber_manual_record, size: 14, color: Color(0xffff3b30)),
                      label: Text(tr('Nagraj')),
                    ),
                    if (endedBySilence)
                      OutlinedButton(style: Ctl.outlined, onPressed: idle && s.input != null ? () => unawaited(s.recordSideB()) : null, child: Text(tr('Nagraj stronę B'))),
                  ],
                ),
        ),
        if (s.recording && markers.isNotEmpty) ...[
          const SizedBox(height: Sp.m),
          Text(tr('Znaczniki: {0}', [markers.map(ingestClock).join(', ')]), style: Ctl.label, textAlign: TextAlign.center),
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
      title: tr('Podział i eksport'),
      trailing: available ? null : tr('Dostępne po nagraniu'),
      enabled: available,
      initiallyOpen: available && s.session != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('Nagranie'), style: Ctl.label),
          const SizedBox(height: Sp.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _dropdown<String>(
              semantics: 'session',
              value: s.session,
              items: [
                for (final x in s.sessions)
                  (
                    x['id'] as String,
                    '${x['label'] ?? tr('Nagranie')} · ${ingestClock(x['durationMs'] as num? ?? 0)}${x['partial'] == true ? tr(' · przerwane') : ''}',
                  ),
              ],
              onChanged: idle
                  ? (v) {
                      if (v != null) unawaited(s.selectSession(v));
                    }
                  : null,
            ),
          ),
          if (selected != null && selected['partial'] == true) ...[
            _warning(tr('Nagranie zostało przerwane. Odzyskaj je, aby podzielić i dodać do biblioteki.')),
            const SizedBox(height: Sp.m),
            FilledButton(style: Ctl.filled, onPressed: idle ? () => unawaited(s.recover()) : null, child: Text(tr('Odzyskaj nagranie'))),
          ] else if (selected != null) ...[
            const SizedBox(height: Sp.l),
            _tracklist(idle),
            const SizedBox(height: Sp.l),
            Row(
              children: [
                Expanded(child: Text(tr('Początki utworów'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                TextButton(style: Ctl.text, onPressed: idle ? () => unawaited(s.analyze()) : null, child: Text(tr('Zaproponuj według ciszy'))),
              ],
            ),
            const SizedBox(height: Sp.s),
            if (s.waveform != null)
              WaveformEditor(state: s, enabled: idle)
            else
              const SizedBox(height: 120, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
            const SizedBox(height: Sp.l),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: idle ? () => unawaited(s.chooseCoverFile()) : null,
                  borderRadius: BorderRadius.circular(6),
                  child: Tooltip(message: tr('Wybierz okładkę'), child: _cover(s.vinylForm.cover, size: 64)),
                ),
                const SizedBox(width: Sp.l),
                Expanded(child: _twoFields(_field(s.vinylForm.album, tr('Album'), enabled: idle), _field(s.vinylForm.artist, tr('Wykonawca albumu'), enabled: idle))),
              ],
            ),
            const SizedBox(height: Sp.s),
            Row(
              children: [
                Expanded(child: _check(tr('Różni wykonawcy (składanka)'), s.vinylForm.various, idle ? s.setVarious : null)),
                Text(tr('Numer pierwszego utworu'), style: Ctl.label),
                const SizedBox(width: Sp.s),
                SizedBox(
                  width: 64,
                  child: TextField(
                    controller: s.firstTrackField,
                    enabled: idle,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                    style: Ctl.fieldText,
                    decoration: Ctl.field(),
                    onChanged: (_) => s.changed(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Sp.s),
            for (var i = 0; i < s.vinylForm.tracks.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: Sp.xs),
                child: Row(
                  children: [
                    SizedBox(width: 28, child: Text('${i + s.firstTrack}.', textAlign: TextAlign.right, style: Ctl.label)),
                    const SizedBox(width: Sp.m),
                    Expanded(flex: 3, child: TextField(controller: s.vinylForm.tracks[i].title, enabled: idle, style: Ctl.fieldText, decoration: Ctl.field())),
                    if (s.vinylForm.various) ...[
                      const SizedBox(width: Sp.s),
                      Expanded(flex: 2, child: TextField(controller: s.vinylForm.tracks[i].artist, enabled: idle, style: Ctl.fieldText, decoration: Ctl.field(hint: tr('Wykonawca')))),
                    ],
                    const SizedBox(width: Sp.m),
                    SizedBox(
                      width: 56,
                      child: Text(
                        ingestClock(i == 0 ? 0 : s.markers[i - 1]),
                        textAlign: TextAlign.right,
                        style: Ctl.label,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: Sp.m),
            Collapsible(
              title: tr('Obróbka kopii'),
              card: false,
              trailing: [if (s.declick) 'trzaski', if (s.hum) 'brum', if (s.speed != 0) tr('prędkość {0}{1}%', [s.speed > 0 ? '+' : '', s.speed.toStringAsFixed(1)])].join(', '),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Dotyczy tylko plików FLAC i MP3. Oryginalne nagranie WAV zostaje bez zmian.'), style: Ctl.label),
                  _check(tr('Usuń trzaski'), s.declick, idle ? (v) => setState(() => s.declick = v) : null, sub: tr('Krótkie trzaski i pyknięcia z płyty winylowej.')),
                  _check(tr('Filtr brumu 50 Hz'), s.hum, idle ? (v) => setState(() => s.hum = v) : null, sub: tr('Wycina 50, 100 i 150 Hz z przewodów i uziemienia.')),
                  Row(
                    children: [
                      const SizedBox(width: Sp.m),
                      Text(tr('Korekta prędkości kasety'), style: TextStyle(fontSize: 13.5)),
                      Expanded(
                        child: Slider(
                          value: s.speed,
                          min: -5,
                          max: 5,
                          divisions: 100,
                          label: '${s.speed > 0 ? '+' : ''}${s.speed.toStringAsFixed(1)}%',
                          onChanged: idle ? (v) => setState(() => s.speed = (v * 10).round() / 10) : null,
                        ),
                      ),
                      SizedBox(width: 56, child: Text('${s.speed > 0 ? '+' : ''}${s.speed.toStringAsFixed(1)}%', style: Ctl.label)),
                    ],
                  ),
                ],
              ),
            ),
            _check(tr('Kopia MP3 192 kb/s na telefon'), s.mp3, idle ? (v) => setState(() => s.mp3 = v) : null),
            const SizedBox(height: Sp.s),
            Text(tr('Każdy utwór trafi do biblioteki jako FLAC z opisem i ReplayGain. Oryginalne nagranie WAV zostaje.'), style: Ctl.label),
            const SizedBox(height: Sp.m),
            if (s.exporting) ...[
              LinearProgressIndicator(
                value: (s.status['total'] as num? ?? 0) > 0 ? ((s.status['done'] as num? ?? 0) / (s.status['total'] as num)).clamp(0, 1).toDouble() : null,
              ),
              const SizedBox(height: Sp.xs),
              Text(trMessage(s.step), style: Ctl.label),
              const SizedBox(height: Sp.s),
              OutlinedButton(style: Ctl.outlined, onPressed: s.busy ? null : () => unawaited(s.stop()), child: Text(tr('Zatrzymaj eksport'))),
            ] else
              FilledButton.icon(
                style: Ctl.filled,
                onPressed: idle && s.vinylForm.tracks.isNotEmpty ? () => unawaited(s.export()) : null,
                icon: const Icon(Icons.library_add_outlined, size: 18),
                label: Text(tr('Dodaj do biblioteki')),
              ),
            if (exportDone) ...[
              Padding(
                padding: const EdgeInsets.only(top: Sp.m),
                child: Text(tr('Dodano do biblioteki: {0}', [trackCount((s.status['files'] as List? ?? const []).length)]), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              for (final w in s.status['warnings'] as List? ?? const []) _note('$w'),
              if ((s.status['folder'] as String? ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Sp.s),
                  child: OutlinedButton.icon(
                    style: Ctl.outlined,
                    onPressed: () => unawaited(s.openFolder(s.status['folder'] as String)),
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: Text(tr('Otwórz folder')),
                  ),
                ),
            ],
            if (s.job == 'export' && s.stage == 'error' && s.status['error'] != null) _error('${s.status['error']}'),
          ],
        ],
      ),
    );
  }

  Widget _tracklist(bool idle) {
    final info = s.tracklist;
    return Collapsible(
      title: tr('Lista utworów z MusicBrainz lub Discogs'),
      card: false,
      initiallyOpen: info == null,
      trailing: info == null ? null : '${info.release.artist} · ${info.release.title}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _twoFields(_field(s.searchAlbum, tr('Album'), enabled: idle), _field(s.searchArtist, tr('Wykonawca'), enabled: idle)),
          const SizedBox(height: Sp.s),
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(style: Ctl.outlined, onPressed: idle ? () => unawaited(s.searchTracklist()) : null, child: Text(tr('Szukaj w MusicBrainz'))),
              SizedBox(
                width: 300,
                child: TextField(
                  controller: s.discogs,
                  enabled: idle,
                  style: Ctl.fieldText,
                  decoration: Ctl.field(hint: tr('albo adres wydania z Discogs')),
                  onSubmitted: (_) => unawaited(s.loadDiscogs()),
                ),
              ),
              TextButton(style: Ctl.text, onPressed: idle ? () => unawaited(s.loadDiscogs()) : null, child: Text(tr('Wczytaj z Discogs'))),
            ],
          ),
          for (final r in s.searchResults)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${r.artist} · ${r.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text([r.date, r.country, r.format, r.label].where((x) => x.isNotEmpty).join(' · '), style: Ctl.label),
              trailing: TextButton(style: Ctl.text, onPressed: idle ? () => unawaited(s.loadTracklist(r)) : null, child: Text(tr('Wybierz'))),
            ),
          if (info != null) ...[
            const SizedBox(height: Sp.m),
            Text(tr('Zaznacz utwory z tego nagrania (jednej strony):'), style: Ctl.label),
            for (var i = 0; i < info.tracks.length; i++)
              _check(
                '${info.tracks[i].number.isNotEmpty ? '${info.tracks[i].number}  ' : ''}${info.tracks[i].title}',
                s.tracklistPicked[i],
                idle ? (v) => s.pickTracklist(i, v) : null,
                sub: info.tracks[i].durationMs > 0 ? ingestClock(info.tracks[i].durationMs) : tr('bez czasu'),
              ),
            const SizedBox(height: Sp.s),
            FilledButton(style: Ctl.filled, onPressed: idle ? () => unawaited(s.applyTracklist()) : null, child: Text(tr('Ustaw znaczniki i tytuły według listy'))),
          ],
        ],
      ),
    );
  }
}

class _OffsetField extends StatefulWidget {
  final IngestState state;
  final bool enabled;
  const _OffsetField({required this.state, required this.enabled});
  @override
  State<_OffsetField> createState() => _OffsetFieldState();
}

class _OffsetFieldState extends State<_OffsetField> {
  late final c = TextEditingController(text: widget.state.manualOffset?.toString() ?? '');
  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        tr('Zostaw puste: Mytify użyje wartości zapamiętanej dla napędu albo ustali ją z AccurateRip przy pierwszej płycie, która jest w bazie.'),
        style: Ctl.label,
      ),
      const SizedBox(height: Sp.s),
      SizedBox(
        width: 160,
        child: TextField(
          controller: c,
          enabled: widget.enabled,
          style: Ctl.fieldText,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?\d{0,4}'))],
          decoration: Ctl.field(hint: tr('np. +6')),
          onChanged: (v) {
            widget.state.manualOffset = int.tryParse(v.replaceAll('+', ''));
            widget.state.changed();
          },
        ),
      ),
    ],
  );
}

/// Real waveform of the recording with draggable track starts, a cursor to listen
/// from, and zoom. Nothing here is drawn from guessed data.
class WaveformEditor extends StatefulWidget {
  final IngestState state;
  final bool enabled;
  const WaveformEditor({super.key, required this.state, required this.enabled});
  @override
  State<WaveformEditor> createState() => _WaveformEditorState();
}

class _WaveformEditorState extends State<WaveformEditor> {
  IngestState get s => widget.state;
  double zoom = 1;
  int? dragging;
  final scroll = ScrollController();

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  int _msAt(double x, double width) {
    final w = s.waveform!;
    return (x / width * w.durationMs).round().clamp(0, w.durationMs);
  }

  @override
  Widget build(BuildContext context) {
    final w = s.waveform!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth * zoom;
            return SizedBox(
              height: 132,
              child: Scrollbar(
                controller: scroll,
                thumbVisibility: zoom > 1,
                child: SingleChildScrollView(
                  controller: scroll,
                  scrollDirection: Axis.horizontal,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: widget.enabled ? (d) => s.setCursor(_msAt(d.localPosition.dx, width)) : null,
                    onDoubleTapDown: widget.enabled ? (d) => s.addMarker(_msAt(d.localPosition.dx, width)) : null,
                    onHorizontalDragStart: widget.enabled
                        ? (d) {
                            // Grab the nearest marker within 10 px.
                            final x = d.localPosition.dx;
                            int? best;
                            var bestDx = 10.0;
                            for (var i = 0; i < s.markers.length; i++) {
                              final mx = s.markers[i] / w.durationMs * width;
                              if ((mx - x).abs() < bestDx) {
                                bestDx = (mx - x).abs();
                                best = i;
                              }
                            }
                            setState(() => dragging = best);
                          }
                        : null,
                    onHorizontalDragUpdate: (d) {
                      final i = dragging;
                      if (i != null) {
                        s.moveMarker(i, _msAt(d.localPosition.dx, width));
                      } else if (scroll.hasClients) {
                        // No marker under the pointer: drag pans the zoomed waveform.
                        scroll.jumpTo((scroll.offset - d.delta.dx).clamp(0, scroll.position.maxScrollExtent));
                      }
                    },
                    onHorizontalDragEnd: (_) => setState(() => dragging = null),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.precise,
                      child: CustomPaint(
                        size: Size(width, 132),
                        painter: _WavePainter(w, s.markers, s.cursorMs, dragging),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: Sp.s),
        Wrap(
          spacing: Sp.s,
          runSpacing: Sp.s,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(tr('Kursor {0}', [markTime(s.cursorMs)]), style: Ctl.label.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            OutlinedButton.icon(
              style: Ctl.outlined,
              onPressed: widget.enabled ? () => unawaited(s.preview(s.cursorMs)) : null,
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(tr('Odsłuchaj')),
            ),
            IconAction(Icons.stop_rounded, tr('Zatrzymaj odsłuch'), widget.enabled ? () => unawaited(s.stopPreview()) : null, color: secondaryText),
            OutlinedButton.icon(
              style: Ctl.outlined,
              onPressed: widget.enabled ? () => s.addMarker(s.cursorMs) : null,
              icon: const Icon(Icons.flag_outlined, size: 18),
              label: Text(tr('Znacznik w kursorze')),
            ),
            const SizedBox(width: Sp.m),
            Icon(Icons.zoom_in_rounded, size: 18, color: secondaryText),
            SizedBox(
              width: 140,
              child: Slider(value: zoom, min: 1, max: 24, onChanged: (v) => setState(() => zoom = v), semanticFormatterCallback: (v) => tr('Powiększenie {0}x', [v.round()])),
            ),
          ],
        ),
        Text(tr('Kliknij, aby ustawić kursor. Dwuklik dodaje znacznik, przeciągnij znacznik, aby go przesunąć.'), style: Ctl.label),
        if (s.markers.isNotEmpty) ...[
          const SizedBox(height: Sp.s),
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.xs,
            children: [
              for (var i = 0; i < s.markers.length; i++)
                InputChip(
                  label: Text('${i + 2}: ${markTime(s.markers[i])}', style: const TextStyle(fontSize: 12.5)),
                  onPressed: widget.enabled
                      ? () {
                          s.setCursor(s.markers[i]);
                          unawaited(s.preview(s.markers[i]));
                        }
                      : null,
                  onDeleted: widget.enabled ? () => s.removeMarker(i) : null,
                  deleteButtonTooltipMessage: tr('Usuń znacznik'),
                  tooltip: tr('Odsłuchaj początek utworu {0}', [i + 2]),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _WavePainter extends CustomPainter {
  final Waveform w;
  final List<int> markers;
  final int cursor;
  final int? active;
  _WavePainter(this.w, this.markers, this.cursor, this.active);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)), Paint()..color = const Color(0xff141619));
    final n = w.peaks.length ~/ 2;
    if (n == 0) return;
    final mid = size.height / 2;
    final paint = Paint()
      ..color = accent.withValues(alpha: .75)
      ..strokeWidth = math.max(1, size.width / n);
    final step = size.width / n;
    for (var i = 0; i < n; i++) {
      final lo = w.peaks[i * 2], hi = w.peaks[i * 2 + 1];
      final x = i * step + step / 2;
      canvas.drawLine(Offset(x, mid - hi * mid * .95), Offset(x, mid - lo * mid * .95 + .5), paint);
    }
    final marker = Paint()
      ..color = primaryText
      ..strokeWidth = 1.5;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i < markers.length; i++) {
      final x = markers[i] / w.durationMs * size.width;
      marker.color = i == active ? accent : primaryText;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), marker);
      // Tab with the number of the track that starts here.
      tp.text = TextSpan(text: '${i + 2}', style: const TextStyle(fontFamily: 'Arial', fontSize: 10.5, color: Colors.black, fontWeight: FontWeight.w700));
      tp.layout();
      final tab = math.max(16.0, tp.width + 8);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x - tab / 2, 0, tab, 16), const Radius.circular(4)),
        Paint()..color = marker.color,
      );
      tp.paint(canvas, Offset(x - tp.width / 2, 8 - tp.height / 2));
    }
    final cx = cursor / w.durationMs * size.width;
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), Paint()
      ..color = warningText
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.w != w || old.markers != markers || old.cursor != cursor || old.active != active;
}
