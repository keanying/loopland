import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import 'image_viewer.dart';
import 'report_sheet.dart';
import 'share_sheet.dart';
import 'social_providers.dart';
import 'social_widgets.dart';

/// D-02 动态卡片: author, text, images (1–9), run + track thumbnail,
/// like / comment / collect / share with optimistic toggles, 审核中 / 未通过
/// badges on my own posts. Reads the latest version from [postCacheProvider].
class PostCard extends ConsumerWidget {
  const PostCard({super.key, required this.post, this.onDeleted});
  final Post post;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = livePost(ref, post);
    if (p == null) return const SizedBox.shrink();
    final me = ref.watch(userProvider.select((u) => u?.id));
    final mine = p.author.id == me;
    void open() => context.push('/posts/${p.id}', extra: p);
    return Material(
      color: LL.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28), side: const BorderSide(color: LL.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            PostHeader(post: p, mine: mine, onDeleted: onDeleted),
            if (p.content.isNotEmpty) ...[
              const SizedBox(height: 10),
              PostText(text: p.content, maxLines: 6),
            ],
            if (p.images.isNotEmpty) ...[
              const SizedBox(height: 10),
              ImageGrid(images: p.images),
            ],
            if (p.activity != null) ...[
              const SizedBox(height: 10),
              RunThumb(activity: p.activity!, height: 170, onTap: open),
            ],
            const SizedBox(height: 12),
            PostActionBar(post: p, onComment: () => context.push('/posts/${p.id}?comment=1', extra: p)),
          ]),
        ),
      ),
    );
  }
}

/// Avatar, name, time · crew, review badge and the ⋮ menu.
class PostHeader extends ConsumerWidget {
  const PostHeader({super.key, required this.post, required this.mine, this.onDeleted, this.trailing, this.avatarSize = 44});
  final Post post;
  final bool mine;
  final VoidCallback? onDeleted;
  final Widget? trailing;
  final double avatarSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = post;
    final sub = [
      Fmt.relative(p.createdAt),
      if (p.author.crew != null) p.author.crew!.name,
      if (mine && p.visibility != 'public') visibilityNames[p.visibility] ?? p.visibility,
    ].where((s) => s.isNotEmpty).join(' · ');
    return Row(children: [
      UserAvatar(user: p.author, size: avatarSize, ring: true, onTap: () => openProfile(context, p.author)),
      const SizedBox(width: 10),
      Expanded(
        child: GestureDetector(
          onTap: () => openProfile(context, p.author),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(p.author.nickname,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
              ),
              if (mine && p.reviewStatus != ReviewStatus.approved) ...[
                const SizedBox(width: 6),
                Flexible(child: ReviewBadge(status: p.reviewStatus, reason: p.rejectReason)),
              ],
            ]),
            if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 12)),
          ]),
        ),
      ),
      ?trailing,
      PopupMenuButton<String>(
        tooltip: '更多',
        icon: const Icon(Icons.more_vert_rounded, color: LL.text2),
        color: LL.card2,
        onSelected: (v) async {
          switch (v) {
            case 'share':
              showShareSheet(context, ref, p);
            case 'report':
              showReportSheet(context, ref, targetType: 'post', targetId: p.id);
            case 'delete':
              if (await PostActions.delete(context, ref, p)) onDeleted?.call();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'share', child: Text('分享')),
          if (!mine) const PopupMenuItem(value: 'report', child: Text('举报')),
          if (mine) const PopupMenuItem(value: 'delete', child: Text('删除', style: TextStyle(color: LL.red))),
        ],
      ),
    ]);
  }
}

/// Post text with #话题 highlighted.
class PostText extends StatelessWidget {
  const PostText({super.key, required this.text, this.maxLines, this.fontSize = 15});
  final String text;
  final int? maxLines;
  final double fontSize;

  static final _tag = RegExp(r'#[^\s#]+');

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _tag.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(TextSpan(text: m.group(0), style: const TextStyle(color: LL.lime, fontWeight: FontWeight.w800)));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: TextStyle(fontSize: fontSize, height: 1.55, color: LL.text),
    );
  }
}

