import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_common.dart' show CursorPager;
import '../../api/gathering_api.dart';
import '../../api/gathering_models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/card_art.dart';
import '../../widgets/common.dart';
import '../../widgets/cursor_list.dart';
import '../community/gathering_providers.dart';
import '../community/gathering_widgets.dart';
import '../social/social_widgets.dart' show UserAvatar, mediaUrl, openProfile;

const _statuses = ['', 'signup', 'upcoming', 'running', 'finished'];
const _statusLabels = ['全部', '报名中', '即将开始', '进行中', '已结束'];

/// 赛事中心（D-12）：按状态列出线上赛 / 线下赛，城区联赛入口。
class RacesPage extends ConsumerStatefulWidget {
  const RacesPage({super.key});
  @override
  ConsumerState<RacesPage> createState() => _RacesPageState();
}

class _RacesPageState extends ConsumerState<RacesPage> {
  int _status = 1;
  late final CursorPager<Race> _pager =
      CursorPager((cursor) => ref.read(gatheringApiProvider).races(status: _statuses[_status], cursor: cursor));

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '赛事中心', subtitle: '线上赛 · 线下赛 · 城区联赛'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ChipTabs(
              labels: _statusLabels,
              index: _status,
              onChanged: (i) {
                setState(() => _status = i);
                _pager.refresh();
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: CursorListView<Race>(
              pager: _pager,
              empty: '暂时没有${_status == 0 ? '' : _statusLabels[_status]}的赛事',
              header: [
                LLCard(
                  color: LL.lime,
                  onTap: () => context.push('/league'),
                  child: const Row(children: [
                    Icon(Icons.shield_moon_outlined, color: LL.ink),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('城区联赛', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: 16)),
                        Text('同城区跑团每周比拼新圈面积', style: TextStyle(color: Color(0xFF3A3F1A), fontSize: 13)),
                      ]),
                    ),
                    Icon(Icons.chevron_right_rounded, color: LL.ink),
                  ]),
                ),
                const SizedBox(height: 12),
              ],
              itemBuilder: (context, r, _) => RaceCard(race: r),
            ),
          ),
        ]),
      ),
    );
  }
}

/// 赛事详情：封面、规则、距离、时间窗、穿戴设备要求、奖牌、排行榜、我的成绩；报名 / 取消。
class RaceDetailPage extends ConsumerStatefulWidget {
  const RaceDetailPage({super.key, required this.raceId});
  final int raceId;
  @override
  ConsumerState<RaceDetailPage> createState() => _RaceDetailPageState();
}

class _RaceDetailPageState extends ConsumerState<RaceDetailPage> {
  bool _busy = false;

  GatheringApi get _api => ref.read(gatheringApiProvider);

