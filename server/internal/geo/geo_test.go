package geo

import (
	"math"
	"testing"
)

func TestProjectionRoundTrip(t *testing.T) {
	p := NewProjection(LatLng{Lat: 31.2304, Lng: 121.4737})
	in := LatLng{Lat: 31.2410, Lng: 121.4901}
	out := p.Inverse(p.Forward(in))
	if math.Abs(out.Lat-in.Lat) > 1e-9 || math.Abs(out.Lng-in.Lng) > 1e-9 {
		t.Fatalf("round trip: got %+v want %+v", out, in)
	}
}

func TestProjectionMatchesHaversine(t *testing.T) {
	o := LatLng{Lat: 31.2304, Lng: 121.4737}
	p := NewProjection(o)
	b := LatLng{Lat: 31.2404, Lng: 121.4837} // ~1.4 km away
	planar := p.Forward(o).Dist(p.Forward(b))
	hv := Haversine(o, b)
	if rel := math.Abs(planar-hv) / hv; rel > 0.001 {
		t.Fatalf("planar %.2f vs haversine %.2f (rel err %.4f)", planar, hv, rel)
	}
}

func TestSegmentIntersection(t *testing.T) {
	pt, tt, ok := SegmentIntersection(Point{0, 0}, Point{10, 10}, Point{0, 10}, Point{10, 0})
	if !ok || math.Abs(pt.X-5) > 1e-9 || math.Abs(pt.Y-5) > 1e-9 || math.Abs(tt-0.5) > 1e-9 {
		t.Fatalf("got %+v t=%v ok=%v", pt, tt, ok)
	}
	if _, _, ok := SegmentIntersection(Point{0, 0}, Point{1, 0}, Point{0, 1}, Point{1, 1}); ok {
		t.Fatal("parallel segments must not intersect")
	}
	if _, _, ok := SegmentIntersection(Point{0, 0}, Point{1, 1}, Point{3, 0}, Point{0, 3}); ok {
		t.Fatal("segments that would cross only when extended must not intersect")
	}
}

func TestRingArea(t *testing.T) {
	sq := []Point{{0, 0}, {100, 0}, {100, 100}, {0, 100}}
	if a := RingArea(sq); a != 10000 {
		t.Fatalf("area = %v", a)
	}
	if p := RingPerimeter(sq); p != 400 {
		t.Fatalf("perimeter = %v", p)
	}
}
