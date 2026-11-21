// Method-aware, stateful fake of the 本地生活 · 订场 / 场馆 endpoints of
// docs/api/v2-4-本地生活与商户.md (venues, slots, check-in, bookings, the
// orders they pay through, a paid race). Plug into
// fakeBackend(handlers: [local.handle, gathering.handle]).
import 'package:dio/dio.dart';
import 'package:loopland/api/local_api.dart' show shanghaiDate;
import 'package:loopland/claim/geo.dart';

import 'fake_backend.dart' show origin;

typedef J = Map<String, dynamic>;

J _brief(int id, String name, {bool crew = false}) =>
    {'id': id, 'nickname': name, 'avatar_url': null, 'crew': crew ? {'id': 3, 'name': '城西跑团'} : null};

J _center(double dx, double dy) {
  final p = Projection(origin).inverse(Point(dx, dy));
  return {'lat': p.lat, 'lng': p.lng};
}

String _iso(DateTime t) => t.toUtc().toIso8601String();

class LocalFake {
  LocalFake({DateTime? now}) : now = now ?? _todayAt10() {
    _seed();
  }

  /// 10:00 today, Asia/Shanghai: every test sees the same slot grid.
  static DateTime _todayAt10() {
    final s = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTime.utc(s.year, s.month, s.day, 2);
  }

  /// The fake's clock (slots before it are not returned).
  final DateTime now;

  final calls = <String>[];
  final bodies = <String, Object?>{};

  final venues = <J>[];
  final bookings = <J>[];
  final orders = <String, J>{};
  late J race;

  /// `POST /v1/bookings` → 403 `realname_required` while false.
  bool realname = true;
  bool minor = false;

  /// `POST /v1/races/7/signup` includes `order` (not in the contract).
  bool raceOrderInResponse = true;
  int _next = 100;

  final yepao = _brief(21, '夜跑兔', crew: true);
  final kai = _brief(7, 'Kai');

  void _seed() {
    venues.addAll([
      {
        'id': 8, 'merchant': {'id': 3, 'name': '城南全民健身中心'}, 'name': '城南全民健身中心 · 匹克球',
        'sports': ['pickleball', 'badminton'], 'center': _center(40, 60), 'address': '徐汇区龙华中路 600 号', 'district': '徐汇区',
        'tags': ['室内', '可租拍'], 'cover_url': null, 'checkin_radius_m': 150, 'bookable': true,
        'price_amt': 6000, 'price_unit': 'hour',
        'owner': {'user': yepao, 'points': 120, 'since': '2026-11-17'}, 'owner_discount_rate': 0.8,
        'distance_m': 800, 'my_week_points': 30, 'checked_in_today': false,
        'week_rank': [
          {'rank': 1, 'user': kai, 'points': 70},
          {'rank': 2, 'user': _brief(1, '阿杰', crew: true), 'points': 30},
        ],
      },
      {
        'id': 9, 'merchant': {'id': 4, 'name': '东港运动公园'}, 'name': '东港运动公园 · 匹克球',
        'sports': ['pickleball', 'tennis'], 'center': _center(1200, -600), 'address': '', 'district': '浦东新区',
        'tags': ['室外', '夜场灯光'], 'cover_url': null, 'checkin_radius_m': 150, 'bookable': true,
        'price_amt': 4000, 'price_unit': 'hour',
        'owner': {'user': kai, 'points': 90, 'since': '2026-11-17'}, 'owner_discount_rate': null,
        'distance_m': 1600, 'my_week_points': 0, 'checked_in_today': false,
      },
      {
        'id': 10, 'merchant': null, 'name': '学府路体育馆 · 匹克球',
        'sports': ['pickleball', 'basketball'], 'center': _center(-2000, 1500), 'address': '', 'district': '徐汇区',
        'tags': ['室内', '学生价'], 'cover_url': null, 'checkin_radius_m': 150, 'bookable': true,
        'price_amt': 5000, 'price_unit': 'hour', 'owner': null, 'owner_discount_rate': null,
        'distance_m': 2900, 'my_week_points': 0, 'checked_in_today': false,
      },
      {
        'id': 11, 'merchant': null, 'name': '滨江攀岩馆', 'sports': ['climbing'], 'center': _center(300, -200),
        'address': '', 'district': '浦东新区', 'tags': ['室内'], 'cover_url': null, 'checkin_radius_m': 150, 'bookable': false,
        'price_amt': 0, 'price_unit': 'hour', 'owner': null, 'owner_discount_rate': null,
        'distance_m': 360, 'my_week_points': 10, 'checked_in_today': true,
      },
    ]);
    final start = now.add(const Duration(days: 2, hours: 8)); // day after tomorrow 18:00
    bookings.addAll([
      _booking(31, 8, start, 2, 'paid', amount: 9600, original: 12000, discount: 'owner'),
      _booking(32, 9, DateTime.now().add(const Duration(minutes: 70)), 1, 'paid', amount: 4000, original: 4000),
      _booking(33, 10, now.subtract(const Duration(days: 3)), 1, 'completed', amount: 5000, original: 5000),
    ]);
    race = {
      'id': 7, 'type': 'online', 'title': '冬日暖跑 5K', 'cover_url': null, 'description': '报名费含完赛奖牌邮寄。',
      'sport': 'run', 'distance_m': 5000,
      'start_time': _iso(DateTime.now().add(const Duration(days: 3))), 'end_time': _iso(DateTime.now().add(const Duration(days: 10))),
      'signup_end_time': _iso(DateTime.now().add(const Duration(days: 2))), 'place': null,
      'capacity': 2000, 'signed_count': 120, 'requires_wearable': false,
      'medal': {'key': 'race_warm_5k', 'name': '冬日暖跑奖牌', 'image_url': null},
      'status': 'signup', 'my_entry': null, 'fee_amt': 3900, 'leaderboard': <J>[],
    };
  }

