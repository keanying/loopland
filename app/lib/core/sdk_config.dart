import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Every key / ID the app reads at build time.
///
/// Values come from `--dart-define` or `--dart-define-from-file=config/prod.json`
/// (see `config/*.json.example`). Nothing here is ever checked in with a real
/// value. Native-only values (AMap Android meta-data, iOS URL schemes,
/// associated domains) live in `android/loopland.properties` and
/// `ios/Flutter/Loopland.xcconfig` instead.
class SdkConfig {
  const SdkConfig({
    this.env = 'prod',
    this.platform = 'other',
    this.release = false,
    this.aliyunAuthSecretAndroid = '',
    this.aliyunAuthSecretIos = '',
    this.wechatAppId = '',
    this.wechatUniversalLink = '',
    this.alipayAppId = '',
    this.alipayUniversalLink = '',
    this.amapAndroidKey = '',
    this.amapIosKey = '',
    this.amapStyleData = '',
    this.amapStyleExtraData = '',
    this.captchaPrefix = '',
    this.captchaSceneId = '',
    this.userAgreementUrl = '',
    this.privacyPolicyUrl = '',
  });

  /// All dart-define names, in the order of `config/*.json.example`.
  static const keys = [
    'LOOPLAND_ENV',
    'API_BASE',
    'ALIYUN_AUTH_SECRET_ANDROID',
    'ALIYUN_AUTH_SECRET_IOS',
    'WECHAT_APP_ID',
    'WECHAT_UNIVERSAL_LINK',
    'ALIPAY_APP_ID',
    'ALIPAY_UNIVERSAL_LINK',
    'AMAP_ANDROID_KEY',
    'AMAP_IOS_KEY',
    'AMAP_STYLE_DATA',
    'AMAP_STYLE_EXTRA_DATA',
    'ALIYUN_CAPTCHA_PREFIX',
    'ALIYUN_CAPTCHA_SCENE_ID',
    'USER_AGREEMENT_URL',
    'PRIVACY_POLICY_URL',
  ];

  /// Reads the compile-time `--dart-define`s. `String.fromEnvironment` must be
  /// called with constant names, hence the explicit list.
  factory SdkConfig.fromEnvironment() => SdkConfig.fromMap(const {
        'LOOPLAND_ENV': String.fromEnvironment('LOOPLAND_ENV', defaultValue: 'prod'),
        'ALIYUN_AUTH_SECRET_ANDROID': String.fromEnvironment('ALIYUN_AUTH_SECRET_ANDROID'),
        'ALIYUN_AUTH_SECRET_IOS': String.fromEnvironment('ALIYUN_AUTH_SECRET_IOS'),
        'WECHAT_APP_ID': String.fromEnvironment('WECHAT_APP_ID'),
        'WECHAT_UNIVERSAL_LINK': String.fromEnvironment('WECHAT_UNIVERSAL_LINK'),
        'ALIPAY_APP_ID': String.fromEnvironment('ALIPAY_APP_ID'),
        'ALIPAY_UNIVERSAL_LINK': String.fromEnvironment('ALIPAY_UNIVERSAL_LINK'),
        'AMAP_ANDROID_KEY': String.fromEnvironment('AMAP_ANDROID_KEY'),
        'AMAP_IOS_KEY': String.fromEnvironment('AMAP_IOS_KEY'),
        'AMAP_STYLE_DATA': String.fromEnvironment('AMAP_STYLE_DATA'),
        'AMAP_STYLE_EXTRA_DATA': String.fromEnvironment('AMAP_STYLE_EXTRA_DATA'),
        'ALIYUN_CAPTCHA_PREFIX': String.fromEnvironment('ALIYUN_CAPTCHA_PREFIX'),
        'ALIYUN_CAPTCHA_SCENE_ID': String.fromEnvironment('ALIYUN_CAPTCHA_SCENE_ID'),
        'USER_AGREEMENT_URL': String.fromEnvironment('USER_AGREEMENT_URL'),
        'PRIVACY_POLICY_URL': String.fromEnvironment('PRIVACY_POLICY_URL'),
      }, platform: currentPlatform, release: kReleaseMode);

