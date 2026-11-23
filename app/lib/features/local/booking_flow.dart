import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/local_api.dart';
import '../../api/local_models.dart';
import '../../auth/auth_controller.dart';
import '../../core/features.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../pay/payment_service.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import 'local_providers.dart';
import 'venue_widgets.dart';

/// Shared pieces of the paid flows (订场, 赛事报名费).
class PayFlow {
  PayFlow._();

  /// 「未成年账号暂不支持…」 — the server answers 403 `minor_not_allowed`;
  /// the app checks first so no order is created.
  static Future<void> minorNotice(BuildContext context, String what) => showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('暂不可用'),
          content: Text('根据未成年人保护规定，未成年账号暂不支持$what。'),
          actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('知道了'))],
        ),
      );

  /// Handles the errors every paid flow shares. Returns true when handled.
  static bool handleError(BuildContext context, ApiException ex, {required String what}) {
    switch (ex.code) {
      case 'realname_required':
        toast(context, ex.serverMessage.isNotEmpty ? ex.serverMessage : '$what前需要先完成实名认证');
        context.push('/realname');
        return true;
      case 'minor_not_allowed':
      case 'minor_blocked':
        minorNotice(context, what);
        return true;
      case 'cancelled':
        toast(context, '支付已取消。订单保留 15 分钟，超时自动取消');
        return true;
    }
    return false;
  }
}

/// Channel list with names; WeChat / Alipay on iOS too (physical service).
class ChannelPicker extends StatelessWidget {
  const ChannelPicker({super.key, required this.channels, required this.value, required this.onChanged});
  final List<String> channels;
  final String? value;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) {
    if (channels.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('暂无可用的支付方式，请稍后再试', style: TextStyle(color: LL.text3)),
      );
    }
    return RadioGroup<String>(
      groupValue: value,
      onChanged: onChanged,
      child: Column(children: [
        for (final c in channels)
          RadioListTile<String>(
            key: Key('channel_$c'),
            value: c,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(channelNames[c] ?? c),
          ),
      ]),
    );
  }
}

/// What [BookingConfirmSheet] popped with.
class BookingOutcome {
  const BookingOutcome({this.booking, this.error});
  final Booking? booking;
  final ApiException? error;
}

/// Order confirmation + payment for a venue booking. Pops with a
/// [BookingOutcome]: the booking once the SDK returned (paid or still
/// pending), or an error the caller handles (`slot_unavailable`,
/// `realname_required`, `minor_not_allowed`, `cancelled`). Other errors are
/// shown in the sheet.
class BookingConfirmSheet extends ConsumerStatefulWidget {
  const BookingConfirmSheet({super.key, required this.venue, required this.selection, this.meetupId});
  final Venue venue;
  final SlotSelection selection;
  final int? meetupId;

  @override
  ConsumerState<BookingConfirmSheet> createState() => _BookingConfirmSheetState();
}

class _BookingConfirmSheetState extends ConsumerState<BookingConfirmSheet> {
  String? _channel;
  bool _busy = false;
  String? _status;

