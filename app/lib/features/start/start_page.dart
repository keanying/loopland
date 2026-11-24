import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import '../../widgets/nav_shell.dart';
import '../local/venue_section.dart';
import '../../audio/audio.dart';

class SportInfo {
  const SportInfo(this.key, this.icon, this.desc, {this.tag});
  final String key;
  final LGlyph icon;
  final String desc;
  final String? tag;
}

const gpsSportInfo = [
  SportInfo('run', LIcons.run, '不用规划路线，随便跑。轨迹一交叉就自动圈下一块地，一次能连圈好几块。', tag: '核心'),
  SportInfo('ride', LIcons.bike, '骑得远，圈得大。轨迹交叉同样能圈地，招募骑士。'),
  SportInfo('hike', LIcons.mountain, '山野徒步也能圈地，招募斥候，地图视野 +1。', tag: '热门'),
  SportInfo('walk', LIcons.walk, '饭后健走一圈，也能圈下小区周边，招募农夫。'),
];

const homeSportInfo = [
  SportInfo('strength', LIcons.dumbbell, '按训练时长换能量，招募铁匠，建造费用 -6%。'),
  SportInfo('yoga', LIcons.yoga, '按练习时长换能量，招募修士，每天恢复能量。'),
  SportInfo('rope', LIcons.rope, '按次数换能量，招募药剂师。'),
  SportInfo('hiit', LIcons.flame, '高强度间歇训练，按时长换能量。'),
];

/// 开始：选运动。
class StartPage extends ConsumerStatefulWidget {
  const StartPage({super.key});
  @override
  ConsumerState<StartPage> createState() => _StartPageState();
}

class _StartPageState extends ConsumerState<StartPage> {
  int _cat = 0;
  String _gps = 'run';
  String _home = 'strength';

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    final cfg = ref.watch(configProvider).value;
    final cap = user?.dailyEnergyCap ?? cfg?.dailyEnergyCap ?? 600;
    final today = user?.energyToday ?? 0;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(padding: EdgeInsets.fromLTRB(16, 12, 16, NavShell.bottomInset(context)), children: [
          Row(children: [
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('开始运动', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
                Text('所有运动都能变成能量，守住你的地盘', style: TextStyle(color: LL.text2, fontSize: 13)),
              ]),
            ),
            EnergyBadge(energy: user?.energy ?? 0),
          ]),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: LL.lime, borderRadius: BorderRadius.circular(30)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('今日能量', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('$today', style: const TextStyle(color: LL.ink, fontSize: 40, fontWeight: FontWeight.w900, height: 1)),
                Text(' / $cap', style: const TextStyle(color: LL.ink, fontSize: 18, fontWeight: FontWeight.w800)),
                const Spacer(),
                Text(today >= cap ? '今日已满，明天再来' : '再拿 ${cap - today} 能量',
                    style: const TextStyle(color: Color(0xFF3A3F1A))),
              ]),
              const SizedBox(height: 14),
              LLProgress(value: cap == 0 ? 0 : today / cap, color: LL.ink, bg: const Color(0x22000000), height: 12),
            ]),
          ),
          const SizedBox(height: 16),
          PillTabs(labels: const ['户外', '场馆球类', '居家跟练'], index: _cat, onChanged: (i) => setState(() => _cat = i)),
          const SizedBox(height: 14),
          if (_cat == 0) ..._gpsSection(cfg),
          if (_cat == 1) _venueSection(),
          if (_cat == 2) ..._homeSection(cfg),
        ]),
      ),
    );
  }

  Widget _grid(List<SportInfo> items, String selected, ValueChanged<String> onPick) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 0.95,
      children: [
        for (final s in items)
          _SportTile(info: s, selected: s.key == selected, onTap: () => onPick(s.key)),
      ],
    );
  }

  List<Widget> _gpsSection(GameConfig? cfg) {
    final info = gpsSportInfo.firstWhere((s) => s.key == _gps);
    return [
      _grid(gpsSportInfo, _gps, (k) => setState(() => _gps = k)),
      const SizedBox(height: 14),
      _DetailCard(
        title: sportName(_gps),
        badge: '自由圈地',
        desc: info.desc,
        energy: cfg?.energyFor(_gps)?.text,
        roles: cfg?.rolesFor(_gps).map((r) => r.name).toList() ?? const [],
        button: '开始${sportName(_gps)}',
        onStart: () => context.push('/start/gps?sport=$_gps'),
      ),
    ];
  }

  List<Widget> _homeSection(GameConfig? cfg) {
    final info = homeSportInfo.firstWhere((s) => s.key == _home);
    return [
      _grid(homeSportInfo, _home, (k) => setState(() => _home = k)),
      const SizedBox(height: 14),
      _DetailCard(
        title: sportName(_home),
        badge: '换能量',
        desc: '${info.desc}AI 跟练按动作引导，摄像头在本机自动计数。居家训练不能圈新地，能量可用来建造和加固领地。',
        energy: cfg?.energyFor(_home)?.text,
        roles: cfg?.rolesFor(_home).map((r) => r.name).toList() ?? const [],
        button: 'AI 跟练',
        onStart: () => context.push('/coach?sport=$_home'),
        // The old free-form timer / counter stays reachable.
        secondary: '手动记录',
        onSecondary: () => context.push('/train/$_home'),
      ),
    ];
  }

  /// 场馆球类（C-07 / C-08）：附近场馆签到、扫码、订场入口。
  Widget _venueSection() => const VenueCheckinSection();
}

