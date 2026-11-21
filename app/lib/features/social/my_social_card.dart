import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_models.dart';
import '../../auth/auth_controller.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'social_providers.dart';
import 'social_widgets.dart';

/// E-01 on 我的: 关注 / 粉丝 / 获赞 (from `GET /v1/users/{my id}`), plus
/// 发动态 / 收藏 / 我的主页 shortcuts.
class MySocialCard extends ConsumerWidget {
  const MySocialCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(userProvider.select((u) => u?.id));
    final p = ref.watch(myProfileProvider).value;
    String n(int? v) => v == null ? '-' : compactCount(v);
    Widget count(String value, String label, VoidCallback? onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(children: [
                Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                Text(label, style: const TextStyle(color: LL.text2, fontSize: 12)),
              ]),
            ),
          ),
        );
    return Column(children: [
      LLCard(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(children: [
          if (p?.postCount != null) count(n(p!.postCount), '动态', id == null ? null : () => context.push('/users/$id')),
          count(n(p?.followingCount), '关注', id == null ? null : () => context.push('/users/$id/following')),
          count(n(p?.followerCount), '粉丝', id == null ? null : () => context.push('/users/$id/followers')),
          count(n(p?.likeReceivedCount), '获赞', id == null ? null : () => context.push('/users/$id')),
        ]),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          flex: 4,
          child: FilledButton.icon(
            onPressed: () => context.push<Post>('/posts/new'),
            icon: const Icon(Icons.add_rounded),
            label: const Text('发动态'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(side: const BorderSide(color: LL.border), backgroundColor: LL.card),
            onPressed: () => context.push('/me/collections'),
            icon: const Icon(Icons.bookmark_border_rounded, size: 20),
            label: const Text('收藏'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(side: const BorderSide(color: LL.border), backgroundColor: LL.card),
            onPressed: id == null ? null : () => context.push('/users/$id'),
            icon: const Icon(Icons.person_outline_rounded, size: 20),
            label: const Text('主页'),
          ),
        ),
      ]),
    ]);
  }
}
