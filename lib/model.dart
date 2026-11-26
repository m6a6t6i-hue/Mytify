import 'audio_models.dart';
export 'audio_models.dart';
import 'metadata_models.dart';
export 'metadata_models.dart';

import 'dart:convert';
import 'dart:typed_data';
import 'l10n.dart';

const audioExtensions = [
  'mp3',
  'flac',
  'm4a',
  'aac',
  'wav',
  'ogg',
  'opus',
  'aif',
  'aiff',
];

class Track {
  final String id, title, artist, album, albumArtist, fileName, format;
  final String? cover;
  final int size,
      durationMs,
      trackNumber,
      discNumber,
      sampleRate,
      bitDepth,
      addedAt;
  final bool liked, available, managed, edited;

  /// A complete copy on this device ("Pobrane") / lives on a network source.
  final bool offline, remote;

  /// On a network source that did not answer: not dimmed, playing connects first.
  bool get waitsForSource => remote && !available && !offline;

  /// Can be played now or after its NAS answers.
  bool get playableSoon => available || waitsForSource;
  final String metadataSource;
  final String? releaseId;
  final int locationCount;
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumArtist,
    required this.fileName,
    required this.format,
    required this.size,
    this.durationMs = 0,
    this.trackNumber = 0,
    this.discNumber = 0,
    this.sampleRate = 0,
    this.bitDepth = 0,
    this.addedAt = 0,
    this.cover,
    this.liked = false,
    this.available = true,
    this.managed = false,
    this.offline = false,
    this.remote = false,
    this.locationCount = 1,
    this.edited = false,
    this.metadataSource = '',
    this.releaseId,
  });
  factory Track.fromJson(Map<String, dynamic> j) => Track(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    artist: j['artist'] as String? ?? '',
    album: j['album'] as String? ?? '',
    albumArtist: j['albumArtist'] as String? ?? '',
    fileName: j['fileName'] as String? ?? '',
    format: j['format'] as String? ?? '',
    size: (j['size'] as num?)?.toInt() ?? 0,
    durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
    trackNumber: (j['trackNumber'] as num?)?.toInt() ?? 0,
    discNumber: (j['discNumber'] as num?)?.toInt() ?? 0,
    sampleRate: (j['sampleRate'] as num?)?.toInt() ?? 0,
    bitDepth: (j['bitDepth'] as num?)?.toInt() ?? 0,
    addedAt: (j['addedAt'] as num?)?.toInt() ?? 0,
    cover: j['cover'] as String?,
    liked: j['liked'] == true,
    available: j['available'] != false,
    managed: j['managed'] == true,
    offline: j['offline'] == true,
    remote: j['remote'] == true,
    locationCount: (j['locationCount'] as num?)?.toInt() ?? 1,
    edited: j['edited'] == true,
    metadataSource: j['metadataSource'] as String? ?? '',
    releaseId: j['releaseId'] as String?,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'albumArtist': albumArtist,
    'fileName': fileName,
    'format': format,
    'size': size,
    'durationMs': durationMs,
    'trackNumber': trackNumber,
    'discNumber': discNumber,
    'sampleRate': sampleRate,
    'bitDepth': bitDepth,
    'addedAt': addedAt,
    'cover': cover,
    'liked': liked,
    'available': available,
    'managed': managed,
    'offline': offline,
    'remote': remote,
    'locationCount': locationCount,
    'edited': edited,
    'metadataSource': metadataSource,
    'releaseId': releaseId,
  };
  Track withLiked(bool value) => Track.fromJson({...toJson(), 'liked': value});
  String get displayArtist => artist.isEmpty ? tr('Nieznany wykonawca') : artist;
  String get displayAlbum => album.isEmpty ? tr('Bez albumu') : album;
  // Untagged files must not collapse into an invented album.
  String get albumKey {
    final normalizedAlbum = albumGroupingPart(album);
    if (normalizedAlbum.isEmpty) return 'file:$id';
    final normalizedAlbumArtist = albumGroupingPart(albumArtist);
    return jsonEncode([
      normalizedAlbum,
      normalizedAlbumArtist.isEmpty
          ? albumGroupingPart(artist)
          : normalizedAlbumArtist,
    ]);
  }

  Uint8List? get coverBytes {
    if (cover == null) return null;
    try {
      return base64Decode(cover!.split(',').last);
    } catch (_) {
      return null;
    }
  }
}

class ImportProgress {
  final int done, total;
  final String name;
  const ImportProgress(this.done, this.total, this.name);
}

