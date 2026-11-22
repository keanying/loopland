// V2 batch 5「商户商品」App screens against the stateful ProductFake:
// 场馆详情「团购 / 套餐」, 商品详情 + buying (mock / WeChat, sold out, limit,
// off sale), 我的订单 → 商品 (detail, 继续支付, 取消, 退款), 卡券包 (已购, 次卡
// 剩余次数, 已退款), 官方活动 and the merchant page.
// With LOOPLAND_SCREENSHOTS=1 they write PNGs to app/screenshots/v2/.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:loopland/api/local_models.dart';
import 'package:loopland/api/perks_models.dart';
import 'package:loopland/api/product_api.dart';
import 'package:loopland/api/product_models.dart';
import 'package:loopland/core/providers.dart';
import 'package:loopland/core/sdk_config.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/features/local/local_page.dart';
import 'package:loopland/features/local/local_routes.dart';
import 'package:loopland/features/local/perks_routes.dart';
import 'package:loopland/features/local/product_pay.dart';
import 'package:loopland/map/territory_map.dart';
import 'package:loopland/map/venue_marker.dart';
import 'package:loopland/pay/payment_service.dart';
import 'package:loopland/run/location_source.dart';
import 'package:loopland/run/run_controller.dart';
import 'package:loopland/widgets/common.dart' show ChipTabs;
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../pay/payment_service_test.dart' show FakeGateways;
import 'fake_backend.dart';
import 'gathering_fake.dart';
import 'local_fake.dart';
import 'product_fake.dart';
import 'screens_test.dart' show fixAt;
import 'test_helpers.dart';

late ProductFake products;
late LocalFake local;
late GatheringFake gathering;
late FakeGateways gateways;

List<Override> overrides() => [
      ...fakeBackend(handlers: [products.handle, local.handle, gathering.handle]),
      locationSourceProvider.overrideWithValue(FakeLocationSource([fixAt(0, 0, 0)])),
      paymentServiceProvider.overrideWith((ref) => PaymentService(ref.watch(apiProvider),
          gateways: gateways, pollInterval: Duration.zero, pollTimeout: Duration.zero, unpaidCheckTimeout: Duration.zero)),
    ];

class _Stub extends StatelessWidget {
  const _Stub(this.loc);
  final String loc;
  @override
  Widget build(BuildContext context) => Scaffold(body: Center(child: Text('STUB $loc')));
}

Widget app(String initial) {
  final router = GoRouter(initialLocation: initial, routes: [
    GoRoute(path: '/local', builder: (_, s) => LocalPage(tab: s.uri.queryParameters['tab'] ?? 'booking', now: () => local.now)),
    ...localRoutes(),
    ...perksRoutes(),
    for (final p in ['/realname', '/users/:id', '/meetups/:id']) GoRoute(path: p, builder: (_, s) => _Stub(s.uri.toString())),
  ]);
  return RepaintBoundary(
    key: const Key('shot'),
    child: ProviderScope(
      overrides: overrides(),
      retry: (_, _) => null,
      child: MaterialApp.router(theme: buildTheme(), routerConfig: router, debugShowCheckedModeBanner: false),
    ),
  );
}

Future<void> shot(WidgetTester t, String name) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await t.pump();
  await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/$name.png');
}

