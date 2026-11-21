import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/models.dart';

/// The bits of a WebSocket the client needs. Production wraps
/// [WebSocketChannel]; tests use an in-memory fake.
abstract class RealtimeChannel {
  /// Completes when the upgrade succeeded, errors when the handshake failed
  /// (network, 401 for a bad token, …).
  Future<void> get ready;
  Stream<dynamic> get stream;
  void send(String text);
  Future<void> close([int? code]);

  /// Close code once [stream] is done (null for an abnormal close).
  int? get closeCode;
}

typedef ChannelFactory = RealtimeChannel Function(Uri uri);

class WebSocketRealtimeChannel implements RealtimeChannel {
  WebSocketRealtimeChannel(Uri uri) : _ch = WebSocketChannel.connect(uri);
  final WebSocketChannel _ch;
  @override
  Future<void> get ready => _ch.ready;
  @override
  Stream<dynamic> get stream => _ch.stream;
  @override
  void send(String text) => _ch.sink.add(text);
  @override
  Future<void> close([int? code]) => _ch.sink.close(code);
  @override
  int? get closeCode => _ch.closeCode;
}

enum RealtimeStatus { disconnected, connecting, connected }

/// Close codes the server may use for an invalid / expired token.
const _authCloseCodes = {1008, 4001, 4003, 4401, 4403};

/// `GET /v1/ws?token=…` client: reconnects with exponential backoff,
/// re-subscribes its topics after every reconnect, refreshes the session
/// when the handshake (or an auth close) fails, and treats a silent socket
/// (no message — not even the 30 s `ping` — for [silenceTimeout]) as dead.
class RealtimeClient {
  RealtimeClient({
    required this.baseUrl,
    required this.token,
    this.onAuthFailure,
    ChannelFactory? connect,
    this.backoff = defaultBackoff,
    this.silenceTimeout = const Duration(seconds: 75),
  }) : _factory = connect ?? WebSocketRealtimeChannel.new;

  /// The REST base (`http(s)://host:port`); turned into `ws(s)://…/v1/ws`.
  final String baseUrl;

  /// Current access token (null when logged out).
  final Future<String?> Function() token;

  /// Called after a failed handshake or an auth close. It should make sure
  /// the access token is valid (refresh it on 401). Returning false means
  /// the session is gone: stop reconnecting.
  final Future<bool> Function()? onAuthFailure;
  final List<Duration> backoff;
  final Duration silenceTimeout;
  final ChannelFactory _factory;

  static const defaultBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  final _events = StreamController<RealtimeEvent>.broadcast();
  final _statusCtl = StreamController<RealtimeStatus>.broadcast();
  final _topics = <String, int>{};
  RealtimeChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry, _watchdog;
  int _attempt = 0;
  int _gen = 0;
  bool _wanted = false;
  bool _disposed = false;
  RealtimeStatus _status = RealtimeStatus.disconnected;

  Stream<RealtimeEvent> get events => _events.stream;
  Stream<RealtimeStatus> get statusChanges => _statusCtl.stream;
  RealtimeStatus get status => _status;
  bool get running => _wanted;

  /// Topics with at least one subscriber.
  Set<String> get topics => _topics.keys.toSet();

  static Uri wsUri(String base, String token) {
    final b = Uri.parse(base);
    final scheme = b.scheme == 'https' ? 'wss' : 'ws';
    final path = '${b.path.endsWith('/') ? b.path.substring(0, b.path.length - 1) : b.path}/v1/ws';
    return b.replace(scheme: scheme, path: path, queryParameters: {'token': token});
  }

  /// Connects (after login). Idempotent.
  void start() {
    if (_disposed) return;
    _wanted = true;
    if (_ch == null && _retry == null && _status != RealtimeStatus.connecting) _connect();
  }

  /// Disconnects (logout). Topics are kept for the next [start].
  Future<void> stop() async {
    _wanted = false;
    _gen++;
    _retry?.cancel();
    _retry = null;
    await _drop();
    _attempt = 0;
    _setStatus(RealtimeStatus.disconnected);
  }

