// V2 batch 4「本地生活」perks screens against the stateful PerksFake: 联名活动,
// 能量商城 (buy / equip), 卡券包 + rotating QR (fake clock), 补给站 claim,
// settlement coupons, merchant chests, avatar frames, territory skins and
// the map marker. With LOOPLAND_SCREENSHOTS=1 they write PNGs to
// app/screenshots/v2/.
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:loopland/api/community_common.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/api/perks_models.dart';
import 'package:loopland/claim/geo.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/features/ai/ai_providers.dart';
import 'package:loopland/features/local/campaigns_tab.dart';
import 'package:loopland/features/local/coupons_pages.dart';
import 'package:loopland/features/local/local_page.dart';
import 'package:loopland/features/local/perks_routes.dart';
import 'package:loopland/features/local/supply_sheet.dart';
import 'package:loopland/features/map/map_page.dart';
import 'package:loopland/features/play/chest_sheet.dart';
import 'package:loopland/features/run/result_page.dart';
import 'package:loopland/features/social/social_widgets.dart';
import 'package:loopland/map/fallback_map.dart';
import 'package:loopland/map/territory_map.dart';
import 'package:loopland/run/location_source.dart';
import 'package:loopland/run/run_controller.dart' show locationSourceProvider;
import 'package:loopland/widgets/cosmetics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../api/fixtures.dart';
import 'fake_backend.dart';
import 'perks_fake.dart';
import 'screens_test.dart' show fixAt;
import 'test_helpers.dart';

/// [home] at `/` inside a GoRouter with the perks routes and a `/map` stub.
Widget routed(Widget home, {List<Override> overrides = const []}) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, _) => home),
    GoRoute(path: '/map', builder: (_, _) => const Scaffold(body: Center(child: Text('MAP_STUB')))),
    ...perksRoutes(),
  ]);
  return ProviderScope(
    overrides: overrides,
    retry: (_, _) => null,
    child: MaterialApp.router(theme: buildTheme(), routerConfig: router, debugShowCheckedModeBanner: false),
  );
}

User userWith({Map<String, dynamic>? equipped}) {
  final m = j(userJson)
    ..['nickname'] = '阿杰'
    ..['energy'] = 1280
    ..['equipped'] = equipped;
  return User.fromJson(m);
}

