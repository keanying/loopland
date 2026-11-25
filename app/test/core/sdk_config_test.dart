import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/core/config_keys.dart';
import 'package:loopland/core/sdk_config.dart';

import '../../tool/src/app_config.dart';

/// `config/<profile>.json` as tool/gen_config.dart would write it from the
/// committed config/app.yaml (no app.local.yaml).
Map<String, Object?> _generated(String profile, {Map<String, String> sets = const {}, bool allowEmptyKeys = false}) {
  final r = generate(
    app: parseYaml(File('config/app.yaml').readAsStringSync()),
    profile: profile,
    sets: sets,
    allowEmptyKeys: allowEmptyKeys,
  );
  expect(r.validation.errors, isEmpty);
  return (jsonDecode(r.files.first.content) as Map).cast<String, Object?>();
}

void main() {
  group('config/app.yaml → config/<profile>.json', () {
    test('generated JSON lists exactly the known dart-defines', () {
      final keys = _generated('dev').keys.where((k) => !k.startsWith('_')).toSet();
      expect(keys, SdkConfig.keys.toSet());
    });

    test('committed prod profile has no secrets and parses as "nothing configured"', () {
      final prod = _generated('prod', allowEmptyKeys: true);
      for (final k in ['ALIYUN_AUTH_SECRET_ANDROID', 'ALIYUN_AUTH_SECRET_IOS', 'WECHAT_APP_ID', 'AMAP_ANDROID_KEY',
          'AMAP_IOS_KEY', 'ALIYUN_CAPTCHA_PREFIX', 'ALIYUN_CAPTCHA_SCENE_ID']) {
        expect(prod[k], '', reason: k);
      }
      final c = SdkConfig.fromMap(prod, platform: 'android', release: true);
      expect(c.env, 'prod');
      expect(c.fromConfigFile, isTrue);
      expect(c.oneClickConfigured, isFalse);
      expect(c.wechatConfigured, isFalse);
      expect(c.amapConfigured, isFalse);
      expect(c.captchaConfigured, isFalse);
      // Non-secret values are kept.
      // 协议链接没单独配置：跟随接口地址
      expect(c.privacyPolicyUrl, SdkConfig.legalUrl(prod['API_BASE'] as String? ?? ConfigFallbacks.apiBase, 'privacy'));
      expect(c.userAgreementUrl, endsWith('/legal/terms'));
      expect(c.captchaJsUrl, ConfigFallbacks.captchaJsUrl);
    });

    test('dev profile enables dev fallbacks', () {
      final c = SdkConfig.fromMap(_generated('dev'), platform: 'android');
      expect(c.isDev, isTrue);
      expect(c.configProfile, 'dev');
      expect(c.oneClickDevFallback, isTrue);
      expect(c.wechatDevFallback, isTrue);
    });

    test('built-in fallbacks equal the app.yaml defaults', () {
      final dev = _generated('dev');
      expect(dev['API_BASE'], ConfigFallbacks.apiBase);
      expect(dev['AMAP_NAVIGATION_URL'], ConfigFallbacks.amapNavigationUrl);
      expect(dev['ALIYUN_CAPTCHA_JS_URL'], ConfigFallbacks.captchaJsUrl);
      expect(dev['ALIYUN_CAPTCHA_PAGE_URL'], ConfigFallbacks.captchaPageUrl);
      // An empty map (no --dart-define-from-file) uses the same values.
      final none = SdkConfig.fromMap(const {});
      expect(none.fromConfigFile, isFalse);
      expect(none.amapNavigationUrl, ConfigFallbacks.amapNavigationUrl);
      expect(none.captchaPageUrl, ConfigFallbacks.captchaPageUrl);
      final logs = <String>[];
      expect(none.logSource(log: logs.add), contains('tool/gen_config.dart'));
      expect(SdkConfig.fromMap(dev).logSource(log: logs.add), isNull);
      expect(logs, hasLength(1));
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
