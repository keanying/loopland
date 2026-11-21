// V2「玩法深化」screens against canned data. With LOOPLAND_SCREENSHOTS=1 they
// write PNGs to app/screenshots/v2/.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/claim/geo.dart';
import 'package:loopland/core/providers.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/features/city/city_page.dart';
import 'package:loopland/features/codex/codex_page.dart';
import 'package:loopland/features/map/map_page.dart';
import 'package:loopland/features/play/boss_page.dart';
import 'package:loopland/features/play/chest_sheet.dart';
import 'package:loopland/features/play/games_page.dart';
import 'package:loopland/features/play/relay_card.dart';
import 'package:loopland/features/play/routes_pages.dart';
import 'package:loopland/features/play/season_page.dart';
import 'package:loopland/features/run/result_page.dart';
import 'package:loopland/features/run/run_page.dart';
import 'package:loopland/map/fallback_map.dart';
import 'package:loopland/map/territory_map.dart';
import 'package:loopland/realtime/realtime_banner.dart';
import 'package:loopland/realtime/realtime_client.dart';
import 'package:loopland/realtime/realtime_providers.dart';
import 'package:loopland/run/location_source.dart';
import 'package:loopland/run/run_controller.dart';
import 'package:material_ui/material_ui.dart';

import '../api/fixtures.dart';
import '../api/fixtures_v2.dart';
import '../realtime/realtime_client_test.dart' show FakeChannel;
import 'fake_backend.dart';
import 'screens_test.dart' show fixAt;
import 'test_helpers.dart';

/// A started realtime client whose socket the test controls.
(RealtimeClient, List<FakeChannel>) fakeRealtime() {
  final chans = <FakeChannel>[];
  final c = RealtimeClient(
    baseUrl: 'http://x',
    token: () async => 'A',
    backoff: const [Duration(milliseconds: 10)],
    silenceTimeout: const Duration(hours: 1),
    connect: (uri) => (chans..add(FakeChannel(uri))).last,
  );
  return (c, chans);
}

/// Inside the boss range (boss centre ≈ 200 m east / 100 m north of origin).
final _nearBoss = FakeLocationSource([fixAt(150, 80, 0)]);

