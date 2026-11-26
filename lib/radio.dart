import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'logo_art.dart';
import 'l10n.dart';
import 'main.dart';
import 'model.dart';
import 'player_ui.dart';
import 'widgets.dart';

/// A radio station from the Radio Browser directory or typed in by the user.
class Station {
  final String id, name, url, logo, country, codec;
  final List<String> tags;
  final int bitrate;
  final bool hls;
  const Station({
    required this.id,
    required this.name,
    required this.url,
    this.logo = '',
    this.tags = const [],
    this.country = '',
    this.codec = '',
    this.bitrate = 0,
    this.hls = false,
  });
  static bool _http(String s) => s.startsWith('http://') || s.startsWith('https://');
  static Station? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String? ?? '';
    final url = j['url'] as String? ?? '';
    if (!id.startsWith('radio:') || id.length > 100 || !_http(url)) return null;
    final logo = j['logo'] as String? ?? '';
    return Station(
      id: id,
      name: (j['name'] as String? ?? '').trim(),
      url: url,
      logo: _http(logo) ? logo : '',
      tags: [for (final t in j['tags'] as List? ?? const []) '$t'],
      country: j['country'] as String? ?? '',
      codec: j['codec'] as String? ?? '',
      bitrate: (j['bitrate'] as num?)?.toInt() ?? 0,
      hls: j['hls'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'logo': logo,
    'tags': tags,
    'country': country,
    'codec': codec,
    'bitrate': bitrate,
    'hls': hls,
  };

  String get displayName => name.isEmpty ? Uri.tryParse(url)?.host ?? url : name;
  String get details => [
    if (tags.isNotEmpty) tags.take(2).join(', '),
    if (codec.isNotEmpty) bitrate > 0 ? '$codec $bitrate kbps' : codec,
    if (country.isNotEmpty) country,
  ].join(' · ');

  /// Stations typed in by hand get a stable id from their address.
  static String customId(String url) {
    var h = 0xcbf29ce4;
    for (final c in url.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return 'radio:u${h.toRadixString(16).padLeft(8, '0')}${url.length.toRadixString(16)}';
  }
}

/// Platforms with internet radio. The directory, the listen count and the address
/// check run natively (Rust on PC, Kotlin on Android).
abstract class RadioRepository {
  Future<List<Station>> radioSearch(Map<String, String> query);

  /// Counts the listen in the directory and returns the current stream address.
  Future<String?> radioClick(String id);

  /// {url, name, codec, hls} for an address the user typed.
  Future<Map<String, dynamic>> radioProbe(String url);

  /// Android Auto plays favourites without the app, so the phone keeps a copy.
  Future<void> radioFavorites(List<Station> stations);

  /// PC loads logos through the core (the window cannot fetch other sites' images).
  Future<String?> radioLogoBase();

  /// HLS stations play on Android; the PC engine does not read HLS yet.
  bool get radioHls;
}

bool isRadio(String? id) => id != null && id.startsWith('radio:');

const radioGenres = [
  ('pop', 'Pop'),
  ('rock', 'Rock'),
  ('jazz', 'Jazz'),
  ('classical', 'Klasyka'),
  ('electronic', 'Elektronika'),
  ('dance', 'Dance'),
  ('hip hop', 'Hip-hop'),
  ('news', 'Wiadomości'),
  ('talk', 'Rozmowy'),
  ('chillout', 'Chillout'),
];

/// "Artist - Title" as stations send it; anything else stays a single title.
(String? artist, String title)? splitOnAir(String? title) {
  final t = title?.trim();
  if (t == null || t.isEmpty) return null;
  final i = t.indexOf(' - ');
  if (i <= 0 || i + 3 >= t.length) return (null, t);
  return (t.substring(0, i).trim(), t.substring(i + 3).trim());
}

/// The station as a "track" for the shared player UI: title and artist come only from
/// what the station reports, otherwise the station's own name.
Track radioTrack(Map<String, dynamic> r, String Function(String logo) logoUri, {bool favorite = false}) {
  final name = (r['name'] as String?)?.trim().isNotEmpty == true ? r['name'] as String : (r['station'] as String? ?? tr('Radio'));
  final onAir = splitOnAir(r['title'] as String?);
  final logo = r['logo'] as String? ?? '';
  return Track(
    id: r['id'] as String,
    title: onAir?.$2 ?? name,
    artist: onAir == null ? tr('Radio') : (onAir.$1 ?? name),
    album: name,
    albumArtist: '',
    fileName: '',
    format: r['codec'] as String? ?? '',
    size: 0,
    cover: logo.isEmpty ? null : asLogo(logoUri(logo)),
    // The heart in the player means "favourite station" while on air.
    liked: favorite,
  );
}

extension RadioActions on LibraryScreenState {
  RadioRepository? get radio => repository is RadioRepository ? repository as RadioRepository : null;

  String radioLogoUri(String logo) {
    final base = radioLogoBase;
    return base == null ? logo : '$base${Uri.encodeQueryComponent(logo)}';
  }

  List<Station> _stations(String key) => [
    for (final v in prefs.get<List>(key, const []))
      if (v is Map) ?Station.fromJson(Map<String, dynamic>.from(v)),
  ];

  List<Station> get favoriteStations => _stations('radio.favorites');
  List<Station> get recentStations => _stations('radio.recent');
  bool isFavoriteStation(String id) => favoriteStations.any((s) => s.id == id);

  Future<void> toggleFavoriteStation(Station s) async {
    final list = favoriteStations;
    final had = list.any((x) => x.id == s.id);
    list.removeWhere((x) => x.id == s.id);
    if (!had) list.insert(0, s);
    refresh(() => prefs.set('radio.favorites', [for (final x in list) x.toJson()]));
    syncNativeAudio(player.state);
    message(had ? tr('Usunięto z ulubionych stacji') : tr('Dodano do ulubionych stacji'));
    try {
      await radio?.radioFavorites(list);
    } catch (_) {
      /* the phone copy is refreshed on the next change */
    }
  }

  /// Station for the one on air (favourites and recent first; they carry tags and codec).
  Station? stationFor(String? id) {
    if (!isRadio(id)) return null;
    for (final s in [...favoriteStations, ...recentStations]) {
      if (s.id == id) return s;
    }
    final r = player.state.radio;
    if (r == null || r['id'] != id) return null;
    return Station.fromJson(r);
  }

  /// What next/previous walk through on air: favourites first, then the list the
  /// station was picked from, then recently played. Stations this device cannot play are left out.
  List<Station> radioQueue(Station s, List<Station> from) {
    final hls = radio?.radioHls ?? false;
    final ids = <String>{};
    final out = <Station>[
      for (final x in [...favoriteStations, ...from, ...recentStations])
        if ((!x.hls || hls) && ids.add(x.id)) x,
    ].take(100).toList();
    if (!out.any((x) => x.id == s.id)) out.insert(0, s);
    return out;
  }

  Future<void> playStation(Station s, {List<Station> from = const []}) async {
    final repo = radio;
    if (repo == null) return;
    if (s.hls && !repo.radioHls) {
      message(tr('Ta stacja nadaje w formacie HLS, który na PC jeszcze nie jest obsługiwany.'));
      return;
    }
    final stations = radioQueue(s, from);
    final recent = recentStations..removeWhere((x) => x.id == s.id);
    refresh(() => prefs.set('radio.recent', [for (final x in [s, ...recent].take(20)) x.toJson()]));
    // Play at once from the known address. The directory only counts the listen,
    // so that call must not delay the sound (it can take seconds).
    if (!s.id.startsWith('radio:u')) unawaited(repo.radioClick(s.id).then((_) {}, onError: (Object _) {}));
    await audioOperation(
      () => player.command({
        'action': 'radio',
        'id': s.id,
        'url': s.url,
        'name': s.displayName,
        'logo': s.logo,
        'codec': s.codec,
        'bitrate': s.bitrate,
        'hls': s.hls,
        'stations': [for (final x in stations) x.toJson()],
      }),
    );
  }

  /// Titles stations announced, newest first: {title, station, at}.
  List<Map<String, dynamic>> get heardOnRadio => [
    for (final v in prefs.get<List>('radio.heard', const []))
      if (v is Map) Map<String, dynamic>.from(v),
  ];

  void recordHeard(String title, String station) {
    final list = heardOnRadio;
    if (list.isNotEmpty && list.first['title'] == title) return;
    list.insert(0, {'title': title, 'station': station, 'at': DateTime.now().millisecondsSinceEpoch});
    prefs.set('radio.heard', list.take(50).toList());
  }

  /// Looks for a song a station announced in the user's own library.
  void findInLibrary(String text) {
    final onAir = splitOnAir(text);
    final q = onAir == null ? text : [?onAir.$1, onAir.$2].join(' ');
    // From the full-screen player straight to the results.
    Navigator.of(context).popUntil((r) => r.isFirst);
    searchText.text = q;
    searchText.selection = TextSelection.collapsed(offset: q.length);
    go(Nav.search);
  }

  /// What the station announced, as the user can search it ("Artist - Title").
  String? onAirText() => (player.state.radio?['title'] as String?)?.trim();

  Future<void> radioMenu(Track t) async {
    final s = stationFor(t.id);
    final onAir = onAirText();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(t.album, style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: Text(s?.details ?? '')),
            if (s != null)
              ListTile(
                leading: Icon(isFavoriteStation(s.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded),
                title: Text(isFavoriteStation(s.id) ? tr('Usuń z ulubionych stacji') : tr('Dodaj do ulubionych stacji')),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(toggleFavoriteStation(s));
                },
              ),
            if (onAir != null && onAir.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.manage_search_rounded),
                title: Text(tr('Szukaj w bibliotece')),
                subtitle: Text(onAir),
                onTap: () {
                  Navigator.pop(context);
                  findInLibrary(onAir);
                },
              ),
            ListTile(
              leading: const Icon(Icons.radio_rounded),
              title: Text(tr('Wszystkie stacje')),
              onTap: () {
                Navigator.pop(context);
                go(const Nav('radio'));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> addStation() async {
    final repo = radio;
    if (repo == null) return;
    final url = TextEditingController(), name = TextEditingController();
    String? error;
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) {
          Future<void> save() async {
            final address = url.text.trim();
            if (!address.startsWith('http://') && !address.startsWith('https://')) {
              set(() => error = tr('Adres stacji musi zaczynać się od http:// lub https://'));
              return;
            }
            set(() {
              busy = true;
              error = null;
            });
            try {
              final p = await repo.radioProbe(address);
              final s = Station(
                id: Station.customId(address),
                name: name.text.trim().isNotEmpty ? name.text.trim() : (p['name'] as String? ?? Uri.parse(address).host),
                url: address,
                codec: p['codec'] as String? ?? '',
                hls: p['hls'] == true,
              );
              if (!context.mounted) return;
              Navigator.pop(context);
              if (!isFavoriteStation(s.id)) await toggleFavoriteStation(s);
              await playStation(s);
            } catch (e) {
              set(() {
                busy = false;
                error = trMessage('$e'.replaceFirst('Exception: ', ''));
              });
            }
          }

          return AlertDialog(
            title: Text(tr('Dodaj stację')),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: url,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(labelText: tr('Adres strumienia lub listy .pls / .m3u'), hintText: 'https://'),
                    onSubmitted: (_) => unawaited(save()),
                  ),
                  const SizedBox(height: Sp.s),
                  TextField(controller: name, decoration: InputDecoration(labelText: tr('Nazwa (opcjonalnie)'))),
                  if (error != null) ...[const SizedBox(height: Sp.s), Text(error!, style: TextStyle(color: dangerText))],
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: Text(tr('Anuluj'))),
              FilledButton(onPressed: busy ? null : () => unawaited(save()), child: Text(busy ? tr('Sprawdzam…') : tr('Dodaj i słuchaj'))),
            ],
          );
        },
      ),
    );
  }
}

