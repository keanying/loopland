import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'sdk_config.dart';

/// `GET /v1/config/features` (no auth): what this deployment actually has
/// configured on the server side.
///
/// ```json
/// {"login": ["apple","oneclick","sms","wechat"],
///  "pay": ["alipay_app","apple_iap","mock","wechat_app"],
///  "captcha": true, "ai": true}
/// ```
class ServerFeatures {
  const ServerFeatures({required this.login, required this.pay, required this.captcha, this.ai = false, this.fetched = true});

  factory ServerFeatures.fromJson(Map<String, dynamic> j) {
    Set<String> set(Object? v) => v is List ? {for (final e in v) '$e'} : <String>{};
    return ServerFeatures(login: set(j['login']), pay: set(j['pay']), captcha: j['captcha'] == true, ai: j['ai'] == true);
  }

  /// Used when the request failed: SMS login only. [captcha] then follows the
  /// local config (sending a token the server does not need is harmless;
  /// skipping one it requires is not). Payment falls back to the local list —
  /// creating the order needs the network anyway and will report the error.
  const ServerFeatures.unreachable({this.captcha = false})
      : login = const {'sms'},
        pay = const {},
        ai = false,
        fetched = false;

  final Set<String> login;
  final Set<String> pay;
  final bool captcha;

  /// V2 batch 3: AI (assistant, routes, reports, coach) is configured. When
  /// false (or the server predates the flag) every AI entry is hidden.
  final bool ai;

  /// False for [ServerFeatures.unreachable].
  final bool fetched;
}

/// Cached for the session (not autoDispose). A failure yields
/// [ServerFeatures.unreachable] and is retried the next time a login screen
/// opens (see [refreshFeaturesIfUnreachable]).
final featuresProvider = FutureProvider<ServerFeatures>((ref) async {
  try {
    final raw = await ref.watch(apiClientProvider).get('/v1/config/features');
    return ServerFeatures.fromJson(raw is Map ? raw.cast<String, dynamic>() : const {});
  } catch (_) {
    return ServerFeatures.unreachable(captcha: SdkConfig.current.captchaConfigured);
  }
});

/// Show AI entries (assistant, 问 AI, AI routes / reports).
final aiEnabledProvider = Provider<bool>((ref) => ref.watch(featuresProvider).value?.ai ?? false);

void refreshFeaturesIfUnreachable(WidgetRef ref) {
  final v = ref.read(featuresProvider).value;
  if (v != null && !v.fetched) ref.invalidate(featuresProvider);
}

/// Login buttons to show: local key checks ∩ server list.
class LoginOptions {
  const LoginOptions({this.oneClick = false, this.wechat = false, this.apple = false, this.sms = true});
  final bool oneClick, wechat, apple, sms;
}

LoginOptions loginOptions(ServerFeatures? f, SdkConfig c) {
  final s = f ?? ServerFeatures.unreachable(captcha: c.captchaConfigured);
  return LoginOptions(
    oneClick: c.offerOneClick && s.login.contains('oneclick'),
    wechat: c.offerWechat && s.login.contains('wechat'),
    apple: c.offerApple && s.login.contains('apple'),
    // SMS is always offered: it is the fallback for every other method.
    sms: true,
  );
}

/// Payment channels in display order: local platform/key checks ∩ server.
/// iOS may only use Apple IAP (`X-Platform: ios` → other channels 400).
List<String> payChannels(ServerFeatures? f, SdkConfig c) {
  final local = [
    if (c.offerAppleIap) 'apple_iap',
    if (c.offerWechatPay) 'wechat_app',
    if (c.offerAlipayPay) 'alipay_app',
    if (c.isDev) 'mock',
  ];
  if (f == null || !f.fetched) return local;
  return [for (final ch in local) if (f.pay.contains(ch)) ch];
}

/// Channels for physical services (订场 E-03, 赛事报名费 D-12): WeChat Pay /
/// Alipay on Android **and iOS** (offline services are not IAP), `mock` in
/// dev; intersected with the server list like [payChannels].
List<String> servicePayChannels(ServerFeatures? f, SdkConfig c) {
  final local = [
    if (c.isMobile && c.offerWechatPayAnyPlatform) 'wechat_app',
    if (c.isMobile && c.alipayConfigured) 'alipay_app',
    if (c.isDev) 'mock',
  ];
  if (f == null || !f.fetched) return local;
  return [for (final ch in local) if (f.pay.contains(ch)) ch];
}

/// Show the captcha before `POST /v1/auth/sms/send` only when the server asks
/// for it and the client can actually render it.
enum CaptchaMode { skip, show, misconfigured }

CaptchaMode captchaMode(ServerFeatures? f, SdkConfig c) {
  final required = f == null ? c.captchaConfigured : f.captcha;
  if (!required) return CaptchaMode.skip;
  return c.captchaConfigured ? CaptchaMode.show : CaptchaMode.misconfigured;
}
