import 'model.dart';
import 'playlists.dart';

/// One album as the user sees it. Grouping matches Track.albumKey and Android Auto.
class AlbumGroup {
  final String key, title, artist;
  final List<Track> tracks;
  AlbumGroup(this.key, this.title, this.artist, this.tracks);
  Track get art => tracks.where((t) => t.cover != null).firstOrNull ?? tracks.first;
  int get addedAt => tracks.fold(0, (m, t) => t.addedAt > m ? t.addedAt : m);
  int get durationMs => tracks.fold(0, (m, t) => m + t.durationMs);
  bool get available => tracks.any((t) => t.available);
  bool get singleArtist =>
      tracks.map((t) => albumGroupingPart(t.artist)).toSet().length <= 1;
  List<Track> get playable => tracks.where((t) => t.available).toList();
  String get artistKey => LibraryIndex.artistKeyOf(artist);
  String? get quality => qualityLabel(tracks);
}

class ArtistGroup {
  final String key, name;
  final List<AlbumGroup> albums = [];
  final List<Track> tracks = [];
  ArtistGroup(this.key, this.name);
  Track? get art =>
      albums.map((a) => a.art).where((t) => t.cover != null).firstOrNull ??
      tracks.where((t) => t.cover != null).firstOrNull;
}

/// Honest quality badge: only when every file is lossless and the tags say so.
String? qualityLabel(List<Track> tracks) {
  if (tracks.isEmpty) return null;
  if (!tracks.every((t) => lossless(t.format))) return null;
  final depth = tracks.map((t) => t.bitDepth).reduce((a, b) => a < b ? a : b);
  final rate = tracks.map((t) => t.sampleRate).reduce((a, b) => a < b ? a : b);
  if (depth >= 24 && rate > 48000) return 'Hi-Res';
  if (depth >= 16 && rate >= 44100) return 'Lossless';
  return null;
}

bool lossless(String format) => const {
  'flac',
  'wav',
  'aif',
  'aiff',
  'ape',
  'wv',
  'alac',
}.contains(format.toLowerCase());

String artistName(Track t) =>
    t.albumArtist.trim().isNotEmpty ? t.albumArtist : t.displayArtist;

class LibraryIndex {
  final List<Track> tracks;
  final Map<String, Track> byId;
  final List<AlbumGroup> albums;
  final Map<String, AlbumGroup> albumByKey;
  final List<ArtistGroup> artists;
  final Map<String, ArtistGroup> artistByKey;
  LibraryIndex._(
    this.tracks,
    this.byId,
    this.albums,
    this.albumByKey,
    this.artists,
    this.artistByKey,
  );
  static String artistKeyOf(String name) => albumGroupingPart(name);

  factory LibraryIndex.build(List<Track> tracks) {
    final byId = {for (final t in tracks) t.id: t};
    final albumMap = <String, AlbumGroup>{};
    for (final t in tracks) {
      albumMap
          .putIfAbsent(
            t.albumKey,
            () => AlbumGroup(
              t.albumKey,
              t.album.trim().isEmpty ? t.title : t.album,
              artistName(t),
              [],
            ),
          )
          .tracks
          .add(t);
    }
    for (final a in albumMap.values) {
      a.tracks.sort(albumOrder);
    }
    final albums = albumMap.values.toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    final artistMap = <String, ArtistGroup>{};
    ArtistGroup artist(String name) {
      final key = artistKeyOf(name);
      return artistMap.putIfAbsent(key, () => ArtistGroup(key, name));
    }

    for (final a in albums) {
      artist(a.artist).albums.add(a);
    }
    for (final t in tracks) {
      artist(t.displayArtist).tracks.add(t);
    }
    final artists = artistMap.values.toList()
      ..sort((a, b) => searchKey(a.name).compareTo(searchKey(b.name)));
    return LibraryIndex._(tracks, byId, albums, albumMap, artists, artistMap);
  }

  static final empty = LibraryIndex.build(const []);

  late final Map<String, String> _keys = {
    for (final t in tracks)
      t.id: searchKey(
        '${t.title} ${t.artist} ${t.album} ${t.albumArtist} ${t.fileName}',
      ),
  };

  static List<String> terms(String query) =>
      searchKey(query).split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();

  List<Track> searchTracks(String query) {
    final words = terms(query);
    if (words.isEmpty) return const [];
    return tracks.where((t) => words.every(_keys[t.id]!.contains)).toList();
  }

  List<AlbumGroup> searchAlbums(String query) {
    final words = terms(query);
    if (words.isEmpty) return const [];
    return albums
        .where((a) => words.every(searchKey('${a.title} ${a.artist}').contains))
        .toList();
  }

  List<ArtistGroup> searchArtists(String query) {
    final words = terms(query);
    if (words.isEmpty) return const [];
    return artists.where((a) => words.every(searchKey(a.name).contains)).toList();
  }

  List<Track> liked() => tracks.where((t) => t.liked).toList()
    ..sort((a, b) => searchKey(a.title).compareTo(searchKey(b.title)));

  List<Track> playlistTracks(MusicPlaylist p) =>
      p.ids.map((id) => byId[id]).whereType<Track>().toList();
}

/// Listening history recorded on this device from real playback.
class PlayHistory {
  final Map<String, int> plays;
  final Map<String, int> lastPlayed;
  final List<String> recent;
  PlayHistory({
    Map<String, int>? plays,
    Map<String, int>? lastPlayed,
    List<String>? recent,
  }) : plays = plays ?? {},
       lastPlayed = lastPlayed ?? {},
       recent = recent ?? [];

  factory PlayHistory.fromJson(Map<String, dynamic> j) => PlayHistory(
    plays: Map<String, int>.from(j['plays'] as Map? ?? {}),
    lastPlayed: Map<String, int>.from(j['last'] as Map? ?? {}),
    recent: (j['recent'] as List? ?? []).cast<String>(),
  );
  Map<String, dynamic> toJson() => {
    'plays': plays,
    'last': lastPlayed,
    'recent': recent,
  };

  void started(String id) {
    recent.remove(id);
    recent.insert(0, id);
    if (recent.length > 300) recent.removeRange(300, recent.length);
    lastPlayed[id] = DateTime.now().millisecondsSinceEpoch;
  }

  void counted(String id) => plays[id] = (plays[id] ?? 0) + 1;

  int count(String id) => plays[id] ?? 0;

  List<AlbumGroup> recentAlbums(LibraryIndex index, {int limit = 20}) {
    final seen = <String>{};
    final out = <AlbumGroup>[];
    for (final id in recent) {
      final t = index.byId[id];
      if (t == null || !seen.add(t.albumKey)) continue;
      final a = index.albumByKey[t.albumKey];
      if (a != null) out.add(a);
      if (out.length >= limit) break;
    }
    return out;
  }

  List<Track> topTracks(LibraryIndex index, {int limit = 20}) {
    final ids = plays.keys.where(index.byId.containsKey).toList()
      ..sort((a, b) => plays[b]!.compareTo(plays[a]!));
    return ids.take(limit).map((id) => index.byId[id]!).toList();
  }

  List<ArtistGroup> topArtists(LibraryIndex index, {int limit = 12}) {
    final score = <String, int>{};
    plays.forEach((id, n) {
      final t = index.byId[id];
      if (t != null) {
        final key = LibraryIndex.artistKeyOf(artistName(t));
        score[key] = (score[key] ?? 0) + n;
      }
    });
    final keys = score.keys.where(index.artistByKey.containsKey).toList()
      ..sort((a, b) => score[b]!.compareTo(score[a]!));
    return keys.take(limit).map((k) => index.artistByKey[k]!).toList();
  }
}
