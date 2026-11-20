import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../claim/geo.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../map/territory_map.dart';
import '../../widgets/card_art.dart';
import '../../widgets/common.dart';

class ResultArgs {
  const ResultArgs({required this.result, this.localTrack = const []});
  final ActivityResult result;

  /// Shown when the server's Activity has no track (e.g. home training).
  final List<LatLng> localTrack;
}

/// 结算页：圈地、攻击、能量（含上限提示）、招募进度、伙伴蛋、奖牌、复核 / 作废。
class ResultPage extends ConsumerWidget {
  const ResultPage({super.key, required this.args});
  final ResultArgs args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = args.result.activity;
    final s = args.result.settlement;
    final cfg = ref.watch(configProvider).value;
    final track = a.track.isNotEmpty ? a.track : args.localTrack;
    final isGps = gpsSports.contains(a.sport);
    final ctrl = TerritoryMapController();
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_title(s), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
                Text('${sportName(a.sport)} · ${Fmt.dateTime(a.startedAt)}', style: const TextStyle(color: LL.text2)),
              ]),
            ),
            RoundIconButton(icon: Icons.close_rounded, tooltip: '完成', onTap: () => context.go('/map')),
          ]),
          const SizedBox(height: 14),
          if (s.status == 'review')
            _Banner(
              color: const Color(0xFF3A3020),
              icon: Icons.hourglass_top_rounded,
              iconColor: LL.yellow,
              title: '本次记录进入人工复核',
              body: '系统发现了一些异常，复核通过后会补发能量并圈地，结果会通过站内信通知你。',
              flags: s.flags,
            ),
          if (s.status == 'voided')
            _Banner(
              color: const Color(0xFF3A1D22),
              icon: Icons.block_rounded,
              iconColor: LL.red,
              title: '本次记录已作废',
              body: '风控判定这次记录不真实，不发放能量、不圈地。如有疑问请联系客服申诉。',
              flags: s.flags,
            ),
          if (isGps && track.length >= 2) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: SizedBox(
                height: 220,
                child: _FitMap(track: track, controller: ctrl),
              ),
            ),
            const SizedBox(height: 14),
          ],
          LLCard(
            child: Row(children: [
              if (isGps) ...[
                Expanded(child: StatBox(value: Fmt.km(a.distanceM), unit: 'km', label: '距离')),
                Expanded(child: StatBox(value: Fmt.pace(a.avgPaceSPerKm), label: '配速')),
              ] else
                Expanded(
                  child: StatBox(
                      value: a.amount == null ? '-' : Fmt.amount(a.amount!, a.sport == 'rope' ? 'count' : 'min'),
                      unit: a.sport == 'rope' ? '次' : '分钟',
                      label: sportName(a.sport)),
                ),
              Expanded(child: StatBox(value: Fmt.duration(a.durationS), label: '时长')),
            ]),
          ),
          const SizedBox(height: 12),
          if (s.status == 'settled') ...[
            _EnergyCard(s: s, cap: cfg?.dailyEnergyCap ?? 600),
            if (s.levelUp != null) ...[
              const SizedBox(height: 12),
              LLCard(
                color: LL.lavender,
                child: Row(children: [
                  const Icon(Icons.trending_up_rounded, color: LL.ink, size: 32),
                  const SizedBox(width: 12),
                  Text('升级到 Lv.${s.levelUp!.to}！解锁更多建筑',
                      style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: 17)),
                ]),
              ),
            ],
            if (isGps) ...[
              const _Section('本次圈地'),
              if (s.claims.isEmpty)
                const Text('这次没有圈到地。下次让轨迹交叉一下，围起来的部分就是你的！', style: TextStyle(color: LL.text2))
              else ...[
                for (final c in s.claims)
                  _Row(
                    icon: c.kind == 'capture' ? Icons.flag_rounded : Icons.crop_square_rounded,
                    color: c.kind == 'capture' ? LL.orange : LL.lime,
                    title: c.kind == 'capture' ? '抢下 领地 #${c.territoryId}' : '新圈 领地 #${c.territoryId}',
                    trailing: Fmt.area(c.areaM2),
                    onTap: () => context.push('/city/${c.territoryId}'),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text('合计 ${Fmt.area(s.claimedAreaM2)}', style: const TextStyle(color: LL.lime, fontWeight: FontWeight.w800)),
                ),
              ],
              if (s.attacks.isNotEmpty) ...[
                const _Section('攻击'),
                for (final at in s.attacks)
                  _Row(
                    icon: at.captured ? Icons.emoji_events_rounded : Icons.shield_outlined,
                    color: at.captured ? LL.lime : LL.orange,
                    title: '${at.owner?.nickname ?? '对手'} 的领地 #${at.territoryId}',
                    subtitle: at.captured
                        ? '能量超过守卫值，抢下 ${Fmt.area(at.areaM2)}'
                        : '守卫 ${at.guardBefore} → ${at.guardAfter}，能量不足以抢下，已削弱',
                    trailing: at.captured ? '已抢下' : '-${at.guardBefore - at.guardAfter}',
                  ),
              ],
            ],
          ],
          if (s.recruits.isNotEmpty) ...[
            const _Section('招募进度'),
            for (final r in s.recruits)
              _ProgressRow(
                art: r.role,
                title: r.recruited ? '招募成功：${r.name}！' : r.name,
                value: r.threshold == 0 ? 0 : r.progress / r.threshold,
                text: '${Fmt.amount(r.progress, r.unit)} / ${Fmt.amount(r.threshold, r.unit)} ${Fmt.unit(r.unit)}',
                done: r.recruited,
              ),
          ],
          if (s.eggs.isNotEmpty) ...[
            const _Section('伙伴蛋'),
            for (final e in s.eggs)
              _ProgressRow(
                art: e.key,
                locked: !e.hatched,
                title: e.hatched ? '孵化成功：${e.name}！' : '${e.name} 的蛋',
                value: e.hatchKm == 0 ? 0 : e.progressKm / e.hatchKm,
                text: e.hatched
                    ? '去图鉴设为陪跑'
                    : '还差 ${(e.hatchKm - e.progressKm).clamp(0, 9999).toStringAsFixed(1)} km 孵化',
                done: e.hatched,
                color: LL.lavender,
              ),
          ],
          if (s.medals.isNotEmpty) ...[
            const _Section('新奖牌'),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final m in s.medals)
                Column(children: [MedalArt(obtained: true, width: 80, label: m.name), const SizedBox(height: 4), Text(m.name)]),
            ]),
          ],
          const SizedBox(height: 24),
          FilledButton(onPressed: () => context.go('/map'), child: const Text('查看我的领地')),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: () => context.go('/me'), child: const Text('完成')),
        ]),
      ),
    );
  }

  String _title(Settlement s) => switch (s.status) {
        'review' => '复核中',
        'voided' => '已作废',
        _ => s.claims.isNotEmpty ? '圈地成功！' : '运动完成',
      };
}