  J _venue(int id) => venues.firstWhere((v) => v['id'] == id);

  J _booking(int id, int venueId, DateTime start, int slots, String status,
      {required int amount, required int original, String discount = 'none', int? meetupId, String channel = 'wechat_app'}) {
    final v = _venue(venueId);
    final no = 'LPBK$id';
    orders[no] = {'order_no': no, 'plan_code': '', 'amount_fen': amount, 'channel': channel, 'status': status == 'pending_pay' ? 'created' : 'paid'};
    return {
      'id': id, 'booking_no': 'BK20261121$id', 'venue': {'id': venueId, 'name': v['name']},
      'start_time': _iso(start), 'end_time': _iso(start.add(Duration(hours: slots))), 'court_qty': 1,
      'amount_amt': amount, 'original_amt': original, 'discount_type': discount, 'status': status, 'meetup_id': meetupId,
      'pay': {'order_no': no, 'channel': channel},
      'cancel_deadline': _iso(start.subtract(const Duration(hours: 2))), 'created_at': _iso(now.subtract(const Duration(hours: 1))),
    };
  }

  /// Hourly 07:00–22:00 (Asia/Shanghai) on [date]; 19:00 and 20:00 full.
  List<J> slotsFor(int venueId, String date) {
    final p = date.split('-').map(int.parse).toList();
    final v = _venue(venueId);
    final price = v['price_amt'] as int;
    final owner = (v['owner'] as Map?)?['user']?['id'] == 1;
    final rate = (v['owner_discount_rate'] as num?)?.toDouble();
    final out = <J>[];
    for (var h = 7; h <= 22; h++) {
      final start = DateTime.utc(p[0], p[1], p[2], h).subtract(const Duration(hours: 8));
      if (!start.isAfter(now)) continue;
      final taken = bookings.any((b) =>
          b['venue']['id'] == venueId &&
          (b['status'] == 'paid' || b['status'] == 'pending_pay') &&
          !DateTime.parse(b['start_time'] as String).isAfter(start) &&
          DateTime.parse(b['end_time'] as String).isAfter(start));
      out.add({
        'start_time': '${date}T${h.toString().padLeft(2, '0')}:00:00+08:00',
        'end_time': '${date}T${(h + 1).toString().padLeft(2, '0')}:00:00+08:00',
        'price_amt': price,
        'owner_price_amt': owner && rate != null ? (price * rate).round() : null,
        'available': h != 19 && h != 20 && !taken,
      });
    }
    return out;
  }

