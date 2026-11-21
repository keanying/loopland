// Synthetic landmark sequences for the rep-counter tests: a stick figure in a
// 480×640 portrait image, moved by a known motion, sampled at a given frame
// rate with landmark jitter, dropouts and outliers.
import 'dart:math' as math;

import 'package:loopland/coach/pose.dart';

const imgW = 480.0, imgH = 640.0;

class Noise {
  Noise({int seed = 1, this.sigmaPx = 0, this.dropout = 0, this.outliers = 0, this.timeJitterMs = 0})
      : rnd = math.Random(seed);
  final math.Random rnd;

  /// Gaussian jitter of every landmark (pixels).
  final double sigmaPx;

  /// Share of frames where nobody / the key joints are not detected.
  final double dropout;

  /// Share of frames where one random joint jumps far away (detector glitch).
  final double outliers;
  final int timeJitterMs;

  double gauss() {
    // Box–Muller
    final u1 = math.max(rnd.nextDouble(), 1e-12), u2 = rnd.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  PoseFrame apply(PoseFrame f) {
    if (dropout > 0 && rnd.nextDouble() < dropout) {
      // Low-confidence frame: the joints are there but unreliable.
      return PoseFrame(
        tMs: f.tMs,
        width: f.width,
        height: f.height,
        joints: {for (final e in f.joints.entries) e.key: Landmark(e.value.x, e.value.y, 0.2)},
      );
    }
    final out = <Joint, Landmark>{};
    for (final e in f.joints.entries) {
      out[e.key] = Landmark(e.value.x + gauss() * sigmaPx, e.value.y + gauss() * sigmaPx, e.value.likelihood);
    }
    if (outliers > 0 && rnd.nextDouble() < outliers) {
      final j = Joint.values[rnd.nextInt(Joint.values.length)];
      final l = out[j];
      if (l != null) out[j] = Landmark(l.x + (rnd.nextBool() ? 80 : -80), l.y + (rnd.nextBool() ? 80 : -80), 0.9);
    }
    return PoseFrame(tMs: f.tMs, width: f.width, height: f.height, joints: out);
  }
}

/// Frame timestamps for [seconds] at [fps].
Iterable<int> times(double seconds, double fps, {Noise? noise}) sync* {
  final n = (seconds * fps).floor();
  for (var i = 0; i < n; i++) {
    final j = noise == null || noise.timeJitterMs == 0 ? 0 : noise.rnd.nextInt(noise.timeJitterMs);
    yield (i * 1000 / fps).round() + j;
  }
}

/// Standing figure; the whole body raised by [liftPx], scaled by [scale]
/// around the image centre.
PoseFrame standing(int tMs, {double liftPx = 0, double scale = 1, double shiftX = 0}) {
  Landmark p(double x, double y) =>
      Landmark(imgW / 2 + (x - imgW / 2) * scale + shiftX, imgH / 2 + (y - imgH / 2) * scale - liftPx);
  return PoseFrame(tMs: tMs, width: imgW, height: imgH, joints: {
    Joint.nose: p(240, 130),
    Joint.leftShoulder: p(210, 200),
    Joint.rightShoulder: p(270, 200),
    Joint.leftElbow: p(195, 265),
    Joint.rightElbow: p(285, 265),
    Joint.leftWrist: p(190, 325),
    Joint.rightWrist: p(290, 325),
    Joint.leftHip: p(220, 330),
    Joint.rightHip: p(260, 330),
    Joint.leftKnee: p(218, 440),
    Joint.rightKnee: p(262, 440),
    Joint.leftAnkle: p(216, 550),
    Joint.rightAnkle: p(264, 550),
  });
}

/// Torso length of [standing] at scale 1 (shoulder mid → hip mid).
const torsoPx = 130.0;

Landmark _polar(Landmark from, double len, double angleDeg) {
  final a = angleDeg * math.pi / 180;
  return Landmark(from.x + len * math.cos(a), from.y + len * math.sin(a));
}

/// Side-view squat: knee angle [kneeDeg] (hip–knee–ankle), shins vertical.
PoseFrame squat(int tMs, double kneeDeg) {
  const shin = 110.0, thigh = 110.0;
  final joints = <Joint, Landmark>{};
  for (final (side, dx) in [(0, -6.0), (1, 6.0)]) {
    final ankle = Landmark(240 + dx, 560);
    final knee = Landmark(ankle.x, ankle.y - shin);
    // Thigh direction: the knee→ankle direction (90°, down) rotated by the
    // knee angle → hip behind (to the left of) the knee.
    final hip = _polar(knee, thigh, 90 + kneeDeg);
    final shoulder = _polar(hip, torsoPx, -80);
    final elbow = _polar(shoulder, 60, 60);
    final wrist = _polar(elbow, 55, 30);
    if (side == 0) {
      joints.addAll({
        Joint.leftAnkle: ankle,
        Joint.leftKnee: knee,
        Joint.leftHip: hip,
        Joint.leftShoulder: shoulder,
        Joint.leftElbow: elbow,
        Joint.leftWrist: wrist,
      });
    } else {
      joints.addAll({
        Joint.rightAnkle: ankle,
        Joint.rightKnee: knee,
        Joint.rightHip: hip,
        Joint.rightShoulder: shoulder,
        Joint.rightElbow: elbow,
        Joint.rightWrist: wrist,
      });
    }
  }
  joints[Joint.nose] = _polar(joints[Joint.leftShoulder]!, 40, -80);
  return PoseFrame(tMs: tMs, width: imgW, height: imgH, joints: joints);
}

/// Side-view push-up (phone on the floor, landscape-ish body across the
/// picture): elbow angle [elbowDeg] (shoulder–elbow–wrist).
PoseFrame pushup(int tMs, double elbowDeg, {double rightLikelihood = 0.95}) {
  const upper = 70.0, fore = 70.0;
  final joints = <Joint, Landmark>{};
  for (final (side, dx, lk) in [(0, -4.0, 0.95), (1, 4.0, rightLikelihood)]) {
    final wrist = Landmark(300 + dx, 420, lk);
    final elbowL = Landmark(wrist.x, wrist.y - fore, lk); // forearm vertical
    final s = _polar(elbowL, upper, 90 + elbowDeg); // upper arm rotated by the elbow angle
    final shoulder = Landmark(s.x, s.y, lk);
    final hip = Landmark(shoulder.x - 160, shoulder.y + 20, lk);
    final knee = Landmark(hip.x - 90, hip.y + 15, lk);
    final ankle = Landmark(knee.x - 90, knee.y + 12, lk);
    final m = side == 0
        ? {
            Joint.leftWrist: wrist,
            Joint.leftElbow: elbowL,
            Joint.leftShoulder: shoulder,
            Joint.leftHip: hip,
            Joint.leftKnee: knee,
            Joint.leftAnkle: ankle,
          }
        : {
            Joint.rightWrist: wrist,
            Joint.rightElbow: elbowL,
            Joint.rightShoulder: shoulder,
            Joint.rightHip: hip,
            Joint.rightKnee: knee,
            Joint.rightAnkle: ankle,
          };
    joints.addAll(m);
  }
  return PoseFrame(tMs: tMs, width: imgW, height: imgH, joints: joints);
}

/// Side-view crunch: torso [elevDeg] above the floor, knees bent up.
PoseFrame crunch(int tMs, double elevDeg) {
  final joints = <Joint, Landmark>{};
  for (final (side, dx) in [(0, -3.0), (1, 3.0)]) {
    final hip = Landmark(260 + dx, 480);
    final shoulder = _polar(hip, torsoPx, 180 + elevDeg); // towards the left, up
    final knee = _polar(hip, 110, -45);
    final ankle = Landmark(knee.x + 70, 480);
    final m = side == 0
        ? {Joint.leftHip: hip, Joint.leftShoulder: shoulder, Joint.leftKnee: knee, Joint.leftAnkle: ankle}
        : {Joint.rightHip: hip, Joint.rightShoulder: shoulder, Joint.rightKnee: knee, Joint.rightAnkle: ankle};
    joints.addAll(m);
  }
  return PoseFrame(tMs: tMs, width: imgW, height: imgH, joints: joints);
}

/// Smooth oscillation between [lo] (at t=0) and [hi] with [periodMs].
double osc(int tMs, double lo, double hi, int periodMs) =>
    lo + (hi - lo) * (1 - math.cos(2 * math.pi * tMs / periodMs)) / 2;