class _FitMap extends StatefulWidget {
  const _FitMap({required this.track, required this.controller});
  final List<LatLng> track;
  final TerritoryMapController controller;
  @override
  State<_FitMap> createState() => _FitMapState();
}

class _FitMapState extends State<_FitMap> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.controller.fitPoints(widget.track));
  }

  @override
  Widget build(BuildContext context) => TerritoryMapView(
        controller: widget.controller,
        interactive: false,
        initialCenter: widget.track.first,
        layers: MapLayers(track: widget.track),
      );
}

class _EnergyCard extends StatelessWidget {
  const _EnergyCard({required this.s, required this.cap});
  final Settlement s;
  final int cap;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: LL.lime, borderRadius: BorderRadius.circular(26)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('获得能量', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w800)),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          const Icon(Icons.bolt_rounded, color: LL.ink, size: 36),
          Text('+${s.energyGranted}', style: const TextStyle(color: LL.ink, fontSize: 40, fontWeight: FontWeight.w900, height: 1.1)),
        ]),
        if (s.energyCapped)
          Text('今日能量已达上限 $cap，本次应得 ${s.energyRaw}，超出部分未计入。',
              style: const TextStyle(color: Color(0xFF3A3F1A), fontSize: 13)),
      ]),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.icon, required this.iconColor, required this.title, required this.body, required this.flags});
  final Color color;
  final IconData icon;
  final Color iconColor;
  final String title, body;
  final List<RiskFlag> flags;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LLCard(
        color: color,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: iconColor),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
          ]),
          const SizedBox(height: 8),
          Text(body, style: const TextStyle(color: LL.text2, height: 1.5)),
          for (final f in flags)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('· ${f.detail}', style: const TextStyle(color: LL.text, fontSize: 13)),
            ),
        ]),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
      );
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.color, required this.title, this.subtitle, required this.trailing, this.onTap});
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final String trailing;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LLCard(
        padding: const EdgeInsets.all(12),
        onTap: onTap,
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: LL.ink, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              if (subtitle != null) Text(subtitle!, style: const TextStyle(color: LL.text2, fontSize: 12)),
            ]),
          ),
          Text(trailing, style: TextStyle(color: color, fontWeight: FontWeight.w900)),
        ]),
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({
    required this.art,
    required this.title,
    required this.value,
    required this.text,
    required this.done,
    this.locked = false,
    this.color = LL.lime,
  });
  final String art, title, text;
  final double value;
  final bool done, locked;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LLCard(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          CardArt(artKey: art, width: 46, locked: locked && !done),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w800, color: done ? color : LL.text)),
              const SizedBox(height: 6),
              LLProgress(value: done ? 1 : value, color: color),
              const SizedBox(height: 4),
              Text(text, style: const TextStyle(color: LL.text2, fontSize: 12)),
            ]),
          ),
        ]),
      ),
    );
  }
}
