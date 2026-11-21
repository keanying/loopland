import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/errors.dart';
import '../api/loopland_api.dart';
import '../api/models.dart';
import '../auth/auth_controller.dart';
import '../core/env.dart';
import '../core/providers.dart';
import 'realtime_client.dart';

/// Overridden in tests with an in-memory channel.
final wsChannelFactoryProvider = Provider<ChannelFactory>((ref) => WebSocketRealtimeChannel.new);

/// The app's WebSocket. Connected while a fully signed-in session exists
/// (after phone binding and consent), disconnected on logout.
final realtimeClientProvider = Provider<RealtimeClient>((ref) {
  final api = ref.watch(apiClientProvider);
  final c = RealtimeClient(
    baseUrl: api.dio.options.baseUrl,
    wsUrl: Env.wsUrlOverride,
    token: () => api.tokens.accessToken,
    connect: ref.watch(wsChannelFactoryProvider),
    // A failed upgrade usually means an expired access token. Probing an
    // authenticated endpoint lets ApiClient rotate the refresh token (single
    // flight) or end the session if that fails too.
    onAuthFailure: () async {
      try {
        await LooplandApi(api).me();
        return true;
      } on ApiException catch (e) {
        return e.status != 401 && e.code != 'account_banned';
      }
    },
  );
  ref.onDispose(c.dispose);
  ref.listen<bool>(
    authProvider.select((a) => a.loggedIn && !a.needBindPhone && !a.needConsent),
    (_, ready) => ready ? c.start() : c.stop(),
    fireImmediately: true,
  );
  return c;
});

/// Every server message (pings included).
final realtimeEventsProvider = StreamProvider<RealtimeEvent>((ref) => ref.watch(realtimeClientProvider).events);

/// Live boss state: subscribes to `boss:<id>` while watched.
final bossLiveProvider = StreamProvider.autoDispose.family<BossHpEvent, int>((ref, id) {
  final c = ref.watch(realtimeClientProvider);
  c.subscribe('boss:$id');
  ref.onDispose(() => c.unsubscribe('boss:$id'));
  return c.events.where((e) => e is BossHpEvent && e.bossId == id).cast<BossHpEvent>();
});

/// Connection state, for "实时" indicators.
final realtimeStatusProvider = StreamProvider<RealtimeStatus>((ref) {
  final c = ref.watch(realtimeClientProvider);
  final ctl = StreamController<RealtimeStatus>();
  ctl.add(c.status);
  final sub = c.statusChanges.listen(ctl.add);
  ref.onDispose(() {
    sub.cancel();
    ctl.close();
  });
  return ctl.stream;
});
