package product

import (
	"context"
	"crypto/rand"
	"fmt"
	"math"
	"math/big"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/billing"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/perks"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/webhook"
)

// OrderProduct is the product of an order (snapshot).
type OrderProduct struct {
	ID    int64   `json:"id"`
	Title string  `json:"title"`
	Type  string  `json:"type"`
	Image *string `json:"image"`
}

// PromotionRef is {id, title}.
type PromotionRef struct {
	ID    int64  `json:"id"`
	Title string `json:"title"`
}

// UserRef is a compact user.
type UserRef struct {
	ID       int64  `json:"id"`
	Nickname string `json:"nickname"`
}

// PayRef is the payment order of a product order.
type PayRef struct {
	OrderNo string `json:"order_no"`
	Channel string `json:"channel"`
}

// Order is ProductOrder.
type Order struct {
	ID           int64        `json:"id"`
	OrderNo      string       `json:"order_no"`
	Product      OrderProduct `json:"product"`
	Merchant     Ref          `json:"merchant"`
	Qty          int          `json:"qty"`
	UnitPriceAmt int          `json:"unit_price_amt"`
	AmountAmt    int          `json:"amount_amt"`
	RefundAmt    int          `json:"refund_amt"`
	// Refundable: 下单时商品是否支持退款（App 据此显示「退款」按钮）
	Refundable bool           `json:"refundable"`
	Promotion  *PromotionRef  `json:"promotion"`
	Status     string         `json:"status"`
	Coupons    []perks.Coupon `json:"coupons"`
	// Pay is the payment order (as on bookings; the dev mock payment
	// /v1/dev/orders/{no}/pay takes its order_no).
	Pay          *PayRef    `json:"pay"`
	PayExpiresAt time.Time  `json:"pay_expires_at"`
	PaidAt       *time.Time `json:"paid_at"`
	CreatedAt    time.Time  `json:"created_at"`
	User         *UserRef   `json:"user,omitempty"`

	userID     int64
	payOrderNo *string
}

const orderCols = `po.id, po.order_no, po.product_id, po.product_title, po.product_type, po.image_url, po.merchant_id, m.merchant_name, po.qty,
	po.unit_price_amt, po.amount_amt, po.refund_amt, po.promotion_id, pr.promotion_title, po.order_status, po.pay_expire_time, po.paid_time,
	po.create_time, po.user_id, u.nickname, po.pay_order_no, po.is_refundable, po.channel`

const orderFrom = ` FROM src.src_ord_loop_product_order po JOIN src.src_mer_loop_merchant m ON m.id=po.merchant_id
	JOIN src.src_usr_loop_user u ON u.id=po.user_id LEFT JOIN src.src_mkt_loop_promotion pr ON pr.id=po.promotion_id `

