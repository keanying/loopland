// V2 batch 5 · 商品详情 (/products/:id), 商户商品 (/merchants/:id), 官方活动
// (/promotions, /promotions/:id) and the 官方活动 strip on 本地生活.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_common.dart' show CursorPager;
import '../../api/local_api.dart' show shanghaiClock;
import '../../api/product_api.dart';
import '../../api/product_models.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/cursor_list.dart';
import '../../widgets/l_icons.dart';
import '../community/gathering_widgets.dart' show Tag;
import '../social/social_widgets.dart' show mediaUrl;
import 'product_pay.dart';
import 'product_providers.dart';
import 'product_widgets.dart';

/// Asia/Shanghai wall clock, like the venue / slot times.
String _mdhm(DateTime? t) => t == null ? '-' : DateFormat('M月d日 HH:mm').format(shanghaiClock(t));

/// 「12月1日 00:00 – 12月12日 23:59」.
String promoRangeText(DateTime? a, DateTime? b) => '${_mdhm(a)} – ${_mdhm(b)}';

// ───────────────────────────── 商品详情 ─────────────────────────────

/// 商品详情: gallery, price (活动价 / 原价), type, venues, validity, rules,
/// refund note, quantity (per-user limit), 立即购买.
class ProductDetailPage extends ConsumerStatefulWidget {
  const ProductDetailPage({super.key, required this.productId});
  final int productId;
  @override
  ConsumerState<ProductDetailPage> createState() => _ProductDetailPageState();
}

class _ProductDetailPageState extends ConsumerState<ProductDetailPage> {
  int _qty = 1;
  bool _busy = false;

  void _reload() => ref.invalidate(productProvider(widget.productId));

