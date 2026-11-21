import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/coach/coach_session.dart';
import 'package:loopland/coach/pose.dart';
import 'package:loopland/coach/tracking.dart';
import 'package:loopland/coach/workout.dart';

import 'synthetic.dart';

/// docs/api/v2-3-AI.md example.
const workoutJson = '''
{
  "key": "rope_basic", "name": "跳绳入门", "sport": "rope", "level": "beginner",
  "cover_url": null, "est_minutes": 12,
  "camera": true,
  "steps": [
    { "key": "rope_jump", "name": "双脚跳", "mode": "count", "target": 100, "rest_sec": 30, "sets": 5,
      "pose": "jump", "cue": "保持节奏，落地轻一点", "demo_url": null }
  ]
}
''';

const twoSteps = Workout(key: 'w', name: '测试', sport: 'hiit', camera: true, steps: [
  WorkoutStep(key: 'a', name: '开合跳', mode: 'time', target: 20, restSec: 10, sets: 2, pose: 'jump', cue: '手臂伸直'),
  WorkoutStep(key: 'b', name: '深蹲', mode: 'count', target: 10, restSec: 0, sets: 2, pose: 'squat'),
]);

void main() {
  group('Workout JSON (contract)', () {
    test('parses the contract example and round-trips', () {
      final w = Workout.fromJson(jsonDecode(workoutJson) as Map<String, dynamic>);
      expect(w.key, 'rope_basic');
      expect(w.sport, 'rope');
      expect(w.camera, isTrue);
      expect(w.usesCamera, isTrue);
      expect(w.totalSets, 5);
      final s = w.steps.single;
      expect((s.mode, s.target, s.restSec, s.sets, s.pose, s.cue), ('count', 100, 30, 5, 'jump', '保持节奏，落地轻一点'));
      expect(s.countable, isTrue);
      expect(Workout.fromJson(jsonDecode(jsonEncode(w.toJson())) as Map<String, dynamic>).steps.single.target, 100);
    });

    test('tolerates odd values; catalog drops empty workouts', () {
      final c = WorkoutCatalog.fromJson({
        'items': [
          {'key': 'x', 'name': 'X', 'sport': 'yoga', 'steps': [
            {'key': 's', 'name': 'S', 'mode': 'weird', 'target': '45', 'sets': 0, 'pose': 'none'}
          ]},
          {'key': 'empty', 'name': 'E', 'steps': []},
          'garbage',
        ]
      });
      expect(c.items.map((w) => w.key), ['x']);
      final s = c.items.single.steps.single;
      expect((s.mode, s.target, s.sets, s.countable), ('time', 45, 1, false));
      expect(c.items.single.usesCamera, isFalse);
    });

    test('built-in catalog covers the four home sports, all valid', () {
      expect(builtinWorkouts.map((w) => w.sport).toSet(), {'rope', 'hiit', 'yoga', 'strength'});
      for (final w in builtinWorkouts) {
        expect(w.steps, isNotEmpty);
        for (final s in w.steps) {
          expect(['jump', 'squat', 'pushup', 'crunch', 'none'], contains(s.pose));
        }
        // Survives a JSON round trip (same parser as the server catalog).
        expect(WorkoutCatalog.fromJson({'items': [w.toJson()]}).items.single.steps.length, w.steps.length);
      }
    });

    test('coach object of the activity upload', () {
      final u = ActivityUpload(
        clientId: 'c',
        sport: 'rope',
        startedAt: DateTime.utc(2026, 11, 21),
        endedAt: DateTime.utc(2026, 11, 21, 0, 12),
        durationS: 720,
        amount: 480,
        device: const DeviceInfo(id: 'd'),
        coach: const CoachReport(workoutKey: 'rope_basic', camera: true, repsDetected: 480, repsManual: 0, setsDone: 5)
            .toJson(),
      );
      final j = u.toJson();
      expect(j['coach'],
          {'workout_key': 'rope_basic', 'camera': true, 'reps_detected': 480, 'reps_manual': 0, 'sets_done': 5});
      expect(ActivityUpload.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>).coach!['sets_done'], 5);
      // Without coach the field is left out (V1 uploads unchanged).
      expect(ActivityUpload.fromJson({...j}..remove('coach')).toJson().containsKey('coach'), isFalse);
    });
  });

  group('CoachSession', () {
    late List<CoachCue> cues;
    late int now;
    late CoachSession s;

    setUp(() {
      cues = [];
      now = 0;
      s = CoachSession(twoSteps, prepareSec: 5, onCue: cues.add);
    });

    void advance(int ms, {int step = 100}) {
      for (var i = 0; i < ms ~/ step; i++) {
        now += step;
        s.tick(now);
      }
    }

    test('prepare countdown → timed set with half / 3-2-1 → rest → next set', () {
      s.start(now);
      expect(s.phase, CoachPhase.prepare);
      expect(cues.last.kind, CueKind.prepare);
      advance(5000);
      expect(s.phase, CoachPhase.work);
      expect(cues.map((c) => c.text), containsAllInOrder(['3', '2', '1']));
      expect(cues.last.text, '开合跳，20 秒，共 2 组。手臂伸直。开始');
      expect(s.elapsedMs, 0, reason: 'the countdown is not training time');
      expect(s.workSerial, 1);
      cues.clear();
      advance(10000);
      expect(cues.single.kind, CueKind.half);
      advance(10000);
      expect(cues.map((c) => c.text).toList(), ['已经一半了，坚持住', '3', '2', '1', '休息 10 秒。准备第 2 组']);
      expect(s.phase, CoachPhase.rest);
      expect(s.setsDone, 1);
      expect((s.stepIndex, s.setIndex), (0, 1));
      expect(s.nextPreview, '开合跳 · 20 秒 · 第 2/2 组');
      advance(10000);
      expect(s.phase, CoachPhase.work);
      expect(cues.last.text, '第 2 组，开始');
      expect(s.elapsedMs, 30000);
    });

    test('reps during a timed set are recorded; count sets end at the target', () {
      s.start(now);
      s.skipRest(now); // skip the countdown
      expect(s.phase, CoachPhase.work);
      s.addReps(1, manual: false);
      s.addReps(1, manual: false);
      expect(s.repsDetected, 2);
      s.skipStep(now); // to 深蹲 (count 10 × 2, no rest)
      expect(s.step.name, '深蹲');
      expect(s.setReps, 0);
      cues.clear();
      for (var i = 0; i < 9; i++) {
        s.addReps(1, manual: false);
      }
      expect(cues.map((c) => c.kind), [CueKind.half, CueKind.almost]);
      expect(s.setReps, 9);
      s.addReps(1, manual: true);
      // rest 0 → the next set starts right away
      expect((s.phase, s.setIndex, s.setReps, s.setsDone), (CoachPhase.work, 1, 0, 1));
      expect((s.repsDetected, s.repsManual, s.totalReps), (11, 1, 12));
      for (var i = 0; i < 10; i++) {
        s.addReps(1, manual: false);
      }
      expect(s.phase, CoachPhase.done);
      expect(s.setsDone, 2);
      expect(cues.last.kind, CueKind.done);
    });

    test('pause freezes the clocks and ignores reps; resume continues', () {
      s.start(now);
      advance(5000);
      advance(4000);
      expect(s.remainingMs, 16000);
      s.pause(now);
      advance(30000);
      expect(s.remainingMs, 16000);
      expect(s.elapsedMs, 4000);
      expect(s.addReps(5, manual: true), 0);
      s.resume(now);
      advance(1000);
      expect(s.remainingMs, 15000);
      expect(s.elapsedMs, 5000);
    });

    test('manual −1 only takes back manual reps', () {
      s.start(now);
      s.skipStep(now);
      s.addReps(3, manual: false);
      expect(s.addReps(-1, manual: true), 0);
      s.addReps(2, manual: true);
      expect(s.addReps(-5, manual: true), -2);
      expect((s.setReps, s.repsManual, s.repsDetected), (3, 0, 3));
    });

    test('完成本组 / 跳过 / 结束', () {
      s.start(now);
      s.skipRest(now);
      s.completeSet(now); // ends the timed set early
      expect(s.phase, CoachPhase.rest);
      expect(s.setsDone, 1);
      s.skipStep(now); // skipping in rest skips the upcoming set of 开合跳 too
      expect((s.step.name, s.phase), ('深蹲', CoachPhase.work));
      s.finish(now);
      expect(s.phase, CoachPhase.done);
      expect(s.setsDone, 1);
      expect(cues.last.text, '训练完成，一共 1 组，太棒了');
      // Nothing moves after done.
      advance(5000);
      expect(s.elapsedMs, 0);
    });

    test('a large tick (app was suspended) does not say 3-2-1 at once', () {
      s.start(now);
      now += 4500;
      s.tick(now);
      expect(cues.where((c) => c.kind == CueKind.countdown).map((c) => c.text), ['1']);
    });
  });

  group('TrackingMonitor', () {
    test('states, full-body hint and fallback reasons', () {
      final m = TrackingMonitor();
      expect(m.stateAt(0), TrackingState.waiting);
      m.restart(0);
      expect(m.unstableReason(1000), isNull);
      expect(m.unstableReason(2600), '摄像头没有画面');
      // 5 s of good frames
      for (var t = 0; t < 5000; t += 66) {
        m.add(standing(t), visible: true, atMs: 2600 + t);
      }
      final now = 7600;
      expect(m.stateAt(now), TrackingState.ok);
      expect(m.fps, closeTo(15, 0.5));
      expect(m.unstableReason(now), isNull);
      // Then only partial bodies for 4 s
      for (var t = 0; t < 4000; t += 66) {
        m.add(standing(t), visible: false, atMs: now + t);
      }
      expect(m.stateAt(now + 4000), TrackingState.partial);
      expect(m.unstableReason(now + 4000), '识别不稳定');
    });

    test('dark picture', () {
      final m = TrackingMonitor()..restart(0);
      for (var t = 0; t < 5000; t += 100) {
        m.add(PoseFrame(tMs: t, joints: const {}, luma: 22), visible: false, atMs: t);
      }
      expect(m.lowLight, isTrue);
      expect(m.stateAt(5000), TrackingState.noPerson);
      expect(m.unstableReason(5000), '光线太暗');
    });
  });
}
