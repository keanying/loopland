// Parses every V2 payload example in docs/api/v2-1-玩法.md.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/errors.dart';
import 'package:loopland/api/loopland_api.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/claim/geo.dart';

import 'api_client_test.dart' show FakeAdapter;
import 'fixtures.dart';
import 'fixtures_v2.dart';

void main() {
  test('gameplay config V2 additions', () {
    final c = GameConfig.fromJson(j(gameplayV2Json));
    expect(c.boss.strikeCost, 100);
    expect(c.boss.strikeCooldownS, 30);
    expect(c.boss.comboMaxPct, 50);
    expect(c.boss.damage, hasLength(8));
    expect(c.boss.damage.first.text, '每 1 km = 100 伤害');
    expect(c.boss.damage[4].text, '每 100 个 = 30 伤害');
    expect(c.boss.damage[5].text, '每 10 分钟 = 30 伤害');
    expect(c.boss.topExtraRolls, 3);
    expect(c.boss.expireRefundPct, 20);
    expect(c.chest.radiusM, 50);
    expect(c.chest.energyMax, 60);
    expect(c.defense.maxGuard, 2000);
    expect(c.seasonTiers.map((t) => t.name), ['青铜', '白银', '黄金', '铂金', '钻石']);
    expect(c.seasonTiers[2].minM2, closeTo(3.6e6, 1));
    expect(c.seasonTasks[1].type, 'weekly_area_m2');
    expect(c.seasonTasks[1].target, 20000);
    expect(c.medals[0].distanceKm, 100);
    expect(c.medals[1].type, 'defends');
    expect(c.medals[1].target, 5);
    expect(c.companion.feedCost, 50);
    expect(c.companion.expPerLevel, 100);
    expect(c.relay.defaultLegs, 6);
    expect(c.relay.legKm, 3);
    expect(c.buildings.single.blueprintBypassLevel, isTrue);
    // V1 payloads still parse with defaults.
    final v1 = GameConfig.fromJson(j(configJson));
    expect(v1.boss.strikeCost, 100);
    expect(v1.medals.single.type, 'distance_km');
    expect(v1.medals.single.target, 100);
  });

  test('settlement V2 blocks', () {
    final s = Settlement.fromJson(j(settlementV2Json));
    expect(s.bossDamage.single.name, '沙发怪');
    expect(s.bossDamage.single.damage, 530);
    expect(s.bossDamage.single.defeated, isFalse);
    expect(s.chests.single.energy, 40);
    expect(s.defended.single.guardAfter, 73);
    expect(s.routes.single.reached, ['拱桥', '老街口']);
    expect(s.campaigns.single.rewardEnergy, 100);
    expect(s.tasks.single.completed, isTrue);
    expect(s.tasks.single.progressText, '3 / 3');
    expect(s.companion!.level, 2);
    expect(s.relay!.leg, 3);
    expect(s.relay!.legs, 6);
    // Missing blocks: empty / null.
    final v1 = Settlement.fromJson(j(activityResultJson)['settlement'] as Map<String, dynamic>);
    expect(v1.bossDamage, isEmpty);
    expect(v1.companion, isNull);
    expect(v1.relay, isNull);
    // `null` for a list is tolerated.
    expect(Settlement.fromJson({'status': 'settled', 'chests': null}).chests, isEmpty);
  });

  test('map objects', () {
    final o = MapObjects.fromJson(j(mapObjectsJson));
    final b = o.bosses.single;
    expect(b.kind, 'sofa');
    expect(b.level, 12);
    expect(b.hpFraction, closeTo(0.38, 1e-9));
    expect(b.radiusM, 1000);
    expect(b.center.lat, 31.2313);
    expect(b.expiresAt, isNotNull);
    expect(o.chests.single.radiusM, 50);
    expect(o.checkpoints.single.isNext, isTrue);
    expect(o.checkpoints.single.routeId, 2);
    expect(MapObjects.fromJson({}).isEmpty, isTrue);
  });

  test('boss detail, strike, chest', () {
    final b = Boss.fromJson(j(bossJson));
    expect(b.isActive, isTrue);
    expect(b.occupiedTerritories, 3);
    expect(b.damageRules, hasLength(4));
    expect(b.strike.cost, 100);
    expect(b.strike.cooldownS, 30);
    expect(b.rank.first.user.nickname, '小鹿');
    expect(b.me.rank, 2);
    expect(b.me.engagedUntil, isNull);
    expect(b.drops.map((d) => d.percent).reduce((a, c) => a + c), 100);
    expect(b.myRewards, isEmpty);
    expect(b.defeatedAt, isNull);
    final done = Boss.fromJson(j(bossJson)
      ..['status'] = 'defeated'
      ..['my_rewards'] = [
        {'item': 'banner', 'kind': 'role', 'name': '旗手卡', 'converted_energy': null},
        {'item': 'knight', 'kind': 'role', 'name': '骑士卡', 'converted_energy': 50},
      ]);
    expect(done.isDefeated, isTrue);
    expect(done.myRewards.first.convertedEnergy, isNull);
    expect(done.myRewards.last.convertedEnergy, 50);

    final s = StrikeResult.fromJson(j(strikeJson));
    expect(s.damage, 44);
    expect(s.comboPct, 10);
    expect(s.energy, 1180);
    expect(s.hp, 3756);
    expect(s.status, 'active');

    final c = ChestOpenResult.fromJson(j('{"energy":40,"bonus":false}'));
    expect(c.energy, 40);
    expect(c.bonus, isFalse);
  });

  test('territory defense', () {
    final m = j(territoryJson)..['defense'] = j(territoryDefenseJson);
    final t = Territory.fromJson(m);
    expect(t.defense!.attackedBy!.nickname, '小鹿');
    expect(t.defense!.deadline, isNotNull);
    expect(Territory.fromJson(j(territoryJson)..['defense'] = null).defense, isNull);
  });

  test('season, league', () {
    final s = SeasonOverview.fromJson(j(seasonJson));
    expect(s.season!.shortName, 'S3');
    expect(s.season!.daysLeft, 42);
    expect(s.me.tier!.text, '白银 II');
    expect(s.me.next!.text, '黄金 I');
    expect(s.me.needM2, 1240000);
    expect(s.me.rank, 128);
    expect(s.crew!.rank, 4);
    expect(s.tiers[1].minM2, 500000);
    // 2.36 km² within 白银 (0.5 – 3.6).
    expect(s.tierProgress, closeTo((2.36 - 0.5) / 3.1, 1e-6));
    expect(s.top.single.name, '小鹿');
    expect(s.crewTop.single.name, '滨江夜跑团');
    expect(s.tasks.first.progressText, '2 / 3 次');
    expect(s.tasks.last.progressText, '2 / 2 万 m²');
    expect(s.medals.first.progressText, '3/5');
    expect(s.medals.last.obtained, isTrue);
    // No season running.
    final none = SeasonOverview.fromJson({'season': null, 'me': {}, 'tiers': [], 'top': [], 'tasks': [], 'medals': []});
    expect(none.season, isNull);
    expect(none.tierProgress, 0);

    final l = League.fromJson(j(leagueJson));
    expect(l.district, '徐汇区');
    expect(l.standings.first.crew!.name, '城西跑团');
    expect(l.standings.first.activeMembers, 9);
    expect(l.myCrew!.rank, 1);
    expect(l.lastWeek.single.scoreM2, 900000);
    expect(League.fromJson(j(leagueJson)..['my_crew'] = null).myCrew, isNull);
  });

  test('campaign rules in Chinese, route ordering', () {
    final c = Campaign.fromJson(j(campaignJson));
    expect(c.typeName, '夜跑专场');
    expect(c.rules.lines, ['单次运动距离不少于 5 km', '平均配速快于 6\'00" / km', '在 19:00 – 23:00 之间开始']);
    expect(c.rewardMedal!.name, '夜行者');
    expect(c.isLive(DateTime.utc(2026, 11, 21)), isTrue);
    expect(c.isLive(DateTime.utc(2026, 10, 1)), isFalse);
    expect(Campaign.fromJson({'id': 1, 'title': 'x', 'rules': {'min_distance_km': 10}}).rules.lines, ['单次运动距离不少于 10 km']);

    final r = CityRoute.fromJson(j(routeJson));
    expect(r.checkpoints.map((c) => c.name), ['拱桥', '老街口', '滨江码头', '城南体育场']);
    expect(r.doneCount, 2);
    expect(r.next!.name, '滨江码头');
  });

  test('codex monsters, companion growth, blueprints, relay', () {
    final c = Codex.fromJson(j(codexV2Json));
    expect(c.monsters, hasLength(4));
    expect(c.monsters.first.bestRank, 3);
    expect(c.monsters[2].seen, isFalse);
    expect(c.progress['monsters'], '2/4');
    final g = c.companions.single;
    expect(g.level, 4);
    expect(g.exp, 362);
    expect(g.expToNext, 38);
    expect(g.meters, 1326);
    expect(c.buildings.single.blueprint, isTrue);

    final r = Relay.fromJson(j(relayJson));
    expect(r.isRunning, isTrue);
    expect(r.legKm, 3);
    expect(r.leg(2)!.user!.nickname, '跑者1024');
    expect(r.leg(3), isNull);
  });

  test('realtime messages', () {
    final b = RealtimeEvent.parse(jsonDecode('{"type":"boss","boss":{"id":3,"hp":3756,"status":"active"},"by":{"id":1,"nickname":"阿杰"},"damage":44}'));
    expect(b, isA<BossHpEvent>().having((e) => e.hp, 'hp', 3756).having((e) => e.by!.nickname, 'by', '阿杰').having((e) => e.damage, 'damage', 44));
    final t = RealtimeEvent.parse(jsonDecode('{"type":"territory_attacked","territory_id":12,"captured":false,"guard_after":20}'));
    expect(t, isA<TerritoryAttackedEvent>().having((e) => e.guardAfter, 'guard', 20));
    final r = RealtimeEvent.parse(jsonDecode('{"type":"rally","boss_id":3,"by":{"id":1,"nickname":"阿杰"}}'));
    expect(r, isA<RallyEvent>().having((e) => e.bossId, 'boss', 3));
    expect(RealtimeEvent.parse(jsonDecode('{"type":"ping"}')), isA<PingEvent>());
    expect(RealtimeEvent.parse(jsonDecode('{"type":"new_thing"}')), isA<UnknownEvent>());
    expect(RealtimeEvent.parse('nope'), isNull);
  });

  test('API paths, bodies and error codes', () async {
    final a = FakeAdapter((o) {
      switch (o.path) {
        case '/v1/map/objects':
          expect(o.queryParameters['bbox'], '121.400000,31.200000,121.500000,31.300000');
          return (200, j(mapObjectsJson));
        case '/v1/bosses/3/strike':
          expect(o.data, {'lat': 31.23, 'lng': 121.47});
          return (429, {'error': {'code': 'cooldown', 'message': '冷却中'}, 'retry_after_s': 12});
        case '/v1/bosses/3/engage':
          return (200, {'engaged_until': '2026-11-21T20:00:00+08:00'});
        case '/v1/chests/9/open':
          return (403, {'error': {'code': 'out_of_range', 'message': ''}});
        case '/v1/crews/3/relays/current':
          return (200, null);
        case '/v1/crews/3/relays':
          expect(o.data, {'legs': 6, 'leg_km': 3.0});
          return (409, {'error': {'code': 'relay_running', 'message': ''}});
        case '/v1/codex/companions/gecko/feed':
          expect(o.method, 'POST');
          return (200, j(codexV2Json));
        case '/v1/league':
          expect(o.queryParameters['district'], '徐汇区');
          return (200, j(leagueJson));
        case '/v1/campaigns':
          return (200, {'items': [j(campaignJson)]});
        case '/v1/routes':
          return (200, {'items': [j(routeJson)]});
      }
      return (404, {'error': {'code': 'not_found', 'message': ''}});
    });
    final api = LooplandApi(ApiClient(tokens: MemoryTokenStore(access: 'A'), baseUrl: 'http://x', adapter: a));
    final o = await api.mapObjects(minLng: 121.4, minLat: 31.2, maxLng: 121.5, maxLat: 31.3);
    expect(o.bosses, hasLength(1));
    await expectLater(
        api.strike(3, const LatLng(31.23, 121.47)),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'cooldown')
            .having((e) => e.status, 'status', 429)
            .having((e) => e.retryAfterS, 'retry', 12)));
    expect(await api.engage(3, const LatLng(31.23, 121.47)), isNotNull);
    await expectLater(api.openChest(9, const LatLng(31.23, 121.47)),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', '离得太远了，走近一点再试')));
    expect(await api.currentRelay(3), isNull);
    await expectLater(api.startRelay(3, legs: 6, legKm: 3),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'relay_running')));
    expect((await api.feedCompanion('gecko')).companions.single.level, 4);
    expect((await api.league(district: '徐汇区')).district, '徐汇区');
    expect(await api.campaigns(), hasLength(1));
    expect(await api.routes(), hasLength(1));
  });
}
