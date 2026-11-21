import 'package:go_router/go_router.dart';

import '../../api/community_models.dart';
import 'compose_page.dart';
import 'feed_page.dart';
import 'post_detail_page.dart';
import 'profile_pages.dart';
import 'replay_page.dart';

/// Routes of the community content side (V2 batch 2, D-02…D-07, E-01).
/// Kept stable for the community home / messages / inbox deep links:
///
/// | path | page |
/// | --- | --- |
/// | `/community/feed?tab=following\|recommend` | 动态流 |
/// | `/posts/new?activity=<id>` (extra: [ComposeArgs]) | 发布动态 → pops the created [Post] |
/// | `/posts/:id?comment=1` (extra: [Post]) | 动态详情与评论 |
/// | `/users/:id` | 他人主页（自己的 id = 我的主页） |
/// | `/users/:id/followers`, `/users/:id/following` | 粉丝 / 关注 |
/// | `/me/profile` | 编辑资料（头像 / 昵称 / 签名） |
/// | `/me/blocks` | 黑名单 |
/// | `/me/collections` | 我的收藏 |
/// | `/replays` | 轨迹回放流 |
/// | `/replays/activity/:id` | 单条运动的回放 |
List<RouteBase> socialRoutes() {
  int id(GoRouterState s) => int.tryParse(s.pathParameters['id'] ?? '') ?? 0;
  return [
    GoRoute(
      path: '/community/feed',
      builder: (_, s) => FeedPage(initialTab: s.uri.queryParameters['tab'] ?? 'recommend'),
    ),
    GoRoute(
      path: '/posts/new',
      builder: (_, s) => ComposePage(
        args: s.extra is ComposeArgs ? s.extra! as ComposeArgs : const ComposeArgs(),
        activityId: int.tryParse(s.uri.queryParameters['activity'] ?? ''),
      ),
    ),
    GoRoute(
      path: '/posts/:id',
      builder: (_, s) => PostDetailPage(
        postId: id(s),
        initial: s.extra is Post ? s.extra! as Post : null,
        focusComment: s.uri.queryParameters['comment'] == '1',
      ),
    ),
    GoRoute(path: '/users/:id', builder: (_, s) => UserProfilePage(userId: id(s))),
    GoRoute(path: '/users/:id/followers', builder: (_, s) => FollowListPage(userId: id(s), followers: true)),
    GoRoute(path: '/users/:id/following', builder: (_, s) => FollowListPage(userId: id(s), followers: false)),
    GoRoute(path: '/me/profile', builder: (_, _) => const EditProfilePage()),
    GoRoute(path: '/me/blocks', builder: (_, _) => const BlocksPage()),
    GoRoute(path: '/me/collections', builder: (_, _) => const CollectionsPage()),
    GoRoute(path: '/replays', builder: (_, _) => const ReplayPage()),
    GoRoute(path: '/replays/activity/:id', builder: (_, s) => ReplayPage(activityId: id(s))),
  ];
}
