import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/ai_api.dart';
import 'package:loopland/api/ai_models.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/community_models.dart';
import 'package:loopland/api/errors.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/core/features.dart';

/// Answers every request with [respond] (raw bytes / status / content type).
class _RawAdapter implements HttpClientAdapter {
  _RawAdapter(this.respond);
  final ResponseBody Function(RequestOptions o) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    requests.add(o);
    return respond(o);
  }

  @override
  void close({bool force = false}) {}
}

Stream<Uint8List> _chunks(String s, int size) {
  final b = utf8.encode(s);
  return Stream.fromIterable([
    for (var i = 0; i < b.length; i += size) Uint8List.fromList(b.sublist(i, i + size > b.length ? b.length : i + size)),
  ]);
}

const _sse = {
  Headers.contentTypeHeader: ['text/event-stream'],
};
const _json = {
  Headers.contentTypeHeader: [Headers.jsonContentType],
};

AiApi _api(ResponseBody Function(RequestOptions o) respond, [List<RequestOptions>? log]) {
  final a = _RawAdapter((o) {
    log?.add(o);
    return respond(o);
  });
  return AiApi(ApiClient(tokens: MemoryTokenStore(access: 'A'), baseUrl: 'http://x', adapter: a));
}

final _done = {
  'message': {
    'id': 32,
    'role': 'assistant',
    'content': '往东绕滨江公园一圈',
    'image_url': null,
    'cards': [
      {
        'type': 'route',
        'route': {
          'id': 'r_8f2c1a',
          'type': 'loop',
          'title': 'AI 推荐闭环',
          'distance_m': 5200,
          'est_duration_sec': 1920,
          'est_area_m2': 400000,
          'waypoints': [
            {'lat': 31.23, 'lng': 121.47}
          ],
          'polyline': [
            [121.47, 31.23],
            [121.48, 31.24]
          ],
          'targets': [
            {'type': 'territory', 'id': 12, 'name': '西岸草坪', 'lat': 31.2, 'lng': 121.4, 'note': '守卫值 42'}
          ],
          'ai_generated': true,
        }
      }
    ],
    'ai_generated': true,
    'created_at': '2026-11-21T12:00:00Z',
  },
  'user_message': {'id': 31, 'role': 'user', 'content': '今晚去哪抢地？', 'cards': [], 'ai_generated': false},
  'quota': {'unlimited': false, 'weekly_free': 3, 'used': 2, 'remaining': 1, 'resets_at': '2026-11-23T16:00:00Z'},
};

