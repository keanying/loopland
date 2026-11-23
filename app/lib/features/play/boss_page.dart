import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/ai_models.dart';
import '../../api/errors.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../claim/geo.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../realtime/realtime_client.dart';
import '../../realtime/realtime_providers.dart';
import '../../widgets/card_art.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import '../../widgets/monster_art.dart';
import '../ai/ai_widgets.dart';
import 'locate.dart';
import 'play_providers.dart';
import 'play_widgets.dart';

/// Damage rules grouped for the 2-column grid: "跑步 / 骑行" · "每 1 km = 100 伤害".
List<(String, String)> damageTiles(List<DamageRule> rules, BossStrikeInfo strike) {
  final groups = <String, List<String>>{};
  for (final r in rules) {
    groups.putIfAbsent(r.text, () => []).add(r.label.isNotEmpty ? r.label : sportName(r.sport));
  }
  return [
    for (final e in groups.entries) (e.value.join(' / '), e.key),
    ('投入能量', '每 ${strike.cost} 能量 = ${strike.damage} 伤害'),
  ];
}

String _kindName(String kind) =>
    switch (kind) { 'role' => '角色卡', 'blueprint' => '建筑图纸', 'egg' => '伙伴蛋', 'energy' => '能量', _ => kind };

/// 怪兽来袭：倒计时、怪兽、血量（WebSocket 实时）、伤害规则、出战 / 合击、伤害榜、掉落概率公示、结果。
class BossPage extends ConsumerStatefulWidget {
  const BossPage({super.key, required this.bossId});
  final int bossId;
  @override
  ConsumerState<BossPage> createState() => _BossPageState();
}

class _BossPageState extends ConsumerState<BossPage> {
  /// Live overrides on top of the fetched boss.
  int? _hp;
  String? _status;
  int? _energy;
  DateTime? _cooldownUntil;
  StrikeResult? _last;
  bool _busy = false;
  int? _myExtraDamage;

  Boss _merge(Boss b) {
    var out = b.copyWith(hp: _hp, status: _status);
    if (_myExtraDamage != null) out = out.copyWith(me: BossMe(damage: b.me.damage + _myExtraDamage!, rank: b.me.rank, engagedUntil: b.me.engagedUntil));
    return out;
  }

  void _onLive(BossHpEvent e) {
    final was = _status;
    setState(() {
      _hp = e.hp;
      _status = e.status;
    });
    if (e.status != 'active' && was != e.status) _reload();
  }

  void _reload() {
    setState(() {
      _hp = null;
      _status = null;
      _myExtraDamage = null;
    });
    ref.invalidate(bossProvider(widget.bossId));
  }

  Future<void> _engage(Boss b) async {
    // GPS sports damage the boss automatically when the track enters its
    // range; engaging (in range) also counts home training for engage_h.
    final at = await currentLocation(context, ref);
    if (!mounted) return;
    if (at != null) {
      try {
        final until = await ref.read(apiProvider).engage(b.id, at);
        if (mounted) toast(context, '已出战！${until == null ? '' : '${Fmt.dateTime(until)} 前'}居家运动也会对${b.name}造成伤害');
      } on ApiException catch (e) {
        if (!mounted) return;
        toast(context, e.code == 'out_of_range' ? '跑进${b.name}的范围，轨迹经过就会造成伤害' : e.message);
      }
    }
    if (mounted) context.push('/start');
  }

