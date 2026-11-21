// AI 跟练 (C-09) against a live dev backend: the workout catalog the app
// parses, and home-workout uploads with the `coach` object (energy, and the
// coach_mismatch review rule).
//
//   LOOPLAND_LIVE_API=http://localhost:8080 flutter test integration_live
//
// Skipped when LOOPLAND_LIVE_API is not set.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/loopland_api.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/coach/coach_api.dart';
import 'package:loopland/coach/workout.dart';
import 'package:loopland/core/providers.dart';

void main() {
  final base = Platform.environment['LOOPLAND_LIVE_API'];
  final skip = base == null ? 'set LOOPLAND_LIVE_API to run' : false;
  final rnd = math.Random().nextInt(90000000) + 10000000;

  ActivityUpload workout(String sport, num amount, int minutes, CoachReport coach, {String device = 'coach-live'}) {
    final end = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    return ActivityUpload(
      clientId: const Uuid().v4(),
      sport: sport,
      startedAt: end.subtract(Duration(minutes: minutes)),
      endedAt: end,
      durationS: minutes * 60,
      amount: amount,
      device: DeviceInfo(id: '$device-$rnd', model: 'live-test', os: 'test'),
      coach: coach.toJson(),
    );
  }

  test('catalog + uploads with coach against the live backend', () async {
    final c = ApiClient(tokens: MemoryTokenStore(), baseUrl: base, platform: 'android');
    final a = LooplandApi(c);
    final phone = '135$rnd';
    await a.sendSms(phone);
    await a.login('sms', {'phone': phone, 'code': '000000'});
    await a.setConsents(privacyVersion: '2026-11', location: true, health: true);

    // The catalog through the app's provider (falls back to built-in on 503).
    final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(c)]);
    addTearDown(container.dispose);
    final cat = await container.read(workoutCatalogProvider.future);
    expect(cat.builtin, isFalse, reason: 'server catalog expected');
    expect(cat.items.map((w) => w.sport).toSet(), containsAll(['rope', 'hiit', 'yoga', 'strength']));
    for (final w in cat.items) {
      expect(w.steps, isNotEmpty);
      for (final s in w.steps) {
        expect(['jump', 'squat', 'pushup', 'crunch', 'none'], contains(s.pose));
        expect(['count', 'time'], contains(s.mode));
      }
    }
    final rope = cat.byKey('rope_basic')!;
    expect(rope.usesCamera, isTrue);
    // The built-in fallback mirrors the server defaults.
    for (final b in builtinWorkouts) {
      final s = cat.byKey(b.key);
      if (s == null) continue; // edited in 玩法配置
      expect(b.steps.map((x) => '${x.key}/${x.mode}/${x.target}/${x.sets}/${x.pose}'),
          s.steps.map((x) => '${x.key}/${x.mode}/${x.target}/${x.sets}/${x.pose}'),
          reason: b.key);
    }

    // Rope by count, camera agrees → settled, energy granted.
    final r1 = await a.uploadActivity(workout(
        'rope', 480, 12, const CoachReport(workoutKey: 'rope_basic', camera: true, repsDetected: 470, repsManual: 10, setsDone: 5)));
    expect(r1.settlement.status, 'settled');
    expect(r1.settlement.energyGranted, greaterThan(0));
    expect(r1.settlement.claims, isEmpty);

    // HIIT by minutes with a camera count.
    final r2 = await a.uploadActivity(workout(
        'hiit', 16, 16, const CoachReport(workoutKey: 'hiit_burn', camera: true, repsDetected: 120, repsManual: 0, setsDone: 12)));
    expect(r2.settlement.status, 'settled');
    expect(r2.settlement.energyGranted, greaterThan(0));

    // Reported far above what the camera saw → coach_mismatch review.
    final r3 = await a.uploadActivity(workout(
        'rope', 300, 10, const CoachReport(workoutKey: 'rope_basic', camera: true, repsDetected: 100, repsManual: 200, setsDone: 3)));
    expect(r3.settlement.status, 'review');

    // No camera (manual only) → no mismatch rule.
    final r4 = await a.uploadActivity(workout(
        'rope', 200, 8, const CoachReport(workoutKey: 'rope_basic', camera: false, repsDetected: 0, repsManual: 200, setsDone: 2)));
    expect(r4.settlement.status, isNot('voided'));
  }, skip: skip);
}