func (s *Service) queryOrders(ctx context.Context, q db.Querier, withUser bool, where string, args ...any) ([]Order, error) {
	rows, err := q.Query(ctx, `SELECT `+orderCols+orderFrom+` WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	os, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Order, error) {
		var o Order
		var promoID *int64
		var promoTitle *string
		var nick, channel string
		err := r.Scan(&o.ID, &o.OrderNo, &o.Product.ID, &o.Product.Title, &o.Product.Type, &o.Product.Image, &o.Merchant.ID, &o.Merchant.Name, &o.Qty,
			&o.UnitPriceAmt, &o.AmountAmt, &o.RefundAmt, &promoID, &promoTitle, &o.Status, &o.PayExpiresAt, &o.PaidAt,
			&o.CreatedAt, &o.userID, &nick, &o.payOrderNo, &o.Refundable, &channel)
		if o.payOrderNo != nil {
			o.Pay = &PayRef{OrderNo: *o.payOrderNo, Channel: channel}
		}
		if promoID != nil && promoTitle != nil {
			o.Promotion = &PromotionRef{ID: *promoID, Title: *promoTitle}
		}
		if withUser {
			o.User = &UserRef{ID: o.userID, Nickname: nick}
		}
		return o, err
	})
	if err != nil {
		return nil, err
	}
	for i := range os {
		if os[i].Coupons, err = perks.CouponsOfOrder(ctx, q, os[i].ID); err != nil {
			return nil, err
		}
	}
	if os == nil {
		os = []Order{}
	}
	return os, nil
}

// LoadOrder loads one order: user > 0 limits to the buyer, merchant to a
// merchant (others are 404); admin views include the user.
func (s *Service) LoadOrder(ctx context.Context, q db.Querier, user int64, merchant *int64, id int64) (Order, error) {
	os, err := s.queryOrders(ctx, q, user == 0, `po.id=$1 AND ($2 = 0 OR po.user_id=$2) AND ($3::bigint IS NULL OR po.merchant_id=$3)`, id, user, merchant)
	if err != nil {
		return Order{}, err
	}
	if len(os) == 0 {
		return Order{}, httpx.NotFound("订单")
	}
	return os[0], nil
}

// MyOrders is GET /v1/me/product-orders.
func (s *Service) MyOrders(ctx context.Context, user int64, status string) ([]Order, error) {
	return s.queryOrders(ctx, s.Pool, false, `po.user_id=$1 AND ($2 = '' OR po.order_status=$2) ORDER BY po.id DESC LIMIT 100`, user, status)
}

// OrderFilter filters the back-office and open API lists.
type OrderFilter struct {
	MerchantID, ProductID int64
	Status                string
	From, To              *time.Time
	// BeforeID pages by id (open API cursor).
	BeforeID int64
}

func (f OrderFilter) where() (string, []any) {
	var to *time.Time
	if f.To != nil {
		t := f.To.AddDate(0, 0, 1)
		to = &t
	}
	return `($1 = 0 OR po.merchant_id=$1) AND ($2 = 0 OR po.product_id=$2) AND ($3 = '' OR po.order_status=$3)
		AND ($4::timestamptz IS NULL OR po.create_time >= $4) AND ($5::timestamptz IS NULL OR po.create_time < $5) AND ($6 = 0 OR po.id < $6)`,
		[]any{f.MerchantID, f.ProductID, f.Status, f.From, to, f.BeforeID}
}

// AdminOrders is GET /admin/v1/product-orders.
func (s *Service) AdminOrders(ctx context.Context, f OrderFilter, p httpx.Page) ([]Order, int, error) {
	where, args := f.where()
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_ord_loop_product_order po WHERE `+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	os, err := s.queryOrders(ctx, s.Pool, true, where+` ORDER BY po.id DESC LIMIT $7 OFFSET $8`, append(args, p.Size, p.Offset())...)
	return os, total, err
}

// OrdersBefore lists a merchant's orders by id descending (open API).
func (s *Service) OrdersBefore(ctx context.Context, f OrderFilter, limit int) ([]Order, error) {
	where, args := f.where()
	return s.queryOrders(ctx, s.Pool, true, where+` ORDER BY po.id DESC LIMIT $7`, append(args, limit)...)
}

// ---------------------------------------------------------------- purchase

func newOrderNo() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(100_000))
	return fmt.Sprintf("PO%s%05d", time.Now().In(clock.Shanghai).Format("20060102150405"), n.Int64())
}

// channels the app may send: the short names of the contract and the
// booking ones.
var channels = map[string]string{"wechat": billing.WeChatApp, "alipay": billing.AlipayApp, "mock": billing.Mock,
	billing.WeChatApp: billing.WeChatApp, billing.AlipayApp: billing.AlipayApp}

// OrderInput is POST /v1/products/{id}/orders.
type OrderInput struct {
	Qty     int    `json:"qty"`
	Channel string `json:"channel"`
}

var (
	errSoldOut   = httpx.Conflict("sold_out", "库存不足")
	errNotOnSale = httpx.Conflict("not_on_sale", "这个商品已下架")
)

