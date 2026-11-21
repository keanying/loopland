package ai

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// LatLng is a GCJ-02 coordinate.
type LatLng = geo.LatLng

func validLL(p LatLng) bool {
	return p.Lat >= -90 && p.Lat <= 90 && p.Lng >= -180 && p.Lng <= 180 && !(p.Lat == 0 && p.Lng == 0)
}

// Route types, in the order they are suggested.
const (
	RouteLoop    = "loop"
	RouteCapture = "capture"
	RouteDefend  = "defend"
	RouteBoss    = "boss"
)

// RouteTypes are the accepted goal.route_type values.
var RouteTypes = map[string]bool{RouteLoop: true, RouteCapture: true, RouteDefend: true, RouteBoss: true}

// Target is a point of interest on a route.
type Target struct {
	Type string  `json:"type"` // territory | boss | chest
	ID   int64   `json:"id"`
	Name string  `json:"name"`
	Lat  float64 `json:"lat"`
	Lng  float64 `json:"lng"`
	Note string  `json:"note"`
}

// Route is a suggested route (docs/api/v2-3-AI.md «Route»).
type Route struct {
	ID             string       `json:"id"`
	Type           string       `json:"type"`
	Title          string       `json:"title"`
	Subtitle       string       `json:"subtitle"`
	Reason         string       `json:"reason"`
	DistanceM      int          `json:"distance_m"`
	EstDurationSec int          `json:"est_duration_sec"`
	EstAreaM2      int          `json:"est_area_m2"`
	Waypoints      []LatLng     `json:"waypoints"`
	Polyline       [][2]float64 `json:"polyline"`
	Targets        []Target     `json:"targets"`
	AIGenerated    bool         `json:"ai_generated"`

	// facts feed the template reason and the model prompt.
	facts string
}

// Candidate is a target the generator may route to.
type Candidate struct {
	ID     int64
	Name   string
	Center LatLng
	// DistanceM from the origin.
	DistanceM float64
	Guard     int
	AreaM2    float64
	// Owner / Crew describe a territory's holder; Lost marks land the user
	// owned before.
	Owner string
	Crew  string
	Lost  bool
	// Deadline is a defended territory's reinforcement deadline.
	Deadline time.Time
	// HP / MaxHP / RadiusM / EndsAt describe a monster.
	HP, MaxHP int
	RadiusM   float64
	EndsAt    time.Time
}

// PlanInput is everything the rule-based generator uses.
type PlanInput struct {
	Origin LatLng
	Sport  string
	// DistanceM is the loop length to aim for.
	DistanceM float64
	// FromHistory is set when DistanceM is the recent average.
	FromHistory bool
	// PaceSecPerKm estimates the duration.
	PaceSecPerKm float64
	MaxM         float64
	Capture      []Candidate
	Defend       []Candidate
	Bosses       []Candidate
	Now          time.Time
}

// loopSides is the polygon that approximates a closed loop.
const loopSides = 8