/// Station logo; without one (or when it fails to load) a tile with the initials.
class StationLogo extends StatelessWidget {
  final LibraryScreenState app;
  final Station station;
  final double size;
  const StationLogo({super.key, required this.app, required this.station, this.size = 44});
  @override
  Widget build(BuildContext context) {
    final tile = InitialsTile(name: station.displayName, size: size);
    if (station.logo.isEmpty) return tile;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * .18),
      child: LogoArt(app.radioLogoUri(station.logo), width: size, height: size, fill: .8, fallback: tile),
    );
  }
}

class InitialsTile extends StatelessWidget {
  final String name;
  final double size;
  const InitialsTile({super.key, required this.name, required this.size});
  @override
  Widget build(BuildContext context) {
    final words = name.split(RegExp(r'[\s\-_.]+')).where((w) => w.isNotEmpty).toList();
    final letters = words.isEmpty
        ? '?'
        : words.length == 1
        ? words.first.characters.take(2).toString()
        : '${words[0].characters.first}${words[1].characters.first}';
    final hue = (name.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0xffff) % 360).toDouble();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * .18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [HSLColor.fromAHSL(1, hue, .45, .42).toColor(), HSLColor.fromAHSL(1, (hue + 40) % 360, .5, .28).toColor()],
        ),
      ),
      child: Text(
        letters.toUpperCase(),
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * .36, letterSpacing: -.5),
      ),
    );
  }
}

