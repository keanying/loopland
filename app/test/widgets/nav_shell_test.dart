import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/core/providers.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/widgets/nav_bar_cover.dart';
import 'package:loopland/widgets/nav_shell.dart';
import 'package:material_ui/material_ui.dart';

import '../api/fixtures.dart';
import 'test_helpers.dart';

/// The center button animates forever: pump fixed frames instead of pumpAndSettle.
Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadFonts);

  testWidgets('底栏：中间「开始」按钮（薰衣紫圆、荧光绿环、虚线外圈）切换到开始页', (t) async {
    await phone(t);
    Widget page(String name) => Container(
          color: LL.night,
          alignment: Alignment.center,
          child: Text(name, style: const TextStyle(fontSize: 28, color: LL.text)),
        );
    final router = GoRouter(initialLocation: '/me', routes: [
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => NavShell(shell: shell),
        branches: [
          for (final (path, name) in [('/map', '领地页'), ('/codex', '图鉴页'), ('/start', '开始页'), ('/community', '社区页'), ('/me', '我的页')])
            StatefulShellBranch(routes: [GoRoute(path: path, builder: (_, _) => page(name))]),
        ],
      ),
    ]);
    final codex = Codex.fromJson(j(codexJson));
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: ProviderScope(
        overrides: [codexProvider.overrideWith((ref) async => codex)],
        retry: (_, _) => null,
        child: MaterialApp.router(theme: buildTheme(), routerConfig: router, debugShowCheckedModeBanner: false),
      ),
    ));
    await frames(t);
    expect(find.text('我的页'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/nav_bar.png');

    await t.tap(find.bySemanticsLabel('开始'));
    await frames(t);
    expect(find.text('开始页'), findsOneWidget);
    await settle(t);
  });

  testWidgets('标签页里弹出底部面板时底栏收起，关掉后恢复', (t) async {
    await phone(t);
    final cover = NavBarCover();
    final router = GoRouter(initialLocation: '/map', routes: [
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => NavShell(shell: shell),
        branches: [
          for (final path in ['/map', '/codex', '/start', '/community', '/me'])
            StatefulShellBranch(observers: [
              NavBarCoverObserver(cover)
            ], routes: [
              GoRoute(
                path: path,
                builder: (context, _) => Center(
                  child: FilledButton(
                    onPressed: () => showModalBottomSheet<void>(
                        context: context, builder: (_) => const SizedBox(height: 300, child: Center(child: Text('领地详情')))),
                    child: Text('打开$path'),
                  ),
                ),
              ),
            ]),
        ],
      ),
    ]);
    await t.pumpWidget(ProviderScope(
      overrides: [codexProvider.overrideWith((ref) async => Codex.fromJson(j(codexJson))), navBarCoverProvider.overrideWithValue(cover)],
      retry: (_, _) => null,
      child: MaterialApp.router(theme: buildTheme(), routerConfig: router),
    ));
    await frames(t);
    bool hidden() => t.widget<IgnorePointer>(find.ancestor(of: find.bySemanticsLabel('开始'), matching: find.byType(IgnorePointer)).first).ignoring;
    expect(hidden(), isFalse);

    await t.tap(find.text('打开/map'));
    await frames(t);
    expect(find.text('领地详情'), findsOneWidget);
    expect(cover.covered, isTrue);
    expect(hidden(), isTrue);

    await t.tapAt(const Offset(195, 100)); // 点遮罩关掉面板
    await frames(t);
    expect(find.text('领地详情'), findsNothing);
    expect(cover.covered, isFalse);
    expect(hidden(), isFalse);
    await settle(t);
  });
}
