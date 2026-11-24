import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import 'play_providers.dart';
import 'play_widgets.dart';
import '../../widgets/sound_refresh.dart';

String km2(double m2) => (m2 / 1e6).toStringAsFixed(2);

/// Medal glyph + colour by medal type.
(LGlyph, Color) medalLook(String type) => switch (type) {
      'defends' => (LIcons.shield, LL.lime),
      'loops_single' => (LIcons.refresh, LL.lavender),
      'boss_defeats' => (LIcons.flame, LL.orange),
      'chests' => (LIcons.chest, LL.yellow),
      'routes' => (LIcons.compass, LL.sky),
      _ => (LIcons.route, LL.pink),
    };

/// 赛季：段位卡（距下一段还差）、我的 / 跑团排名、赛事中心等入口、奖牌 / 赛季任务 / 排行。
class SeasonPage extends ConsumerStatefulWidget {
  const SeasonPage({super.key});
  @override
  ConsumerState<SeasonPage> createState() => _SeasonPageState();
}

class _SeasonPageState extends ConsumerState<SeasonPage> {
  int _tab = 0;
  int _rankTab = 0;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(seasonProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AsyncBody<SeasonOverview>(
          value: async,
          onRetry: () => ref.invalidate(seasonProvider),
          data: (s) => SoundRefresh(
            onRefresh: () => ref.refresh(seasonProvider.future),
            child: _body(s),
          ),
        ),
      ),
    );
  }

  void _rules(SeasonOverview s) {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('赛季规则', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 12),
            const Text('· 每个赛季 2 个月，按赛季内新圈到的面积定段位和排名。', style: TextStyle(color: LL.text2, height: 1.6)),
            const Text('· 段位从青铜到钻石，每段再分 III / II / I。', style: TextStyle(color: LL.text2, height: 1.6)),
            const Text('· 赛季任务每周一刷新，完成即得能量（不计入每日上限）。', style: TextStyle(color: LL.text2, height: 1.6)),
            const Text('· 赛季结束按最终段位发赛季奖牌，建筑和图鉴不会清空。', style: TextStyle(color: LL.text2, height: 1.6)),
            const SizedBox(height: 12),
            for (final t in s.tiers)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('${t.name}：赛季新圈 ≥ ${km2(t.minM2)} km²', style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _body(SeasonOverview s) {
    final user = ref.watch(userProvider);
    final season = s.season;
    final bottom = 32 + MediaQuery.paddingOf(context).bottom;
    if (season == null) {
      return ListView(padding: EdgeInsets.fromLTRB(16, 0, 16, bottom), children: const [
        BackHeader(title: '赛季'),
        SizedBox(height: 40),
        Center(child: Text('当前没有进行中的赛季，敬请期待下一季', style: TextStyle(color: LL.text2))),
      ]);
    }
    final parts = season.name.split(' ');
    return ListView(padding: EdgeInsets.fromLTRB(16, 8, 16, bottom), children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        RoundIconButton(icon: LIcons.back, onTap: () => Navigator.of(context).maybePop()),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.rich(TextSpan(children: [
              TextSpan(text: parts.first, style: const TextStyle(color: LL.lime)),
              if (parts.length > 1) TextSpan(text: ' ${parts.skip(1).join(' ')}'),
            ]), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
            Text('${periodText(season.startsAt, season.endsAt)} · 剩余 ${season.daysLeft} 天',
                style: const TextStyle(color: LL.text2, fontSize: 13)),
          ]),
        ),
        TextButton(
          style: TextButton.styleFrom(backgroundColor: LL.card, foregroundColor: LL.text, minimumSize: const Size(64, 44)),
          onPressed: () => _rules(s),
          child: const Text('规则'),
        ),
      ]),
      const SizedBox(height: 16),
      _TierCard(s: s),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _RankBox(label: '我的排名', value: s.me.rank == null ? '-' : '#${s.me.rank}')),
        const SizedBox(width: 10),
        Expanded(
          child: _RankBox(
            label: s.crew == null ? '跑团排名' : '「${s.crew!.name}」',
            value: s.crew?.rank == null ? (s.crew == null ? '未加入' : '-') : '#${s.crew!.rank}',
            sub: s.crew == null ? null : '${km2(s.crew!.areaM2)} km²',
          ),
        ),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: _EntryTile(
              icon: LIcons.trophy, color: LL.sky, title: '赛事中心', sub: '城区联赛', onTap: () => context.push('/league')),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _EntryTile(
              icon: LIcons.store, color: LL.pink, title: '本地生活', sub: '订场 · 联名', onTap: () => context.push('/local')),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _EntryTile(
              icon: LIcons.bolt,
              color: LL.yellow,
              title: '能量商城',
              sub: '${Fmt.thousands(user?.energy ?? 0)} 可用',
              onTap: () => context.push('/local?tab=shop')),
        ),
      ]),
      const SizedBox(height: 16),
      PillTabs(labels: const ['奖牌', '赛季任务', '排行'], index: _tab, onChanged: (i) => setState(() => _tab = i)),
      const SizedBox(height: 14),
      switch (_tab) {
        0 => _MedalGrid(medals: s.medals),
        1 => _Tasks(tasks: s.tasks),
        _ => _ranks(s),
      },
    ]);
  }

  Widget _ranks(SeasonOverview s) {
    final me = ref.watch(userProvider);
    final list = _rankTab == 0 ? s.top : s.crewTop;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Align(
        alignment: Alignment.centerLeft,
        child: PillTabs(labels: const ['个人', '跑团'], index: _rankTab, expand: false, onChanged: (i) => setState(() => _rankTab = i)),
      ),
      const SizedBox(height: 10),
      LLCard(
        padding: const EdgeInsets.all(8),
        child: list.isEmpty
            ? const Padding(padding: EdgeInsets.all(20), child: Text('榜单还空着，快去圈地', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)))
            : Column(children: [
                for (final e in list)
                  RankRow(
                    rank: e.rank,
                    name: e.name,
                    value: '${km2(e.areaM2)} km²',
                    highlight: _rankTab == 0 ? e.user?.id == me?.id : e.crew?.id == s.crew?.id,
                  ),
              ]),
      ),
    ]);
  }
}

