import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'library_index.dart';

/// View settings and local listening history. Missing storage never blocks the UI.
class UiPrefs {
  SharedPreferences? _store;
  Map<String, dynamic> _values = {};
  PlayHistory history = PlayHistory();
  Timer? _saveTimer, _historyTimer;

  Future<void> load() async {
    try {
      _store = await SharedPreferences.getInstance();
      _values = Map<String, dynamic>.from(
        jsonDecode(_store!.getString('mytify.ui') ?? '{}') as Map,
      );
      history = PlayHistory.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(_store!.getString('mytify.history') ?? '{}') as Map,
        ),
      );
    } catch (_) {
      /* first run, tests or unavailable storage: defaults */
    }
  }

  T get<T>(String key, T fallback) {
    final v = _values[key];
    return v is T ? v : fallback;
  }

  double number(String key, double fallback) =>
      (_values[key] as num?)?.toDouble() ?? fallback;

  List<String> list(String key) =>
      (_values[key] as List? ?? const []).cast<String>();

  void set(String key, Object? value) {
    _values[key] = value;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_write('mytify.ui', jsonEncode(_values)));
    });
  }

  void saveHistory() {
    _historyTimer?.cancel();
    _historyTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_write('mytify.history', jsonEncode(history.toJson())));
    });
  }

  Future<void> _write(String key, String value) async {
    try {
      await _store?.setString(key, value);
    } catch (_) {
      /* best effort */
    }
  }

  void dispose() {
    _saveTimer?.cancel();
    _historyTimer?.cancel();
  }

  bool pinned(String id) => list('pins').contains(id);
  void togglePin(String id) {
    final pins = list('pins');
    pins.contains(id) ? pins.remove(id) : pins.insert(0, id);
    set('pins', pins);
  }

  void rememberSearch(String query) {
    final q = query.trim();
    if (q.length < 2) return;
    final all = list('searches')..remove(q);
    all.insert(0, q);
    set('searches', all.take(8).toList());
  }
}
