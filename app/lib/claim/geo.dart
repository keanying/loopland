// Port of server/internal/geo/geo.go.
//
// Coordinates come from AMap (GCJ-02). Inside one city the error of a local
// equirectangular projection is well under 1%, which is fine for loop
// detection and the in-run area preview. The authoritative area and the
// overlap with other people's territory are computed by PostGIS on the server.
import 'dart:math' as math;

/// Mean Earth radius in metres.
const double earthRadiusM = 6371008.8;

/// A GCJ-02 coordinate in degrees.
class LatLng {
  const LatLng(this.lat, this.lng);

  final double lat;
  final double lng;

  factory LatLng.fromJson(Map<String, dynamic> j) =>
      LatLng((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble());

  /// GeoJSON order: [lng, lat].
  factory LatLng.fromGeoJson(List<dynamic> c) =>
      LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng};

  @override
  bool operator ==(Object other) =>
      other is LatLng && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'LatLng($lat, $lng)';
}

/// A position in metres on a local tangent plane.
class Point {
  const Point(this.x, this.y);

  final double x;
  final double y;

  Point operator -(Point q) => Point(x - q.x, y - q.y);

  double dist(Point q) => _hypot(x - q.x, y - q.y);

  @override
  bool operator ==(Object other) =>
      other is Point && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Point($x, $y)';
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

double _cross(Point a, Point b) => a.x * b.y - a.y * b.x;

/// Maps lat/lng to metres around a fixed origin (equirectangular).
class Projection {
  Projection(this.origin)
      : ky = earthRadiusM * math.pi / 180,
        kx = earthRadiusM * math.pi / 180 * math.cos(origin.lat * math.pi / 180);

  final LatLng origin;

  /// Metres per degree.
  final double kx, ky;

  Point forward(LatLng ll) =>
      Point((ll.lng - origin.lng) * kx, (ll.lat - origin.lat) * ky);

  LatLng inverse(Point pt) =>
      LatLng(origin.lat + pt.y / ky, origin.lng + pt.x / kx);
}

/// Result of [segmentIntersection].
class Intersection {
  const Intersection(this.pt, this.t);

  final Point pt;

  /// Position along segment a (0..1).
  final double t;
}

/// Reports where segment a1→a2 properly crosses b1→b2, or null.
///
/// Collinear overlaps are reported as no intersection: real GPS tracks
/// practically never run exactly collinear, and treating a shared line as a
/// "crossing" would create zero-area loops.
Intersection? segmentIntersection(Point a1, Point a2, Point b1, Point b2) {
  final r = a2 - a1;
  final s = b2 - b1;
  final den = _cross(r, s);
  if (den.abs() < 1e-12) return null;
  final qp = b1 - a1;
  final t = _cross(qp, s) / den;
  final u = _cross(qp, r) / den;
  if (t < 0 || t > 1 || u < 0 || u > 1) return null;
  return Intersection(Point(a1.x + t * r.x, a1.y + t * r.y), t);
}

/// Returns the point on segment a→b nearest to p.
Point closestOnSegment(Point p, Point a, Point b) {
  final ab = b - a;
  final l2 = ab.x * ab.x + ab.y * ab.y;
  if (l2 == 0) return a;
  var t = ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / l2;
  t = math.max(0, math.min(1, t));
  return Point(a.x + t * ab.x, a.y + t * ab.y);
}

/// Unsigned area of a ring (closed or open) in m².
double ringArea(List<Point> ring) {
  final n = ring.length;
  if (n < 3) return 0;
  var s = 0.0;
  for (var i = 0; i < n; i++) {
    final j = (i + 1) % n;
    s += ring[i].x * ring[j].y - ring[j].x * ring[i].y;
  }
  return s.abs() / 2;
}

/// Perimeter of a ring, closing it if needed.
double ringPerimeter(List<Point> ring) {
  final n = ring.length;
  if (n < 2) return 0;
  var s = 0.0;
  for (var i = 0; i < n; i++) {
    s += ring[i].dist(ring[(i + 1) % n]);
  }
  return s;
}

/// Great-circle distance in metres.
double haversine(LatLng a, LatLng b) {
  const rad = math.pi / 180;
  final dLat = (b.lat - a.lat) * rad;
  final dLng = (b.lng - a.lng) * rad;
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(a.lat * rad) *
          math.cos(b.lat * rad) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * earthRadiusM * math.asin(math.min(1, math.sqrt(h)));
}
