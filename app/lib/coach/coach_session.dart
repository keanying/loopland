import 'package:flutter/foundation.dart';

import 'workout.dart';

enum CoachPhase {
  /// Not started (「开始」).
  ready,

  /// Countdown before the first set, to get in position.
  prepare,
  work,

  /// Between sets / steps; [CoachSession.step] is already the upcoming one.
  rest,
  done,
}

enum CueKind { prepare, start, half, almost, countdown, rest, done }

/// A voice prompt (the UI also shows the latest one in the hint bubble).
class CoachCue {
  const CoachCue(this.kind, this.text);
  final CueKind kind;
  final String text;
  @override
  String toString() => 'CoachCue($kind, $text)';
}

/// The guided session: steps × sets, count / time targets, rest timers,
/// pause / resume / skip, and the voice cues. Pure logic driven by [tick]
/// with the caller's clock (milliseconds), so it is unit-tested without
/// timers.
class CoachSession extends ChangeNotifier {
  CoachSession(this.workout, {this.prepareSec = 5, this.onCue}) : assert(workout.steps.isNotEmpty);

  final Workout workout;
  final int prepareSec;
  void Function(CoachCue cue)? onCue;

  CoachPhase phase = CoachPhase.ready;
  bool paused = false;
  int stepIndex = 0;
  int setIndex = 0;

  /// Reps of the current set (camera + manual).
  int setReps = 0;
  int repsDetected = 0;
  int repsManual = 0;
  int setsDone = 0;

  /// Active training time (work + rest, without pauses and the countdown).
  int elapsedMs = 0;

  /// Time left of the countdown / timed set / rest.
  int remainingMs = 0;

  /// Time spent in the current set.
  int setMs = 0;

  /// Increments every time a set starts — the UI resets its rep counter on it.
  int workSerial = 0;

  /// Latest cue, shown in the hint bubble.
  CoachCue? lastCue;

  int? _lastTick;
  bool _halfCued = false;
  bool _almostCued = false;

  WorkoutStep get step => workout.steps[stepIndex];
  bool get started => phase != CoachPhase.ready;
  bool get running => started && phase != CoachPhase.done && !paused;
  bool get isLastStep => stepIndex == workout.steps.length - 1;
  int get totalReps => repsDetected + repsManual;

  /// Sets completed + current, over all sets (「组数 x/y」 of the step).
  int get setNumber => setIndex + 1;

  /// Progress of the current set, 0..1.
  double get setProgress {
    if (phase != CoachPhase.work) return 0;
    if (step.isCount) return (setReps / step.target).clamp(0.0, 1.0);
    return (1 - remainingMs / (step.target * 1000)).clamp(0.0, 1.0);
  }

  /// What comes after the current set (「下一个」 preview).
  String get nextPreview {
    if (phase == CoachPhase.rest || phase == CoachPhase.prepare) {
      return '${step.name} · ${step.targetText} · 第 $setNumber/${step.sets} 组';
    }
    if (setIndex + 1 < step.sets) return '${step.name} · 第 ${setIndex + 2}/${step.sets} 组';
    if (!isLastStep) {
      final n = workout.steps[stepIndex + 1];
      return '${n.name} · ${n.targetText} × ${n.sets} 组';
    }
    return '最后一组，坚持住';
  }

  void _cue(CueKind k, String text) {
    lastCue = CoachCue(k, text);
    onCue?.call(lastCue!);
  }

  // ── controls ──

  void start(int nowMs) {
    if (phase != CoachPhase.ready) return;
    _lastTick = nowMs;
    paused = false;
    if (prepareSec <= 0) {
      _beginWork();
    } else {
      phase = CoachPhase.prepare;
      remainingMs = prepareSec * 1000;
      _cue(CueKind.prepare, '第一个动作：${step.name}，${step.targetText}，共 ${step.sets} 组。准备');
    }
    notifyListeners();
  }

  void pause(int nowMs) {
    if (!running) return;
    tick(nowMs);
    paused = true;
    notifyListeners();
  }

  void resume(int nowMs) {
    if (!paused || phase == CoachPhase.done) return;
    paused = false;
    _lastTick = nowMs;
    notifyListeners();
  }

