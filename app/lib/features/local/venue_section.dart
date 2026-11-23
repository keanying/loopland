import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/local_api.dart';
import '../../api/local_models.dart';
import '../../auth/auth_controller.dart';
import '../../claim/geo.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../run/location_source.dart';
import '../../run/run_controller.dart' show locationSourceProvider;
import '../../widgets/l_icons.dart';
import 'venue_checkin.dart';
import 'venue_widgets.dart';

/// Nearby venues (check-in points and bookable venues) for the start page.
final nearbyVenuesProvider = FutureProvider.autoDispose<(LatLng?, List<Venue>)>((ref) async {
  final near = await _locate(ref);
  final page = await ref.watch(localApiProvider).venues(near: near, radiusM: 5000);
  return (near, page.items);
});

/// Same as `quietLocation` (place_picker.dart), for a provider.
Future<LatLng?> _locate(Ref ref) async {
  try {
    final src = ref.read(locationSourceProvider);
    if (await src.ensurePermission() != LocationPermissionResult.granted) return null;
    final f = await src.current().timeout(const Duration(seconds: 8));
    return f == null ? null : LatLng(f.lat, f.lng);
  } catch (_) {
    return null;
  }
}

/// 开始页「场馆球类」（C-07 / C-08）：附近场馆、签到按钮、扫码签到、订场入口。
class VenueCheckinSection extends ConsumerStatefulWidget {
  const VenueCheckinSection({super.key});
  @override
  ConsumerState<VenueCheckinSection> createState() => _VenueCheckinSectionState();
}

class _VenueCheckinSectionState extends ConsumerState<VenueCheckinSection> {
  final _busy = <int>{};

  Future<void> _checkin(Venue v) async {
    setState(() => _busy.add(v.id));
    final r = await VenueCheckin.byLocation(context, ref, v);
    if (!mounted) return;
    setState(() => _busy.remove(v.id));
    if (r != null) ref.invalidate(nearbyVenuesProvider);
  }

  Future<void> _scan() async {
    final r = await VenueCheckin.byQr(context, ref);
    if (r != null && mounted) ref.invalidate(nearbyVenuesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(nearbyVenuesProvider);
    final me = ref.watch(userProvider);
    final energy = ref.watch(configProvider).value?.energyFor('venue')?.text;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(28)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('场馆签到', style: TextStyle(color: LL.ink, fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text(
                '${energy ?? '每次签到 20 能量'} · 馆主积分 +10\n每周积分第一成为馆主，头像挂在地图据点上',
                style: const TextStyle(color: Color(0xFF2A2440), fontSize: 13, height: 1.45),
              ),
            ]),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            key: const Key('start_scan'),
            style: FilledButton.styleFrom(backgroundColor: LL.ink, foregroundColor: LL.lavender, minimumSize: const Size(0, 48)),
            onPressed: _scan,
            icon: const LIcon(LIcons.scan),
            label: const Text('扫码'),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      Row(children: [
        const Expanded(child: Text('附近场馆', style: TextStyle(color: LL.text2, fontWeight: FontWeight.w700, fontSize: 15))),
        TextButton.icon(
          onPressed: () => context.push('/local'),
          icon: const LIcon(LIcons.calendarCheck, size: 18),
          label: const Text('订场'),
        ),
      ]),
      async.when(
        loading: () => const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        error: (e, _) => ErrorBox(error: e, onRetry: () => ref.invalidate(nearbyVenuesProvider)),
        data: (r) {
          final (near, list) = r;
          if (list.isEmpty) {
            return LLCard(
              child: Text(near == null ? '没有拿到定位。可以扫场馆里的圈圈二维码签到。' : '5 公里内还没有圈圈场馆，可以扫场馆二维码签到',
                  style: const TextStyle(color: LL.text2)),
            );
          }
          return Column(children: [
            for (final v in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: LLCard(
                  key: Key('start_venue_${v.id}'),
                  onTap: () => context.push('/venues/${v.id}'),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    VenueHeader(venue: v, me: me, showPrice: false),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: Text(
                          [v.sportsText, '本周 ${v.myWeekPoints} 分'].where((s) => s.isNotEmpty).join(' · '),
                          style: const TextStyle(color: LL.text3, fontSize: 12),
                        ),
                      ),
                      FilledButton(
                        key: Key('checkin_${v.id}'),
                        style: FilledButton.styleFrom(minimumSize: const Size(96, 40)),
                        onPressed: v.checkedInToday || _busy.contains(v.id) ? null : () => _checkin(v),
                        child: Text(v.checkedInToday ? '今日已签' : '签到'),
                      ),
                    ]),
                  ]),
                ),
              ),
          ]);
        },
      ),
    ]);
  }
}