  Future<void> _pay(List<String> channels) async {
    final channel = channels.contains(_channel) ? _channel! : channels.first;
    final pay = ref.read(paymentServiceProvider);
    final api = ref.read(localApiProvider);
    final s = widget.selection;
    setState(() {
      _busy = true;
      _status = '正在创建订单…';
    });
    try {
      await pay.ensureChannelReady(channel);
      final created = await api.createBooking(
          venueId: widget.venue.id, startTime: s.start, slots: s.count, channel: channel, meetupId: widget.meetupId);
      var b = created.booking;
      ref.invalidate(myBookingsProvider);
      final no = b.orderNo;
      if (no == null || no.isEmpty) throw ApiException(status: 0, code: 'unknown', message: '订单缺少支付单号，请在「我的订场」查看');
      if (mounted) setState(() => _status = '等待支付结果…');
      try {
        await pay.payOrder(no, channel, created.payParams);
      } on ApiException catch (e) {
        if (e.code != 'cancelled') rethrow;
        // Backed out of the SDK: the booking stays pending for 15 minutes.
        if (mounted) Navigator.pop(context, BookingOutcome(error: e));
        return;
      }
      b = await api.booking(b.id).catchError((_) => b);
      ref.invalidate(myBookingsProvider);
      if (mounted) Navigator.pop(context, BookingOutcome(booking: b));
    } catch (e) {
      final ex = ApiException.from(e);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = null;
      });
      // These are handled by the caller (navigation / reload).
      if (const {'slot_unavailable', 'realname_required', 'minor_not_allowed'}.contains(ex.code)) {
        Navigator.pop(context, BookingOutcome(error: ex));
        return;
      }
      showError(context, ex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    final s = widget.selection;
    final channels = ref.watch(paymentServiceProvider).serviceChannels(ref.watch(featuresProvider).value);
    if (!channels.contains(_channel)) _channel = channels.firstOrNull;
    final me = ref.watch(userProvider);
    final isOwner = v.owner != null && v.owner!.user.id == me?.id;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('确认订单', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          LLCard(
            color: LL.card2,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(v.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
              const SizedBox(height: 6),
              Text(slotRangeText(s.start, s.end), style: const TextStyle(color: LL.text2)),
              Text('${s.count} 个时段 · 1 片场地', style: const TextStyle(color: LL.text2)),
              if (widget.meetupId != null)
                const Text('订给你发起的约球局，组局详情会显示场地', style: TextStyle(color: LL.lavender, fontSize: 13)),
              const Divider(height: 22, color: LL.border),
              _line('原价', Fmt.yuan(s.originalAmount)),
              if (s.discounted || isOwner)
                _line('馆主${v.discountText ?? '折扣'}', '-${Fmt.yuan(s.originalAmount - s.amount)}', color: LL.lime),
              const SizedBox(height: 4),
              Row(children: [
                const Text('实付', style: TextStyle(fontWeight: FontWeight.w800)),
                const Spacer(),
                Text(Fmt.yuan(s.amount), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: LL.lime)),
              ]),
            ]),
          ),
          const SizedBox(height: 10),
          const Text('开始前 $freeCancelHours 小时以上可免费取消，原路退款；15 分钟内未支付自动取消。线下场地服务，使用微信 / 支付宝付款。',
              style: TextStyle(color: LL.text3, fontSize: 12, height: 1.5)),
          const SizedBox(height: 8),
          const Text('支付方式', style: TextStyle(color: LL.text2)),
          ChannelPicker(channels: channels, value: _channel, onChanged: _busy ? (_) {} : (c) => setState(() => _channel = c)),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('booking_pay'),
            onPressed: _busy || channels.isEmpty ? null : () => _pay(channels),
            child: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text('支付 ${Fmt.yuan(s.amount)}'),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_status!, textAlign: TextAlign.center, style: const TextStyle(color: LL.text2)),
            ),
        ]),
      ),
    );
  }

  Widget _line(String k, String v, {Color color = LL.text2}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [Text(k, style: TextStyle(color: color)), const Spacer(), Text(v, style: TextStyle(color: color))]),
      );
}

/// Confirm sheet → pay → result. Returns the booking (paid or still
/// pending) or null.
Future<Booking?> bookVenue(
  BuildContext context,
  WidgetRef ref, {
  required Venue venue,
  required SlotSelection selection,
  int? meetupId,
  VoidCallback? onSlotTaken,
  bool showResult = true,
}) async {
  if (ref.read(userProvider)?.isMinor == true) {
    await PayFlow.minorNotice(context, '订场');
    return null;
  }
  final r = await showModalBottomSheet<BookingOutcome>(
    context: context,
    isScrollControlled: true,
    backgroundColor: LL.card,
    showDragHandle: true,
    builder: (_) => BookingConfirmSheet(venue: venue, selection: selection, meetupId: meetupId),
  );
  if (r == null || !context.mounted) return null;
  final ex = r.error;
  if (ex != null) {
    if (ex.code == 'slot_unavailable') {
      onSlotTaken?.call();
      toast(context, ex.message);
    } else if (!PayFlow.handleError(context, ex, what: '订场')) {
      showError(context, ex);
    }
    return null;
  }
  final b = r.booking;
  if (b == null) return null;
  if (showResult) await showBookingResult(context, b);
  return b;
}

Future<void> showBookingResult(BuildContext context, Booking b) => showModalBottomSheet<void>(
      context: context,
      backgroundColor: LL.card,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            LIcon(b.isPaid ? LIcons.checkCircleFilled : LIcons.hourglass,
                color: b.isPaid ? LL.lime : LL.yellow, size: 56),
            const SizedBox(height: 8),
            Text(b.isPaid ? '预订成功' : '等待支付结果', textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text('${b.venue?.name ?? ''}\n${slotRangeText(b.start, b.end)} · ${Fmt.yuan(b.amountAmt)}',
                textAlign: TextAlign.center, style: const TextStyle(color: LL.text2, height: 1.5)),
            const SizedBox(height: 6),
            Text(b.isPaid ? '到场后在开始页「场馆球类」签到，攒馆主积分' : '支付结果以服务端为准，可在「我的订场」查看',
                textAlign: TextAlign.center, style: const TextStyle(color: LL.text3, fontSize: 12)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pop(c);
                    context.push('/me/bookings/${b.id}');
                  },
                  child: const Text('查看订单'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: FilledButton(onPressed: () => Navigator.pop(c), child: const Text('完成'))),
            ]),
          ]),
        ),
      ),
    );
