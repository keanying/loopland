package perks

import (
	"context"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/webhook"
)

// UserRef is a compact user.
type UserRef struct {
	ID       int64  `json:"id"`
	Nickname string `json:"nickname"`
}

// Redemption is one in-store redemption (a pass makes one per use).
type Redemption struct {
	ID           int64       `json:"id"`
	RedemptionNo string      `json:"redemption_no"`
	Coupon       Coupon      `json:"coupon"`
	User         UserRef     `json:"user"`
	Merchant     MerchantRef `json:"merchant"`
	Store        string      `json:"store"`
	Status       string      `json:"status"`
	// ActivityID is the day's activity a drop coupon relied on (null for
	// product coupons).
	ActivityID *int64    `json:"activity_id"`
	CreatedAt  time.Time `json:"created_at"`
}

// RedeemInput is POST /admin/v1/redemptions.
type RedeemInput struct {
	Payload string `json:"payload"`
	Code    string `json:"code"`
	// Store optionally names the store; defaults to the drop's store name.
	Store string `json:"store"`
}

// Operator is who redeems: a back-office account (AdminID; Scope limits
// merchant staff to their merchant) or an open platform app (AppID, Scope
// is its merchant).
type Operator struct {
	Scope   *int64
	AdminID int64
	AppID   int64
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

// couponOf resolves the QR payload or the hand-typed code to a coupon id.
func (s *Service) couponOf(ctx context.Context, in RedeemInput) (int64, string, error) {
	switch {
	case strings.TrimSpace(in.Payload) != "":
		id, err := s.parseQR(in.Payload, time.Now())
		return id, "payload", err
	case strings.TrimSpace(in.Code) != "":
		var id int64
		err := s.Pool.QueryRow(ctx, `SELECT id FROM src.src_mkt_loop_coupon WHERE coupon_code=$1`, strings.ToUpper(strings.TrimSpace(in.Code))).Scan(&id)
		if db.IsNoRows(err) {
			return 0, "", errInvalidCoupon
		}
		return id, "code", err
	}
	return 0, "", httpx.BadRequest("invalid_body", "payload 和 code 至少填一个")
}

// Redeem checks and redeems a coupon. scope limits merchant staff to their
// merchant; adminID is the operator.
func (s *Service) Redeem(ctx context.Context, scope *int64, adminID int64, in RedeemInput) (Redemption, error) {
	return s.RedeemAs(ctx, Operator{Scope: scope, AdminID: adminID}, in)
}

// RedeemAs redeems for a back-office account or an open platform app. Drop
// coupons need an activity of the day and respect the drop's daily cap;
// product coupons need neither but are checked against their stores, and a
// pass is redeemed one use at a time.
func (s *Service) RedeemAs(ctx context.Context, op Operator, in RedeemInput) (Redemption, error) {
	couponID, inputType, err := s.couponOf(ctx, in)
	if err != nil {
		return Redemption{}, err
	}
	var out Redemption
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var user, merchant int64
		var drop, campaign *int64
		var status, title, source string
		var expired bool
		var pc productCoupon
		var productID, orderID *int64
		err := tx.QueryRow(ctx, `SELECT c.user_id, c.merchant_id, c.drop_id, c.campaign_id, c.coupon_status, c.expire_time <= now(), c.perk_json->>'title',
				c.source_type, c.product_id, c.product_order_id, c.use_qty, c.left_use_qty, c.paid_amt, c.platform_subsidy_amt, c.venue_ids,
				m.merchant_name, c.source_name
			FROM src.src_mkt_loop_coupon c JOIN src.src_mer_loop_merchant m ON m.id=c.merchant_id WHERE c.id=$1 FOR UPDATE OF c`, couponID).
			Scan(&user, &merchant, &drop, &campaign, &status, &expired, &title, &source, &productID, &orderID, &pc.useQty, &pc.leftUseQty,
				&pc.paidAmt, &pc.subsidyAmt, &pc.venueIDs, &pc.merchantName, &pc.perkName)
		if db.IsNoRows(err) {
			return errInvalidCoupon
		}
		if err != nil {
			return err
		}
		if op.Scope != nil && *op.Scope != merchant {
			return errWrongMerchant
		}
		switch {
		case status == "used":
			return errCouponUsed
		case status == "voided":
			return httpx.BadRequest("invalid_coupon", "这张券已作废")
		case status == "refunded":
			return httpx.BadRequest("invalid_coupon", "这张券已退款")
		case status == "expired" || expired:
			return errCouponExpired
		}
		today := clock.Today()
		var adminID, appID *int64
		if op.AdminID != 0 {
			adminID = &op.AdminID
		}
		if op.AppID != 0 {
			appID = &op.AppID
		}
		var id int64
		var body string
		if source == "product" {
			pc.productID, pc.orderID = *productID, *orderID
			storeName, err := storeFor(ctx, tx, pc, in.Store)
			if err != nil {
				return err
			}
			if err := tx.QueryRow(ctx, `SELECT promotion_id FROM src.src_ord_loop_product_order WHERE id=$1`, pc.orderID).Scan(&pc.promotionID); err != nil {
				return err
			}
			amt := int(math.Round(float64(pc.paidAmt) / float64(pc.useQty)))
			subsidy := int(math.Round(float64(pc.subsidyAmt) / float64(pc.useQty)))
			if err := tx.QueryRow(ctx, `INSERT INTO src.src_mer_loop_redemption (redemption_no, coupon_id, user_id, merchant_id, admin_id, open_app_id,
					input_type, store_name, redeem_date, settle_price_amt, settle_direction, redemption_type, product_id, product_order_id, promotion_id,
					product_amt, product_subsidy_amt)
				VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,0,'platform_pays','product',$10,$11,$12,$13,$14) RETURNING id`,
				newRedemptionNo(), couponID, user, merchant, adminID, appID, inputType, storeName, today, pc.productID, pc.orderID, pc.promotionID,
				amt, subsidy).Scan(&id); err != nil {
				return err
			}
			left := pc.leftUseQty - 1
			if _, err := tx.Exec(ctx, `UPDATE src.src_mkt_loop_coupon SET left_use_qty=$2,
					coupon_status=CASE WHEN $2 = 0 THEN 'used' ELSE coupon_status END,
					use_time=CASE WHEN $2 = 0 THEN now() ELSE use_time END, use_store_name=CASE WHEN $2 = 0 THEN $3 ELSE use_store_name END,
					update_time=now() WHERE id=$1`, couponID, left, storeName); err != nil {
				return err
			}
			if err := SyncProductOrders(ctx, tx, pc.orderID); err != nil {
				return err
			}
			body = fmt.Sprintf("你的「%s」已在%s核销，祝你运动愉快。", title, storeName)
			if pc.useQty > 1 {
				body = fmt.Sprintf("你的「%s」已在%s核销 1 次，还剩 %d 次。", title, storeName, left)
			}
		} else {
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
				*drop).Scan(&dailyCap, &price, &direction, &dropName, &store); err != nil {
				return err
			}
			if dailyCap > 0 {
				var n int
				if err := tx.QueryRow(ctx, `SELECT count(*) FROM src.src_mer_loop_redemption WHERE drop_id=$1 AND redeem_date=$2 AND redemption_status='valid'`,
					*drop, today).Scan(&n); err != nil {
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
			if err := tx.QueryRow(ctx, `INSERT INTO src.src_mer_loop_redemption (redemption_no, coupon_id, user_id, merchant_id, drop_id, campaign_id, admin_id,
					open_app_id, input_type, store_name, activity_id, redeem_date, settle_price_amt, settle_direction)
				VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14) RETURNING id`,
				newRedemptionNo(), couponID, user, merchant, *drop, campaign, adminID, appID, inputType, storeName, activityID, today, price, direction).Scan(&id); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE src.src_mkt_loop_coupon SET coupon_status='used', use_time=now(), use_store_name=$2, update_time=now() WHERE id=$1`,
				couponID, storeName); err != nil {
				return err
			}
			body = fmt.Sprintf("你的「%s」已在%s核销，祝你运动愉快。", title, storeName)
		}
		if err := inbox.Notify(ctx, tx, user, inbox.System, "券已核销", body, map[string]any{"coupon_id": couponID, "redemption_id": id}); err != nil {
			return err
		}
		out, err = loadRedemption(ctx, tx, id)
		if err != nil {
			return err
		}
		return webhook.Emit(ctx, tx, merchant, webhook.RedemptionCreated, out)
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
	// BeforeID pages by id (open API cursor): only redemptions older than it.
	BeforeID int64
}

// Redemptions lists redemptions, newest first.
func (s *Service) Redemptions(ctx context.Context, f RedemptionFilter, p httpx.Page) ([]Redemption, int, error) {
	where := `($1 = 0 OR r.merchant_id=$1) AND ($2::date IS NULL OR r.redeem_date >= $2) AND ($3::date IS NULL OR r.redeem_date <= $3)
		AND ($4 = '' OR r.redemption_status=$4) AND ($5 = 0 OR r.id < $5)`
	args := []any{f.MerchantID, f.From, f.To, f.Status, f.BeforeID}
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*)`+redemptionFrom+` WHERE `+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT `+redemptionCols+redemptionFrom+` WHERE `+where+` ORDER BY r.id DESC LIMIT $6 OFFSET $7`,
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
	for _, d := range deps {
		var voided bool
		var merchant int64
		if err := tx.QueryRow(ctx, `SELECT redemption_status='voided', merchant_id FROM src.src_mer_loop_redemption WHERE id=$1`, d.id).Scan(&voided, &merchant); err != nil {
			return err
		}
		if !voided {
			continue
		}
		x, err := loadRedemption(ctx, tx, d.id)
		if err != nil {
			return err
		}
		if err := webhook.Emit(ctx, tx, merchant, webhook.RedemptionVoided, x); err != nil {
			return err
		}
	}
	_, err = tx.Exec(ctx, `UPDATE src.src_mkt_loop_coupon SET coupon_status='voided', void_time=now(), update_time=now()
		WHERE activity_id=$1 AND coupon_status='unused'`, activityID)
	return err
}
