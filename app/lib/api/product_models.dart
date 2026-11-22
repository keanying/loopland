// V2 batch 5「商户商品与开放平台」— the App side: merchant products (套餐券 /
// 代金券 / 次卡), product orders and official promotions
// (docs/api/v2-5-商户商品与开放平台.md). Product coupons reuse Coupon
// (perks_models.dart). Same tolerant parsing as the other model files.
import 'community_common.dart';
import 'local_models.dart' show IdName;
import 'models.dart' show Json;
import 'perks_models.dart' show Coupon;

/// `type` → label: `package` 套餐券, `voucher` 代金券, `pass` 次卡.
String productTypeName(String type) => switch (type) {
      'package' => '套餐券',
      'voucher' => '代金券',
      'pass' => '次卡',
      _ => '团购',
    };

/// `Product.promotion`: the official promotion price in effect.
class ProductPromotion {
  const ProductPromotion({required this.id, this.title = '', this.promoPriceAmt = 0, this.endsAt, this.promoLeftQty});
  final int id;
  final String title;
  final int promoPriceAmt;
  final DateTime? endsAt;

  /// Promotion stock left; null = unlimited.
  final int? promoLeftQty;

  static ProductPromotion? maybe(Object? v) {
    final j = jmn(v);
    if (j == null) return null;
    return ProductPromotion(
      id: ji(j['id']),
      title: js(j['title']),
      promoPriceAmt: ji(j['promo_price_amt']),
      endsAt: jdt(j['ends_at']),
      promoLeftQty: jin(j['promo_left_qty']),
    );
  }
}

/// `Product` as the App sees it (only `on_sale` ones; `sold_out` instead of
/// the stock).
class Product {
  const Product({
    required this.id,
    required this.title,
    this.merchant,
    this.type = 'package',
    this.subtitle = '',
    this.description = '',
    this.images = const [],
    this.sports = const [],
    this.priceAmt = 0,
    this.originalAmt,
    this.useQty = 1,
    this.validDays,
    this.validUntil,
    this.soldQty = 0,
    this.soldOut = false,
    this.perUserLimitQty = 0,
    this.refundable = true,
    this.promotion,
    this.venueIds = const [],
    this.venues = const [],
    this.rules = '',
    this.myBoughtQty,
  });
  final int id;
  final String title;
  final IdName? merchant;

  /// `package | voucher | pass`.
  final String type;
  final String subtitle, description;
  final List<String> images;
  final List<String> sports;

  /// Selling price (分).
  final int priceAmt;

  /// 门市价 / 面值 (代金券); null = none.
  final int? originalAmt;

  /// Uses per coupon: 2–100 for `pass`, else 1.
  final int useQty;

  /// Either [validDays] (days after purchase) or [validUntil] (`YYYY-MM-DD`).
  final int? validDays;
  final String? validUntil;
  final int soldQty;
  final bool soldOut;

  /// 0 = no limit.
  final int perUserLimitQty;
  final bool refundable;
  final ProductPromotion? promotion;

  /// Empty = every venue of the merchant.
  final List<int> venueIds;
  final List<IdName> venues;
  final String rules;

  /// Only from `GET /v1/products/{id}`: paid, not fully refunded pieces I bought.
  final int? myBoughtQty;

  bool get isPass => type == 'pass';
  bool get isVoucher => type == 'voucher';
  bool get onPromotion => promotion != null;

  /// What one piece costs now (the promotion price when there is one).
  int get payAmt => promotion?.promoPriceAmt ?? priceAmt;

  /// The struck-through reference price: the regular price under a
  /// promotion, else the 门市价 (only when higher).
  int? get strikeAmt {
    if (promotion != null) return promotion!.promoPriceAmt < priceAmt ? priceAmt : (_orig);
    return _orig;
  }

  int? get _orig => originalAmt != null && originalAmt! > payAmt ? originalAmt : null;

  /// 「套餐券」「代金券 · 面值 ¥100」「次卡 10 次」.
  String get typeLabel => switch (type) {
        'pass' => '次卡 $useQty 次',
        'voucher' => originalAmt == null ? '代金券' : '代金券 · 面值 ${_yuan(originalAmt!)}',
        _ => productTypeName(type),
      };

