// Pure Dart (no Flutter imports): shared by the app and `tool/gen_config.dart`.

/// Every `--dart-define` the app reads, in the order `tool/gen_config.dart`
/// writes them into `config/<profile>.json`. The values come from
/// `config/app.yaml` (+ `config/app.local.yaml`); see app/README.md.
const dartDefineKeys = [
  'LOOPLAND_ENV',
  'LOOPLAND_CONFIG_PROFILE',
  'API_BASE',
  'WS_URL',
  'USER_AGREEMENT_URL',
  'PRIVACY_POLICY_URL',
  'WECHAT_APP_ID',
  'WECHAT_UNIVERSAL_LINK',
  'ALIPAY_APP_ID',
  'ALIPAY_UNIVERSAL_LINK',
  'AMAP_ANDROID_KEY',
  'AMAP_IOS_KEY',
  'AMAP_STYLE_DATA',
  'AMAP_STYLE_EXTRA_DATA',
  'AMAP_NAVIGATION_URL',
  'ALIYUN_AUTH_SECRET_ANDROID',
  'ALIYUN_AUTH_SECRET_IOS',
  'ALIYUN_CAPTCHA_PREFIX',
  'ALIYUN_CAPTCHA_SCENE_ID',
  'ALIYUN_CAPTCHA_JS_URL',
  'ALIYUN_CAPTCHA_PAGE_URL',
];

/// Fallbacks used only when the app is built without
/// `--dart-define-from-file=config/<profile>.json`. They must equal the
/// `shared` values in `config/app.yaml` (a test checks this).
abstract final class ConfigFallbacks {
  /// `api.base_url` of the dev profile; the Android emulator reaches the
  /// host machine through 10.0.2.2 instead.
  static const apiBase = 'http://localhost:8080';
  static const apiBaseAndroidEmulator = 'http://10.0.2.2:8080';
  static const amapNavigationUrl = 'https://uri.amap.com/navigation';
  static const captchaJsUrl = 'https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js';
  static const captchaPageUrl = 'https://captcha.loopland.local/';
}

/// The WebSocket endpoint derived from a REST base: `http → ws`,
/// `https → wss`, same host / port / base path, plus `/v1/ws`.
String deriveWsUrl(String apiBase) {
  final b = Uri.parse(apiBase.trim());
  final scheme = b.scheme == 'https' ? 'wss' : 'ws';
  final path = b.path.endsWith('/') ? b.path.substring(0, b.path.length - 1) : b.path;
  return Uri(
    scheme: scheme,
    userInfo: b.userInfo.isEmpty ? null : b.userInfo,
    host: b.host,
    port: b.hasPort ? b.port : null,
    path: '$path/v1/ws',
  ).toString();
}
