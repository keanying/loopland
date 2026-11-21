package perks

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/activity"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/play"
	"github.com/keanying/loopland/server/internal/territory"
)

// Drop is an admin drop (投放).
type Drop struct {
	ID              int64       `json:"id"`
	Merchant        MerchantRef `json:"merchant"`
	CampaignID      *int64      `json:"campaign_id"`
	Type            string      `json:"type"`
	Name            string      `json:"name"`
	Center          *LatLng     `json:"center"`
	RadiusM         float64     `json:"radius_m"`
	VenueID         *int64      `json:"venue_id"`
	StoreName       *string     `json:"store_name"`
	Perk            Perk        `json:"perk"`
	DailyCap        int         `json:"daily_cap"`
	IssuedToday     int         `json:"issued_today"`
	RedeemedToday   int         `json:"redeemed_today"`
	StartTime       time.Time   `json:"start_time"`
	EndTime         time.Time   `json:"end_time"`
	Status          string      `json:"status"`
	SettlePriceAmt  int64       `json:"settle_price_amt"`
	SettleDirection string      `json:"settle_direction"`
}

// PublicDrop is the Drop as the app sees it (no settlement or daily numbers).
type PublicDrop struct {
	ID         int64       `json:"id"`
	Merchant   MerchantRef `json:"merchant"`
	CampaignID *int64      `json:"campaign_id"`
	Type       string      `json:"type"`
	Name       string      `json:"name"`
	Center     *LatLng     `json:"center"`
	RadiusM    float64     `json:"radius_m"`
	VenueID    *int64      `json:"venue_id"`
	Perk       Perk        `json:"perk"`
	DailyCap   int         `json:"daily_cap"`
	StartTime  time.Time   `json:"start_time"`
	EndTime    time.Time   `json:"end_time"`
	Status     string      `json:"status"`
}

// Public strips the admin-only fields.
func (d Drop) Public() PublicDrop {
	return PublicDrop{ID: d.ID, Merchant: d.Merchant, CampaignID: d.CampaignID, Type: d.Type, Name: d.Name, Center: d.Center, RadiusM: d.RadiusM,
		VenueID: d.VenueID, Perk: d.Perk, DailyCap: d.DailyCap, StartTime: d.StartTime, EndTime: d.EndTime, Status: d.Status}
}

const dropCols = `d.id, m.id, m.merchant_name, d.campaign_id, d.drop_type, d.drop_name, ST_Y(d.center_geom), ST_X(d.center_geom), d.radius_m, d.venue_id,
	d.store_name, d.perk_title, d.perk_description, d.perk_value_text, d.perk_valid_days, d.perk_rules, d.daily_cap_qty,
	(SELECT count(*) FROM src.src_mkt_loop_coupon c WHERE c.drop_id=d.id AND c.obtain_date=` + todaySQL + `)::int,
	(SELECT count(*) FROM src.src_mer_loop_redemption r WHERE r.drop_id=d.id AND r.redeem_date=` + todaySQL + ` AND r.redemption_status='valid')::int,
	d.start_time, d.end_time, ` + dropStatusSQL + `, d.settle_price_amt, d.settle_direction`

func scanDrop(r pgx.Row) (Drop, error) {
	var d Drop
	var lat, lng *float64
	err := r.Scan(&d.ID, &d.Merchant.ID, &d.Merchant.Name, &d.CampaignID, &d.Type, &d.Name, &lat, &lng, &d.RadiusM, &d.VenueID, &d.StoreName,
		&d.Perk.Title, &d.Perk.Description, &d.Perk.ValueText, &d.Perk.ValidDays, &d.Perk.Rules, &d.DailyCap, &d.IssuedToday, &d.RedeemedToday,
		&d.StartTime, &d.EndTime, &d.Status, &d.SettlePriceAmt, &d.SettleDirection)
	if lat != nil && lng != nil {
		d.Center = &LatLng{Lat: *lat, Lng: *lng}
	}
	return d, err
}

func collectDrops(rows pgx.Rows, err error) ([]Drop, error) {
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Drop, error) { return scanDrop(r) })
	if out == nil {
		out = []Drop{}
	}
	return out, err
}

