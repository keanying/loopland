import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/core/sdk_config.dart';

Map<String, Object?> _example(String name) =>
    (jsonDecode(File('config/$name').readAsStringSync()) as Map).cast<String, Object?>();

void main() {
  group('config/*.json.example', () {
    for (final name in ['dev.json.example', 'prod.json.example']) {
      test('$name lists exactly the known dart-defines', () {
        expect(_example(name).keys.toSet(), SdkConfig.keys.toSet());
      });
    }

    test('templates contain no real-looking secrets', () {
      final prod = _example('prod.json.example');
      for (final k in ['ALIYUN_AUTH_SECRET_ANDROID', 'ALIYUN_AUTH_SECRET_IOS', 'WECHAT_APP_ID', 'AMAP_ANDROID_KEY',
          'AMAP_IOS_KEY', 'ALIYUN_CAPTCHA_PREFIX', 'ALIYUN_CAPTCHA_SCENE_ID']) {
        expect('${prod[k]}', startsWith('<'), reason: k);
      }
      final dev = _example('dev.json.example');
      expect(dev['ALIYUN_AUTH_SECRET_ANDROID'], '');
      expect(dev['WECHAT_APP_ID'], '');
    });

    test('unfilled prod template parses as "nothing configured"', () {
      final c = SdkConfig.fromMap(_example('prod.json.example'), platform: 'android', release: true);
      expect(c.env, 'prod');
      expect(c.oneClickConfigured, isFalse);
      expect(c.wechatConfigured, isFalse);
      expect(c.amapConfigured, isFalse);
      expect(c.captchaConfigured, isFalse);
      // Non-secret values are kept.
      expect(c.privacyPolicyUrl, 'https://loopland.example.com/legal/privacy');
      expect(c.amapStyleData, 'assets/map/style.data');
    });

    test('dev template enables dev fallbacks', () {
      final c = SdkConfig.fromMap(_example('dev.json.example'), platform: 'android');
      expect(c.isDev, isTrue);
      expect(c.oneClickDevFallback, isTrue);
      expect(c.wechatDevFallback, isTrue);
    });
  });

  test('parsing trims values, defaults env to prod and ignores unknown keys', () {
    final c = SdkConfig.fromMap({'LOOPLAND_ENV': ' ', 'WECHAT_APP_ID': '  wx123 ', 'NOPE': 'x', 'AMAP_IOS_KEY': 42});
    expect(c.env, 'prod');
    expect(c.wechatAppId, 'wx123');
    expect(c.amapIosKey, '42');
  });

  test('per-platform secret / key selection', () {
    const m = {
      'ALIYUN_AUTH_SECRET_ANDROID': 'A-SECRET',
      'ALIYUN_AUTH_SECRET_IOS': '',
      'AMAP_ANDROID_KEY': 'a-key',
      'AMAP_IOS_KEY': 'i-key',
    };
    final a = SdkConfig.fromMap(m, platform: 'android');
    final i = SdkConfig.fromMap(m, platform: 'ios');
    expect(a.oneClickSecret, 'A-SECRET');
    expect(a.oneClickConfigured, isTrue);
    expect(i.oneClickConfigured, isFalse, reason: 'iOS secret is separate');
    expect(a.amapKey, 'a-key');
    expect(i.amapKey, 'i-key');
    expect(SdkConfig.fromMap(m, platform: 'web').amapConfigured, isFalse);
  });

  test('WeChat on iOS also needs the universal link', () {
    const m = {'WECHAT_APP_ID': 'wx1'};
    expect(SdkConfig.fromMap(m, platform: 'android').wechatConfigured, isTrue);
    expect(SdkConfig.fromMap(m, platform: 'ios').wechatConfigured, isFalse);
    expect(SdkConfig.fromMap({...m, 'WECHAT_UNIVERSAL_LINK': 'https://x/wx/'}, platform: 'ios').wechatConfigured, isTrue);
  });

  test('release builds hide unconfigured options, debug builds keep them visible', () {
    final rel = SdkConfig.fromMap(const {}, platform: 'android', release: true);
    expect(rel.offerOneClick, isFalse);
    expect(rel.offerWechat, isFalse);
    expect(rel.offerWechatPay, isFalse);
    expect(rel.offerAlipayPay, isTrue, reason: 'Alipay needs no client key');

    final dbg = SdkConfig.fromMap(const {}, platform: 'android');
    expect(dbg.offerOneClick, isTrue);
    expect(dbg.offerWechat, isTrue);

    final devRel = SdkConfig.fromMap(const {'LOOPLAND_ENV': 'dev'}, platform: 'android', release: true);
    expect(devRel.offerOneClick, isTrue, reason: 'dev:<phone> fallback');
    expect(devRel.offerWechatPay, isFalse, reason: 'no dev fallback for real payments');
  });

  test('logMissing reports every required missing key and never throws', () {
    final logs = <String>[];
    final missing = SdkConfig.fromMap(const {}, platform: 'android', release: true).logMissing(log: logs.add);
    expect(missing.map((c) => c.name), containsAll(['阿里云号码认证（一键登录）', '微信登录 / 支付（fluwx）', '高德地图', '阿里云人机验证 2.0']));
    expect(missing.any((c) => c.name.contains('自定义样式')), isFalse, reason: 'style is optional');
    expect(logs.first, contains('ALIYUN_AUTH_SECRET_ANDROID'));
    expect(logs.first, contains('已隐藏'));

    final full = SdkConfig.fromMap(const {
      'ALIYUN_AUTH_SECRET_ANDROID': 's',
      'WECHAT_APP_ID': 'wx',
      'AMAP_ANDROID_KEY': 'k',
      'ALIYUN_CAPTCHA_PREFIX': 'p',
      'ALIYUN_CAPTCHA_SCENE_ID': 'sc',
      'USER_AGREEMENT_URL': 'u',
      'PRIVACY_POLICY_URL': 'p',
    }, platform: 'android', release: true);
    expect(full.logMissing(log: (_) {}), isEmpty);
  });
}