class RadioPage extends StatefulWidget {
  final LibraryScreenState app;
  const RadioPage({super.key, required this.app});
  @override
  State<RadioPage> createState() => _RadioPageState();
}

class _RadioPageState extends State<RadioPage> {
  LibraryScreenState get app => widget.app;
  final query = TextEditingController();
  String? genre;
  String? searched;
  List<Station>? results, popular;
  String? error, popularError;
  bool searching = false;
  int _serial = 0;

  String get country => lang == 'pl' ? 'PL' : '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadPopular());
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _loadPopular() async {
    final repo = app.radio;
    if (repo == null) return;
    try {
      final list = await repo.radioSearch({if (country.isNotEmpty) 'country': country, 'limit': '30'});
      if (mounted) setState(() => popular = list);
    } catch (e) {
      if (mounted) setState(() => popularError = trMessage('$e'));
    }
  }

  Future<void> _search({String? name, String? tag}) async {
    final repo = app.radio;
    if (repo == null) return;
    final serial = ++_serial;
    setState(() {
      searching = true;
      error = null;
      searched = name ?? tag;
    });
    try {
      final list = await repo.radioSearch({
        if (name != null && name.isNotEmpty) 'name': name,
        'tag': ?tag,
        'limit': '60',
      });
      if (!mounted || serial != _serial) return;
      setState(() {
        results = list;
        searching = false;
      });
    } catch (e) {
      if (!mounted || serial != _serial) return;
      setState(() {
        error = trMessage('$e');
        searching = false;
        results = null;
      });
    }
  }

