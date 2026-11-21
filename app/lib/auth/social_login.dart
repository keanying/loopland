import 'dart:async';

import 'package:fluwx/fluwx.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../api/errors.dart';
import '../core/privacy.dart';
import '../core/sdk_config.dart';

/// WeChat login & pay via fluwx.
///
/// `registerApi` runs only after the first-launch privacy agreement
/// ([SdkBootstrap]), with `WECHAT_APP_ID` / `WECHAT_UNIVERSAL_LINK`.
/// Android: fluwx's manifest already declares `${applicationId}.wxapi.
/// WXEntryActivity` / `WXPayEntryActivity` (activity-alias) and the
/// `com.tencent.mm` package query. iOS: URL type = AppID and
/// LSApplicationQueriesSchemes in Info.plist, associated domain in
/// Runner.entitlements (both from ios/Flutter/Loopland.xcconfig).
class WeChat {
  WeChat._();
  static final fluwx = Fluwx();
  static bool _registered = false;

  static SdkConfig get _c => SdkConfig.current;
  static bool get configured => _c.wechatConfigured;

  static const notInstalled = '未安装微信，请安装微信后再试，或选择其他方式';

  static Future<void> ensureRegistered() async {
    if (_registered || !configured || !LaunchPrivacy.agreed) return;
    try {
      _registered = await fluwx.registerApi(
        appId: _c.wechatAppId,
        universalLink: _c.wechatUniversalLink.isEmpty ? null : _c.wechatUniversalLink,
      );
    } catch (_) {
      _registered = false;
    }
  }

  /// Throws a friendly [ApiException] when WeChat cannot be used.
  static Future<void> ensureReady() async {
    if (!configured) {
      throw ApiException(status: 0, code: 'provider_error', message: '微信暂未开通，请选择其他方式');
    }
    await ensureRegistered();
    bool installed;
    try {
      installed = await fluwx.isWeChatInstalled;
    } catch (_) {
      installed = false;
    }
    if (!installed) throw ApiException(status: 0, code: 'wechat_not_installed', message: notInstalled);
  }

  static Future<T> _await<T extends WeChatResponse>(Future<bool> Function() start) async {
    await ensureReady();
    final done = Completer<T>();
    final cancel = fluwx.addSubscriber((r) {
      if (r is T && !done.isCompleted) done.complete(r);
    });
    try {
      final ok = await start();
      if (!ok) throw ApiException(status: 0, code: 'provider_error', message: '无法打开微信');
      return await done.future.timeout(const Duration(minutes: 5));
    } finally {
      cancel.cancel();
    }
  }

  /// Returns the auth `code` for `/v1/auth/login` (provider=wechat).
  /// Without an AppID in a dev build the dev backend's `dev:<openid>` is used.
  static Future<String?> authCode() async {
    if (_c.wechatDevFallback) return 'dev:wx-demo-user';
    final r = await _await<WeChatAuthResponse>(
        () => fluwx.authBy(which: NormalAuth(scope: 'snsapi_userinfo', state: 'loopland')));
    if (r.errCode == -2) return null; // user cancelled
    if (!r.isSuccessful) {
      throw ApiException(status: 0, code: 'provider_error', message: '微信授权失败（${r.errCode}）');
    }
    return r.code;
  }

  /// Launches WeChat Pay with the server's pay_params, field for field.
  /// Returns the SDK's errCode: 0 success, -2 cancelled, other = failed.
  static Future<int> pay(Map<String, dynamic> p) async {
    final r = await _await<WeChatPaymentResponse>(() => fluwx.pay(which: wechatPayment(p)));
    return r.errCode ?? -1;
  }
}

/// `pay_params` → fluwx [Payment]. Every value is passed through unchanged
/// (the server signed exactly these strings).
Payment wechatPayment(Map<String, dynamic> p) {
  const fields = ['appid', 'partnerid', 'prepayid', 'package', 'noncestr', 'timestamp', 'sign'];
  final missing = fields.where((k) => '${p[k] ?? ''}'.isEmpty).toList();
  final ts = int.tryParse('${p['timestamp']}');
  if (missing.isNotEmpty || ts == null) {
    throw ApiException(status: 0, code: 'provider_error', message: '微信支付参数不完整（${missing.join(', ')}）');
  }
  return Payment(
    appId: '${p['appid']}',
    partnerId: '${p['partnerid']}',
    prepayId: '${p['prepayid']}',
    packageValue: '${p['package']}',
    nonceStr: '${p['noncestr']}',
    timestamp: ts,
    sign: '${p['sign']}',
  );
}

/// Sign in with Apple → `{"identity_token","nickname"}`.
Future<Map<String, dynamic>?> appleCredential() async {
  final c = SdkConfig.current;
  if (c.isDev && !c.isIOS) return {'identity_token': 'dev:apple-demo-user', 'nickname': 'Apple 测试'};
  try {
    final cred = await SignInWithApple.getAppleIDCredential(scopes: [AppleIDAuthorizationScopes.fullName]);
    final token = cred.identityToken;
    if (token == null) return null;
    final name = [cred.familyName, cred.givenName].whereType<String>().join();
    return {'identity_token': token, if (name.isNotEmpty) 'nickname': name};
  } on SignInWithAppleAuthorizationException catch (e) {
    if (e.code == AuthorizationErrorCode.canceled) return null;
    throw ApiException(status: 0, code: 'provider_error', message: 'Apple 登录失败：${e.message}');
  }
}
