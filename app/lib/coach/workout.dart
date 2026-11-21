/// AI 跟练 workout catalog (docs/api/v2-3-AI.md「App · AI 跟练」).
library;

import '../api/models.dart' show Json;

String _s(Object? v, [String d = '']) => v is String ? v : (v == null ? d : v.toString());
int _i(Object? v, [int d = 0]) => v is num ? v.toInt() : (int.tryParse('$v') ?? d);

/// One exercise of a workout.
class WorkoutStep {
  const WorkoutStep({
    required this.key,
    required this.name,
    required this.mode,
    required this.target,
    this.restSec = 0,
    this.sets = 1,
    this.pose = 'none',
    this.cue = '',
    this.demoUrl,
  });

  final String key;
  final String name;

  /// `count` (target = reps per set) | `time` (target = seconds per set).
  final String mode;
  final int target;
  final int restSec;
  final int sets;

  /// Rep-counting rule: `jump | squat | pushup | crunch | none`.
  final String pose;
  final String cue;
  final String? demoUrl;

  bool get isCount => mode == 'count';
  bool get isTime => !isCount;

  /// Whether the camera can count this step.
  bool get countable => const {'jump', 'squat', 'pushup', 'crunch'}.contains(pose);

  /// 「100 次」/「40 秒」.
  String get targetText => isCount ? '$target 次' : '$target 秒';

  factory WorkoutStep.fromJson(Json j) {
    final mode = _s(j['mode'], 'time') == 'count' ? 'count' : 'time';
    return WorkoutStep(
      key: _s(j['key']),
      name: _s(j['name']),
      mode: mode,
      target: _i(j['target'], mode == 'count' ? 10 : 30).clamp(1, 100000),
      restSec: _i(j['rest_sec']).clamp(0, 3600),
      sets: _i(j['sets'], 1).clamp(1, 100),
      pose: _s(j['pose'], 'none'),
      cue: _s(j['cue']),
      demoUrl: j['demo_url'] is String ? j['demo_url'] as String : null,
    );
  }

  Json toJson() => {
        'key': key,
        'name': name,
        'mode': mode,
        'target': target,
        'rest_sec': restSec,
        'sets': sets,
        'pose': pose,
        'cue': cue,
        'demo_url': demoUrl,
      };
}

class Workout {
  const Workout({
    required this.key,
    required this.name,
    required this.sport,
    this.level = 'beginner',
    this.coverUrl,
    this.estMinutes = 0,
    this.camera = false,
    this.steps = const [],
  });

  final String key;
  final String name;

  /// Activity sport for the upload: `rope | hiit | yoga | strength`.
  final String sport;

  /// `beginner | intermediate | advanced`.
  final String level;
  final String? coverUrl;
  final int estMinutes;

  /// Whether the workout supports camera counting at all.
  final bool camera;
  final List<WorkoutStep> steps;

  bool get usesCamera => camera && steps.any((s) => s.countable);

  int get totalSets => steps.fold(0, (a, s) => a + s.sets);

  String get levelName => switch (level) {
        'intermediate' => '进阶',
        'advanced' => '挑战',
        _ => '入门',
      };

  factory Workout.fromJson(Json j) => Workout(
        key: _s(j['key']),
        name: _s(j['name']),
        sport: _s(j['sport'], 'strength'),
        level: _s(j['level'], 'beginner'),
        coverUrl: j['cover_url'] is String ? j['cover_url'] as String : null,
        estMinutes: _i(j['est_minutes']),
        camera: j['camera'] == true,
        steps: [
          for (final s in (j['steps'] is List ? j['steps'] as List : const []))
            if (s is Map) WorkoutStep.fromJson(s.cast<String, dynamic>()),
        ],
      );

  Json toJson() => {
        'key': key,
        'name': name,
        'sport': sport,
        'level': level,
        'cover_url': coverUrl,
        'est_minutes': estMinutes,
        'camera': camera,
        'steps': [for (final s in steps) s.toJson()],
      };
}

/// `GET /v1/ai/workouts`, or the built-in catalog when that is unavailable.
class WorkoutCatalog {
  const WorkoutCatalog({required this.items, this.builtin = false});
  final List<Workout> items;

  /// True when the server catalog could not be loaded (503 `ai_unavailable`,
  /// offline …) and [builtinWorkouts] is shown instead.
  final bool builtin;

