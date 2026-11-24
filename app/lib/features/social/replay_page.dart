import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_api.dart';
import '../../api/community_common.dart';
import '../../api/community_models.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import 'social_providers.dart';
import 'social_widgets.dart';
import '../../widgets/sound_refresh.dart';
import '../../audio/audio.dart';

/// D-06 轨迹回放: vertical pages from `/v1/replays` (`/replays`), or one run
/// (`/replays/activity/:id`, `GET /v1/activities/{id}/replay`). Each track is
/// drawn over 15–30 s depending on the run's duration.
class ReplayPage extends ConsumerStatefulWidget {
  const ReplayPage({super.key, this.activityId});
  final int? activityId;
  @override
  ConsumerState<ReplayPage> createState() => _ReplayPageState();
}

class _ReplayPageState extends ConsumerState<ReplayPage> {
  late final CursorPager<Replay> _pager = CursorPager<Replay>((cursor) async {
    final api = ref.read(communityApiProvider);
    if (widget.activityId != null) return CursorPage([await api.activityReplay(widget.activityId!)], null);
    return api.replays(cursor: cursor);
  });
  final _page = PageController();
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _pager.addListener(_changed);
    _pager.refresh();
  }

  @override
  void dispose() {
    _pager.removeListener(_changed);
    _pager.dispose();
    _page.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _onPage(int i) {
    setState(() => _index = i);
    if (i >= _pager.items.length - 2) _pager.loadMore();
  }

  Future<void> _like(Replay r) async {
    final on = !r.liked;
    if (on) {
      ref.read(audioProvider)
        ..play(Sounds.like)
        ..haptic(HapticKind.light);
    }
    _pager.replaceWhere(
      (e) => e.postId == r.postId,
      (e) => e.copyWith(liked: on, likeCount: (e.likeCount + (on ? 1 : -1)).clamp(0, 1 << 31)),
    );
    try {
      final res = await ref.read(communityApiProvider).likePost(r.postId, on);
      _pager.replaceWhere((e) => e.postId == r.postId, (e) => e.copyWith(liked: res.on, likeCount: res.count));
      final cached = ref.read(postCacheProvider)[r.postId];
      if (cached != null) {
        ref.read(postCacheProvider.notifier).put(cached.copyWith(liked: res.on, likeCount: res.count));
      }
    } catch (e) {
      _pager.replaceWhere((e) => e.postId == r.postId, (_) => r);
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _pager.items;
    final canExport = ref.watch(replayExportProvider).value ?? false;
    Widget body;
    if (items.isEmpty) {
      body = _pager.error != null
          ? ErrorBox(error: _pager.error!, onRetry: _pager.refresh)
          : _pager.initialLoading
          ? const Center(child: CircularProgressIndicator())
          : const Center(
              child: Text('还没有可回放的轨迹', style: TextStyle(color: LL.text2)),
            );
    } else {
      body = SoundRefresh(
        onRefresh: _pager.refresh,
        child: PageView.builder(
          controller: _page,
          scrollDirection: Axis.vertical,
          itemCount: items.length,
          onPageChanged: _onPage,
          itemBuilder: (_, i) => ReplayView(
            key: ValueKey('replay-${items[i].postId}'),
            replay: items[i],
            active: i == _index,
            canExport: canExport,
            onLike: () => _like(items[i]),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: LL.night,
      body: Stack(
        children: [
          Positioned.fill(child: body),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    RoundIconButton(
                      icon: LIcons.back,
                      tooltip: '返回',
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 14),
                    const Text('轨迹回放', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One full-screen replay: animated track, author, stats, like, export.
class ReplayView extends StatefulWidget {
  const ReplayView({
    super.key,
    required this.replay,
    required this.active,
    required this.onLike,
    this.canExport = false,
  });
  final Replay replay;
  final bool active;
  final bool canExport;
  final VoidCallback onLike;
  @override
  State<ReplayView> createState() => _ReplayViewState();
}

class _ReplayViewState extends State<ReplayView> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: widget.replay.playback);
  late final _track = [for (final p in widget.replay.points) p.latLng];
  late final _times = [for (final p in widget.replay.points) p.t];

  @override
  void initState() {
    super.initState();
    if (widget.active) _anim.forward();
  }

  @override
  void didUpdateWidget(covariant ReplayView old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _anim.forward(from: 0);
    if (!widget.active && old.active) _anim.stop();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_anim.isAnimating) {
      _anim.stop();
    } else {
      _anim.isCompleted ? _anim.forward(from: 0) : _anim.forward();
    }
    setState(() {});
  }

  void _export() => showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('导出 1080p 视频'),
      content: const Text('会员专属的 1080p 回放视频导出即将上线，敬请期待。'),
      actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('好的'))],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final r = widget.replay;
    final a = r.activity;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _anim,
              builder: (_, _) => TrackView(
                track: _track,
                times: _times.length == _track.length && _times.last > 0 ? _times : null,
                progress: _anim.value,
                padding: 48,
                strokeWidth: 5,
              ),
            ),
          ),
          // Author.
          Positioned(
            left: 16,
            right: 16,
            top: MediaQuery.paddingOf(context).top + 72,
            child: GestureDetector(
              onTap: () => openProfile(context, r.author),
              child: Row(
                children: [
                  UserAvatar(user: r.author, size: 48, ring: true),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.author.nickname, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                        Text(
                          [
                            if (r.author.crew != null) r.author.crew!.name,
                            sportName(a.sport),
                            if (a.startTime != null) Fmt.relative(a.startTime),
                          ].join(' · '),
                          style: const TextStyle(color: LL.text2, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Pause hint.
          AnimatedBuilder(
            animation: _anim,
            builder: (_, _) => !_anim.isAnimating && widget.active
                ? Center(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: const BoxDecoration(color: Color(0x66F4F4F5), shape: BoxShape.circle),
                      child: LIcon(
                        _anim.isCompleted ? LIcons.replay : LIcons.play,
                        color: LL.text,
                        size: 40,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          // Side actions.
          Positioned(
            right: 12,
            bottom: bottom + 150,
            child: Column(
              children: [
                _SideButton(
                  icon: r.liked ? LIcons.heartFilled : LIcons.heart,
                  color: r.liked ? LL.red : LL.text,
                  label: compactCount(r.likeCount),
                  tooltip: r.liked ? '取消点赞' : '点赞',
                  onTap: widget.onLike,
                ),
                const SizedBox(height: 14),
                _SideButton(
                  icon: LIcons.chat,
                  label: '评论',
                  tooltip: '查看动态',
                  onTap: () => context.push('/posts/${r.postId}'),
                ),
              ],
            ),
          ),
          // Stats + progress.
          Positioned(
            left: 16,
            right: 84,
            bottom: bottom + 24,
            child: AnimatedBuilder(
              animation: _anim,
              builder: (_, _) {
                final f = _anim.value;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        StatChip('${Fmt.km(a.distanceM * f)} km'),
                        StatChip(Fmt.duration(a.durationSec * f)),
                        StatChip(Fmt.pace(a.pace)),
                        if (a.claimedAreaM2 > 0) StatChip('+${Fmt.area(a.claimedAreaM2)}', color: LL.lime),
                      ],
                    ),
                    if (r.content.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        r.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                    ],
                    if (widget.canExport) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        onPressed: _export,
                        icon: const LIcon(LIcons.film, size: 18),
                        label: const Text('导出 1080p 视频'),
                      ),
                    ],
                    const SizedBox(height: 12),
                    LLProgress(value: f, height: 4),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SideButton extends StatelessWidget {
  const _SideButton({required this.icon, required this.label, required this.onTap, this.color = LL.text, this.tooltip});
  final LGlyph icon;
  final String label;
  final VoidCallback onTap;
  final Color color;
  final String? tooltip;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      RoundIconButton(icon: icon, fg: color, color: const Color(0xCC24242A), size: 52, tooltip: tooltip, onTap: onTap),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
    ],
  );
}
