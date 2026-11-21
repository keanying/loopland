// V2 batch 4 perks API layer (lib/api/perks_api.dart) against a live dev
// backend: brand campaigns, supply stations on the map, coupons from a run's
// settlement, the store QR, manual claim errors, the energy shop (buy /
// already_owned / not_enough_energy / equip / unequip) and the cosmetics
// showing up in /v1/me, territories and UserBrief.
//
//   LOOPLAND_LIVE_API=http://localhost:8080 flutter test integration_live/perks_live_test.dart
//
// The backend must run with LOOPLAND_ENV=dev (SMS code 000000) and the
// bootstrap admin admin:admin-password-1 (to create the merchant, drops and
// the campaign). Optional LOOPLAND_LIVE_DB (a psql connection string for the
// same scratch database) tops the test user's energy up so the shop can be
// bought from; without it only the not_enough_energy path is checked.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/community_api.dart';
import 'package:loopland/api/errors.dart';
import 'package:loopland/api/loopland_api.dart';
import 'package:loopland/api/perks_api.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/claim/geo.dart';

import 'gathering_live_test.dart' show origin, runEndingNow;

Matcher apiError(String code) => throwsA(isA<ApiException>().having((e) => e.code, 'code', code));

void main() {
  final base = Platform.environment['LOOPLAND_LIVE_API'];
  final dbUrl = Platform.environment['LOOPLAND_LIVE_DB'];
  final skip = base == null ? 'set LOOPLAND_LIVE_API to run' : false;
  final rnd = math.Random().nextInt(90000000) + 10000000;

  test('campaigns, supplies, settlement coupons, QR, claim, shop buy / equip', () async {
    final c = ApiClient(tokens: MemoryTokenStore(), baseUrl: base, platform: 'android');
    final api = LooplandApi(c);
    final perks = PerksApi(c);
    await api.sendSms('134$rnd');
    await api.login('sms', {'phone': '134$rnd', 'code': '000000'});
    final me = await api.setConsents(privacyVersion: '2026-11', location: true, health: true);

    // ── 运营：商户、两个补给站、联名活动 ──
    final admin = Dio(BaseOptions(baseUrl: base!, contentType: 'application/json'));
    final login = await admin.post<Map<String, dynamic>>('/admin/v1/login', data: {'username': 'admin', 'password': 'admin-password-1'});
    admin.options.headers['Authorization'] = 'Bearer ${login.data!['token']}';
    final merchant = (await admin.post<Map<String, dynamic>>('/admin/v1/merchants',
            data: {'name': '测试咖啡$rnd', 'type': 'brand', 'status': 'partner', 'contact_name': '王经理', 'contact_phone': '13800138000'}))
        .data!;
    final proj = Projection(origin);
    final dx = rnd % 50 * 1000.0 + 120000; // a quiet corner of the map per run
    final onTrack = proj.inverse(Point(dx + 150, 0)); // on the run's first leg
    final away = proj.inverse(Point(dx + 3000, 0));
    final now = DateTime.now().toUtc();
    Future<int> drop(String name, LatLng at) async => ((await admin.post<Map<String, dynamic>>('/admin/v1/drops', data: {
          'merchant_id': merchant['id'],
          'type': 'supply',
          'name': name,
          'center': {'lat': at.lat, 'lng': at.lng},
          'radius_m': 80,
          'perk': {'title': '美式 5 折', 'description': '每人每天 1 次', 'value_text': '5 折', 'valid_days': 7, 'rules': '到店出示券码，店员扫码核销'},
          'daily_cap': 100,
          'start_time': now.subtract(const Duration(hours: 1)).toIso8601String(),
          'end_time': now.add(const Duration(days: 7)).toIso8601String(),
          'settle_price_amt': 200,
          'settle_direction': 'merchant_pays',
        }))
            .data!['id'] as num)
        .toInt();
    final s1 = await drop('补给站 · 测试$rnd 滨江', onTrack);
    final s2 = await drop('补给站 · 测试$rnd 外滩', away);
    final camp = (await admin.post<Map<String, dynamic>>('/admin/v1/brand-campaigns', data: {
      'merchant_id': merchant['id'],
      'title': '跑完来杯咖啡$rnd',
      'description': '跑步经过补给站领券',
      'start_time': now.add(const Duration(hours: 1)).toIso8601String(),
      'end_time': now.add(const Duration(days: 7)).toIso8601String(),
      'store_count': 2,
      'target_redemptions': 100,
      'merchant_investment_amt': 100000,
      'drop_ids': [s1, s2],
    }))
        .data!;
    await admin.post<dynamic>('/admin/v1/brand-campaigns/${camp['id']}/launch');

    // ── 联名活动 tab ──
    final campaigns = await perks.brandCampaigns();
    final mine = campaigns.firstWhere((e) => e.title == '跑完来杯咖啡$rnd');
    expect(mine.merchant?.name, '测试咖啡$rnd');
    expect(mine.drops.map((d) => d.id), containsAll([s1, s2]));
    expect(mine.perks.single.title, '美式 5 折');
    expect(mine.dropTypes, ['supply']);

    // ── 地图补给站 ──
    final objs = await api.mapObjects(
        minLng: onTrack.lng - 0.01, minLat: onTrack.lat - 0.01, maxLng: onTrack.lng + 0.01, maxLat: onTrack.lat + 0.01);
    final sup = objs.supplies.firstWhere((s) => s.id == s1);
    expect(sup.perkTitle, '美式 5 折');
    expect(sup.radiusM, 80);
    expect(sup.claimedToday, isFalse);

    // ── 跑步经过补给站：结算发券 ──
    final res = await api.uploadActivity(runEndingNow(dx, 0));
    expect(res.settlement.status, 'settled');
    final won = res.settlement.coupons.where((e) => e.source?.dropId == s1).toList();
    expect(won, hasLength(1), reason: 'the run passes the supply station');
    expect(won.single.perk.title, '美式 5 折');
    expect(won.single.status, 'unused');
    expect(won.single.code, isNotEmpty);

    // ── 卡券包 + 二维码 ──
    final unused = await perks.myCoupons('unused');
    expect(unused.map((e) => e.id), contains(won.single.id));
    expect(await perks.myCoupons('used'), isEmpty);
    final qr = await perks.couponQr(won.single.id);
    expect(qr.payload, startsWith('LPC.${won.single.id}.'));
    expect(qr.expiresInSec, 60);

    // ── 手动领取 ──
    await expectLater(perks.claimDrop(s1, onTrack), apiError('already_claimed'));
    await expectLater(perks.claimDrop(s2, onTrack), apiError('too_far'));
    final claimed = await perks.claimDrop(s2, away);
    expect(claimed.source?.dropId, s2);
    final after = await api.mapObjects(minLng: away.lng - 0.01, minLat: away.lat - 0.01, maxLng: away.lng + 0.01, maxLat: away.lat + 0.01);
    expect(after.supplies.firstWhere((s) => s.id == s2).claimedToday, isTrue);
    expect((await perks.myCoupons('unused')).length, 2);

    // ── 能量商城 ──
    var cat = await perks.shopItems();
    expect(cat.items.map((e) => e.key), containsAll(['skin_neon', 'frame_gold', 'marker_star']));
    expect(cat.items.firstWhere((e) => e.key == 'skin_neon').preview.pattern, 'grid');
    expect((await perks.shopItems(type: 'avatar_frame')).items.every((e) => e.type == 'avatar_frame'), isTrue);
    final priciest = cat.items.reduce((a, b) => a.priceEnergy >= b.priceEnergy ? a : b);
    if (cat.energy < priciest.priceEnergy) {
      await expectLater(perks.buy(priciest.key), apiError('not_enough_energy'));
    }
    if (dbUrl == null) {
      markTestSkipped('LOOPLAND_LIVE_DB not set: buy / equip not checked');
      return;
    }
    final psql = await Process.run('psql', [dbUrl, '-c', 'UPDATE src.src_usr_loop_user SET energy = 3000 WHERE id = ${me.id}']);
    expect(psql.exitCode, 0, reason: '${psql.stderr}');
    cat = await perks.shopItems();
    expect(cat.energy, 3000);
    final bought = await perks.buy('skin_neon');
    expect(bought.item.owned, isTrue);
    expect(bought.energy, 3000 - bought.item.priceEnergy);
    await expectLater(perks.buy('skin_neon'), apiError('already_owned'));
    expect((await perks.equip('skin_neon')).equipped, isTrue);
    await perks.buy('frame_gold');
    await perks.equip('frame_gold');
    await perks.buy('marker_star');
    await perks.equip('marker_star');
    var u = await api.me();
    expect(u.equipped.territorySkin, 'skin_neon');
    expect(u.equipped.avatarFrame, 'frame_gold');
    expect(u.equipped.mapMarker, 'marker_star');
    expect((await CommunityApi(c).profile(me.id)).user.avatarFrame, 'frame_gold');
    final c0 = proj.inverse(Point(dx + 150, 150));
    final terrs = await api.territories(minLng: c0.lng - 0.01, minLat: c0.lat - 0.01, maxLng: c0.lng + 0.01, maxLat: c0.lat + 0.01, scope: 'mine');
    expect(terrs, isNotEmpty, reason: 'the run claims a loop');
    expect(terrs.first.skin?.key, 'skin_neon');
    expect(terrs.first.skin?.fill, '#D9F26B');
    expect((await perks.unequip('marker_star')).equipped, isFalse);
    u = await api.me();
    expect(u.equipped.mapMarker, isNull);
    expect(u.energy, 3000 - 800 - 600 - 200);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
