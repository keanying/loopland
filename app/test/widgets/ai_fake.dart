// Stateful fake of the V2 batch 3「AI」App endpoints (docs/api/v2-3-AI.md):
// info, greeting, history, chat (JSON and SSE streaming), routes, battle
// reports. Plug in with
//   fakeBackend(handlers: [ai.handle], wrapAdapter: ai.adapter)
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:loopland/claim/geo.dart';

import 'fake_backend.dart' show origin;

typedef J = Map<String, dynamic>;

/// `[lng, lat]` points of a loop around [origin] (metres offsets).
List<List<double>> loopLine({double r = 600, int n = 24}) {
  final p = Projection(origin);
  return [
    for (var i = 0; i <= n; i++)
      () {
        final a = i / n * 2 * math.pi;
        final ll = p.inverse(Point(r * 1.3 * math.cos(a), r * math.sin(a) + 120 * math.sin(3 * a)));
        return [ll.lng, ll.lat];
      }(),
  ];
}

J aiRouteJson(String type, {String? id}) {
  final p = Projection(origin);
  final west = p.inverse(const Point(-380, -60));
  final boss = p.inverse(const Point(200, 260));
  return switch (type) {
    'capture' => {
        'id': id ?? 'r_capture',
        'type': 'capture',
        'title': '夺回 西岸草坪',
        'subtitle': '「城西跑团」占领 · 守卫值 42，较易夺回',
        'reason': '西岸草坪守卫值只剩 42，你这周能量够一次拿下，绕它跑一圈约 18 分钟。',
        'distance_m': 3100,
        'est_duration_sec': 1100,
        'est_area_m2': 90000,
        'waypoints': [
          {'lat': origin.lat, 'lng': origin.lng},
          {'lat': west.lat, 'lng': west.lng},
        ],
        'polyline': [
          [origin.lng, origin.lat],
          [west.lng + 0.002, west.lat + 0.001],
          [west.lng, west.lat],
          [west.lng - 0.001, west.lat - 0.0015],
          [origin.lng, origin.lat],
        ],
        'targets': [
          {'type': 'territory', 'id': 4, 'name': '西岸草坪', 'lat': west.lat, 'lng': west.lng, 'note': '「城西跑团」占领 · 守卫值 42，较易夺回'},
        ],
        'ai_generated': true,
      },
    'boss' => {
        'id': id ?? 'r_boss',
        'type': 'boss',
        'title': '顺路打 沙发怪',
        'subtitle': '沙发怪在云杉坡出没，还剩 3 小时',
        'reason': '跑进范围每公里造成 100 伤害。',
        'distance_m': 2600,
        'est_duration_sec': 960,
        'est_area_m2': 0,
        'waypoints': [],
        'polyline': [
          [origin.lng, origin.lat],
          [boss.lng, boss.lat],
        ],
        'targets': [
          {'type': 'boss', 'id': 3, 'name': '沙发怪', 'lat': boss.lat, 'lng': boss.lng, 'note': '剩余血量 38%'},
        ],
        'ai_generated': false,
      },
    _ => {
        'id': id ?? 'r_loop',
        'type': 'loop',
        'title': 'AI 推荐闭环',
        'subtitle': '绕滨江公园一圈，回到起点圈下约 0.4 km²',
        'reason': '你最近 5 公里配速 6\'10"，这一圈约 32 分钟，途经两块守卫值很低的地。',
        'distance_m': 5200,
        'est_duration_sec': 1920,
        'est_area_m2': 400000,
        'waypoints': [
          {'lat': origin.lat, 'lng': origin.lng},
        ],
        'polyline': loopLine(),
        'targets': [
          {'type': 'territory', 'id': 1, 'name': '滨江公园', 'lat': origin.lat - 0.001, 'lng': origin.lng, 'note': '我的领地 · 守卫值 68'},
        ],
        'ai_generated': true,
      },
  };
}

J aiMsg(int id, String role, String content, {List<J> cards = const [], String? image}) => {
      'id': id,
      'role': role,
      'content': content,
      'image_url': image,
      'cards': cards,
      'ai_generated': role == 'assistant',
      'created_at': DateTime.now().subtract(Duration(minutes: 100 - id)).toIso8601String(),
    };

J territoryCard() {
  final west = Projection(origin).inverse(const Point(-380, -60));
  return {
    'type': 'territory',
    'territory': {
      'id': 4,
      'name': '西岸草坪',
      'owner': {'id': 8, 'nickname': '小鹿'},
      'crew': {'id': 2, 'name': '城西跑团'},
      'guard': 42,
      'center': {'lat': west.lat, 'lng': west.lng},
    },
  };
}

J bossCard() => {
      'type': 'boss',
      'boss': {
        'id': 3,
        'name': '沙发怪',
        'hp': 1900,
        'max_hp': 5000,
        'center': {'lat': origin.lat + 0.002, 'lng': origin.lng + 0.002},
        'ends_at': DateTime.now().add(const Duration(hours: 3)).toIso8601String(),
      },
    };

