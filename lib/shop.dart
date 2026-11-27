import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'l10n.dart';
import 'links.dart';
import 'main.dart';
import 'widgets.dart';

/// An album or song for sale. Prices come only from the iTunes Search API, the one
/// store with a public price lookup; the price is the store's, shown as it says.
class Offer {
  final String store, kind, title, artist, currency, year, url;
  final double? price;
  final int tracks;
  const Offer({
    required this.store,
    required this.kind,
    required this.title,
    required this.artist,
    required this.url,
    this.price,
    this.currency = '',
    this.year = '',
    this.tracks = 0,
  });
  static Offer? fromJson(Map<String, dynamic> j) {
    final url = j['url'] as String? ?? '';
    if (!url.startsWith('https://')) return null;
    return Offer(
      store: j['store'] as String? ?? '',
      kind: j['kind'] as String? ?? 'album',
      title: j['title'] as String? ?? '',
      artist: j['artist'] as String? ?? '',
      url: url,
      price: (j['price'] as num?)?.toDouble(),
      currency: j['currency'] as String? ?? '',
      year: j['year'] as String? ?? '',
      tracks: (j['tracks'] as num?)?.toInt() ?? 0,
    );
  }

  String get priceText {
    final p = price;
    if (p == null) return tr('cena w sklepie');
    final value = p.toStringAsFixed(2);
    return currency == 'PLN' ? '${value.replaceAll('.', ',')} zł' : '$value $currency';
  }
}

abstract class ShopRepository {
  Future<List<Offer>> shopSearch(String query, String country);
}

/// Stores selling downloads to keep (no subscription), opened as a search in the browser.
List<(String name, String formats, String url)> storeLinks(String query) {
  final q = Uri.encodeComponent(query.trim());
  return [
    ('Bandcamp', tr('MP3 320 / FLAC, głównie wydawcy niezależni'), 'https://bandcamp.com/search?q=$q&item_type=a'),
    ('Qobuz', tr('MP3 320 / FLAC / Hi-Res'), 'https://www.qobuz.com/pl-pl/search?q=$q'),
    ('iTunes Store', tr('AAC 256 kb/s (M4A), bez zabezpieczeń DRM'), 'https://music.apple.com/pl/search?term=$q'),
  ];
}

/// "Buy music" under the search results: prices from iTunes when asked for, links to
/// other stores always. The query leaves the device only here, after a pause in typing.
class BuyMusic extends StatefulWidget {
  final LibraryScreenState app;
  final String query;
  final bool prices;
  const BuyMusic({super.key, required this.app, required this.query, this.prices = false});
  @override
  State<BuyMusic> createState() => _BuyMusicState();
}

class _BuyMusicState extends State<BuyMusic> {
  static final _cache = <String, List<Offer>>{};
  Timer? _wait;
  List<Offer>? offers;
  String? error;
  bool expanded = false;

  ShopRepository? get _shop => widget.app.repository is ShopRepository ? widget.app.repository as ShopRepository : null;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(BuyMusic old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query || old.prices != widget.prices) _schedule();
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  void _schedule() {
    _wait?.cancel();
    final q = widget.query.trim().toLowerCase();
    offers = _cache[q];
    error = null;
    if (!widget.prices || _shop == null || q.length < 2 || offers != null) return;
    _wait = Timer(const Duration(milliseconds: 700), () => unawaited(_load(q)));
  }

  Future<void> _load(String q) async {
    try {
      final list = await _shop!.shopSearch(q, 'PL');
      _cache[q] = list;
      if (mounted && widget.query.trim().toLowerCase() == q) setState(() => offers = list);
    } catch (e) {
      if (mounted) setState(() => error = trMessage('$e'));
    }
  }

  void _open(String url) => unawaited(openLink(url, browser: true).catchError((Object _) => widget.app.message(tr('Nie można otworzyć strony.'))));

  @override
  Widget build(BuildContext context) {
    final desktop = widget.app.desktopMode;
    final pad = EdgeInsets.symmetric(horizontal: desktop ? Sp.xl : Sp.l);
    final list = offers ?? const <Offer>[];
    final albums = list.where((o) => o.kind == 'album').take(expanded ? 8 : 4).toList();
    final songs = list.where((o) => o.kind == 'song').take(expanded ? 5 : 2).toList();
    final waiting = widget.prices && _shop != null && offers == null && error == null && widget.query.trim().length >= 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          widget.prices ? tr('Nie masz tego w bibliotece. Kup muzykę') : tr('Nie ma tego, czego szukasz? Kup muzykę'),
          padding: EdgeInsets.fromLTRB(desktop ? Sp.xl : Sp.l, 20, Sp.s, Sp.xs),
        ),
        if (waiting) const Padding(padding: EdgeInsets.all(Sp.l), child: Center(child: CircularProgressIndicator())),
        if (error != null) Padding(padding: pad, child: Text(error!, style: Txt.meta.copyWith(color: dangerText))),
        for (final o in [...albums, ...songs])
          ListTile(
            contentPadding: pad,
            leading: Icon(o.kind == 'album' ? Icons.album_outlined : Icons.music_note_outlined, color: secondaryText),
            title: Text(o.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                o.artist,
                if (o.kind == 'album' && o.tracks > 0) collectionCount(o.tracks, 'utwór', 'utwory', 'utworów'),
                if (o.year.isNotEmpty) o.year,
                o.store,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Txt.meta,
            ),
            trailing: Text(o.priceText, style: const TextStyle(fontWeight: FontWeight.w700)),
            onTap: () => _open(o.url),
          ),
        if (!expanded && list.length > albums.length + songs.length)
          Padding(
            padding: pad,
            child: Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => setState(() => expanded = true), child: Text(tr('Pokaż więcej')))),
          ),
        if (offers != null && list.isEmpty) Padding(padding: pad, child: Text(tr('iTunes Store nie ma tego w sprzedaży.'), style: Txt.meta)),
        Padding(
          padding: pad.copyWith(top: Sp.s),
          child: Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              for (final (name, formats, url) in storeLinks(widget.query))
                Tooltip(
                  message: formats,
                  child: OutlinedButton.icon(
                    onPressed: () => _open(url),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: Text(tr('Szukaj w: {0}', [name])),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: pad.copyWith(top: Sp.s, bottom: Sp.l),
          child: Text(
            widget.prices
                ? tr('Ceny z iTunes Store dla Polski.')
                : tr('Kupione pliki dodasz do biblioteki jak każdy inny folder z muzyką.'),
            style: Txt.meta,
          ),
        ),
      ],
    );
  }
}
