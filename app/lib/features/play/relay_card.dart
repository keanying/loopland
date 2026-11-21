import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'play_providers.dart';
import 'play_widgets.dart';

/// 跑团接力 card on the crew page: legs filled by members + deadline; the
/// leader can start one.
class RelayCard extends ConsumerWidget {
  const RelayCard({super.key, required this.crew});
  final Crew crew;

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final cfg = ref.read(configProvider).value?.relay ?? const RelayConfig();
    final picked = await showModalBottomSheet<(int, double)>(
      context: context,
      builder: (_) => _StartRelaySheet(legs: cfg.defaultLegs, legKm: cfg.legKm, durationH: cfg.durationH, reward: cfg.rewardEnergy),
    );
    if (picked == null || !context.mounted) return;
    try {
      await ref.read(apiProvider).startRelay(crew.id, legs: picked.$1, legKm: picked.$2);
      if (context.mounted) toast(context, '接力已发起，团友跑满 ${_km(picked.$2)} km 就能接一棒');
    } on ApiException catch (e) {
      if (context.mounted) showError(context, e);
    }
    ref.invalidate(relayProvider(crew.id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!crew.isMember) return const SizedBox.shrink();
    final async = ref.watch(relayProvider(crew.id));
    final me = ref.watch(userProvider);
    return async.when(
      skipLoadingOnRefresh: true,
      loading: () => const SizedBox.shrink(),
      error: (e, _) => LLCard(
        onTap: () => ref.invalidate(relayProvider(crew.id)),
        child: Text('接力加载失败：${errorText(e)} · 点此重试', style: const TextStyle(color: LL.text2, fontSize: 12)),
      ),
      data: (r) {
        if (r == null || !r.isRunning) {
          return LLCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.timeline_rounded, color: LL.lavender),
                const SizedBox(width: 8),
                const Expanded(child: Text('跑团接力', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17))),
                if (r != null) Tag(r.status == 'completed' ? '上一场已完成' : '上一场未接满', color: r.status == 'completed' ? LL.lime : LL.card2, fg: r.status == 'completed' ? LL.ink : LL.text2),
              ]),
              const SizedBox(height: 6),
              Text(crew.isLeader ? '发起一场接力：每位团友一次运动跑满单棒距离就算一棒，限时接满全员得奖励。' : '团长发起接力后，你跑满单棒距离就能接一棒。',
                  style: const TextStyle(color: LL.text2, height: 1.5)),
              if (crew.isLeader) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(onPressed: () => _start(context, ref), child: const Text('发起接力')),
                ),
              ],
            ]),
          );
        }
        final mine = r.runs.where((x) => x.user?.id == me?.id).firstOrNull;
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF26223A),
            borderRadius: BorderRadius.circular(LL.radius),
            border: Border.all(color: LL.lavender, width: 1.5),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.timeline_rounded, color: LL.lavender),
              const SizedBox(width: 8),
              Expanded(
                child: Text('跑团接力 · ${r.runs.length}/${r.legs} 棒',
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
              ),
              Countdown(
                until: r.expiresAt,
                builder: (_, left) => Text('还剩 ${formatCountdown(left)}', style: const TextStyle(color: LL.orange, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 4),
            Text('每棒单次 GPS 运动 ≥ ${_km(r.legKm)} km · ${Fmt.dateTime(r.expiresAt)} 截止 · 每人最多一棒',
                style: const TextStyle(color: LL.text2, fontSize: 12)),
            const SizedBox(height: 12),
            LayoutBuilder(builder: (context, box) {
              final w = (box.maxWidth - 16) / 3;
              return Wrap(spacing: 8, runSpacing: 8, children: [
                for (var i = 1; i <= r.legs; i++) SizedBox(width: w, child: _Leg(n: i, run: r.leg(i), mine: r.leg(i)?.user?.id == me?.id)),
              ]);
            }),
            const SizedBox(height: 10),
            Text(mine != null ? '你已经跑了第 ${mine.leg} 棒，等团友接力' : '去跑满 ${_km(r.legKm)} km，接下一棒',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        );
      },
    );
  }
}

String _km(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);

class _Leg extends StatelessWidget {
  const _Leg({required this.n, required this.run, required this.mine});
  final int n;
  final RelayRun? run;
  final bool mine;
  @override
  Widget build(BuildContext context) {
    final r = run;
    return Container(
      height: 74,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: r == null ? const Color(0x14F4F4F5) : (mine ? LL.lime : LL.lavender),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('第 $n 棒', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: r == null ? LL.text3 : LL.ink)),
        const Spacer(),
        if (r == null)
          const Text('待接', style: TextStyle(color: LL.text2, fontWeight: FontWeight.w800))
        else ...[
          Text(r.user?.nickname ?? '团友',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w900)),
          Text(Fmt.distance(r.distanceM), style: const TextStyle(color: Color(0xFF3B3355), fontSize: 11)),
        ],
      ]),
    );
  }
}

class _StartRelaySheet extends StatefulWidget {
  const _StartRelaySheet({required this.legs, required this.legKm, required this.durationH, required this.reward});
  final int legs;
  final double legKm;
  final int durationH, reward;
  @override
  State<_StartRelaySheet> createState() => _StartRelaySheetState();
}

class _StartRelaySheetState extends State<_StartRelaySheet> {
  late int _legs = widget.legs;
  late double _legKm = widget.legKm;

  Widget _stepper(String label, String value, VoidCallback? minus, VoidCallback? plus) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          RoundIconButton(icon: Icons.remove_rounded, size: 40, color: LL.card2, onTap: minus),
          SizedBox(width: 72, child: Text(value, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18))),
          RoundIconButton(icon: Icons.add_rounded, size: 40, color: LL.card2, onTap: plus),
        ]),
      );

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('发起跑团接力', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text('${widget.durationH ~/ 24} 天内接满，全员 +${widget.reward} 能量', style: const TextStyle(color: LL.text2)),
            const SizedBox(height: 16),
            _stepper('棒数', '$_legs 棒', _legs > 2 ? () => setState(() => _legs--) : null, _legs < 20 ? () => setState(() => _legs++) : null),
            _stepper('每棒距离', '${_km(_legKm)} km', _legKm > 1 ? () => setState(() => _legKm -= 1) : null,
                _legKm < 21 ? () => setState(() => _legKm += 1) : null),
            const SizedBox(height: 8),
            FilledButton(onPressed: () => Navigator.pop(context, (_legs, _legKm)), child: const Text('发起')),
          ]),
        ),
      );
}
