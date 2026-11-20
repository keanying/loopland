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

// Goal is the pre-run target.
type Goal struct {
	Type        string   `json:"type"`
	Value       *float64 `json:"value,omitempty"`
	TerritoryID *int64   `json:"territory_id,omitempty"`
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
}

func emptySettlement(status string, flags []anticheat.Flag) Settlement {
	if flags == nil {
		flags = []anticheat.Flag{}
	}
	return Settlement{Status: status, Claims: []territory.ClaimRef{}, Attacks: []territory.AttackRef{},
		Recruits: []codex.Recruit{}, Eggs: []codex.Egg{}, Medals: []codex.MedalRef{}, Flags: flags}
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
	if err := s.Pool.QueryRow(ctx, `SELECT consents, status FROM users WHERE id=$1`, user).Scan(&consents, &status); err != nil {
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
		if _, err := s.Pool.Exec(ctx, `INSERT INTO user_devices (device_id, user_id) VALUES ($1,$2)
			ON CONFLICT (device_id, user_id) DO UPDATE SET last_seen_at=now()`, u.Device.ID, user); err != nil {
			return Result{}, err
		}
		if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM user_devices WHERE device_id=$1 AND last_seen_at > now() - interval '30 days'`,
			u.Device.ID).Scan(&sameDevice); err != nil {
			return Result{}, err
		}
	}
	rules, err := anticheat.LoadRules(ctx, s.Pool)
	if err != nil {
		return Result{}, err
	}
	verdict := anticheat.Evaluate(rules, anticheat.Input{Sport: u.Sport, Points: u.Points, DistanceM: dist, Device: u.Device, SameDeviceAccounts: sameDevice})

	var res Result
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		goal, _ := json.Marshal(u.Goal)
		device, _ := json.Marshal(u.Device)
		wearable, _ := json.Marshal(u.Wearable)
		var id int64
		err := tx.QueryRow(ctx, `INSERT INTO activities (user_id, client_id, sport, started_at, ended_at, distance_m, duration_s, amount,
				track, goal, device, wearable)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8, ST_GeomFromText($9, 4326), $10, $11, $12)
			ON CONFLICT (user_id, client_id) DO NOTHING RETURNING id`,
			user, u.ClientID, string(u.Sport), u.StartedAt, u.EndedAt, dist, duration, amount, trackWKT(u.Points), goal, device, wearable).Scan(&id)
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
			if _, err := tx.CopyFrom(ctx, pgx.Identifier{"track_points"},
				[]string{"activity_id", "seq", "recorded_at", "lat", "lng", "accuracy_m", "speed_mps", "heart_rate", "cadence", "source"},
				pgx.CopyFromRows(rows)); err != nil {
				return err
			}
		}
		for _, f := range verdict.Flags {
			if _, err := tx.Exec(ctx, `INSERT INTO risk_alerts (activity_id, user_id, type, confidence, detail) VALUES ($1,$2,$3,$4,$5)`,
				id, user, f.Rule, f.Confidence, f.Detail); err != nil {
				return err
			}
		}
		var st Settlement
		switch verdict.Verdict {
		case anticheat.Pass:
			st, err = s.settle(ctx, tx, id)
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
	err := s.Pool.QueryRow(ctx, `SELECT id, result FROM activities WHERE user_id=$1 AND client_id=$2`, user, clientID).Scan(&id, &raw)
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
	_, err := tx.Exec(ctx, `UPDATE activities SET status=$2, result=$3 WHERE id=$1`, id, status, raw)
	return err
}

func saveResult(ctx context.Context, tx pgx.Tx, id int64, st Settlement) error {
	raw, _ := json.Marshal(st)
	var area float64
	for _, c := range st.Claims {
		area += c.AreaM2
	}
	_, err := tx.Exec(ctx, `UPDATE activities SET status='settled', energy_raw=$2, energy_granted=$3, claimed_area_m2=$4, result=$5 WHERE id=$1`,
		id, st.EnergyRaw, st.EnergyGranted, area, raw)
	return err
}

// EarnedToday is activity energy already granted today (counts against the cap).
func EarnedToday(ctx context.Context, q db.Querier, user int64) (int, error) {
	var n int
	err := q.QueryRow(ctx, `SELECT COALESCE(sum(delta),0) FROM energy_ledger WHERE user_id=$1 AND day=$2 AND reason='activity'`,
		user, clock.Today()).Scan(&n)
	return n, err
}

// settle runs a stored activity through energy, claims and codex. The caller
// saves the result.
func (s *Service) settle(ctx context.Context, tx pgx.Tx, id int64) (Settlement, error) {
	var user int64
	var sport string
	var dist, amount float64
	if err := tx.QueryRow(ctx, `SELECT user_id, sport, distance_m, amount FROM activities WHERE id=$1`, id).Scan(&user, &sport, &dist, &amount); err != nil {
		return Settlement{}, err
	}
	cfg := s.Config.For(user)
	st := emptySettlement("settled", nil)

	var energy int
	var earned int64
	if err := tx.QueryRow(ctx, `SELECT energy, energy_earned_total FROM users WHERE id=$1 FOR UPDATE`, user).Scan(&energy, &earned); err != nil {
		return st, err
	}
	raw, err := cfg.RawEnergy(gameplay.Sport(sport), amount)
	if err != nil {
		return st, err
	}
	today, err := EarnedToday(ctx, tx, user)
	if err != nil {
		return st, err
	}
	st.EnergyRaw = raw
	st.EnergyGranted = cfg.Grant(raw, today)
	st.EnergyCapped = st.EnergyGranted < raw

	if gameplay.GPSSports[gameplay.Sport(sport)] {
		rows, err := tx.Query(ctx, `SELECT lat, lng FROM track_points WHERE activity_id=$1 ORDER BY seq`, id)
		if err != nil {
			return st, err
		}
		pts, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (geo.LatLng, error) {
			var p geo.LatLng
			return p, r.Scan(&p.Lat, &p.Lng)
		})
		if err != nil {
			return st, err
		}
		var crew *int64
		err = tx.QueryRow(ctx, `SELECT crew_id FROM crew_members WHERE user_id=$1`, user).Scan(&crew)
		if err != nil && !db.IsNoRows(err) {
			return st, err
		}
		det := claim.Detect(pts, claim.Options{MinAreaM2: cfg.MinClaimAreaM2})
		for _, l := range det.Loops {
			// Attack strength is the activity's own energy before the daily
			// cap: the cap limits what you bank, not how hard you ran.
			out, err := territory.Claim(ctx, tx, territory.ClaimInput{UserID: user, CrewID: crew, ActivityID: id, Ring: l.Ring,
				AttackEnergy: raw, MinAreaM2: cfg.MinClaimAreaM2})
			if err != nil {
				return st, err
			}
			st.Claims = append(st.Claims, out.Claims...)
			st.Attacks = append(st.Attacks, out.Attacks...)
		}
	}

	if st.EnergyGranted > 0 {
		if _, err := tx.Exec(ctx, `UPDATE users SET energy=energy+$2, energy_earned_total=energy_earned_total+$2 WHERE id=$1`, user, st.EnergyGranted); err != nil {
			return st, err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO energy_ledger (user_id, day, delta, reason, ref_id) VALUES ($1,$2,$3,'activity',$4)`,
			user, clock.Today(), st.EnergyGranted, id); err != nil {
			return st, err
		}
	}
	if before, after := cfg.Level(earned), cfg.Level(earned+int64(st.EnergyGranted)); after > before {
		st.LevelUp = &after
	}
	p, err := codex.AfterActivity(ctx, tx, cfg, user, gameplay.Sport(sport), amount, dist, len(st.Claims) > 0)
	if err != nil {
		return st, err
	}
	st.Recruits, st.Eggs, st.Medals = p.Recruits, p.Eggs, p.Medals
	return st, nil
}

