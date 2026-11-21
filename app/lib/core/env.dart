import 'package:flutter/foundation.dart';

import 'sdk_config.dart';

/// Build-time configuration via `--dart-define` (see `config/*.json.example`).
/// SDK keys live in [SdkConfig]; this class keeps the app-level switches.
class Env {
  Env._();

  static const _apiBase = String.fromEnvironment('API_BASE');

  /// `dev` enables the mock payment channel, fixed SMS code hints, the
  /// 「环境检查」page and the `dev:` credentials when an SDK is not configured.
  static String get env => SdkConfig.current.env;
  static bool get isDev => SdkConfig.current.isDev;

  static String get amapIosKey => SdkConfig.current.amapIosKey;
  static String get amapAndroidKey => SdkConfig.current.amapAndroidKey;

  /// Version string sent to `/v1/me/consents` and stored with the local
  /// first-launch privacy consent.
  static const privacyVersion = '2026-11';

  static bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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
  static String get amapKey => SdkConfig.current.amapKey;
}
