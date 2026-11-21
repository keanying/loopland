// Package anticheat evaluates an uploaded activity before it may claim land
// (风控防作弊). Rules are thresholds editable in the admin console; certain
// cheating is voided automatically, suspicious activity goes to manual review.
package anticheat

import (
	"context"
	"encoding/json"
	"fmt"
	"math"

	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/platform/db"
)

// Rules are the admin-tunable thresholds (功能清单 M-23).
type Rules struct {
	RunMaxKmh                float64 `json:"run_max_kmh"`
	RideMaxKmh               float64 `json:"ride_max_kmh"`
	HikeMaxKmh               float64 `json:"hike_max_kmh"`
	WalkMaxKmh               float64 `json:"walk_max_kmh"`
	TeleportM                float64 `json:"teleport_m"`
	GapS                     float64 `json:"gap_s"`
	RequireWearableForEvents bool    `json:"require_wearable_for_events"`
}

// DefaultRules are the launch values.
var DefaultRules = Rules{RunMaxKmh: 20, RideMaxKmh: 45, HikeMaxKmh: 12, WalkMaxKmh: 10, TeleportM: 500, GapS: 30, RequireWearableForEvents: true}

// Validate checks admin input.
func (r Rules) Validate() error {
	for _, v := range []float64{r.RunMaxKmh, r.RideMaxKmh, r.HikeMaxKmh, r.WalkMaxKmh, r.TeleportM, r.GapS} {
		if v <= 0 || v > 10000 {
			return fmt.Errorf("阈值必须是正数")
		}
	}
	return nil
}

// MaxKmh is the average-speed ceiling for a sport.
func (r Rules) MaxKmh(s gameplay.Sport) float64 {
	switch s {
	case gameplay.SportRun:
		return r.RunMaxKmh
	case gameplay.SportRide:
		return r.RideMaxKmh
	case gameplay.SportHike:
		return r.HikeMaxKmh
	case gameplay.SportWalk:
		return r.WalkMaxKmh
	}
	return math.Inf(1)
}

// LoadRules reads the current rules.
func LoadRules(ctx context.Context, q db.Querier) (Rules, error) {
	var raw []byte
	err := q.QueryRow(ctx, `SELECT setting_value FROM src.src_sys_setting WHERE setting_key='risk_rules'`).Scan(&raw)
	if db.IsNoRows(err) {
		return DefaultRules, nil
	}
	if err != nil {
		return Rules{}, err
	}
	r := DefaultRules
	return r, json.Unmarshal(raw, &r)
}

// SaveRules stores new rules (apply to new activities only).
func SaveRules(ctx context.Context, q db.Querier, r Rules) error {
	raw, _ := json.Marshal(r)
	_, err := q.Exec(ctx, `INSERT INTO src.src_sys_setting (setting_key, setting_value) VALUES ('risk_rules', $1)
		ON CONFLICT (setting_key) DO UPDATE SET setting_value=EXCLUDED.setting_value, update_time=now()`, raw)
	return err
}

// Point is one GPS sample.
type Point struct {
	T   int64    `json:"t"` // unix ms
	Lat float64  `json:"lat"`
	Lng float64  `json:"lng"`
	Acc *float64 `json:"acc,omitempty"`
	Spd *float64 `json:"spd,omitempty"`
	HR  *int     `json:"hr,omitempty"`
	Cad *int     `json:"cad,omitempty"`
	Src string   `json:"src,omitempty"`
}

// Device is what the client reports about itself.
type Device struct {
	ID        string `json:"id"`
	Model     string `json:"model"`
	OS        string `json:"os"`
	Rooted    bool   `json:"rooted"`
	Emulator  bool   `json:"emulator"`
	MultiOpen bool   `json:"multi_open"`
}

// Input is everything the rules look at.
type Input struct {
	Sport              gameplay.Sport
	Points             []Point
	DistanceM          float64
	Device             Device
	SameDeviceAccounts int
}

// Flag is one triggered rule.
type Flag struct {
	Rule       string  `json:"rule"`
	Detail     string  `json:"detail"`
	Confidence float64 `json:"-"`
}

// Verdict decides what happens to the activity.
type Verdict string

const (
	Pass   Verdict = "pass"
	Review Verdict = "review"
	Void   Verdict = "void"
)

// Confidence thresholds: at or above voidAt the activity is voided
// automatically, at or above reviewAt it waits for a human. Anything lower
// passes but is still recorded as an alert for monitoring.
const (
	voidAt   = 0.9
	reviewAt = 0.6
)

// Result of an evaluation.
type Result struct {
	Verdict Verdict
	Flags   []Flag
}

