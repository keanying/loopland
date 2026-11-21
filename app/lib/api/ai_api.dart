import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import 'ai_models.dart';
import 'api_client.dart';
import 'community_common.dart';
import 'errors.dart';
import 'models.dart' show Json;

final aiApiProvider = Provider<AiApi>((ref) => AiApi(ref.watch(apiClientProvider)));

/// One Server-Sent Event.
class SseEvent {
  const SseEvent(this.event, this.data);

  /// `message` when the server sent no `event:` line.
  final String event;
  final String data;
  @override
  String toString() => 'SseEvent($event, $data)';
}

/// Parses a `text/event-stream` body: `event:` / `data:` lines (several
/// `data:` lines are joined with `\n`), `:` comments and `id:` / `retry:`
/// ignored, a blank line dispatches. Handles `\n`, `\r\n` and chunks that
/// split lines or UTF-8 sequences anywhere.
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  String? event;
  final data = <String>[];
  await for (final raw in bytes.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter())) {
    if (raw.isEmpty) {
      if (data.isNotEmpty) yield SseEvent(event ?? 'message', data.join('\n'));
      event = null;
      data.clear();
      continue;
    }
    if (raw.startsWith(':')) continue;
    final i = raw.indexOf(':');
    final field = i < 0 ? raw : raw.substring(0, i);
    var value = i < 0 ? '' : raw.substring(i + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        data.add(value);
    }
  }
  // A last event without the trailing blank line.
  if (data.isNotEmpty) yield SseEvent(event ?? 'message', data.join('\n'));
}

/// Maps SSE events of `POST /v1/ai/chat` to [AIChatEvent]s. Unknown events
/// are skipped.
Stream<AIChatEvent> aiChatEvents(Stream<SseEvent> events) async* {
  await for (final e in events) {
    Object? data;
    try {
      data = e.data.isEmpty ? const <String, dynamic>{} : jsonDecode(e.data);
    } catch (_) {
      continue;
    }
    final j = jm(data);
    switch (e.event) {
      case 'delta':
        final t = js(j['text']);
        if (t.isNotEmpty) yield AIDelta(t);
      case 'card':
        yield AICardEvent(AICard.fromJson(j));
      case 'done':
        yield AIDone(AIChatResult.fromJson(j));
        return;
      case 'error':
        yield AIError(js(j['code'], 'ai_unavailable'), js(j['message']));
        return;
    }
  }
}

/// App endpoints of docs/api/v2-3-AI.md (info, greeting, history, chat with
/// SSE streaming, route suggestions, battle reports).
class AiApi {
  AiApi(this.c);
  final ApiClient c;

  /// Streaming answers can take a while between chunks (tool calls).
  static const streamTimeout = Duration(seconds: 90);

  Future<AIInfo> info() async => AIInfo.fromJson(jm(await c.get('/v1/ai/info')));

  Future<AIGreeting> greeting({double? lat, double? lng}) async =>
      AIGreeting.fromJson(jm(await c.get('/v1/ai/greeting', query: {'lat': ?lat, 'lng': ?lng})));

  /// History, newest first. [before] is the previous page's `next_cursor`.
  Future<CursorPage<AIMessage>> messages({String? before, int limit = 30}) async {
    final raw = await c.get('/v1/ai/messages', query: {
      if (before != null && before.isNotEmpty) 'before': before,
      'limit': limit,
    });
    final page = CursorPage.fromJson(raw, AIMessage.fromJson);
    // Newest first regardless of how the server orders the page.
    final items = List.of(page.items)..sort((a, b) => b.id.compareTo(a.id));
    return CursorPage(items, page.nextCursor);
  }

  /// Clears my conversation (soft delete on the server).
  Future<void> clearMessages() => c.delete('/v1/ai/messages');

  Json _chatBody(String content, {int? imageId, AIContext? context, double? lat, double? lng}) => {
        'content': content,
        'image_id': ?imageId,
        if (context != null) 'context': context.toJson(),
        'lat': ?lat,
        'lng': ?lng,
      };

