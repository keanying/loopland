// Package user is the account profile: the User object, settings, privacy
// consents, real-name/age, account deletion with a cooling-off period and
// personal data export.
package user

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/platform/secure"
)

// DeletionCoolingOff is the 注销冷静期.
const DeletionCoolingOff = 7 * 24 * time.Hour

// Consents are the privacy authorisations.
type Consents struct {
	PrivacyVersion string `json:"privacy_version"`
	Location       bool   `json:"location"`
	Health         bool   `json:"health"`
}

// Settings are the privacy settings.
type Settings struct {
	TrackVisibility string `json:"track_visibility"`
	HideEndpoints   bool   `json:"hide_endpoints"`
	ShowAvatarOnMap bool   `json:"show_avatar_on_map"`
	Personalized    bool   `json:"personalized"`
}

// CrewRef is a compact crew.
type CrewRef struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// Membership is the user's membership state.
type Membership struct {
	Active       bool       `json:"active"`
	PlanCode     string     `json:"plan_code,omitempty"`
	PlanName     string     `json:"plan_name,omitempty"`
	ExpiresAt    *time.Time `json:"expires_at,omitempty"`
	AutoRenew    bool       `json:"auto_renew"`
	NextChargeAt *time.Time `json:"next_charge_at,omitempty"`
	Channel      string     `json:"channel,omitempty"`
}

// Week is this week's activity.
type Week struct {
	Count     int     `json:"count"`
	DistanceM float64 `json:"distance_m"`
	DurationS int     `json:"duration_s"`
	Energy    int     `json:"energy"`
}

// Stats are the profile numbers.
type Stats struct {
	TotalDistanceM  float64 `json:"total_distance_m"`
	ActivityCount   int     `json:"activity_count"`
	TerritoryCount  int     `json:"territory_count"`
	TerritoryAreaM2 float64 `json:"territory_area_m2"`
	Week            Week    `json:"week"`
}

// User is the account as returned by the API.
type User struct {
	ID               int64       `json:"id"`
	Nickname         string      `json:"nickname"`
	AvatarURL        *string     `json:"avatar_url"`
	Level            int         `json:"level"`
	Energy           int         `json:"energy"`
	EnergyToday      int         `json:"energy_today"`
	DailyEnergyCap   int         `json:"daily_energy_cap"`
	PhoneMasked      *string     `json:"phone_masked"`
	RealnameVerified bool        `json:"realname_verified"`
	IsAdult          *bool       `json:"is_adult"`
	Status           string      `json:"status"`
	MutedUntil       *time.Time  `json:"muted_until"`
	DeleteAfter      *time.Time  `json:"delete_after"`
	Consents         Consents    `json:"consents"`
	Settings         Settings    `json:"settings"`
	Crew             *CrewRef    `json:"crew"`
	Membership       *Membership `json:"membership"`
	Stats            Stats       `json:"stats"`
	CreatedAt        time.Time   `json:"created_at"`

	// Internal, not serialised.
	HasPhone bool  `json:"-"`
	Earned   int64 `json:"-"`
}