  factory WorkoutCatalog.fromJson(Json j) => WorkoutCatalog(items: [
        for (final w in (j['items'] is List ? j['items'] as List : const []))
          if (w is Map) Workout.fromJson(w.cast<String, dynamic>()),
      ].where((w) => w.key.isNotEmpty && w.steps.isNotEmpty).toList());

  Workout? byKey(String key) {
    for (final w in items) {
      if (w.key == key) return w;
    }
    return null;
  }
}

/// The `coach` object of `POST /v1/activities`.
class CoachReport {
  const CoachReport({
    required this.workoutKey,
    required this.camera,
    required this.repsDetected,
    required this.repsManual,
    required this.setsDone,
  });
  final String workoutKey;

  /// Camera counting was used during the session.
  final bool camera;
  final int repsDetected;
  final int repsManual;
  final int setsDone;

  Json toJson() => {
        'workout_key': workoutKey,
        'camera': camera,
        'reps_detected': repsDetected,
        'reps_manual': repsManual,
        'sets_done': setsDone,
      };
}

/// Bundled with the app; the same as the server's default `workouts`
/// (server/internal/gameplay/workouts.go: 跳绳入门、HIIT 燃脂、普拉提核心、
/// 力量入门), so AI 跟练 works when the catalog endpoint answers 503
/// `ai_unavailable` or the phone is offline.
const builtinWorkouts = <Workout>[
  Workout(key: 'rope_basic', name: '跳绳入门', sport: 'rope', estMinutes: 12, camera: true, steps: [
    WorkoutStep(key: 'rope_jump', name: '双脚跳', mode: 'count', target: 100, restSec: 30, sets: 5, pose: 'jump', cue: '保持节奏，落地轻一点'),
    WorkoutStep(
        key: 'rope_alternate', name: '左右交替跳', mode: 'count', target: 60, restSec: 30, sets: 2, pose: 'jump', cue: '像原地慢跑一样换脚'),
  ]),
  Workout(key: 'hiit_burn', name: 'HIIT 燃脂', sport: 'hiit', level: 'intermediate', estMinutes: 16, camera: true, steps: [
    WorkoutStep(
        key: 'jumping_jack', name: '开合跳', mode: 'time', target: 40, restSec: 20, sets: 3, pose: 'jump', cue: '手脚同时打开，核心收紧'),
    WorkoutStep(key: 'squat', name: '深蹲', mode: 'count', target: 15, restSec: 20, sets: 3, pose: 'squat', cue: '膝盖对准脚尖，臀部向后坐'),
    WorkoutStep(
        key: 'pushup', name: '俯卧撑', mode: 'count', target: 10, restSec: 30, sets: 3, pose: 'pushup', cue: '身体成一条直线，做不动可以跪姿'),
    WorkoutStep(
        key: 'high_knees', name: '高抬腿', mode: 'time', target: 30, restSec: 30, sets: 3, pose: 'none', cue: '大腿抬到水平，快速交替'),
  ]),
  Workout(key: 'pilates_core', name: '普拉提核心', sport: 'yoga', estMinutes: 18, camera: true, steps: [
    WorkoutStep(key: 'crunch', name: '卷腹', mode: 'count', target: 15, restSec: 20, sets: 3, pose: 'crunch', cue: '下背贴地，用腹部发力'),
    WorkoutStep(key: 'plank', name: '平板支撑', mode: 'time', target: 40, restSec: 20, sets: 3, pose: 'none', cue: '肩在手肘正上方，别塌腰'),
    WorkoutStep(
        key: 'glute_bridge', name: '臀桥', mode: 'count', target: 15, restSec: 20, sets: 3, pose: 'none', cue: '臀部发力抬起，顶峰停一秒'),
  ]),
  Workout(key: 'strength_basic', name: '力量入门', sport: 'strength', estMinutes: 20, camera: true, steps: [
    WorkoutStep(key: 'squat', name: '徒手深蹲', mode: 'count', target: 15, restSec: 30, sets: 4, pose: 'squat', cue: '吸气下蹲，呼气起身'),
    WorkoutStep(key: 'pushup', name: '俯卧撑', mode: 'count', target: 10, restSec: 30, sets: 3, pose: 'pushup', cue: '下放慢一点，推起快一点'),
    WorkoutStep(key: 'lunge', name: '弓步蹲', mode: 'time', target: 40, restSec: 20, sets: 3, pose: 'none', cue: '前后脚都成 90 度'),
    WorkoutStep(key: 'crunch', name: '卷腹', mode: 'count', target: 20, restSec: 20, sets: 3, pose: 'crunch', cue: '别用手拉脖子'),
  ]),
];
