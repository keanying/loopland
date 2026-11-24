import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_api.dart';
import '../../api/community_common.dart';
import '../../api/community_models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/cursor_list.dart';
import '../../widgets/l_icons.dart';
import '../ai/ai_widgets.dart';
import 'image_viewer.dart';
import 'post_card.dart';
import 'report_sheet.dart';
import 'share_sheet.dart';
import 'social_providers.dart';
import 'social_widgets.dart';
import '../../audio/audio.dart';

final postDetailProvider = FutureProvider.autoDispose.family<Post, int>((ref, id) async {
  final p = await ref.watch(communityApiProvider).post(id);
  ref.read(postCacheProvider.notifier).put(p);
  return p;
});

/// D-04 动态详情 (`/posts/:id`, optional `extra: Post` for an instant first
/// frame, `?comment=1` focuses the input): large images, full track, stats,
/// like / collect / share, follow author, two-level comments.
class PostDetailPage extends ConsumerStatefulWidget {
  const PostDetailPage({super.key, required this.postId, this.initial, this.focusComment = false});
  final int postId;
  final Post? initial;
  final bool focusComment;
  @override
  ConsumerState<PostDetailPage> createState() => _PostDetailPageState();
}

class _ReplyState {
  final loaded = <Comment>[];
  String? cursor;
  bool loading = false;
  bool done = false;
}

