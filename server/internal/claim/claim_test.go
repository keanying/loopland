package claim

import (
	"math"
	"testing"

	"github.com/keanying/loopland/server/internal/geo"
)

// Tests are written in metres around a fixed origin (人民广场, Shanghai) and
// converted to lat/lng, so the expected areas are easy to read.
var origin = geo.LatLng{Lat: 31.2304, Lng: 121.4737}

func track(pts ...[2]float64) []geo.LatLng {
	p := geo.NewProjection(origin)
	out := make([]geo.LatLng, len(pts))
	for i, xy := range pts {
		out[i] = p.Inverse(geo.Point{X: xy[0], Y: xy[1]})
	}
	return out
}

func near(got, want, tol float64) bool { return math.Abs(got-want) <= tol }

func TestNoLoopOnOpenPath(t *testing.T) {
	r := Detect(track([2]float64{0, 0}, [2]float64{200, 0}, [2]float64{200, 200}, [2]float64{0, 200}), Options{})
	if len(r.Loops) != 0 {
		t.Fatalf("expected no loops, got %d", len(r.Loops))
	}
	if r.Hint == nil || !near(r.Hint.DistanceM, 200, 0.5) {
		t.Fatalf("hint = %+v, want ~200 m back to the start", r.Hint)
	}
}

func TestLoopWithoutReturningToStart(t *testing.T) {
	// Out east, north, back west, then south across the first leg at (50,0).
	r := Detect(track(
		[2]float64{0, 0}, [2]float64{100, 0}, [2]float64{100, 100},
		[2]float64{50, 100}, [2]float64{50, -50},
	), Options{})
	if len(r.Loops) != 1 {
		t.Fatalf("loops = %d, want 1", len(r.Loops))
	}
	l := r.Loops[0]
	if !near(l.AreaM2, 5000, 1) {
		t.Fatalf("area = %.1f, want 5000", l.AreaM2)
	}
	if !near(l.PerimeterM, 300, 0.5) {
		t.Fatalf("perimeter = %.1f, want 300", l.PerimeterM)
	}
	if l.ClosedAt != 4 {
		t.Fatalf("closed at = %d, want 4", l.ClosedAt)
	}
	if l.Ring[0] != l.Ring[len(l.Ring)-1] {
		t.Fatal("ring must be closed")
	}
}

func TestFigureEightClaimsTwoLoops(t *testing.T) {
	// Two 100x100 squares run one after the other, each closed by crossing.
	r := Detect(track(
		[2]float64{0, 0}, [2]float64{100, 0}, [2]float64{100, 100},
		[2]float64{20, 100}, [2]float64{20, -20}, // closes square 1 (80x100)
		[2]float64{20, -120}, [2]float64{-80, -120}, [2]float64{-80, -60},
		[2]float64{40, -60}, // crosses the (20,-20)->(20,-120) leg: closes 60x60
	), Options{})
	if len(r.Loops) != 2 {
		t.Fatalf("loops = %d, want 2", len(r.Loops))
	}
	if !near(r.Loops[0].AreaM2, 8000, 1) || !near(r.Loops[1].AreaM2, 100*60, 1) {
		t.Fatalf("areas = %.1f, %.1f", r.Loops[0].AreaM2, r.Loops[1].AreaM2)
	}
	if !near(r.TotalAreaM2, 14000, 2) {
		t.Fatalf("total = %.1f", r.TotalAreaM2)
	}
}

