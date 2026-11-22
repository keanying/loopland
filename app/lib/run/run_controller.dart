import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../api/models.dart';
import '../claim/claim.dart';
import '../claim/geo.dart';
import '../core/providers.dart';
import 'device.dart';
import 'location_source.dart';
import 'run_store.dart';
import 'uploader.dart';

final locationSourceProvider = Provider<LocationSource>((ref) => GeolocatorSource());

/// Injectable clock for tests.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

enum RunPhase { idle, countdown, running, paused, finished }

class RunConfig {
  const RunConfig({required this.sport, this.goal = const Goal(), this.guide});
  final String sport;
  final Goal goal;

  /// Optional route drawn as a guide line (AI 路线建议).
  final RunGuide? guide;
}

/// A suggested route shown while running: dashed line + target markers.
/// Only a visual aid — claiming rules do not change.
class RunGuide {
  const RunGuide({required this.title, this.path = const [], this.targets = const []});
  final String title;
  final List<LatLng> path;
  final List<GuideTarget> targets;
}

class GuideTarget {
  const GuideTarget({required this.name, required this.center, this.type = 'territory'});
  final String name;
  final LatLng center;

  /// `territory | boss | chest`.
  final String type;
}

/// Points worse than this are recorded (the server decides) but not used for
/// the local distance / loop preview.
const double kMaxPreviewAccuracyM = 40;

/// API limit on `points`.
const int kMaxPoints = 20000;

class RunState {
  const RunState({
    this.phase = RunPhase.idle,
    this.countdown = 0,
    this.sport = 'run',
    this.goal = const Goal(),
    this.clientId = '',
    this.startedAt,
    this.points = const [],
    this.activeMs = 0,
    this.resumedAt,
    this.distanceM = 0,
    this.loops = const [],
    this.hint,
    this.lastFix,
    this.mockDetected = false,
    this.tick = 0,
    this.minClaimAreaM2 = 500,
    this.guide,
  });

  final RunPhase phase;
  final int countdown;
  final String sport;
  final Goal goal;
  final String clientId;
  final DateTime? startedAt;

  /// Everything recorded (uploaded as-is).
  final List<TrackPoint> points;

  /// Active time accumulated before [resumedAt].
  final int activeMs;

  /// When the current running segment started (null while paused).
  final DateTime? resumedAt;
  final double distanceM;
  final List<Loop> loops;
  final ClosingHint? hint;
  final Fix? lastFix;
  final bool mockDetected;

  /// Bumped every second so the UI refreshes the clock.
  final int tick;
  final double minClaimAreaM2;

  /// Route guide chosen before the start (not persisted across restarts).
  final RunGuide? guide;

  int elapsedMs(DateTime now) =>
      activeMs + (resumedAt == null ? 0 : now.difference(resumedAt!).inMilliseconds.clamp(0, 1 << 40));

  double get claimedAreaM2 => loops.fold(0.0, (s, l) => s + l.areaM2);

  /// Average pace in s/km.
  double? paceSPerKm(DateTime now) => distanceM < 20 ? null : elapsedMs(now) / 1000 / (distanceM / 1000);

  List<LatLng> get track => [for (final p in points) p.latLng];

  LatLng? get position => lastFix == null ? null : LatLng(lastFix!.lat, lastFix!.lng);

  bool goalReached(DateTime now) => switch (goal.type) {
        'distance' => goal.value != null && distanceM >= goal.value!,
        'time' => goal.value != null && elapsedMs(now) / 1000 >= goal.value!,
        _ => false,
      };

