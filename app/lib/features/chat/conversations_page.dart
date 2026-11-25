import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_common.dart' show CursorPager;
import '../../api/gathering_api.dart';
import '../../api/gathering_models.dart';
import '../../core/format.dart';
import '../../core/refresh.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/cursor_list.dart';
import '../../widgets/l_icons.dart';
import '../community/gathering_providers.dart';
import '../community/gathering_widgets.dart';

/// One conversation row: avatar, title, last message, time, unread.
class ConversationTile extends StatelessWidget {
  const ConversationTile({super.key, required this.conversation, this.onTap, this.compact = false});
  final Conversation conversation;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = conversation;
    final last = c.lastMessage;
    final preview = last == null
        ? (c.isGroup ? '群聊已创建' : '打个招呼吧')
        : (c.isGroup && last.sender != null ? '${last.sender!.nickname}：${last.preview}' : last.preview);
    final avatar = c.isGroup
        ? Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: c.refType == 'rally' ? LL.lavender : LL.pink, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: c.avatarUrl != null
                ? PersonAvatar(name: c.displayTitle, url: c.avatarUrl, size: 48)
                : Text(c.displayTitle.isEmpty ? '群' : String.fromCharCodes(c.displayTitle.runes.take(1)),
                    style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: 20)),
          )
        : PersonAvatar(name: c.displayTitle, url: c.peer?.avatarUrl ?? c.avatarUrl, size: 48, color: LL.orange);
    return LLCard(
      padding: const EdgeInsets.all(14),
      onTap: onTap,
      child: Row(children: [
        avatar,
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Flexible(
                child: Text(c.isGroup ? '${c.displayTitle} · 群聊' : c.displayTitle,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
              ),
              if (c.muted) const Padding(padding: EdgeInsets.only(left: 4), child: LIcon(LIcons.bellOff, size: 14, color: LL.text3)),
            ]),
            const SizedBox(height: 2),
            Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 13)),
          ]),
        ),
        if (!compact || c.unreadCount > 0)
          Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
            if (!compact) Text(Fmt.relative(c.updatedAt ?? last?.createdAt), style: const TextStyle(color: LL.text3, fontSize: 11)),
            if (!compact) const SizedBox(height: 4),
            CountBadge(count: c.unreadCount, muted: c.muted),
          ]),
      ]),
    );
  }
}

/// 私信 / 群聊 列表（cursor 分页，按最后消息时间倒序）。长按：免打扰、删除 / 退出。
class ConversationsPage extends ConsumerStatefulWidget {
  const ConversationsPage({super.key});
  @override
  ConsumerState<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends ConsumerState<ConversationsPage> {
  late final CursorPager<Conversation> _pager;

  GatheringApi get _api => ref.read(gatheringApiProvider);

  @override
  void initState() {
    super.initState();
    _pager = CursorPager((cursor) => _api.conversations(cursor: cursor));
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Future<void> _open(Conversation c) async {
    _pager.replaceWhere((x) => x.id == c.id, (x) => x.copyWith(unreadCount: 0));
    await context.push('/chat/${c.id}', extra: c);
    if (mounted) _pager.refresh();
  }

  Future<void> _actions(Conversation c) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (s) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: LIcon(c.muted ? LIcons.bellRing : LIcons.bellOff),
            title: Text(c.muted ? '取消免打扰' : '消息免打扰'),
            onTap: () => Navigator.pop(s, 'mute'),
          ),
          ListTile(
            leading: const LIcon(LIcons.trash, color: LL.red),
            title: Text(c.isGroup ? '退出群聊' : '删除会话', style: const TextStyle(color: LL.red)),
            onTap: () => Navigator.pop(s, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted || v == null) return;
    if (v == 'mute') {
      final ok = await runGuarded(context, () async {
        await _api.muteConversation(c.id, !c.muted);
        return true;
      });
      if (ok == true) _pager.replaceWhere((x) => x.id == c.id, (x) => x.copyWith(muted: !c.muted));
    } else {
      if (!await confirmLeave(context, c)) return;
      if (!mounted) return;
      final ok = await runGuarded(context, () async {
        await _api.deleteConversation(c.id);
        return true;
      });
      if (ok == true) {
        _pager.removeWhere((x) => x.id == c.id);
        ref.read(refreshProvider).afterInboxRead();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatEventsProvider, (_, next) {
      if (next.value is ChatMessageEvent) _pager.refresh();
    });
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '私信 · 群聊', subtitle: '长按可设置免打扰或删除'),
          Expanded(
            child: CursorListView<Conversation>(
              pager: _pager,
              separator: 10,
              empty: '还没有会话。在跑友主页点「私信」，或报名组局 / 集结跑进入群聊。',
              itemBuilder: (context, c, _) => GestureDetector(
                onLongPress: () => _actions(c),
                child: ConversationTile(conversation: c, onTap: () => _open(c)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Confirms 删除会话 / 退出群聊 (退出组局的群聊同时取消报名).
Future<bool> confirmLeave(BuildContext context, Conversation c) async =>
    await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(c.isGroup ? '退出群聊？' : '删除会话？'),
        content: Text(c.isGroup
            ? (c.refType == 'meetup' ? '退出后不再接收群消息，组局报名也会一并取消。' : '退出后不再接收群消息。')
            : '会话会从列表隐藏，对方发来新消息时会重新出现。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(c.isGroup ? '退出' : '删除')),
        ],
      ),
    ) ==
    true;
