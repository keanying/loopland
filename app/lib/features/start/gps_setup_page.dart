import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/ai_models.dart';
import '../../api/errors.dart';
import '../../api/models.dart';
import '../../claim/geo.dart';
import '../../core/features.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../map/territory_map.dart';
import '../../run/location_source.dart';
import '../../run/run_controller.dart';
import '../../widgets/common.dart';
import '../ai/ai_providers.dart';
import '../ai/ai_widgets.dart';
import '../login/consent_page.dart';

/// 开跑前：选运动、选目标（自由圈地 / AI 推荐路线 / 定距离 / 定时间 / 抢指定领地）。
class GpsSetupPage extends ConsumerStatefulWidget {
  const GpsSetupPage({super.key, this.sport = 'run', this.targetId, this.targetName, this.aiRoute, this.autostart = false});
  final String sport;
  final int? targetId;
  final String? targetName;

  /// A route from the assistant, preselected as the goal.
  final AIRoute? aiRoute;

  /// Start immediately (「一键开跑」); consent / permission checks still run.
  final bool autostart;

  @override
  ConsumerState<GpsSetupPage> createState() => _GpsSetupPageState();
}

class _GpsSetupPageState extends ConsumerState<GpsSetupPage> {
  late String _sport = widget.sport;
  late String _goal = widget.aiRoute != null ? 'ai' : (widget.targetId != null ? 'target' : 'free');
  int _distanceKm = 5;
  int _minutes = 30;
  LatLng? _me;
  double? _accuracy;
  bool _locating = true;
  bool _starting = false;

  // AI 路线建议 (C-04): selection is by route type (one per type), or
  // 'chat' for the route passed in from the assistant.
  late String? _aiSel = widget.aiRoute != null ? 'chat' : null;
  int _aiKm = 5;
  AIRoute? _aiRoute;
  final _preview = TerritoryMapController();
  String? _fitted;

  @override
  void initState() {
    super.initState();
    _aiRoute = widget.aiRoute;
    _locate();
    if (widget.autostart) WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _locate() async {
    setState(() => _locating = true);
    final f = await ref.read(locationSourceProvider).current();
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (f != null) {
        _me = LatLng(f.lat, f.lng);
        _accuracy = f.accuracy;
        _fitted = null;
      }
    });
  }

  Goal get _goalValue => switch (_goal) {
        'distance' => Goal(type: 'distance', value: _distanceKm * 1000),
        'time' => Goal(type: 'time', value: _minutes * 60),
        'target' => Goal(type: 'target', territoryId: widget.targetId),
        'ai' when _aiRoute != null => Goal(type: 'ai_route', routeId: _aiRoute!.id, routeType: _aiRoute!.type),
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
      final ai = _goal == 'ai' ? _aiRoute : null;
      ref.read(runControllerProvider.notifier).start(
            RunConfig(sport: _sport, goal: _goalValue, guide: ai == null ? null : guideOf(ai)),
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

  AIRoute? get _shownRoute => _goal == 'ai' ? _aiRoute : null;

  MapLayers _previewLayers() {
    final r = _shownRoute;
    if (r == null) return MapLayers(myLocation: _me);
    return MapLayers(
      myLocation: _me,
      routePath: r.path,
      objects: MapObjects(checkpoints: [
        for (var i = 0; i < r.targets.length; i++)
          if (r.targets[i].center != null)
            MapCheckpoint(routeId: 0, index: i, name: r.targets[i].name, center: r.targets[i].center!),
      ]),
    );
  }

  /// Frames the selected route on the preview map (once per route).
  void _fitPreview() {
    final r = _shownRoute;
    final key = r == null ? null : '${r.id}@$_me';
    if (key == _fitted) return;
    _fitted = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (r == null) {
        if (_me != null) _preview.moveTo(_me!, zoom: 15.5);
        return;
      }
      _preview.fitPoints([
        ...r.path,
        for (final t in r.targets) ?t.center,
        ?_me,
      ]);
    });
  }

  void _pickAi(String key, AIRoute r) => setState(() {
        _goal = 'ai';
        _aiSel = key;
        _aiRoute = r;
      });

  Widget _aiTile(AIRoute r, String key) {
    final selected = _goal == 'ai' && _aiSel == key;
    return _GoalTile(
      key: ValueKey('ai-route-$key'),
      selected: selected,
      color: aiRouteColor(r.type),
      icon: aiRouteIcon(r.type),
      title: r.title.isEmpty ? 'AI 推荐路线' : r.title,
      sub: r.subtitle.isNotEmpty ? r.subtitle : aiRouteStats(r),
      onTap: () => _pickAi(key, r),
      extra: selected
          ? _RouteDetail(
              route: r,
              distance: key != 'chat' && r.type == 'loop'
                  ? _Choices(values: const [3, 5, 10], selected: _aiKm, unit: 'km', onPick: (v) => setState(() => _aiKm = v))
                  : null,
            )
          : null,
    );
  }

  /// The AI goal tiles (route from the assistant first, then
  /// `GET /v1/ai/routes`), with loading / empty / error states. Also
  /// resolves [_aiRoute] for the current selection.
  List<Widget> _aiGoals() {
    final out = <Widget>[];
    final chat = widget.aiRoute;
    if (chat != null) out.add(_aiTile(chat, 'chat'));
    if (!ref.watch(aiEnabledProvider)) return out;
    final me = _me;
    if (me == null) {
      out.add(_locating
          ? const _AiStatusTile(text: 'AI 推荐路线 · 正在定位…', loading: true)
          : _AiStatusTile(text: '定位后才能推荐 AI 路线', action: '重试', onAction: _locate));
      return out;
    }
    final q = aiRoutesQuery(me, _sport, _aiKm);
    final async = ref.watch(aiRoutesProvider(q));
    async.when(
      skipLoadingOnRefresh: false,
      loading: () => out.add(const _AiStatusTile(text: 'AI 正在按你的位置和配速规划路线…', loading: true)),
      error: (e, _) => out.add(_AiStatusTile(
        text: ApiException.from(e).code == 'ai_unavailable' ? 'AI 路线暂时不可用' : 'AI 路线加载失败：${errorText(e)}',
        action: '重试',
        onAction: () => ref.invalidate(aiRoutesProvider(q)),
      )),
      data: (r) {
        if (_aiSel != null && _aiSel != 'chat') {
          final same = r.items.where((x) => x.type == _aiSel).firstOrNull;
          if (same != null) {
            _aiRoute = same;
          } else if (_goal == 'ai') {
            // The selected kind is gone after a refresh: back to free.
            _goal = 'free';
            _aiSel = null;
            _aiRoute = null;
          }
        }
        if (r.items.isEmpty) {
          out.add(const _AiStatusTile(text: '附近暂时没有可推荐的 AI 路线，先自由圈地吧'));
        }
        for (final route in r.items) {
          out.add(_aiTile(route, route.type));
        }
      },
    );
    return out;
  }

  @override
  Widget build(BuildContext context) {
    const sports = ['run', 'walk', 'ride', 'hike'];
    final aiGoals = _aiGoals();
    _fitPreview();
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
                        controller: _preview,
                        interactive: false,
                        initialCenter: _me ?? const LatLng(31.2304, 121.4737),
                        initialZoom: 15.5,
                        layers: _previewLayers(),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      bottom: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: LL.night.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(16)),
                        child: Row(children: [
                          Icon(Icons.circle, color: _shownRoute == null ? LL.lime : aiRouteColor(_shownRoute!.type), size: 10),
                          const SizedBox(width: 6),
                          Text(
                            _shownRoute == null
                                ? '自由圈地 · 轨迹一交叉就占领'
                                : '${_shownRoute!.title} · ${Fmt.km(_shownRoute!.distanceM, digits: 1)} km',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 18),
              Row(children: [
                const Expanded(child: Text('本次目标', style: TextStyle(color: LL.text2))),
                if (ref.watch(aiEnabledProvider) && _me != null)
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: LL.lavender, visualDensity: VisualDensity.compact),
                    onPressed: () => ref.invalidate(aiRoutesProvider(aiRoutesQuery(_me!, _sport, _aiKm))),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('刷新 AI 路线'),
                  ),
              ]),
              const SizedBox(height: 6),
              _GoalTile(
                selected: _goal == 'free',
                color: LL.lavender,
                icon: Icons.gesture_rounded,
                title: '自由圈地 · 推荐',
                sub: '随便跑，轨迹一交叉就自动圈地，可连圈多块',
                onTap: () => setState(() => _goal = 'free'),
              ),
              ...aiGoals,
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
    super.key,
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

