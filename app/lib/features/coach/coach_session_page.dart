import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../api/errors.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../coach/coach_api.dart';
import '../../coach/coach_session.dart';
import '../../coach/pose.dart';
import '../../coach/pose_source.dart';
import '../../coach/rep_counter.dart';
import '../../coach/tracking.dart';
import '../../coach/voice.dart';
import '../../coach/workout.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../run/device.dart';
import '../../run/run_controller.dart' show clockProvider;
import '../../run/uploader.dart';
import '../../widgets/common.dart';
import '../run/result_page.dart';
import 'skeleton_painter.dart';

/// `/coach/:key` — finds the workout (passed as `extra`, or in the catalog).
class CoachSessionPage extends ConsumerWidget {
  const CoachSessionPage({super.key, required this.workoutKey, this.workout});
  final String workoutKey;
  final Workout? workout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (workout != null) return CoachSessionView(workout: workout!);
    final cat = ref.watch(workoutCatalogProvider);
    return cat.when(
      data: (c) {
        final w = c.byKey(workoutKey);
        if (w != null) return CoachSessionView(workout: w);
        return Scaffold(
          body: SafeArea(
            child: Column(children: [
              const BackHeader(title: 'AI 跟练'),
              const Expanded(child: Center(child: Text('这个课程已下架', style: TextStyle(color: LL.text2)))),
            ]),
          ),
        );
      },
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: ErrorBox(error: e, onRetry: () => ref.invalidate(workoutCatalogProvider))),
    );
  }
}

/// Camera / counting mode of the session.
enum CountMode {
  /// Camera + pose detection count the reps.
  auto,

  /// Tap +1 (no camera, permission refused, unstable tracking, or chosen).
  manual,
}

/// AI 跟练 session (design 11_AI_跟练): camera card with the skeleton overlay
/// and the rep count, hint bubble, bottom sheet with elapsed time, the big
/// countdown / count, sets, start / pause and the energy estimate.
class CoachSessionView extends ConsumerStatefulWidget {
  const CoachSessionView({super.key, required this.workout});
  final Workout workout;
  @override
  ConsumerState<CoachSessionView> createState() => _CoachSessionViewState();
}

class _CoachSessionViewState extends ConsumerState<CoachSessionView> with WidgetsBindingObserver {
  late final CoachSession _s;
  PoseSource? _source;
  StreamSubscription<PoseFrame>? _sub;

  /// null while the camera is starting (or not wanted).
  PoseSourceStatus? _camStatus;
  bool _camStarting = false;
  CountMode _mode = CountMode.manual;
  String? _fallbackReason;
  bool _cameraUsed = false;
  final _monitor = TrackingMonitor();
  RepCounter _counter = NoneCounter();
  int _serial = -1;
  PoseFrame? _frame;
  Timer? _timer;
  DateTime? _startedAt;
  bool _busy = false;
  bool _backgrounded = false;
  late final VoiceCoach _voice;

  /// Latest spoken sentence (not the 3-2-1 digits), for the hint bubble.
  String? _cueText;

  Workout get w => widget.workout;
  int _nowMs() => ref.read(clockProvider)().millisecondsSinceEpoch;