// LoadDrop returns one drop.
func LoadDrop(ctx context.Context, q db.Querier, id int64) (Drop, error) {
	d, err := scanDrop(q.QueryRow(ctx, `SELECT `+dropCols+dropFrom+` WHERE d.id=$1`, id))
	if db.IsNoRows(err) {
		return d, httpx.NotFound("投放")
	}
	return d, err
}

// DropsOfMerchant lists a merchant's drops (for the merchant detail page).
func DropsOfMerchant(ctx context.Context, q db.Querier, merchantID int64) ([]Drop, error) {
	return collectDrops(q.Query(ctx, `SELECT `+dropCols+dropFrom+` WHERE d.merchant_id=$1 ORDER BY d.id DESC`, merchantID))
}

// DropFilter filters the admin list.
type DropFilter struct {
	MerchantID, CampaignID int64
	Type, Status           string
}

// AdminDrops lists drops for the admin.
func (s *Service) AdminDrops(ctx context.Context, f DropFilter, p httpx.Page) ([]Drop, int, error) {
	where := `($1 = 0 OR d.merchant_id=$1) AND ($2 = 0 OR d.campaign_id=$2) AND ($3 = '' OR d.drop_type=$3) AND ($4 = '' OR ` + dropStatusSQL + ` = $4)`
	args := []any{f.MerchantID, f.CampaignID, f.Type, f.Status}
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*)`+dropFrom+` WHERE `+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	items, err := collectDrops(s.Pool.Query(ctx, `SELECT `+dropCols+dropFrom+` WHERE `+where+` ORDER BY d.id DESC LIMIT $5 OFFSET $6`,
		append(args, p.Size, p.Offset())...))
	return items, total, err
}

// DropInput is the admin create / update body.
type DropInput struct {
	MerchantID      int64     `json:"merchant_id"`
	CampaignID      *int64    `json:"campaign_id"`
	Type            string    `json:"type"`
	Name            string    `json:"name"`
	Center          *LatLng   `json:"center"`
	RadiusM         float64   `json:"radius_m"`
	VenueID         *int64    `json:"venue_id"`
	StoreName       *string   `json:"store_name"`
	Perk            Perk      `json:"perk"`
	DailyCap        int       `json:"daily_cap"`
	StartTime       time.Time `json:"start_time"`
	EndTime         time.Time `json:"end_time"`
	SettlePriceAmt  int64     `json:"settle_price_amt"`
	SettleDirection string    `json:"settle_direction"`
}

func bad(msg string) error { return httpx.BadRequest("invalid_body", msg) }

func (in *DropInput) validate(ctx context.Context, q db.Querier) error {
	in.Name, in.Perk.Title = strings.TrimSpace(in.Name), strings.TrimSpace(in.Perk.Title)
	if in.SettleDirection == "" {
		in.SettleDirection = "merchant_pays"
	}
	if in.Perk.ValidDays == 0 {
		in.Perk.ValidDays = 7
	}
	if in.RadiusM == 0 {
		in.RadiusM = 80
	}
	switch {
	case in.Type != "supply" && in.Type != "chest" && in.Type != "stronghold":
		return bad("type 只能是 supply / chest / stronghold")
	case in.Name == "" || in.Perk.Title == "":
		return bad("名称和权益标题不能为空")
	case in.Perk.ValidDays < 1 || in.Perk.ValidDays > 365:
		return bad("券有效天数为 1-365")
	case in.RadiusM <= 0 || in.RadiusM > 5000:
		return bad("范围半径为 1-5000 米")
	case in.DailyCap < 0:
		return bad("每日上限不能为负（0 表示不限）")
	case !in.EndTime.After(in.StartTime):
		return bad("结束时间必须晚于开始时间")
	case in.SettlePriceAmt < 0:
		return bad("结算单价不能为负")
	case in.SettleDirection != "merchant_pays" && in.SettleDirection != "platform_pays":
		return bad("settle_direction 只能是 merchant_pays / platform_pays")
	case in.Type == "stronghold" && in.VenueID == nil:
		return bad("据点必须绑定场馆（venue_id）")
	case in.Type != "stronghold" && in.Center == nil:
		return bad("补给站和宝箱必须设置位置（center）")
	}
	if c := in.Center; c != nil && (c.Lat < -90 || c.Lat > 90 || c.Lng < -180 || c.Lng > 180 || (c.Lat == 0 && c.Lng == 0)) {
		return bad("位置不合法")
	}
	var ok bool
	if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_mer_loop_merchant WHERE id=$1)`, in.MerchantID).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return bad("商户不存在")
	}
	if in.CampaignID != nil {
		var m int64
		err := q.QueryRow(ctx, `SELECT merchant_id FROM src.src_mkt_loop_brand_campaign WHERE id=$1`, *in.CampaignID).Scan(&m)
		if db.IsNoRows(err) || (err == nil && m != in.MerchantID) {
			return bad("联名活动不存在或不属于这个商户")
		}
		if err != nil {
			return err
		}
	}
	if in.VenueID != nil {
		// Venues live in 0009 (part A); check only once that table exists.
		var exists bool
		if err := q.QueryRow(ctx, `SELECT to_regclass('src.src_mer_loop_venue') IS NOT NULL`).Scan(&exists); err != nil {
			return err
		}
		if exists {
			if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_mer_loop_venue WHERE id=$1)`, *in.VenueID).Scan(&ok); err != nil {
				return err
			}
			if !ok {
				return bad("场馆不存在")
			}
		}
	}
	return nil
}

func (in DropInput) point() (any, any) {
	if in.Center == nil {
		return nil, nil
	}
	return in.Center.Lng, in.Center.Lat
}

// CreateDrop stores a new drop.
func (s *Service) CreateDrop(ctx context.Context, tx pgx.Tx, by int64, in DropInput) (int64, error) {
	if err := in.validate(ctx, tx); err != nil {
		return 0, err
	}
	lng, lat := in.point()
	var id int64
	err := tx.QueryRow(ctx, `INSERT INTO src.src_mer_loop_drop (merchant_id, campaign_id, drop_type, drop_name, center_geom, radius_m, venue_id, store_name,
			perk_title, perk_description, perk_value_text, perk_valid_days, perk_rules, daily_cap_qty, start_time, end_time, settle_price_amt, settle_direction, create_admin_id)
		VALUES ($1,$2,$3,$4, CASE WHEN $5::float8 IS NULL THEN NULL ELSE ST_SetSRID(ST_MakePoint($5,$6),4326) END, $7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20)
		RETURNING id`,
		in.MerchantID, in.CampaignID, in.Type, in.Name, lng, lat, in.RadiusM, in.VenueID, in.StoreName,
		in.Perk.Title, in.Perk.Description, in.Perk.ValueText, in.Perk.ValidDays, in.Perk.Rules, in.DailyCap, in.StartTime, in.EndTime,
		in.SettlePriceAmt, in.SettleDirection, by).Scan(&id)
	return id, err
}

// DropInputOf returns the editable fields of a drop.
func (s *Service) DropInputOf(ctx context.Context, id int64) (DropInput, error) {
	d, err := LoadDrop(ctx, s.Pool, id)
	if err != nil {
		return DropInput{}, err
	}
	return DropInput{MerchantID: d.Merchant.ID, CampaignID: d.CampaignID, Type: d.Type, Name: d.Name, Center: d.Center, RadiusM: d.RadiusM,
		VenueID: d.VenueID, StoreName: d.StoreName, Perk: d.Perk, DailyCap: d.DailyCap, StartTime: d.StartTime, EndTime: d.EndTime,
		SettlePriceAmt: d.SettlePriceAmt, SettleDirection: d.SettleDirection}, nil
}

// UpdateDrop saves edited fields. The type cannot change.
func (s *Service) UpdateDrop(ctx context.Context, tx pgx.Tx, id int64, in DropInput) error {
	if err := in.validate(ctx, tx); err != nil {
		return err
	}
	// A moved or edited chest drop gets a fresh chest on the next spawn.
	// Chests are locked before the drop, as a chest open does.
	if _, err := tx.Exec(ctx, `UPDATE src.src_ply_loop_chest SET remove_time=now() WHERE drop_id=$1 AND remove_time IS NULL`, id); err != nil {
		return err
	}
	lng, lat := in.point()
	_, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_drop SET merchant_id=$2, campaign_id=$3, drop_name=$4,
			center_geom=CASE WHEN $5::float8 IS NULL THEN NULL ELSE ST_SetSRID(ST_MakePoint($5,$6),4326) END, radius_m=$7, venue_id=$8, store_name=$9,
			perk_title=$10, perk_description=$11, perk_value_text=$12, perk_valid_days=$13, perk_rules=$14, daily_cap_qty=$15,
			start_time=$16, end_time=$17, settle_price_amt=$18, settle_direction=$19, update_time=now() WHERE id=$1`,
		id, in.MerchantID, in.CampaignID, in.Name, lng, lat, in.RadiusM, in.VenueID, in.StoreName,
		in.Perk.Title, in.Perk.Description, in.Perk.ValueText, in.Perk.ValidDays, in.Perk.Rules, in.DailyCap,
		in.StartTime, in.EndTime, in.SettlePriceAmt, in.SettleDirection)
	return err
}