// Load builds the User object.
func Load(ctx context.Context, q db.Querier, cfgs *gameplay.Store, box *secure.Box, id int64) (User, error) {
	var u User
	var phoneEnc []byte
	var consents, settings []byte
	var bannedUntil *time.Time
	err := q.QueryRow(ctx, `SELECT id, nickname, avatar_url, energy, energy_earned_total, phone_enc, realname_verified, is_adult,
			status, muted_until, banned_until, delete_after, consents, settings, created_at
		FROM users WHERE id=$1 AND status <> 'deleted'`, id).
		Scan(&u.ID, &u.Nickname, &u.AvatarURL, &u.Energy, &u.Earned, &phoneEnc, &u.RealnameVerified, &u.IsAdult,
			&u.Status, &u.MutedUntil, &bannedUntil, &u.DeleteAfter, &consents, &settings, &u.CreatedAt)
	if db.IsNoRows(err) {
		return u, httpx.NotFound("用户")
	}
	if err != nil {
		return u, err
	}
	cfg := cfgs.For(id)
	u.Level = cfg.Level(u.Earned)
	u.DailyEnergyCap = cfg.DailyEnergyCap
	if phoneEnc != nil {
		u.HasPhone = true
		if p, err := box.Open(phoneEnc); err == nil {
			m := secure.MaskPhone(p)
			u.PhoneMasked = &m
		}
	}
	if u.Status == "active" && u.MutedUntil != nil && u.MutedUntil.After(time.Now()) {
		u.Status = "muted"
	}
	if u.MutedUntil != nil && !u.MutedUntil.After(time.Now()) {
		u.MutedUntil = nil
	}
	_ = json.Unmarshal(consents, &u.Consents)
	_ = json.Unmarshal(settings, &u.Settings)

	if err := q.QueryRow(ctx, `SELECT COALESCE(sum(delta),0) FROM energy_ledger WHERE user_id=$1 AND day=$2 AND reason IN ('activity','rollback')`,
		id, clock.Today()).Scan(&u.EnergyToday); err != nil {
		return u, err
	}
	var crew CrewRef
	err = q.QueryRow(ctx, `SELECT c.id, c.name FROM crew_members m JOIN crews c ON c.id=m.crew_id WHERE m.user_id=$1`, id).Scan(&crew.ID, &crew.Name)
	if err == nil {
		u.Crew = &crew
	} else if !db.IsNoRows(err) {
		return u, err
	}
	m, err := LoadMembership(ctx, q, id)
	if err != nil {
		return u, err
	}
	if m.Active {
		u.Membership = &m
	}
	if err := q.QueryRow(ctx, `SELECT COALESCE(sum(distance_m),0), count(*) FROM activities WHERE user_id=$1 AND status='settled'`, id).
		Scan(&u.Stats.TotalDistanceM, &u.Stats.ActivityCount); err != nil {
		return u, err
	}
	if err := q.QueryRow(ctx, `SELECT count(*), COALESCE(sum(area_m2),0) FROM territories WHERE owner_user_id=$1`, id).
		Scan(&u.Stats.TerritoryCount, &u.Stats.TerritoryAreaM2); err != nil {
		return u, err
	}
	weekStart := clock.Today()
	weekStart = weekStart.AddDate(0, 0, -((int(weekStart.Weekday()) + 6) % 7))
	if err := q.QueryRow(ctx, `SELECT count(*), COALESCE(sum(distance_m),0), COALESCE(sum(duration_s),0), COALESCE(sum(energy_granted),0)
		FROM activities WHERE user_id=$1 AND status='settled' AND started_at >= $2`, id, weekStart).
		Scan(&u.Stats.Week.Count, &u.Stats.Week.DistanceM, &u.Stats.Week.DurationS, &u.Stats.Week.Energy); err != nil {
		return u, err
	}
	return u, nil
}

// LoadMembership returns the current membership (Active=false if none).
// A renewal that failed keeps benefits during the 3-day grace period.
func LoadMembership(ctx context.Context, q db.Querier, id int64) (Membership, error) {
	var m Membership
	var exp time.Time
	var grace *time.Time
	err := q.QueryRow(ctx, `SELECT m.plan_code, p.name, m.expires_at, m.auto_renew, m.next_charge_at, m.channel, m.grace_until
		FROM memberships m JOIN plans p ON p.code=m.plan_code WHERE m.user_id=$1`, id).
		Scan(&m.PlanCode, &m.PlanName, &exp, &m.AutoRenew, &m.NextChargeAt, &m.Channel, &grace)
	if db.IsNoRows(err) {
		return Membership{Active: false}, nil
	}
	if err != nil {
		return m, err
	}
	now := time.Now()
	m.ExpiresAt = &exp
	m.Active = exp.After(now) || (grace != nil && grace.After(now))
	if !m.Active {
		return Membership{Active: false}, nil
	}
	if !m.AutoRenew {
		m.NextChargeAt = nil
	}
	return m, nil
}

// Realname verifies a name + ID number. The production implementation calls
// a licensed 实名核验 service (e.g. 阿里云实人认证 / 身份证二要素); without one
// configured, only the checksum and birth date are validated (dev).
type Realname interface {
	Verify(ctx context.Context, name, idNumber string) (birth time.Time, err error)
}

// ChecksumRealname validates the GB 11643 checksum and extracts the birth
// date. It does NOT prove the person exists; use only in dev.
type ChecksumRealname struct{}

