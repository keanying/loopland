import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../play/relay_card.dart';
import 'community_page.dart';

/// 找跑团。
class CrewSearchPage extends ConsumerStatefulWidget {
  const CrewSearchPage({super.key});
  @override
  ConsumerState<CrewSearchPage> createState() => _CrewSearchPageState();
}

class _CrewSearchPageState extends ConsumerState<CrewSearchPage> {
  final _q = TextEditingController();
  final _district = TextEditingController();
  Future<Paged<Crew>>? _future;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _q.dispose();
    _district.dispose();
    super.dispose();
  }

  void _search() => setState(() {
        _future = ref.read(apiProvider).crews(q: _q.text.trim(), district: _district.text.trim());
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          BackHeader(
            title: '找跑团',
            trailing: TextButton(onPressed: () => context.push('/crews/new'), child: const Text('创建')),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _q,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(hintText: '跑团名称', prefixIcon: Icon(Icons.search_rounded)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _district,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(hintText: '城区'),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<Paged<Crew>>(
              future: _future,
              builder: (context, snap) {
                if (snap.hasError) return ErrorBox(error: snap.error!, onRetry: _search);
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final items = snap.data!.items;
                if (items.isEmpty) {
                  return const Center(child: Text('没有找到跑团，换个关键词或自己创建一个', style: TextStyle(color: LL.text2)));
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final c = items[i];
                    return LLCard(
                      padding: const EdgeInsets.all(12),
                      onTap: () => context.push('/crews/${c.id}'),
                      child: Row(children: [
                        Avatar(name: c.name, size: 52, color: [LL.pink, LL.sky, LL.lavender, LL.lime][i % 4]),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(c.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                            Text('${c.memberCount} 名成员 · ${c.district} · ${joinModeNames[c.joinMode] ?? c.joinMode}',
                                style: const TextStyle(color: LL.text2, fontSize: 12)),
                          ]),
                        ),
                        Text(Fmt.area(c.territoryAreaM2), style: const TextStyle(fontWeight: FontWeight.w900)),
                      ]),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

/// 创建跑团：名称 2–16 字、城区、加入方式。
class CrewCreatePage extends ConsumerStatefulWidget {
  const CrewCreatePage({super.key});
  @override
  ConsumerState<CrewCreatePage> createState() => _CrewCreatePageState();
}

class _CrewCreatePageState extends ConsumerState<CrewCreatePage> {
  final _name = TextEditingController();
  final _district = TextEditingController();
  String _mode = 'open';
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _district.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.runes.length < 2 || name.runes.length > 16) {
      toast(context, '跑团名称需要 2–16 个字');
      return;
    }
    if (_district.text.trim().isEmpty) {
      toast(context, '请填写所在城区');
      return;
    }
    setState(() => _busy = true);
    final c = await runGuarded(
        context, () => ref.read(apiProvider).createCrew(name: name, district: _district.text.trim(), joinMode: _mode));
    if (!mounted) return;
    setState(() => _busy = false);
    if (c != null) {
      await ref.read(authProvider.notifier).refreshUser().catchError((_) {});
      if (mounted) context.pushReplacement('/crews/${c.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(children: [
          const BackHeader(title: '创建跑团', subtitle: '名称和头像需要通过审核'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
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
                index: const ['open', 'apply', 'invite'].indexOf(_mode),
                onChanged: (i) => setState(() => _mode = const ['open', 'apply', 'invite'][i]),
              ),
              const SizedBox(height: 28),
              FilledButton(onPressed: _busy ? null : _create, child: const Text('创建')),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// 跑团详情：信息、本周排行、成员；加入 / 退出 / 管理。
class CrewDetailPage extends ConsumerWidget {
  const CrewDetailPage({super.key, required this.crewId});
  final int crewId;

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final s = await runGuarded(context, () => ref.read(apiProvider).joinCrew(crewId));
    if (s == null || !context.mounted) return;
    toast(context, s == 'joined' ? '已加入跑团' : '申请已提交，等待团长审核');
    ref.invalidate(crewProvider(crewId));
    await ref.read(authProvider.notifier).refreshUser().catchError((_) {});
  }

  Future<void> _leave(BuildContext context, WidgetRef ref, Crew c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('退出跑团？'),
        content: Text(c.memberCount <= 1 ? '你是最后一名成员，退出后跑团会解散。' : '退出后你之后圈的地不再记到「${c.name}」名下。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('退出')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final done = await runGuarded(context, () async {
      await ref.read(apiProvider).leaveCrew(crewId);
      return true;
    });
    if (done == true && context.mounted) {
      await ref.read(authProvider.notifier).refreshUser().catchError((_) {});
      if (context.mounted) context.pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(crewProvider(crewId));
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<Crew>(
          value: async,
          onRetry: () => ref.invalidate(crewProvider(crewId)),
          data: (c) => ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            BackHeader(title: c.name, subtitle: '${c.district} · ${joinModeNames[c.joinMode] ?? ''}'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                CrewCard(crew: c),
                const SizedBox(height: 14),
                if (c.myRole == null)
                  FilledButton(
                    onPressed: c.joinMode == 'invite' ? null : () => _join(context, ref),
                    child: Text(c.joinMode == 'invite' ? '仅限邀请加入' : (c.joinMode == 'apply' ? '申请加入' : '加入跑团')),
                  )
                else if (c.myRole == 'applicant')
                  const FilledButton(onPressed: null, child: Text('已申请，等待审核'))
                else
                  Row(children: [
                    if (c.isLeader)
                      Expanded(
                        child: FilledButton(onPressed: () => context.push('/crews/${c.id}/manage'), child: const Text('管理跑团')),
                      ),
                    if (c.isLeader) const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(onPressed: () => _leave(context, ref, c), child: const Text('退出跑团')),
                    ),
                  ]),
                if (c.isLeader)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('团长需要先转让团长才能退出；只剩你一人时退出即解散。',
                        textAlign: TextAlign.center, style: TextStyle(color: LL.text3, fontSize: 12)),
                  ),
                if (c.isMember) ...[
                  const SizedBox(height: 14),
                  RelayCard(crew: c),
                ],
                const SizedBox(height: 20),
                const Text('成员', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                Consumer(builder: (context, ref, _) {
                  final m = ref.watch(crewMembersProvider(crewId));
                  return AsyncBody<List<CrewMember>>(
                    value: m,
                    onRetry: () => ref.invalidate(crewMembersProvider(crewId)),
                    data: (list) => Column(children: [
                      for (final x in list)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Avatar(name: x.user.nickname, size: 40),
                          title: Text(x.user.nickname),
                          subtitle: Text('${Fmt.date(x.joinedAt)} 加入', style: const TextStyle(color: LL.text3)),
                          trailing: x.role == 'leader' ? const ComingSoon(text: '团长') : null,
                        ),
                    ]),
                  );
                }),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 团长管理：成员（踢人、转让）与入团申请。
class CrewManagePage extends ConsumerStatefulWidget {
  const CrewManagePage({super.key, required this.crewId});
  final int crewId;
  @override
  ConsumerState<CrewManagePage> createState() => _CrewManagePageState();
}

class _CrewManagePageState extends ConsumerState<CrewManagePage> {
  int _tab = 0;

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('确定')),
          ],
        ),
      ) ==
      true;

  Future<void> _kick(CrewMember m) async {
    if (!await _confirm('移出成员', '确定把 ${m.user.nickname} 移出跑团？') || !mounted) return;
    await runGuarded(context, () => ref.read(apiProvider).kick(widget.crewId, m.user.id));
    ref.invalidate(crewMembersProvider(widget.crewId));
    ref.invalidate(crewProvider(widget.crewId));
  }

  Future<void> _transfer(CrewMember m) async {
    if (!await _confirm('转让团长', '转让后 ${m.user.nickname} 成为团长，你变为普通成员。') || !mounted) return;
    final c = await runGuarded(context, () => ref.read(apiProvider).transfer(widget.crewId, m.user.id));
    if (c != null && mounted) {
      ref.invalidate(crewProvider(widget.crewId));
      context.pop();
    }
  }

  Future<void> _decide(CrewApplication a, bool approve) async {
    final api = ref.read(apiProvider);
    await runGuarded(
        context,
        () => approve
            ? api.approveApplication(widget.crewId, a.user.id)
            : api.rejectApplication(widget.crewId, a.user.id));
    ref.invalidate(crewApplicationsProvider(widget.crewId));
    ref.invalidate(crewMembersProvider(widget.crewId));
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(userProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '管理跑团'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: PillTabs(labels: const ['成员', '入团申请'], index: _tab, onChanged: (i) => setState(() => _tab = i)),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _tab == 0
                ? AsyncBody<List<CrewMember>>(
                    value: ref.watch(crewMembersProvider(widget.crewId)),
                    onRetry: () => ref.invalidate(crewMembersProvider(widget.crewId)),
                    data: (list) => ListView(padding: const EdgeInsets.all(16), children: [
                      for (final m in list)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Avatar(name: m.user.nickname, size: 40),
                          title: Text(m.user.nickname),
                          subtitle: Text(m.role == 'leader' ? '团长' : '成员', style: const TextStyle(color: LL.text3)),
                          trailing: m.role == 'leader' || m.user.id == me?.id
                              ? null
                              : PopupMenuButton<String>(
                                  onSelected: (v) => v == 'kick' ? _kick(m) : _transfer(m),
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(value: 'transfer', child: Text('转让团长')),
                                    PopupMenuItem(value: 'kick', child: Text('移出跑团')),
                                  ],
                                ),
                        ),
                    ]),
                  )
                : AsyncBody<List<CrewApplication>>(
                    value: ref.watch(crewApplicationsProvider(widget.crewId)),
                    onRetry: () => ref.invalidate(crewApplicationsProvider(widget.crewId)),
                    data: (list) => list.isEmpty
                        ? const Center(child: Text('暂无入团申请', style: TextStyle(color: LL.text2)))
                        : ListView(padding: const EdgeInsets.all(16), children: [
                            for (final a in list)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Avatar(name: a.user.nickname, size: 40),
                                title: Text(a.user.nickname),
                                subtitle: Text(Fmt.relative(a.createdAt), style: const TextStyle(color: LL.text3)),
                                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                  TextButton(onPressed: () => _decide(a, false), child: const Text('拒绝', style: TextStyle(color: LL.text2))),
                                  FilledButton(
                                    style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
                                    onPressed: () => _decide(a, true),
                                    child: const Text('通过'),
                                  ),
                                ]),
                              ),
                          ]),
                  ),
          ),
        ]),
      ),
    );
  }
}
