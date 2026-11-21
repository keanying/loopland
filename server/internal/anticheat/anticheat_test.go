package anticheat

import (
	"testing"

	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/geo"
)

// line builds points every `step` metres going east, `dt` seconds apart.
func line(n int, step, dt float64) ([]Point, float64) {
	p := geo.NewProjection(geo.LatLng{Lat: 31.23, Lng: 121.47})
	pts := make([]Point, n)
	for i := range pts {
		ll := p.Inverse(geo.Point{X: float64(i) * step})
		pts[i] = Point{T: int64(float64(i) * dt * 1000), Lat: ll.Lat, Lng: ll.Lng, Src: "gps"}
	}
	return pts, float64(n-1) * step
}

var dev = Device{ID: "d1"}

func TestNormalRunPasses(t *testing.T) {
	pts, d := line(300, 3, 1) // 10.8 km/h
	r := Evaluate(DefaultRules, Input{Sport: gameplay.SportRun, Points: pts, DistanceM: d, Device: dev})
	if r.Verdict != Pass || len(r.Flags) != 0 {
		t.Fatalf("%+v", r)
	}
}

func TestSpeedReviewAndVoid(t *testing.T) {
	pts, d := line(300, 6.5, 1) // 23.4 km/h > 20
	if r := Evaluate(DefaultRules, Input{Sport: gameplay.SportRun, Points: pts, DistanceM: d, Device: dev}); r.Verdict != Review {
		t.Fatalf("%+v", r)
	}
	pts, d = line(300, 10, 1) // 36 km/h: a car
	if r := Evaluate(DefaultRules, Input{Sport: gameplay.SportRun, Points: pts, DistanceM: d, Device: dev}); r.Verdict != Void {
		t.Fatalf("%+v", r)
	}
	// The same speed is fine on a bike.
	if r := Evaluate(DefaultRules, Input{Sport: gameplay.SportRide, Points: pts, DistanceM: d, Device: dev}); r.Verdict != Pass {
		t.Fatalf("%+v", r)
	}
}

func TestMockLocationVoids(t *testing.T) {
	pts, d := line(100, 3, 1)
	pts[50].Src = "mock"
	r := Evaluate(DefaultRules, Input{Sport: gameplay.SportRun, Points: pts, DistanceM: d, Device: dev})
	if r.Verdict != Void || r.Flags[0].Rule != "mock_location" {
		t.Fatalf("%+v", r)
	}
}

func TestTeleport(t *testing.T) {
	pts, _ := line(100, 3, 1)
	p := geo.NewProjection(geo.LatLng{Lat: 31.23, Lng: 121.47})
	for i := 50; i < 100; i++ { // jump 2 km north between point 49 and 50
		ll := p.Inverse(geo.Point{X: float64(i) * 3, Y: 2000})
		pts[i].Lat, pts[i].Lng = ll.Lat, ll.Lng
	}
	r := Evaluate(DefaultRules, Input{Sport: gameplay.SportRun, Points: pts, DistanceM: 300, Device: dev})
	if r.Verdict != Review {
		t.Fatalf("%+v", r)
	}
	// A long gap over a plausible distance is a tunnel, not a jump.
	pts2, d := line(3, 600, 300)
	if j := Teleports(DefaultRules, gameplay.SportRun, pts2); len(j) != 0 {
		t.Fatalf("jumps %+v", j)
	}
	_ = d
}

func TestHomeTrainingIgnoresGPSRules(t *testing.T) {
	r := Evaluate(DefaultRules, Input{Sport: gameplay.SportYoga, Device: dev})
	if r.Verdict != Pass {
		t.Fatalf("%+v", r)
	}
}

func TestDeviceAndMultiAccount(t *testing.T) {
	r := Evaluate(DefaultRules, Input{Sport: gameplay.SportYoga, Device: Device{ID: "x", Rooted: true}})
	if r.Verdict != Review {
		t.Fatalf("%+v", r)
	}
	r = Evaluate(DefaultRules, Input{Sport: gameplay.SportYoga, Device: dev, SameDeviceAccounts: 4})
	if r.Verdict != Pass || len(r.Flags) != 1 {
		t.Fatalf("multi-account alone is only monitored: %+v", r)
	}
}

func TestCoachMismatch(t *testing.T) {
	cases := []struct {
		name   string
		in     Input
		review bool
	}{
		{"rope matches camera", Input{Sport: gameplay.SportRope, Amount: 480, Device: dev, Coach: &Coach{Camera: true, RepsDetected: 480}}, false},
		{"rope within 20%", Input{Sport: gameplay.SportRope, Amount: 560, Device: dev, Coach: &Coach{Camera: true, RepsDetected: 480}}, false},
		{"rope over 20%", Input{Sport: gameplay.SportRope, Amount: 600, Device: dev, Coach: &Coach{Camera: true, RepsDetected: 480}}, true},
		{"hiit manual reps", Input{Sport: gameplay.SportHIIT, Amount: 15, Device: dev, Coach: &Coach{Camera: true, RepsDetected: 40, RepsManual: 30}}, true},
		{"no camera", Input{Sport: gameplay.SportRope, Amount: 600, Device: dev, Coach: &Coach{Camera: false, RepsDetected: 0}}, false},
		{"tiny difference", Input{Sport: gameplay.SportRope, Amount: 12, Device: dev, Coach: &Coach{Camera: true, RepsDetected: 9}}, false},
		{"no coach", Input{Sport: gameplay.SportRope, Amount: 600, Device: dev}, false},
	}
	for _, c := range cases {
		r := Evaluate(DefaultRules, c.in)
		got := r.Verdict == Review && len(r.Flags) == 1 && r.Flags[0].Rule == "coach_mismatch"
		if got != c.review || (!c.review && r.Verdict != Pass) {
			t.Errorf("%s: %+v", c.name, r)
		}
	}
}
