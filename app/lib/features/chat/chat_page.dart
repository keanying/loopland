import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_api.dart';
import '../../api/community_common.dart';
import '../../api/community_models.dart' show PostImage;
import '../../api/errors.dart';
import '../../api/gathering_api.dart';
import '../../api/gathering_models.dart';
import '../../auth/auth_controller.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/cursor_list.dart';
import '../../widgets/l_icons.dart';
import '../community/gathering_providers.dart';
import '../social/image_viewer.dart';
import '../social/social_widgets.dart';
import 'conversations_page.dart';
import 'pick_image.dart';

/// `/chat/direct/:userId`: opens (or creates) the direct conversation via
/// `POST /v1/conversations/direct`, then shows it.
class DirectChatPage extends ConsumerStatefulWidget {
  const DirectChatPage({super.key, required this.userId});
  final int userId;
  @override
  ConsumerState<DirectChatPage> createState() => _DirectChatPageState();
}

class _DirectChatPageState extends ConsumerState<DirectChatPage> {
  late Future<Conversation> _f = _open();

  Future<Conversation> _open() => ref.read(gatheringApiProvider).openDirect(widget.userId);

  @override
  Widget build(BuildContext context) => FutureBuilder<Conversation>(
        future: _f,
        builder: (context, snap) {
          if (snap.hasData) return ChatPage(conversationId: snap.data!.id, initial: snap.data);
          return Scaffold(
            body: SafeArea(
              child: Column(children: [
                const BackHeader(title: '私信'),
                Expanded(
                  child: snap.hasError
                      ? ErrorBox(error: snap.error!, onRetry: () => setState(() => _f = _open()))
                      : const Center(child: CircularProgressIndicator()),
                ),
              ]),
            ),
          );
        },
      );
}