  /// 「购买后 30 天内有效」/「有效期至 2026-12-31」.
  String get validityText {
    if (validUntil != null && validUntil!.isNotEmpty) return '有效期至 $validUntil';
    if (validDays != null && validDays! > 0) return '购买后 $validDays 天内有效';
    return '以券面有效期为准';
  }

  /// 「随时退 · 过期自动退」/「不可退」.
  String get refundText => refundable ? '随时退 · 过期自动退' : '不可退';

  /// How many more I may buy now (null = no per-user limit).
  int? get limitLeft {
    if (perUserLimitQty <= 0) return null;
    final left = perUserLimitQty - (myBoughtQty ?? 0);
    return left < 0 ? 0 : left;
  }

  /// Max quantity of one order: 1–10, the per-user limit and the promotion
  /// stock.
  int get maxQty {
    var m = 10;
    final l = limitLeft;
    if (l != null && l < m) m = l;
    final p = promotion?.promoLeftQty;
    if (p != null && p < m) m = p;
    return m < 0 ? 0 : m;
  }

  /// 「已售 37」/「已售 1.2 万」.
  String get soldText => soldQty >= 10000 ? '已售 ${(soldQty / 10000).toStringAsFixed(1)} 万' : '已售 $soldQty';

  String? get cover => images.isEmpty ? null : images.first;

  factory Product.fromJson(Json j) => Product(
        id: ji(j['id']),
        title: js(j['title']),
        merchant: IdName.maybe(j['merchant']),
        type: js(j['type'], 'package'),
        subtitle: js(j['subtitle']),
        description: js(j['description']),
        images: j['images'] is List ? [for (final s in j['images'] as List) if (s is String && s.isNotEmpty) s] : const [],
        sports: j['sports'] is List ? [for (final s in j['sports'] as List) if (s != null) '$s'] : const [],
        priceAmt: ji(j['price_amt']),
        originalAmt: jin(j['original_amt']),
        useQty: ji(j['use_qty'], 1),
        validDays: jin(j['valid_days']),
        validUntil: jsn(j['valid_until']),
        soldQty: ji(j['sold_qty']),
        soldOut: jb(j['sold_out']),
        perUserLimitQty: ji(j['per_user_limit_qty']),
        refundable: jb(j['refundable'], true),
        promotion: ProductPromotion.maybe(j['promotion']),
        venueIds: j['venue_ids'] is List ? [for (final v in j['venue_ids'] as List) if (v is num) v.toInt()] : const [],
        venues: [
          if (j['venues'] is List)
            for (final v in j['venues'] as List) ?IdName.maybe(v),
        ],
        rules: js(j['rules']),
        myBoughtQty: jin(j['my_bought_qty']),
      );
}

String _yuan(int fen) => fen % 100 == 0 ? '¥${fen ~/ 100}' : '¥${(fen / 100).toStringAsFixed(2)}';

/// `ProductOrder.product`.
class ProductBrief {
  const ProductBrief({required this.id, this.title = '', this.type = 'package', this.image});
  final int id;
  final String title, type;
  final String? image;
  static ProductBrief? maybe(Object? v) {
    final j = jmn(v);
    if (j == null) return null;
    return ProductBrief(id: ji(j['id']), title: js(j['title']), type: js(j['type'], 'package'), image: jsn(j['image']));
  }
}

const productOrderStatusNames = {
  'pending': '待支付',
  'paid': '待使用',
  'completed': '已完成',
  'refunding': '退款中',
  'refunded': '已退款',
  'cancelled': '已取消',
};

/// `ProductOrder`.
class ProductOrder {
  const ProductOrder({
    required this.id,
    this.orderNo = '',
    this.product,
    this.merchant,
    this.qty = 1,
    this.unitPriceAmt = 0,
    this.amountAmt = 0,
    this.refundAmt = 0,
    this.promotion,
    this.status = 'pending',
    this.coupons = const [],
    this.payExpiresAt,
    this.paidAt,
    this.createdAt,
    this.payOrderNo,
    this.channel,
    this.refundable,
  });
  final int id;

  /// `PO…` — the product order's own number.
  final String orderNo;
  final ProductBrief? product;
  final IdName? merchant;
  final int qty;
  final int unitPriceAmt, amountAmt;