  bool get _wantCamera => w.usesCamera;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _voice = ref.read(voiceCoachProvider);
    _s = CoachSession(w, onCue: _onCue)..addListener(_onSession);
    _counter = RepCounter.forPose(_s.step.pose);
    if (_wantCamera) _startCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _s.removeListener(_onSession);
    _s.dispose();
    _stopCamera();
    _voice.stop().ignore();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the camera in the background (and pause): nothing is recorded
    // while the app is not visible.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (_backgrounded) return;
      _backgrounded = true;
      _s.pause(_nowMs());
      if (_source != null) _stopCamera();
    } else if (state == AppLifecycleState.resumed && _backgrounded) {
      _backgrounded = false;
      if (_wantCamera && _camStatus == PoseSourceStatus.ready) _startCamera();
    }
  }

  // ── camera ──

  Future<void> _startCamera() async {
    if (_camStarting) return;
    _camStarting = true;
    final src = ref.read(poseSourceFactoryProvider)();
    _source = src;
    setState(() => _camStatus = null);
    final st = await src.start();
    _camStarting = false;
    if (!mounted || _source != src) {
      await src.dispose();
      return;
    }
    setState(() {
      _camStatus = st;
      if (st == PoseSourceStatus.ready) {
        _sub = src.frames.listen(_onFrame);
        _mode = _fallbackReason == null ? CountMode.auto : _mode;
        _monitor.restart(_nowMs());
      } else {
        _mode = CountMode.manual;
      }
    });
  }

  void _stopCamera() {
    _sub?.cancel();
    _sub = null;
    final src = _source;
    _source = null;
    _frame = null;
    src?.dispose().ignore();
  }

  void _onFrame(PoseFrame f) {
    if (!mounted) return;
    final now = _nowMs();
    final visible = _counter.visible(f);
    _monitor.add(f, visible: visible, atMs: now);
    if (_mode == CountMode.auto && _s.phase == CoachPhase.work && !_s.paused && _s.step.countable) {
      _cameraUsed = true;
      final n = _counter.add(f);
      if (n > 0) _s.addReps(n, manual: false);
    }
    setState(() => _frame = f);
  }

  // ── session ──

  void _onSession() {
    if (_s.workSerial != _serial) {
      _serial = _s.workSerial;
      _counter = RepCounter.forPose(_s.step.pose);
      _monitor.restart(_nowMs());
    }
    if (_s.phase == CoachPhase.done) {
      _timer?.cancel();
      // Nothing left to count: turn the camera off right away.
      if (_source != null) _stopCamera();
    }
    if (mounted) setState(() {});
  }

  void _onCue(CoachCue c) {
    if (c.kind != CueKind.countdown) _cueText = c.text;
    if (!mounted || ref.read(voiceMutedProvider)) return;
    _voice.speak(c.text).ignore();
  }

  void _tick() {
    final now = _nowMs();
    _s.tick(now);
    // Fall back to manual counting when tracking is unusable during a set.
    if (_mode == CountMode.auto && _s.phase == CoachPhase.work && !_s.paused && _s.step.countable) {
      final why = _monitor.unstableReason(now);
      if (why != null) {
        setState(() {
          _mode = CountMode.manual;
          _fallbackReason = why;
        });
        toast(context, '$why，已切换为手动计数');
      }
    }
  }

  void _toggle() {
    final now = _nowMs();
    switch (_s.phase) {
      case CoachPhase.ready:
        _startedAt = ref.read(clockProvider)();
        _s.start(now);
        _timer = Timer.periodic(const Duration(milliseconds: 200), (_) => _tick());
      case CoachPhase.done:
        _claim();
      default:
        _s.paused ? _s.resume(now) : _s.pause(now);
    }
  }

  void _manual(int n) {
    if (_s.phase != CoachPhase.work) return;
    _s.addReps(n, manual: true);
  }

  void _setMode(CountMode m) {
    if (m == CountMode.auto && _camStatus != PoseSourceStatus.ready) {
      _startCamera();
      return;
    }
    setState(() {
      _mode = m;
      if (m == CountMode.auto) {
        _fallbackReason = null;
        _counter.reset();
        _monitor.restart(_nowMs());
      }
    });
  }

  Future<bool> _confirmLeave() async {
    if (_s.phase == CoachPhase.ready || _s.phase == CoachPhase.done) return true;
    final wasPaused = _s.paused;
    _s.pause(_nowMs());
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('结束训练？'),
        content: const Text('结束后可以按已完成的部分领取能量。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'quit'), child: const Text('放弃')),
          TextButton(onPressed: () => Navigator.pop(c, 'finish'), child: const Text('结束并结算')),
          FilledButton(onPressed: () => Navigator.pop(c), child: const Text('继续训练')),
        ],
      ),
    );
    if (r == 'quit') return true;
    if (r == 'finish') {
      _s.finish(_nowMs());
      return false;
    }
    if (!wasPaused) _s.resume(_nowMs());
    return false;
  }

  // ── upload ──

  /// Rope is settled by count, the others by minutes (as manual home
  /// training, docs/api/v1.md).
  num get _amount => w.sport == 'rope' ? _s.totalReps : (_s.elapsedMs / 60000).floor();

  int _estimate(GameConfig? cfg) {
    final r = cfg?.energyFor(w.sport);
    if (r == null || r.per == 0) return 0;
    return (_amount / r.per * r.energy).floor();
  }

  int get _kcal {
    const met = {'rope': 11.0, 'hiit': 8.0, 'yoga': 3.0, 'strength': 5.0};
    return ((met[w.sport] ?? 5) * 60 * _s.elapsedMs / 3600000).round();
  }

  Future<void> _claim() async {
    if (_amount <= 0) {
      toast(context, w.sport == 'rope' ? '还没有计数哦' : '至少训练 1 分钟才能换能量');
      return;
    }
    setState(() => _busy = true);
    final now = ref.read(clockProvider)();
    final deviceId = await ref.read(tokenStoreProvider).deviceId();
    final upload = ActivityUpload(
      clientId: const Uuid().v4(),
      sport: w.sport,
      startedAt: _startedAt ?? now,
      endedAt: now,
      durationS: (_s.elapsedMs / 1000).round(),
      amount: _amount,
      device: await collectDevice(deviceId),
      coach: CoachReport(
        workoutKey: w.key,
        camera: _cameraUsed,
        repsDetected: _s.repsDetected,
        repsManual: _s.repsManual,
        setsDone: _s.setsDone,
      ).toJson(),
    );
    try {
      final r = await ref.read(uploaderProvider).submit(upload);
      ref.read(authProvider.notifier).refreshUser().ignore();
      if (mounted) context.go('/result', extra: ResultArgs(result: r));
    } catch (e) {
      if (!mounted) return;
      toast(context, '${ApiException.from(e).message}。记录已保存，稍后自动上传');
      context.go('/me');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(configProvider).value;
    final muted = ref.watch(voiceMutedProvider);
    return PopScope(
      canPop: _s.phase == CoachPhase.ready || _s.phase == CoachPhase.done,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            _header(muted),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: _s.phase == CoachPhase.done ? _summary(cfg) : _cameraCard(),
              ),
            ),
            _sheet(cfg),
          ]),
        ),
      ),
    );
  }

  Widget _header(bool muted) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Row(children: [
        RoundIconButton(icon: Icons.arrow_back_ios_new_rounded, onTap: () => Navigator.of(context).maybePop()),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('AI 跟练', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            Text('${w.name} · ${w.levelName}', style: const TextStyle(color: LL.text2, fontSize: 12)),
          ]),
        ),
        RoundIconButton(
          icon: muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          size: 40,
          tooltip: muted ? '语音提示已关闭' : '语音提示',
          onTap: () {
            ref.read(voiceMutedProvider.notifier).toggle();
            if (!muted) _voice.stop().ignore();
          },
        ),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('$_kcal', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const Text('千卡', style: TextStyle(color: LL.text2, fontSize: 11)),
        ]),
      ]),
    );
  }

  bool get _autoCounting =>
      _mode == CountMode.auto && _camStatus == PoseSourceStatus.ready && _s.step.countable;

  TrackingState get _tracking => _monitor.stateAt(_nowMs());

  (Color, String) get _status {
    if (!_wantCamera) return (LL.text3, '计时模式');
    switch (_camStatus) {
      case null:
        return (LL.orange, '正在打开摄像头…');
      case PoseSourceStatus.denied:
        return (LL.red, '未获得摄像头权限 · 手动计数');
      case PoseSourceStatus.unavailable:
        return (LL.text3, '没有可用的摄像头 · 手动计数');
      case PoseSourceStatus.error:
        return (LL.red, '摄像头打开失败 · 手动计数');
      case PoseSourceStatus.ready:
        break;
    }
    if (_s.phase == CoachPhase.done) return (LL.lavender, '训练完成');
    if (_mode == CountMode.manual) return (LL.orange, '${_fallbackReason ?? '手动计数'} · 点此恢复自动');
    if (!_s.step.countable && _s.phase == CoachPhase.work) return (LL.lime, '${_s.step.name} · 计时中');
    final tr = _tracking;
    if (tr == TrackingState.partial) return (LL.orange, '未检测到全身');
    if (tr == TrackingState.noPerson || tr == TrackingState.waiting) return (LL.orange, '摄像头已就绪');
    if (_s.phase == CoachPhase.work && !_s.paused) return (LL.lime, '${sportTab(w.sport)} · AI 计数中');
    return (LL.lime, '已识别到你');
  }

  String get _hint {
    if (_s.paused) return '已暂停，休息一下，准备好再继续';
    final working = _s.phase == CoachPhase.work || _s.phase == CoachPhase.prepare || _s.phase == CoachPhase.ready;
    if (_autoCounting && working) {
      final tr = _tracking;
      if (_monitor.lowLight) return '光线有点暗，打开灯识别更准';
      if (tr == TrackingState.partial) return '全身入镜：${_counter.framingHint}';
      if (tr == TrackingState.noPerson && _s.phase != CoachPhase.ready) return '没看到你，站到画面中间';
    }
    if (_s.phase == CoachPhase.work && _showManualPad && _fallbackReason != null) {
      return '$_fallbackReason，已改为手动计数：做完一下点一次 +1';
    }
    final cue = _cueText;
    if (cue != null) return cue;
    if (_s.phase == CoachPhase.ready) {
      if (_wantCamera && _camStatus == PoseSourceStatus.ready) return '把手机立在 2 米外，全身入镜后点开始';
      if (_camStatus == PoseSourceStatus.denied) return '没有摄像头权限也能练：跟着计时，做完一下点一次 +1';
      return '跟着计时练，做完一下点一次 +1';
    }
    return _s.step.cue;
  }

  Widget _cameraCard() {
    final preview = _source?.buildPreview();
    final (dot, statusText) = _status;
    final showFigure = preview == null && _frame == null;
    final count = _s.phase == CoachPhase.work || _s.phase == CoachPhase.rest ? _s.setReps : 0;
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF16161B), borderRadius: BorderRadius.circular(32)),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        const Positioned.fill(child: CustomPaint(painter: CoachGridPainter())),
        if (preview != null) Positioned.fill(child: Opacity(opacity: 0.85, child: preview)),
        Positioned.fill(
          child: CustomPaint(
            key: const Key('coach-skeleton'),
            painter: SkeletonPainter(
              frame: showFigure ? standingFrame() : _frame,
              mirrored: !showFigure && (_source?.mirrored ?? false),
              opacity: showFigure ? 0.35 : 1,
            ),
          ),
        ),
        // status chip
        Positioned(
          left: 16,
          top: 16,
          right: 76,
          child: Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: _mode == CountMode.manual && _wantCamera && _s.phase != CoachPhase.done
                  ? () => _setMode(CountMode.auto)
                  : null,
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(color: const Color(0xD90E0E10), borderRadius: BorderRadius.circular(15)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Flexible(child: Text(statusText, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
                ]),
              ),
            ),
          ),
        ),
        // big count
        if (_s.step.isCount || _s.step.countable)
          Positioned(
            left: 16,
            top: 54,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$count',
                  key: const Key('coach-count'),
                  style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w900, height: 1.05)),
              Text(_autoCounting ? '个 · AI 自动计数' : '个 · 手动计数', style: const TextStyle(color: LL.text2, fontSize: 12)),
            ]),
          ),
        // sets of the step
        Positioned(right: 14, top: 16, child: _SetBars(total: _s.step.sets, done: _setsDoneOfStep, current: _s.setIndex)),
        if (_s.phase == CoachPhase.rest) Positioned.fill(child: _restOverlay()),
        if (_s.phase == CoachPhase.prepare)
          Positioned.fill(
            child: Center(
              child: Text('${(_s.remainingMs / 1000).ceil()}',
                  style: const TextStyle(fontSize: 120, fontWeight: FontWeight.w900, color: LL.lime)),
            ),
          ),
        Positioned(
          left: 14,
          right: 14,
          bottom: 14,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_showManualPad) ...[_manualPad(), const SizedBox(height: 10)],
            _HintBubble(text: _hint),
            const SizedBox(height: 6),
            const Text('姿态识别在手机本地完成，画面不上传、不保存',
                style: TextStyle(color: LL.text3, fontSize: 11), textAlign: TextAlign.center),
          ]),
        ),
      ]),
    );
  }

  /// Sets of the current step already completed (for the bars).
  int get _setsDoneOfStep => _s.phase == CoachPhase.done ? _s.step.sets : _s.setIndex;

  bool get _showManualPad =>
      _s.phase == CoachPhase.work && !_s.paused && _s.step.isCount && !_autoCounting;

  Widget _manualPad() {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _PadButton(label: '-1', onTap: _s.repsManual > 0 && _s.setReps > 0 ? () => _manual(-1) : null),
      const SizedBox(width: 14),
      Material(
        color: LL.lime,
        shape: const CircleBorder(),
        child: InkWell(
          key: const Key('coach-plus1'),
          customBorder: const CircleBorder(),
          onTap: () => _manual(1),
          child: const SizedBox(
            width: 84,
            height: 84,
            child: Center(child: Text('+1', style: TextStyle(color: LL.ink, fontSize: 30, fontWeight: FontWeight.w900))),
          ),
        ),
      ),
      const SizedBox(width: 14),
      _PadButton(label: '+10', onTap: () => _manual(10)),
    ]);
  }

  Widget _restOverlay() {
    return Container(
      color: const Color(0xCC0E0E10),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('休息一下', style: TextStyle(color: LL.text2, fontSize: 16)),
          Text(Fmt.duration((_s.remainingMs / 1000).ceilToDouble()),
              style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w900, color: LL.lavender)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: LL.card2, borderRadius: BorderRadius.circular(16)),
            child: Text('下一个：${_s.nextPreview}', style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 14),
          OutlinedButton(onPressed: () => _s.skipRest(_nowMs()), child: const Text('跳过休息')),
        ]),
      ),
    );
  }

  Widget _summary(GameConfig? cfg) {
    final rule = cfg?.energyFor(w.sport);
    return Container(
      key: const Key('coach-summary'),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(color: const Color(0xFF16161B), borderRadius: BorderRadius.circular(32)),
      child: ListView(children: [
        const Icon(Icons.emoji_events_rounded, color: LL.yellow, size: 44),
        const SizedBox(height: 8),
        Text(_s.setsDone == 0 ? '训练结束' : '训练完成！',
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
        Text(w.name, textAlign: TextAlign.center, style: const TextStyle(color: LL.text2)),
        const SizedBox(height: 18),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.1,
          children: [
            StatBox(label: '用时', value: Fmt.duration(_s.elapsedMs / 1000)),
            StatBox(label: '完成组数', value: '${_s.setsDone}/${w.totalSets}'),
            StatBox(label: 'AI 自动计数', value: '${_s.repsDetected} 次'),
            StatBox(label: '手动计数', value: '${_s.repsManual} 次'),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          rule == null ? '居家训练只换能量，不圈地' : '${rule.text}。居家训练只换能量，不圈地',
          textAlign: TextAlign.center,
          style: const TextStyle(color: LL.text3, fontSize: 12),
        ),
        // Server rule coach_mismatch: reported > detected × 1.2 → review.
        if (_cameraUsed && _s.totalReps - _s.repsDetected >= 5 && _s.totalReps > _s.repsDetected * 1.2)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('手动补记的次数明显多于自动识别时，记录可能进入人工复核',
                textAlign: TextAlign.center, style: TextStyle(color: LL.text3, fontSize: 12)),
          ),
      ]),
    );
  }

  Widget _sheet(GameConfig? cfg) {
    final done = _s.phase == CoachPhase.done;
    final s = _s;
    String big;
    String bigLabel;
    switch (s.phase) {
      case CoachPhase.ready:
        big = s.step.isTime ? Fmt.duration(s.step.target.toDouble()) : '${s.step.target}';
        bigLabel = s.step.isTime ? s.step.name : '${s.step.name} · 目标次数';
      case CoachPhase.prepare:
        big = Fmt.duration((s.remainingMs / 1000).ceilToDouble());
        bigLabel = '准备';
      case CoachPhase.work:
        big = s.step.isTime ? Fmt.duration((s.remainingMs / 1000).ceilToDouble()) : '${s.setReps}/${s.step.target}';
        bigLabel = s.step.name;
      case CoachPhase.rest:
        big = Fmt.duration((s.remainingMs / 1000).ceilToDouble());
        bigLabel = '休息';
      case CoachPhase.done:
        big = '${s.setsDone}/${w.totalSets}';
        bigLabel = '完成组数';
    }
    const ink = LL.ink;
    const sub = Color(0xFF55555E);
    final (label, icon) = switch (s.phase) {
      CoachPhase.ready => ('开始', Icons.play_arrow_rounded),
      CoachPhase.done => ('领取能量', Icons.bolt_rounded),
      _ => s.paused ? ('继续', Icons.play_arrow_rounded) : ('暂停', Icons.pause_rounded),
    };
    final pausedLook = s.started && !done && !s.paused;
    return Container(
      padding: EdgeInsets.fromLTRB(24, 10, 24, 14 + MediaQuery.paddingOf(context).bottom),
      decoration: const BoxDecoration(
        color: LL.text,
        borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: ink),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFC9C9D1), borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('已用时', style: TextStyle(fontSize: 12, color: sub)),
              Text(Fmt.duration(s.elapsedMs / 1000),
                  key: const Key('coach-elapsed'),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
            ]),
            Expanded(
              child: Column(children: [
                FittedBox(
                  child: Text(big,
                      key: const Key('coach-big'),
                      style: const TextStyle(
                          fontSize: 40, fontWeight: FontWeight.w900, height: 1.1, fontFeatures: [FontFeature.tabularFigures()])),
                ),
                Text(bigLabel, style: const TextStyle(fontSize: 12, color: sub), overflow: TextOverflow.ellipsis),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              const Text('组数', style: TextStyle(fontSize: 12, color: sub)),
              Text(done ? '${s.step.sets}/${s.step.sets}' : '${s.setNumber}/${s.step.sets}',
                  key: const Key('coach-sets'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ]),
          ]),
          if (s.phase == CoachPhase.work || s.phase == CoachPhase.prepare) ...[
            const SizedBox(height: 6),
            Text('下一个：${s.nextPreview}', style: const TextStyle(fontSize: 12, color: sub), overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 50,
                child: FilledButton.icon(
                  key: const Key('coach-main'),
                  style: FilledButton.styleFrom(
                    backgroundColor: pausedLook ? LL.lavender : ink,
                    foregroundColor: pausedLook ? ink : LL.lime,
                    shape: const StadiumBorder(),
                  ),
                  onPressed: _busy ? null : _toggle,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(icon),
                  label: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Container(
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(25)),
              child: Row(children: [
                const Icon(Icons.bolt_rounded, color: LL.yellow, size: 18),
                Text('+${_estimate(cfg)}',
                    key: const Key('coach-energy'),
                    style: const TextStyle(color: LL.yellow, fontWeight: FontWeight.w800, fontSize: 14)),
              ]),
            ),
          ]),
          if (s.started && !done)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                if (s.phase == CoachPhase.work && (s.step.isCount || !s.isLastStep))
                  _SheetLink(
                    label: s.step.isCount ? '完成本组' : '提前完成',
                    onTap: () => _s.completeSet(_nowMs()),
                  ),
                _SheetLink(label: '跳过动作', onTap: () => _s.skipStep(_nowMs())),
                _SheetLink(label: '结束训练', onTap: () => _s.finish(_nowMs())),
                if (_wantCamera && _camStatus == PoseSourceStatus.ready && s.step.countable)
                  _SheetLink(
                    label: _mode == CountMode.auto ? '改为手动' : '自动计数',
                    onTap: () => _setMode(_mode == CountMode.auto ? CountMode.manual : CountMode.auto),
                  ),
              ]),
            ),
          if (done)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _SheetLink(label: '不领取，返回', onTap: () => context.pop()),
            ),
        ]),
      ),
    );
  }
}