  /// Parses a `config/*.json` style map. Values are trimmed; non-string values
  /// are stringified; unknown keys are ignored.
  factory SdkConfig.fromMap(Map<String, Object?> m, {String platform = 'other', bool release = false}) {
    String s(String k) => '${m[k] ?? ''}'.trim();
    final env = s('LOOPLAND_ENV');
    return SdkConfig(
      env: env.isEmpty ? 'prod' : env,
      platform: platform,
      release: release,
      aliyunAuthSecretAndroid: s('ALIYUN_AUTH_SECRET_ANDROID'),
      aliyunAuthSecretIos: s('ALIYUN_AUTH_SECRET_IOS'),
      wechatAppId: s('WECHAT_APP_ID'),
      wechatUniversalLink: s('WECHAT_UNIVERSAL_LINK'),
      alipayAppId: s('ALIPAY_APP_ID'),
      alipayUniversalLink: s('ALIPAY_UNIVERSAL_LINK'),
      amapAndroidKey: s('AMAP_ANDROID_KEY'),
      amapIosKey: s('AMAP_IOS_KEY'),
      amapStyleData: s('AMAP_STYLE_DATA'),
      amapStyleExtraData: s('AMAP_STYLE_EXTRA_DATA'),
      captchaPrefix: s('ALIYUN_CAPTCHA_PREFIX'),
      captchaSceneId: s('ALIYUN_CAPTCHA_SCENE_ID'),
      userAgreementUrl: s('USER_AGREEMENT_URL'),
      privacyPolicyUrl: s('PRIVACY_POLICY_URL'),
    );
  }