void main() {
  setUpAll(() async {
    TerritoryMapView.forceFallback = true;
    await loadFonts();
  });

  testWidgets('boss page: art, HP, rules, actions, leaderboard, drops; live HP; strike', (t) async {
    await phone(t, size: const Size(390, 1900));
    final (rt, chans) = fakeRealtime();
    addTearDown(rt.dispose);
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(const BossPage(bossId: 3), overrides: [
        ...fakeBackend(),
        realtimeClientProvider.overrideWithValue(rt),
        locationSourceProvider.overrideWithValue(_nearBoss),
      ]),
    ));
    await t.runAsync(() async => rt.start());
    await idle(t);
    expect(find.text('怪兽来袭'), findsOneWidget);
    expect(find.text('沙发怪'), findsOneWidget);
    expect(find.text('首领 Lv.12'), findsOneWidget);
    expect(find.text('3,800 / 10,000'), findsOneWidget);
    expect(find.text('跑步 / 骑行'), findsOneWidget);
    expect(find.text('每 1 km = 100 伤害'), findsOneWidget);
    expect(find.text('跳绳'), findsOneWidget);
    expect(find.text('每 100 个 = 30 伤害'), findsOneWidget);
    expect(find.text('投入能量'), findsOneWidget);
    expect(find.text('每 100 能量 = 40 伤害'), findsOneWidget);
    expect(find.text('去运动出战'), findsOneWidget);
    expect(find.text('发起合击'), findsOneWidget);
    expect(find.text('沙发怪伤害榜'), findsOneWidget);
    expect(find.text('已有 23 人出战'), findsOneWidget);
    expect(find.text('击退奖励 · 掉落概率公示'), findsOneWidget);
    expect(find.text('旗手卡'), findsOneWidget);
    expect(find.text('35%'), findsOneWidget);
    expect(find.textContaining('不支持付费抽取'), findsOneWidget);
    expect(find.text('实时'), findsOneWidget);
    // Subscribed to the boss topic.
    expect(chans.single.sent, [
      {'sub': 'boss:3'}
    ]);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/boss.png');

    // Live HP over the WebSocket.
    chans.single.push({
      'type': 'boss',
      'boss': {'id': 3, 'hp': 3000, 'status': 'active'},
      'by': {'id': 7, 'nickname': '小鹿'},
      'damage': 800
    });
    await idle(t, 1);
    expect(find.text('3,000 / 10,000'), findsOneWidget);

    // 发起合击: POST strike with my location → combo, energy, cooldown.
    await t.tap(find.text('发起合击'));
    await idle(t);
    expect(find.textContaining('造成 44 伤害'), findsOneWidget);
    expect(find.textContaining('合击加成 +10%'), findsOneWidget);
    expect(find.textContaining('剩余能量 1,180'), findsOneWidget);
    expect(find.text('3,756 / 10,000'), findsOneWidget);
    expect(find.textContaining('冷却'), findsOneWidget);
    await settle(t);
  });

  testWidgets('boss page: defeated result with my rewards', (t) async {
    await phone(t, size: const Size(390, 1500));
    final m = j(bossJson)
      ..['status'] = 'defeated'
      ..['hp'] = 0
      ..['my_rewards'] = [
        {'item': 'banner', 'kind': 'role', 'name': '旗手卡', 'converted_energy': null},
        {'item': 'knight', 'kind': 'role', 'name': '骑士卡', 'converted_energy': 50},
      ];
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(const BossPage(bossId: 3), overrides: fakeBackend(extra: {'/v1/bosses/3': m})),
    ));
    await idle(t);
    expect(find.text('击退成功！沙发怪被赶走了'), findsOneWidget);
    expect(find.text('旗手卡'), findsWidgets);
    expect(find.text('重复，折算 50 能量'), findsOneWidget);
    expect(find.text('发起合击'), findsNothing);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/boss_defeated.png');

    // Expired without a win.
    m
      ..['status'] = 'expired'
      ..['hp'] = 1200
      ..['my_rewards'] = [];
    await t.pumpWidget(wrap(const BossPage(bossId: 3), overrides: fakeBackend(extra: {'/v1/bosses/3': m})));
    await idle(t);
    expect(find.text('沙发怪溜走了'), findsOneWidget);
    expect(find.textContaining('按比例返还'), findsOneWidget);
    await settle(t);
  });

  testWidgets('season page: tier card, ranks, medals / tasks / ranking tabs', (t) async {
    await phone(t, size: const Size(390, 1300));
    await t.pumpWidget(RepaintBoundary(key: const Key('shot'), child: wrap(const SeasonPage(), overrides: fakeBackend())));
    await idle(t);
    expect(find.text('白银 II'), findsOneWidget);
    expect(find.textContaining('2.36'), findsOneWidget);
    expect(find.text('距 黄金 I 还差 1.24 km²'), findsOneWidget);
    expect(find.textContaining('剩余 42 天'), findsOneWidget);
    expect(find.text('#128'), findsOneWidget);
    expect(find.text('#4'), findsOneWidget);
    expect(find.text('赛事中心'), findsOneWidget);
    expect(find.text('本地生活'), findsOneWidget);
    expect(find.text('能量商城'), findsOneWidget);
    expect(find.text('守护者'), findsOneWidget);
    expect(find.text('进行中 3/5'), findsOneWidget);
    expect(find.text('已解锁'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/season.png');

    await t.tap(find.text('赛季任务'));
    await t.pump();
    expect(find.text('本周运动 3 次'), findsOneWidget);
    expect(find.text('2 / 3 次'), findsOneWidget);
    expect(find.text('+60'), findsOneWidget);

    await t.tap(find.text('排行'));
    await t.pump();
    expect(find.text('小鹿'), findsOneWidget);
    expect(find.text('9.00 km²'), findsOneWidget);
    await t.tap(find.text('跑团'));
    await t.pump();
    expect(find.text('滨江夜跑团'), findsOneWidget);
    await settle(t);
  });

  testWidgets('league page: standings, my crew, last week', (t) async {
    await phone(t, size: const Size(390, 1000));
    await t.pumpWidget(RepaintBoundary(key: const Key('shot'), child: wrap(const LeaguePage(), overrides: fakeBackend())));
    await idle(t);
    expect(find.text('城区联赛'), findsOneWidget);
    expect(find.text('第 1 名'), findsOneWidget);
    expect(find.text('城西跑团'), findsOneWidget);
    expect(find.text('9 人出力'), findsOneWidget);
    expect(find.text('上周结果'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/league.png');
    await settle(t);
  });

  testWidgets('games hub: core card, tiles, selecting a tile switches the card', (t) async {
    await phone(t, size: const Size(390, 1500));
    await t.pumpWidget(RepaintBoundary(key: const Key('shot'), child: wrap(const GamesPage(), overrides: fakeBackend())));
    await idle(t);
    expect(find.text('玩法中心'), findsOneWidget);
    expect(find.text('城市争霸'), findsNWidgets(2));
    expect(find.text('去开跑'), findsOneWidget);
    for (final name in ['城区联赛', '能量宝箱', '城市定向', '跑步伙伴', '跑团接力', '限时活动', 'AI 剧情夜跑', '轨迹绘画']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    expect(find.text('即将开放'), findsNWidgets(2));
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/games.png');

    await t.tap(find.text('城市定向'));
    await idle(t);
    expect(find.text('查看定向路线'), findsOneWidget);
    expect(find.text('1 条路线开放中'), findsOneWidget);
    await t.tap(find.text('限时活动'));
    await idle(t);
    expect(find.text('1 个进行中'), findsOneWidget);
    await t.tap(find.text('跑步伙伴'));
    await idle(t);
    expect(find.text('泡泡蛙 · Lv.1'), findsOneWidget);
    expect(find.text('喂 50 能量'), findsOneWidget);
    await t.tap(find.text('AI 剧情夜跑'));
    await t.pump();
    expect(find.text('即将开放'), findsNWidgets(4)); // players line + CTA + 2 tiles
    await settle(t);
  });

  testWidgets('城市定向: list + detail with ordered checkpoints on the map', (t) async {
    await phone(t, size: const Size(390, 1100));
    await t.pumpWidget(wrap(const RoutesPage(), overrides: fakeBackend()));
    await idle(t);
    expect(find.text('城南线'), findsOneWidget);
    expect(find.text('2/4'), findsOneWidget);
    expect(find.text('下一站：滨江码头'), findsOneWidget);

    await t.pumpWidget(RepaintBoundary(key: const Key('shot'), child: wrap(const RouteDetailPage(routeId: 2), overrides: fakeBackend())));
    await idle(t);
    expect(find.text('拱桥'), findsOneWidget);
    expect(find.text('已打卡'), findsNWidgets(2));
    expect(find.text('下一站'), findsOneWidget);
    expect(find.text('待打卡'), findsOneWidget);
    expect(find.text('去打卡 · 下一站 滨江码头'), findsOneWidget);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/route.png');
    await settle(t);
  });

  testWidgets('限时活动: rules in Chinese and completion state', (t) async {
    await phone(t, size: const Size(390, 1000));
    await t.pumpWidget(RepaintBoundary(key: const Key('shot'), child: wrap(const CampaignsPage(), overrides: fakeBackend())));
    await idle(t);
    expect(find.text('夜跑专场'), findsNWidgets(2)); // type tag + title
    expect(find.text('单次运动距离不少于 5 km'), findsOneWidget);
    expect(find.text('平均配速快于 6\'00" / km'), findsOneWidget);
    expect(find.text('在 19:00 – 23:00 之间开始'), findsOneWidget);
    expect(find.text(' · 奖牌「夜行者」'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/campaigns.png');
    await settle(t);
  });

  testWidgets('result page renders every V2 settlement block', (t) async {
    await phone(t, size: const Size(390, 2900));
    final m = j(activityResultJson);
    final v2 = j(settlementV2Json);
    (m['settlement'] as Map).addAll(<String, dynamic>{for (final k in ['boss_damage', 'chests', 'defended', 'routes', 'campaigns', 'tasks', 'companion', 'relay']) k: v2[k]});
    final r = ActivityResult.fromJson(m);
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(ResultPage(args: ResultArgs(result: r)), overrides: fakeBackend()),
    ));
    await idle(t);
    expect(find.text('怪兽伤害'), findsOneWidget);
    expect(find.text('对沙发怪造成 530 伤害'), findsOneWidget);
    expect(find.text('能量宝箱'), findsOneWidget);
    expect(find.text('路过开启宝箱 #9'), findsOneWidget);
    expect(find.text('守地成功'), findsOneWidget);
    expect(find.text('守卫 20 → 73'), findsOneWidget);
    expect(find.text('城市定向'), findsOneWidget);
    expect(find.text('打卡 拱桥、老街口'), findsOneWidget);
    expect(find.text('完成「夜跑专场」'), findsOneWidget);
    expect(find.text('本周运动 3 次 · 已完成'), findsOneWidget);
    expect(find.text('伙伴 Lv.2'), findsOneWidget);
    expect(find.text('你跑了第 3 棒'), findsOneWidget);
    expect(find.text('3 / 6 棒'), findsOneWidget);
    expect(find.textContaining('另得 200 能量'), findsOneWidget);
    // V1 blocks still there.
    expect(find.text('新圈 领地 #101'), findsOneWidget);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/result.png');
    await settle(t);
  });

  testWidgets('map: bosses, chests and checkpoints are drawn and hit-tested; S3 chip and 玩法 button', (t) async {
    await phone(t);
    final loc = FakeLocationSource([fixAt(60, 0, 0)]);
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(const MapPage(), overrides: [...fakeBackend(), locationSourceProvider.overrideWithValue(loc)]),
    ));
    await t.pump();
    for (var i = 0; i < 3; i++) {
      await idle(t, 1);
      await t.pump(const Duration(milliseconds: 400));
    }
    await idle(t);
    expect(find.text('S3'), findsNothing); // inside a rich text
    expect(find.textContaining('剩 42 天', findRichText: true), findsOneWidget);
    expect(find.text('玩法'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/map.png');

    final objects = MapObjects.fromJson(j(mapObjectsJson));
    final view = MapView(Projection(origin).inverse(const Point(60, 0)), 16, const Size(390, 844));
    expect(hitTestObjects(view, objects, view.toScreen(objects.bosses.single.center)), isA<BossHit>());
    expect(hitTestObjects(view, objects, view.toScreen(objects.chests.single.center)), isA<ChestHit>());
    expect(hitTestObjects(view, objects, view.toScreen(objects.checkpoints.single.center)), isA<CheckpointHit>());
    expect(hitTestObjects(view, objects, const Offset(5, 5)), isNull);

    // Tap the chest → chest sheet.
    final mapBox = t.getTopLeft(find.byType(FallbackTerritoryMap));
    final st = t.state(find.byType(FallbackTerritoryMap));
    // ignore: invalid_use_of_protected_member
    expect(st.mounted, isTrue);
    final chestAt = view.toScreen(objects.chests.single.center) + mapBox;
    await t.tapAt(chestAt);
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(find.text('能量宝箱'), findsOneWidget);
    expect(find.text('打开宝箱'), findsOneWidget);
    await settle(t);
  });

  testWidgets('chest sheet: open with location; already_opened', (t) async {
    await phone(t);
    final chest = MapObjects.fromJson(j(mapObjectsJson)).chests.single;
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(Scaffold(body: ChestSheet(chest: chest)),
          overrides: [...fakeBackend(), locationSourceProvider.overrideWithValue(FakeLocationSource([fixAt(-100, -160, 0)]))]),
    ));
    await t.pump();
    await t.tap(find.text('打开宝箱'));
    await idle(t);
    expect(find.text('+40 能量'), findsOneWidget);
    expect(find.text('药剂师加成，能量翻倍！'), findsOneWidget);

    await t.pumpWidget(wrap(Scaffold(body: ChestSheet(chest: chest)), overrides: [
      ...fakeBackend(extra: {
        '/v1/chests/9/open': (403, {'error': {'code': 'already_opened', 'message': ''}})
      }),
      locationSourceProvider.overrideWithValue(FakeLocationSource([fixAt(-100, -160, 0)])),
    ]));
    await t.pump();
    await t.tap(find.text('打开宝箱'));
    await idle(t);
    expect(find.text('这个宝箱你已经开过了'), findsOneWidget);
    expect(find.text('好的'), findsOneWidget);
    await settle(t);
  });

  testWidgets('running: nearby boss / chest hints', (t) async {
    await phone(t);
    final container = ProviderContainer(
      overrides: [...fakeBackend(), locationSourceProvider.overrideWithValue(FakeLocationSource())],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final ctrl = container.read(runControllerProvider.notifier);
    ctrl.start(const RunConfig(sport: 'run'), countdownFrom: 0);
    // Chest centre is at 31.2290,121.4720 → walk right onto it.
    final chest = MapObjects.fromJson(j(mapObjectsJson)).chests.single.center;
    final p = Projection(origin).forward(chest);
    ctrl.onFix(fixAt(p.x - 60, p.y, 0));
    ctrl.onFix(fixAt(p.x, p.y, 30));
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: buildTheme(), home: const RunPage(), debugShowCheckedModeBanner: false),
      ),
    ));
    await idle(t);
    expect(find.text('正在对沙发怪造成伤害'), findsOneWidget);
    expect(find.text('经过能量宝箱，结算时自动开启'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/run.png');
    ctrl.reset();
    await t.pump();
    await settle(t);
  });

  testWidgets('codex: monsters tab, companion growth and feeding', (t) async {
    await phone(t, size: const Size(390, 1000));
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(const CodexPage(), overrides: [
        ...fakeBackend(extra: {'/v1/codex': j(codexV2Json), '/v1/codex/companions/gecko/feed': j(codexV2Json)}),
      ]),
    ));
    await idle(t);
    await t.tap(find.text('怪兽'));
    await t.pump();
    expect(find.text('2/4'), findsOneWidget);
    expect(find.text('沙发怪'), findsOneWidget);
    expect(find.text('击退 2 次 · 最佳第 3'), findsOneWidget);
    expect(find.text('出手 1 次'), findsOneWidget);
    expect(find.text('???'), findsNWidgets(2));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/codex_monsters.png');

    await t.tap(find.text('伙伴'));
    await t.pump();
    expect(find.text('陪跑中 · Lv.4'), findsOneWidget);
    await t.tap(find.text('陪跑中 · Lv.4'));
    await t.pumpAndSettle();
    expect(find.text('闪电壁虎 · Lv.4'), findsOneWidget);
    expect(find.text('经验 62 / 100 · 已陪你跑 1,326 米'), findsOneWidget);
    await t.tap(find.text('喂 50 能量'));
    await idle(t);
    expect(find.text('喂食成功，经验 +10'), findsOneWidget);
    await settle(t);
  });

  testWidgets('crew relay card: legs, members, deadline; leader can start one', (t) async {
    await phone(t);
    final crew = Crew.fromJson(j(crewJson));
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: RelayCard(crew: crew))), overrides: fakeBackend()),
    ));
    await idle(t);
    expect(find.text('跑团接力 · 2/6 棒'), findsOneWidget);
    expect(find.text('小鹿'), findsOneWidget);
    expect(find.text('3.20 km'), findsOneWidget);
    expect(find.text('待接'), findsNWidgets(4));
    expect(find.textContaining('还剩'), findsOneWidget);
    expect(find.text('你已经跑了第 2 棒，等团友接力'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/relay.png');

    // No relay: the leader sees 发起接力 → POST relays.
    var posted = false;
    await t.pumpWidget(wrap(Scaffold(body: RelayCard(crew: crew)), overrides: fakeBackend(extra: {
      '/v1/crews/3/relays/current': null,
      '/v1/crews/3/relays': () {
        posted = true;
        return j(relayJson);
      }(),
    })));
    await idle(t);
    expect(find.text('发起接力'), findsOneWidget);
    await t.tap(find.text('发起接力'));
    await t.pumpAndSettle();
    expect(find.text('6 棒'), findsOneWidget);
    expect(find.text('3 km'), findsOneWidget);
    await t.tap(find.text('发起'));
    await idle(t);
    expect(posted, isTrue);
    await settle(t);
  });

  testWidgets('守地挑战 on the city page; blueprint in the building picker', (t) async {
    await phone(t, size: const Size(390, 1100));
    final terr = j(territoryJson)..['defense'] = j(territoryDefenseJson);
    await t.pumpWidget(wrap(const CityPage(territoryId: 101), overrides: fakeBackend(extra: {'/v1/territories/101': terr})));
    await idle(t);
    expect(find.text('24 小时内跑一圈经过这里即可加固'), findsOneWidget);
    expect(find.text('守地挑战 · 小鹿 攻击了这里'), findsOneWidget);

    final cfg = GameConfig.fromJson(j(gameplayV2Json));
    final low = j(userJson)..['level'] = 2;
    await t.pumpWidget(wrap(Scaffold(body: BuildingPicker(config: cfg)),
        overrides: fakeBackend(user: User.fromJson(low), extra: {'/v1/codex': j(codexV2Json)})));
    await idle(t);
    expect(find.text('图纸可建'), findsOneWidget);
    expect(find.text('Lv.5 解锁'), findsNothing);
    await settle(t);
  });

  testWidgets('realtime banner: territory_attacked and rally open the right page', (t) async {
    await phone(t);
    final (rt, chans) = fakeRealtime();
    addTearDown(rt.dispose);
    final opened = <String>[];
    await t.pumpWidget(ProviderScope(
      overrides: [...fakeBackend(), realtimeClientProvider.overrideWithValue(rt)],
      child: MaterialApp(
        theme: buildTheme(),
        builder: (context, child) => RealtimeBannerHost(onOpen: opened.add, child: child!),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    ));
    await t.runAsync(() async => rt.start());
    await idle(t, 1);
    chans.single.push({'type': 'territory_attacked', 'territory_id': 12, 'captured': false, 'guard_after': 20});
    await idle(t, 1);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('领地 #12 正在被攻击'), findsOneWidget);
    expect(find.textContaining('24 小时内跑一圈经过这里即可加固'), findsOneWidget);
    await t.tap(find.text('领地 #12 正在被攻击'));
    await t.pump(const Duration(milliseconds: 300));
    expect(opened, ['/city/12']);

    chans.single.push({'type': 'rally', 'boss_id': 3, 'by': {'id': 7, 'nickname': '小鹿'}});
    await idle(t, 1);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('小鹿 正在合击怪兽，快来一起出手！'), findsOneWidget);
    await t.tap(find.text('合击召集'));
    await t.pump(const Duration(milliseconds: 300));
    expect(opened.last, '/bosses/3');
    await settle(t);
  });

  test('damage tiles group identical rules', () {
    final b = Boss.fromJson(j(bossJson));
    expect(damageTiles(b.damageRules, b.strike), [
      ('跑步 / 骑行', '每 1 km = 100 伤害'),
      ('跳绳', '每 100 个 = 30 伤害'),
      ('瑜伽', '每 10 分钟 = 30 伤害'),
      ('投入能量', '每 100 能量 = 40 伤害'),
    ]);
    expect(codexProvider, isNotNull);
  });
}
