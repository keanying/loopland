import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Pop-ups (bottom sheets, menus…) open inside the five tab pages. While any
/// is open the floating bottom bar slides away, so it never covers a sheet
/// opened from 领地 / 图鉴 / 开始 / 社区 / 我的.
class NavBarCover extends ChangeNotifier {
  final _open = <Route<dynamic>>{};

  bool get covered => _open.isNotEmpty;

  // Navigator callbacks can run in the middle of a build: notify after it.
  void _changed() => scheduleMicrotask(notifyListeners);

  void add(Route<dynamic> r) {
    if (_open.add(r)) _changed();
  }

  void remove(Route<dynamic> r) {
    if (_open.remove(r)) _changed();
  }
}

final navBarCoverProvider = Provider<NavBarCover>((ref) {
  final c = NavBarCover();
  ref.onDispose(c.dispose);
  return c;
});

/// Attached to each tab's navigator (StatefulShellBranch.observers; one
/// instance per navigator). Reports the pop-up routes pushed on it.
class NavBarCoverObserver extends NavigatorObserver {
  NavBarCoverObserver(this.cover);
  final NavBarCover cover;

  void _add(Route<dynamic>? r) {
    if (r is PopupRoute) cover.add(r);
  }

  void _remove(Route<dynamic>? r) {
    if (r != null) cover.remove(r);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _remove(oldRoute);
    _add(newRoute);
  }
}
