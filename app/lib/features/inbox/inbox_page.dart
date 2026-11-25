import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_common.dart';
import '../../api/gathering_api.dart';
import '../../api/gathering_models.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/refresh.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import '../chat/conversations_page.dart';
import '../community/gathering_providers.dart';
import '../community/gathering_widgets.dart';
import '../../widgets/sound_refresh.dart';

/// Inbox categories (`GET /v1/inbox?category=`), in display order.
const inboxCategories = [
  ('interaction', '互动', LIcons.heartFilled, LL.pink),
  ('territory', '领地', LIcons.flagFilled, LL.yellow),
  ('monster', '怪兽', LIcons.flame, LL.orange),
  ('system', '系统', LIcons.megaphone, LL.sky),
];

/// Where tapping a notification goes, from `data.type` and the ids in
/// `data` (docs/api/v2-2-社区.md「消息与社区首页」). Null = nowhere.
String? inboxTarget(InboxItem it, {int? myCrewId}) {
  final d = it.data;
  int? id(String k) {
    final v = d[k];
    return v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  }

  String? posts(int? v) => v == null ? null : '/posts/$v';
  String? users(int? v) => v == null ? null : '/users/$v';
  final type = js(d['type']);
  switch (type) {
    case 'post':
      return posts(id('post_id') ?? id('id'));
    case 'user':
      return users(id('user_id') ?? id('id'));
    case 'like_post' || 'comment' || 'reply' || 'like_comment' || 'review_rejected':
      return posts(id('post_id'));
    case 'follow':
      return users(id('user_id'));
    case 'meetup_cancelled':
      final m = id('meetup_id');
      return m == null ? null : '/meetups/$m';
    case 'rally_created':
      final c = id('crew_id') ?? myCrewId;
      return c == null ? null : '/crews/$c';
    case 'race_finished':
      final r = id('race_id');
      return r == null ? null : '/races/$r';
  }
  if (id('territory_id') != null) return '/city/${id('territory_id')}';
  if (id('boss_id') != null) return '/bosses/${id('boss_id')}';
  if (id('post_id') != null) return posts(id('post_id'));
  if (id('meetup_id') != null) return '/meetups/${id('meetup_id')}';
  if (id('race_id') != null) return '/races/${id('race_id')}';
  if (id('user_id') != null) return users(id('user_id'));
  return null;
}

/// Short action label per notification type (prototype: 查看 / 回复 / 回关).
String? inboxAction(InboxItem it) => switch (js(it.data['type'])) {
      'comment' || 'reply' => '回复',
      'follow' => '回关',
      'like_post' || 'like_comment' || 'post' || 'race_finished' || 'meetup_cancelled' || 'rally_created' => '查看',
      _ when it.territoryId != null => '去看看',
      _ => null,
    };

