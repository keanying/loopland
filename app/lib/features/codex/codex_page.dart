import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/card_art.dart';
import '../../widgets/common.dart';
import '../../widgets/nav_shell.dart';

/// One card in the codex grid, normalised across categories.
class CodexCardData {
  const CodexCardData({
    required this.art,
    required this.title,
    required this.sub,
    required this.obtained,
    this.detailSource = '',
    this.detailEffect = '',
    this.progress,
    this.medal = false,
    this.companion,
  });
  final String art;
  final String title;
  final String sub;
  final bool obtained;
  final String detailSource;
  final String detailEffect;
  final double? progress;
  final bool medal;
  final CodexCompanion? companion;
}

List<CodexCardData> roleCards(Codex c) => [
      for (final r in c.roles)
        CodexCardData(
          art: r.key,
          title: r.obtained ? r.name : '???',
          sub: r.obtained
              ? '${sportName(r.sport)} · 已招募'
              : '${sportName(r.sport)} ${Fmt.amount(r.progress, r.unit)} / ${Fmt.amount(r.threshold, r.unit)} ${Fmt.unit(r.unit)}',
          obtained: r.obtained,
          detailSource: '${sportName(r.sport)}累计 ${Fmt.amount(r.threshold, r.unit)} ${Fmt.unit(r.unit)}招募，也可能从城市怪兽掉落',
          detailEffect: r.buffText,
          progress: r.threshold > 0 ? r.progress / r.threshold : null,
        ),
    ];

List<CodexCardData> buildingCards(Codex c) => [
      for (final b in c.buildings)
        CodexCardData(
          art: b.key,
          title: b.unlocked ? b.name : '???',
          sub: b.unlocked ? '守卫 +${b.guard} · 产能 +${b.dailyEnergy}' : 'Lv.${b.unlockLevel} 解锁',
          obtained: b.unlocked,
          detailSource: '达到 Lv.${b.unlockLevel} 解锁；高级图纸也可从怪兽掉落',
          detailEffect: '建造 ${b.cost} 能量 · 守卫 +${b.guard} · 每天产出 ${b.dailyEnergy} 能量',
        ),
    ];

List<CodexCardData> companionCards(Codex c) => [
      for (final p in c.companions)
        CodexCardData(
          art: p.key,
          title: p.hatched ? p.name : (p.isEgg ? '神秘蛋' : '???'),
          sub: p.hatched
              ? (p.escort ? '陪跑中' : '已孵化')
              : p.isEgg
                  ? '还差 ${(p.hatchKm - p.progressKm).clamp(0, 9999).toStringAsFixed(1)} km 孵化'
                  : '跑步或打怪兽获得蛋',
          obtained: p.hatched,
          detailSource: p.isEgg
              ? '蛋要跑够 ${p.hatchKm.toStringAsFixed(0)} km 才能孵化'
              : '新用户第一次圈地送一颗蛋，其他蛋来自城市怪兽掉落',
          detailEffect: '孵化后可设为陪跑，跑步时出现在屏幕上。伙伴不提供对抗加成。',
          progress: p.isEgg && p.hatchKm > 0 ? p.progressKm / p.hatchKm : null,
          companion: p,
        ),
    ];

List<CodexCardData> medalCards(Codex c) => [
      for (final m in c.medals)
        CodexCardData(
          art: m.key,
          title: m.obtained ? m.name : '???',
          sub: m.obtained ? Fmt.date(m.obtainedAt) : m.name,
          obtained: m.obtained,
          medal: true,
          detailSource: '累计里程达到要求后自动获得',
        ),
    ];

/// 图鉴：角色 / 建筑 / 伙伴 / 怪兽（V2）/ 奖牌。
class CodexPage extends ConsumerStatefulWidget {
  const CodexPage({super.key});
  @override
  ConsumerState<CodexPage> createState() => _CodexPageState();
}

class _CodexPageState extends ConsumerState<CodexPage> {
  int _tab = 0;

  static const _hints = [
    '不同运动招募不同角色。角色可以派去驻守领地，提供加成。',
    '基础建筑按等级解锁，高级建筑的图纸靠打怪兽掉落。',
    '先拿到蛋，跑够距离就能孵化。孵化后可以设为陪跑。',
    '',
    '里程奖牌：100 / 500 / 1000 km。赛季奖牌随赛季开放。',
  ];

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(codexProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AsyncBody<Codex>(
          value: async,
          onRetry: () => ref.invalidate(codexProvider),
          data: (c) => _body(c),
        ),
      ),
    );
  }

  Widget _body(Codex c) {
    String prog(String k, int got, int total) => c.progress[k] ?? '$got/$total';
    final tabs = ['角色', '建筑', '伙伴', '怪兽', '奖牌'];
    final counts = [
      prog('roles', c.roles.where((r) => r.obtained).length, c.roles.length),
      prog('buildings', c.buildings.where((b) => b.unlocked).length, c.buildings.length),
      prog('companions', c.companions.where((p) => p.hatched).length, c.companions.length),
      '',
      prog('medals', c.medals.where((m) => m.obtained).length, c.medals.length),
    ];
    final cards = switch (_tab) {
      0 => roleCards(c),
      1 => buildingCards(c),
      2 => companionCards(c),
      4 => medalCards(c),
      _ => <CodexCardData>[],
    };
    final total = c.totalCount;
    final egg = c.companions.where((p) => p.isEgg).firstOrNull;
    return RefreshIndicator(
      onRefresh: () => ref.refresh(codexProvider.future),
      child: ListView(padding: EdgeInsets.fromLTRB(16, 12, 16, NavShell.bottomInset(context)), children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('图鉴', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
              Text('运动招募角色 · 领地盖建筑 · 里程孵伙伴', style: TextStyle(color: LL.text2, fontSize: 13)),
            ]),
          ),
          Text.rich(TextSpan(children: [
            TextSpan(text: '${c.obtainedCount}', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
            TextSpan(text: ' / $total', style: const TextStyle(color: LL.text3, fontWeight: FontWeight.w800)),
          ])),
        ]),
        const SizedBox(height: 12),
        LLProgress(value: total == 0 ? 0 : c.obtainedCount / total),
        const SizedBox(height: 16),
        ChipTabs(labels: tabs, trailing: counts, index: _tab, onChanged: (i) => setState(() => _tab = i)),
        const SizedBox(height: 14),
        if (_tab == 3)
          const _MonstersSoon()
        else ...[
          LLCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Text(_hints[_tab], style: const TextStyle(color: LL.text2, fontSize: 13, height: 1.5)),
          ),
          if (_tab == 2 && egg != null) ...[
            const SizedBox(height: 12),
            _EggBanner(egg: egg),
          ],
          const SizedBox(height: 14),
          CodexGrid(cards: cards, onTap: (d) => _detail(d)),
        ],
      ]),
    );
  }

  Future<void> _detail(CodexCardData d) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CodexDetailSheet(data: d),
    );
  }
}

