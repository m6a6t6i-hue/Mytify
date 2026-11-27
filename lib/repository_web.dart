import 'playlists.dart';
import 'transfer.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'model.dart';
import 'ingest.dart';
import 'l10n.dart';
import 'radio.dart';
import 'shop.dart';

@JS('mytifyBridge.load')
external JSPromise<JSString> _load();
@JS('mytifyBridge.sources')
external JSPromise<JSString> _sources();
@JS('mytifyBridge.search')
external JSPromise<JSString> _search(JSString query);
@JS('mytifyBridge.importAudio')
external JSPromise<JSString> _import(JSBoolean folder);
@JS('mytifyBridge.importPaths')
external JSPromise<JSString> _importPaths(JSString body);
@JS('mytifyOnDrop')
external set _onDrop(JSFunction? handler);
@JS('mytifyBridge.rescan')
external JSPromise<JSString> _rescan(JSString id);
@JS('mytifyBridge.relink')
external JSPromise<JSString> _relink(JSString id);
@JS('mytifyBridge.forgetSource')
external JSPromise<JSAny?> _forgetSource(JSString id);
@JS('mytifyBridge.migrate')
external JSPromise<JSString> _migrate();
@JS('mytifyBridge.cancel')
external JSPromise<JSAny?> _cancel();
@JS('mytifyBridge.progress')
external JSString _progress();
@JS('mytifyBridge.like')
external JSPromise<JSAny?> _like(JSString id, JSBoolean value);
@JS('mytifyBridge.remove')
external JSPromise<JSAny?> _remove(JSString id);
@JS('mytifyBridge.playableUri')
external JSPromise<JSString> _uri(JSString id);

@JS('mytifyBridge.metadata')
external JSPromise<JSString> _metadata(JSString action, JSString args);

@JS('mytifyBridge.windowAvailable')
external JSBoolean _windowAvailable();
@JS('mytifyBridge.windowAction')
external void _windowAction(JSString body);
@JS('mytifyBridge.audio')
external JSPromise<JSString> _audio(JSString route, JSString body);
LibraryRepository createRepository() => WebLibraryRepository();

@JS('mytifyBridge.transfer')
external JSPromise<JSString> _transfer(JSString body);

@JS('mytifyBridge.network')
external JSPromise<JSString> _network(JSString action, JSString body);

@JS('mytifyBridge.artists')
external JSPromise<JSString> _artists(JSString action, JSString body);

@JS('mytifyBridge.shop')
external JSPromise<JSString> _shop(JSString query, JSString country);

@JS('mytifyBridge.radio')
external JSPromise<JSString> _radio(JSString action, JSString body);

@JS('mytifyBridge.ingest')
external JSPromise<JSString> _ingest(JSString body);

