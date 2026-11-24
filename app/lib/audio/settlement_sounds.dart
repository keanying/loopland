import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../core/format.dart' show gpsSports;
import 'audio.dart';
import 'run_sounds.dart' show runSummaryLine;

/// The settlement's sounds, in order: sound effects (claim, boss hit /
/// defeat, chests, energy, level, 图鉴) staggered [gap] apart, and up to four
/// voice lines (summary, 抢地, 击败怪兽, 升级, 新图鉴, 补给券, 能量拿满 / 复核).
class SettlementPlan {
  SettlementPlan(this.result);
  final ActivityResult result;

  static String monsterKind(String name) =>
      monsterNames.entries.where((e) => e.value == name).firstOrNull?.key ?? 'sofa';

  /// (sound, haptic) in play order.
  List<(Sound, HapticKind?)> get effects {
    final s = result.settlement;
    if (s.status == 'voided') return [(Sounds.uiError, null)];
    if (s.status != 'settled') return const [];
    final down = s.bossDamage.where((b) => b.defeated).firstOrNull;
    return [
      if (s.claims.isNotEmpty) (Sounds.claim, HapticKind.medium),
      if (down != null) ...[
        (Sounds.bossDown, HapticKind.heavy),
        (Sounds.bossDownChar(monsterKind(down.name)), null),
      ] else if (s.bossDamage.isNotEmpty) ...[
        (Sounds.bossHit, null),
        (Sounds.bossHitChar(monsterKind(s.bossDamage.first.name)), null),
      ],
      if (s.chests.isNotEmpty) (Sounds.chestOpen, HapticKind.medium),
      if (s.energyGranted > 0) (Sounds.energyGain, null),
      if (s.levelUp != null) (Sounds.levelUp, HapticKind.medium),
      if (_codex) (Sounds.codexUnlock, null),
    ];
  }

  bool get _codex => result.settlement.eggs.any((e) => e.hatched) || result.settlement.recruits.any((r) => r.recruited);

  /// Voice parts in speaking order (at most four).
  List<VoicePart> get voice {
    final a = result.activity;
    final s = result.settlement;
    if (s.status == 'review') return const [VoicePart.clip(Sounds.resultReview)];
    if (s.status != 'settled') return const [];
    final steal = s.claims.any((c) => c.kind == 'capture') || s.attacks.any((x) => x.captured);
    return [
      if (gpsSports.contains(a.sport) && a.distanceM > 0)
        VoicePart.tts(runSummaryLine(distanceM: a.distanceM, durationS: a.durationS, claims: s.claims.length)),
      if (steal) const VoicePart.clip(Sounds.runSteal),
      if (s.bossDamage.any((b) => b.defeated)) const VoicePart.clip(Sounds.runBossDown),
      if (s.levelUp != null) const VoicePart.clip(Sounds.resultLevelUp),
      if (_codex) const VoicePart.clip(Sounds.resultCodex),
      if (s.coupons.any((c) => c.source?.type == 'supply')) const VoicePart.clip(Sounds.runSupply),
      if (s.energyCapped) const VoicePart.clip(Sounds.runEnergyFull),
    ].take(4).toList();
  }
}

/// Plays [SettlementPlan] once when the result page opens.
class SettlementSounds extends ConsumerStatefulWidget {
  const SettlementSounds({
    super.key,
    required this.result,
    required this.child,
    this.gap = const Duration(milliseconds: 650),
  });
  final ActivityResult result;
  final Widget child;
  final Duration gap;

  @override
  ConsumerState<SettlementSounds> createState() => _SettlementSoundsState();
}

class _SettlementSoundsState extends ConsumerState<SettlementSounds> {
  final _timers = <Timer>[];

  @override
  void initState() {
    super.initState();
    final audio = ref.read(audioProvider);
    final plan = SettlementPlan(widget.result);
    final fx = plan.effects;
    for (final (i, (sound, haptic)) in fx.indexed) {
      void go() {
        audio.play(sound);
        if (haptic != null) audio.haptic(haptic);
      }

      if (i == 0) {
        go();
      } else {
        _timers.add(Timer(widget.gap * i, go));
      }
    }
    for (final (i, p) in plan.voice.indexed) {
      audio.sayParts(
        [p],
        priority: VoicePriority.claim,
        kind: 'result_$i',
        interval: Duration.zero,
        maxAge: const Duration(seconds: 40),
      );
    }
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
