import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../map/territory_map.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';

final activityProvider =
    FutureProvider.autoDispose.family<Activity, int>((ref, id) => ref.watch(apiProvider).activity(id));

String statusText(String s) => switch (s) {
      'review' => '复核中',
      'voided' => '已作废',
      _ => '',
    };

LGlyph sportIcon(String s) => switch (s) {
      'run' => LIcons.run,
      'ride' => LIcons.bike,
      'hike' => LIcons.mountain,
      'walk' => LIcons.walk,
      'strength' => LIcons.dumbbell,
      'yoga' => LIcons.yoga,
      'rope' => LIcons.rope,
      _ => LIcons.flame,
    };

/// 运动记录列表（分页）。
class ActivitiesPage extends ConsumerStatefulWidget {
  const ActivitiesPage({super.key});
  @override
  ConsumerState<ActivitiesPage> createState() => _ActivitiesPageState();
}

class _ActivitiesPageState extends ConsumerState<ActivitiesPage> {
  final _items = <Activity>[];
  int _page = 0, _total = 1 << 30;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _more();
  }

  Future<void> _more() async {
    if (_loading || _items.length >= _total) return;
    setState(() => _loading = true);
    try {
      final p = await ref.read(apiProvider).activities(page: _page + 1);
      if (!mounted) return;
      setState(() {
        _page++;
        _items.addAll(p.items);
        _total = p.items.isEmpty ? _items.length : p.total;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '运动记录'),
          Expanded(
            child: _error != null && _items.isEmpty
                ? ErrorBox(error: _error!, onRetry: _more)
                : NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.extentAfter < 300) _more();
                      return false;
                    },
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: _items.length + 1,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        if (i == _items.length) {
                          if (_loading) return const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()));
                          if (_items.isEmpty) {
                            return const Padding(
                              padding: EdgeInsets.all(40),
                              child: Text('还没有运动记录，去跑一圈吧', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)),
                            );
                          }
                          return const SizedBox.shrink();
                        }
                        return ActivityTile(a: _items[i]);
                      },
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}

class ActivityTile extends StatelessWidget {
  const ActivityTile({super.key, required this.a});
  final Activity a;
  @override
  Widget build(BuildContext context) {
    final gps = gpsSports.contains(a.sport);
    final st = statusText(a.status);
    return LLCard(
      padding: const EdgeInsets.all(14),
      onTap: () => context.push('/activities/${a.id}'),
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: gps ? LL.lime : LL.lavender, shape: BoxShape.circle),
          child: LIcon(sportIcon(a.sport), color: LL.ink),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(
                gps ? '${sportName(a.sport)} ${Fmt.km(a.distanceM)} km' : '${sportName(a.sport)} ${Fmt.minutes(a.durationS)}',
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
              ),
              if (st.isNotEmpty) ...[const SizedBox(width: 8), ComingSoon(text: st)],
            ]),
            Text(
              [
                Fmt.dateTime(a.startedAt),
                if (gps) '配速 ${Fmt.pace(a.avgPaceSPerKm)}',
                if (a.claimedAreaM2 > 0) '+${Fmt.area(a.claimedAreaM2)}',
              ].join(' · '),
              style: const TextStyle(color: LL.text2, fontSize: 12),
            ),
          ]),
        ),
        Text('+${a.energyGranted}', style: const TextStyle(color: LL.yellow, fontWeight: FontWeight.w900)),
      ]),
    );
  }
}

/// 运动详情（含轨迹）。
class ActivityDetailPage extends ConsumerStatefulWidget {
  const ActivityDetailPage({super.key, required this.id});
  final int id;
  @override
  ConsumerState<ActivityDetailPage> createState() => _ActivityDetailPageState();
}

class _ActivityDetailPageState extends ConsumerState<ActivityDetailPage> {
  final _map = TerritoryMapController();

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(activityProvider(widget.id));
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<Activity>(
          value: async,
          onRetry: () => ref.invalidate(activityProvider(widget.id)),
          data: (a) {
            if (a.track.length >= 2) {
              WidgetsBinding.instance.addPostFrameCallback((_) => _map.fitPoints(a.track));
            }
            final gps = gpsSports.contains(a.sport);
            return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
              BackHeader(title: sportName(a.sport), subtitle: Fmt.dateTime(a.startedAt)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (a.track.length >= 2)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: SizedBox(
                        height: 300,
                        child: TerritoryMapView(
                          controller: _map,
                          initialCenter: a.track.first,
                          layers: MapLayers(track: a.track),
                        ),
                      ),
                    ),
                  if (statusText(a.status).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: LLCard(
                        child: Text(a.status == 'review' ? '这条记录正在人工复核，通过后补发能量并圈地。' : '这条记录已被风控作废，不计能量和圈地。',
                            style: const TextStyle(color: LL.text2)),
                      ),
                    ),
                  const SizedBox(height: 12),
                  LLCard(
                    child: Wrap(runSpacing: 16, children: [
                      if (gps) ...[
                        _half(StatBox(value: Fmt.km(a.distanceM), unit: 'km', label: '距离')),
                        _half(StatBox(value: Fmt.pace(a.avgPaceSPerKm), label: '平均配速')),
                      ] else
                        _half(StatBox(value: Fmt.amount(a.amount ?? 0, a.sport == 'rope' ? 'count' : 'min'), unit: a.sport == 'rope' ? '次' : '分钟', label: '训练量')),
                      _half(StatBox(value: Fmt.duration(a.durationS), label: '时长')),
                      _half(StatBox(value: '+${a.energyGranted}', label: '能量')),
                      if (gps) _half(StatBox(value: Fmt.area(a.claimedAreaM2), label: '圈地面积')),
                    ]),
                  ),
                  if (a.claims.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Text('圈地', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    for (final c in a.claims)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: LIcon(c.kind == 'capture' ? LIcons.flagFilled : LIcons.plot,
                            color: c.kind == 'capture' ? LL.orange : LL.lime),
                        title: Text('${c.kind == 'capture' ? '抢下' : '新圈'} 领地 #${c.territoryId}'),
                        trailing: Text(Fmt.area(c.areaM2)),
                        onTap: () => context.push('/city/${c.territoryId}'),
                      ),
                  ],
                ]),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _half(Widget w) => FractionallySizedBox(widthFactor: 0.5, child: w);
}
