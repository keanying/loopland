// The app's AI API layer (lib/api/ai_api.dart, docs/api/v2-3-AI.md) against a
// live dev backend (LOOPLAND_ENV=dev without AI config → built-in mock AI):
//
//   LOOPLAND_LIVE_API=http://localhost:8080 flutter test integration_live/ai_live_test.dart
//
// Skipped when LOOPLAND_LIVE_API is not set.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/ai_api.dart';
import 'package:loopland/api/ai_models.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/community_api.dart';
import 'package:loopland/api/community_models.dart';
import 'package:loopland/api/errors.dart';
import 'package:loopland/api/loopland_api.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/core/features.dart';

import 'community_live_test.dart' show png;
import 'live_api_test.dart' show origin, run;

void main() {
  final base = Platform.environment['LOOPLAND_LIVE_API'];
  final skip = base == null ? 'set LOOPLAND_LIVE_API to run' : false;
  final rnd = math.Random().nextInt(90000000) + 10000000;

  test('AI: info, greeting, SSE + JSON chat, quota, history, routes, ai_route goal, report, post', () async {
    final c = ApiClient(tokens: MemoryTokenStore(), baseUrl: base, platform: 'android');
    final api = LooplandApi(c);
    final ai = AiApi(c);
    final community = CommunityApi(c);
    await api.sendSms('135$rnd');
    await api.login('sms', {'phone': '135$rnd', 'code': '000000'});
    await api.setConsents(privacyVersion: '2026-11', location: true, health: true);

    final features = ServerFeatures.fromJson((await c.get('/v1/config/features') as Map).cast<String, dynamic>());
    expect(features.ai, isTrue);

    final info = await ai.info();
    expect(info.enabled, isTrue);
    expect(info.modelName, isNotEmpty);
    expect(info.quota.unlimited, isFalse);
    expect(info.quota.remaining, 3);
    expect(info.quota.resetsAt, isNotNull);

    final g = await ai.greeting(lat: origin.lat, lng: origin.lng);
    expect(g.text, isNotEmpty);
    expect(g.suggestions, isNotEmpty);
    expect((await ai.messages()).items, isEmpty);

    // A real territory to ask about (and a run to report on).
    final x = rnd % 50 * 1000.0 + 6000;
    final square = [
      [0.0, 0.0], [400.0, 0.0], [400.0, 400.0], [200.0, 400.0], [200.0, -50.0]
    ].map((p) => [p[0] + x, p[1] + 3000]).toList();
    final first = await api.uploadActivity(run(square));
    expect(first.settlement.status, 'settled');
    final tid = first.settlement.claims.first.territoryId;

    // Raw check: the server really streams text/event-stream.
    final raw = await c.dio.post<ResponseBody>('/v1/ai/chat',
        data: {'content': '今天跑多少合适？'},
        options: Options(responseType: ResponseType.stream, headers: {'Accept': 'text/event-stream'}));
    expect(raw.headers.value(Headers.contentTypeHeader), startsWith('text/event-stream'));
    final rawEvents = await parseSse(raw.data!.stream).toList();
    expect(rawEvents.map((e) => e.event), contains('delta'));
    expect(rawEvents.last.event, 'done');

    // App layer, streamed, with 问 AI context.
    final evs = await ai
        .chatStream('规划圈地路线', lat: origin.lat, lng: origin.lng)
        .toList();
    final deltas = evs.whereType<AIDelta>().map((e) => e.text).join();
    expect(deltas, isNotEmpty);
    final done = evs.whereType<AIDone>().single.result;
    expect(done.message.role, 'assistant');
    expect(done.message.aiGenerated, isTrue);
    expect(done.message.content, isNotEmpty);
    expect(done.userMessage!.content, '规划圈地路线');
    expect(done.userMessage!.aiGenerated, isFalse);
    expect(done.quota!.remaining, 1);
    final cards = evs.whereType<AICardEvent>().map((e) => e.card).toList();
    expect(cards, isNotEmpty);
    expect(cards.every((c) => c.known), isTrue);
    final routeCard = cards.firstWhere((c) => c.type == 'route').route!;
    expect(routeCard.path.length, greaterThanOrEqualTo(2));
    expect(done.message.cards.length, cards.length);
    // ignore: avoid_print
    print('streamed ${evs.whereType<AIDelta>().length} deltas, ${evs.whereType<AICardEvent>().length} cards: $deltas');

    // Photo without a vision model.
    if (!info.vision) {
      final img = await community.uploadMedia(png, filename: 'food.png', purpose: 'chat');
      await expectLater(ai.chatStream('这是什么', imageId: img.id).toList(),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', 'ai_image_unsupported')));
    }

    // JSON mode uses the last free question; then the quota error arrives as
    // a plain HTTP error even though streaming was requested.
    final json = await ai.chat('这块地怎么抢下来？', context: AIContext(type: 'territory', id: tid), lat: origin.lat, lng: origin.lng);
    expect(json.message.content, isNotEmpty);
    expect(json.quota!.remaining, 0);
    await expectLater(
      ai.chatStream('再问一次').toList(),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'ai_quota_exceeded').having((e) => e.status, 'status', 429)),
    );
    expect((await ai.info()).quota.exhausted, isTrue);

    // History: newest first, paged with before=.
    final hist = await ai.messages(limit: 2);
    expect(hist.items, hasLength(2));
    expect(hist.items.first.id, greaterThan(hist.items.last.id));
    expect(hist.items.first.role, 'assistant');
    expect(hist.hasMore, isTrue);
    final older = await ai.messages(before: hist.nextCursor, limit: 30);
    expect(older.items.every((m) => m.id < hist.items.last.id), isTrue);
    expect(hist.items.length + older.items.length, 6);

    // C-04 routes, then run one with the ai_route goal.
    final routes = await ai.routes(lat: origin.lat, lng: origin.lng, distanceKm: 3);
    expect(routes.items, isNotEmpty);
    final loop = routes.items.first;
    expect(loop.type, 'loop');
    expect(loop.id, isNotEmpty);
    expect(loop.path.length, greaterThanOrEqualTo(3));
    expect(loop.distanceM, greaterThan(1500));
    expect((loop.path.first.lat - origin.lat).abs(), lessThan(0.05)); // [lng, lat] parsed right
    // ignore: avoid_print
    print('routes: ${routes.items.map((r) => '${r.type} ${r.title} ${r.distanceM.round()}m ai=${r.aiGenerated}').join(' | ')}');
    final guided = run(square.map((p) => [p[0], p[1] + 600]).toList());
    final res = await api.uploadActivity(ActivityUpload(
      clientId: guided.clientId,
      sport: guided.sport,
      startedAt: guided.startedAt,
      endedAt: guided.endedAt,
      durationS: guided.durationS,
      points: guided.points,
      device: guided.device,
      goal: Goal(type: 'ai_route', routeId: loop.id, routeType: loop.type),
    ));
    expect(res.settlement.status, 'settled');

    // C-05 report: stored, regenerated twice, then 409.
    final r1 = await ai.report(res.activity.id);
    expect(r1.text, isNotEmpty);
    expect(r1.aiGenerated, isTrue);
    expect(r1.regenerateLeft, 2);
    expect((await ai.report(res.activity.id)).text, r1.text);
    expect((await ai.report(res.activity.id, regenerate: true)).regenerateLeft, 1);
    final r3 = await ai.report(res.activity.id, regenerate: true);
    expect(r3.regenerateLeft, 0);
    await expectLater(ai.report(res.activity.id, regenerate: true),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'regenerate_limit')));

    // D-05 post with the report.
    final post = await community.createPost(NewPost(content: '今晚按 AI 路线跑了一圈', activityId: res.activity.id, aiReport: true));
    expect(post.aiReport?.text, r3.text);
    expect(post.aiReport?.aiGenerated, isTrue);
    expect((await community.post(post.id)).aiReport?.text, r3.text);
    final plain = await community.createPost(NewPost(content: '没带战报', activityId: first.activity.id));
    expect(plain.aiReport, isNull);

    await ai.clearMessages();
    expect((await ai.messages()).items, isEmpty);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
