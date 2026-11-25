import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mytify/audio_player.dart';
import 'package:mytify/audio_settings.dart';
import 'package:mytify/model.dart';

class ReceiverRepo implements LibraryRepository {
  AudioSnapshot current = const AudioSnapshot(
    selectedDevice: 'dlna:fake',
    volumeAvailable: false,
    output: {
      'name': 'Yamaha',
      'backend': 'DLNA',
      'sampleRate': 0,
      'sampleFormat': 'FLAC',
      'channels': 2,
    },
  );
  final actions = <Map<String, dynamic>>[];
  @override
  Future<AudioSnapshot> audioState() async => current;
  @override
  Future<AudioSnapshot> audioCommand(Map<String, dynamic> action) async {
    actions.add(action);
    return current;
  }

  @override
  Future<List<AudioDevice>> audioDevices() async => [
    const AudioDevice('auto', 'Komputer'),
    const AudioDevice('dlna:fake', 'Yamaha'),
  ];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets(
    'receiver volume stays disabled until actually read, with no volume command on connect',
    (t) async {
      t.view.physicalSize = const Size(1000, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final repo = ReceiverRepo();
      final player = NativeAudioPlayer(repo);
      await player.start();
      await t.pumpWidget(MaterialApp(home: AudioSettings(player: player)));
      await t.pumpAndSettle();
      expect(t.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      expect(repo.actions, isEmpty);
      repo.current = const AudioSnapshot(
        selectedDevice: 'dlna:fake',
        volumeAvailable: true,
        volume: 33,
        output: {
          'name': 'Yamaha',
          'backend': 'DLNA',
          'sampleRate': 0,
          'sampleFormat': 'FLAC',
          'channels': 2,
        },
      );
      await t.pump(const Duration(milliseconds: 200));
      await t.pump();
      expect(t.widget<Slider>(find.byType(Slider)).value, 33);
      expect(t.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
      expect(repo.actions, isEmpty);
      await t.pumpWidget(const SizedBox());
      await player.dispose();
    },
  );
}