  RunState copyWith({
    RunPhase? phase,
    int? countdown,
    String? sport,
    Goal? goal,
    String? clientId,
    DateTime? startedAt,
    List<TrackPoint>? points,
    int? activeMs,
    DateTime? Function()? resumedAt,
    double? distanceM,
    List<Loop>? loops,
    ClosingHint? Function()? hint,
    Fix? lastFix,
    bool? mockDetected,
    int? tick,
    double? minClaimAreaM2,
  }) =>
      RunState(
        phase: phase ?? this.phase,
        countdown: countdown ?? this.countdown,
        sport: sport ?? this.sport,
        goal: goal ?? this.goal,
        clientId: clientId ?? this.clientId,
        startedAt: startedAt ?? this.startedAt,
        points: points ?? this.points,
        activeMs: activeMs ?? this.activeMs,
        resumedAt: resumedAt != null ? resumedAt() : this.resumedAt,
        distanceM: distanceM ?? this.distanceM,
        loops: loops ?? this.loops,
        hint: hint != null ? hint() : this.hint,
        lastFix: lastFix ?? this.lastFix,
        mockDetected: mockDetected ?? this.mockDetected,
        tick: tick ?? this.tick,
        minClaimAreaM2: minClaimAreaM2 ?? this.minClaimAreaM2,
        guide: guide,
      );
}

final runControllerProvider = NotifierProvider<RunController, RunState>(RunController.new);

/// Records a GPS activity: countdown → running ⇄ paused → finished. Every
/// point feeds the local [ClaimTracker] for the in-run loop preview and the
/// "还差 X 米可闭合" hint, and the run is snapshotted to disk so it survives
/// the app being killed.
class RunController extends Notifier<RunState> {
  StreamSubscription<Fix>? _sub;
  Timer? _ticker;
  Timer? _countdown;
  ClaimTracker _tracker = ClaimTracker();
  LatLng? _lastGood;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  DateTime _now() => ref.read(clockProvider)();
  RunStore get _store => ref.read(runStoreProvider);

  @override
  RunState build() {
    ref.onDispose(_stopAll);
    return const RunState();
  }

  void _stopAll() {
    _sub?.cancel();
    _sub = null;
    _ticker?.cancel();
    _ticker = null;
    _countdown?.cancel();
    _countdown = null;
  }

