import '../api/models.dart';
import '../claim/geo.dart';
import '../run/run_controller.dart';
import 'audio_backend.dart';
import 'audio_engine.dart';
import 'sound_catalog.dart';

/// Turns the run's state changes into sounds (docs/音频素材清单.md 4.1):
/// countdown, go, pause / resume, half / goal, closing hints (200 / 100 /
/// 50 m, each once per approach), claims (combo from the 2nd), boss near /
/// hit (once per run), chests passed, GPS weak > 30 s / back, a TTS line
/// every km (and every 10 min for time goals), and the long-press finish.
///
/// Pure logic around [AudioEngine]; the run page feeds it every state.
class RunSounds {
  RunSounds(this.audio, RunState initial, DateTime now)
    : _loops = initial.loops.length,
      _km = (initial.distanceM / 1000).floor(),
      _kmAtMs = initial.elapsedMs(now),
      _tenMin = initial.elapsedMs(now) ~/ 600000,
      _countdown = initial.phase == RunPhase.countdown ? null : -1,
      _goodAt = now {
    _halfSaid = _progress(initial, now) >= 0.5;
    _goalSaid = initial.goalReached(now);
  }

  final AudioEngine audio;

  /// The thresholds of the closing hint, largest first.
  static const closeAt = [200, 100, 50];

  /// GPS counts as weak after this long without a usable fix.
  static const gpsWeakAfter = Duration(seconds: 30);

  /// Bosses are announced this far outside their damage range.
  static const bossNearM = 300.0;

  int _loops;
  int _km;
  int _kmAtMs;
  int _tenMin;
  int? _countdown;
  bool _halfSaid = false, _goalSaid = false;
  final _closeSaid = <int>{};
  DateTime _goodAt;
  bool _gpsWeak = false;
  final _bossNear = <int>{};
  bool _bossHit = false;
  final _chests = <int>{};
  bool _holding = false;

  static double _progress(RunState s, DateTime now) {
    final v = s.goal.value;
    if (v == null || v <= 0) return 0;
    return switch (s.goal.type) {
      'distance' => s.distanceM / v,
      'time' => s.elapsedMs(now) / 1000 / v,
      _ => 0,
    };
  }

  /// Called with every new state (and once with the current one when the
  /// run page opens, `prev` null).
  void onState(RunState? prev, RunState next, DateTime now, {MapObjects nearby = const MapObjects()}) {
    // 3-2-1: the voice number and a tick, each second.
    if (next.phase == RunPhase.countdown && next.countdown > 0 && next.countdown != _countdown) {
      _countdown = next.countdown;
      audio.say(Sounds.runCount(next.countdown), priority: VoicePriority.countdown, interrupt: true);
      audio.play(Sounds.runTick);
    }
    final was = prev?.phase;
    if (was == RunPhase.countdown && next.phase == RunPhase.running) {
      _goodAt = now;
      audio.say(Sounds.runGo, priority: VoicePriority.countdown, interrupt: true);
      audio.play(Sounds.runGoSfx);
      audio.haptic(HapticKind.medium);
    }
    if (was == RunPhase.running && next.phase == RunPhase.paused) {
      audio.say(Sounds.runPause, interval: const Duration(seconds: 5));
    }
    if (was == RunPhase.paused && next.phase == RunPhase.running) {
      _goodAt = now; // no GPS warning for the time spent paused
      audio.say(Sounds.runResume, interval: const Duration(seconds: 5));
    }
    if (next.phase != RunPhase.running) return;

    _claims(next);
    _closing(next);
    _progressLines(next, now);
    _gps(prev, next, now);
    _objects(next.position, nearby);
  }

  void _claims(RunState s) {
    final n = s.loops.length;
    if (n <= _loops) return;
    final first = _loops == 0;
    _loops = n;
    _closeSaid.clear();
    audio.play(Sounds.claim);
    audio.haptic(HapticKind.medium);
    audio.say(first ? Sounds.runClaim : Sounds.runClaimCombo, priority: VoicePriority.claim, kind: 'claim');
  }

  void _closing(RunState s) {
    final h = s.hint;
    if (h == null) {
      _closeSaid.clear();
      return;
    }
    final d = h.distanceM;
    // Moved clearly away again: that threshold can be announced again.
    _closeSaid.removeWhere((t) => d > t + 60);
    int? band;
    for (final t in closeAt) {
      if (d <= t) band = t;
    }
    final b = band;
    if (b == null || _closeSaid.contains(b)) return;
    // Mark the larger ones too: coming in at 80 m says 「还差一百米」 once.
    _closeSaid.addAll(closeAt.where((t) => t >= b));
    audio.say(switch (b) {
      200 => Sounds.runClose200,
      100 => Sounds.runClose100,
      _ => Sounds.runClose50,
    });
  }

