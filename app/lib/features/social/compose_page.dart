import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/ai_api.dart';
import '../../api/ai_models.dart';
import '../../api/community_api.dart';
import '../../api/community_models.dart';
import '../../api/errors.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/features.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import '../ai/ai_widgets.dart';
import 'media_picker.dart';
import 'social_providers.dart';

/// Opens the composer: `context.push<Post>('/posts/new', extra: ComposeArgs(...))`.
/// The settlement page passes the run it just finished and its AI 战报
/// (C-05「一键带上战报发动态」).
class ComposeArgs {
  const ComposeArgs({this.activity, this.text = '', this.aiReport});

  /// Pre-attached run.
  final Activity? activity;

  /// Pre-filled text.
  final String text;

  /// Pre-attached AI 战报 of [activity]; posted as `ai_report: true` and
  /// shown as its own block (not part of the 500-character text).
  final AIReport? aiReport;
}

class _Img {
  _Img(this.picked);
  final PickedImage picked;
  double progress = 0;
  MediaUpload? uploaded;
  Object? error;
  bool get done => uploaded != null;
}

/// D-05 发布动态: text ≤ 500, up to 9 photos (uploaded right away with
/// progress), one recent run, visibility, endpoint-hiding and review notes.
class ComposePage extends ConsumerStatefulWidget {
  const ComposePage({super.key, this.args = const ComposeArgs(), this.activityId});
  final ComposeArgs args;