/// SSE text for one answer: deltas, cards, done.
String sseAnswer(List<String> deltas, {List<J> cards = const [], required J done}) {
  final b = StringBuffer();
  for (final d in deltas) {
    b.write('event: delta\ndata: ${jsonEncode({'text': d})}\n\n');
  }
  for (final c in cards) {
    b.write('event: card\ndata: ${jsonEncode(c)}\n\n');
  }
  b.write('event: done\ndata: ${jsonEncode(done)}\n\n');
  return b.toString();
}

class AiFake {
  AiFake({this.enabled = true, this.vision = true, this.unlimited = false, this.remaining = 2, this.history = 0});

  bool enabled;
  bool vision;
  bool unlimited;
  int? remaining;

  /// Number of stored history messages (paged 30 at a time).
  int history;

  /// How `POST /v1/ai/chat` answers: `stream` (SSE), `json`, `manual`
  /// (test drives [sse]), or an error code (`ai_quota_exceeded`,
  /// `content_blocked`, `ai_unavailable` as SSE error event, …).
  String chatMode = 'stream';

  /// Answer text / cards for the next chat.
  List<String> deltas = ['往东绕滨江公园', '一圈，回到起点', '能圈下约 0.4 km²。'];
  List<J> cards = [
    {'type': 'route', 'route': aiRouteJson('loop')},
    territoryCard(),
    bossCard(),
  ];

  /// For `chatMode == 'manual'`: the test adds SSE chunks.
  StreamController<Uint8List>? sse;

  final chats = <J>[];
  final reports = <String>[];
  final posts = <J>[];
  int routesCalls = 0;
  int cleared = 0;
  int _nextId = 1000;
  int regenerateLeft = 2;
  int _reportVersion = 0;

  J get quota => {
        'unlimited': unlimited,
        'weekly_free': 3,
        'used': unlimited ? 0 : 3 - (remaining ?? 0),
        'remaining': unlimited ? null : remaining,
        'resets_at': '2026-11-23T16:00:00Z',
      };

  J infoJson() => {
        'enabled': enabled,
        'model_name': '通义千问',
        'registration_no': 'Beijing-XXXX-20240101',
        'vision': vision,
        'disclaimer': '内容由 AI 生成，仅供参考',
        'quota': quota,
      };

  J _done(String content) {
    final userId = _nextId++, botId = _nextId++;
    final last = chats.last;
    if (!unlimited && remaining != null) remaining = remaining! - 1;
    return {
      'message': aiMsg(botId, 'assistant', content, cards: cards),
      'user_message': aiMsg(userId, 'user', '${last['content']}', image: last['image_id'] == null ? null : '/media/chat.png'),
      'quota': quota,
    };
  }

  (int, Object?) _err(int status, String code, [String message = '']) => (status, {
        'error': {'code': code, 'message': message}
      });

  List<J> _history() => [
        for (var i = history; i >= 1; i--) aiMsg(i, i.isOdd ? 'user' : 'assistant', i.isOdd ? '历史问题 $i' : '历史回答 $i'),
      ];

