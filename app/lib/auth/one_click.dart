import 'dart:async';

import 'package:ali_auth/ali_auth.dart';
import 'package:ali_auth/ali_auth_platform_interface.dart';

import '../core/sdk_config.dart';

/// Thin seam over the `ali_auth` plugin (阿里云号码认证 / 一键登录) so the
/// event protocol can be tested with a fake.
abstract class AliAuthBackend {
  /// Plugin events: `{"code": "600000", "msg": "...", "data": "<token>"}`.
  Stream<Map<String, dynamic>> events();
  Future<void> init(AliAuthModel model);
  Future<void> checkEnv();
  Future<void> login({int timeout = 5000});
  Future<void> quit();
}

class PluginAliAuthBackend implements AliAuthBackend {
  @override
  Stream<Map<String, dynamic>> events() => (AliAuth.onChange() ?? const Stream.empty())
      .map((e) => e is Map ? e.map((k, v) => MapEntry('$k', v)) : <String, dynamic>{'code': '$e'});
  @override
  Future<void> init(AliAuthModel model) async => AliAuth.initSdk(model);
  @override
  Future<void> checkEnv() => AliAuthPlatform.instance.checkEnvAvailable();
  @override
  Future<void> login({int timeout = 5000}) async => AliAuth.login(timeout: timeout);
  @override
  Future<void> quit() => AliAuth.quitPage();
}

enum OneClickEnd {
  /// [OneClickOutcome.token] holds the carrier token.
  token,

  /// User closed the authorisation page.
  cancelled,

  /// User tapped 「其他手机号登录」.
  useSms,

  /// No SIM / Wi-Fi only / carrier maintenance / SDK error / not configured.
  unavailable,
}

class OneClickOutcome {
  const OneClickOutcome._(this.end, {this.token, this.message = '', this.code = ''});
  const OneClickOutcome.token(String t) : this._(OneClickEnd.token, token: t);
  const OneClickOutcome.cancelled() : this._(OneClickEnd.cancelled);
  const OneClickOutcome.useSms() : this._(OneClickEnd.useSms);
  const OneClickOutcome.unavailable(String message, {String code = ''})
      : this._(OneClickEnd.unavailable, message: message, code: code);

  final OneClickEnd end;
  final String? token;
  final String message;
  final String code;
}

/// Why one-click is not possible, per Aliyun result code (PNSReturnCode /
/// ResultCode). Everything here makes the app fall back to SMS.
const oneClickReasons = {
  '500000': '未配置号码认证秘钥',
  '500005': '当前环境不支持一键登录',
  '600002': '授权页拉起失败',
  '600004': '获取运营商配置失败',
  '600005': '手机终端不安全',
  '600007': '未检测到 SIM 卡',
  '600008': '蜂窝网络未开启',
  '600009': '无法判断运营商',
  '600010': '未知异常',
  '600011': '获取登录凭证失败',
  '600013': '运营商维护升级中',
  '600014': '运营商维护升级中',
  '600015': '请求超时',
  '600017': '号码认证秘钥无效',
  '600021': '运营商已切换',
  '600025': '终端环境检查失败',
};

/// 本机号码一键登录 with the `ali_auth` plugin. The SDK secret (号码认证方案
/// 秘钥, different per platform) comes from `ALIYUN_AUTH_SECRET_ANDROID` /
/// `ALIYUN_AUTH_SECRET_IOS`. The returned token goes to `POST /v1/auth/login`
/// with `provider=oneclick` (or `/v1/me/phone` as `oneclick_token`).
class OneClickLogin {
  OneClickLogin({AliAuthBackend? backend, SdkConfig? config, this.envTimeout = const Duration(seconds: 12)})
      : _backend = backend ?? PluginAliAuthBackend(),
        _config = config ?? SdkConfig.current;

  final AliAuthBackend _backend;
  final SdkConfig _config;
  final Duration envTimeout;

  /// The dev backend accepts `dev:<phone>` as a carrier token.
  static const devToken = 'dev:13800138000';

  /// Android's plugin keeps its helper after the first `initSdk` and only
  /// refreshes the UI on later calls, so the environment check has to be
  /// triggered explicitly from the second run on.
  static bool _initialisedOnce = false;

  bool get offered => _config.offerOneClick;