class _SportTile extends StatelessWidget {
  const _SportTile({required this.info, required this.selected, required this.onTap});
  final SportInfo info;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: () {
          playSound(context, Sounds.uiTap);
          onTap();
        },
        borderRadius: BorderRadius.circular(24),
        child: Container(
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF1E2112) : LL.card,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: selected ? LL.lime : LL.border, width: selected ? 1.5 : 1),
          ),
          child: Stack(children: [
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(color: selected ? LL.lime : LL.card2, shape: BoxShape.circle),
                  child: LIcon(info.icon, color: selected ? LL.ink : LL.text, size: 28),
                ),
                const SizedBox(height: 10),
                Text(sportName(info.key), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ]),
            ),
            if (info.tag != null)
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: LL.orange, borderRadius: BorderRadius.circular(10)),
                  child: Text(info.tag!, style: const TextStyle(color: LL.ink, fontSize: 11, fontWeight: FontWeight.w800)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({
    required this.title,
    required this.badge,
    required this.desc,
    required this.energy,
    required this.roles,
    required this.button,
    required this.onStart,
    this.secondary,
    this.onSecondary,
  });
  final String title, badge, desc, button;
  final String? energy;
  final List<String> roles;
  final VoidCallback onStart;
  final String? secondary;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return LLCard(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(14)),
            child: Text(badge, style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w800)),
          ),
        ]),
        const SizedBox(height: 10),
        Text(desc, style: const TextStyle(color: LL.text2, height: 1.6)),
        const SizedBox(height: 10),
        if (energy != null)
          Row(children: [
            const LIcon(LIcons.bolt, color: LL.yellow, size: 18),
            const SizedBox(width: 4),
            Text(energy!, style: const TextStyle(color: LL.text2)),
          ]),
        if (roles.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              const LIcon(LIcons.userPlus, color: LL.lavender, size: 18),
              const SizedBox(width: 4),
              Text('招募 ${roles.join('、')}', style: const TextStyle(color: LL.text2)),
            ]),
          ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
              onPressed: onStart, icon: const LIcon(LIcons.play), label: Text(button)),
        ),
        if (secondary != null)
          Center(
            child: TextButton(
              onPressed: onSecondary,
              style: TextButton.styleFrom(foregroundColor: LL.text2),
              child: Text(secondary!),
            ),
          ),
      ]),
    );
  }
}
