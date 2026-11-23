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
import 'media_picker.dart';
import 'post_card.dart';
import 'report_sheet.dart';
import 'social_providers.dart';
import 'social_widgets.dart';

/// Route of the direct chat (built by the messaging side).
String directChatPath(int userId) => '/chat/direct/$userId';

/// Asks before blocking / unblocking. Returns true when done.
Future<bool> confirmBlock(BuildContext context, WidgetRef ref, UserBrief u, {required bool block}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(block ? '拉黑 ${u.nickname}？' : '取消拉黑 ${u.nickname}？'),
      content: Text(block ? '拉黑后你们会互相取消关注，看不到对方的动态和评论，也不能私信。' : '取消后对方可以重新关注你、给你发私信。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(block ? '拉黑' : '取消拉黑')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final done = await runGuarded(context, () async {
    await ref.read(communityApiProvider).block(u.id, block);
    return true;
  });
  if (done == true && context.mounted) toast(context, block ? '已拉黑' : '已取消拉黑');
  return done == true;
}

/// D-07 他人主页 (`/users/:id`; my own id shows my page with 编辑资料).
class UserProfilePage extends ConsumerStatefulWidget {
  const UserProfilePage({super.key, required this.userId});
  final int userId;
  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage> {
  late final _posts = CursorPager<Post>((c) => ref.read(communityApiProvider).userPosts(widget.userId, cursor: c));
  Relation? _rel; // local override after follow / block
  int _followerDelta = 0;
  bool _busy = false;

  @override
  void dispose() {
    _posts.dispose();
    super.dispose();
  }

  Future<void> _follow(Profile p) async {
    final rel = _rel ?? p.relation;
    final on = !rel.following;
    setState(() {
      _busy = true;
      _rel = rel.copyWith(following: on);
      _followerDelta += on ? 1 : -1;
    });
    try {
      final r = await ref.read(communityApiProvider).follow(p.user.id, on);
      if (mounted && r != on) {
        setState(() {
          _rel = rel.copyWith(following: r);
          _followerDelta += r ? 1 : -1;
        });
      }
      ref.invalidate(myProfileProvider);
    } catch (e) {
      if (mounted) {
        setState(() {
          _rel = rel;
          _followerDelta -= on ? 1 : -1;
        });
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _block(Profile p, bool block) async {
    final rel = _rel ?? p.relation;
    if (!await confirmBlock(context, ref, p.user, block: block) || !mounted) return;
    setState(() {
      if (block && rel.following) _followerDelta -= 1;
      _rel = rel.copyWith(blocked: block, following: block ? false : rel.following);
    });
    _posts.refresh();
    ref.invalidate(myProfileProvider);
  }

  Future<void> _menu(Profile p) async {
    final rel = _rel ?? p.relation;
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (s) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const LIcon(LIcons.flag), title: const Text('举报'), onTap: () => Navigator.pop(s, 'report')),
          ListTile(
            leading: LIcon(rel.blocked ? LIcons.unlock : LIcons.block, color: rel.blocked ? LL.text : LL.red),
            title: Text(rel.blocked ? '取消拉黑' : '拉黑', style: TextStyle(color: rel.blocked ? LL.text : LL.red)),
            onTap: () => Navigator.pop(s, 'block'),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    if (v == 'report') showReportSheet(context, ref, targetType: 'user', targetId: p.user.id);
    if (v == 'block') _block(p, !rel.blocked);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(profileProvider(widget.userId));
    final me = ref.watch(userProvider)?.id;
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<Profile>(
          value: async,
          onRetry: () => ref.invalidate(profileProvider(widget.userId)),
          data: (p) {
            final self = p.isSelf || p.user.id == me;
            final rel = _rel ?? p.relation;
            return Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(children: [
                  RoundIconButton(icon: LIcons.back, tooltip: '返回', onTap: () => Navigator.of(context).maybePop()),
                  const Spacer(),
                  if (self)
                    RoundIconButton(icon: LIcons.pencil, tooltip: '编辑资料', onTap: () => context.push('/me/profile'))
                  else
                    RoundIconButton(icon: LIcons.moreH, tooltip: '更多', onTap: () => _menu(p)),
                ]),
              ),
              Expanded(
                child: CursorListView<Post>(
                  pager: _posts,
                  empty: rel.blockedBy
                      ? '暂时看不到 TA 的动态'
                      : rel.blocked
                          ? '你已拉黑对方，看不到 TA 的动态'
                          : (self ? '还没有发过动态' : 'TA 还没有发过动态'),
                  header: [
                    _ProfileCard(
                      profile: p.copyWith(relation: rel, followerCount: p.followerCount + _followerDelta),
                      self: self,
                      busy: _busy,
                      onFollow: () => _follow(p),
                      onUnblock: () => _block(p, false),
                    ),
                    const SizedBox(height: 12),
                    _StatTiles(profile: p),
                    const SizedBox(height: 18),
                    Text(self ? '我的动态' : 'TA 的动态', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 10),
                  ],
                  itemBuilder: (context, post, _) =>
                      PostCard(post: post, onDeleted: () => _posts.removeWhere((e) => e.id == post.id)),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile, required this.self, required this.busy, required this.onFollow, required this.onUnblock});
  final Profile profile;
  final bool self;
  final bool busy;
  final VoidCallback onFollow;
  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final u = p.user;
    final rel = p.relation;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: LL.card, borderRadius: BorderRadius.circular(32), border: Border.all(color: LL.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          UserAvatar(user: u, size: 72, ring: true),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(u.nickname, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
              if (u.crew != null)
                GestureDetector(
                  onTap: () => context.push('/crews/${u.crew!.id}'),
                  child: Text('「${u.crew!.name}」', style: const TextStyle(color: LL.lavender)),
                ),
            ]),
          ),
          if (!self && !rel.anyBlock && !u.isDeleted)
            FollowButton(following: rel.following, followedBy: rel.followedBy, height: 44, onTap: busy ? null : onFollow),
        ]),
        if (p.bio.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const LIcon(LIcons.flame, color: LL.orange, size: 18),
            const SizedBox(width: 6),
            Expanded(child: Text(p.bio, style: const TextStyle(color: LL.text, height: 1.4))),
          ]),
        ],
        const SizedBox(height: 16),
        Row(children: [
          if (p.postCount != null) _Count(value: p.postCount!, label: '动态'),
          _Count(value: p.followerCount, label: '粉丝', onTap: () => context.push('/users/${u.id}/followers')),
          _Count(value: p.followingCount, label: '关注', onTap: () => context.push('/users/${u.id}/following')),
          _Count(value: p.likeReceivedCount, label: '获赞'),
        ]),
        if (!self) ...[
          const SizedBox(height: 14),
          if (rel.blocked)
            Row(children: [
              const Expanded(child: Text('你已拉黑对方', style: TextStyle(color: LL.red))),
              OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)), onPressed: onUnblock, child: const Text('取消拉黑')),
            ])
          else
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: rel.anyBlock || u.isDeleted ? null : () => context.push(directChatPath(u.id)),
                  icon: const LIcon(LIcons.mail, size: 18),
                  label: const Text('私信'),
                ),
              ),
            ]),
          if (rel.blockedBy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('对方设置了权限，你们暂时不能互动', style: TextStyle(color: LL.text3, fontSize: 12)),
            ),
        ],
      ]),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.value, required this.label, this.onTap});
  final int value;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              Text(compactCount(value), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              Text(label, style: const TextStyle(color: LL.text2, fontSize: 12)),
            ]),
          ),
        ),
      );
}