// Verify implements Realname.
func (ChecksumRealname) Verify(_ context.Context, name, id string) (time.Time, error) {
	id = strings.ToUpper(strings.TrimSpace(id))
	if utf8.RuneCountInString(strings.TrimSpace(name)) < 2 || len(id) != 18 {
		return time.Time{}, fmt.Errorf("姓名或身份证号格式错误")
	}
	weights := []int{7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2}
	sum := 0
	for i := 0; i < 17; i++ {
		d := id[i] - '0'
		if d > 9 {
			return time.Time{}, fmt.Errorf("身份证号格式错误")
		}
		sum += int(d) * weights[i]
	}
	if "10X98765432"[sum%11] != id[17] {
		return time.Time{}, fmt.Errorf("身份证号校验失败")
	}
	birth, err := time.Parse("20060102", id[6:14])
	if err != nil {
		return time.Time{}, fmt.Errorf("身份证号出生日期错误")
	}
	return birth, nil
}

// UnconfiguredRealname refuses verification until a provider is wired.
type UnconfiguredRealname struct{}

// Verify implements Realname.
func (UnconfiguredRealname) Verify(context.Context, string, string) (time.Time, error) {
	return time.Time{}, fmt.Errorf("实名认证服务暂未开通")
}

// IsAdult reports whether someone born on birth is 18 on day.
func IsAdult(birth, day time.Time) bool {
	return !day.Before(birth.AddDate(18, 0, 0))
}

// Handler serves /v1/me.
type Handler struct {
	Pool     *pgxpool.Pool
	Config   *gameplay.Store
	Box      *secure.Box
	Realname Realname
}

// Routes registers the endpoints. authAny allows users without a phone.
func (h *Handler) Routes(mux *http.ServeMux, auth, authAny func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /v1/me", authAny(h.me))
	mux.Handle("PATCH /v1/me", auth(h.patch))
	mux.Handle("POST /v1/me/consents", authAny(h.consents))
	mux.Handle("POST /v1/me/realname", auth(h.realname))
	mux.Handle("POST /v1/me/deletion", auth(h.requestDeletion))
	mux.Handle("DELETE /v1/me/deletion", authAny(h.cancelDeletion))
	mux.Handle("GET /v1/me/export", auth(h.export))
}

func (h *Handler) load(r *http.Request) (User, error) {
	return Load(r.Context(), h.Pool, h.Config, h.Box, httpx.UserID(r.Context()))
}

func (h *Handler) me(w http.ResponseWriter, r *http.Request) error {
	u, err := h.load(r)
	if err != nil {
		return err
	}
	return httpx.OK(w, u)
}

var visibilities = map[string]bool{"public": true, "followers": true, "crew": true, "private": true}

func (h *Handler) patch(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Nickname  *string         `json:"nickname"`
		AvatarURL *string         `json:"avatar_url"`
		Settings  json.RawMessage `json:"settings"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	uid := httpx.UserID(r.Context())
	err := pgx.BeginFunc(r.Context(), h.Pool, func(tx pgx.Tx) error {
		if req.Nickname != nil {
			n := strings.TrimSpace(*req.Nickname)
			if c := utf8.RuneCountInString(n); c < 2 || c > 16 {
				return httpx.BadRequest("invalid_nickname", "昵称 2–16 个字")
			}
			var muted bool
			if err := tx.QueryRow(r.Context(), `SELECT COALESCE(muted_until > now(), false) FROM users WHERE id=$1`, uid).Scan(&muted); err != nil {
				return err
			}
			if muted {
				return httpx.Forbidden("muted", "禁言期间不能修改昵称")
			}
			if _, err := tx.Exec(r.Context(), `UPDATE users SET nickname=$2 WHERE id=$1`, uid, n); err != nil {
				return err
			}
		}
		if req.AvatarURL != nil {
			if _, err := tx.Exec(r.Context(), `UPDATE users SET avatar_url=NULLIF($2,'') WHERE id=$1`, uid, *req.AvatarURL); err != nil {
				return err
			}
		}
		if len(req.Settings) > 0 {
			var cur []byte
			if err := tx.QueryRow(r.Context(), `SELECT settings FROM users WHERE id=$1 FOR UPDATE`, uid).Scan(&cur); err != nil {
				return err
			}
			var s Settings
			_ = json.Unmarshal(cur, &s)
			dec := json.NewDecoder(strings.NewReader(string(req.Settings)))
			dec.DisallowUnknownFields()
			if err := dec.Decode(&s); err != nil {
				return httpx.BadRequest("invalid_body", "settings 字段错误")
			}
			if !visibilities[s.TrackVisibility] {
				return httpx.BadRequest("invalid_body", "track_visibility 取值错误")
			}
			raw, _ := json.Marshal(s)
			if _, err := tx.Exec(r.Context(), `UPDATE users SET settings=$2 WHERE id=$1`, uid, raw); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	return h.me(w, r)
}

func (h *Handler) consents(w http.ResponseWriter, r *http.Request) error {
	var c Consents
	if err := httpx.Decode(r, &c); err != nil {
		return err
	}
	raw, _ := json.Marshal(c)
	if _, err := h.Pool.Exec(r.Context(), `UPDATE users SET consents=$2 WHERE id=$1`, httpx.UserID(r.Context()), raw); err != nil {
		return err
	}
	return h.me(w, r)
}

func (h *Handler) realname(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Name     string `json:"name"`
		IDNumber string `json:"id_number"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	birth, err := h.Realname.Verify(r.Context(), req.Name, req.IDNumber)
	if err != nil {
		return httpx.BadRequest("realname_failed", err.Error())
	}
	// Only the outcome is kept, never the name or ID number.
	if _, err := h.Pool.Exec(r.Context(), `UPDATE users SET realname_verified=true, is_adult=$2, birth_year=$3 WHERE id=$1`,
		httpx.UserID(r.Context()), IsAdult(birth, clock.Today()), birth.Year()); err != nil {
		return err
	}
	return h.me(w, r)
}

