import 'dart:math' as math;

import 'pose.dart';

/// Counts repetitions from a stream of [PoseFrame]s. Pure Dart: no camera, no
/// plugin types, so every rule is unit-tested with synthetic landmark
/// sequences (test/coach/rep_counter_test.dart).
///
/// Workout steps name the rule with `pose` (docs/api/v2-3-AI.md):
/// `jump` | `squat` | `pushup` | `crunch` | `none`.
abstract class RepCounter {
  /// Reps counted since the last [reset].
  int get reps;

  /// Feeds one frame (in time order). Returns the reps it completed (0 or 1).
  int add(PoseFrame f);

  /// Starts over (a new set).
  void reset();

  /// Whether the body parts this rule needs are in the picture — drives the
  /// 「全身入镜」 hint and the stability check.
  bool visible(PoseFrame f);

  /// Hint shown while [visible] is false.
  String get framingHint;

  /// Whether this rule counts anything (`none` is timer only).
  bool get counts => true;

  static RepCounter forPose(String pose) => switch (pose) {
        'jump' => JumpCounter(),
        'squat' => AngleRepCounter.squat(),
        'pushup' => AngleRepCounter.pushup(),
        'crunch' => AngleRepCounter.crunch(),
        _ => NoneCounter(),
      };
}

/// `none`: timer only.
class NoneCounter extends RepCounter {
  @override
  int get reps => 0;
  @override
  int add(PoseFrame f) => 0;
  @override
  void reset() {}
  @override
  bool visible(PoseFrame f) => f.hasPerson;
  @override
  String get framingHint => '站到画面中间';
  @override
  bool get counts => false;
}

/// Average of the confidently detected joints among [a] and [b] (null when
/// neither is).
Landmark? _pair(PoseFrame f, Joint a, Joint b) {
  final la = f.get(a), lb = f.get(b);
  if (la != null && lb != null) return midpoint(la, lb);
  return la ?? lb;
}

/// `jump` (跳绳 / 开合跳): the hips — and with them the whole trunk — go up
/// and down.
///
/// 1. Body height: in a jump the whole body rises together, so each of the
///    nose, shoulders, hips, knees and ankles gives an estimate of the trunk
///    centre (its y minus its learned offset). A trimmed mean of those
///    (highest and lowest dropped) ignores a glitching landmark and averages
///    the jitter of the rest. Normalised by the torso length, so the distance
///    to the phone does not matter. Arms are left out (they turn the rope /
///    swing in jumping jacks).
/// 2. Peaks with hysteresis: a jump is a peak that rises at least H above the
///    previous valley and is confirmed once the trunk has dropped H below it
///    (a Schmitt trigger on the swing, not on absolute levels — works for
///    rope hops with short air time as well as symmetric jumping jacks).
///    The rise has to happen within [riseMs] (half a cycle of the slowest
///    jumping jack), so slow swaying, drifting and landmark jitter that
///    accumulates over seconds don't count. H adapts to the recent swing
///    size (35 %), never below [minHysteresis] — jitter of a person standing
///    still stays under that — nor above [maxHysteresis]; it decays when
///    swings stop.
class JumpCounter extends RepCounter {
  JumpCounter({
    this.minHysteresis = 0.055,
    this.maxHysteresis = 0.12,
    this.swingDecayMs = 3000,
    this.riseMs = 600,
    this.warmupMs = 400,
    this.minPeriodMs = 220,
    this.gapResetMs = 800,
  });

  /// In torso lengths.
  final double minHysteresis;
  final double maxHysteresis;
  final int swingDecayMs;
  final int riseMs;
  final int warmupMs;

  /// Fastest plausible rope skipping is ~4 jumps / s.
  final int minPeriodMs;

  /// A longer gap between usable frames (person lost) restarts the tracking.
  final int gapResetMs;

  static const _body = [
    Joint.nose,
    Joint.leftShoulder,
    Joint.rightShoulder,
    Joint.leftHip,
    Joint.rightHip,
    Joint.leftKnee,
    Joint.rightKnee,
    Joint.leftAnkle,
    Joint.rightAnkle,
  ];
  static const _trunk = [Joint.leftShoulder, Joint.rightShoulder, Joint.leftHip, Joint.rightHip];

  int _reps = 0;
  int? _lastT;
  final _offset = <Joint, double>{};
  final _offMiss = <Joint, int>{};
  int _startT = 0;
  double? _scale;
  int _scaleMiss = 0;
  double? _v;
  bool _seekPeak = true;
  double _max = 0;
  int _maxT = 0;
  double _min = 0;
  final _recent = <(int, double)>[];
  double _swing = 0;
  int _lastCountT = -1 << 30;

  /// Current trunk height (torso lengths, + = up) — for debugging / tests.
  double height = 0;

  @override
  int get reps => _reps;

  @override
  void reset() {
    _reps = 0;
    _swing = 0;
    _restart();
  }

  void _restart() {
    _lastT = null;
    _offset.clear();
    _offMiss.clear();
    _scale = null;
    _scaleMiss = 0;
    _v = null;
    _seekPeak = true;
    _recent.clear();
  }

