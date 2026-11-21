// Package perks is V2 batch 4 「本地生活与商户」 part B
// (docs/api/v2-4-本地生活与商户.md): merchant drops (supply stations,
// merchant chests, strongholds), the coupons they issue for free through
// exercise and check-ins, in-store redemption with a rotating QR code,
// brand campaigns and the weekly merchant statements.
package perks

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Service implements drops, coupons, redemptions, campaigns and statements.
type Service struct {
	Pool *pgxpool.Pool
	Log  *slog.Logger
	// QRKey signs the rotating coupon QR payload (DeriveKey of the data key).
	QRKey []byte
}

// DeriveKey derives the coupon QR signing key from the data key.
func DeriveKey(dataKey []byte) []byte {
	m := hmac.New(sha256.New, dataKey)
	m.Write([]byte("loopland/coupon-qr"))
	return m.Sum(nil)
}

// QRTTL is how long a shown QR payload is accepted (防截图转卖).
const QRTTL = 60 * time.Second

// MerchantRef is a compact merchant.
type MerchantRef struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// LatLng is a coordinate.
type LatLng struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

// Perk is the coupon template of a drop.
type Perk struct {
	Title       string `json:"title"`
	Description string `json:"description"`
	ValueText   string `json:"value_text"`
	ValidDays   int    `json:"valid_days"`
	Rules       string `json:"rules"`
}

// CouponSource is where a coupon came from.
type CouponSource struct {
	Type   string `json:"type"`
	DropID int64  `json:"drop_id"`
	Name   string `json:"name"`
}

// Coupon is a user's coupon.
type Coupon struct {
	ID         int64        `json:"id"`
	Code       string       `json:"code"`
	Perk       Perk         `json:"perk"`
	Merchant   MerchantRef  `json:"merchant"`
	Source     CouponSource `json:"source"`
	Status     string       `json:"status"`
	ObtainedAt time.Time    `json:"obtained_at"`
	ExpiresAt  time.Time    `json:"expires_at"`
	UsedAt     *time.Time   `json:"used_at"`
	UsedStore  *string      `json:"used_store"`

	userID int64
}

// couponStatusSQL is the effective status (expired as soon as it passes
// expire_time, before the job marks it).
const couponStatusSQL = `(CASE WHEN c.coupon_status='unused' AND c.expire_time <= now() THEN 'expired' ELSE c.coupon_status END)`

const couponCols = `c.id, c.coupon_code, c.perk_json, m.id, m.merchant_name, c.source_type, c.drop_id, c.source_name,
	` + couponStatusSQL + `, c.create_time, c.expire_time, c.use_time, c.use_store_name, c.user_id`

const couponFrom = ` FROM src.src_mkt_loop_coupon c JOIN src.src_mer_loop_merchant m ON m.id=c.merchant_id `

func scanCoupon(r pgx.Row) (Coupon, error) {
	var c Coupon
	var perk []byte
	err := r.Scan(&c.ID, &c.Code, &perk, &c.Merchant.ID, &c.Merchant.Name, &c.Source.Type, &c.Source.DropID, &c.Source.Name,
		&c.Status, &c.ObtainedAt, &c.ExpiresAt, &c.UsedAt, &c.UsedStore, &c.userID)
	_ = json.Unmarshal(perk, &c.Perk)
	return c, err
}

func loadCoupon(ctx context.Context, q db.Querier, id int64) (Coupon, error) {
	c, err := scanCoupon(q.QueryRow(ctx, `SELECT `+couponCols+couponFrom+` WHERE c.id=$1`, id))
	if db.IsNoRows(err) {
		return c, httpx.NotFound("券")
	}
	return c, err
}

// dropStatusSQL is the effective status of drop d (campaign bc may be
// NULL): a campaign's state cascades to its drops.
const dropStatusSQL = `(CASE WHEN d.is_paused OR bc.campaign_status = 'paused' THEN 'paused'
	WHEN d.end_time <= now() OR bc.end_time <= now() THEN 'ended'
	WHEN d.start_time > now() OR bc.campaign_status = 'draft' OR bc.start_time > now() THEN 'scheduled'
	ELSE 'active' END)`

