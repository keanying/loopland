import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/nav_shell.dart';
import '../play/relay_card.dart';

final crewProvider = FutureProvider.autoDispose.family<Crew, int>((ref, id) => ref.watch(apiProvider).crew(id));
final crewMembersProvider =
    FutureProvider.autoDispose.family<List<CrewMember>, int>((ref, id) => ref.watch(apiProvider).crewMembers(id));
final crewApplicationsProvider = FutureProvider.autoDispose
    .family<List<CrewApplication>, int>((ref, id) => ref.watch(apiProvider).crewApplications(id));

const joinModeNames = {'open': '公开加入', 'apply': '申请加入', 'invite': '仅邀请'};

/// 社区（V1）：我的跑团 + 找 / 建跑团；动态、组局、赛事为 V2。
class CommunityPage extends ConsumerWidget {
  const CommunityPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProvider);
    final crewRef = user?.crew;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            await ref.read(authProvider.notifier).refreshUser();
            if (crewRef != null) ref.invalidate(crewProvider(crewRef.id));
          },
          child: ListView(padding: EdgeInsets.fromLTRB(16, 0, 16, NavShell.bottomInset(context)), children: [
            PageTitle(
              title: '社区',
              subtitle: '跑团 · 组局 · 动态',
              trailing: RoundIconButton(icon: Icons.search_rounded, size: 52, tooltip: '找跑团', onTap: () => context.push('/crews/search')),
            ),
            const SizedBox(height: 8),
            if (crewRef == null)
              _NoCrew()
            else
              Consumer(builder: (context, ref, _) {
                final async = ref.watch(crewProvider(crewRef.id));
                return AsyncBody<Crew>(
                  value: async,
                  onRetry: () => ref.invalidate(crewProvider(crewRef.id)),
                  data: (c) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    CrewCard(crew: c),
                    if (c.isMember) ...[const SizedBox(height: 10), RelayCard(crew: c)],
                  ]),
                );
              }),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _Tile(color: LL.pink, title: '组局', body: '约跑、约球、约骑', soon: true)),
              const SizedBox(width: 10),
              Expanded(child: _Tile(color: LL.card, title: '动态', body: '跑友的圈地战报', soon: true)),
            ]),
            const SizedBox(height: 10),
            LLCard(
              onTap: () => context.push('/league'),
              child: Row(children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: const BoxDecoration(color: LL.sky, shape: BoxShape.circle),
                  child: const Icon(Icons.emoji_events_outlined, color: LL.ink),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('赛事 · 城区联赛', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                    Text('同城区跑团每周比拼新圈面积', style: TextStyle(color: LL.text2, fontSize: 13)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: LL.text3),
              ]),
            ),
            const SizedBox(height: 10),
            LLCard(
              onTap: () => context.push('/inbox'),
              child: const Row(children: [
                Icon(Icons.notifications_none_rounded, color: LL.lime),
                SizedBox(width: 12),
                Expanded(child: Text('消息通知', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                Icon(Icons.chevron_right_rounded, color: LL.text3),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _NoCrew extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(32)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('还没有跑团', style: TextStyle(color: LL.ink, fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text('加入跑团后，你圈的地会记到跑团名下，一起参加城区排名。',
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
      ]),
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
            Avatar(name: c.name, size: 60, color: LL.ink),
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

class _Tile extends StatelessWidget {
  const _Tile({required this.color, required this.title, required this.body, this.soon = false});
  final Color color;
  final String title, body;
  final bool soon;
  @override
  Widget build(BuildContext context) {
    final dark = color != LL.card;
    return Container(
      height: 130,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(28),
        border: dark ? null : Border.all(color: LL.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(color: dark ? LL.ink : LL.text2, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(body, style: TextStyle(color: dark ? LL.ink : LL.text, fontWeight: FontWeight.w900, fontSize: 17)),
        const Spacer(),
        if (soon) const ComingSoon(),
      ]),
    );
  }
}