  /// JSON endpoints (`fakeBackend(handlers: [ai.handle])`).
  (int, Object?)? handle(RequestOptions o) {
    final p = o.path, m = o.method;
    if (p == '/v1/config/features') {
      return (200, {
        'login': ['sms'],
        'pay': ['mock'],
        'captcha': false,
        'ai': enabled,
      });
    }
    if (p == '/v1/ai/info') return enabled ? (200, infoJson()) : _err(503, 'ai_unavailable');
    if (p == '/v1/ai/greeting') {
      return (200, {
        'text': '晚上好阿杰！今天你已经拿了 320 能量。\n「城西跑团」正在靠近滨江公园，要我帮你规划一条守地路线吗？',
        'suggestions': ['规划圈地路线', '今晚去哪抢地', '生成今日战报', '帮我排一周计划'],
        'ai_generated': false,
      });
    }
    if (p == '/v1/ai/messages' && m == 'DELETE') {
      cleared++;
      history = 0;
      return (200, <String, dynamic>{});
    }
    if (p == '/v1/ai/messages') {
      final all = _history();
      final before = int.tryParse('${o.queryParameters['before'] ?? ''}');
      final limit = int.tryParse('${o.queryParameters['limit'] ?? 30}') ?? 30;
      final from = before == null ? all : all.where((e) => (e['id'] as int) < before).toList();
      final page = from.take(limit).toList();
      final more = from.length > limit;
      return (200, {'items': page, 'next_cursor': more ? '${page.last['id']}' : null});
    }
    if (p == '/v1/ai/chat' && m == 'POST') {
      final body = (o.data as Map).cast<String, dynamic>();
      chats.add(body);
      if (chatMode != 'stream' && chatMode != 'json' && chatMode != 'manual') return _chatError();
      return (200, _done(deltas.join()));
    }
    if (p == '/v1/ai/routes') {
      routesCalls++;
      if (!enabled) return _err(503, 'ai_unavailable');
      return (200, {
        'items': [aiRouteJson('loop'), aiRouteJson('capture'), aiRouteJson('boss')],
        'ai_generated': true,
      });
    }
    final rep = RegExp(r'^/v1/activities/(\d+)/ai-report$').firstMatch(p);
    if (rep != null && m == 'POST') {
      final regen = '${o.queryParameters['regenerate']}' == '1';
      reports.add(regen ? 'regenerate' : 'get');
      if (!enabled) return _err(503, 'ai_unavailable');
      if (regen) {
        if (regenerateLeft <= 0) return _err(409, 'regenerate_limit', '这次运动的战报已经换过 2 次了');
        regenerateLeft--;
        _reportVersion++;
      }
      final texts = [
        '今晚 5.2 公里，配速 6\'05"，一口气圈下滨江两块地，西岸草坪的守卫只剩 42，下次顺手拿下！',
        '夜袭滨江！31 分钟连圈两块，配速稳得像节拍器，本周领地 +0.4 km²。',
        '又是一场漂亮的夜跑：5.2 km、两块新地，伙伴小蛙也长大了一点。',
      ];
      return (200, {
        'activity_id': int.parse(rep.group(1)!),
        'text': texts[_reportVersion % texts.length],
        'model_name': '通义千问',
        'ai_generated': true,
        'generated_at': DateTime.now().toIso8601String(),
        'regenerate_left': regenerateLeft,
      });
    }
    if (p == '/v1/media' && m == 'POST') return (200, {'id': 77, 'url': '/media/77.png', 'width': 1, 'height': 1});
    if (p == '/v1/posts' && m == 'POST') {
      posts.add((o.data as Map).cast<String, dynamic>());
      return null; // the community fake creates the post
    }
    return null;
  }

  (int, Object?) _chatError() => switch (chatMode) {
        'ai_quota_exceeded' => _err(429, 'ai_quota_exceeded', '本周免费次数已用完，开通会员不限次数'),
        'content_blocked' => _err(400, 'content_blocked', '内容包含不允许发布的信息，请修改后再试'),
        'ai_image_unsupported' => _err(400, 'ai_image_unsupported', '当前模型不支持图片'),
        'rate_limited' => _err(429, 'rate_limited', '操作太频繁，请稍后再试'),
        _ => _err(503, chatMode, 'AI 暂时不可用'),
      };

  /// SSE response for a streamed chat.
  ResponseBody sseResponse(RequestOptions o) {
    final body = (o.data as Map).cast<String, dynamic>();
    chats.add(body);
    ResponseBody json(int status, Object? data) => ResponseBody.fromString(jsonEncode(data), status, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
    const sseHeaders = {
      Headers.contentTypeHeader: ['text/event-stream; charset=utf-8'],
    };
    switch (chatMode) {
      case 'json':
        return json(200, _done(deltas.join()));
      case 'manual':
        sse = StreamController<Uint8List>();
        return ResponseBody(sse!.stream, 200, headers: sseHeaders);
      case 'ai_unavailable':
        // Streams an error event after the headers (model call failed).
        return ResponseBody(
            Stream.value(utf8.encode('event: error\ndata: {"code":"ai_unavailable","message":"AI 暂时不可用，请稍后再试"}\n\n')),
            200,
            headers: sseHeaders);
      case 'stream':
        final text = sseAnswer(deltas, cards: cards, done: _done(deltas.join()));
        // Split into odd-sized chunks (lines and UTF-8 sequences cut).
        final bytes = utf8.encode(text);
        final chunks = <Uint8List>[];
        for (var i = 0; i < bytes.length; i += 37) {
          chunks.add(Uint8List.fromList(bytes.sublist(i, i + 37 > bytes.length ? bytes.length : i + 37)));
        }
        return ResponseBody(Stream.fromIterable(chunks), 200, headers: sseHeaders);
      default:
        final (status, data) = _chatError();
        return json(status, data);
    }
  }

  /// Done event JSON for manual streams.
  J doneFor(String content) => _done(content);

  HttpClientAdapter adapter(HttpClientAdapter inner) => _SseAdapter(inner, this);
}

class _SseAdapter implements HttpClientAdapter {
  _SseAdapter(this.inner, this.fake);
  final HttpClientAdapter inner;
  final AiFake fake;

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    if (o.path == '/v1/ai/chat' && '${o.headers['Accept']}'.contains('text/event-stream')) {
      return fake.sseResponse(o);
    }
    return inner.fetch(o, body, cancel);
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
}
