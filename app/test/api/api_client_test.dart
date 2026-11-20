import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/errors.dart';
import 'package:loopland/api/loopland_api.dart';
import 'package:loopland/auth/token_store.dart';

import 'fixtures.dart';

typedef Handler = FutureOr<(int, Object?)> Function(RequestOptions o);

/// Fake HTTP layer: routes requests to [handler] and records them.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  final Handler handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    requests.add(o);
    final (status, data) = await handler(o);
    return ResponseBody.fromString(jsonEncode(data), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('adds bearer + X-Platform and parses User', () async {
    final a = FakeAdapter((o) => (200, j(userJson)));
    final c = ApiClient(tokens: MemoryTokenStore(access: 'A1', refresh: 'R1'), baseUrl: 'http://x', adapter: a, platform: 'ios');
    final u = await LooplandApi(c).me();
    expect(u.nickname, '跑者1024');
    expect(a.requests.single.headers['Authorization'], 'Bearer A1');
    expect(a.requests.single.headers['X-Platform'], 'ios');
  });

  test('maps error body to ApiException and raises phone_required event', () async {
    final a = FakeAdapter((o) => (403, {
          'error': {'code': 'phone_required', 'message': '请先绑定手机号'}
        }));
    final c = ApiClient(tokens: MemoryTokenStore(access: 'A1'), baseUrl: 'http://x', adapter: a);
    final events = <ApiEvent>[];
    c.events.listen(events.add);
    await expectLater(
      LooplandApi(c).codex(),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'phone_required').having((e) => e.status, 'status', 403)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(events, [ApiEvent.phoneRequired]);
  });

  test('refresh token rotation: concurrent 401s share one refresh, requests retried', () async {
    var refreshes = 0;
    final tokens = MemoryTokenStore(access: 'old', refresh: 'R1');
    final a = FakeAdapter((o) async {
      if (o.path == '/v1/auth/refresh') {
        refreshes++;
        expect((o.data as Map)['refresh_token'], 'R1');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return (200, j(authResultJson)..['access_token'] = 'new'..['refresh_token'] = 'R2');
      }
      if (o.headers['Authorization'] == 'Bearer new') return (200, j(userJson));
      return (401, {
        'error': {'code': 'unauthorized', 'message': ''}
      });
    });
    final api = LooplandApi(ApiClient(tokens: tokens, baseUrl: 'http://x', adapter: a));
    final users = await Future.wait([api.me(), api.me(), api.me()]);
    expect(users, hasLength(3));
    expect(refreshes, 1);
    expect(await tokens.accessToken, 'new');
    expect(await tokens.refreshToken, 'R2');
  });

  test('rejected refresh clears tokens and emits sessionExpired', () async {
    final tokens = MemoryTokenStore(access: 'old', refresh: 'R1');
    final a = FakeAdapter((o) => o.path == '/v1/auth/refresh'
        ? (401, {'error': {'code': 'unauthorized', 'message': ''}})
        : (401, {'error': {'code': 'unauthorized', 'message': ''}}));
    final c = ApiClient(tokens: tokens, baseUrl: 'http://x', adapter: a);
    final events = <ApiEvent>[];
    c.events.listen(events.add);
    await expectLater(LooplandApi(c).me(), throwsA(isA<ApiException>()));
    await Future<void>.delayed(Duration.zero);
    expect(events, contains(ApiEvent.sessionExpired));
    expect(await tokens.refreshToken, isNull);
  });

  test('login stores tokens and sends device_id/platform', () async {
    final tokens = MemoryTokenStore();
    final a = FakeAdapter((o) => (200, j(authResultJson)));
    final api = LooplandApi(ApiClient(tokens: tokens, baseUrl: 'http://x', adapter: a, platform: 'android'));
    final r = await api.login('sms', {'phone': '13800138000', 'code': '000000'});
    expect(r.user.id, 1);
    expect(await tokens.accessToken, 'acc');
    final body = a.requests.single.data as Map;
    expect(body['provider'], 'sms');
    expect(body['platform'], 'android');
    expect(body['device_id'], isNotEmpty);
    expect(a.requests.single.headers.containsKey('Authorization'), isFalse);
  });

  test('territories sends bbox and scope', () async {
    final a = FakeAdapter((o) => (200, {'items': [j(territorySummaryJson)]}));
    final api = LooplandApi(ApiClient(tokens: MemoryTokenStore(access: 'A'), baseUrl: 'http://x', adapter: a));
    final items = await api.territories(minLng: 121.4, minLat: 31.2, maxLng: 121.5, maxLat: 31.3, scope: 'mine');
    expect(items.single.id, 101);
    expect(a.requests.single.queryParameters['bbox'], '121.400000,31.200000,121.500000,31.300000');
    expect(a.requests.single.queryParameters['scope'], 'mine');
  });

  test('network failure maps to network code', () async {
    final c = ApiClient(tokens: MemoryTokenStore(), baseUrl: 'http://x', adapter: FakeAdapter((o) {
      throw DioException.connectionError(requestOptions: o, reason: 'offline');
    }));
    await expectLater(LooplandApi(c).gameplay(), throwsA(isA<ApiException>().having((e) => e.isNetwork, 'network', isTrue)));
  });
}