/// 聊天：文字 / 图片 / 分享的动态 / 系统消息；向上翻历史（`before`）；实时收消息
/// 与已读回执；免打扰、删除会话 / 退出群聊；陌生人限制、拉黑、内容拦截的提示。
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.conversationId, this.initial});
  final int conversationId;

  /// Passed by lists (route `extra`) so the header shows at once; otherwise
  /// looked up in the conversation list.
  final Conversation? initial;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  late final CursorPager<ChatMessage> _pager;
  final _text = TextEditingController();
  final _focus = FocusNode();
  Conversation? _conv;
  bool _sending = false;

  /// Last error from sending (stranger_limit / blocked / content_blocked…).
  ApiException? _sendError;

  /// Highest message id the peer has read (from `conversation_read`).
  int _peerRead = 0;
  int _markedRead = 0;

  int get _id => widget.conversationId;
  GatheringApi get _api => ref.read(gatheringApiProvider);
  int? get _me => ref.read(userProvider)?.id;

  @override
  void initState() {
    super.initState();
    _conv = widget.initial;
    _peerRead = widget.initial?.peerReadMessageId ?? 0;
    _pager = CursorPager((cursor) => _api.messages(_id, before: cursor))..addListener(_onPage);
    // Always refresh: the header may be missing and the peer's read
    // position may have moved since the list was loaded.
    _api.findConversation(_id).then((c) {
      if (mounted && c != null) {
        setState(() {
          _conv = c;
          if (c.peerReadMessageId > _peerRead) _peerRead = c.peerReadMessageId;
        });
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _pager
      ..removeListener(_onPage)
      ..dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onPage() => _markRead();

  /// Marks everything up to the newest loaded message as read.
  void _markRead() {
    final newest = _pager.items.firstOrNull;
    if (newest == null || newest.id <= _markedRead) return;
    _markedRead = newest.id;
    _api.markConversationRead(_id, newest.id).then((_) {
      if (mounted) ref.invalidate(inboxSummaryProvider);
    }).catchError((_) {});
  }

  void _add(ChatMessage m) {
    if (_pager.items.any((x) => x.id == m.id)) return;
    _pager.insertFirst(m);
  }

  void _onEvent(ChatEvent e) {
    switch (e) {
      case ChatMessageEvent(:final message) when message.conversationId == _id:
        _add(message);
        if (message.sender?.id != _me) _markRead();
      case ConversationReadEvent(:final conversationId, :final userId, :final messageId)
          when conversationId == _id && userId != _me:
        if (messageId > _peerRead) setState(() => _peerRead = messageId);
      default:
    }
  }

  Future<void> _send(Future<ChatMessage> Function() f, {VoidCallback? onSent}) async {
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      final m = await f();
      if (!mounted) return;
      _add(m);
      onSent?.call();
    } catch (e) {
      if (mounted) setState(() => _sendError = ApiException.from(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendText() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    if (t.runes.length > 500) {
      toast(context, '一条消息最多 500 字');
      return;
    }
    await _send(() => _api.sendText(_id, t), onSent: _text.clear);
  }

  Future<void> _sendImage() async {
    if (_sending) return;
    final picked = await ref.read(singleImagePickerProvider)();
    if (picked == null || !mounted) return;
    await _send(() async {
      final up = await ref.read(communityApiProvider).uploadMedia(picked.bytes, filename: picked.name, purpose: 'chat');
      return _api.sendImage(_id, up.id);
    });
  }

  Future<void> _menu() async {
    final c = _conv;
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (s) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (c?.peer != null)
            ListTile(
              leading: const LIcon(LIcons.user),
              title: const Text('查看主页'),
              onTap: () => Navigator.pop(s, 'profile'),
            ),
          if (c?.refType == 'meetup' && c?.refId != null)
            ListTile(
              leading: const LIcon(LIcons.calendar),
              title: const Text('组局详情'),
              onTap: () => Navigator.pop(s, 'ref'),
            ),
          ListTile(
            leading: LIcon((c?.muted ?? false) ? LIcons.bellRing : LIcons.bellOff),
            title: Text((c?.muted ?? false) ? '取消免打扰' : '消息免打扰'),
            onTap: () => Navigator.pop(s, 'mute'),
          ),
          ListTile(
            leading: const LIcon(LIcons.trash, color: LL.red),
            title: Text((c?.isGroup ?? false) ? '退出群聊' : '删除会话', style: const TextStyle(color: LL.red)),
            onTap: () => Navigator.pop(s, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted || v == null) return;
    switch (v) {
      case 'profile':
        context.push('/users/${c!.peer!.id}');
      case 'ref':
        context.push('/meetups/${c!.refId}');
      case 'mute':
        final muted = !(c?.muted ?? false);
        final ok = await runGuarded(context, () async {
          await _api.muteConversation(_id, muted);
          return true;
        });
        if (ok == true && mounted) {
          setState(() => _conv = c?.copyWith(muted: muted));
          toast(context, muted ? '已开启免打扰' : '已取消免打扰');
        }
      case 'delete':
        final conv = c ?? Conversation(id: _id);
        if (!await confirmLeave(context, conv) || !mounted) return;
        final ok = await runGuarded(context, () async {
          await _api.deleteConversation(_id);
          return true;
        });
        if (ok == true && mounted) {
          ref.invalidate(inboxSummaryProvider);
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/inbox');
          }
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatEventsProvider, (_, next) {
      final e = next.value;
      if (e != null) _onEvent(e);
    });
    final me = ref.watch(userProvider)?.id;
    final c = _conv;
    final title = c?.displayTitle ?? '聊天';
    final subtitle = c == null
        ? null
        : c.isGroup
            ? (c.refType == 'meetup' ? '组局群聊' : (c.refType == 'rally' ? '集结跑群聊' : '群聊'))
            : (c.peer?.crew?.name ?? '私信');
    final blocked = _sendError?.code == 'blocked';
    // My newest message (for the read receipt in direct chats).
    final myLatest = _pager.items.where((m) => m.sender?.id == me && !m.isSystem).firstOrNull?.id;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          BackHeader(
            title: title,
            subtitle: [?subtitle, if (c?.muted ?? false) '免打扰'].join(' · '),
            trailing: RoundIconButton(icon: LIcons.moreH, tooltip: '更多', onTap: _menu),
          ),
          const Divider(),
          Expanded(
            child: GestureDetector(
              onTap: () => _focus.unfocus(),
              child: CursorListView<ChatMessage>(
                pager: _pager,
                reverse: true,
                separator: 8,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                empty: c?.isGroup ?? false ? '群聊已创建，打个招呼吧' : '打个招呼吧',
                itemBuilder: (context, m, i) {
                  final older = i + 1 < _pager.items.length ? _pager.items[i + 1] : null;
                  final showTime = older == null ||
                      (m.createdAt != null &&
                          older.createdAt != null &&
                          m.createdAt!.difference(older.createdAt!).inMinutes >= 5);
                  final mine = m.sender?.id == me && me != null;
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (showTime && m.createdAt != null) _TimeLabel(m.createdAt!),
                    MessageBubble(
                      message: m,
                      mine: mine,
                      showName: c?.isGroup ?? false,
                      receipt: mine && !(c?.isGroup ?? true) && m.id == myLatest
                          ? (_peerRead >= m.id ? '已读' : '已送达')
                          : null,
                    ),
                  ]);
                },
              ),
            ),
          ),
          if (_sendError != null) _ErrorBanner(error: _sendError!, onClose: () => setState(() => _sendError = null)),
          _Composer(
            controller: _text,
            focus: _focus,
            sending: _sending,
            enabled: !blocked,
            onSend: _sendText,
            onImage: _sendImage,
          ),
        ]),
      ),
    );
  }
}

class _TimeLabel extends StatelessWidget {
  const _TimeLabel(this.t);
  final DateTime t;
  @override
  Widget build(BuildContext context) {
    final l = t.toLocal();
    final n = DateTime.now();
    final today = l.year == n.year && l.month == n.month && l.day == n.day;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(DateFormat(today ? 'HH:mm' : 'MM-dd HH:mm').format(l),
          textAlign: TextAlign.center, style: const TextStyle(color: LL.text3, fontSize: 12)),
    );
  }
}