/// Loading / empty / error row in the 本次目标 list.
class _AiStatusTile extends StatelessWidget {
  const _AiStatusTile({required this.text, this.loading = false, this.action, this.onAction});
  final String text;
  final bool loading;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: LL.card,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: LL.border),
        ),
        child: Row(children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(color: Color(0xFF26223A), shape: BoxShape.circle),
            child: loading
                ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2, color: LL.lavender))
                : const Icon(Icons.auto_awesome_rounded, color: LL.lavender),
          ),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: const TextStyle(color: LL.text2, fontSize: 13))),
          if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
        ]),
      ),
    );
  }
}

/// Selected AI route: stats, the one-line reason (AI-labelled), targets and
/// the distance choice for loops.
class _RouteDetail extends StatelessWidget {
  const _RouteDetail({required this.route, this.distance});
  final AIRoute route;
  final Widget? distance;

  @override
  Widget build(BuildContext context) {
    final r = route;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(aiRouteStats(r), style: const TextStyle(fontWeight: FontWeight.w800)),
      if (r.reason.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(r.reason, style: const TextStyle(color: Color(0xFFD6D6DD), fontSize: 13, height: 1.5)),
        if (r.aiGenerated) const Padding(padding: EdgeInsets.only(top: 4), child: AILabel()),
      ],
      for (final t in r.targets)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(
              switch (t.type) { 'boss' => Icons.whatshot_rounded, 'chest' => Icons.inventory_2_outlined, _ => Icons.flag_outlined },
              size: 15,
              color: LL.text2,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(t.note.isEmpty ? t.name : '${t.name} · ${t.note}', style: const TextStyle(color: LL.text2, fontSize: 12)),
            ),
          ]),
        ),
      if (distance != null) ...[
        const SizedBox(height: 10),
        const Text('闭环距离', style: TextStyle(color: LL.text3, fontSize: 12)),
        const SizedBox(height: 6),
        distance!,
      ],
    ]);
  }
}
