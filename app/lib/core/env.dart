import 'package:flutter/foundation.dart';

import 'config_keys.dart';
import 'sdk_config.dart';

/// App-level build-time switches. All values come from `config/app.yaml` via
/// `dart run tool/gen_config.dart` → `--dart-define-from-file=config/<p>.json`
/// (see app/README.md「配置」). SDK keys live in [SdkConfig].
class Env {
  Env._();

  static const _apiBase = String.fromEnvironment('API_BASE');
  static const _wsUrl = String.fromEnvironment('WS_URL');

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

  /// `API_BASE` (`api.base_url`). Fallback when built without the config
  /// file: the Android emulator's host alias, else localhost.
  static String get apiBase {
    if (_apiBase.isNotEmpty) return _apiBase;
    if (isAndroid) return ConfigFallbacks.apiBaseAndroidEmulator;
    return ConfigFallbacks.apiBase;
  }

  /// Explicit `WS_URL` (`api.ws_url`), or empty: then the WebSocket endpoint
  /// is derived from the REST base at runtime ([deriveWsUrl]), so a lone
  /// `--dart-define=API_BASE=…` moves the WebSocket too.
  static String get wsUrlOverride => _wsUrl;

  /// The effective WebSocket endpoint (shown on the 环境检查 page).
  static String get wsUrl => _wsUrl.isNotEmpty ? _wsUrl : deriveWsUrl(apiBase);

  /// The AMap key for the current platform; empty means "use the fallback map".
  static String get amapKey => SdkConfig.current.amapKey;
}
