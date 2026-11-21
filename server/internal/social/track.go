package social

import (
	"math"

	"github.com/keanying/loopland/server/internal/geo"
)

// Track limits (docs/api/v2-2-社区.md).
const (
	PostTrackMax   = 300
	ReplayTrackMax = 600
)

// TPoint is a track point with seconds since the activity start.
type TPoint struct {
	Lng, Lat float64
	T        float64
}

// HideEndpoints drops the leading points within radius of the start and
// the trailing points within radius of the end, so the shared track does
// not reveal where the author lives or works. A track that never leaves
// the zones comes back empty.
func HideEndpoints(pts []TPoint, radiusM float64) []TPoint {
	if radiusM <= 0 || len(pts) == 0 {
		return pts
	}
	start, end := ll(pts[0]), ll(pts[len(pts)-1])
	i := 0
	for i < len(pts) && geo.Haversine(start, ll(pts[i])) < radiusM {
		i++
	}
	j := len(pts) - 1
	for j >= i && geo.Haversine(end, ll(pts[j])) < radiusM {
		j--
	}
	if i > j {
		return []TPoint{}
	}
	return pts[i : j+1]
}

func ll(p TPoint) geo.LatLng { return geo.LatLng{Lat: p.Lat, Lng: p.Lng} }

// Simplify reduces a track to at most max points: Douglas–Peucker with a
// growing tolerance, then even sampling if it is still too long. The
// first and last points are kept.
func Simplify(pts []TPoint, max int) []TPoint {
	if len(pts) <= max || max < 2 {
		return pts
	}
	proj := geo.NewProjection(ll(pts[0]))
	xy := make([]geo.Point, len(pts))
	for i, p := range pts {
		xy[i] = proj.Forward(ll(p))
	}
	for tol := 1.0; tol <= 64; tol *= 2 {
		keep := dp(xy, tol)
		if len(keep) <= max {
			out := make([]TPoint, len(keep))
			for k, idx := range keep {
				out[k] = pts[idx]
			}
			return out
		}
	}
	out := make([]TPoint, 0, max)
	step := float64(len(pts)-1) / float64(max-1)
	for k := 0; k < max; k++ {
		out = append(out, pts[int(math.Round(float64(k)*step))])
	}
	return out
}

// dp returns the indexes Douglas–Peucker keeps at tolerance tol (metres).
func dp(xy []geo.Point, tol float64) []int {
	keep := make([]bool, len(xy))
	keep[0], keep[len(xy)-1] = true, true
	type span struct{ a, b int }
	stack := []span{{0, len(xy) - 1}}
	for len(stack) > 0 {
		s := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		far, idx := 0.0, -1
		for i := s.a + 1; i < s.b; i++ {
			if d := xy[i].Dist(geo.ClosestOnSegment(xy[i], xy[s.a], xy[s.b])); d > far {
				far, idx = d, i
			}
		}
		if idx >= 0 && far > tol {
			keep[idx] = true
			stack = append(stack, span{s.a, idx}, span{idx, s.b})
		}
	}
	out := []int{}
	for i, k := range keep {
		if k {
			out = append(out, i)
		}
	}
	return out
}

// round6 keeps ~0.1 m precision in JSON.
func round6(v float64) float64 { return math.Round(v*1e6) / 1e6 }
