import 'dart:async';

import 'package:flutter/services.dart';
import 'package:fluwx/fluwx.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../api/errors.dart';
import '../core/env.dart';

/// 运营商一键登录（阿里云号码认证）。There is no official Flutter plugin, so
/// the native side is reached over a MethodChannel. The native handlers in
/// MainActivity.kt / AppDelegate.swift are TODO stubs until the Aliyun SDK is
/// integrated (see README).
class OneClickLogin {
  OneClickLogin([MethodChannel? channel]) : _ch = channel ?? const MethodChannel('loopland/oneclick');
  final MethodChannel _ch;

  /// The dev backend accepts `dev:<phone>` as a carrier token.
  static const devToken = 'dev:13800138000';

  /// Whether the carrier SDK is integrated and the SIM supports it.
  Future<bool> isAvailable() async {
    try {
      return await _ch.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Shows the carrier authorisation page and returns its token, or null if
  /// the user switched to "其他手机号登录".
  Future<String?> getToken() async {
    try {
      return await _ch.invokeMethod<String>('getToken');
    } on MissingPluginException {
      if (Env.isDev) return devToken;
      throw ApiException(status: 0, code: 'provider_error', message: '本机号码一键登录暂不可用，请使用验证码登录');
    } on PlatformException catch (e) {
      if (e.code == 'cancel') return null;
      if (Env.isDev && e.code == 'not_implemented') return devToken;
      throw ApiException(status: 0, code: 'provider_error', message: e.message ?? '一键登录失败，请使用验证码登录');
    }
  }
}

/// WeChat login & pay via fluwx.
class WeChat {
  WeChat._();
  static final fluwx = Fluwx();
  static bool _registered = false;

  static bool get configured => Env.wechatAppId.isNotEmpty;

  static Future<void> ensureRegistered() async {
    if (_registered || !configured) return;
    _registered = await fluwx.registerApi(
      appId: Env.wechatAppId,
      universalLink: Env.wechatUniversalLink.isEmpty ? null : Env.wechatUniversalLink,
    );
  }

  static Future<T> _await<T extends WeChatResponse>(Future<bool> Function() start) async {
    await ensureRegistered();
    if (!configured) {
      throw ApiException(status: 0, code: 'provider_error', message: '未配置微信 AppID（--dart-define=WECHAT_APP_ID）');
    }
    if (!await fluwx.isWeChatInstalled) {
      throw ApiException(status: 0, code: 'provider_error', message: '未安装微信');
    }
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
    if (!configured && Env.isDev) return 'dev:wx-demo-user';
    final r = await _await<WeChatAuthResponse>(
        () => fluwx.authBy(which: NormalAuth(scope: 'snsapi_userinfo', state: 'loopland')));
    if (!r.isSuccessful) return null; // user cancelled
    return r.code;
  }

  /// Launches WeChat Pay with the server's pay_params.
  static Future<bool> pay(Map<String, dynamic> p) async {
    final r = await _await<WeChatPaymentResponse>(() => fluwx.pay(
          which: Payment(
            appId: '${p['appid']}',
            partnerId: '${p['partnerid']}',
            prepayId: '${p['prepayid']}',
            packageValue: '${p['package'] ?? 'Sign=WXPay'}',
            nonceStr: '${p['noncestr']}',
            timestamp: int.tryParse('${p['timestamp']}') ?? 0,
            sign: '${p['sign']}',
          ),
        ));
    return r.isSuccessful;
  }
}

/// Sign in with Apple → `{"identity_token","nickname"}`.
Future<Map<String, dynamic>?> appleCredential() async {
  if (Env.isDev && !Env.isIOS) return {'identity_token': 'dev:apple-demo-user', 'nickname': 'Apple 测试'};
  try {
    final c = await SignInWithApple.getAppleIDCredential(scopes: [AppleIDAuthorizationScopes.fullName]);
    final token = c.identityToken;
    if (token == null) return null;
    final name = [c.familyName, c.givenName].whereType<String>().join();
    return {'identity_token': token, if (name.isNotEmpty) 'nickname': name};
  } on SignInWithAppleAuthorizationException catch (e) {
    if (e.code == AuthorizationErrorCode.canceled) return null;
    throw ApiException(status: 0, code: 'provider_error', message: 'Apple 登录失败：${e.message}');
  }
}