class WebLibraryRepository extends LibraryRepository
    implements IngestRepository, PlaylistRepository, TransferRepository, RadioRepository, ShopRepository, SourceProbe, ArtistPhotoRepository, DropImport {
  @override
  void listenForDrops(void Function(List<String> folders, List<String> files) onDrop) {
    _onDrop = ((JSString json) {
      final v = jsonDecode(json.toDart) as Map;
      onDrop([for (final p in v['folders'] as List? ?? const []) '$p'], [for (final p in v['files'] as List? ?? const []) '$p']);
    }).toJS;
  }
  @override
  Future<ImportReport> importPaths(List<String> paths, {required bool folder, required void Function(ImportProgress) onProgress}) =>
      _operation(_importPaths(jsonEncode({'paths': paths, 'folder': folder}).toJS), onProgress);
  Future<dynamic> _artist(String action, [Map<String, dynamic> body = const {}]) async =>
      jsonDecode((await _artists(action.toJS, jsonEncode(body).toJS).toDart).toDart);
  @override
  Future<Map<String, String>> artistPhotos() async => {
    for (final e in (await _artist('photos') as Map).entries) '${e.key}': '${(e.value as Map)['uri']}',
  };
  @override
  Future<Map<String, dynamic>> artistPhotoStatus() async => Map<String, dynamic>.from(await _artist('status') as Map);
  @override
  Future<Map<String, dynamic>> refreshArtistPhotos({bool download = false, List<String>? only}) async =>
      Map<String, dynamic>.from(await _artist('refresh', {'download': download, 'only': ?only}) as Map);
  @override
  Future<void> cancelArtistPhotos() async => _artist('cancel');
  @override
  Future<String?> artistPhotoFolder() async => (await _artist('folder') as Map)['path'] as String?;
  @override
  Future<void> setArtistPhotoFolder(String? path) async => _artist('setFolder', {'path': path});
  @override
  Future<String?> pickArtistPhotoFolder() async {
    final paths = (await _artist('pick') as Map)['paths'] as List? ?? const [];
    return paths.isEmpty ? null : '${paths.first}';
  }
  @override
  Future<void> probeSources() async => _net('probe', '');
  @override
  Future<List<Offer>> shopSearch(String query, String country) async => [
    for (final v in jsonDecode((await _shop(query.toJS, country.toJS).toDart).toDart) as List) ?Offer.fromJson(Map<String, dynamic>.from(v as Map)),
  ];
  Future<dynamic> _radioCall(String action, Map<String, dynamic> body) async =>
      jsonDecode((await _radio(action.toJS, jsonEncode(body).toJS).toDart).toDart);
  @override
  Future<List<Station>> radioSearch(Map<String, String> query) async => [
    for (final v in await _radioCall('search', query) as List) ?Station.fromJson(Map<String, dynamic>.from(v as Map)),
  ];
  @override
  Future<String?> radioClick(String id) async => ((await _radioCall('click', {'id': id})) as Map)['url'] as String?;
  @override
  Future<Map<String, dynamic>> radioProbe(String url) async => Map<String, dynamic>.from(await _radioCall('probe', {'url': url}) as Map);
  @override
  Future<void> radioFavorites(List<Station> stations) async {}
  String? _logoBase;
  @override
  Future<String?> radioLogoBase() async => _logoBase ??= await _radioCall('logoBase', {}) as String;
  @override
  bool get radioHls => false;
  Future<dynamic> _net(String action, [Object? body]) async =>
      jsonDecode((await _network(action.toJS, (body is String ? body : jsonEncode(body)).toJS).toDart).toDart);
  @override
  Future<List<String>> networkProtocols() async => [for (final p in await _net('protocols', '') as List) p as String];
  @override
  Future<({List<String> folders, String? message})> testSource(Map<String, dynamic> config, {String? id}) async {
    final r = await _net('test', {'id': id, 'config': config}) as Map;
    return (folders: [for (final f in r['folders'] as List? ?? const []) f as String], message: r['message'] as String?);
  }
  @override
  Future<void> played(String id) async {
    await _net('played', id);
  }
  @override
  Future<Map<String, dynamic>> downloads(String action, [Map<String, dynamic> args = const {}]) async =>
      Map<String, dynamic>.from(await _net('downloads', {...args, 'action': action}) as Map);
  @override
  Future<List<String>> browseSource(Map<String, dynamic> config, String path, {String? id}) async =>
      [for (final f in (await _net('browse', {'id': id, 'config': config, 'path': path}) as Map)['folders'] as List) f as String];
  @override
  Future<String> saveSource(Map<String, dynamic> config, {String? id}) async =>
      (await _net('save', {'id': id, 'config': config}) as Map)['id'] as String;
  @override
  Future<Map<String, dynamic>> sourceSettings(String id) async =>
      Map<String, dynamic>.from(await _net('settings', id) as Map);

  @override
  bool get receivesTransfers => false;
  @override
  Future<dynamic> transfer(Map<String, dynamic> request) async =>
      jsonDecode((await _transfer(jsonEncode(request).toJS).toDart).toDart);
  @override
  Future<List<MusicPlaylist>> playlists() async =>
      ((await transfer({'action': 'playlistList'})) as List)
          .map(
            (j) => MusicPlaylist.fromJson(Map<String, dynamic>.from(j as Map)),
          )
          .toList();
  @override
  Future<void> savePlaylist(String? id, String name, List<String> ids) async {
    await transfer({
      'action': 'playlistSave',
      'id': id,
      'name': name,
      'ids': ids,
    });
  }

  @override
  Future<void> deletePlaylist(String id) async {
    await transfer({'action': 'playlistDelete', 'id': id});
  }

  @override
  Future<dynamic> ingest(Map<String, dynamic> request) async =>
      jsonDecode((await _ingest(jsonEncode(request).toJS).toDart).toDart);

  Future<dynamic> _meta(String action, Object? args) async => jsonDecode(
    (await _metadata(action.toJS, jsonEncode(args).toJS).toDart).toDart,
  );
  @override
  Future<List<ReleaseCandidate>> findReleases(
    String album,
    String artist,
  ) async =>
      ((await _meta('search', {'album': album, 'artist': artist})) as List)
          .map(
            (v) =>
                ReleaseCandidate.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
  @override
  Future<ReleaseInfo> releaseDetails(String id) async => ReleaseInfo.fromJson(
    Map<String, dynamic>.from(await _meta('release', id) as Map),
  );
  @override
  Future<ReleaseInfo> discogsRelease(String id) async => ReleaseInfo.fromJson(
    Map<String, dynamic>.from(await _meta('discogs', id) as Map),
  );
  @override
  Future<CoverChoice?> downloadCover(String id) async => CoverChoice.fromJson(
    Map<String, dynamic>.from(await _meta('cover', id) as Map),
  );
  @override
  Future<CoverChoice?> chooseCover() async => CoverChoice.fromJson(
    Map<String, dynamic>.from(await _meta('chooseCover', null) as Map),
  );
  @override
  Future<void> editMetadata(List<MetadataEdit> edits) async {
    await _meta('edits', edits.map((e) => e.toJson()).toList());
  }

  @override
  Future<void> resetMetadata(List<String> ids) async {
    await _meta('reset', ids);
  }

  Future<dynamic> _audioApi(String route, Object? body) async => jsonDecode(
    (await _audio(route.toJS, jsonEncode(body).toJS).toDart).toDart,
  );
  @override
  Future<AudioSnapshot> audioState() async => AudioSnapshot.fromJson(
    Map<String, dynamic>.from(await _audioApi('state', null) as Map),
  );
  @override
  Future<AudioSnapshot> audioCommand(Map<String, dynamic> action) async =>
      AudioSnapshot.fromJson(
        Map<String, dynamic>.from(await _audioApi('command', action) as Map),
      );
  @override
  bool get hasWindow {
    try {
      return _windowAvailable().toDart;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> windowAction(Map<String, dynamic> action) async => _windowAction(jsonEncode(action).toJS);

  @override
  bool get hasAudioLevels => true;
  @override
  Future<List<double>?> audioLevels() async =>
      levelsFrom(await _audioApi('levels', null));
  @override
  Future<int?> systemIdleMs() async => ((await _audioApi('idle', null)) as Map?)?['idleMs'] as int?;
  @override
  Future<List<AudioDevice>> audioDevices() async =>
      ((await _audioApi('devices', null)) as List)
          .map((v) => AudioDevice.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();
  @override
  String get storageDescription =>
      tr('Mytify zapamięta położenie muzyki na dysku. Nie utworzy dodatkowych kopii i nie zmieni oryginałów. Katalog i polubienia zapisuje na tym komputerze.');
  @override
  Future<List<Track>> load() async =>
      (jsonDecode((await _load().toDart).toDart) as List)
          .map((j) => Track.fromJson(Map<String, dynamic>.from(j as Map)))
          .toList();
  @override
  Future<List<LibrarySource>> sources() async =>
      (jsonDecode((await _sources().toDart).toDart) as List)
          .map(
            (j) => LibrarySource.fromJson(Map<String, dynamic>.from(j as Map)),
          )
          .toList();
  @override
  Future<List<String>> searchIds(String query) async =>
      (jsonDecode((await _search(query.toJS).toDart).toDart) as List)
          .cast<String>();
  Future<ImportReport> _operation(
    JSPromise<JSString> pending,
    void Function(ImportProgress) update,
  ) async {
    final timer = Timer.periodic(const Duration(milliseconds: 180), (_) {
      final j = jsonDecode(_progress().toDart) as Map<String, dynamic>;
      update(
        ImportProgress(
          (j['done'] as num).toInt(),
          (j['total'] as num).toInt(),
          j['name'] as String,
        ),
      );
    });
    try {
      return ImportReport.fromJson(
        jsonDecode((await pending.toDart).toDart) as Map<String, dynamic>,
      );
    } finally {
      timer.cancel();
    }
  }

  @override
  Future<ImportReport> importAudio({
    required bool folder,
    required void Function(ImportProgress) onProgress,
  }) => _operation(_import(folder.toJS), onProgress);
  @override
  Future<ImportReport> rescan({
    String? sourceId,
    required void Function(ImportProgress) onProgress,
  }) => _operation(_rescan((sourceId ?? 'all').toJS), onProgress);
  @override
  Future<ImportReport> relink(
    String id, {
    required void Function(ImportProgress) onProgress,
  }) => _operation(_relink(id.toJS), onProgress);
  @override
  Future<ImportReport> migrateLegacy({
    required void Function(ImportProgress) onProgress,
  }) => _operation(_migrate(), onProgress);
  @override
  Future<void> cancelImport() async {
    await _cancel().toDart;
  }

  @override
  Future<void> forgetSource(String id) async {
    await _forgetSource(id.toJS).toDart;
  }

  @override
  Future<void> setLiked(String id, bool value) async {
    await _like(id.toJS, value.toJS).toDart;
  }

  @override
  Future<void> remove(String id) async {
    await _remove(id.toJS).toDart;
  }

  @override
  Future<String> playableUri(String id) async =>
      (await _uri(id.toJS).toDart).toDart;
}
