import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'companion_card.dart';
import 'play_providers.dart';

class _Game {
  const _Game({
    required this.id,
    required this.name,
    required this.kind,
    required this.color,
    required this.icon,
    required this.desc,
    required this.steps,
    required this.reward,
    required this.cta,
    this.soon = false,
  });
  final String id, name, kind;
  final Color color;
  final IconData icon;
  final String desc;
  final List<String> steps;
  final String reward, cta;
  final bool soon;
}

/// 玩法中心：核心玩法卡 + 全部玩法。点选下面的玩法，上面的大卡切换成它的说明和入口（同原型）。
class GamesPage extends ConsumerStatefulWidget {
  const GamesPage({super.key, this.initial = 'war'});
  final String initial;
  @override
  ConsumerState<GamesPage> createState() => _GamesPageState();
}

class _GamesPageState extends ConsumerState<GamesPage> {
  late String _sel = widget.initial;

  List<_Game> _games(GameConfig? cfg) {
    final chest = cfg?.chest ?? const ChestConfig();
    final relay = cfg?.relay ?? const RelayConfig();
    final legKm = relay.legKm % 1 == 0 ? relay.legKm.toInt() : relay.legKm;
    return [
      const _Game(
        id: 'war',
        name: '城市争霸',
        kind: '核心玩法',
        color: LL.lime,
        icon: Icons.fort_outlined,
        desc: '自由跑就能圈地，轨迹交叉自动占领。地块可以被抢、被夺回，地图上每块颜色都是一个真人。',
        steps: ['随便跑，路线一交叉就圈下一块', '守卫值低的地最容易被抢，被攻击后 24 小时内跑一圈经过就能加固', '赛季结束按新圈面积定段位、发赛季奖牌'],
        reward: '赛季段位 · 赛季奖牌',
        cta: '去开跑',
      ),
      const _Game(
        id: 'league',
        name: '城区联赛',
        kind: '每周对抗',
        color: LL.lavender,
        icon: Icons.shield_outlined,
        desc: '同一城区的跑团按本周成员新圈的面积排名，每周一 00:00 结算。你圈的每一块地都算进跑团的分。',
        steps: ['加入或创建一个跑团', '本周和团友一起去圈新地', '周一 00:00 结算，看看你们排第几'],
        reward: '城区排名 · 跑团荣誉',
        cta: '查看联赛榜',
      ),
      _Game(
        id: 'chest',
        name: '能量宝箱',
        kind: '每日刷新',
        color: LL.yellow,
        icon: Icons.inventory_2_outlined,
        desc: '地图上每天 06:00 刷新金色宝箱（23:00–05:00 不刷新），跑步轨迹经过自动开启，也可以走到附近手动打开。',
        steps: ['在地图上找到金色宝箱', '跑步经过 ${chest.radiusM.round()} 米内自动开启', '药剂师在场时有概率能量翻倍'],
        reward: '能量 ${chest.energyMin}–${chest.energyMax} · 不计入每日上限',
        cta: '去地图找宝箱',
      ),
      const _Game(
        id: 'orient',
        name: '城市定向',
        kind: '打卡路线',
        color: LL.sky,
        icon: Icons.explore_outlined,
        desc: '按顺序打卡一条路线上的城市地标，像一场城市寻宝。可以分多次跑完，走路、跑步、骑车都算。',
        steps: ['选一条路线，看清打卡点顺序', '运动时按顺序经过每个点自动打卡', '全部到达即完成，领取能量奖励'],
        reward: '能量 · 城市定向家奖牌',
        cta: '查看定向路线',
      ),
      const _Game(
        id: 'pet',
        name: '跑步伙伴',
        kind: '养成',
        color: LL.pink,
        icon: Icons.pets_outlined,
        desc: '孵化后的伙伴会陪你跑步，每跑 100 米涨经验，也可以喂能量。伙伴只陪伴，不提供对抗加成。',
        steps: ['跑步孵化伙伴蛋', '设为陪跑，一起跑就涨经验', '用能量喂它，升级更快'],
        reward: '伙伴等级 · 陪跑里程',
        cta: '带它去跑步',
      ),
      _Game(
        id: 'relay',
        name: '跑团接力',
        kind: '团队',
        color: LL.lavender,
        icon: Icons.timeline_rounded,
        desc: '团长发起 ${relay.defaultLegs} 棒接力，每位成员一次运动跑满 $legKm km 算一棒，限时接满全员得奖励。',
        steps: ['团长在跑团页发起接力', '每人最多跑一棒，单次 GPS 运动 ≥ $legKm km', '${relay.durationH ~/ 24} 天内接满，全员 +${relay.rewardEnergy} 能量'],
        reward: '全员 +${relay.rewardEnergy} 能量',
        cta: '去跑团',
      ),
      const _Game(
        id: 'campaign',
        name: '限时活动',
        kind: '运营活动',
        color: LL.orange,
        icon: Icons.local_fire_department_outlined,
        desc: '配速挑战、夜跑专场、距离挑战……活动期间完成一次符合规则的运动，结算时自动判定完成。',
        steps: ['看清活动规则和时间', '在活动期间去运动', '结算页会显示完成的活动和奖励'],
        reward: '能量 · 限定奖牌',
        cta: '查看限时活动',
      ),
      const _Game(
        id: 'story',
        name: 'AI 剧情夜跑',
        kind: 'AI 语音',
        color: LL.orange,
        icon: Icons.headphones_outlined,
        desc: 'AI 根据你今晚的路线和城市地标实时生成剧情，戴上耳机边听边跑。',
        steps: ['戴上耳机，选一个剧情主题', 'AI 按你的配速调整剧情节奏', '完成章节解锁收藏卡'],
        reward: '剧情收藏卡',
        cta: '即将开放',
        soon: true,
      ),
      const _Game(
        id: 'art',
        name: '轨迹绘画',
        kind: '创意',
        color: LL.lime,
        icon: Icons.gesture_rounded,
        desc: '用跑步轨迹在地图上画画，AI 识别你画的是什么，高分作品进入城市画廊。',
        steps: ['选一个本周主题', '跑出图形，AI 自动识别打分', '高分作品登上城市画廊'],
        reward: '画廊展示 · 能量',
        cta: '即将开放',
        soon: true,
      ),
    ];
  }

