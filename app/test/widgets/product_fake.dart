// Method-aware, stateful fake of the V2 batch 5 App endpoints of
// docs/api/v2-5-商户商品与开放平台.md: products, product orders (create / pay /
// cancel / refund), official promotions, the merchant page and the coupons
// they issue (wallet + QR). Venue detail's `products` is set on LocalFake's
// venue. Plug into fakeBackend(handlers: [products.handle, ...]).
//
// Product orders carry only what the contract names (no `pay` object): the
// mock channel is paid through `/v1/dev/orders/{order_no}/pay`; WeChat /
// Alipay "callbacks" arrive by the first `GET /v1/product-orders/{id}`.
import 'package:dio/dio.dart';

typedef J = Map<String, dynamic>;

const paoye = {'id': 3, 'name': '城南全民健身中心'};

J promo3({int left = 80}) =>
    {'id': 3, 'title': '双 12 运动狂欢', 'promo_price_amt': 4900, 'ends_at': '2026-12-12T23:59:59+08:00', 'promo_left_qty': left};

J productJson(
  int id, {
  String type = 'package',
  String title = '羽毛球 2 小时畅打套餐',
  String subtitle = '含球拍租借',
  int price = 6900,
  int? original = 9000,
  int useQty = 1,
  int? validDays = 30,
  String? validUntil,
  int sold = 37,
  bool soldOut = false,
  int limit = 0,
  bool refundable = true,
  J? promotion,
  List<J> venues = const [{'id': 8, 'name': '城南全民健身中心 · 匹克球'}],
  int? myBought,
}) =>
    {
      'id': id,
      'merchant': paoye,
      'type': type,
      'title': title,
      'subtitle': subtitle,
      'description': '周一至周五可用，节假日通用',
      'images': <String>[],
      'sports': ['badminton'],
      'price_amt': price,
      'original_amt': original,
      'use_qty': useQty,
      'valid_days': validDays,
      'valid_until': validUntil,
      'sold_qty': sold,
      'sold_out': soldOut,
      'per_user_limit_qty': limit,
      'refundable': refundable,
      'allow_promotion': promotion != null,
      'promotion': promotion,
      'venue_ids': [for (final v in venues) v['id']],
      'venues': venues,
      'rules': '到店出示券码，店员扫码核销；每次限 1 人使用',
      'my_bought_qty': ?myBought,
      'created_at': '2026-11-20T10:00:00+08:00',
      'updated_at': '2026-11-20T10:00:00+08:00',
    };

class ProductFake {
  ProductFake() {
    _seed();
  }

  final calls = <String>[];
  final bodies = <String, Object?>{};
  final products = <int, J>{};
  final orders = <J>[];
  final coupons = <J>[];

  /// The channel each order was created with (not in the order JSON).
  final channelOf = <int, String>{};

  /// What the server counts as already bought (per product) — the detail's
  /// `my_bought_qty` can be stale.
  final bought = <int, int>{};

  /// Products whose order answers 409 `not_on_sale` / `sold_out`.
  final offSale = <int>{};
  final soldOutNow = <int>{};
  int qrCount = 0;

  /// WeChat / Alipay orders get paid by the first poll (the "callback").
  bool callbackPays = true;
  int _next = 200;
  int _coupon = 900;

  List<J> promotions = [];