/// One chat message. System messages are a centred grey line.
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message, required this.mine, this.showName = false, this.receipt});
  final ChatMessage message;
  final bool mine;
  final bool showName;

  /// 「已读」/「已送达」 under my latest message in a direct chat.
  final String? receipt;

  @override
  Widget build(BuildContext context) {
    final m = message;
    if (m.isSystem) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(color: LL.card, borderRadius: BorderRadius.circular(12)),
          child: Text(m.content, style: const TextStyle(color: LL.text3, fontSize: 12)),
        ),
      );
    }
    final body = switch (m.type) {
      'image' when m.imageUrl != null => _ImageBody(message: m),
      'post' => _PostBody(message: m, mine: mine),
      _ => GestureDetector(
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: m.content));
            toast(context, '已复制', kind: ToastKind.success);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: mine ? LL.lime : LL.card2,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(mine ? 18 : 4),
                bottomRight: Radius.circular(mine ? 4 : 18),
              ),
            ),
            child: Text(m.content, style: TextStyle(color: mine ? LL.ink : LL.text, fontSize: 15, height: 1.4)),
          ),
        ),
    };
    final sender = m.sender!;
    final column = Column(
      crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showName && !mine)
          Padding(
            padding: const EdgeInsets.only(bottom: 3, left: 2),
            child: Text(sender.nickname, style: const TextStyle(color: LL.text3, fontSize: 12)),
          ),
        body,
        if (receipt != null)
          Padding(
            padding: const EdgeInsets.only(top: 3, right: 2),
            child: Text(receipt!, style: TextStyle(color: receipt == '已读' ? LL.text3 : LL.text2, fontSize: 11)),
          ),
      ],
    );
    final avatar = UserAvatar(user: sender, size: 36, onTap: () => openProfile(context, sender));
    return Row(
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!mine) ...[avatar, const SizedBox(width: 8)],
        Flexible(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 270), child: column)),
        if (mine) ...[const SizedBox(width: 8), avatar],
      ],
    );
  }
}

class _ImageBody extends StatelessWidget {
  const _ImageBody({required this.message});
  final ChatMessage message;
  @override
  Widget build(BuildContext context) {
    final w = message.imageWidth ?? 0, h = message.imageHeight ?? 0;
    final aspect = w > 0 && h > 0 ? (w / h).clamp(0.5, 2.0) : 1.0;
    final url = message.imageUrl!;
    return GestureDetector(
      onTap: () => showImageViewer(context, [PostImage(url: url, width: w, height: h)], 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(width: 180, child: AspectRatio(aspectRatio: aspect, child: NetImage(url: url))),
      ),
    );
  }
}

/// A shared post (`payload.post_id`): tap opens it.
class _PostBody extends StatelessWidget {
  const _PostBody({required this.message, required this.mine});
  final ChatMessage message;
  final bool mine;
  @override
  Widget build(BuildContext context) {
    final id = message.postId;
    return Material(
      color: LL.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: LL.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: id == null ? null : () => context.push('/posts/$id'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(12)),
              child: const LIcon(LIcons.doc, color: LL.ink),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                const Text('分享了一条动态', style: TextStyle(fontWeight: FontWeight.w800)),
                Text(message.content.isNotEmpty ? message.content : '点击查看动态详情',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 12)),
              ]),
            ),
            const LIcon(LIcons.chevronRight, color: LL.text3),
          ]),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.error, required this.onClose});
  final ApiException error;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    final hint = switch (error.code) {
      'stranger_limit' => '对方回复或关注你之后就可以继续聊了。',
      'content_blocked' => '修改一下内容再发送。',
      'blocked' => '无法给对方发消息。',
      'muted' => '禁言结束后才能发送消息。',
      _ => null,
    };
    return Container(
      key: const Key('chat_error'),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: const Color(0x22FF5A6E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: LL.red.withValues(alpha: 0.5)),
      ),
      child: Row(children: [
        const LIcon(LIcons.alert, color: LL.red, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text([error.displayMessage, ?hint].join(' '), style: const TextStyle(color: LL.text, fontSize: 13, height: 1.4)),
        ),
        IconButton(onPressed: onClose, icon: const LIcon(LIcons.close, size: 18, color: LL.text3)),
      ]),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.sending,
    required this.enabled,
    required this.onSend,
    required this.onImage,
  });
  final TextEditingController controller;
  final FocusNode focus;
  final bool sending, enabled;
  final VoidCallback onSend, onImage;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: const BoxDecoration(color: LL.night, border: Border(top: BorderSide(color: LL.border))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        RoundIconButton(icon: LIcons.image, size: 46, tooltip: '发图片', onTap: enabled && !sending ? onImage : null),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            key: const Key('chat_input'),
            controller: controller,
            focusNode: focus,
            enabled: enabled,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => onSend(),
            inputFormatters: [LengthLimitingTextInputFormatter(500)],
            decoration: InputDecoration(
              hintText: enabled ? '发消息…' : '无法发送消息',
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 8),
        RoundIconButton(
          icon: sending ? LIcons.hourglass : LIcons.send,
          size: 46,
          color: LL.lime,
          fg: LL.ink,
          tooltip: '发送',
          onTap: enabled && !sending ? onSend : null,
        ),
      ]),
    );
  }
}
