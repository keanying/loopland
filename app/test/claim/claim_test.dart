// Port of server/internal/claim/claim_test.go.
//
// Tests are written in metres around a fixed origin (人民广场, Shanghai) and
// converted to lat/lng, so the expected areas are easy to read.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/claim/claim.dart';
import 'package:loopland/claim/geo.dart';

const origin = LatLng(31.2304, 121.4737);

List<LatLng> track(List<List<double>> pts) {
  final p = Projection(origin);
  return [for (final xy in pts) p.inverse(Point(xy[0], xy[1]))];
}

bool near(double got, double want, double tol) => (got - want).abs() <= tol;

void main() {
  test('no loop on open path', () {
    final r = detect(track([[0, 0], [200, 0], [200, 200], [0, 200]]));
    expect(r.loops, isEmpty);
    expect(r.hint, isNotNull);
    expect(near(r.hint!.distanceM, 200, 0.5), isTrue, reason: 'hint ${r.hint!.distanceM}, want ~200 m back to the start');
  });

  test('loop without returning to start', () {
    // Out east, north, back west, then south across the first leg at (50,0).
    final r = detect(track([[0, 0], [100, 0], [100, 100], [50, 100], [50, -50]]));
    expect(r.loops, hasLength(1));
    final l = r.loops.first;
    expect(near(l.areaM2, 5000, 1), isTrue, reason: 'area ${l.areaM2}');
    expect(near(l.perimeterM, 300, 0.5), isTrue, reason: 'perimeter ${l.perimeterM}');
    expect(l.closedAt, 4);
    expect(l.ring.first, l.ring.last, reason: 'ring must be closed');
  });

  test('figure eight claims two loops', () {
    final r = detect(track([
      [0, 0], [100, 0], [100, 100],
      [20, 100], [20, -20], // closes square 1 (80x100)
      [20, -120], [-80, -120], [-80, -60],
      [40, -60], // crosses the (20,-20)->(20,-120) leg: closes 100x60
    ]));
    expect(r.loops, hasLength(2));
    expect(near(r.loops[0].areaM2, 8000, 1), isTrue, reason: 'area0 ${r.loops[0].areaM2}');
    expect(near(r.loops[1].areaM2, 100 * 60, 1), isTrue, reason: 'area1 ${r.loops[1].areaM2}');
    expect(near(r.totalAreaM2, 14000, 2), isTrue, reason: 'total ${r.totalAreaM2}');
  });

  test('one segment closes several loops', () {
    // A comb-shaped path; the final long westward segment at y=50 cuts it
    // into three 50x50 cells.
    final r = detect(track([
      [0, 0], [0, 100], [50, 100], [50, 0],
      [100, 0], [100, 100], [150, 100], [150, 50],
      [-10, 50],
    ]));
    expect(r.loops, hasLength(3));
    for (final (i, l) in r.loops.indexed) {
      expect(near(l.areaM2, 2500, 1), isTrue, reason: 'loop $i area ${l.areaM2}');
      expect(l.closedAt, 8, reason: 'loop $i');
    }
  });

  test('jitter loop is discarded', () {
    final r = detect(track([[0, 0], [10, 0], [10, 10], [5, 10], [5, -5], [5, -300]]));
    expect(r.loops, isEmpty);
    expect(r.discarded, 1);
  });

  test('points too close are ignored', () {
    final t = ClaimTracker();
    for (final p in track([[0, 0], [0.5, 0], [1, 0.5]])) {
      t.add(p);
    }
    expect(t.path, hasLength(1));
  });

  test('round run near circle area', () {
    // A 300 m radius run that overshoots the start by 30°.
    const r = 300.0;
    final pts = <List<double>>[];
    for (var deg = 0; deg <= 390; deg += 5) {
      final a = deg * math.pi / 180;
      var rr = r;
      if (deg > 360) rr = r - 20; // drift inside so the overshoot crosses the first leg
      pts.add([rr * math.cos(a), rr * math.sin(a)]);
    }
    pts.insert(0, [r + 20, -20]); // approach from outside
    final res = detect(track(pts));
    expect(res.loops, hasLength(1));
    const want = math.pi * r * r;
    expect((res.loops.first.areaM2 - want).abs() / want, lessThan(0.03), reason: 'area ${res.loops.first.areaM2}');
  });

  test('incremental matches batch', () {
    final pts = track([[0, 0], [100, 0], [100, 100], [50, 100], [50, -50]]);
    final t = ClaimTracker();
    final closedAt = <int>[];
    for (final (i, p) in pts.indexed) {
      if (t.add(p).isNotEmpty) closedAt.add(i);
    }
    expect(closedAt, [4]);
  });

  // Client-only behaviour on top of the port.
  test('hint ignores only the last HintWindowM metres of the path', () {
    final t = ClaimTracker();
    // Heading back west along y=100 after a 200x200 U: the leg just run
    // (x=200) is outside the 40 m window, so it is the nearest crossable one.
    for (final p in track([[0, 0], [200, 0], [200, 200], [100, 200], [100, 100]])) {
      t.add(p);
    }
    final h = t.closingHint()!;
    expect(near(h.distanceM, 100, 0.5), isTrue, reason: '${h.distanceM}');
    expect(t.openPath, hasLength(5));
    // Target is a point on the open path: (100,0) or (200,100), both 100 m away.
    final p = Projection(origin).forward(h.target);
    expect(near(p.y, 0, 0.5) || near(p.x, 200, 0.5), isTrue, reason: '$p');
  });

  test('hint ignores the leg just run', () {
    // The previous corner is 150 m back along a straight leg; running there
    // encloses nothing. The real target is the first leg, 200 m south.
    final r = detect(track([[0, 0], [200, 0], [200, 200], [50, 200]]));
    expect(r.hint, isNotNull);
    expect(near(r.hint!.distanceM, 200, 0.5), isTrue, reason: '${r.hint!.distanceM}');
    expect(detect(track([[0, 0], [100, 0], [300, 0]])).hint, isNull);
  });
}
