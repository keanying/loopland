import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/claim/geo.dart';
import 'package:loopland/core/providers.dart';
import 'package:loopland/run/location_source.dart';
import 'package:loopland/run/run_controller.dart';
import 'package:loopland/run/run_store.dart';
import 'package:loopland/run/uploader.dart';

const origin = LatLng(31.2304, 121.4737);

void main() {
  late Directory dir;
  late DateTime now;
  late ProviderContainer c;
  late RunStore store;

  Fix fix(double x, double y, int sec, {double acc = 5, bool mocked = false}) {
    final ll = Projection(origin).inverse(Point(x, y));
    return Fix(time: DateTime.utc(2026, 11, 20, 12).add(Duration(seconds: sec)), lat: ll.lat, lng: ll.lng, accuracy: acc, mocked: mocked);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ll_run');
    store = RunStore(directory: () async => dir);
    now = DateTime.utc(2026, 11, 20, 12);
    c = ProviderContainer(overrides: [
      clockProvider.overrideWithValue(() => now),
      runStoreProvider.overrideWithValue(store),
      tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      locationSourceProvider.overrideWithValue(FakeLocationSource()),
    ]);
  });

  tearDown(() async {
    c.dispose();
    await dir.delete(recursive: true);
  });

  test('records points, previews loops and the closing hint, excludes paused time', () async {
    final ctrl = c.read(runControllerProvider.notifier);
    ctrl.start(const RunConfig(sport: 'run'), countdownFrom: 0);
    expect(c.read(runControllerProvider).phase, RunPhase.running);

    ctrl.onFix(fix(0, 0, 0));
    ctrl.onFix(fix(100, 0, 30));
    ctrl.onFix(fix(100, 100, 60));
    var s = c.read(runControllerProvider);
    expect(s.loops, isEmpty);
    // Right after the corner the nearest closable point is part-way along
    // the first leg, not straight back down the leg just run.
    expect(s.hint, isNotNull);
    expect(s.hint!.distanceM, closeTo(113.3, 1));

    ctrl.onFix(fix(50, 100, 90));
    s = c.read(runControllerProvider);
    expect(s.hint, isNotNull);
    expect(s.hint!.distanceM, closeTo(100, 1)); // back to the first leg

    ctrl.onFix(fix(50, -50, 120)); // crosses the first leg → loop
    s = c.read(runControllerProvider);
    expect(s.loops, hasLength(1));
    expect(s.claimedAreaM2, closeTo(5000, 1));
    expect(s.distanceM, closeTo(400, 2));
    expect(s.points, hasLength(5));

    now = now.add(const Duration(minutes: 2));
    ctrl.pause();
    ctrl.onFix(fix(500, 500, 200)); // ignored while paused
    now = now.add(const Duration(minutes: 10));
    ctrl.resume();
    now = now.add(const Duration(minutes: 1));
    s = c.read(runControllerProvider);
    expect(s.points, hasLength(5));
    expect(s.elapsedMs(now), 3 * 60 * 1000);

    final up = await ctrl.finish();
    expect(up.durationS, 180);
    expect(up.points, hasLength(5));
    expect(up.sport, 'run');
    expect(await store.loadInProgress(), isNull);
    final pending = await store.pending();
    expect(pending.single.upload.clientId, up.clientId);
  });

  test('mock locations are tagged src=mock; out-of-order and noisy fixes handled', () async {
    final ctrl = c.read(runControllerProvider.notifier);
    ctrl.start(const RunConfig(sport: 'walk'), countdownFrom: 0);
    ctrl.onFix(fix(0, 0, 10, mocked: true));
    ctrl.onFix(fix(5, 0, 5)); // older timestamp → dropped
    ctrl.onFix(fix(80, 0, 20, acc: 120)); // recorded, but not used for distance
    final s = c.read(runControllerProvider);
    expect(s.points.map((p) => p.src), ['mock', 'gps']);
    expect(s.mockDetected, isTrue);
    expect(s.distanceM, 0);
  });

  test('snapshot survives a restart and restores as paused', () async {
    final ctrl = c.read(runControllerProvider.notifier);
    ctrl.start(const RunConfig(sport: 'run', goal: Goal(type: 'distance', value: 5000)), countdownFrom: 0);
    for (final (i, p) in [[0.0, 0.0], [100.0, 0.0], [100.0, 100.0], [50.0, 100.0], [50.0, -50.0]].indexed) {
      ctrl.onFix(fix(p[0], p[1], i * 30));
    }
    now = now.add(const Duration(minutes: 5));
    ctrl.pause(); // forces a snapshot
    // The snapshot is written asynchronously (temp file + rename).
    RunSnapshot? snap;
    for (var i = 0; i < 250 && snap == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      snap = await store.loadInProgress();
    }
    expect(snap, isNotNull);
    expect(snap!.points, hasLength(5));
    expect(snap.goal.type, 'distance');

    ctrl.reset();
    ctrl.restore(snap);
    final s = c.read(runControllerProvider);
    expect(s.phase, RunPhase.paused);
    expect(s.loops, hasLength(1));
    expect(s.clientId, snap.clientId);
    expect(s.activeMs, 5 * 60 * 1000);
  });

  test('thinPoints keeps first/last and the limit', () {
    final pts = [for (var i = 0; i < 25000; i++) TrackPoint(t: i, lat: 0, lng: 0)];
    final out = thinPoints(pts);
    expect(out, hasLength(kMaxPoints));
    expect(out.first.t, 0);
    expect(out.last.t, 24999);
    for (var i = 1; i < out.length; i++) {
      expect(out[i].t, greaterThan(out[i - 1].t));
    }
  });
}
