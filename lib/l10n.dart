import 'l10n_en.dart';

/// App language: 'pl' (default) or 'en'. Read before the first frame; a change in the
/// settings rebuilds every widget.
String lang = 'pl';

const languages = [('pl', 'Polski'), ('en', 'English')];

/// Translates a Polish UI text. {0}, {1}... in the text are filled from [args].
/// Texts without a translation stay Polish, so nothing ever shows a key.
String tr(String pl, [List<Object?> args = const []]) {
  var s = lang == 'en' ? (enStrings[pl] ?? pl) : pl;
  for (var i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i]}');
  }
  return s;
}

final _patterns = <(RegExp, String)>[];

/// Messages that come from the engine or Android at run time: exact text first, then
/// the known messages with a variable part.
String trMessage(String message) {
  if (lang != 'en') return message;
  final exact = enStrings[message];
  if (exact != null) return exact;
  if (_patterns.isEmpty) {
    for (final e in enStrings.entries) {
      if (!e.key.contains('{0}')) continue;
      final parts = e.key.split(RegExp(r'\{\d+\}'));
      _patterns.add((RegExp('^${parts.map(RegExp.escape).join('(.*?)')}\$', dotAll: true), e.key));
    }
  }
  for (final (re, key) in _patterns) {
    final m = re.firstMatch(message);
    if (m == null) continue;
    final order = RegExp(r'\{(\d+)\}').allMatches(key).map((x) => int.parse(x.group(1)!)).toList();
    final args = List<Object?>.filled(order.isEmpty ? 0 : order.reduce((a, b) => a > b ? a : b) + 1, '');
    for (var i = 0; i < order.length; i++) {
      args[order[i]] = m.group(i + 1);
    }
    return tr(key, args);
  }
  return message;
}