  Future<void> _act(Future<Race> Function() f, String done) async {
    setState(() => _busy = true);
    final r = await runGuarded(context, f);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r == null) return;
    ref.invalidate(raceProvider(widget.raceId));
    ref.invalidate(communityHomeProvider);
    toast(context, done);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(raceProvider(widget.raceId));
    final me = ref.watch(userProvider)?.id;
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<Race>(
          value: async,
          onRetry: () => ref.invalidate(raceProvider(widget.raceId)),
          data: (r) => Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                BackHeader(title: r.isOnline ? '线上赛' : '线下赛', subtitle: r.statusName),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    ClipRRect(borderRadius: BorderRadius.circular(LL.radius), child: RaceCover(race: r, height: 170)),
                    const SizedBox(height: 14),
                    Text(r.title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      Tag(r.isOnline ? '线上赛' : '线下赛', color: r.isOnline ? LL.sky : LL.orange),
                      Tag(r.statusName, color: r.status == 'signup' || r.status == 'running' ? LL.lime : LL.card2),
                      Tag(sportName(r.sport)),
                      if (r.requiresWearable) const Tag('需穿戴设备', color: LL.yellow),
                    ]),
                    const SizedBox(height: 14),
                    if (r.myEntry != null) ...[_MyResult(race: r), const SizedBox(height: 12)],
                    LLCard(
                      child: Column(children: [
                        _Row(Icons.straighten_rounded, '距离', '${Fmt.km(r.distanceM, digits: r.distanceM % 1000 == 0 ? 0 : 1)} km'),
                        _Row(Icons.schedule_rounded, '比赛时间', '${Fmt.dateTime(r.startTime)} – ${Fmt.dateTime(r.endTime)}'),
                        _Row(Icons.how_to_reg_outlined, '报名截止', Fmt.dateTime(r.signupEndTime)),
                        if (r.place != null) _Row(Icons.place_outlined, '地点', r.place!.name),
                        _Row(Icons.groups_outlined, '名额',
                            '已报名 ${Fmt.thousands(r.signedCount)}${r.capacity > 0 ? ' / ${Fmt.thousands(r.capacity)}' : ''}'),
                      ]),
                    ),
                    const SectionHeader('规则'),
                    LLCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                          r.isOnline
                              ? '比赛时间内，单次${sportName(r.sport)}距离达到 ${Fmt.km(r.distanceM, digits: 1)} km 即完赛（开始和结束都要在时间窗内）。成绩按距离折算到赛事距离，用时越短排名越靠前；只算第一次完赛。'
                              : '线下赛按现场成绩，由主办方在赛后标记完赛并发放奖牌。',
                          style: const TextStyle(height: 1.6),
                        ),
                        if (r.requiresWearable) ...[
                          const SizedBox(height: 10),
                          Container(
                            key: const Key('race_wearable'),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(color: LL.yellow.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                            child: const Row(children: [
                              Icon(Icons.watch_outlined, color: LL.yellow, size: 18),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text('本赛事要求穿戴设备（手表 / 手环）数据，只用手机记录的运动不计成绩。',
                                    style: TextStyle(fontSize: 13, height: 1.4)),
                              ),
                            ]),
                          ),
                        ],
                        if (r.description.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(r.description, style: const TextStyle(color: LL.text2, height: 1.6)),
                        ],
                      ]),
                    ),
                    if (r.medal != null) ...[
                      const SectionHeader('完赛奖牌'),
                      LLCard(
                        child: Row(children: [
                          _MedalImage(medal: r.medal!, obtained: r.myEntry?.finished ?? false),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(r.medal!.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                              const SizedBox(height: 4),
                              Text((r.myEntry?.finished ?? false) ? '已获得，可在图鉴 › 奖牌查看' : '完赛后自动发放到图鉴 › 奖牌',
                                  style: const TextStyle(color: LL.text2, fontSize: 13)),
                            ]),
                          ),
                        ]),
                      ),
                    ],
                    if (r.leaderboard.isNotEmpty || r.status == 'running' || r.status == 'finished') ...[
                      SectionHeader(r.isOnline ? '排行榜 · 用时' : '完赛名单'),
                      if (r.leaderboard.isEmpty)
                        const LLCard(child: Text('还没有人完赛', style: TextStyle(color: LL.text2)))
                      else
                        for (final e in r.leaderboard)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: LLCard(
                              color: e.user.id == me ? const Color(0xFF23271A) : null,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              child: Row(children: [
                                SizedBox(
                                  width: 30,
                                  child: Text('${e.rank}',
                                      style: TextStyle(fontWeight: FontWeight.w900, color: e.rank <= 3 ? LL.lime : LL.text2)),
                                ),
                                UserAvatar(user: e.user, size: 36, onTap: () => openProfile(context, e.user)),
                                const SizedBox(width: 10),
                                Expanded(child: Text(e.user.id == me ? '${e.user.nickname}（我）' : e.user.nickname)),
                                Text(Fmt.duration(e.resultSec), style: const TextStyle(fontWeight: FontWeight.w900)),
                              ]),
                            ),
                          ),
                    ],
                  ]),
                ),
              ]),
            ),
            _actions(r),
          ]),
        ),
      ),
    );
  }

  Widget _actions(Race r) {
    final e = r.myEntry;
    final Widget button;
    if (r.canCancel) {
      button = OutlinedButton(
        onPressed: _busy ? null : () => _act(() => _api.cancelRaceSignup(r.id), '已取消报名'),
        child: const Text('取消报名'),
      );
    } else if (r.canSignup) {
      button = FilledButton(
        onPressed: _busy ? null : () => _act(() => _api.signupRace(r.id), r.isOnline ? '报名成功，比赛时间内去跑吧' : '报名成功'),
        child: const Text('立即报名（免费）'),
      );
    } else {
      final label = switch (r.status) {
        _ when e?.finished ?? false => '已完赛',
        _ when e != null && r.status == 'running' => r.isOnline ? '比赛进行中，去跑一次吧' : '比赛进行中',
        'signup' => '名额已满',
        'upcoming' => '报名已截止',
        'running' => '比赛进行中',
        'cancelled' => '赛事已取消',
        _ => '已结束',
      };
      button = e != null && r.status == 'running' && r.isOnline
          ? FilledButton(onPressed: () => context.go('/start'), child: Text(label))
          : FilledButton(onPressed: null, child: Text(label));
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: LL.border))),
      child: SizedBox(width: double.infinity, child: button),
    );
  }
}

class _MyResult extends StatelessWidget {
  const _MyResult({required this.race});
  final Race race;
  @override
  Widget build(BuildContext context) {
    final e = race.myEntry!;
    final (title, body, color) = switch (e.status) {
      'finished' => (
          '完赛 ${e.resultSec == null ? '' : Fmt.duration(e.resultSec!)}',
          [if (e.rank != null) '第 ${e.rank} 名', if (e.finishedAt != null) '${Fmt.dateTime(e.finishedAt)} 完成'].join(' · '),
          LL.lime,
        ),
      'dnf' => ('未完赛', '比赛时间内没有完成规定距离', LL.card2),
      _ => (
          '已报名',
          race.isOnline ? '在比赛时间内完成一次 ≥ ${Fmt.km(race.distanceM, digits: 1)} km 的${sportName(race.sport)}即可完赛' : '按时到场参赛',
          LL.sky,
        ),
    };
    final dark = color != LL.card2;
    return Container(
      key: const Key('race_my_entry'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(LL.radius)),
      child: Row(children: [
        Icon(e.finished ? Icons.emoji_events_rounded : Icons.how_to_reg_rounded, color: dark ? LL.ink : LL.text, size: 32),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('我的成绩 · $title',
                style: TextStyle(color: dark ? LL.ink : LL.text, fontWeight: FontWeight.w900, fontSize: 17)),
            if (body.isNotEmpty)
              Text(body, style: TextStyle(color: dark ? const Color(0xFF2A2F14) : LL.text2, fontSize: 13)),
          ]),
        ),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.icon, this.label, this.value);
  final IconData icon;
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(icon, size: 18, color: LL.text3),
          const SizedBox(width: 8),
          SizedBox(width: 68, child: Text(label, style: const TextStyle(color: LL.text3))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
      );
}

class _MedalImage extends StatelessWidget {
  const _MedalImage({required this.medal, required this.obtained});
  final RaceMedal medal;
  final bool obtained;
  @override
  Widget build(BuildContext context) {
    final art = MedalArt(obtained: obtained, width: 64, label: medal.name);
    final u = medal.imageUrl;
    if (u == null) return art;
    return SizedBox(
      width: 64,
      height: 77,
      child: Image.network(mediaUrl(u), fit: BoxFit.contain, errorBuilder: (_, _, _) => art),
    );
  }
}