class _TierCard extends StatelessWidget {
  const _TierCard({required this.s});
  final SeasonOverview s;
  @override
  Widget build(BuildContext context) {
    final tier = s.me.tier;
    final next = s.me.next;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: LL.lime, borderRadius: BorderRadius.circular(32)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('当前段位', style: TextStyle(color: Color(0xFF3A3F1A), fontWeight: FontWeight.w800, fontSize: 13)),
              Text(tier?.text ?? '未定级', style: const TextStyle(color: LL.ink, fontSize: 34, fontWeight: FontWeight.w900)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            const Text('赛季占领', style: TextStyle(color: Color(0xFF3A3F1A), fontWeight: FontWeight.w800, fontSize: 13)),
            Text.rich(TextSpan(children: [
              TextSpan(text: km2(s.me.areaM2), style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900)),
              const TextSpan(text: ' km²', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
            ]), style: const TextStyle(color: LL.ink)),
          ]),
        ]),
        const SizedBox(height: 12),
        LLProgress(value: s.tierProgress, color: LL.ink, bg: const Color(0x33121212), height: 12),
        const SizedBox(height: 12),
        if (s.tiers.isNotEmpty)
          Row(children: [
            for (final t in s.tiers)
              Expanded(
                child: Container(
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.name == tier?.name ? LL.ink : Colors.transparent,
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Text(t.name,
                      style: TextStyle(
                          color: t.name == tier?.name ? LL.lime : const Color(0xFF3A3F1A),
                          fontWeight: FontWeight.w900,
                          fontSize: 14)),
                ),
              ),
          ]),
        const SizedBox(height: 10),
        Text(
          next == null
              ? '已经是最高段位，守住它！'
              : '距 ${next.text} 还差 ${km2(math.max(0, s.me.needM2 ?? 0))} km²',
          style: const TextStyle(color: LL.ink, fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ]),
    );
  }
}

class _RankBox extends StatelessWidget {
  const _RankBox({required this.label, required this.value, this.sub});
  final String label, value;
  final String? sub;
  @override
  Widget build(BuildContext context) => LLCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 12)),
          const SizedBox(height: 2),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            if (sub != null) ...[
              const SizedBox(width: 6),
              Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(sub!, style: const TextStyle(color: LL.text3, fontSize: 11))),
            ],
          ]),
        ]),
      );
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.icon, required this.color, required this.title, required this.sub, required this.onTap});
  final LGlyph icon;
  final Color color;
  final String title, sub;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LLCard(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: LIcon(icon, color: LL.ink, size: 20),
          ),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
          const SizedBox(height: 2),
          Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 12)),
        ]),
      );
}

class _MedalGrid extends StatelessWidget {
  const _MedalGrid({required this.medals});
  final List<SeasonMedal> medals;
  @override
  Widget build(BuildContext context) {
    if (medals.isEmpty) {
      return const Padding(padding: EdgeInsets.all(24), child: Text('本赛季暂无奖牌', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)));
    }
    return LayoutBuilder(builder: (context, box) {
      final w = (box.maxWidth - 10) / 2;
      return Wrap(spacing: 10, runSpacing: 10, children: [
        for (final m in medals) SizedBox(width: w, child: _MedalCard(m: m)),
      ]);
    });
  }
}

