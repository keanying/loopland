import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../api/community_api.dart';
import '../../api/gathering_api.dart';
import '../../api/gathering_models.dart';
import '../../api/models.dart';
import '../../core/format.dart';
import '../../core/refresh.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import '../chat/pick_image.dart';
import 'community_page.dart';
import 'gathering_widgets.dart';

/// 团长生成邀请码（7 天有效，可多次使用），复制或分享。
Future<void> showInviteSheet(BuildContext context, Crew crew) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _InviteSheet(crew: crew),
    );

class _InviteSheet extends ConsumerStatefulWidget {
  const _InviteSheet({required this.crew});
  final Crew crew;
  @override
  ConsumerState<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<_InviteSheet> {
  late Future<CrewInvite> _f = _gen();

  Future<CrewInvite> _gen() => ref.read(gatheringApiProvider).createInvite(widget.crew.id);

  String _text(CrewInvite i) =>
      '来圈圈加入「${widget.crew.name}」一起跑步圈地！打开圈圈 › 社区 › 输入邀请码 ${i.code}${i.expiresAt == null ? '' : '（${Fmt.date(i.expiresAt)} 前有效）'}';

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: FutureBuilder<CrewInvite>(
          future: _f,
          builder: (context, snap) {
            if (snap.hasError) {
              return ErrorBox(error: snap.error!, onRetry: () => setState(() => _f = _gen()));
            }
            if (!snap.hasData) {
              return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
            }
            final i = snap.data!;
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('邀请成员', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text('${i.expiresAt == null ? '7 天内' : '${Fmt.dateTime(i.expiresAt)} 前'}有效，可多次使用。对方在「社区」输入邀请码即可直接加入。',
                  style: const TextStyle(color: LL.text2, height: 1.5)),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 22),
                decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(24)),
                alignment: Alignment.center,
                child: SelectableText(i.code,
                    key: const Key('invite_code'),
                    style: const TextStyle(color: LL.ink, fontSize: 40, fontWeight: FontWeight.w900, letterSpacing: 8)),
              ),
              const SizedBox(height: 18),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: i.code));
                      toast(context, '邀请码已复制');
                    },
                    icon: const LIcon(LIcons.copy),
                    label: const Text('复制'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => SharePlus.instance.share(ShareParams(text: _text(i), subject: '圈圈 Loopland')),
                    icon: const LIcon(LIcons.shareOut),
                    label: const Text('分享'),
                  ),
                ),
              ]),
            ]);
          },
        ),
      ),
    );
  }
}

/// 输入邀请码加入跑团。
class JoinByCodePage extends ConsumerStatefulWidget {
  const JoinByCodePage({super.key, this.code});
  final String? code;
  @override
  ConsumerState<JoinByCodePage> createState() => _JoinByCodePageState();
}

class _JoinByCodePageState extends ConsumerState<JoinByCodePage> {
  late final _code = TextEditingController(text: widget.code ?? '');
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = _code.text.trim();
    if (code.length < 4) {
      toast(context, '请输入完整的邀请码');
      return;
    }
    setState(() => _busy = true);
    final id = await runGuarded(context, () => ref.read(gatheringApiProvider).joinByCode(code));
    if (!mounted) return;
    setState(() => _busy = false);
    if (id == null) return;
    await ref.read(refreshProvider).afterCrewChange();
    if (!mounted) return;
    toast(context, '已加入跑团', kind: ToastKind.success);
    context.pushReplacement('/crews/$id');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(children: [
          const BackHeader(title: '邀请码加入', subtitle: '向团长要一个 6 位邀请码'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                key: const Key('invite_input'),
                controller: _code,
                textAlign: TextAlign.center,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 6),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                  LengthLimitingTextInputFormatter(12),
                  TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toUpperCase())),
                ],
                decoration: const InputDecoration(hintText: '8K2D9Q'),
                onSubmitted: (_) => _join(),
              ),
              const SizedBox(height: 10),
              const Text('加入新跑团前需要先退出当前跑团。', textAlign: TextAlign.center, style: TextStyle(color: LL.text3, fontSize: 12)),
              const SizedBox(height: 24),
              FilledButton(onPressed: _busy ? null : _join, child: const Text('加入跑团')),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// 团长编辑跑团：名称、头像（上传 purpose=crew_avatar）、城区、加入方式。
