import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'main.dart';
import 'model.dart';
import 'player_ui.dart';
import 'playlists.dart';
import 'views.dart';
import 'widgets.dart';

const sidebarColor = Color(0xff111214);

/// Windows / wide layout: sidebar, toolbar, content, optional right panel, player bar.
class DesktopShell extends StatefulWidget {
  final LibraryScreenState app;
  const DesktopShell({super.key, required this.app});
  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  LibraryScreenState get app => widget.app;
  double? _dragSidebar, _dragPanel;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool get _editing =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return false;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    final k = e.logicalKey;
    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed || keys.isMetaPressed;
    final shift = keys.isShiftPressed;
    final alt = keys.isAltPressed;
    if (_editing) {
      if (k == LogicalKeyboardKey.escape) {
        if (app.searchText.text.isNotEmpty) {
          app.searchText.clear();
          app.refresh();
        }
        FocusManager.instance.primaryFocus?.unfocus();
        return true;
      }
      return false;
    }
    void run(FutureOr<void> Function() f) => unawaited(Future.sync(f));
    if (e is KeyRepeatEvent &&
        !(ctrl && (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown))) {
      return false;
    }
    if (k == LogicalKeyboardKey.space && !ctrl && !alt) {
      run(app.togglePlay);
    } else if (ctrl && k == LogicalKeyboardKey.arrowRight) {
      run(app.nextTrack);
    } else if (ctrl && k == LogicalKeyboardKey.arrowLeft) {
      run(app.previousTrack);
    } else if (ctrl && k == LogicalKeyboardKey.arrowUp) {
      run(() => app.nudgeVolume(5));
    } else if (ctrl && k == LogicalKeyboardKey.arrowDown) {
      run(() => app.nudgeVolume(-5));
    } else if (ctrl && k == LogicalKeyboardKey.keyF) {
      app.focusSearch();
    } else if (ctrl && k == LogicalKeyboardKey.keyO) {
      if (!app.importing) run(() => app.importMusic(shift));
    } else if (ctrl && k == LogicalKeyboardKey.keyL) {
      run(app.likeCurrent);
    } else if (ctrl && k == LogicalKeyboardKey.keyN) {
      if (app.playlistRepo != null) run(app.createPlaylist);
    } else if (ctrl && k == LogicalKeyboardKey.comma) {
      app.go(const Nav('settings'));
    } else if (ctrl && k == LogicalKeyboardKey.keyA) {
      if (app.visibleList.isEmpty) return false;
      app.selectAll();
    } else if (ctrl && k == LogicalKeyboardKey.keyM) {
      app.toggleFloating();
    } else if (ctrl && shift && k == LogicalKeyboardKey.keyV) {
      app.openVisualizer();
    } else if (k == LogicalKeyboardKey.f11) {
      app.openNowPlaying();
    } else if (alt && k == LogicalKeyboardKey.arrowLeft) {
      app.back();
    } else if (alt && k == LogicalKeyboardKey.arrowRight) {
      app.forward();
    } else if (k == LogicalKeyboardKey.delete) {
      if (app.selected.isEmpty) return false;
      run(app.deleteSelection);
    } else if (k == LogicalKeyboardKey.enter) {
      final list = app.selectedTracks;
      if (list.isEmpty) return false;
      run(() => app.playTracks(app.visibleList, start: list.first));
    } else if (k == LogicalKeyboardKey.escape) {
      if (app.selected.isNotEmpty) {
        app.refresh(app.selected.clear);
      } else if (panelOpen) {
        setPanel(false);
      } else {
        return false;
      }
    } else {
      return false;
    }
    return true;
  }

  double get width => MediaQuery.sizeOf(context).width;
  bool get collapsed =>
      app.prefs.get<bool>('sidebarCollapsed', false) || width < 1000;
  /// Settings, sources and import hide the right panel by default. Opening it
  /// there lasts until leaving; the remembered library state is never touched.
  bool get _utility => const {'settings', 'sources', 'import', 'downloads'}.contains(app.route.page);
  bool _utilityPanel = false;
  String? _utilityRoute;
  bool get panelOpen {
    if (width < 1100) return false;
    if (_utility) return _utilityPanel;
    return app.prefs.get<bool>('panel.open', width >= 1400);
  }

  String get panelTab => app.prefs.get<String>('panel.tab', 'now');
  void setPanel(bool open, [String? tab]) => app.refresh(() {
    if (_utility) {
      _utilityPanel = open;
    } else {
      app.prefs.set('panel.open', open);
    }
    if (tab != null) app.prefs.set('panel.tab', tab);
  });

  void onPanel(String tab) {
    if (width < 1100) {
      // Too narrow for a third column: queue opens as a sheet, now playing full screen.
      if (tab == 'queue') {
        showQueueSheet(app);
      } else {
        app.openNowPlaying();
      }
      return;
    }
    if (tab.isEmpty) return setPanel(!panelOpen);
    if (panelOpen && panelTab == tab) return setPanel(false);
    setPanel(true, tab);
  }

  @override
  Widget build(BuildContext context) {
    final sidebarW = collapsed
        ? 68.0
        : (_dragSidebar ?? app.prefs.number('sidebar.w', 240)).clamp(200.0, 320.0);
    final panelW = (_dragPanel ?? app.prefs.number('panel.w', 320)).clamp(280.0, 420.0);
    final route = app.route;
    if (_utilityRoute != route.page) {
      _utilityRoute = route.page;
      _utilityPanel = false;
    }
    return Scaffold(
      backgroundColor: background,
      body: Listener(
        onPointerDown: (e) {
          if (e.buttons & kBackMouseButton != 0) app.back();
          if (e.buttons & kForwardMouseButton != 0) app.forward();
        },
        child: Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedContainer(
                    duration: _dragSidebar == null ? motion(context, Dur.standard) : Duration.zero,
                    curve: Curves.easeOutCubic,
                    width: sidebarW,
                    child: Sidebar(app: app, collapsed: collapsed, onToggle: () => app.refresh(() => app.prefs.set('sidebarCollapsed', !app.prefs.get<bool>('sidebarCollapsed', false)))),
                  ),
                  if (!collapsed)
                    _ResizeHandle(
                      onDrag: (dx) => setState(() => _dragSidebar = (sidebarW + dx).clamp(200.0, 320.0)),
                      onEnd: () {
                        app.prefs.set('sidebar.w', _dragSidebar ?? sidebarW);
                        setState(() => _dragSidebar = null);
                      },
                    )
                  else
                    const VerticalDivider(width: 1, color: softBorder),
                  Expanded(
                    child: Column(
                      children: [
                        Toolbar(app: app),
                        Expanded(
                          child: ClipRect(
                            child: AnimatedSwitcher(
                              duration: motion(context, Dur.screen),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeIn,
                              transitionBuilder: (child, a) => FadeTransition(
                                opacity: a,
                                child: SlideTransition(
                                  position: Tween(begin: const Offset(0, .012), end: Offset.zero).animate(a),
                                  child: child,
                                ),
                              ),
                              layoutBuilder: (current, previous) => Stack(
                                alignment: Alignment.topCenter,
                                children: [
                                  for (final old in previous) IgnorePointer(child: ExcludeFocus(child: old)),
                                  ?current,
                                ],
                              ),
                              child: KeyedSubtree(key: ValueKey(app.navSerial), child: pageFor(app, route)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (panelOpen) ...[
                    _ResizeHandle(
                      onDrag: (dx) => setState(() => _dragPanel = (panelW - dx).clamp(280.0, 420.0)),
                      onEnd: () {
                        app.prefs.set('panel.w', _dragPanel ?? panelW);
                        setState(() => _dragPanel = null);
                      },
                    ),
                    SizedBox(
                      width: panelW,
                      child: SidePanel(
                        app: app,
                        tab: panelTab,
                        onTab: (t) => setPanel(true, t),
                        onClose: () => setPanel(false),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            PlayerBar(app: app, panelOpen: panelOpen, panelTab: panelTab, onPanel: onPanel),
          ],
        ),
      ),
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  final ValueChanged<double> onDrag;
  final VoidCallback onEnd;
  const _ResizeHandle({required this.onDrag, required this.onEnd});
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
      onHorizontalDragEnd: (_) => onEnd(),
      child: const SizedBox(
        width: 5,
        child: Center(child: VerticalDivider(width: 1, color: softBorder)),
      ),
    ),
  );
}

class Toolbar extends StatelessWidget {
  final LibraryScreenState app;
  const Toolbar({super.key, required this.app});
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.m),
      child: Row(
        children: [
          IconAction(Icons.chevron_left_rounded, 'Wstecz (Alt+←)', app.canGoBack ? app.back : null, size: 24, box: 34),
          IconAction(Icons.chevron_right_rounded, 'Dalej (Alt+→)', app.canGoForward ? app.forward : null, size: 24, box: 34),
          const SizedBox(width: Sp.m),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380, minWidth: 180),
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: app.searchText,
                focusNode: app.searchFocus,
                onChanged: app.onSearchChanged,
                onSubmitted: (v) => app.prefs.rememberSearch(v),
                style: const TextStyle(fontSize: 13.5),
                decoration: InputDecoration(
                  hintText: 'Szukaj',
                  prefixIcon: const Icon(Icons.search_rounded, size: 18, color: secondaryText),
                  prefixIconConstraints: const BoxConstraints(minWidth: 36),
                  suffixIcon: app.query.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.only(right: 10, top: 10),
                          child: Text('Ctrl+F', style: TextStyle(fontSize: 11, color: secondaryText)),
                        )
                      : IconAction(Icons.close_rounded, 'Wyczyść', () {
                          app.searchText.clear();
                          app.refresh();
                        }, size: 16, box: 30),
                  contentPadding: const EdgeInsets.symmetric(vertical: 9),
                ),
              ),
            ),
          ),
          const Spacer(),
          if (app.importing) ImportStatus(app: app, compact: true),
          IngestStatus(app: app),
          Builder(
            builder: (context) => IconAction(
              Icons.add_rounded,
              'Dodaj źródło',
              () {
                final box = context.findRenderObject() as RenderBox?;
                app.showAddMusic(at: box?.localToGlobal(box.size.bottomLeft(Offset.zero)));
              },
              color: secondaryText,
            ),
          ),
          IconAction(Icons.settings_outlined, 'Ustawienia (Ctrl+,)', () => app.go(const Nav('settings')), color: secondaryText, size: 20),
        ],
      ),
    ),
  );
}

