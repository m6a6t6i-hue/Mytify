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
  List<dynamic> discReleases = [];
  Map<String, dynamic>? cdText;
  List<dynamic> sessions = [];
  bool media = false;
  ReleaseInfo? details;
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
        return sessions;
      case 'disc':
        return discReleases;
      case 'media':
        return [
          for (final d in drives) {'id': (d as Map)['id'], 'media': media},
        ];
      case 'waveform':
        return {'rate': 1000, 'frames': 180000, 'perPoint': 60, 'peaks': [for (var i = 0; i < 6000; i++) i.isEven ? -.4 : .4]};
      case 'align':
        return [61000];
      case 'analyze':
        return [59000, 121000];
      case 'export':
        state = {'running': true, 'stage': 'exporting', 'total': 2, 'done': 0, 'files': <String>[]};
        return state;
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
          'cdText': ?cdText,
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
  Future<ReleaseInfo> releaseDetails(String id) async => details!;
  @override
  Future<ReleaseInfo> discogsRelease(String id) async => details!;
  @override
  Future<CoverChoice?> downloadCover(String id) async => null;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

ReleaseCandidate release(String id, String title, {String artist = 'Różni wykonawcy'}) => ReleaseCandidate(
  id: id,
  title: title,
  artist: artist,
  date: '1999',
  country: 'PL',
  format: 'CD',
  label: 'Pomaton',
  barcode: '',
  disambiguation: '',
  trackCount: 2,
  score: 100,
);

Map<String, dynamic> releaseJson(String id, String title) => {
  'id': id,
  'title': title,
  'artist': 'Różni wykonawcy',
  'date': '1999',
  'country': 'PL',
  'format': 'CD',
  'label': 'Pomaton',
  'barcode': '',
  'disambiguation': '',
  'trackCount': 2,
  'score': 100,
};

