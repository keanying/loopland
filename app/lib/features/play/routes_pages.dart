import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../claim/geo.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../map/territory_map.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import 'play_providers.dart';
import 'play_widgets.dart';

String _cpState(RouteCheckpoint c) => c.isDone ? '已打卡' : (c.isNext ? '下一站' : '待打卡');

/// 城市定向：路线列表。
class RoutesPage extends ConsumerWidget {
  const RoutesPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(routesProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '城市定向', subtitle: '按顺序打卡城市地标，可以分多次跑完'),
          Expanded(
            child: AsyncBody<List<CityRoute>>(
              value: async,
              onRetry: () => ref.invalidate(routesProvider),
              data: (list) => RefreshIndicator(
                onRefresh: () => ref.refresh(routesProvider.future),
                child: list.isEmpty
                    ? ListView(children: const [
                        SizedBox(height: 80),
                        Center(child: Text('暂时没有开放的定向路线', style: TextStyle(color: LL.text2))),
                      ])
                    : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
                        for (final r in list)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _RouteCard(route: r, onTap: () => context.push('/routes/${r.id}')),
                          ),
                      ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({required this.route, required this.onTap});
  final CityRoute route;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final r = route;
    final n = r.checkpoints.length;
    return LLCard(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(color: LL.sky, shape: BoxShape.circle),
            child: const LIcon(LIcons.compass, color: LL.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
              Text('$n 个点 · ${periodText(r.startsAt, r.endsAt)}', style: const TextStyle(color: LL.text2, fontSize: 12)),
            ]),
          ),
          r.completed ? const Tag('已完成', color: LL.lime, fg: LL.ink) : Tag('${r.doneCount}/$n', color: LL.card2, fg: LL.sky),
        ]),
        if (r.description.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(r.description, style: const TextStyle(color: LL.text2, height: 1.5)),
        ],
        const SizedBox(height: 10),
        LLProgress(value: n == 0 ? 0 : r.doneCount / n, color: LL.sky),
        const SizedBox(height: 8),
        Row(children: [
          if (r.next != null) Expanded(child: Text('下一站：${r.next!.name}', style: const TextStyle(fontWeight: FontWeight.w700))) else const Spacer(),
          const LIcon(LIcons.bolt, color: LL.yellow, size: 16),
          Text('+${r.rewardEnergy}', style: const TextStyle(fontWeight: FontWeight.w900)),
        ]),
      ]),
    );
  }
}

/// 路线详情：地图上有序打卡点（已打卡 / 下一站 / 待打卡）+ 列表 +「去打卡」。
class RouteDetailPage extends ConsumerWidget {
  const RouteDetailPage({super.key, required this.routeId});
  final int routeId;

