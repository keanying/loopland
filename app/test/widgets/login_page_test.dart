import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/features/login/login_page.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_backend.dart';
import 'test_helpers.dart';

void main() {
  setUpAll(loadFonts);

  testWidgets('login page: buttons, agreement gate, screenshot', (t) async {
    LoginPage.enableVideo = false;
    await phone(t);
    await t.pumpWidget(RepaintBoundary(key: const Key('shot'), child: wrap(const LoginPage(), overrides: fakeBackend())));
    await t.pump();

    expect(find.text('跑一圈，\n就是你的地'), findsOneWidget);
    expect(find.text('本机号码一键登录'), findsOneWidget);
    expect(find.text('微信登录'), findsOneWidget);
    expect(find.text('其他手机号登录 / 注册'), findsOneWidget);

    // Not agreed yet → a dialog asks first; declining keeps the user here.
    await t.tap(find.text('本机号码一键登录'));
    await t.pumpAndSettle();
    expect(find.textContaining('请阅读并同意'), findsOneWidget);
    await t.tap(find.text('不同意'));
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsNothing);

    // Tap the agreement row → checkbox checked.
    await t.tap(find.textContaining('我已阅读并同意'));
    await t.pump();
    expect(find.byIcon(Icons.check), findsOneWidget);

    await t.runAsync(() => precacheImage(const AssetImage('assets/media/login-poster.jpg'), t.element(find.byType(LoginPage))));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/login.png');
    await settle(t);
  });
}