class ImportStatus extends StatelessWidget {
  final LibraryScreenState app;
  final bool compact;
  const ImportStatus({super.key, required this.app, this.compact = false});
  @override
  Widget build(BuildContext context) {
    final p = app.progress;
    final label = p.total == 0 ? 'Import' : 'Import ${p.done} z ${p.total}';
    return Tooltip(
      message: p.name,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.s),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: p.total == 0 ? null : p.done / p.total,
              ),
            ),
            const SizedBox(width: Sp.s),
            Text(label, style: Txt.meta),
            IconAction(
              Icons.close_rounded,
              app.cancelling ? 'Przerywanie' : 'Zatrzymaj po bieżącym pliku',
              app.cancelling ? null : () => unawaited(app.cancelImport()),
              size: 16,
              box: 30,
              color: secondaryText,
            ),
          ],
        ),
      ),
    );
  }
}

class Sidebar extends StatelessWidget {
  final LibraryScreenState app;
  final bool collapsed;
  final VoidCallback onToggle;
  const Sidebar({super.key, required this.app, required this.collapsed, required this.onToggle});

  bool _active(String page, [String? arg]) {
    final r = app.route;
    if (r.page != page) return false;
    return arg == null || r.arg == arg;
  }

  Widget _item(IconData icon, IconData activeIcon, String label, Nav target, {bool? active}) {
    final on = active ?? _active(target.page, target.arg);
    final tile = Material(
      color: on ? hoverFill : Colors.transparent,
      borderRadius: BorderRadius.circular(Rad.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(Rad.control),
        onTap: () => app.go(target),
        child: SizedBox(
          height: 38,
          child: Row(
            mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              if (!collapsed) const SizedBox(width: Sp.m),
              Icon(on ? activeIcon : icon, size: 21, color: on ? primaryText : secondaryText),
              if (!collapsed) ...[
                const SizedBox(width: Sp.m),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? primaryText : secondaryText),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: collapsed ? Sp.s : Sp.s, vertical: 1),
      child: collapsed ? Tooltip(message: label, preferBelow: false, child: tile) : tile,
    );
  }

  Widget _label(String text, {Widget? trailing}) => collapsed
      ? const Padding(padding: EdgeInsets.symmetric(vertical: Sp.s), child: Divider(height: 1, indent: 18, endIndent: 18, color: softBorder))
      : Padding(
          padding: const EdgeInsets.fromLTRB(Sp.xl, Sp.l, Sp.s, Sp.xs),
          child: Row(
            children: [
              Expanded(child: Text(text.toUpperCase(), style: Txt.meta.copyWith(fontSize: 11, letterSpacing: .8, fontWeight: FontWeight.w700))),
              ?trailing,
            ],
          ),
        );

  @override
  Widget build(BuildContext context) {
    final playlists = app.orderedPlaylists;
    return ColoredBox(
      color: sidebarColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 52,
            child: Row(
              mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                if (!collapsed) ...[
                  const SizedBox(width: Sp.l),
                  const Expanded(child: MytifyBrand(size: 26)),
                ],
                IconAction(
                  collapsed ? Icons.menu_rounded : Icons.menu_open_rounded,
                  collapsed ? 'Rozwiń panel' : 'Zwiń panel',
                  onToggle,
                  color: secondaryText,
                  size: 20,
                ),
                if (!collapsed) const SizedBox(width: Sp.xs),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final nav = <Widget>[
                  _item(Icons.home_outlined, Icons.home_rounded, 'Start', Nav.home),
                  _item(Icons.search_rounded, Icons.manage_search_rounded, 'Szukaj', Nav.search),
                  _label('Biblioteka'),
                  _item(Icons.album_outlined, Icons.album_rounded, 'Albumy', const Nav('library', 'albums'), active: _active('library', 'albums') || _active('library', 'all') || _active('album')),
                  _item(Icons.person_outline_rounded, Icons.person_rounded, 'Artyści', const Nav('library', 'artists'), active: _active('library', 'artists') || _active('artist')),
                  _item(Icons.music_note_outlined, Icons.music_note_rounded, 'Utwory', const Nav('library', 'tracks')),
                  _item(Icons.favorite_border_rounded, Icons.favorite_rounded, 'Polubione', const Nav('liked')),
                  _item(Icons.schedule_rounded, Icons.schedule_rounded, 'Ostatnio dodane', const Nav('recent')),
                  if (app.playlistRepo != null)
                    _label(
                      'Playlisty',
                      trailing: IconAction(Icons.add_rounded, 'Nowa playlista (Ctrl+N)', () => unawaited(app.createPlaylist()), size: 18, box: 28, color: secondaryText),
                    ),
                ];
                final items = [
                  for (final p in playlists) _PlaylistItem(app: app, playlist: p, collapsed: collapsed),
                  if (collapsed && app.playlistRepo != null)
                    Center(child: IconAction(Icons.add_rounded, 'Nowa playlista', () => unawaited(app.createPlaylist()), color: secondaryText)),
                ];
                // Tall windows: playlists scroll on their own under fixed navigation.
                if (box.maxHeight >= 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ...nav,
                      Expanded(
                        child: ListView(padding: const EdgeInsets.only(bottom: Sp.s), children: items),
                      ),
                    ],
                  );
                }
                return ListView(padding: const EdgeInsets.only(bottom: Sp.s), children: [...nav, ...items]);
              },
            ),
          ),
          const Divider(height: 1, color: softBorder),
          const SizedBox(height: Sp.xs),
          if (app.importing && !collapsed) ImportStatus(app: app),
          _item(Icons.folder_open_outlined, Icons.folder_rounded, 'Źródła muzyki', const Nav('sources'), active: _active('sources') || _active('settings', 'sources') || _active('downloads')),
          if (app.canTransfer)
            _item(Icons.phonelink_rounded, Icons.phonelink_rounded, 'Połącz telefon', const Nav('settings', 'phone')),
          _item(Icons.settings_outlined, Icons.settings_rounded, 'Ustawienia', const Nav('settings'), active: (_active('settings') && !_active('settings', 'sources') && !_active('settings', 'phone')) || _active('import')),
          const SizedBox(height: Sp.s),
        ],
      ),
    );
  }
}