  static MapObjects objectsFor(CityRoute r) => MapObjects(checkpoints: [
        for (final c in r.checkpoints)
          if (c.center != null)
            MapCheckpoint(routeId: r.id, index: c.index, name: c.name, center: c.center!, radiusM: c.radiusM, state: c.state),
      ]);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(routeProvider(routeId));
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<CityRoute>(
          value: async,
          onRetry: () => ref.invalidate(routeProvider(routeId)),
          data: (r) {
            final pts = [for (final c in r.checkpoints) if (c.center != null) c.center!];
            return Column(children: [
              BackHeader(title: r.name, subtitle: '${r.checkpoints.length} 个打卡点 · 已完成 ${r.doneCount}'),
              Expanded(
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                  if (pts.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: SizedBox(height: 240, child: _RouteMap(objects: objectsFor(r), path: pts)),
                    ),
                  if (r.description.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(r.description, style: const TextStyle(color: LL.text2, height: 1.5)),
                  ],
                  const SectionTitle('打卡点'),
                  for (final c in r.checkpoints) _CheckpointRow(c: c, last: c == r.checkpoints.last),
                  const SizedBox(height: 10),
                  LLCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(children: [
                      const LIcon(LIcons.bolt, color: LL.yellow),
                      const SizedBox(width: 6),
                      Expanded(child: Text('全部到达奖励 ${r.rewardEnergy} 能量', style: const TextStyle(fontWeight: FontWeight.w800))),
                      if (r.completed) Text('已于 ${Fmt.dateTime(r.completedAt)} 完成', style: const TextStyle(color: LL.lime, fontSize: 12)),
                    ]),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: r.completed ? null : () => context.push('/start/gps?sport=run'),
                    icon: const LIcon(LIcons.flag),
                    label: Text(r.completed ? '这条路线已完成' : (r.next == null ? '去打卡' : '去打卡 · 下一站 ${r.next!.name}')),
                  ),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

class _RouteMap extends StatefulWidget {
  const _RouteMap({required this.objects, required this.path});
  final MapObjects objects;
  final List<LatLng> path;
  @override
  State<_RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<_RouteMap> {
  final _ctrl = TerritoryMapController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ctrl.fitPoints(widget.path));
  }

  @override
  Widget build(BuildContext context) => TerritoryMapView(
        controller: _ctrl,
        initialCenter: widget.path.first,
        layers: MapLayers(objects: widget.objects, routePath: widget.path),
        onObjectTap: (h) {
          if (h is CheckpointHit) toast(context, '第 ${h.checkpoint.index + 1} 站 · ${h.checkpoint.name}');
        },
      );
}

class _CheckpointRow extends StatelessWidget {
  const _CheckpointRow({required this.c, required this.last});
  final RouteCheckpoint c;
  final bool last;
  @override
  Widget build(BuildContext context) {
    final color = c.isDone ? LL.sky : (c.isNext ? LL.sky : LL.text3);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 34,
          child: Column(children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.isNext ? LL.sky : (c.isDone ? LL.ink : LL.night),
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 2),
              ),
              child: c.isDone
                  ? const LIcon(LIcons.check, size: 16, color: LL.sky)
                  : Text('${c.index + 1}', style: TextStyle(fontWeight: FontWeight.w900, color: c.isNext ? LL.ink : color, fontSize: 13)),
            ),
            if (!last) Expanded(child: Container(width: 2, color: c.isDone ? LL.sky : LL.border)),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16, top: 4),
            child: Row(children: [
              Expanded(
                child: Text(c.name,
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: c.isDone || c.isNext ? LL.text : LL.text2)),
              ),
              Tag(_cpState(c), color: c.isNext ? LL.sky : LL.card2, fg: c.isNext ? LL.ink : (c.isDone ? LL.sky : LL.text3)),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// 限时活动：规则（中文）、时间、奖励、完成状态。
class CampaignsPage extends ConsumerWidget {
  const CampaignsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(campaignsProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '限时活动', subtitle: '活动期间完成一次符合规则的运动，结算时自动判定'),
          Expanded(
            child: AsyncBody<List<Campaign>>(
              value: async,
              onRetry: () => ref.invalidate(campaignsProvider),
              data: (list) => RefreshIndicator(
                onRefresh: () => ref.refresh(campaignsProvider.future),
                child: list.isEmpty
                    ? ListView(children: const [
                        SizedBox(height: 80),
                        Center(child: Text('暂时没有进行中的活动', style: TextStyle(color: LL.text2))),
                      ])
                    : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
                        for (final c in list) Padding(padding: const EdgeInsets.only(bottom: 12), child: CampaignCard(c: c)),
                      ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class CampaignCard extends StatelessWidget {
  const CampaignCard({super.key, required this.c});
  final Campaign c;
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final notStarted = c.startsAt != null && now.isBefore(c.startsAt!);
    final ended = c.endsAt != null && !now.isBefore(c.endsAt!);
    final color = switch (c.type) { 'pace' => LL.lime, 'night_run' => LL.lavender, _ => LL.sky };
    final (stateText, stateColor, stateFg) = c.completed
        ? ('已完成', LL.lime, LL.ink)
        : notStarted
            ? ('未开始', LL.card2, LL.text2)
            : ended
                ? ('已结束', LL.card2, LL.text3)
                : ('进行中', LL.orange, LL.ink);
    final rules = c.rules.lines;
    return LLCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Tag(c.typeName, color: color, fg: LL.ink),
          const SizedBox(width: 8),
          Expanded(child: Text(periodText(c.startsAt, c.endsAt), style: const TextStyle(color: LL.text2, fontSize: 12))),
          Tag(stateText, color: stateColor, fg: stateFg),
        ]),
        const SizedBox(height: 10),
        Text(c.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
        if (c.description.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(c.description, style: const TextStyle(color: LL.text2, height: 1.5)),
        ],
        if (rules.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final r in rules)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                LIcon(c.completed ? LIcons.check : LIcons.chevronRight, size: 18, color: color),
                const SizedBox(width: 4),
                Expanded(child: Text(r, style: const TextStyle(height: 1.4))),
              ]),
            ),
        ],
        if (!c.completed && !ended && c.endsAt != null && !notStarted)
          Countdown(
            until: c.endsAt,
            builder: (_, left) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('还剩 ${formatCountdown(left)}', style: const TextStyle(color: LL.orange, fontSize: 12)),
            ),
          ),
        const SizedBox(height: 10),
        Row(children: [
          const LIcon(LIcons.bolt, color: LL.yellow, size: 18),
          Text('+${c.rewardEnergy} 能量', style: const TextStyle(fontWeight: FontWeight.w900)),
          if (c.rewardMedal != null) Text(' · 奖牌「${c.rewardMedal!.name}」', style: const TextStyle(fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('${c.participants} 人参加', style: const TextStyle(color: LL.text3, fontSize: 12)),
        ]),
      ]),
    );
  }
}
