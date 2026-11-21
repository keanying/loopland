package perks

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// UserRef is a compact user.
type UserRef struct {
	ID       int64  `json:"id"`
	Nickname string `json:"nickname"`
}

// Redemption is one in-store redemption.
type Redemption struct {
	ID           int64       `json:"id"`
	RedemptionNo string      `json:"redemption_no"`
	Coupon       Coupon      `json:"coupon"`
	User         UserRef     `json:"user"`
	Merchant     MerchantRef `json:"merchant"`
	Store        string      `json:"store"`
	Status       string      `json:"status"`
	ActivityID   int64       `json:"activity_id"`
	CreatedAt    time.Time   `json:"created_at"`
}

// RedeemInput is POST /admin/v1/redemptions.
type RedeemInput struct {
	Payload string `json:"payload"`
	Code    string `json:"code"`
	// Store optionally names the store; defaults to the drop's store name.
	Store string `json:"store"`
}

var (
	errCouponUsed    = httpx.Conflict("coupon_used", "这张券已经核销过了")
	errCouponExpired = httpx.Conflict("coupon_expired", "这张券已过期")
	errWrongMerchant = httpx.Forbidden("wrong_merchant", "这张券不是本商户的")
	errNoActivity    = httpx.Conflict("no_activity_today", "今天还没有运动记录，运动后再来核销")
	errCapReached    = httpx.Conflict("daily_cap_reached", "这个投放今天的核销已达上限")
)

func newRedemptionNo() string {
	t := time.Now().In(clock.Shanghai)
	return "RD" + t.Format("20060102150405") + newCode()[:4]
}

// Redeem checks and redeems a coupon. scope limits merchant staff to their
// merchant; adminID is the operator.
func (s *Service) Redeem(ctx context.Context, scope *int64, adminID int64, in RedeemInput) (Redemption, error) {
	var couponID int64
	inputType := "payload"
	switch {
	case strings.TrimSpace(in.Payload) != "":
		id, err := s.parseQR(in.Payload, time.Now())
		if err != nil {
			return Redemption{}, err
		}
		couponID = id
	case strings.TrimSpace(in.Code) != "":
		inputType = "code"
		err := s.Pool.QueryRow(ctx, `SELECT id FROM src.src_mkt_loop_coupon WHERE coupon_code=$1`, strings.ToUpper(strings.TrimSpace(in.Code))).Scan(&couponID)
		if db.IsNoRows(err) {
			return Redemption{}, errInvalidCoupon
		}
		if err != nil {
			return Redemption{}, err
		}
	default:
		return Redemption{}, httpx.BadRequest("invalid_body", "payload 和 code 至少填一个")
	}
	var out Redemption
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var user, merchant, drop int64
		var campaign *int64
		var status, title string
		var expired bool
		err := tx.QueryRow(ctx, `SELECT user_id, merchant_id, drop_id, campaign_id, coupon_status, expire_time <= now(), perk_json->>'title'
			FROM src.src_mkt_loop_coupon WHERE id=$1 FOR UPDATE`, couponID).Scan(&user, &merchant, &drop, &campaign, &status, &expired, &title)
		if db.IsNoRows(err) {
			return errInvalidCoupon
		}
		if err != nil {
			return err
		}
		if scope != nil && *scope != merchant {
			return errWrongMerchant
		}
		switch {
		case status == "used":
			return errCouponUsed
		case status == "voided":
			return httpx.BadRequest("invalid_coupon", "这张券已作废")
		case status == "expired" || expired:
			return errCouponExpired
		}
		today := clock.Today()
		var activityID int64
		err = tx.QueryRow(ctx, `SELECT id FROM src.src_act_loop_activity WHERE user_id=$1 AND status='settled' AND end_time >= $2 AND end_time < $3
			ORDER BY end_time DESC LIMIT 1`, user, today, today.AddDate(0, 0, 1)).Scan(&activityID)
		if db.IsNoRows(err) {
			return errNoActivity
		}
		if err != nil {
			return err
		}
		var dailyCap int
		var price int64
		var direction, dropName string
		var store *string
		if err := tx.QueryRow(ctx, `SELECT daily_cap_qty, settle_price_amt, settle_direction, drop_name, store_name FROM src.src_mer_loop_drop WHERE id=$1 FOR UPDATE`,
			drop).Scan(&dailyCap, &price, &direction, &dropName, &store); err != nil {
			return err
		}
		if dailyCap > 0 {
			var n int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM src.src_mer_loop_redemption WHERE drop_id=$1 AND redeem_date=$2 AND redemption_status='valid'`,
				drop, today).Scan(&n); err != nil {
				return err
			}
			if n >= dailyCap {
				return errCapReached
			}
		}
		storeName := strings.TrimSpace(in.Store)
		if storeName == "" && store != nil {
			storeName = *store
		}
		if storeName == "" {
			storeName = dropName
		}
		var id int64
		if err := tx.QueryRow(ctx, `INSERT INTO src.src_mer_loop_redemption (redemption_no, coupon_id, user_id, merchant_id, drop_id, campaign_id, admin_id,
				input_type, store_name, activity_id, redeem_date, settle_price_amt, settle_direction)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING id`,
			newRedemptionNo(), couponID, user, merchant, drop, campaign, adminID, inputType, storeName, activityID, today, price, direction).Scan(&id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_mkt_loop_coupon SET coupon_status='used', use_time=now(), use_store_name=$2, update_time=now() WHERE id=$1`,
			couponID, storeName); err != nil {
			return err
		}
		if err := inbox.Notify(ctx, tx, user, inbox.System, "券已核销", fmt.Sprintf("你的「%s」已在%s核销，祝你运动愉快。", title, storeName),
			map[string]any{"coupon_id": couponID, "redemption_id": id}); err != nil {
			return err
		}
		out, err = loadRedemption(ctx, tx, id)
		return err
	})
	return out, err
}