class _StatTiles extends StatelessWidget {
  const _StatTiles({required this.profile});
  final Profile profile;
  @override
  Widget build(BuildContext context) {
    final p = profile;
    Widget tile(String v, String label, {Color? bg, bool dark = false}) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: bg ?? LL.card,
              borderRadius: BorderRadius.circular(22),
              border: bg == null ? Border.all(color: LL.border) : null,
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FittedBox(
                child: Text(v, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: dark ? LL.ink : LL.text)),
              ),
              Text(label, maxLines: 1, style: TextStyle(fontSize: 12, color: dark ? const Color(0xFF3A2A1A) : LL.text2)),
            ]),
          ),
        );
    return Row(children: [
      tile((p.territoryAreaM2 / 1e6).toStringAsFixed(2), '领地 km² · ${p.territoryCount} 块', bg: LL.orange, dark: true),
      const SizedBox(width: 8),
      tile(Fmt.km(p.totalDistanceM, digits: 1), '累计 km'),
      const SizedBox(width: 8),
      tile('${p.codexCount}', '图鉴'),
    ]);
  }
}

/// 粉丝 / 关注 lists (`/users/:id/followers`, `/users/:id/following`).
class FollowListPage extends ConsumerStatefulWidget {
  const FollowListPage({super.key, required this.userId, required this.followers});
  final int userId;
  final bool followers;
  @override
  ConsumerState<FollowListPage> createState() => _FollowListPageState();
}