  static String get currentPlatform {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      _ => 'other',
    };
  }

  /// The config the app runs with. Tests replace it.
  static SdkConfig current = SdkConfig.fromEnvironment();

  final String env;

  /// `ios | android | web | other`.
  final String platform;

  /// Release build: missing keys hide the feature instead of showing an error.
  final bool release;

  final String aliyunAuthSecretAndroid;
  final String aliyunAuthSecretIos;
  final String wechatAppId;
  final String wechatUniversalLink;
  final String alipayAppId;
  final String alipayUniversalLink;
  final String amapAndroidKey;
  final String amapIosKey;

  /// Flutter asset paths of the AMap console's exported custom style
  /// (`style.data` / `style_extra.data`).
  final String amapStyleData;
  final String amapStyleExtraData;
  final String captchaPrefix;
  final String captchaSceneId;
  final String userAgreementUrl;
  final String privacyPolicyUrl;

  bool get isDev => env == 'dev';
  bool get isIOS => platform == 'ios';
  bool get isAndroid => platform == 'android';
  bool get isMobile => isIOS || isAndroid;

  String get oneClickSecret => isIOS ? aliyunAuthSecretIos : (isAndroid ? aliyunAuthSecretAndroid : '');
  String get amapKey => isIOS ? amapIosKey : (isAndroid ? amapAndroidKey : '');

  bool get oneClickConfigured => isMobile && oneClickSecret.isNotEmpty;

  /// iOS additionally needs the universal link (WeChat SDK ≥ 1.8.6).
  bool get wechatConfigured => wechatAppId.isNotEmpty && (!isIOS || wechatUniversalLink.isNotEmpty);
  bool get amapConfigured => isMobile && amapKey.isNotEmpty;
  bool get amapStyleConfigured => amapStyleData.isNotEmpty;

  /// The order string comes from the server; the client needs no key. On iOS
  /// the URL scheme is native config (xcconfig), which Dart cannot see.
  bool get alipayConfigured => isAndroid || isIOS;
  bool get captchaConfigured => captchaPrefix.isNotEmpty && captchaSceneId.isNotEmpty;
  bool get legalUrlsConfigured => userAgreementUrl.isNotEmpty && privacyPolicyUrl.isNotEmpty;

  /// The dev backend accepts `dev:` credentials; only used when the real SDK
  /// is not configured.
  bool get oneClickDevFallback => isDev && !oneClickConfigured;
  bool get wechatDevFallback => isDev && !wechatConfigured;

  /// Whether the button/channel may be offered at all (local view; the
  /// server's `/v1/config/features` is intersected on top, see features.dart).
  ///
  /// In release builds a missing key hides the option. In debug/profile
  /// builds it stays visible so the developer sees a clear error.
  bool _offer(bool configured, {bool devFallback = false}) => configured || devFallback || !release;

  bool get offerOneClick => _offer(oneClickConfigured, devFallback: oneClickDevFallback) && (isMobile || isDev);
  bool get offerWechat => _offer(wechatConfigured, devFallback: wechatDevFallback);
  bool get offerApple => isIOS || isDev;
  bool get offerAlipayPay => isAndroid && alipayConfigured;
  bool get offerWechatPay => isAndroid && _offer(wechatConfigured);
  bool get offerAppleIap => isIOS;

  /// Required keys for a production build of the current platform.
  List<SdkCheck> checks() => [
        SdkCheck('阿里云号码认证（一键登录）', oneClickConfigured,
            missing: [isIOS ? 'ALIYUN_AUTH_SECRET_IOS' : 'ALIYUN_AUTH_SECRET_ANDROID'],
            note: oneClickDevFallback ? '开发环境：使用 dev:13800138000' : null),
        SdkCheck('微信登录 / 支付（fluwx）', wechatConfigured,
            missing: ['WECHAT_APP_ID', if (isIOS) 'WECHAT_UNIVERSAL_LINK'],
            note: wechatDevFallback ? '开发环境：使用 dev:wx-demo-user' : null),
        if (isAndroid) SdkCheck('支付宝（tobias）', true, note: '无需客户端密钥；ALIPAY_APP_ID 可选（风控优化）'),
        if (isIOS)
          const SdkCheck('支付宝 URL Scheme', true, note: '在 ios/Flutter/Loopland.xcconfig 配置 ALIPAY_URL_SCHEME'),
        SdkCheck('高德地图', amapConfigured,
            missing: [isIOS ? 'AMAP_IOS_KEY' : 'AMAP_ANDROID_KEY'], note: amapConfigured ? null : '使用内置备用地图'),
        SdkCheck('高德暗色自定义样式', amapStyleConfigured,
            required: false, missing: ['AMAP_STYLE_DATA'], note: amapStyleConfigured ? null : '使用内置 night 样式'),
        SdkCheck('阿里云人机验证 2.0', captchaConfigured,
            missing: ['ALIYUN_CAPTCHA_PREFIX', 'ALIYUN_CAPTCHA_SCENE_ID'],
            note: captchaConfigured ? null : '未配置：发送短信前跳过人机验证'),
        SdkCheck('用户协议 / 隐私政策链接', legalUrlsConfigured, missing: ['USER_AGREEMENT_URL', 'PRIVACY_POLICY_URL']),
        if (isIOS) const SdkCheck('Sign in with Apple / 内购', true, note: '需在 Xcode 打开对应 Capability'),
      ];

  /// Logs every missing required key. Called once at start; never throws.
  List<SdkCheck> logMissing({void Function(String)? log}) {
    final missing = checks().where((c) => c.required && !c.configured).toList();
    for (final c in missing) {
      final msg = '[loopland/config] ${c.name} 未配置（缺少 ${c.missing.join(', ')}），'
          '${release ? '已隐藏对应入口' : '调试包仍显示入口'}';
      (log ?? (m) => developer.log(m, name: 'loopland.config'))(msg);
    }
    return missing;
  }
}

class SdkCheck {
  const SdkCheck(this.name, this.configured, {this.missing = const [], this.note, this.required = true});
  final String name;
  final bool configured;
  final List<String> missing;
  final String? note;
  final bool required;
}
