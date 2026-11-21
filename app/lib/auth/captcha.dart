import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api/errors.dart';
import '../core/features.dart';
import '../core/sdk_config.dart';
import '../core/theme.dart';
import '../widgets/common.dart';

/// 阿里云验证码 2.0（人机验证），无 SDK 接入：a WebView hosts Aliyun's
/// captcha JS (`AliyunCaptchaConfig` region cn + prefix, `initAliyunCaptcha`
/// with the scene id) and returns `captchaVerifyParam` over a JS channel. The
/// server verifies it with VerifyIntelligentCaptcha (CaptchaVerifyParam).
///
/// The scene must use the "V3 架构" (verification submitted together with the
/// business request — the `success(captchaVerifyParam)` callback).
abstract class CaptchaService {
  /// The `captchaVerifyParam`, or null if the user closed the page.
  /// Throws [ApiException] when the captcha could not load.
  Future<String?> verify(BuildContext context);
}

final captchaServiceProvider = Provider<CaptchaService>((ref) => WebCaptchaService());

class WebCaptchaService implements CaptchaService {
  @override
  Future<String?> verify(BuildContext context) async {
    final r = await Navigator.of(context).push<_CaptchaResult>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => CaptchaPage(config: SdkConfig.current)),
    );
    if (r == null) return null;
    if (r.error != null) throw ApiException(status: 0, code: 'captcha_unavailable', message: r.error);
    return r.param;
  }
}

/// What `POST /v1/auth/sms/send` gets as `captcha_token`: null = skip
/// (server does not ask for it), a string = the verify param. Returns
/// `(proceed: false)` when the user closed the captcha.
Future<({bool proceed, String? token})> captchaForSms(BuildContext context, WidgetRef ref) async {
  ServerFeatures? f;
  try {
    f = await ref.read(featuresProvider.future);
  } catch (_) {}
  if (!context.mounted) return (proceed: false, token: null);
  switch (captchaMode(f, SdkConfig.current)) {
    case CaptchaMode.skip:
      return (proceed: true, token: null);
    case CaptchaMode.misconfigured:
      throw ApiException(
          status: 0, code: 'captcha_unavailable', message: '人机验证未配置（ALIYUN_CAPTCHA_PREFIX / ALIYUN_CAPTCHA_SCENE_ID），暂时无法发送验证码');
    case CaptchaMode.show:
      final t = await ref.read(captchaServiceProvider).verify(context);
      return (proceed: t != null && t.isNotEmpty, token: t);
  }
}

class _CaptchaResult {
  const _CaptchaResult({this.param, this.error});
  final String? param;
  final String? error;
}

/// A JS string literal that is also safe inside an inline `<script>`.
String _js(String v) => jsonEncode(v).replaceAll('<', r'\u003c');

/// The page hosted in the WebView. Prefix and scene id are JSON-encoded (and
/// `<` escaped) so a config value can never break out of the script.
String captchaHtml({required String prefix, required String sceneId}) => '''
<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>
html,body{margin:0;background:#0E0E10;color:#F4F4F5;font-family:-apple-system,"PingFang SC","Noto Sans SC",sans-serif}
#wrap{display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;padding:0 16px;box-sizing:border-box}
#captcha-element{width:100%;max-width:340px}
#captcha-button{display:none}
.tip{color:#8A8A94;font-size:13px;margin-top:20px}
</style>
<script>
function post(m){try{LooplandCaptcha.postMessage(JSON.stringify(m));}catch(e){}}
window.AliyunCaptchaConfig={region:"cn",prefix:${_js(prefix)}};
</script>
<script src="https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js" onerror="post({type:'error',message:'load'})"></script>
</head><body>
<div id="wrap"><div id="captcha-element"></div><button id="captcha-button"></button>
<div class="tip">完成验证后将自动发送短信验证码</div></div>
<script>
var captcha;
function start(){
  if(typeof initAliyunCaptcha!=='function'){post({type:'error',message:'sdk'});return;}
  initAliyunCaptcha({
    SceneId:${_js(sceneId)},
    mode:'embed',
    element:'#captcha-element',
    button:'#captcha-button',
    success:function(p){post({type:'success',param:p});},
    fail:function(r){post({type:'fail',message:JSON.stringify(r||{})});},
    getInstance:function(i){captcha=i;},
    slideStyle:{width:320,height:40},
    language:'cn'
  });
}
window.addEventListener('load',start);
</script>
</body></html>
''';

class CaptchaPage extends StatefulWidget {
  const CaptchaPage({super.key, required this.config});
  final SdkConfig config;
  @override
  State<CaptchaPage> createState() => _CaptchaPageState();
}

class _CaptchaPageState extends State<CaptchaPage> {
  late final WebViewController _web;
  bool _loading = true;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(LL.night)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame == true) _finish(const _CaptchaResult(error: '人机验证加载失败，请检查网络后重试'));
        },
      ))
      ..addJavaScriptChannel('LooplandCaptcha', onMessageReceived: _onMessage)
      ..loadHtmlString(captchaHtml(prefix: widget.config.captchaPrefix, sceneId: widget.config.captchaSceneId),
          baseUrl: 'https://captcha.loopland.local/');
  }

  void _onMessage(JavaScriptMessage m) {
    Map<String, dynamic> msg;
    try {
      msg = (jsonDecode(m.message) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'success':
        final p = '${msg['param'] ?? ''}';
        if (p.isNotEmpty) _finish(_CaptchaResult(param: p));
      case 'error':
        _finish(const _CaptchaResult(error: '人机验证加载失败，请检查网络后重试'));
      case 'fail':
        if (mounted) toast(context, '验证未通过，请再试一次');
    }
  }

  void _finish(_CaptchaResult r) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop(r);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('安全验证'), backgroundColor: LL.night),
      backgroundColor: LL.night,
      body: Stack(children: [
        WebViewWidget(controller: _web),
        if (_loading) const Center(child: CircularProgressIndicator()),
      ]),
    );
  }
}