  @override
  bool visible(PoseFrame f) =>
      _pair(f, Joint.leftHip, Joint.rightHip) != null &&
      _pair(f, Joint.leftShoulder, Joint.rightShoulder) != null &&
      (f.inFrame(Joint.leftAnkle) || f.inFrame(Joint.rightAnkle)) &&
      (f.inFrame(Joint.leftShoulder) || f.inFrame(Joint.rightShoulder));

  @override
  String get framingHint => '退后一点，让头到脚都进入画面';

  /// Mean without the highest and lowest value (median-like for 3–4 values).
  static double _trimmedMean(List<double> v) {
    v.sort();
    final n = v.length;
    if (n <= 2) return v.reduce((a, b) => a + b) / n;
    if (n == 4) return (v[1] + v[2]) / 2;
    var sum = 0.0;
    for (var i = 1; i < n - 1; i++) {
      sum += v[i];
    }
    return sum / (n - 2);
  }

  @override
  int add(PoseFrame f) {
    final hip = _pair(f, Joint.leftHip, Joint.rightHip);
    final sh = _pair(f, Joint.leftShoulder, Joint.rightShoulder);
    if (hip == null || sh == null) return 0;
    final t = f.tMs;
    if (_lastT != null && (t - _lastT! > gapResetMs || t < _lastT!)) _restart();
    final dt = _lastT == null ? 0 : t - _lastT!;
    if (_lastT == null) _startT = t;
    _lastT = t;

    // Torso length; a few frames far off (glitch) are ignored, a lasting
    // change (stepped closer) is taken over.
    final s = distance(sh, hip);
    if (s < 1) return 0;
    if (_scale == null || (s - _scale!).abs() < 0.25 * _scale! || ++_scaleMiss >= 5) {
      _scale = _scale == null || _scaleMiss >= 5 ? s : _scale! + 0.2 * (s - _scale!);
      _scaleMiss = 0;
    }
    final scale = _scale!;

    // Robust trunk centre (image y, down = +).
    final pts = {for (final j in _body) j: f.get(j)};
    if (_offset.isEmpty) {
      if (_trunk.any((j) => pts[j] == null)) return 0; // start from a complete trunk
      final c = (sh.y + hip.y) / 2;
      pts.forEach((j, l) {
        if (l != null) _offset[j] = l.y - c;
      });
    }
    final est = [
      for (final e in pts.entries)
        if (e.value != null && _offset[e.key] != null) e.value!.y - _offset[e.key]!,
    ];
    if (est.length < 3) return 0;
    final c = _trimmedMean(est);
    // Learn offsets of joints that (re)appear; adapt slowly to posture; a
    // joint that disagrees for several frames in a row (bad first frame,
    // posture change) is re-learned.
    pts.forEach((j, l) {
      if (l == null) return;
      final o = _offset[j];
      final want = l.y - c;
      if (o == null) {
        _offset[j] = want;
      } else if ((want - o).abs() < 0.2 * scale) {
        _offset[j] = o + 0.05 * (want - o);
        _offMiss[j] = 0;
      } else if ((_offMiss[j] = (_offMiss[j] ?? 0) + 1) >= 5) {
        _offset[j] = want;
        _offMiss[j] = 0;
      }
    });

    final raw = -c / scale; // + = up
    _v = _v == null ? raw : _v! + 0.75 * (raw - _v!);
    final v = _v!;
    height = v;
    _recent
      ..add((t, v))
      ..removeWhere((e) => t - e.$1 > 2 * riseMs);
    if (dt == 0 || t - _startT < warmupMs) {
      _max = _min = v;
      _maxT = t;
      _seekPeak = true;
      return 0;
    }
    _swing *= math.exp(-dt / swingDecayMs);
    final h = (0.35 * _swing).clamp(minHysteresis, maxHysteresis);

    if (_seekPeak) {
      if (v > _max) {
        _max = v;
        _maxT = t;
      }
      if (_max - v >= h) {
        // Peak confirmed: how far did it rise within riseMs before the peak?
        var low = _max;
        for (final e in _recent) {
          if (e.$1 <= _maxT && _maxT - e.$1 <= riseMs && e.$2 < low) low = e.$2;
        }
        final prominence = _max - low;
        _seekPeak = false;
        final peak = _max;
        _min = v;
        if (prominence >= h) {
          _swing = math.max(_swing, prominence) * 0.5 + prominence * 0.5;
          if (t - _lastCountT >= minPeriodMs) {
            _lastCountT = t;
            _reps++;
            _max = peak;
            return 1;
          }
        }
      }
    } else {
      if (v < _min) _min = v;
      if (v - _min >= h) {
        // Valley confirmed; look for the next peak from here.
        _seekPeak = true;
        _max = v;
        _maxT = t;
      }
    }
    return 0;
  }
}