// Plan builds up to 4 routes (loop, capture, defend, boss) with straight
// polylines between the waypoints. Routes longer than MaxM are dropped.
func Plan(in PlanInput) []Route {
	if in.Now.IsZero() {
		in.Now = time.Now()
	}
	if in.PaceSecPerKm <= 0 {
		in.PaceSecPerKm = defaultPace(in.Sport)
	}
	if in.MaxM <= 0 {
		in.MaxM = 15000
	}
	in.DistanceM = math.Max(500, math.Min(in.DistanceM, in.MaxM))
	proj := geo.NewProjection(in.Origin)
	var out []Route
	add := func(r Route, ring []geo.Point) {
		r.Waypoints = make([]LatLng, len(ring))
		for i, p := range ring {
			r.Waypoints[i] = round(proj.Inverse(p))
		}
		r.DistanceM = int(math.Round(pathLen(ring)))
		if float64(r.DistanceM) > in.MaxM*1.25 {
			return
		}
		r.Polyline = straight(r.Waypoints)
		r.EstDurationSec = int(math.Round(float64(r.DistanceM) / 1000 * in.PaceSecPerKm))
		if r.Targets == nil {
			r.Targets = []Target{}
		}
		out = append(out, r)
	}

	// Loop: a regular polygon through the origin whose perimeter is the
	// target distance, leaning towards the weakest nearby land.
	heading := math.Pi / 2 // east (angle from north, clockwise)
	if len(in.Capture) > 0 {
		var sx, sy float64
		n := 0
		for _, c := range in.Capture {
			if c.DistanceM <= in.DistanceM/2 {
				p := proj.Forward(c.Center)
				w := 1 / float64(c.Guard+10)
				sx, sy = sx+p.X*w, sy+p.Y*w
				n++
			}
		}
		if n > 0 && (sx != 0 || sy != 0) {
			heading = math.Atan2(sx, sy)
		}
	}
	ring, center, radius := loopRing(in.DistanceM, heading)
	loop := Route{Type: RouteLoop, Title: "AI 推荐闭环",
		Subtitle:  fmt.Sprintf("向%s绕一圈，回到起点圈下约 %.2f km²", direction(heading), polyArea(ring)/1e6),
		EstAreaM2: int(math.Round(polyArea(ring)))}
	for _, c := range in.Capture {
		if len(loop.Targets) >= 3 {
			break
		}
		if proj.Forward(c.Center).Dist(center) <= radius {
			loop.Targets = append(loop.Targets, territoryTarget(c))
		}
	}
	loop.facts = fmt.Sprintf("闭环约 %.1f 公里，约 %d 分钟", in.DistanceM/1000, int(math.Round(in.DistanceM/1000*in.PaceSecPerKm/60)))
	if in.FromHistory {
		loop.facts = fmt.Sprintf("按你近 4 周平均 %.1f 公里规划，", in.DistanceM/1000) + loop.facts
	}
	if n := len(loop.Targets); n > 0 {
		loop.facts += fmt.Sprintf("，途经 %d 块守卫值较低的地", n)
	}
	add(loop, closeRing(ring))

	// Capture: the best land by benefit / distance.
	if best, ok := bestCapture(in.Capture); ok {
		half := math.Max(math.Sqrt(math.Max(best.AreaM2, 1))/2+30, 60)
		ring := aroundSquare(proj.Forward(best.Center), half, geo.Point{})
		title := "抢下「" + best.Name + "」"
		if best.Lost {
			title = "夺回「" + best.Name + "」"
		}
		r := Route{Type: RouteCapture, Title: title,
			Subtitle:  fmt.Sprintf("往%s约 %.1f km，绕这块地一圈圈下它", direction(bearing(in.Origin, best.Center)), best.DistanceM/1000),
			EstAreaM2: int(math.Round(4 * half * half)), Targets: []Target{territoryTarget(best)}}
		r.facts = fmt.Sprintf("「%s」守卫值 %d，离你 %.1f 公里", best.Name, best.Guard, best.DistanceM/1000)
		add(r, append(append([]geo.Point{{}}, ring...), geo.Point{}))
	}

	// Defend: my land still in its 24-hour reinforcement window, the most
	// urgent first.
	if len(in.Defend) > 0 {
		d := in.Defend[0]
		for _, c := range in.Defend[1:] {
			if c.Deadline.Before(d.Deadline) {
				d = c
			}
		}
		half := math.Max(math.Sqrt(math.Max(d.AreaM2, 1))/2*0.6, 20)
		ring := aroundSquare(proj.Forward(d.Center), half, geo.Point{})
		left := math.Max(0, d.Deadline.Sub(in.Now).Hours())
		t := territoryTarget(d)
		t.Note = fmt.Sprintf("被攻击，加固期还剩 %.0f 小时 · 守卫值 %d", math.Ceil(left), d.Guard)
		r := Route{Type: RouteDefend, Title: "守住「" + d.Name + "」",
			Subtitle: fmt.Sprintf("加固期还剩 %.0f 小时，跑进领地就能加固", math.Ceil(left)), Targets: []Target{t}}
		r.facts = fmt.Sprintf("「%s」被攻击，还剩 %.0f 小时加固，离你 %.1f 公里", d.Name, math.Ceil(left), d.DistanceM/1000)
		add(r, append(append([]geo.Point{{}}, ring...), geo.Point{}))
	}

	// Boss: the nearest active monster.
	if len(in.Bosses) > 0 {
		b := in.Bosses[0]
		for _, c := range in.Bosses[1:] {
			if c.DistanceM < b.DistanceM {
				b = c
			}
		}
		half := math.Max(math.Min(b.RadiusM*0.6, 300), 50)
		ring := aroundSquare(proj.Forward(b.Center), half, geo.Point{})
		pct := 0
		if b.MaxHP > 0 {
			pct = int(math.Round(float64(b.HP) * 100 / float64(b.MaxHP)))
		}
		r := Route{Type: RouteBoss, Title: "顺路打「" + b.Name + "」",
			Subtitle: fmt.Sprintf("怪兽在%s %.1f km，剩余血量 %d%%", direction(bearing(in.Origin, b.Center)), b.DistanceM/1000, pct),
			Targets: []Target{{Type: "boss", ID: b.ID, Name: b.Name, Lat: b.Center.Lat, Lng: b.Center.Lng,
				Note: fmt.Sprintf("血量 %d / %d · 还剩 %.0f 小时", b.HP, b.MaxHP, math.Ceil(math.Max(0, b.EndsAt.Sub(in.Now).Hours())))}}}
		r.facts = fmt.Sprintf("「%s」剩余血量 %d%%，离你 %.1f 公里，跑进范围就能造成伤害", b.Name, pct, b.DistanceM/1000)
		add(r, append(append([]geo.Point{{}}, ring...), geo.Point{}))
	}
	return out
}

