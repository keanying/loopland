import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/local_api.dart';
import '../../api/local_models.dart';
import '../../api/models.dart' show User;
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'local_providers.dart';

const _venueColors = [LL.lavender, LL.pink, LL.sky, LL.lime, LL.orange, LL.yellow];

Color venueColor(int id) => _venueColors[id.abs() % _venueColors.length];

/// `18:00` in Asia/Shanghai.
String clockText(DateTime? t) {
  if (t == null) return '--:--';
  final s = shanghaiClock(t);
  return '${s.hour.toString().padLeft(2, '0')}:${s.minute.toString().padLeft(2, '0')}';
}

const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

/// 「11 月 21 日 周六 18:00–20:00」.
String slotRangeText(DateTime? a, DateTime? b) {
  if (a == null) return '-';
  final s = shanghaiClock(a);
  return '${s.month} 月 ${s.day} 日 周${_weekdays[s.weekday - 1]} ${clockText(a)}–${clockText(b)}';
}

/// 「距你 0.8 km · 室内 · 可租拍」.
String venueMeta(Venue v, {int maxTags = 2}) => [
      if (v.distanceM != null) '距你 ${Fmt.distance(v.distanceM!)}',
      ...v.tags.take(maxTags),
      if (v.distanceM == null && v.tags.isEmpty && v.district.isNotEmpty) v.district,
    ].join(' · ');

/// 馆主 line: 「馆主 · 夜跑兔（你的跑团）」/「馆主 · 暂无馆主 · 先签到先得」.
String ownerText(Venue v, User? me) {
  final o = v.owner;
  if (o == null) return '馆主 · 暂无馆主 · 先签到先得';
  if (me != null && o.user.id == me.id) return '馆主 · 你${v.discountText == null ? '' : ' · 订场${v.discountText}'}';
  final myCrew = me?.crew?.id;
  if (myCrew != null && o.user.crew?.id == myCrew) return '馆主 · ${o.user.nickname}（你的跑团）';
  return '馆主 · ${o.user.nickname}';
}

/// Coloured square with the venue's first character (design: 南 / 港 / 学).
class VenueInitial extends StatelessWidget {
  const VenueInitial({super.key, required this.venue, this.size = 48});
  final Venue venue;
  final double size;
  @override
  Widget build(BuildContext context) {
    final n = venue.name.trim();
    final ch = n.isEmpty ? '馆' : String.fromCharCodes(n.runes.take(1));
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: venueColor(venue.id), borderRadius: BorderRadius.circular(size * 0.33)),
      child: Text(ch, style: TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: size * 0.42)),
    );
  }
}

/// Name, meta, 馆主 line and price.
class VenueHeader extends StatelessWidget {
  const VenueHeader({super.key, required this.venue, required this.me, this.showPrice = true, this.onTapName});
  final Venue venue;
  final User? me;
  final bool showPrice;
  final VoidCallback? onTapName;
  @override
  Widget build(BuildContext context) {
    final v = venue;
    final color = venueColor(v.id);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      VenueInitial(venue: v),
      const SizedBox(width: 12),
      Expanded(
        child: GestureDetector(
          onTap: onTapName,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(v.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            if (venueMeta(v).isNotEmpty) Text(venueMeta(v), style: const TextStyle(color: LL.text2, fontSize: 13)),
            const SizedBox(height: 2),
            Text(ownerText(v, me), style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
      if (showPrice && v.bookable) ...[
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(Fmt.yuan(v.priceAmt), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          Text('/${v.priceUnitText}', style: const TextStyle(color: LL.text2, fontSize: 12)),
        ]),
      ],
    ]);
  }
}

/// Date strip (today + 6 days, Asia/Shanghai), slot grid, consecutive
/// selection (1–[maxSlots]) and the confirm button「先选一个时段」.
class VenueBookingPanel extends ConsumerStatefulWidget {
  const VenueBookingPanel({
    super.key,
    required this.venue,
    required this.onConfirm,
    this.confirmVerb = '确认预订',
    this.now,
    this.maxSlots = maxBookingSlots,
  });
  final Venue venue;
  final void Function(SlotSelection selection) onConfirm;
  final String confirmVerb;
  final DateTime Function()? now;
  final int maxSlots;

  @override
  ConsumerState<VenueBookingPanel> createState() => VenueBookingPanelState();
}

class VenueBookingPanelState extends ConsumerState<VenueBookingPanel> {
  int _day = 0;
  SlotSelection _sel = const SlotSelection([]);

  DateTime get _now => (widget.now ?? DateTime.now)();
  String _date(int i) => shanghaiDate(_now.add(Duration(days: i)));

