import 'playlists.dart';
import 'transfer.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';
import 'ingest.dart';
import 'repository_android.dart';

LibraryRepository createRepository() =>
    Platform.isAndroid ? AndroidLibraryRepository() : NativeLibraryRepository();

class NativeLibraryRepository extends LibraryRepository
    implements IngestRepository, PlaylistRepository, TransferRepository {
  @override
  bool get receivesTransfers => false;
  @override
  Future<dynamic> transfer(Map<String, dynamic> request) async =>
      _api('/api/transfer', method: 'POST', body: request);
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
  Future<dynamic> ingest(Map<String, dynamic> request) => _api(
    request['action'] == 'disc' ? '/api/metadata/disc' : '/api/ingest',
    method: 'POST',
    body: request,
  );

  final HttpClient _client = HttpClient();
  final String? executablePath, dataDirectory;
  Process? _process;
  Uri? _base;
  String? _token;
  Future<void>? _ready;
  String? _job;
  bool _disposed = false;
  NativeLibraryRepository({this.executablePath, this.dataDirectory});
  @override
  Future<List<ReleaseCandidate>> findReleases(
    String album,
    String artist,
  ) async =>
      ((await _api(
            '/api/metadata/search?album=${Uri.encodeComponent(album)}&artist=${Uri.encodeComponent(artist)}',
          )) as List)
          .map(
            (v) =>
                ReleaseCandidate.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
  @override
  Future<ReleaseInfo> releaseDetails(String id) async => ReleaseInfo.fromJson(
    Map<String, dynamic>.from(
      await _api('/api/metadata/release/${Uri.encodeComponent(id)}') as Map,
    ),
  );
  @override
  Future<CoverChoice?> downloadCover(String id) async => CoverChoice.fromJson(
    Map<String, dynamic>.from(
      await _api('/api/metadata/cover/${Uri.encodeComponent(id)}') as Map,
    ),
  );
  @override
  Future<CoverChoice?> chooseCover() async =>
      throw StateError('Własne okładki są dostępne w Mytify.exe z paczki 0.4.');
  @override
  Future<void> editMetadata(List<MetadataEdit> edits) async {
    await _api(
      '/api/metadata/edits',
      method: 'POST',
      body: edits.map((e) => e.toJson()).toList(),
    );
  }

  @override
  Future<void> resetMetadata(List<String> ids) async {
    await _api('/api/metadata/reset', method: 'POST', body: ids);
  }

  @override
  Future<AudioSnapshot> audioState() async => AudioSnapshot.fromJson(
    Map<String, dynamic>.from(await _api('/api/player/state') as Map),
  );
  @override
  Future<AudioSnapshot> audioCommand(Map<String, dynamic> action) async =>
      AudioSnapshot.fromJson(
        Map<String, dynamic>.from(
          await _api('/api/player/command', method: 'POST', body: action)
              as Map,
        ),
      );
  @override
  Future<List<AudioDevice>> audioDevices() async =>
      ((await _api('/api/player/devices')) as List)
          .map((v) => AudioDevice.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();
  @override
  String get storageDescription =>
      'Mytify zapamięta lokalizacje muzyki na dysku. Nie kopiuje ani nie zmienia Twoich plików. Katalog i polubienia zapisuje na tym komputerze.';
  Future<void> _ensure() => _ready ??= _start();
  Future<void> _start() async {
    final parent = p.dirname(Platform.resolvedExecutable);
    final choices = [
      ?executablePath,
      p.join(parent, 'mytify_backend.exe'),
      p.join(
        Directory.current.path,
        'native',
        'mytify_core',
        'target',
        'release',
        Platform.isWindows ? 'mytify.exe' : 'mytify',
      ),
    ];
    final executable = choices
        .where((file) => File(file).existsSync())
        .firstOrNull;
    if (executable == null) {
      throw StateError(
        'Brakuje mytify_backend.exe. Zbuduj rdzeń Rust lub uruchom Mytify.exe z paczki 0.4.',
      );
    }
    _process = await Process.start(executable, [
      '--headless',
      '--port',
      '0',
      if (dataDirectory != null) ...['--data-dir', dataDirectory!],
    ]);
    unawaited(_process!.stderr.drain<void>());
    final line = await _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 20));
    final config = jsonDecode(line) as Map<String, dynamic>;
    final uri = Uri.parse(config['base'] as String);
    if (uri.scheme != 'http' || uri.host != '127.0.0.1') {
      throw StateError('Nieprawidłowy adres lokalnego katalogu.');
    }
    _base = uri;
    _token = config['token'] as String;
    if (_disposed) {
      _process?.kill();
      throw StateError('Mytify jest zamknięte.');
    }
  }

  Future<dynamic> _api(
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    await _ensure();
    final request = await _client.openUrl(method, _base!.resolve(path));
    request.followRedirects = false;
    request.headers.set('X-Mytify-Token', _token!);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final value = jsonDecode(await utf8.decoder.bind(response).join());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError((value as Map)['error']?.toString() ?? 'Błąd katalogu.');
    }
    return value;
  }

  @override
  Future<List<Track>> load() async => ((await _api('/api/library')) as List)
      .map((j) => Track.fromJson(Map<String, dynamic>.from(j as Map)))
      .toList();
  @override
  Future<List<LibrarySource>> sources() async =>
      ((await _api('/api/sources')) as List)
          .map(
            (j) => LibrarySource.fromJson(Map<String, dynamic>.from(j as Map)),
          )
          .toList();
  @override
  Future<List<String>> searchIds(String query) async =>
      ((await _api('/api/search?q=${Uri.encodeComponent(query)}')) as List)
          .cast<String>();
  Future<ImportReport> _scan(
    Map<String, dynamic> args,
    void Function(ImportProgress) update,
  ) async {
    final started = await _api('/api/scan', method: 'POST', body: args) as Map;
    _job = started['job'] as String;
    try {
      while (true) {
        final state = await _api('/api/jobs/$_job') as Map;
        final progress = state['progress'] as Map;
        update(
          ImportProgress(
            (progress['done'] as num).toInt(),
            (progress['total'] as num).toInt(),
            progress['name'] as String,
          ),
        );
        if (state['finished'] == true) {
          if (state['error'] != null) {
            throw StateError(state['error'].toString());
          }
          return ImportReport.fromJson(
            Map<String, dynamic>.from(state['result'] as Map),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 160));
      }
    } finally {
      _job = null;
    }
  }

  @override
  Future<ImportReport> importAudio({
    required bool folder,
    required void Function(ImportProgress) onProgress,
  }) async {
    final selected = await _api(
      '/api/pick',
      method: 'POST',
      body: {'folder': folder},
    ) as Map;
    final paths = selected['paths'] as List;
    if (paths.isEmpty) return const ImportReport(cancelled: true);
    return _scan({'paths': paths, 'folder': folder}, onProgress);
  }

  @override
  Future<ImportReport> rescan({
    String? sourceId,
    required void Function(ImportProgress) onProgress,
  }) => _scan({'sourceId': sourceId ?? 'all'}, onProgress);
  @override
  Future<ImportReport> relink(
    String id, {
    required void Function(ImportProgress) onProgress,
  }) async {
    final selected =
        await _api('/api/pick', method: 'POST', body: {'folder': true}) as Map;
    final paths = selected['paths'] as List;
    if (paths.isEmpty) return const ImportReport(cancelled: true);
    await _api(
      '/api/relink',
      method: 'POST',
      body: {'id': id, 'path': paths.first},
    );
    return _scan({'sourceId': id}, onProgress);
  }

  @override
  Future<void> forgetSource(String id) async {
    await _api('/api/sources/${Uri.encodeComponent(id)}', method: 'DELETE');
  }

  @override
  Future<void> setLiked(String id, bool liked) async {
    await _api(
      '/api/like/${Uri.encodeComponent(id)}',
      method: 'POST',
      body: {'liked': liked},
    );
  }

  @override
  Future<void> remove(String id) async {
    await _api('/api/tracks/${Uri.encodeComponent(id)}', method: 'DELETE');
  }

  @override
  Future<String> playableUri(String id) async {
    await _ensure();
    return '${_base!}/api/audio/${Uri.encodeComponent(id)}?token=$_token';
  }

  @override
  Future<void> cancelImport() async {
    if (_job != null) await _api('/api/jobs/$_job', method: 'DELETE');
  }

  @override
  Future<ImportReport> migrateLegacy({
    required void Function(ImportProgress) onProgress,
  }) => Future.error(
    StateError(
      'Aby przenieść bibliotekę przeglądarkową 0.1, uruchom MIGRACJA_0.1.cmd.',
    ),
  );
  @override
  Future<void> dispose() async {
    _disposed = true;
    _client.close(force: true);
    _process?.kill();
  }
}
