import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../api/errors.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../run/device.dart';
import '../../run/run_controller.dart';
import '../../run/uploader.dart';
import '../../widgets/common.dart';
import 'result_page.dart';

/// 居家训练：力量 / 瑜伽 / HIIT 计时，跳绳计数。完成后按时长或次数换能量。
class HomeTrainingPage extends ConsumerStatefulWidget {
  const HomeTrainingPage({super.key, required this.sport});
  final String sport;
  @override
  ConsumerState<HomeTrainingPage> createState() => _HomeTrainingPageState();
}

class _HomeTrainingPageState extends ConsumerState<HomeTrainingPage> {
  Timer? _timer;
  DateTime? _startedAt;
  DateTime? _resumedAt;
  int _accMs = 0;
  int _count = 0;
  bool _busy = false;

  bool get _counter => widget.sport == 'rope';
  bool get _running => _resumedAt != null;

  DateTime _now() => ref.read(clockProvider)();

  int get _elapsedMs => _accMs + (_resumedAt == null ? 0 : _now().difference(_resumedAt!).inMilliseconds);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      if (_running) {
        _accMs = _elapsedMs;
        _resumedAt = null;
        _timer?.cancel();
      } else {
        _startedAt ??= _now();
        _resumedAt = _now();
        _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
      }
    });
  }

  num get _amount => _counter ? _count : (_elapsedMs / 60000).floor();

  int _estimate(GameConfig? cfg) {
    final r = cfg?.energyFor(widget.sport);
    if (r == null || r.per == 0) return 0;
    return (_amount / r.per * r.energy).floor();
  }

  Future<void> _finish() async {
    if (_amount <= 0) {
      toast(context, _counter ? '还没有计数哦' : '至少训练 1 分钟才能换能量');
      return;
    }
    if (_running) _toggle();
    setState(() => _busy = true);
    final now = _now();
    final deviceId = await ref.read(tokenStoreProvider).deviceId();
    final upload = ActivityUpload(
      clientId: const Uuid().v4(),
      sport: widget.sport,
      startedAt: _startedAt ?? now,
      endedAt: now,
      durationS: (_elapsedMs / 1000).round(),
      amount: _amount,
      device: await collectDevice(deviceId),
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

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(configProvider).value;
    final rule = cfg?.energyFor(widget.sport);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          BackHeader(title: sportName(widget.sport), subtitle: rule == null ? '居家训练' : '居家训练 · ${rule.text}'),
          Expanded(
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(Fmt.duration(_elapsedMs / 1000),
                    style: TextStyle(
                        fontSize: _counter ? 36 : 72,
                        fontWeight: FontWeight.w900,
                        color: _counter ? LL.text2 : LL.text,
                        fontFeatures: const [FontFeature.tabularFigures()])),
                if (_counter) ...[
                  const SizedBox(height: 8),
                  Text('$_count', style: const TextStyle(fontSize: 96, fontWeight: FontWeight.w900, height: 1)),
                  const Text('次', style: TextStyle(color: LL.text2)),
                  const SizedBox(height: 20),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    OutlinedButton(onPressed: _count > 0 ? () => setState(() => _count--) : null, child: const Text('-1')),
                    const SizedBox(width: 12),
                    Material(
                      color: LL.lime,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () {
                          if (!_running) _toggle();
                          setState(() => _count++);
                        },
                        child: const SizedBox(
                            width: 120, height: 120, child: Center(child: Text('+1', style: TextStyle(color: LL.ink, fontSize: 36, fontWeight: FontWeight.w900)))),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(onPressed: () => setState(() => _count += 10), child: const Text('+10')),
                  ]),
                ] else
                  const Text('训练时长', style: TextStyle(color: LL.text2)),
                const SizedBox(height: 24),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.bolt_rounded, color: LL.yellow),
                  Text('预计 +${_estimate(cfg)} 能量', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 6),
                const Text('居家训练不能圈新地，能量可用来建造和加固领地', style: TextStyle(color: LL.text3, fontSize: 12)),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _toggle,
                  child: Text(_running ? '暂停' : (_startedAt == null ? '开始计时' : '继续')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _busy || _startedAt == null ? null : _finish,
                  child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)) : const Text('完成'),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