// loopRing returns the polygon vertices (origin first, not closed), its
// centre and circumradius for a loop of length d heading away from the
// origin.
func loopRing(d, heading float64) ([]geo.Point, geo.Point, float64) {
	r := d / (2 * loopSides * math.Sin(math.Pi/loopSides))
	center := geo.Point{X: r * math.Sin(heading), Y: r * math.Cos(heading)}
	start := math.Atan2(-center.Y, -center.X) // angle (from +x) of the origin seen from the centre
	ring := make([]geo.Point, loopSides)
	for k := range loopSides {
		a := start + float64(k)*2*math.Pi/loopSides
		ring[k] = geo.Point{X: center.X + r*math.Cos(a), Y: center.Y + r*math.Sin(a)}
	}
	ring[0] = geo.Point{}
	return ring, center, r
}

// aroundSquare is a square of half-size h around c, starting from the
// corner nearest to from.
func aroundSquare(c geo.Point, h float64, from geo.Point) []geo.Point {
	corners := []geo.Point{{X: c.X - h, Y: c.Y - h}, {X: c.X + h, Y: c.Y - h}, {X: c.X + h, Y: c.Y + h}, {X: c.X - h, Y: c.Y + h}}
	best := 0
	for i, p := range corners {
		if p.Dist(from) < corners[best].Dist(from) {
			best = i
		}
	}
	out := append(append([]geo.Point{}, corners[best:]...), corners[:best]...)
	return append(out, out[0])
}

func closeRing(ring []geo.Point) []geo.Point { return append(append([]geo.Point{}, ring...), ring[0]) }

func pathLen(pts []geo.Point) float64 {
	var d float64
	for i := 1; i < len(pts); i++ {
		d += pts[i].Dist(pts[i-1])
	}
	return d
}

func polyArea(ring []geo.Point) float64 { return geo.RingArea(ring) }

func bestCapture(cs []Candidate) (Candidate, bool) {
	var best Candidate
	bestScore := -1.0
	for _, c := range cs {
		// Benefit: bigger, weaker land; cost: distance.
		score := (math.Sqrt(math.Max(c.AreaM2, 100)) / float64(c.Guard+20)) / (c.DistanceM/1000 + 0.3)
		if c.Lost {
			score *= 1.5
		}
		if score > bestScore {
			best, bestScore = c, score
		}
	}
	return best, bestScore >= 0
}

func territoryTarget(c Candidate) Target {
	note := fmt.Sprintf("守卫值 %d", c.Guard)
	switch {
	case c.Crew != "":
		note = "「" + c.Crew + "」占领 · " + note
	case c.Owner != "":
		note = c.Owner + " 占领 · " + note
	}
	if c.Guard < 100 {
		note += "，较易夺回"
	}
	if c.Lost {
		note = "你丢掉的地 · " + note
	}
	return Target{Type: "territory", ID: c.ID, Name: c.Name, Lat: c.Center.Lat, Lng: c.Center.Lng, Note: note}
}

func round(p LatLng) LatLng {
	return LatLng{Lat: math.Round(p.Lat*1e6) / 1e6, Lng: math.Round(p.Lng*1e6) / 1e6}
}

