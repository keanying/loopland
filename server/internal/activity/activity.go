// Package activity handles uploads (运动上传), the anti-cheat verdict and
// settlement: energy with the daily cap, land claims, recruitment, eggs,
// medals. It also provides the admin paths that settle a reviewed activity
// or void a settled one.
package activity

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/anticheat"
	"github.com/keanying/loopland/server/internal/claim"
	"github.com/keanying/loopland/server/internal/codex"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/territory"
)

// MaxPoints bounds one upload.
const MaxPoints = 20000

// V1Sports are the sports that can be uploaded in V1. Venue check-ins and
// swimming come with 场馆 in V2.
var V1Sports = map[gameplay.Sport]bool{
	gameplay.SportRun: true, gameplay.SportRide: true, gameplay.SportHike: true, gameplay.SportWalk: true,
	gameplay.SportStrength: true, gameplay.SportYoga: true, gameplay.SportRope: true, gameplay.SportHIIT: true,
}

// Goal is the pre-run target. type ai_route carries the chosen AI route
// (docs/api/v2-3-AI.md, for the adoption rate).
type Goal struct {
	Type        string   `json:"type"`
	Value       *float64 `json:"value,omitempty"`
	TerritoryID *int64   `json:"territory_id,omitempty"`
	RouteID     string   `json:"route_id,omitempty"`
	RouteType   string   `json:"route_type,omitempty"`
}

// aiRouteTypes are the route types of goal.type=ai_route.
var aiRouteTypes = map[string]bool{"loop": true, "capture": true, "defend": true, "boss": true}

// Coach is the AI follow-along report of a home workout (AI 跟练).
type Coach struct {
	WorkoutKey   string `json:"workout_key"`
	Camera       bool   `json:"camera"`
	RepsDetected int    `json:"reps_detected"`
	RepsManual   int    `json:"reps_manual"`
	SetsDone     int    `json:"sets_done"`
}

// Upload is POST /v1/activities.
type Upload struct {
	ClientID  string            `json:"client_id"`
	Sport     gameplay.Sport    `json:"sport"`
	StartedAt time.Time         `json:"started_at"`
	EndedAt   time.Time         `json:"ended_at"`
	DurationS int               `json:"duration_s"`
	Goal      *Goal             `json:"goal,omitempty"`
	Points    []anticheat.Point `json:"points"`
	Amount    float64           `json:"amount"`
	Device    anticheat.Device  `json:"device"`
	Wearable  *struct {
		Brand string `json:"brand"`
	} `json:"wearable,omitempty"`
	Coach *Coach `json:"coach,omitempty"`
}

// Settlement is what the run earned.
type Settlement struct {
	Status        string                `json:"status"`
	EnergyRaw     int                   `json:"energy_raw"`
	EnergyGranted int                   `json:"energy_granted"`
	EnergyCapped  bool                  `json:"energy_capped"`
	Claims        []territory.ClaimRef  `json:"claims"`
	Attacks       []territory.AttackRef `json:"attacks"`
	Recruits      []codex.Recruit       `json:"recruits"`
	Eggs          []codex.Egg           `json:"eggs"`
	Medals        []codex.MedalRef      `json:"medals"`
	LevelUp       *int                  `json:"level_up"`
	Flags         []anticheat.Flag      `json:"flags"`
	Extra
}

// Extra holds the V2 gameplay blocks (docs/api/v2-1-玩法.md), filled by
// the Hook.
type Extra struct {
	BossDamage []BossHit      `json:"boss_damage"`
	Chests     []ChestOpen    `json:"chests"`
	Defended   []Defended     `json:"defended"`
	Routes     []RouteStep    `json:"routes"`
	Campaigns  []CampaignDone `json:"campaigns"`
	Tasks      []TaskProgress `json:"tasks"`
	Companion  *CompanionGain `json:"companion"`
	Relay      *RelayLeg      `json:"relay"`
	// Rally and Races are filled by the Community step
	// (docs/api/v2-2-社区.md).
	Rally *RallyBonus `json:"rally"`
	Races []RaceDone  `json:"races"`
}

// RallyBonus is the crew rally bonus applied to this activity (集结跑加成).
type RallyBonus struct {
	ID        int64   `json:"id"`
	BonusRate float64 `json:"bonus_rate"`
}

// RaceMedal is a race's finisher medal.
type RaceMedal struct {
	Key      string  `json:"key"`
	Name     string  `json:"name"`
	ImageURL *string `json:"image_url"`
}

