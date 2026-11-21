package venue

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// ---------------------------------------------------------------- QR

// QR is the venue code: payload LPV.<venue_id>.<sig> and its universal link.
type QR struct {
	Payload string `json:"payload"`
	URL     string `json:"url"`
}

// sign is the QR signature of a venue at a code version: rotating bumps the
// version, which invalidates every printed code.
func (s *Service) sign(id int64, version int) string {
	m := hmac.New(sha256.New, s.QRKey)
	fmt.Fprintf(m, "venue:%d:%d", id, version)
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil)[:15])
}

func (s *Service) qr(id int64, version int) QR {
	p := fmt.Sprintf("LPV.%d.%s", id, s.sign(id, version))
	return QR{Payload: p, URL: strings.TrimRight(s.LinkBase, "/") + "/v/" + p}
}

// QRCode is GET /admin/v1/venues/{id}/qr.
func (s *Service) QRCode(ctx context.Context, id int64) (QR, error) {
	var version int
	err := s.Pool.QueryRow(ctx, `SELECT qr_version FROM src.src_mer_loop_venue WHERE id=$1`, id).Scan(&version)
	if db.IsNoRows(err) {
		return QR{}, httpx.NotFound("场馆")
	}
	return s.qr(id, version), err
}

// RotateQR is POST /admin/v1/venues/{id}/qr/rotate.
func (s *Service) RotateQR(ctx context.Context, tx pgx.Tx, id int64) (QR, error) {
	var version int
	err := tx.QueryRow(ctx, `UPDATE src.src_mer_loop_venue SET qr_version=qr_version+1, update_time=now() WHERE id=$1 RETURNING qr_version`, id).Scan(&version)
	if db.IsNoRows(err) {
		return QR{}, httpx.NotFound("场馆")
	}
	return s.qr(id, version), err
}

// verifyQR checks a scanned code (raw payload or the universal link) for
// venue id at its current code version.
func (s *Service) verifyQR(raw string, id int64, version int) bool {
	raw = strings.TrimSpace(raw)
	if i := strings.LastIndex(raw, "/v/"); i >= 0 {
		raw = raw[i+3:]
	}
	parts := strings.Split(raw, ".")
	if len(parts) != 3 || parts[0] != "LPV" {
		return false
	}
	got, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || got != id {
		return false
	}
	return hmac.Equal([]byte(parts[2]), []byte(s.sign(id, version)))
}

// ---------------------------------------------------------------- check-in

// CheckinInput is POST /v1/venues/{id}/checkin.
type CheckinInput struct {
	Lat *float64 `json:"lat"`
	Lng *float64 `json:"lng"`
	QR  string   `json:"qr"`
}

// CheckinResult is the check-in response.
type CheckinResult struct {
	ActivityID int64 `json:"activity_id"`
	Energy     int   `json:"energy"`
	Points     int   `json:"points"`
	WeekPoints int   `json:"week_points"`
	Coupon     any   `json:"coupon"`
	Venue      Venue `json:"venue"`
}

func notAllowed(msg string) error { return httpx.BadRequest("checkin_not_allowed", msg) }