Future<void> tapIdle(WidgetTester t, Finder f, [int rounds = 3]) async {
  for (final m in t.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
    m.removeCurrentSnackBar();
  }
  await t.pump(const Duration(milliseconds: 100));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await idle(t, rounds);
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  late SdkConfig saved;

  setUpAll(() async {
    TerritoryMapView.forceFallback = true;
    VenueAvatars.enabled = false;
    await loadFonts();
  });

  setUp(() {
    products = ProductFake();
    local = LocalFake();
    gathering = GatheringFake();
    gateways = FakeGateways();
    // Venue 8 sells three products (one sold out).
    local.venues.first['products'] = [products.products[31], products.products[32], products.products[33], products.products[34]];
    saved = SdkConfig.current;
    SdkConfig.current = SdkConfig.fromMap(
        const {'LOOPLAND_ENV': 'dev', 'WECHAT_APP_ID': 'wx123', 'WECHAT_UNIVERSAL_LINK': 'https://loop.test/wechat/'},
        platform: 'ios');
  });

  tearDown(() => SdkConfig.current = saved);

  group('models', () {
    test('product: promotion price, struck price, type labels, validity, limits', () {
      final p = Product.fromJson(products.products[31]!);
      expect(p.payAmt, 4900);
      expect(p.strikeAmt, 6900, reason: 'regular price struck under a promotion');
      expect(p.promotion!.promoLeftQty, 80);
      expect(p.typeLabel, '套餐券');
      expect(p.validityText, '购买后 30 天内有效');
      expect(p.refundText, '随时退 · 过期自动退');
      expect(p.limitLeft, 1);
      expect(p.maxQty, 1);
      expect(p.venues.single.name, '城南全民健身中心 · 匹克球');

      final pass = Product.fromJson({...products.products[32]!, 'promotion': null});
      expect(pass.typeLabel, '次卡 10 次');
      expect(pass.strikeAmt, 50000, reason: '门市价 without a promotion');
      expect(pass.limitLeft, isNull);
      expect(pass.maxQty, 10);
      expect(pass.soldText, '已售 1260');

      final v = Product.fromJson(products.products[33]!);
      expect(v.typeLabel, '代金券 · 面值 ¥100');
      expect(v.soldOut, isTrue);
      expect(v.refundText, '不可退');
      final until = Product.fromJson(products.products[34]!);
      expect(until.validityText, '有效期至 2026-12-31');
      expect(until.strikeAmt, isNull);
      expect(Product.fromJson({'id': 1, 'title': 'x', 'sold_qty': 12345}).soldText, '已售 1.2 万');

      final venue = Venue.fromJson(local.venues.first);
      expect(venue.products.length, 4);
    });

    test('product order, coupons and channels', () {
      final o = ProductOrder.fromJson(products.orders.firstWhere((o) => o['id'] == 123));
      expect(o.status, 'completed');
      expect(o.partlyRefunded, isTrue);
      expect(o.coupons.first.isProduct, isTrue);
      expect(o.coupons.first.source!.orderId, 123);
      expect(o.coupons.first.usesTotal, 10);
      expect(o.paymentNo, o.orderNo, reason: 'no pay object in the contract');
      expect(ProductOrder.fromJson({'id': 1, 'order_no': 'PO1', 'pay': {'order_no': 'LP9', 'channel': 'wechat'}}).paymentNo, 'LP9');
      final c = Coupon.fromJson(products.passCoupon());
      expect(c.isPass, isTrue);
      expect(c.usesText, '剩余 3/10 次');
      expect(Coupon.fromJson({'id': 1, 'code': 'x', 'perk': {}, 'status': 'refunded'}).statusText, '已退款');
      expect(Coupon.fromJson({'id': 1, 'code': 'x', 'perk': {}}).usesLeft, 1);
      expect(productChannel('wechat_app'), 'wechat');
      expect(productChannel('alipay_app'), 'alipay');
      expect(productChannel('mock'), 'mock');
      expect(appChannel('wechat'), 'wechat_app');
      expect(channelOfParams({'order_string': 'x'}), 'alipay_app');
      expect(channelOfParams({'prepayid': 'x'}), 'wechat_app');
      expect(channelOfParams({}), isNull);
      final promo = Promotion.fromJson(products.promotions.first);
      expect(promo.isActive, isTrue);
      expect(promo.productQty, 2);
    });
  });

  testWidgets('场馆详情: 团购 / 套餐 cards with 活动价, struck price, sold out, expand; → 商品详情', (t) async {
    await phone(t, size: const Size(390, 1500));
    await t.pumpWidget(app('/venues/8'));
    await idle(t);
    expect(find.text('团购 / 套餐'), findsOneWidget);
    expect(find.text('羽毛球 2 小时畅打套餐'), findsOneWidget);
    expect(find.text('¥49'), findsOneWidget);
    expect(find.text('¥69'), findsOneWidget, reason: 'regular price struck');
    expect(find.text('活动价'), findsNWidgets(2));
    expect(find.text('官方活动 · 双 12 运动狂欢'), findsNWidgets(2));
    expect(find.text('已售 37'), findsOneWidget);
    expect(find.text('已售罄'), findsNWidgets(2), reason: 'overlay + sales line of the voucher');
    expect(find.text('匹克球 1 小时体验课'), findsNothing, reason: 'collapsed to 3');
    await shot(t, 'product_venue_section');
    await tapIdle(t, find.byKey(const Key('products_toggle')));
    expect(find.text('匹克球 1 小时体验课'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);

    await tapIdle(t, find.byKey(const Key('product_31')));
    expect(products.calls, contains('GET /v1/products/31'));
    expect(find.byKey(const Key('price_block')), findsOneWidget);
    await settle(t);
  });

  testWidgets('商品详情: price block, venues, validity, rules, refund note, limit; buy with mock → coupons', (t) async {
    await phone(t, size: const Size(390, 1700));
    await t.pumpWidget(app('/products/31'));
    await idle(t);
    expect(t.widget<Text>(find.byKey(const Key('product_price'))).data, '¥49');
    expect(find.text('原价 '), findsOneWidget);
    expect(find.text('门市价 '), findsOneWidget);
    expect(find.text('¥90'), findsOneWidget);
    expect(find.textContaining('官方活动 · 双 12 运动狂欢'), findsOneWidget);
    expect(find.textContaining('活动剩 80 件'), findsWidgets);
    expect(find.text('套餐券'), findsOneWidget);
    expect(find.text('随时退 · 过期自动退'), findsOneWidget);
    expect(find.text('城南全民健身中心 · 匹克球'), findsOneWidget);
    expect(find.text('购买后 30 天内有效'), findsOneWidget);
    expect(find.text('每次限 1 人使用'), findsOneWidget);
    expect(find.textContaining('随时退：未使用的券'), findsOneWidget);
    expect(find.textContaining('每人限购 2 件，已买 1 件'), findsOneWidget);
    // Limit 2, bought 1 → only one more.
    expect(t.widget<IconButton>(find.byKey(const Key('qty_plus'))).onPressed, isNull);
    expect(t.widget<Text>(find.byKey(const Key('product_total'))).data, '¥49');
    await shot(t, 'product_detail');

    await tapIdle(t, find.byKey(const Key('product_buy')));
    expect(find.text('确认订单'), findsOneWidget);
    expect(find.text('支付 ¥49'), findsOneWidget);
    await shot(t, 'product_buy_sheet');
    await t.tap(find.byKey(const Key('channel_mock')));
    await t.pump();
    await tapIdle(t, find.byKey(const Key('product_pay')), 5);
    expect(products.bodies['POST /v1/products/31/orders'], {'qty': 1, 'channel': 'mock'});
    expect(products.calls, contains('POST /v1/dev/orders/PO20261122103000200/pay'));
    expect(find.text('购买成功'), findsOneWidget);
    expect(find.textContaining('1 张券已放进卡券包'), findsOneWidget);
    expect(find.text('羽毛球 2 小时畅打套餐'), findsWidgets);
    await shot(t, 'product_paid');
    await tapIdle(t, find.byKey(const Key('result_coupons')));
    expect(find.text('卡券包'), findsOneWidget);
    await settle(t);
  });

  testWidgets('购买: WeChat (contract channel name), quantity stepper, sold out, limit reached, off sale', (t) async {
    await phone(t, size: const Size(390, 1500));
    await t.pumpWidget(app('/products/32'));
    await idle(t);
    expect(find.text('次卡 10 次'), findsOneWidget);
    expect(find.textContaining('次卡共 10 次'), findsOneWidget);
    await tapIdle(t, find.byKey(const Key('qty_plus')));
    await tapIdle(t, find.byKey(const Key('qty_plus')));
    expect(t.widget<Text>(find.byKey(const Key('qty'))).data, '3');
    expect(t.widget<Text>(find.byKey(const Key('product_total'))).data, '¥897');
    await tapIdle(t, find.byKey(const Key('qty_minus')));
    await tapIdle(t, find.byKey(const Key('product_buy')));
    await tapIdle(t, find.byKey(const Key('product_pay')), 5); // default: WeChat
    expect(gateways.log, ['sdk']);
    expect(gateways.wechatParams!['prepayid'], 'pp');
    expect(products.bodies['POST /v1/products/32/orders'], {'qty': 2, 'channel': 'wechat'});
    expect(find.text('购买成功'), findsOneWidget);
    expect(find.text('剩余 10/10 次 · 有效期至 12.22'), findsNWidgets(2));
    await t.tapAt(const Offset(195, 40)); // close the result sheet
    await idle(t);

    // Sold out meanwhile → dialog, product reloaded.
    products.soldOutNow.add(32);
    await tapIdle(t, find.byKey(const Key('product_buy')));
    await tapIdle(t, find.byKey(const Key('product_pay')), 5);
    expect(find.text('已售罄'), findsWidgets);
    expect(find.textContaining('库存刚被抢完了'), findsOneWidget);
    await tapIdle(t, find.text('知道了'));

    // The page thinks one more is allowed; the server says the limit is reached.
    await t.pumpWidget(app('/products/31'));
    await idle(t);
    products.bought[31] = 2;
    await tapIdle(t, find.byKey(const Key('product_buy')));
    await tapIdle(t, find.byKey(const Key('product_pay')), 5);
    expect(find.text('已达限购'), findsWidgets);
    expect(find.textContaining('已达到每人限购数量'), findsOneWidget);
    await tapIdle(t, find.text('知道了'));
    expect(find.text('已达限购'), findsOneWidget, reason: 'reloaded: the buy button is blocked');
    expect(t.widget<FilledButton>(find.byKey(const Key('product_buy'))).onPressed, isNull);

    await t.pumpWidget(app('/products/34'));
    await idle(t);
    products.offSale.add(34);
    await tapIdle(t, find.byKey(const Key('product_buy')));
    await tapIdle(t, find.byKey(const Key('product_pay')), 5);
    expect(find.text('这个商品已下架，暂时买不了'), findsOneWidget);
    await settle(t);
  });

  testWidgets('不可退 + 已售罄: refund note, buy blocked; WeChat cancelled → order kept pending', (t) async {
    await phone(t, size: const Size(390, 1500));
    await t.pumpWidget(app('/products/33'));
    await idle(t);
    expect(find.text('代金券 · 面值 ¥100'), findsOneWidget);
    expect(find.text('不可退'), findsOneWidget);
    expect(find.textContaining('不可退：该商品购买后不支持退款'), findsOneWidget);
    expect(find.text('面值 '), findsOneWidget);
    expect(t.widget<FilledButton>(find.byKey(const Key('product_buy'))).onPressed, isNull);
    await shot(t, 'product_not_refundable');

    gateways = FakeGateways(wechatCode: -2);
    products.callbackPays = false;
    await t.pumpWidget(app('/products/34'));
    await idle(t);
    expect(find.text('有效期至 2026-12-31'), findsOneWidget);
    await tapIdle(t, find.byKey(const Key('product_buy')));
    await tapIdle(t, find.byKey(const Key('product_pay')), 5);
    expect(find.textContaining('支付已取消'), findsOneWidget);
    expect(products.orders.first['status'], 'pending');
    await settle(t);
  });

  testWidgets('我的订单 → 商品: list, partial refund, detail with coupons, refund with confirm', (t) async {
    await phone(t, size: const Size(390, 1200));
    await t.pumpWidget(app('/me/orders?type=product'));
    await idle(t);
    expect(find.text('我的订单'), findsOneWidget);
    expect(find.text('商品'), findsOneWidget);
    expect(products.calls, contains('GET /v1/me/product-orders'));
    expect(find.text('待使用'), findsWidgets);
    expect(find.text('已退 ¥399'), findsOneWidget);
    expect(find.text('活动价购买'), findsOneWidget);
    expect(find.text('¥98'), findsOneWidget);
    await shot(t, 'product_orders');

    await tapIdle(t, find.descendant(of: find.byType(ChipTabs), matching: find.text('已退款')));
    expect(products.calls.last, 'GET /v1/me/product-orders');
    expect(find.text('匹克球 1 小时体验课'), findsOneWidget);
    expect(find.text('羽毛球 2 小时畅打套餐'), findsNothing);
    await tapIdle(t, find.descendant(of: find.byType(ChipTabs), matching: find.text('全部', skipOffstage: false), skipOffstage: false));

    await tapIdle(t, find.byKey(const Key('product_order_120')));
    expect(find.text('订单详情'), findsOneWidget);
    expect(find.text('官方活动'), findsOneWidget);
    expect(find.text('双 12 运动狂欢'), findsOneWidget);
    expect(find.text('券 · 2 张'), findsOneWidget);
    expect(find.text('2 张可用'), findsOneWidget);
    expect(find.byKey(const Key('coupon_bought')), findsNWidgets(2));
    await shot(t, 'product_order_detail');
    await tapIdle(t, find.byKey(const Key('product_order_refund')));
    expect(find.textContaining('将退回 2 张未使用的券，约 ¥98'), findsOneWidget);
    await tapIdle(t, find.byKey(const Key('confirm_yes')));
    expect(products.calls, contains('POST /v1/product-orders/120/refund'));
    expect(find.text('退款成功，原路退回'), findsOneWidget);
    expect(find.text('已退款'), findsWidgets);
    expect(find.textContaining('已全部退款，¥98 原路退回'), findsOneWidget);
    expect(find.byKey(const Key('product_order_refund')), findsNothing);
    await shot(t, 'product_order_refunded');
    await settle(t);
  });

  testWidgets('商品订单: 继续支付 (mock), 取消, not refundable from the server', (t) async {
    await phone(t, size: const Size(390, 1100));
    products.pendingOrder(130, 34);
    await t.pumpWidget(app('/me/product-orders/130'));
    await idle(t);
    expect(find.text('待支付'), findsOneWidget);
    expect(find.textContaining('前完成支付'), findsOneWidget);
    await shot(t, 'product_order_pending');
    await tapIdle(t, find.byKey(const Key('product_order_repay')), 5);
    expect(products.calls, contains('POST /v1/product-orders/130/pay'));
    expect(products.calls, contains('POST /v1/dev/orders/PO20261122103000130/pay'));
    expect(find.text('购买成功'), findsOneWidget);
    await t.tapAt(const Offset(195, 40));
    await idle(t);
    expect(find.text('待使用'), findsOneWidget);

    products.pendingOrder(131, 34);
    await t.pumpWidget(app('/me/product-orders/131'));
    await idle(t);
    await tapIdle(t, find.byKey(const Key('product_order_cancel')));
    await tapIdle(t, find.byKey(const Key('confirm_yes')));
    expect(products.calls, contains('POST /v1/product-orders/131/cancel'));
    expect(find.text('已取消'), findsWidgets);
    expect(find.byKey(const Key('product_order_repay')), findsNothing);

    // A paid voucher (不可退) the client cannot tell apart: the server says no.
    final o = products.pendingOrder(132, 33);
    o['status'] = 'paid';
    o['coupons'] = [
      {'id': 990, 'code': 'VCH1', 'perk': {'title': '100 元代金券', 'value_text': '¥88'}, 'merchant': paoye,
        'source': {'type': 'product', 'product_id': 33, 'order_id': 132, 'name': '100 元代金券'},
        'status': 'unused', 'uses_total': 1, 'uses_left': 1},
    ];
    await t.pumpWidget(app('/me/product-orders/132'));
    await idle(t);
    await tapIdle(t, find.byKey(const Key('product_order_refund')));
    await tapIdle(t, find.byKey(const Key('confirm_yes')));
    expect(find.text('该商品不可退款'), findsOneWidget);
    await settle(t);
  });

  testWidgets('卡券包: 已购 tag, 次卡 剩余次数, 已退款 tab; pass detail without the run rule', (t) async {
    await phone(t, size: const Size(390, 1100));
    products.coupons.insert(0, products.passCoupon());
    products.coupons.add({
      'id': 77, 'code': '8K2D9QXW',
      'perk': {'title': '美式咖啡 5 折', 'description': '', 'value_text': '5 折', 'valid_days': 7, 'rules': '到店出示'},
      'merchant': {'id': 5, 'name': '瑞幸咖啡'}, 'source': {'type': 'supply', 'drop_id': 4, 'name': '补给站 · 瑞幸滨江店'},
      'status': 'unused', 'obtained_at': '2026-11-21T08:10:00', 'expires_at': '2026-11-28T23:59:59',
    });
    await t.pumpWidget(app('/me/coupons'));
    await idle(t);
    expect(find.text('游泳 10 次卡'), findsOneWidget);
    expect(find.text('剩余 3/10 次 · 有效期至 12.22'), findsOneWidget);
    expect(find.byKey(const Key('coupon_bought')), findsNWidgets(3), reason: 'pass + the two coupons of order 120');
    expect(find.text('美式咖啡 5 折'), findsOneWidget);
    await shot(t, 'coupons_products');

    await tapIdle(t, find.text('已退款'));
    expect(products.calls.where((c) => c == 'GET /v1/me/coupons').length, greaterThanOrEqualTo(2));
    expect(find.text('已退款 · 原路退回'), findsNWidgets(2));
    expect(find.text('匹克球 1 小时体验课'), findsOneWidget);
    expect(find.text('游泳 10 次卡'), findsOneWidget, reason: 'the refunded half of order 123');
    await shot(t, 'coupons_refunded');

    await tapIdle(t, find.text('未使用'));
    await tapIdle(t, find.text('游泳 10 次卡'));
    expect(find.text('券详情'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const Key('coupon_uses'))).data, '剩余 3/10 次');
    expect(find.textContaining('核销需要当天有一条运动记录'), findsNothing);
    expect(find.text('购买的券到店出示即可核销，不需要当天有运动记录'), findsOneWidget);
    expect(find.text('来源：购买「游泳 10 次卡」'), findsOneWidget);
    await shot(t, 'coupon_pass');
    await tapIdle(t, find.byKey(const Key('coupon_order')));
    expect(find.text('订单详情'), findsOneWidget);
    await settle(t);
  });

  testWidgets('官方活动: strip on 本地生活 → detail with promotion prices; list with two; merchant page', (t) async {
    await phone(t, size: const Size(390, 1300));
    await t.pumpWidget(app('/local'));
    await idle(t, 4);
    expect(find.byKey(const Key('promotion_strip')), findsOneWidget);
    expect(find.text('官方活动 · 双 12 运动狂欢'), findsOneWidget);
    await shot(t, 'promotion_strip');
    await tapIdle(t, find.byKey(const Key('promotion_strip')));
    expect(products.calls, contains('GET /v1/promotions/3'));
    expect(find.text('活动商品 · 2 个'), findsOneWidget);
    expect(find.text('¥49'), findsOneWidget);
    expect(find.text('¥299'), findsOneWidget);
    expect(find.text('¥399'), findsOneWidget, reason: 'regular price struck');
    expect(find.textContaining('12月1日 00:00 – 12月12日 23:59'), findsOneWidget);
    await shot(t, 'promotion_detail');

    products.promotions.add({
      'id': 4, 'title': '新年开练季', 'subtitle': '健身次卡限时 8 折', 'banner_url': null, 'description': '',
      'starts_at': '2027-01-01T00:00:00+08:00', 'ends_at': '2027-01-15T23:59:59+08:00', 'status': 'scheduled', 'product_qty': 0,
    });
    await t.pumpWidget(app('/promotions'));
    await idle(t);
    expect(find.text('双 12 运动狂欢'), findsOneWidget);
    expect(find.text('新年开练季'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('即将开始'), findsOneWidget);
    await shot(t, 'promotions');
    await tapIdle(t, find.byKey(const Key('promotion_4')));
    expect(find.text('活动商品 · 开始后按活动价购买'), findsOneWidget);
    expect(find.text('活动商品正在上架中，晚点再来看看'), findsOneWidget);

    await t.pumpWidget(app('/merchants/3'));
    await idle(t);
    expect(products.calls, contains('GET /v1/merchants/3/products'));
    expect(find.text('城南全民健身中心'), findsOneWidget);
    expect(find.byKey(const Key('product_34')), findsOneWidget);
    await shot(t, 'merchant_products');
    await settle(t);
  });

  testWidgets('商品详情 on a 390×844 phone: gallery, price and the buy bar fit', (t) async {
    await phone(t);
    products.products[31]!['images'] = ['https://img.test/a.jpg', 'https://img.test/b.jpg'];
    await t.pumpWidget(app('/products/31'));
    await idle(t);
    expect(find.byKey(const Key('product_gallery')), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    expect(find.byKey(const Key('product_buy')), findsOneWidget);
    expect(t.takeException(), isNull);
    await shot(t, 'product_detail_phone');
    await settle(t);
  });

  testWidgets('本地生活 without promotions: no strip', (t) async {
    await phone(t);
    products.promotions = [];
    await t.pumpWidget(app('/local'));
    await idle(t, 4);
    expect(find.byKey(const Key('promotion_strip')), findsNothing);
    expect(find.text('本地生活'), findsOneWidget);
    await settle(t);
  });
}
