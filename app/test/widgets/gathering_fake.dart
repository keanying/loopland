// Method-aware, stateful fake of the gatherings & messages endpoints of
// docs/api/v2-2-社区.md: community home, inbox summary, conversations and
// messages, meetups, rallies, races, crew invites / editing.
// Plug into fakeBackend(handlers: [fake.handle]).
import 'package:dio/dio.dart';
import 'package:loopland/claim/geo.dart';

import 'fake_backend.dart' show origin;

typedef J = Map<String, dynamic>;

J _brief(int id, String name, {bool crew = false}) =>
    {'id': id, 'nickname': name, 'avatar_url': null, 'crew': crew ? {'id': 3, 'name': '城西跑团'} : null};

final gMe = _brief(1, '阿杰', crew: true);
final gDeer = _brief(8, '小鹿', crew: true);
final gKai = _brief(7, 'Kai');
final gZhen = _brief(11, '阿珍');

String _at(Duration d) => DateTime.now().add(d).toUtc().toIso8601String();

/// A point [dx], [dy] metres from the test origin.
J placeAt(String name, double dx, double dy) {
  final p = Projection(origin).inverse(Point(dx, dy));
  return {'name': name, 'lat': p.lat, 'lng': p.lng};
}

class GatheringFake {
  GatheringFake() {
    _seed();
  }

  /// Every request, as "METHOD /path".
  final calls = <String>[];

  /// Request bodies by "METHOD /path" (last one).
  final bodies = <String, Object?>{};

  late J home;
  final convs = <J>[];
  final messages = <int, List<J>>{};
  final meetups = <J>[];
  final rallies = <J>[];
  final races = <J>[];
  late J crew;
  int _nextId = 1000;
  int strangerSent = 0;