// CreateOrder buys qty units at the promotion price when one applies:
// stock (and promotion stock) are locked until payment or expiry.
func (s *Service) CreateOrder(ctx context.Context, user, productID int64, in OrderInput, ip string) (Order, map[string]any, error) {
	if in.Qty < 1 || in.Qty > 10 {
		return Order{}, nil, httpx.BadRequest("invalid_request", "一次可买 1–10 件")
	}
	channel, ok := channels[in.Channel]
	if !ok {
		return Order{}, nil, httpx.BadRequest("channel_not_allowed", "请选择微信或支付宝支付")
	}
	if err := s.Billing.CheckBizChannel(channel); err != nil {
		return Order{}, nil, err
	}
	timeout := s.Config.For(user).Booking.PayTimeoutMin
	var id int64
	var bo billing.Order
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT true FROM src.src_mer_loop_product WHERE id=$1 FOR UPDATE`, productID).Scan(&exists); err != nil {
			if db.IsNoRows(err) {
				return httpx.NotFound("商品")
			}
			return err
		}
		ps, err := s.query(ctx, tx, `p.id=$1`, productID)
		if err != nil {
			return err
		}
		p := ps[0]
		if !p.sellable() {
			if p.archived {
				return httpx.NotFound("商品")
			}
			return errNotOnSale
		}
		if p.validUntil != nil && p.validUntil.Before(clock.Today()) {
			return errNotOnSale
		}
		if p.PerUserLimitQty > 0 {
			n, err := boughtQty(ctx, tx, user, productID, `'pending','paid','completed','refunding'`)
			if err != nil {
				return err
			}
			if n+in.Qty > p.PerUserLimitQty {
				return httpx.Conflict("limit_reached", fmt.Sprintf("每人限购 %d 件", p.PerUserLimitQty))
			}
		}
		if p.StockQty != nil && *p.StockQty < in.Qty {
			return errSoldOut
		}
		unit, subsidy := p.PriceAmt, 0
		var promoID, entryID *int64
		var promoPrice *int
		if pp := p.Promotion; pp != nil {
			var stock *int
			var sold int
			if err := tx.QueryRow(ctx, `SELECT promo_stock_qty, promo_sold_qty FROM src.src_mkt_loop_promotion_entry WHERE id=$1 FOR UPDATE`, pp.entryID).
				Scan(&stock, &sold); err != nil {
				return err
			}
			if stock != nil && sold+in.Qty > *stock {
				return errSoldOut
			}
			if _, err := tx.Exec(ctx, `UPDATE src.src_mkt_loop_promotion_entry SET promo_sold_qty=promo_sold_qty+$2, update_time=now() WHERE id=$1`,
				pp.entryID, in.Qty); err != nil {
				return err
			}
			unit, subsidy = pp.PromoPriceAmt, pp.subsidyAmt
			promoID, entryID, promoPrice = &pp.ID, &pp.entryID, &pp.PromoPriceAmt
		}
		if p.StockQty != nil {
			if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET stock_qty=stock_qty-$2 WHERE id=$1`, productID, in.Qty); err != nil {
				return err
			}
		}
		var image *string
		if len(p.Images) > 0 {
			image = &p.Images[0]
		}
		if err := tx.QueryRow(ctx, `INSERT INTO src.src_ord_loop_product_order (order_no, user_id, product_id, merchant_id, product_type, product_title, image_url,
				qty, unit_price_amt, amount_amt, promotion_id, promotion_entry_id, promo_price_amt, platform_subsidy_amt, use_qty, valid_days,
				valid_until_date, is_refundable, venue_ids, rules, subtitle, channel, pay_expire_time)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22, now() + make_interval(mins => $23)) RETURNING id`,
			newOrderNo(), user, productID, p.Merchant.ID, p.Type, p.Title, image, in.Qty, unit, unit*in.Qty, promoID, entryID, promoPrice, subsidy,
			p.UseQty, p.ValidDays, nullDate(p.validUntil), p.Refundable, p.VenueIDs, p.Rules, p.Subtitle, channel, timeout).Scan(&id); err != nil {
			return err
		}
		bo, err = s.Billing.NewBizOrder(ctx, tx, billing.BizOrder{UserID: user, BizType: billing.BizProduct, BizID: id,
			Title: "商品·" + p.Title, AmountFen: unit * in.Qty, Channel: channel})
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE src.src_ord_loop_product_order SET pay_order_no=$2 WHERE id=$1`, id, bo.OrderNo)
		return err
	})
	if err != nil {
		return Order{}, nil, err
	}
	params, err := s.Billing.PayParams(ctx, bo, ip)
	if err != nil {
		_ = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error { return s.cancelTx(ctx, tx, id) })
		return Order{}, nil, err
	}
	o, err := s.LoadOrder(ctx, s.Pool, user, nil, id)
	return o, params, err
}

// lockOrder locks the payment order before the product order (the order
// the payment callback takes them in) and returns the product order's
// status and payment order number.
func lockOrder(ctx context.Context, tx pgx.Tx, user, id int64) (status string, payNo *string, err error) {
	err = tx.QueryRow(ctx, `SELECT pay_order_no FROM src.src_ord_loop_product_order WHERE id=$1 AND ($2 = 0 OR user_id=$2)`, id, user).Scan(&payNo)
	if db.IsNoRows(err) {
		return "", nil, httpx.NotFound("订单")
	}
	if err != nil {
		return
	}
	if payNo != nil {
		if _, err = tx.Exec(ctx, `SELECT 1 FROM src.src_ord_loop_order WHERE order_no=$1 FOR UPDATE`, *payNo); err != nil {
			return
		}
	}
	err = tx.QueryRow(ctx, `SELECT order_status FROM src.src_ord_loop_product_order WHERE id=$1 FOR UPDATE`, id).Scan(&status)
	return
}

// cancelTx cancels a pending order (after lockOrder) and releases its
// stock and promotion stock.
func (s *Service) cancelTx(ctx context.Context, tx pgx.Tx, id int64) error {
	var product int64
	var qty int
	var payNo *string
	var entryID *int64
	err := tx.QueryRow(ctx, `UPDATE src.src_ord_loop_product_order SET order_status='cancelled', cancel_time=now(), update_time=now()
		WHERE id=$1 AND order_status='pending' RETURNING product_id, qty, promotion_entry_id, pay_order_no`, id).Scan(&product, &qty, &entryID, &payNo)
	if db.IsNoRows(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET stock_qty=stock_qty+$2 WHERE id=$1 AND stock_qty IS NOT NULL`, product, qty); err != nil {
		return err
	}
	if entryID != nil {
		if _, err := tx.Exec(ctx, `UPDATE src.src_mkt_loop_promotion_entry SET promo_sold_qty=GREATEST(promo_sold_qty-$2, 0), update_time=now() WHERE id=$1`,
			*entryID, qty); err != nil {
			return err
		}
	}
	if payNo != nil {
		return billing.CloseUnpaid(ctx, tx, *payNo)
	}
	return nil
}