// RaceDone is an online race finished by this activity.
type RaceDone struct {
	ID        int64     `json:"id"`
	Title     string    `json:"title"`
	ResultSec int       `json:"result_sec"`
	Medal     RaceMedal `json:"medal"`
}

// BossHit is damage dealt to a city monster.
type BossHit struct {
	BossID   int64  `json:"boss_id"`
	Name     string `json:"name"`
	Damage   int    `json:"damage"`
	Defeated bool   `json:"defeated"`
}

// ChestOpen is a chest opened on the way.
type ChestOpen struct {
	ChestID int64 `json:"chest_id"`
	Energy  int   `json:"energy"`
}

// Defended is a reinforced territory (守地挑战).
type Defended struct {
	TerritoryID int64 `json:"territory_id"`
	GuardBefore int   `json:"guard_before"`
	GuardAfter  int   `json:"guard_after"`
}

// RouteStep is orienteering progress.
type RouteStep struct {
	RouteID   int64    `json:"route_id"`
	Name      string   `json:"name"`
	Reached   []string `json:"reached"`
	Completed bool     `json:"completed"`
}

// CampaignDone is a completed limited-time campaign.
type CampaignDone struct {
	CampaignID   int64  `json:"campaign_id"`
	Title        string `json:"title"`
	RewardEnergy int    `json:"reward_energy"`
}

// TaskProgress is a season task's progress after this activity.
type TaskProgress struct {
	Key          string  `json:"key"`
	Name         string  `json:"name"`
	Progress     float64 `json:"progress"`
	Target       float64 `json:"target"`
	Completed    bool    `json:"completed"`
	RewardEnergy int     `json:"reward_energy"`
}

// CompanionGain is the escort companion's growth.
type CompanionGain struct {
	Key     string `json:"key"`
	Exp     int    `json:"exp"`
	Level   int    `json:"level"`
	LevelUp bool   `json:"level_up"`
}

// RelayLeg is a leg run for the crew relay.
type RelayLeg struct {
	RelayID   int64 `json:"relay_id"`
	Leg       int   `json:"leg"`
	Legs      int   `json:"legs"`
	Completed bool  `json:"completed"`
}

// HookInput is what the gameplay hook needs about a settled activity.
type HookInput struct {
	Config     gameplay.Config
	ActivityID int64
	UserID     int64
	CrewID     *int64
	Sport      gameplay.Sport
	Amount     float64
	DistanceM  float64
	DurationS  int
	StartedAt  time.Time
	EndedAt    time.Time
	// Wearable is set when the upload carried wearable device data.
	Wearable  bool
	Points    []geo.LatLng
	EnergyRaw int
	Claims    []territory.ClaimRef
	Attacks   []territory.AttackRef
	// BonusRate (集结跑加成) multiplies the monster damage this activity
	// deals: damage × (1 + BonusRate). Energy is already multiplied.
	BonusRate float64
}

// Hook runs V2 gameplay inside the settlement transaction. The returned
// function (may be nil) runs after commit, e.g. to publish realtime events.
type Hook interface {
	AfterSettle(ctx context.Context, tx pgx.Tx, in HookInput) (Extra, func(context.Context), error)
}

// Community is the optional 社区 step of settlement.
type Community interface {
	// RallyBonus runs before energy is granted (in has no energy, claims or
	// attacks yet). A non-nil result multiplies the activity's energy and
	// monster damage by 1 + BonusRate.
	RallyBonus(ctx context.Context, tx pgx.Tx, in HookInput) (*RallyBonus, error)
	// FinishRaces runs after the gameplay hook and completes online races.
	FinishRaces(ctx context.Context, tx pgx.Tx, in HookInput) ([]RaceDone, error)
}

func emptyExtra() Extra {
	return Extra{BossDamage: []BossHit{}, Chests: []ChestOpen{}, Defended: []Defended{}, Routes: []RouteStep{}, Campaigns: []CampaignDone{}, Tasks: []TaskProgress{}, Races: []RaceDone{}}
}

func emptySettlement(status string, flags []anticheat.Flag) Settlement {
	if flags == nil {
		flags = []anticheat.Flag{}
	}
	return Settlement{Status: status, Claims: []territory.ClaimRef{}, Attacks: []territory.AttackRef{},
		Recruits: []codex.Recruit{}, Eggs: []codex.Egg{}, Medals: []codex.MedalRef{}, Flags: flags, Extra: emptyExtra()}
}

