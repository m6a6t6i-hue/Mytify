import 'dart:math';

import 'model.dart';

class PlaybackQueue {
  List<Track> items = [];
  List<Track> _original = [];
  int index = 0;
  bool repeat = false, shuffled = false;
  Track? get current => items.isEmpty ? null : items[index];
  void replace(List<Track> tracks, String selectedId) {
    if (tracks.isEmpty) {
      items = [];
      _original = [];
      index = 0;
      return;
    }
    final selected = tracks.indexWhere((t) => t.id == selectedId);
    if (selected < 0) {
      throw ArgumentError('Wybrany utwór nie należy do kolejki.');
    }
    items = List.of(tracks);
    _original = List.of(tracks);
    index = selected;
    shuffled = false;
  }

  bool next() {
    if (items.isEmpty) return false;
    for (var offset = 1; offset <= items.length; offset++) {
      var candidate = index + offset;
      if (candidate >= items.length && !repeat) break;
      candidate %= items.length;
      if (items[candidate].available) {
        index = candidate;
        return true;
      }
    }
    return false;
  }

  bool previous() {
    if (items.isEmpty) return false;
    for (var offset = 1; offset <= items.length; offset++) {
      var candidate = index - offset;
      if (candidate < 0 && !repeat) break;
      candidate = (candidate + items.length) % items.length;
      if (items[candidate].available) {
        index = candidate;
        return true;
      }
    }
    return false;
  }

  void toggleShuffle({Random? random}) {
    final selectedId = current?.id;
    shuffled = !shuffled;
    items = List.of(_original);
    if (shuffled) items.shuffle(random);
    index = selectedId == null
        ? 0
        : items.indexWhere((t) => t.id == selectedId);
  }

  void remove(String id) {
    final selectedId = current?.id;
    items.removeWhere((t) => t.id == id);
    _original.removeWhere((t) => t.id == id);
    if (items.isEmpty) {
      index = 0;
      return;
    }
    final newIndex = items.indexWhere((t) => t.id == selectedId);
    index = newIndex >= 0 ? newIndex : index.clamp(0, items.length - 1);
  }

  void refresh(List<Track> tracks) {
    final currentId = current?.id;
    final byId = {for (final track in tracks) track.id: track};
    items = items
        .where((t) => byId.containsKey(t.id))
        .map((t) => byId[t.id]!)
        .toList();
    _original = _original
        .where((t) => byId.containsKey(t.id))
        .map((t) => byId[t.id]!)
        .toList();
    if (items.isEmpty) {
      index = 0;
      return;
    }
    final found = items.indexWhere((t) => t.id == currentId);
    index = found >= 0 ? found : index.clamp(0, items.length - 1);
  }
}