  Future<void> _buy(Product p) async {
    setState(() => _busy = true);
    await buyProduct(context, ref, product: p, qty: _qty.clamp(1, p.maxQty < 1 ? 1 : p.maxQty), onRefresh: _reload);
    if (!mounted) return;
    _reload();
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(productProvider(widget.productId));
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<Product>(
          value: async,
          onRetry: _reload,
          data: (p) {
            final max = p.maxQty;
            if (_qty > max && max > 0) _qty = max;
            return Column(children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => ref.refresh(productProvider(widget.productId).future),
                  child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                    _Gallery(product: p),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const SizedBox(height: 14),
                        _PriceBlock(product: p),
                        const SizedBox(height: 14),
                        Text(p.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                        if (p.subtitle.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(p.subtitle, style: const TextStyle(color: LL.text2)),
                          ),
                        const SizedBox(height: 10),
                        Wrap(spacing: 8, runSpacing: 6, children: [
                          Tag(p.typeLabel, color: LL.lavender),
                          Tag(p.refundText, color: p.refundable ? LL.lime : LL.card2),
                          Tag(p.soldOut ? '已售罄' : p.soldText),
                          if (p.perUserLimitQty > 0) Tag('每人限购 ${p.perUserLimitQty} 件'),
                        ]),
                        if (p.merchant != null) ...[
                          const SizedBox(height: 12),
                          LLCard(
                            key: const Key('product_merchant'),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            onTap: () => context.push('/merchants/${p.merchant!.id}', extra: p.merchant!.name),
                            child: Row(children: [
                              const LIcon(LIcons.store, color: LL.sky),
                              const SizedBox(width: 10),
                              Expanded(child: Text(p.merchant!.name, style: const TextStyle(fontWeight: FontWeight.w800))),
                              const Text('全部商品', style: TextStyle(color: LL.text3, fontSize: 13)),
                              const LIcon(LIcons.chevronRight, color: LL.text3),
                            ]),
                          ),
                        ],
                        _section('适用门店'),
                        LLCard(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          child: p.venues.isEmpty
                              ? Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  child: Text('${p.merchant?.name ?? '商户'}所有门店通用', style: const TextStyle(fontWeight: FontWeight.w700)),
                                )
                              : Column(children: [
                                  for (final v in p.venues)
                                    InkWell(
                                      onTap: () => context.push('/venues/${v.id}'),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 8),
                                        child: Row(children: [
                                          const LIcon(LIcons.pin, size: 18, color: LL.lime),
                                          const SizedBox(width: 8),
                                          Expanded(child: Text(v.name, style: const TextStyle(fontWeight: FontWeight.w700))),
                                          const LIcon(LIcons.chevronRight, color: LL.text3),
                                        ]),
                                      ),
                                    ),
                                ]),
                        ),
                        _section('有效期'),
                        LLCard(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          child: Text(p.validityText, style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        _section('使用规则'),
                        LLCard(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            if (p.description.isNotEmpty) _Bullet(p.description),
                            for (final r in _split(p.rules)) _Bullet(r),
                            if (p.isPass) _Bullet('次卡共 ${p.useQty} 次，每次核销用掉 1 次'),
                            if (p.isVoucher && p.originalAmt != null) _Bullet('代金券面值 ${_yuan(p.originalAmt!)}，到店消费抵扣'),
                            const _Bullet('购买后每件发 1 张券，放进卡券包；到店出示二维码，由店员扫码核销'),
                            const _Bullet('花钱买的券核销不需要当天有运动记录'),
                          ]),
                        ),
                        _section('退款说明'),
                        LLCard(
                          key: const Key('refund_note'),
                          color: p.refundable ? const Color(0xFF23271A) : LL.card2,
                          child: Text(
                            p.refundable
                                ? '随时退：未使用的券可在「我的订单」申请退款，原路退回；过期未使用自动退款。已核销的不能退。'
                                : '不可退：该商品购买后不支持退款，过期未使用作废，请在有效期内使用。',
                            style: const TextStyle(height: 1.5),
                          ),
                        ),
                        _section('购买数量'),
                        _QtyRow(
                          product: p,
                          qty: _qty,
                          onChanged: (v) => setState(() => _qty = v),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ),
              _bottomBar(p),
            ]);
          },
        ),
      ),
    );
  }

  Widget _bottomBar(Product p) {
    final max = p.maxQty;
    final String? blocked = p.soldOut
        ? '已售罄'
        : (p.limitLeft == 0 ? '已达限购' : (max < 1 ? '活动库存已抢完' : null));
    final qty = _qty.clamp(1, max < 1 ? 1 : max);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: LL.border))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('合计', style: const TextStyle(color: LL.text3, fontSize: 12)),
            Text(_yuan(p.payAmt * qty),
                key: const Key('product_total'),
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: p.onPromotion ? promoColor : LL.lime)),
          ]),
        ),
        SizedBox(
          width: 190,
          child: FilledButton(
            key: const Key('product_buy'),
            onPressed: blocked != null || _busy ? null : () => _buy(p),
            child: Text(blocked ?? '立即购买'),
          ),
        ),
      ]),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 0, 8),
        child: Text(t, style: const TextStyle(color: LL.text2, fontSize: 15, fontWeight: FontWeight.w700)),
      );

  static List<String> _split(String s) => s.split(RegExp(r'[；;\n]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
}

String _yuan(int fen) => fen % 100 == 0 ? '¥${fen ~/ 100}' : '¥${(fen / 100).toStringAsFixed(2)}';

class _Gallery extends StatefulWidget {
  const _Gallery({required this.product});
  final Product product;
  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  int _i = 0;
  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final imgs = p.images;
    const h = 250.0;
    return SizedBox(
      height: h,
      child: Stack(children: [
        Positioned.fill(
          child: imgs.length <= 1
              ? ProductImage(url: p.cover, seed: p.id, type: p.type, height: h, radius: 0)
              : PageView.builder(
                  key: const Key('product_gallery'),
                  itemCount: imgs.length,
                  onPageChanged: (i) => setState(() => _i = i),
                  itemBuilder: (_, i) => ProductImage(url: imgs[i], seed: p.id + i, type: p.type, height: h, radius: 0),
                ),
        ),
        Positioned(
          left: 16,
          top: 8,
          child: RoundIconButton(
            icon: LIcons.back,
            color: const Color(0xCC1B1B20),
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        if (imgs.length > 1)
          Positioned(
            right: 16,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: const Color(0xAA0E0E10), borderRadius: BorderRadius.circular(12)),
              child: Text('${_i + 1}/${imgs.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
            ),
          ),
      ]),
    );
  }
}

class _PriceBlock extends StatelessWidget {
  const _PriceBlock({required this.product});
  final Product product;
  @override
  Widget build(BuildContext context) {
    final p = product;
    final promo = p.promotion;
    final orig = p.originalAmt;
    final strike = TextStyle(color: LL.text3, decoration: TextDecoration.lineThrough, decorationColor: LL.text3, fontSize: 14);
    return Container(
      key: const Key('price_block'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LL.radius),
        color: promo != null ? null : LL.card,
        gradient: promo != null
            ? const LinearGradient(colors: [Color(0xFF3A2414), Color(0xFF2A1A26)], begin: Alignment.topLeft, end: Alignment.bottomRight)
            : null,
        border: Border.all(color: promo != null ? const Color(0x66FF9F5A) : LL.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.end, runSpacing: 6, children: [
          if (promo != null) ...[const PromoBadge(), const SizedBox(width: 8)],
          Text(_yuan(p.payAmt),
              key: const Key('product_price'),
              style: TextStyle(fontSize: 34, height: 1, fontWeight: FontWeight.w900, color: promo != null ? promoColor : LL.lime)),
          const SizedBox(width: 10),
          if (promo != null && promo.promoPriceAmt < p.priceAmt) ...[
            Text('原价 ', style: const TextStyle(color: LL.text3, fontSize: 13)),
            Text(_yuan(p.priceAmt), style: strike),
            const SizedBox(width: 8),
          ],
          if (orig != null && orig > p.payAmt) ...[
            Text(p.isVoucher ? '面值 ' : '门市价 ', style: const TextStyle(color: LL.text3, fontSize: 13)),
            Text(_yuan(orig), style: strike),
          ],
        ]),
        if (promo != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            const LIcon(LIcons.flame, color: promoColor, size: 18),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                [
                  if (promo.title.isNotEmpty) '官方活动 · ${promo.title}',
                  if (promo.endsAt != null) '${_mdhm(promo.endsAt)} 结束',
                  if (promo.promoLeftQty != null) '活动剩 ${promo.promoLeftQty} 件',
                ].join(' · '),
                style: const TextStyle(color: promoColor, fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}

class _QtyRow extends StatelessWidget {
  const _QtyRow({required this.product, required this.qty, required this.onChanged});
  final Product product;
  final int qty;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) {
    final p = product;
    final max = p.maxQty;
    final note = [
      if (p.perUserLimitQty > 0) '每人限购 ${p.perUserLimitQty} 件${(p.myBoughtQty ?? 0) > 0 ? '，已买 ${p.myBoughtQty} 件' : ''}',
      if (p.promotion?.promoLeftQty != null) '活动剩 ${p.promotion!.promoLeftQty} 件',
      if (p.perUserLimitQty <= 0 && p.promotion?.promoLeftQty == null) '每单最多 10 件',
    ].join(' · ');
    return LLCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(children: [
        Expanded(child: Text(note, style: const TextStyle(color: LL.text2, fontSize: 13))),
        IconButton(
          key: const Key('qty_minus'),
          onPressed: qty > 1 ? () => onChanged(qty - 1) : null,
          icon: const LIcon(LIcons.minusCircle),
        ),
        SizedBox(
          width: 28,
          child: Text('${max < 1 ? 0 : qty}',
              key: const Key('qty'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        ),
        IconButton(
          key: const Key('qty_plus'),
          onPressed: qty < max ? () => onChanged(qty + 1) : null,
          icon: const LIcon(LIcons.plusCircle),
        ),
      ]),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 7, right: 8),
            child: CircleAvatar(radius: 2.5, backgroundColor: LL.lime),
          ),
          Expanded(child: Text(text, style: const TextStyle(height: 1.5, fontSize: 14))),
        ]),
      );
}

// ───────────────────────────── 商户商品 ─────────────────────────────

/// /merchants/:id — the merchant's on-sale products (cursor list).
class MerchantProductsPage extends ConsumerStatefulWidget {
  const MerchantProductsPage({super.key, required this.merchantId, this.name});
  final int merchantId;
  final String? name;
  @override
  ConsumerState<MerchantProductsPage> createState() => _MerchantProductsPageState();
}

class _MerchantProductsPageState extends ConsumerState<MerchantProductsPage> {
  late final CursorPager<Product> _pager =
      CursorPager((cursor) => ref.read(productApiProvider).merchantProducts(widget.merchantId, cursor: cursor));

  @override
  void initState() {
    super.initState();
    _pager.addListener(_changed);
  }

  @override
  void dispose() {
    _pager.removeListener(_changed);
    _pager.dispose();
    super.dispose();
  }

  /// The title falls back to the products' merchant name (deep link). The
  /// pager notifies while the list mounts, so rebuild after the frame.
  void _changed() {
    if (widget.name != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.name ?? _pager.items.firstOrNull?.merchant?.name ?? '商户';
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          BackHeader(title: name, subtitle: '团购 / 套餐 · 到店核销'),
          Expanded(
            child: CursorListView<Product>(
              pager: _pager,
              empty: '这家商户暂时没有在售的商品',
              separator: 10,
              itemBuilder: (_, p, _) => ProductCard(product: p),
            ),
          ),
        ]),
      ),
    );
  }
}

