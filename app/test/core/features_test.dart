import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/core/features.dart';
import 'package:loopland/core/sdk_config.dart';

void main() {
  const allLocal = {
    'ALIYUN_AUTH_SECRET_ANDROID': 's',
    'ALIYUN_AUTH_SECRET_IOS': 's',
    'WECHAT_APP_ID': 'wx',
    'WECHAT_UNIVERSAL_LINK': 'https://x/wx/',
    'ALIYUN_CAPTCHA_PREFIX': 'p',
    'ALIYUN_CAPTCHA_SCENE_ID': 'scene',
  };
  final android = SdkConfig.fromMap(allLocal, platform: 'android', release: true);
  final ios = SdkConfig.fromMap(allLocal, platform: 'ios', release: true);

  test('parses /v1/config/features tolerantly', () {
    final f = ServerFeatures.fromJson({
      'login': ['sms', 'wechat'],
      'pay': ['alipay_app'],
      'captcha': true,
    });
    expect(f.login, {'sms', 'wechat'});
    expect(f.pay, {'alipay_app'});
    expect(f.captcha, isTrue);
    expect(f.fetched, isTrue);
    final empty = ServerFeatures.fromJson({'login': 'oops'});
    expect(empty.login, isEmpty);
    expect(empty.captcha, isFalse);
  });

  test('login buttons = local config ∩ server list', () {
    final f = ServerFeatures.fromJson({
      'login': ['sms', 'wechat', 'apple'],
    });
    final o = loginOptions(f, android);
    expect(o.oneClick, isFalse, reason: 'server does not list oneclick');
    expect(o.wechat, isTrue);
    expect(o.apple, isFalse, reason: 'Apple only on iOS');
    expect(o.sms, isTrue);
    expect(loginOptions(f, ios).apple, isTrue);

    final unconfigured = SdkConfig.fromMap(const {}, platform: 'android', release: true);
    final all = ServerFeatures.fromJson({
      'login': ['sms', 'wechat', 'oneclick'],
    });
    expect(loginOptions(all, unconfigured).wechat, isFalse, reason: 'missing local key hides it');
    expect(loginOptions(all, unconfigured).oneClick, isFalse);
  });

  test('network failure → SMS only', () {
    const f = ServerFeatures.unreachable();
    final o = loginOptions(f, android);
    expect([o.oneClick, o.wechat, o.apple], [false, false, false]);
    expect(o.sms, isTrue);
    expect(loginOptions(null, android).wechat, isFalse, reason: 'still loading counts as unreachable');
  });

  test('payment channels = platform/local ∩ server; iOS only Apple IAP', () {
    final f = ServerFeatures.fromJson({
      'pay': ['alipay_app', 'apple_iap', 'mock'],
    });
    expect(payChannels(f, android), ['alipay_app'], reason: 'wechat_app not listed; mock needs a dev build');
    expect(payChannels(f, ios), ['apple_iap']);
    final dev = SdkConfig.fromMap({...allLocal, 'LOOPLAND_ENV': 'dev'}, platform: 'android', release: true);
    expect(payChannels(f, dev), ['alipay_app', 'mock']);
    expect(payChannels(const ServerFeatures.unreachable(), android), ['wechat_app', 'alipay_app'],
        reason: 'unreachable → local list; creating the order reports the network error');
  });

  test('captcha shown only when the server asks and the client is configured', () {
    final on = ServerFeatures.fromJson({'captcha': true});
    final off = ServerFeatures.fromJson({'captcha': false});
    final none = SdkConfig.fromMap(const {}, platform: 'android');
    expect(captchaMode(off, android), CaptchaMode.skip);
    expect(captchaMode(on, android), CaptchaMode.show);
    expect(captchaMode(on, none), CaptchaMode.misconfigured);
    expect(captchaMode(off, none), CaptchaMode.skip, reason: 'dev: no scene id, server off → skip');
    expect(captchaMode(const ServerFeatures.unreachable(captcha: true), android), CaptchaMode.show);
  });
}
