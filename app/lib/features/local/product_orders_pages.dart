// V2 batch 5 · 我的订单 → 商品: the list (embedded in MyBookingsPage) and
// /me/product-orders/:id (coupons, 继续支付, 取消, 退款).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/product_api.dart';
import '../../api/product_models.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../community/gathering_widgets.dart' show Tag;
import 'coupons_pages.dart' show CouponCard, openCoupon;
import 'product_pay.dart';
import 'product_providers.dart';
import 'product_widgets.dart';
import '../../widgets/sound_refresh.dart';

const productOrderFilters = ['', 'pending', 'paid', 'completed', 'refunded', 'cancelled'];
const productOrderFilterLabels = ['全部', '待支付', '待使用', '已完成', '已退款', '已取消'];

/// The 商品 half of 我的订单: status chips and the list.
class ProductOrdersList extends ConsumerStatefulWidget {
  const ProductOrdersList({super.key});
  @override
  ConsumerState<ProductOrdersList> createState() => _ProductOrdersListState();
}

class _ProductOrdersListState extends ConsumerState<ProductOrdersList> {
  int _f = 0;

  @override
  Widget build(BuildContext context) {
    final status = productOrderFilters[_f];
    final async = ref.watch(myProductOrdersProvider(status));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ChipTabs(labels: productOrderFilterLabels, index: _f, onChanged: (i) => setState(() => _f = i)),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: SoundRefresh(
          onRefresh: () => ref.refresh(myProductOrdersProvider(status).future),
          child: AsyncBody<List<ProductOrder>>(
            value: async,
            onRetry: () => ref.invalidate(myProductOrdersProvider(status)),
            data: (list) => list.isEmpty
                ? ListView(children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(40, 40, 40, 12),
                      child: Text('还没有商品订单\n场馆页的「团购 / 套餐」可以买到店核销的券',
                          textAlign: TextAlign.center, style: TextStyle(color: LL.text2, height: 1.6)),
                    ),
                    Center(child: FilledButton(onPressed: () => context.push('/local'), child: const Text('去逛逛'))),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => ProductOrderTile(order: list[i]),
                  ),
          ),
        ),
      ),
    ]);
  }
}

