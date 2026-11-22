// V2 batch 4「本地生活」— 订场 (venue list, slots, booking, payment,
// my bookings / cancel), 场馆签到 (location + QR + universal link), venue
// detail, 约球订场, 赛事报名费, venue markers on the map.
// With LOOPLAND_SCREENSHOTS=1 they write PNGs to app/screenshots/v2/.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:loopland/api/local_models.dart';
import 'package:loopland/api/models.dart' hide Slot;
import 'package:loopland/core/providers.dart';
import 'package:loopland/core/sdk_config.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/features/community/gathering_routes.dart';
import 'package:loopland/features/local/local_page.dart';
import 'package:loopland/features/local/local_routes.dart';
import 'package:loopland/features/local/qr_scan_page.dart';
import 'package:loopland/features/start/start_page.dart';
import 'package:loopland/map/fallback_map.dart';
import 'package:loopland/map/territory_map.dart';
import 'package:loopland/map/venue_marker.dart';
import 'package:loopland/pay/payment_service.dart';
import 'package:loopland/run/location_source.dart';
import 'package:loopland/run/run_controller.dart';
import 'package:material_ui/material_ui.dart';

import '../api/fixtures.dart';
import '../pay/payment_service_test.dart' show FakeGateways;
import 'fake_backend.dart';
import 'gathering_fake.dart';
import 'local_fake.dart';
import 'screens_test.dart' show fixAt;
import 'test_helpers.dart';

class _Stub extends StatelessWidget {
  const _Stub(this.loc);
  final String loc;
  @override
  Widget build(BuildContext context) => Scaffold(body: Center(child: Text('STUB $loc')));
}

GoRoute _stub(String path) => GoRoute(path: path, builder: (_, s) => _Stub(s.uri.toString()));

late LocalFake local;
late GatheringFake gathering;
late FakeGateways gateways;
String? scanned;

List<Override> overrides({User? user, LocationSource? loc}) => [
      ...fakeBackend(user: user, handlers: [local.handle, gathering.handle]),
      locationSourceProvider.overrideWithValue(loc ?? FakeLocationSource([fixAt(0, 0, 0)])),
      paymentServiceProvider.overrideWith((ref) => PaymentService(ref.watch(apiProvider),
          gateways: gateways, pollInterval: Duration.zero, pollTimeout: Duration.zero, unpaidCheckTimeout: Duration.zero)),
      qrScannerProvider.overrideWithValue((_) async => scanned),
    ];