void main() {
  group('parseSse', () {
    test('events, multi-line data, comments, CRLF, split chunks and UTF-8', () async {
      const text = ': keep-alive\r\n'
          'event: delta\r\ndata: {"text":"往东"}\r\n\r\n'
          'event: delta\ndata: {"text":"绕滨江公园"}\n\n'
          'data: line1\ndata: line2\n\n'
          'id: 7\nretry: 100\nevent: done\ndata: {}\n';
      for (final size in [1, 3, 7, 64]) {
        final evs = await parseSse(_chunks(text, size)).toList();
        expect(evs.map((e) => e.event).toList(), ['delta', 'delta', 'message', 'done'], reason: 'chunk $size');
        expect(evs[0].data, '{"text":"往东"}');
        expect(evs[1].data, '{"text":"绕滨江公园"}');
        expect(evs[2].data, 'line1\nline2');
      }
    });

    test('aiChatEvents maps delta / card / done / error and stops after done', () async {
      final evs = await aiChatEvents(Stream.fromIterable(const [
        SseEvent('delta', '{"text":"往东"}'),
        SseEvent('ping', '{}'),
        SseEvent('card', '{"type":"boss","boss":{"id":5,"name":"沙发怪","hp":1200,"max_hp":5000}}'),
        SseEvent('delta', 'not json'),
        SseEvent('error', '{"code":"ai_unavailable","message":"挂了"}'),
        SseEvent('delta', '{"text":"never"}'),
      ])).toList();
      expect(evs, hasLength(3));
      expect((evs[0] as AIDelta).text, '往东');
      final card = (evs[1] as AICardEvent).card;
      expect(card.type, 'boss');
      expect(card.boss!.hpFraction, closeTo(0.24, 1e-9));
      expect((evs[2] as AIError).code, 'ai_unavailable');
    });
  });

  group('AiApi.chatStream', () {
    test('streams deltas, cards and done; sends Accept: text/event-stream', () async {
      final log = <RequestOptions>[];
      final body = 'event: delta\ndata: {"text":"往东"}\n\n'
          'event: delta\ndata: {"text":"绕滨江公园一圈"}\n\n'
          'event: card\ndata: ${jsonEncode((_done['message'] as Map)['cards'][0])}\n\n'
          'event: done\ndata: ${jsonEncode(_done)}\n\n';
      final api = _api((o) => ResponseBody(_chunks(body, 5), 200, headers: _sse), log);
      final evs = await api
          .chatStream('今晚去哪抢地？', imageId: 12, context: const AIContext(type: 'territory', id: 12), lat: 31.23, lng: 121.47)
          .toList();
      expect(evs.whereType<AIDelta>().map((e) => e.text).join(), '往东绕滨江公园一圈');
      final card = evs.whereType<AICardEvent>().single.card;
      expect(card.route!.polyline.first.lat, 31.23); // [lng, lat] order
      expect(card.route!.polyline.first.lng, 121.47);
      final done = (evs.last as AIDone).result;
      expect(done.message.id, 32);
      expect(done.userMessage!.id, 31);
      expect(done.quota!.remaining, 1);
      final req = log.single;
      expect(req.headers['Accept'], 'text/event-stream');
      expect(req.responseType, ResponseType.stream);
      expect(req.data, {
        'content': '今晚去哪抢地？',
        'image_id': 12,
        'context': {'type': 'territory', 'id': 12},
        'lat': 31.23,
        'lng': 121.47,
      });
    });

    test('HTTP errors keep the server code (quota / blocked)', () async {
      final api = _api((o) => ResponseBody.fromString(
          jsonEncode({
            'error': {'code': 'ai_quota_exceeded', 'message': '本周免费次数已用完，开通会员不限次数'}
          }),
          429,
          headers: _json));
      await expectLater(
        api.chatStream('hi').toList(),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'ai_quota_exceeded')
            .having((e) => e.status, 'status', 429)
            .having((e) => e.message, 'message', '本周免费次数已用完，开通会员不限次数')),
      );
    });

    test('a JSON answer to a stream request becomes delta + cards + done', () async {
      final api = _api((o) => ResponseBody.fromString(jsonEncode(_done), 200, headers: _json));
      final evs = await api.chatStream('hi').toList();
      expect(evs.map((e) => e.runtimeType).toList(), [AIDelta, AICardEvent, AIDone]);
    });

    test('a stream that ends without done reports stream_interrupted', () async {
      final api = _api((o) => ResponseBody(_chunks('event: delta\ndata: {"text":"往"}\n\n', 4), 200, headers: _sse));
      final evs = await api.chatStream('hi').toList();
      expect((evs.last as AIError).code, 'stream_interrupted');
    });

    test('JSON chat sends Accept: application/json', () async {
      final log = <RequestOptions>[];
      final api = _api((o) => ResponseBody.fromString(jsonEncode(_done), 200, headers: _json), log);
      final r = await api.chat('hi');
      expect(r.message.cards.single.known, isTrue);
      expect(log.single.headers['Accept'], 'application/json');
    });
  });

  test('history pages are sorted newest first and use before=', () async {
    final log = <RequestOptions>[];
    final api = _api(
        (o) => ResponseBody.fromString(
            jsonEncode({
              'items': [
                {'id': 1, 'role': 'user', 'content': 'a'},
                {'id': 2, 'role': 'assistant', 'content': 'b', 'ai_generated': true},
              ],
              'next_cursor': '1',
            }),
            200,
            headers: _json),
        log);
    final p = await api.messages(before: '9');
    expect(p.items.map((m) => m.id), [2, 1]);
    expect(p.hasMore, isTrue);
    expect(log.single.queryParameters, {'before': '9', 'limit': 30});
  });

  test('report / routes requests', () async {
    final log = <RequestOptions>[];
    final api = _api((o) {
      if (o.path.endsWith('/ai-report')) {
        return ResponseBody.fromString(
            jsonEncode({'activity_id': 55, 'text': '今晚 5.2 公里', 'model_name': '通义千问', 'ai_generated': true, 'regenerate_left': 2}),
            200,
            headers: _json);
      }
      return ResponseBody.fromString(jsonEncode({'items': [], 'ai_generated': true}), 200, headers: _json);
    }, log);
    final r = await api.report(55, regenerate: true);
    expect(r.regenerateLeft, 2);
    expect(log.last.method, 'POST');
    expect(log.last.queryParameters, {'regenerate': 1});
    expect((await api.routes(lat: 31.2, lng: 121.4, distanceKm: 5)).items, isEmpty);
    expect(log.last.queryParameters, {'lat': 31.2, 'lng': 121.4, 'sport': 'run', 'distance_km': 5});
  });

  test('models: info / quota, goal, post ai_report, features flag', () {
    final info = AIInfo.fromJson({
      'enabled': true,
      'model_name': '通义千问',
      'registration_no': 'Beijing-XXXX-20240101',
      'vision': false,
      'quota': {'unlimited': true, 'weekly_free': 3, 'used': 0, 'remaining': null},
    });
    expect(info.quota.unlimited, isTrue);
    expect(info.quota.exhausted, isFalse);
    expect(const AIQuota(remaining: 0).exhausted, isTrue);

    expect(const Goal(type: 'ai_route', routeId: 'r_8f2c1a', routeType: 'loop').toJson(),
        {'type': 'ai_route', 'route_id': 'r_8f2c1a', 'route_type': 'loop'});
    expect(Goal.fromJson({'type': 'ai_route', 'route_id': 'r_1', 'route_type': 'boss'}).routeType, 'boss');

    expect(const NewPost(content: 'x', activityId: 5, aiReport: true).toJson()['ai_report'], isTrue);
    expect(const NewPost(content: 'x', aiReport: true).toJson().containsKey('ai_report'), isFalse);
    expect(const NewPost(content: 'x', activityId: 5).toJson().containsKey('ai_report'), isFalse);
    final post = Post.fromJson({
      'id': 1,
      'author': {'id': 1, 'nickname': 'a'},
      'ai_report': {'text': '今晚 5.2 公里', 'ai_generated': true},
    });
    expect(post.aiReport!.text, '今晚 5.2 公里');
    expect(post.copyWith(liked: true).aiReport, isNotNull);
    expect(Post.fromJson({'id': 2, 'author': {}, 'ai_report': null}).aiReport, isNull);

    expect(ServerFeatures.fromJson({'ai': true}).ai, isTrue);
    expect(ServerFeatures.fromJson({}).ai, isFalse);
    expect(const ServerFeatures.unreachable().ai, isFalse);
  });
}
