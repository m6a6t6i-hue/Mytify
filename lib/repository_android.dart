import 'transfer.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'model.dart';
import 'radio.dart';
import 'playlists.dart';
import 'l10n.dart';

class AndroidLibraryRepository extends LibraryRepository
    implements
        PlaylistRepository,
        TransferRepository,
        LibraryChangesRepository,
        RadioRepository {
  Future<dynamic> _radioCall(String action, Map<String, dynamic> body) =>
      _call('radio', jsonEncode({...body, 'action': action}));
  @override
  Future<List<Station>> radioSearch(Map<String, String> query) async => [
    for (final v in await _radioCall('search', query) as List) ?Station.fromJson(Map<String, dynamic>.from(v as Map)),
  ];
  @override
  Future<String?> radioClick(String id) async => ((await _radioCall('click', {'id': id})) as Map)['url'] as String?;
  @override
  Future<Map<String, dynamic>> radioProbe(String url) async => Map<String, dynamic>.from(await _radioCall('probe', {'url': url}) as Map);
  @override
  Future<void> radioFavorites(List<Station> stations) async {
    await _radioCall('favorites', {'stations': [for (final s in stations) s.toJson()]});
  }
  @override
  Future<String?> radioLogoBase() async => null;
  @override
  bool get radioHls => true;
  @override
  bool get queueRestore => false;
  @override
  bool get receivesTransfers => true;
  @override
  Future<dynamic> transfer(Map<String, dynamic> request) async =>
      _call('transfer', jsonEncode(request));

  final _changes = StreamController<void>.broadcast();
  @override
  Stream<void> get changes => _changes.stream;
  static const _channel = MethodChannel('pl.mytify/library');
  static const _events = EventChannel('pl.mytify/import');
  void Function(ImportProgress)? _progress;
  late final StreamSubscription<dynamic> _subscription = _events
      .receiveBroadcastStream()
      .listen((event) {
        final j = jsonDecode(event as String) as Map;
        _progress?.call(
          ImportProgress(
            j['done'] as int,
            j['total'] as int,
            j['name'] as String,
          ),
        );
      }, onError: (Object _) {});
  AndroidLibraryRepository() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'libraryChanged') _changes.add(null);
    });
    _subscription;
  }
  Future<dynamic> _call(String method, [Object? args]) async {
    final s = await _channel.invokeMethod<String>(method, args);
    return s == null ? null : jsonDecode(s);
  }

  Map<String, dynamic> _map(dynamic v) => Map<String, dynamic>.from(v as Map);
  Future<ImportReport> _job(
    String method,
    Object? args,
    void Function(ImportProgress) update,
  ) async {
    _progress = update;
    try {
      return ImportReport.fromJson(_map(await _call(method, args)));
    } finally {
      _progress = null;
    }
  }

  @override
  String get storageDescription =>
      tr('Wybierz folder Muzyka lub pojedyncze pliki. Mytify zapamięta dostęp i odczyta tagi oraz okładki. Nie kopiuje ani nie zmienia muzyki. Duży import pozostaw otwarty; po przerwaniu możesz ponowić skan.');
  @override
  Future<List<Track>> load() async => (await _call('load') as List)
      .map((v) => Track.fromJson(_map(v)))
      .toList();
  @override
  Future<ImportReport> importAudio({
    required bool folder,
    required void Function(ImportProgress) onProgress,
  }) => _job('import', {'folder': folder}, onProgress);
  @override
  Future<ImportReport> rescan({
    String? sourceId,
    required void Function(ImportProgress) onProgress,
  }) => _job('rescan', {'id': sourceId}, onProgress);
  @override
  Future<ImportReport> relink(
    String id, {
    required void Function(ImportProgress) onProgress,
  }) => _job('relink', {'id': id}, onProgress);
  @override
  Future<void> cancelImport() async {
    await _call('cancel');
  }

  @override
  Future<void> setLiked(String id, bool value) async {
    await _call('like', {'id': id, 'value': value});
  }

  @override
  Future<void> remove(String id) async {
    await _call('remove', id);
  }

  @override
  Future<String> playableUri(String id) async =>
      await _call('uri', id) as String;
  @override
  Future<List<LibrarySource>> sources() async =>
      (await _call('sources') as List)
          .map((v) => LibrarySource.fromJson(_map(v)))
          .toList();
  @override
  Future<void> forgetSource(String id) async {
    await _call('forget', id);
  }

  @override
  Future<List<String>> searchIds(String query) async =>
      filterTracks(await load(), query).map((t) => t.id).toList();
  @override
  Future<ImportReport> migrateLegacy({
    required void Function(ImportProgress) onProgress,
  }) => Future.error(StateError(tr('Migrację wersji PC wykonaj na komputerze.')));
  @override
  Future<List<ReleaseCandidate>> findReleases(
    String album,
    String artist,
  ) async =>
      (await _call('findReleases', {'album': album, 'artist': artist}) as List)
          .map((v) => ReleaseCandidate.fromJson(_map(v)))
          .toList();
  @override
  Future<ReleaseInfo> releaseDetails(String id) async =>
      ReleaseInfo.fromJson(_map(await _call('releaseDetails', id)));
  @override
  Future<CoverChoice?> downloadCover(String id) async =>
      CoverChoice.fromJson(_map(await _call('downloadCover', id)));
  @override
  Future<CoverChoice?> chooseCover() async {
    final v = await _call('chooseCover');
    return v == null ? null : CoverChoice.fromJson(_map(v));
  }

  @override
  Future<void> editMetadata(List<MetadataEdit> edits) async {
    await _call('edit', jsonEncode(edits.map((e) => e.toJson()).toList()));
  }

  @override
  Future<void> resetMetadata(List<String> ids) async {
    await _call('reset', ids);
  }

  @override
  bool get hasAudioLevels => true;
  @override
  Future<List<double>?> audioLevels() async => levelsFrom(await _call('audioLevels'));
  @override
  Future<Map<String, dynamic>?> systemOutput() async {
    final v = await _channel.invokeMethod<Object?>('systemOutput');
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  @override
  Future<void> setLanguage(String code) => _channel.invokeMethod<void>('setLanguage', code);

  @override
  Future<bool> openSystemOutputs() async => await _channel.invokeMethod<bool>('openSystemOutputs') ?? false;

  @override
  Future<void> keepScreenOn(bool value) async {
    await _channel.invokeMethod<void>('keepScreenOn', value);
  }

  @override
  Future<AudioSnapshot> audioState() async =>
      AudioSnapshot.fromJson(_map(await _call('audioState')));
  @override
  Future<AudioSnapshot> audioCommand(Map<String, dynamic> action) async =>
      AudioSnapshot.fromJson(_map(await _call('audioCommand', action)));
  @override
  Future<List<AudioDevice>> audioDevices() async =>
      ((await _call('audioDevices')) as List)
          .map((v) => AudioDevice.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();

  @override
  Future<List<String>> networkProtocols() async =>
      [for (final p in await _call('networkProtocols') as List) p as String];
  @override
  Future<({List<String> folders, String? message})> testSource(Map<String, dynamic> config, {String? id}) async {
    final r = _map(await _call('testSource', jsonEncode({'id': id, 'config': config})));
    return (folders: [for (final f in r['folders'] as List? ?? const []) f as String], message: r['message'] as String?);
  }
  @override
  Future<void> played(String id) async {
    await _call('played', id);
  }
  @override
  Future<Map<String, dynamic>> downloads(String action, [Map<String, dynamic> args = const {}]) async =>
      _map(await _call('downloads', jsonEncode({...args, 'action': action})));
  @override
  Future<List<String>> browseSource(Map<String, dynamic> config, String path, {String? id}) async => [
    for (final f in _map(await _call('browseSource', jsonEncode({'id': id, 'config': config, 'path': path})))['folders'] as List)
      f as String,
  ];
  @override
  Future<String> saveSource(Map<String, dynamic> config, {String? id}) async =>
      _map(await _call('saveSource', jsonEncode({'id': id, 'config': config})))['id'] as String;
  @override
  Future<Map<String, dynamic>> sourceSettings(String id) async => _map(await _call('sourceSettings', id));

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _changes.close();
    await _subscription.cancel();
  }

  @override
  Future<List<MusicPlaylist>> playlists() async =>
      (await _call('playlists') as List)
          .map((j) => MusicPlaylist.fromJson(_map(j)))
          .toList();
  @override
  Future<void> savePlaylist(String? id, String name, List<String> ids) async {
    await _call('savePlaylist', {'id': id, 'name': name, 'ids': ids});
  }

  @override
  Future<void> deletePlaylist(String id) async {
    await _call('deletePlaylist', id);
  }
}