class _PlaylistItem extends StatelessWidget {
  final LibraryScreenState app;
  final MusicPlaylist playlist;
  final bool collapsed;
  const _PlaylistItem({required this.app, required this.playlist, required this.collapsed});
  @override
  Widget build(BuildContext context) {
    final p = playlist;
    final active = app.route == Nav('playlist', p.id);
    final pinned = app.prefs.pinned('playlist:${p.id}');
    final tracks = app.index.playlistTracks(p);
    return DragTarget<List<Track>>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => unawaited(app.addToPlaylist(p, d.data)),
      builder: (context, candidates, _) {
        final over = candidates.isNotEmpty;
        final tile = AnimatedContainer(
          duration: motion(context, Dur.hover),
          margin: const EdgeInsets.symmetric(horizontal: Sp.s, vertical: 1),
          decoration: BoxDecoration(
            color: over ? selectedFill : active ? hoverFill : Colors.transparent,
            borderRadius: BorderRadius.circular(Rad.control),
            border: Border.all(color: over ? accent : Colors.transparent),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(Rad.control),
            onTap: () => app.go(Nav('playlist', p.id)),
            onSecondaryTapUp: (d) => unawaited(app.playlistMenu(p, at: d.globalPosition)),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : Sp.s, vertical: 5),
              child: Row(
                mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
                children: [
                  PlaylistArt(tracks: tracks, size: collapsed ? 36 : 32),
                  if (!collapsed) ...[
                    const SizedBox(width: Sp.m),
                    Expanded(
                      child: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, color: active ? primaryText : secondaryText, fontWeight: active ? FontWeight.w700 : FontWeight.w500),
                      ),
                    ),
                    if (pinned) const Icon(Icons.push_pin_rounded, size: 13, color: secondaryText),
                  ],
                ],
              ),
            ),
          ),
        );
        return collapsed ? Tooltip(message: p.name, child: tile) : tile;
      },
    );
  }
}

