package social

import (
	"math"
	"testing"
	"time"

	"github.com/keanying/loopland/server/internal/geo"
)

var start = geo.LatLng{Lat: 31.2304, Lng: 121.4737}

// line walks east from start, one point every step metres.
func line(n int, step float64) []TPoint {
	proj := geo.NewProjection(start)
	out := make([]TPoint, n)
	for i := range out {
		ll := proj.Inverse(geo.Point{X: float64(i) * step})
		out[i] = TPoint{Lng: ll.Lng, Lat: ll.Lat, T: float64(i)}
	}
	return out
}

func TestHideEndpoints(t *testing.T) {
	pts := line(101, 10) // 1 km
	got := HideEndpoints(pts, 200)
	if len(got) == 0 {
		t.Fatal("everything hidden")
	}
	first, last := got[0], got[len(got)-1]
	if d := geo.Haversine(start, ll(first)); d < 200 || d > 211 {
		t.Fatalf("first kept point %.1f m from start", d)
	}
	if d := geo.Haversine(ll(pts[100]), ll(last)); d < 200 || d > 211 {
		t.Fatalf("last kept point %.1f m from end", d)
	}
	if len(HideEndpoints(pts, 0)) != len(pts) {
		t.Fatal("radius 0 must keep the track")
	}
	// A loop that ends where it started: points near home vanish at both ends.
	loop := append(line(51, 10), reverse(line(51, 10))...)
	if got := HideEndpoints(loop, 200); len(got) == 0 || geo.Haversine(start, ll(got[0])) < 200 || geo.Haversine(start, ll(got[len(got)-1])) < 200 {
		t.Fatalf("loop: %d points", len(got))
	}
	if got := HideEndpoints(line(10, 10), 200); len(got) != 0 {
		t.Fatalf("short track should be fully hidden, got %d", len(got))
	}
}

func reverse(p []TPoint) []TPoint {
	out := make([]TPoint, len(p))
	for i := range p {
		out[i] = p[len(p)-1-i]
	}
	return out
}

func TestSimplify(t *testing.T) {
	// A straight line collapses to its ends.
	if got := Simplify(line(1000, 1), 300); len(got) != 2 {
		t.Fatalf("straight line: %d points", len(got))
	}
	// A zig-zag keeps its corners, never more than max, ends preserved.
	proj := geo.NewProjection(start)
	var zz []TPoint
	for i := 0; i < 2000; i++ {
		ll := proj.Inverse(geo.Point{X: float64(i), Y: 30 * math.Sin(float64(i)/5)})
		zz = append(zz, TPoint{Lng: ll.Lng, Lat: ll.Lat, T: float64(i)})
	}
	for _, max := range []int{300, 600, 50} {
		got := Simplify(zz, max)
		if len(got) > max || len(got) < 2 || got[0] != zz[0] || got[len(got)-1] != zz[len(zz)-1] {
			t.Fatalf("max %d: %d points", max, len(got))
		}
		for i := 1; i < len(got); i++ {
			if got[i].T <= got[i-1].T {
				t.Fatal("order not kept")
			}
		}
	}
	short := line(5, 10)
	if got := Simplify(short, 300); len(got) != 5 {
		t.Fatal("short track changed")
	}
}

func TestCursor(t *testing.T) {
	now := time.Date(2026, 11, 21, 8, 30, 0, 123456000, time.UTC)
	for _, c := range []cursor{{T: &now, ID: 42}, {Off: 40, Snap: now.UnixMicro()}, {}} {
		got, err := decodeCursor(c.encode())
		if err != nil {
			t.Fatal(err)
		}
		if got.ID != c.ID || got.Off != c.Off || got.Snap != c.Snap || (c.T == nil) != (got.T == nil) || (c.T != nil && !got.T.Equal(*c.T)) {
			t.Fatalf("round trip: %+v -> %+v", c, got)
		}
	}
	for _, bad := range []string{"%%", "bm90IGpzb24", "eyJvIjotMX0"} { // not base64, not json, negative offset
		if _, err := decodeCursor(bad); err == nil {
			t.Fatalf("%q accepted", bad)
		}
	}
	if c, err := decodeCursor(""); err != nil || c.T != nil || c.Off != 0 {
		t.Fatal("empty cursor must be the start")
	}
	if tm, id := (cursor{}).keysetDesc(); id != 0 || tm.Year() != 9999 {
		t.Fatal("desc start")
	}
}
