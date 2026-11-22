// 本地生活 · 场馆 / 签到 / 订场 / 约球订场 / 赛事报名费 API layer
// (lib/api/local_api.dart, GatheringApi.signupPaidRace) against a live dev
// backend, paying with the `mock` channel + POST /v1/dev/orders/{no}/pay.
//
//   LOOPLAND_LIVE_API=http://localhost:8080 flutter test integration_live/local_live_test.dart
//
// The backend must run with LOOPLAND_ENV=dev (SMS code 000000, mock pay) and
// the bootstrap admin looproot:LoopRoot101011! (to create venues and a race).
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/errors.dart';
import 'package:loopland/api/gathering_api.dart';
import 'package:loopland/api/gathering_models.dart';
import 'package:loopland/api/local_api.dart';
import 'package:loopland/api/local_models.dart';
import 'package:loopland/api/loopland_api.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/claim/geo.dart';
import 'package:loopland/pay/payment_service.dart';

import 'live_api_test.dart' show idNumber;

const origin = LatLng(31.2304, 121.4737);

Matcher apiError(String code) => throwsA(isA<ApiException>().having((e) => e.code, 'code', code));

class Session {
  Session(this.c) : api = LooplandApi(c), local = LocalApi(c), g = GatheringApi(c);
  final ApiClient c;
  final LooplandApi api;
  final LocalApi local;
  final GatheringApi g;
}

