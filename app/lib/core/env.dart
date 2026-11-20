import 'package:flutter/foundation.dart';

/// Build-time configuration via `--dart-define`.
class Env {
  Env._();

  static const _apiBase = String.fromEnvironment('API_BASE');

  /// `dev` enables the mock payment channel and fixed SMS code hints.
  static const env = String.fromEnvironment('LOOPLAND_ENV', defaultValue: 'prod');
  static bool get isDev => env == 'dev';

  static const amapIosKey = String.fromEnvironment('AMAP_IOS_KEY');
  static const amapAndroidKey = String.fromEnvironment('AMAP_ANDROID_KEY');

  static const wechatAppId = String.fromEnvironment('WECHAT_APP_ID');
  static const wechatUniversalLink = String.fromEnvironment('WECHAT_UNIVERSAL_LINK');
  static const alipayAppId = String.fromEnvironment('ALIPAY_APP_ID');

  /// Version string sent to `/v1/me/consents`.
  static const privacyVersion = '2026-11';

  static bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// `ios | android` as the API expects in `platform` / `X-Platform`.
  static String get platform => isIOS ? 'ios' : 'android';

  /// API base: `--dart-define=API_BASE=...`, else the Android emulator host
  /// alias, else localhost.
  static String get apiBase {
    if (_apiBase.isNotEmpty) return _apiBase;
    if (isAndroid) return 'http://10.0.2.2:8080';
    return 'http://localhost:8080';
  }

  /// The AMap key for the current platform; empty means "use the fallback map".
  static String get amapKey {
    if (isIOS) return amapIosKey;
    if (isAndroid) return amapAndroidKey;
    return '';
  }
}