  /// `/posts/new?activity=<id>` when no [ComposeArgs.activity] was passed.
  final int? activityId;
  @override
  ConsumerState<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends ConsumerState<ComposePage> {
  static const maxLen = 500;
  static const maxImages = 9;

  late final _text = TextEditingController(text: widget.args.text);
  final _images = <_Img>[];
  late int? _activityId = widget.args.activity?.id ?? widget.activityId;
  String _visibility = 'public';
  bool _posting = false;
  bool _uploading = false;

  /// The attached AI 战报 (of [_activityId]).
  late AIReport? _report =
      widget.args.aiReport != null && widget.args.aiReport!.activityId == (widget.args.activity?.id ?? widget.activityId)
          ? widget.args.aiReport
          : null;
  bool _reportBusy = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _canPost {
    if (_posting || _uploading || _images.any((i) => !i.done)) return false;
    final t = _text.text.trim();
    if (t.length > maxLen) return false;
    return t.isNotEmpty || _images.isNotEmpty || _activityId != null;
  }

  Future<void> _pick() async {
    final room = maxImages - _images.length;
    if (room <= 0) return;
    final List<PickedImage> picked;
    try {
      picked = await ref.read(mediaPickerProvider).pickImages(room);
    } catch (e) {
      if (mounted) toast(context, '无法打开相册，请在系统设置里允许圈圈访问照片', kind: ToastKind.warning);
      return;
    }
    if (picked.isEmpty || !mounted) return;
    setState(() => _images.addAll(picked.take(room).map(_Img.new)));
    await _uploadAll();
  }

  /// Uploads pending images one by one (`POST /v1/media` purpose=post).
  Future<void> _uploadAll() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    final api = ref.read(communityApiProvider);
    try {
      for (final img in List.of(_images)) {
        if (img.done || !_images.contains(img)) continue;
        img.error = null;
        try {
          img.uploaded = await api.uploadMedia(
            img.picked.bytes,
            filename: img.picked.name,
            purpose: 'post',
            onProgress: (s, t) {
              if (t > 0 && mounted) setState(() => img.progress = s / t);
            },
          );
          img.progress = 1;
        } catch (e) {
          img.error = e;
        }
        if (mounted) setState(() {});
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
    final failed = _images.where((i) => i.error != null).toList();
    if (failed.isNotEmpty && mounted) showError(context, failed.first.error!);
  }

  Future<void> _submit() async {
    if (!_canPost) return;
    setState(() => _posting = true);
    try {
      final p = await ref.read(communityApiProvider).createPost(NewPost(
            content: _text.text.trim(),
            imageIds: [for (final i in _images) i.uploaded!.id],
            activityId: _activityId,
            visibility: _visibility,
            aiReport: _report != null && _report!.activityId == _activityId,
          ));
      if (!mounted) return;
      ref.read(postCacheProvider.notifier).put(p);
      ref.invalidate(myProfileProvider);
      final show = toaster(context);
      final nav = Navigator.of(context);
      // Opened directly (deep link) there is nothing to return to: show the feed.
      nav.canPop() ? nav.pop(p) : context.go('/community/feed?tab=following');
      show(p.reviewStatus == ReviewStatus.pending ? '已提交，审核通过后其他人就能看到' : '发布成功', kind: ToastKind.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _posting = false);
      await _handleError(ApiException.from(e));
    }
  }

  Future<void> _handleError(ApiException e) async {
    switch (e.code) {
      case 'content_blocked':
        await _alert('内容未通过检查', e.message);
      case 'muted':
        final until = ref.read(userProvider)?.mutedUntil;
        await _alert('暂时不能发布', until == null ? e.message : '${e.message}\n解除时间：${Fmt.dateTime(until)}');
      case 'invalid_media':
        // Drop the uploads; the user re-picks (or retries) them.
        setState(() {
          for (final i in _images) {
            i.uploaded = null;
            i.progress = 0;
            i.error = e;
          }
        });
        await _alert('图片无效', '${e.message}。请删除后重新添加，或点图片重试上传。');
      case 'not_in_crew':
        setState(() => _visibility = 'public');
        await _alert('还没有跑团', '「仅跑团」需要先加入跑团，已改为公开。');
      default:
        showError(context, e);
    }
  }

  Future<void> _alert(String title, String body) => showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('知道了'))],
        ),
      );

  /// C-05: generate (or 换一篇) the attached run's AI 战报 and attach it.
  Future<void> _aiReport() async {
    final id = _activityId;
    if (id == null || _reportBusy) return;
    setState(() => _reportBusy = true);
    try {
      final r = await ref.read(aiApiProvider).report(id, regenerate: _report?.activityId == id);
      if (mounted && _activityId == id) setState(() => _report = r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _reportBusy = false);
    }
  }

  void _selectRun(int? id) => setState(() {
        _activityId = id;
        // A report belongs to one run.
        if (_report?.activityId != id) _report = null;
      });

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    final runs = ref.watch(recentRunsProvider);
    final hide = user?.settings.hideEndpoints ?? true;
    final len = _text.text.trim().length;
    final ai = ref.watch(aiEnabledProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              RoundIconButton(icon: LIcons.close, tooltip: '关闭', onTap: () => Navigator.of(context).maybePop()),
              const SizedBox(width: 14),
              const Expanded(child: Text('发布动态', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900))),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(84, 48)),
                onPressed: _canPost ? _submit : null,
                child: Text(_posting ? '发布中…' : '发布'),
              ),
            ]),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
              const Text('附上运动记录', style: TextStyle(color: LL.text2)),
              const SizedBox(height: 10),
              SizedBox(
                height: 104,
                child: runs.when(
                  skipLoadingOnRefresh: true,
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: TextButton(onPressed: () => ref.invalidate(recentRunsProvider), child: const Text('加载运动记录失败，重试'))),
                  data: (list) {
                    final all = [
                      if (widget.args.activity != null && !list.any((a) => a.id == widget.args.activity!.id)) widget.args.activity!,
                      ...list,
                    ];
                    if (all.isEmpty) {
                      return const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('最近还没有户外运动记录', style: TextStyle(color: LL.text3)),
                      );
                    }
                    return ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: all.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (_, i) => _RunChoice(
                        activity: all[i],
                        selected: all[i].id == _activityId,
                        onTap: () => _selectRun(all[i].id == _activityId ? null : all[i].id),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                decoration: BoxDecoration(color: LL.card, borderRadius: BorderRadius.circular(24), border: Border.all(color: LL.border)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('说点什么', style: TextStyle(color: LL.text2)),
                  TextField(
                    key: const Key('compose-text'),
                    controller: _text,
                    minLines: 5,
                    maxLines: 10,
                    maxLength: maxLen,
                    decoration: const InputDecoration(
                      hintText: '今天跑得怎么样？圈了哪块地？',
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                      counterText: '',
                    ),
                  ),
                  if (_report != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: AIReportBlock(
                        key: const Key('compose-ai-report'),
                        text: _report!.text,
                        aiGenerated: _report!.aiGenerated,
                        trailing: GestureDetector(
                          onTap: () => setState(() => _report = null),
                          child: const LIcon(LIcons.close, size: 18, color: LL.text2, semanticLabel: '移除 AI 战报'),
                        ),
                      ),
                    ),
                  Row(children: [
                    if (ai)
                      ActionChip(
                        avatar: _reportBusy
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: LL.lavender))
                            : const QuanMark(size: 18),
                        label: Text(_report == null ? 'AI 写战报' : '换一篇'),
                        onPressed: _activityId == null || _reportBusy ? null : _aiReport,
                        backgroundColor: const Color(0xFF26223A),
                        side: BorderSide.none,
                        labelStyle: const TextStyle(color: LL.lavender, fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    const Spacer(),
                    Text('$len/$maxLen', style: TextStyle(color: len > maxLen ? LL.red : LL.text3, fontSize: 13)),
                  ]),
                ]),
              ),
              const SizedBox(height: 14),
              _imageGrid(),
              const SizedBox(height: 18),
              const Text('谁可以看', style: TextStyle(color: LL.text2)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in visibilityNames.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: _visibility == e.key,
                    onSelected: e.key == 'crew' && user?.crew == null ? null : (_) => setState(() => _visibility = e.key),
                    selectedColor: LL.lime,
                    backgroundColor: LL.card2,
                    disabledColor: LL.card,
                    side: BorderSide.none,
                    showCheckmark: false,
                    labelStyle: TextStyle(color: _visibility == e.key ? LL.ink : LL.text, fontWeight: FontWeight.w700),
                  ),
              ]),
              const SizedBox(height: 16),
              _Note(
                icon: LIcons.pinOff,
                text: hide ? '为保护隐私，轨迹起点和终点 200 m 内会自动隐藏' : '你在设置里关闭了「隐藏起终点」，完整轨迹会公开',
              ),
              const _Note(icon: LIcons.verified, text: '动态先过审核：内容安全的会立即发布，其余审核通过后其他人可见'),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _imageGrid() {
    final tiles = <Widget>[
      for (final img in _images) _ImageTile(
        img: img,
        onRemove: () => setState(() => _images.remove(img)),
        onRetry: img.error != null && !_uploading ? _uploadAll : null,
      ),
      if (_images.length < maxImages)
        InkWell(
          key: const Key('add-photo'),
          onTap: _pick,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: LL.text3, width: 1),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const LIcon(LIcons.plus, color: LL.text2, size: 30),
              Text(_images.isEmpty ? '添加照片' : '${_images.length}/$maxImages', style: const TextStyle(color: LL.text2, fontSize: 13)),
            ]),
          ),
        ),
    ];
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: tiles,
    );
  }
}