// Cancel is POST /v1/product-orders/{id}/cancel (unpaid orders only).
func (s *Service) Cancel(ctx context.Context, user, id int64) (Order, error) {
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		status, _, err := lockOrder(ctx, tx, user, id)
		if err != nil {
			return err
		}
		if status != "pending" {
			return httpx.Conflict("invalid_status", "只有待支付的订单可以取消")
		}
		return s.cancelTx(ctx, tx, id)
	})
	if err != nil {
		return Order{}, err
	}
	return s.LoadOrder(ctx, s.Pool, user, nil, id)
}

// Repay is POST /v1/product-orders/{id}/pay: the payment parameters again
// for an order still waiting for payment (same order and expiry).
func (s *Service) Repay(ctx context.Context, user, id int64, ip string) (Order, map[string]any, error) {
	o, err := s.LoadOrder(ctx, s.Pool, user, nil, id)
	if err != nil {
		return Order{}, nil, err
	}
	if o.Status != "pending" || o.payOrderNo == nil || !o.PayExpiresAt.After(time.Now()) {
		return Order{}, nil, httpx.Conflict("invalid_status", "这个订单不在待支付状态")
	}
	bo, err := s.Billing.GetOrder(ctx, s.Pool, *o.payOrderNo, user)
	if err != nil {
		return Order{}, nil, err
	}
	if bo.Status != "created" {
		return Order{}, nil, httpx.Conflict("invalid_status", "这个订单已经关闭，请重新下单")
	}
	params, err := s.Billing.PayParams(ctx, bo, ip)
	if err != nil {
		_ = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error { return s.cancelTx(ctx, tx, id) })
		return Order{}, nil, err
	}
	return o, params, nil
}