class _FollowListPageState extends ConsumerState<FollowListPage> {
  late final _pager = CursorPager<FollowEntry>((c) {
    final api = ref.read(communityApiProvider);
    return widget.followers ? api.followers(widget.userId, cursor: c) : api.following(widget.userId, cursor: c);
  });

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Future<void> _toggle(FollowEntry e) async {
    final on = !e.following;
    _pager.replaceWhere((x) => x.user.id == e.user.id, (x) => x.copyWith(following: on));
    try {
      await ref.read(communityApiProvider).follow(e.user.id, on);
      ref.invalidate(myProfileProvider);
    } catch (err) {
      _pager.replaceWhere((x) => x.user.id == e.user.id, (x) => x.copyWith(following: !on));
      if (mounted) showError(context, err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(userProvider)?.id;
    final self = widget.userId == me;
    final title = widget.followers ? (self ? '我的粉丝' : '粉丝') : (self ? '我的关注' : '关注');
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          BackHeader(title: title),
          Expanded(
            child: CursorListView<FollowEntry>(
              pager: _pager,
              separator: 8,
              empty: widget.followers ? '还没有粉丝' : '还没有关注任何人',
              itemBuilder: (context, e, _) => UserRow(
                user: e.user,
                subtitle: e.followedAt == null ? null : '${Fmt.date(e.followedAt)} 关注',
                trailing: e.user.id == me ? null : FollowButton(following: e.following, onTap: () => _toggle(e)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Avatar + name + crew row that opens the profile.
class UserRow extends StatelessWidget {
  const UserRow({super.key, required this.user, this.subtitle, this.trailing});
  final UserBrief user;
  final String? subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final sub = subtitle ?? (user.crew == null ? null : '「${user.crew!.name}」');
    return LLCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      onTap: () => openProfile(context, user),
      child: Row(children: [
        UserAvatar(user: user, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(user.nickname, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            if (sub != null) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 12)),
          ]),
        ),
        ?trailing,
      ]),
    );
  }
}

final blocksProvider = FutureProvider.autoDispose<List<BlockEntry>>((ref) => ref.watch(communityApiProvider).blocks());

/// 黑名单 (`/me/blocks`).
class BlocksPage extends ConsumerWidget {
  const BlocksPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(blocksProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '黑名单', subtitle: '拉黑的人看不到你的动态，也不能关注你、给你发私信'),
          Expanded(
            child: AsyncBody<List<BlockEntry>>(
              value: async,
              onRetry: () => ref.invalidate(blocksProvider),
              data: (list) => list.isEmpty
                  ? const Center(child: Text('黑名单是空的', style: TextStyle(color: LL.text2)))
                  : RefreshIndicator(
                      onRefresh: () => ref.refresh(blocksProvider.future),
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final b = list[i];
                          return UserRow(
                            user: b.user,
                            subtitle: b.blockedAt == null ? null : '${Fmt.date(b.blockedAt)} 拉黑',
                            trailing: OutlinedButton(
                              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                              onPressed: () async {
                                if (await confirmBlock(context, ref, b.user, block: false)) ref.invalidate(blocksProvider);
                              },
                              child: const Text('取消拉黑'),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// 我的收藏 (`/me/collections`).
class CollectionsPage extends ConsumerStatefulWidget {
  const CollectionsPage({super.key});
  @override
  ConsumerState<CollectionsPage> createState() => _CollectionsPageState();
}

class _CollectionsPageState extends ConsumerState<CollectionsPage> {
  late final _pager = CursorPager<Post>((c) => ref.read(communityApiProvider).collections(cursor: c));

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            const BackHeader(title: '我的收藏'),
            Expanded(
              child: CursorListView<Post>(
                pager: _pager,
                empty: '还没有收藏的动态',
                itemBuilder: (context, p, _) => PostCard(post: p, onDeleted: () => _pager.removeWhere((e) => e.id == p.id)),
              ),
            ),
          ]),
        ),
      );
}

/// 编辑资料 (`/me/profile`): avatar (upload purpose=avatar), nickname, bio.
/// Post-moderation: changes show immediately and are reviewed afterwards.
class EditProfilePage extends ConsumerStatefulWidget {
  const EditProfilePage({super.key});
  @override
  ConsumerState<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends ConsumerState<EditProfilePage> {
  final _name = TextEditingController();
  final _bio = TextEditingController();
  bool _loaded = false;
  bool _saving = false;
  double? _avatarProgress;

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _avatar() async {
    final PickedImage? img;
    try {
      img = await ref.read(mediaPickerProvider).pickOne();
    } catch (_) {
      if (mounted) toast(context, '无法打开相册，请在系统设置里允许圈圈访问照片');
      return;
    }
    if (img == null || !mounted) return;
    setState(() => _avatarProgress = 0);
    final api = ref.read(communityApiProvider);
    final u = await runGuarded(context, () async {
      final m = await api.uploadMedia(img!.bytes, filename: img.name, purpose: 'avatar', onProgress: (s, t) {
        if (t > 0 && mounted) setState(() => _avatarProgress = s / t);
      });
      return api.updateProfile(avatarUrl: m.url);
    });
    if (!mounted) return;
    setState(() => _avatarProgress = null);
    if (u != null) {
      ref.read(authProvider.notifier).setUser(u);
      ref.invalidate(myProfileProvider);
      toast(context, '头像已更新，审核中（未通过会恢复默认头像）');
    }
  }

  Future<void> _save(Profile p) async {
    final name = _name.text.trim();
    final bio = _bio.text.trim();
    if (name.isEmpty) {
      toast(context, '昵称不能为空');
      return;
    }
    final changedName = name != p.user.nickname;
    final changedBio = bio != p.bio;
    if (!changedName && !changedBio) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _saving = true);
    final u = await runGuarded(
        context,
        () => ref
            .read(communityApiProvider)
            .updateProfile(nickname: changedName ? name : null, bio: changedBio ? bio : null));
    if (!mounted) return;
    setState(() => _saving = false);
    if (u == null) return;
    ref.read(authProvider.notifier).setUser(u);
    ref.invalidate(myProfileProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).maybePop();
    messenger?..removeCurrentSnackBar()..showSnackBar(const SnackBar(content: Text('已保存，审核中（未通过会恢复默认并通知你）')));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(myProfileProvider);
    final user = ref.watch(userProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '编辑资料'),
          Expanded(
            child: AsyncBody<Profile?>(
              value: async,
              onRetry: () => ref.invalidate(myProfileProvider),
              data: (p) {
                if (p == null) return const SizedBox.shrink();
                if (!_loaded) {
                  _loaded = true;
                  _name.text = user?.nickname ?? p.user.nickname;
                  _bio.text = p.bio;
                }
                final brief = UserBrief(id: p.user.id, nickname: user?.nickname ?? p.user.nickname, avatarUrl: user?.avatarUrl ?? p.user.avatarUrl);
                return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
                  Center(
                    child: GestureDetector(
                      onTap: _avatarProgress == null ? _avatar : null,
                      child: Stack(alignment: Alignment.center, children: [
                        UserAvatar(user: brief, size: 96, ring: true),
                        if (_avatarProgress != null)
                          SizedBox(
                            width: 96,
                            height: 96,
                            child: CircularProgressIndicator(value: _avatarProgress! <= 0 ? null : _avatarProgress, strokeWidth: 4),
                          ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(color: LL.lime, shape: BoxShape.circle),
                            child: const LIcon(LIcons.camera, size: 18, color: LL.ink, semanticLabel: '更换头像'),
                          ),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text('昵称', style: TextStyle(color: LL.text2)),
                  const SizedBox(height: 6),
                  TextField(key: const Key('edit-nickname'), controller: _name, maxLength: 16),
                  const SizedBox(height: 8),
                  const Text('签名', style: TextStyle(color: LL.text2)),
                  const SizedBox(height: 6),
                  TextField(
                    key: const Key('edit-bio'),
                    controller: _bio,
                    maxLength: 60,
                    maxLines: 3,
                    minLines: 2,
                    decoration: const InputDecoration(hintText: '介绍一下自己，比如「每天 5 公里」'),
                  ),
                  const SizedBox(height: 8),
                  const Text('昵称、头像和签名修改后立即生效，随后进入审核；审核未通过会恢复为默认值，并通过站内信通知你。',
                      style: TextStyle(color: LL.text3, fontSize: 12, height: 1.5)),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: _saving ? null : () => _save(p), child: Text(_saving ? '保存中…' : '保存')),
                ]);
              },
            ),
          ),
        ]),
      ),
    );
  }
}
