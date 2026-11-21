import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/auth/captcha.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/core/features.dart';
import 'package:loopland/core/providers.dart';
import 'package:loopland/core/sdk_config.dart';
import 'package:loopland/features/login/phone_code_form.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api_client_test.dart' show FakeAdapter;
import '../widgets/test_helpers.dart';

class FakeCaptcha implements CaptchaService {
  FakeCaptcha(this.result);
  final String? result;
  var shown = 0;
  @override
  Future<String?> verify(BuildContext context) async {
    shown++;
    return result;
  }
}

void main() {
  final saved = SdkConfig.current;
  tearDown(() => SdkConfig.current = saved);

  Future<({FakeAdapter adapter, FakeCaptcha captcha})> pump(WidgetTester t,
      {required ServerFeatures features, required SdkConfig config, String? captchaResult = 'CAPTCHA-PARAM'}) async {
    SdkConfig.current = config;
    final adapter = FakeAdapter((o) => o.path == '/v1/auth/sms/send' ? (200, {'cooldown_s': 60}) : (404, {}));
    final captcha = FakeCaptcha(captchaResult);
    await t.pumpWidget(wrap(
      Scaffold(body: PhoneCodeForm(submitLabel: '登录', onSubmit: (_, _) async {})),
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(tokens: MemoryTokenStore(), baseUrl: 'http://x', adapter: adapter)),
        featuresProvider.overrideWith((ref) async => features),
        captchaServiceProvider.overrideWithValue(captcha),
      ],
    ));
    await t.enterText(find.byType(TextField).first, '13800138000');
    await t.tap(find.text('获取验证码'));
    await t.pumpAndSettle();
    return (adapter: adapter, captcha: captcha);
  }

  List<Map> smsBodies(FakeAdapter a) =>
      [for (final r in a.requests.where((r) => r.path == '/v1/auth/sms/send')) r.data as Map];

  final withScene = SdkConfig.fromMap(const {'ALIYUN_CAPTCHA_PREFIX': 'pfx', 'ALIYUN_CAPTCHA_SCENE_ID': 'scene'}, platform: 'android');
  final devNoScene = SdkConfig.fromMap(const {'LOOPLAND_ENV': 'dev'}, platform: 'android');

  testWidgets('captcha=false (or dev without scene id): skipped, no captcha_token', (t) async {
    for (final cfg in [withScene, devNoScene]) {
      final r = await pump(t, features: ServerFeatures.fromJson({'login': ['sms'], 'captcha': false}), config: cfg);
      expect(r.captcha.shown, 0);
      expect(smsBodies(r.adapter), [
        {'phone': '13800138000'}
      ]);
      await settle(t);
    }
  });

  testWidgets('captcha=true: captchaVerifyParam is sent as captcha_token', (t) async {
    final r = await pump(t, features: ServerFeatures.fromJson({'captcha': true}), config: withScene);
    expect(r.captcha.shown, 1);
    expect(smsBodies(r.adapter), [
      {'phone': '13800138000', 'captcha_token': 'CAPTCHA-PARAM'}
    ]);
    expect(find.text('60s'), findsOneWidget);
    await settle(t);
  });

  testWidgets('captcha closed by the user → no SMS request', (t) async {
    final r = await pump(t, features: ServerFeatures.fromJson({'captcha': true}), config: withScene, captchaResult: null);
    expect(r.captcha.shown, 1);
    expect(smsBodies(r.adapter), isEmpty);
    expect(find.text('获取验证码'), findsOneWidget);
    await settle(t);
  });

  testWidgets('server requires captcha but the app has no scene id → clear error, no SMS', (t) async {
    final r = await pump(t, features: ServerFeatures.fromJson({'captcha': true}), config: devNoScene);
    expect(r.captcha.shown, 0);
    expect(smsBodies(r.adapter), isEmpty);
    expect(find.textContaining('人机验证未配置'), findsOneWidget);
    await settle(t);
  });

  test('captcha page escapes config values into the JS', () {
    final html = captchaHtml(prefix: 'p"x</script>', sceneId: 'scene-1');
    expect(html, contains('region:"cn"'));
    expect(html, contains(r'prefix:"p\"x\u003c/script>"'));
    expect(html.indexOf('</script>'), greaterThan(html.indexOf('region:"cn"')), reason: 'no early </script>');
    expect(html, contains('SceneId:"scene-1"'));
    expect(html, contains('LooplandCaptcha.postMessage'));
    expect(html, contains('src="https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js"'));
  });

  test('captcha SDK URL comes from config and is attribute-escaped', () {
    final html = captchaHtml(prefix: 'p', sceneId: 's', jsUrl: 'https://cdn.test/a.js?x="1"&y=2');
    expect(html, contains('src="https://cdn.test/a.js?x=&quot;1&quot;&amp;y=2"'));
  });
}