func straight(wps []LatLng) [][2]float64 {
	out := make([][2]float64, len(wps))
	for i, p := range wps {
		out[i] = [2]float64{p.Lng, p.Lat}
	}
	return out
}

// bearing is the angle from north, clockwise, in radians.
func bearing(a, b LatLng) float64 {
	p := geo.NewProjection(a).Forward(b)
	return math.Atan2(p.X, p.Y)
}

func direction(heading float64) string {
	names := []string{"北", "东北", "东", "东南", "南", "西南", "西", "西北"}
	deg := math.Mod(heading*180/math.Pi+360+22.5, 360)
	return names[int(deg/45)%8]
}

func defaultPace(sport string) float64 {
	switch sport {
	case "ride":
		return 180
	case "hike":
		return 720
	case "walk":
		return 600
	}
	return 390
}

func defaultDistance(sport string) float64 {
	switch sport {
	case "ride":
		return 15000
	case "walk":
		return 3000
	}
	return 5000
}

// routeID is stable for one user, place, type and target within the cache.
func routeID(user int64, origin LatLng, r Route) string {
	key := fmt.Sprintf("%d|%.3f|%.3f|%s|%d", user, origin.Lat, origin.Lng, r.Type, r.DistanceM)
	if len(r.Targets) > 0 {
		key += fmt.Sprintf("|%d", r.Targets[0].ID)
	}
	h := sha1.Sum([]byte(key))
	return "r_" + hex.EncodeToString(h[:3])
}

func templateReason(r Route) string {
	switch r.Type {
	case RouteLoop:
		return r.facts + "，回到起点就能圈下一整块。"
	case RouteCapture:
		return r.facts + "，守卫低、离得近，最划算。"
	case RouteDefend:
		return r.facts + "，抓紧跑一趟守住它。"
	case RouteBoss:
		return r.facts + "。"
	}
	return r.facts
}

// ---------------------------------------------------------------- 高德 path planning