class ImportReport {
  final int added,
      duplicates,
      ignored,
      updated,
      unchanged,
      missing,
      offlineSources;
  final List<String> errors;
  final bool cancelled;
  const ImportReport({
    this.added = 0,
    this.duplicates = 0,
    this.ignored = 0,
    this.updated = 0,
    this.unchanged = 0,
    this.missing = 0,
    this.offlineSources = 0,
    this.errors = const [],
    this.cancelled = false,
  });
  factory ImportReport.fromJson(Map<String, dynamic> j) => ImportReport(
    added: (j['added'] as num?)?.toInt() ?? 0,
    duplicates: (j['duplicates'] as num?)?.toInt() ?? 0,
    ignored: (j['ignored'] as num?)?.toInt() ?? 0,
    updated: (j['updated'] as num?)?.toInt() ?? 0,
    unchanged: (j['unchanged'] as num?)?.toInt() ?? 0,
    missing: (j['missing'] as num?)?.toInt() ?? 0,
    offlineSources: (j['offlineSources'] as num?)?.toInt() ?? 0,
    errors: (j['errors'] as List? ?? []).cast<String>(),
    cancelled: j['cancelled'] == true,
  );
}

/// Platforms with network sources: checks the shares right now (normally done in the background).
abstract class SourceProbe {
  Future<void> probeSources();
}

abstract class LibraryRepository {
  String get storageDescription;
  Future<List<Track>> load();
  Future<ImportReport> importAudio({
    required bool folder,
    required void Function(ImportProgress) onProgress,
  });
  Future<void> setLiked(String id, bool value);
  Future<void> remove(String id);
  Future<String> playableUri(String id);
  Future<List<LibrarySource>> sources();
  Future<ImportReport> rescan({
    String? sourceId,
    required void Function(ImportProgress) onProgress,
  });
  Future<ImportReport> relink(
    String id, {
    required void Function(ImportProgress) onProgress,
  });
  Future<void> forgetSource(String id);
  Future<List<String>> searchIds(String query);
  Future<ImportReport> migrateLegacy({
    required void Function(ImportProgress) onProgress,
  });
  Future<void> cancelImport();
  Future<List<ReleaseCandidate>> findReleases(String album, String artist);
  Future<ReleaseInfo> releaseDetails(String id);

  /// Discogs release by number or page address (PC).
  Future<ReleaseInfo> discogsRelease(String id) => throw UnsupportedError(tr('Discogs jest dostępny w wersji na PC'));
  Future<CoverChoice?> downloadCover(String id);
  Future<CoverChoice?> chooseCover();
  Future<void> editMetadata(List<MetadataEdit> edits);
  Future<void> resetMetadata(List<String> ids);
  Future<AudioSnapshot> audioState();
  Future<AudioSnapshot> audioCommand(Map<String, dynamic> action);
  Future<List<AudioDevice>> audioDevices();

  /// Band levels in dBFS (low to high) of what the output is playing right now,
  /// or null when the platform has no real signal to show.
  Future<List<double>?> audioLevels() async => null;
  bool get hasAudioLevels => false;

  /// The desktop window can switch to the mini player and full screen.
  bool get hasWindow => false;

  /// Time since the last keyboard or mouse input in the whole system (PC), or null.
  Future<int?> systemIdleMs() async => null;
  Future<void> windowAction(Map<String, dynamic> action) async {}

  /// Keeps the display on (full screen visualizations on a phone).
  Future<void> keepScreenOn(bool value) async {}

  /// Where the phone sends media now: {kind: bluetooth|usb|wired|hdmi|speaker, name}.
  Future<Map<String, dynamic>?> systemOutput() async => null;

  /// Language of texts the platform shows itself (Android Auto, notification, widget).
  Future<void> setLanguage(String code) async {}

  /// Opens the system picker for Bluetooth and other outputs; false when there is none.
  Future<bool> openSystemOutputs() async => false;
  Future<void> dispose() async {}

  /// Network protocols that really work here ("smb" ...). Empty means local music only.
  Future<List<String>> networkProtocols() async => const [];

  /// Logs in and lists the chosen folder; nothing is saved. Throws a readable message.
  /// Music servers have no folders and describe themselves in [message].
  Future<({List<String> folders, String? message})> testSource(Map<String, dynamic> config, {String? id}) =>
      Future.error(StateError(tr('Źródła sieciowe nie są dostępne w tej wersji.')));

  /// A finished play; music servers receive it as a scrobble.
  Future<void> played(String id) async {}

  /// Offline copies: status, estimate, add, pause, cancel, remove, keep, cellular.
  Future<Map<String, dynamic>> downloads(String action, [Map<String, dynamic> args = const {}]) =>
      Future.error(StateError(tr('Pobieranie offline nie jest dostępne w tej wersji.')));

