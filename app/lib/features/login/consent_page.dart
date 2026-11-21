import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../auth/auth_controller.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// 隐私授权：隐私政策（必选）+ 位置/行踪轨迹 + 运动健康数据，分开单独同意。
class ConsentPage extends ConsumerStatefulWidget {
  const ConsentPage({super.key});
  @override
  ConsumerState<ConsentPage> createState() => _ConsentPageState();
}

class _ConsentPageState extends ConsumerState<ConsentPage> {
  late bool _location = ref.read(userProvider)?.consents.location ?? false;
  late bool _health = ref.read(userProvider)?.consents.health ?? false;
  bool _busy = false;

  Future<void> _accept() async {
    setState(() => _busy = true);
    await runGuarded(context, () async {
      await ref.read(authProvider.notifier).saveConsents(location: _location, health: _health);
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 32), children: [
          const Text('隐私与授权', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text('隐私政策版本 ${Env.privacyVersion}', style: const TextStyle(color: LL.text3)),
          const SizedBox(height: 20),
          const LLCard(
            child: Text(
              '圈圈会处理你的手机号、运动记录和行踪轨迹，用于圈地判定、领地排名和防作弊。'
              '行踪轨迹属于敏感个人信息，默认隐藏起终点 200 m，你可以随时在「设置」里修改可见范围、导出或删除数据、注销账号。\n\n'
              '我们使用高德地图 SDK 展示地图和定位，相关数据处理遵循其隐私政策。',
              style: TextStyle(color: LL.text2, height: 1.7),
            ),
          ),
          const SizedBox(height: 16),
          ConsentSwitches(
            location: _location,
            health: _health,
            onLocation: (v) => setState(() => _location = v),
            onHealth: (v) => setState(() => _health = v),
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _busy ? null : _accept,
            child: const Text('同意隐私政策并继续'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => ref.read(authProvider.notifier).logout(),
            child: const Text('不同意并退出', style: TextStyle(color: LL.text2)),
          ),
        ]),
      ),
    );
  }
}

class ConsentSwitches extends StatelessWidget {
  const ConsentSwitches({super.key, required this.location, required this.health, required this.onLocation, required this.onHealth});
  final bool location, health;
  final ValueChanged<bool> onLocation, onHealth;

  @override
  Widget build(BuildContext context) {
    return LLCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(children: [
        SwitchListTile(
          value: location,
          onChanged: onLocation,
          title: const Text('位置信息与行踪轨迹', style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: const Text('运动时记录 GPS 轨迹用于圈地。开始第一次户外运动前必须开启。',
              style: TextStyle(color: LL.text3, fontSize: 12)),
        ),
        const Divider(indent: 16, endIndent: 16),
        SwitchListTile(
          value: health,
          onChanged: onHealth,
          title: const Text('运动健康数据', style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: const Text('心率、步频（来自手表或系统健康）用于防作弊佐证和数据分析，可选。',
              style: TextStyle(color: LL.text3, fontSize: 12)),
        ),
      ]),
    );
  }
}

/// Asked before the first GPS run when location consent is missing.
/// Returns true when location is granted.
Future<bool> ensureRunConsent(BuildContext context, WidgetRef ref) async {
  final u = ref.read(userProvider);
  if (u == null) return false;
  if (u.consents.privacyAccepted && u.consents.location) return true;
  var location = true, health = u.consents.health;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('开始前需要你的授权', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          const Text('户外运动需要记录行踪轨迹才能圈地。轨迹默认隐藏起终点 200 m。', style: TextStyle(color: LL.text2)),
          const SizedBox(height: 16),
          ConsentSwitches(
            location: location,
            health: health,
            onLocation: (v) => setS(() => location = v),
            onHealth: (v) => setS(() => health = v),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: location ? () => Navigator.pop(c, true) : null, child: const Text('同意并开始')),
        ]),
      ),
    ),
  );
  if (ok != true || !context.mounted) return false;
  final saved = await runGuarded(context, () async {
    await ref.read(authProvider.notifier).saveConsents(location: location, health: health);
    return true;
  });
  return saved == true;
}