class ProductOrderTile extends StatelessWidget {
  const ProductOrderTile({super.key, required this.order});
  final ProductOrder order;
  @override
  Widget build(BuildContext context) {
    final o = order;
    final pr = o.product;
    return LLCard(
      key: Key('product_order_${o.id}'),
      padding: const EdgeInsets.all(12),
      onTap: () => context.push('/me/product-orders/${o.id}'),
      child: Row(children: [
        ProductImage(url: pr?.image, seed: pr?.id ?? o.id, type: pr?.type ?? 'package', size: 56, radius: 14),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(pr?.title ?? '商品', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 2),
            Text('${o.merchant?.name ?? productTypeName(pr?.type ?? '')} · × ${o.qty}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 13)),
            if (o.partlyRefunded)
              Text('已退 ${Fmt.yuan(o.refundAmt)}', style: const TextStyle(color: LL.orange, fontSize: 12, fontWeight: FontWeight.w700))
            else if (o.promotion != null)
              const Text('活动价购买', style: TextStyle(color: promoColor, fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          ProductOrderStatusTag(status: o.status),
          const SizedBox(height: 6),
          Text(Fmt.yuan(o.amountAmt), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        ]),
      ]),
    );
  }
}

/// 商品订单详情.
class ProductOrderDetailPage extends ConsumerStatefulWidget {
  const ProductOrderDetailPage({super.key, required this.orderId, this.now});
  final int orderId;
  final DateTime Function()? now;
  @override
  ConsumerState<ProductOrderDetailPage> createState() => _ProductOrderDetailPageState();
}

class _ProductOrderDetailPageState extends ConsumerState<ProductOrderDetailPage> {
  bool _busy = false;

  void _reload() {
    ref.invalidate(productOrderProvider(widget.orderId));
    ref.invalidate(myProductOrdersProvider);
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      final ex = ApiException.from(e);
      if (mounted && ex.code != 'cancelled') showError(context, ex);
      if (mounted && ex.code == 'cancelled') toast(context, '支付已取消，订单保留到支付截止时间');
    } finally {
      _reload();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _repay(ProductOrder o) => _run(() async {
        final after = await ProductPay(ref).repay(o);
        if (!mounted) return;
        if (!after.isPending) {
          ref.invalidate(productOrderProvider(widget.orderId));
          await showProductOrderResult(context, after);
        }
      });

  Future<void> _cancel(ProductOrder o) async {
    final ok = await _confirm('取消这个订单？', '未支付的订单取消后库存会释放给其他人。', '取消订单');
    if (ok) {
      await _run(() async {
        await ref.read(productApiProvider).cancel(o.id);
        if (mounted) toast(context, '订单已取消');
      });
    }
  }

  Future<void> _refund(ProductOrder o) async {
    final n = o.unusedCoupons.length;
    final ok = await _confirm(
      '申请退款？',
      '将退回 $n 张未使用的券，约 ${Fmt.yuan(o.unitPriceAmt * n)} 原路退回，一般 1–3 个工作日到账。退款后这些券立即失效。',
      '确认退款',
    );
    if (!ok) return;
    await _run(() async {
      final r = await ref.read(productApiProvider).refund(o.id);
      if (mounted) toast(context, r.status == 'refunded' ? '退款成功，原路退回' : '已提交退款，原路退回');
    });
  }

  Future<bool> _confirm(String title, String body, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('再想想')),
            FilledButton(key: const Key('confirm_yes'), onPressed: () => Navigator.pop(d, true), child: Text(yes)),
          ],
        ),
      ) ==
      true;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(productOrderProvider(widget.orderId));
    final now = (widget.now ?? DateTime.now)();
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<ProductOrder>(
          value: async,
          onRetry: _reload,
          data: (o) {
            final pr = o.product;
            final canRefund = o.isPaid && o.unusedCoupons.isNotEmpty && o.refundable != false;
            final expired = o.isPending && o.payExpiresAt != null && now.isAfter(o.payExpiresAt!);
            return Column(children: [
              Expanded(
                child: SoundRefresh(
                  onRefresh: () => ref.refresh(productOrderProvider(widget.orderId).future),
                  child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                    BackHeader(title: '订单详情', subtitle: o.orderNo.isEmpty ? null : o.orderNo),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        LLCard(
                          onTap: pr == null ? null : () => context.push('/products/${pr.id}'),
                          child: Row(children: [
                            ProductImage(url: pr?.image, seed: pr?.id ?? o.id, type: pr?.type ?? 'package', size: 64, radius: 14),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(pr?.title ?? '商品', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                                const SizedBox(height: 2),
                                Text(
                                  [productTypeName(pr?.type ?? ''), if (o.merchant != null) o.merchant!.name].join(' · '),
                                  style: const TextStyle(color: LL.text2, fontSize: 13),
                                ),
                                const SizedBox(height: 6),
                                ProductOrderStatusTag(status: o.status),
                              ]),
                            ),
                            Text(Fmt.yuan(o.amountAmt), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                          ]),
                        ),
                        const SizedBox(height: 12),
                        LLCard(
                          child: Column(children: [
                            _row('数量', '${o.qty} 件'),
                            _row(o.promotion != null ? '活动价' : '单价', Fmt.yuan(o.unitPriceAmt)),
                            if (o.promotion != null) _row('官方活动', o.promotion!.name),
                            _row('实付', Fmt.yuan(o.amountAmt)),
                            if (o.refundAmt > 0) _row('已退款', Fmt.yuan(o.refundAmt), color: LL.orange),
                            if (o.orderNo.isNotEmpty) _row('订单号', o.orderNo),
                            _row('下单时间', Fmt.dateTime(o.createdAt)),
                            if (o.paidAt != null) _row('支付时间', Fmt.dateTime(o.paidAt)),
                            if (o.isPending && o.payExpiresAt != null) _row('支付截止', Fmt.dateTime(o.payExpiresAt)),
                          ]),
                        ),
                        const SizedBox(height: 12),
                        LLCard(
                          key: const Key('order_note'),
                          color: LL.card2,
                          child: Text(_note(o, expired), style: const TextStyle(color: LL.text2, height: 1.5)),
                        ),
                        if (o.coupons.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 18, 0, 8),
                            child: Row(children: [
                              Expanded(
                                child: Text('券 · ${o.coupons.length} 张',
                                    style: const TextStyle(color: LL.text2, fontSize: 15, fontWeight: FontWeight.w700)),
                              ),
                              if (o.unusedCoupons.isNotEmpty) Tag('${o.unusedCoupons.length} 张可用', color: LL.lime),
                            ]),
                          ),
                          for (final c in o.coupons) ...[
                            CouponCard(coupon: c, compact: true, onTap: () => openCoupon(context, c)),
                            const SizedBox(height: 8),
                          ],
                        ],
                      ]),
                    ),
                  ]),
                ),
              ),
              if (o.isPending && !expired)
                _bar([
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('product_order_cancel'),
                      onPressed: _busy ? null : () => _cancel(o),
                      child: const Text('取消订单'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      key: const Key('product_order_repay'),
                      onPressed: _busy ? null : () => _repay(o),
                      child: Text('继续支付 ${Fmt.yuan(o.amountAmt)}'),
                    ),
                  ),
                ])
              else if (canRefund)
                _bar([
                  if (pr != null) ...[
                    Expanded(
                      child: OutlinedButton(onPressed: () => context.push('/products/${pr.id}'), child: const Text('再来一单')),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      key: const Key('product_order_refund'),
                      style: FilledButton.styleFrom(backgroundColor: LL.card2, foregroundColor: LL.text),
                      onPressed: _busy ? null : () => _refund(o),
                      child: Text('退款 ${o.unusedCoupons.length} 张未使用的券'),
                    ),
                  ),
                ]),
            ]);
          },
        ),
      ),
    );
  }

  String _note(ProductOrder o, bool expired) {
    if (expired) return '超过支付时间，订单即将自动取消，库存已释放。';
    return switch (o.status) {
      'pending' => '待支付：请在 ${Fmt.dateTime(o.payExpiresAt)} 前完成支付，超时自动取消。',
      'paid' => o.refundable == false
          ? '券已放进卡券包，到店出示二维码由店员核销。该商品不可退款。'
          : '券已放进卡券包，到店出示二维码由店员核销。未使用的券随时可退，过期未使用自动退款。',
      'completed' => o.refundAmt > 0 ? '订单已完成，其中 ${Fmt.yuan(o.refundAmt)} 已原路退回。' : '订单已完成，券已全部使用。',
      'refunding' => '退款处理中，原路退回，一般 1–3 个工作日到账。',
      'refunded' => '已全部退款，${Fmt.yuan(o.refundAmt > 0 ? o.refundAmt : o.amountAmt)} 原路退回。',
      _ => '订单已取消。',
    };
  }

  Widget _bar(List<Widget> children) => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: LL.border))),
        child: Row(children: children),
      );

  Widget _row(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          SizedBox(width: 96, child: Text(k, style: const TextStyle(color: LL.text3))),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, color: color))),
        ]),
      );
}
