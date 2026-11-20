// Package geo holds the small amount of planar geometry the claim engine needs.
//
// Coordinates come from AMap (GCJ-02) on the client. Inside one city the error
// of a local equirectangular projection is well under 1%, which is fine for
// loop detection and the in-run area preview. The authoritative area and the
// overlap with other people's territory are computed by PostGIS on the server.
package geo

import "math"

// EarthRadiusM is the mean Earth radius in metres.
const EarthRadiusM = 6371008.8

// LatLng is a WGS84/GCJ-02 coordinate in degrees.
type LatLng struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

// Point is a position in metres on a local tangent plane.
type Point struct{ X, Y float64 }

// Sub returns p - q.
func (p Point) Sub(q Point) Point { return Point{p.X - q.X, p.Y - q.Y} }

// Dist returns the Euclidean distance between p and q.
func (p Point) Dist(q Point) float64 { return math.Hypot(p.X-q.X, p.Y-q.Y) }

func cross(a, b Point) float64 { return a.X*b.Y - a.Y*b.X }

// Projection maps lat/lng to metres around a fixed origin (equirectangular).
type Projection struct {
	origin LatLng
	kx, ky float64 // metres per degree
}

// NewProjection returns a projection centred on origin.
func NewProjection(origin LatLng) Projection {
	ky := EarthRadiusM * math.Pi / 180
	return Projection{origin: origin, ky: ky, kx: ky * math.Cos(origin.Lat*math.Pi/180)}
}

// Forward projects ll to the plane.
func (p Projection) Forward(ll LatLng) Point {
	return Point{X: (ll.Lng - p.origin.Lng) * p.kx, Y: (ll.Lat - p.origin.Lat) * p.ky}
}

// Inverse maps a plane point back to lat/lng.
func (p Projection) Inverse(pt Point) LatLng {
	return LatLng{Lat: p.origin.Lat + pt.Y/p.ky, Lng: p.origin.Lng + pt.X/p.kx}
}

// SegmentIntersection reports where segment a1→a2 properly crosses b1→b2.
// t is the position along a (0..1). Collinear overlaps are reported as no
// intersection: real GPS tracks practically never run exactly collinear, and
// treating a shared line as a "crossing" would create zero-area loops.
func SegmentIntersection(a1, a2, b1, b2 Point) (pt Point, t float64, ok bool) {
	r := a2.Sub(a1)
	s := b2.Sub(b1)
	den := cross(r, s)
	if math.Abs(den) < 1e-12 {
		return Point{}, 0, false
	}
	qp := b1.Sub(a1)
	t = cross(qp, s) / den
	u := cross(qp, r) / den
	if t < 0 || t > 1 || u < 0 || u > 1 {
		return Point{}, 0, false
	}
	return Point{a1.X + t*r.X, a1.Y + t*r.Y}, t, true
}

// ClosestOnSegment returns the point on segment a→b nearest to p.
func ClosestOnSegment(p, a, b Point) Point {
	ab := b.Sub(a)
	l2 := ab.X*ab.X + ab.Y*ab.Y
	if l2 == 0 {
		return a
	}
	t := ((p.X-a.X)*ab.X + (p.Y-a.Y)*ab.Y) / l2
	t = math.Max(0, math.Min(1, t))
	return Point{a.X + t*ab.X, a.Y + t*ab.Y}
}

// RingArea returns the unsigned area of a ring (closed or open) in m².
func RingArea(ring []Point) float64 {
	n := len(ring)
	if n < 3 {
		return 0
	}
	var s float64
	for i := 0; i < n; i++ {
		j := (i + 1) % n
		s += ring[i].X*ring[j].Y - ring[j].X*ring[i].Y
	}
	return math.Abs(s) / 2
}

// RingPerimeter returns the perimeter of a ring, closing it if needed.
func RingPerimeter(ring []Point) float64 {
	n := len(ring)
	if n < 2 {
		return 0
	}
	var s float64
	for i := 0; i < n; i++ {
		s += ring[i].Dist(ring[(i+1)%n])
	}
	return s
}

// Haversine returns the great-circle distance in metres.
func Haversine(a, b LatLng) float64 {
	rad := math.Pi / 180
	dLat := (b.Lat - a.Lat) * rad
	dLng := (b.Lng - a.Lng) * rad
	h := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(a.Lat*rad)*math.Cos(b.Lat*rad)*math.Sin(dLng/2)*math.Sin(dLng/2)
	return 2 * EarthRadiusM * math.Asin(math.Min(1, math.Sqrt(h)))
}
