import 'pose.dart';

enum TrackingState {
  /// No frame yet (camera starting).
  waiting,

  /// Frames arrive but nobody is detected.
  noPerson,

  /// Somebody is there but the body parts the step needs are not all in the
  /// picture → 「全身入镜」 hint.
  partial,
  ok,
}

/// Watches the pose stream for the hints and for the fallback to manual
/// counting: too dark, too few usable frames, or the camera stalled.
///
/// Times are the caller's clock (arrival time of each frame), so the stall
/// check works even when no frames come at all.
class TrackingMonitor {
  TrackingMonitor({
    this.windowMs = 4000,
    this.minOkRate = 0.4,
    this.stallMs = 2500,
    this.lowLuma = 40,
    this.stateMs = 700,
  });

  /// Span of the stability statistics.
  final int windowMs;

  /// Below this share of usable frames (over a full window) tracking is
  /// considered unstable.
  final double minOkRate;

  /// No frame for this long = camera stalled.
  final int stallMs;

  /// Mean brightness (0..255) below which the picture is too dark.
  final double lowLuma;

  /// [state] summarises this recent span (majority), so it doesn't flicker.
  final int stateMs;

  final _frames = <_F>[];
  int? _firstAt;
  int? _lastAt;

  void reset() {
    _frames.clear();
    _firstAt = null;
    _lastAt = null;
  }

  /// Starts a new observation span at [atMs] (a new set, camera reopened):
  /// earlier frames no longer count, and the stall timer starts now.
  void restart(int atMs) {
    _frames.clear();
    _firstAt = atMs;
    _lastAt = atMs;
  }

  void add(PoseFrame f, {required bool visible, required int atMs}) {
    _firstAt ??= atMs;
    _lastAt = atMs;
    _frames
      ..add(_F(atMs, f.hasPerson, visible, f.luma))
      ..removeWhere((e) => atMs - e.at > windowMs);
  }

  TrackingState stateAt(int nowMs) {
    if (_lastAt == null) return TrackingState.waiting;
    final recent = _frames.where((e) => nowMs - e.at <= stateMs).toList();
    if (recent.isEmpty) return TrackingState.noPerson;
    final ok = recent.where((e) => e.visible).length;
    if (ok * 2 >= recent.length) return TrackingState.ok;
    final person = recent.where((e) => e.person).length;
    return person * 2 >= recent.length ? TrackingState.partial : TrackingState.noPerson;
  }

  /// Mean brightness over the window, when the source reports it.
  double? get luma {
    final ls = [for (final e in _frames) ?e.luma];
    if (ls.isEmpty) return null;
    return ls.reduce((a, b) => a + b) / ls.length;
  }

  bool get lowLight {
    final l = luma;
    return l != null && _frames.length >= 5 && l < lowLuma;
  }

  /// Frames per second over the window.
  double get fps {
    if (_frames.length < 2) return 0;
    final span = _frames.last.at - _frames.first.at;
    return span <= 0 ? 0 : (_frames.length - 1) * 1000 / span;
  }

  /// Share of usable frames over the window.
  double get okRate => _frames.isEmpty ? 0 : _frames.where((e) => e.visible).length / _frames.length;

  /// Why automatic counting should give way to manual counting, or null.
  /// Only judged once the camera has run for a full window.
  String? unstableReason(int nowMs) {
    if (_firstAt == null) return null;
    if (nowMs - _lastAt! >= stallMs) return '摄像头没有画面';
    if (nowMs - _firstAt! < windowMs) return null;
    if (lowLight) return '光线太暗';
    if (okRate < minOkRate) return '识别不稳定';
    return null;
  }
}

class _F {
  _F(this.at, this.person, this.visible, this.luma);
  final int at;
  final bool person;
  final bool visible;
  final double? luma;
}