  void subscribe(String topic) {
    final n = (_topics[topic] ?? 0) + 1;
    _topics[topic] = n;
    if (n == 1) _send({'sub': topic});
  }

  void unsubscribe(String topic) {
    final n = (_topics[topic] ?? 0) - 1;
    if (n > 0) {
      _topics[topic] = n;
      return;
    }
    if (_topics.remove(topic) != null) _send({'unsub': topic});
  }

  Future<void> dispose() async {
    await stop();
    _disposed = true;
    await _events.close();
    await _statusCtl.close();
  }

  void _send(Map<String, Object?> m) {
    if (_status == RealtimeStatus.connected) _ch?.send(jsonEncode(m));
  }

  void _setStatus(RealtimeStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }

  Future<void> _connect() async {
    final gen = ++_gen;
    _setStatus(RealtimeStatus.connecting);
    String? t;
    try {
      t = await token();
    } catch (_) {
      t = null;
    }
    if (!_wanted || gen != _gen) return;
    if (t == null || t.isEmpty) {
      // Logged out underneath us; the auth listener will start() again.
      _wanted = false;
      _setStatus(RealtimeStatus.disconnected);
      return;
    }
    RealtimeChannel ch;
    try {
      ch = _factory(wsUri(baseUrl, t));
      await ch.ready;
    } catch (e) {
      if (!_wanted || gen != _gen) return;
      dev.log('ws handshake failed: $e', name: 'loopland.ws');
      _setStatus(RealtimeStatus.disconnected);
      await _authCheck(gen);
      return;
    }
    if (!_wanted || gen != _gen) {
      unawaited(ch.close());
      return;
    }
    _ch = ch;
    _attempt = 0;
    _setStatus(RealtimeStatus.connected);
    _sub = ch.stream.listen(
      (m) => _onData(gen, m),
      onDone: () => _onClosed(gen, ch.closeCode),
      onError: (Object _) => _onClosed(gen, null),
      cancelOnError: true,
    );
    for (final topic in _topics.keys) {
      ch.send(jsonEncode({'sub': topic}));
    }
    _armWatchdog(gen);
  }

  void _onData(int gen, dynamic msg) {
    if (gen != _gen) return;
    _armWatchdog(gen);
    Object? decoded;
    try {
      decoded = msg is String ? jsonDecode(msg) : null;
    } catch (_) {
      return;
    }
    final e = RealtimeEvent.parse(decoded);
    if (e != null && !_events.isClosed) _events.add(e);
  }

  Future<void> _onClosed(int gen, int? code) async {
    if (gen != _gen) return;
    await _drop();
    _setStatus(RealtimeStatus.disconnected);
    if (!_wanted) return;
    if (code != null && _authCloseCodes.contains(code)) {
      await _authCheck(gen);
    } else {
      _schedule();
    }
  }

  Future<void> _authCheck(int gen) async {
    final cb = onAuthFailure;
    if (cb != null) {
      bool ok;
      try {
        ok = await cb();
      } catch (_) {
        ok = true; // network trouble: keep retrying
      }
      if (gen != _gen || !_wanted) return;
      if (!ok) {
        _wanted = false;
        return;
      }
    }
    _schedule();
  }

  void _schedule() {
    if (!_wanted || _disposed) return;
    final d = backoff.isEmpty ? Duration.zero : backoff[_attempt.clamp(0, backoff.length - 1)];
    _attempt++;
    _retry?.cancel();
    _retry = Timer(d, () {
      _retry = null;
      if (_wanted) _connect();
    });
  }

  void _armWatchdog(int gen) {
    _watchdog?.cancel();
    _watchdog = Timer(silenceTimeout, () {
      if (gen != _gen) return;
      dev.log('ws silent for $silenceTimeout, reconnecting', name: 'loopland.ws');
      _ch?.close();
      _onClosed(gen, null);
    });
  }

  Future<void> _drop() async {
    _watchdog?.cancel();
    _watchdog = null;
    final sub = _sub, ch = _ch;
    _sub = null;
    _ch = null;
    await sub?.cancel();
    if (ch != null) {
      try {
        await ch.close().timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
  }
}
