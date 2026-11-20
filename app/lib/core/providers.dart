import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/loopland_api.dart';
import '../api/models.dart';
import '../auth/token_store.dart';

/// Overridden in tests with [MemoryTokenStore].
final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  final c = ApiClient(tokens: ref.watch(tokenStoreProvider));
  ref.onDispose(c.dispose);
  return c;
});

final apiProvider = Provider<LooplandApi>((ref) => LooplandApi(ref.watch(apiClientProvider)));

/// Small key/value cache (last user, last config) so the app opens offline.
abstract class KvCache {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class PrefsCache implements KvCache {
  Future<SharedPreferences> get _p => SharedPreferences.getInstance();
  @override
  Future<String?> read(String key) async => (await _p).getString(key);
  @override
  Future<void> write(String key, String value) async => (await _p).setString(key, value);
  @override
  Future<void> remove(String key) async => (await _p).remove(key);
}

class MemoryCache implements KvCache {
  final _m = <String, String>{};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> remove(String key) async => _m.remove(key);
}

final kvCacheProvider = Provider<KvCache>((ref) => PrefsCache());

/// Gameplay config; cached so it is available offline / before login.
final configProvider = FutureProvider<GameConfig>((ref) async {
  final cache = ref.watch(kvCacheProvider);
  try {
    final raw = await ref.watch(apiClientProvider).get('/v1/config/gameplay');
    await cache.write('gameplay', jsonEncode(raw));
    return GameConfig.fromJson((raw as Map).cast<String, dynamic>());
  } catch (e) {
    final c = await cache.read('gameplay');
    if (c != null) return GameConfig.fromJson((jsonDecode(c) as Map).cast<String, dynamic>());
    rethrow;
  }
});

final codexProvider = FutureProvider.autoDispose<Codex>((ref) => ref.watch(apiProvider).codex());

final territoryProvider =
    FutureProvider.autoDispose.family<Territory, int>((ref, id) => ref.watch(apiProvider).territory(id));

final inboxUnreadProvider = FutureProvider.autoDispose<int>((ref) async {
  final p = await ref.watch(apiProvider).inbox(page: 1);
  return p.unread;
});

/// Disables Riverpod's automatic retry; errors are shown with a retry button.
Duration? noRetry(int retryCount, Object error) => null;
