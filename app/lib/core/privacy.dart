import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/common.dart';
import 'env.dart';
import 'providers.dart';
import 'sdk_config.dart';
import 'theme.dart';

/// First-launch privacy dialog (个人信息保护指引). 工信部 / 高德 / 微信 / 阿里云
/// compliance: no third-party SDK may initialise, and no location may be
/// read, before the user agreed. The agreement is stored locally with the
/// policy version; a new version asks again.
///
/// `null` = not loaded yet, `false` = must ask, `true` = agreed.
final launchPrivacyProvider = NotifierProvider<LaunchPrivacy, bool?>(LaunchPrivacy.new);

class LaunchPrivacy extends Notifier<bool?> {
  static const key = 'privacy_launch_version';

  /// Set from [SdkBootstrap] so that agreeing initialises the SDKs.
  static void Function()? onAgreed;

  /// Process-wide flag read by code that has no `ref` (location source,
  /// map). Mirrors the provider state.
  static bool agreed = false;

  @override
  bool? build() => null;

  Future<void> load() async {
    String? v;
    try {
      v = await ref.read(kvCacheProvider).read(key);
    } catch (_) {}
    _set(v == Env.privacyVersion);
  }

  Future<void> accept() async {
    try {
      await ref.read(kvCacheProvider).write(key, Env.privacyVersion);
    } catch (_) {}
    _set(true);
  }

  Future<void> revoke() async {
    try {
      await ref.read(kvCacheProvider).remove(key);
    } catch (_) {}
    _set(false);
  }

  void _set(bool v) {
    agreed = v;
    state = v;
    if (v) onAgreed?.call();
  }
}

/// Opens 用户协议 / 隐私政策 (URLs from `USER_AGREEMENT_URL` /
/// `PRIVACY_POLICY_URL`) in an in-app browser.
Future<void> openLegal(BuildContext context, {required bool privacy}) async {
  final c = SdkConfig.current;
  final url = privacy ? c.privacyPolicyUrl : c.userAgreementUrl;
  if (url.isEmpty) {
    toast(context, privacy ? '未配置隐私政策链接（PRIVACY_POLICY_URL）' : '未配置用户协议链接（USER_AGREEMENT_URL）');
    return;
  }
  var ok = false;
  try {
    ok = await launchUrl(Uri.parse(url), mode: LaunchMode.inAppBrowserView);
  } catch (_) {}
  if (!ok && context.mounted) toast(context, '无法打开链接');
}

/// The page shown on first launch before anything else.
class LaunchPrivacyPage extends ConsumerWidget {
  const LaunchPrivacyPage({super.key});

  Future<void> _decline(BuildContext context) async {
    final again = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('温馨提示'),
        content: const Text('不同意《隐私政策》将无法使用圈圈的圈地、运动记录和登录功能。你可以再看看，或退出应用。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('退出应用', style: TextStyle(color: LL.text2))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('再看看')),
        ],
      ),
    );
    if (again == false) await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = const TextStyle(color: LL.lime, fontWeight: FontWeight.w700);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('欢迎使用圈圈', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: LLCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text(
                      '我们非常重视你的个人信息保护。在使用前，请阅读并同意《用户协议》和《隐私政策》：\n\n'
                      '· 位置信息与行踪轨迹（敏感个人信息）：仅在你开始户外运动、查看附近领地时使用，用于圈地判定和排名；\n'
                      '· 设备信息：用于账号安全和防作弊（识别模拟器、Root/越狱、应用多开）；\n'
                      '· 第三方 SDK：高德地图（地图与定位）、阿里云号码认证（一键登录）、阿里云验证码（人机验证）、'
                      '微信、支付宝、Apple（登录与支付）。这些 SDK 只会在你同意后初始化。\n\n'
                      '你可以随时在「设置」中撤回授权、导出或删除数据、注销账号。',
                      style: TextStyle(color: LL.text2, height: 1.7),
                    ),
                    const SizedBox(height: 12),
                    Wrap(spacing: 16, children: [
                      TextButton(onPressed: () => openLegal(context, privacy: false), child: Text('《用户协议》', style: link)),
                      TextButton(onPressed: () => openLegal(context, privacy: true), child: Text('《隐私政策》', style: link)),
                    ]),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => ref.read(launchPrivacyProvider.notifier).accept(),
              child: const Text('同意并继续'),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: () => _decline(context), child: const Text('不同意', style: TextStyle(color: LL.text2))),
          ]),
        ),
      ),
    );
  }
}
