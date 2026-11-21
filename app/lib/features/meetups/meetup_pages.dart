import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_common.dart';
import '../../api/gathering_api.dart';
import '../../api/gathering_models.dart';
import '../../auth/auth_controller.dart';
import '../../claim/geo.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../map/territory_map.dart';
import '../../widgets/common.dart';
import '../../widgets/cursor_list.dart';
import '../community/gathering_providers.dart';
import '../community/gathering_widgets.dart';
import '../community/place_picker.dart';
import '../social/social_widgets.dart' show UserAvatar, openProfile;

const _types = ['', 'run', 'ball', 'ride'];
const _typeLabels = ['全部', '约跑', '约球', '约骑'];

/// 组局（D-11）：附近的局（按类型筛选、按距离排序）和我的局。
class MeetupsPage extends ConsumerStatefulWidget {
  const MeetupsPage({super.key});
  @override
  ConsumerState<MeetupsPage> createState() => _MeetupsPageState();
}

class _MeetupsPageState extends ConsumerState<MeetupsPage> {
  late final CursorPager<Meetup> _pager;
  int _tab = 0, _type = 0;
  LatLng? _near;
  bool _located = false;
  final _busy = <int>{};

  GatheringApi get _api => ref.read(gatheringApiProvider);

  @override
  void initState() {
    super.initState();
    _pager = CursorPager((cursor) => _api.meetups(type: _types[_type], near: _near, cursor: cursor));
    _locate();
  }

  Future<void> _locate() async {
    final p = await quietLocation(ref);
    if (!mounted) return;
    setState(() {
      _near = p;
      _located = true;
    });
    _pager.refresh();
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Future<void> _join(Meetup m) async {
    setState(() => _busy.add(m.id));
    final r = await runGuarded(context, () => _api.joinMeetup(m.id));
    if (!mounted) return;
    setState(() => _busy.remove(m.id));
    if (r == null) return;
    _pager.replaceWhere((x) => x.id == m.id, (_) => r.withDistance(m.distanceM));
    ref.invalidate(myMeetupsProvider);
    ref.invalidate(communityHomeProvider);
    toast(context, '报名成功，已加入群聊');
  }

  Future<void> _create() async {
    final m = await context.push<Meetup>('/meetups/new');
    if (m != null && mounted) {
      _pager.refresh();
      ref.invalidate(myMeetupsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          BackHeader(
            title: '组局',
            subtitle: '约跑 · 约球 · 约骑，报名即进群聊',
            trailing: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(80, 46)),
              onPressed: _create,
              icon: const Icon(Icons.add_rounded),
              label: const Text('发起'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: PillTabs(labels: const ['附近', '我的'], index: _tab, onChanged: (i) => setState(() => _tab = i)),
          ),
          const SizedBox(height: 10),
          Expanded(child: _tab == 0 ? _nearby() : _mine()),
        ]),
      ),
    );
  }

  Widget _nearby() => Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ChipTabs(
            labels: _typeLabels,
            index: _type,
            onChanged: (i) {
              setState(() => _type = i);
              _pager.refresh();
            },
          ),
        ),
        if (_located && _near == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              const Icon(Icons.location_off_outlined, color: LL.text3, size: 16),
              const SizedBox(width: 6),
              const Expanded(child: Text('没有拿到定位，按开始时间排序', style: TextStyle(color: LL.text3, fontSize: 12))),
              TextButton(onPressed: _locate, child: const Text('重新定位')),
            ]),
          ),
        Expanded(
          child: CursorListView<Meetup>(
            pager: _pager,
            empty: '附近还没有局，发起一个吧',
            itemBuilder: (context, m, _) => MeetupCard(meetup: m, busy: _busy.contains(m.id), onJoin: () => _join(m)),
          ),
        ),
      ]);

  Widget _mine() {
    final async = ref.watch(myMeetupsProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(myMeetupsProvider),
      child: AsyncBody<List<Meetup>>(
        value: async,
        onRetry: () => ref.invalidate(myMeetupsProvider),
        data: (list) => list.isEmpty
            ? ListView(children: const [
                Padding(
                  padding: EdgeInsets.all(40),
                  child: Text('你还没有发起或报名组局', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)),
                ),
              ])
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, i) => MeetupCard(meetup: list[i]),
              ),
      ),
    );
  }
}

