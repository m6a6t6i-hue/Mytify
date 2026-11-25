import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mytify/model.dart';
import 'package:mytify/ingest.dart';

class IngestFake implements LibraryRepository, IngestRepository {
  final calls = <Map<String, dynamic>>[];
  bool running = false;
  @override
  Future<dynamic> ingest(Map<String, dynamic> request) async {
    calls.add(request);
    switch (request['action']) {
      case 'drives':
        return ['D:'];
      case 'inputs':
        return [];
      case 'sessions':
        return [];
      case 'state':
        return {
          'running': running,
          'stage': running ? 'ripping' : 'finished',
          'files': <String>[],
          'total': 150,
          'done': 0,
        };
      case 'toc':
        return {
          'discId': 'known-disc',
          'tracks': [
            {'number': 1},
            {'number': 2},
          ],
        };
      case 'rip':
        running = true;
        return {};
      case 'stop':
        running = false;
        return {};
    }
    return {};
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets(
    'CD wizard sends inspected disc and edited titles, and can cancel',
    (t) async {
      t.view.physicalSize = const Size(1200, 2200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final repo = IngestFake();
      await t.pumpWidget(
        MaterialApp(
          home: IngestScreen(library: repo, repository: repo, cd: true),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Odczytaj płytę'));
      await t.pumpAndSettle();
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), 'Mój album');
      await t.enterText(fields.at(1), 'Wykonawca');
      await t.enterText(fields.at(2), 'Pierwszy');
      await t.tap(find.text('Importuj jako FLAC'));
      await t.pumpAndSettle();
      final rip = repo.calls.firstWhere((c) => c['action'] == 'rip');
      expect(rip['discId'], 'known-disc');
      expect(rip['album'], 'Mój album');
      expect(rip['titles'], ['Pierwszy', 'Utwór 2']);
      await t.tap(find.text('Zatrzymaj — zachowaj ukończone pliki'));
      await t.pumpAndSettle();
      expect(repo.running, isFalse);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('no audio input does not offer fake recording', (t) async {
    final repo = IngestFake();
    await t.pumpWidget(
      MaterialApp(
        home: IngestScreen(library: repo, repository: repo),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.textContaining('Nie wykryto obsługiwanego wejścia'),
      findsOneWidget,
    );
    final button = t.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Rozpocznij nagranie'),
    );
    expect(button.onPressed, isNull);
    expect(repo.calls.any((c) => c['action'] == 'record'), isFalse);
    await t.pumpWidget(const SizedBox());
  });
}