  Future<void> _strike(Boss b) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final at = await currentLocation(context, ref);
      if (at == null || !mounted) return;
      final c = b.center;
      if (c != null && haversine(c, at) > b.radiusM) {
        toast(context, '你离${b.name}还有 ${distanceText(haversine(c, at) - b.radiusM)}，进入范围才能合击');
        return;
      }
      final r = await ref.read(apiProvider).strike(b.id, at);
      if (!mounted) return;
      setState(() {
        _last = r;
        _hp = r.hp;
        _status = r.status;
        _energy = r.energy;
        _myExtraDamage = (_myExtraDamage ?? 0) + r.damage;
        _cooldownUntil = DateTime.now().add(Duration(seconds: b.strike.cooldownS));
      });
      ref.read(authProvider.notifier).refreshUser().ignore();
      if (r.status != 'active') _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'cooldown') {
        setState(() => _cooldownUntil = DateTime.now().add(Duration(seconds: e.retryAfterS ?? b.strike.cooldownS)));
      }
      if (e.code == 'boss_not_active') _reload();
      showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<BossHpEvent>>(bossLiveProvider(widget.bossId), (_, next) {
      final e = next.value;
      if (e != null) _onLive(e);
    });
    final async = ref.watch(bossProvider(widget.bossId));
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AsyncBody<Boss>(
          value: async,
          onRetry: () => ref.invalidate(bossProvider(widget.bossId)),
          data: (fetched) {
            final b = _merge(fetched);
            _cooldownUntil ??= fetched.strike.availableInS > 0
                ? DateTime.now().add(Duration(seconds: fetched.strike.availableInS))
                : null;
            return RefreshIndicator(onRefresh: () async => _reload(), child: _body(b));
          },
        ),
      ),
    );
  }

  Widget _body(Boss b) {
    final user = ref.watch(userProvider);
    final live = ref.watch(realtimeStatusProvider).value == RealtimeStatus.connected;
    final energy = _energy ?? user?.energy ?? 0;
    return ListView(padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom), children: [
      Row(children: [
        RoundIconButton(icon: LIcons.back, onTap: () => Navigator.of(context).maybePop()),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('怪兽来袭', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 1)),
            Text([if (b.locationName.isNotEmpty) b.locationName, '${b.participants} 人出战'].join(' · '),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 13)),
          ]),
        ),
        if (b.isActive) ...[
          // A-04「问 AI」: how to beat it (hidden when AI is off).
          AskAIButton(aiContext: AIContext(type: 'boss', id: b.id, name: b.name), compact: true),
          const SizedBox(width: 8),
          TimerPill(until: b.expiresAt),
        ],
      ]),
      const SizedBox(height: 14),
      _MonsterCard(boss: b, live: live && b.isActive),
      if (b.isActive) ...[
        const SizedBox(height: 12),
        _RulesGrid(tiles: damageTiles(b.damageRules, b.strike)),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () => _engage(b),
              icon: const LIcon(LIcons.play),
              label: const Text('去运动出战'),
            ),
          ),
          const SizedBox(width: 10),
          Countdown(
            until: _cooldownUntil,
            builder: (context, left) {
              final cooling = left > Duration.zero;
              final noEnergy = energy < b.strike.cost;
              return FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6A3D),
                  foregroundColor: LL.ink,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                onPressed: cooling || _busy || noEnergy ? null : () => _strike(b),
                icon: const LIcon(LIcons.bolt),
                label: Text(cooling ? '冷却 ${left.inSeconds + 1}s' : (noEnergy ? '能量不足' : '发起合击')),
              );
            },
          ),
        ]),
        const SizedBox(height: 8),
        Text('合击：消耗你 ${b.strike.cost} 能量造成 ${b.strike.damage} 伤害，召集在线队友一起出手。剩余 ${Fmt.thousands(energy)} 能量',
            textAlign: TextAlign.center, style: const TextStyle(color: LL.text3, fontSize: 12, height: 1.5)),
        if (_last != null) ...[
          const SizedBox(height: 10),
          _StrikeResultCard(r: _last!),
        ],
      ] else ...[
        const SizedBox(height: 14),
        _ResultCard(boss: b),
      ],
      if (b.me.damage > 0 || b.me.engagedUntil != null) ...[
        const SizedBox(height: 12),
        LLCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            const LIcon(LIcons.flame, color: LL.orange),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                [
                  '我的伤害 ${Fmt.thousands(b.me.damage)}',
                  if (b.me.rank != null) '第 ${b.me.rank} 名',
                  if (b.me.engagedUntil != null && b.isActive) '出战至 ${Fmt.dateTime(b.me.engagedUntil)}',
                ].join(' · '),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ]),
        ),
      ],
      SectionTitle('${b.name}伤害榜', trailing: Text('已有 ${b.participants} 人出战', style: const TextStyle(color: LL.text2, fontSize: 12))),
      LLCard(
        padding: const EdgeInsets.all(8),
        child: b.rank.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Text('还没有人出手，第一刀留给你', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)))
            : Column(children: [
                for (final r in b.rank)
                  RankRow(rank: r.rank, name: r.user.nickname, value: Fmt.thousands(r.damage), highlight: r.user.id == user?.id),
              ]),
      ),
      if (b.drops.isNotEmpty) ...[
        const SectionTitle('击退奖励 · 掉落概率公示'),
        _DropTable(drops: b.drops),
      ],
    ]);
  }
}