// ───────────────────────────── 官方活动 ─────────────────────────────

/// Banner art: the image, or a warm gradient with the title.
class PromotionBanner extends StatelessWidget {
  const PromotionBanner({super.key, required this.promotion, this.height = 150, this.radius = LL.radius});
  final Promotion promotion;
  final double height;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final p = promotion;
    final art = Container(
      height: height,
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [LL.orange, LL.pink, LL.lavender], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      padding: const EdgeInsets.all(18),
      alignment: Alignment.bottomLeft,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('官方活动', style: TextStyle(color: LL.ink, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1)),
        Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: LL.ink, fontSize: 26, fontWeight: FontWeight.w900)),
        if (p.subtitle.isNotEmpty)
          Text(p.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF2A2A2A), fontWeight: FontWeight.w700)),
      ]),
    );
    final u = p.bannerUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: u == null
          ? art
          : Image.network(mediaUrl(u), height: height, width: double.infinity, fit: BoxFit.cover, errorBuilder: (_, _, _) => art),
    );
  }
}

Widget _promoStatus(Promotion p) =>
    p.isUpcoming ? const Tag('即将开始', color: LL.sky) : const Tag('进行中', color: promoColor);

/// 本地生活 top strip: the running promotion(s); hidden when there are none.
class PromotionStrip extends ConsumerWidget {
  const PromotionStrip({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(promotionsProvider).value ?? const <Promotion>[];
    final active = list.where((p) => p.isActive).toList();
    final shown = active.isNotEmpty ? active : list;
    if (shown.isEmpty) return const SizedBox.shrink();
    final first = shown.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF3A2414), Color(0xFF2A1A26)], begin: Alignment.centerLeft, end: Alignment.centerRight),
          ),
          child: InkWell(
            key: const Key('promotion_strip'),
            onTap: () => context.push(list.length == 1 ? '/promotions/${first.id}' : '/promotions'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              child: Row(children: [
                const LIcon(LIcons.flame, color: promoColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(first.isActive ? '官方活动 · ${first.title}' : '即将开始 · ${first.title}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900)),
                    Text(
                      first.subtitle.isNotEmpty ? first.subtitle : '活动价限时抢购',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: promoColor, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ]),
                ),
                if (list.length > 1) Text('${list.length} 个活动', style: const TextStyle(color: LL.text3, fontSize: 12)),
                const LIcon(LIcons.chevronRight, color: LL.text3),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// /promotions — running and upcoming official promotions.
class PromotionsPage extends ConsumerWidget {
  const PromotionsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(promotionsProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '官方活动', subtitle: '限时活动价 · 合作商户让利'),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(promotionsProvider.future),
              child: AsyncBody<List<Promotion>>(
                value: async,
                onRetry: () => ref.invalidate(promotionsProvider),
                data: (list) => list.isEmpty
                    ? ListView(children: const [
                        SizedBox(height: 80),
                        LIcon(LIcons.flame, color: LL.text3, size: 44),
                        SizedBox(height: 12),
                        Text('暂时没有进行中的官方活动', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)),
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 14),
                        itemBuilder: (_, i) => _PromotionTile(promotion: list[i]),
                      ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _PromotionTile extends StatelessWidget {
  const _PromotionTile({required this.promotion});
  final Promotion promotion;
  @override
  Widget build(BuildContext context) {
    final p = promotion;
    return LLCard(
      key: Key('promotion_${p.id}'),
      padding: EdgeInsets.zero,
      onTap: () => context.push('/promotions/${p.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PromotionBanner(promotion: p, height: 130, radius: 0),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Row(children: [
            _promoStatus(p),
            const SizedBox(width: 8),
            Expanded(
              child: Text(promoRangeText(p.startsAt, p.endsAt),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 13)),
            ),
            if (p.productQty > 0) Text('${p.productQty} 个商品', style: const TextStyle(color: LL.text3, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }
}

/// /promotions/:id — banner, time, description, products at the promotion price.
class PromotionDetailPage extends ConsumerWidget {
  const PromotionDetailPage({super.key, required this.promotionId});
  final int promotionId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(promotionProvider(promotionId));
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<Promotion>(
          value: async,
          onRetry: () => ref.invalidate(promotionProvider(promotionId)),
          data: (p) => RefreshIndicator(
            onRefresh: () => ref.refresh(promotionProvider(promotionId).future),
            child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              const BackHeader(title: '官方活动'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  PromotionBanner(promotion: p, height: 170),
                  const SizedBox(height: 12),
                  Row(children: [
                    _promoStatus(p),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(promoRangeText(p.startsAt, p.endsAt),
                          key: const Key('promotion_time'), style: const TextStyle(color: LL.text2, fontWeight: FontWeight.w700)),
                    ),
                  ]),
                  if (p.description.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(p.description, style: const TextStyle(color: LL.text2, height: 1.6)),
                  ],
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 18, 0, 8),
                    child: Text(p.isUpcoming ? '活动商品 · 开始后按活动价购买' : '活动商品 · ${p.items.length} 个',
                        style: const TextStyle(color: LL.text2, fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                  if (p.items.isEmpty)
                    const LLCard(child: Text('活动商品正在上架中，晚点再来看看', style: TextStyle(color: LL.text2)))
                  else
                    for (final it in p.items) ...[ProductCard(product: it), const SizedBox(height: 8)],
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
