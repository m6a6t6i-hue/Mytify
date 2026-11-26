import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'main.dart';
import 'radio.dart';
import 'player_ui.dart';
import 'views.dart';
import 'widgets.dart';
import 'l10n.dart';

/// Android / narrow layout: three tabs, compact header, mini-player above the bar.
class MobileShell extends StatelessWidget {
  final LibraryScreenState app;
  const MobileShell({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final route = app.route;
    final showMini = app.current != null &&
        !(app.tab == 0 && route.page == 'home' && app.homePlayerVisible);
    return PopScope(
      canPop: !app.canGoBack && app.tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (app.canGoBack) {
          app.back();
        } else {
          app.selectTab(0);
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: (palette.light ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light).copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: background,
        ),
        child: Scaffold(
          backgroundColor: background,
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                _Header(app: app),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: motion(context, Dur.screen),
                    switchInCurve: Curves.easeOutCubic,
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: SlideTransition(
                        position: Tween(begin: const Offset(.03, 0), end: Offset.zero).animate(a),
                        child: child,
                      ),
                    ),
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topCenter,
                      children: [
                        for (final old in previous) IgnorePointer(child: old),
                        ?current,
                      ],
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(app.navSerial),
                      child: pageFor(app, route),
                    ),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSize(
                duration: motion(context, Dur.standard),
                curve: Curves.easeOutCubic,
                child: AnimatedSwitcher(
                  duration: motion(context, Dur.standard),
                  transitionBuilder: (child, a) => FadeTransition(
                    opacity: a,
                    child: SlideTransition(
                      position: Tween(begin: const Offset(0, .3), end: Offset.zero).animate(a),
                      child: child,
                    ),
                  ),
                  child: showMini
                      ? MiniPlayer(key: const ValueKey('mini'), app: app)
                      : const SizedBox(key: ValueKey('none'), width: double.infinity),
                ),
              ),
              NavigationBar(
                selectedIndex: app.tab,
                onDestinationSelected: (i) {
                  HapticFeedback.selectionClick();
                  app.selectTab(i);
                },
                destinations: [
                  NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: tr('Start')),
                  NavigationDestination(icon: Icon(Icons.search_rounded), selectedIcon: Icon(Icons.manage_search_rounded), label: tr('Szukaj')),
                  NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music_rounded), label: tr('Biblioteka')),
                  if (app.radio != null) NavigationDestination(icon: Icon(Icons.radio_outlined), selectedIcon: Icon(Icons.radio_rounded), label: tr('Radio')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final LibraryScreenState app;
  const _Header({required this.app});
  @override
  Widget build(BuildContext context) {
    final route = app.route;
    final root = !app.canGoBack;
    final actions = <Widget>[
      // Full screen visualization one tap away while something plays.
      if (route.page == 'home' && app.current != null)
        IconAction(Icons.blur_on_rounded, tr('Wizualizacja'), app.openVisualizer, size: 22, box: 48),
      if (route.page == 'home' || route.page == 'radio') DeviceButton(app: app, size: 22),
      if (route.page == 'library')
        Builder(
          builder: (context) => IconAction(Icons.add_rounded, tr('Dodaj źródło'), () => app.showAddMusic(), size: 24, box: 48),
        ),
      if (route.page == 'playlist' && app.playlistById(route.arg) != null)
        IconAction(Icons.more_vert_rounded, tr('Więcej'), () => app.playlistMenu(app.playlistById(route.arg)!), size: 22, box: 48),
      if (root && route.page != 'settings')
        IconAction(Icons.settings_outlined, tr('Ustawienia'), () => app.go(const Nav('settings')), size: 22, box: 48, color: secondaryText),
    ];
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
        child: Row(
          children: [
            if (!root)
              IconAction(Icons.arrow_back_rounded, tr('Wstecz'), app.back, size: 24, box: 48)
            else
              const SizedBox(width: Sp.m),
            if (root && route.page == 'home')
              const Expanded(child: Align(alignment: Alignment.centerLeft, child: MytifyBrand(size: 28)))
            else
              Expanded(
                child: Text(
                    // Album, artist and playlist names live in the page header; the bar stays quiet.
                    root || route.page == 'settings' || route.page == 'transfer'
                        ? pageTitle(app, route)
                        : '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: root ? Txt.display.copyWith(fontSize: 24) : Txt.title.copyWith(fontSize: 18),
                ),
              ),
            ...actions,
          ],
        ),
      ),
    );
  }
}