  /// Refunded so far (partial refunds keep `paid` / `completed`).
  final int refundAmt;

  /// `{id, title}` when bought at a promotion price.
  final IdName? promotion;

  /// `pending | paid | completed | refunding | refunded | cancelled`.
  final String status;
  final List<Coupon> coupons;
  final DateTime? payExpiresAt, paidAt, createdAt;

  /// The payment order behind it (`pay.order_no`, as on Booking) when the
  /// server sends it; the contract only names [orderNo].
  final String? payOrderNo;

  /// `pay.channel` / `channel` when sent.
  final String? channel;

  /// `refundable` (order or product) when sent; null = unknown.
  final bool? refundable;

  String get statusName => productOrderStatusNames[status] ?? status;
  bool get isPending => status == 'pending';
  bool get isPaid => status == 'paid';
  bool get partlyRefunded => refundAmt > 0 && status != 'refunded';

  /// Coupons not used yet (what a refund returns).
  List<Coupon> get unusedCoupons => [for (final c in coupons) if (c.isUnused) c];

  /// The order number the payment endpoints (`/v1/orders/{no}`,
  /// `/v1/dev/orders/{no}/pay`) understand.
  String get paymentNo => payOrderNo ?? orderNo;

  factory ProductOrder.fromJson(Json j) {
    final pay = jm(j['pay']);
    final prod = jm(j['product']);
    final r = j['refundable'] ?? prod['refundable'];
    return ProductOrder(
      id: ji(j['id']),
      orderNo: js(j['order_no']),
      product: ProductBrief.maybe(j['product']),
      merchant: IdName.maybe(j['merchant']),
      qty: ji(j['qty'], 1),
      unitPriceAmt: ji(j['unit_price_amt']),
      amountAmt: ji(j['amount_amt']),
      refundAmt: ji(j['refund_amt']),
      promotion: _promo(j['promotion']),
      status: js(j['status'], 'pending'),
      coupons: jl(j['coupons'], Coupon.fromJson),
      payExpiresAt: jdt(j['pay_expires_at']),
      paidAt: jdt(j['paid_at']),
      createdAt: jdt(j['created_at']),
      payOrderNo: jsn(pay['order_no']),
      channel: jsn(pay['channel']) ?? jsn(j['channel']),
      refundable: r is bool ? r : null,
    );
  }
}

/// `ProductOrder.promotion` is `{id, title}`.
IdName? _promo(Object? v) {
  final j = jmn(v);
  return j == null ? null : IdName(id: ji(j['id']), name: js(j['title'], js(j['name'])));
}

/// `POST /v1/products/{id}/orders`, `POST /v1/product-orders/{id}/pay` →
/// `{"order", "pay_params"}`.
class ProductOrderCreated {
  const ProductOrderCreated({required this.order, this.payParams = const {}});
  final ProductOrder order;
  final Json payParams;
  factory ProductOrderCreated.fromJson(Json j) =>
      ProductOrderCreated(order: ProductOrder.fromJson(jm(j['order'])), payParams: jm(j['pay_params']));
}

/// Official promotion (官方活动). `GET /v1/promotions/{id}` adds [items].
class Promotion {
  const Promotion({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.bannerUrl,
    this.description = '',
    this.startsAt,
    this.endsAt,
    this.status = 'active',
    this.productQty = 0,
    this.items = const [],
  });
  final int id;
  final String title, subtitle;
  final String? bannerUrl;
  final String description;
  final DateTime? startsAt, endsAt;

  /// The App sees `scheduled | active`.
  final String status;
  final int productQty;

  /// Products of the active entries; their `promotion` is this one's price.
  final List<Product> items;

  bool get isActive => status == 'active';
  bool get isUpcoming => status == 'scheduled';

  factory Promotion.fromJson(Json j) => Promotion(
        id: ji(j['id']),
        title: js(j['title']),
        subtitle: js(j['subtitle']),
        bannerUrl: jsn(j['banner_url']),
        description: js(j['description']),
        startsAt: jdt(j['starts_at']),
        endsAt: jdt(j['ends_at']),
        status: js(j['status'], 'active'),
        productQty: ji(j['product_qty']),
        items: jl(j['items'], Product.fromJson),
      );
}
