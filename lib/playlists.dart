import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'model.dart';

class MusicPlaylist {
  final String id, name;
  final List<String> ids;
  const MusicPlaylist(this.id, this.name, this.ids);
  factory MusicPlaylist.fromJson(Map<String, dynamic> j) => MusicPlaylist(
    j['id'] as String,
    j['name'] as String,
    (j['ids'] as List).cast<String>(),
  );
}

abstract interface class PlaylistRepository {
  Future<List<MusicPlaylist>> playlists();
  Future<void> savePlaylist(String? id, String name, List<String> ids);
  Future<void> deletePlaylist(String id);
}

class PlaylistScreen extends StatefulWidget {
  final PlaylistRepository repository;
  final List<Track> tracks;
  final void Function(List<Track>) onPlay;
  const PlaylistScreen({
    super.key,
    required this.repository,
    required this.tracks,
    required this.onPlay,
  });
  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  List<MusicPlaylist> items = [];
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final v = await widget.repository.playlists();
      if (mounted) {
        setState(() => items = v);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> edit([MusicPlaylist? playlist]) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => _PlaylistEditor(
        repository: widget.repository,
        tracks: widget.tracks,
        playlist: playlist,
      ),
    );
    if (result == true) {
      await refresh();
    }
  }

  Future<void> remove(MusicPlaylist p) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Usuń playlistę?'),
        content: Text(p.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Usuń'),
          ),
        ],
      ),
    );
    if (yes != true) {
      return;
    }
    try {
      await widget.repository.deletePlaylist(p.id);
      await refresh();
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Playlisty')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => edit(),
      icon: const Icon(Icons.add),
      label: const Text('Nowa playlista'),
    ),
    body: busy
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
            children: [
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.redAccent)),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Utwórz playlistę i wybierz utwory.'),
                ),
              ...items.map(
                (p) => ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(p.name),
                  subtitle: Text(collectionCount(p.ids.length, 'utwór', 'utwory', 'utworów')),
                  onTap: () => edit(p),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Odtwórz playlistę',
                        onPressed: () {
                          final byId = {for (final t in widget.tracks) t.id: t};
                          final selection = p.ids
                              .where(byId.containsKey)
                              .map((id) => byId[id]!)
                              .where((t) => t.available)
                              .toList();
                          if (selection.isNotEmpty) {
                            widget.onPlay(selection);
                          }
                        },
                        icon: const Icon(Icons.play_arrow),
                      ),
                      IconButton(
                        tooltip: 'Usuń playlistę',
                        onPressed: () => remove(p),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
  );
}

class _PlaylistEditor extends StatefulWidget {
  final PlaylistRepository repository;
  final List<Track> tracks;
  final MusicPlaylist? playlist;
  const _PlaylistEditor({
    required this.repository,
    required this.tracks,
    this.playlist,
  });
  @override
  State<_PlaylistEditor> createState() => _PlaylistEditorState();
}

class _PlaylistEditorState extends State<_PlaylistEditor> {
  late final name = TextEditingController(text: widget.playlist?.name ?? '');
  late final knownIds = {for (final t in widget.tracks) t.id};
  late final selected = [
    ...(widget.playlist?.ids.where(knownIds.contains) ?? <String>[]),
  ];
  bool busy = false;
  String? error;
  String query = '';
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (name.text.trim().isEmpty) {
      setState(() => error = 'Podaj nazwę playlisty.');
      return;
    }
    setState(() => busy = true);
    try {
      await widget.repository.savePlaylist(
        widget.playlist?.id,
        name.text,
        selected,
      );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracks = filterTracks(widget.tracks, query);
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text(
          widget.playlist == null ? 'Nowa playlista' : 'Edytuj playlistę',
        ),
        content: SizedBox(
          width: 520,
          height: MediaQuery.sizeOf(context).height * .55,
          child: Column(
            children: [
              TextField(
                controller: name,
                maxLength: 100,
                decoration: const InputDecoration(labelText: 'Nazwa playlisty'),
              ),
              TextField(
                onChanged: (s) => setState(() => query = s),
                decoration: const InputDecoration(
                  labelText: 'Szukaj utworów',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              Text(
                '${selected.length} wybranych · kolejność dodawania',
                style: const TextStyle(fontSize: 12),
              ),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.redAccent)),
              Expanded(
                child: ListView.builder(
                  itemCount: tracks.length,
                  itemBuilder: (c, i) {
                    final t = tracks[i];
                    return CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        t.displayArtist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      value: selected.contains(t.id),
                      onChanged: busy
                          ? null
                          : (v) => setState(() {
                              if (v == true) {
                                selected.add(t.id);
                              } else {
                                selected.remove(t.id);
                              }
                            }),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context, false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: busy ? null : save,
            child: const Text('Zapisz'),
          ),
        ],
      ),
    );
  }
}