  /// Shows the carrier authorisation page. Never throws.
  Future<OneClickOutcome> run() async {
    final c = _config;
    if (!c.oneClickConfigured) {
      if (c.oneClickDevFallback) return const OneClickOutcome.token(devToken);
      return const OneClickOutcome.unavailable('本机号码一键登录暂未开通，请使用验证码登录', code: 'not_configured');
    }
    final done = Completer<OneClickOutcome>();
    final listening = Completer<void>();
    var loginRequested = false, pageShown = false;
    Timer? timer;

    void finish(OneClickOutcome o) {
      if (!done.isCompleted) done.complete(o);
    }

    void fail(String code, [String? msg]) {
      final reason = oneClickReasons[code] ?? (msg == null || msg.isEmpty ? '一键登录失败' : msg);
      finish(OneClickOutcome.unavailable('$reason，请使用验证码登录', code: code));
    }

    void arm(Duration d) {
      timer?.cancel();
      timer = Timer(d, () => fail('timeout', '一键登录超时'));
    }

    final sub = _backend.events().listen((e) {
      final code = '${e['code'] ?? ''}';
      switch (code) {
        case '500004': // listener attached
          if (!listening.isCompleted) listening.complete();
        case '600024': // 终端支持认证
          if (!loginRequested) {
            loginRequested = true;
            _backend.login(timeout: 5000).catchError((Object _) => fail('600002'));
          }
        case '600001': // 授权页已拉起 → the user now has as long as they need.
          pageShown = true;
          arm(const Duration(minutes: 10));
        case '600000':
          final t = '${e['data'] ?? ''}';
          t.isEmpty ? fail('600011') : finish(OneClickOutcome.token(t));
        case '700000':
          finish(const OneClickOutcome.cancelled());
        case '700001':
          finish(const OneClickOutcome.useSms());
        case '600016' || '600012' || '700002' || '700003' || '700004' || '700005' || '':
          break; // prefetch result / UI clicks
        default:
          fail(code, '${e['msg'] ?? ''}');
      }
    }, onError: (Object _) => fail('600010'));

    arm(envTimeout);
    try {
      // Android's initSdk refuses to run before the event listener is attached.
      await listening.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      await _backend.init(_model(c));
      if (_initialisedOnce && !done.isCompleted && !loginRequested) await _backend.checkEnv();
      _initialisedOnce = true;
    } catch (_) {
      fail('600010');
    }
    final r = await done.future;
    timer?.cancel();
    await sub.cancel();
    // The page stays open on token failure ("失败时也不关闭"), close it.
    if (pageShown && r.end != OneClickEnd.cancelled) {
      try {
        await _backend.quit();
      } catch (_) {}
    }
    return r;
  }

  /// The authorisation page in the brand colours (dark #0E0E10, primary
  /// #DCF26A), with 用户协议 / 隐私政策 next to the carrier's agreement.
  /// Exposed for tests.
  static AliAuthModel brandModel(SdkConfig c) => _model(c);

  static AliAuthModel _model(SdkConfig c) {
    const night = '#0E0E10', lime = '#DCF26A', text = '#F4F4F5', text2 = '#B5B5BE', text3 = '#8A8A94';
    return AliAuthModel(
      c.aliyunAuthSecretAndroid,
      c.aliyunAuthSecretIos,
      isDebug: !c.release,
      isDelay: true,
      pageType: PageType.fullPort,
      pageBackgroundPath: null,
      backgroundColor: night,
      statusBarColor: night,
      bottomNavColor: night,
      bottomNavBarColor: night,
      lightColor: false,
      navColor: night,
      navText: '',
      navTextColor: text,
      webNavColor: night,
      webNavTextColor: text,
      webViewStatusBarColor: night,
      logoImgPath: 'assets/brand/auth_logo.png',
      logoWidth: 72,
      logoHeight: 72,
      logoOffsetY: 40,
      sloganText: '圈一圈，共同运动，共同圈',
      sloganTextColor: text2,
      sloganOffsetY: 130,
      numberColor: text,
      numberSize: 28,
      numFieldOffsetY: 180,
      logBtnText: '本机号码一键登录',
      logBtnTextColor: '#121212',
      logBtnBackgroundColor: lime,
      logBtnCornerRadius: 26,
      logBtnTextBold: true,
      logBtnHeight: 52,
      logBtnMarginLeftAndRight: 24,
      logBtnOffsetY: 250,
      switchAccText: '其他手机号登录',
      switchAccTextColor: lime,
      switchAccHidden: false,
      switchCheck: false,
      switchOffsetY: 320,
      isHiddenCustom: true,
      protocolOneName: c.userAgreementUrl.isEmpty ? null : '《用户协议》',
      protocolOneURL: c.userAgreementUrl.isEmpty ? null : c.userAgreementUrl,
      protocolTwoName: c.privacyPolicyUrl.isEmpty ? null : '《隐私政策》',
      protocolTwoURL: c.privacyPolicyUrl.isEmpty ? null : c.privacyPolicyUrl,
      protocolColor: text3,
      protocolCustomColor: lime,
      protocolOwnColor: lime,
      protocolOwnOneColor: lime,
      protocolOwnTwoColor: lime,
      vendorPrivacyPrefix: '《',
      vendorPrivacySuffix: '》',
      privacyBefore: '我已阅读并同意',
      privacyEnd: '，未注册的手机号将自动创建圈圈账号',
      privacyTextSize: 12,
      privacyMargin: 28,
      privacyOffsetY_B: 36,
      // 合规：协议勾选框不能默认勾选。
      privacyState: false,
      toastText: '请先阅读并同意服务协议',
      toastBackground: '#E624242A',
      toastColor: '#FFF4F4F5',
      privacyAlertIsNeedShow: true,
      privacyAlertTitleContent: '请阅读并同意以下条款',
      privacyAlertTitleColor: text,
      privacyAlertTitleBackgroundColor: '#1B1B20',
      privacyAlertBackgroundColor: '#1B1B20',
      privacyAlertContentBackgroundColor: '#1B1B20',
      privacyAlertContentBaseColor: text2,
      privacyAlertContentColor: lime,
      privacyAlertOwnOneColor: lime,
      privacyAlertOwnTwoColor: lime,
      privacyAlertOperatorColor: lime,
      privacyAlertBtnText: '同意并登录',
      privacyAlertBtnTextColor: '#121212',
      privacyAlertCornerRadiusArray: const [16, 16, 16, 16],
      autoQuitPage: true,
      authPageUseDayLight: false,
    );
  }
}