// ExpireOrders cancels unpaid orders past their payment deadline.
func (s *Service) ExpireOrders(ctx context.Context) error {
	rows, err := s.Pool.Query(ctx, `SELECT id FROM src.src_ord_loop_product_order WHERE order_status='pending' AND pay_expire_time <= now() ORDER BY id LIMIT 200`)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	for _, id := range ids {
		err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
			status, _, err := lockOrder(ctx, tx, 0, id)
			if err != nil || status != "pending" {
				return err
			}
			return s.cancelTx(ctx, tx, id)
		})
		if err != nil {
			return err
		}
	}
	return nil
}

// ---------------------------------------------------------------- payment

// Fulfiller is the billing fulfiller of biz_type product.
func (s *Service) Fulfiller() billing.Fulfiller { return fulfiller{s} }

type fulfiller struct{ s *Service }

var _ billing.RefundGuard = fulfiller{}

// expireOf is when the coupons of an order paid at t expire.
func expireOf(t time.Time, days *int, until *time.Time) time.Time {
	if until != nil {
		d := time.Date(until.Year(), until.Month(), until.Day(), 0, 0, 0, 0, clock.Shanghai)
		return d.AddDate(0, 0, 1).Add(-time.Second)
	}
	n := 30
	if days != nil {
		n = *days
	}
	return t.AddDate(0, 0, n)
}