  /// Subfolders of [path] inside the share, for the folder picker.
  Future<List<String>> browseSource(Map<String, dynamic> config, String path, {String? id}) =>
      Future.error(StateError(tr('Źródła sieciowe nie są dostępne w tej wersji.')));

  /// Adds or edits a network source. Returns its id. The password goes to the system store.
  Future<String> saveSource(Map<String, dynamic> config, {String? id}) =>
      Future.error(StateError(tr('Źródła sieciowe nie są dostępne w tej wersji.')));

  /// Saved settings without the password (`hasPassword` tells if one is stored).
  Future<Map<String, dynamic>> sourceSettings(String id) =>
      Future.error(StateError(tr('Źródła sieciowe nie są dostępne w tej wersji.')));

  /// Rust player accepts an atomic queue restore; Android Media3 does not.
  bool get queueRestore => true;
}

class LibrarySource {
  final String id, name, path, kind, state;
  final int files, availableFiles, lastScan;

  /// "local", "smb" ... and what the source can do. Address never contains credentials.
  final String protocol, address;
  final List<String> capabilities;
  const LibrarySource({
    required this.id,
    required this.name,
    required this.path,
    required this.kind,
    required this.state,
    required this.files,
    required this.availableFiles,
    required this.lastScan,
    this.protocol = 'local',
    this.address = '',
    this.capabilities = const [],
  });
  bool get network => protocol != 'local';
  factory LibrarySource.fromJson(Map<String, dynamic> j) => LibrarySource(
    id: j['id'] as String,
    name: j['name'] as String,
    path: j['path'] as String,
    kind: j['kind'] as String,
    state: j['state'] as String,
    files: (j['files'] as num).toInt(),
    availableFiles: (j['availableFiles'] as num).toInt(),
    lastScan: (j['lastScan'] as num).toInt(),
    protocol: j['protocol'] as String? ?? 'local',
    address: j['address'] as String? ?? '',
    capabilities: [for (final c in j['capabilities'] as List? ?? const []) c as String],
  );
}

String durationLabel(int milliseconds) {
  if (milliseconds <= 0) return '--:--';
  final seconds = milliseconds ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String searchKey(String value) => value
    .toLowerCase()
    .replaceAll('ą', 'a')
    .replaceAll('ć', 'c')
    .replaceAll('ę', 'e')
    .replaceAll('ł', 'l')
    .replaceAll('ń', 'n')
    .replaceAll('ó', 'o')
    .replaceAll('ś', 's')
    .replaceAll('ź', 'z')
    .replaceAll('ż', 'z');

List<Track> filterTracks(List<Track> tracks, String query) {
  final terms = searchKey(query)
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty);
  return tracks.where((t) {
    final haystack = searchKey(
      '${t.title} ${t.artist} ${t.album} ${t.albumArtist} ${t.fileName}',
    );
    return terms.every(haystack.contains);
  }).toList();
}

int albumOrder(Track a, Track b) {
  final disc = a.discNumber.compareTo(b.discNumber);
  if (disc != 0) return disc;
  if (a.trackNumber != b.trackNumber) {
    return a.trackNumber.compareTo(b.trackNumber);
  }
  return a.fileName.compareTo(b.fileName);
}

// Positional suggestions require an unambiguous disc/track pair on both sides.
List<int> suggestTrackMapping(List<Track> local, List<ReleaseSong> release) =>
    local.map((track) {
      if (track.discNumber <= 0 || track.trackNumber <= 0) {
        return -1;
      }
      final localCount = local
          .where(
            (t) =>
                t.discNumber == track.discNumber &&
                t.trackNumber == track.trackNumber,
          )
          .length;
      final matches = release.indexed
          .where(
            (p) =>
                p.$2.discNumber == track.discNumber &&
                p.$2.trackNumber == track.trackNumber,
          )
          .toList();
      return localCount == 1 && matches.length == 1 ? matches.single.$1 : -1;
    }).toList();

/// Formatting differences in tags must not split an album. Original text is retained.
String albumGroupingPart(String text) => text
    .replaceAll(
      RegExp(
        r'[\s\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+',
      ),
      ' ',
    )
    .trim()
    .toLowerCase();

/// `{"bands": [...]}` from the player, or null when there is nothing real to show.
List<double>? levelsFrom(Object? json) {
  final bands = json is Map ? json['bands'] : null;
  if (bands is! List || bands.isEmpty) return null;
  return [for (final b in bands) (b as num).toDouble()];
}