  void _seed() {
    products[31] = productJson(31, limit: 2, promotion: promo3(), myBought: 1);
    products[32] = productJson(32,
        type: 'pass', title: '游泳 10 次卡', subtitle: '恒温泳池 · 每次 2 小时', price: 39900, original: 50000, useQty: 10, validDays: 180, sold: 1260,
        promotion: {...promo3(), 'promo_price_amt': 29900, 'promo_left_qty': null});
    products[33] = productJson(33,
        type: 'voucher', title: '100 元代金券', subtitle: '全场通用', price: 8800, original: 10000, soldOut: true, refundable: false, sold: 520);
    products[34] = productJson(34, title: '匹克球 1 小时体验课', subtitle: '教练带练 · 含拍', price: 9900, original: null, validDays: null, validUntil: '2026-12-31', sold: 12);
    bought[31] = 1;
    promotions = [
      {
        'id': 3, 'title': '双 12 运动狂欢', 'subtitle': '羽毛球、游泳、健身 5 折起', 'banner_url': null,
        'description': '12 月 1 日至 12 日，合作场馆的团购套餐限时活动价，数量有限，抢完即止。',
        'starts_at': '2026-12-01T00:00:00+08:00', 'ends_at': '2026-12-12T23:59:59+08:00',
        'apply_open': true, 'apply_deadline': '2026-11-28T23:59:59+08:00', 'status': 'active', 'product_qty': 2,
        'created_at': '2026-11-20T10:00:00+08:00',
      },
    ];
    // A paid promotion order with two unused coupons.
    final o120 = _order(120, 31, 2, 'paid', unit: 4900, promotion: {'id': 3, 'title': '双 12 运动狂欢'});
    orders.add(o120);
    _issue(o120);
    // A pass, partly used, partly refunded.
    final o123 = _order(123, 32, 2, 'completed', unit: 39900, refund: 39900);
    orders.add(o123);
    _issue(o123);
    (o123['coupons'] as List)[0]
      ..['status'] = 'used'
      ..['uses_left'] = 0
      ..['used_at'] = '2026-11-21T19:00:00+08:00'
      ..['used_store'] = '张江店';
    (o123['coupons'] as List)[1]['status'] = 'refunded';
    final o122 = _order(122, 34, 1, 'refunded', unit: 9900, refund: 9900);
    orders.add(o122);
    _issue(o122, status: 'refunded');
  }

  /// A coupon for the wallet: a pass with 3 of 10 uses left.
  J passCoupon() {
    final o = orders.firstWhere((o) => o['id'] == 123);
    return {...(o['coupons'] as List)[0] as J, 'id': 950, 'code': 'PASS3LFT', 'status': 'unused', 'uses_left': 3, 'used_at': null, 'used_store': null};
  }

  /// An unpaid order on [channel] (for 继续支付 / 取消).
  J pendingOrder(int id, int productId, {String channel = 'mock'}) {
    final o = _order(id, productId, 1, 'pending', unit: products[productId]!['price_amt'] as int);
    channelOf[id] = channel;
    orders.insert(0, o);
    return o;
  }

  J _order(int id, int productId, int qty, String status, {required int unit, int refund = 0, J? promotion}) {
    final p = products[productId]!;
    return {
      'id': id,
      'order_no': 'PO20261122103000$id',
      'product': {'id': productId, 'title': p['title'], 'type': p['type'], 'image': null},
      'merchant': paoye,
      'qty': qty,
      'unit_price_amt': unit,
      'amount_amt': unit * qty,
      'refund_amt': refund,
      'promotion': promotion,
      'status': status,
      'coupons': <J>[],
      'pay_expires_at': '2099-11-22T10:45:00+08:00',
      'paid_at': status == 'pending' ? null : '2026-11-22T10:31:00+08:00',
      'created_at': '2026-11-22T10:30:00+08:00',
    };
  }

  void _issue(J o, {String status = 'unused'}) {
    final p = products[(o['product'] as Map)['id']]!;
    final list = <J>[
      for (var i = 0; i < (o['qty'] as int); i++)
        {
          'id': _coupon++,
          'code': 'PRD${o['id']}X$i',
          'perk': {
            'title': p['title'],
            'description': p['subtitle'],
            'value_text': _yuan(o['unit_price_amt'] as int),
            'valid_days': p['valid_days'] ?? 0,
            'rules': p['rules'],
          },
          'merchant': paoye,
          'source': {'type': 'product', 'product_id': p['id'], 'order_id': o['id'], 'name': p['title']},
          'status': status,
          'uses_total': p['use_qty'],
          'uses_left': status == 'unused' ? p['use_qty'] : 0,
          'obtained_at': '2026-11-22T10:31:00+08:00',
          'expires_at': '2026-12-22T23:59:59+08:00',
          'used_at': null,
          'used_store': null,
        },
    ];
    o['coupons'] = list;
    coupons.addAll(list);
  }