/// 名称和头像先生效后审核。
class CrewEditPage extends ConsumerStatefulWidget {
  const CrewEditPage({super.key, required this.crewId});
  final int crewId;
  @override
  ConsumerState<CrewEditPage> createState() => _CrewEditPageState();
}

class _CrewEditPageState extends ConsumerState<CrewEditPage> {
  final _name = TextEditingController();
  final _district = TextEditingController();
  String _mode = 'open';
  Crew? _crew;
  String? _avatarUrl;
  int? _avatarId;
  bool _busy = false, _uploading = false;

  @override
  void initState() {
    super.initState();
    ref.read(crewProvider(widget.crewId).future).then((c) {
      if (!mounted) return;
      setState(() {
        _crew = c;
        _name.text = c.name;
        _district.text = c.district;
        _mode = c.joinMode;
        _avatarUrl = c.avatarUrl;
      });
    }).catchError((Object e) {
      if (mounted) showError(context, e);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _district.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picked = await ref.read(singleImagePickerProvider)();
    if (picked == null || !mounted) return;
    setState(() => _uploading = true);
    final up = await runGuarded(
        context, () => ref.read(communityApiProvider).uploadMedia(picked.bytes, filename: picked.name, purpose: 'crew_avatar'));
    if (!mounted) return;
    setState(() {
      _uploading = false;
      if (up != null) {
        _avatarId = up.id;
        _avatarUrl = up.url;
      }
    });
  }

  Future<void> _save() async {
    final c = _crew;
    if (c == null) return;
    final name = _name.text.trim();
    if (name.runes.length < 2 || name.runes.length > 16) {
      toast(context, '跑团名称需要 2–16 个字', kind: ToastKind.warning);
      return;
    }
    if (_district.text.trim().isEmpty) {
      toast(context, '请填写所在城区');
      return;
    }
    setState(() => _busy = true);
    final r = await runGuarded(
      context,
      () => ref.read(gatheringApiProvider).updateCrew(
            c.id,
            name: name == c.name ? null : name,
            avatarId: _avatarId,
            district: _district.text.trim() == c.district ? null : _district.text.trim(),
            joinMode: _mode == c.joinMode ? null : _mode,
          ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r == null) return;
    await ref.read(refreshProvider).afterCrewChange();
    if (!mounted) return;
    toast(context, name != c.name || _avatarId != null ? '已保存，名称和头像会在审核后保留' : '已保存');
    if (context.canPop()) {
      context.pop();
    } else {
      context.pushReplacement('/crews/${c.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _crew;
    return Scaffold(
      body: SafeArea(
        child: ListView(children: [
          const BackHeader(title: '编辑跑团'),
          if (c == null)
            const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
          else
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(
                  child: GestureDetector(
                    onTap: _uploading ? null : _pickAvatar,
                    child: Stack(children: [
                      PersonAvatar(name: _name.text, url: _avatarUrl, size: 96, color: LL.lavender),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: const BoxDecoration(color: LL.lime, shape: BoxShape.circle),
                          child: _uploading
                              ? const Padding(padding: EdgeInsets.all(7), child: CircularProgressIndicator(strokeWidth: 2, color: LL.ink))
                              : const LIcon(LIcons.camera, size: 18, color: LL.ink),
                        ),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  key: const Key('crew_name'),
                  controller: _name,
                  inputFormatters: [LengthLimitingTextInputFormatter(16)],
                  decoration: const InputDecoration(hintText: '跑团名称（2–16 字）'),
                ),
                const SizedBox(height: 12),
                TextField(controller: _district, decoration: const InputDecoration(hintText: '所在城区，如 徐汇区')),
                const SizedBox(height: 20),
                const Text('加入方式', style: TextStyle(color: LL.text2)),
                const SizedBox(height: 8),
                PillTabs(
                  labels: const ['公开', '申请', '邀请'],
                  index: const ['open', 'apply', 'invite'].indexOf(_mode).clamp(0, 2),
                  onChanged: (i) => setState(() => _mode = const ['open', 'apply', 'invite'][i]),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: LL.card, borderRadius: BorderRadius.circular(16)),
                  child: const Text('名称和头像修改后立即生效，随后进入审核；审核未通过会恢复为默认名称 / 头像，并通过站内信告诉你原因。',
                      style: TextStyle(color: LL.text2, fontSize: 12, height: 1.5)),
                ),
                const SizedBox(height: 24),
                FilledButton(onPressed: _busy || _uploading ? null : _save, child: const Text('保存')),
              ]),
            ),
        ]),
      ),
    );
  }
}