/// 组局详情：时间地点、要求、发起人、成员；报名 / 退出 / 取消；进群聊。
class MeetupDetailPage extends ConsumerStatefulWidget {
  const MeetupDetailPage({super.key, required this.meetupId});
  final int meetupId;
  @override
  ConsumerState<MeetupDetailPage> createState() => _MeetupDetailPageState();
}

class _MeetupDetailPageState extends ConsumerState<MeetupDetailPage> {
  bool _busy = false;

  GatheringApi get _api => ref.read(gatheringApiProvider);

  Future<void> _act(Future<Meetup> Function() f, String done) async {
    setState(() => _busy = true);
    final r = await runGuarded(context, f);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r == null) return;
    ref.invalidate(meetupProvider(widget.meetupId));
    ref.invalidate(myMeetupsProvider);
    ref.invalidate(communityHomeProvider);
    toast(context, done);
  }

  Future<bool> _confirm(String title, String body, String ok) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('再想想')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(ok)),
          ],
        ),
      ) ==
      true;

  void _chat(Meetup m) {
    final id = m.conversationId;
    if (id == null) {
      toast(context, '群聊还没准备好，稍后再试');
      return;
    }
    context.push('/chat/$id');
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(meetupProvider(widget.meetupId));
    final me = ref.watch(userProvider)?.id;
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<Meetup>(
          value: async,
          onRetry: () => ref.invalidate(meetupProvider(widget.meetupId)),
          data: (m) => Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                BackHeader(title: '${m.typeName} · 组局', subtitle: m.district.isEmpty ? null : m.district),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (m.isPending || m.isRejected) ...[
                      _Notice(
                        color: m.isPending ? LL.yellow : LL.red,
                        text: m.isPending ? '审核中：通过后其他人才能在附近列表看到这个局' : '未通过审核：标题或说明含不允许的内容，请取消后重新发起',
                      ),
                      const SizedBox(height: 10),
                    ],
                    _Hero(meetup: m),
                    const SizedBox(height: 12),
                    if (m.place != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(LL.radius),
                        child: SizedBox(
                          height: 150,
                          child: TerritoryMapView(
                            initialCenter: m.place!.latLng,
                            initialZoom: 15.5,
                            interactive: false,
                            layers: MapLayers(myLocation: m.place!.latLng),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    LLCard(
                      child: Column(children: [
                        _InfoRow(icon: Icons.schedule_rounded, label: '时间', value: timeRangeText(m.startTime, m.endTime)),
                        _InfoRow(
                            icon: Icons.place_outlined,
                            label: '地点',
                            value: [m.place?.name ?? '-', if (m.distanceM != null) Fmt.distance(m.distanceM!)].join(' · ')),
                        _InfoRow(icon: Icons.groups_outlined, label: '人数', value: '${m.joinedCount} / ${m.capacity} 人'),
                        if (m.requirement.isNotEmpty) _InfoRow(icon: Icons.rule_rounded, label: '要求', value: m.requirement),
                      ]),
                    ),
                    if (m.description.isNotEmpty) ...[
                      const SectionHeader('说明'),
                      LLCard(child: Text(m.description, style: const TextStyle(height: 1.6))),
                    ],
                    SectionHeader('已报名 ${m.joinedCount} 人'),
                    Wrap(spacing: 14, runSpacing: 12, children: [
                      for (final u in m.members.isEmpty && m.creator != null ? [m.creator!] : m.members)
                        SizedBox(
                          width: 60,
                          child: Column(children: [
                            UserAvatar(user: u, size: 48, onTap: () => openProfile(context, u)),
                            const SizedBox(height: 4),
                            Text(u.id == m.creator?.id ? '${u.nickname}·发起' : u.nickname,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: LL.text2)),
                          ]),
                        ),
                    ]),
                  ]),
                ),
              ]),
            ),
            _actions(m, me),
          ]),
        ),
      ),
    );
  }

  Widget _actions(Meetup m, int? me) {
    final creator = m.isCreator(me);
    final live = m.status == 'open' || m.status == 'full';
    Widget? primary, secondary;
    if (creator || m.joined) {
      primary = FilledButton.icon(
          onPressed: () => _chat(m), icon: const Icon(Icons.forum_outlined), label: const Text('进群聊'));
      if (live) {
        secondary = OutlinedButton(
          onPressed: _busy
              ? null
              : () async {
                  if (creator) {
                    if (await _confirm('取消这个局？', '所有报名的人都会收到通知。', '取消组局')) {
                      await _act(() => _api.cancelMeetup(m.id), '组局已取消');
                    }
                  } else if (await _confirm('退出这个局？', '退出后也会离开群聊。', '退出')) {
                    await _act(() => _api.leaveMeetup(m.id), '已退出');
                  }
                },
          child: Text(creator ? '取消组局' : '退出'),
        );
      }
    } else {
      final label = switch (m.status) {
        'full' => '已满员',
        'cancelled' => '已取消',
        'ended' => '已结束',
        _ => '报名加入',
      };
      primary = FilledButton(
        onPressed: m.status == 'open' && !_busy ? () => _act(() => _api.joinMeetup(m.id), '报名成功，已加入群聊') : null,
        child: Text(label),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: LL.border))),
      child: Row(children: [
        if (secondary != null) ...[Expanded(child: secondary), const SizedBox(width: 10)],
        Expanded(flex: 2, child: primary),
      ]),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.meetup});
  final Meetup meetup;
  @override
  Widget build(BuildContext context) {
    final m = meetup;
    final color = meetupColor(m.type);
    final status = switch (m.status) {
      'full' => '已满员',
      'cancelled' => '已取消',
      'ended' => '已结束',
      _ => '报名中',
    };
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(28)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Tag(m.typeName, color: LL.ink, fg: color),
          const SizedBox(width: 8),
          Text(whenText(m.startTime), style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w700)),
          const Spacer(),
          Tag(status, color: const Color(0x33000000), fg: LL.ink),
        ]),
        const SizedBox(height: 12),
        Text(m.title, style: const TextStyle(color: LL.ink, fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(height: 14),
        LLProgress(value: m.capacity == 0 ? 0 : m.joinedCount / m.capacity, color: LL.ink, bg: const Color(0x33000000)),
        const SizedBox(height: 6),
        Row(children: [
          Text('${m.joinedCount} / ${m.capacity} 人', style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (m.creator != null)
            Text('发起人 ${m.creator!.nickname}', style: const TextStyle(color: Color(0xFF2E2A1A), fontSize: 13)),
        ]),
      ]),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: LL.text3),
          const SizedBox(width: 8),
          SizedBox(width: 40, child: Text(label, style: const TextStyle(color: LL.text3))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
      );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.color, required this.text});
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.4))),
        ]),
      );
}

