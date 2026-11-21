import 'dart:async';

import 'package:ali_auth/ali_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/auth/one_click.dart';
import 'package:loopland/core/sdk_config.dart';

/// Replays the ali_auth event protocol: listener attached (500004), env
/// check (600024), auth page (600001), then [afterPage].
class FakeAliAuth implements AliAuthBackend {
  FakeAliAuth({this.env = '600024', this.afterPage = const []});
  final String env;
  final List<Map<String, dynamic>> afterPage;
  final ctrl = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <String>[];
  AliAuthModel? model;

  @override
  Stream<Map<String, dynamic>> events() {
    scheduleMicrotask(() => ctrl.add({'code': '500004'}));
    return ctrl.stream;
  }

  @override
  Future<void> init(AliAuthModel m) async {
    calls.add('init');
    model = m;
    scheduleMicrotask(() => ctrl.add({'code': env, 'msg': 'env'}));
  }

  @override
  Future<void> checkEnv() async => calls.add('checkEnv');

  @override
  Future<void> login({int timeout = 5000}) async {
    calls.add('login');
    scheduleMicrotask(() {
      ctrl.add({'code': '600001'});
      for (final e in afterPage) {
        ctrl.add(e);
      }
    });
  }

  @override
  Future<void> quit() async => calls.add('quit');
}

final configured = SdkConfig.fromMap(const {
  'ALIYUN_AUTH_SECRET_ANDROID': 'android-secret',
  'ALIYUN_AUTH_SECRET_IOS': 'ios-secret',
  'USER_AGREEMENT_URL': 'https://x/terms',
  'PRIVACY_POLICY_URL': 'https://x/privacy',
}, platform: 'android', release: true);

void main() {
  test('token from 600000 is returned', () async {
    final f = FakeAliAuth(afterPage: [
      {'code': '700002'},
      {'code': '600000', 'data': 'carrier-token'},
    ]);
    final r = await OneClickLogin(backend: f, config: configured).run();
    expect(r.end, OneClickEnd.token);
    expect(r.token, 'carrier-token');
    expect(f.calls, ['init', 'login', 'quit']);
    expect(f.model!.androidSk, 'android-secret');
    expect(f.model!.iosSk, 'ios-secret');
  });

  test('no SIM / cellular off → unavailable (falls back to SMS), no crash', () async {
    for (final code in ['600007', '600008', '600013']) {
      final f = FakeAliAuth(env: code);
      final r = await OneClickLogin(backend: f, config: configured).run();
      expect(r.end, OneClickEnd.unavailable, reason: code);
      expect(r.message, contains('验证码'));
      expect(f.calls, isNot(contains('login')));
    }
  });

  test('「其他手机号登录」→ useSms; back → cancelled', () async {
    expect((await OneClickLogin(backend: FakeAliAuth(afterPage: [{'code': '700001'}]), config: configured).run()).end,
        OneClickEnd.useSms);
    expect((await OneClickLogin(backend: FakeAliAuth(afterPage: [{'code': '700000'}]), config: configured).run()).end,
        OneClickEnd.cancelled);
  });

  test('token failure after the page opened → unavailable and the page is closed', () async {
    final f = FakeAliAuth(afterPage: [{'code': '600011', 'msg': '获取token失败'}]);
    final r = await OneClickLogin(backend: f, config: configured).run();
    expect(r.end, OneClickEnd.unavailable);
    expect(f.calls.last, 'quit');
  });

  test('SDK never answers → times out as unavailable', () async {
    final f = FakeAliAuth(env: '600016'); // only a prefetch event, no env result
    final r = await OneClickLogin(backend: f, config: configured, envTimeout: const Duration(milliseconds: 50)).run();
    expect(r.end, OneClickEnd.unavailable);
  });

  test('not configured: dev uses dev:<phone>, prod is unavailable without touching the SDK', () async {
    final f = FakeAliAuth();
    final dev = await OneClickLogin(backend: f, config: SdkConfig.fromMap(const {'LOOPLAND_ENV': 'dev'}, platform: 'android')).run();
    expect(dev.token, OneClickLogin.devToken);
    final prod = await OneClickLogin(backend: f, config: SdkConfig.fromMap(const {}, platform: 'android')).run();
    expect(prod.end, OneClickEnd.unavailable);
    expect(f.calls, isEmpty);
  });

  test('authorisation page uses the brand colours and our agreements', () {
    final m = OneClickLogin.brandModel(configured).toJson();
    expect(m['backgroundColor'], '#0E0E10');
    expect(m['logBtnBackgroundColor'], '#DCF26A');
    expect(m['protocolOneURL'], 'https://x/terms');
    expect(m['protocolTwoURL'], 'https://x/privacy');
    expect(m['privacyState'], isFalse, reason: '协议不能默认勾选');
    expect(m['isDelay'], isTrue);
  });
}