// View is the Activity object.
type View struct {
	ID            int64                `json:"id"`
	Sport         string               `json:"sport"`
	Status        string               `json:"status"`
	StartedAt     time.Time            `json:"started_at"`
	EndedAt       time.Time            `json:"ended_at"`
	DistanceM     float64              `json:"distance_m"`
	DurationS     int                  `json:"duration_s"`
	AvgPaceSPerKm *int                 `json:"avg_pace_s_per_km"`
	Amount        float64              `json:"amount"`
	EnergyGranted int                  `json:"energy_granted"`
	ClaimedAreaM2 float64              `json:"claimed_area_m2"`
	Track         json.RawMessage      `json:"track,omitempty"`
	Claims        []territory.ClaimRef `json:"claims,omitempty"`
}

// Result is the upload response.
type Result struct {
	Activity   View       `json:"activity"`
	Settlement Settlement `json:"settlement"`
}

// Service runs uploads and settlements.
type Service struct {
	Pool   *pgxpool.Pool
	Config *gameplay.Store
	Hook   Hook // optional V2 gameplay
	// Community is optional: crew rally bonus and online races.
	Community Community
}

func badRequest(msg string) error { return httpx.BadRequest("invalid_body", msg) }

func (u *Upload) validate() error {
	if _, err := uuid.Parse(u.ClientID); err != nil {
		return badRequest("client_id 必须是 UUID")
	}
	if !V1Sports[u.Sport] {
		return httpx.BadRequest("sport_not_supported", "这项运动暂未开放")
	}
	if u.EndedAt.Before(u.StartedAt) || u.EndedAt.Sub(u.StartedAt) > 24*time.Hour {
		return badRequest("开始和结束时间不合法")
	}
	if len(u.Points) > MaxPoints {
		return httpx.E(http.StatusRequestEntityTooLarge, "too_many_points", "单次最多 %d 个定位点", MaxPoints)
	}
	if gameplay.GPSSports[u.Sport] {
		for i, p := range u.Points {
			if p.Lat < -90 || p.Lat > 90 || p.Lng < -180 || p.Lng > 180 {
				return badRequest(fmt.Sprintf("第 %d 个点坐标不合法", i))
			}
			if i > 0 && p.T < u.Points[i-1].T {
				return badRequest("定位点必须按时间升序")
			}
		}
	} else {
		u.Points = nil
		if u.Amount < 0 || math.IsNaN(u.Amount) {
			return badRequest("amount 不合法")
		}
	}
	if g := u.Goal; g != nil && g.Type == "ai_route" {
		if g.RouteID == "" || len(g.RouteID) > 64 || !aiRouteTypes[g.RouteType] {
			return badRequest("goal.route_id 不能为空，route_type 只能是 loop / capture / defend / boss")
		}
	}
	if c := u.Coach; c != nil {
		if gameplay.GPSSports[u.Sport] {
			return badRequest("coach 只用于居家训练")
		}
		if c.RepsDetected < 0 || c.RepsManual < 0 || c.SetsDone < 0 || len(c.WorkoutKey) > 64 {
			return badRequest("coach 数值不合法")
		}
	}
	return nil
}

func distance(pts []anticheat.Point) float64 {
	var d float64
	for i := 1; i < len(pts); i++ {
		d += geo.Haversine(geo.LatLng{Lat: pts[i-1].Lat, Lng: pts[i-1].Lng}, geo.LatLng{Lat: pts[i].Lat, Lng: pts[i].Lng})
	}
	return d
}

func trackWKT(pts []anticheat.Point) *string {
	if len(pts) < 2 {
		return nil
	}
	var b strings.Builder
	b.WriteString("LINESTRING(")
	for i, p := range pts {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(&b, "%.7f %.7f", p.Lng, p.Lat)
	}
	b.WriteByte(')')
	s := b.String()
	return &s
}

