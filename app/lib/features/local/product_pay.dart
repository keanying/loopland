// V2 batch 5 · buying a product: confirm sheet (quantity, channel) → create
// the order → pay (same SDK flow as 订场) → wait for the server → result
// sheet with the coupons.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/product_api.dart';
import '../../api/product_models.dart';
import '../../core/features.dart';
import '../../core/format.dart';
import '../../core/refresh.dart';
import '../../core/theme.dart';
import '../../pay/payment_service.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import 'booking_flow.dart' show ChannelPicker, PayFlow;
import 'coupons_pages.dart' show CouponCard, openCoupon;
import 'perks_providers.dart';
import 'product_providers.dart';
import 'product_widgets.dart';

/// The app's channel name for one the server sent (`wechat` → `wechat_app`).
String appChannel(String c) => switch (c) {
      'wechat' => 'wechat_app',
      'alipay' => 'alipay_app',
      _ => c,
    };

/// The channel a set of payment parameters is for, when the order does not
/// say (继续支付): Alipay has `order_string`, WeChat `prepayid` / `partnerid`.
String? channelOfParams(Map<String, dynamic> p) {
  if (p.containsKey('order_string')) return 'alipay_app';
  if (p.containsKey('prepayid') || p.containsKey('partnerid') || p.containsKey('package')) return 'wechat_app';
  return null;
}

/// Payment of a product order. The product order itself is the source of
/// truth: after the SDK returns, `GET /v1/product-orders/{id}` is polled
/// until it leaves `pending`.
class ProductPay {
  ProductPay(this.ref);
  final WidgetRef ref;

  PaymentService get _pay => ref.read(paymentServiceProvider);
  ProductApi get _api => ref.read(productApiProvider);

  /// Pays [created] on [channel]. Throws `cancelled` when the user backed
  /// out (and the server also says unpaid). Returns the order as the server
  /// sees it afterwards (paid, or still pending if the callback is late).
  Future<ProductOrder> pay(ProductOrderCreated created, String channel) async {
    final o = await _payOnce(created, channel);
    if (o.isPaid) _pay.onPaid?.call();
    return o;
  }

  Future<ProductOrder> _payOnce(ProductOrderCreated created, String channel) async {
    final o = created.order;
    switch (channel) {
      case 'mock':
        // Dev only: mark the payment order paid.
        try {
          await _pay.api.devPay(o.paymentNo);
        } catch (_) {
          // The poll below tells whether it worked.
        }
        return poll(o.id, _pay.pollTimeout);
      case 'wechat_app':
      case 'alipay_app':
        bool ok;
        try {
          ok = await _pay.sdkPay(channel, created.payParams);
        } on ApiException {
          // Backed out — the callback may still arrive (paid, then closed).
          final after = await poll(o.id, _pay.unpaidCheckTimeout);
          if (after.isPending) rethrow;
          return after;
        }
        final after = await poll(o.id, ok ? _pay.pollTimeout : _pay.unpaidCheckTimeout);
        if (!ok && after.isPending) {
          throw ApiException(status: 0, code: 'provider_error', message: '${channelNames[channel] ?? channel}未完成，可以在「我的订单」继续支付');
        }
        return after;
      default:
        throw ApiException(status: 0, code: 'channel_not_allowed');
    }
  }

  Future<ProductOrder> poll(int id, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final o = await _api.order(id);
      if (!o.isPending || DateTime.now().isAfter(deadline)) return o;
      await Future<void>.delayed(_pay.pollInterval);
    }
  }

  /// 「继续支付」 for a `pending` order: fresh parameters, the order's own
  /// channel (or the one the parameters are for).
  Future<ProductOrder> repay(ProductOrder order) async {
    final r = await _api.repay(order.id);
    final sent = r.order.channel ?? order.channel;
    final channel = sent != null ? appChannel(sent) : (channelOfParams(r.payParams) ?? (r.payParams.isEmpty ? 'mock' : null));
    if (channel == null) throw ApiException(status: 0, code: 'unknown', message: '订单信息不完整，请取消后重新下单');
    await _pay.ensureChannelReady(channel);
    final created = ProductOrderCreated(order: r.order.id == 0 ? order : r.order, payParams: r.payParams);
    return pay(created, channel);
  }

  void invalidate(int productId) {
    ref.invalidate(myProductOrdersProvider);
    ref.invalidate(productProvider(productId));
    ref.invalidate(myCouponsProvider);
  }
}

/// What [ProductBuySheet] popped with.
class ProductBuyOutcome {
  const ProductBuyOutcome({this.order, this.error});
  final ProductOrder? order;
  final ApiException? error;
}

/// 确认订单: product, quantity, total, channel, pay.
class ProductBuySheet extends ConsumerStatefulWidget {
  const ProductBuySheet({super.key, required this.product, required this.qty});
  final Product product;
  final int qty;
  @override
  ConsumerState<ProductBuySheet> createState() => _ProductBuySheetState();
}

class _ProductBuySheetState extends ConsumerState<ProductBuySheet> {
  String? _channel;
  bool _busy = false;
  String? _status;