class _ImageTile extends StatelessWidget {
  const _ImageTile({required this.img, required this.onRemove, this.onRetry});
  final _Img img;
  final VoidCallback onRemove;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(fit: StackFit.expand, children: [
        Image.memory(img.picked.bytes, fit: BoxFit.cover, errorBuilder: (_, _, _) => const ColoredBox(color: LL.card2)),
        if (!img.done)
          GestureDetector(
            onTap: onRetry,
            child: Container(
              color: const Color(0x990E0E10),
              alignment: Alignment.center,
              child: img.error != null
                  ? const Column(mainAxisSize: MainAxisSize.min, children: [
                      LIcon(LIcons.refresh, color: LL.red),
                      Text('上传失败，点击重试', style: TextStyle(color: LL.text, fontSize: 11)),
                    ])
                  : SizedBox(
                      width: 40,
                      height: 40,
                      child: CircularProgressIndicator(value: img.progress <= 0 ? null : img.progress, strokeWidth: 3),
                    ),
            ),
          ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(color: Color(0xCC0E0E10), shape: BoxShape.circle),
              child: const LIcon(LIcons.close, size: 16, color: LL.text, semanticLabel: '移除'),
            ),
          ),
        ),
      ]),
    );
  }
}

class _RunChoice extends StatelessWidget {
  const _RunChoice({required this.activity, required this.selected, required this.onTap});
  final Activity activity;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = activity;
    final when = a.startedAt == null ? '' : Fmt.relative(a.startedAt);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 170,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: LL.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: selected ? LL.lime : LL.border, width: selected ? 2 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: selected ? LL.lime : LL.lavender, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Expanded(
              child: Text('$when · ${sportName(a.sport)}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 4),
          Text('${Fmt.km(a.distanceM, digits: 1)} km · ${Fmt.duration(a.durationS)}',
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
          const SizedBox(height: 2),
          Text(a.claimedAreaM2 > 0 ? '圈地 +${Fmt.area(a.claimedAreaM2)}' : '配速 ${Fmt.pace(a.avgPaceSPerKm)}',
              style: TextStyle(color: a.claimedAreaM2 > 0 ? LL.lime : LL.lavender, fontSize: 13)),
        ]),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final LGlyph icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LIcon(icon, size: 16, color: LL.text3),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: const TextStyle(color: LL.text3, fontSize: 12, height: 1.4))),
        ]),
      );
}
