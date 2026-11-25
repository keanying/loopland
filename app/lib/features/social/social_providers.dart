import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_api.dart';
import '../../api/community_models.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../widgets/common.dart';
import '../../audio/audio.dart';
import '../../core/refresh.dart';

/// Latest known version of every post the user touched (like / collect /
/// comment counts), so the feed, the detail page and profiles stay in sync
/// after optimistic toggles. Deleted ids map to null.
final postCacheProvider = NotifierProvider<PostCache, Map<int, Post?>>(PostCache.new);

class PostCache extends Notifier<Map<int, Post?>> {
  @override
  Map<int, Post?> build() => const {};

  void put(Post p) => state = {...state, p.id: p};
  void markDeleted(int id) => state = {...state, id: null};
  bool isDeleted(int id) => state.containsKey(id) && state[id] == null;
}

/// [p] with any newer local version applied; null when it was deleted here.
Post? livePost(WidgetRef ref, Post p) {
  final m = ref.watch(postCacheProvider.select((m) => m.containsKey(p.id) ? (m[p.id], true) : (null, false)));
  return m.$2 ? m.$1 : p;
}

/// Optimistic like / collect toggles shared by cards and the detail page.
class PostActions {
  PostActions._();

  static Future<void> toggleLike(BuildContext context, WidgetRef ref, Post p) async {
    final cache = ref.read(postCacheProvider.notifier);
    final on = !p.liked;
    if (on) {
      ref.read(audioProvider)
        ..play(Sounds.like)
        ..haptic(HapticKind.light);
    }
    cache.put(p.copyWith(liked: on, likeCount: (p.likeCount + (on ? 1 : -1)).clamp(0, 1 << 31)));
    try {
      final r = await ref.read(communityApiProvider).likePost(p.id, on);
      final cur = ref.read(postCacheProvider)[p.id] ?? p;
      cache.put(cur.copyWith(liked: r.on, likeCount: r.count));
    } catch (e) {
      cache.put(p);
      if (context.mounted) showError(context, e);
    }
  }

  static Future<void> toggleCollect(BuildContext context, WidgetRef ref, Post p) async {
    final cache = ref.read(postCacheProvider.notifier);
    final on = !p.collected;
    cache.put(p.copyWith(collected: on, collectCount: (p.collectCount + (on ? 1 : -1)).clamp(0, 1 << 31)));
    try {
      final r = await ref.read(communityApiProvider).collectPost(p.id, on);
      final cur = ref.read(postCacheProvider)[p.id] ?? p;
      cache.put(cur.copyWith(collected: r.on, collectCount: r.count));
      if (context.mounted) toast(context, r.on ? '已收藏' : '已取消收藏');
    } catch (e) {
      cache.put(p);
      if (context.mounted) showError(context, e);
    }
  }

  static Future<bool> delete(BuildContext context, WidgetRef ref, Post p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('删除这条动态？'),
        content: const Text('删除后不可恢复，点赞和评论会一起删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return false;
    final done = await runGuarded(context, () async {
      await ref.read(communityApiProvider).deletePost(p.id);
      return true;
    });
    if (done == true) {
      ref.read(postCacheProvider.notifier).markDeleted(p.id);
      ref.read(refreshProvider).afterProfileChange(); // my post count
      if (context.mounted) toast(context, '已删除', kind: ToastKind.success);
      return true;
    }
    return false;
  }
}

final profileProvider =
    FutureProvider.autoDispose.family<Profile, int>((ref, id) => ref.watch(communityApiProvider).profile(id));

/// E-01: my follower / following / like counts come from my own profile.
final myProfileProvider = FutureProvider.autoDispose<Profile?>((ref) async {
  final id = ref.watch(userProvider.select((u) => u?.id));
  if (id == null) return null;
  return ref.watch(communityApiProvider).profile(id);
});

/// Composer: my recent settled outdoor runs to attach.
final recentRunsProvider = FutureProvider.autoDispose<List<Activity>>((ref) async {
  final p = await ref.watch(apiProvider).activities(pageSize: 10);
  return p.items.where((a) => a.status == 'settled' && gpsSports.contains(a.sport)).toList();
});

/// Entitlement keys that unlock 1080p replay export. The contract names it
/// `replay_1080p`; the plans API (v1) calls it `hd_replay_export`.
const replayExportEntitlements = {'replay_1080p', 'hd_replay_export'};

/// Whether the member may export the 1080p replay video: an active membership
/// whose plan carries the entitlement (when plans can't be loaded, an active
/// membership is enough — the server enforces it anyway).
final replayExportProvider = FutureProvider.autoDispose<bool>((ref) async {
  final u = ref.watch(userProvider);
  final m = u?.membership;
  if (m == null || !m.active) return false;
  try {
    final plans = await ref.watch(apiProvider).plans();
    final plan = plans.items.where((p) => p.code == m.planCode).firstOrNull;
    if (plan == null) return true;
    return plan.entitlements.any(replayExportEntitlements.contains);
  } catch (_) {
    return true;
  }
});