  /// Drops the selection and reloads (e.g. after `slot_unavailable`).
  void reload() {
    setState(() => _sel = const SlotSelection([]));
    ref.invalidate(slotsProvider((widget.venue.id, _date(_day))));
  }

  String _dayLabel(int i) {
    if (i == 0) return '今天';
    if (i == 1) return '明天';
    final s = shanghaiClock(_now.add(Duration(days: i)));
    return '周${_weekdays[s.weekday - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final date = _date(_day);
    final slots = ref.watch(slotsProvider((widget.venue.id, date)));
    final d = shanghaiClock(_now.add(Duration(days: _day)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 54,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: 7,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final sel = i == _day;
            final s = shanghaiClock(_now.add(Duration(days: i)));
            return GestureDetector(
              key: Key('day_$i'),
              onTap: () => setState(() {
                _day = i;
                _sel = const SlotSelection([]);
              }),
              child: Container(
                width: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: sel ? LL.text : LL.card2,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_dayLabel(i), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: sel ? LL.ink : LL.text)),
                  Text('${s.month}/${s.day}', style: TextStyle(fontSize: 11, color: sel ? LL.ink : LL.text3)),
                ]),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 12),
      Text('${_dayLabel(_day)} ${d.month} 月 ${d.day} 日 · 选择时段（可连选 ${widget.maxSlots} 个）',
          style: const TextStyle(color: LL.text2, fontSize: 13)),
      const SizedBox(height: 10),
      slots.when(
        loading: () => const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
        error: (e, _) => ErrorBox(error: e, onRetry: reload),
        data: (day) => day.items.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text('这一天没有可预订的时段了', textAlign: TextAlign.center, style: TextStyle(color: LL.text3)),
              )
            : _grid(day.items),
      ),
      const SizedBox(height: 12),
      _confirm(),
    ]);
  }

  Widget _grid(List<BookingSlot> items) {
    final all = [...items]..sort((a, b) => a.start.compareTo(b.start));
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.75,
      children: [
        for (final s in all)
          _SlotCell(
            slot: s,
            selected: _sel.slots.any((x) => x.start == s.start),
            onTap: () {
              final next = SlotSelection.toggle(_sel, all, s, max: widget.maxSlots);
              if (next.count == 1 && _sel.count == widget.maxSlots && next.slots.first.start == s.start) {
                toast(context, '最多连续预订 ${widget.maxSlots} 个时段');
              }
              setState(() => _sel = next);
            },
          ),
      ],
    );
  }

  Widget _confirm() {
    final s = _sel;
    final label = s.isEmpty
        ? '先选一个时段'
        : '${widget.confirmVerb} ${clockText(s.start)}–${clockText(s.end)} · ${Fmt.yuan(s.amount)}';
    return FilledButton(
      key: const Key('slot_confirm'),
      style: FilledButton.styleFrom(
        disabledBackgroundColor: LL.card2,
        disabledForegroundColor: LL.text2,
        minimumSize: const Size.fromHeight(54),
      ),
      onPressed: s.isEmpty ? null : () => widget.onConfirm(s),
      child: Text(label),
    );
  }
}

class _SlotCell extends StatelessWidget {
  const _SlotCell({required this.slot, required this.selected, required this.onTap});
  final BookingSlot slot;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final full = !slot.available;
    final owner = slot.ownerPriceAmt != null && slot.ownerPriceAmt! < slot.priceAmt;
    return Semantics(
      button: true,
      selected: selected,
      enabled: !full,
      label: '${clockText(slot.start)}${full ? ' 已订满' : ''}',
      child: GestureDetector(
        onTap: full ? null : onTap,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: full ? const Color(0xFF17171B) : (selected ? LL.lime : Colors.transparent),
            borderRadius: BorderRadius.circular(16),
            border: full || selected ? null : Border.all(color: const Color(0xFF3A3A42)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              clockText(slot.start),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: full ? const Color(0xFF55555E) : (selected ? LL.ink : LL.text),
                decoration: full ? TextDecoration.lineThrough : null,
                decorationColor: const Color(0xFF55555E),
              ),
            ),
            if (owner && !full)
              Text('馆主 ${Fmt.yuan(slot.ownerPriceAmt!)}',
                  style: TextStyle(fontSize: 10, color: selected ? LL.ink : LL.lime, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

/// Status chip colours for bookings.
Color bookingStatusColor(String s) => switch (s) {
      'pending_pay' => LL.yellow,
      'paid' => LL.lime,
      'completed' => LL.sky,
      'refunding' => LL.orange,
      'refunded' => LL.lavender,
      _ => LL.card2,
    };
