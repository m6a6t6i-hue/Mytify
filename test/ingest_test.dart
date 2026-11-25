import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mytify/ingest.dart';
import 'package:mytify/main.dart';
import 'package:mytify/model.dart';

class IngestFake implements LibraryRepository, IngestRepository {
  final calls = <Map<String, dynamic>>[];
  List<dynamic> drives = [
    {'id': 'D:', 'name': 'ASUS SDRW-08U9M-U'},
  ];
  List<dynamic> inputs = [];
  Object? tocError;
  Map<String, dynamic> state = {'running': false, 'stage': '', 'files': <String>[]};

  @override
  Future<dynamic> ingest(Map<String, dynamic> request) async {
    calls.add(request);
    switch (request['action']) {
      case 'drives':
        return drives;
      case 'inputs':
        return inputs;
      case 'sessions':
        return [];
      case 'folders':
        return {'recordings': r'C:\dane\recordings', 'cd': r'C:\dane\cd-imports'};
      case 'state':
        return state;
      case 'toc':
        if (tocError != null) throw tocError!;
        return {
          'discId': 'known-disc',
          'tracks': [
            {'number': 1, 'start': 0, 'end': 75 * 200},
            {'number': 2, 'start': 75 * 200, 'end': 75 * 400},
          ],
        };
      case 'rip':
      case 'monitor':
        state = {
          'running': true,
          'stage': request['action'] == 'rip' ? 'ripping' : 'monitor',
          'total': 150,
          'done': 0,
          'files': <String>[],
          'channels': 1,
          'peaks': [0.5],
          'clips': 3,
        };
        return state;
      case 'stop':
        state = {'running': false, 'stage': 'cancelled', 'files': <String>[]};
        return state;
    }
    return {};
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late IngestFake repo;
  late IngestState state;

  Future<void> open(WidgetTester t, {double width = 1300, int tab = 0}) async {
    t.view.physicalSize = Size(width, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    state = IngestState(
      repository: repo,
      library: repo,
      beforeCapture: () async {},
      onLibraryChanged: () async {},
    )..tab = tab;
    await t.pumpWidget(MaterialApp(theme: mytifyTheme(), home: Scaffold(body: IngestView(state: state))));
    await t.pumpAndSettle();
  }

  Future<void> close(WidgetTester t) async {
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    state.dispose();
  }

  setUp(() => repo = IngestFake());

  testWidgets('opening import only lists hardware, it starts nothing', (t) async {
    await open(t);
    final actions = repo.calls.map((c) => c['action']).toSet();
    expect(actions.difference({'drives', 'inputs', 'sessions', 'state', 'folders'}), isEmpty);
    expect(find.text('Gotowe'), findsNothing);
    await close(t);
  });

  testWidgets('no drive: one message and one refresh, nothing disabled on show', (t) async {
    repo.drives = [];
    await open(t);
    expect(find.text('Nie wykryto napędu'), findsOneWidget);
    expect(find.text('Podłącz napęd USB i odśwież listę.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Odśwież'), findsOneWidget);
    expect(find.text('Odczytaj'), findsNothing);
    expect(find.text('Odczytaj płytę'), findsNothing);
    final before = repo.calls.where((c) => c['action'] == 'drives').length;
    await t.tap(find.widgetWithText(FilledButton, 'Odśwież'));
    await t.pumpAndSettle();
    expect(repo.calls.where((c) => c['action'] == 'drives').length, before + 1);
    await close(t);
  });

  testWidgets('empty tray and data discs are told apart', (t) async {
    repo.tocError = Exception('Brak płyty w napędzie.');
    await open(t);
    expect(find.text('ASUS SDRW-08U9M-U (D:)'), findsOneWidget);
    await t.tap(find.text('Odczytaj'));
    await t.pumpAndSettle();
    expect(state.cd, CdState.noDisc);
    expect(find.textContaining('Włóż płytę Audio CD'), findsOneWidget);
    repo.tocError = Exception('Płyta zawiera ścieżki z danymi (CD-Extra, CD-ROM lub DVD).');
    await t.tap(find.text('Odczytaj'));
    await t.pumpAndSettle();
    expect(state.cd, CdState.unsupported);
    await close(t);
  });

  testWidgets('CD: real tracks, selection, titles and stop keep their meaning', (t) async {
    await open(t);
    await t.tap(find.text('Odczytaj'));
    await t.pumpAndSettle();
    expect(state.cd, CdState.ready);
    expect(find.text('3:20'), findsNWidgets(2));
    await t.enterText(find.byType(TextField).at(0), 'Mój album');
    await t.enterText(find.byType(TextField).at(1), 'Wykonawca');
    await t.enterText(find.byType(TextField).at(2), 'Pierwszy');
    // Untick the second track.
    await t.tap(find.byType(Checkbox).at(2));
    await t.pumpAndSettle();
    // Switching tabs keeps the read disc and the form.
    await t.tap(find.text('Winyl i kaseta'));
    await t.pumpAndSettle();
    await t.tap(find.text('Audio CD'));
    await t.pumpAndSettle();
    expect(find.text('Mój album'), findsOneWidget);
    await t.tap(find.text('Importuj zaznaczone (1)'));
    await t.pump();
    await t.pump();
    final rip = repo.calls.firstWhere((c) => c['action'] == 'rip');
    expect(rip['discId'], 'known-disc');
    expect(rip['album'], 'Mój album');
    expect(rip['titles'], ['Pierwszy', 'Utwór 2']);
    expect(rip['tracks'], [1]);
    expect(state.cd, CdState.importing);
    await t.tap(find.text('Zatrzymaj i zachowaj gotowe pliki'));
    await t.pumpAndSettle();
    expect(repo.calls.any((c) => c['action'] == 'stop'), isTrue);
    expect(state.cd, CdState.done);
    expect(find.text('Import zatrzymany, nic nie zapisano'), findsOneWidget);
    await close(t);
  });

  testWidgets('vinyl without input offers no recording and shows the meter off', (t) async {
    await open(t, tab: 1);
    expect(find.textContaining('Nie wykryto wejścia audio'), findsOneWidget);
    final record = t.widget<ButtonStyleButton>(find.ancestor(of: find.text('Nagraj'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
    expect(record.onPressed, isNull);
    expect(find.text('Podgląd wyłączony'), findsOneWidget);
    expect(find.text('Dostępne po nagraniu'), findsOneWidget);
    expect(repo.calls.any((c) => c['action'] == 'record' || c['action'] == 'monitor'), isFalse);
    await close(t);
  });

  for (final width in [1300.0, 700.0]) {
    testWidgets('level check shows only real channels and clipping, width $width', (t) async {
      repo.inputs = [
        {'id': 'in', 'name': 'USB Audio CODEC', 'rates': [44100, 48000], 'channels': 1},
      ];
      await open(t, width: width, tab: 1);
      await t.tap(find.text('Sprawdź poziom'));
      await t.pump();
      await t.pump();
      expect(repo.calls.firstWhere((c) => c['action'] == 'monitor')['rate'], 48000);
      expect(find.text('M'), findsOneWidget);
      expect(find.text('L'), findsNothing);
      expect(find.textContaining('Przesterowanie'), findsOneWidget);
      expect(find.text('Podgląd wyłączony'), findsNothing);
      await t.tap(find.text('Zakończ podgląd'));
      await t.pumpAndSettle();
      await close(t);
    });
  }
}