const redemptionCols = `r.id, r.redemption_no, r.coupon_id, u.id, u.nickname, m.id, m.merchant_name, r.store_name, r.redemption_status, r.activity_id, r.create_time`

const redemptionFrom = ` FROM src.src_mer_loop_redemption r JOIN src.src_usr_loop_user u ON u.id=r.user_id JOIN src.src_mer_loop_merchant m ON m.id=r.merchant_id `

func scanRedemption(ctx context.Context, q db.Querier, row pgx.Row) (Redemption, error) {
	var x Redemption
	var couponID int64
	if err := row.Scan(&x.ID, &x.RedemptionNo, &couponID, &x.User.ID, &x.User.Nickname, &x.Merchant.ID, &x.Merchant.Name, &x.Store, &x.Status,
		&x.ActivityID, &x.CreatedAt); err != nil {
		return x, err
	}
	var err error
	x.Coupon, err = loadCoupon(ctx, q, couponID)
	return x, err
}

func loadRedemption(ctx context.Context, q db.Querier, id int64) (Redemption, error) {
	return scanRedemption(ctx, q, q.QueryRow(ctx, `SELECT `+redemptionCols+redemptionFrom+` WHERE r.id=$1`, id))
}

// RedemptionFilter filters the list.
type RedemptionFilter struct {
	MerchantID int64
	From, To   *time.Time
	Status     string
}

