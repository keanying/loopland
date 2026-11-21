import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/gathering_api.dart';
import '../../api/gathering_models.dart';
import '../../api/models.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../play/locate.dart';
import 'gathering_providers.dart';
import 'gathering_widgets.dart';
import 'place_picker.dart';

/// 集结跑（D-10）inside the crew page: list, 团长发起, 报名 / 退出 / 取消,
/// 到场签到（当前位置）, 加成状态, 群聊.
class RallySection extends ConsumerWidget {
  const RallySection({super.key, required this.crew});
  final Crew crew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(ralliesProvider(crew.id));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Row(children: [
          const Expanded(child: Text('集结跑', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
          if (crew.isLeader)
            TextButton.icon(
              key: const Key('rally_new'),
              onPressed: () async {
                final r = await Navigator.of(context)
                    .push<Rally>(MaterialPageRoute(builder: (_) => RallyCreatePage(crewId: crew.id)));
                if (r != null) ref.invalidate(ralliesProvider(crew.id));
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('发起'),
            ),
        ]),
      ),
      AsyncBody<List<Rally>>(
        value: async,
        onRetry: () => ref.invalidate(ralliesProvider(crew.id)),
        data: (list) => list.isEmpty
            ? LLCard(
                child: Text(
                    crew.isLeader ? '发起一次集结跑，约团友同时同地出发。签到满 2 人，这次运动的合击伤害和能量都有加成。' : '团长还没有发起集结跑。签到满 2 人，这次运动的合击伤害和能量都有加成。',
                    style: const TextStyle(color: LL.text2, height: 1.5)),
              )
            : Column(children: [
                for (final r in list)
                  Padding(padding: const EdgeInsets.only(bottom: 10), child: RallyCard(rally: r, crew: crew)),
              ]),
      ),
    ]);
  }
}

class RallyCard extends ConsumerStatefulWidget {
  const RallyCard({super.key, required this.rally, required this.crew});
  final Rally rally;
  final Crew crew;
  @override
  ConsumerState<RallyCard> createState() => _RallyCardState();
}

class _RallyCardState extends ConsumerState<RallyCard> {
  bool _busy = false;

  GatheringApi get _api => ref.read(gatheringApiProvider);

  Future<void> _run(Future<Rally> Function() f, String done) async {
    setState(() => _busy = true);
    final r = await runGuarded(context, f);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r == null) return;
    ref.invalidate(ralliesProvider(widget.crew.id));
    ref.invalidate(communityHomeProvider);
    toast(context, done);
  }

  Future<void> _checkin() async {
    setState(() => _busy = true);
    final at = await currentLocation(context, ref);
    if (!mounted) return;
    if (at == null) {
      setState(() => _busy = false);
      return;
    }
    try {
      final r = await _api.checkinRally(widget.rally.id, at);
      if (!mounted) return;
      ref.invalidate(ralliesProvider(widget.crew.id));
      ref.invalidate(communityHomeProvider);
      toast(context, r.bonusActive ? '签到成功！集结加成已生效' : '签到成功，再有 1 名团友签到即可激活加成');
    } catch (e) {
      if (!mounted) return;
      final ex = ApiException.from(e);
      if (ex.code == 'checkin_not_allowed') {
        await showDialog<void>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('暂时不能签到'),
            content: Text(ex.message),
            actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('知道了'))],
          ),
        );
      } else {
        showError(context, ex);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('取消这次集结跑？'),
        content: const Text('报名的团友会收到通知。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('再想想')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('取消集结跑')),
        ],
      ),
    );
    if (ok == true && mounted) await _run(() => _api.cancelRally(widget.rally.id), '已取消');
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.rally;
    final open = r.isOpen;
    final status = switch (r.status) {
      'cancelled' => '已取消',
      'ended' => '已结束',
      _ => null,
    };
    return LLCard(
      color: r.bonusActive ? const Color(0xFF23271A) : null,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Tag('集结跑', color: LL.lavender),
          const SizedBox(width: 8),
          Text(whenText(r.startTime), style: const TextStyle(color: LL.text2)),
          const Spacer(),
          if (status != null) Tag(status) else if (r.checkedIn) const Tag('已签到', color: LL.lime) else if (r.joined) const Tag('已报名', color: LL.sky),
          if (widget.crew.isLeader && open)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz_rounded, color: LL.text3),
              onSelected: (_) => _cancel(),
              itemBuilder: (_) => const [PopupMenuItem(value: 'cancel', child: Text('取消集结跑'))],
            ),
        ]),
        const SizedBox(height: 8),
        Text(r.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text('${r.place?.name ?? '-'} · 目标 ${Fmt.km(r.distanceGoalM, digits: 1)} km',
            style: const TextStyle(color: LL.text2, fontSize: 13)),
        const SizedBox(height: 10),
        Row(children: [
          _Count(value: r.joinedCount, label: '报名'),
          const SizedBox(width: 18),
          _Count(value: r.checkedInCount, label: '已签到'),
          const Spacer(),
          if (r.conversationId != null && (r.joined || widget.crew.isLeader))
            RoundIconButton(
              icon: Icons.forum_outlined,
              size: 42,
              tooltip: '群聊',
              onTap: () => context.push('/chat/${r.conversationId}'),
            ),
        ]),
        const SizedBox(height: 10),
        _BonusBar(active: r.bonusActive, checkedIn: r.checkedInCount),
        if (open) ...[
          const SizedBox(height: 12),
          Row(children: [
            if (r.joined && !r.checkedIn) ...[
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
                  onPressed: _busy ? null : () => _run(() => _api.leaveRally(r.id), '已退出'),
                  child: const Text('退出'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                  onPressed: _busy ? null : _checkin,
                  icon: const Icon(Icons.where_to_vote_outlined),
                  label: const Text('到场签到'),
                ),
              ),
            ] else if (!r.joined)
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                  onPressed: _busy ? null : () => _run(() => _api.joinRally(r.id), '报名成功，已加入群聊'),
                  child: const Text('报名'),
                ),
              ),
          ]),
          if (r.joined && !r.checkedIn)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('开始前 30 分钟到开始后 60 分钟内，在集合点 300 米内签到',
                  style: TextStyle(color: LL.text3, fontSize: 12)),
            ),
        ],
      ]),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.value, required this.label});
  final int value;
  final String label;
  @override
  Widget build(BuildContext context) => Text.rich(TextSpan(children: [
        TextSpan(text: '$value', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        TextSpan(text: ' $label', style: const TextStyle(color: LL.text2, fontSize: 13)),
      ]));
}