// snap replaces straight segments with 高德 walking / riding paths. A
// segment that fails keeps its straight line. It returns the new length.
func (s *Service) snap(ctx context.Context, key, sport string, r *Route) {
	if key == "" || len(r.Waypoints) < 2 {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	var poly [][2]float64
	total := 0.0
	snapped := false
	for i := 1; i < len(r.Waypoints); i++ {
		a, b := r.Waypoints[i-1], r.Waypoints[i]
		pts, d, err := s.amapPath(ctx, key, sport, a, b)
		if err != nil || len(pts) == 0 {
			if s.Log != nil && err != nil {
				s.Log.Warn("amap path", "err", err)
			}
			pts = [][2]float64{{a.Lng, a.Lat}, {b.Lng, b.Lat}}
			d = geo.Haversine(a, b)
		} else {
			snapped = true
		}
		if len(poly) > 0 && len(pts) > 0 && poly[len(poly)-1] == pts[0] {
			pts = pts[1:]
		}
		poly = append(poly, pts...)
		total += d
	}
	if snapped {
		r.Polyline = poly
		r.DistanceM = int(math.Round(total))
	}
}

func (s *Service) amapBase() string {
	if s.AMapBase != "" {
		return strings.TrimRight(s.AMapBase, "/")
	}
	return "https://restapi.amap.com"
}

// amapPath plans one segment: v3 walking (run, hike, walk) or v4
// bicycling (ride).
func (s *Service) amapPath(ctx context.Context, key, sport string, a, b LatLng) ([][2]float64, float64, error) {
	q := url.Values{"origin": {fmt.Sprintf("%.6f,%.6f", a.Lng, a.Lat)}, "destination": {fmt.Sprintf("%.6f,%.6f", b.Lng, b.Lat)}, "key": {key}}
	u := s.amapBase() + "/v3/direction/walking?" + q.Encode()
	if sport == "ride" {
		u = s.amapBase() + "/v4/direction/bicycling?" + q.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, 0, err
	}
	hc := s.HTTP
	if hc == nil {
		hc = http.DefaultClient
	}
	resp, err := hc.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	type path struct {
		Distance json.RawMessage `json:"distance"`
		Steps    []struct {
			Polyline string `json:"polyline"`
		} `json:"steps"`
	}
	var body struct {
		Status string `json:"status"`
		Info   string `json:"info"`
		Route  struct {
			Paths []path `json:"paths"`
		} `json:"route"`
		ErrCode *int   `json:"errcode"`
		ErrMsg  string `json:"errmsg"`
		Data    struct {
			Paths []path `json:"paths"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, 0, err
	}
	paths := body.Route.Paths
	if sport == "ride" {
		if body.ErrCode == nil || *body.ErrCode != 0 {
			return nil, 0, fmt.Errorf("高德骑行规划失败：%s", body.ErrMsg)
		}
		paths = body.Data.Paths
	} else if body.Status != "1" {
		return nil, 0, fmt.Errorf("高德步行规划失败：%s", body.Info)
	}
	if len(paths) == 0 {
		return nil, 0, fmt.Errorf("高德没有返回路径")
	}
	p := paths[0]
	d, _ := strconv.ParseFloat(strings.Trim(string(p.Distance), `"`), 64)
	var out [][2]float64
	for _, st := range p.Steps {
		for _, pair := range strings.Split(st.Polyline, ";") {
			lng, lat, ok := strings.Cut(pair, ",")
			if !ok {
				continue
			}
			x, err1 := strconv.ParseFloat(lng, 64)
			y, err2 := strconv.ParseFloat(lat, 64)
			if err1 != nil || err2 != nil {
				continue
			}
			pt := [2]float64{x, y}
			if len(out) > 0 && out[len(out)-1] == pt {
				continue
			}
			out = append(out, pt)
		}
	}
	if d == 0 {
		for i := 1; i < len(out); i++ {
			d += geo.Haversine(LatLng{Lat: out[i-1][1], Lng: out[i-1][0]}, LatLng{Lat: out[i][1], Lng: out[i][0]})
		}
	}
	return out, d, nil
}

// ---------------------------------------------------------------- data and endpoint

// gpsSports can follow a route.
var gpsSports = map[string]bool{"run": true, "ride": true, "hike": true, "walk": true}

// planInput gathers the user's history and the targets around origin.
func (s *Service) planInput(ctx context.Context, user int64, origin LatLng, sport string, distanceKm *float64) (PlanInput, error) {
	cfg := s.Config.For(user)
	in := PlanInput{Origin: origin, Sport: sport, MaxM: cfg.AI.RouteMaxKm * 1000, Now: time.Now()}
	var avgM, distSum float64
	var durSum int
	var n int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*), COALESCE(avg(distance_m), 0), COALESCE(sum(distance_m), 0), COALESCE(sum(duration_sec), 0)
		FROM src.src_act_loop_activity WHERE user_id=$1 AND sport=$2 AND status='settled' AND distance_m > 300 AND start_time > now() - interval '28 days'`,
		user, sport).Scan(&n, &avgM, &distSum, &durSum); err != nil {
		return in, err
	}
	if n > 0 && distSum > 0 {
		in.PaceSecPerKm = float64(durSum) / (distSum / 1000)
	}
	switch {
	case distanceKm != nil:
		in.DistanceM = *distanceKm * 1000
	case n > 0 && avgM >= 1000:
		in.DistanceM, in.FromHistory = avgM, true
	default:
		in.DistanceM = defaultDistance(sport)
	}
	var err error
	if in.Capture, err = s.captureCandidates(ctx, user, origin, 3000, 20); err != nil {
		return in, err
	}
	if in.Defend, err = s.defendCandidates(ctx, user, origin); err != nil {
		return in, err
	}
	in.Bosses, err = s.bossCandidates(ctx, origin, 5000)
	return in, err
}

const pointSQL = `ST_SetSRID(ST_MakePoint($2, $3), 4326)`

// captureCandidates are other people's land around origin, weakest first;
// land the user lost in the last 7 days is marked.
func (s *Service) captureCandidates(ctx context.Context, user int64, origin LatLng, radiusM float64, limit int) ([]Candidate, error) {
	rows, err := s.Pool.Query(ctx, `SELECT t.id, COALESCE(t.name, '领地 #' || t.id), ST_Y(ST_PointOnSurface(t.area_geom)), ST_X(ST_PointOnSurface(t.area_geom)),
			ST_Distance(ST_PointOnSurface(t.area_geom)::geography, `+pointSQL+`::geography), t.guard, t.area_m2, COALESCE(u.nickname, ''), COALESCE(c.name, ''),
			EXISTS (SELECT 1 FROM src.src_ter_loop_event e WHERE e.territory_id=t.id AND e.prev_owner_id=$1 AND e.event_type IN ('capture', 'capture_whole')
			        AND e.create_time > now() - interval '7 days')
		FROM src.src_ter_loop_territory t JOIN src.src_usr_loop_user u ON u.id=t.owner_user_id
		LEFT JOIN src.src_soc_loop_crew c ON c.id=t.owner_crew_id
		WHERE t.owner_user_id <> $1 AND NOT t.is_frozen AND ST_DWithin(t.area_geom::geography, `+pointSQL+`::geography, $4)
		ORDER BY t.guard, 5 LIMIT $5`, user, origin.Lng, origin.Lat, radiusM, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Candidate
	for rows.Next() {
		var c Candidate
		if err := rows.Scan(&c.ID, &c.Name, &c.Center.Lat, &c.Center.Lng, &c.DistanceM, &c.Guard, &c.AreaM2, &c.Owner, &c.Crew, &c.Lost); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// defendCandidates are the user's land in its reinforcement window.
func (s *Service) defendCandidates(ctx context.Context, user int64, origin LatLng) ([]Candidate, error) {
	rows, err := s.Pool.Query(ctx, `SELECT t.id, COALESCE(t.name, '领地 #' || t.id), ST_Y(ST_PointOnSurface(t.area_geom)), ST_X(ST_PointOnSurface(t.area_geom)),
			ST_Distance(ST_PointOnSurface(t.area_geom)::geography, `+pointSQL+`::geography), t.guard, t.area_m2, d.deadline_time
		FROM src.src_ter_loop_defense d JOIN src.src_ter_loop_territory t ON t.id=d.territory_id
		WHERE t.owner_user_id=$1 AND d.deadline_time > now() ORDER BY d.deadline_time LIMIT 10`, user, origin.Lng, origin.Lat)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Candidate
	for rows.Next() {
		var c Candidate
		if err := rows.Scan(&c.ID, &c.Name, &c.Center.Lat, &c.Center.Lng, &c.DistanceM, &c.Guard, &c.AreaM2, &c.Deadline); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// bossCandidates are active monsters around origin, nearest first.
func (s *Service) bossCandidates(ctx context.Context, origin LatLng, radiusM float64) ([]Candidate, error) {
	rows, err := s.Pool.Query(ctx, `SELECT b.id, b.name, ST_Y(b.center_geom), ST_X(b.center_geom), ST_Distance(b.center_geom::geography, `+pointSQL+`::geography),
			b.hp, b.hp_max, b.radius_m, b.expire_time
		FROM src.src_ply_loop_boss b WHERE b.status='active' AND b.expire_time > now()
		  AND ST_DWithin(b.center_geom::geography, `+pointSQL+`::geography, $1)
		ORDER BY 5 LIMIT 5`, radiusM, origin.Lng, origin.Lat)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Candidate
	for rows.Next() {
		var c Candidate
		if err := rows.Scan(&c.ID, &c.Name, &c.Center.Lat, &c.Center.Lng, &c.DistanceM, &c.HP, &c.MaxHP, &c.RadiusM, &c.EndsAt); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// Suggest builds the routes for a user at origin: rule-based candidates,
// 高德 paths when configured, and (withReasons) one sentence per route from
// the small model. Results are cached for 10 minutes per user, ~200 m
// grid cell, sport and distance.
func (s *Service) Suggest(ctx context.Context, user int64, origin LatLng, sport string, distanceKm *float64, withReasons bool) ([]Route, error) {
	dk := 0
	if distanceKm != nil {
		dk = int(math.Round(*distanceKm * 10))
	}
	cacheKey := fmt.Sprintf("ai:routes:%d:%d:%d:%s:%d", user, int(math.Floor(origin.Lat/0.0018)), int(math.Floor(origin.Lng/0.0021)), sport, dk)
	if s.Redis != nil {
		if raw, err := s.Redis.Get(ctx, cacheKey).Bytes(); err == nil {
			var cached []Route
			if json.Unmarshal(raw, &cached) == nil {
				return cached, nil
			}
		}
	}
	in, err := s.planInput(ctx, user, origin, sport, distanceKm)
	if err != nil {
		return nil, err
	}
	routes := Plan(in)
	key := ""
	if s.AMapKey != nil {
		key = s.AMapKey()
	}
	for i := range routes {
		r := &routes[i]
		if key != "" {
			s.snap(ctx, key, sport, r)
			// Keep the loop within ±25% of the target on the road network.
			if r.Type == RouteLoop && (float64(r.DistanceM) > in.DistanceM*1.25 || float64(r.DistanceM) < in.DistanceM*0.75) && r.DistanceM > 0 {
				scaled := in
				scaled.DistanceM = in.DistanceM * in.DistanceM / float64(r.DistanceM)
				if again := Plan(scaled); len(again) > 0 && again[0].Type == RouteLoop {
					nr := again[0]
					s.snap(ctx, key, sport, &nr)
					*r = nr
				}
			}
			r.EstDurationSec = int(math.Round(float64(r.DistanceM) / 1000 * in.PaceSecPerKm))
		}
		r.ID = routeID(user, origin, *r)
		r.Reason = templateReason(*r)
	}
	if withReasons && len(routes) > 0 {
		s.reasons(ctx, user, routes)
	}
	if withReasons && s.Redis != nil {
		if raw, err := json.Marshal(routes); err == nil {
			s.Redis.Set(ctx, cacheKey, raw, 10*time.Minute)
		}
	}
	return routes, nil
}

// reasons asks the small model for one sentence per route (JSON mode);
// routes it could not explain keep the template and ai_generated=false.
func (s *Service) reasons(ctx context.Context, user int64, routes []Route) {
	b, err := s.Backend()
	if err != nil {
		return
	}
	var facts []string
	for i, r := range routes {
		facts = append(facts, fmt.Sprintf("%d. [%s] %s：%s；%s", i+1, r.Type, r.Title, r.Subtitle, r.facts))
	}
	resp, err := s.Call(ctx, b, FeatureRoute, user, Request{Model: b.SmallModel, JSON: true, MaxTokens: 400, Messages: []Message{
		{Role: "system", Content: promptRouteReasons},
		{Role: "user", Content: strings.Join(facts, "\n")},
	}}, nil)
	if err != nil {
		return
	}
	var out struct {
		Reasons []string `json:"reasons"`
	}
	if json.Unmarshal([]byte(extractJSON(resp.Content)), &out) != nil {
		return
	}
	for i := range routes {
		if i >= len(out.Reasons) {
			break
		}
		txt := strings.TrimSpace(out.Reasons[i])
		if txt == "" || len([]rune(txt)) > 80 || (s.Mod != nil && s.Mod.Check(ctx, txt, false).Blocked) {
			continue
		}
		routes[i].Reason, routes[i].AIGenerated = txt, true
	}
}

// extractJSON trims code fences some models wrap JSON in.
func extractJSON(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.Index(s, "{"); i >= 0 {
		if j := strings.LastIndex(s, "}"); j > i {
			return s[i : j+1]
		}
	}
	return s
}

func (h *Handler) routes(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	p, err := point(r)
	if err != nil {
		return err
	}
	if p == nil {
		return httpx.BadRequest("invalid_body", "需要 lat 和 lng")
	}
	sport := r.URL.Query().Get("sport")
	if sport == "" {
		sport = "run"
	}
	if !gpsSports[sport] {
		return httpx.BadRequest("invalid_body", "sport 只能是 run / ride / hike / walk")
	}
	dk, err := queryFloat(r, "distance_km")
	if err != nil {
		return err
	}
	uid := httpx.UserID(ctx)
	if dk != nil {
		maxKm := h.Svc.Config.For(uid).AI.RouteMaxKm
		if *dk <= 0 || *dk > maxKm {
			return httpx.BadRequest("invalid_body", fmt.Sprintf("distance_km 应在 0–%.0f 之间", maxKm))
		}
	}
	if _, err := h.Svc.Backend(); err != nil {
		return err
	}
	routes, err := h.Svc.Suggest(ctx, uid, *p, sport, dk, true)
	if err != nil {
		return err
	}
	if routes == nil {
		routes = []Route{}
	}
	sort.SliceStable(routes, func(i, j int) bool { return routeOrder[routes[i].Type] < routeOrder[routes[j].Type] })
	return httpx.OK(w, map[string]any{"items": routes, "ai_generated": true})
}

var routeOrder = map[string]int{RouteLoop: 0, RouteCapture: 1, RouteDefend: 2, RouteBoss: 3}
