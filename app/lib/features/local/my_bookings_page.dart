import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/local_api.dart';
import '../../api/local_models.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../pay/payment_service.dart' show channelNames;
import '../../widgets/common.dart';
import '../community/gathering_widgets.dart' show Tag;
import 'local_providers.dart';
import 'venue_widgets.dart';

const _filters = ['', 'pending_pay', 'paid', 'completed', 'refunded', 'cancelled'];
const _filterLabels = ['全部', '待支付', '待使用', '已完成', '已退款', '已取消'];

/// 我的订场：状态筛选、列表。
class MyBookingsPage extends ConsumerStatefulWidget {
  const MyBookingsPage({super.key});
  @override
  ConsumerState<MyBookingsPage> createState() => _MyBookingsPageState();
}

class _MyBookingsPageState extends ConsumerState<MyBookingsPage> {
  int _f = 0;

  @override
  Widget build(BuildContext context) {
    final status = _filters[_f];
    final async = ref.watch(myBookingsProvider(status));
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '我的订场', subtitle: '开始前 $freeCancelHours 小时以上可免费取消'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ChipTabs(labels: _filterLabels, index: _f, onChanged: (i) => setState(() => _f = i)),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(myBookingsProvider(status)),
              child: AsyncBody<List<Booking>>(
                value: async,
                onRetry: () => ref.invalidate(myBookingsProvider(status)),
                data: (list) => list.isEmpty
                    ? ListView(children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(40, 40, 40, 12),
                          child: Text('还没有订场记录', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)),
                        ),
                        Center(child: FilledButton(onPressed: () => context.push('/local'), child: const Text('去订场'))),
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, i) => BookingTile(booking: list[i]),
                      ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class BookingStatusChip extends StatelessWidget {
  const BookingStatusChip({super.key, required this.status});
  final String status;
  @override
  Widget build(BuildContext context) => Tag(bookingStatusNames[status] ?? status, color: bookingStatusColor(status));
}

class BookingTile extends StatelessWidget {
  const BookingTile({super.key, required this.booking});
  final Booking booking;
  @override
  Widget build(BuildContext context) {
    final b = booking;
    return LLCard(
      key: Key('booking_${b.id}'),
      onTap: () => context.push('/me/bookings/${b.id}'),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(b.venue?.name ?? '场馆', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 4),
            Text(slotRangeText(b.start, b.end), style: const TextStyle(color: LL.text2, fontSize: 13)),
            if (b.meetupId != null)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text('约球组局订场', style: TextStyle(color: LL.lavender, fontSize: 12)),
              ),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          BookingStatusChip(status: b.status),
          const SizedBox(height: 6),
          Text(Fmt.yuan(b.amountAmt), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        ]),
      ]),
    );
  }
}

/// 订场详情：场馆、时段、金额、订单号、取消规则；免费取消（开始前 2 小时）。
class BookingDetailPage extends ConsumerStatefulWidget {
  const BookingDetailPage({super.key, required this.bookingId, this.now});
  final int bookingId;
  final DateTime Function()? now;
  @override
  ConsumerState<BookingDetailPage> createState() => _BookingDetailPageState();
}

class _BookingDetailPageState extends ConsumerState<BookingDetailPage> {
  bool _busy = false;