/// 加成状态：签到满 2 人后，签到成员开始后 3 小时内的运动合击伤害、能量加成。
class _BonusBar extends StatelessWidget {
  const _BonusBar({required this.active, required this.checkedIn});
  final bool active;
  final int checkedIn;
  @override
  Widget build(BuildContext context) => Container(
        key: Key(active ? 'rally_bonus_on' : 'rally_bonus_off'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? LL.lime : LL.card2,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          Icon(Icons.bolt_rounded, size: 18, color: active ? LL.ink : LL.text3),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              active ? '集结加成生效：签到成员 3 小时内的运动，合击伤害和能量加成' : '签到满 2 人激活加成（当前 $checkedIn 人）',
              style: TextStyle(color: active ? LL.ink : LL.text2, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
      );
}

/// 团长发起集结跑：标题、开始时间、集合点（地图选点）、目标距离。
class RallyCreatePage extends ConsumerStatefulWidget {
  const RallyCreatePage({super.key, required this.crewId, this.now});
  final int crewId;
  final DateTime? now;
  @override
  ConsumerState<RallyCreatePage> createState() => _RallyCreatePageState();
}

class _RallyCreatePageState extends ConsumerState<RallyCreatePage> {
  final _title = TextEditingController();
  late DateTime _start;
  Place? _place;
  double _km = 5;
  bool _busy = false;

  static const _goals = [3.0, 5.0, 8.0, 10.0, 21.1];

  @override
  void initState() {
    super.initState();
    final n = widget.now ?? DateTime.now();
    _start = DateTime(n.year, n.month, n.day, n.hour).add(const Duration(hours: 2));
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final n = widget.now ?? DateTime.now();
    final d = await showDatePicker(
        context: context, initialDate: _start, firstDate: DateTime(n.year, n.month, n.day), lastDate: n.add(const Duration(days: 30)));
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_start));
    if (t == null || !mounted) return;
    setState(() => _start = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _submit() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      toast(context, '给这次集结跑起个名字');
      return;
    }
    final place = _place;
    if (place == null) {
      toast(context, '请在地图上选择集合点');
      return;
    }
    if (!_start.isAfter(widget.now ?? DateTime.now())) {
      toast(context, '开始时间需要晚于现在');
      return;
    }
    setState(() => _busy = true);
    final r = await runGuarded(
        context,
        () => ref
            .read(gatheringApiProvider)
            .createRally(widget.crewId, title: title, startTime: _start, place: place, distanceGoalM: _km * 1000));
    if (!mounted) return;
    setState(() => _busy = false);
    if (r == null) return;
    ref.invalidate(communityHomeProvider);
    toast(context, '已发起，全体团员会收到通知');
    Navigator.of(context).pop(r);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(children: [
          const BackHeader(title: '发起集结跑', subtitle: '同一跑团最多 3 个未结束的集结跑'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                key: const Key('rally_title'),
                controller: _title,
                inputFormatters: [LengthLimitingTextInputFormatter(30)],
                decoration: const InputDecoration(hintText: '标题，如 周三夜跑'),
              ),
              const SizedBox(height: 10),
              LLCard(
                onTap: _pickStart,
                child: Row(children: [
                  const Icon(Icons.schedule_rounded, color: LL.text3),
                  const SizedBox(width: 10),
                  const Text('开始时间', style: TextStyle(color: LL.text2)),
                  const Spacer(),
                  Text(DateFormat('MM-dd HH:mm').format(_start), style: const TextStyle(fontWeight: FontWeight.w800)),
                ]),
              ),
              const SizedBox(height: 10),
              LLCard(
                key: const Key('rally_place'),
                onTap: () async {
                  final p = await pickPlace(context, initial: _place, title: '集合点');
                  if (p != null && mounted) setState(() => _place = p);
                },
                child: Row(children: [
                  const Icon(Icons.place_outlined, color: LL.text3),
                  const SizedBox(width: 10),
                  const Text('集合点', style: TextStyle(color: LL.text2)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(_place?.name ?? '在地图上选择',
                        textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              const Text('目标距离', style: TextStyle(color: LL.text2)),
              const SizedBox(height: 8),
              ChipTabs(
                labels: [for (final g in _goals) '${g == g.roundToDouble() ? g.toInt() : g} km'],
                index: _goals.indexOf(_km),
                onChanged: (i) => setState(() => _km = _goals[i]),
              ),
              const SizedBox(height: 12),
              const Text('签到：开始前 30 分钟到开始后 60 分钟内，离集合点 300 米内。签到满 2 人后，签到成员 3 小时内的运动合击伤害和能量都有加成。',
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