class _MedalCard extends StatelessWidget {
  const _MedalCard({required this.m});
  final SeasonMedal m;
  @override
  Widget build(BuildContext context) {
    final (icon, color) = medalLook(m.type);
    return LLCard(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 16),
      onTap: () => toast(context, m.obtained ? '${m.name} · ${Fmt.date(m.obtainedAt)} 获得' : '${m.name} · 进度 ${m.progressText}'),
      child: Column(children: [
        SizedBox(
          width: 96,
          height: 96,
          child: Stack(alignment: Alignment.center, children: [
            Container(
              decoration: BoxDecoration(shape: BoxShape.circle, color: m.obtained ? color : color.withValues(alpha: 0.3)),
            ),
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: CircularProgressIndicator(
                value: m.fraction,
                strokeWidth: 3,
                color: m.obtained ? LL.ink : color,
                  strokeCap: StrokeCap.round,
                  backgroundColor: const Color(0x33121212),
                ),
              ),
            ),
            Container(
              width: 62,
              height: 62,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF121214)),
              child: LIcon(icon, color: color, size: 32),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Text(m.name, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        const SizedBox(height: 8),
        Tag(m.obtained ? '已解锁' : '进行中 ${m.progressText}',
            color: m.obtained ? LL.lavender : LL.card2, fg: m.obtained ? LL.ink : const Color(0xFFD6D6DD)),
      ]),
    );
  }
}

class _Tasks extends StatelessWidget {
  const _Tasks({required this.tasks});
  final List<SeasonTask> tasks;
  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return const Padding(padding: EdgeInsets.all(24), child: Text('本周暂无赛季任务', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)));
    }
    return Column(children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 10),
        child: Text('每周一 00:00 刷新 · 奖励能量不计入每日上限', style: TextStyle(color: LL.text3, fontSize: 12)),
      ),
      for (final t in tasks)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: LLCard(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              LIcon(t.completed ? LIcons.checkCircleFilled : LIcons.ring,
                  color: t.completed ? LL.lime : LL.text3, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  const SizedBox(height: 6),
                  LLProgress(value: t.completed ? 1 : t.fraction),
                  const SizedBox(height: 4),
                  Text(t.progressText, style: const TextStyle(color: LL.text2, fontSize: 12)),
                ]),
              ),
              const SizedBox(width: 12),
              Row(children: [
                const LIcon(LIcons.bolt, color: LL.yellow, size: 18),
                Text('+${t.rewardEnergy}', style: TextStyle(fontWeight: FontWeight.w900, color: t.completed ? LL.text3 : LL.text)),
              ]),
            ]),
          ),
        ),
    ]);
  }
}

/// 城区联赛：本周榜、我的跑团、上周结果。
class LeaguePage extends ConsumerWidget {
  const LeaguePage({super.key, this.district = ''});
  final String district;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(leagueProvider(district));
    final myCrew = ref.watch(userProvider)?.crew;
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<League>(
          value: async,
          onRetry: () => ref.invalidate(leagueProvider(district)),
          data: (l) => ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
            BackHeader(title: '城区联赛', subtitle: [if (l.district.isNotEmpty) l.district, if (l.weekStart.isNotEmpty) '${l.weekStart} 这周'].join(' · ')),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(28)),
              child: l.myCrew == null
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(myCrew == null ? '还没有跑团' : '「${myCrew.name}」本周还没上榜',
                          style: const TextStyle(color: LL.ink, fontSize: 20, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 6),
                      Text(myCrew == null ? '加入一个跑团，和团友一起冲城区第一。' : '本周和团友一起去圈新地，就能上榜。',
                          style: const TextStyle(color: Color(0xFF3B3355))),
                      if (myCrew == null) ...[
                        const SizedBox(height: 12),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: LL.ink, foregroundColor: LL.lavender, minimumSize: const Size(0, 44)),
                          onPressed: () => context.push('/crews/search'),
                          child: const Text('找跑团'),
                        ),
                      ],
                    ])
                  : Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(myCrew == null ? '我的跑团' : '「${myCrew.name}」',
                              style: const TextStyle(color: Color(0xFF3B3355), fontWeight: FontWeight.w800)),
                          Text('第 ${l.myCrew!.rank} 名', style: const TextStyle(color: LL.ink, fontSize: 30, fontWeight: FontWeight.w900)),
                        ]),
                      ),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        const Text('本周新圈', style: TextStyle(color: Color(0xFF3B3355), fontWeight: FontWeight.w800)),
                        Text(Fmt.area(l.myCrew!.scoreM2), style: const TextStyle(color: LL.ink, fontSize: 24, fontWeight: FontWeight.w900)),
                      ]),
                    ]),
            ),
            const SectionTitle('本周排名', trailing: Text('周一 00:00 结算', style: TextStyle(color: LL.text3, fontSize: 12))),
            _standings(l.standings, myCrew?.id),
            if (l.lastWeek.isNotEmpty) ...[
              const SectionTitle('上周结果'),
              _standings(l.lastWeek, myCrew?.id),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _standings(List<LeagueEntry> list, int? myCrewId) => LLCard(
        padding: const EdgeInsets.all(8),
        child: list.isEmpty
            ? const Padding(padding: EdgeInsets.all(20), child: Text('本周还没有跑团上榜', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)))
            : Column(children: [
                for (final e in list)
                  RankRow(
                    rank: e.rank,
                    name: e.crew?.name ?? '',
                    sub: e.activeMembers == null ? null : '${e.activeMembers} 人出力',
                    value: Fmt.area(e.scoreM2),
                    highlight: e.crew?.id != null && e.crew?.id == myCrewId,
                  ),
              ]),
      );
}