// Checkin checks a user in at a venue: inside the radius or with the
// venue's current QR code; once per venue per day, at most
// venue.daily_checkin_venues venues per day. It creates a venue activity
// (energy through the normal settlement), adds owner points and asks the
// perks module for the stronghold coupon.
func (s *Service) Checkin(ctx context.Context, user, id int64, in CheckinInput) (CheckinResult, error) {
	v, err := s.Get(ctx, s.Pool, user, id, false)
	if err != nil {
		return CheckinResult{}, err
	}
	method := ""
	switch {
	case in.QR != "":
		if !s.verifyQR(in.QR, id, v.row.qrVersion) {
			return CheckinResult{}, notAllowed("场馆二维码无效或已更换，请扫描场馆现场的二维码")
		}
		method = "qr"
	case in.Lat != nil && in.Lng != nil:
		d := geo.Haversine(geo.LatLng{Lat: *in.Lat, Lng: *in.Lng}, geo.LatLng{Lat: v.Center.Lat, Lng: v.Center.Lng})
		if d > v.CheckinRadiusM {
			return CheckinResult{}, notAllowed(fmt.Sprintf("你距离场馆约 %d 米，需要在 %d 米范围内签到，或扫场馆二维码", int(math.Round(d)), int(v.CheckinRadiusM)))
		}
		method = "radius"
	default:
		return CheckinResult{}, notAllowed("请在场馆范围内定位签到，或扫场馆二维码")
	}
	cfg := s.Config.For(user).Venue
	now := time.Now()
	today := clock.Day(now)
	week := weekStart(today)
	var res CheckinResult
	var after func(context.Context)
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var status string
		var consents []byte
		if err := tx.QueryRow(ctx, `SELECT status, consents_json FROM src.src_usr_loop_user WHERE id=$1 FOR UPDATE`, user).Scan(&status, &consents); err != nil {
			return err
		}
		if status == "banned" {
			return httpx.Forbidden("account_banned", "账号已被封禁")
		}
		var c struct {
			PrivacyVersion string `json:"privacy_version"`
		}
		_ = json.Unmarshal(consents, &c)
		if c.PrivacyVersion == "" {
			return httpx.Forbidden("consent_required", "请先同意隐私政策")
		}
		var here bool
		var venues int
		if err := tx.QueryRow(ctx, `SELECT bool_or(venue_id=$2) IS TRUE, count(*) FROM src.src_mer_loop_venue_checkin WHERE user_id=$1 AND checkin_date=$3`,
			user, id, today).Scan(&here, &venues); err != nil {
			return err
		}
		if here {
			return httpx.Conflict("already_checked_in", "今天已经在这个场馆签到过了，明天再来")
		}
		if venues >= cfg.DailyCheckinVenues {
			return httpx.E(http.StatusTooManyRequests, "rate_limited", "每天最多在 %d 个场馆签到", cfg.DailyCheckinVenues)
		}
		aid, st, cb, err := s.Activities.SettleCheckin(ctx, tx, user, now)
		if err != nil {
			return err
		}
		after = cb
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_mer_loop_venue_checkin (venue_id, user_id, checkin_date, week_start_date, checkin_type, activity_id, energy_qty, points_qty)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`, id, user, today, week, method, aid, st.EnergyGranted, cfg.CheckinPoints); err != nil {
			if db.IsUniqueViolation(err) {
				return httpx.Conflict("already_checked_in", "今天已经在这个场馆签到过了，明天再来")
			}
			return err
		}
		res = CheckinResult{ActivityID: aid, Energy: st.EnergyGranted, Points: cfg.CheckinPoints}
		if err := tx.QueryRow(ctx, `SELECT COALESCE(sum(points_qty),0) FROM src.src_mer_loop_venue_checkin WHERE venue_id=$1 AND user_id=$2 AND week_start_date=$3`,
			id, user, week).Scan(&res.WeekPoints); err != nil {
			return err
		}
		if s.Coupons != nil {
			if res.Coupon, err = s.Coupons.IssueStronghold(ctx, tx, user, id); err != nil {
				return err
			}
		}
		res.Venue, err = s.Get(ctx, tx, user, id, false)
		return err
	})
	if err != nil {
		return CheckinResult{}, err
	}
	if after != nil {
		after(ctx)
	}
	return res, nil
}

// ---------------------------------------------------------------- owners

// SettleOwners crowns this week's venue owners from last week's points,
// once per week (the first job tick after Monday 00:00 Shanghai): the
// highest total wins, ties go to whoever reached it first.
func (s *Service) SettleOwners(ctx context.Context) error {
	week := weekStart(clock.Today())
	prev := week.AddDate(0, 0, -7)
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO src.src_sys_loop_setting (setting_key, setting_value) VALUES ('venue_owner_week', to_jsonb($1::text))
			ON CONFLICT (setting_key) DO UPDATE SET setting_value=EXCLUDED.setting_value, update_time=now()
			WHERE src_sys_loop_setting.setting_value <> to_jsonb($1::text)`, week.Format("2006-01-02"))
		if err != nil || tag.RowsAffected() == 0 {
			return err // already done this week
		}
		rows, err := tx.Query(ctx, `INSERT INTO src.src_mer_loop_venue_owner (venue_id, week_start_date, user_id, points_qty, reach_time)
			SELECT DISTINCT ON (venue_id) venue_id, $1::date, user_id, pts, reached FROM (
				SELECT venue_id, user_id, sum(points_qty)::int AS pts, max(create_time) AS reached
				FROM src.src_mer_loop_venue_checkin WHERE week_start_date=$2 GROUP BY venue_id, user_id HAVING sum(points_qty) > 0) x
			ORDER BY venue_id, pts DESC, reached, user_id
			ON CONFLICT DO NOTHING
			RETURNING venue_id, user_id, points_qty, (SELECT venue_name FROM src.src_mer_loop_venue v WHERE v.id=venue_id)`, week, prev)
		if err != nil {
			return err
		}
		type crowned struct {
			venue, user int64
			pts         int
			name        string
		}
		cs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (crowned, error) {
			var c crowned
			return c, r.Scan(&c.venue, &c.user, &c.pts, &c.name)
		})
		if err != nil {
			return err
		}
		for _, c := range cs {
			if err := inbox.Notify(ctx, tx, c.user, inbox.Interaction, "你成为了本周馆主",
				fmt.Sprintf("上周你在「%s」获得 %d 馆主积分，成为本周馆主！你的头像会出现在地图据点上。", c.name, c.pts),
				map[string]any{"type": "venue_owner", "venue_id": c.venue}); err != nil {
				return err
			}
		}
		return nil
	})
}
