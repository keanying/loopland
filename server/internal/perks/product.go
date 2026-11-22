package perks

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// 商品券 (V2 第五批): coupons bought with a merchant product share the
// wallet, the QR code and the redemption desk with drop coupons, but need no
// activity of the day and no daily cap; a pass (次卡) is redeemed once per
// use (docs/api/v2-5-商户商品与开放平台.md «券（Coupon）扩展»).

// ProductCoupons is what a paid product order issues: one coupon per unit.
type ProductCoupons struct {
	OrderID, ProductID, MerchantID, UserID int64
	Qty                                    int
	Name                                   string
	Perk                                   Perk
	UseQty                                 int
	// PaidAmt and SubsidyAmt are per coupon (one unit).
	PaidAmt, SubsidyAmt int
	Refundable          bool
	VenueIDs            []int64
	ExpireTime          time.Time
}

// IssueProductCoupons inserts the coupons of a paid order inside the
// payment transaction.
func IssueProductCoupons(ctx context.Context, tx pgx.Tx, in ProductCoupons) error {
	perk, _ := json.Marshal(in.Perk)
	if in.VenueIDs == nil {
		in.VenueIDs = []int64{}
	}
	for i := 0; i < in.Qty; i++ {
		for attempt := 0; ; attempt++ {
			tag, err := tx.Exec(ctx, `INSERT INTO src.src_mkt_loop_coupon (coupon_code, user_id, merchant_id, source_type, source_name, perk_json, obtain_date,
					expire_time, product_id, product_order_id, use_qty, left_use_qty, paid_amt, platform_subsidy_amt, is_refundable, venue_ids)
				VALUES ($1,$2,$3,'product',$4,$5,$6,$7,$8,$9,$10,$10,$11,$12,$13,$14) ON CONFLICT (coupon_code) DO NOTHING`,
				newCode(), in.UserID, in.MerchantID, in.Name, perk, clock.Today(), in.ExpireTime, in.ProductID, in.OrderID, in.UseQty,
				in.PaidAmt, in.SubsidyAmt, in.Refundable, in.VenueIDs)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 1 {
				break
			}
			if attempt >= 5 {
				return errInvalidCoupon
			}
		}
	}
	return nil
}

// CouponsOfOrder lists a product order's coupons.
func CouponsOfOrder(ctx context.Context, q db.Querier, orderID int64) ([]Coupon, error) {
	rows, err := q.Query(ctx, `SELECT `+couponCols+couponFrom+` WHERE c.product_order_id=$1 ORDER BY c.id`, orderID)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Coupon, error) { return scanCoupon(r) })
	if out == nil {
		out = []Coupon{}
	}
	return out, err
}

// ProductOrderStatusSQL is the status a paid product order should have
// (alias po): refunding while a refund waits for the channel, paid while a
// coupon is unused, refunded when everything was refunded, else completed.
const ProductOrderStatusSQL = `(CASE
	WHEN EXISTS (SELECT 1 FROM src.src_ord_loop_product_refund rf WHERE rf.product_order_id=po.id AND rf.refund_status='pending') THEN 'refunding'
	WHEN EXISTS (SELECT 1 FROM src.src_mkt_loop_coupon cc WHERE cc.product_order_id=po.id AND cc.coupon_status='unused') THEN 'paid'
	WHEN po.refund_amt >= po.amount_amt THEN 'refunded'
	ELSE 'completed' END)`

// SyncProductOrders recomputes the status of paid product orders (one
// order, or all with id 0) after coupons were used, expired or refunded.
func SyncProductOrders(ctx context.Context, q db.Querier, orderID int64) error {
	_, err := q.Exec(ctx, `UPDATE src.src_ord_loop_product_order po SET order_status=`+ProductOrderStatusSQL+`, update_time=now()
		WHERE po.order_status IN ('paid','completed','refunding','refunded') AND ($1 = 0 OR po.id=$1)
		  AND po.order_status IS DISTINCT FROM `+ProductOrderStatusSQL, orderID)
	return err
}

// productCoupon is the product part of a coupon being redeemed.
type productCoupon struct {
	productID, orderID     int64
	useQty, leftUseQty     int
	paidAmt, subsidyAmt    int
	venueIDs               []int64
	promotionID            *int64
	merchantName, perkName string
}

// storeFor picks and checks the store of a product redemption: a given
// store must be one of the coupon's venues (by name or id) when the coupon
// is limited to venues (403 wrong_store); without one it defaults to the
// only venue, or the merchant name.
func storeFor(ctx context.Context, q db.Querier, pc productCoupon, store string) (string, error) {
	store = strings.TrimSpace(store)
	if len(pc.venueIDs) == 0 {
		if store == "" {
			return pc.merchantName, nil
		}
		return store, nil
	}
	rows, err := q.Query(ctx, `SELECT id::text, venue_name FROM src.src_mer_loop_venue WHERE id = ANY($1) ORDER BY id`, pc.venueIDs)
	if err != nil {
		return "", err
	}
	type vn struct{ id, name string }
	vs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (vn, error) {
		var v vn
		return v, r.Scan(&v.id, &v.name)
	})
	if err != nil {
		return "", err
	}
	if store == "" {
		if len(vs) == 1 {
			return vs[0].name, nil
		}
		return pc.merchantName, nil
	}
	for _, v := range vs {
		if v.name == store || v.id == store {
			return v.name, nil
		}
	}
	return "", errWrongStore
}

var errWrongStore = httpx.Forbidden("wrong_store", "这张券不能在这家门店使用")

// LookupCoupon is POST /open/v1/coupons/lookup: the coupon behind a QR
// payload or code, without redeeming it; other merchants' coupons are 404.
func (s *Service) LookupCoupon(ctx context.Context, merchantID int64, in RedeemInput) (Coupon, error) {
	id, _, err := s.couponOf(ctx, in)
	if err != nil {
		return Coupon{}, err
	}
	c, err := loadCoupon(ctx, s.Pool, id)
	if err != nil {
		return c, err
	}
	if c.Merchant.ID != merchantID {
		return Coupon{}, httpx.NotFound("券")
	}
	return c, nil
}
