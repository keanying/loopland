// Package claim implements 自由圈地: whenever a track crosses itself, the
// enclosed area becomes a claimed loop. The runner never has to return to the
// start, and one activity can close any number of loops (产品文档 · 自由圈地,
// 功能清单 A-05).
//
// Algorithm. The tracker keeps the "open path": the track so far with every
// closed loop cut out. Each new segment is tested against the non-adjacent
// segments of the open path. At the first crossing X along the new segment,
// the part of the path after the crossed segment, together with X, forms a
// simple polygon (any earlier self-crossing inside it would already have been
// cut out). That piece is removed from the path, the path now ends at X, and
// the rest of the new segment is tested again, so one long GPS segment can
// close several loops.
//
// The same code runs on the server (authoritative settlement, before the
// PostGIS overlap step) and is small enough to port to the Flutter client for
// the in-run preview, including the "还差多少米可闭合" hint.
package claim

import (
	"math"

	"github.com/keanying/loopland/server/internal/geo"
)

// Options tune the engine. Zero values fall back to DefaultOptions.
type Options struct {
	// MinAreaM2 drops loops smaller than this. GPS jitter while standing at a
	// traffic light easily draws tiny crossings; they are cut from the path
	// but do not become territory.
	MinAreaM2 float64 `json:"min_area_m2"`
	// MinStepM ignores a new point closer than this to the previous kept one.
	MinStepM float64 `json:"min_step_m"`
	// HintWindowM is how much of the most recent path the closing hint
	// ignores; otherwise the nearest "closable" point would always be the
	// point the runner just passed.
	HintWindowM float64 `json:"hint_window_m"`
}

// DefaultOptions are placeholders until 数值策划 sets real values; they are
// meant to be moved into the gameplay config centre.
var DefaultOptions = Options{MinAreaM2: 500, MinStepM: 2, HintWindowM: 40}

func (o Options) withDefaults() Options {
	if o.MinAreaM2 <= 0 {
		o.MinAreaM2 = DefaultOptions.MinAreaM2
	}
	if o.MinStepM <= 0 {
		o.MinStepM = DefaultOptions.MinStepM
	}
	if o.HintWindowM <= 0 {
		o.HintWindowM = DefaultOptions.HintWindowM
	}
	return o
}

// Loop is one closed area.
type Loop struct {
	Ring       []geo.LatLng `json:"ring"` // closed: first == last
	AreaM2     float64      `json:"area_m2"`
	PerimeterM float64      `json:"perimeter_m"`
	// ClosedAt is the index of the input point whose arrival closed the loop.
	ClosedAt int `json:"closed_at"`
}

// Tracker detects loops incrementally as points arrive.
type Tracker struct {
	opts      Options
	proj      geo.Projection
	path      []geo.Point
	loops     []Loop
	discarded int
	n         int // number of input points seen
}

// NewTracker returns an empty tracker.
func NewTracker(opts Options) *Tracker {
	return &Tracker{opts: opts.withDefaults()}
}

// Add feeds the next GPS point and returns the loops it closed, if any.
func (t *Tracker) Add(ll geo.LatLng) []Loop {
	idx := t.n
	t.n++
	if len(t.path) == 0 {
		t.proj = geo.NewProjection(ll)
		t.path = append(t.path, t.proj.Forward(ll))
		return nil
	}
	q := t.proj.Forward(ll)
	cur := t.path[len(t.path)-1]
	if cur.Dist(q) < t.opts.MinStepM {
		return nil
	}

	var closed []Loop
	for {
		n := len(t.path)
		best, bestT := -1, math.Inf(1)
		var bestPt geo.Point
		// Segment n-2 ends at cur and is adjacent to the new segment.
		for k := 0; k <= n-3; k++ {
			pt, tt, ok := geo.SegmentIntersection(cur, q, t.path[k], t.path[k+1])
			if ok && tt > 1e-9 && tt < bestT {
				best, bestT, bestPt = k, tt, pt
			}
		}
		if best < 0 {
			break
		}
		ring := make([]geo.Point, 0, n-best+1)
		ring = append(ring, bestPt)
		ring = append(ring, t.path[best+1:]...)
		if l, ok := t.makeLoop(ring, idx); ok {
			closed = append(closed, l)
		} else {
			t.discarded++
		}
		t.path = append(t.path[:best+1:best+1], bestPt)
		cur = bestPt
	}
	t.path = append(t.path, q)
	t.loops = append(t.loops, closed...)
	return closed
}

func (t *Tracker) makeLoop(ring []geo.Point, idx int) (Loop, bool) {
	area := geo.RingArea(ring)
	if len(ring) < 3 || area < t.opts.MinAreaM2 {
		return Loop{}, false
	}
	ll := make([]geo.LatLng, 0, len(ring)+1)
	for _, p := range ring {
		ll = append(ll, t.proj.Inverse(p))
	}
	ll = append(ll, ll[0])
	return Loop{Ring: ll, AreaM2: area, PerimeterM: geo.RingPerimeter(ring), ClosedAt: idx}, true
}

// Loops returns every loop closed so far.
func (t *Tracker) Loops() []Loop { return t.loops }

// Discarded returns how many crossings were too small to count.
func (t *Tracker) Discarded() int { return t.discarded }

// TotalAreaM2 sums the area of all loops.
func (t *Tracker) TotalAreaM2() float64 {
	var s float64
	for _, l := range t.loops {
		s += l.AreaM2
	}
	return s
}

// Hint tells the runner how far they are from closing a loop.
type Hint struct {
	DistanceM float64    `json:"distance_m"`
	Target    geo.LatLng `json:"target"` // nearest point on the open path
}

// ClosingHint returns the straight-line distance from the current position
// to the nearest point of the open path that could still be crossed, ignoring
// the last HintWindowM metres. ok is false when there is nothing to close yet.
func (t *Tracker) ClosingHint() (Hint, bool) {
	n := len(t.path)
	if n < 3 {
		return Hint{}, false
	}
	cur := t.path[n-1]
	// Walk back from the end until the window is used up; segments before
	// index `limit` are eligible.
	walked, limit := 0.0, n-1
	for limit > 0 && walked < t.opts.HintWindowM {
		walked += t.path[limit].Dist(t.path[limit-1])
		limit--
	}
	best := math.Inf(1)
	var bestPt geo.Point
	for k := 0; k < limit; k++ {
		p := geo.ClosestOnSegment(cur, t.path[k], t.path[k+1])
		if d := p.Dist(cur); d < best {
			best, bestPt = d, p
		}
	}
	if math.IsInf(best, 1) {
		return Hint{}, false
	}
	return Hint{DistanceM: best, Target: t.proj.Inverse(bestPt)}, true
}

// Result is the outcome of running a whole track through the engine.
type Result struct {
	Loops       []Loop  `json:"loops"`
	TotalAreaM2 float64 `json:"total_area_m2"`
	Discarded   int     `json:"discarded"`
	Hint        *Hint   `json:"hint,omitempty"`
}

// Detect runs a complete track and returns every loop it closed.
func Detect(points []geo.LatLng, opts Options) Result {
	t := NewTracker(opts)
	for _, p := range points {
		t.Add(p)
	}
	r := Result{Loops: t.Loops(), TotalAreaM2: t.TotalAreaM2(), Discarded: t.Discarded()}
	if r.Loops == nil {
		r.Loops = []Loop{}
	}
	if h, ok := t.ClosingHint(); ok {
		r.Hint = &h
	}
	return r
}