void main() {
  setUpAll(() async {
    TerritoryMapView.forceFallback = true;
    await loadFonts();
  });

  test('perks models parse the contract examples', () {
    final b = UserBrief.fromJson({'id': 1, 'nickname': 'a', 'avatar_frame': 'frame_gold'});
    expect(b.avatarFrame, 'frame_gold');
    expect(b.toJson()['avatar_frame'], 'frame_gold');
    expect(UserBrief.fromJson({'id': 1, 'nickname': 'a'}).avatarFrame, isNull);

    final u = userWith(equipped: {'map_marker': 'marker_bolt', 'avatar_frame': {'key': 'frame_neon'}, 'territory_skin': null});
    expect(u.equipped.mapMarker, 'marker_bolt');
    expect(u.equipped.avatarFrame, 'frame_neon');
    expect(u.equipped.territorySkin, isNull);
    expect(User.fromJson(j(userJson)).equipped.mapMarker, isNull);

    final t = TerritorySummary.fromJson({
      ...territory(1, 'x', 'enemy', 0, 0, 100, 1),
      'skin': {'key': 'skin_neon', 'fill': '#D9F26B', 'stroke': '#A0D911', 'pattern': 'grid'},
    });
    expect(t.skin!.pattern, 'grid');
    expect(TerritoryColors.of(t.skin, LL.orange).fill, const Color(0xFFD9F26B));
    expect(TerritoryColors.of(t.skin, LL.orange).stroke, const Color(0xFFA0D911));
    expect(TerritoryColors.of(null, LL.orange).fill, LL.orange);

    final s = Settlement.fromJson({'status': 'settled', 'coupons': [couponJson(77)]});
    expect(s.coupons.single.perk.title, '美式咖啡 5 折');
    expect(s.coupons.single.source!.type, 'supply');
    final mo = MapObjects.fromJson({'supplies': [supplyJson()]});
    expect(mo.supplies.single.radiusM, 80);
    expect(mo.supplies.single.claimedToday, isFalse);
    final mc = MapChest.fromJson({'id': 1, 'center': at(0, 0), 'merchant': luckin, 'perk_title': '拿铁立减 5 元'});
    expect(mc.isMerchant, isTrue);
    expect(mc.perk!.title, '拿铁立减 5 元');
    final chest = ChestOpenResult.fromJson({'energy': 0, 'coupon': couponJson(78)});
    expect(chest.coupon!.code, '8K2D9QXW');
    final camp = BrandCampaign.fromJson(PerksFake().campaign());
    expect(camp.perks.map((p) => p.title), ['美式咖啡 5 折', '拿铁立减 5 元']);
    expect(camp.dropTypes, ['supply', 'chest']);
    expect(camp.drops[1].soldOutToday, isTrue);
    expect(groupedCode('8K2D9QXW'), '8K2D 9QXW');
    expect(parseHexColor('#A0D911'), const Color(0xFFA0D911));
    expect(parseHexColor('nope'), isNull);
  });

  testWidgets('联名活动 tab: perks, how to get, drops, rules; drop → map focus', (t) async {
    await phone(t, size: const Size(390, 1700));
    final fake = PerksFake();
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: routed(const LocalPage(tab: 'campaigns'), overrides: fakeBackend(handlers: [fake.handle], user: userWith())),
    ));
    await idle(t);
    expect(find.text('跑完来杯咖啡'), findsOneWidget);
    expect(find.text('品牌联名 · 瑞幸咖啡'), findsOneWidget);
    expect(find.textContaining('12 家门店'), findsOneWidget);
    expect(find.textContaining('已发 3,200 张'), findsOneWidget);
    expect(find.text('美式咖啡 5 折'), findsOneWidget);
    expect(find.text('拿铁立减 5 元'), findsOneWidget);
    expect(find.textContaining('跑步轨迹经过补给站 80 米范围自动领取', findRichText: true), findsOneWidget);
    expect(find.textContaining('商户宝箱：', findRichText: true), findsOneWidget);
    expect(find.text('补给站 · 瑞幸滨江店'), findsOneWidget);
    expect(find.textContaining('今日已发完'), findsOneWidget);
    expect(find.textContaining('需要当天有一条运动记录'), findsWidgets);
    expect(find.textContaining('不设付费抽取'), findsOneWidget);
    expect(find.text('2 张可用 · 到店出示二维码核销'), findsOneWidget);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/local_campaigns.png');

    // Tap a drop location → the map is centred there.
    final container = ProviderScope.containerOf(t.element(find.byType(CampaignsTab)), listen: false);
    await t.tap(find.text('补给站 · 瑞幸滨江店'));
    await t.pumpAndSettle();
    expect(find.text('MAP_STUB'), findsOneWidget);
    final focus = container.read(mapFocusProvider);
    expect(focus, isNotNull);
    expect(haversine(focus!.center, LatLng.fromJson(at(60, 0))), lessThan(1));
    await settle(t);
  });

  testWidgets('能量商城 tab: buy with confirm, already_owned, equip / unequip, not_enough_energy', (t) async {
    await phone(t, size: const Size(390, 1800));
    final fake = PerksFake();
    fake.items.add(shopItem('marker_flag', '旗帜标记', 'map_marker', 150, preview: {'fill': '#FF9F5A'}));
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: routed(const LocalPage(tab: 'shop'), overrides: fakeBackend(handlers: [fake.handle], user: userWith())),
    ));
    await idle(t);
    expect(find.text('能量只能运动获得，不能充值、不能转让'), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const Key('shop_energy'))).data, '1,280');
    expect(find.text('霓虹领地皮肤'), findsOneWidget);
    expect(find.text('800 兑换'), findsOneWidget);
    expect(find.text('能量不足 1,500'), findsOneWidget);
    expect(find.text('已装备'), findsOneWidget); // marker_bolt
    expect(find.textContaining('限时 至12.31'), findsOneWidget);
    expect(find.byType(SkinPreview), findsNWidgets(2));
    expect(find.byType(MarkerPreview), findsNWidgets(3));
    expect(find.byType(FramedAvatar), findsNWidgets(2));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/local_shop.png');

    // Type filter.
    await t.tap(find.text('头像框').first);
    await t.pump();
    expect(find.text('霓虹领地皮肤'), findsNothing);
    expect(find.text('金色头像框'), findsOneWidget);
    await t.tap(find.text('全部'));
    await t.pump();

    // already_owned (bought elsewhere): the card flips to 「装备」.
    fake.items.firstWhere((i) => i['key'] == 'frame_gold')['owned'] = true;
    await t.tap(find.byKey(const Key('buy:frame_gold')));
    await t.pumpAndSettle();
    expect(find.text('兑换「金色头像框」'), findsOneWidget);
    expect(find.textContaining('剩余 780'), findsOneWidget);
    await t.tap(find.text('确认兑换'));
    await idle(t);
    expect(find.textContaining('你已经拥有「金色头像框」'), findsOneWidget);
    expect(find.byKey(const Key('equip:frame_gold')), findsOneWidget);

    // Buy the neon skin: energy 1280 → 480.
    await t.tap(find.byKey(const Key('buy:skin_neon')));
    await t.pumpAndSettle();
    await t.tap(find.text('确认兑换'));
    await idle(t);
    expect(fake.count('POST', '/v1/shop/items/skin_neon/buy'), 1);
    expect(t.widget<Text>(find.byKey(const Key('shop_energy'))).data, '480');
    expect(find.byKey(const Key('equip:skin_neon')), findsOneWidget);

    // Equip it; unequip the marker.
    await t.tap(find.byKey(const Key('equip:skin_neon')));
    await idle(t);
    expect(find.byKey(const Key('unequip:skin_neon')), findsOneWidget);
    expect(fake.count('POST', '/v1/shop/items/skin_neon/equip'), 1);
    await t.tap(find.byKey(const Key('unequip:marker_bolt')));
    await idle(t);
    expect(find.byKey(const Key('equip:marker_bolt')), findsOneWidget);
    expect(fake.count('DELETE', '/v1/shop/items/marker_bolt/equip'), 1);

    // Too expensive locally: no dialog, no request.
    await t.tap(find.byKey(const Key('buy:skin_aurora')));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('兑换「极光领地皮肤」'), findsNothing); // no confirm dialog
    expect(fake.count('POST', '/v1/shop/items/skin_aurora/buy'), 0);

    // Server says not_enough_energy (spent elsewhere) → reload shows 100.
    fake.energy = 100;
    await t.tap(find.byKey(const Key('buy:marker_flag')));
    await t.pumpAndSettle();
    await t.tap(find.text('确认兑换'));
    await idle(t);
    await t.pump(const Duration(seconds: 1));
    expect(fake.count('POST', '/v1/shop/items/marker_flag/buy'), 1);
    expect(find.byKey(const Key('buy:marker_flag')), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const Key('shop_energy'))).data, '100');
    await settle(t);
  });

  testWidgets('卡券包: tabs, detail with code / rules / validity', (t) async {
    await phone(t);
    final fake = PerksFake();
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: routed(const CouponsPage(), overrides: fakeBackend(handlers: [fake.handle])),
    ));
    await idle(t);
    expect(find.text('美式咖啡 5 折'), findsOneWidget);
    expect(find.text('运动饮料买一送一'), findsOneWidget);
    expect(find.text('有效期至 11.28'), findsNWidgets(2));
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/coupons.png');

    await t.tap(find.text('已使用'));
    await idle(t);
    expect(find.textContaining('已于 11.22 14:30 使用 · 滨江店'), findsOneWidget);
    await t.tap(find.text('已过期'));
    await idle(t);
    expect(find.text('拿铁立减 5 元'), findsOneWidget);
    expect(find.textContaining('过期'), findsWidgets);

    await t.tap(find.text('未使用'));
    await idle(t);
    await t.tap(find.text('美式咖啡 5 折'));
    await t.pumpAndSettle();
    await idle(t);
    expect(find.text('券详情'), findsOneWidget);
    expect(find.text('8K2D 9QXW'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('核销需要当天有一条运动记录'), findsOneWidget);
    expect(find.text('需要当天有一条运动记录'), findsOneWidget); // from the perk rules
    expect(find.textContaining('有效期：11.21 – 11.28（领取后 7 天内有效）'), findsOneWidget);
    expect(find.text('来源：补给站 · 瑞幸滨江店（补给站）'), findsOneWidget);
    await settle(t);
  });

  testWidgets('coupon QR: refreshes every 50 s on a fake clock, and on resume', (t) async {
    await phone(t, size: const Size(390, 1100));
    final fake = PerksFake();
    var now = DateTime(2026, 11, 21, 10);
    final coupon = Coupon.fromJson(couponJson(77));
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: routed(CouponDetailPage(couponId: 77, coupon: coupon, clock: () => now),
          overrides: fakeBackend(handlers: [fake.handle])),
    ));
    await idle(t);
    expect(fake.qrCount, 1);
    expect(find.byKey(const ValueKey('qr:LPC.77.1.sig1')), findsOneWidget);
    expect(find.text('50 秒后自动刷新 · 截图无效'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/coupon_qr.png');

    now = now.add(const Duration(seconds: 30));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('20 秒后自动刷新 · 截图无效'), findsOneWidget);
    expect(fake.qrCount, 1);

    now = now.add(const Duration(seconds: 19));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('1 秒后自动刷新 · 截图无效'), findsOneWidget);
    expect(fake.qrCount, 1);

    now = now.add(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    await idle(t);
    expect(fake.qrCount, 2);
    expect(find.byKey(const ValueKey('qr:LPC.77.2.sig2')), findsOneWidget);
    expect(find.text('50 秒后自动刷新 · 截图无效'), findsOneWidget);

    // Back from the background → fresh code right away.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await idle(t);
    expect(fake.qrCount, 3);
    expect(find.byKey(const ValueKey('qr:LPC.77.3.sig3')), findsOneWidget);
    await settle(t);
  });

  testWidgets('补给站: map layer, claim within range, too far, already claimed, sold out', (t) async {
    await phone(t);
    final fake = PerksFake();
    final loc = FakeLocationSource([fixAt(60, 0, 0)]);
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: routed(const MapPage(),
          overrides: [...fakeBackend(handlers: [fake.handle]), locationSourceProvider.overrideWithValue(loc)]),
    ));
    await t.pump();
    for (var i = 0; i < 3; i++) {
      await idle(t, 1);
      await t.pump(const Duration(milliseconds: 400));
    }
    await idle(t);
    final map = t.widget<FallbackTerritoryMap>(find.byType(FallbackTerritoryMap));
    expect(map.layers.objects.supplies.single.perkTitle, '美式咖啡 5 折');

    final view = MapView(Projection(origin).inverse(const Point(60, 0)), 16, const Size(390, 844));
    final supply = map.layers.objects.supplies.single;
    expect(hitTestObjects(view, map.layers.objects, view.toScreen(supply.center)), isA<SupplyHit>());
    await t.tapAt(view.toScreen(supply.center) + t.getTopLeft(find.byType(FallbackTerritoryMap)));
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(find.text('补给站 · 瑞幸滨江店'), findsOneWidget);
    expect(find.textContaining('你已经在范围内'), findsOneWidget);
    await t.tap(find.text('领取'));
    await idle(t);
    expect(fake.count('POST', '/v1/drops/4/claim'), 1);
    expect(find.text('领到「美式咖啡 5 折」！'), findsOneWidget);
    expect(find.text('去卡券包看看'), findsOneWidget);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/supply.png');
    await t.tap(find.text('好的'));
    await t.pumpAndSettle();
    expect(t.widget<FallbackTerritoryMap>(find.byType(FallbackTerritoryMap)).layers.objects.supplies.single.claimedToday, isTrue);
    await settle(t);

    // Too far: no request, a distance hint.
    Future<void> sheet(PerksFake f, LocationSource l, {bool claimed = false}) async {
      await t.pumpWidget(routed(Scaffold(body: SupplySheet(supply: MapSupply.fromJson(supplyJson(claimed: claimed)))),
          overrides: [...fakeBackend(handlers: [f.handle]), locationSourceProvider.overrideWithValue(l)]));
      await t.pump();
    }

    final far = PerksFake();
    await sheet(far, FakeLocationSource([fixAt(400, 0, 0)]));
    await t.tap(find.text('领取'));
    await idle(t);
    expect(find.textContaining('离补给站还有 260 m'), findsOneWidget);
    expect(far.count('POST', '/v1/drops/4/claim'), 0);

    final again = PerksFake()..claimed.add(4);
    await sheet(again, FakeLocationSource([fixAt(60, 0, 0)]));
    await t.tap(find.text('领取'));
    await idle(t);
    expect(find.text('今天已经领过这里的券了，明天再来'), findsOneWidget);
    expect(find.text('查看卡券包'), findsOneWidget);

    final gone = PerksFake()..soldOut.add(4);
    await sheet(gone, FakeLocationSource([fixAt(60, 0, 0)]));
    await t.tap(find.text('领取'));
    await idle(t);
    expect(find.text('今天的券已经发完了，明天再来'), findsOneWidget);

    await sheet(PerksFake(), FakeLocationSource([fixAt(60, 0, 0)]), claimed: true);
    expect(find.textContaining('今天已经领过了'), findsOneWidget);
    expect(find.text('领取'), findsNothing);
    await settle(t);
  });

  testWidgets('settlement page: coupons won during the run → wallet', (t) async {
    await phone(t, size: const Size(390, 2400));
    final fake = PerksFake();
    final m = j(activityResultJson);
    (m['settlement'] as Map)['coupons'] = [
      couponJson(91, code: 'NEWC0DE4'),
      couponJson(92, perk: perkJson('运动饮料买一送一', '买一送一'), merchant: decathlon, source: 'chest', sourceName: '迪卡侬宝箱'),
    ];
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: routed(ResultPage(args: ResultArgs(result: ActivityResult.fromJson(m))), overrides: fakeBackend(handlers: [fake.handle])),
    ));
    await idle(t);
    expect(find.text('联名福利'), findsOneWidget);
    expect(find.text('美式咖啡 5 折'), findsOneWidget);
    expect(find.text('运动饮料买一送一'), findsOneWidget);
    expect(find.textContaining('得到 2 张券，已放进卡券包'), findsOneWidget);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/settlement_coupons.png');

    await t.ensureVisible(find.text('运动饮料买一送一'));
    await t.tap(find.text('运动饮料买一送一'));
    await t.pumpAndSettle();
    await idle(t);
    expect(find.text('券详情'), findsOneWidget);
    expect(find.text('来源：迪卡侬宝箱（商户宝箱）'), findsOneWidget);
    await settle(t);
  });

  testWidgets('merchant chest: shows the perk, opens a coupon', (t) async {
    await phone(t);
    final chest = MapChest.fromJson({
      'id': 12,
      'center': at(-100, -160),
      'radius_m': 50,
      'expires_at': '2099-11-22T06:00:00+08:00',
      'merchant': decathlon,
      'perk': perkJson('运动饮料买一送一', '买一送一'),
    });
    expect(chest.isMerchant, isTrue);
    await t.pumpWidget(routed(Scaffold(body: ChestSheet(chest: chest)), overrides: [
      ...fakeBackend(extra: {
        '/v1/chests/12/open': {'energy': 0, 'bonus': false, 'coupon': couponJson(93, perk: perkJson('运动饮料买一送一', '买一送一'), merchant: decathlon)},
      }),
      locationSourceProvider.overrideWithValue(FakeLocationSource([fixAt(-100, -160, 0)])),
    ]));
    await t.pump();
    expect(find.text('迪卡侬宝箱'), findsOneWidget);
    expect(find.textContaining('宝箱里是「运动饮料买一送一」券'), findsOneWidget);
    await t.tap(find.text('打开宝箱'));
    await idle(t);
    expect(find.text('开出「运动饮料买一送一」'), findsOneWidget);
    expect(find.textContaining('已放进卡券包'), findsOneWidget);
    await settle(t);
  });

  testWidgets('avatar frames: known keys, unknown → generic, none → plain', (t) async {
    await phone(t, size: const Size(390, 300));
    UserBrief u(String? frame, int id) => UserBrief(id: id, nickname: '阿杰', avatarFrame: frame);
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(Scaffold(
        body: Center(
          child: Wrap(spacing: 12, runSpacing: 12, children: [
            for (final (i, k) in const ['frame_gold', 'frame_runner', 'frame_night', 'frame_neon', 'frame_aurora', 'frame_flame', 'frame_ice', 'frame_future', null].indexed)
              UserAvatar(user: u(k, i), size: 64),
          ]),
        ),
      )),
    ));
    await t.pump();
    final painters = t
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((c) => c.foregroundPainter)
        .whereType<AvatarFramePainter>()
        .map((p) => p.frameKey)
        .toList();
    expect(painters, ['frame_gold', 'frame_runner', 'frame_night', 'frame_neon', 'frame_aurora', 'frame_flame', 'frame_ice', 'frame_future']);
    expect(frameStyle('frame_runner'), isNot(same(genericFrame)));
    expect(frameStyle('frame_future'), same(genericFrame));
    expect(frameStyle('frame_gold').kind, FrameKind.ring);
    // Framed avatars keep their footprint.
    expect(t.getSize(find.byType(FramedAvatar).first), const Size(64, 64));
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/avatar_frames.png');
    await settle(t);
  });

  testWidgets('territory skin and map marker are rendered', (t) async {
    // Pixel check on the painter: skin fill replaces the relation colour.
    Future<Color> centrePixel(Map<String, dynamic>? skin, {String? marker, bool me = false}) async {
      final terr = TerritorySummary.fromJson({...territory(1, 'x', 'enemy', 0, 0, 150, 1), 'skin': skin});
      const size = Size(200, 200);
      final painter = TerritoryPainter(
        view: MapView(origin, 16, size),
        layers: MapLayers(territories: [terr], myLocation: me ? origin : null, myMarker: marker),
        refLat: origin.lat,
      );
      final rec = ui.PictureRecorder();
      painter.paint(Canvas(rec), size);
      final img = await rec.endRecording().toImage(200, 200);
      final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      // Sample just off-centre (avoid the label pill at the centre).
      const x = 100, y = 140;
      final o = (y * 200 + x) * 4;
      return Color.fromARGB(255, data.getUint8(o), data.getUint8(o + 1), data.getUint8(o + 2));
    }

    await t.runAsync(() async {
      final plain = await centrePixel(null);
      final red = await centrePixel({'key': 'skin_red', 'fill': '#FF0000', 'stroke': '#FF0000', 'pattern': null});
      // Default enemy = orange (R high, G mid); the red skin has much less green.
      expect((red.r * 255).round(), greaterThan(90));
      expect((red.g * 255).round(), lessThan((plain.g * 255).round() - 20));

      // Map marker: the bolt marker is lime around the centre, the default dot lavender.
      Future<Color> markerPixel(String? key) async {
        final rec = ui.PictureRecorder();
        paintMapMarker(Canvas(rec), const Offset(50, 50), key);
        final img = await rec.endRecording().toImage(100, 100);
        final d = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final o = (50 * 100 + 61) * 4; // inside the marker disc, right of the glyph
        return Color.fromARGB(255, d.getUint8(o), d.getUint8(o + 1), d.getUint8(o + 2));
      }

      expect(await markerPixel('marker_bolt'), LL.lime);
      expect(await markerPixel(null), isNot(LL.lime));
    });

    // The map page passes the equipped marker of /v1/me to the map.
    await phone(t);
    final fake = PerksFake();
    final skinned = [
      for (final m in sampleTerritories)
        m['id'] == 3 ? {...m, 'skin': {'key': 'skin_aurora', 'fill': '#B4A3F5', 'stroke': '#6FD3E8', 'pattern': 'waves'}} : m,
      {...territory(7, '霓虹地块', 'enemy', 60, 240, 120, 30), 'skin': {'key': 'skin_neon', 'fill': '#D9F26B', 'stroke': '#A0D911', 'pattern': 'grid'}},
    ];
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: routed(const MapPage(), overrides: [
        ...fakeBackend(
            handlers: [fake.handle],
            user: userWith(equipped: {'map_marker': 'marker_bolt', 'avatar_frame': 'frame_gold'}),
            extra: {'/v1/territories': {'items': skinned}}),
        locationSourceProvider.overrideWithValue(FakeLocationSource([fixAt(60, 0, 0)])),
      ]),
    ));
    await t.pump();
    for (var i = 0; i < 3; i++) {
      await idle(t, 1);
      await t.pump(const Duration(milliseconds: 400));
    }
    await idle(t);
    final map = t.widget<FallbackTerritoryMap>(find.byType(FallbackTerritoryMap));
    expect(map.layers.myMarker, 'marker_bolt');
    expect(map.layers.territories.where((e) => e.skin != null).map((e) => e.skin!.key), ['skin_aurora', 'skin_neon']);
    expect(find.byType(FramedAvatar), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/map_skins.png');
    await settle(t);
  });
}