/// Running CD import, level check, recording or export, visible from any view.
class IngestStatus extends StatelessWidget {
  final LibraryScreenState app;
  const IngestStatus({super.key, required this.app});
  @override
  Widget build(BuildContext context) {
    if (!app.canDigitize || app.isPhone) return const SizedBox.shrink();
    final s = app.ingest;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        if (!s.running || app.route.page == 'import') return const SizedBox.shrink();
        final done = (s.status['done'] as num? ?? 0).toDouble();
        final total = (s.status['total'] as num? ?? 0).toDouble();
        final frames = (s.status['frames'] as num? ?? 0).toDouble();
        final rate = (s.status['rate'] as num? ?? 0).toDouble();
        final label = s.recording
            ? 'Nagrywanie ${clock(rate > 0 ? (frames * 1000 / rate).round() : 0)}'
            : s.monitoring
            ? 'Podgląd poziomu'
            : s.ripping
            ? 'Import CD${total > 0 ? ' ${(done * 100 / total).clamp(0, 100).round()}%' : ''}'
            : s.exporting
            ? 'Eksport ${done.round()} z ${total.round()}'
            : 'Import';
        return Padding(
          padding: const EdgeInsets.only(right: Sp.s),
          child: TextButton.icon(
            style: Ctl.text,
            onPressed: () => app.go(const Nav('import')),
            icon: s.recording
                ? const Icon(Icons.fiber_manual_record, size: 12, color: Color(0xffff5252))
                : const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            label: Text(label, style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
          ),
        );
      },
    );
  }
}