class _MonsterCard extends StatelessWidget {
  const _MonsterCard({required this.boss, required this.live});
  final Boss boss;
  final bool live;
  @override
  Widget build(BuildContext context) {
    final b = boss;
    final color = monsterColor(b.kind);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF16161B),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: const Color(0xFF2A2A31), width: 1.5),
      ),
      child: Column(children: [
        Opacity(
          opacity: b.isActive ? 1 : 0.55,
          child: hasArt(b.kind) ? CardArt(artKey: b.kind, width: 170) : MonsterArt(kind: b.kind, size: 170, badge: true),
        ),
        const SizedBox(height: 14),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Flexible(child: Text(b.name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900))),
          const SizedBox(width: 8),
          Tag('首领 Lv.${b.level}', color: color, fg: LL.ink),
        ]),
        if (b.description.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(b.description, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFC9C9D1), fontSize: 13, height: 1.6)),
        ],
        if (b.isActive && (b.occupiedTerritories > 0 || b.effectText.isNotEmpty)) ...[
          const SizedBox(height: 6),
          Text(
            [if (b.occupiedTerritories > 0) '霸占 ${b.occupiedTerritories} 块地', if (b.effectText.isNotEmpty) b.effectText].join(' · '),
            textAlign: TextAlign.center,
            style: const TextStyle(color: LL.orange, fontSize: 12),
          ),
        ],
        const SizedBox(height: 14),
        Row(children: [
          const Text('剩余血量', style: TextStyle(color: LL.text2, fontSize: 13)),
          if (live) ...[
            const SizedBox(width: 8),
            Container(width: 7, height: 7, decoration: const BoxDecoration(color: LL.lime, shape: BoxShape.circle)),
            const SizedBox(width: 4),
            const Text('实时', style: TextStyle(color: LL.lime, fontSize: 11, fontWeight: FontWeight.w700)),
          ],
          const Spacer(),
          Text('${Fmt.thousands(b.hp)} / ${Fmt.thousands(b.hpMax)}', style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: LL.ink, width: 1.5)),
          child: LLProgress(value: b.hpFraction, color: const Color(0xFFFF6A3D), bg: const Color(0xFF2A2A31), height: 14),
        ),
      ]),
    );
  }
}

class _RulesGrid extends StatelessWidget {
  const _RulesGrid({required this.tiles});
  final List<(String, String)> tiles;
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = (box.maxWidth - 8) / 2;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (title, text) in tiles)
          SizedBox(
            width: w,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: LL.card, borderRadius: BorderRadius.circular(18)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                const SizedBox(height: 4),
                Text(text, style: const TextStyle(color: LL.lime, fontSize: 13)),
              ]),
            ),
          ),
      ]);
    });
  }
}

