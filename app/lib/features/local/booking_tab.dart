import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_common.dart' show CursorPager;
import '../../api/gathering_api.dart';
import '../../api/gathering_models.dart';
import '../../api/local_api.dart';
import '../../api/local_models.dart';
import '../../api/models.dart' show User;
import '../../auth/auth_controller.dart';
import '../../claim/geo.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/cursor_list.dart';
import '../../widgets/l_icons.dart';
import '../community/place_picker.dart' show quietLocation;
import 'booking_flow.dart';
import 'venue_widgets.dart';

/// Sport chips of the 订场 tab: 全部 + the contract's sports.
final bookingSportKeys = ['', ...venueSportNames.keys];

/// 订场（E-03）：运动分类、按距离的合作场馆、馆主、时段、价格、下单支付。
class BookingTab extends ConsumerStatefulWidget {
  const BookingTab({super.key, this.initialSport = '', this.now});
  final String initialSport;

  /// Fixed clock for tests.
  final DateTime Function()? now;

  @override
  ConsumerState<BookingTab> createState() => _BookingTabState();
}

class _BookingTabState extends ConsumerState<BookingTab> {
  late int _sport = bookingSportKeys.indexOf(widget.initialSport).clamp(0, bookingSportKeys.length - 1);
  LatLng? _near;
  bool _located = false;
  int? _open;
  bool _openTouched = false;
  Meetup? _tip;
  final _panels = <int, GlobalKey<VenueBookingPanelState>>{};

  late final CursorPager<Venue> _pager = CursorPager((cursor) => ref
      .read(localApiProvider)
      .venues(sport: bookingSportKeys[_sport], near: _near, bookable: true, cursor: cursor));

  @override
  void initState() {
    super.initState();
    _pager.addListener(_onPage);
    _locate();
  }

  @override
  void dispose() {
    _pager.removeListener(_onPage);
    _pager.dispose();
    super.dispose();
  }

  /// The nearest venue starts expanded (design: first card open).
  void _onPage() {
    if (!_openTouched && _open == null && _pager.items.isNotEmpty) setState(() => _open = _pager.items.first.id);
  }

  Future<void> _locate() async {
    final p = await quietLocation(ref);
    if (!mounted) return;
    setState(() {
      _near = p;
      _located = true;
    });
    _pager.refresh();
    _loadTip();
  }

  /// 「推荐」: a nearby ball meetup that still has spots (rule-based; no AI).
  Future<void> _loadTip() async {
    try {
      final page = await ref.read(gatheringApiProvider).meetups(type: 'ball', near: _near);
      final now = (widget.now ?? DateTime.now)();
      final sport = bookingSportKeys[_sport];
      final name = sport.isEmpty ? null : venueSportName(sport);
      final open = page.items.where((m) =>
          m.status == 'open' &&
          !m.joined &&
          m.capacity > m.joinedCount &&
          (m.startTime?.isAfter(now) ?? false) &&
          (m.distanceM == null || m.distanceM! <= 5000));
      // Prefer one that mentions the selected sport.
      final pick = (name == null ? null : open.where((m) => '${m.title}${m.description}'.contains(name)).firstOrNull) ?? open.firstOrNull;
      if (mounted) setState(() => _tip = pick);
    } catch (_) {
      if (mounted) setState(() => _tip = null);
    }
  }

  void _pickSport(int i) {
    setState(() {
      _sport = i;
      _open = null;
      _openTouched = false;
    });
    _pager.refresh();
    _loadTip();
  }

  String _tipText(Meetup m) {
    final spots = m.capacity - m.joinedCount;
    final now = (widget.now ?? DateTime.now)();
    final t = m.startTime?.toLocal();
    var when = '';
    if (t != null) {
      final today = DateTime(now.year, now.month, now.day);
      final d = DateTime(t.year, t.month, t.day).difference(today).inDays;
      final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      when = switch (d) {
        0 => t.hour >= 18 ? '今晚 $hm ' : '今天 $hm ',
        1 => '明天 $hm ',
        _ => '${t.month}/${t.day} $hm ',
      };
    }
    final dist = m.distanceM == null ? '' : '，离你 ${Fmt.distance(m.distanceM!)}';
    final need = m.title.contains('还差') ? '' : ' 还差 $spots 人';
    return '$when${m.title}$need$dist，去组局看看';
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(userProvider);
    final header = <Widget>[
      SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: bookingSportKeys.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final sel = i == _sport;
            final k = bookingSportKeys[i];
            return Semantics(
              button: true,
              selected: sel,
              child: GestureDetector(
                key: Key('sport_${k.isEmpty ? 'all' : k}'),
                onTap: () => _pickSport(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: sel ? LL.lime : LL.card2, borderRadius: BorderRadius.circular(22)),
                  child: Text(k.isEmpty ? '全部' : venueSportName(k),
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: sel ? LL.ink : const Color(0xFFC9C9D1))),
                ),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 12),
      if (_tip != null) ...[_tipCard(_tip!), const SizedBox(height: 12)],
      if (_located && _near == null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            const LIcon(LIcons.pinOff, color: LL.text3, size: 16),
            const SizedBox(width: 6),
            const Expanded(child: Text('没有拿到定位，暂不按距离排序', style: TextStyle(color: LL.text3, fontSize: 12))),
            TextButton(onPressed: _locate, child: const Text('重新定位')),
          ]),
        ),
    ];
    if (!_located) {
      return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        ...header,
        const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
      ]);
    }
    return CursorListView<Venue>(
      pager: _pager,
      header: header,
      empty: '附近还没有可预订的${_sport == 0 ? '' : venueSportName(bookingSportKeys[_sport])}场馆',
      itemBuilder: (context, v, _) => _venueCard(v, me),
    );
  }

  Widget _tipCard(Meetup m) => Semantics(
        button: true,
        label: '推荐组局',
        child: GestureDetector(
          key: const Key('booking_tip'),
          onTap: () => context.push('/meetups/${m.id}'),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(
              color: const Color(0xFF26223A),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: LL.lavender, width: 1.2),
            ),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(14)),
                child: const Text('推荐', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: 12)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(_tipText(m), style: const TextStyle(height: 1.45))),
              const LIcon(LIcons.chevronRight, color: LL.text2),
            ]),
          ),
        ),
      );

  Widget _venueCard(Venue v, User? me) {
    final open = _open == v.id;
    final color = venueColor(v.id);
    final panelKey = _panels.putIfAbsent(v.id, GlobalKey<VenueBookingPanelState>.new);
    return Container(
      key: Key('venue_${v.id}'),
      decoration: BoxDecoration(
        color: LL.card,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: open ? color : LL.border, width: open ? 1.5 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: () => setState(() {
            _openTouched = true;
            _open = open ? null : v.id;
          }),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: VenueHeader(venue: v, me: me, onTapName: null),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              VenueBookingPanel(
                key: panelKey,
                venue: v,
                now: widget.now,
                onConfirm: (sel) => bookVenue(context, ref,
                    venue: v, selection: sel, onSlotTaken: () => panelKey.currentState?.reload()).then((b) {
                  if (b != null) panelKey.currentState?.reload();
                }),
              ),
              Align(
                child: TextButton.icon(
                  onPressed: () => context.push('/venues/${v.id}'),
                  icon: const LIcon(LIcons.trophy, size: 18),
                  label: const Text('场馆详情 · 馆主榜'),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}