  Future<void> _cancel(Booking b) async {
    final paid = b.isPaid;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('取消这次订场？'),
        content: Text(paid ? '取消后 ${Fmt.yuan(b.amountAmt)} 原路退回，一般 1–3 个工作日到账。' : '未支付的订单取消后时段会释放给其他人。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('再想想')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('取消订场')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await ref.read(localApiProvider).cancelBooking(b.id);
      if (!mounted) return;
      ref.invalidate(bookingProvider(widget.bookingId));
      ref.invalidate(myBookingsProvider);
      toast(context, r.status == 'refunding' || r.status == 'refunded' ? '已取消，退款原路退回' : '已取消');
    } catch (e) {
      final ex = ApiException.from(e);
      if (!mounted) return;
      if (ex.code == 'cancel_too_late') ref.invalidate(bookingProvider(widget.bookingId));
      showError(context, ex);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(bookingProvider(widget.bookingId));
    final now = (widget.now ?? DateTime.now)();
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<Booking>(
          value: async,
          onRetry: () => ref.invalidate(bookingProvider(widget.bookingId)),
          data: (b) {
            final canCancel = b.canCancelAt(now);
            return Column(children: [
              Expanded(
                child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                  BackHeader(title: '订场详情', subtitle: b.bookingNo.isEmpty ? null : b.bookingNo),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(color: venueColor(b.venue?.id ?? 0), borderRadius: BorderRadius.circular(28)),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Tag(b.statusName, color: LL.ink, fg: bookingStatusColor(b.status) == LL.card2 ? LL.text2 : bookingStatusColor(b.status)),
                            const Spacer(),
                            Text(Fmt.yuan(b.amountAmt), style: const TextStyle(color: LL.ink, fontSize: 24, fontWeight: FontWeight.w900)),
                          ]),
                          const SizedBox(height: 12),
                          Text(b.venue?.name ?? '场馆', style: const TextStyle(color: LL.ink, fontSize: 22, fontWeight: FontWeight.w900)),
                          const SizedBox(height: 4),
                          Text(slotRangeText(b.start, b.end), style: const TextStyle(color: Color(0xFF2A2A2A), fontWeight: FontWeight.w700)),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      LLCard(
                        child: Column(children: [
                          _row('场地', '${b.courtQty} 片'),
                          _row('原价', Fmt.yuan(b.originalAmt)),
                          if (b.discountType == 'owner') _row('馆主折扣', '-${Fmt.yuan(b.originalAmt - b.amountAmt)}'),
                          _row('实付', Fmt.yuan(b.amountAmt)),
                          if (b.channel != null) _row('支付方式', channelNames[b.channel] ?? b.channel!),
                          if (b.orderNo != null) _row('支付单号', b.orderNo!),
                          _row('下单时间', Fmt.dateTime(b.createdAt)),
                          if (b.cancelDeadline != null) _row('免费取消截止', Fmt.dateTime(b.cancelDeadline)),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      LLCard(
                        color: LL.card2,
                        child: Text(
                          switch (b.status) {
                            'pending_pay' => '待支付：15 分钟内未支付自动取消并释放时段。',
                            'paid' => '到场后在开始页「场馆球类」签到，攒馆主积分。开始前 $freeCancelHours 小时以上可免费取消，原路退款；之后不能自助取消，可联系客服。',
                            'refunding' => '退款处理中，原路退回，一般 1–3 个工作日到账。',
                            'refunded' => '已原路退款。',
                            'expired' => '超时未支付，订单已关闭。',
                            'completed' => '已完成，欢迎再来。',
                            _ => '订单已取消。',
                          },
                          style: const TextStyle(color: LL.text2, height: 1.5),
                        ),
                      ),
                      if (b.meetupId != null) ...[
                        const SizedBox(height: 12),
                        LLCard(
                          onTap: () => context.push('/meetups/${b.meetupId}'),
                          child: const Row(children: [
                            Icon(Icons.sports_tennis_rounded, color: LL.lavender),
                            SizedBox(width: 10),
                            Expanded(child: Text('这次订场属于你发起的约球局')),
                            Icon(Icons.chevron_right_rounded, color: LL.text3),
                          ]),
                        ),
                      ],
                    ]),
                  ),
                ]),
              ),
              if (b.isActive)
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: LL.border))),
                  child: Row(children: [
                    if (b.venue != null)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => context.push('/venues/${b.venue!.id}'),
                          child: const Text('场馆'),
                        ),
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: canCancel
                          ? FilledButton(
                              key: const Key('booking_cancel'),
                              style: FilledButton.styleFrom(backgroundColor: LL.card2, foregroundColor: LL.text),
                              onPressed: _busy ? null : () => _cancel(b),
                              child: Text(b.isPaid ? '取消并退款' : '取消订单'),
                            )
                          : const FilledButton(onPressed: null, child: Text('开始前 2 小时内不可取消')),
                    ),
                  ]),
                ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          SizedBox(width: 96, child: Text(k, style: const TextStyle(color: LL.text3))),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
      );
}
