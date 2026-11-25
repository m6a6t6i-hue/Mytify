import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytify/design.dart';

void main() {
  testWidgets('Playback animation stops on pause and resumes on play', (
    tester,
  ) async {
    var frames = 0;
    Widget app(bool active) => MaterialApp(
      home: PlaybackMotion(
        active: active,
        builder: (_, value) {
          frames++;
          return Text('$value');
        },
      ),
    );
    await tester.pumpWidget(app(true));
    await tester.pump(const Duration(milliseconds: 120));
    final moving = frames;
    await tester.pump(const Duration(milliseconds: 120));
    expect(frames, greaterThan(moving));
    await tester.pumpWidget(app(false));
    final paused = frames;
    await tester.pump(const Duration(seconds: 1));
    expect(frames, paused);
    await tester.pumpWidget(app(true));
    await tester.pump(const Duration(milliseconds: 120));
    expect(frames, greaterThan(paused));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Reduced motion keeps playback decoration static', (
    tester,
  ) async {
    var frames = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: PlaybackMotion(
            active: true,
            builder: (_, value) {
              frames++;
              return Text('$value');
            },
          ),
        ),
      ),
    );
    final initial = frames;
    await tester.pump(const Duration(seconds: 2));
    expect(frames, initial);
    expect(find.text('0.0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Background playback keeps audio UI animation asleep', (
    tester,
  ) async {
    var frames = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PlaybackMotion(
          active: true,
          builder: (_, value) {
            frames++;
            return Text('$value');
          },
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final paused = frames;
    await tester.pump(const Duration(seconds: 2));
    expect(frames, paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 120));
    expect(frames, greaterThan(paused));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Animated play control works from keyboard and has an action', (
    tester,
  ) async {
    var plays = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: PlayButton(playing: false, onPressed: () => plays++),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(plays, 1);
    expect(
      tester.getSemantics(find.byType(PlayButton)),
      matchesSemantics(
        label: 'Odtwórz',
        isButton: true,
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
