import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../core/env.dart';
import '../../core/features.dart';
import '../../core/privacy.dart';
import '../../core/sdk_config.dart';
import '../../core/theme.dart';
import '../../map/amap_map.dart';
import '../../run/device.dart';
import '../../widgets/common.dart';

final _deviceProbeProvider = FutureProvider.autoDispose<DeviceInfo>((ref) => collectDevice('env-check'));

/// 环境检查（仅 LOOPLAND_ENV=dev）：which SDKs are configured, what the
/// server's `/v1/config/features` says, and the resulting login / payment
/// options.
class EnvCheckPage extends ConsumerWidget {
  const EnvCheckPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = SdkConfig.current;
    final features = ref.watch(featuresProvider);
    final f = features.value;
    final login = loginOptions(f, c);
    final device = ref.watch(_deviceProbeProvider);
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(featuresProvider);
            ref.invalidate(_deviceProbeProvider);
          },
          child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            const BackHeader(title: '环境检查', subtitle: '仅开发环境可见'),
            _section('构建', [
              _kv('配置来源', c.fromConfigFile ? 'config/app.yaml · ${c.configProfile}' : '未加载（内置默认值，见 README）'),
              _kv('LOOPLAND_ENV', c.env),
              _kv('API_BASE', Env.apiBase),
              _kv('WebSocket', Env.wsUrl),
              _kv('平台', c.platform),
              _kv('Release 构建', c.release ? '是（缺少的 Key 会隐藏入口）' : '否'),
              _kv('启动隐私弹窗', LaunchPrivacy.agreed ? '已同意' : '未同意'),
              _kv('高德隐私合规', AmapTerritoryMap.privacyAgreed ? '已调用 updatePrivacyAgree' : '未调用（使用备用地图）'),
            ]),
            _section('SDK 配置', [for (final s in c.checks()) _check(s)]),
            _section('服务端 /v1/config/features', [
              if (features.isLoading) _kv('状态', '加载中…'),
              if (f != null) ...[
                _kv('状态', f.fetched ? '已获取' : '请求失败（只显示短信登录）'),
                _kv('login', f.login.join(', ')),
                _kv('pay', f.pay.join(', ')),
                _kv('captcha', '${f.captcha}'),
                _kv('ai', '${f.ai}'),
              ],
            ]),
            _section('最终显示', [
              _kv('一键登录', _yn(login.oneClick)),
              _kv('微信登录', _yn(login.wechat)),
              _kv('Apple 登录', _yn(login.apple)),
              _kv('短信前人机验证', switch (captchaMode(f, c)) {
                CaptchaMode.skip => '跳过',
                CaptchaMode.show => '显示',
                CaptchaMode.misconfigured => '服务端要求但客户端未配置！',
              }),
              _kv('支付渠道', payChannels(f, c).join(', ')),
            ]),
            _section('设备风控', [
              if (device.value case final d?) ...[
                _kv('model / os', '${d.model} · ${d.os}'),
                _kv('rooted', '${d.rooted}'),
                _kv('emulator', '${d.emulator}'),
                _kv('multi_open', '${d.multiOpen}'),
              ] else
                _kv('状态', '检测中…'),
            ]),
          ]),
        ),
      ),
    );
  }

  static String _yn(bool v) => v ? '显示' : '隐藏';

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: LLCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(k, style: const TextStyle(color: LL.text3, fontSize: 13))),
          Expanded(child: Text(v.isEmpty ? '—' : v, style: const TextStyle(fontSize: 13))),
        ]),
      );

  Widget _check(SdkCheck s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(s.configured ? Icons.check_circle : Icons.error_outline,
              size: 18, color: s.configured ? LL.lime : (s.required ? LL.orange : LL.text3)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              if (!s.configured && s.missing.isNotEmpty)
                Text('缺少 ${s.missing.join(' / ')}', style: const TextStyle(color: LL.text3, fontSize: 12)),
              if (s.note != null) Text(s.note!, style: const TextStyle(color: LL.text3, fontSize: 12)),
            ]),
          ),
        ]),
      );
}