// PauseDrop pauses (on) or resumes a drop.
func (s *Service) PauseDrop(ctx context.Context, tx pgx.Tx, id int64, on bool) error {
	if on { // chests before the drop, as a chest open locks them
		if _, err := tx.Exec(ctx, `UPDATE src.src_ply_loop_chest SET remove_time=now() WHERE drop_id=$1 AND remove_time IS NULL`, id); err != nil {
			return err
		}
	}
	tag, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_drop SET is_paused=$2, update_time=now() WHERE id=$1`, id, on)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return httpx.NotFound("投放")
	}
	return nil
}

// ---------------------------------------------------------------- supplies

// SupplyPin is a supply station on the map.
type SupplyPin struct {
	ID           int64   `json:"id"`
	Name         string  `json:"name"`
	Center       LatLng  `json:"center"`
	RadiusM      float64 `json:"radius_m"`
	PerkTitle    string  `json:"perk_title"`
	ClaimedToday bool    `json:"claimed_today"`
}

// Supplies implements play.Perks: active supply stations in the viewport
// that still have coupons today.
func (s *Service) Supplies(ctx context.Context, b territory.BBox, user int64) (any, error) {
	rows, err := s.Pool.Query(ctx, `SELECT d.id, d.drop_name, ST_Y(d.center_geom), ST_X(d.center_geom), d.radius_m, d.perk_title,
			EXISTS (SELECT 1 FROM src.src_mkt_loop_coupon c WHERE c.drop_id=d.id AND c.user_id=$5 AND c.obtain_date=`+todaySQL+`)`+dropFrom+`
		WHERE d.drop_type='supply' AND `+issuableSQL+` AND d.center_geom && ST_MakeEnvelope($1,$2,$3,$4,4326)
		  AND (d.daily_cap_qty = 0 OR (SELECT count(*) FROM src.src_mkt_loop_coupon c WHERE c.drop_id=d.id AND c.obtain_date=`+todaySQL+`) < d.daily_cap_qty)
		ORDER BY d.id LIMIT 300`, b[0], b[1], b[2], b[3], user)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (SupplyPin, error) {
		var p SupplyPin
		return p, r.Scan(&p.ID, &p.Name, &p.Center.Lat, &p.Center.Lng, &p.RadiusM, &p.PerkTitle, &p.ClaimedToday)
	})
	if out == nil {
		out = []SupplyPin{}
	}
	return out, err
}

// SuppliesOnTrack implements play.Perks: a coupon from every supply station
// the settled track passed (每人每个补给站每天 1 张).
func (s *Service) SuppliesOnTrack(ctx context.Context, tx pgx.Tx, in activity.HookInput, track *string) ([]any, error) {
	out := []any{}
	if track == nil {
		return out, nil
	}
	rows, err := tx.Query(ctx, `SELECT d.id`+dropFrom+`
		WHERE d.drop_type='supply' AND `+issuableSQL+`
		  AND ST_DWithin(d.center_geom::geography, ST_GeomFromText($1,4326)::geography, d.radius_m)
		ORDER BY d.id`, *track)
	if err != nil {
		return out, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return out, err
	}
	aid := in.ActivityID
	for _, id := range ids {
		c, err := s.issue(ctx, tx, id, in.UserID, issueSource{activityID: &aid})
		if soft(err) {
			continue
		}
		if err != nil {
			return out, err
		}
		out = append(out, c)
	}
	return out, nil
}

// Claim is POST /v1/drops/{id}/claim: the user stands in a supply station.
func (s *Service) Claim(ctx context.Context, user, id int64, lat, lng float64) (*Coupon, error) {
	var typ string
	var inRange bool
	err := s.Pool.QueryRow(ctx, `SELECT d.drop_type, COALESCE(ST_DWithin(d.center_geom::geography, ST_SetSRID(ST_MakePoint($2,$3),4326)::geography, d.radius_m), false)
		FROM src.src_mer_loop_drop d WHERE d.id=$1`, id, lng, lat).Scan(&typ, &inRange)
	if db.IsNoRows(err) || (err == nil && typ != "supply") {
		return nil, httpx.NotFound("补给站")
	}
	if err != nil {
		return nil, err
	}
	if !inRange {
		return nil, httpx.BadRequest("too_far", "离补给站太远了，走近一点再领")
	}
	var c *Coupon
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var err error
		c, err = s.issue(ctx, tx, id, user, issueSource{})
		if errors.Is(err, errUnavailable) {
			return httpx.NotFound("补给站")
		}
		return err
	})
	return c, err
}

// ---------------------------------------------------------------- merchant chests

// ChestCoupon implements play.Perks: the coupon inside a merchant chest.
// Soft failures (sold out, already got one today, drop paused) come back as
// errors the caller may skip.
func (s *Service) ChestCoupon(ctx context.Context, tx pgx.Tx, chestID, dropID, user int64, activityID *int64) (any, error) {
	c, err := s.issue(ctx, tx, dropID, user, issueSource{activityID: activityID, chestID: &chestID})
	if err != nil {
		return nil, err
	}
	return c, nil
}

// SoftError implements play.Perks: whether a ChestCoupon error only means
// "no coupon this time".
func (s *Service) SoftError(err error) bool { return soft(err) }

// SpawnChests keeps one chest at every active chest drop that still has
// coupons today, from 06:00 until 23:00 (深夜不刷: the chest expires at 23:00).
// Chests of drops that stopped issuing are taken off the map.
func (s *Service) SpawnChests(ctx context.Context, now time.Time) error {
	if _, err := s.Pool.Exec(ctx, `UPDATE src.src_ply_loop_chest c SET remove_time=now() FROM src.src_mer_loop_drop d
			JOIN src.src_mer_loop_merchant m ON m.id=d.merchant_id LEFT JOIN src.src_mkt_loop_brand_campaign bc ON bc.id=d.campaign_id
		WHERE c.drop_id=d.id AND c.remove_time IS NULL AND c.expire_time > now() AND NOT (`+issuableSQL+`)`); err != nil {
		return err
	}
	if play.Night(now) || now.In(clock.Shanghai).Hour() < 6 {
		return nil
	}
	day := clock.Day(now)
	nightAt := time.Date(day.Year(), day.Month(), day.Day(), 23, 0, 0, 0, clock.Shanghai)
	_, err := s.Pool.Exec(ctx, `INSERT INTO src.src_ply_loop_chest (center_geom, radius_m, energy_min, energy_max, source, drop_id, expire_time)
		SELECT d.center_geom, d.radius_m, 0, 0, 'merchant', d.id, LEAST($1::timestamptz, d.end_time, COALESCE(bc.end_time, d.end_time))`+dropFrom+`
		WHERE d.drop_type='chest' AND d.center_geom IS NOT NULL AND `+issuableSQL+`
		  AND (d.daily_cap_qty = 0 OR (SELECT count(*) FROM src.src_mkt_loop_coupon c WHERE c.drop_id=d.id AND c.obtain_date=$2) < d.daily_cap_qty)
		  AND NOT EXISTS (SELECT 1 FROM src.src_ply_loop_chest c WHERE c.drop_id=d.id AND c.remove_time IS NULL AND c.expire_time > now())`,
		nightAt, day)
	return err
}

// ---------------------------------------------------------------- strongholds

// IssueStronghold gives the coupon of the venue's stronghold drop on a
// check-in (据点). It implements venue.CouponIssuer: nil when the venue has
// no active stronghold, it ran out today or the user already got one today.
func (s *Service) IssueStronghold(ctx context.Context, tx pgx.Tx, userID, venueID int64) (any, error) {
	rows, err := tx.Query(ctx, `SELECT d.id`+dropFrom+` WHERE d.drop_type='stronghold' AND d.venue_id=$1 AND `+issuableSQL+` ORDER BY d.id`, venueID)
	if err != nil {
		return nil, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return nil, err
	}
	for _, id := range ids {
		c, err := s.issue(ctx, tx, id, userID, issueSource{venueID: &venueID})
		if soft(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		return c, nil
	}
	return nil, nil
}
