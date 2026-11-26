import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'library_index.dart';
import 'main.dart';
import 'model.dart';
import 'ui_prefs.dart';
import 'widgets.dart';
import 'l10n.dart';

/// Optional columns of the desktop track table. Title is always shown and flexible.
class TableColumn {
  final String key, label;
  final double width;
  final bool right;
  final String? sort;
  const TableColumn(this.key, this.label, this.width, {this.right = false, this.sort});
}

List<TableColumn> get tableColumns => [
  TableColumn('artist', tr('Artysta'), 180, sort: 'artist'),
  TableColumn('album', tr('Album'), 220, sort: 'album'),
  TableColumn('format', tr('Format'), 72),
  TableColumn('bitrate', tr('Bitrate'), 92, right: true),
  TableColumn('added', tr('Dodano'), 104, right: true, sort: 'added'),
  TableColumn('plays', tr('Odtworzenia'), 104, right: true, sort: 'plays'),
  TableColumn('time', tr('Czas'), 64, right: true, sort: 'duration'),
];

const _defaultColumns = ['album', 'time'];

List<TableColumn> visibleColumns(UiPrefs prefs) {
  final chosen = prefs.list('cols');
  final keys = chosen.isEmpty ? _defaultColumns : chosen;
  return tableColumns.where((c) => keys.contains(c.key)).toList();
}

double columnWidth(UiPrefs prefs, TableColumn c) =>
    prefs.number('colw.${c.key}', c.width).clamp(56.0, 480.0);

bool compactTable(UiPrefs prefs) => prefs.get<String>('density', 'normal') == 'compact';

String _date(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}

String cellText(TableColumn c, Track t, PlayHistory h) => switch (c.key) {
  'artist' => t.displayArtist,
  'album' => t.displayAlbum,
  'format' => formatLabel(t),
  'bitrate' => bitrateLabel(t) ?? '',
  'added' => _date(t.addedAt),
  'plays' => h.count(t.id) == 0 ? '' : '${h.count(t.id)}',
  'time' => t.durationMs > 0 ? clock(t.durationMs) : '',
  _ => '',
};

const _tabular = [FontFeature.tabularFigures()];

/// Cells after the title, shared by header and rows so they always line up.
List<Widget> tableCells(LibraryScreenState app, Track t) {
  final h = app.prefs.history;
  return [
    for (final c in visibleColumns(app.prefs))
      SizedBox(
        width: columnWidth(app.prefs, c),
        child: Padding(
          padding: const EdgeInsets.only(left: Sp.m),
          child: Text(
            cellText(c, t, h),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: c.right ? TextAlign.right : TextAlign.left,
            style: Txt.meta.copyWith(fontSize: 13, fontFeatures: _tabular),
          ),
        ),
      ),
  ];
}

Future<void> showColumnMenu(LibraryScreenState app, Offset at) async {
  final overlay = Overlay.of(app.context).context.findRenderObject() as RenderBox;
  final cols = visibleColumns(app.prefs).map((c) => c.key).toSet();
  final chosen = await showMenu<String>(
    context: app.context,
    position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
    items: [
      for (final c in tableColumns)
        CheckedPopupMenuItem<String>(value: c.key, checked: cols.contains(c.key), height: 36, child: Text(c.label)),
      const PopupMenuDivider(height: 8),
      CheckedPopupMenuItem<String>(value: '#compact', checked: compactTable(app.prefs), height: 36, child: Text(tr('Tryb kompaktowy'))),
      PopupMenuItem<String>(value: '#reset', height: 36, child: Text(tr('Przywróć domyślne'))),
    ],
  );
  if (chosen == null) return;
  app.refresh(() {
    if (chosen == '#compact') {
      app.prefs.set('density', compactTable(app.prefs) ? 'normal' : 'compact');
    } else if (chosen == '#reset') {
      app.prefs.set('cols', <String>[]);
      for (final c in tableColumns) {
        app.prefs.set('colw.${c.key}', null);
      }
    } else {
      cols.contains(chosen) ? cols.remove(chosen) : cols.add(chosen);
      app.prefs.set('cols', [for (final c in tableColumns) if (cols.contains(c.key)) c.key]);
    }
  });
}

/// Header with sortable, resizable columns. Right-click chooses columns.
class TrackTableHeader extends StatelessWidget {
  final LibraryScreenState app;
  final bool numbered, cover;
  final String? sort;
  final bool descending;
  final void Function(String key)? onSort;
  const TrackTableHeader({
    super.key,
    required this.app,
    this.numbered = false,
    this.cover = true,
    this.sort,
    this.descending = false,
    this.onSort,
  });

  Widget _label(String text, String? key, {bool right = false}) {
    final active = key != null && sort == key;
    final label = Row(
      mainAxisAlignment: right ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Txt.meta.copyWith(color: active ? primaryText : secondaryText, fontWeight: FontWeight.w600),
          ),
        ),
        if (active)
          Icon(descending ? Icons.arrow_drop_down_rounded : Icons.arrow_drop_up_rounded, size: 18, color: primaryText),
      ],
    );
    if (key == null || onSort == null) return label;
    return InkWell(onTap: () => onSort!(key), child: label);
  }

  @override
  Widget build(BuildContext context) {
    final compact = compactTable(app.prefs);
    return GestureDetector(
      onSecondaryTapUp: (d) => showColumnMenu(app, d.globalPosition),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: Sp.s),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: softBorder))),
        child: Row(
          children: [
            SizedBox(width: 36, child: Text(numbered ? '#' : '', textAlign: TextAlign.center, style: Txt.meta)),
            if (cover && !compact) const SizedBox(width: 52) else const SizedBox(width: Sp.s),
            Expanded(child: _label(tr('Tytuł'), 'title')),
            for (final c in visibleColumns(app.prefs))
              SizedBox(
                width: columnWidth(app.prefs, c),
                child: Row(
                  children: [
                    _Grip(
                      onDrag: (dx) => app.refresh(
                        () => app.prefs.set('colw.${c.key}', (columnWidth(app.prefs, c) - dx).clamp(56.0, 480.0)),
                      ),
                    ),
                    Expanded(child: _label(c.label, c.sort, right: c.right)),
                  ],
                ),
              ),
            const SizedBox(width: 32),
            Builder(
              builder: (context) => IconAction(
                Icons.view_column_outlined,
                tr('Kolumny'),
                () {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box != null) showColumnMenu(app, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                },
                size: 16,
                box: 32,
                color: secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Grip extends StatelessWidget {
  final ValueChanged<double> onDrag;
  const _Grip({required this.onDrag});
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
      child: SizedBox(
        width: Sp.m,
        height: 34,
        child: Center(child: SizedBox(width: 1, height: 14, child: ColoredBox(color: softBorder))),
      ),
    ),
  );
}
