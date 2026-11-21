import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/card_art.dart';
import '../../widgets/common.dart';

/// Hatched companion: level, exp bar, metres run together, 「喂 50 能量」.
class CompanionCard extends ConsumerStatefulWidget {
  const CompanionCard({super.key, required this.companion, this.dark = false, this.onFed});
  final CodexCompanion companion;

  /// Ink-on-lime style (玩法中心 hero card).
  final bool dark;
  final ValueChanged<Codex>? onFed;

  @override
  ConsumerState<CompanionCard> createState() => _CompanionCardState();
}

class _CompanionCardState extends ConsumerState<CompanionCard> {
  bool _busy = false;
  CodexCompanion? _local;

  Future<void> _feed() async {
    setState(() => _busy = true);
    final codex = await runGuarded(context, () => ref.read(apiProvider).feedCompanion(widget.companion.key));
    if (!mounted) return;
    setState(() => _busy = false);
    if (codex == null) return;
    final c = codex.companions.where((x) => x.key == widget.companion.key).firstOrNull;
    setState(() => _local = c);
    final cfg = ref.read(configProvider).value?.companion;
    final up = c != null && c.level > widget.companion.level;
    toast(context, up ? '${c.name} 升到 Lv.${c.level} 了！' : '喂食成功，经验 +${cfg?.feedExp ?? 10}');
    ref.invalidate(codexProvider);
    ref.read(authProvider.notifier).refreshUser().ignore();
    widget.onFed?.call(codex);
  }

  @override
  Widget build(BuildContext context) {
    final c = _local ?? widget.companion;
    final cost = ref.watch(configProvider).value?.companion.feedCost ?? 50;
    final energy = ref.watch(userProvider)?.energy ?? 0;
    final fg = widget.dark ? LL.ink : LL.text;
    final sub = widget.dark ? const Color(0xFF3A3F1A) : LL.text2;
    // `exp` is cumulative; `exp_to_next` is what is left to the next level
    // (server: level × exp_per_level − exp).
    final per = ref.watch(configProvider).value?.companion.expPerLevel ?? 100;
    final inLevel = (per - c.expToNext).clamp(0, per);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: widget.dark ? const Color(0x14000000) : LL.card2,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(children: [
        CardArt(artKey: c.key, width: 56),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${c.name} · Lv.${c.level}', style: TextStyle(color: fg, fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 6),
            LLProgress(
              value: per <= 0 ? 0 : inLevel / per,
              color: widget.dark ? LL.ink : LL.pink,
              bg: widget.dark ? const Color(0x33121212) : LL.card,
            ),
            const SizedBox(height: 4),
            Text('经验 $inLevel / $per · 已陪你跑 ${Fmt.thousands(c.meters.round())} 米',
                style: TextStyle(color: sub, fontSize: 12)),
          ]),
        ),
        const SizedBox(width: 8),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            backgroundColor: widget.dark ? LL.ink : LL.lime,
            foregroundColor: widget.dark ? LL.lime : LL.ink,
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, fontFamilyFallback: LL.fonts),
          ),
          onPressed: _busy || energy < cost ? null : _feed,
          child: Text(energy < cost ? '能量不足' : '喂 $cost 能量'),
        ),
      ]),
    );
  }
}