/// A rep is a round trip of an angle between a rest position and an active
/// position, with hysteresis between the two thresholds:
///
/// * `squat` — knee angle (hip–knee–ankle): standing ≥ 155°, down ≤ 115°.
/// * `pushup` — elbow angle (shoulder–elbow–wrist): arms straight ≥ 150°,
///   down ≤ 100°.
/// * `crunch` — torso elevation (hip→shoulder above the floor line, side
///   view): lying ≤ 15°, curled up ≥ 28°.
///
/// The angle is the median of the last [windowMs] of frames (kills single-frame
/// landmark glitches). The rep is counted when the movement returns to rest,
/// at most once per [minRepMs]. A side (left / right) is used when its three
/// joints are confidently detected; with both, the one with the clearly
/// higher confidence wins, otherwise they are averaged.
class AngleRepCounter extends RepCounter {
  AngleRepCounter({
    required this.name,
    required this.measure,
    required this.rest,
    required this.active,
    required this.framingHint,
    this.windowMs = 300,
    this.minRepMs = 600,
    this.lostResetMs = 1500,
  });

  factory AngleRepCounter.squat() => AngleRepCounter(
        name: 'squat',
        rest: 155,
        active: 115,
        framingHint: '侧身或正对手机，让髋、膝、脚踝都在画面里',
        measure: (f) => _sided(f, (Joint.leftHip, Joint.leftKnee, Joint.leftAnkle),
            (Joint.rightHip, Joint.rightKnee, Joint.rightAnkle), angleAt),
      );

  factory AngleRepCounter.pushup() => AngleRepCounter(
        name: 'pushup',
        rest: 150,
        active: 100,
        minRepMs: 500,
        framingHint: '侧对手机，让肩、肘、手腕都在画面里',
        measure: (f) => _sided(f, (Joint.leftShoulder, Joint.leftElbow, Joint.leftWrist),
            (Joint.rightShoulder, Joint.rightElbow, Joint.rightWrist), angleAt),
      );

  factory AngleRepCounter.crunch() => AngleRepCounter(
        name: 'crunch',
        rest: 15,
        active: 28,
        minRepMs: 500,
        framingHint: '侧躺对着手机，让肩、髋、膝都在画面里',
        measure: (f) => _sided(f, (Joint.leftHip, Joint.leftShoulder, Joint.leftKnee),
            (Joint.rightHip, Joint.rightShoulder, Joint.rightKnee), (hip, shoulder, _) => elevation(hip, shoulder)),
      );

  final String name;

  /// Angle (degrees) of the frame, or null when it can't be measured.
  final double? Function(PoseFrame f) measure;

  /// Threshold of the rest position and of the active position. When
  /// `rest > active` the rest position is the larger angle.
  final double rest;
  final double active;
  @override
  final String framingHint;
  final int windowMs;
  final int minRepMs;
  final int lostResetMs;

  bool get _restAbove => rest > active;

  int _reps = 0;
  final _window = <(int, double)>[];
  _Phase _phase = _Phase.unknown;
  int? _lastSeen;
  int _lastCountT = -1 << 30;

  /// Last filtered angle, for tests / debugging.
  double? angle;

  @override
  int get reps => _reps;

  @override
  void reset() {
    _reps = 0;
    _window.clear();
    _phase = _Phase.unknown;
    _lastSeen = null;
    angle = null;
  }

  @override
  bool visible(PoseFrame f) => measure(f) != null;

  @override
  int add(PoseFrame f) {
    final v = measure(f);
    final t = f.tMs;
    if (v == null) {
      // Lost the person for a while: the movement in between is unknown, so
      // wait for the rest position again instead of guessing a rep.
      if (_lastSeen != null && t - _lastSeen! > lostResetMs) {
        _phase = _Phase.unknown;
        _window.clear();
      }
      return 0;
    }
    _lastSeen = t;
    _window
      ..add((t, v))
      ..removeWhere((e) => t - e.$1 > windowMs);
    final sorted = [for (final e in _window) e.$2]..sort();
    final m = sorted[sorted.length ~/ 2];
    angle = m;
    final atRest = _restAbove ? m >= rest : m <= rest;
    final atActive = _restAbove ? m <= active : m >= active;
    switch (_phase) {
      case _Phase.unknown:
        if (atRest) _phase = _Phase.rest;
      case _Phase.rest:
        if (atActive) _phase = _Phase.active;
      case _Phase.active:
        if (atRest) {
          _phase = _Phase.rest;
          if (t - _lastCountT >= minRepMs) {
            _lastCountT = t;
            _reps++;
            return 1;
          }
        }
    }
    return 0;
  }

  static double? _sided(
    PoseFrame f,
    (Joint, Joint, Joint) left,
    (Joint, Joint, Joint) right,
    double Function(Landmark, Landmark, Landmark) fn,
  ) {
    (double, double)? side((Joint, Joint, Joint) j) {
      final a = f.get(j.$1), b = f.get(j.$2), c = f.get(j.$3);
      if (a == null || b == null || c == null) return null;
      return (fn(a, b, c), math.min(a.likelihood, math.min(b.likelihood, c.likelihood)));
    }

    final l = side(left), r = side(right);
    if (l == null) return r?.$1;
    if (r == null) return l.$1;
    if ((l.$2 - r.$2).abs() >= 0.15) return l.$2 > r.$2 ? l.$1 : r.$1;
    return (l.$1 + r.$1) / 2;
  }
}

enum _Phase { unknown, rest, active }
