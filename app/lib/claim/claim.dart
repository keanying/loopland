// Port of server/internal/claim/claim.go — 自由圈地.
//
// Whenever a track crosses itself, the enclosed area becomes a claimed loop.
// The runner never has to return to the start, and one activity can close any
// number of loops.
//
// The tracker keeps the "open path": the track so far with every closed loop
// cut out. Each new segment is tested against the non-adjacent segments of the
// open path. At the first crossing X along the new segment, the part of the
// path after the crossed segment, together with X, forms a simple polygon.
// That piece is removed from the path, the path now ends at X, and the rest of
// the new segment is tested again, so one long GPS segment can close several
// loops.
//
// The client only uses this for the in-run preview and the "还差 X 米可闭合"
// hint; settlement is always the server's.
import 'dart:math' as math;

import 'geo.dart';

/// Tuning knobs. Non-positive values fall back to [ClaimOptions.defaults].
class ClaimOptions {
  const ClaimOptions({this.minAreaM2 = 0, this.minStepM = 0, this.hintWindowM = 0});

  /// Loops smaller than this are cut from the path but not counted.
  final double minAreaM2;

  /// A new point closer than this to the previous kept one is ignored.
  final double minStepM;

  /// How much of the most recent path the closing hint ignores.
  final double hintWindowM;

  static const defaults =
      ClaimOptions(minAreaM2: 500, minStepM: 2, hintWindowM: 40);

  ClaimOptions withDefaults() => ClaimOptions(
        minAreaM2: minAreaM2 > 0 ? minAreaM2 : defaults.minAreaM2,
        minStepM: minStepM > 0 ? minStepM : defaults.minStepM,
        hintWindowM: hintWindowM > 0 ? hintWindowM : defaults.hintWindowM,
      );
}

/// One closed area.
class Loop {
  const Loop({
    required this.ring,
    required this.areaM2,
    required this.perimeterM,
    required this.closedAt,
  });

  /// Closed ring: first == last.
  final List<LatLng> ring;
  final double areaM2;
  final double perimeterM;

  /// Index of the input point whose arrival closed the loop.
  final int closedAt;
}

/// How far the runner is from closing a loop.
class ClosingHint {
  const ClosingHint(this.distanceM, this.target);

  final double distanceM;

  /// Nearest point on the open path.
  final LatLng target;
}

/// Detects loops incrementally as points arrive.
class ClaimTracker {
  ClaimTracker([ClaimOptions opts = const ClaimOptions()])
      : opts = opts.withDefaults();

  final ClaimOptions opts;
  Projection? _proj;
  List<Point> _path = [];
  final List<Loop> _loops = [];
  int _discarded = 0;
  int _n = 0;

  /// The open path in plane coordinates (exposed for tests).
  List<Point> get path => List.unmodifiable(_path);

  /// The open path as lat/lng, for drawing.
  List<LatLng> get openPath =>
      _proj == null ? const [] : [for (final p in _path) _proj!.inverse(p)];

  /// Every loop closed so far.
  List<Loop> get loops => List.unmodifiable(_loops);

  /// How many crossings were too small to count.
  int get discarded => _discarded;

  /// Number of input points seen.
  int get pointCount => _n;

  double get totalAreaM2 => _loops.fold(0.0, (s, l) => s + l.areaM2);

  /// Feeds the next GPS point and returns the loops it closed, if any.
  List<Loop> add(LatLng ll) {
    final idx = _n;
    _n++;
    if (_path.isEmpty) {
      _proj = Projection(ll);
      _path.add(_proj!.forward(ll));
      return const [];
    }
    final proj = _proj!;
    final q = proj.forward(ll);
    var cur = _path.last;
    if (cur.dist(q) < opts.minStepM) return const [];

    final closed = <Loop>[];
    while (true) {
      final n = _path.length;
      var best = -1;
      var bestT = double.infinity;
      Point? bestPt;
      // Segment n-2 ends at cur and is adjacent to the new segment.
      for (var k = 0; k <= n - 3; k++) {
        final hit = segmentIntersection(cur, q, _path[k], _path[k + 1]);
        if (hit != null && hit.t > 1e-9 && hit.t < bestT) {
          best = k;
          bestT = hit.t;
          bestPt = hit.pt;
        }
      }
      if (best < 0) break;
      final ring = <Point>[bestPt!, ..._path.sublist(best + 1)];
      final loop = _makeLoop(ring, idx);
      if (loop != null) {
        closed.add(loop);
      } else {
        _discarded++;
      }
      _path = [..._path.sublist(0, best + 1), bestPt];
      cur = bestPt;
    }
    _path.add(q);
    _loops.addAll(closed);
    return closed;
  }