void main() {
  late IngestFake repo;
  late IngestState state;

  Future<void> open(WidgetTester t, {double width = 1300, double height = 1600, int tab = 0}) async {
    t.view.physicalSize = Size(width, height);
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
    expect(actions.difference({'drives', 'inputs', 'apps', 'sessions', 'state', 'folders'}), isEmpty);
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
    // Untick the second track (after "Różni wykonawcy" and "select all").
    await t.tap(find.byType(Checkbox).at(3));
    await t.pumpAndSettle();
    // Switching tabs keeps the read disc and the form.
    await t.tap(find.text('Winyl / kaseta / aplikacja'));
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
    expect(rip['eject'], isFalse);
    expect(rip['mp3'], isFalse);
    expect(rip['offset'], isNull);
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

  testWidgets('CD: one MusicBrainz release fills the form, compilation artists go per track', (t) async {
    repo.discReleases = [releaseJson('mb-1', 'Składanka')];
    repo.details = ReleaseInfo(release('mb-1', 'Składanka'), const [
      ReleaseSong(title: 'Pierwszy', artist: 'Anna', discNumber: 1, trackNumber: 1, durationMs: 200000),
      ReleaseSong(title: 'Drugi', artist: 'Bartek', discNumber: 1, trackNumber: 2, durationMs: 200500),
    ]);
    await open(t);
    await t.tap(find.text('Odczytaj'));
    await t.pumpAndSettle();
    expect(find.text('Składanka'), findsOneWidget);
    expect(find.textContaining('Opis z MusicBrainz'), findsOneWidget);
    expect(state.cdForm.various, isTrue);
    expect(find.text('Anna'), findsOneWidget);
    await t.tap(find.text('Kopia MP3 192 kb/s na telefon'));
    await t.pump();
    await t.tap(find.text('Importuj'));
    await t.pump();
    await t.pump();
    final rip = repo.calls.firstWhere((c) => c['action'] == 'rip');
    expect(rip['releaseId'], 'mb-1');
    expect(rip['artists'], ['Anna', 'Bartek']);
    expect(rip['mp3'], isTrue);
    // Finished import with verification per track.
    repo.state = {
      'running': false,
      'stage': 'finished',
      'files': ['a.flac', 'b.flac'],
      'offset': 6,
      'offsetSource': 'zapamiętane dla napędu',
      'discCheck': {'accuraterip': 2, 'ctdb': 1},
      'verdicts': [
        {'track': 1, 'accuraterip': 12, 'accurateripBest': 12, 'ctdb': 4, 'crc': 'abcd', 'v1': '1', 'v2': '2', 'retriedSectors': 0},
        {'track': 2, 'accuraterip': 0, 'accurateripBest': 9, 'ctdb': 0, 'crc': 'ef01', 'v1': '3', 'v2': '4', 'retriedSectors': 2},
      ],
      'folder': r'C:\dane\cd-imports\Składanka',
    };
    await state.poll();
    await t.pumpAndSettle();
    expect(state.cd, CdState.done);
    expect(find.textContaining('Niezgodne z bazą: 1'), findsOneWidget);
    expect(find.textContaining('+6 próbek'), findsOneWidget);
    expect(find.text('Otwórz folder z raportem'), findsOneWidget);
    await close(t);
  });

  testWidgets('CD: several releases are offered, none falls back to CD-Text', (t) async {
    repo.discReleases = [releaseJson('a', 'Wydanie A'), releaseJson('b', 'Wydanie B')];
    await open(t);
    await t.tap(find.text('Odczytaj'));
    await t.pumpAndSettle();
    expect(find.textContaining('kilka wydań'), findsOneWidget);
    expect(find.text('Wybierz'), findsNWidgets(2));
    repo.discReleases = [];
    repo.cdText = {'album': 'Z płyty', 'artist': 'Zespół', 'titles': ['Raz', 'Dwa'], 'artists': ['', '']};
    await t.tap(find.text('Odczytaj ponownie'));
    await t.pumpAndSettle();
    expect(find.textContaining('CD-Text'), findsOneWidget);
    expect(find.text('Z płyty'), findsOneWidget);
    expect(find.text('Dwa'), findsOneWidget);
    await close(t);
  });

  testWidgets('serial mode: an inserted disc with one release imports by itself', (t) async {
    repo.discReleases = [releaseJson('mb-1', 'Album')];
    repo.details = ReleaseInfo(release('mb-1', 'Album', artist: 'Zespół'), const [
      ReleaseSong(title: 'Raz', artist: 'Zespół', discNumber: 1, trackNumber: 1, durationMs: 200000),
      ReleaseSong(title: 'Dwa', artist: 'Zespół', discNumber: 1, trackNumber: 2, durationMs: 200000),
    ]);
    await open(t);
    state.serial = true;
    state.watchDiscs();
    await t.pump(const Duration(seconds: 3));
    await t.pump();
    expect(repo.calls.any((c) => c['action'] == 'toc'), isFalse);
    repo.media = true;
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
    final rip = repo.calls.firstWhere((c) => c['action'] == 'rip');
    expect(rip['eject'], isTrue);
    expect(rip['titles'], ['Raz', 'Dwa']);
    await t.tap(find.text('Zatrzymaj i zachowaj gotowe pliki'));
    await t.pumpAndSettle();
    await close(t);
  });

  testWidgets('vinyl: waveform markers, Discogs side A, restoration only on export', (t) async {
    repo.inputs = [
      {'id': 'in', 'name': 'USB Audio CODEC', 'rates': [48000], 'channels': 2},
    ];
    repo.sessions = [
      {'id': 's1', 'label': 'Winyl, strona A', 'durationMs': 180000, 'markers': <int>[]},
    ];
    repo.details = ReleaseInfo(release('discogs:1', 'Płyta', artist: 'Zespół'), const [
      ReleaseSong(title: 'A jeden', artist: 'Zespół', discNumber: 1, trackNumber: 1, durationMs: 60000, number: 'A1'),
      ReleaseSong(title: 'A dwa', artist: 'Zespół', discNumber: 1, trackNumber: 2, durationMs: 120000, number: 'A2'),
      ReleaseSong(title: 'B jeden', artist: 'Zespół', discNumber: 1, trackNumber: 3, durationMs: 100000, number: 'B1'),
    ]);
    await open(t, tab: 1, height: 3200);
    await state.selectSession('s1');
    await t.pumpAndSettle();
    await t.tap(find.text('Podział i eksport'));
    await t.pumpAndSettle();
    expect(find.byType(WaveformEditor), findsOneWidget);
    // Cursor and preview listen to the real recording.
    state.setCursor(30000);
    await t.pump();
    await t.tap(find.text('Odsłuchaj'));
    await t.pump();
    expect(repo.calls.lastWhere((c) => c['action'] == 'preview')['positionMs'], 30000);
    await t.tap(find.text('Zaproponuj według ciszy'));
    await t.pumpAndSettle();
    expect(state.markers, [59000, 121000]);
    expect(state.vinylForm.tracks.length, 3);
    state.moveMarker(0, 200000);
    expect(state.markers.first, lessThan(121000));
    state.removeMarker(1);
    expect(state.markers.length, 1);
    // Tracklist from Discogs: only side A is picked, markers are aligned in the engine.
    await t.enterText(find.widgetWithText(TextField, 'albo adres wydania z Discogs'), 'https://www.discogs.com/release/1');
    await t.tap(find.text('Wczytaj z Discogs'));
    await t.pumpAndSettle();
    expect(state.tracklistPicked, [true, true, false]);
    await t.tap(find.text('Ustaw znaczniki i tytuły według listy'));
    await t.pumpAndSettle();
    expect(repo.calls.lastWhere((c) => c['action'] == 'align')['durations'], [60000, 120000]);
    expect(state.markers, [61000]);
    expect(find.text('A dwa'), findsOneWidget);
    state.declick = true;
    state.hum = true;
    state.speed = 1.5;
    state.changed();
    await t.pump();
    await t.tap(find.text('Dodaj do biblioteki'));
    await t.pump();
    await t.pump();
    final export = repo.calls.lastWhere((c) => c['action'] == 'export');
    expect(export['markers'], [61000]);
    expect(export['titles'], ['A jeden', 'A dwa']);
    expect(export['firstTrack'], 1);
    expect(export['totalTracks'], 3);
    expect(export['releaseId'], '');
    final restore = export['restore'] as Map;
    expect(restore['declick'], isTrue);
    expect(restore['hum'], 50);
    expect(restore['speed'] as double, closeTo(1.015, 1e-9));
    await t.tap(find.text('Zatrzymaj eksport'));
    await t.pumpAndSettle();
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
