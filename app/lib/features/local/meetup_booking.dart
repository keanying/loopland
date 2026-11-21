import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_common.dart' show CursorPager;
import '../../api/gathering_models.dart';
import '../../api/local_api.dart';
import '../../api/local_models.dart';
import '../../auth/auth_controller.dart';
import '../../claim/geo.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/cursor_list.dart';
import '../community/place_picker.dart' show quietLocation;
import 'booking_flow.dart';
import 'local_providers.dart';
import 'venue_widgets.dart';

/// Ball sports offered when booking for a 约球 meetup (D-11).
const ballSports = ['badminton', 'pickleball', 'tennis', 'basketball', 'football'];

/// Venue + consecutive slots picked for a meetup.
typedef VenuePick = ({Venue venue, SlotSelection selection});

Future<VenuePick?> pickVenueSlots(BuildContext context, {DateTime Function()? now}) =>
    Navigator.of(context).push<VenuePick>(MaterialPageRoute(builder: (_) => VenuePickerPage(now: now)));

/// 选择场馆和时段（约球订场 D-11）：附近合作场馆（球类）、日期、连续时段。
class VenuePickerPage extends ConsumerStatefulWidget {
  const VenuePickerPage({super.key, this.now});
  final DateTime Function()? now;
  @override
  ConsumerState<VenuePickerPage> createState() => _VenuePickerPageState();
}

class _VenuePickerPageState extends ConsumerState<VenuePickerPage> {
  int _sport = 0;
  LatLng? _near;
  bool _located = false;
  int? _open;

  late final CursorPager<Venue> _pager = CursorPager(
      (cursor) => ref.read(localApiProvider).venues(sport: ballSports[_sport], near: _near, bookable: true, cursor: cursor));

  @override
  void initState() {
    super.initState();
    _locate();
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    final p = await quietLocation(ref);
    if (!mounted) return;
    setState(() {
      _near = p;
      _located = true;
    });
    _pager.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(userProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '选择场馆和时段', subtitle: '发起后用微信 / 支付宝支付场地费'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ChipTabs(
              labels: [for (final s in ballSports) venueSportName(s)],
              index: _sport,
              onChanged: (i) {
                setState(() {
                  _sport = i;
                  _open = null;
                });
                _pager.refresh();
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: !_located
                ? const Center(child: CircularProgressIndicator())
                : CursorListView<Venue>(
                    pager: _pager,
                    empty: '附近没有可预订的${venueSportName(ballSports[_sport])}场馆',
                    itemBuilder: (context, v, _) {
                      final open = _open == v.id;
                      return LLCard(
                        key: Key('pick_venue_${v.id}'),
                        onTap: open ? null : () => setState(() => _open = v.id),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          VenueHeader(venue: v, me: me),
                          if (open) ...[
                            const SizedBox(height: 12),
                            VenueBookingPanel(
                              venue: v,
                              now: widget.now,
                              confirmVerb: '选定',
                              onConfirm: (sel) => Navigator.of(context).pop<VenuePick>((venue: v, selection: sel)),
                            ),
                          ],
                        ]),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}

/// 组局详情的「场地」卡：已订的场馆和时段；发起人可以给约球局订场。
class MeetupBookingCard extends ConsumerStatefulWidget {
  const MeetupBookingCard({super.key, required this.meetup, this.now});
  final Meetup meetup;
  final DateTime Function()? now;
  @override
  ConsumerState<MeetupBookingCard> createState() => _MeetupBookingCardState();
}

class _MeetupBookingCardState extends ConsumerState<MeetupBookingCard> {
  Future<void> _book() async {
    final m = widget.meetup;
    final pick = await pickVenueSlots(context, now: widget.now);
    if (pick == null || !mounted) return;
    final b = await bookVenue(context, ref, venue: pick.venue, selection: pick.selection, meetupId: m.id);
    if (b != null) ref.invalidate(myBookingsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.meetup;
    final me = ref.watch(userProvider)?.id;
    final creator = m.isCreator(me);
    var booking = m.booking;
    Booking? mine;
    if (booking == null && creator) {
      // The contract has no booking field on Meetup; the creator finds their
      // own booking by meetup_id.
      final list = ref.watch(myBookingsProvider('')).value ?? const <Booking>[];
      mine = list.where((b) => b.meetupId == m.id && b.status != 'cancelled' && b.status != 'expired' && b.status != 'refunded').firstOrNull;
      if (mine != null) booking = MeetupBooking.of(mine);
    }
    if (booking != null) {
      final b = booking;
      return LLCard(
        key: const Key('meetup_booking'),
        onTap: mine != null ? () => context.push('/me/bookings/${mine!.id}') : (b.venue == null ? null : () => context.push('/venues/${b.venue!.id}')),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.stadium_outlined, color: LL.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('已订场 · ${b.venue?.name ?? '场馆'}', style: const TextStyle(fontWeight: FontWeight.w900)),
              Text(slotRangeText(b.start, b.end), style: const TextStyle(color: LL.text2, fontSize: 13)),
              if (b.status == 'pending_pay') const Text('待支付', style: TextStyle(color: LL.yellow, fontSize: 12)),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: LL.text3),
        ]),
      );
    }
    final live = m.status == 'open' || m.status == 'full';
    if (!creator || m.type != 'ball' || !live) return const SizedBox.shrink();
    return LLCard(
      key: const Key('meetup_book_cta'),
      onTap: _book,
      child: const Row(children: [
        Icon(Icons.event_available_rounded, color: LL.lime),
        SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('给这个局订场', style: TextStyle(fontWeight: FontWeight.w900)),
            Text('订合作场馆的时段，局里的人都能看到场地', style: TextStyle(color: LL.text2, fontSize: 12)),
          ]),
        ),
        Icon(Icons.chevron_right_rounded, color: LL.text3),
      ]),
    );
  }
}