  Loop? _makeLoop(List<Point> ring, int idx) {
    final area = ringArea(ring);
    if (ring.length < 3 || area < opts.minAreaM2) return null;
    final proj = _proj!;
    final ll = [for (final p in ring) proj.inverse(p)];
    ll.add(ll.first);
    return Loop(
      ring: ll,
      areaM2: area,
      perimeterM: ringPerimeter(ring),
      closedAt: idx,
    );
  }

  /// Straight-line distance from the current position to the nearest point
  /// of the open path that could still be crossed, ignoring the last
  /// [ClaimOptions.hintWindowM] metres. Null when there is nothing to close.
  ClosingHint? closingHint() {
    final n = _path.length;
    if (n < 3) return null;
    final cur = _path[n - 1];
    // suffix[i] is the path length from vertex i to the current position. A
    // point only closes a loop if reaching it along the path is at least
    // hintWindowM longer than the straight line; the leg just run never is.
    final suffix = List<double>.filled(n, 0);
    for (var i = n - 2; i >= 0; i--) {
      suffix[i] = suffix[i + 1] + _path[i].dist(_path[i + 1]);
    }
    var best = double.infinity;
    Point? bestPt;
    for (var k = 0; k <= n - 3; k++) {
      final p = _closableOnSegment(cur, _path[k], _path[k + 1], suffix[k + 1], opts.hintWindowM);
      if (p == null) continue;
      final d = p.dist(cur);
      if (d < best) {
        best = d;
        bestPt = p;
      }
    }
    if (best.isInfinite) return null;
    return ClosingHint(best, _proj!.inverse(bestPt!));
  }
}

/// The point of segment a→b nearest to [cur] that would close a loop:
/// walking the path from there to [cur] must be at least [window] longer
/// than the straight line ([tail] is the path length from b to cur). Moving
/// from the nearest point towards a only increases that difference, so a
/// binary search finds the first qualifying point. Mirrors the Go version.
Point? _closableOnSegment(Point cur, Point a, Point b, double tail, double window) {
  Point at(double u) => Point(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u);
  double gain(double u) {
    final p = at(u);
    return p.dist(b) + tail - p.dist(cur);
  }

  final p = closestOnSegment(cur, a, b);
  final segLen = a.dist(b);
  final u0 = segLen > 0 ? a.dist(p) / segLen : 0.0;
  if (gain(u0) >= window) return p;
  if (gain(0) < window) return null;
  var lo = 0.0, hi = u0;
  for (var i = 0; i < 40; i++) {
    final mid = (lo + hi) / 2;
    if (gain(mid) >= window) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return at(lo);
}

/// The outcome of running a whole track through the engine.
class ClaimResult {
  const ClaimResult({
    required this.loops,
    required this.totalAreaM2,
    required this.discarded,
    this.hint,
  });

  final List<Loop> loops;
  final double totalAreaM2;
  final int discarded;
  final ClosingHint? hint;
}

/// Runs a complete track and returns every loop it closed.
ClaimResult detect(List<LatLng> points, [ClaimOptions opts = const ClaimOptions()]) {
  final t = ClaimTracker(opts);
  for (final p in points) {
    t.add(p);
  }
  return ClaimResult(
    loops: t.loops,
    totalAreaM2: t.totalAreaM2,
    discarded: t.discarded,
    hint: t.closingHint(),
  );
}

/// Sum of haversine distances along a track in metres.
double trackDistanceM(List<LatLng> pts) {
  var s = 0.0;
  for (var i = 1; i < pts.length; i++) {
    s += haversine(pts[i - 1], pts[i]);
  }
  return s;
}

/// Bounding box helper used by map views.
({double minLat, double minLng, double maxLat, double maxLng})? boundsOf(
    Iterable<LatLng> pts) {
  double? a, b, c, d;
  for (final p in pts) {
    a = a == null ? p.lat : math.min(a, p.lat);
    b = b == null ? p.lng : math.min(b, p.lng);
    c = c == null ? p.lat : math.max(c, p.lat);
    d = d == null ? p.lng : math.max(d, p.lng);
  }
  if (a == null) return null;
  return (minLat: a, minLng: b!, maxLat: c!, maxLng: d!);
}