class _PostDetailPageState extends ConsumerState<PostDetailPage> {
  late final _comments =
      CursorPager<Comment>((cursor) => ref.read(communityApiProvider).comments(widget.postId, cursor: cursor));
  final _replyStates = <int, _ReplyState>{};
  final _input = TextEditingController();
  final _focus = FocusNode();
  Comment? _replyTarget; // the comment (or reply) being answered
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusComment) WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _comments.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ── comments ──

  void _reply(Comment c) {
    setState(() => _replyTarget = c);
    _focus.requestFocus();
  }

  void _bumpCommentCount(Post p, int delta) =>
      ref.read(postCacheProvider.notifier).put(p.copyWith(commentCount: (p.commentCount + delta).clamp(0, 1 << 31)));

  Future<void> _send(Post post, [String? quick]) async {
    final text = (quick ?? _input.text).trim();
    if (text.isEmpty || _sending) return;
    if (text.length > 200) {
      toast(context, '评论最多 200 字');
      return;
    }
    final target = _replyTarget;
    // Replying to a reply: parent is the top-level comment, reply_to its author.
    final parentId = target == null ? null : (target.parentId ?? target.id);
    final replyTo = target != null && target.parentId != null ? target.author.id : null;
    setState(() => _sending = true);
    final c = await runGuarded(
        context, () => ref.read(communityApiProvider).addComment(post.id, text, parentId: parentId, replyToUserId: replyTo));
    if (!mounted) return;
    setState(() => _sending = false);
    if (c == null) return;
    if (quick == null) _input.clear();
    _focus.unfocus();
    setState(() => _replyTarget = null);
    if (parentId == null) {
      _comments.hasMore ? _comments.insertFirst(c) : _comments.append(c);
    } else {
      _comments.replaceWhere((e) => e.id == parentId, (e) {
        final rs = _replyStates[parentId];
        if (rs != null && (rs.done || rs.loaded.isNotEmpty)) {
          rs.loaded.add(c);
          return e.copyWith(replyCount: e.replyCount + 1);
        }
        return e.copyWith(replyCount: e.replyCount + 1, replies: [...e.replies, c]);
      });
    }
    _bumpCommentCount(ref.read(postCacheProvider)[post.id] ?? post, 1);
    if (c.reviewStatus == ReviewStatus.pending && mounted) toast(context, '评论已提交，审核通过后其他人可见');
  }

  /// Applies [f] to the comment with [id], top-level or reply.
  void _update(int id, Comment Function(Comment) f) {
    _comments.replaceWhere((e) => e.id == id || e.replies.any((r) => r.id == id), (e) {
      if (e.id == id) return f(e);
      return e.copyWith(replies: [for (final r in e.replies) r.id == id ? f(r) : r]);
    });
    for (final rs in _replyStates.values) {
      for (var i = 0; i < rs.loaded.length; i++) {
        if (rs.loaded[i].id == id) rs.loaded[i] = f(rs.loaded[i]);
      }
    }
    setState(() {});
  }

  Future<void> _likeComment(Comment c) async {
    final on = !c.liked;
    if (on) {
      ref.read(audioProvider)
        ..play(Sounds.like)
        ..haptic(HapticKind.light);
    }
    _update(c.id, (e) => e.copyWith(liked: on, likeCount: (e.likeCount + (on ? 1 : -1)).clamp(0, 1 << 31)));
    try {
      final r = await ref.read(communityApiProvider).likeComment(c.id, on);
      _update(c.id, (e) => e.copyWith(liked: r.on, likeCount: r.count));
    } catch (e) {
      _update(c.id, (_) => c);
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deleteComment(Post post, Comment c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('删除这条评论？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await runGuarded(context, () async {
      await ref.read(communityApiProvider).deleteComment(c.id);
      return true;
    });
    if (done != true || !mounted) return;
    if (c.isTopLevel) {
      _comments.removeWhere((e) => e.id == c.id);
      _bumpCommentCount(ref.read(postCacheProvider)[post.id] ?? post, -(1 + c.replyCount));
    } else {
      _comments.replaceWhere((e) => e.id == c.parentId, (e) => e.copyWith(
            replyCount: (e.replyCount - 1).clamp(0, 1 << 31),
            replies: e.replies.where((r) => r.id != c.id).toList(),
          ));
      _replyStates[c.parentId]?.loaded.removeWhere((r) => r.id == c.id);
      _bumpCommentCount(ref.read(postCacheProvider)[post.id] ?? post, -1);
    }
    if (mounted) toast(context, '已删除', kind: ToastKind.success);
  }

  Future<void> _moreReplies(Comment parent) async {
    final rs = _replyStates.putIfAbsent(parent.id, _ReplyState.new);
    if (rs.loading || rs.done) return;
    setState(() => rs.loading = true);
    try {
      final page = await ref.read(communityApiProvider).replies(parent.id, cursor: rs.cursor);
      final known = {...parent.replies.map((e) => e.id), ...rs.loaded.map((e) => e.id)};
      rs.loaded.addAll(page.items.where((e) => !known.contains(e.id)));
      rs.cursor = page.nextCursor;
      rs.done = !page.hasMore;
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => rs.loading = false);
    }
  }

  Future<void> _commentMenu(Post post, Comment c, bool canDelete) async {
    final me = ref.read(userProvider)?.id;
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (s) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const LIcon(LIcons.reply), title: const Text('回复'), onTap: () => Navigator.pop(s, 'reply')),
          if (c.author.id != me)
            ListTile(leading: const LIcon(LIcons.flag), title: const Text('举报'), onTap: () => Navigator.pop(s, 'report')),
          if (canDelete)
            ListTile(
              leading: const LIcon(LIcons.trash, color: LL.red),
              title: const Text('删除', style: TextStyle(color: LL.red)),
              onTap: () => Navigator.pop(s, 'delete'),
            ),
        ]),
      ),
    );
    if (!mounted) return;
    switch (v) {
      case 'reply':
        _reply(c);
      case 'report':
        showReportSheet(context, ref, targetType: 'comment', targetId: c.id);
      case 'delete':
        _deleteComment(post, c);
    }
  }

  // ── build ──

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(postDetailProvider(widget.postId));
    final base = async.value ?? widget.initial;
    if (base == null) {
      return Scaffold(
        body: SafeArea(
          child: Column(children: [
            const BackHeader(title: '动态详情'),
            Expanded(
              child: AsyncBody<Post>(
                value: async,
                onRetry: () => ref.invalidate(postDetailProvider(widget.postId)),
                data: (_) => const SizedBox.shrink(),
              ),
            ),
          ]),
        ),
      );
    }
    final post = livePost(ref, base);
    if (post == null) {
      return const Scaffold(
        body: SafeArea(child: Column(children: [BackHeader(title: '动态详情'), Expanded(child: Center(child: Text('动态已删除')))])),
      );
    }
    final me = ref.watch(userProvider)?.id;
    final mine = post.author.id == me;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          BackHeader(
            title: '动态详情',
            trailing: RoundIconButton(icon: LIcons.share, tooltip: '分享', onTap: () => showShareSheet(context, ref, post)),
          ),
          Expanded(
            child: CursorListView<Comment>(
              pager: _comments,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              separator: 14,
              empty: '还没有评论，来抢沙发',
              header: _header(post, mine),
              itemBuilder: (context, c, _) => _commentTile(post, c, me),
            ),
          ),
          _inputBar(post),
        ]),
      ),
    );
  }

  List<Widget> _header(Post post, bool mine) {
    final a = post.activity;
    return [
      PostHeader(
        post: post,
        mine: mine,
        avatarSize: 52,
        onDeleted: () => Navigator.of(context).maybePop(),
        trailing: mine ? null : _AuthorFollow(user: post.author),
      ),
      if (post.reviewStatus == ReviewStatus.rejected && mine && (post.rejectReason ?? '').isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('未通过原因：${post.rejectReason}', style: const TextStyle(color: LL.red, fontSize: 13)),
        ),
      if (post.reviewStatus == ReviewStatus.pending && mine)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('审核通过前只有你自己能看到这条动态', style: TextStyle(color: LL.yellow, fontSize: 13)),
        ),
      if (post.content.isNotEmpty) ...[
        const SizedBox(height: 12),
        PostText(text: post.content, fontSize: 17),
      ],
      if (post.aiReport != null) ...[
        const SizedBox(height: 12),
        AIReportBlock(text: post.aiReport!.text, aiGenerated: post.aiReport!.aiGenerated),
      ],
      if (post.images.isNotEmpty) ...[
        const SizedBox(height: 12),
        _LargeImages(images: post.images),
      ],
      if (a != null) ...[
        const SizedBox(height: 12),
        RunThumb(
          activity: a,
          height: 260,
          label: '轨迹回放',
          onPlay: () => context.push('/replays/activity/${a.id}'),
        ),
        const SizedBox(height: 10),
        Row(children: [
          _Stat(value: Fmt.km(a.distanceM), label: 'km'),
          _Stat(value: Fmt.duration(a.durationSec), label: '用时'),
          _Stat(value: Fmt.pace(a.pace), label: '配速'),
          _Stat(
              value: a.claimedAreaM2 > 0 ? '+${(a.claimedAreaM2 / 1e6).toStringAsFixed(2)}' : '0',
              label: '圈地 km²',
              color: LL.orange),
        ]),
      ],
      const SizedBox(height: 12),
      PostActionBar(post: post, showComment: false),
      const SizedBox(height: 20),
      Text('评论 ${post.commentCount}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
      const SizedBox(height: 12),
    ];
  }

  Widget _commentTile(Post post, Comment c, int? me) {
    final rs = _replyStates[c.id];
    final shown = [...c.replies, ...?rs?.loaded];
    final more = c.replyCount - shown.length;
    bool canDelete(Comment x) => x.author.id == me || post.author.id == me;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _CommentRow(
        comment: c,
        onReply: () => _reply(c),
        onLike: () => _likeComment(c),
        onMore: () => _commentMenu(post, c, canDelete(c)),
        mine: c.author.id == me,
      ),
      if (shown.isNotEmpty || more > 0)
        Padding(
          padding: const EdgeInsets.only(left: 50, top: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final r in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _CommentRow(
                  comment: r,
                  small: true,
                  onReply: () => _reply(r),
                  onLike: () => _likeComment(r),
                  onMore: () => _commentMenu(post, r, canDelete(r)),
                  mine: r.author.id == me,
                ),
              ),
            if (more > 0 && !(rs?.done ?? false))
              GestureDetector(
                onTap: () => _moreReplies(c),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(rs?.loading == true ? '加载中…' : '展开更多回复（$more）',
                      style: const TextStyle(color: LL.lavender, fontWeight: FontWeight.w700, fontSize: 13)),
                ),
              ),
          ]),
        ),
    ]);
  }

  Widget _inputBar(Post post) {
    final target = _replyTarget;
    const quick = ['加油！', '求路线', '带我一个', '周六见'];
    return Container(
      decoration: const BoxDecoration(color: LL.night, border: Border(top: BorderSide(color: LL.border))),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (target == null)
          SizedBox(
            height: 34,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final q in quick)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      side: const BorderSide(color: LL.border),
                      textStyle: const TextStyle(fontSize: 13, fontFamilyFallback: LL.fonts),
                    ),
                    onPressed: _sending ? null : () => _send(post, q),
                    child: Text(q),
                  ),
                ),
            ]),
          )
        else
          Row(children: [
            Expanded(
              child: Text('回复 @${target.author.nickname}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.lavender, fontSize: 13)),
            ),
            GestureDetector(
              onTap: () => setState(() => _replyTarget = null),
              child: const Text('取消', style: TextStyle(color: LL.text3, fontSize: 13)),
            ),
          ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              maxLength: 200,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(post),
              decoration: InputDecoration(
                counterText: '',
                isDense: true,
                hintText: target == null ? '说点什么，给 ${post.author.nickname} 加个油…' : '回复 ${target.author.nickname}',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(26), borderSide: const BorderSide(color: LL.border)),
                enabledBorder:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(26), borderSide: const BorderSide(color: LL.border)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(72, 48)),
            onPressed: _sending ? null : () => _send(post),
            child: const Text('发送'),
          ),
        ]),
      ]),
    );
  }
}