class CodexGrid extends StatelessWidget {
  const CodexGrid({super.key, required this.cards, required this.onTap});
  final List<CodexCardData> cards;
  final ValueChanged<CodexCardData> onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = (box.maxWidth - 16) / 3;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final d in cards)
          SizedBox(
            width: w,
            child: LLCard(
              border: false,
              radius: 20,
              padding: const EdgeInsets.fromLTRB(5, 5, 5, 10),
              onTap: () => onTap(d),
              child: Column(children: [
                d.medal
                    ? MedalArt(obtained: d.obtained, width: w - 10)
                    : CardArt(artKey: d.art, locked: !d.obtained, width: w - 10),
                const SizedBox(height: 8),
                Text(d.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 2),
                Text(d.sub,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: d.obtained ? LL.text2 : LL.text3, fontSize: 11, height: 1.3)),
              ]),
            ),
          ),
      ]);
    });
  }
}

class _EggBanner extends StatelessWidget {
  const _EggBanner({required this.egg});
  final CodexCompanion egg;
  @override
  Widget build(BuildContext context) {
    final left = (egg.hatchKm - egg.progressKm).clamp(0, 9999);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF26223A),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: LL.lavender, width: 1.5),
      ),
      child: Row(children: [
        const Icon(Icons.egg_alt_rounded, color: Color(0xFFF4E9D8), size: 52),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('神秘蛋 · 孵化中', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text('再跑 ${left.toStringAsFixed(1)} km 孵化', style: const TextStyle(color: LL.text2, fontSize: 13)),
            const SizedBox(height: 8),
            LLProgress(value: egg.hatchKm == 0 ? 0 : egg.progressKm / egg.hatchKm, color: LL.lavender, bg: const Color(0x26F4F4F5)),
          ]),
        ),
      ]),
    );
  }
}

class _MonstersSoon extends StatelessWidget {
  const _MonstersSoon();
  @override
  Widget build(BuildContext context) {
    return LLCard(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (final k in ['sofa', 'bat', 'smog', 'sugar'])
            Padding(padding: const EdgeInsets.all(4), child: CardArt(artKey: k, locked: true, width: 64)),
        ]),
        const SizedBox(height: 16),
        const Text('城市怪兽 · 即将开放', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text('沙发怪、熬夜蝠、雾霾怪、糖分怪正在路上。和附近的人一起合击，点亮怪兽图鉴。',
            textAlign: TextAlign.center, style: TextStyle(color: LL.text2, height: 1.5)),
      ]),
    );
  }
}

class CodexDetailSheet extends ConsumerStatefulWidget {
  const CodexDetailSheet({super.key, required this.data});
  final CodexCardData data;
  @override
  ConsumerState<CodexDetailSheet> createState() => _CodexDetailSheetState();
}

class _CodexDetailSheetState extends ConsumerState<CodexDetailSheet> {
  bool _busy = false;

  Future<void> _escort() async {
    final key = widget.data.companion!.key;
    setState(() => _busy = true);
    final c = await runGuarded(context, () => ref.read(apiProvider).setEscort(key));
    if (!mounted) return;
    setState(() => _busy = false);
    if (c != null) {
      ref.invalidate(codexProvider);
      Navigator.pop(context);
      toast(context, '已设为陪跑');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final comp = d.companion;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          d.medal ? MedalArt(obtained: d.obtained, width: 160) : CardArt(artKey: d.art, locked: !d.obtained, width: 160),
          const SizedBox(height: 16),
          Text(d.title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text(d.sub, style: const TextStyle(color: LL.text2)),
          if (d.progress != null && !d.obtained) ...[
            const SizedBox(height: 12),
            LLProgress(value: d.progress!),
          ],
          const SizedBox(height: 16),
          if (d.detailSource.isNotEmpty) _row(Icons.explore_outlined, '来源', d.detailSource),
          if (d.detailEffect.isNotEmpty) _row(Icons.auto_awesome_outlined, '效果', d.detailEffect),
          if (comp != null && comp.hatched) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: comp.escort || _busy ? null : _escort,
                child: Text(comp.escort ? '陪跑中' : '设为陪跑'),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _row(IconData icon, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: LL.lime),
          const SizedBox(width: 8),
          Text('$k  ', style: const TextStyle(fontWeight: FontWeight.w800)),
          Expanded(child: Text(v, style: const TextStyle(color: LL.text2, height: 1.4))),
        ]),
      );
}
