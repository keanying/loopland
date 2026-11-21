// Fakes for AI 跟练 (C-09): the catalog / upload endpoints and a pose source
// that the test drives frame by frame (no camera).
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show RequestOptions;
import 'package:loopland/coach/pose.dart';
import 'package:loopland/coach/pose_source.dart';
import 'package:material_ui/material_ui.dart';

import '../api/fixtures.dart';

/// Small workouts so a whole session fits in a test.
final coachWorkoutsJson = <Map<String, Object?>>[
  {
    'key': 'rope_test',
    'name': '跳绳入门',
    'sport': 'rope',
    'level': 'beginner',
    'cover_url': null,
    'est_minutes': 12,
    'camera': true,
    'steps': [
      {'key': 'rope_jump', 'name': '双脚跳', 'mode': 'count', 'target': 5, 'rest_sec': 3, 'sets': 2, 'pose': 'jump', 'cue': '保持节奏，落地轻一点', 'demo_url': null},
      {'key': 'stretch', 'name': '放松拉伸', 'mode': 'time', 'target': 4, 'rest_sec': 0, 'sets': 1, 'pose': 'none', 'cue': '慢慢呼吸', 'demo_url': null},
    ],
  },
  {
    'key': 'rope_long',
    'name': '跳绳进阶',
    'sport': 'rope',
    'level': 'intermediate',
    'est_minutes': 20,
    'camera': true,
    'steps': [
      {'key': 'rope_jump', 'name': '双脚跳', 'mode': 'count', 'target': 200, 'rest_sec': 45, 'sets': 5, 'pose': 'jump', 'cue': '手腕发力'},
      {'key': 'rope_single', 'name': '单脚交替跳', 'mode': 'time', 'target': 60, 'rest_sec': 45, 'sets': 3, 'pose': 'jump', 'cue': ''},
    ],
  },
  {
    'key': 'hiit_test',
    'name': 'HIIT 燃脂',
    'sport': 'hiit',
    'level': 'intermediate',
    'est_minutes': 15,
    'camera': true,
    'steps': [
      {'key': 'squat', 'name': '深蹲', 'mode': 'count', 'target': 15, 'rest_sec': 20, 'sets': 3, 'pose': 'squat', 'cue': '膝盖对准脚尖'},
    ],
  },
];

/// Gameplay config with energy rules for the home sports.
Map<String, dynamic> coachConfig() {
  final c = (jsonDecode(configJson) as Map).cast<String, dynamic>();
  c['energy'] = [
    ...(c['energy'] as List),
    {'sport': 'rope', 'name': '跳绳', 'unit': '次', 'per': 5, 'energy': 1},
    {'sport': 'hiit', 'name': 'HIIT', 'unit': 'min', 'per': 10, 'energy': 8},
    {'sport': 'yoga', 'name': '瑜伽', 'unit': 'min', 'per': 10, 'energy': 4},
  ];
  return c;
}

/// Answers the AI 跟练 endpoints; records uploads.
class CoachFake {
  CoachFake({this.catalogAvailable = true});

  /// false → `GET /v1/ai/workouts` answers 503 `ai_unavailable`.
  bool catalogAvailable;
  final uploads = <Map<String, dynamic>>[];

  (int, Object?)? handle(RequestOptions o) {
    final p = o.path, m = o.method.toUpperCase();
    if (p == '/v1/ai/workouts' && m == 'GET') {
      if (!catalogAvailable) {
        return (503, {'error': {'code': 'ai_unavailable', 'message': 'AI 服务暂不可用'}});
      }
      return (200, {'items': coachWorkoutsJson});
    }
    if (p == '/v1/config/gameplay') return (200, coachConfig());
    if (p == '/v1/activities' && m == 'POST') {
      final body = (o.data as Map).cast<String, dynamic>();
      uploads.add(body);
      final r = (jsonDecode(activityResultJson) as Map).cast<String, dynamic>();
      final act = (r['activity'] as Map).cast<String, dynamic>()
        ..['sport'] = body['sport']
        ..['amount'] = body['amount']
        ..['duration_s'] = body['duration_s']
        ..['started_at'] = body['started_at']
        ..['ended_at'] = body['ended_at']
        ..['distance_m'] = 0
        ..['track'] = null
        ..['claims'] = <Object>[]
        ..['status'] = 'settled';
      r['activity'] = act;
      r['settlement'] = {
        'status': 'settled',
        'energy_raw': 2,
        'energy_granted': 2,
        'energy_capped': false,
        'claims': <Object>[],
        'attacks': <Object>[],
        'recruits': <Object>[],
        'eggs': <Object>[],
        'medals': <Object>[],
      };
      return (200, r);
    }
    return null;
  }
}

/// Pose source driven by the test.
class FakePoseSource implements PoseSource {
  FakePoseSource({this.status = PoseSourceStatus.ready, this.preview = false});
  final PoseSourceStatus status;

  /// Show a stand-in "camera picture" (screenshots).
  final bool preview;
  final _c = StreamController<PoseFrame>.broadcast();
  bool started = false;
  bool disposed = false;

  void emit(PoseFrame f) {
    if (!_c.isClosed) _c.add(f);
  }

  @override
  Future<PoseSourceStatus> start() async {
    started = true;
    return status;
  }

  @override
  Stream<PoseFrame> get frames => _c.stream;

  @override
  Widget? buildPreview() => preview && status == PoseSourceStatus.ready
      ? const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF2A2833), Color(0xFF1A1A20), Color(0xFF24222A)],
            ),
          ),
        )
      : null;

  @override
  bool get mirrored => false;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _c.close();
  }
}