// SettleReviewed settles an activity a reviewer released as a false positive.
func (s *Service) SettleReviewed(ctx context.Context, tx pgx.Tx, id int64) error {
	var status string
	var user int64
	if err := tx.QueryRow(ctx, `SELECT status, user_id FROM activities WHERE id=$1 FOR UPDATE`, id).Scan(&status, &user); err != nil {
		return err
	}
	if status != "review" && status != "voided" {
		return nil
	}
	st, err := s.settle(ctx, tx, id)
	if err != nil {
		return err
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
	if err := tx.QueryRow(ctx, `SELECT status, user_id, energy_granted, amount, distance_m, sport FROM activities WHERE id=$1 FOR UPDATE`, id).
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
			if _, err := tx.Exec(ctx, `UPDATE users SET energy=GREATEST(0, energy-$2), energy_earned_total=GREATEST(0, energy_earned_total-$2) WHERE id=$1`, user, granted); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO energy_ledger (user_id, day, delta, reason, ref_id) VALUES ($1,$2,$3,'rollback',$4)`,
				user, clock.Today(), -granted, id); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE user_sport_totals SET amount=GREATEST(0, amount-$3), distance_m=GREATEST(0, distance_m-$4)
			WHERE user_id=$1 AND sport=$2`, user, sport, amount, dist); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE activities SET status='voided', result=jsonb_set(COALESCE(result,'{}'), '{status}', '"voided"') WHERE id=$1`, id); err != nil {
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
		trackSQL = "ST_AsGeoJSON(track, 6)"
	}
	err := q.QueryRow(ctx, `SELECT id, sport, status, started_at, ended_at, distance_m, duration_s, amount, energy_granted, claimed_area_m2, `+
		trackSQL+`, result FROM activities WHERE id=$1 AND ($2 = 0 OR user_id=$2)`, id, user).
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
	rows, err := q.Query(ctx, `SELECT (extract(epoch from recorded_at)*1000)::bigint, lat, lng, accuracy_m, speed_mps, heart_rate, cadence, COALESCE(source,'gps')
		FROM track_points WHERE activity_id=$1 ORDER BY seq`, id)
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
	rows, err := h.Svc.Pool.Query(r.Context(), `SELECT id FROM activities WHERE user_id=$1 ORDER BY started_at DESC LIMIT $2 OFFSET $3`, uid, p.Size, p.Offset())
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
	if err := h.Svc.Pool.QueryRow(r.Context(), `SELECT count(*) FROM activities WHERE user_id=$1`, uid).Scan(&total); err != nil {
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
