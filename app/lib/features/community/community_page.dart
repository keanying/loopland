import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/gathering_models.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import '../../widgets/nav_shell.dart';
import 'gathering_providers.dart';
import 'gathering_widgets.dart';
import '../../widgets/sound_refresh.dart';

final crewProvider = FutureProvider.autoDispose.family<Crew, int>((ref, id) => ref.watch(apiProvider).crew(id));
final crewMembersProvider =
    FutureProvider.autoDispose.family<List<CrewMember>, int>((ref, id) => ref.watch(apiProvider).crewMembers(id));
final crewApplicationsProvider = FutureProvider.autoDispose
    .family<List<CrewApplication>, int>((ref, id) => ref.watch(apiProvider).crewApplications(id));

const joinModeNames = {'open': '公开加入', 'apply': '申请加入', 'invite': '仅邀请'};

/// 社区首页（D-01）：我的跑团卡片（或加入 / 创建）、动态 / 组局 / 赛事 / 消息入口
/// （带未读数）、即将开始的集结跑、我报名的组局、进行中的赛事。
class CommunityPage extends ConsumerWidget {
  const CommunityPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(communityHomeProvider);
    final home = async.value;
    final unread = (home?.unreadInteraction ?? 0) + (home?.unreadChat ?? 0);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: SoundRefresh(
          onRefresh: () async {
            ref.invalidate(communityHomeProvider);
            await ref.read(authProvider.notifier).refreshUser().catchError((_) {});
            await ref.read(communityHomeProvider.future).catchError((_) => const CommunityHome());
          },
          child: ListView(padding: EdgeInsets.fromLTRB(16, 0, 16, NavShell.bottomInset(context)), children: [
            PageTitle(
              title: '社区',
              subtitle: '跑团 · 组局 · 动态 · 赛事',
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                RoundIconButton(
                    icon: LIcons.bell,
                    size: 52,
                    tooltip: '消息',
                    badge: unread > 0,
                    onTap: () => context.push('/inbox')),
                const SizedBox(width: 8),
                RoundIconButton(
                    icon: LIcons.search, size: 52, tooltip: '找跑团', onTap: () => context.push('/crews/search')),
              ]),
            ),
            const SizedBox(height: 8),
            if (home == null && async.hasError)
              ErrorBox(error: async.error!, onRetry: () => ref.invalidate(communityHomeProvider))
            else if (home == null)
              const Center(child: Padding(padding: EdgeInsets.all(48), child: CircularProgressIndicator()))
            else
              ..._body(context, ref, home),
          ]),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, WidgetRef ref, CommunityHome h) {
    final crew = h.crew;
    return [
      if (crew == null) const _NoCrew() else _HomeCrewCard(crew: crew),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: _Tile(
            key: const Key('entry_meetups'),
            color: LL.pink,
            title: '组局',
            body: h.meetups.isEmpty ? '约跑 · 约球 · 约骑' : '已报名 ${h.meetups.length} 个局',
            foot: '附近找搭子',
            onTap: () => context.push('/meetups'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _Tile(
            key: const Key('entry_feed'),
            color: LL.card,
            title: '动态',
            body: '跑友的圈地战报',
            foot: '关注 · 推荐',
            onTap: () => context.push('/community/feed'),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      _EntryRow(
        key: const Key('entry_races'),
        color: LL.sky,
        icon: LIcons.trophy,
        title: h.races.isEmpty ? '赛事 · 城区联赛' : '赛事 · ${h.races.first.title}',
        subtitle: h.races.isEmpty ? '线上赛、线下赛，完赛得奖牌' : '${h.races.length} 场报名中 / 进行中',
        onTap: () => context.push('/races'),
      ),
      const SizedBox(height: 10),
      _EntryRow(
        key: const Key('entry_inbox'),
        color: LL.lime,
        icon: LIcons.chat,
        title: '消息',
        subtitle: h.unreadInteraction + h.unreadChat == 0
            ? '互动、领地、怪兽、系统通知和私信'
            : [
                if (h.unreadInteraction > 0) '${h.unreadInteraction} 条互动',
                if (h.unreadChat > 0) '${h.unreadChat} 条私信',
              ].join(' · '),
        badge: h.unreadInteraction + h.unreadChat,
        onTap: () async {
          await context.push('/inbox');
          ref.invalidate(communityHomeProvider);
        },
      ),
      if (h.rallies.isNotEmpty) ...[
        SectionHeader('跑团集结跑', action: '全部', onAction: crew == null ? null : () => context.push('/crews/${crew.id}')),
        for (final r in h.rallies)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: RallyBrief(rally: r, onTap: () => context.push('/crews/${r.crew?.id ?? crew?.id ?? 0}')),
          ),
      ],
      if (h.meetups.isNotEmpty) ...[
        SectionHeader('我报名的组局', action: '找更多', onAction: () => context.push('/meetups')),
        for (final m in h.meetups) Padding(padding: const EdgeInsets.only(bottom: 10), child: MeetupCard(meetup: m)),
      ],
      if (h.races.isNotEmpty) ...[
        SectionHeader('赛事', action: '赛事中心', onAction: () => context.push('/races')),
        for (final r in h.races) Padding(padding: const EdgeInsets.only(bottom: 10), child: RaceCard(race: r, compact: true)),
      ],
    ];
  }
}

class _NoCrew extends StatelessWidget {
  const _NoCrew();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(32)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('还没有跑团', style: TextStyle(color: LL.ink, fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text('加入跑团后，你圈的地会记到跑团名下，一起参加集结跑和城区排名。',
            style: TextStyle(color: Color(0xFF2E2648), height: 1.5)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: LL.ink, foregroundColor: LL.lavender),
              onPressed: () => context.push('/crews/search'),
              child: const Text('找跑团'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: LL.ink, side: const BorderSide(color: LL.ink)),
              onPressed: () => context.push('/crews/new'),
              child: const Text('创建跑团'),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Center(
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: LL.ink),
            onPressed: () => context.push('/crews/join-code'),
            child: const Text('有邀请码？输入加入'),
          ),
        ),
      ]),
    );
  }
}