/// 1 image: one wide tile; 2 / 4: two columns; otherwise three columns.
/// Tapping opens the swipe viewer.
class ImageGrid extends StatelessWidget {
  const ImageGrid({super.key, required this.images, this.radius = 14});
  final List<PostImage> images;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final n = images.length.clamp(0, 9);
    if (n == 0) return const SizedBox.shrink();
    Widget tile(int i) => GestureDetector(
          onTap: () => showImageViewer(context, images, i),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Hero(tag: 'img-${images[i].url}-$i', child: NetImage(url: images[i].url)),
          ),
        );
    if (n == 1) {
      final a = images.first.aspect.clamp(0.75, 1.6);
      return LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth * (a < 1 ? 0.66 : 1);
        return SizedBox(width: w, child: AspectRatio(aspectRatio: a, child: tile(0)));
      });
    }
    final cols = (n == 2 || n == 4) ? 2 : 3;
    return GridView.count(
      crossAxisCount: cols,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      children: [for (var i = 0; i < n; i++) tile(i)],
    );
  }
}

/// Track thumbnail with distance / pace / area chips and a play hint.
class RunThumb extends StatelessWidget {
  const RunThumb({super.key, required this.activity, this.height = 170, this.onTap, this.onPlay, this.label});
  final PostActivity activity;
  final double height;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final a = activity;
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          height: height,
          child: Stack(children: [
            Positioned.fill(child: TrackView(track: a.track)),
            if (a.track.length < 2)
              Center(child: Text('${sportName(a.sport)} · 轨迹已隐藏', style: const TextStyle(color: LL.text3))),
            if (label != null)
              Positioned(top: 10, right: 10, child: StatChip(label!, color: LL.text2)),
            if (onPlay != null)
              Center(
                child: Material(
                  color: const Color(0xD9F4F4F5),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onPlay,
                    child: const SizedBox(width: 56, height: 56, child: Icon(Icons.play_arrow_rounded, color: LL.ink, size: 34)),
                  ),
                ),
              ),
            Positioned(
              left: 10,
              bottom: 10,
              right: 10,
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                StatChip('${Fmt.km(a.distanceM, digits: a.distanceM >= 10000 ? 1 : 2)} km'),
                StatChip(Fmt.pace(a.pace)),
                if (a.claimedAreaM2 > 0) StatChip('+${Fmt.area(a.claimedAreaM2)}', color: LL.lime),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// ♥ 128 · 💬 21 · 🔖 34 · ➤ 12.
class PostActionBar extends ConsumerWidget {
  const PostActionBar({super.key, required this.post, this.onComment, this.showComment = true});
  final Post post;
  final VoidCallback? onComment;
  final bool showComment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = post;
    return Row(children: [
      ActionPill(
        icon: p.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        color: p.liked ? LL.red : LL.text,
        label: compactCount(p.likeCount),
        tooltip: p.liked ? '取消点赞' : '点赞',
        onTap: () => PostActions.toggleLike(context, ref, p),
      ),
      if (showComment) ...[
        const SizedBox(width: 8),
        ActionPill(icon: Icons.chat_bubble_outline_rounded, label: compactCount(p.commentCount), tooltip: '评论', onTap: onComment),
      ],
      const SizedBox(width: 8),
      ActionPill(
        icon: p.collected ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
        color: p.collected ? LL.lime : LL.text,
        label: compactCount(p.collectCount),
        tooltip: p.collected ? '取消收藏' : '收藏',
        onTap: () => PostActions.toggleCollect(context, ref, p),
      ),
      const Spacer(),
      ActionPill(
        icon: Icons.near_me_outlined,
        label: compactCount(p.shareCount),
        tooltip: '分享',
        trailingIcon: true,
        onTap: () => showShareSheet(context, ref, p),
      ),
    ]);
  }
}

class ActionPill extends StatelessWidget {
  const ActionPill({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.color = LL.text,
    this.tooltip,
    this.trailingIcon = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color color;
  final String? tooltip;
  final bool trailingIcon;

  @override
  Widget build(BuildContext context) {
    final i = Icon(icon, size: 20, color: color);
    final t = Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14));
    return Semantics(
      button: true,
      label: tooltip,
      child: Material(
        color: LL.card2,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(mainAxisSize: MainAxisSize.min, children: trailingIcon ? [t, const SizedBox(width: 6), i] : [i, const SizedBox(width: 6), t]),
          ),
        ),
      ),
    );
  }
}