  /// Non-streaming `POST /v1/ai/chat` (`Accept: application/json`).
  ///
  /// Errors: 400 `content_blocked` / `ai_image_unsupported` / `invalid_media`,
  /// 429 `ai_quota_exceeded` / `rate_limited`, 503 `ai_unavailable`.
  Future<AIChatResult> chat(String content, {int? imageId, AIContext? context, double? lat, double? lng}) async {
    try {
      final r = await c.dio.post<dynamic>(
        '/v1/ai/chat',
        data: _chatBody(content, imageId: imageId, context: context, lat: lat, lng: lng),
        options: Options(headers: {'Accept': 'application/json'}, receiveTimeout: streamTimeout),
      );
      return AIChatResult.fromJson(jm(r.data));
    } catch (e) {
      throw ApiException.from(e);
    }
  }

  /// Streaming `POST /v1/ai/chat` (`Accept: text/event-stream`): [AIDelta]s,
  /// [AICardEvent]s, then exactly one [AIDone] or [AIError]. HTTP errors
  /// before the stream starts (quota, blocked content, …) are thrown as
  /// [ApiException] with the server's code. A server that answers with JSON
  /// instead of a stream yields the whole text as one delta plus [AIDone].
  Stream<AIChatEvent> chatStream(
    String content, {
    int? imageId,
    AIContext? context,
    double? lat,
    double? lng,
    CancelToken? cancel,
  }) async* {
    final Response<ResponseBody> r;
    try {
      r = await c.dio.post<ResponseBody>(
        '/v1/ai/chat',
        data: _chatBody(content, imageId: imageId, context: context, lat: lat, lng: lng),
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Accept': 'text/event-stream', 'Cache-Control': 'no-cache'},
          receiveTimeout: streamTimeout,
        ),
      );
    } catch (e) {
      throw await _streamError(e);
    }
    final body = r.data!;
    final type = body.headers[Headers.contentTypeHeader]?.first ?? r.headers.value(Headers.contentTypeHeader) ?? '';
    if (!type.contains('text/event-stream')) {
      final bytes = await _readAll(body.stream);
      final result = AIChatResult.fromJson(jm(jsonDecode(utf8.decode(bytes))));
      if (result.message.content.isNotEmpty) yield AIDelta(result.message.content);
      for (final card in result.message.cards) {
        yield AICardEvent(card);
      }
      yield AIDone(result);
      return;
    }
    var ended = false;
    try {
      await for (final ev in aiChatEvents(parseSse(body.stream))) {
        if (ev is AIDone || ev is AIError) ended = true;
        yield ev;
        if (ended) return;
      }
    } on DioException catch (e) {
      throw ApiException.from(e);
    }
    if (!ended) yield const AIError('stream_interrupted', '回答中断了，请重试');
  }

  /// HTTP errors of a streamed request carry the JSON error body as a stream.
  static Future<ApiException> _streamError(Object e) async {
    if (e is DioException) {
      final res = e.response;
      final data = res?.data;
      if (res != null && data is ResponseBody) {
        try {
          final text = utf8.decode(await _readAll(data.stream));
          return ApiException.fromResponse(res.statusCode ?? 0, text.isEmpty ? null : jsonDecode(text));
        } catch (_) {
          return ApiException.fromResponse(res.statusCode ?? 0, null);
        }
      }
    }
    return ApiException.from(e);
  }

  static Future<List<int>> _readAll(Stream<List<int>> s) async {
    final out = <int>[];
    await for (final chunk in s) {
      out.addAll(chunk);
    }
    return out;
  }

  /// C-04 `GET /v1/ai/routes` (≤ 4: loop → capture → defend → boss).
  Future<AIRoutes> routes({required double lat, required double lng, String sport = 'run', int? distanceKm}) async =>
      AIRoutes.fromJson(jm(await c.get('/v1/ai/routes', query: {
        'lat': lat,
        'lng': lng,
        'sport': sport,
        'distance_km': ?distanceKm,
      })));

  /// C-05 battle report for my settled activity. The first call generates and
  /// stores it; [regenerate] writes a new one (409 `regenerate_limit` after 2).
  Future<AIReport> report(int activityId, {bool regenerate = false}) async =>
      AIReport.fromJson(jm(await c.request('POST', '/v1/activities/$activityId/ai-report',
          data: const <String, dynamic>{}, query: {'regenerate': regenerate ? 1 : 0})));
}