/// Compact crew card from `GET /v1/community/home`.
class _HomeCrewCard extends StatelessWidget {
  const _HomeCrewCard({required this.crew});
  final HomeCrew crew;
  @override
  Widget build(BuildContext context) {
    final c = crew;
    return GestureDetector(
      onTap: () => context.push('/crews/${c.id}'),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(32)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _CrewBadge(name: c.name, url: c.avatarUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.name, style: const TextStyle(color: LL.ink, fontSize: 22, fontWeight: FontWeight.w900)),
                Text('${c.memberCount} 名成员', style: const TextStyle(color: Color(0xFF2E2648))),
              ]),
            ),
            if (c.myRank != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: LL.ink, borderRadius: BorderRadius.circular(16)),
                child: Text('团内 #${c.myRank}', style: const TextStyle(color: LL.lavender, fontWeight: FontWeight.w800)),
              ),
          ]),
          const SizedBox(height: 14),
          const Text('本周新圈', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w800)),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(Fmt.area(c.weekAreaM2), style: const TextStyle(color: LL.ink, fontSize: 36, fontWeight: FontWeight.w900)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: const Color(0x22000000), borderRadius: BorderRadius.circular(16)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Text('集结跑 · 接力', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w800)),
                LIcon(LIcons.chevronRight, color: LL.ink, size: 18),
              ]),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow(
      {super.key, required this.color, required this.icon, required this.title, required this.subtitle, this.badge = 0, this.onTap});
  final Color color;
  final LGlyph icon;
  final String title, subtitle;
  final int badge;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => LLCard(
        onTap: onTap,
        child: Row(children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: LIcon(icon, color: LL.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 13)),
            ]),
          ),
          CountBadge(count: badge),
          const LIcon(LIcons.chevronRight, color: LL.text3),
        ]),
      );
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.color, required this.title, required this.body, required this.foot, this.onTap});
  final Color color;
  final String title, body, foot;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final dark = color != LL.card;
    return Material(
      color: color,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28), side: dark ? BorderSide.none : const BorderSide(color: LL.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 130,
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: dark ? LL.ink : LL.text2, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(body, style: TextStyle(color: dark ? LL.ink : LL.text, fontWeight: FontWeight.w900, fontSize: 17)),
            const Spacer(),
            Text(foot, style: TextStyle(color: dark ? const Color(0xFF3A2440) : LL.text3, fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}

class CrewCard extends StatelessWidget {
  const CrewCard({super.key, required this.crew});
  final Crew crew;
  @override
  Widget build(BuildContext context) {
    final c = crew;
    return GestureDetector(
      onTap: () => context.push('/crews/${c.id}'),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(32)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _CrewBadge(name: c.name, url: c.avatarUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.name, style: const TextStyle(color: LL.ink, fontSize: 22, fontWeight: FontWeight.w900)),
                Text('${c.memberCount} 名成员 · ${c.district}', style: const TextStyle(color: Color(0xFF2E2648))),
              ]),
            ),
            if (c.isLeader)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: LL.ink, borderRadius: BorderRadius.circular(16)),
                child: const Text('团长', style: TextStyle(color: LL.lavender, fontWeight: FontWeight.w800)),
              ),
          ]),
          const SizedBox(height: 14),
          const Text('跑团领地', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w800)),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(Fmt.area(c.territoryAreaM2), style: const TextStyle(color: LL.ink, fontSize: 36, fontWeight: FontWeight.w900)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: const Color(0x22000000), borderRadius: BorderRadius.circular(16)),
              child: Text('${c.territoryCount} 块', style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w800)),
            ),
          ]),
          if (c.weekRank.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('本周团内排行', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            for (final (i, r) in c.weekRank.take(5).indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(width: 22, child: Text('${i + 1}', style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w900))),
                  Expanded(child: Text(r.user.nickname, style: const TextStyle(color: LL.ink))),
                  Text('${Fmt.km(r.distanceM, digits: 1)} km · ${Fmt.area(r.areaM2)}',
                      style: const TextStyle(color: Color(0xFF2E2648), fontSize: 13)),
                ]),
              ),
          ],
        ]),
      ),
    );
  }
}

/// Crew avatar on the lavender card: photo, or the first character in
/// lavender on ink (prototype「兔」badge).
class _CrewBadge extends StatelessWidget {
  const _CrewBadge({required this.name, this.url});
  final String name;
  final String? url;
  @override
  Widget build(BuildContext context) {
    final letter = Container(
      width: 60,
      height: 60,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: LL.ink, shape: BoxShape.circle),
      child: Text(name.isEmpty ? '?' : String.fromCharCodes(name.runes.take(1)),
          style: const TextStyle(color: LL.lavender, fontWeight: FontWeight.w900, fontSize: 26)),
    );
    return url == null ? letter : PersonAvatar(name: name, url: url, size: 60, color: LL.ink);
  }
}