  void _seed() {
    crew = {
      'id': 3, 'name': '城西跑团', 'avatar_url': null, 'district': '徐汇区', 'join_mode': 'open',
      'leader': {'id': 1, 'nickname': '阿杰'}, 'member_count': 12, 'territory_count': 30, 'territory_area_m2': 1203300,
      'my_role': 'leader', 'week_rank': <J>[],
    };
    meetups.addAll([
      {
        'id': 8, 'type': 'run', 'title': '周六世纪公园约跑', 'description': '配速 6 分左右，跑 10 公里，跑完一起吃早饭',
        'start_time': _at(const Duration(days: 1, hours: 2)), 'end_time': _at(const Duration(days: 1, hours: 4)),
        'place': placeAt('世纪公园 3 号门', 300, 200), 'district': '浦东新区',
        'capacity': 10, 'joined_count': 3, 'requirement': '配速 5\'30"–6\'30"',
        'creator': gDeer, 'status': 'open', 'review_status': 'approved', 'joined': false, 'conversation_id': 4,
        'distance_m': null, 'created_at': _at(const Duration(hours: -3)),
        'members': [gDeer, gKai, gZhen],
      },
      {
        'id': 9, 'type': 'ball', 'title': '匹克球双打 · 还差 2 人', 'description': '2.5 级左右',
        'start_time': _at(const Duration(hours: 5)), 'end_time': _at(const Duration(hours: 7)),
        'place': placeAt('城南全民健身中心', -800, -300), 'district': '徐汇区',
        'capacity': 4, 'joined_count': 2, 'requirement': '2.5 级左右',
        'creator': gKai, 'status': 'open', 'review_status': 'approved', 'joined': false, 'conversation_id': 5,
        'distance_m': null, 'created_at': _at(const Duration(hours: -1)),
      },
      {
        'id': 10, 'type': 'ride', 'title': '滨江夜骑 30 公里', 'description': '',
        'start_time': _at(const Duration(days: 2)), 'end_time': _at(const Duration(days: 2, hours: 2)),
        'place': placeAt('滨江大道', 1500, 0), 'district': '浦东新区',
        'capacity': 8, 'joined_count': 8, 'requirement': '',
        'creator': gZhen, 'status': 'full', 'review_status': 'approved', 'joined': false, 'conversation_id': null,
        'distance_m': null, 'created_at': _at(const Duration(hours: -6)),
      },
    ]);
    rallies.addAll([
      {
        'id': 5, 'crew': {'id': 3, 'name': '城西跑团'}, 'creator': gMe, 'title': '周三夜跑',
        'start_time': _at(const Duration(minutes: 20)), 'place': placeAt('徐家汇公园', 50, 40), 'distance_goal_m': 5000,
        'status': 'open', 'joined_count': 6, 'checked_in_count': 1, 'joined': true, 'checked_in': false,
        'bonus_active': false, 'conversation_id': 9, 'created_at': _at(const Duration(days: -1)),
      },
      {
        'id': 6, 'crew': {'id': 3, 'name': '城西跑团'}, 'creator': gMe, 'title': '周末长距离',
        'start_time': _at(const Duration(days: 3)), 'place': placeAt('滨江公园', 3000, 3000), 'distance_goal_m': 10000,
        'status': 'open', 'joined_count': 4, 'checked_in_count': 0, 'joined': false, 'checked_in': false,
        'bonus_active': false, 'conversation_id': 10, 'created_at': _at(const Duration(days: -1)),
      },
    ]);
    races.addAll([
      {
        'id': 2, 'type': 'online', 'title': '城市 10K 线上赛', 'cover_url': null,
        'description': '冬季城市跑，跑完领限定奖牌。', 'sport': 'run', 'distance_m': 10000,
        'start_time': _at(const Duration(days: -1)), 'end_time': _at(const Duration(days: 6)),
        'signup_end_time': _at(const Duration(days: 5)), 'place': null,
        'capacity': 5000, 'signed_count': 1200, 'requires_wearable': true,
        'medal': {'key': 'race_2026_city10k', 'name': '城市 10K 完赛奖牌', 'image_url': null},
        'status': 'signup', 'my_entry': null,
        'leaderboard': [
          {'rank': 1, 'user': gKai, 'result_sec': 2400},
          {'rank': 2, 'user': gDeer, 'result_sec': 2580},
        ],
      },
      {
        'id': 3, 'type': 'offline', 'title': '滨江半程马拉松', 'cover_url': null, 'description': '',
        'sport': 'run', 'distance_m': 21097,
        'start_time': _at(const Duration(days: 20)), 'end_time': _at(const Duration(days: 20, hours: 4)),
        'signup_end_time': _at(const Duration(days: -1)), 'place': placeAt('滨江大道起点', 0, 0),
        'capacity': 3000, 'signed_count': 3000, 'requires_wearable': false, 'medal': null,
        'status': 'upcoming', 'my_entry': {'status': 'signed', 'result_sec': null, 'finished_at': null, 'rank': null},
      },
      {
        'id': 4, 'type': 'online', 'title': '秋季 5K', 'cover_url': null, 'description': '', 'sport': 'run', 'distance_m': 5000,
        'start_time': _at(const Duration(days: -30)), 'end_time': _at(const Duration(days: -20)),
        'signup_end_time': _at(const Duration(days: -31)), 'place': null, 'capacity': 0, 'signed_count': 800,
        'requires_wearable': false, 'medal': {'key': 'race_5k', 'name': '秋季 5K 奖牌', 'image_url': null},
        'status': 'finished',
        'my_entry': {'status': 'finished', 'result_sec': 1650, 'finished_at': _at(const Duration(days: -25)), 'rank': 35},
        'leaderboard': [
          {'rank': 1, 'user': gKai, 'result_sec': 1200},
          {'rank': 35, 'user': gMe, 'result_sec': 1650},
        ],
      },
    ]);
    J msg(int id, int conv, J? sender, String type, String content, {J payload = const {}, Duration ago = Duration.zero}) => {
          'id': id, 'conversation_id': conv, 'sender': sender, 'type': type, 'content': content, 'payload': payload,
          'created_at': _at(-ago),
        };
    messages[4] = [
      msg(77, 4, gDeer, 'text', '周六 06:50 东门集合', ago: const Duration(minutes: 3)),
      msg(76, 4, gKai, 'post', '', payload: {'post_id': 101}, ago: const Duration(minutes: 20)),
      msg(75, 4, null, 'system', 'Kai 加入了群聊', ago: const Duration(minutes: 40)),
      msg(74, 4, gMe, 'text', '我带两瓶水', ago: const Duration(hours: 2)),
    ];
    messages[6] = [
      for (var i = 0; i < 30; i++)
        msg(300 - i, 6, i.isEven ? gKai : gMe, 'text', i == 0 ? '桥下那条线你跑过吗' : '第 ${30 - i} 条', ago: Duration(minutes: 10 + i * 7)),
      // Older page (before=271).
    ];
    messages[-6] = [
      for (var i = 0; i < 5; i++) msg(270 - i, 6, gKai, 'text', '更早的第 ${5 - i} 条', ago: Duration(hours: 10 + i)),
    ];
    convs.addAll([
      {
        'id': 4, 'type': 'group', 'title': '周六世纪公园约跑', 'avatar_url': null, 'peer': null,
        'ref': {'type': 'meetup', 'id': 8}, 'last_message': messages[4]!.first, 'unread_count': 2, 'muted': false,
        'updated_at': _at(const Duration(minutes: -3)),
      },
      {
        'id': 6, 'type': 'direct', 'title': 'Kai', 'avatar_url': null, 'peer': gKai, 'ref': null,
        'last_message': messages[6]!.first, 'unread_count': 1, 'muted': false, 'updated_at': _at(const Duration(minutes: -10)),
      },
      {
        'id': 9, 'type': 'group', 'title': '周三夜跑', 'avatar_url': null, 'peer': null, 'ref': {'type': 'rally', 'id': 5},
        'last_message': null, 'unread_count': 0, 'muted': true, 'updated_at': _at(const Duration(days: -1)),
      },
    ]);
    home = {
      'crew': {'id': 3, 'name': '城西跑团', 'avatar_url': null, 'member_count': 12, 'week_area_m2': 50000, 'my_rank': 2},
      'unread': {'interaction': 3, 'chat': 5},
      'rallies': [rallies.first],
      'meetups': [
        {...meetups.first, 'joined': true},
      ],
      'races': [races.first],
    };
  }