class _AuthorFollow extends ConsumerStatefulWidget {
  const _AuthorFollow({required this.user});
  final UserBrief user;
  @override
  ConsumerState<_AuthorFollow> createState() => _AuthorFollowState();
}

class _AuthorFollowState extends ConsumerState<_AuthorFollow> {
  bool? _following;

  Future<void> _toggle(Relation rel) async {
    final on = !(_following ?? rel.following);
    setState(() => _following = on);
    try {
      final r = await ref.read(communityApiProvider).follow(widget.user.id, on);
      if (mounted) setState(() => _following = r);
      ref.invalidate(myProfileProvider);
    } catch (e) {
      if (mounted) {
        setState(() => _following = !on);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rel = ref.watch(profileProvider(widget.user.id)).value?.relation;
    if (rel == null || rel.anyBlock || widget.user.isDeleted) return const SizedBox.shrink();
    return FollowButton(following: _following ?? rel.following, followedBy: rel.followedBy, onTap: () => _toggle(rel));
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({
    required this.comment,
    required this.onReply,
    required this.onLike,
    required this.onMore,
    this.small = false,
    this.mine = false,
  });
  final Comment comment;
  final VoidCallback onReply;
  final VoidCallback onLike;
  final VoidCallback onMore;
  final bool small;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final c = comment;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onReply,
      onLongPress: onMore,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        UserAvatar(user: c.author, size: small ? 30 : 40, onTap: () => openProfile(context, c.author)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: c.author.nickname),
                    if (c.replyTo != null) ...[
                      const TextSpan(text: ' 回复 ', style: TextStyle(color: LL.text3, fontWeight: FontWeight.w400)),
                      TextSpan(text: c.replyTo!.nickname),
                    ],
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w800, color: LL.text2, fontSize: small ? 13 : 14),
                ),
              ),
              if (mine && c.reviewStatus != ReviewStatus.approved) ...[
                const SizedBox(width: 6),
                ReviewBadge(status: c.reviewStatus),
              ],
            ]),
            const SizedBox(height: 2),
            Text(c.content, style: TextStyle(fontSize: small ? 14 : 15, height: 1.45)),
            const SizedBox(height: 4),
            Row(children: [
              Text(Fmt.relative(c.createdAt), style: const TextStyle(color: LL.text3, fontSize: 12)),
              const SizedBox(width: 14),
              GestureDetector(
                onTap: onReply,
                child: const Text('回复', style: TextStyle(color: LL.text2, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 14),
              GestureDetector(
                onTap: onMore,
                child: const LIcon(LIcons.moreH, color: LL.text3, size: 18, semanticLabel: '更多'),
              ),
            ]),
          ]),
        ),
        Semantics(
          button: true,
          label: c.liked ? '取消点赞评论' : '点赞评论',
          child: GestureDetector(
            onTap: onLike,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Column(children: [
                LIcon(c.liked ? LIcons.heartFilled : LIcons.heart,
                    size: 20, color: c.liked ? LL.red : LL.text2),
                Text('${c.likeCount}', style: const TextStyle(color: LL.text2, fontSize: 12)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.color = LL.text});
  final String value;
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(color: LL.card, borderRadius: BorderRadius.circular(18)),
          child: Column(children: [
            FittedBox(child: Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: color))),
            Text(label, style: const TextStyle(color: LL.text2, fontSize: 12)),
          ]),
        ),
      );
}

/// Swipeable large images with a page indicator; tap opens the viewer.
class _LargeImages extends StatefulWidget {
  const _LargeImages({required this.images});
  final List<PostImage> images;
  @override
  State<_LargeImages> createState() => _LargeImagesState();
}

class _LargeImagesState extends State<_LargeImages> {
  int _i = 0;
  @override
  Widget build(BuildContext context) {
    final imgs = widget.images;
    final aspect = imgs.first.aspect.clamp(0.75, 1.6);
    return Column(children: [
      AspectRatio(
        aspectRatio: aspect,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: PageView.builder(
            itemCount: imgs.length,
            onPageChanged: (i) => setState(() => _i = i),
            itemBuilder: (context, i) => GestureDetector(
              onTap: () => showImageViewer(context, imgs, i),
              child: NetImage(url: imgs[i].url),
            ),
          ),
        ),
      ),
      if (imgs.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < imgs.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _i ? 16 : 6,
                height: 6,
                decoration: BoxDecoration(color: i == _i ? LL.lime : LL.text3, borderRadius: BorderRadius.circular(3)),
              ),
          ]),
        ),
    ]);
  }
}
