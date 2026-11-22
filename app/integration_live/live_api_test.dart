// Runs the app's own API layer against a live dev backend.
//
//   LOOPLAND_LIVE_API=http://localhost:8080 flutter test integration_live
//
// The backend must run with LOOPLAND_ENV=dev (SMS code 000000, mock pay).
// Skipped when LOOPLAND_LIVE_API is not set.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/errors.dart';
import 'package:loopland/api/loopland_api.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/claim/claim.dart';
import 'package:loopland/claim/geo.dart';
import 'package:loopland/realtime/realtime_client.dart';
import 'package:uuid/uuid.dart';

const origin = LatLng(31.2304, 121.4737);

/// A run around waypoints (metres from origin) at [speed] m/s, every 5 m.
ActivityUpload run(List<List<double>> wps, {double speed = 3, String device = 'live-device'}) {
  final proj = Projection(origin);
  final start = DateTime.now().subtract(const Duration(hours: 1));
  final pts = <TrackPoint>[];
  var t = 0.0;
  void add(double x, double y) {
    final ll = proj.inverse(Point(x, y));
    pts.add(TrackPoint(t: start.millisecondsSinceEpoch + (t * 1000).round(), lat: ll.lat, lng: ll.lng, acc: 5));
  }

  add(wps[0][0], wps[0][1]);
  for (var i = 1; i < wps.length; i++) {
    final a = wps[i - 1], b = wps[i];
    final d = math.sqrt(math.pow(b[0] - a[0], 2) + math.pow(b[1] - a[1], 2));
    final n = (d / 5).ceil();
    for (var k = 1; k <= n; k++) {
      t += d / n / speed;
      add(a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n);
    }
  }
  return ActivityUpload(
    clientId: const Uuid().v4(),
    sport: 'run',
    startedAt: start,
    endedAt: start.add(Duration(milliseconds: (t * 1000).round())),
    durationS: t.round(),
    points: pts,
    device: DeviceInfo(id: device, model: 'live-test', os: 'test'),
  );
}

String idNumber(String birth) {
  final base = '110105${birth}123';
  const w = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
  var s = 0;
  for (var i = 0; i < 17; i++) {
    s += (base.codeUnitAt(i) - 48) * w[i];
  }
  return base + '10X98765432'[s % 11];
}

