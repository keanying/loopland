import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/local_models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../map/territory_map.dart';
import '../../claim/geo.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import '../community/gathering_widgets.dart' show SectionHeader, Tag;
import '../social/social_widgets.dart' show UserAvatar, openProfile;
import 'booking_flow.dart';
import 'local_providers.dart';
import 'product_widgets.dart' show ProductSection;
import 'venue_checkin.dart';
import 'venue_widgets.dart';

/// 场馆详情（C-07 / C-08 / E-03）：团购 / 套餐、馆主、本周积分榜、签到（定位 / 扫码）、订场。
class VenueDetailPage extends ConsumerStatefulWidget {
  const VenueDetailPage({super.key, required this.venueId, this.now});
  final int venueId;
  final DateTime Function()? now;
  @override
  ConsumerState<VenueDetailPage> createState() => _VenueDetailPageState();
}

class _VenueDetailPageState extends ConsumerState<VenueDetailPage> {
  bool _busy = false;

  Future<void> _checkin(Venue v, {bool qr = false}) async {
    setState(() => _busy = true);
    if (qr) {
      await VenueCheckin.byQr(context, ref);
    } else {
      await VenueCheckin.byLocation(context, ref, v);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _book(Venue v) async {
    final key = GlobalKey<VenueBookingPanelState>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: LL.card,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(v.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 12),
            VenueBookingPanel(
              key: key,
              venue: v,
              now: widget.now,
              onConfirm: (sel) async {
                final b = await bookVenue(c, ref, venue: v, selection: sel, onSlotTaken: () => key.currentState?.reload());
                if (b != null && c.mounted) Navigator.pop(c);
              },
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(venueProvider(widget.venueId));
    final me = ref.watch(userProvider);
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<Venue>(
          value: async,
          onRetry: () => ref.invalidate(venueProvider(widget.venueId)),
          data: (v) => Column(children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async => ref.invalidate(venueProvider(widget.venueId)),
                child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                  BackHeader(title: '场馆', subtitle: v.district.isEmpty ? null : v.district),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      LLCard(child: VenueHeader(venue: v, me: me)),
                      const SizedBox(height: 10),
                      Wrap(spacing: 8, runSpacing: 6, children: [
                        for (final s in v.sports) Tag(venueSportName(s), color: venueColor(v.id)),
                        if (!v.bookable) const Tag('仅签到'),
                        if (v.discountText != null) Tag('馆主订场${v.discountText}', color: LL.lime),
                      ]),
                      if (v.lat != 0) ...[
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(LL.radius),
                          child: SizedBox(
                            height: 140,
                            child: TerritoryMapView(
                              initialCenter: LatLng(v.lat, v.lng),
                              initialZoom: 15.5,
                              interactive: false,
                              layers: MapLayers(myLocation: LatLng(v.lat, v.lng)),
                            ),
                          ),
                        ),
                      ],
                      if (v.address.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(v.address, style: const TextStyle(color: LL.text2)),
                      ],
                      if (v.products.isNotEmpty)
                        ProductSection(products: v.products, merchantId: v.merchant?.id, merchantName: v.merchant?.name),
                      const SectionHeader('本周馆主'),
                      _ownerCard(v, me?.id, me?.crew?.id),
                      const SizedBox(height: 10),
                      LLCard(
                        color: LL.card2,
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('我的本周积分 ${v.myWeekPoints}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                              Text(v.checkedInToday ? '今天已签到，明天再来' : '每天签到 1 次 · ${v.checkinRadiusM.round()} 米内定位或扫码',
                                  style: const TextStyle(color: LL.text2, fontSize: 12)),
                            ]),
                          ),
                          if (v.checkedInToday) const Tag('今日已签', color: LL.lime),
                        ]),
                      ),
                      SectionHeader('本周积分榜 · 周一 00:00 结算'),
                      if (v.weekRank.isEmpty)
                        const LLCard(child: Text('本周还没有人签到，先签到先得', style: TextStyle(color: LL.text2)))
                      else
                        for (final e in v.weekRank) _rankRow(e, me?.id),
                    ]),
                  ),
                ]),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: LL.border))),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('venue_scan'),
                    onPressed: _busy || v.checkedInToday ? null : () => _checkin(v, qr: true),
                    icon: const LIcon(LIcons.scan, size: 18),
                    label: const Text('扫码'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    key: const Key('venue_checkin'),
                    onPressed: _busy || v.checkedInToday ? null : () => _checkin(v),
                    child: Text(v.checkedInToday ? '今日已签到' : '定位签到 +能量'),
                  ),
                ),
                if (v.bookable) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      key: const Key('venue_book'),
                      style: FilledButton.styleFrom(backgroundColor: LL.lavender),
                      onPressed: () => _book(v),
                      child: const Text('订场'),
                    ),
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _ownerCard(Venue v, int? meId, int? myCrew) {
    final o = v.owner;
    if (o == null) {
      return const LLCard(
        child: Row(children: [
          LIcon(LIcons.trophy, color: LL.text3, size: 36),
          SizedBox(width: 12),
          Expanded(child: Text('暂无馆主 · 先签到先得\n本周积分第一的人成为下周馆主', style: TextStyle(color: LL.text2, height: 1.5))),
        ]),
      );
    }
    final mine = o.user.id == meId;
    final crewmate = !mine && myCrew != null && o.user.crew?.id == myCrew;
    return LLCard(
      key: const Key('venue_owner'),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: LL.yellow, width: 2.5)),
          child: UserAvatar(user: o.user, size: 52, onTap: () => openProfile(context, o.user)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(mine ? '你' : o.user.nickname, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18))),
              if (crewmate) ...[const SizedBox(width: 8), const Tag('你的跑团', color: LL.lavender)],
            ]),
            Text(
              [
                '上周 ${o.points} 分',
                if (o.since != null) '${o.since} 起',
                if (o.user.crew != null) o.user.crew!.name,
              ].join(' · '),
              style: const TextStyle(color: LL.text2, fontSize: 13),
            ),
            if (mine && v.discountText != null)
              Text('馆主订场享${v.discountText}', style: const TextStyle(color: LL.lime, fontSize: 13)),
          ]),
        ),
        const LIcon(LIcons.crown, color: LL.yellow, size: 30),
      ]),
    );
  }

  Widget _rankRow(VenueRankEntry e, int? me) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: LLCard(
          color: e.user.id == me ? const Color(0xFF23271A) : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            SizedBox(
              width: 30,
              child: Text('${e.rank}', style: TextStyle(fontWeight: FontWeight.w900, color: e.rank <= 3 ? LL.lime : LL.text2)),
            ),
            UserAvatar(user: e.user, size: 36, onTap: () => openProfile(context, e.user)),
            const SizedBox(width: 10),
            Expanded(child: Text(e.user.id == me ? '${e.user.nickname}（我）' : e.user.nickname)),
            Text('${Fmt.thousands(e.points)} 分', style: const TextStyle(fontWeight: FontWeight.w900)),
          ]),
        ),
      );
}

/// Universal link `https://<domain>/v/<content>` (system camera scan): checks
/// in with the venue code, then shows the venue.
class VenueLinkPage extends ConsumerStatefulWidget {
  const VenueLinkPage({super.key, required this.payload});
  final String payload;
  @override
  ConsumerState<VenueLinkPage> createState() => _VenueLinkPageState();
}

class _VenueLinkPageState extends ConsumerState<VenueLinkPage> {
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _go());
  }

  Future<void> _go() async {
    final qr = parseVenueQr(widget.payload);
    if (qr == null) {
      setState(() => _error = '这不是圈圈场馆二维码');
      return;
    }
    await VenueCheckin.byPayload(context, ref, qr.payload);
    if (mounted) context.pushReplacement('/venues/${qr.venueId}');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            const BackHeader(title: '场馆签到'),
            Expanded(
              child: Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : Text(_error!, style: const TextStyle(color: LL.text2)),
              ),
            ),
          ]),
        ),
      );
}