const dropFrom = ` FROM src.src_mer_loop_drop d JOIN src.src_mer_loop_merchant m ON m.id=d.merchant_id
	LEFT JOIN src.src_mkt_loop_brand_campaign bc ON bc.id=d.campaign_id `

// issuableSQL: the drop issues coupons now (active, merchant not suspended).
const issuableSQL = dropStatusSQL + ` = 'active' AND m.merchant_status <> 'suspended'`

// todaySQL is the business date in SQL.
const todaySQL = `(now() AT TIME ZONE 'Asia/Shanghai')::date`

// Soft issuing failures: during settlement they are skipped silently.
var (
	errAlreadyClaimed = httpx.Conflict("already_claimed", "今天已经领过这个投放的券了")
	errSoldOut        = httpx.Conflict("sold_out", "今天的券已经发完了")
	errUnavailable    = httpx.NotFound("投放")
)

func soft(err error) bool {
	return errors.Is(err, errAlreadyClaimed) || errors.Is(err, errSoldOut) || errors.Is(err, errUnavailable)
}

// issueSource records how the coupon was earned.
type issueSource struct {
	activityID, chestID, venueID *int64
}

const codeAlphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

func newCode() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	for i := range b {
		b[i] = codeAlphabet[int(b[i])%len(codeAlphabet)]
	}
	return string(b)
}

