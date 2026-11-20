import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../claim/geo.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../map/territory_map.dart';
import '../../run/location_source.dart';
import '../../run/run_controller.dart';
import '../../widgets/common.dart';
import '../login/consent_page.dart';

/// 开跑前：选运动、选目标（自由圈地 / 定距离 / 定时间 / 抢指定领地）。
class GpsSetupPage extends ConsumerStatefulWidget {
  const GpsSetupPage({super.key, this.sport = 'run', this.targetId, this.targetName});
  final String sport;
  final int? targetId;
  final String? targetName;

  @override
  ConsumerState<GpsSetupPage> createState() => _GpsSetupPageState();
}

class _GpsSetupPageState extends ConsumerState<GpsSetupPage> {
  late String _sport = widget.sport;
  late String _goal = widget.targetId != null ? 'target' : 'free';
  int _distanceKm = 5;
  int _minutes = 30;
  LatLng? _me;
  double? _accuracy;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    ref.read(locationSourceProvider).current().then((f) {
      if (f != null && mounted) {
        setState(() {
          _me = LatLng(f.lat, f.lng);
          _accuracy = f.accuracy;
        });
      }
    });
  }

  Goal get _goalValue => switch (_goal) {
        'distance' => Goal(type: 'distance', value: _distanceKm * 1000),
        'time' => Goal(type: 'time', value: _minutes * 60),
        'target' => Goal(type: 'target', territoryId: widget.targetId),
        _ => const Goal(),
      };

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      if (!await ensureRunConsent(context, ref)) return;
      final perm = await ref.read(locationSourceProvider).ensurePermission();
      if (!mounted) return;
      if (perm != LocationPermissionResult.granted) {
        await _permissionHelp(perm);
        return;
      }
      final cfg = ref.read(configProvider).value;
      ref.read(runControllerProvider.notifier).start(
            RunConfig(sport: _sport, goal: _goalValue),
            minClaimAreaM2: cfg?.minClaimAreaM2 ?? 500,
          );
      context.pushReplacement('/run');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _permissionHelp(LocationPermissionResult p) async {
    final msg = switch (p) {
      LocationPermissionResult.serviceDisabled => '手机的定位服务没有打开，请在系统设置中开启。',
      LocationPermissionResult.deniedForever => '定位权限被拒绝了。请在系统设置里允许圈圈「始终」使用位置，锁屏时才能继续记录。',
      _ => '需要定位权限才能记录轨迹和圈地。',
    };
    final open = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('需要定位权限'),
        content: Text('$msg\n\n部分安卓手机会在后台杀掉运动记录，建议把圈圈加入电池优化白名单。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('去设置')),
        ],
      ),
    );
    if (open == true) await ref.read(locationSourceProvider).openSettings();
  }

  @override
  Widget build(BuildContext context) {
    const sports = ['run', 'walk', 'ride', 'hike'];
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '开跑'),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              PillTabs(
                labels: [for (final s in sports) sportName(s)],
                index: sports.indexOf(_sport).clamp(0, 3),
                onChanged: (i) => setState(() => _sport = sports[i]),
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: SizedBox(
                  height: 220,
                  child: Stack(children: [
                    Positioned.fill(
                      child: TerritoryMapView(
                        key: ValueKey(_me),
                        interactive: false,
                        initialCenter: _me ?? const LatLng(31.2304, 121.4737),
                        initialZoom: 15.5,
                        layers: MapLayers(myLocation: _me),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      bottom: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: LL.night.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(16)),
                        child: const Row(children: [
                          Icon(Icons.circle, color: LL.lime, size: 10),
                          SizedBox(width: 6),
                          Text('自由圈地 · 轨迹一交叉就占领', style: TextStyle(fontSize: 13)),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 18),
              const Text('本次目标', style: TextStyle(color: LL.text2)),
              const SizedBox(height: 10),
              _GoalTile(
                selected: _goal == 'free',
                color: LL.lavender,
                icon: Icons.gesture_rounded,
                title: '自由圈地 · 推荐',
                sub: '随便跑，轨迹一交叉就自动圈地，可连圈多块',
                onTap: () => setState(() => _goal = 'free'),
              ),
              _GoalTile(
                selected: _goal == 'distance',
                color: LL.lime,
                icon: Icons.straighten_rounded,
                title: '定距离 · $_distanceKm km',
                sub: '达到距离会提醒你，可以继续跑',
                onTap: () => setState(() => _goal = 'distance'),
                extra: _goal == 'distance'
                    ? _Choices(values: const [3, 5, 10, 21], selected: _distanceKm, unit: 'km', onPick: (v) => setState(() => _distanceKm = v))
                    : null,
              ),
              _GoalTile(
                selected: _goal == 'time',
                color: LL.sky,
                icon: Icons.timer_outlined,
                title: '定时间 · $_minutes 分钟',
                sub: '到时间会提醒你，可以继续跑',
                onTap: () => setState(() => _goal = 'time'),
                extra: _goal == 'time'
                    ? _Choices(values: const [20, 30, 45, 60], selected: _minutes, unit: '分钟', onPick: (v) => setState(() => _minutes = v))
                    : null,
              ),
              _GoalTile(
                selected: _goal == 'target',
                color: LL.pink,
                icon: Icons.flag_outlined,
                title: widget.targetId != null ? '抢 ${widget.targetName ?? '领地 #${widget.targetId}'}' : '抢指定领地',
                sub: widget.targetId != null ? '围着它跑一圈，能量超过守卫值就能抢下' : '在「领地」地图上点一块地，选择「导航去抢」',
                onTap: widget.targetId != null ? () => setState(() => _goal = 'target') : () => context.go('/map'),
              ),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.circle, size: 10, color: _accuracy == null ? LL.text3 : (_accuracy! <= 20 ? LL.lime : LL.orange)),
                const SizedBox(width: 6),
                Text(
                  _accuracy == null
                      ? '正在获取 GPS…'
                      : (_accuracy! <= 20 ? 'GPS 信号良好' : 'GPS 信号一般（±${_accuracy!.round()} m）'),
                  style: const TextStyle(color: LL.text2),
                ),
              ]),
              const SizedBox(height: 20),
              Center(
                child: Semantics(
                  button: true,
                  label: '开始',
                  child: GestureDetector(
                    onTap: _start,
                    child: Container(
                      width: 150,
                      height: 150,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(shape: BoxShape.circle, color: LL.lime.withValues(alpha: 0.18)),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(shape: BoxShape.circle, color: LL.lime),
                        child: _starting
                            ? const CircularProgressIndicator(color: LL.ink)
                            : const Text('开始', style: TextStyle(color: LL.ink, fontSize: 32, fontWeight: FontWeight.w900)),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _GoalTile extends StatelessWidget {
  const _GoalTile({
    required this.selected,
    required this.color,
    required this.icon,
    required this.title,
    required this.sub,
    required this.onTap,
    this.extra,
  });
  final bool selected;
  final Color color;
  final IconData icon;
  final String title, sub;
  final VoidCallback onTap;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF1E2112) : LL.card,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: selected ? LL.lime : LL.border, width: selected ? 1.5 : 1),
          ),
          child: Column(children: [
            Row(children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: Icon(icon, color: LL.ink),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 2),
                  Text(sub, style: const TextStyle(color: LL.text2, fontSize: 13)),
                ]),
              ),
            ]),
            if (extra != null) Padding(padding: const EdgeInsets.only(top: 12), child: extra),
          ]),
        ),
      ),
    );
  }
}

class _Choices extends StatelessWidget {
  const _Choices({required this.values, required this.selected, required this.unit, required this.onPick});
  final List<int> values;
  final int selected;
  final String unit;
  final ValueChanged<int> onPick;
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (final v in values)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text('$v $unit'),
            selected: v == selected,
            onSelected: (_) => onPick(v),
            selectedColor: LL.lime,
            labelStyle: TextStyle(color: v == selected ? LL.ink : LL.text, fontWeight: FontWeight.w700),
            showCheckmark: false,
          ),
        ),
    ]);
  }
}