  static String _yuan(int fen) => fen % 100 == 0 ? '¥${fen ~/ 100}' : '¥${(fen / 100).toStringAsFixed(2)}';

  int count(String call) => calls.where((c) => c == call).length;

  static (int, Object?) _err(int status, String code, [String message = '']) =>
      (status, {'error': {'code': code, 'message': message}});

  J? _orderById(int? id) => orders.where((o) => o['id'] == id).firstOrNull;

  J _params(String channel) => switch (channel) {
        'wechat' => {'appid': 'wx1', 'partnerid': '1', 'prepayid': 'pp', 'package': 'Sign=WXPay', 'noncestr': 'n', 'timestamp': '1', 'sign': 's'},
        'alipay' => {'order_string': 'alipay_sdk=po'},
        _ => <String, dynamic>{},
      };

  void _markPaid(J o) {
    if (o['status'] != 'pending') return;
    o['status'] = 'paid';
    o['paid_at'] = '2026-11-22T10:31:00+08:00';
    final pid = (o['product'] as Map)['id'] as int;
    bought[pid] = (bought[pid] ?? 0) + (o['qty'] as int);
    final p = products[pid]!;
    p['sold_qty'] = (p['sold_qty'] as int) + (o['qty'] as int);
    _issue(o);
  }

  (int, Object?)? handle(RequestOptions o) {
    final body = o.data is Map ? (o.data as Map).cast<String, dynamic>() : <String, dynamic>{};
    final r = _route(o.method, o.path, body, o.queryParameters);
    if (r != null) {
      calls.add('${o.method} ${o.path}');
      bodies['${o.method} ${o.path}'] = o.data is Map ? body : o.data;
    }
    return r;
  }

