import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/env.dart';
import '../../core/format.dart';
import '../../core/privacy.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../login/consent_page.dart';

const visibilityNames = {'public': '公开', 'followers': '仅粉丝', 'crew': '仅跑团', 'private': '仅自己'};

/// 设置与隐私：轨迹可见范围、隐藏起终点、地图头像、个性化推荐、授权、实名、导出、注销、退出。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _busy = false;

  Future<void> _patch(Map<String, dynamic> settings) async {
    final u = await runGuarded(context, () => ref.read(apiProvider).updateMe(settings: settings));
    if (u != null) ref.read(authProvider.notifier).setUser(u);
  }

  Future<void> _consent({bool? location, bool? health}) async {
    final c = ref.read(userProvider)!.consents;
    await runGuarded(
        context,
        () => ref.read(authProvider.notifier).saveConsents(
              location: location ?? c.location,
              health: health ?? c.health,
            ));
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final text = await ref.read(apiProvider).exportData();
      if (kIsWeb) {
        if (mounted) toast(context, '已导出 ${text.length} 字节（网页版请在 App 中导出文件）');
        return;
      }
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/loopland-export-${DateTime.now().millisecondsSinceEpoch}.json');
      await f.writeAsString(text);
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/json')], subject: '圈圈数据导出'));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(User u) async {
    if (u.isDeleting) {
      final nu = await runGuarded(context, () => ref.read(apiProvider).cancelDeletion());
      if (nu != null && mounted) {
        ref.read(authProvider.notifier).setUser(nu);
        toast(context, '已撤回注销');
      }
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('注销账号'),
        content: const Text('申请后有 7 天冷静期，期间可以随时撤回。到期后将删除你的轨迹和个人信息，名下领地变为无主，会员权益不退。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: LL.red, foregroundColor: LL.text),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('申请注销'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final when = await runGuarded(context, () => ref.read(apiProvider).requestDeletion());
    if (!mounted) return;
    await ref.read(authProvider.notifier).refreshUser().catchError((_) {});
    if (mounted && when != null) toast(context, '已申请注销，将于 ${Fmt.dateTime(when)} 生效，期间可撤回');
  }

  @override
  Widget build(BuildContext context) {
    final u = ref.watch(userProvider);
    if (u == null) return const SizedBox.shrink();
    final s = u.settings;
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
          const BackHeader(title: '设置与隐私'),
          _group('轨迹与隐私', [
            ListTile(
              title: const Text('轨迹默认可见范围'),
              trailing: DropdownButton<String>(
                value: s.trackVisibility,
                underline: const SizedBox.shrink(),
                items: [
                  for (final e in visibilityNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => v == null ? null : _patch({'track_visibility': v}),
              ),
            ),
            SwitchListTile(
              title: const Text('隐藏轨迹起终点'),
              subtitle: const Text('隐藏起点和终点附近 200 m，保护住址', style: TextStyle(color: LL.text3, fontSize: 12)),
              value: s.hideEndpoints,
              onChanged: (v) => _patch({'hide_endpoints': v}),
            ),
            SwitchListTile(
              title: const Text('在地图上显示我的头像'),
              value: s.showAvatarOnMap,
              onChanged: (v) => _patch({'show_avatar_on_map': v}),
            ),
            SwitchListTile(
              title: const Text('个性化推荐'),
              subtitle: const Text('关闭后不再根据你的数据推荐内容', style: TextStyle(color: LL.text3, fontSize: 12)),
              value: s.personalized,
              onChanged: (v) => _patch({'personalized': v}),
            ),
          ]),
          _group('授权', [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 0),
              child: ConsentSwitches(
                location: u.consents.location,
                health: u.consents.health,
                onLocation: (v) => _consent(location: v),
                onHealth: (v) => _consent(health: v),
              ),
            ),
          ]),
          _group('账号', [
            ListTile(
              title: const Text('手机号'),
              trailing: Text(u.phoneMasked ?? '未绑定', style: const TextStyle(color: LL.text2)),
            ),
            ListTile(
              title: const Text('实名认证'),
              trailing: Text(
                  u.realnameVerified ? (u.isAdult == false ? '已认证 · 未成年' : '已认证') : '去认证',
                  style: const TextStyle(color: LL.text2)),
              onTap: () => context.push('/realname'),
            ),
            ListTile(
              title: const Text('导出我的数据'),
              subtitle: const Text('账号资料、运动记录（含轨迹）、领地、图鉴、订单', style: TextStyle(color: LL.text3, fontSize: 12)),
              trailing: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download_rounded),
              onTap: _busy ? null : _export,
            ),
            ListTile(
              title: Text(u.isDeleting ? '撤回注销' : '注销账号', style: TextStyle(color: u.isDeleting ? LL.lime : LL.red)),
              subtitle: u.isDeleting
                  ? Text('冷静期中，将于 ${Fmt.dateTime(u.deleteAfter)} 删除', style: const TextStyle(color: LL.text3, fontSize: 12))
                  : const Text('7 天冷静期内可撤回', style: TextStyle(color: LL.text3, fontSize: 12)),
              onTap: () => _delete(u),
            ),
          ]),
          _group('协议', [
            ListTile(title: const Text('用户协议'), trailing: const Icon(Icons.chevron_right), onTap: () => openLegal(context, privacy: false)),
            ListTile(title: const Text('隐私政策'), trailing: const Icon(Icons.chevron_right), onTap: () => openLegal(context, privacy: true)),
            if (Env.isDev)
              ListTile(
                title: const Text('环境检查'),
                subtitle: const Text('开发环境：查看各 SDK 配置情况', style: TextStyle(color: LL.text3, fontSize: 12)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/dev/env'),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton(
              onPressed: () => ref.read(authProvider.notifier).logout(),
              child: const Text('退出登录'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _group(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title, style: const TextStyle(color: LL.text2, fontWeight: FontWeight.w700)),
          ),
          LLCard(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(children: children)),
        ]),
      );
}

/// 实名认证（服务端只保存是否成年和出生年份）。
class RealnamePage extends ConsumerStatefulWidget {
  const RealnamePage({super.key});
  @override
  ConsumerState<RealnamePage> createState() => _RealnamePageState();
}

class _RealnamePageState extends ConsumerState<RealnamePage> {
  final _name = TextEditingController();
  final _id = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty || _id.text.trim().length != 18) {
      toast(context, '请填写姓名和 18 位身份证号');
      return;
    }
    setState(() => _busy = true);
    final u = await runGuarded(context, () => ref.read(apiProvider).realname(_name.text.trim(), _id.text.trim().toUpperCase()));
    if (!mounted) return;
    setState(() => _busy = false);
    if (u != null) {
      ref.read(authProvider.notifier).setUser(u);
      toast(context, u.isAdult == false ? '认证成功。未成年账号将不展示付费服务。' : '实名认证成功');
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = ref.watch(userProvider);
    return Scaffold(
      body: SafeArea(
        child: ListView(children: [
          const BackHeader(title: '实名认证', subtitle: '我们只保存是否成年和出生年份，不保存身份证号'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: u?.realnameVerified == true
                ? LLCard(child: Text(u!.isAdult == false ? '已认证 · 未成年账号' : '已完成实名认证'))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    TextField(controller: _name, decoration: const InputDecoration(hintText: '真实姓名')),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _id,
                      maxLength: 18,
                      decoration: const InputDecoration(hintText: '身份证号', counterText: ''),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(onPressed: _busy ? null : _submit, child: const Text('提交认证')),
                  ]),
          ),
        ]),
      ),
    );
  }
}