  /// 3-2-1 countdown, then recording starts.
  void start(RunConfig cfg, {double minClaimAreaM2 = 500, int countdownFrom = 3}) {
    _stopAll();
    _tracker = ClaimTracker(ClaimOptions(minAreaM2: minClaimAreaM2));
    _lastGood = null;
    state = RunState(
      phase: RunPhase.countdown,
      countdown: countdownFrom,
      sport: cfg.sport,
      goal: cfg.goal,
      clientId: const Uuid().v4(),
      minClaimAreaM2: minClaimAreaM2,
      guide: cfg.guide,
    );
    if (countdownFrom <= 0) {
      _begin();
      return;
    }
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      final n = state.countdown - 1;
      if (n <= 0) {
        t.cancel();
        _begin();
      } else {
        state = state.copyWith(countdown: n);
      }
    });
  }

  void _begin() {
    final now = _now();
    state = state.copyWith(phase: RunPhase.running, countdown: 0, startedAt: now, resumedAt: () => now);
    _listen();
    _save(force: true);
  }

  void _listen() {
    _sub?.cancel();
    _sub = ref.read(locationSourceProvider).watch().listen(onFix, onError: (_) {});
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.phase == RunPhase.running) state = state.copyWith(tick: state.tick + 1);
    });
  }

  /// Feeds one location fix (public for tests).
  void onFix(Fix f) {
    if (state.phase != RunPhase.running) {
      if (state.phase == RunPhase.paused) state = state.copyWith(lastFix: f);
      return;
    }
    final t = f.time.millisecondsSinceEpoch;
    if (state.points.isNotEmpty && t <= state.points.last.t) return;
    final p = TrackPoint(
      t: t,
      lat: f.lat,
      lng: f.lng,
      acc: f.accuracy,
      spd: f.speed,
      src: f.mocked ? 'mock' : 'gps',
    );
    var distance = state.distanceM;
    var loops = state.loops;
    final good = f.accuracy == null || f.accuracy! <= kMaxPreviewAccuracyM;
    if (good) {
      final ll = LatLng(f.lat, f.lng);
      if (_lastGood != null) distance += haversine(_lastGood!, ll);
      _lastGood = ll;
      final closed = _tracker.add(ll);
      if (closed.isNotEmpty) loops = [...loops, ...closed];
    }
    state = state.copyWith(
      points: [...state.points, p],
      distanceM: distance,
      loops: loops,
      hint: () => _tracker.closingHint(),
      lastFix: f,
      mockDetected: state.mockDetected || f.mocked,
    );
    _save();
  }

  void pause() {
    if (state.phase != RunPhase.running) return;
    final now = _now();
    state = state.copyWith(phase: RunPhase.paused, activeMs: state.elapsedMs(now), resumedAt: () => null);
    _save(force: true);
  }

  void resume() {
    if (state.phase != RunPhase.paused) return;
    final now = _now();
    state = state.copyWith(phase: RunPhase.running, resumedAt: () => now);
    if (_sub == null) _listen();
    _save(force: true);
  }

  /// Rebuilds a run from a snapshot (paused), e.g. after the app was killed.
  void restore(RunSnapshot s, {double minClaimAreaM2 = 500}) {
    _stopAll();
    _tracker = ClaimTracker(ClaimOptions(minAreaM2: minClaimAreaM2));
    _lastGood = null;
    var distance = 0.0;
    for (final p in s.points) {
      if (p.acc != null && p.acc! > kMaxPreviewAccuracyM) continue;
      if (_lastGood != null) distance += haversine(_lastGood!, p.latLng);
      _lastGood = p.latLng;
      _tracker.add(p.latLng);
    }
    state = RunState(
      phase: RunPhase.paused,
      sport: s.sport,
      goal: s.goal,
      clientId: s.clientId,
      startedAt: s.startedAt,
      points: s.points,
      activeMs: s.activeMs,
      distanceM: distance,
      loops: _tracker.loops,
      hint: _tracker.closingHint(),
      mockDetected: s.points.any((p) => p.src == 'mock'),
      minClaimAreaM2: minClaimAreaM2,
    );
  }

  Future<void> _save({bool force = false}) async {
    final now = _now();
    if (!force && now.difference(_lastSave).inSeconds < 5) return;
    if (state.startedAt == null) return;
    _lastSave = now;
    try {
      await _store.saveInProgress(RunSnapshot(
        clientId: state.clientId,
        sport: state.sport,
        goal: state.goal,
        startedAt: state.startedAt!,
        points: state.points,
        activeMs: state.elapsedMs(now),
        savedAt: now,
      ));
    } catch (_) {
      // Disk errors must never stop the recording.
    }
  }

  /// Stops recording and returns the upload body; the activity is queued on
  /// disk before the in-progress snapshot is removed.
  Future<ActivityUpload> finish() async {
    final now = _now();
    final elapsed = state.elapsedMs(now);
    _stopAll();
    final deviceId = await ref.read(tokenStoreProvider).deviceId();
    final device = await collectDevice(deviceId);
    final upload = ActivityUpload(
      clientId: state.clientId,
      sport: state.sport,
      startedAt: state.startedAt ?? now,
      endedAt: now,
      durationS: (elapsed / 1000).round(),
      goal: state.goal,
      points: thinPoints(state.points),
      device: device,
    );
    // 本机保存失败（磁盘满、没有文件系统等）不能挡住结束：直接上传，失败时由页面提示
    try {
      await _store.savePending(PendingUpload(upload: upload));
      await _store.clearInProgress();
    } catch (_) {}
    state = state.copyWith(phase: RunPhase.finished, activeMs: elapsed, resumedAt: () => null);
    return upload;
  }

  Future<void> discard() async {
    _stopAll();
    await _store.clearInProgress();
    state = const RunState();
  }

  void reset() {
    _stopAll();
    state = const RunState();
  }
}

/// Keeps at most [kMaxPoints] points (evenly thinned, first and last kept).
List<TrackPoint> thinPoints(List<TrackPoint> pts, [int max = kMaxPoints]) {
  if (pts.length <= max) return pts;
  final step = pts.length / (max - 1);
  final out = <TrackPoint>[];
  for (var i = 0; i < max - 1; i++) {
    out.add(pts[(i * step).floor()]);
  }
  out.add(pts.last);
  return out;
}
