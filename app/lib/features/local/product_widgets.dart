// V2 batch 5 · 团购 / 套餐: product image, price block and the product card
// used on venue detail, the merchant page and official promotions.
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/product_models.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../community/gathering_widgets.dart' show Tag;
import '../social/social_widgets.dart' show mediaUrl;

/// Promotion colour (活动价 badge, banner).
const promoColor = LL.orange;

const _artColors = [
  [LL.lime, LL.sky],
  [LL.lavender, LL.pink],
  [LL.sky, LL.lavender],
  [LL.yellow, LL.orange],
  [LL.pink, LL.orange],
];

IconData productTypeIcon(String type) => switch (type) {
      'voucher' => Icons.local_activity_outlined,
      'pass' => Icons.style_outlined,
      _ => Icons.redeem_rounded,
    };

/// Friendly text for the purchase errors of `POST /v1/products/{id}/orders`.
String productErrorText(ApiException e) => switch (e.code) {
      'sold_out' => '已售罄，库存刚被抢完了，看看其他套餐吧',
      'limit_reached' => '已达到每人限购数量，不能再买了',
      'not_on_sale' => '这个商品已下架，暂时买不了',
      'invalid_request' || 'invalid_body' => '购买数量需要在 1–10 件之间',
      _ => e.displayMessage,
    };

/// The product's first image, or a coloured placeholder with its type.
class ProductImage extends StatelessWidget {
  const ProductImage({super.key, required this.url, required this.seed, this.type = 'package', this.size, this.height, this.radius = 16});
  final String? url;
  final int seed;
  final String type;

  /// Square side; or full width with [height].
  final double? size;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = _artColors[seed.abs() % _artColors.length];
    final h = size ?? height;
    final art = Container(
      width: size ?? double.infinity,
      height: h,
      decoration: BoxDecoration(gradient: LinearGradient(colors: c, begin: Alignment.topLeft, end: Alignment.bottomRight)),
      alignment: Alignment.center,
      child: Icon(productTypeIcon(type), color: LL.ink.withValues(alpha: 0.75), size: (h ?? 80) * 0.38),
    );
    final u = url;
    final child = u == null
        ? art
        : Image.network(mediaUrl(u), width: size ?? double.infinity, height: h, fit: BoxFit.cover, errorBuilder: (_, _, _) => art);
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: child);
  }
}

/// 「活动价」 pill.
class PromoBadge extends StatelessWidget {
  const PromoBadge({super.key, this.text = '活动价'});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: promoColor, borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: const TextStyle(color: LL.ink, fontSize: 11, fontWeight: FontWeight.w900)),
      );
}

/// Price now (promotion price when there is one), the struck reference price.
class ProductPrice extends StatelessWidget {
  const ProductPrice({super.key, required this.product, this.size = 20});
  final Product product;
  final double size;
  @override
  Widget build(BuildContext context) {
    final p = product;
    final strike = p.strikeAmt;
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
      if (p.onPromotion) ...[const PromoBadge(), const SizedBox(width: 6)],
      Text(Fmt.yuan(p.payAmt),
          style: TextStyle(fontSize: size, fontWeight: FontWeight.w900, color: p.onPromotion ? promoColor : LL.lime)),
      if (strike != null) ...[
        const SizedBox(width: 6),
        Text(Fmt.yuan(strike),
            style: TextStyle(
                fontSize: size * 0.62, color: LL.text3, decoration: TextDecoration.lineThrough, decorationColor: LL.text3)),
      ],
    ]);
  }
}

void openProduct(BuildContext context, Product p) => context.push('/products/${p.id}');

/// One product row: image, title, subtitle, type, price, struck price, sold.
class ProductCard extends StatelessWidget {
  const ProductCard({super.key, required this.product, this.onTap});
  final Product product;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = product;
    return LLCard(
      key: Key('product_${p.id}'),
      padding: const EdgeInsets.all(10),
      radius: 20,
      onTap: onTap ?? () => openProduct(context, p),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Stack(children: [
          ProductImage(url: p.cover, seed: p.id, type: p.type, size: 88),
          if (p.soldOut)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(color: const Color(0xAA0E0E10), borderRadius: BorderRadius.circular(16)),
                alignment: Alignment.center,
                child: const Text('已售罄', style: TextStyle(fontWeight: FontWeight.w900, color: LL.text)),
              ),
            ),
        ]),
        const SizedBox(width: 12),
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 88),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
              const SizedBox(height: 2),
              Text(
                [p.typeLabel, if (p.subtitle.isNotEmpty) p.subtitle].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: LL.text2, fontSize: 12),
              ),
              if (p.onPromotion && p.promotion!.title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('官方活动 · ${p.promotion!.title}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: promoColor, fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              const SizedBox(height: 6),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: ProductPrice(product: p))),
                const SizedBox(width: 6),
                Text(p.soldOut ? '已售罄' : p.soldText, style: TextStyle(color: p.soldOut ? LL.orange : LL.text3, fontSize: 12)),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// 「团购 / 套餐」 on venue detail: the first [collapsed] products and a
/// toggle for the rest; a link to the merchant's page.
class ProductSection extends StatefulWidget {
  const ProductSection({super.key, required this.products, this.merchantId, this.merchantName, this.collapsed = 3});
  final List<Product> products;
  final int? merchantId;
  final String? merchantName;
  final int collapsed;
  @override
  State<ProductSection> createState() => _ProductSectionState();
}

class _ProductSectionState extends State<ProductSection> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final list = widget.products;
    final shown = _all ? list : list.take(widget.collapsed).toList();
    final mid = widget.merchantId;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 0, 8),
        child: Row(children: [
          const Expanded(
            child: Text('团购 / 套餐', style: TextStyle(color: LL.text2, fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          if (mid != null)
            TextButton(
              key: const Key('merchant_products'),
              onPressed: () => context.push('/merchants/$mid', extra: widget.merchantName),
              child: const Text('商户全部商品'),
            ),
        ]),
      ),
      for (final p in shown) ...[ProductCard(product: p), const SizedBox(height: 8)],
      if (list.length > widget.collapsed)
        Center(
          child: TextButton.icon(
            key: const Key('products_toggle'),
            onPressed: () => setState(() => _all = !_all),
            icon: Icon(_all ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
            label: Text(_all ? '收起' : '展开全部 ${list.length} 个'),
          ),
        ),
    ]);
  }
}

/// Small status tag for a product order.
class ProductOrderStatusTag extends StatelessWidget {
  const ProductOrderStatusTag({super.key, required this.status});
  final String status;
  @override
  Widget build(BuildContext context) => Tag(productOrderStatusNames[status] ?? status, color: productOrderStatusColor(status));
}

Color productOrderStatusColor(String s) => switch (s) {
      'pending' => LL.yellow,
      'paid' => LL.lime,
      'refunding' => LL.orange,
      'completed' => LL.sky,
      _ => LL.card2,
    };