  void _clear() {
    _serial++;
    query.clear();
    setState(() {
      genre = null;
      searched = null;
      results = null;
      error = null;
      searching = false;
    });
  }

  Widget _row(Station s, [List<Station> from = const []]) {
    final onAir = app.player.state.radio?['id'] == s.id;
    final blocked = s.hls && !(app.radio?.radioHls ?? true);
    final fav = app.isFavoriteStation(s.id);
    return Opacity(
      opacity: blocked ? .55 : 1,
      child: ListTile(
        contentPadding: EdgeInsets.symmetric(horizontal: app.desktopMode ? Sp.xl : Sp.l),
        leading: StationLogo(app: app, station: s),
        title: Text(
          s.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.w600, color: onAir ? accent : primaryText),
        ),
        subtitle: Text(
          blocked ? tr('HLS, na PC jeszcze niedostępna') : s.details,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Txt.meta,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onAir) LevelBars(playing: app.playing, width: 16, height: 14),
            IconAction(
              fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              fav ? tr('Usuń z ulubionych stacji') : tr('Dodaj do ulubionych stacji'),
              () => unawaited(app.toggleFavoriteStation(s)),
              color: fav ? accent : secondaryText,
            ),
          ],
        ),
        onTap: () => unawaited(onAir ? app.togglePlay() : app.playStation(s, from: from)),
      ),
    );
  }

  Widget _header(String text) => SectionHeader(
    text,
    padding: EdgeInsets.fromLTRB(app.desktopMode ? Sp.xl : Sp.l, Sp.l, Sp.s, Sp.xs),
  );

  @override
  Widget build(BuildContext context) => PlayerListener(app: app, builder: (context, _) => _list(context));

  Widget _list(BuildContext context) {
    final desktop = app.desktopMode;
    final pad = EdgeInsets.symmetric(horizontal: desktop ? Sp.xl : Sp.l);
    final favorites = app.favoriteStations;
    final heard = app.heardOnRadio.take(8).toList();
    final recent = app.recentStations.where((s) => !app.isFavoriteStation(s.id)).take(6).toList();
    final children = <Widget>[
      if (desktop) Padding(padding: const EdgeInsets.fromLTRB(Sp.xl, Sp.xl, Sp.xl, Sp.s), child: Text(tr('Radio'), style: Txt.display)),
      Padding(
        padding: pad.copyWith(top: Sp.s),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: query,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: tr('Szukaj stacji'),
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: searched == null ? null : IconAction(Icons.close_rounded, tr('Wyczyść'), _clear),
                ),
                onSubmitted: (v) {
                  if (v.trim().isEmpty) return _clear();
                  setState(() => genre = null);
                  unawaited(_search(name: v.trim()));
                },
              ),
            ),
            const SizedBox(width: Sp.s),
            IconAction(Icons.add_link_rounded, tr('Dodaj stację z adresu'), () => unawaited(app.addStation()), color: secondaryText),
          ],
        ),
      ),
      SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: pad.copyWith(top: Sp.s),
          children: [
            for (final (tag, label) in radioGenres)
              Padding(
                padding: const EdgeInsets.only(right: Sp.xs),
                child: FilterChip(
                  label: Text(tr(label)),
                  selected: genre == tag,
                  onSelected: (on) {
                    if (!on) return _clear();
                    query.clear();
                    setState(() => genre = tag);
                    unawaited(_search(tag: tag));
                  },
                ),
              ),
          ],
        ),
      ),
      if (searched != null) ...[
        _header(genre != null ? tr(radioGenres.firstWhere((g) => g.$1 == genre).$2) : tr('Wyniki: {0}', [searched!])),
        if (searching)
          const Padding(padding: EdgeInsets.all(Sp.xl), child: Center(child: CircularProgressIndicator()))
        else if (error != null)
          Padding(padding: pad, child: Text(error!, style: TextStyle(color: dangerText)))
        else if (results!.isEmpty)
          Padding(padding: pad, child: Text(tr('Brak stacji.'), style: Txt.sub))
        else
          for (final s in results!) _row(s, results!),
      ] else ...[
        _header(tr('Ulubione stacje')),
        if (favorites.isEmpty)
          Padding(
            padding: pad,
            child: Text(tr('Dotknij serca przy stacji, żeby mieć ją tutaj i w Android Auto.'), style: Txt.sub),
          )
        else
          for (final s in favorites) _row(s, favorites),
        if (recent.isNotEmpty) ...[
          _header(tr('Ostatnio słuchane')),
          for (final s in recent) _row(s, recent),
        ],
        if (heard.isNotEmpty) ...[
          _header(tr('Słyszane w radiu')),
          for (final h in heard)
            ListTile(
              contentPadding: pad,
              leading: const Icon(Icons.music_note_rounded),
              title: Text(h['title'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(h['station'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.meta),
              trailing: Icon(Icons.manage_search_rounded, color: secondaryText),
              onTap: () => app.findInLibrary(h['title'] as String? ?? ''),
            ),
        ],
        _header(country == 'PL' ? tr('Popularne w Polsce') : tr('Popularne stacje')),
        if (popular == null && popularError == null)
          const Padding(padding: EdgeInsets.all(Sp.xl), child: Center(child: CircularProgressIndicator()))
        else if (popularError != null)
          Padding(padding: pad, child: Text(popularError!, style: TextStyle(color: dangerText)))
        else
          for (final s in popular!) _row(s, popular!),
        Padding(
          padding: pad.copyWith(top: Sp.l, bottom: Sp.xxl),
          child: Text(tr('Katalog stacji: radio-browser.info (społecznościowy, bez reklam).'), style: Txt.meta),
        ),
      ],
    ];
    return ListView(padding: const EdgeInsets.only(bottom: Sp.xl), children: children);
  }
}

/// Square station tile for shelves (Home: recently played stations).
Widget stationCard(LibraryScreenState app, Station s, double size) {
  final onAir = app.player.state.radio?['id'] == s.id;
  return CollectionCard(
    cover: null,
    placeholder: StationLogo(app: app, station: s, size: size - Sp.l),
    title: s.displayName,
    subtitle: s.details.isEmpty ? tr('Radio') : s.details,
    size: size,
    current: onAir,
    playing: onAir && app.playing,
    onOpen: () => unawaited(onAir ? app.togglePlay() : app.playStation(s, from: app.recentStations)),
  );
}