// issue gives the user one coupon of the drop (one per user per drop per
// day, within the drop's daily cap). The drop row is locked so concurrent
// issues count the cap correctly.
func (s *Service) issue(ctx context.Context, tx pgx.Tx, dropID, user int64, src issueSource) (*Coupon, error) {
	var typ, name string
	var merchant int64
	var campaign *int64
	var dailyCap int
	var perk Perk
	var ok bool
	err := tx.QueryRow(ctx, `SELECT d.drop_type, d.drop_name, d.merchant_id, d.campaign_id, d.daily_cap_qty,
			d.perk_title, d.perk_description, d.perk_value_text, d.perk_valid_days, d.perk_rules, `+issuableSQL+dropFrom+`
		WHERE d.id=$1 FOR UPDATE OF d`, dropID).
		Scan(&typ, &name, &merchant, &campaign, &dailyCap, &perk.Title, &perk.Description, &perk.ValueText, &perk.ValidDays, &perk.Rules, &ok)
	if db.IsNoRows(err) || (err == nil && !ok) {
		return nil, errUnavailable
	}
	if err != nil {
		return nil, err
	}
	today := clock.Today()
	var mine bool
	var issued int
	if err := tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE user_id=$2) > 0, count(*) FROM src.src_mkt_loop_coupon WHERE drop_id=$1 AND obtain_date=$3`,
		dropID, user, today).Scan(&mine, &issued); err != nil {
		return nil, err
	}
	if mine {
		return nil, errAlreadyClaimed
	}
	if dailyCap > 0 && issued >= dailyCap {
		return nil, errSoldOut
	}
	perkJSON, _ := json.Marshal(perk)
	var id int64
	for attempt := 0; ; attempt++ {
		err = tx.QueryRow(ctx, `INSERT INTO src.src_mkt_loop_coupon (coupon_code, user_id, drop_id, merchant_id, campaign_id, source_type, source_name,
				perk_json, obtain_date, expire_time, activity_id, chest_id, venue_id)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9, now() + make_interval(days => $10), $11, $12, $13) ON CONFLICT DO NOTHING RETURNING id`,
			newCode(), user, dropID, merchant, campaign, typ, name, perkJSON, today, perk.ValidDays, src.activityID, src.chestID, src.venueID).Scan(&id)
		if err == nil {
			break
		}
		if !db.IsNoRows(err) || attempt >= 5 {
			return nil, err
		}
		// Conflict: a code collision (retry) — the per-day row was checked above.
	}
	if dailyCap > 0 && issued+1 >= dailyCap && typ == "chest" {
		// 发完当天不再发，地图上不显示.
		if _, err := tx.Exec(ctx, `UPDATE src.src_ply_loop_chest SET remove_time=now() WHERE drop_id=$1 AND remove_time IS NULL`, dropID); err != nil {
			return nil, err
		}
	}
	c, err := loadCoupon(ctx, tx, id)
	return &c, err
}

// ---------------------------------------------------------------- QR

func qrSig(key []byte, id, ts int64) string {
	m := hmac.New(sha256.New, key)
	fmt.Fprintf(m, "LPC.%d.%d", id, ts)
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil)[:16])
}

// QRPayload is the content of the coupon QR code shown at time t.
func (s *Service) QRPayload(id int64, t time.Time) string {
	ts := t.Unix()
	return fmt.Sprintf("LPC.%d.%d.%s", id, ts, qrSig(s.QRKey, id, ts))
}

var (
	errInvalidCoupon = httpx.BadRequest("invalid_coupon", "无效的券码")
	errQRExpired     = httpx.BadRequest("invalid_coupon", "二维码已过期，请让用户刷新后重新出示")
)

// parseQR checks a payload's signature and age and returns the coupon id.
func (s *Service) parseQR(p string, now time.Time) (int64, error) {
	parts := strings.Split(strings.TrimSpace(p), ".")
	if len(parts) != 4 || parts[0] != "LPC" {
		return 0, errInvalidCoupon
	}
	id, err1 := strconv.ParseInt(parts[1], 10, 64)
	ts, err2 := strconv.ParseInt(parts[2], 10, 64)
	if err1 != nil || err2 != nil || !hmac.Equal([]byte(parts[3]), []byte(qrSig(s.QRKey, id, ts))) {
		return 0, errInvalidCoupon
	}
	age := now.Sub(time.Unix(ts, 0))
	if age > QRTTL || age < -5*time.Second {
		return 0, errQRExpired
	}
	return id, nil
}

// ---------------------------------------------------------------- app reads

// MyCoupons lists the user's coupons (status: unused | used | expired | voided | "").
func (s *Service) MyCoupons(ctx context.Context, user int64, status string) ([]Coupon, error) {
	rows, err := s.Pool.Query(ctx, `SELECT `+couponCols+couponFrom+` WHERE c.user_id=$1 AND ($2 = '' OR `+couponStatusSQL+` = $2)
		ORDER BY CASE WHEN `+couponStatusSQL+` = 'unused' THEN c.expire_time END, c.create_time DESC LIMIT 200`,
		user, status)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Coupon, error) { return scanCoupon(r) })
	if out == nil {
		out = []Coupon{}
	}
	return out, err
}

// QR returns the current QR payload of the user's unused coupon.
func (s *Service) QR(ctx context.Context, user, id int64) (string, error) {
	c, err := loadCoupon(ctx, s.Pool, id)
	if err != nil {
		return "", err
	}
	if c.userID != user {
		return "", httpx.NotFound("券")
	}
	switch c.Status {
	case "used":
		return "", httpx.Conflict("coupon_used", "这张券已经核销过了")
	case "expired":
		return "", httpx.Conflict("coupon_expired", "这张券已过期")
	case "voided":
		return "", httpx.Conflict("coupon_voided", "这张券已作废")
	}
	return s.QRPayload(id, time.Now()), nil
}

// ---------------------------------------------------------------- jobs

// ExpireCoupons marks unused coupons past their expiry.
func (s *Service) ExpireCoupons(ctx context.Context) error {
	_, err := s.Pool.Exec(ctx, `UPDATE src.src_mkt_loop_coupon SET coupon_status='expired', update_time=now()
		WHERE coupon_status='unused' AND expire_time <= now()`)
	return err
}

// Jobs returns the periodic jobs for the job runner.
func (s *Service) Jobs() map[string]func(context.Context) error {
	return map[string]func(context.Context) error{
		"coupon_expire":     s.ExpireCoupons,
		"merchant_chests":   func(ctx context.Context) error { return s.SpawnChests(ctx, time.Now()) },
		"weekly_statements": func(ctx context.Context) error { return s.WeeklyStatements(ctx, time.Now()) },
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