  final inboxItems = <J>[
    {
      'id': 31, 'category': 'interaction', 'title': 'Kai 赞了你的动态', 'body': '夜袭滨江！31 分钟连圈 3 块…',
      'data': {'type': 'like_post', 'post_id': 101, 'user_id': 7}, 'read': false, 'created_at': _at(const Duration(minutes: -5)),
    },
    {
      'id': 32, 'category': 'interaction', 'title': '阿珍 关注了你', 'body': '',
      'data': {'type': 'follow', 'user_id': 11}, 'read': false, 'created_at': _at(const Duration(minutes: -30)),
    },
    {
      'id': 33, 'category': 'territory', 'title': '领地警报 西岸草坪 被「城西跑团」夺走', 'body': '',
      'data': {'territory_id': 101}, 'read': false, 'created_at': _at(const Duration(hours: -1)),
    },
    {
      'id': 34, 'category': 'monster', 'title': '沙发怪出现在你附近', 'body': '叫上团友一起合击',
      'data': {'boss_id': 3}, 'read': true, 'created_at': _at(const Duration(hours: -2)),
    },
    {
      'id': 35, 'category': 'system', 'title': '城市 10K 线上赛 完赛！', 'body': '获得「城市 10K 完赛奖牌」',
      'data': {'type': 'race_finished', 'race_id': 2}, 'read': true, 'created_at': _at(const Duration(days: -1)),
    },
  ];

  J _summary() {
    int n(String c) => inboxItems.where((i) => i['category'] == c && i['read'] == false).length;
    return {
      'interaction': n('interaction'),
      'territory': n('territory'),
      'monster': n('monster'),
      'system': n('system'),
      'chat': convs.fold<int>(0, (s, c) => s + (c['unread_count'] as int)),
    };
  }

  static (int, Object?) _err(int status, String code, [String message = '']) =>
      (status, {'error': {'code': code, 'message': message}});

  J _byId(List<J> l, int id) => l.firstWhere((x) => x['id'] == id);

  (int, Object?)? handle(RequestOptions o) {
    final p = o.path;
    final m = o.method;
    final key = '$m $p';
    final body = o.data is Map ? (o.data as Map).cast<String, dynamic>() : <String, dynamic>{};
    final q = o.queryParameters;
    final r = _route(m, p, body, q);
    if (r != null) {
      calls.add(key);
      bodies[key] = o.data is Map ? body : o.data;
    }
    return r;
  }

