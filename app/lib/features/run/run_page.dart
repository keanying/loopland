import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../claim/claim.dart';
import '../../claim/geo.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../map/territory_map.dart';
import '../../run/run_controller.dart';
import '../../run/uploader.dart';
import '../../widgets/common.dart';
import '../../widgets/monster_art.dart';
import 'result_page.dart';

/// 运动中：倒计时、实时轨迹 + 圈地预览、「还差 X 米可闭合」、暂停 / 继续、长按结束。
class RunPage extends ConsumerStatefulWidget {
  const RunPage({super.key});
  @override
  ConsumerState<RunPage> createState() => _RunPageState();
}

class _RunPageState extends ConsumerState<RunPage> {
  final _map = TerritoryMapController();
  bool _follow = true;
  bool _finishing = false;
  bool _goalToastShown = false;
  int _lastLoopCount = 0;

  // V2: bosses / chests / checkpoints around the runner.
  MapObjects _nearby = const MapObjects();
  LatLng? _nearbyAt;
  DateTime? _nearbyTime;
  bool _nearbyLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLoadNearby(ref.read(runControllerProvider).position);
    });
  }

  /// Reloads objects within ~1.5 km when the runner moved 400 m or every 2 min.
  Future<void> _maybeLoadNearby(LatLng? pos) async {
    if (pos == null || _nearbyLoading) return;
    final at = _nearbyAt, t = _nearbyTime;
    if (at != null && t != null && haversine(at, pos) < 400 && DateTime.now().difference(t) < const Duration(minutes: 2)) {
      return;
    }
    _nearbyLoading = true;
    try {
      const dLat = 0.0135;
      final dLng = dLat / math.cos(pos.lat * math.pi / 180);
      final o = await ref
          .read(apiProvider)
          .mapObjects(minLng: pos.lng - dLng, minLat: pos.lat - dLat, maxLng: pos.lng + dLng, maxLat: pos.lat + dLat);
      if (!mounted) return;
      setState(() {
        _nearby = o;
        _nearbyAt = pos;
        _nearbyTime = DateTime.now();
      });
    } catch (_) {
      // Best effort; the server settles damage / chests from the track anyway.
      _nearbyAt = pos;
      _nearbyTime = DateTime.now();
    } finally {
      _nearbyLoading = false;
    }
  }

  /// Live hints for objects whose range the runner is inside.
  List<Widget> _objectHints(LatLng? pos) {
    if (pos == null) return const [];
    final out = <Widget>[];
    for (final b in _nearby.bosses) {
      if (haversine(pos, b.center) <= b.radiusM) {
        out.add(_HintChip(
          leading: MonsterArt(kind: b.kind, size: 30, badge: true),
          text: '正在对${b.name}造成伤害',
          color: monsterColor(b.kind),
        ));
      }
    }
    for (final c in _nearby.chests) {
      if (haversine(pos, c.center) <= c.radiusM) {
        out.add(const _HintChip(icon: Icons.inventory_2_rounded, text: '经过能量宝箱，结算时自动开启', color: LL.yellow));
      }
    }
    for (final c in _nearby.checkpoints) {
      if (c.isNext && haversine(pos, c.center) <= c.radiusM) {
        out.add(_HintChip(icon: Icons.explore_rounded, text: '到达打卡点「${c.name}」', color: LL.sky));
      }
    }
    for (final g in ref.read(runControllerProvider).guide?.targets ?? const <GuideTarget>[]) {
      if (haversine(pos, g.center) <= 80) {
        out.add(_HintChip(icon: Icons.flag_rounded, text: '到达路线目标「${g.name}」', color: LL.lavender));
      }
    }
    return out;
  }

  /// Nearby objects plus the AI route's targets (numbered markers).
  MapObjects _withGuide(RunGuide? g) {
    if (g == null || g.targets.isEmpty) return _nearby;
    return MapObjects(
      bosses: _nearby.bosses,
      chests: _nearby.chests,
      checkpoints: [
        ..._nearby.checkpoints,
        for (var i = 0; i < g.targets.length; i++)
          MapCheckpoint(routeId: 0, index: i, name: g.targets[i].name, center: g.targets[i].center),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(runControllerProvider);
    final now = ref.watch(clockProvider)();
    ref.listen<RunState>(runControllerProvider, (prev, next) {
      final pos = next.position;
      if (_follow && pos != null && pos != prev?.position) _map.moveTo(pos);
      if (pos != prev?.position) _maybeLoadNearby(pos);
      if (next.loops.length > _lastLoopCount) {
        final added = next.loops.length - _lastLoopCount;
        _lastLoopCount = next.loops.length;
        toast(context, '圈下 $added 块地！已圈 ${Fmt.area(next.claimedAreaM2)}');
      }
      if (!_goalToastShown && next.goalReached(ref.read(clockProvider)())) {
        _goalToastShown = true;
        toast(context, '目标达成！可以继续跑，也可以长按结束');
      }
    });

    if (s.phase == RunPhase.idle) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('没有进行中的运动', style: TextStyle(color: LL.text2)),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => context.go('/start'), child: const Text('去开始')),
          ]),
        ),
      );
    }

    final hint = s.hint;
    final top = MediaQuery.paddingOf(context).top;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) toast(context, s.phase == RunPhase.countdown ? '倒计时中…' : '先暂停，再长按「结束」完成本次运动');
      },
      child: Scaffold(
        body: Stack(children: [
          Positioned.fill(
            child: Listener(
              onPointerDown: (_) => setState(() => _follow = false),
              child: TerritoryMapView(
                controller: _map,
                initialCenter: s.position ?? const LatLng(31.2304, 121.4737),
                initialZoom: 16.5,
                layers: MapLayers(
                  objects: _withGuide(s.guide),
                  // AI 路线建议: the chosen route as a dashed guide line.
                  routePath: s.guide?.path ?? const [],
                  track: s.track,
                  loops: [for (final l in s.loops) l.ring],
                  hintFrom: hint == null ? null : s.position,
                  hintTarget: hint?.target,
                  myLocation: s.position,
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            top: top + 10,
            child: Row(children: [
              _Chip(
                icon: Icons.satellite_alt_rounded,
                text: s.lastFix == null
                    ? '搜索 GPS…'
                    : (s.lastFix!.accuracy ?? 99) <= 20
                        ? 'GPS 良好'
                        : 'GPS 弱',
                color: s.lastFix == null ? LL.text3 : ((s.lastFix!.accuracy ?? 99) <= 20 ? LL.lime : LL.orange),
              ),
              const SizedBox(width: 8),
              _Chip(icon: Icons.flag_rounded, text: _goalText(s, now), color: LL.lavender),
              const Spacer(),
              if (!_follow)
                RoundIconButton(
                  icon: Icons.my_location_rounded,
                  tooltip: '跟随我的位置',
                  onTap: () {
                    setState(() => _follow = true);
                    if (s.position != null) _map.moveTo(s.position!);
                  },
                ),
            ]),
          ),
          Positioned(
            left: 16,
            right: 16,
            top: top + 64,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (s.mockDetected)
                const LLCard(
                  color: Color(0xFF3A1D22),
                  padding: EdgeInsets.all(12),
                  child: Text('检测到模拟定位，本次记录可能会被风控作废。', style: TextStyle(color: LL.text)),
                ),
              for (final h in _objectHints(s.position)) Padding(padding: const EdgeInsets.only(top: 8), child: h),
            ]),
          ),
          Positioned(left: 0, right: 0, bottom: 0, child: _panel(s, now, hint)),
          if (s.phase == RunPhase.countdown) _Countdown(n: s.countdown),
          if (_finishing)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0xCC0E0E10),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('正在结算圈地…'),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  String _goalText(RunState s, DateTime now) => switch (s.goal.type) {
        'distance' => '目标 ${Fmt.km(s.goal.value ?? 0, digits: 0)} km',
        'time' => '目标 ${((s.goal.value ?? 0) / 60).round()} 分钟',
        'target' => '抢领地 #${s.goal.territoryId}',
        'ai_route' => s.guide?.title ?? 'AI 路线',
        _ => '自由圈地',
      };

  Widget _panel(RunState s, DateTime now, ClosingHint? hint) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final paused = s.phase == RunPhase.paused;
    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottom),
      decoration: const BoxDecoration(
        color: LL.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        boxShadow: [BoxShadow(color: Color(0x99000000), blurRadius: 24)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (hint != null)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: const Color(0xFF26223A), borderRadius: BorderRadius.circular(18)),
            child: Row(children: [
              const Icon(Icons.all_inclusive_rounded, color: LL.lavender),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  const TextSpan(text: '还差 '),
                  TextSpan(
                      text: '${hint.distanceM.round()}',
                      style: const TextStyle(color: LL.lavender, fontWeight: FontWeight.w900, fontSize: 18)),
                  const TextSpan(text: ' 米可闭合，跑回虚线终点即可圈地'),
                ])),
              ),
            ]),
          ),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(Fmt.km(s.distanceM), style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w900, height: 1)),
          const Padding(padding: EdgeInsets.only(bottom: 8, left: 4), child: Text('公里', style: TextStyle(color: LL.text2))),
          const Spacer(),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(Fmt.area(s.claimedAreaM2),
                style: const TextStyle(color: LL.lime, fontSize: 22, fontWeight: FontWeight.w900)),
            Text('已圈 ${s.loops.length} 块', style: const TextStyle(color: LL.text2, fontSize: 12)),
          ]),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: StatBox(value: Fmt.pace(s.paceSPerKm(now)), label: '平均配速')),
          Expanded(child: StatBox(value: Fmt.duration(s.elapsedMs(now) / 1000), label: '时长')),
          Expanded(child: StatBox(value: sportName(s.sport), label: paused ? '已暂停' : '记录中')),
        ]),
        const SizedBox(height: 18),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          if (paused)
            _BigButton(
              label: '继续',
              icon: Icons.play_arrow_rounded,
              color: LL.lime,
              onTap: () => ref.read(runControllerProvider.notifier).resume(),
            )
          else
            _BigButton(
              label: '暂停',
              icon: Icons.pause_rounded,
              color: LL.text,
              onTap: s.phase == RunPhase.running ? () => ref.read(runControllerProvider.notifier).pause() : null,
            ),
          LongPressButton(
            label: '长按结束',
            onComplete: s.phase == RunPhase.countdown ? null : _finish,
          ),
        ]),
      ]),
    );
  }

  Future<void> _finish() async {
    final ctrl = ref.read(runControllerProvider.notifier);
    final st = ref.read(runControllerProvider);
    if (st.points.length < 2) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('还没有记录到轨迹'),
          content: const Text('没有有效的 GPS 轨迹，结束后不会生成记录。确定结束吗？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('继续运动')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('结束')),
          ],
        ),
      );
      if (discard == true) {
        await ctrl.discard();
        if (mounted) context.go('/start');
      }
      return;
    }
    setState(() => _finishing = true);
    final track = st.track;
    try {
      // finish() 也放在 try 里：任何一步出错都要关掉「正在结算」遮罩
      final upload = await ctrl.finish();
      final r = await ref.read(uploaderProvider).submit(upload);
      ref.read(authProvider.notifier).refreshUser().ignore();
      ref.invalidate(codexProvider);
      ctrl.reset();
      if (mounted) context.go('/result', extra: ResultArgs(result: r, localTrack: track));
    } catch (e) {
      ctrl.reset();
      if (!mounted) return;
      final ex = ApiException.from(e);
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('已保存在本机'),
          content: Text('${ex.message}\n\n这次运动已安全保存，网络恢复后会自动上传（在「我的」里也可以手动重试）。'),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('好的'))],
        ),
      );
      if (mounted) context.go('/me');
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: LL.night.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(18)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        ]),
      );
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.label, required this.icon, required this.color, this.onTap});
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 76, height: 76, child: Icon(icon, size: 38, color: LL.ink)),
        ),
      ),
      const SizedBox(height: 6),
      Text(label, style: const TextStyle(color: LL.text2, fontSize: 12)),
    ]);
  }
}

