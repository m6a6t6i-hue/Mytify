import 'dart:async';

import 'model.dart';

class AudioStreams {
  final Stream<bool> playing;
  final Stream<Duration> position;
  final Stream<String> error;
  final Stream<AudioSnapshot> snapshot;
  const AudioStreams(this.playing, this.position, this.error, this.snapshot);
}

/// Controls the one Rust-owned player. This client never decodes or plays audio.
class NativeAudioPlayer {
  final LibraryRepository repository;
  final _playing = StreamController<bool>.broadcast(),
      _position = StreamController<Duration>.broadcast(),
      _error = StreamController<String>.broadcast(),
      _snapshot = StreamController<AudioSnapshot>.broadcast();
  late final AudioStreams stream = AudioStreams(
    _playing.stream,
    _position.stream,
    _error.stream,
    _snapshot.stream,
  );
  AudioSnapshot state = const AudioSnapshot();
  Timer? _timer, _volumeTimer;
  bool _polling = false, _disposed = false, _connectionFailed = false;
  int _generation = 0, _lastError = 0;
  Future<void> _commands = Future<void>.value();
  NativeAudioPlayer(this.repository);
  Future<void> start() async {
    await _poll();
    if (!_disposed) {
      _timer = Timer.periodic(
        const Duration(milliseconds: 150),
        (_) => unawaited(_poll()),
      );
    }
  }

  void _accept(AudioSnapshot next) {
    if (_disposed) {
      return;
    }
    final previous = state;
    state = next;
    if (next.playing != previous.playing) {
      _playing.add(next.playing);
    }
    if (next.position != previous.position ||
        next.duration != previous.duration ||
        next.currentId != previous.currentId) {
      _position.add(next.position);
    }
    if (next.error != null && next.errorSerial > _lastError) {
      _error.add(next.error!);
    }
    _lastError = next.errorSerial;
    _snapshot.add(next);
  }

  Future<void> _poll() async {
    if (_polling || _disposed) {
      return;
    }
    _polling = true;
    final generation = _generation;
    try {
      final next = await repository.audioState();
      _connectionFailed = false;
      if (generation == _generation) {
        _accept(next);
      }
    } catch (e) {
      if (!_disposed && !_connectionFailed) {
        _connectionFailed = true;
        _error.add('Brak połączenia z odtwarzaczem: $e');
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> command(Map<String, dynamic> action) {
    final completer = Completer<void>();
    _commands = _commands.then((_) async {
      if (_disposed) {
        completer.complete();
        return;
      }
      _generation++;
      try {
        _accept(await repository.audioCommand(action));
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> openQueue(List<String> ids, int index) =>
      command({'action': 'load', 'ids': ids, 'index': index});
  Future<void> play() => command({'action': 'play'});
  Future<void> playOrPause() =>
      command({'action': state.playing ? 'pause' : 'play'});
  Future<void> stop() => command({'action': 'stop'});
  Future<void> next() => command({'action': 'next'});
  Future<void> previous() => command({'action': 'previous'});
  Future<void> seek(Duration position) =>
      command({'action': 'seek', 'positionMs': position.inMilliseconds});
  Future<void> repeat(bool value) =>
      command({'action': 'repeat', 'value': value});
  Future<void> shuffle(bool value) =>
      command({'action': 'shuffle', 'value': value});
  Future<void> jump(String id) => command({'action': 'jump', 'id': id});
  Future<void> selectDevice(String id) =>
      command({'action': 'device', 'id': id});
  Future<List<AudioDevice>> devices() => repository.audioDevices();

  /// Rebuilds the queue in the given order without losing the current position.
  Future<void> rearrange(List<String> ids, String currentId) async {
    final index = ids.indexOf(currentId);
    if (index < 0) throw ArgumentError('Brak bieżącego utworu w kolejce.');
    final position = state.position.inMilliseconds;
    final wasPlaying = state.playing;
    if (repository.queueRestore) {
      return command({
        'action': 'restore',
        'ids': ids,
        'index': index,
        'positionMs': position,
        'playing': wasPlaying,
      });
    }
    await command({'action': 'load', 'ids': ids, 'index': index});
    if (position > 0) await seek(Duration(milliseconds: position));
    if (!wasPlaying) await command({'action': 'pause'});
  }
  Future<void> setVolume(double value) async {
    _volumeTimer?.cancel();
    _volumeTimer = Timer(
      const Duration(milliseconds: 35),
      () => unawaited(
        command({'action': 'volume', 'value': value}).catchError((Object e) {
          if (!_disposed) {
            _error.add('$e');
          }
        }),
      ),
    );
  }

  Future<void> commitVolume(double value) {
    _volumeTimer?.cancel();
    return command({'action': 'volume', 'value': value});
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _volumeTimer?.cancel();
    await Future.wait([
      _playing.close(),
      _position.close(),
      _error.close(),
      _snapshot.close(),
    ]);
  }
}