func (h *Handler) requestDeletion(w http.ResponseWriter, r *http.Request) error {
	after := time.Now().Add(DeletionCoolingOff)
	var got time.Time
	err := h.Pool.QueryRow(r.Context(), `UPDATE users SET status='deleting', delete_after=COALESCE(delete_after, $2)
		WHERE id=$1 AND status IN ('active','deleting') RETURNING delete_after`, httpx.UserID(r.Context()), after).Scan(&got)
	if db.IsNoRows(err) {
		return httpx.Forbidden("account_banned", "账号当前状态不能注销，请联系客服")
	}
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]time.Time{"delete_after": got})
}

func (h *Handler) cancelDeletion(w http.ResponseWriter, r *http.Request) error {
	if _, err := h.Pool.Exec(r.Context(), `UPDATE users SET status='active', delete_after=NULL WHERE id=$1 AND status='deleting'`,
		httpx.UserID(r.Context())); err != nil {
		return err
	}
	return h.me(w, r)
}

func (h *Handler) export(w http.ResponseWriter, r *http.Request) error {
	uid := httpx.UserID(r.Context())
	u, err := h.load(r)
	if err != nil {
		return err
	}
	var phone *string
	var enc []byte
	if err := h.Pool.QueryRow(r.Context(), `SELECT phone_enc FROM users WHERE id=$1`, uid).Scan(&enc); err != nil {
		return err
	}
	if enc != nil {
		if p, err := h.Box.Open(enc); err == nil {
			phone = &p
		}
	}
	jsonRows := func(sql string) (json.RawMessage, error) {
		var raw []byte
		err := h.Pool.QueryRow(r.Context(), `SELECT COALESCE(json_agg(x), '[]'::json) FROM (`+sql+`) x`, uid).Scan(&raw)
		return raw, err
	}
	out := map[string]any{"exported_at": time.Now(), "account": u, "phone": phone}
	for key, sql := range map[string]string{
		"activities": `SELECT id, sport, status, started_at, ended_at, distance_m, duration_s, amount, energy_granted,
			ST_AsGeoJSON(track)::json AS track FROM activities WHERE user_id=$1 ORDER BY started_at`,
		"territories": `SELECT id, area_m2, guard, captured_at, ST_AsGeoJSON(geom)::json AS geometry FROM territories WHERE owner_user_id=$1`,
		"codex":       `SELECT kind, item, progress, obtained_at FROM codex_items WHERE user_id=$1`,
		"orders":      `SELECT order_no, plan_name, amount_fen, channel, status, created_at, paid_at FROM orders WHERE user_id=$1`,
		"energy":      `SELECT day, delta, reason, created_at FROM energy_ledger WHERE user_id=$1 ORDER BY id`,
	} {
		raw, err := jsonRows(sql)
		if err != nil {
			return err
		}
		out[key] = raw
	}
	w.Header().Set("Content-Disposition", `attachment; filename="loopland-export-`+strconv.FormatInt(uid, 10)+`.json"`)
	return httpx.OK(w, out)
}
