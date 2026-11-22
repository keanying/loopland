import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/errors.dart';
import '../api/loopland_api.dart';
import '../api/models.dart';
import '../core/providers.dart';
import 'run_store.dart';

// 浏览器里没有 App 的文件目录：用内存版（只在当前标签页里保留）
final runStoreProvider = Provider<RunStore>((ref) => kIsWeb ? MemoryRunStore() : RunStore());

final uploaderProvider = Provider<Uploader>(
    (ref) => Uploader(api: ref.watch(apiProvider), store: ref.watch(runStoreProvider)));

/// Pending (not yet acknowledged) uploads, for the 我的 page banner.
final pendingUploadsProvider =
    FutureProvider.autoDispose<List<PendingUpload>>((ref) => ref.watch(runStoreProvider).pending());

/// Persists every finished activity before sending it, and retries with the
/// same `client_id` until the server answers.
class Uploader {
  Uploader({required this.api, required this.store});
  final LooplandApi api;
  final RunStore store;

  /// Upload one activity. It is written to disk first; on success it is
  /// removed. On failure it stays queued and the error is rethrown.
  Future<ActivityResult> submit(ActivityUpload u) async {
    await store.savePending(PendingUpload(upload: u));
    return _attempt(PendingUpload(upload: u));
  }

  Future<ActivityResult> _attempt(PendingUpload p) async {
    try {
      final r = await api.uploadActivity(p.upload);
      await store.removePending(p.upload.clientId);
      return r;
    } catch (e) {
      final ex = ApiException.from(e);
      await store.savePending(PendingUpload(upload: p.upload, attempts: p.attempts + 1, lastError: ex.message));
      rethrow;
    }
  }

  Future<ActivityResult> retry(String clientId) async {
    final all = await store.pending();
    final p = all.firstWhere((e) => e.upload.clientId == clientId);
    return _attempt(p);
  }

  /// Tries every queued upload once; stops at the first network failure.
  /// Returns the results that went through.
  Future<List<ActivityResult>> flush() async {
    final out = <ActivityResult>[];
    for (final p in await store.pending()) {
      try {
        out.add(await _attempt(p));
      } on ApiException catch (e) {
        if (e.isNetwork ||
            const {'unauthorized', 'consent_required', 'phone_required', 'account_banned', 'rate_limited'}.contains(e.code)) {
          break;
        }
      }
    }
    return out;
  }
}