  static (int, Object?) _err(int status, String code, [String message = '']) =>
      (status, {'error': {'code': code, 'message': message}});

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

    if (m == 'GET' && p == '/v1/venues') {
      final sport = '${q['sport'] ?? ''}';
      final bookable = q['bookable'];
      final items = [
        for (final v in venues)
          if ((sport.isEmpty || (v['sports'] as List).contains(sport)) && (bookable == null || '${v['bookable']}' == '$bookable'))
            {...v}..remove('week_rank'),
      ]..sort((a, b) => (a['distance_m'] as num).compareTo(b['distance_m'] as num));
      return (200, {'items': items, 'next_cursor': null});
    }
    if (seg.length >= 4 && seg[2] == 'venues') {
      final id = idAt(3);
      if (id == null || !venues.any((v) => v['id'] == id)) return _err(404, 'not_found');
      final v = _venue(id);
      final sub = seg.length > 4 ? seg[4] : '';
      if (m == 'GET' && sub.isEmpty) return (200, v);
      if (m == 'GET' && sub == 'slots') {
        final date = '${q['date']}';
        return (200, {'date': date, 'items': slotsFor(id, date)});
      }
      if (m == 'POST' && sub == 'checkin') {
        if (v['checked_in_today'] == true) return _err(409, 'already_checked_in', '今天已经在这个场馆签到过了');
        final qr = body['qr'];
        if (qr != null) {
          if (qr != 'LPV.$id.sig-ok') return _err(400, 'checkin_not_allowed', '二维码无效或已更换，请扫描场馆现场的二维码');
        } else {
          final at = LatLng((body['lat'] as num).toDouble(), (body['lng'] as num).toDouble());
          final c = v['center'] as Map;
          final d = haversine(at, LatLng((c['lat'] as num).toDouble(), (c['lng'] as num).toDouble()));
          if (d > (v['checkin_radius_m'] as num)) {
            return _err(400, 'checkin_not_allowed', '你离场馆还有 ${d.round()} 米，需要在 ${v['checkin_radius_m']} 米内');
          }
        }
        v['checked_in_today'] = true;
        v['my_week_points'] = (v['my_week_points'] as int) + 10;
        return (200, {
          'activity_id': 120, 'energy': 20, 'points': 10, 'week_points': v['my_week_points'],
          'coupon': id == 8
              ? {
                  'id': 77, 'code': '8K2D9QXW',
                  'perk': {'title': '运动饮料兑换券', 'description': '', 'value_text': '饮料', 'valid_days': 7, 'rules': '到店出示'},
                  'merchant': {'id': 3, 'name': '城南全民健身中心'},
                  'source': {'type': 'stronghold', 'drop_id': 5, 'name': '据点 · 城南'},
                  'status': 'unused', 'obtained_at': _iso(DateTime.now()), 'expires_at': _iso(DateTime.now().add(const Duration(days: 7))),
                  'used_at': null, 'used_store': null,
                }
              : null,
          'venue': v,
        });
      }
    }