void main() {
  final base = Platform.environment['LOOPLAND_LIVE_API'];
  final skip = base == null ? 'set LOOPLAND_LIVE_API to run' : false;
  final rnd = math.Random().nextInt(90000000) + 10000000;

  Future<Session> login(String phone, {String platform = 'android'}) async {
    final s = Session(ApiClient(tokens: MemoryTokenStore(), baseUrl: base, platform: platform));
    await s.api.sendSms(phone);
    await s.api.login('sms', {'phone': phone, 'code': '000000'});
    await s.api.setConsents(privacyVersion: '2026-11', location: true, health: true);
    return s;
  }

  test('venues, check-in (location / QR), booking + mock pay + cancel, meetup booking, race fee', () async {
    final a = await login('135$rnd', platform: 'ios'); // iOS also books with non-IAP channels
    final b = await login('134$rnd');
    final dx = rnd % 50 * 1000.0 + 120000;
    final at = Projection(origin).inverse(Point(dx, 0));
    final far = Projection(origin).inverse(Point(dx + 3000, 0));

    final admin = Dio(BaseOptions(baseUrl: base!, contentType: 'application/json'));
    final al = await admin.post<Map<String, dynamic>>('/admin/v1/login', data: {'username': 'looproot', 'password': 'LoopRoot101011!'});
    admin.options.headers['Authorization'] = 'Bearer ${al.data!['token']}';
    final merchant = await admin.post<Map<String, dynamic>>('/admin/v1/merchants',
        data: {'name': '联调健身中心$rnd', 'type': 'venue', 'status': 'partner', 'contact_name': '王', 'contact_phone': '13800001111'});
    final venueRes = await admin.post<Map<String, dynamic>>('/admin/v1/venues', data: {
      'merchant_id': merchant.data!['id'],
      'name': '联调馆 $rnd · 匹克球',
      'sports': ['pickleball', 'badminton'],
      'center': {'lat': at.lat, 'lng': at.lng},
      'address': '联调路 1 号',
      'district': '徐汇区',
      'tags': ['室内'],
      'checkin_radius_m': 150,
      'bookable': true,
      'price_amt': 6000,
      'slot_minutes': 60,
      'open_time': '07:00',
      'close_time': '23:00',
      'court_qty': 1,
      'owner_discount_rate': 0.8,
    });
    final venueId = venueRes.data!['id'] as int;

    // ── 场馆列表 / 详情 ──
    final list = await a.local.venues(sport: 'pickleball', near: at, bookable: true);
    final v = list.items.firstWhere((x) => x.id == venueId);
    expect(v.bookable, isTrue);
    expect(v.priceAmt, 6000);
    expect(v.distanceM, lessThan(50));
    expect(v.owner, isNull);
    expect(v.discountText, '八折');
    final detail = await a.local.venue(venueId);
    expect(detail.name, '联调馆 $rnd · 匹克球');
    expect(detail.weekRank, isEmpty);

    // ── 签到：定位 / 太远 / 重复 / 扫码 ──
    final r1 = await a.local.checkin(venueId, at: at);
    expect(r1.energy, greaterThan(0));
    expect(r1.points, 10);
    expect(r1.weekPoints, 10);
    expect(r1.venue?.id, venueId);
    await expectLater(a.local.checkin(venueId, at: at), apiError('already_checked_in'));
    await expectLater(b.local.checkin(venueId, at: far), apiError('checkin_not_allowed'));
    final qr = await admin.get<Map<String, dynamic>>('/admin/v1/venues/$venueId/qr');
    final url = '${qr.data!['url']}';
    final parsed = parseVenueQr(url) ?? parseVenueQr('${qr.data!['payload']}');
    expect(parsed?.venueId, venueId, reason: 'admin QR: $url');
    final r2 = await b.local.checkin(venueId, qr: parsed!.payload);
    expect(r2.points, 10);
    await expectLater(b.local.checkin(venueId, qr: 'LPV.$venueId.forged'), apiError('checkin_not_allowed'));
    final ranked = await a.local.venue(venueId);
    expect(ranked.weekRank.map((e) => e.points), everyElement(10));
    expect(ranked.checkedInToday, isTrue);

    // ── 地图据点 ──
    final o = await a.api.mapObjects(minLng: at.lng - 0.01, minLat: at.lat - 0.01, maxLng: at.lng + 0.01, maxLat: at.lat + 0.01);
    expect(o.venues.map((x) => x.id), contains(venueId));

    // ── 订场 ──
    final tomorrow = shanghaiDate(DateTime.now().add(const Duration(days: 1)));
    final day = await a.local.slots(venueId, tomorrow);
    expect(day.items, isNotEmpty);
    expect(day.items.first.priceAmt, 6000);
    final s0 = day.items.firstWhere((s) => s.available);
    await expectLater(a.local.createBooking(venueId: venueId, startTime: s0.start, slots: 2, channel: 'mock'), apiError('realname_required'));
    await a.api.realname('张三', idNumber('19900307'));
    await expectLater(a.local.createBooking(venueId: venueId, startTime: s0.start, slots: 5, channel: 'mock'),
        throwsA(isA<ApiException>()));
    final created = await a.local.createBooking(venueId: venueId, startTime: s0.start, slots: 2, channel: 'mock');
    var bk = created.booking;
    expect(bk.status, 'pending_pay');
    expect(bk.amountAmt, 12000);
    expect(bk.orderNo, isNotNull);
    expect(bk.start!.isAtSameMomentAs(s0.start), isTrue);
    expect(bk.end!.difference(bk.start!), const Duration(hours: 2));
    final paid = await a.api.devPay(bk.orderNo!);
    expect(paid.isPaid, isTrue);
    bk = await a.local.booking(bk.id);
    expect(bk.status, 'paid');
    expect((await a.local.myBookings()).map((x) => x.id), contains(bk.id));
    final after = await b.local.slots(venueId, tomorrow);
    expect(after.items.firstWhere((s) => s.start.isAtSameMomentAs(s0.start)).available, isFalse);
    await b.api.realname('李四', idNumber('19920101'));
    await expectLater(b.local.createBooking(venueId: venueId, startTime: s0.start, slots: 1, channel: 'mock'), apiError('slot_unavailable'));
    final cancelled = await a.local.cancelBooking(bk.id);
    expect(cancelled.status, anyOf('refunding', 'refunded'));

    // ── 约球订场 ──
    final s1 = (await a.local.slots(venueId, tomorrow)).items.lastWhere((s) => s.available);
    final meetup = await a.g.createMeetup(MeetupDraft(
      type: 'ball',
      title: '联调匹克球',
      startTime: s1.start,
      endTime: s1.end,
      place: Place(name: '联调馆', lat: at.lat, lng: at.lng),
      capacity: 4,
    ));
    final mb = await a.local.createBooking(venueId: venueId, startTime: s1.start, slots: 1, channel: 'mock', meetupId: meetup.id);
    expect(mb.booking.meetupId, meetup.id);
    // The app's flow: PaymentService.payOrder (mock → dev pay → poll GET /v1/orders/{no}).
    final order = await PaymentService(a.api, pollInterval: const Duration(milliseconds: 200))
        .payOrder(mb.booking.orderNo!, 'mock', mb.payParams);
    expect(order.isPaid, isTrue);
    expect((await a.local.booking(mb.booking.id)).status, 'paid');
    final m2 = await b.g.meetup(meetup.id);
    expect(m2.booking?.venue?.id, venueId, reason: 'meetup detail shows the booked venue');
    expect(m2.booking?.start?.isAtSameMomentAs(s1.start), isTrue);

    // ── 赛事报名费 ──
    final now = DateTime.now().toUtc();
    final race = await admin.post<Map<String, dynamic>>('/admin/v1/races', data: {
      'type': 'online',
      'title': '付费 5K $rnd',
      'description': '联调',
      'sport': 'run',
      'distance_m': 5000,
      'start_time': now.add(const Duration(days: 2)).toIso8601String(),
      'end_time': now.add(const Duration(days: 3)).toIso8601String(),
      'signup_end_time': now.add(const Duration(days: 1)).toIso8601String(),
      'capacity': 100,
      'requires_wearable': false,
      'fee_amt': 3900,
      'published': true,
    });
    final raceId = race.data!['id'] as int;
    expect((await a.g.race(raceId)).feeAmt, 3900);
    final su = await a.g.signupPaidRace(raceId, 'mock');
    expect(su.race.myEntry?.status, 'pending_pay');
    expect(su.orderNo, isNotNull, reason: 'order number (my_entry.order_no) needed to pay');
    await a.api.devPay(su.orderNo!);
    var r = await a.g.race(raceId);
    expect(r.myEntry?.status, 'signed');
    r = await a.g.cancelRaceSignup(raceId);
    expect(r.myEntry, isNull);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