func TestOneSegmentClosesSeveralLoops(t *testing.T) {
	// A comb-shaped path; the final long westward segment at y=50 cuts it
	// into three 50x50 cells: the right tooth, the gap between the teeth
	// (bounded by the bottom leg), and the left tooth.
	r := Detect(track(
		[2]float64{0, 0}, [2]float64{0, 100}, [2]float64{50, 100}, [2]float64{50, 0},
		[2]float64{100, 0}, [2]float64{100, 100}, [2]float64{150, 100}, [2]float64{150, 50},
		[2]float64{-10, 50},
	), Options{})
	if len(r.Loops) != 3 {
		t.Fatalf("loops = %d, want 3", len(r.Loops))
	}
	for i, l := range r.Loops {
		if !near(l.AreaM2, 2500, 1) {
			t.Fatalf("loop %d area = %.1f, want 2500", i, l.AreaM2)
		}
		if l.ClosedAt != 8 {
			t.Fatalf("loop %d closed at %d, want 8", i, l.ClosedAt)
		}
	}
}

func TestJitterLoopIsDiscarded(t *testing.T) {
	r := Detect(track(
		[2]float64{0, 0}, [2]float64{10, 0}, [2]float64{10, 10}, [2]float64{5, 10}, [2]float64{5, -5},
		[2]float64{5, -300},
	), Options{})
	if len(r.Loops) != 0 || r.Discarded != 1 {
		t.Fatalf("loops = %d discarded = %d, want 0 / 1", len(r.Loops), r.Discarded)
	}
}

func TestPointsTooCloseAreIgnored(t *testing.T) {
	tr := NewTracker(Options{})
	for _, p := range track([2]float64{0, 0}, [2]float64{0.5, 0}, [2]float64{1, 0.5}) {
		tr.Add(p)
	}
	if len(tr.path) != 1 {
		t.Fatalf("path len = %d, want 1", len(tr.path))
	}
}

func TestRoundRunNearCircleArea(t *testing.T) {
	// A 300 m radius run that overshoots the start by 30°.
	const r = 300.0
	var pts [][2]float64
	for deg := 0; deg <= 390; deg += 5 {
		a := float64(deg) * math.Pi / 180
		rr := r
		if deg > 360 {
			rr = r - 20 // drift inside so the overshoot crosses the first leg
		}
		pts = append(pts, [2]float64{rr * math.Cos(a), rr * math.Sin(a)})
	}
	pts = append([][2]float64{{r + 20, -20}}, pts...) // approach from outside
	res := Detect(track(pts...), Options{})
	if len(res.Loops) != 1 {
		t.Fatalf("loops = %d, want 1", len(res.Loops))
	}
	want := math.Pi * r * r
	if rel := math.Abs(res.Loops[0].AreaM2-want) / want; rel > 0.03 {
		t.Fatalf("area = %.0f, want ≈ %.0f", res.Loops[0].AreaM2, want)
	}
}

func TestIncrementalMatchesBatch(t *testing.T) {
	pts := track(
		[2]float64{0, 0}, [2]float64{100, 0}, [2]float64{100, 100},
		[2]float64{50, 100}, [2]float64{50, -50},
	)
	tr := NewTracker(Options{})
	var closedAt []int
	for i, p := range pts {
		if len(tr.Add(p)) > 0 {
			closedAt = append(closedAt, i)
		}
	}
	if len(closedAt) != 1 || closedAt[0] != 4 {
		t.Fatalf("closed at %v", closedAt)
	}
}

func TestHintIgnoresTheLegJustRun(t *testing.T) {
	// East 200 m, north 200 m, then a long 150 m leg west. The previous
	// corner (200,200) is 150 m behind on a straight line; running back to it
	// encloses nothing. The real closing point is the first leg, 200 m south.
	r := Detect(track([2]float64{0, 0}, [2]float64{200, 0}, [2]float64{200, 200}, [2]float64{50, 200}), Options{})
	if r.Hint == nil || !near(r.Hint.DistanceM, 200, 0.5) {
		t.Fatalf("hint = %+v, want ~200 m south to the first leg", r.Hint)
	}
	// A straight line has nothing to close.
	if r := Detect(track([2]float64{0, 0}, [2]float64{100, 0}, [2]float64{300, 0}), Options{}); r.Hint != nil {
		t.Fatalf("straight line hint = %+v", r.Hint)
	}
}