void main() {
  final base = Platform.environment['LOOPLAND_LIVE_API'];
  final skip = base == null ? 'set LOOPLAND_LIVE_API to run' : false;
  final rnd = math.Random().nextInt(90000000) + 10000000;

  LooplandApi client() => LooplandApi(ApiClient(tokens: MemoryTokenStore(), baseUrl: base, platform: 'android'));

  test('main flow against the live backend', () async {
    final a = client();
    final phone = '139$rnd';
    await a.sendSms(phone);
    final auth = await a.login('sms', {'phone': phone, 'code': '000000'});
    expect(auth.isNew, isTrue);
    expect(auth.needBindPhone, isFalse);

    // Upload before consent is refused with the code the app reacts to.
    final square = [
      [0.0, 0.0], [300.0, 0.0], [300.0, 300.0], [150.0, 300.0], [150.0, -50.0]
    ].map((p) => [p[0] + rnd % 50 * 1000.0, p[1]]).toList();
    final upload = run(square);
    await expectLater(a.uploadActivity(upload),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'consent_required')));
    await a.setConsents(privacyVersion: '2026-11', location: true, health: true);

    // The app's own claim preview agrees with the server's settlement.
    final local = detect(upload.points.map((p) => LatLng(p.lat, p.lng)).toList());
    final res = await a.uploadActivity(upload);
    expect(res.settlement.status, 'settled');
    expect(res.settlement.claims, hasLength(1));
    expect(local.loops, hasLength(1));
    expect((res.settlement.claims.first.areaM2 - local.loops.first.areaM2).abs() / local.loops.first.areaM2, lessThan(0.02));
    expect(res.settlement.eggs.map((e) => e.key), contains('gecko'));

    // Idempotent retry from the offline uploader.
    final again = await a.uploadActivity(upload);
    expect(again.activity.id, res.activity.id);

    final tid = res.settlement.claims.first.territoryId;
    final c = Projection(origin).inverse(Point(square[0][0] + 150, 150));
    final terrs = await a.territories(minLng: c.lng - 0.01, minLat: c.lat - 0.01, maxLng: c.lng + 0.01, maxLat: c.lat + 0.01, scope: 'mine');
    expect(terrs.map((t) => t.id), contains(tid));
    expect(terrs.firstWhere((t) => t.id == tid).relation, 'mine');

    final detail = await a.territory(tid);
    expect(detail.slots.length, 6);
    // V2 season tasks / chests can top the first run's energy up past the
    // campfire's cost, so either outcome is valid here.
    try {
      final built = await a.build(tid, 0, 'campfire');
      expect(built.territory.slots.firstWhere((s) => s.slot == 0).building, 'campfire');
    } on ApiException catch (e) {
      expect(e.code, 'not_enough_energy');
    }

    final codex = await a.codex();
    expect(codex.roles, hasLength(8));
    expect(codex.progress['roles'], isNotNull);

    final history = await a.activities();
    expect(history.items.first.id, res.activity.id);
    final act = await a.activity(res.activity.id);
    expect(act.id, res.activity.id);

    // Home training: energy only.
    final yoga = await a.uploadActivity(ActivityUpload(
      clientId: const Uuid().v4(),
      sport: 'yoga',
      startedAt: DateTime.now().subtract(const Duration(minutes: 40)),
      endedAt: DateTime.now(),
      durationS: 2400,
      amount: 40,
      device: const DeviceInfo(id: 'live-device'),
    ));
    expect(yoga.settlement.energyGranted, 16);
    expect(yoga.settlement.claims, isEmpty);

    // Membership through the mock channel; realname first.
    await expectLater(a.createOrder('auto_month', 'mock'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'realname_required')));
    await a.realname('张三', idNumber('19900307'));
    final plans = await a.plans();
    expect(plans.minorBlocked, isFalse);
    expect(plans.items, isNotEmpty);
    final order = await a.createOrder('auto_month', 'mock');
    final paid = await a.devPay(order.order.orderNo);
    expect(paid.status, 'paid');
    final m = await a.membership();
    expect(m.active, isTrue);

    // Crew.
    final crew = await a.createCrew(name: '联调$rnd'.substring(0, 8), district: '徐汇区', joinMode: 'open');
    expect((await a.crew(crew.id)).id, crew.id);

    // Inbox has the territory/system messages.
    final inbox = await a.inbox();
    expect(inbox.items, isNotEmpty);

    // WeChat user must bind a phone before anything else.
    final b = client();
    final wx = await b.login('wechat', {'code': 'dev:live-$rnd'});
    expect(wx.needBindPhone, isTrue);
    await expectLater(b.codex(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'phone_required')));
    await b.bindPhone(phone: '137$rnd', code: '000000');
    await b.codex();

    final me = await a.me();
    expect(me.energy, greaterThan(0));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('V2 玩法 against the live backend', () async {
    final proj = Projection(origin);
    LatLng at(double x, double y) => proj.inverse(Point(x, y));
    // Far from the V1 test and the seed data.
    final cx = 60000.0 + rnd % 40 * 1000, cy = 8000.0;

    // Operator places a monster on the track and two chests.
    final admin = Dio(BaseOptions(baseUrl: base!, contentType: 'application/json'));
    final login = await admin.post<Map<String, dynamic>>('/admin/v1/login', data: {'username': 'looproot', 'password': 'LoopRoot101011!'});
    admin.options.headers['Authorization'] = 'Bearer ${login.data!['token']}';
    final c0 = at(cx, cy);
    final spawned = await admin.post<Map<String, dynamic>>('/admin/v1/bosses',
        data: {'kind': 'sofa', 'lat': c0.lat, 'lng': c0.lng, 'location_name': '联调公园', 'level': 3, 'hp': 10000, 'radius_m': 1000, 'duration_h': 2});
    final bossId = (spawned.data!['id'] as num).toInt();
    final onTrack = at(cx + 2000, cy);
    await admin.post<dynamic>('/admin/v1/chests',
        data: {'lat': onTrack.lat, 'lng': onTrack.lng, 'energy_min': 20, 'energy_max': 60, 'duration_h': 2, 'radius_m': 50});
    final manual = at(cx - 3000, cy + 3000);
    final manualChest = await admin.post<Map<String, dynamic>>('/admin/v1/chests',
        data: {'lat': manual.lat, 'lng': manual.lng, 'energy_min': 20, 'energy_max': 60, 'duration_h': 2, 'radius_m': 50});
    final manualId = (manualChest.data!['id'] as num).toInt();

    final a = client();
    final phone = '136$rnd';
    await a.sendSms(phone);
    await a.login('sms', {'phone': phone, 'code': '000000'});
    await a.setConsents(privacyVersion: '2026-11', location: true, health: true);

    // Map objects around the track.
    final objs = await a.mapObjects(minLng: c0.lng - 0.05, minLat: c0.lat - 0.05, maxLng: c0.lng + 0.05, maxLat: c0.lat + 0.05);
    expect(objs.bosses.map((b) => b.id), contains(bossId));
    expect(objs.chests.map((c) => c.id), contains(manualId));
    expect(objs.chests.length, greaterThanOrEqualTo(2));

    // Boss detail.
    var boss = await a.boss(bossId);
    expect(boss.isActive, isTrue);
    expect(boss.hp, 10000);
    expect(boss.damageRules, isNotEmpty);
    expect(boss.drops.fold<double>(0, (s, d) => s + d.percent), closeTo(100, 0.01));

    // Live HP over the WebSocket (the app's own client, real socket).
    final tokens = a.c.tokens;
    final ws = RealtimeClient(baseUrl: base, token: () => tokens.accessToken);
    final hp = Completer<BossHpEvent>();
    final sub = ws.events.listen((e) {
      if (e is BossHpEvent && e.bossId == bossId && !hp.isCompleted) hp.complete(e);
    });
    ws.subscribe('boss:$bossId');
    ws.start();
    for (var i = 0; i < 50 && ws.status != RealtimeStatus.connected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(ws.status, RealtimeStatus.connected);
    await Future<void>.delayed(const Duration(milliseconds: 300)); // let the sub land

    // A run: small loop (claim) inside the boss range, then a long U through
    // the range and over the on-track chest (~11 km, ~110 energy).
    final track = run([
      [cx, cy], [cx + 300, cy], [cx + 300, cy + 300], [cx + 150, cy + 300], [cx + 150, cy - 50],
      [cx + 150, cy - 100], [cx + 5000, cy - 100], [cx + 5000, cy - 40], [cx + 400, cy - 40],
    ], speed: 3.6, device: 'live-v2-$rnd');
    final res = await a.uploadActivity(track);
    expect(res.settlement.status, 'settled');
    expect(res.settlement.bossDamage.map((b) => b.bossId), contains(bossId));
    final dmg = res.settlement.bossDamage.firstWhere((b) => b.bossId == bossId).damage;
    expect(dmg, greaterThan(100));
    expect(res.settlement.chests, isNotEmpty, reason: 'the run passes over a chest');
    // The run's own damage is pushed live.
    final ev = await hp.future.timeout(const Duration(seconds: 5));
    expect(ev.hp, lessThan(10000));

    boss = await a.boss(bossId);
    expect(boss.me.damage, dmg);
    expect(boss.rank.map((r) => r.damage), contains(dmg));

    // Strike from far away is refused; from inside the range it hits (if
    // the run earned enough energy) and then cools down.
    await expectLater(a.strike(bossId, at(cx + 9000, cy)),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'out_of_range')));
    try {
      final s = await a.strike(bossId, at(cx + 100, cy + 100));
      expect(s.damage, greaterThanOrEqualTo(40));
      expect(s.hp, lessThan(boss.hp));
      try {
        await a.strike(bossId, at(cx + 100, cy + 100));
        fail('second strike should cool down');
      } on ApiException catch (e) {
        expect(e.code, anyOf('cooldown', 'not_enough_energy'));
        if (e.code == 'cooldown') {
          expect(e.status, 429);
          expect(e.retryAfterS, greaterThan(0));
        }
      }
    } on ApiException catch (e) {
      expect(e.code, 'not_enough_energy');
    }
    expect(await a.engage(bossId, at(cx, cy)), isNotNull);

    // Chests: manual open in range; again → already_opened; far → out_of_range.
    final opened = await a.openChest(manualId, manual);
    expect(opened.energy, greaterThanOrEqualTo(20));
    await expectLater(a.openChest(manualId, manual),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'already_opened')));
    final third = await admin.post<Map<String, dynamic>>('/admin/v1/chests',
        data: {'lat': manual.lat, 'lng': manual.lng + 0.01, 'energy_min': 20, 'energy_max': 60, 'duration_h': 2, 'radius_m': 50});
    await expectLater(a.openChest((third.data!['id'] as num).toInt(), manual),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'out_of_range')));
    final after = await a.mapObjects(minLng: c0.lng - 0.05, minLat: c0.lat - 0.05, maxLng: c0.lng + 0.05, maxLat: c0.lat + 0.05);
    expect(after.chests.map((c) => c.id), isNot(contains(manualId)), reason: 'opened chests are hidden');

    // Season, league (needs a crew), campaigns, routes.
    final season = await a.season();
    if (season.season != null) {
      expect(season.tiers, isNotEmpty);
      expect(season.me.tier, isNotNull);
      expect(season.tasks, isNotEmpty);
      expect(season.medals, isNotEmpty);
    }
    final crew = await a.createCrew(name: '接力$rnd'.substring(0, 8), district: '徐汇区', joinMode: 'open');
    final league = await a.league();
    expect(league.district, '徐汇区');
    expect(league.weekStart, isNotEmpty);
    await a.campaigns();
    final routes = await a.routes();
    if (routes.isNotEmpty) {
      final r = await a.route(routes.first.id);
      expect(r.checkpoints.length, greaterThanOrEqualTo(2));
    }

    // Relay: leader starts one; a second is refused.
    expect(await a.currentRelay(crew.id), isNull);
    final relay = await a.startRelay(crew.id, legs: 2, legKm: 3);
    expect(relay.isRunning, isTrue);
    expect((await a.currentRelay(crew.id))!.id, relay.id);
    await expectLater(a.startRelay(crew.id, legs: 2, legKm: 3),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'relay_running')));

    // Codex: monsters + companion growth; feed if hatched.
    final codex = await a.codex();
    expect(codex.monsters.where((m) => m.key == 'sofa').single.seen, isTrue);
    final pet = codex.companions.where((c) => c.hatched).firstOrNull;
    if (pet != null) {
      try {
        final fed = await a.feedCompanion(pet.key);
        expect(fed.companions.firstWhere((c) => c.key == pet.key).exp, greaterThan(pet.exp));
      } on ApiException catch (e) {
        expect(e.code, 'not_enough_energy');
      }
    } else {
      await expectLater(a.feedCompanion('gecko'),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', anyOf('companion_not_hatched', 'not_enough_energy'))));
    }

    // Territory detail carries the (optional) defense field.
    final tid = res.settlement.claims.first.territoryId;
    expect((await a.territory(tid)).defense, isNull);

    await sub.cancel();
    await ws.dispose();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
