import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mytify/main.dart';
import 'package:mytify/player_ui.dart';
import 'package:mytify/radio.dart';
import 'package:mytify/repository_android.dart';
import 'package:mytify/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pl.mytify/library');
  const events = MethodChannel('pl.mytify/import');
  late Map<String, dynamic> audio;
  late List<Map<String, dynamic>> commands, radioCalls;

  test('stations from the directory, typed addresses and what is on air', () {
    expect(Station.fromJson({'id': 'x', 'url': 'http://a'}), isNull);
    expect(Station.fromJson({'id': 'radio:a', 'url': 'ftp://a'}), isNull);
    final s = Station.fromJson({'id': 'radio:a', 'url': 'https://a/live', 'logo': 'javascript:x', 'tags': ['rock', 'pop', 'indie'], 'codec': 'AAC', 'bitrate': 64})!;
    expect(s.logo, '');
    expect(s.details, 'rock, pop · AAC 64 kbps');
    expect(Station.customId('http://x/a'), Station.customId('http://x/a'));
    expect(Station.customId('http://x/a'), isNot(Station.customId('http://x/b')));
    expect(splitOnAir('Artysta - Tytuł - Live'), ('Artysta', 'Tytuł - Live'));
    expect(splitOnAir('Wiadomości'), (null, 'Wiadomości'));
    expect(splitOnAir('  '), isNull);
    final quiet = radioTrack({'id': 'radio:a', 'name': 'Jazz FM', 'title': null, 'logo': ''}, (l) => l);
    expect((quiet.title, quiet.artist, quiet.album, quiet.cover), ('Jazz FM', 'Radio', 'Jazz FM', null));
    final song = radioTrack({'id': 'radio:a', 'name': 'Jazz FM', 'title': 'Miles Davis - So What', 'logo': 'https://l/x.png'}, (l) => 'base?u=$l');
    expect((song.title, song.artist, song.cover), ('So What', 'Miles Davis', 'base?u=https://l/x.png'));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    commands = [];
    radioCalls = [];
    audio = {
      'available': true,
      'playing': false,
      'completed': false,
      'buffering': false,
      'repeat': false,
      'shuffled': false,
      'queueIds': <String>[],
      'currentId': null,
      'index': 0,
      'errorSerial': 0,
      'revision': 1,
      'underrunFrames': 0,
      'renderedFrames': 0,
      'volume': 80,
      'positionMs': 0,
      'durationMs': 0,
      'selectedDevice': 'auto',
    };
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'audioCommand') {
        final c = Map<String, dynamic>.from(call.arguments as Map);
        commands.add(c);
        if (c['action'] == 'radio') {
          audio = {
            ...audio,
            'playing': true,
            'queueIds': [c['id']],
            'currentId': c['id'],
            'radio': {'id': c['id'], 'name': c['name'], 'url': c['url'], 'logo': '', 'title': null, 'codec': 'MP3', 'bitrate': 128},
          };
        }
      }
      if (call.method == 'radio') {
        final args = Map<String, dynamic>.from(jsonDecode(call.arguments as String) as Map);
        radioCalls.add(args);
        return jsonEncode(switch (args['action']) {
          'search' => [
            {'id': 'radio:jazz', 'name': 'Jazz Radio', 'url': 'https://jazz.example/live', 'tags': ['jazz'], 'codec': 'MP3', 'bitrate': 128, 'country': 'PL'},
            {'id': 'radio:hls', 'name': 'Nowa Fala', 'url': 'https://hls.example/a.m3u8', 'hls': true},
          ],
          'click' => {'url': 'https://jazz.example/live?fresh'},
          _ => {'ok': true},
        });
      }
      return jsonEncode(switch (call.method) {
        'load' => [
          {'id': 'hash', 'title': 'So What', 'artist': 'Miles Davis', 'album': 'Kind of Blue', 'fileName': 'a.flac', 'format': 'FLAC', 'durationMs': 60000},
        ],
        'sources' => [],
        'audioDevices' => [
          {'id': 'auto', 'name': 'Ten telefon'},
        ],
        'audioState' || 'audioCommand' => audio,
        _ => null,
      });
    });
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('radio tab: popular stations, playing one, live bar, heart looks in the library, favourites reach the phone', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MytifyApp(repository: AndroidLibraryRepository()));
    await settle(tester);
    final app = tester.state<LibraryScreenState>(find.byType(LibraryScreen));
    await tester.tap(find.text('Radio').last);
    await settle(tester);
    expect(app.route, const Nav('radio'));
    expect(radioCalls.first['action'], 'search');
    expect(radioCalls.first['country'], 'PL');
    expect(find.text('Jazz Radio'), findsOneWidget);

    await tester.tap(find.text('Jazz Radio'));
    await settle(tester);
    final play = commands.lastWhere((c) => c['action'] == 'radio');
    expect(play['id'], 'radio:jazz');
    // Sound starts from the known address; the directory click runs alongside.
    expect(play['url'], 'https://jazz.example/live');
    expect(radioCalls.any((c) => c['action'] == 'click' && c['id'] == 'radio:jazz'), isTrue);
    expect(app.recentStations.first.id, 'radio:jazz');
    expect(app.current?.id, 'radio:jazz');
    expect(app.current?.title, 'Jazz Radio');

    // The station names the song: the player shows it and remembers it as heard.
    audio = {
      ...audio,
      'radio': {...audio['radio'] as Map, 'title': 'Miles Davis - So What'},
    };
    await settle(tester);
    expect(app.current?.title, 'So What');
    expect(app.heardOnRadio.first['title'], 'Miles Davis - So What');
    final mini = find.byType(MiniPlayer);
    expect(find.descendant(of: mini, matching: find.text('So What')), findsOneWidget);
    expect(tester.widget<SeekBar>(find.descendant(of: mini, matching: find.byType(SeekBar))).live, isTrue);

    // The heart makes the station a favourite.
    app.openNowPlaying();
    await settle(tester);
    final screen = find.byType(NowPlayingScreen);
    expect(find.descendant(of: screen, matching: find.text('NA ŻYWO')), findsOneWidget);
    // Next changes the station: the list sent along starts with favourites, then the list it came from.
    final skip = tester.widget<IconAction>(find.descendant(of: screen, matching: find.widgetWithIcon(IconAction, Icons.skip_next_rounded)));
    expect(skip.onPressed, isNotNull);
    expect([for (final x in play['stations'] as List) (x as Map)['id']], ['radio:jazz', 'radio:hls']);
    await tester.tap(find.descendant(of: screen, matching: find.byType(LikeButton)));
    await settle(tester);
    expect(app.isFavoriteStation('radio:jazz'), isTrue);
    expect(app.current?.liked, isTrue);
    // What the station announced can be looked up in the library.
    app.findInLibrary(app.onAirText()!);
    await settle(tester);
    expect(app.route, Nav.search);
    expect(app.searchText.text, 'Miles Davis So What');

    // Favourites are kept and handed to Android Auto.
    final fav = radioCalls.lastWhere((c) => c['action'] == 'favorites');
    expect((fav['stations'] as List).single['id'], 'radio:jazz');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
