import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluwx/fluwx.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../api/community_api.dart';
import '../../api/community_models.dart';
import '../../auth/social_login.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'social_providers.dart';
import 'social_widgets.dart';

/// Which channels the share sheet offers. WeChat needs a configured AppID
/// (and WeChat installed, checked on tap); tests override this.
bool Function() shareWeChatAvailable = () => WeChat.configured;

/// D-03 分享: 微信 / 朋友圈 (hidden without the WeChat SDK) / 生成海报 /
/// 复制链接 / 更多 (system sheet). Every channel calls
/// `POST /v1/posts/{id}/share` first (share count + link + poster text).
Future<void> showShareSheet(BuildContext context, WidgetRef ref, Post post) => showModalBottomSheet<void>(
      context: context,
      builder: (_) => ShareSheet(post: post),
    );

class ShareSheet extends ConsumerStatefulWidget {
  const ShareSheet({super.key, required this.post});
  final Post post;
  @override
  ConsumerState<ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<ShareSheet> {
  bool _busy = false;

  Future<PostShare?> _record(String channel) async {
    setState(() => _busy = true);
    final r = await runGuarded(context, () => ref.read(communityApiProvider).share(widget.post.id, channel));
    if (mounted) setState(() => _busy = false);
    if (r != null) {
      final cur = ref.read(postCacheProvider)[widget.post.id] ?? widget.post;
      ref.read(postCacheProvider.notifier).put(cur.copyWith(shareCount: r.shareCount));
    }
    return r;
  }

  String get _title {
    final p = widget.post;
    if (p.content.isNotEmpty) return p.content.length > 30 ? '${p.content.substring(0, 30)}…' : p.content;
    return '${p.author.nickname} 的${p.activity == null ? '动态' : '圈地战报'}';
  }

  Future<void> _wechat(WeChatScene scene) async {
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await WeChat.ensureReady();
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    final r = await _record(scene == WeChatScene.timeline ? 'moments' : 'wechat');
    if (r == null || r.url.isEmpty) return;
    try {
      await WeChat.fluwx.share(WeChatShareWebPageModel(r.url,
          title: r.posterTitle.isNotEmpty ? r.posterTitle : _title, description: r.posterSubtitle, scene: scene));
      nav.pop();
    } catch (_) {
      messenger?..removeCurrentSnackBar()..showSnackBar(const SnackBar(content: Text('无法打开微信')));
    }
  }

  Future<void> _copy() async {
    final r = await _record('link');
    if (r == null || !mounted) return;
    await Clipboard.setData(ClipboardData(text: r.url));
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);
    messenger?..removeCurrentSnackBar()..showSnackBar(const SnackBar(content: Text('链接已复制')));
  }

  Future<void> _system() async {
    final r = await _record('link');
    if (r == null || !mounted) return;
    Navigator.pop(context);
    await SharePlus.instance.share(ShareParams(text: '$_title ${r.url}', subject: '圈圈 Loopland'));
  }

  Future<void> _poster() async {
    final r = await _record('poster');
    if (r == null || !mounted) return;
    final nav = Navigator.of(context);
    nav.pop();
    await nav.push(MaterialPageRoute<void>(builder: (_) => PosterPage(post: widget.post, share: r)));
  }

  @override
  Widget build(BuildContext context) {
    final wx = shareWeChatAvailable();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('分享到', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            if (wx) _Channel(icon: Icons.chat_rounded, color: const Color(0xFF2DC100), label: '微信', onTap: _busy ? null : () => _wechat(WeChatScene.session)),
            if (wx) _Channel(icon: Icons.camera_rounded, color: const Color(0xFF2DC100), label: '朋友圈', onTap: _busy ? null : () => _wechat(WeChatScene.timeline)),
            _Channel(icon: Icons.image_outlined, color: LL.lime, label: '生成海报', onTap: _busy ? null : _poster),
            _Channel(icon: Icons.link_rounded, color: LL.sky, label: '复制链接', onTap: _busy ? null : _copy),
            _Channel(icon: Icons.ios_share_rounded, color: LL.lavender, label: '更多', onTap: _busy ? null : _system),
          ]),
        ]),
      ),
    );
  }
}

