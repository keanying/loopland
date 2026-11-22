import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/core/providers.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/widgets/nav_shell.dart';
import 'package:material_ui/material_ui.dart';

import '../api/fixtures.dart';
import 'fake_backend.dart';
import 'test_helpers.dart';

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
    await t.pumpAndSettle();
    expect(find.text('我的页'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/nav_bar.png');

    await t.tap(find.bySemanticsLabel('开始'));
    await t.pumpAndSettle();
    expect(find.text('开始页'), findsOneWidget);
    await settle(t);
  });
}