  (int, Object?)? _route(String m, String p, J body, Map<String, dynamic> q) {
    final seg = p.split('/');
    int? idAt(int i) => seg.length > i ? int.tryParse(seg[i]) : null;

    if (m == 'GET' && p == '/v1/community/home') return (200, home);
    if (m == 'GET' && p == '/v1/inbox/summary') return (200, _summary());
    if (m == 'GET' && p == '/v1/inbox') {
      final cat = '${q['category'] ?? 'all'}';
      final items = [for (final i in inboxItems) if (cat == 'all' || i['category'] == cat) i];
      return (200, {'items': items, 'total': items.length, 'unread': inboxItems.where((i) => i['read'] == false).length});
    }
    if (m == 'POST' && p == '/v1/inbox/read') {
      final ids = (body['ids'] as List?)?.cast<int>() ?? const [];
      for (final i in inboxItems) {
        if (body['all'] == true || ids.contains(i['id'])) i['read'] = true;
      }
      return (200, {'unread': inboxItems.where((i) => i['read'] == false).length});
    }

    // ── conversations ──
    if (m == 'GET' && p == '/v1/conversations') return (200, {'items': convs, 'next_cursor': null});
    if (m == 'GET' && seg.length == 4 && seg[2] == 'conversations' && seg[3] != 'direct') {
      final c = convs.where((c) => '${c['id']}' == seg[3]).firstOrNull;
      return c == null ? _err(404, 'not_found', '会话不存在') : (200, c);
    }
    if (m == 'POST' && p == '/v1/conversations/direct') {
      final uid = body['user_id'];
      if (uid == 66) return _err(403, 'blocked', '对方已把你拉黑，无法私信');
      final ex = convs.where((c) => (c['peer'] as Map?)?['id'] == uid).firstOrNull;
      if (ex != null) return (200, ex);
      final c = {
        'id': 20, 'type': 'direct', 'title': '阿珍', 'avatar_url': null, 'peer': gZhen, 'ref': null, 'last_message': null,
        'unread_count': 0, 'muted': false, 'updated_at': _at(Duration.zero),
      };
      convs.insert(0, c);
      messages[20] = [];
      return (200, c);
    }
    if (seg.length >= 4 && seg[2] == 'conversations') {
      final id = idAt(3);
      if (id == null) return null;
      final sub = seg.length > 4 ? seg[4] : '';
      if (m == 'GET' && sub == 'messages') {
        final before = q['before'];
        if (before != null) return (200, {'items': messages[-id] ?? const [], 'next_cursor': null});
        final list = messages[id] ?? const [];
        return (200, {'items': list, 'next_cursor': id == 6 ? '${list.last['id']}' : null});
      }
      if (m == 'POST' && sub == 'messages') {
        final text = '${body['content'] ?? ''}';
        if (text.contains('加我微信')) return _err(400, 'content_blocked', '消息包含联系方式，未发送');
        if (id == 20) {
          strangerSent++;
          if (strangerSent > 3) return _err(403, 'stranger_limit', '对方回复前最多发 3 条消息');
        }
        final msg = {
          'id': _nextId++, 'conversation_id': id, 'sender': gMe, 'type': body['type'] ?? 'text', 'content': text,
          'payload': body['type'] == 'image' ? {'url': 'https://cdn.test/chat/1.jpg', 'width': 800, 'height': 600} : <String, dynamic>{},
          'created_at': _at(Duration.zero),
        };
        (messages[id] ??= []).insert(0, msg);
        return (200, msg);
      }
      if (m == 'POST' && sub == 'read') {
        final c = convs.where((c) => c['id'] == id).firstOrNull;
        if (c != null) c['unread_count'] = 0;
        return (200, <String, dynamic>{});
      }
      if (m == 'POST' && sub == 'mute') {
        _byId(convs, id)['muted'] = body['muted'];
        return (200, <String, dynamic>{});
      }
      if (m == 'DELETE' && sub.isEmpty) {
        convs.removeWhere((c) => c['id'] == id);
        return (200, <String, dynamic>{});
      }
    }

    // ── meetups ──
    if (m == 'GET' && p == '/v1/meetups') {
      final type = '${q['type'] ?? ''}';
      final near = q['lat'] != null;
      final items = [
        for (final x in meetups)
          if (type.isEmpty || x['type'] == type) {...x, 'distance_m': near ? 400.0 + (x['id'] as int) * 350 : null},
      ];
      return (200, {'items': items, 'next_cursor': null});
    }
    if (m == 'GET' && p == '/v1/me/meetups') {
      return (200, {'items': [for (final x in meetups) if (x['joined'] == true) x]});
    }
    if (m == 'POST' && p == '/v1/meetups') {
      final x = {
        ...body, 'id': 50, 'district': '徐汇区', 'joined_count': 1, 'creator': gMe, 'status': 'open',
        'review_status': '${body['description']}'.contains('联系') ? 'pending' : 'approved', 'joined': true,
        'conversation_id': 51, 'distance_m': null, 'created_at': _at(Duration.zero), 'members': [gMe],
      };
      meetups.insert(0, x);
      return (200, x);
    }
    if (seg.length >= 4 && seg[2] == 'meetups') {
      final id = idAt(3);
      if (id == null) return null;
      final x = meetups.where((e) => e['id'] == id).firstOrNull;
      if (x == null) return _err(404, 'not_found');
      final sub = seg.length > 4 ? seg[4] : '';
      if (m == 'GET' && sub.isEmpty) return (200, x);
      if (m == 'POST' && sub == 'join') {
        if (x['status'] == 'full') return _err(409, 'meetup_full', '这个局已经满员了');
        x['joined'] = true;
        x['joined_count'] = (x['joined_count'] as int) + 1;
        (x['members'] as List?)?.add(gMe);
        return (200, x);
      }
      if (m == 'POST' && sub == 'leave') {
        x['joined'] = false;
        x['joined_count'] = (x['joined_count'] as int) - 1;
        return (200, x);
      }
      if (m == 'POST' && sub == 'cancel') {
        x['status'] = 'cancelled';
        return (200, x);
      }
    }

    // ── rallies ──
    if (m == 'GET' && p == '/v1/crews/3/rallies') return (200, {'items': rallies});
    if (m == 'POST' && p == '/v1/crews/3/rallies') {
      final x = {
        ...body, 'id': 60, 'crew': {'id': 3, 'name': '城西跑团'}, 'creator': gMe, 'status': 'open', 'joined_count': 1,
        'checked_in_count': 0, 'joined': true, 'checked_in': false, 'bonus_active': false, 'conversation_id': 61,
        'created_at': _at(Duration.zero),
      };
      rallies.insert(0, x);
      return (200, x);
    }
    if (seg.length >= 5 && seg[2] == 'rallies') {
      final x = _byId(rallies, idAt(3)!);
      switch (seg[4]) {
        case 'join':
          x['joined'] = true;
          x['joined_count'] = (x['joined_count'] as int) + 1;
        case 'leave':
          x['joined'] = false;
          x['joined_count'] = (x['joined_count'] as int) - 1;
        case 'cancel':
          x['status'] = 'cancelled';
        case 'checkin':
          final place = x['place'] as J;
          final d = haversine(LatLng((body['lat'] as num).toDouble(), (body['lng'] as num).toDouble()),
              LatLng((place['lat'] as num).toDouble(), (place['lng'] as num).toDouble()));
          if (d > 300) return _err(400, 'checkin_not_allowed', '离集合点还有 ${d.round()} 米，走到 300 米内再签到');
          x['checked_in'] = true;
          x['checked_in_count'] = (x['checked_in_count'] as int) + 1;
          x['bonus_active'] = (x['checked_in_count'] as int) >= 2;
      }
      return (200, x);
    }

    // ── races ──
    if (m == 'GET' && p == '/v1/races') {
      final st = '${q['status'] ?? ''}';
      return (200, {
        'items': [for (final r in races) if (st.isEmpty || r['status'] == st) r],
        'next_cursor': null,
      });
    }
    if (seg.length >= 4 && seg[2] == 'races') {
      final x = _byId(races, idAt(3)!);
      if (seg.length == 4 && m == 'GET') return (200, x);
      if (seg.length == 5 && seg[4] == 'signup') {
        if (m == 'POST') {
          x['my_entry'] = {'status': 'signed', 'result_sec': null, 'finished_at': null, 'rank': null};
          x['signed_count'] = (x['signed_count'] as int) + 1;
        } else {
          x['my_entry'] = null;
          x['signed_count'] = (x['signed_count'] as int) - 1;
        }
        return (200, x);
      }
    }

    // ── crews ──
    if (m == 'GET' && p == '/v1/crews/3') return (200, crew);
    if (m == 'GET' && p == '/v1/crews/3/members') {
      return (200, {
        'items': [
          {'user': gMe, 'role': 'leader', 'joined_at': _at(const Duration(days: -30))},
          {'user': gDeer, 'role': 'member', 'joined_at': _at(const Duration(days: -10))},
        ]
      });
    }
    if (m == 'POST' && p == '/v1/crews/3/invites') return (200, {'code': '8K2D9Q', 'expires_at': _at(const Duration(days: 7))});
    if (m == 'POST' && p == '/v1/crews/join-by-code') {
      return body['code'] == '8K2D9Q' ? (200, {'status': 'joined', 'crew_id': 3}) : _err(400, 'invalid_invite', '邀请码无效或已过期');
    }
    if (m == 'PATCH' && p == '/v1/crews/3') {
      crew = {...crew, ...body};
      if (body['avatar_id'] != null) crew['avatar_url'] = 'https://cdn.test/crew_avatar/1.jpg';
      return (200, crew);
    }
    if (m == 'POST' && p == '/v1/media') {
      return (200, {'id': 12, 'url': 'https://cdn.test/chat/1.jpg', 'width': 800, 'height': 600});
    }
    return null;
  }
}