// Submit stores and settles an upload. It is idempotent on client_id.
func (s *Service) Submit(ctx context.Context, user int64, u Upload) (Result, error) {
	if err := u.validate(); err != nil {
		return Result{}, err
	}
	var consents []byte
	var status string
	if err := s.Pool.QueryRow(ctx, `SELECT consents_json, status FROM src.src_usr_loop_user WHERE id=$1`, user).Scan(&consents, &status); err != nil {
		return Result{}, err
	}
	var c struct {
		PrivacyVersion string `json:"privacy_version"`
		Location       bool   `json:"location"`
	}
	_ = json.Unmarshal(consents, &c)
	if c.PrivacyVersion == "" || (gameplay.GPSSports[u.Sport] && !c.Location) {
		return Result{}, httpx.Forbidden("consent_required", "请先同意隐私政策和定位授权")
	}
	if status == "banned" {
		return Result{}, httpx.Forbidden("account_banned", "账号已被封禁")
	}
	if r, ok, err := s.existing(ctx, user, u.ClientID); err != nil || ok {
		return r, err
	}

	dist := 0.0
	duration := u.DurationS
	amount := u.Amount
	if gameplay.GPSSports[u.Sport] {
		dist = distance(u.Points)
		amount = dist / 1000
		if n := len(u.Points); n >= 2 && duration <= 0 {
			duration = int((u.Points[n-1].T - u.Points[0].T) / 1000)
		}
	}
	if duration <= 0 {
		duration = int(u.EndedAt.Sub(u.StartedAt).Seconds())
	}

	sameDevice := 0
	if u.Device.ID != "" {
		if _, err := s.Pool.Exec(ctx, `INSERT INTO src.src_usr_loop_device (device_id, user_id) VALUES ($1,$2)
			ON CONFLICT (device_id, user_id) DO UPDATE SET last_seen_time=now()`, u.Device.ID, user); err != nil {
			return Result{}, err
		}
		if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_usr_loop_device WHERE device_id=$1 AND last_seen_time > now() - interval '30 days'`,
			u.Device.ID).Scan(&sameDevice); err != nil {
			return Result{}, err
		}
	}
	rules, err := anticheat.LoadRules(ctx, s.Pool)
	if err != nil {
		return Result{}, err
	}
	in := anticheat.Input{Sport: u.Sport, Points: u.Points, DistanceM: dist, Device: u.Device, SameDeviceAccounts: sameDevice, Amount: amount}
	if c := u.Coach; c != nil {
		in.Coach = &anticheat.Coach{Camera: c.Camera, RepsDetected: c.RepsDetected, RepsManual: c.RepsManual}
	}
	verdict := anticheat.Evaluate(rules, in)

	var res Result
	var after func(context.Context)
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		goal, _ := json.Marshal(u.Goal)
		device, _ := json.Marshal(u.Device)
		wearable, _ := json.Marshal(u.Wearable)
		var coach []byte
		if u.Coach != nil {
			coach, _ = json.Marshal(u.Coach)
		}
		var id int64
		err := tx.QueryRow(ctx, `INSERT INTO src.src_act_loop_activity (user_id, client_id, sport, start_time, end_time, distance_m, duration_sec, amount,
				track_geom, goal_json, device_json, wearable_json, coach_json)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8, ST_GeomFromText($9, 4326), $10, $11, $12, $13)
			ON CONFLICT (user_id, client_id) DO NOTHING RETURNING id`,
			user, u.ClientID, string(u.Sport), u.StartedAt, u.EndedAt, dist, duration, amount, trackWKT(u.Points), goal, device, wearable, coach).Scan(&id)
		if db.IsNoRows(err) {
			return errDuplicate
		}
		if err != nil {
			return err
		}
		if len(u.Points) > 0 {
			rows := make([][]any, len(u.Points))
			for i, p := range u.Points {
				var hr, cad *int16
				if p.HR != nil {
					v := int16(*p.HR)
					hr = &v
				}
				if p.Cad != nil {
					v := int16(*p.Cad)
					cad = &v
				}
				src := p.Src
				if src == "" {
					src = "gps"
				}
				rows[i] = []any{id, int32(i), time.UnixMilli(p.T), p.Lat, p.Lng, f32(p.Acc), f32(p.Spd), hr, cad, src}
			}
			if _, err := tx.CopyFrom(ctx, pgx.Identifier{"src", "src_act_loop_track_point"},
				[]string{"activity_id", "seq", "record_time", "lat", "lng", "accuracy_m", "speed_mps", "heart_rate", "cadence", "source"},
				pgx.CopyFromRows(rows)); err != nil {
				return err
			}
		}
		// Automatically voided runs are recorded as already resolved so they
		// don't wait in the manual queue; everything else stays open.
		for _, f := range verdict.Flags {
			status, resolution := "open", (*string)(nil)
			if verdict.Verdict == anticheat.Void {
				auto := "auto_void"
				status, resolution = "resolved", &auto
			}
			if _, err := tx.Exec(ctx, `INSERT INTO src.src_ris_loop_alert (activity_id, user_id, alert_type, confidence, detail, status, resolution, resolve_time)
				VALUES ($1,$2,$3,$4,$5,$6,$7, CASE WHEN $6='resolved' THEN now() END)`,
				id, user, f.Rule, f.Confidence, f.Detail, status, resolution); err != nil {
				return err
			}
		}
		var st Settlement
		switch verdict.Verdict {
		case anticheat.Pass:
			st, after, err = s.settle(ctx, tx, id)
			if err != nil {
				return err
			}
			st.Flags = nonNil(verdict.Flags)
			if err := saveResult(ctx, tx, id, st); err != nil {
				return err
			}
		case anticheat.Review:
			st = emptySettlement("review", verdict.Flags)
			if err := setStatus(ctx, tx, id, "review", st); err != nil {
				return err
			}
		default:
			st = emptySettlement("voided", verdict.Flags)
			if err := setStatus(ctx, tx, id, "voided", st); err != nil {
				return err
			}
		}
		v, err := loadView(ctx, tx, user, id, false)
		res = Result{Activity: v, Settlement: st}
		return err
	})
	if err == errDuplicate {
		r, _, err := s.existing(ctx, user, u.ClientID)
		return r, err
	}
	if err == nil && after != nil {
		after(ctx)
	}
	return res, err
}

var errDuplicate = fmt.Errorf("duplicate upload")

func nonNil(f []anticheat.Flag) []anticheat.Flag {
	if f == nil {
		return []anticheat.Flag{}
	}
	return f
}

func f32(p *float64) *float32 {
	if p == nil {
		return nil
	}
	v := float32(*p)
	return &v
}

func (s *Service) existing(ctx context.Context, user int64, clientID string) (Result, bool, error) {
	var id int64
	var raw []byte
	err := s.Pool.QueryRow(ctx, `SELECT id, result_json FROM src.src_act_loop_activity WHERE user_id=$1 AND client_id=$2`, user, clientID).Scan(&id, &raw)
	if db.IsNoRows(err) {
		return Result{}, false, nil
	}
	if err != nil {
		return Result{}, false, err
	}
	var r Result
	if raw != nil {
		_ = json.Unmarshal(raw, &r.Settlement)
	}
	r.Activity, err = loadView(ctx, s.Pool, user, id, false)
	return r, true, err
}

func setStatus(ctx context.Context, tx pgx.Tx, id int64, status string, st Settlement) error {
	raw, _ := json.Marshal(st)
	_, err := tx.Exec(ctx, `UPDATE src.src_act_loop_activity SET status=$2, result_json=$3 WHERE id=$1`, id, status, raw)
	return err
}

func saveResult(ctx context.Context, tx pgx.Tx, id int64, st Settlement) error {
	raw, _ := json.Marshal(st)
	var area float64
	for _, c := range st.Claims {
		area += c.AreaM2
	}
	_, err := tx.Exec(ctx, `UPDATE src.src_act_loop_activity SET status='settled', energy_raw=$2, energy_granted=$3, claimed_area_m2=$4, result_json=$5 WHERE id=$1`,
		id, st.EnergyRaw, st.EnergyGranted, area, raw)
	return err
}

// EarnedToday is activity energy already granted today (counts against the cap).
func EarnedToday(ctx context.Context, q db.Querier, user int64) (int, error) {
	var n int
	err := q.QueryRow(ctx, `SELECT COALESCE(sum(delta),0) FROM src.src_ply_loop_energy_ledger WHERE user_id=$1 AND ledger_date=$2 AND reason='activity'`,
		user, clock.Today()).Scan(&n)
	return n, err
}

// settle runs a stored activity through energy, claims and codex. The caller
// saves the result.
func (s *Service) settle(ctx context.Context, tx pgx.Tx, id int64) (Settlement, func(context.Context), error) {
	var after func(context.Context)
	var user int64
	var sport string
	var dist, amount float64
	var durationS int
	var startedAt, endedAt time.Time
	var wearable bool
	if err := tx.QueryRow(ctx, `SELECT user_id, sport, distance_m, amount, duration_sec, start_time, end_time,
			COALESCE(jsonb_typeof(wearable_json) = 'object', false)
		FROM src.src_act_loop_activity WHERE id=$1`, id).
		Scan(&user, &sport, &dist, &amount, &durationS, &startedAt, &endedAt, &wearable); err != nil {
		return Settlement{}, nil, err
	}
	cfg := s.Config.For(user)
	st := emptySettlement("settled", nil)

	var energy int
	var earned int64
	if err := tx.QueryRow(ctx, `SELECT energy, energy_earned_total FROM src.src_usr_loop_user WHERE id=$1 FOR UPDATE`, user).Scan(&energy, &earned); err != nil {
		return st, nil, err
	}
	raw, err := cfg.RawEnergy(gameplay.Sport(sport), amount)
	if err != nil {
		return st, nil, err
	}
	today, err := EarnedToday(ctx, tx, user)
	if err != nil {
		return st, nil, err
	}
	in := HookInput{Config: cfg, ActivityID: id, UserID: user, Sport: gameplay.Sport(sport), Amount: amount, DistanceM: dist,
		DurationS: durationS, StartedAt: startedAt, EndedAt: endedAt, Wearable: wearable}
	if s.Community != nil {
		if st.Rally, err = s.Community.RallyBonus(ctx, tx, in); err != nil {
			return st, nil, err
		}
	}
	st.EnergyRaw = raw
	if st.Rally != nil {
		in.BonusRate = st.Rally.BonusRate
		st.EnergyRaw = int(math.Floor(float64(raw) * (1 + in.BonusRate)))
	}
	st.EnergyGranted = cfg.Grant(st.EnergyRaw, today)
	st.EnergyCapped = st.EnergyGranted < st.EnergyRaw

	var crew *int64
	err = tx.QueryRow(ctx, `SELECT crew_id FROM src.src_soc_loop_crew_member WHERE user_id=$1`, user).Scan(&crew)
	if err != nil && !db.IsNoRows(err) {
		return st, nil, err
	}
	var pts []geo.LatLng
	if gameplay.GPSSports[gameplay.Sport(sport)] {
		rows, err := tx.Query(ctx, `SELECT lat, lng FROM src.src_act_loop_track_point WHERE activity_id=$1 ORDER BY seq`, id)
		if err != nil {
			return st, nil, err
		}
		pts, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (geo.LatLng, error) {
			var p geo.LatLng
			return p, r.Scan(&p.Lat, &p.Lng)
		})
		if err != nil {
			return st, nil, err
		}
		det := claim.Detect(pts, claim.Options{MinAreaM2: cfg.MinClaimAreaM2})
		for _, l := range det.Loops {
			// Attack strength is the activity's own energy before the daily
			// cap: the cap limits what you bank, not how hard you ran.
			out, err := territory.Claim(ctx, tx, territory.ClaimInput{UserID: user, CrewID: crew, ActivityID: id, Ring: l.Ring,
				AttackEnergy: raw, MinAreaM2: cfg.MinClaimAreaM2, DefenseWindowH: cfg.Defense.WindowH})
			if err != nil {
				return st, nil, err
			}
			st.Claims = append(st.Claims, out.Claims...)
			st.Attacks = append(st.Attacks, out.Attacks...)
		}
	}

	if st.EnergyGranted > 0 {
		if _, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET energy=energy+$2, energy_earned_total=energy_earned_total+$2 WHERE id=$1`, user, st.EnergyGranted); err != nil {
			return st, nil, err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_loop_energy_ledger (user_id, ledger_date, delta, reason, ref_id) VALUES ($1,$2,$3,'activity',$4)`,
			user, clock.Today(), st.EnergyGranted, id); err != nil {
			return st, nil, err
		}
	}
	if before, after := cfg.Level(earned), cfg.Level(earned+int64(st.EnergyGranted)); after > before {
		st.LevelUp = &after
	}
	p, err := codex.AfterActivity(ctx, tx, cfg, user, gameplay.Sport(sport), amount, dist, len(st.Claims) > 0)
	if err != nil {
		return st, nil, err
	}
	st.Recruits, st.Eggs, st.Medals = p.Recruits, p.Eggs, p.Medals
	in.CrewID, in.Points, in.EnergyRaw, in.Claims, in.Attacks = crew, pts, raw, st.Claims, st.Attacks
	if s.Hook != nil {
		rally := st.Rally
		extra, cb, err := s.Hook.AfterSettle(ctx, tx, in)
		if err != nil {
			return st, nil, err
		}
		st.Extra = extra
		st.Rally, st.Races = rally, []RaceDone{}
		after = cb
		// The hook may have raised counters for more medals (defends, chests, …).
		more, err := codex.AwardMedals(ctx, tx, cfg, user)
		if err != nil {
			return st, nil, err
		}
		st.Medals = append(st.Medals, more...)
	}
	if s.Community != nil {
		if st.Races, err = s.Community.FinishRaces(ctx, tx, in); err != nil {
			return st, nil, err
		}
	}
	return st, after, nil
}

// SettleReviewed settles an activity a reviewer released as a false positive.
func (s *Service) SettleReviewed(ctx context.Context, tx pgx.Tx, id int64) error {
	var status string
	var user int64
	if err := tx.QueryRow(ctx, `SELECT status, user_id FROM src.src_act_loop_activity WHERE id=$1 FOR UPDATE`, id).Scan(&status, &user); err != nil {
		return err
	}
	if status != "review" && status != "voided" {
		return nil
	}
	st, after, err := s.settle(ctx, tx, id)
	if err != nil {
		return err
	}
	if after != nil {
		defer after(ctx) // best effort: may run just before the caller commits
	}
	if err := saveResult(ctx, tx, id, st); err != nil {
		return err
	}
	return inbox.Notify(ctx, tx, user, inbox.System, "运动记录复核通过",
		fmt.Sprintf("你的运动记录已通过人工复核，获得 %d 能量，圈地 %d 块。", st.EnergyGranted, len(st.Claims)), map[string]any{"activity_id": id})
}

// Void cancels an activity: rolls back its land, takes back its energy and
// sport totals.
func (s *Service) Void(ctx context.Context, tx pgx.Tx, id int64) error {
	var status string
	var user int64
	var granted int
	var amount, dist float64
	var sport string
	if err := tx.QueryRow(ctx, `SELECT status, user_id, energy_granted, amount, distance_m, sport FROM src.src_act_loop_activity WHERE id=$1 FOR UPDATE`, id).
		Scan(&status, &user, &granted, &amount, &dist, &sport); err != nil {
		return err
	}
	if status == "voided" {
		return nil
	}
	if status == "settled" {
		if err := territory.Rollback(ctx, tx, id); err != nil {
			return err
		}
		if granted > 0 {
			if _, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET energy=GREATEST(0, energy-$2), energy_earned_total=GREATEST(0, energy_earned_total-$2) WHERE id=$1`, user, granted); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_loop_energy_ledger (user_id, ledger_date, delta, reason, ref_id) VALUES ($1,$2,$3,'rollback',$4)`,
				user, clock.Today(), -granted, id); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_act_loop_sport_total SET amount=GREATEST(0, amount-$3), distance_m=GREATEST(0, distance_m-$4)
			WHERE user_id=$1 AND sport=$2`, user, sport, amount, dist); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_act_loop_activity SET status='voided', result_json=jsonb_set(COALESCE(result_json,'{}'), '{status}', '"voided"') WHERE id=$1`, id); err != nil {
		return err
	}
	return inbox.Notify(ctx, tx, user, inbox.System, "运动记录已作废",
		"你的一条运动记录经核查判定为异常，已作废，相关领地和能量已收回。如有异议请联系客服。", map[string]any{"activity_id": id})
}

func loadView(ctx context.Context, q db.Querier, user, id int64, withTrack bool) (View, error) {
	var v View
	var track *string
	var raw []byte
	trackSQL := "NULL"
	if withTrack {
		trackSQL = "ST_AsGeoJSON(track_geom, 6)"
	}
	err := q.QueryRow(ctx, `SELECT id, sport, status, start_time, end_time, distance_m, duration_sec, amount, energy_granted, claimed_area_m2, `+
		trackSQL+`, result_json FROM src.src_act_loop_activity WHERE id=$1 AND ($2 = 0 OR user_id=$2)`, id, user).
		Scan(&v.ID, &v.Sport, &v.Status, &v.StartedAt, &v.EndedAt, &v.DistanceM, &v.DurationS, &v.Amount, &v.EnergyGranted, &v.ClaimedAreaM2, &track, &raw)
	if db.IsNoRows(err) {
		return v, httpx.NotFound("运动记录")
	}
	if err != nil {
		return v, err
	}
	if v.DistanceM > 0 && v.DurationS > 0 {
		p := int(float64(v.DurationS) / (v.DistanceM / 1000))
		v.AvgPaceSPerKm = &p
	}
	if withTrack {
		if track != nil {
			v.Track = json.RawMessage(*track)
		}
		var st Settlement
		_ = json.Unmarshal(raw, &st)
		v.Claims = st.Claims
		if v.Claims == nil {
			v.Claims = []territory.ClaimRef{}
		}
	}
	return v, nil
}

// LoadView exposes the activity view (admin uses user=0).
func LoadView(ctx context.Context, q db.Querier, user, id int64, withTrack bool) (View, error) {
	return loadView(ctx, q, user, id, withTrack)
}

// LoadPoints returns the stored GPS points.
func LoadPoints(ctx context.Context, q db.Querier, id int64) ([]anticheat.Point, error) {
	rows, err := q.Query(ctx, `SELECT (extract(epoch from record_time)*1000)::bigint, lat, lng, accuracy_m, speed_mps, heart_rate, cadence, COALESCE(source,'gps')
		FROM src.src_act_loop_track_point WHERE activity_id=$1 ORDER BY seq`, id)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (anticheat.Point, error) {
		var p anticheat.Point
		var acc, spd *float32
		var hr, cad *int16
		err := r.Scan(&p.T, &p.Lat, &p.Lng, &acc, &spd, &hr, &cad, &p.Src)
		if acc != nil {
			v := float64(*acc)
			p.Acc = &v
		}
		if spd != nil {
			v := float64(*spd)
			p.Spd = &v
		}
		if hr != nil {
			v := int(*hr)
			p.HR = &v
		}
		if cad != nil {
			v := int(*cad)
			p.Cad = &v
		}
		return p, err
	})
}

// Handler serves /v1/activities and /v1/claims/preview.
type Handler struct{ Svc *Service }

// Routes registers the endpoints.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("POST /v1/activities", auth(h.upload))
	mux.Handle("GET /v1/activities", auth(h.list))
	mux.Handle("GET /v1/activities/{id}", auth(h.get))
	mux.Handle("POST /v1/claims/preview", auth(h.preview))
}

func (h *Handler) upload(w http.ResponseWriter, r *http.Request) error {
	var u Upload
	if err := httpx.DecodeLimit(r, &u, 16<<20); err != nil {
		return err
	}
	res, err := h.Svc.Submit(r.Context(), httpx.UserID(r.Context()), u)
	if err != nil {
		return err
	}
	return httpx.OK(w, res)
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) error {
	uid := httpx.UserID(r.Context())
	p := httpx.GetPage(r)
	rows, err := h.Svc.Pool.Query(r.Context(), `SELECT id FROM src.src_act_loop_activity WHERE user_id=$1 ORDER BY start_time DESC LIMIT $2 OFFSET $3`, uid, p.Size, p.Offset())
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	items := make([]View, 0, len(ids))
	for _, id := range ids {
		v, err := loadView(r.Context(), h.Svc.Pool, uid, id, false)
		if err != nil {
			return err
		}
		items = append(items, v)
	}
	var total int
	if err := h.Svc.Pool.QueryRow(r.Context(), `SELECT count(*) FROM src.src_act_loop_activity WHERE user_id=$1`, uid).Scan(&total); err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	v, err := loadView(r.Context(), h.Svc.Pool, httpx.UserID(r.Context()), id, true)
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *Handler) preview(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Sport  gameplay.Sport `json:"sport"`
		Points []geo.LatLng   `json:"points"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if !gameplay.GPSSports[req.Sport] {
		return httpx.BadRequest("sport_cannot_claim", "这项运动不能圈地")
	}
	if len(req.Points) > MaxPoints {
		return httpx.E(http.StatusRequestEntityTooLarge, "too_many_points", "单次最多 %d 个定位点", MaxPoints)
	}
	cfg := h.Svc.Config.For(httpx.UserID(r.Context()))
	res := claim.Detect(req.Points, claim.Options{MinAreaM2: cfg.MinClaimAreaM2})
	var d float64
	for i := 1; i < len(req.Points); i++ {
		d += geo.Haversine(req.Points[i-1], req.Points[i])
	}
	energy, _ := cfg.RawEnergy(req.Sport, d/1000)
	return httpx.OK(w, map[string]any{"loops": res.Loops, "total_area_m2": res.TotalAreaM2, "discarded": res.Discarded,
		"hint": res.Hint, "distance_km": d / 1000, "raw_energy": energy})
}