  Future<void> _go(List<String> channels) async {
    final channel = channels.contains(_channel) ? _channel! : channels.first;
    final p = widget.product;
    final flow = ProductPay(ref);
    setState(() {
      _busy = true;
      _status = '正在创建订单…';
    });
    try {
      await ref.read(paymentServiceProvider).ensureChannelReady(channel);
      final created = await ref.read(productApiProvider).createOrder(p.id, qty: widget.qty, channel: channel);
      flow.invalidate(p.id);
      if (mounted) setState(() => _status = '等待支付结果…');
      ProductOrder o;
      try {
        o = await flow.pay(created, channel);
      } on ApiException catch (e) {
        if (e.code != 'cancelled') rethrow;
        if (mounted) Navigator.pop(context, ProductBuyOutcome(order: created.order, error: e));
        return;
      }
      flow.invalidate(p.id);
      // Coupons bought, stock, orders, …（数据刷新约定）
      if (o.isPaid) ref.read(refreshProvider).afterPayment().ignore();
      if (mounted) Navigator.pop(context, ProductBuyOutcome(order: o));
    } catch (e) {
      final ex = ApiException.from(e);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = null;
      });
      if (const {'sold_out', 'limit_reached', 'not_on_sale', 'realname_required', 'minor_not_allowed'}.contains(ex.code)) {
        Navigator.pop(context, ProductBuyOutcome(error: ex));
        return;
      }
      toast(context, productErrorText(ex));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final total = p.payAmt * widget.qty;
    final channels = ref.watch(paymentServiceProvider).serviceChannels(ref.watch(featuresProvider).value);
    if (!channels.contains(_channel)) _channel = channels.firstOrNull;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('确认订单', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          LLCard(
            color: LL.card2,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                ProductImage(url: p.cover, seed: p.id, type: p.type, size: 52, radius: 12),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                    Text('${p.typeLabel} · ${p.merchant?.name ?? ''}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 13)),
                  ]),
                ),
              ]),
              const Divider(height: 22, color: LL.border),
              _line(p.onPromotion ? '活动价' : '单价', Fmt.yuan(p.payAmt), color: p.onPromotion ? promoColor : LL.text2),
              if (p.onPromotion && p.payAmt < p.priceAmt) _line('原价', Fmt.yuan(p.priceAmt)),
              _line('数量', '× ${widget.qty}'),
              const SizedBox(height: 4),
              Row(children: [
                const Text('实付', style: TextStyle(fontWeight: FontWeight.w800)),
                const Spacer(),
                Text(Fmt.yuan(total), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: LL.lime)),
              ]),
            ]),
          ),
          const SizedBox(height: 10),
          Text(
            '支付成功后每件发 1 张券，放进卡券包，到店出示二维码核销。${p.refundable ? '未使用的券随时可退，过期未使用自动退款。' : '该商品购买后不可退款。'}15 分钟内未支付自动取消。',
            style: const TextStyle(color: LL.text3, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 8),
          const Text('支付方式', style: TextStyle(color: LL.text2)),
          ChannelPicker(channels: channels, value: _channel, onChanged: _busy ? (_) {} : (c) => setState(() => _channel = c)),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('product_pay'),
            onPressed: _busy || channels.isEmpty ? null : () => _go(channels),
            child: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text('支付 ${Fmt.yuan(total)}'),
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

/// Confirm sheet → pay → result sheet. [onRefresh] reloads the product after
/// `sold_out` / `limit_reached` / `not_on_sale`. Returns the order (paid or
/// still pending) or null.
Future<ProductOrder?> buyProduct(BuildContext context, WidgetRef ref,
    {required Product product, required int qty, VoidCallback? onRefresh}) async {
  final r = await showModalBottomSheet<ProductBuyOutcome>(
    context: context,
    isScrollControlled: true,
    backgroundColor: LL.card,
    showDragHandle: true,
    builder: (_) => ProductBuySheet(product: product, qty: qty),
  );
  if (r == null || !context.mounted) return null;
  final ex = r.error;
  if (ex != null) {
    if (ex.code == 'cancelled') {
      toast(context, '支付已取消。订单保留 15 分钟，可在「我的订单」继续支付');
      return r.order;
    }
    if (const {'sold_out', 'limit_reached', 'not_on_sale'}.contains(ex.code)) {
      onRefresh?.call();
      await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(switch (ex.code) { 'sold_out' => '已售罄', 'limit_reached' => '已达限购', _ => '已下架' }),
          content: Text(productErrorText(ex)),
          actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('知道了'))],
        ),
      );
      return null;
    }
    if (!PayFlow.handleError(context, ex, what: '购买')) showError(context, ex);
    return null;
  }
  final o = r.order;
  if (o == null) return null;
  await showProductOrderResult(context, o);
  return o;
}

/// 购买成功 (with the coupons) / 等待支付结果.
Future<void> showProductOrderResult(BuildContext context, ProductOrder o) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: LL.card,
      showDragHandle: true,
      builder: (c) {
        final paid = !o.isPending;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.8),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                LIcon(paid ? LIcons.checkCircleFilled : LIcons.hourglass, color: paid ? LL.lime : LL.yellow, size: 56),
                const SizedBox(height: 8),
                Text(paid ? '购买成功' : '等待支付结果',
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                Text('${o.product?.title ?? ''} × ${o.qty} · ${Fmt.yuan(o.amountAmt)}',
                    textAlign: TextAlign.center, style: const TextStyle(color: LL.text2, height: 1.5)),
                const SizedBox(height: 4),
                Text(
                  paid ? '${o.coupons.isEmpty ? o.qty : o.coupons.length} 张券已放进卡券包，到店出示二维码核销' : '支付结果以服务端为准，可在「我的订单」查看',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: LL.text3, fontSize: 12),
                ),
                if (paid && o.coupons.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final cp in o.coupons.take(3)) ...[
                    CouponCard(
                      coupon: cp,
                      compact: true,
                      onTap: () {
                        Navigator.pop(c);
                        openCoupon(context, cp);
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('result_order'),
                      onPressed: () {
                        Navigator.pop(c);
                        context.push('/me/product-orders/${o.id}');
                      },
                      child: const Text('查看订单'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      key: const Key('result_coupons'),
                      onPressed: () {
                        Navigator.pop(c);
                        if (paid) context.push('/me/coupons');
                      },
                      child: Text(paid ? '查看券' : '完成'),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        );
      },
    );
