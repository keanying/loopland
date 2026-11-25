import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'config_keys.dart';

/// Every key / ID / environment URL the app reads at build time.
///
/// Single source: `config/app.yaml` (+ gitignored `config/app.local.yaml`).
/// `dart run tool/gen_config.dart --profile <p>` turns it into
/// `config/<p>.json` for `--dart-define-from-file`, plus the native
/// `android/loopland.properties` / `ios/Flutter/Loopland.xcconfig` (AMap
/// Android meta-data, iOS URL schemes, associated domains). A lone
/// `--dart-define` still overrides the file. Nothing here is ever checked in
/// with a real value; without any define the [ConfigFallbacks] apply.
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
    this.amapNavigationUrl = ConfigFallbacks.amapNavigationUrl,
    this.captchaJsUrl = ConfigFallbacks.captchaJsUrl,
    this.captchaPageUrl = ConfigFallbacks.captchaPageUrl,
    this.configProfile = '',
  });

  /// All dart-define names, in the order of the generated `config/<p>.json`.
  static const keys = dartDefineKeys;

  /// 协议页面地址：`<apiBase>/legal/<page>`（page = terms | privacy）。
  static String legalUrl(String apiBase, String page) {
    var b = apiBase.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return '$b/legal/$page';
  }

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
        'API_BASE': String.fromEnvironment('API_BASE'),
        'USER_AGREEMENT_URL': String.fromEnvironment('USER_AGREEMENT_URL'),
        'PRIVACY_POLICY_URL': String.fromEnvironment('PRIVACY_POLICY_URL'),
        'AMAP_NAVIGATION_URL': String.fromEnvironment('AMAP_NAVIGATION_URL'),
        'ALIYUN_CAPTCHA_JS_URL': String.fromEnvironment('ALIYUN_CAPTCHA_JS_URL'),
        'ALIYUN_CAPTCHA_PAGE_URL': String.fromEnvironment('ALIYUN_CAPTCHA_PAGE_URL'),
        'LOOPLAND_CONFIG_PROFILE': String.fromEnvironment('LOOPLAND_CONFIG_PROFILE'),
      }, platform: currentPlatform, release: kReleaseMode);

  /// Parses a `config/<profile>.json` style map. Values are trimmed;
  /// non-string values are stringified; unknown keys are ignored.
  factory SdkConfig.fromMap(Map<String, Object?> m, {String platform = 'other', bool release = false}) {
    // Unfilled placeholders (`<...>`) count as missing.
    String s(String k) {
      final v = '${m[k] ?? ''}'.trim();
      return v.startsWith('<') && v.endsWith('>') ? '' : v;
    }

    String or(String k, String fallback) => s(k).isEmpty ? fallback : s(k);

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
      // 没单独配置时跟随 App 的接口地址：后端在 /legal/terms、/legal/privacy 提供协议页面
      // （上线后可在 nginx 把 /legal/ 转给后端，或在 app.yaml 的 links 里配独立地址）。
      userAgreementUrl: or('USER_AGREEMENT_URL', legalUrl(or('API_BASE', ConfigFallbacks.apiBase), 'terms')),
      privacyPolicyUrl: or('PRIVACY_POLICY_URL', legalUrl(or('API_BASE', ConfigFallbacks.apiBase), 'privacy')),
      amapNavigationUrl: or('AMAP_NAVIGATION_URL', ConfigFallbacks.amapNavigationUrl),
      captchaJsUrl: or('ALIYUN_CAPTCHA_JS_URL', ConfigFallbacks.captchaJsUrl),
      captchaPageUrl: or('ALIYUN_CAPTCHA_PAGE_URL', ConfigFallbacks.captchaPageUrl),
      configProfile: s('LOOPLAND_CONFIG_PROFILE'),
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

  /// AMap URI API base (`amap.navigation_url`).
  final String amapNavigationUrl;

  /// Aliyun captcha 2.0 web SDK (`aliyun.captcha_js_url`) and the origin the
  /// captcha WebView page is loaded under (`aliyun.captcha_page_url`).
  final String captchaJsUrl;
  final String captchaPageUrl;

  /// The `config/app.yaml` profile the build was generated from; empty when
  /// built without `--dart-define-from-file` (fallback defaults).
  final String configProfile;
  bool get fromConfigFile => configProfile.isNotEmpty;

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

  /// WeChat Pay for physical services (订场 / 报名费), allowed on iOS too.
  bool get offerWechatPayAnyPlatform => isMobile && _offer(wechatConfigured);

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
          const SdkCheck('支付宝 URL Scheme', true, note: 'config/app.yaml 的 alipay.url_scheme（生成到 Loopland.xcconfig）'),
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

  /// Without `--dart-define-from-file=config/<p>.json` the app still runs on
  /// [ConfigFallbacks] (localhost / 10.0.2.2, env prod); this says how to get
  /// the real config. Returns the message (null when a file was used).
  String? logSource({void Function(String)? log}) {
    if (fromConfigFile) return null;
    const msg = '[loopland/config] 未加载 config/<profile>.json，使用内置默认值'
        '（API http://localhost:8080，Android 模拟器 http://10.0.2.2:8080）。'
        '请运行 dart run tool/gen_config.dart --profile dev，'
        '再 flutter run --dart-define-from-file=config/dev.json';
    (log ?? (m) => developer.log(m, name: 'loopland.config'))(msg);
    return msg;
  }

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
