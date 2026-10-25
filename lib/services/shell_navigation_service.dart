import 'package:flutter/widgets.dart';

enum ShellTab { home, library, repository, settings, search }

class ShellNavigationService {
  static final searchRequests = ValueNotifier<int>(0);
  static final chromeBrightness = ValueNotifier<Brightness?>(null);
  static final chromeSurface = ValueNotifier<Color?>(null);
  static final _visiblePages = <GlobalKey<NavigatorState>, Route<dynamic>?>{};
  static final _chromeScopes =
      <
        Object,
        ({ModalRoute<dynamic> route, Brightness brightness, Color? surface})
      >{};
  static bool _chromeUpdateScheduled = false;
  static int _searchGeneration = 0;

  static void setChromeBrightness({
    required Object owner,
    required ModalRoute<dynamic> route,
    required Brightness brightness,
    Color? surface,
  }) {
    final scope = (route: route, brightness: brightness, surface: surface);
    if (_chromeScopes[owner] == scope) return;
    _chromeScopes[owner] = scope;
    _scheduleChromeUpdate();
  }

  static void clearChromeBrightness(Object owner) {
    _chromeScopes.remove(owner);
    _scheduleChromeUpdate();
  }

  static void _scheduleChromeUpdate() {
    if (_chromeUpdateScheduled) return;
    _chromeUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chromeUpdateScheduled = false;
      final activePage = _visiblePages[_activeTabNavigatorKey()];
      Brightness? brightness;
      Color? surface;
      for (final scope in _chromeScopes.values) {
        if (identical(scope.route, activePage)) {
          brightness = scope.brightness;
          surface = scope.surface;
        }
      }
      chromeBrightness.value = brightness;
      chromeSurface.value = surface;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  static void requestSearch() {
    if (!requestTab(ShellTab.search)) return;
    final generation = ++_searchGeneration;
    final owner = _tabSelectionOwner;
    // PageView creates Search lazily. Deliver the request after its navigator
    // and focus listener mount, rather than losing the first tap on another tab.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _searchGeneration ||
          !identical(owner, _tabSelectionOwner) ||
          _currentTabIndex != (_showSearchTab ? (_showRepoTab ? 3 : 2) : 0)) {
        return;
      }
      final navigatorKey = _showSearchTab
          ? searchTabNavigatorKey
          : homeTabNavigatorKey;
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
      searchRequests.value++;
      // Search scrolls to its field and requests focus after layout.
      // Scheduling that frame avoids waiting for another tap to wake it up.
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  static final GlobalKey<NavigatorState> homeTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> libraryTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> repoTabNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> searchTabNavigatorKey =
      GlobalKey<NavigatorState>();

  static int _currentTabIndex = 0;
  static bool _showRepoTab = false;
  static bool _showSearchTab = false;
  static Object? _tabSelectionOwner;
  static ValueChanged<ShellTab>? _tabSelectionHandler;

  static void registerTabSelectionHandler({
    required Object owner,
    required ValueChanged<ShellTab> handler,
  }) {
    _tabSelectionOwner = owner;
    _tabSelectionHandler = handler;
  }

  static void unregisterTabSelectionHandler(Object owner) {
    if (!identical(_tabSelectionOwner, owner)) return;
    _tabSelectionOwner = null;
    _tabSelectionHandler = null;
  }

  static bool requestTab(ShellTab tab) {
    final handler = _tabSelectionHandler;
    if (handler == null) return false;
    handler(tab);
    return true;
  }

  static void syncState({
    required int currentTabIndex,
    required bool showRepoTab,
    bool showSearchTab = false,
  }) {
    if (_currentTabIndex == currentTabIndex &&
        _showRepoTab == showRepoTab &&
        _showSearchTab == showSearchTab) {
      return;
    }
    _currentTabIndex = currentTabIndex;
    _showRepoTab = showRepoTab;
    _showSearchTab = showSearchTab;
    _scheduleChromeUpdate();
  }

  static GlobalKey<NavigatorState>? _activeTabNavigatorKey() {
    if (_currentTabIndex == 0) return homeTabNavigatorKey;
    if (_currentTabIndex == 1) return libraryTabNavigatorKey;
    if (_showRepoTab && _currentTabIndex == 2) {
      return repoTabNavigatorKey;
    }
    if (_showSearchTab && _currentTabIndex == (_showRepoTab ? 3 : 2)) {
      return searchTabNavigatorKey;
    }
    return null;
  }

  static NavigatorState? activeTabNavigator() =>
      _activeTabNavigatorKey()?.currentState;
}

/// Track the top page in each tab. Dialogs keep the underlying page's contrast;
/// a pushed album, another tab, or a back gesture restores its own appearance.
class ShellChromeObserver extends NavigatorObserver {
  ShellChromeObserver(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;
  final _routes = <Route<dynamic>>[];

  void _update() {
    Route<dynamic>? page;
    for (final route in _routes.reversed) {
      if (route is PageRoute<dynamic>) {
        page = route;
        break;
      }
    }
    ShellNavigationService._visiblePages[navigatorKey] = page;
    ShellNavigationService._scheduleChromeUpdate();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _update();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _update();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _update();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    }
    _update();
  }

  void detach() {
    _routes.clear();
    ShellNavigationService._visiblePages.remove(navigatorKey);
    ShellNavigationService._scheduleChromeUpdate();
  }
}