// Evaluate applies the rules.
func Evaluate(r Rules, in Input) Result {
	var flags []Flag
	gps := gameplay.GPSSports[in.Sport]
	if gps {
		var mock int
		for _, p := range in.Points {
			if p.Src == "mock" {
				mock++
			}
		}
		if mock > 0 {
			flags = append(flags, Flag{Rule: "mock_location", Confidence: 0.98,
				Detail: fmt.Sprintf("%d 个定位点来自模拟定位", mock)})
		}
		if n := len(in.Points); n >= 2 {
			dur := float64(in.Points[n-1].T-in.Points[0].T) / 1000
			if dur > 0 {
				avg := in.DistanceM / dur * 3.6
				max := r.MaxKmh(in.Sport)
				if avg > max {
					c := 0.75
					if avg > max*1.5 {
						c = 0.95
					}
					flags = append(flags, Flag{Rule: "speed", Confidence: c,
						Detail: fmt.Sprintf("平均速度 %.1f km/h 超过%s上限 %.0f", avg, sportName(in.Sport), max)})
				}
			}
			tp := Teleports(r, in.Sport, in.Points)
			if len(tp) > 0 {
				c := 0.8
				if len(tp) >= 3 {
					c = 0.95
				}
				flags = append(flags, Flag{Rule: "teleport", Confidence: c,
					Detail: fmt.Sprintf("%d 处轨迹瞬移，最大 %.0f m", len(tp), maxJump(tp))})
			}
		}
	}
	if in.Device.Rooted || in.Device.Emulator || in.Device.MultiOpen {
		flags = append(flags, Flag{Rule: "device_tamper", Confidence: 0.65, Detail: "设备已 root / 越狱、是模拟器或多开"})
	}
	if in.Device.ID == "" {
		flags = append(flags, Flag{Rule: "missing_device_data", Confidence: 0.4, Detail: "缺少设备信息"})
	}
	if in.SameDeviceAccounts > 2 {
		flags = append(flags, Flag{Rule: "multi_account", Confidence: 0.55,
			Detail: fmt.Sprintf("同一设备 30 天内登录过 %d 个账号", in.SameDeviceAccounts)})
	}
	v := Pass
	for _, f := range flags {
		switch {
		case f.Confidence >= voidAt:
			v = Void
		case f.Confidence >= reviewAt && v == Pass:
			v = Review
		}
	}
	return Result{Verdict: v, Flags: flags}
}

func sportName(s gameplay.Sport) string {
	return map[gameplay.Sport]string{gameplay.SportRun: "跑步", gameplay.SportRide: "骑行", gameplay.SportHike: "徒步", gameplay.SportWalk: "健走"}[s]
}

// Jump is a teleport segment.
type Jump struct {
	From      geo.LatLng `json:"from"`
	To        geo.LatLng `json:"to"`
	DistanceM float64    `json:"distance_m"`
	GapS      float64    `json:"gap_s"`
}

// Teleports finds consecutive points further apart than the teleport
// distance that also imply a speed beyond twice the sport's limit. A long
// signal gap (tunnel, paused watch) over a plausible distance is not a jump.
func Teleports(r Rules, s gameplay.Sport, pts []Point) []Jump {
	var out []Jump
	max := r.MaxKmh(s)
	for i := 1; i < len(pts); i++ {
		a := geo.LatLng{Lat: pts[i-1].Lat, Lng: pts[i-1].Lng}
		b := geo.LatLng{Lat: pts[i].Lat, Lng: pts[i].Lng}
		d := geo.Haversine(a, b)
		if d < r.TeleportM {
			continue
		}
		gap := float64(pts[i].T-pts[i-1].T) / 1000
		if gap <= 0 || d/gap*3.6 > 2*max {
			out = append(out, Jump{From: a, To: b, DistanceM: d, GapS: gap})
		}
	}
	return out
}

func maxJump(j []Jump) float64 {
	var m float64
	for _, x := range j {
		m = math.Max(m, x.DistanceM)
	}
	return m
}

// SpeedSample is one point of the admin speed curve.
type SpeedSample struct {
	T    int64   `json:"t"`
	Kmh  float64 `json:"kmh"`
	Over bool    `json:"over"`
}

// Speeds computes per-segment speeds for the admin evidence view.
func Speeds(r Rules, s gameplay.Sport, pts []Point) []SpeedSample {
	out := []SpeedSample{}
	max := r.MaxKmh(s)
	for i := 1; i < len(pts); i++ {
		gap := float64(pts[i].T-pts[i-1].T) / 1000
		if gap <= 0 {
			continue
		}
		d := geo.Haversine(geo.LatLng{Lat: pts[i-1].Lat, Lng: pts[i-1].Lng}, geo.LatLng{Lat: pts[i].Lat, Lng: pts[i].Lng})
		k := d / gap * 3.6
		out = append(out, SpeedSample{T: pts[i].T, Kmh: math.Round(k*10) / 10, Over: k > max})
	}
	return out
}