class _StrikeResultCard extends StatelessWidget {
  const _StrikeResultCard({required this.r});
  final StrikeResult r;
  @override
  Widget build(BuildContext context) => LLCard(
        color: const Color(0xFF2A1A14),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          const LIcon(LIcons.bolt, color: LL.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '造成 ${r.damage} 伤害', style: const TextStyle(fontWeight: FontWeight.w900)),
              if (r.comboPct > 0)
                TextSpan(text: '  合击加成 +${r.comboPct}%', style: const TextStyle(color: LL.lime, fontWeight: FontWeight.w800)),
              TextSpan(text: '  剩余能量 ${Fmt.thousands(r.energy)}', style: const TextStyle(color: LL.text2)),
            ])),
          ),
        ]),
      );
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.boss});
  final Boss boss;
  @override
  Widget build(BuildContext context) {
    final b = boss;
    final won = b.isDefeated;
    final fg = won ? LL.ink : LL.text;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: won ? LL.lime : LL.card, borderRadius: BorderRadius.circular(26)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(won ? '击退成功！${b.name}被赶走了' : '${b.name}溜走了',
            style: TextStyle(color: fg, fontSize: 20, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        Text(
          won
              ? '${b.occupiedTerritories > 0 ? '被霸占的 ${b.occupiedTerritories} 块地已解放，能量产出恢复。' : ''}${b.myRewards.isEmpty ? (b.me.damage > 0 ? '战利品已发放。' : '这次你没有参战。') : '你的战利品：'}'
              : b.me.damage > 0
                  ? '到期没能击退。合击花费的能量已按比例返还。'
                  : '到期没能击退，下次早点出手。',
          style: TextStyle(color: won ? const Color(0xFF2B300E) : LL.text2, fontSize: 13),
        ),
        if (b.myRewards.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 10, children: [
            for (final r in b.myRewards)
              SizedBox(
                width: 92,
                child: Column(children: [
                  if (r.kind == 'energy')
                    Container(
                      width: 72,
                      height: 86,
                      decoration: BoxDecoration(color: LL.ink, borderRadius: BorderRadius.circular(10)),
                      child: const LIcon(LIcons.bolt, color: LL.yellow, size: 40),
                    )
                  else
                    CardArt(artKey: r.item, width: 72),
                  const SizedBox(height: 4),
                  Text(r.name, textAlign: TextAlign.center, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w900)),
                  if (r.convertedEnergy != null)
                    Text('重复，折算 ${r.convertedEnergy} 能量',
                        textAlign: TextAlign.center, style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 10)),
                ]),
              ),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: LL.ink, foregroundColor: LL.lime, minimumSize: const Size(0, 44)),
              onPressed: () => context.go('/codex'),
              child: const Text('去图鉴查看'),
            ),
          ),
        ],
      ]),
    );
  }
}

class _DropTable extends ConsumerWidget {
  const _DropTable({required this.drops});
  final List<BossDrop> drops;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(configProvider).value?.boss;
    return LLCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final d in drops)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              if (hasArt(d.item))
                CardArt(artKey: d.item, width: 36)
              else
                Container(
                  width: 36,
                  height: 43,
                  decoration: BoxDecoration(color: LL.card2, borderRadius: BorderRadius.circular(8)),
                  child: LIcon(d.kind == 'energy' ? LIcons.bolt : LIcons.egg, color: LL.yellow, size: 20),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(_kindName(d.kind), style: const TextStyle(color: LL.text3, fontSize: 11)),
                ]),
              ),
              Text('${d.percent % 1 == 0 ? d.percent.toInt() : d.percent}%',
                  style: const TextStyle(color: LL.lime, fontWeight: FontWeight.w900, fontSize: 15)),
            ]),
          ),
        const Divider(),
        const SizedBox(height: 8),
        Text(
          '击退后每位参与者掷 1 次掉落表${cfg == null ? '' : '，伤害前 ${cfg.topExtraRolls} 名多掷 1 次'}；重复的角色卡或图纸折算为能量。'
          '${cfg == null ? '' : '到期未击退返还合击花费的 ${cfg.expireRefundPct}%。'}',
          style: const TextStyle(color: LL.text2, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 6),
        const Text('掉落只能通过运动和合力击退获得，不支持付费抽取。', style: TextStyle(color: LL.text3, fontSize: 12, height: 1.5)),
      ]),
    );
  }
}