class _Channel extends StatelessWidget {
  const _Channel({required this.icon, required this.color, required this.label, this.onTap});
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(icon, color: LL.ink),
            ),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 12, color: LL.text2)),
          ]),
        ),
      );
}

/// 生成海报: renders [PosterCard] to a PNG and hands it to the system share
/// sheet (save to photos / any app) or WeChat.
class PosterPage extends StatefulWidget {
  const PosterPage({super.key, required this.post, required this.share});
  final Post post;
  final PostShare share;
  @override
  State<PosterPage> createState() => _PosterPageState();
}

class _PosterPageState extends State<PosterPage> {
  final _key = GlobalKey();
  bool _busy = false;

  Future<Uint8List?> _render() async {
    final ro = _key.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return null;
    final img = await ro.toImage(pixelRatio: 3);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  Future<void> _share({bool wechat = false}) async {
    setState(() => _busy = true);
    try {
      final bytes = await _render();
      if (bytes == null) return;
      if (wechat) {
        await WeChat.ensureReady();
        await WeChat.fluwx.share(WeChatShareImageModel(WeChatImageToShare(uint8List: bytes), scene: WeChatScene.session));
      } else {
        await SharePlus.instance.share(ShareParams(
          files: [XFile.fromData(bytes, mimeType: 'image/png', name: 'loopland_${widget.post.id}.png')],
          fileNameOverrides: ['loopland_${widget.post.id}.png'],
        ));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '分享海报'),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: RepaintBoundary(key: _key, child: PosterCard(post: widget.post, share: widget.share)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Row(children: [
              if (shareWeChatAvailable()) ...[
                Expanded(
                  child: OutlinedButton(onPressed: _busy ? null : () => _share(wechat: true), child: const Text('发给微信好友')),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(child: FilledButton(onPressed: _busy ? null : _share, child: const Text('保存 / 分享'))),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The poster itself (also used by screenshots).
class PosterCard extends StatelessWidget {
  const PosterCard({super.key, required this.post, required this.share});
  final Post post;
  final PostShare share;

  @override
  Widget build(BuildContext context) {
    final a = post.activity;
    final title = share.posterTitle.isNotEmpty ? share.posterTitle : '${post.author.nickname} 的圈地战报';
    final sub = share.posterSubtitle.isNotEmpty
        ? share.posterSubtitle
        : (a == null ? '' : '${Fmt.km(a.distanceM)} km · ${Fmt.pace(a.pace)}');
    return Container(
      width: 320,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: LL.night, borderRadius: BorderRadius.circular(28), border: Border.all(color: LL.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          UserAvatar(user: post.author, size: 40, ring: true),
          const SizedBox(width: 10),
          Expanded(
            child: Text(post.author.nickname, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
          ),
          const Text('圈圈', style: TextStyle(color: LL.lime, fontWeight: FontWeight.w900, fontSize: 18)),
        ]),
        const SizedBox(height: 14),
        Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, height: 1.3)),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(sub, style: const TextStyle(color: LL.lime, fontWeight: FontWeight.w800, fontSize: 16)),
        ],
        if (a != null && a.track.length >= 2) ...[
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(height: 220, child: TrackView(track: a.track, strokeWidth: 5)),
          ),
        ] else if (post.content.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(post.content, maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, height: 1.5)),
        ],
        const SizedBox(height: 14),
        Row(children: [
          const Expanded(
            child: Text('跑一圈，就是你的地\n打开圈圈查看完整动态', style: TextStyle(color: LL.text3, fontSize: 12, height: 1.5)),
          ),
          if (share.url.isNotEmpty)
            Flexible(
              child: Text(share.url.replaceFirst(RegExp(r'^https?://'), ''),
                  textAlign: TextAlign.right, style: const TextStyle(color: LL.text2, fontSize: 11)),
            ),
        ]),
      ]),
    );
  }
}