  void _go(_Game g) {
    switch (g.id) {
      case 'war':
      case 'pet':
        context.go('/start');
      case 'league':
        context.push('/league');
      case 'chest':
        context.go('/map');
        toast(context, '地图上的金色宝箱就是能量宝箱，点开看看');
      case 'orient':
        context.push('/routes');
      case 'relay':
        final crew = ref.read(userProvider)?.crew;
        crew == null ? context.go('/community') : context.push('/crews/${crew.id}');
      case 'campaign':
        context.push('/campaigns');
    }
  }

  String _players(_Game g) {
    switch (g.id) {
      case 'league':
        final c = ref.watch(userProvider)?.crew;
        return c == null ? '加入跑团参赛' : '「${c.name}」参赛中';
      case 'orient':
        final r = ref.watch(routesProvider).value;
        return r == null ? '' : '${r.length} 条路线开放中';
      case 'campaign':
        final c = ref.watch(campaignsProvider).value;
        if (c == null) return '';
        final now = DateTime.now();
        return '${c.where((x) => x.isLive(now) && !x.completed).length} 个进行中';
      case 'chest':
        return '每天 06:00 刷新';
      case 'pet':
        final p = ref.watch(codexProvider).value?.companions.where((x) => x.hatched).length;
        return p == null ? '' : '已孵化 $p 只';
      case 'relay':
        return ref.watch(userProvider)?.crew == null ? '需要先加入跑团' : '团长发起';
      case 'war':
        return '圈一圈，共同运动，共同圈';
      default:
        return '即将开放';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(configProvider).value;
    final games = _games(cfg);
    final cur = games.firstWhere((g) => g.id == _sel, orElse: () => games.first);
    final live = games.where((g) => !g.soon).length;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(padding: EdgeInsets.fromLTRB(16, 0, 16, 32 + MediaQuery.paddingOf(context).bottom), children: [
          BackHeader(title: '玩法中心', subtitle: '${games.length} 种玩法 · 已开放 $live 种 · 都会给你的领地加分'),
          const SizedBox(height: 6),
          _Hero(game: cur, players: _players(cur), onGo: cur.soon ? null : () => _go(cur), extra: _extra(cur)),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 22, 0, 10),
            child: Text('全部玩法', style: TextStyle(color: LL.text2, fontSize: 15)),
          ),
          LayoutBuilder(builder: (context, box) {
            final w = (box.maxWidth - 10) / 2;
            return Wrap(spacing: 10, runSpacing: 10, children: [
              for (final g in games)
                SizedBox(
                  width: w,
                  child: _Tile(game: g, selected: g.id == cur.id, onTap: () => setState(() => _sel = g.id)),
                ),
            ]);
          }),
        ]),
      ),
    );
  }

  Widget? _extra(_Game g) {
    if (g.id != 'pet') return null;
    final codex = ref.watch(codexProvider).value;
    final pets = codex?.companions.where((c) => c.hatched).toList() ?? const <CodexCompanion>[];
    if (pets.isEmpty) {
      return const Text('还没有孵化的伙伴，先去跑步孵蛋吧。', style: TextStyle(color: Color(0xFF3A3F1A)));
    }
    final p = pets.where((c) => c.escort).firstOrNull ?? pets.first;
    return CompanionCard(companion: p, dark: true);
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.game, required this.players, required this.onGo, this.extra});
  final _Game game;
  final String players;
  final VoidCallback? onGo;
  final Widget? extra;
  @override
  Widget build(BuildContext context) {
    final g = game;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: LL.lime, borderRadius: BorderRadius.circular(32)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: LL.ink, borderRadius: BorderRadius.circular(16)),
            child: Text(g.kind, style: const TextStyle(color: LL.lime, fontWeight: FontWeight.w900, fontSize: 13)),
          ),
          const Spacer(),
          Flexible(
            child: Text(players,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w800, fontSize: 13)),
          ),
        ]),
        const SizedBox(height: 14),
        Text(g.name, style: const TextStyle(color: LL.ink, fontSize: 30, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        Text(g.desc, style: const TextStyle(color: Color(0xFF2B300E), fontSize: 14, height: 1.6)),
        const SizedBox(height: 12),
        for (final (i, s) in g.steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: LL.ink, shape: BoxShape.circle),
                child: Text('${i + 1}', style: const TextStyle(color: LL.lime, fontSize: 12, fontWeight: FontWeight.w900)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(s, style: const TextStyle(color: LL.ink, fontSize: 14, height: 1.4))),
            ]),
          ),
        if (extra != null) ...[const SizedBox(height: 6), extra!, const SizedBox(height: 6)],
        const SizedBox(height: 6),
        Text('奖励 · ${g.reward}', style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w900)),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: LL.ink, foregroundColor: LL.lime, disabledBackgroundColor: const Color(0x33121212)),
            onPressed: onGo,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(g.cta),
              if (onGo != null) ...[const SizedBox(width: 8), const Icon(Icons.arrow_forward_rounded, size: 20)],
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.game, required this.selected, required this.onTap});
  final _Game game;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final g = game;
    return Semantics(
      button: true,
      selected: selected,
      label: g.name,
      child: Material(
        color: selected ? const Color(0xFF1E1E24) : LL.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
          side: BorderSide(color: selected ? g.color : const Color(0xFF232329), width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: g.soon ? LL.card2 : g.color, shape: BoxShape.circle),
                  child: Icon(g.icon, color: g.soon ? LL.text3 : LL.ink, size: 22),
                ),
                const Spacer(),
                if (g.soon) const ComingSoon(),
              ]),
              const SizedBox(height: 12),
              Text(g.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
              const SizedBox(height: 4),
              Text(g.kind, style: const TextStyle(color: LL.text2, fontSize: 13)),
            ]),
          ),
        ),
      ),
    );
  }
}
