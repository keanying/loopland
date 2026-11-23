import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_api.dart';
import '../../api/community_common.dart';
import '../../api/community_models.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/cursor_list.dart';
import '../../widgets/l_icons.dart';
import 'post_card.dart';

/// D-02 动态流 (`/community/feed?tab=following|recommend`): 关注 / 推荐,
/// cursor infinite scroll, pull to refresh. Each tab keeps its own list and
/// scroll position.
class FeedPage extends ConsumerStatefulWidget {
  const FeedPage({super.key, this.initialTab = 'recommend'});
  final String initialTab;
  @override
  ConsumerState<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends ConsumerState<FeedPage> {
  static const tabs = ['following', 'recommend'];
  late int _tab = widget.initialTab == 'following' ? 0 : 1;
  late final _visited = {_tab}; // a tab's list loads when first shown
  late final List<CursorPager<Post>> _pagers = [
    for (final t in tabs) CursorPager<Post>((cursor) => ref.read(communityApiProvider).feed(t, cursor: cursor)),
  ];

  @override
  void dispose() {
    for (final p in _pagers) {
      p.dispose();
    }
    super.dispose();
  }

  Future<void> _compose() async {
    final p = await context.push<Post>('/posts/new');
    if (p == null || !mounted) return;
    // My new post shows at the top of 关注 (it includes my own posts).
    if (_visited.contains(0)) _pagers[0].insertFirst(p); // otherwise its first load includes it
    setState(() => _visited.add(_tab = 0));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  RoundIconButton(
                    icon: LIcons.back,
                    tooltip: '返回',
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text('动态', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                  ),
                  RoundIconButton(
                    icon: LIcons.playCircle,
                    tooltip: '轨迹回放',
                    onTap: () => context.push('/replays'),
                  ),
                  const SizedBox(width: 8),
                  RoundIconButton(icon: LIcons.plus, tooltip: '发动态', color: LL.lime, fg: LL.ink, onTap: _compose),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: PillTabs(
                labels: const ['关注', '推荐'],
                index: _tab,
                onChanged: (i) => setState(() => _visited.add(_tab = i)),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    if (!_visited.contains(i))
                      const SizedBox.shrink()
                    else
                      CursorListView<Post>(
                        key: PageStorageKey('feed-${tabs[i]}'),
                        pager: _pagers[i],
                        empty: i == 0 ? '还没有关注的人发动态\n去「推荐」看看，关注喜欢的跑友吧' : '最近 7 天还没有新动态',
                        itemBuilder: (context, p, _) =>
                            PostCard(post: p, onDeleted: () => _pagers[i].removeWhere((e) => e.id == p.id)),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