// Paid issues one coupon per unit; an order cancelled before the money
// arrived is refunded in full.
func (f fulfiller) Paid(ctx context.Context, tx pgx.Tx, o billing.Order) (bool, error) {
	s := f.s
	var id, product, merchant int64
	var qty, unit, subsidy, useQty int
	var title, subtitle, rules, typ string
	var days *int
	var until *time.Time
	var refundable bool
	var venues []int64
	err := tx.QueryRow(ctx, `UPDATE src.src_ord_loop_product_order SET order_status='paid', paid_time=now(), update_time=now()
		WHERE pay_order_no=$1 AND order_status='pending'
		RETURNING id, product_id, merchant_id, qty, unit_price_amt, platform_subsidy_amt, use_qty, product_title, subtitle, rules, product_type,
			valid_days, valid_until_date, is_refundable, venue_ids`, o.OrderNo).
		Scan(&id, &product, &merchant, &qty, &unit, &subsidy, &useQty, &title, &subtitle, &rules, &typ, &days, &until, &refundable, &venues)
	if db.IsNoRows(err) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET sold_qty=sold_qty+$2 WHERE id=$1`, product, qty); err != nil {
		return false, err
	}
	var original *int
	if err := tx.QueryRow(ctx, `SELECT original_amt FROM src.src_mer_loop_product WHERE id=$1`, product).Scan(&original); err != nil {
		return false, err
	}
	expire := expireOf(time.Now(), days, until)
	perk := perks.Perk{Title: title, Description: subtitle, ValueText: valueText(typ, unit, original, useQty), Rules: rules,
		ValidDays: max(1, int(math.Ceil(time.Until(expire).Hours()/24)))}
	if err := perks.IssueProductCoupons(ctx, tx, perks.ProductCoupons{OrderID: id, ProductID: product, MerchantID: merchant, UserID: o.UserID, Qty: qty,
		Name: title, Perk: perk, UseQty: useQty, PaidAmt: unit, SubsidyAmt: subsidy, Refundable: refundable, VenueIDs: venues, ExpireTime: expire}); err != nil {
		return false, err
	}
	ord, err := s.LoadOrder(ctx, tx, 0, nil, id)
	if err != nil {
		return false, err
	}
	if err := webhook.Emit(ctx, tx, merchant, webhook.ProductOrderPaid, ord); err != nil {
		return false, err
	}
	return false, inbox.Notify(ctx, tx, o.UserID, inbox.System, "购买成功",
		fmt.Sprintf("「%s」×%d 已放入卡券包，到店出示券码即可使用。", title, qty), map[string]any{"type": "product_order_paid", "product_order_id": id})
}

// valueText is the coupon's price text (价格文案).
func valueText(typ string, unit int, original *int, uses int) string {
	yuan := func(f int) string {
		if f%100 == 0 {
			return fmt.Sprintf("¥%d", f/100)
		}
		return strings.TrimRight(strings.TrimRight(fmt.Sprintf("¥%.2f", float64(f)/100), "0"), ".")
	}
	switch {
	case typ == "voucher" && original != nil:
		return yuan(*original) + " 代金券"
	case typ == "pass":
		return fmt.Sprintf("%s · %d 次", yuan(unit), uses)
	}
	return yuan(unit)
}

// CanRefund implements billing.RefundGuard: whole-order refunds through the
// generic order refund are only for orders that were cancelled before the
// money arrived; paid orders refund their unused coupons instead.
func (f fulfiller) CanRefund(ctx context.Context, q db.Querier, o billing.Order) error {
	var status string
	err := q.QueryRow(ctx, `SELECT order_status FROM src.src_ord_loop_product_order WHERE pay_order_no=$1`, o.OrderNo).Scan(&status)
	if db.IsNoRows(err) || (err == nil && status == "cancelled") {
		return nil
	}
	if err != nil {
		return err
	}
	return httpx.Conflict("use_product_refund", "商品订单请在「商品订单」里退款（只退未使用的券）")
}

// Refunded runs after a whole-order refund (CanRefund allowed it): nothing
// was issued, so nothing changes.
func (f fulfiller) Refunded(context.Context, pgx.Tx, billing.Order, string) error { return nil }

// ---------------------------------------------------------------- refunds

// Refund types.
const (
	RefundUser   = "user"
	RefundAdmin  = "admin"
	RefundExpire = "auto_expire"
)

func newRefundNo() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(100_000))
	return fmt.Sprintf("PR%s%05d", time.Now().In(clock.Shanghai).Format("20060102150405"), n.Int64())
}

// refundSpec is one refund request.
type refundSpec struct {
	user              int64
	typ, reason       string
	adminID           int64
	requireRefundable bool
	expiredOnly       bool
}

// couponRefund is what a coupon gives back: its paid price, or for a used
// pass what its remaining uses are worth (每次核销按 实付 ÷ 次数 结算).
func couponRefund(paid, uses, left int) int {
	if left >= uses {
		return paid
	}
	per := int(math.Round(float64(paid) / float64(uses)))
	return max(0, paid-per*(uses-left))
}

// refund refunds every unused coupon of the order: the coupons are marked
// refunded and the refund goes to the channel right after (retried by
// RetryRefunds while the channel fails).
func (s *Service) refund(ctx context.Context, id int64, sp refundSpec) (Order, error) {
	var refundID int64
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		status, payNo, err := lockOrder(ctx, tx, sp.user, id)
		if err != nil {
			return err
		}
		var refundable bool
		if err := tx.QueryRow(ctx, `SELECT is_refundable FROM src.src_ord_loop_product_order WHERE id=$1`, id).Scan(&refundable); err != nil {
			return err
		}
		if sp.requireRefundable && !refundable {
			return httpx.Conflict("not_refundable", "这个商品不支持退款")
		}
		if status == "pending" || status == "cancelled" || payNo == nil {
			return httpx.Conflict("nothing_to_refund", "没有可退的券")
		}
		rows, err := tx.Query(ctx, `SELECT id, use_qty, left_use_qty, paid_amt FROM src.src_mkt_loop_coupon
			WHERE product_order_id=$1 AND coupon_status='unused' AND left_use_qty > 0 AND (NOT $2 OR expire_time <= now()) ORDER BY id FOR UPDATE`, id, sp.expiredOnly)
		if err != nil {
			return err
		}
		type cp struct{ id, uses, left, paid int64 }
		cs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (cp, error) {
			var c cp
			return c, r.Scan(&c.id, &c.uses, &c.left, &c.paid)
		})
		if err != nil {
			return err
		}
		amount := 0
		ids := make([]int64, 0, len(cs))
		for _, c := range cs {
			amount += couponRefund(int(c.paid), int(c.uses), int(c.left))
			ids = append(ids, c.id)
		}
		if len(cs) == 0 || amount <= 0 {
			return httpx.Conflict("nothing_to_refund", "没有可退的券")
		}
		var admin any
		if sp.adminID != 0 {
			admin = sp.adminID
		}
		if err := tx.QueryRow(ctx, `INSERT INTO src.src_ord_loop_product_refund (refund_no, product_order_id, pay_order_no, refund_amt, coupon_qty, refund_type,
				refund_reason, admin_id) VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id`,
			newRefundNo(), id, *payNo, amount, len(cs), sp.typ, sp.reason, admin).Scan(&refundID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_mkt_loop_coupon SET coupon_status='refunded', refund_id=$2, refund_time=now(), update_time=now()
			WHERE id = ANY($1)`, ids, refundID); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE src.src_ord_loop_product_order SET refund_amt=refund_amt+$2, order_status='refunding', update_time=now() WHERE id=$1`,
			id, amount)
		return err
	})
	if err != nil {
		return Order{}, err
	}
	if err := s.completeRefund(ctx, refundID); err != nil {
		s.Log.Error("product refund", "refund", refundID, "err", err) // stays refunding; RetryRefunds retries
	}
	return s.LoadOrder(ctx, s.Pool, sp.user, nil, id)
}

// completeRefund sends a pending refund to the channel and, once it went
// through, records it, closes a fully refunded payment order and tells the
// user and the merchant's systems.
func (s *Service) completeRefund(ctx context.Context, refundID int64) error {
	var no, payNo, reason string
	var amt int
	var status string
	if err := s.Pool.QueryRow(ctx, `SELECT refund_no, pay_order_no, refund_amt, refund_reason, refund_status FROM src.src_ord_loop_product_refund WHERE id=$1`,
		refundID).Scan(&no, &payNo, &amt, &reason, &status); err != nil {
		return err
	}
	if status != "pending" {
		return nil
	}
	if reason == "" {
		reason = "商品订单退款"
	}
	if err := s.Billing.RefundPart(ctx, payNo, no, amt, reason); err != nil {
		_, _ = s.Pool.Exec(ctx, `UPDATE src.src_ord_loop_product_refund SET retry_qty=retry_qty+1, update_time=now() WHERE id=$1`, refundID)
		return err
	}
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var orderID, user, merchant int64
		var refunded, total int
		var title string
		err := tx.QueryRow(ctx, `UPDATE src.src_ord_loop_product_refund r SET refund_status='succeeded', success_time=now(), update_time=now()
			FROM src.src_ord_loop_product_order po WHERE po.id=r.product_order_id AND r.id=$1 AND r.refund_status='pending'
			RETURNING po.id, po.user_id, po.merchant_id, po.refund_amt, po.amount_amt, po.product_title`, refundID).
			Scan(&orderID, &user, &merchant, &refunded, &total, &title)
		if db.IsNoRows(err) {
			return nil
		}
		if err != nil {
			return err
		}
		if refunded >= total {
			if err := billing.MarkRefunded(ctx, tx, payNo, reason); err != nil {
				return err
			}
		}
		if err := perks.SyncProductOrders(ctx, tx, orderID); err != nil {
			return err
		}
		ord, err := s.LoadOrder(ctx, tx, 0, nil, orderID)
		if err != nil {
			return err
		}
		if err := webhook.Emit(ctx, tx, merchant, webhook.ProductOrderRefunded, ord); err != nil {
			return err
		}
		return inbox.Notify(ctx, tx, user, inbox.System, "商品已退款",
			fmt.Sprintf("「%s」未使用的券已退款，¥%.2f 已原路退回（%s）。", title, float64(amt)/100, reason),
			map[string]any{"type": "product_order_refunded", "product_order_id": orderID})
	})
}

// UserRefund is POST /v1/product-orders/{id}/refund.
func (s *Service) UserRefund(ctx context.Context, user, id int64) (Order, error) {
	return s.refund(ctx, id, refundSpec{user: user, typ: RefundUser, reason: "用户申请退款", requireRefundable: true})
}

// AdminRefund is POST /admin/v1/product-orders/{id}/refund (also for
// products that are not refundable).
func (s *Service) AdminRefund(ctx context.Context, adminID, id int64, reason string) (Order, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		reason = "客服退款"
	}
	return s.refund(ctx, id, refundSpec{typ: RefundAdmin, reason: reason, adminID: adminID})
}

// AutoRefundExpired refunds expired unused coupons of refundable orders
// (每天 02:00, DailyAutoRefund).
func (s *Service) AutoRefundExpired(ctx context.Context) error {
	rows, err := s.Pool.Query(ctx, `SELECT DISTINCT product_order_id FROM src.src_mkt_loop_coupon
		WHERE source_type='product' AND coupon_status='unused' AND is_refundable AND expire_time <= now() LIMIT 500`)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	for _, id := range ids {
		if _, err := s.refund(ctx, id, refundSpec{typ: RefundExpire, reason: "券过期未使用，自动退款", expiredOnly: true}); err != nil {
			if he, ok := err.(*httpx.Error); ok && he.Code == "nothing_to_refund" {
				continue
			}
			s.Log.Error("auto refund", "product_order", id, "err", err)
		}
	}
	return nil
}

// DailyAutoRefund runs AutoRefundExpired once a day from 02:00 (Asia/Shanghai).
func (s *Service) DailyAutoRefund(ctx context.Context, now time.Time) error {
	today := clock.Day(now)
	if now.Before(today.Add(2 * time.Hour)) {
		return nil
	}
	tag, err := s.Pool.Exec(ctx, `INSERT INTO src.src_sys_loop_setting (setting_key, setting_value) VALUES ('product_auto_refund_day', to_jsonb($1::text))
		ON CONFLICT (setting_key) DO UPDATE SET setting_value=EXCLUDED.setting_value, update_time=now() WHERE src_sys_loop_setting.setting_value <> to_jsonb($1::text)`,
		today.Format(time.DateOnly))
	if err != nil || tag.RowsAffected() == 0 {
		return err
	}
	return s.AutoRefundExpired(ctx)
}

// RetryRefunds retries refunds the channel has not accepted yet.
func (s *Service) RetryRefunds(ctx context.Context) error {
	rows, err := s.Pool.Query(ctx, `SELECT id FROM src.src_ord_loop_product_refund WHERE refund_status='pending' AND update_time < now() - interval '1 minute'
		ORDER BY id LIMIT 100`)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	for _, id := range ids {
		if err := s.completeRefund(ctx, id); err != nil {
			s.Log.Error("retry product refund", "refund", id, "err", err)
		}
	}
	return nil
}

// Jobs are the periodic jobs of the module.
func (s *Service) Jobs() map[string]func(context.Context) error {
	return map[string]func(context.Context) error{
		"product_order_expire": s.ExpireOrders,
		"product_order_sync":   func(ctx context.Context) error { return perks.SyncProductOrders(ctx, s.Pool, 0) },
		"product_auto_refund":  func(ctx context.Context) error { return s.DailyAutoRefund(ctx, time.Now()) },
		"product_refund_retry": s.RetryRefunds,
	}
}