/// 发起组局：类型、标题、说明、起止时间、地点（地图选点）、人数、要求。
/// 标题和说明走审核；进入人工审核时显示「审核中」。
class MeetupCreatePage extends ConsumerStatefulWidget {
  const MeetupCreatePage({super.key, this.now});

  /// Fixed "now" for tests.
  final DateTime? now;
  @override
  ConsumerState<MeetupCreatePage> createState() => _MeetupCreatePageState();
}

class _MeetupCreatePageState extends ConsumerState<MeetupCreatePage> {
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _req = TextEditingController();
  int _type = 1;
  late DateTime _start, _end;
  Place? _place;
  int _capacity = 10;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final n = widget.now ?? DateTime.now();
    // Next full hour, at least 2 hours from now.
    _start = DateTime(n.year, n.month, n.day, n.hour).add(const Duration(hours: 3));
    _end = _start.add(const Duration(hours: 2));
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _req.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final n = widget.now ?? DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(n.year, n.month, n.day),
      lastDate: n.add(const Duration(days: 30)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_start));
    if (t == null || !mounted) return;
    final dur = _end.difference(_start);
    setState(() {
      _start = DateTime(d.year, d.month, d.day, t.hour, t.minute);
      _end = _start.add(dur);
    });
  }

  Future<void> _pickEnd() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_end));
    if (t == null || !mounted) return;
    var e = DateTime(_start.year, _start.month, _start.day, t.hour, t.minute);
    if (!e.isAfter(_start)) e = e.add(const Duration(days: 1));
    setState(() => _end = e);
  }

  Future<void> _pickPlace() async {
    final p = await pickPlace(context, initial: _place, title: '集合地点');
    if (p != null && mounted) setState(() => _place = p);
  }

  Future<void> _submit() async {
    final place = _place;
    if (place == null) {
      toast(context, '请在地图上选择集合地点');
      return;
    }
    final d = MeetupDraft(
      type: _types[_type],
      title: _title.text,
      description: _desc.text,
      startTime: _start,
      endTime: _end,
      place: place,
      capacity: _capacity,
      requirement: _req.text,
    );
    final err = d.validate(now: widget.now);
    if (err != null) {
      toast(context, err);
      return;
    }
    setState(() => _busy = true);
    final m = await runGuarded(context, () => ref.read(gatheringApiProvider).createMeetup(d));
    if (!mounted) return;
    setState(() => _busy = false);
    if (m == null) return;
    ref.invalidate(myMeetupsProvider);
    ref.invalidate(communityHomeProvider);
    toast(context, m.isPending ? '已提交，审核通过后会出现在附近列表' : '发起成功，群聊已创建');
    if (context.canPop()) {
      context.pop(m);
    } else {
      context.pushReplacement('/meetups/${m.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MM-dd HH:mm');
    return Scaffold(
      body: SafeArea(
        child: ListView(children: [
          const BackHeader(title: '发起组局', subtitle: '报名的人会自动进群聊'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              PillTabs(labels: _typeLabels.sublist(1), index: _type - 1, onChanged: (i) => setState(() => _type = i + 1)),
              const SizedBox(height: 14),
              TextField(
                key: const Key('meetup_title'),
                controller: _title,
                inputFormatters: [LengthLimitingTextInputFormatter(30)],
                decoration: const InputDecoration(hintText: '标题（≤ 30 字），如 周六世纪公园约跑'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('meetup_desc'),
                controller: _desc,
                minLines: 3,
                maxLines: 6,
                inputFormatters: [LengthLimitingTextInputFormatter(300)],
                decoration: const InputDecoration(hintText: '说明（≤ 300 字）：路线、配速、装备…'),
              ),
              const SizedBox(height: 10),
              _PickTile(icon: Icons.play_circle_outline_rounded, label: '开始', value: fmt.format(_start), onTap: _pickStart),
              _PickTile(icon: Icons.stop_circle_outlined, label: '结束', value: fmt.format(_end), onTap: _pickEnd),
              _PickTile(
                key: const Key('meetup_place'),
                icon: Icons.place_outlined,
                label: '地点',
                value: _place?.name ?? '在地图上选择',
                onTap: _pickPlace,
              ),
              LLCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(children: [
                  const Icon(Icons.groups_outlined, color: LL.text3),
                  const SizedBox(width: 10),
                  const Text('人数', style: TextStyle(color: LL.text2)),
                  const Spacer(),
                  IconButton(
                      onPressed: _capacity > 2 ? () => setState(() => _capacity--) : null,
                      icon: const Icon(Icons.remove_circle_outline)),
                  Text('$_capacity', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                  IconButton(
                      onPressed: _capacity < 50 ? () => setState(() => _capacity++) : null,
                      icon: const Icon(Icons.add_circle_outline)),
                ]),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _req,
                inputFormatters: [LengthLimitingTextInputFormatter(40)],
                decoration: const InputDecoration(hintText: '要求（选填），如 配速 5\'30"–6\'30"'),
              ),
              const SizedBox(height: 10),
              const Text('开始时间需在 1 小时后、30 天内，时长不超过 12 小时，人数 2–50。标题和说明需要通过审核，含联系方式等内容会进入人工审核。',
                  style: TextStyle(color: LL.text3, fontSize: 12, height: 1.5)),
              const SizedBox(height: 20),
              FilledButton(onPressed: _busy ? null : _submit, child: const Text('发起')),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _PickTile extends StatelessWidget {
  const _PickTile({super.key, required this.icon, required this.label, required this.value, required this.onTap});
  final IconData icon;
  final String label, value;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: LLCard(
          onTap: onTap,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(children: [
            Icon(icon, color: LL.text3),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(color: LL.text2)),
            const SizedBox(width: 16),
            Expanded(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800))),
            const Icon(Icons.chevron_right_rounded, color: LL.text3),
          ]),
        ),
      );
}