  /// Advances the clocks to [nowMs].
  void tick(int nowMs) {
    final last = _lastTick;
    _lastTick = nowMs;
    if (!running || last == null) return;
    final dt = nowMs - last;
    if (dt <= 0) return;
    switch (phase) {
      case CoachPhase.prepare:
        final before = remainingMs;
        remainingMs -= dt;
        _countdown(before, remainingMs);
        if (remainingMs <= 0) _beginWork();
      case CoachPhase.work:
        elapsedMs += dt;
        setMs += dt;
        if (step.isTime) {
          final before = remainingMs;
          remainingMs -= dt;
          final half = step.target * 500;
          if (!_halfCued && step.target >= 10 && remainingMs <= half && remainingMs > 0) {
            _halfCued = true;
            _cue(CueKind.half, '已经一半了，坚持住');
          }
          _countdown(before, remainingMs);
          if (remainingMs <= 0) _completeSet();
        }
      case CoachPhase.rest:
        elapsedMs += dt;
        final before = remainingMs;
        remainingMs -= dt;
        _countdown(before, remainingMs);
        if (remainingMs <= 0) _beginWork();
      case CoachPhase.ready:
      case CoachPhase.done:
        break;
    }
    notifyListeners();
  }

  /// Reps from the camera ([manual] false) or from the +1 / +10 / −1 buttons.
  /// Ignored outside a running set. Returns the reps actually applied.
  int addReps(int n, {required bool manual}) {
    if (phase != CoachPhase.work || paused || n == 0) return 0;
    if (n < 0) {
      // Corrections only take back manual reps of this set.
      final take = (-n).clamp(0, repsManual).clamp(0, setReps);
      repsManual -= take;
      setReps -= take;
      notifyListeners();
      return -take;
    }
    setReps += n;
    if (manual) {
      repsManual += n;
    } else {
      repsDetected += n;
    }
    if (step.isCount) {
      final t = step.target;
      if (!_halfCued && t >= 10 && setReps * 2 >= t && setReps < t) {
        _halfCued = true;
        _cue(CueKind.half, '过半了，保持节奏');
      }
      if (!_almostCued && t >= 10 && t - setReps == 3) {
        _almostCued = true;
        _cue(CueKind.almost, '最后 3 个');
      }
      if (setReps >= t) _completeSet();
    }
    notifyListeners();
    return n;
  }

  /// 「完成本组」: ends the current set with the reps counted so far.
  void completeSet(int nowMs) {
    if (phase != CoachPhase.work) return;
    tick(nowMs);
    if (phase != CoachPhase.work) return;
    _completeSet();
    notifyListeners();
  }

  void skipRest(int nowMs) {
    if (phase != CoachPhase.rest && phase != CoachPhase.prepare) return;
    tick(nowMs);
    if (phase == CoachPhase.rest || phase == CoachPhase.prepare) _beginWork();
    notifyListeners();
  }

  /// 「跳过」 the rest of the current step (its remaining sets don't count).
  void skipStep(int nowMs) {
    if (phase != CoachPhase.work && phase != CoachPhase.rest && phase != CoachPhase.prepare) return;
    tick(nowMs);
    if (isLastStep) {
      _finish();
    } else {
      stepIndex++;
      setIndex = 0;
      _beginWork();
    }
    notifyListeners();
  }

  /// 「结束」 early.
  void finish(int nowMs) {
    if (phase == CoachPhase.done) return;
    tick(nowMs);
    _finish();
    notifyListeners();
  }

  // ── transitions ──

  void _beginWork() {
    phase = CoachPhase.work;
    paused = false;
    setReps = 0;
    setMs = 0;
    workSerial++;
    _halfCued = false;
    _almostCued = false;
    remainingMs = step.isTime ? step.target * 1000 : 0;
    if (setIndex == 0) {
      final cue = step.cue.isEmpty ? '' : '${step.cue}。';
      _cue(CueKind.start, '${step.name}，${step.targetText}，共 ${step.sets} 组。$cue开始');
    } else {
      _cue(CueKind.start, '第 $setNumber 组，开始');
    }
  }

  void _completeSet() {
    setsDone++;
    final rest = step.restSec;
    if (setIndex + 1 < step.sets) {
      setIndex++;
    } else if (!isLastStep) {
      stepIndex++;
      setIndex = 0;
    } else {
      _finish();
      return;
    }
    if (rest <= 0) {
      _beginWork();
      return;
    }
    phase = CoachPhase.rest;
    remainingMs = rest * 1000;
    final next = setIndex == 0 ? '下一个：${step.name}' : '准备第 $setNumber 组';
    _cue(CueKind.rest, '休息 $rest 秒。$next');
  }

  void _finish() {
    phase = CoachPhase.done;
    paused = false;
    remainingMs = 0;
    _cue(CueKind.done, setsDone == 0 ? '训练结束' : '训练完成，一共 $setsDone 组，太棒了');
  }

  void _countdown(int before, int after) {
    // Only the lowest number crossed (a long tick doesn't say 3-2-1 at once),
    // and none when the phase ends in this tick.
    for (final k in const [1, 2, 3]) {
      if (before > k * 1000 && after <= k * 1000) {
        if (after > 0) _cue(CueKind.countdown, '$k');
        return;
      }
    }
  }
}