/// Tab label of a home sport (design: 跳绳 / HIIT / 普拉提).
String sportTab(String sport) => switch (sport) {
      'rope' => '跳绳',
      'hiit' => 'HIIT',
      'yoga' => '普拉提',
      'strength' => '力量',
      _ => sportName(sport),
    };

class _HintBubble extends StatelessWidget {
  const _HintBubble({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('coach-hint'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF26223A),
        border: Border.all(color: LL.lavender),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(children: [
        Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(11)),
          child: const Text('AI', style: TextStyle(color: LL.ink, fontSize: 11, fontWeight: FontWeight.w900)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.4, color: Color(0xFFE2DCFB)))),
      ]),
    );
  }
}

class _SetBars extends StatelessWidget {
  const _SetBars({required this.total, required this.done, required this.current});
  final int total, done, current;
  @override
  Widget build(BuildContext context) {
    final n = total.clamp(1, 8);
    return Semantics(
      label: '已完成 $done 组，共 $total 组',
      child: Container(
        width: 44,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(color: LL.text, borderRadius: BorderRadius.circular(22)),
        child: Column(children: [
          for (var i = 0; i < n; i++)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              width: 26,
              height: 10,
              decoration: BoxDecoration(
                color: i < done ? LL.lavender : (i == current ? LL.ink : const Color(0xFFD6D6DD)),
                borderRadius: BorderRadius.circular(5),
              ),
            ),
        ]),
      ),
    );
  }
}

class _PadButton extends StatelessWidget {
  const _PadButton({required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: LL.card2,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 56,
            height: 56,
            child: Center(
              child: Text(label,
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: onTap == null ? LL.text3 : LL.text)),
            ),
          ),
        ),
      );
}

class _SheetLink extends StatelessWidget {
  const _SheetLink({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(foregroundColor: const Color(0xFF3A3A44), padding: const EdgeInsets.symmetric(horizontal: 8)),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
      );
}
