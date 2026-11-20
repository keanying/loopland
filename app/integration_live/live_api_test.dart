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

import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/errors.dart';
import 'package:loopland/api/loopland_api.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/claim/claim.dart';
import 'package:loopland/claim/geo.dart';
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
    await expectLater(a.build(tid, 0, 'campfire'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'not_enough_energy')));

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
}