/// Finish button that must be held (防误触).
class LongPressButton extends StatefulWidget {
  const LongPressButton({super.key, required this.label, this.onComplete, this.duration = const Duration(milliseconds: 1200)});
  final String label;
  final VoidCallback? onComplete;
  final Duration duration;
  @override
  State<LongPressButton> createState() => _LongPressButtonState();
}

class _LongPressButtonState extends State<LongPressButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration)
    ..addStatusListener(_onStatus);

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed) {
      _c.reset();
      widget.onComplete?.call();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onComplete != null;
    return Column(children: [
      Semantics(
        button: true,
        label: widget.label,
        onLongPress: widget.onComplete,
        child: GestureDetector(
          onTapDown: enabled ? (_) => _c.forward() : null,
          onTapUp: (_) => _c.reverse(),
          onTapCancel: () => _c.reverse(),
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => SizedBox(
              width: 76,
              height: 76,
              child: Stack(alignment: Alignment.center, children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: enabled ? LL.red : LL.card2),
                  child: const Icon(Icons.stop_rounded, size: 38, color: LL.text),
                ),
                SizedBox(
                  width: 76,
                  height: 76,
                  child: CircularProgressIndicator(value: _c.value, strokeWidth: 5, color: LL.text, backgroundColor: Colors.transparent),
                ),
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text(widget.label, style: const TextStyle(color: LL.text2, fontSize: 12)),
    ]);
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown({required this.n});
  final int n;
  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xE60E0E10),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TweenAnimationBuilder<double>(
              key: ValueKey(n),
              tween: Tween(begin: 1.6, end: 1),
              duration: const Duration(milliseconds: 400),
              builder: (context, v, child) => Transform.scale(scale: v, child: child),
              child: Text('$n', style: const TextStyle(fontSize: 160, fontWeight: FontWeight.w900, color: LL.lime)),
            ),
            const Text('准备出发，跑一圈就是你的地', style: TextStyle(color: LL.text2)),
          ]),
        ),
      ),
    );
  }
}

class _HintChip extends StatelessWidget {
  const _HintChip({this.leading, this.icon, required this.text, required this.color});
  final Widget? leading;
  final IconData? icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 14, 6),
        decoration: BoxDecoration(
          color: LL.night.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: color, width: 1.5),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          leading ?? Icon(icon, color: color, size: 22),
          const SizedBox(width: 8),
          Flexible(child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 14))),
        ]),
      );
}