// Redemptions lists redemptions, newest first.
func (s *Service) Redemptions(ctx context.Context, f RedemptionFilter, p httpx.Page) ([]Redemption, int, error) {
	where := `($1 = 0 OR r.merchant_id=$1) AND ($2::date IS NULL OR r.redeem_date >= $2) AND ($3::date IS NULL OR r.redeem_date <= $3)
		AND ($4 = '' OR r.redemption_status=$4)`
	args := []any{f.MerchantID, f.From, f.To, f.Status}
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*)`+redemptionFrom+` WHERE `+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT `+redemptionCols+redemptionFrom+` WHERE `+where+` ORDER BY r.id DESC LIMIT $5 OFFSET $6`,
		append(args, p.Size, p.Offset())...)
	if err != nil {
		return nil, 0, err
	}
	type raw struct {
		x        Redemption
		couponID int64
	}
	var list []raw
	for rows.Next() {
		var x raw
		if err := rows.Scan(&x.x.ID, &x.x.RedemptionNo, &x.couponID, &x.x.User.ID, &x.x.User.Nickname, &x.x.Merchant.ID, &x.x.Merchant.Name,
			&x.x.Store, &x.x.Status, &x.x.ActivityID, &x.x.CreatedAt); err != nil {
			rows.Close()
			return nil, 0, err
		}
		list = append(list, x)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	out := make([]Redemption, 0, len(list))
	for _, x := range list {
		c, err := loadCoupon(ctx, s.Pool, x.couponID)
		if err != nil {
			return nil, 0, err
		}
		x.x.Coupon = c
		out = append(out, x.x)
	}
	return out, total, nil
}

// ActivityVoided runs when risk control voids an activity (activity.Service
// OnVoid): redemptions that relied on it move to another valid activity of
// the same day, or are voided (不进结算); unused coupons it earned are
// voided. Draft statements that already list a voided redemption are
// recomputed.
func (s *Service) ActivityVoided(ctx context.Context, tx pgx.Tx, activityID int64) error {
	rows, err := tx.Query(ctx, `SELECT id, user_id, redeem_date, statement_id FROM src.src_mer_loop_redemption
		WHERE activity_id=$1 AND redemption_status='valid' FOR UPDATE`, activityID)
	if err != nil {
		return err
	}
	type dep struct {
		id, user  int64
		day       time.Time
		statement *int64
	}
	deps, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (dep, error) {
		var d dep
		return d, r.Scan(&d.id, &d.user, &d.day, &d.statement)
	})
	if err != nil {
		return err
	}
	touched := map[int64]bool{}
	for _, d := range deps {
		day := time.Date(d.day.Year(), d.day.Month(), d.day.Day(), 0, 0, 0, 0, clock.Shanghai)
		var other int64
		err := tx.QueryRow(ctx, `SELECT id FROM src.src_act_loop_activity WHERE user_id=$1 AND id<>$2 AND status='settled' AND end_time >= $3 AND end_time < $4
			ORDER BY end_time DESC LIMIT 1`, d.user, activityID, day, day.AddDate(0, 0, 1)).Scan(&other)
		if err == nil {
			if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_redemption SET activity_id=$2, update_time=now() WHERE id=$1`, d.id, other); err != nil {
				return err
			}
			continue
		}
		if !db.IsNoRows(err) {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_redemption SET redemption_status='voided', void_reason='activity_voided', void_time=now(), update_time=now()
			WHERE id=$1`, d.id); err != nil {
			return err
		}
		if d.statement != nil {
			if _, err := tx.Exec(ctx, `UPDATE src.src_fin_loop_statement_line SET is_voided=true WHERE line_type='redemption' AND ref_id=$1`, d.id); err != nil {
				return err
			}
			touched[*d.statement] = true
		}
	}
	for id := range touched {
		var status string
		if err := tx.QueryRow(ctx, `SELECT statement_status FROM src.src_fin_loop_statement WHERE id=$1 FOR UPDATE`, id).Scan(&status); err != nil {
			return err
		}
		if status == "draft" {
			if err := recompute(ctx, tx, id); err != nil {
				return err
			}
		}
	}
	_, err = tx.Exec(ctx, `UPDATE src.src_mkt_loop_coupon SET coupon_status='voided', void_time=now(), update_time=now()
		WHERE activity_id=$1 AND coupon_status='unused'`, activityID)
	return err
}
