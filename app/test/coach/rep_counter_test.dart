import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/coach/pose.dart';
import 'package:loopland/coach/rep_counter.dart';

import 'synthetic.dart';

int run(RepCounter c, Iterable<PoseFrame> frames) {
  for (final f in frames) {
    c.add(f);
  }
  return c.reps;
}

/// Jumping figure: [height] (torso lengths) of the hips over time.
Iterable<PoseFrame> jumping(
  double Function(int tMs) height, {
  double seconds = 10,
  double fps = 15,
  Noise? noise,
  double Function(int tMs)? scale,
}) =>
    times(seconds, fps, noise: noise).map((t) {
      final s = scale?.call(t) ?? 1;
      final f = standing(t, liftPx: height(t) * torsoPx * s, scale: s);
      return noise == null ? f : noise.apply(f);
    });

void main() {
  group('geometry', () {
    test('angleAt and elevation', () {
      expect(angleAt(const Landmark(0, -1), const Landmark(0, 0), const Landmark(1, 0)), closeTo(90, 1e-9));
      expect(angleAt(const Landmark(0, -1), const Landmark(0, 0), const Landmark(0, 1)), closeTo(180, 1e-9));
      expect(elevation(const Landmark(0, 0), const Landmark(-1, -1)), closeTo(45, 1e-9));
      expect(elevation(const Landmark(0, 0), const Landmark(5, 0)), 0);
    });

    test('synthetic poses have the requested angles', () {
      final s = squat(0, 100);
      expect(angleAt(s.joints[Joint.leftHip]!, s.joints[Joint.leftKnee]!, s.joints[Joint.leftAnkle]!), closeTo(100, 1e-6));
      final p = pushup(0, 85);
      expect(angleAt(p.joints[Joint.leftShoulder]!, p.joints[Joint.leftElbow]!, p.joints[Joint.leftWrist]!),
          closeTo(85, 1e-6));
      final c = crunch(0, 33);
      expect(elevation(c.joints[Joint.leftHip]!, c.joints[Joint.leftShoulder]!), closeTo(33, 1e-6));
    });
  });

  group('jump (hip oscillation with hysteresis)', () {
    // 20 jumps in 10 s; the first one falls into the 0.4 s warm-up.
    test('clean rope skipping, 2 Hz for 10 s → 19', () {
      final n = run(JumpCounter(), jumping((t) => 0.08 * math.sin(2 * math.pi * 2 * t / 1000)));
      expect(n, 19);
    });

    test('hops (air time then ground contact) with landmark jitter → 19 ± 1', () {
      final noise = Noise(seed: 3, sigmaPx: 1.5, timeJitterMs: 8);
      final n = run(
          JumpCounter(), jumping((t) => 0.10 * math.max(0, math.sin(2 * math.pi * 2 * t / 1000)), noise: noise));
      expect(n, inInclusiveRange(18, 20));
    });

    test('jumping jacks 1 Hz at 12 fps with noise, dropouts and outliers → 8 ± 1', () {
      final noise = Noise(seed: 5, sigmaPx: 2, dropout: 0.1, outliers: 0.05);
      final n = run(JumpCounter(),
          jumping((t) => 0.15 * math.sin(2 * math.pi * t / 1000), seconds: 8, fps: 12, noise: noise));
      expect(n, inInclusiveRange(7, 9));
    });

    test('slow phone (8 fps) still counts 2 Hz skipping → 20 ± 2', () {
      final noise = Noise(seed: 9, sigmaPx: 1, timeJitterMs: 30);
      final n = run(
          JumpCounter(), jumping((t) => 0.09 * math.sin(2 * math.pi * 2 * t / 1000), fps: 8, noise: noise));
      expect(n, inInclusiveRange(18, 22));
    });

    test('walking towards the phone while skipping (scale 1 → 1.4) → 19 ± 1', () {
      final noise = Noise(seed: 11, sigmaPx: 1.5);
      final n = run(
          JumpCounter(),
          jumping((t) => 0.08 * math.sin(2 * math.pi * 2 * t / 1000),
              noise: noise, scale: (t) => 1 + 0.4 * t / 10000));
      expect(n, inInclusiveRange(18, 20));
    });

    test('hops at 10 fps (2–3 frames in the air) → 17–20', () {
      final noise = Noise(seed: 13, sigmaPx: 2, timeJitterMs: 20);
      final n = run(JumpCounter(),
          jumping((t) => 0.10 * math.max(0, math.sin(2 * math.pi * 2 * t / 1000)), fps: 10, noise: noise));
      expect(n, inInclusiveRange(17, 20));
    });

    test('standing still with jitter → 0', () {
      for (final seed in [1, 2, 3, 4]) {
        final noise = Noise(seed: seed, sigmaPx: 2.5, outliers: 0.03);
        expect(run(JumpCounter(), jumping((_) => 0, seconds: 15, noise: noise)), 0, reason: 'seed $seed');
      }
    });

    test('slow sway / stepping around → 0', () {
      final noise = Noise(seed: 21, sigmaPx: 1.5);
      final frames = times(12, 15).map((t) => noise.apply(
          standing(t, liftPx: 6 * math.sin(2 * math.pi * t / 4000), shiftX: 60 * math.sin(2 * math.pi * t / 6000))));
      expect(run(JumpCounter(), frames), 0);
    });

    test('nobody in the picture → 0, and reset starts over', () {
      final c = JumpCounter();
      for (final t in times(3, 15)) {
        c.add(PoseFrame(tMs: t, joints: const {}));
      }
      expect(c.reps, 0);
      run(c, jumping((t) => 0.08 * math.sin(2 * math.pi * 2 * t / 1000), seconds: 3));
      expect(c.reps, greaterThan(3));
      c.reset();
      expect(c.reps, 0);
    });

    test('a long gap (person left) restarts tracking without phantom reps', () {
      final c = JumpCounter();
      run(c, jumping((_) => 0, seconds: 2));
      // Comes back 3 s later standing 0.4 torso lengths higher in the picture.
      final later = times(2, 15).map((t) => standing(t + 5000, liftPx: 0.4 * torsoPx));
      expect(run(c, later), 0);
    });

    test('visible needs shoulders, hips and feet in the picture', () {
      final c = JumpCounter();
      expect(c.visible(standing(0)), isTrue);
      final cut = standing(0);
      final noFeet = PoseFrame(tMs: 0, width: imgW, height: imgH, joints: {
        for (final e in cut.joints.entries)
          if (e.key != Joint.leftAnkle && e.key != Joint.rightAnkle) e.key: e.value,
      });
      expect(c.visible(noFeet), isFalse);
      // Feet below the bottom edge (too close to the phone).
      expect(c.visible(standing(0, scale: 1.6)), isFalse);
    });
  });

  group('squat (knee angle)', () {
    Iterable<PoseFrame> squats(double lo, {int reps = 10, int periodMs = 2500, double fps = 15, Noise? noise}) =>
        times(reps * periodMs / 1000 + 0.5, fps, noise: noise).map((t) {
          final f = squat(t, osc(t, 175, lo, periodMs));
          return noise == null ? f : noise.apply(f);
        });

    test('10 full squats → 10', () {
      expect(run(AngleRepCounter.squat(), squats(85)), 10);
    });

    test('noisy landmarks, glitches and dropouts → 10', () {
      for (final seed in [1, 2, 3]) {
        final noise = Noise(seed: seed, sigmaPx: 3, outliers: 0.08, dropout: 0.1, timeJitterMs: 20);
        expect(run(AngleRepCounter.squat(), squats(90, noise: noise)), 10, reason: 'seed $seed');
      }
    });

    test('fast squats at a low frame rate → 10', () {
      expect(run(AngleRepCounter.squat(), squats(90, periodMs: 1400, fps: 8)), 10);
    });

    test('half squats that never reach depth → 0', () {
      expect(run(AngleRepCounter.squat(), squats(130)), 0);
    });

    test('standing still with jitter → 0', () {
      final noise = Noise(seed: 4, sigmaPx: 4, outliers: 0.1);
      expect(run(AngleRepCounter.squat(), times(15, 15).map((t) => noise.apply(squat(t, 172)))), 0);
    });

    test('starting at the bottom does not count until a full round trip', () {
      final c = AngleRepCounter.squat();
      // Begins squatting down (unknown phase), stands up: no rep yet.
      run(c, times(1, 15).map((t) => squat(t, 90)));
      run(c, times(1, 15).map((t) => squat(1000 + t, 175)));
      expect(c.reps, 0);
      run(c, times(2.5, 15).map((t) => squat(2000 + t, osc(t, 175, 90, 2500))));
      expect(c.reps, 1);
    });

    test('losing the person mid-rep waits for the rest position again', () {
      final c = AngleRepCounter.squat();
      run(c, times(1, 15).map((t) => squat(t, 175)));
      run(c, times(0.6, 15).map((t) => squat(1000 + t, 90))); // down
      for (final t in times(2, 15)) {
        c.add(PoseFrame(tMs: 1600 + t, joints: const {})); // gone 2 s
      }
      run(c, times(1, 15).map((t) => squat(3600 + t, 175))); // back, standing
      expect(c.reps, 0);
    });
  });

  group('pushup (elbow angle)', () {
    test('8 push-ups with noise → 8', () {
      final noise = Noise(seed: 7, sigmaPx: 2.5, outliers: 0.05);
      final frames = times(8 * 2.0 + 0.5, 15).map((t) => noise.apply(pushup(t, osc(t, 170, 80, 2000))));
      expect(run(AngleRepCounter.pushup(), frames), 8);
    });

    test('far side occluded (low confidence) → counts with the near side', () {
      final frames = times(6.5, 15).map((t) => pushup(t, osc(t, 170, 85, 2000), rightLikelihood: 0.3));
      expect(run(AngleRepCounter.pushup(), frames), 3);
    });

    test('shallow dips → 0', () {
      final frames = times(10, 15).map((t) => pushup(t, osc(t, 170, 125, 2000)));
      expect(run(AngleRepCounter.pushup(), frames), 0);
    });
  });

  group('crunch (torso elevation)', () {
    test('12 crunches with noise → 12', () {
      final noise = Noise(seed: 8, sigmaPx: 2, outliers: 0.05, dropout: 0.05);
      final frames = times(12 * 1.8 + 0.4, 15).map((t) => noise.apply(crunch(t, osc(t, 4, 38, 1800))));
      expect(run(AngleRepCounter.crunch(), frames), 12);
    });

    test('lying still / tiny head nods → 0', () {
      final noise = Noise(seed: 2, sigmaPx: 3);
      final frames = times(12, 15).map((t) => noise.apply(crunch(t, osc(t, 5, 16, 1500))));
      expect(run(AngleRepCounter.crunch(), frames), 0);
    });
  });

  test('forPose maps the contract names', () {
    expect(RepCounter.forPose('jump'), isA<JumpCounter>());
    expect((RepCounter.forPose('squat') as AngleRepCounter).name, 'squat');
    expect((RepCounter.forPose('pushup') as AngleRepCounter).name, 'pushup');
    expect((RepCounter.forPose('crunch') as AngleRepCounter).name, 'crunch');
    final none = RepCounter.forPose('none');
    expect(none.counts, isFalse);
    expect(RepCounter.forPose('unknown_future_pose').counts, isFalse);
    expect(run(none, times(3, 15).map((t) => squat(t, osc(t, 175, 80, 1000)))), 0);
  });
}
