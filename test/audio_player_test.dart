import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytify/model.dart';
import 'package:mytify/audio_player.dart';

class AudioRepo implements LibraryRepository {
  Future<AudioSnapshot> Function() read = () =>
      Future.value(const AudioSnapshot());
  Future<AudioSnapshot> Function(Map<String, dynamic>) act = (_) =>
      Future.value(const AudioSnapshot());
  final calls = <Map<String, dynamic>>[];
  @override
  Future<AudioSnapshot> audioState() => read();
  @override
  Future<AudioSnapshot> audioCommand(Map<String, dynamic> action) {
    calls.add(action);
    return act(action);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test(
    'spóźniony odczyt stanu nie cofa nowszego polecenia odtwarzania',
    () async {
      final repo = AudioRepo();
      final stale = Completer<AudioSnapshot>(), started = Completer<void>();
      var reads = 0;
      repo.read = () {
        reads++;
        if (reads == 1) {
          return Future.value(const AudioSnapshot());
        }
        if (!started.isCompleted) {
          started.complete();
        }
        return stale.future;
      };
      repo.act = (_) => Future.value(
        const AudioSnapshot(queueIds: ['new'], currentId: 'new', playing: true),
      );
      final player = NativeAudioPlayer(repo);
      await player.start();
      await started.future.timeout(const Duration(seconds: 2));
      await player.openQueue(['new'], 0);
      stale.complete(const AudioSnapshot(queueIds: ['old'], currentId: 'old'));
      await Future<void>.delayed(Duration.zero);
      expect(player.state.currentId, 'new');
      await player.dispose();
    },
  );
  test(
    'polecenia są szeregowane i błąd jednego nie blokuje kolejnego',
    () async {
      final repo = AudioRepo();
      final pending = Completer<AudioSnapshot>();
      var commands = 0;
      repo.act = (_) {
        commands++;
        return commands == 1
            ? pending.future
            : Future.value(const AudioSnapshot(playing: true));
      };
      final player = NativeAudioPlayer(repo);
      final first = player.command({'action': 'pause'});
      final expectation = expectLater(first, throwsStateError);
      final next = player.play();
      await Future<void>.delayed(Duration.zero);
      expect(repo.calls.length, 1);
      pending.completeError(StateError('test failure'));
      await expectation;
      await next;
      expect(repo.calls.length, 2);
      expect(player.state.playing, isTrue);
      await player.dispose();
    },
  );
  test('końcowa głośność zastępuje opóźnione wartości suwaka', () async {
    final repo = AudioRepo();
    final player = NativeAudioPlayer(repo);
    await player.setVolume(10);
    await player.setVolume(20);
    await player.commitVolume(30);
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(repo.calls, [
      {'action': 'volume', 'value': 30.0},
    ]);
    await player.dispose();
  });
}
