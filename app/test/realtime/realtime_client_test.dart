import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/realtime/realtime_client.dart';

/// In-memory WebSocket: the test plays the server.
class FakeChannel implements RealtimeChannel {
  FakeChannel(this.uri, {this.fail = false});
  final Uri uri;
  final bool fail;
  final sent = <Map<String, dynamic>>[];
  final _in = StreamController<dynamic>();
  int? _closeCode;
  bool closed = false;

  @override
  Future<void> get ready => fail ? Future.error(Exception('HTTP 401')) : Future.value();
  @override
  Stream<dynamic> get stream => _in.stream;
  @override
  void send(String text) => sent.add((jsonDecode(text) as Map).cast<String, dynamic>());
  @override
  Future<void> close([int? code]) async {
    closed = true;
    if (!_in.isClosed) await _in.close();
  }

  @override
  int? get closeCode => _closeCode;

  // Server side.
  void push(Object msg) => _in.add(jsonEncode(msg));
  Future<void> serverClose([int? code]) async {
    _closeCode = code;
    await _in.close();
  }
}

Future<void> tick([int ms = 5]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('wsUri maps http(s) to ws(s) and keeps the base path', () {
    expect(RealtimeClient.wsUri('http://10.0.2.2:8080', 'T k').toString(), 'ws://10.0.2.2:8080/v1/ws?token=T+k');
    expect(RealtimeClient.wsUri('https://api.loopland.cn/', 'abc').toString(), 'wss://api.loopland.cn/v1/ws?token=abc');
    expect(RealtimeClient.wsUri('https://x.cn/api', 'abc', wsUrl: '').toString(), 'wss://x.cn/api/v1/ws?token=abc');
  });

  test('wsUri uses an explicit WS_URL (api.ws_url) as-is', () {
    expect(RealtimeClient.wsUri('https://api.loopland.cn', 'abc', wsUrl: 'wss://ws.loopland.cn/v1/ws').toString(),
        'wss://ws.loopland.cn/v1/ws?token=abc');
  });

  test('connects, subscribes, parses events, reconnects with backoff and re-subscribes', () async {
    final channels = <FakeChannel>[];
    final c = RealtimeClient(
      baseUrl: 'http://x',
      token: () async => 'tok',
      backoff: const [Duration(milliseconds: 10), Duration(milliseconds: 20)],
      connect: (uri) => (channels..add(FakeChannel(uri))).last,
    );
    final events = <RealtimeEvent>[];
    c.events.listen(events.add);

    c.subscribe('boss:3'); // before connecting: sent on connect
    c.start();
    await tick();
    expect(c.status, RealtimeStatus.connected);
    expect(channels, hasLength(1));
    expect(channels.first.uri.queryParameters['token'], 'tok');
    expect(channels.first.sent, [
      {'sub': 'boss:3'}
    ]);

    channels.first.push({'type': 'ping'});
    channels.first.push({
      'type': 'boss',
      'boss': {'id': 3, 'hp': 3756, 'status': 'active'},
      'by': {'id': 1, 'nickname': '阿杰'},
      'damage': 44
    });
    await tick();
    expect(events.whereType<PingEvent>(), hasLength(1));
    expect(events.whereType<BossHpEvent>().single.hp, 3756);

    // Second subscriber to the same topic does not resend; a new topic does.
    c.subscribe('boss:3');
    c.subscribe('boss:7');
    expect(channels.first.sent.last, {'sub': 'boss:7'});
    expect(channels.first.sent, hasLength(2));

    // Server drops the connection → reconnect after backoff, topics resent.
    await channels.first.serverClose(1006);
    await tick();
    expect(c.status, RealtimeStatus.disconnected);
    await tick(30);
    expect(channels, hasLength(2));
    expect(c.status, RealtimeStatus.connected);
    expect(channels[1].sent, [
      {'sub': 'boss:3'},
      {'sub': 'boss:7'}
    ]);

    // Unsubscribe only after the last listener leaves.
    c.unsubscribe('boss:3');
    expect(channels[1].sent, hasLength(2));
    c.unsubscribe('boss:3');
    expect(channels[1].sent.last, {'unsub': 'boss:3'});
    expect(c.topics, {'boss:7'});

    await c.stop();
    expect(channels[1].closed, isTrue);
    expect(c.status, RealtimeStatus.disconnected);
    await tick(40);
    expect(channels, hasLength(2)); // no reconnect after stop
    await c.dispose();
  });

  test('handshake failure refreshes the session, then reconnects with the new token', () async {
    var token = 'expired';
    var authChecks = 0;
    final channels = <FakeChannel>[];
    final c = RealtimeClient(
      baseUrl: 'http://x',
      token: () async => token,
      backoff: const [Duration(milliseconds: 10)],
      onAuthFailure: () async {
        authChecks++;
        token = 'fresh'; // ApiClient rotated the refresh token
        return true;
      },
      connect: (uri) => (channels..add(FakeChannel(uri, fail: uri.queryParameters['token'] == 'expired'))).last,
    );
    c.subscribe('boss:3');
    c.start();
    await tick(40);
    expect(authChecks, 1);
    expect(channels.map((ch) => ch.uri.queryParameters['token']), ['expired', 'fresh']);
    expect(c.status, RealtimeStatus.connected);
    expect(channels.last.sent, [
      {'sub': 'boss:3'}
    ]);

    // An auth close code (policy violation) also triggers the check.
    token = 'expired';
    await channels.last.serverClose(4001);
    await tick(60);
    expect(authChecks, greaterThanOrEqualTo(2));
    expect(channels.last.uri.queryParameters['token'], 'fresh');
    expect(c.status, RealtimeStatus.connected);
    await c.dispose();
  });

  test('stops when the session is gone', () async {
    final channels = <FakeChannel>[];
    final c = RealtimeClient(
      baseUrl: 'http://x',
      token: () async => 'bad',
      backoff: const [Duration(milliseconds: 5)],
      onAuthFailure: () async => false, // refresh rejected → logged out
      connect: (uri) => (channels..add(FakeChannel(uri, fail: true))).last,
    );
    c.start();
    await tick(40);
    expect(channels, hasLength(1));
    expect(c.running, isFalse);
    await c.dispose();
  });

  test('no token: stays disconnected', () async {
    var made = 0;
    final c = RealtimeClient(baseUrl: 'http://x', token: () async => null, connect: (uri) {
      made++;
      return FakeChannel(uri);
    });
    c.start();
    await tick();
    expect(made, 0);
    expect(c.status, RealtimeStatus.disconnected);
    await c.dispose();
  });

  test('a silent socket (no ping) is treated as dead and replaced', () async {
    final channels = <FakeChannel>[];
    final c = RealtimeClient(
      baseUrl: 'http://x',
      token: () async => 't',
      backoff: const [Duration(milliseconds: 5)],
      silenceTimeout: const Duration(milliseconds: 30),
      connect: (uri) => (channels..add(FakeChannel(uri))).last,
    );
    c.start();
    await tick();
    // Pings keep it alive.
    for (var i = 0; i < 3; i++) {
      channels.first.push({'type': 'ping'});
      await tick(15);
    }
    expect(channels, hasLength(1));
    await tick(60);
    expect(channels.length, greaterThanOrEqualTo(2));
    expect(channels.first.closed, isTrue);
    await c.dispose();
  });
}