/// 消息（D-13）：互动 / 领地 / 怪兽 / 系统 分类与未读数、私信 / 群聊、通知列表。
class InboxPage extends ConsumerStatefulWidget {
  const InboxPage({super.key});
  @override
  ConsumerState<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends ConsumerState<InboxPage> {
  /// null = 全部.
  String? _cat;
  List<InboxItem> _items = const [];
  int _total = 0, _page = 1;
  bool _loading = true;
  Object? _error;
  List<Conversation> _convs = const [];

  @override
  void initState() {
    super.initState();
    _load();
    _loadConversations();
  }

  GatheringApi get _api => ref.read(gatheringApiProvider);

  Future<void> _load({bool more = false}) async {
    setState(() => _loading = true);
    try {
      final page = more ? _page + 1 : 1;
      final p = await _api.inbox(category: _cat ?? 'all', page: page);
      if (!mounted) return;
      setState(() {
        _items = more ? [..._items, ...p.items] : p.items;
        _total = p.total;
        _page = page;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadConversations() async {
    try {
      final p = await _api.conversations(limit: 20);
      if (mounted) setState(() => _convs = p.items);
    } catch (_) {
      // The notifications still work; the section just stays empty.
    }
  }

  Future<void> _refresh() async {
    ref.invalidate(inboxSummaryProvider);
    await Future.wait([_load(), _loadConversations()]);
  }

  void _unreadChanged() => ref.read(refreshProvider).afterInboxRead();

  Future<void> _readAll() async {
    final n = await runGuarded(context, () => ref.read(apiProvider).markRead(all: true));
    if (n == null || !mounted) return;
    setState(() => _items = [for (final i in _items) i.copyWith(read: true)]);
    _unreadChanged();
  }

  Future<void> _open(InboxItem it) async {
    if (!it.read) {
      final n = await runGuarded(context, () => ref.read(apiProvider).markRead(ids: [it.id]));
      if (n != null && mounted) {
        setState(() => _items = [for (final i in _items) i.id == it.id ? i.copyWith(read: true) : i]);
        _unreadChanged();
      }
    }
    if (!mounted) return;
    final to = inboxTarget(it, myCrewId: ref.read(userProvider)?.crew?.id);
    if (to != null) context.push(to);
  }

  Future<void> _openConversation(Conversation c) async {
    await context.push('/chat/${c.id}', extra: c);
    if (!mounted) return;
    _loadConversations();
    _unreadChanged();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatEventsProvider, (_, _) {
      _loadConversations();
      ref.invalidate(inboxSummaryProvider);
    });
    final summary = ref.watch(inboxSummaryProvider).value;
    final unread = summary?.total ?? _items.where((i) => !i.read).length;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          BackHeader(
            title: '消息',
            subtitle: '$unread 条未读',
            trailing: TextButton(
                onPressed: (summary?.notifications ?? 1) == 0 ? null : _readAll, child: const Text('全部已读')),
          ),
          Expanded(
            child: SoundRefresh(
          onRefresh: _refresh,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Row(children: [
              for (final (i, (key, name, icon, color)) in inboxCategories.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: _CategoryTile(
                    key: Key('cat_$key'),
                    name: name,
                    icon: icon,
                    color: color,
                    count: summary?.of(key) ?? 0,
                    selected: _cat == key,
                    onTap: () {
                      setState(() => _cat = _cat == key ? null : key);
                      _load();
                    },
                  ),
                ),
              ],
            ]),
            SectionHeader(
              '私信 · 群聊${(summary?.chat ?? 0) > 0 ? '（${summary!.chat} 条未读）' : ''}',
              action: '全部',
              onAction: () async {
                await context.push('/conversations');
                if (!mounted) return;
                _loadConversations();
                _unreadChanged();
              },
            ),
            if (_convs.isEmpty)
              const LLCard(
                child: Text('还没有私信。在跑友主页点「私信」，或报名组局 / 集结跑进入群聊。',
                    style: TextStyle(color: LL.text2, height: 1.5)),
              )
            else
              SizedBox(
                height: 84,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _convs.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, i) => SizedBox(
                    width: 270,
                    child: ConversationTile(conversation: _convs[i], compact: true, onTap: () => _openConversation(_convs[i])),
                  ),
                ),
              ),
            SectionHeader(_cat == null ? '全部通知' : '${inboxCategories.firstWhere((c) => c.$1 == _cat).$2}通知'),
            if (_loading && _items.isEmpty)
              const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
            else if (_error != null && _items.isEmpty)
              ErrorBox(error: _error!, onRetry: _load)
            else if (_items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Text('暂无消息', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)),
              )
            else ...[
              for (final it in _items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _InboxTile(item: it, onTap: () => _open(it)),
                ),
              if (_items.length < _total)
                Center(
                  child: TextButton(onPressed: _loading ? null : () => _load(more: true), child: const Text('加载更多')),
                ),
            ],
          ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile(
      {super.key, required this.name, required this.icon, required this.color, required this.count, required this.selected, this.onTap});
  final String name;
  final LGlyph icon;
  final Color color;
  final int count;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? LL.card2 : LL.card,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22), side: BorderSide(color: selected ? color : LL.border, width: selected ? 1.5 : 1)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(children: [
            Stack(clipBehavior: Clip.none, children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: LIcon(icon, color: LL.ink, size: 22),
              ),
              Positioned(right: -10, top: -6, child: CountBadge(count: count)),
            ]),
            const SizedBox(height: 8),
            Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
        ),
      ),
    );
  }
}

class _InboxTile extends StatelessWidget {
  const _InboxTile({required this.item, required this.onTap});
  final InboxItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cat = inboxCategories.where((c) => c.$1 == item.category).firstOrNull ?? inboxCategories.last;
    final action = inboxAction(item);
    return LLCard(
      padding: const EdgeInsets.all(14),
      onTap: onTap,
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: cat.$4, shape: BoxShape.circle),
          child: LIcon(cat.$3, color: LL.ink),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            if (item.body.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: LL.card2, borderRadius: BorderRadius.circular(12)),
                child: Text(item.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, height: 1.4)),
              ),
            ],
            const SizedBox(height: 6),
            Text(Fmt.relative(item.createdAt), style: const TextStyle(color: LL.text3, fontSize: 12)),
          ]),
        ),
        if (action != null)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                  color: action == '回复' ? LL.lavender : (action == '回关' ? LL.lime : LL.text),
                  borderRadius: BorderRadius.circular(18)),
              child: Text(action, style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w800, fontSize: 13)),
            ),
          ),
        if (!item.read)
          Container(
            margin: const EdgeInsets.only(left: 8),
            width: 9,
            height: 9,
            decoration: const BoxDecoration(color: LL.red, shape: BoxShape.circle),
          ),
      ]),
    );
  }
}