  void _progressLines(RunState s, DateTime now) {
    final ms = s.elapsedMs(now);
    final km = (s.distanceM / 1000).floor();
    if (km > _km) {
      final split = ((ms - _kmAtMs) / 1000).round();
      _km = km;
      _kmAtMs = ms;
      final pace = ms / 1000 / (s.distanceM / 1000);
      audio.sayText('第 $km 公里，用时 ${_minSec(split)}，平均配速 ${_pace(pace)}', priority: VoicePriority.km, kind: 'km');
    }
    if (s.goal.type == 'time') {
      final ten = ms ~/ 600000;
      if (ten > _tenMin) {
        _tenMin = ten;
        audio.sayText(
          '已经跑了 ${ten * 10} 分钟，${(s.distanceM / 1000).toStringAsFixed(1)} 公里',
          priority: VoicePriority.km,
          kind: 'time',
        );
      }
    }
    final p = _progress(s, now);
    if (!_goalSaid && p >= 1) {
      _goalSaid = _halfSaid = true;
      audio.say(Sounds.runGoal, priority: VoicePriority.km);
      audio.haptic(HapticKind.medium);
    } else if (!_halfSaid && p >= 0.5) {
      _halfSaid = true;
      audio.say(Sounds.runHalf, priority: VoicePriority.km);
    }
  }

  void _gps(RunState? prev, RunState s, DateTime now) {
    final f = s.lastFix;
    final fresh = f != null && !identical(f, prev?.lastFix);
    if (fresh && (f.accuracy == null || f.accuracy! <= kMaxPreviewAccuracyM)) {
      _goodAt = now;
      if (_gpsWeak) {
        _gpsWeak = false;
        audio.say(Sounds.runGpsBack, priority: VoicePriority.safety);
      }
      return;
    }
    if (!_gpsWeak && now.difference(_goodAt) > gpsWeakAfter) {
      _gpsWeak = true;
      audio.say(Sounds.runGpsWeak, priority: VoicePriority.safety);
    }
  }

  void _objects(LatLng? pos, MapObjects o) {
    if (pos == null) return;
    for (final b in o.bosses) {
      final d = haversine(pos, b.center);
      if (d <= b.radiusM) {
        _bossNear.add(b.id);
        if (_bossHit) continue;
        _bossHit = true;
        audio.play(Sounds.bossHit);
        audio.play(Sounds.bossHitChar(b.kind));
        audio.say(Sounds.runBossHit, priority: VoicePriority.boss);
      } else if (d <= b.radiusM + bossNearM && _bossNear.add(b.id)) {
        audio.play(Sounds.bossTap(b.kind));
        audio.say(Sounds.runBossNear, priority: VoicePriority.boss);
      }
    }
    for (final c in o.chests) {
      if (haversine(pos, c.center) <= c.radiusM && _chests.add(c.id)) {
        audio.haptic(HapticKind.medium);
        audio.say(Sounds.runChest, interval: const Duration(seconds: 5));
      }
    }
  }

  // ── long-press finish ──

  void holdStart() {
    _holding = true;
    audio.startLoop(Sounds.runHold);
  }

  void holdCancel() {
    if (!_holding) return;
    _holding = false;
    audio.stopLoop();
  }

  /// The finish button was held long enough; [settling] when the run will be
  /// uploaded (not discarded).
  void holdDone({required bool settling}) {
    _holding = false;
    audio.stopLoop();
    audio.play(Sounds.runHoldDone);
    audio.haptic(HapticKind.heavy);
    if (settling) audio.say(Sounds.runFinish, interrupt: true, interval: Duration.zero);
  }

  static String _minSec(int sec) {
    final m = sec ~/ 60, s = sec % 60;
    if (m == 0) return '$s 秒';
    return s == 0 ? '$m 分钟' : '$m 分 $s 秒';
  }

  static String _pace(double sPerKm) {
    final t = sPerKm.round();
    final m = t ~/ 60, s = t % 60;
    return s == 0 ? '$m 分' : '$m 分 $s';
  }
}

/// 结束总结（结算页）：「本次 5.2 公里，用时 31 分钟，圈下 2 块地」.
String runSummaryLine({required double distanceM, required int durationS, required int claims}) {
  final km = (distanceM / 1000).toStringAsFixed(1);
  final min = (durationS / 60).round();
  final time = min < 1 ? '$durationS 秒' : '$min 分钟';
  return '本次 $km 公里，用时 $time${claims > 0 ? '，圈下 $claims 块地' : ''}';
}