    if (m == 'POST' && p == '/v1/bookings') {
      if (!realname) return _err(403, 'realname_required', '订场前需要先完成实名认证');
      if (minor) return _err(403, 'minor_not_allowed', '');
      final v = _venue(body['venue_id'] as int);
      final start = DateTime.parse(body['start_time'] as String);
      final n = body['slots'] as int;
      if (n < 1 || n > 4) return _err(400, 'invalid_body', '连续 1–4 个时段');
      final day = shanghaiDate(start);
      final slots = slotsFor(v['id'] as int, day);
      var amount = 0, original = 0;
      for (var i = 0; i < n; i++) {
        final t = start.add(Duration(hours: i));
        final s = slots.where((x) => DateTime.parse(x['start_time'] as String).isAtSameMomentAs(t)).firstOrNull;
        if (s == null || s['available'] != true) return _err(409, 'slot_unavailable', '这个时段刚被订走了，换一个吧');
        amount += (s['owner_price_amt'] ?? s['price_amt']) as int;
        original += s['price_amt'] as int;
      }
      final channel = body['channel'] as String;
      final b = _booking(_next++, v['id'] as int, start, n, 'pending_pay',
          amount: amount, original: original, discount: amount < original ? 'owner' : 'none', meetupId: body['meetup_id'] as int?, channel: channel);
      bookings.insert(0, b);
      final params = switch (channel) {
        'wechat_app' => {'appid': 'wx1', 'partnerid': '1', 'prepayid': 'p', 'package': 'Sign=WXPay', 'noncestr': 'n', 'timestamp': '1', 'sign': 's'},
        'alipay_app' => {'order_string': 'alipay_sdk=1'},
        _ => <String, dynamic>{},
      };
      return (200, {'booking': b, 'pay_params': params});
    }
    if (m == 'GET' && p == '/v1/me/bookings') {
      final st = '${q['status'] ?? ''}';
      return (200, {'items': [for (final b in bookings) if (st.isEmpty || b['status'] == st) b]});
    }
    if (seg.length >= 4 && seg[2] == 'bookings') {
      final id = idAt(3);
      final b = bookings.where((x) => x['id'] == id).firstOrNull;
      if (b == null) return _err(404, 'not_found');
      if (m == 'GET' && seg.length == 4) return (200, b);
      if (m == 'POST' && seg.length == 5 && seg[4] == 'cancel') {
        if (DateTime.parse(b['start_time'] as String).difference(DateTime.now()) < const Duration(hours: 2)) {
          return _err(409, 'cancel_too_late', '开始前 2 小时内不能自助取消，如需退款请联系客服');
        }
        b['status'] = b['status'] == 'paid' ? 'refunding' : 'cancelled';
        return (200, b);
      }
    }

    // Orders behind bookings / the race fee. WeChat / Alipay "callbacks"
    // arrive by the first poll.
    if (seg.length == 4 && seg[2] == 'orders' && m == 'GET') {
      final o = orders[seg[3]];
      if (o == null) return null;
      if (o['channel'] != 'mock') _markPaid(seg[3]);
      return (200, o);
    }
    if (seg.length == 6 && seg[2] == 'dev' && seg[3] == 'orders' && m == 'POST') {
      if (!orders.containsKey(seg[4])) return null;
      _markPaid(seg[4]);
      return (200, orders[seg[4]]);
    }

    // A paid race (D-12).
    if (p == '/v1/races/7') return m == 'GET' ? (200, race) : null;
    if (p == '/v1/races/7/signup') {
      if (m == 'POST') {
        if (!realname) return _err(403, 'realname_required', '');
        final channel = '${body['channel'] ?? ''}';
        if (channel.isEmpty) return _err(400, 'invalid_body', '收费赛事需要选择支付方式');
        orders['LPRACE7'] = {'order_no': 'LPRACE7', 'plan_code': '', 'amount_fen': 3900, 'channel': channel, 'status': 'created'};
        race['my_entry'] = {'status': 'pending_pay', 'result_sec': null, 'finished_at': null, 'rank': null};
        return (200, {
          'race': race,
          'pay_params': channel == 'wechat_app' ? {'appid': 'wx1', 'prepayid': 'p'} : <String, dynamic>{},
          if (raceOrderInResponse) 'order': orders['LPRACE7'],
        });
      }
      if (m == 'DELETE') {
        race['my_entry'] = null;
        race['signed_count'] = (race['signed_count'] as int) - 1;
        return (200, race);
      }
    }
    return null;
  }

  void _markPaid(String no) {
    final o = orders[no]!;
    if (o['status'] == 'paid') return;
    o['status'] = 'paid';
    for (final b in bookings) {
      if ((b['pay'] as Map)['order_no'] == no && b['status'] == 'pending_pay') b['status'] = 'paid';
    }
    if (no == 'LPRACE7' && race['my_entry'] != null) {
      race['my_entry'] = {...race['my_entry'] as Map, 'status': 'signed'};
      race['signed_count'] = (race['signed_count'] as int) + 1;
    }
  }
}