Widget app(String initial, List<Override> o) {
  final router = GoRouter(initialLocation: initial, routes: [
    GoRoute(path: '/local', builder: (_, s) => LocalPage(tab: s.uri.queryParameters['tab'] ?? 'booking', now: () => local.now)),
    GoRoute(path: '/start', builder: (_, _) => const StartPage()),
    ...localRoutes(),
    ...gatheringRoutes(),
    for (final p in ['/realname', '/me/coupons', '/users/:id', '/league', '/posts/:id', '/crews/:id', '/coach', '/train/:sport'])
      _stub(p),
  ]);
  return RepaintBoundary(
    key: const Key('shot'),
    child: ProviderScope(
      overrides: o,
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

/// The slot cell labelled [hm] (e.g. 21:00).
Finder slot(String hm) => find.descendant(of: find.byType(GridView), matching: find.text(hm));

void main() {
  late SdkConfig saved;

  setUpAll(() async {
    TerritoryMapView.forceFallback = true;
    VenueAvatars.enabled = false;
    await loadFonts();
  });

  setUp(() {
    local = LocalFake();
    gathering = GatheringFake();
    gateways = FakeGateways();
    scanned = null;
    saved = SdkConfig.current;
    // An iPhone in dev: WeChat / Alipay are offered for physical services.
    SdkConfig.current = SdkConfig.fromMap(
        const {'LOOPLAND_ENV': 'dev', 'WECHAT_APP_ID': 'wx123', 'WECHAT_UNIVERSAL_LINK': 'https://loop.test/wechat/'},
        platform: 'ios');
  });

  tearDown(() => SdkConfig.current = saved);

  group('models', () {
    test('venue QR payloads: raw, universal link, encoded, invalid', () {
      expect(parseVenueQr('LPV.8.k3J9x_-Ab')!.venueId, 8);
      expect(parseVenueQr('  LPV.8.k3J9x  ')!.payload, 'LPV.8.k3J9x');
      final link = parseVenueQr('https://loop.test/v/LPV.12.sig-ok');
      expect(link!.venueId, 12);
      expect(link.payload, 'LPV.12.sig-ok');
      expect(parseVenueQr('https://loop.test/v/LPV.5.a%2Bb%3D')!.payload, 'LPV.5.a+b=');
      for (final bad in ['', 'LPC.77.1.x', 'LPV.x.sig', 'LPV.8.', 'https://loop.test/u/LPV.8.x', 'https://loop.test/v/', 'hello']) {
        expect(parseVenueQr(bad), isNull, reason: bad);
      }
    });

    BookingSlot s(int h, {bool ok = true}) =>
        BookingSlot(start: DateTime.utc(2026, 11, 21, h), end: DateTime.utc(2026, 11, 21, h + 1), priceAmt: 6000, available: ok);

    test('consecutive slot selection: extend, shrink, restart, gaps, max', () {
      final all = [s(10), s(11), s(12, ok: false), s(13), s(14), s(15), s(16), s(17)];
      var sel = SlotSelection.toggle(const SlotSelection([]), all, all[0]);
      sel = SlotSelection.toggle(sel, all, all[1]);
      expect(sel.count, 2);
      expect(SlotSelection.toggle(sel, all, all[2]).count, 2, reason: 'full slot ignored');
      expect(SlotSelection.toggle(sel, all, all[3]).slots.single.start.hour, 13, reason: 'gap → new run');
      expect(SlotSelection.toggle(sel, all, all[0]).slots.single.start.hour, 11, reason: 'shrink from the start');
      var run = const SlotSelection([]);
      for (final x in all.sublist(3)) {
        run = SlotSelection.toggle(run, all, x);
      }
      expect(run.count, 1, reason: 'the 5th slot starts over (max 4)');
      run = const SlotSelection([]);
      for (final x in all.sublist(3, 7)) {
        run = SlotSelection.toggle(run, all, x);
      }
      expect(run.count, 4);
      expect(run.amount, 24000);
      expect(SlotSelection.toggle(run, all, all[5]).slots.single.start.hour, 15, reason: 'middle tap restarts');
    });

    test('venue, booking, check-in and map venue JSON', () {
      final v = Venue.fromJson(local.venues.first);
      expect(v.discountText, '八折');
      expect(v.owner!.user.nickname, '夜跑兔');
      expect(v.weekRank.length, 2);
      expect(Booking.fromJson(local.bookings.first).orderNo, 'LPBK31');
      final o = MapObjects.fromJson({
        'venues': [
          {'id': 8, 'name': '城南', 'center': {'lat': 31.2, 'lng': 121.4}, 'sports': ['pickleball'], 'owner_avatar_url': null, 'owner_nickname': '夜跑兔', 'bookable': true}
        ]
      });
      expect(o.venues.single.hasOwner, isTrue);
      expect(o.isEmpty, isFalse);
      final r = CheckinResult.fromJson({'energy': 20, 'points': 10, 'week_points': 40, 'coupon': null, 'venue': null});
      expect(r.coupon, isNull);
      expect(r.weekPoints, 40);
    });

    test('map hit test finds venues', () {
      const v = MapVenue(id: 8, name: '城南', center: origin, ownerNickname: '夜跑兔');
      final view = MapView(origin, 15, const Size(400, 400));
      final hit = hitTestObjects(view, const MapObjects(venues: [v]), const Offset(200, 200));
      expect(hit, isA<VenueHit>());
    });
  });

  testWidgets('订场: sport chips, 推荐 meetup, venues by distance with 馆主, slots, book 2 slots, mock pay', (t) async {
    await phone(t, size: const Size(390, 1500));
    await t.pumpWidget(app('/local', overrides()));
    await idle(t, 4);
    expect(find.text('本地生活'), findsOneWidget);
    expect(find.text('订场 · 品牌联名 · 用能量换福利'), findsOneWidget);
    expect(find.text('联名活动'), findsOneWidget);
    expect(find.text('能量商城'), findsOneWidget);
    // 推荐 (rule-based, not AI): the nearby ball meetup with spots.
    expect(find.text('推荐'), findsOneWidget);
    expect(find.textContaining('匹克球双打'), findsOneWidget);
    expect(find.text('AI'), findsNothing);
    // Pick 匹克球 like the design.
    await tapIdle(t, find.byKey(const Key('sport_pickleball')));
    expect(local.calls.where((c) => c == 'GET /v1/venues').length, greaterThanOrEqualTo(2));
    expect(find.text('城南全民健身中心 · 匹克球'), findsOneWidget);
    expect(find.text('距你 800 m · 室内 · 可租拍'), findsOneWidget);
    expect(find.text('馆主 · 夜跑兔（你的跑团）'), findsOneWidget);
    expect(find.text('馆主 · Kai'), findsOneWidget);
    expect(find.text('馆主 · 暂无馆主 · 先签到先得'), findsOneWidget);
    expect(find.text('¥60'), findsOneWidget);
    expect(find.text('先选一个时段'), findsOneWidget);
    expect(slot('18:00'), findsOneWidget);
    expect(find.text('滨江攀岩馆'), findsNothing, reason: 'check-in only venues are not bookable');
    await shot(t, 'local_booking');

    // 21:00 + 22:00; 19:00 is full and ignored.
    await t.tap(slot('19:00'));
    await t.pump();
    expect(find.text('先选一个时段'), findsOneWidget);
    await t.tap(slot('21:00'));
    await t.pump();
    await t.tap(slot('22:00'));
    await t.pump();
    expect(find.text('确认预订 21:00–23:00 · ¥120'), findsOneWidget);
    await tapIdle(t, find.byKey(const Key('slot_confirm')));
    expect(find.text('确认订单'), findsOneWidget);
    expect(find.text('2 个时段 · 1 片场地'), findsOneWidget);
    expect(find.text('微信支付'), findsOneWidget, reason: 'iOS offers WeChat for physical services');
    expect(find.text('支付宝'), findsOneWidget);
    expect(find.text('Apple 内购'), findsNothing);
    await shot(t, 'local_booking_confirm');
    await t.tap(find.byKey(const Key('channel_mock')));
    await t.pump();
    await tapIdle(t, find.byKey(const Key('booking_pay')), 5);
    final body = local.bodies['POST /v1/bookings']! as Map;
    expect(body['venue_id'], 8);
    expect(body['slots'], 2);
    expect(body['channel'], 'mock');
    expect(body['meetup_id'], isNull);
    expect('${body['start_time']}', endsWith('T21:00:00+08:00'));
    expect(local.calls, contains('POST /v1/dev/orders/LPBK100/pay'));
    expect(find.text('预订成功'), findsOneWidget);
    await shot(t, 'local_booking_paid');
    await tapIdle(t, find.text('查看订单'));
    expect(find.text('订场详情'), findsOneWidget);
    expect(find.text('已支付'), findsWidgets);
    await settle(t);
  });

  testWidgets('订场 with WeChat on iOS; slot taken meanwhile → reload; realname required → 实名', (t) async {
    await phone(t, size: const Size(390, 1500));
    await t.pumpWidget(app('/local', overrides()));
    await idle(t, 4);
    await t.tap(slot('18:00'));
    await t.pump();
    await tapIdle(t, find.byKey(const Key('slot_confirm')));
    await tapIdle(t, find.byKey(const Key('booking_pay')), 5); // default channel: WeChat
    expect(gateways.log, ['sdk']);
    expect(gateways.wechatParams!['prepayid'], 'p');
    expect((local.bodies['POST /v1/bookings']! as Map)['channel'], 'wechat_app');
    expect(find.text('预订成功'), findsOneWidget);
    await tapIdle(t, find.text('完成'));

    // Someone else books 21:00 after the grid loaded.
    final s21 = local.slotsFor(8, _today()).firstWhere((s) => '${s['start_time']}'.contains('T21:00'));
    local.bookings.add({
      'id': 99, 'venue': {'id': 8, 'name': 'x'}, 'status': 'paid', 'pay': {'order_no': 'X'},
      'start_time': s21['start_time'], 'end_time': s21['end_time'],
    });
    await t.tap(slot('21:00'));
    await t.pump();
    await tapIdle(t, find.byKey(const Key('slot_confirm')));
    await tapIdle(t, find.byKey(const Key('booking_pay')), 5);
    expect(find.text('这个时段刚被订走了，换一个吧'), findsOneWidget);
    expect(find.text('先选一个时段'), findsOneWidget, reason: 'selection dropped, grid reloaded');

    local.realname = false;
    await t.tap(slot('22:00'));
    await t.pump();
    await tapIdle(t, find.byKey(const Key('slot_confirm')));
    await tapIdle(t, find.byKey(const Key('booking_pay')), 5);
    expect(find.text('STUB /realname'), findsOneWidget);
    await settle(t);
  });

  testWidgets('订场: minors see a notice and no order is created', (t) async {
    await phone(t, size: const Size(390, 1500));
    final minor = User.fromJson(j(userJson)
      ..['is_adult'] = false
      ..['realname_verified'] = true
      ..['nickname'] = '小鱼');
    await t.pumpWidget(app('/local', overrides(user: minor)));
    await idle(t, 4);
    await t.tap(slot('18:00'));
    await t.pump();
    await tapIdle(t, find.byKey(const Key('slot_confirm')));
    expect(find.textContaining('未成年账号暂不支持订场'), findsOneWidget);
    expect(local.calls, isNot(contains('POST /v1/bookings')));
    await settle(t);
  });

  testWidgets('我的订场: status chips, detail, cancel with refund, too late', (t) async {
    await phone(t, size: const Size(390, 1100));
    // Client thinks it can still cancel 32; the server says too late.
    local.bookings[1]['cancel_deadline'] = DateTime.now().add(const Duration(hours: 1)).toUtc().toIso8601String();
    await t.pumpWidget(app('/me/bookings', overrides()));
    await idle(t);
    expect(find.text('我的订单'), findsOneWidget);
    expect(find.text('订场'), findsOneWidget); // 订场 | 商品
    expect(find.text('城南全民健身中心 · 匹克球'), findsOneWidget);
    expect(find.text('已支付'), findsNWidgets(2));
    expect(find.text('已完成'), findsWidgets);
    expect(find.text('¥96'), findsOneWidget);
    await shot(t, 'local_my_bookings');

    await tapIdle(t, find.byKey(const Key('booking_31')));
    expect(find.text('订场详情'), findsOneWidget);
    expect(find.text('馆主折扣'), findsOneWidget);
    expect(find.text('-¥24'), findsOneWidget);
    await shot(t, 'local_booking_detail');
    await tapIdle(t, find.byKey(const Key('booking_cancel')));
    expect(find.textContaining('原路退回'), findsOneWidget);
    await tapIdle(t, find.text('取消订场'));
    expect(local.calls, contains('POST /v1/bookings/31/cancel'));
    expect(find.text('退款中'), findsWidgets);
    expect(find.byKey(const Key('booking_cancel')), findsNothing);

    await t.pumpWidget(app('/me/bookings/32', overrides()));
    await idle(t);
    await tapIdle(t, find.byKey(const Key('booking_cancel')));
    await tapIdle(t, find.text('取消订场'));
    expect(find.text('开始前 2 小时内不能自助取消，如需退款请联系客服'), findsOneWidget);
    await settle(t);
  });

  testWidgets('我的订场: 继续支付 for a pending booking (mock channel)', (t) async {
    await phone(t, size: const Size(390, 1100));
    final start = DateTime.now().add(const Duration(days: 1));
    local.bookings.add(local.pendingBooking(40, start));
    await t.pumpWidget(app('/me/bookings/40', overrides()));
    await idle(t);
    expect(find.byKey(const Key('booking_repay')), findsOneWidget);
    await tapIdle(t, find.byKey(const Key('booking_repay')));
    expect(local.calls, contains('POST /v1/bookings/40/pay'));
    await settle(t);
  });

  testWidgets('开始页 场馆球类: nearby venues, check in by location → energy, points, coupon; too far', (t) async {
    await phone(t, size: const Size(390, 1600));
    await t.pumpWidget(app('/start', overrides()));
    await idle(t);
    await tapIdle(t, find.text('场馆球类'));
    expect(find.text('场馆签到'), findsOneWidget);
    expect(find.text('滨江攀岩馆'), findsOneWidget);
    expect(find.text('今日已签'), findsOneWidget);
    expect(find.text('馆主 · 夜跑兔（你的跑团）'), findsOneWidget);
    await shot(t, 'venue_start_tab');

    await tapIdle(t, find.byKey(const Key('checkin_8')), 4);
    final body = local.bodies['POST /v1/venues/8/checkin']! as Map;
    expect(body.containsKey('lat') && body.containsKey('lng'), isTrue);
    expect(body.containsKey('qr'), isFalse);
    expect(find.text('签到成功'), findsOneWidget);
    expect(find.text('+20'), findsOneWidget);
    expect(find.text('+10'), findsOneWidget);
    expect(find.text('40'), findsOneWidget);
    expect(find.textContaining('本周第一 Kai 70 分'), findsOneWidget);
    expect(find.byKey(const Key('checkin_coupon')), findsOneWidget);
    expect(find.text('运动饮料兑换券'), findsOneWidget);
    await shot(t, 'venue_checkin');
    await tapIdle(t, find.byKey(const Key('checkin_coupon')));
    expect(find.text('STUB /me/coupons'), findsOneWidget);

    // Too far from 东港 → the server's reason.
    await t.pumpWidget(app('/start', overrides()));
    await idle(t);
    await tapIdle(t, find.text('场馆球类'));
    await tapIdle(t, find.byKey(const Key('checkin_9')), 4);
    expect(find.textContaining('需要在 150 米内'), findsOneWidget);
    await settle(t);
  });

  testWidgets('扫码签到: link form from the scanner, invalid code, universal link route', (t) async {
    await phone(t, size: const Size(390, 1400));
    await t.pumpWidget(app('/start', overrides()));
    await idle(t);
    await tapIdle(t, find.text('场馆球类'));
    scanned = 'hello';
    await tapIdle(t, find.byKey(const Key('start_scan')));
    expect(find.text('这不是圈圈场馆二维码'), findsOneWidget);
    scanned = 'https://loop.test/v/LPV.9.sig-ok';
    await tapIdle(t, find.byKey(const Key('start_scan')), 4);
    expect((local.bodies['POST /v1/venues/9/checkin']! as Map)['qr'], 'LPV.9.sig-ok');
    expect(find.text('签到成功'), findsOneWidget);
    expect(find.byKey(const Key('checkin_coupon')), findsNothing);
    await tapIdle(t, find.text('好的'));

    // System camera → universal link → /v/<content>.
    await t.pumpWidget(app('/v/LPV.10.sig-ok', overrides()));
    await idle(t, 4);
    expect(local.calls, contains('POST /v1/venues/10/checkin'));
    expect(find.text('签到成功'), findsOneWidget);
    await tapIdle(t, find.text('好的'));
    expect(find.text('学府路体育馆 · 匹克球'), findsWidgets, reason: 'then the venue page');
    await settle(t);
  });

  testWidgets('场馆详情: 馆主 (your crew), week rank, check-in, booking sheet', (t) async {
    await phone(t, size: const Size(390, 1300));
    await t.pumpWidget(app('/venues/8', overrides()));
    await idle(t);
    expect(find.byKey(const Key('venue_owner')), findsOneWidget);
    expect(find.text('夜跑兔'), findsOneWidget);
    expect(find.text('你的跑团'), findsOneWidget);
    expect(find.text('我的本周积分 30'), findsOneWidget);
    expect(find.text('本周积分榜 · 周一 00:00 结算'), findsOneWidget);
    expect(find.text('70 分'), findsOneWidget);
    expect(find.text('阿杰（我）'), findsOneWidget);
    expect(find.text('馆主订场八折'), findsOneWidget);
    await shot(t, 'venue_detail');
    await tapIdle(t, find.byKey(const Key('venue_book')));
    expect(find.text('先选一个时段'), findsOneWidget);
    await t.tapAt(const Offset(20, 20));
    await idle(t);
    await tapIdle(t, find.byKey(const Key('venue_checkin')), 4);
    expect(find.text('签到成功'), findsOneWidget);
    await settle(t);
  });

  testWidgets('约球订场: create a ball meetup with a venue + slots, booking carries meetup_id; detail shows it', (t) async {
    await phone(t, size: const Size(390, 1500));
    await t.pumpWidget(app('/meetups/new', overrides()));
    await idle(t);
    expect(find.byKey(const Key('meetup_book_toggle')), findsNothing, reason: '约跑 has no court');
    await tapIdle(t, find.text('约球'));
    await tapIdle(t, find.descendant(of: find.byKey(const Key('meetup_book_toggle')), matching: find.byType(Switch)));
    await tapIdle(t, find.byKey(const Key('meetup_pick_venue')), 4);
    expect(find.text('选择场馆和时段'), findsWidgets);
    await tapIdle(t, find.byKey(const Key('pick_venue_8')));
    await tapIdle(t, find.byKey(const Key('day_1')));
    await t.tap(slot('21:00'));
    await t.pump();
    expect(find.textContaining('选定 21:00–22:00'), findsOneWidget);
    await tapIdle(t, find.byKey(const Key('slot_confirm')));
    expect(find.textContaining('城南全民健身中心 · 匹克球\n'), findsOneWidget);
    await t.enterText(find.byKey(const Key('meetup_title')), '周末匹克球双打');
    await shot(t, 'meetup_booking_create');
    await tapIdle(t, find.text('发起'));
    final m = gathering.bodies['POST /v1/meetups']! as Map;
    expect((m['place'] as Map)['name'], '城南全民健身中心 · 匹克球');
    expect(m['type'], 'ball');
    await t.tap(find.byKey(const Key('channel_mock')));
    await t.pump();
    await tapIdle(t, find.byKey(const Key('booking_pay')), 5);
    final b = local.bodies['POST /v1/bookings']! as Map;
    expect(b['meetup_id'], 50);
    expect(b['slots'], 1);
    expect(local.bookings.first['status'], 'paid');

    await t.pumpWidget(app('/meetups/50', overrides()));
    await idle(t, 4);
    expect(find.byKey(const Key('meetup_booking')), findsOneWidget);
    expect(find.text('已订场 · 城南全民健身中心 · 匹克球'), findsOneWidget);
    await shot(t, 'meetup_booking_detail');

    // Other people see the server's `booking` field.
    gathering.meetups.firstWhere((x) => x['id'] == 9)['booking'] = {
      'venue': {'id': 9, 'name': '东港运动公园 · 匹克球'},
      'start_time': '2026-11-22T10:00:00+08:00',
      'end_time': '2026-11-22T12:00:00+08:00',
      'status': 'paid',
    };
    await t.pumpWidget(app('/meetups/9', overrides()));
    await idle(t, 4);
    expect(find.text('已订场 · 东港运动公园 · 匹克球'), findsOneWidget);
    expect(find.textContaining('10:00–12:00'), findsOneWidget);
    await settle(t);
  });

  testWidgets('赛事报名费: fee, pay (mock), signed; cancel → refund note; pending_pay state', (t) async {
    await phone(t, size: const Size(390, 1300));
    await t.pumpWidget(app('/races/7', overrides()));
    await idle(t);
    expect(find.text('报名费'), findsOneWidget);
    expect(find.text('¥39'), findsOneWidget);
    expect(find.text('报名 ¥39'), findsOneWidget);
    await tapIdle(t, find.byKey(const Key('race_signup')));
    expect(find.text('报名缴费'), findsOneWidget);
    expect(find.textContaining('报名费原路退回'), findsOneWidget);
    await shot(t, 'race_fee');
    await t.tap(find.byKey(const Key('channel_mock')));
    await t.pump();
    await tapIdle(t, find.byKey(const Key('race_pay')), 5);
    expect(local.bodies['POST /v1/races/7/signup'], {'channel': 'mock'});
    expect(local.calls, contains('POST /v1/dev/orders/LPRACE7/pay'));
    expect(find.text('报名成功，已支付 ¥39'), findsOneWidget);
    expect(find.text('取消报名并退款'), findsOneWidget);
    await tapIdle(t, find.byKey(const Key('race_cancel')));
    expect(find.text('报名费 ¥39 将原路退回，一般 1–3 个工作日到账。'), findsOneWidget);
    await tapIdle(t, find.text('取消并退款'));
    expect(local.calls, contains('DELETE /v1/races/7/signup'));
    expect(find.text('报名 ¥39'), findsOneWidget);

    // WeChat without an order number in the response: SDK, then poll the race.
    local.raceOrderInResponse = false;
    gateways = FakeGateways(wechatCode: -2);
    await t.pumpWidget(app('/races/7', overrides()));
    await idle(t);
    await tapIdle(t, find.byKey(const Key('race_signup')));
    await tapIdle(t, find.byKey(const Key('race_pay')), 5);
    expect(gateways.log, ['sdk']);
    expect(find.text('支付已取消。订单保留 15 分钟，超时自动取消'), findsOneWidget);
    expect(find.textContaining('我的成绩 · 待支付'), findsOneWidget);
    expect(find.text('继续支付 ¥39'), findsOneWidget);
    expect(find.byKey(const Key('race_cancel')), findsOneWidget);
    await shot(t, 'race_fee_pending');
    await settle(t);
  });
}

String _today() {
  final s = local.now.toUtc().add(const Duration(hours: 8));
  return '${s.year}-${s.month.toString().padLeft(2, '0')}-${s.day.toString().padLeft(2, '0')}';
}
