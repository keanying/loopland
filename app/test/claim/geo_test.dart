// Port of server/internal/geo/geo_test.go.
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/claim/geo.dart';

void main() {
  test('projection round trip', () {
    final p = Projection(const LatLng(31.2304, 121.4737));
    const inp = LatLng(31.2410, 121.4901);
    final out = p.inverse(p.forward(inp));
    expect((out.lat - inp.lat).abs(), lessThan(1e-9));
    expect((out.lng - inp.lng).abs(), lessThan(1e-9));
  });

  test('projection matches haversine', () {
    const o = LatLng(31.2304, 121.4737);
    final p = Projection(o);
    const b = LatLng(31.2404, 121.4837); // ~1.4 km away
    final planar = p.forward(o).dist(p.forward(b));
    final hv = haversine(o, b);
    expect((planar - hv).abs() / hv, lessThan(0.001), reason: 'planar $planar vs haversine $hv');
  });

  test('segment intersection', () {
    final hit = segmentIntersection(const Point(0, 0), const Point(10, 10), const Point(0, 10), const Point(10, 0));
    expect(hit, isNotNull);
    expect((hit!.pt.x - 5).abs(), lessThan(1e-9));
    expect((hit.pt.y - 5).abs(), lessThan(1e-9));
    expect((hit.t - 0.5).abs(), lessThan(1e-9));
    expect(segmentIntersection(const Point(0, 0), const Point(1, 0), const Point(0, 1), const Point(1, 1)), isNull,
        reason: 'parallel segments must not intersect');
    expect(segmentIntersection(const Point(0, 0), const Point(1, 1), const Point(3, 0), const Point(0, 3)), isNull,
        reason: 'segments that would cross only when extended must not intersect');
  });

  test('ring area and perimeter', () {
    const sq = [Point(0, 0), Point(100, 0), Point(100, 100), Point(0, 100)];
    expect(ringArea(sq), 10000);
    expect(ringPerimeter(sq), 400);
  });
}