  (int, Object?)? _route(String m, String p, J body, Map<String, dynamic> q) {
    final seg = p.split('/');
    int? idAt(int i) => seg.length > i ? int.tryParse(seg[i]) : null;

    // GET /v1/merchants/{id}/products
    if (m == 'GET' && seg.length == 5 && seg[2] == 'merchants' && seg[4] == 'products') {
      return (200, {'items': [for (final v in products.values) if (v['merchant']['id'] == idAt(3)) {...v}..remove('my_bought_qty')], 'next_cursor': null});
    }
    if (seg.length >= 4 && seg[2] == 'products') {
      final id = idAt(3);
      final prod = products[id];
      if (prod == null) return _err(404, 'not_found');
      if (m == 'GET' && seg.length == 4) return (200, {...prod, 'my_bought_qty': bought[id] ?? 0});
      if (m == 'POST' && seg.length == 5 && seg[4] == 'orders') {
        final qty = body['qty'];
        if (qty is! int || qty < 1 || qty > 10) return _err(400, 'invalid_request', 'qty 1–10');
        if (!const {'wechat', 'alipay', 'mock'}.contains(body['channel'])) return _err(400, 'channel_not_allowed');
        if (offSale.contains(id)) return _err(409, 'not_on_sale', '商品已下架');
        if (prod['sold_out'] == true || soldOutNow.contains(id)) return _err(409, 'sold_out', '库存不足');
        final limit = prod['per_user_limit_qty'] as int;
        if (limit > 0 && (bought[id] ?? 0) + qty > limit) return _err(409, 'limit_reached', '超过限购');
        final promo = prod['promotion'] as Map?;
        final unit = promo == null ? prod['price_amt'] as int : promo['promo_price_amt'] as int;
        final ord = _order(_next++, id!, qty, 'pending', unit: unit, promotion: promo == null ? null : {'id': promo['id'], 'title': promo['title']});
        channelOf[ord['id'] as int] = body['channel'] as String;
        orders.insert(0, ord);
        return (200, {'order': ord, 'pay_params': _params(body['channel'] as String)});
      }
    }
    if (m == 'GET' && p == '/v1/me/product-orders') {
      final st = '${q['status'] ?? ''}';
      return (200, {'items': [for (final o in orders) if (st.isEmpty || o['status'] == st) o]});
    }
    if (seg.length >= 4 && seg[2] == 'product-orders') {
      final ord = _orderById(idAt(3));
      if (ord == null) return _err(404, 'not_found');
      final id = ord['id'] as int;
      final sub = seg.length > 4 ? seg[4] : '';
      if (m == 'GET' && sub.isEmpty) {
        if (callbackPays && channelOf[id] != 'mock' && channelOf[id] != null) _markPaid(ord);
        return (200, ord);
      }
      if (m == 'POST' && sub == 'pay') {
        if (ord['status'] != 'pending') return _err(409, 'invalid_status');
        return (200, {'order': ord, 'pay_params': _params(channelOf[id] ?? 'mock')});
      }
      if (m == 'POST' && sub == 'cancel') {
        if (ord['status'] != 'pending') return _err(409, 'invalid_status');
        ord['status'] = 'cancelled';
        return (200, ord);
      }
      if (m == 'POST' && sub == 'refund') {
        final prod = products[(ord['product'] as Map)['id']]!;
        if (prod['refundable'] != true) return _err(409, 'not_refundable', '该商品不可退款');
        final unused = [for (final c in ord['coupons'] as List) if (c['status'] == 'unused' && c['uses_left'] == c['uses_total']) c as J];
        if (unused.isEmpty) return _err(409, 'nothing_to_refund');
        for (final c in unused) {
          c['status'] = 'refunded';
        }
        ord['refund_amt'] = (ord['refund_amt'] as int) + unused.length * (ord['unit_price_amt'] as int);
        final all = (ord['coupons'] as List).every((c) => c['status'] == 'refunded');
        if (all) ord['status'] = 'refunded';
        return (200, ord);
      }
    }
    // The mock channel's dev payment, by the product order's number.
    if (m == 'POST' && seg.length == 6 && seg[2] == 'dev' && seg[3] == 'orders') {
      final ord = orders.where((o) => o['order_no'] == seg[4]).firstOrNull;
      if (ord == null) return null;
      _markPaid(ord);
      return (200, {'order_no': seg[4], 'plan_code': '', 'amount_fen': ord['amount_amt'], 'channel': 'mock', 'status': 'paid'});
    }
    if (m == 'GET' && p == '/v1/promotions') return (200, {'items': promotions});
    if (m == 'GET' && seg.length == 4 && seg[2] == 'promotions') {
      final pr = promotions.where((x) => x['id'] == idAt(3)).firstOrNull;
      if (pr == null) return _err(404, 'not_found');
      return (200, {
        ...pr,
        'items': [
          for (final v in products.values)
            if ((v['promotion'] as Map?)?['id'] == pr['id']) {...v}..remove('my_bought_qty'),
        ],
      });
    }
    // Wallet: every coupon (bought ones and a drop coupon).
    if (m == 'GET' && p == '/v1/me/coupons') {
      final st = q['status'];
      return (200, {'items': [for (final c in coupons) if (st == null || c['status'] == st) c]});
    }
    final qr = RegExp(r'^/v1/coupons/(\d+)/qr$').firstMatch(p);
    if (qr != null) {
      qrCount++;
      return (200, {'payload': 'LPC.${qr.group(1)}.$qrCount.sig', 'expires_in_sec': 60});
    }
    return null;
  }
}
