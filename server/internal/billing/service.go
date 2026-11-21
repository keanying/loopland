package billing

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Entitlement keys. guard_bonus and extra_energy exist only to be refused:
// 会员只给体验类权益，花钱买不到抢地优势.
var Entitlements = []struct {
	Key, Name string
	Locked    bool
}{
	{"map_styles", "手绘 / 3D 地图", false},
	{"advanced_stats", "高级运动数据", false},
	{"ai_coach_unlimited", "AI 教练不限次", false},
	{"exclusive_skins", "专属领地皮肤", false},
	{"hd_replay_export", "高清回放导出", false},
	{"crew_tools", "跑团管理工具", false},
	{"guard_bonus", "抢地守卫加成", true},
	{"extra_energy", "额外能量", true},
}

// Plan is a membership product.
type Plan struct {
	Code           string   `json:"code"`
	Name           string   `json:"name"`
	Period         string   `json:"period"`
	AutoRenew      bool     `json:"auto_renew"`
	PriceFen       int      `json:"price_fen"`
	FirstPriceFen  *int     `json:"first_price_fen"`
	RenewPriceFen  int      `json:"renew_price_fen"`
	Seats          int      `json:"seats"`
	Recommended    bool     `json:"recommended"`
	AppleProductID *string  `json:"apple_product_id"`
	Entitlements   []string `json:"entitlements"`
	OnSale         bool     `json:"on_sale"`
	Sort           int      `json:"sort"`
}

// AddPeriod extends t by the plan's period.
func (p Plan) AddPeriod(t time.Time) time.Time {
	switch p.Period {
	case "quarter":
		return t.AddDate(0, 3, 0)
	case "year":
		return t.AddDate(1, 0, 0)
	default:
		return t.AddDate(0, 1, 0)
	}
}

// UserRef is a compact user.
type UserRef struct {
	ID       int64  `json:"id"`
	Nickname string `json:"nickname"`
}

// Order is a purchase.
type Order struct {
	OrderNo         string     `json:"order_no"`
	UserID          int64      `json:"-"`
	User            *UserRef   `json:"user,omitempty"`
	PlanCode        string     `json:"plan_code"`
	PlanName        string     `json:"plan_name"`
	AmountFen       int        `json:"amount_fen"`
	Channel         string     `json:"channel"`
	Kind            string     `json:"kind"`
	Status          string     `json:"status"`
	TradeNo         *string    `json:"trade_no,omitempty"`
	AppAccountToken *uuid.UUID `json:"-"`
	CreatedAt       time.Time  `json:"created_at"`
	PaidAt          *time.Time `json:"paid_at"`
	RefundedAt      *time.Time `json:"refunded_at,omitempty"`
}

// Service is the billing domain.
type Service struct {
	Pool      *pgxpool.Pool
	Providers map[string]Provider
	Apple     *AppleStore
	Log       *slog.Logger
	Dev       bool
}

const planCols = `code, name, period_type, is_auto_renew, price_amt, first_price_amt, renew_price_amt, seats, is_recommended, apple_product_id, entitlements, is_on_sale, sort`

func scanPlan(r pgx.Row) (Plan, error) {
	var p Plan
	err := r.Scan(&p.Code, &p.Name, &p.Period, &p.AutoRenew, &p.PriceFen, &p.FirstPriceFen, &p.RenewPriceFen, &p.Seats, &p.Recommended,
		&p.AppleProductID, &p.Entitlements, &p.OnSale, &p.Sort)
	if p.Entitlements == nil {
		p.Entitlements = []string{}
	}
	return p, err
}

// Plans lists plans, optionally only those on sale.
func (s *Service) Plans(ctx context.Context, onSaleOnly bool) ([]Plan, error) {
	rows, err := s.Pool.Query(ctx, `SELECT `+planCols+` FROM src.src_ord_plan WHERE ($1 = false OR is_on_sale) ORDER BY sort, code`, onSaleOnly)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Plan, error) { return scanPlan(r) })
}

// Plan loads one plan.
func (s *Service) Plan(ctx context.Context, q db.Querier, code string) (Plan, error) {
	p, err := scanPlan(q.QueryRow(ctx, `SELECT `+planCols+` FROM src.src_ord_plan WHERE code=$1`, code))
	if db.IsNoRows(err) {
		return p, httpx.NotFound("套餐")
	}
	return p, err
}

const orderCols = `o.order_no, o.user_id, u.nickname, o.plan_code, o.plan_name, o.order_amt, o.channel, o.order_type, o.status, o.trade_no,
	o.app_account_token, o.create_time, o.pay_time, o.refund_time`

func scanOrder(r pgx.Row) (Order, error) {
	var o Order
	var nick string
	err := r.Scan(&o.OrderNo, &o.UserID, &nick, &o.PlanCode, &o.PlanName, &o.AmountFen, &o.Channel, &o.Kind, &o.Status, &o.TradeNo,
		&o.AppAccountToken, &o.CreatedAt, &o.PaidAt, &o.RefundedAt)
	o.User = &UserRef{ID: o.UserID, Nickname: nick}
	return o, err
}

// GetOrder loads an order (user=0 for admin).
func (s *Service) GetOrder(ctx context.Context, q db.Querier, no string, user int64) (Order, error) {
	o, err := scanOrder(q.QueryRow(ctx, `SELECT `+orderCols+` FROM src.src_ord_order o JOIN src.src_usr_user u ON u.id=o.user_id WHERE o.order_no=$1 AND ($2=0 OR o.user_id=$2)`, no, user))
	if db.IsNoRows(err) {
		return o, httpx.NotFound("订单")
	}
	return o, err
}

func newOrderNo() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(1_000_000))
	return fmt.Sprintf("LP%s%06d", time.Now().In(clock.Shanghai).Format("20060102150405"), n.Int64())
}

// CreateOrder starts a purchase.
func (s *Service) CreateOrder(ctx context.Context, user int64, planCode, channel, platform, ip string) (Order, map[string]any, error) {
	prov, ok := s.Providers[channel]
	if !ok || (channel == Mock && !s.Dev) {
		return Order{}, nil, httpx.BadRequest("channel_not_allowed", "不支持的支付方式")
	}
	if platform == "ios" && channel != AppleIAP && channel != Mock {
		return Order{}, nil, httpx.BadRequest("channel_not_allowed", "iOS 上请使用 App Store 支付")
	}
	var verified bool
	var adult *bool
	if err := s.Pool.QueryRow(ctx, `SELECT is_realname_verified, is_adult FROM src.src_usr_user WHERE id=$1`, user).Scan(&verified, &adult); err != nil {
		return Order{}, nil, err
	}
	if adult != nil && !*adult {
		return Order{}, nil, httpx.Forbidden("minor_blocked", "未成年用户不能购买会员")
	}
	if !verified {
		return Order{}, nil, httpx.Forbidden("realname_required", "购买会员前请先完成实名认证")
	}
	p, err := s.Plan(ctx, s.Pool, planCode)
	if err != nil {
		return Order{}, nil, err
	}
	if !p.OnSale {
		return Order{}, nil, httpx.BadRequest("plan_off_sale", "这个套餐已下架")
	}
	amount := p.PriceFen
	if p.FirstPriceFen != nil {
		var bought bool
		if err := s.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_ord_order WHERE user_id=$1 AND plan_code=$2 AND status IN ('paid','refunded','refund_requested'))`,
			user, p.Code).Scan(&bought); err != nil {
			return Order{}, nil, err
		}
		if !bought {
			amount = *p.FirstPriceFen
		}
	}
	o := Order{OrderNo: newOrderNo(), UserID: user, PlanCode: p.Code, PlanName: p.Name, AmountFen: amount, Channel: channel, Kind: "purchase", Status: "created", CreatedAt: time.Now()}
	if channel == AppleIAP {
		t := uuid.New()
		o.AppAccountToken = &t
	}
	if _, err := s.Pool.Exec(ctx, `INSERT INTO src.src_ord_order (order_no, user_id, plan_code, plan_name, order_amt, channel, app_account_token)
		VALUES ($1,$2,$3,$4,$5,$6,$7)`, o.OrderNo, user, p.Code, p.Name, amount, channel, o.AppAccountToken); err != nil {
		return Order{}, nil, err
	}
	params, err := prov.Create(ctx, o, p, ip)
	if err != nil {
		s.Log.Error("create payment", "channel", channel, "order", o.OrderNo, "err", err)
		_, _ = s.Pool.Exec(ctx, `UPDATE src.src_ord_order SET status='closed' WHERE order_no=$1`, o.OrderNo)
		return Order{}, nil, httpx.E(http.StatusBadGateway, "provider_error", "支付渠道暂时不可用，请稍后再试")
	}
	return o, params, nil
}

// MarkPaid records a verified payment and grants membership. It is
// idempotent: callbacks are delivered more than once.
func (s *Service) MarkPaid(ctx context.Context, p Paid, expiresAt *time.Time) error {
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error { return s.markPaidTx(ctx, tx, p, expiresAt) })
}

func (s *Service) markPaidTx(ctx context.Context, tx pgx.Tx, p Paid, expiresAt *time.Time) error {
	o, err := scanOrder(tx.QueryRow(ctx, `SELECT `+orderCols+` FROM src.src_ord_order o JOIN src.src_usr_user u ON u.id=o.user_id WHERE o.order_no=$1 FOR UPDATE OF o`, p.OrderNo))
	if db.IsNoRows(err) {
		return fmt.Errorf("notify for unknown order %s", p.OrderNo)
	}
	if err != nil {
		return err
	}
	if o.Status == "paid" || o.Status == "refunded" || o.Status == "refund_requested" {
		return nil
	}
	if p.AmountFen != o.AmountFen {
		return fmt.Errorf("order %s: paid %d fen, expected %d", o.OrderNo, p.AmountFen, o.AmountFen)
	}
	if p.PaidAt.IsZero() {
		p.PaidAt = time.Now()
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_ord_order SET status='paid', trade_no=$2, pay_time=$3 WHERE order_no=$1`, o.OrderNo, p.TradeNo, p.PaidAt); err != nil {
		return err
	}
	plan, err := s.Plan(ctx, tx, o.PlanCode)
	if err != nil {
		return err
	}
	return grant(ctx, tx, o.UserID, plan, o.Channel, expiresAt, nil)
}

// grant extends (or starts) a membership by one period of plan.
func grant(ctx context.Context, tx pgx.Tx, user int64, plan Plan, channel string, expiresAt *time.Time, appleOrig *string) error {
	now := time.Now()
	var cur time.Time
	err := tx.QueryRow(ctx, `SELECT expire_time FROM src.src_ord_membership WHERE user_id=$1 FOR UPDATE`, user).Scan(&cur)
	if err != nil && !db.IsNoRows(err) {
		return err
	}
	from := now
	if cur.After(now) {
		from = cur
	}
	exp := plan.AddPeriod(from)
	if expiresAt != nil {
		exp = *expiresAt
	}
	auto := plan.AutoRenew
	var next *time.Time
	if auto {
		next = &exp
	}
	_, err = tx.Exec(ctx, `INSERT INTO src.src_ord_membership (user_id, plan_code, channel, expire_time, is_auto_renew, next_charge_time, grace_end_time, apple_original_transaction_id)
		VALUES ($1,$2,$3,$4,$5,$6,NULL,$7)
		ON CONFLICT (user_id) DO UPDATE SET plan_code=EXCLUDED.plan_code, channel=EXCLUDED.channel, expire_time=EXCLUDED.expire_time,
			is_auto_renew=EXCLUDED.is_auto_renew, next_charge_time=EXCLUDED.next_charge_time, grace_end_time=NULL,
			apple_original_transaction_id=COALESCE(EXCLUDED.apple_original_transaction_id, src.src_ord_membership.apple_original_transaction_id), update_time=now()`,
		user, plan.Code, channel, exp, auto, next, appleOrig)
	if err != nil {
		return err
	}
	return inbox.Notify(ctx, tx, user, inbox.System, "会员已开通", fmt.Sprintf("「%s」已生效，有效期至 %s。", plan.Name, exp.In(clock.Shanghai).Format("2006-01-02")),
		map[string]any{"plan_code": plan.Code})
}

// Notify handles a WeChat or Alipay callback.
func (s *Service) Notify(w http.ResponseWriter, r *http.Request, channel string) {
	prov, ok := s.Providers[channel]
	if !ok {
		http.NotFound(w, r)
		return
	}
	paid, err := prov.ParseNotify(r)
	if err != nil {
		s.Log.Warn("payment notify rejected", "channel", channel, "err", err)
		http.Error(w, "invalid notify", http.StatusBadRequest)
		return
	}
	if paid != nil {
		if err := s.MarkPaid(r.Context(), *paid, nil); err != nil {
			s.Log.Error("payment notify", "channel", channel, "order", paid.OrderNo, "err", err)
			http.Error(w, "retry", http.StatusInternalServerError)
			return
		}
	}
	prov.Ack(w)
}

// AppleTransaction verifies a signed transaction from the device and grants
// the membership for the matching order.
func (s *Service) AppleTransaction(ctx context.Context, user int64, signed string) error {
	if s.Apple == nil {
		return httpx.BadRequest("channel_not_allowed", "App Store 支付未开通")
	}
	var tx AppleTransaction
	if err := s.Apple.Verifier.Decode(signed, &tx); err != nil {
		s.Log.Warn("apple transaction rejected", "err", err)
		return httpx.BadRequest("invalid_transaction", "交易校验失败")
	}
	if tx.BundleID != s.Apple.BundleID {
		return httpx.BadRequest("invalid_transaction", "交易不属于本应用")
	}
	if tx.RevocationDate > 0 {
		return httpx.BadRequest("invalid_transaction", "交易已被撤销")
	}
	return pgx.BeginFunc(ctx, s.Pool, func(dbtx pgx.Tx) error {
		return s.applyAppleTx(ctx, dbtx, user, tx)
	})
}

func (s *Service) applyAppleTx(ctx context.Context, dbtx pgx.Tx, user int64, tx AppleTransaction) error {
	// Already processed?
	var exists bool
	if err := dbtx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_ord_order WHERE channel='apple_iap' AND trade_no=$1)`, tx.TransactionID).Scan(&exists); err != nil {
		return err
	}
	if exists {
		return nil
	}
	var o Order
	var err error
	if tx.AppAccountToken != "" {
		o, err = scanOrder(dbtx.QueryRow(ctx, `SELECT `+orderCols+` FROM src.src_ord_order o JOIN src.src_usr_user u ON u.id=o.user_id
			WHERE o.app_account_token=$1 FOR UPDATE OF o`, tx.AppAccountToken))
	} else {
		err = pgx.ErrNoRows
	}
	var plan Plan
	if err == nil && o.Status == "created" {
		if user != 0 && o.UserID != user {
			return httpx.Forbidden("forbidden", "订单不属于当前用户")
		}
		plan, err = s.Plan(ctx, dbtx, o.PlanCode)
		if err != nil {
			return err
		}
		if plan.AppleProductID == nil || *plan.AppleProductID != tx.ProductID {
			return httpx.BadRequest("invalid_transaction", "商品与订单不一致")
		}
		if _, err := dbtx.Exec(ctx, `UPDATE src.src_ord_order SET status='paid', trade_no=$2, pay_time=$3 WHERE order_no=$1`,
			o.OrderNo, tx.TransactionID, time.UnixMilli(tx.PurchaseDate)); err != nil {
			return err
		}
	} else {
		// A renewal (or an order whose token we no longer have): find the
		// user through the original transaction and record a renewal order.
		var owner int64
		err := dbtx.QueryRow(ctx, `SELECT user_id FROM src.src_ord_membership WHERE apple_original_transaction_id=$1`, tx.OriginalTransactionID).Scan(&owner)
		if db.IsNoRows(err) {
			return httpx.NotFound("对应的订单")
		}
		if err != nil {
			return err
		}
		if err := dbtx.QueryRow(ctx, `SELECT `+planCols+` FROM src.src_ord_plan WHERE apple_product_id=$1`, tx.ProductID).Scan(
			&plan.Code, &plan.Name, &plan.Period, &plan.AutoRenew, &plan.PriceFen, &plan.FirstPriceFen, &plan.RenewPriceFen, &plan.Seats,
			&plan.Recommended, &plan.AppleProductID, &plan.Entitlements, &plan.OnSale, &plan.Sort); err != nil {
			return err
		}
		o = Order{OrderNo: newOrderNo(), UserID: owner}
		if _, err := dbtx.Exec(ctx, `INSERT INTO src.src_ord_order (order_no, user_id, plan_code, plan_name, order_amt, channel, order_type, status, trade_no, pay_time)
			VALUES ($1,$2,$3,$4,$5,'apple_iap','renewal','paid',$6,$7)`, o.OrderNo, owner, plan.Code, plan.Name, plan.RenewPriceFen,
			tx.TransactionID, time.UnixMilli(tx.PurchaseDate)); err != nil {
			return err
		}
	}
	var exp *time.Time
	if tx.ExpiresDate > 0 {
		t := time.UnixMilli(tx.ExpiresDate)
		exp = &t
	}
	orig := tx.OriginalTransactionID
	return grant(ctx, dbtx, o.UserID, plan, AppleIAP, exp, &orig)
}

// AppleNotification handles App Store Server Notifications V2.
func (s *Service) AppleNotification(ctx context.Context, signedPayload string) error {
	if s.Apple == nil {
		return errors.New("apple not configured")
	}
	var n AppleNotification
	if err := s.Apple.Verifier.Decode(signedPayload, &n); err != nil {
		return err
	}
	if n.Data.BundleID != s.Apple.BundleID {
		return fmt.Errorf("bundle mismatch %q", n.Data.BundleID)
	}
	var tx AppleTransaction
	if n.Data.SignedTransactionInfo != "" {
		if err := s.Apple.Verifier.Decode(n.Data.SignedTransactionInfo, &tx); err != nil {
			return err
		}
	}
	switch n.NotificationType {
	case "SUBSCRIBED", "DID_RENEW", "ONE_TIME_CHARGE":
		err := pgx.BeginFunc(ctx, s.Pool, func(dbtx pgx.Tx) error { return s.applyAppleTx(ctx, dbtx, 0, tx) })
		var he *httpx.Error
		if errors.As(err, &he) && he.Code == "not_found" {
			return nil // purchase whose order we never saw; the device will post it
		}
		return err
	case "DID_CHANGE_RENEWAL_STATUS":
		var ri AppleRenewal
		if err := s.Apple.Verifier.Decode(n.Data.SignedRenewalInfo, &ri); err != nil {
			return err
		}
		_, err := s.Pool.Exec(ctx, `UPDATE src.src_ord_membership SET is_auto_renew=$2, next_charge_time=CASE WHEN $2 THEN expire_time END, update_time=now()
			WHERE apple_original_transaction_id=$1`, ri.OriginalTransactionID, ri.AutoRenewStatus == 1)
		return err
	case "DID_FAIL_TO_RENEW":
		_, err := s.Pool.Exec(ctx, `UPDATE src.src_ord_membership SET grace_end_time=expire_time + interval '3 days', update_time=now()
			WHERE apple_original_transaction_id=$1`, tx.OriginalTransactionID)
		return err
	case "REFUND", "REVOKE":
		return pgx.BeginFunc(ctx, s.Pool, func(dbtx pgx.Tx) error {
			var no string
			err := dbtx.QueryRow(ctx, `UPDATE src.src_ord_order SET status='refunded', refund_time=now(), refund_reason='App Store 退款'
				WHERE channel='apple_iap' AND trade_no=$1 RETURNING order_no`, tx.TransactionID).Scan(&no)
			if db.IsNoRows(err) {
				return nil
			}
			if err != nil {
				return err
			}
			return revoke(ctx, dbtx, no)
		})
	}
	return nil
}

// revoke takes back the period an order granted.
func revoke(ctx context.Context, tx pgx.Tx, orderNo string) error {
	var user int64
	var period string
	if err := tx.QueryRow(ctx, `SELECT o.user_id, p.period_type FROM src.src_ord_order o JOIN src.src_ord_plan p ON p.code=o.plan_code WHERE o.order_no=$1`, orderNo).Scan(&user, &period); err != nil {
		return err
	}
	interval := map[string]string{"month": "1 month", "quarter": "3 months", "year": "1 year"}[period]
	_, err := tx.Exec(ctx, `UPDATE src.src_ord_membership SET expire_time = GREATEST(now(), expire_time - $2::interval),
		is_auto_renew = CASE WHEN expire_time - $2::interval <= now() THEN false ELSE is_auto_renew END,
		next_charge_time = CASE WHEN expire_time - $2::interval <= now() THEN NULL ELSE next_charge_time END, grace_end_time=NULL, update_time=now()
		WHERE user_id=$1`, user, interval)
	if err != nil {
		return err
	}
	return inbox.Notify(ctx, tx, user, inbox.System, "订单已退款", "你的会员订单已退款，对应的会员权益已收回。", map[string]any{"order_no": orderNo})
}

// Refund refunds through the original channel and revokes the benefits.
func (s *Service) Refund(ctx context.Context, orderNo, reason string) (Order, error) {
	o, err := s.GetOrder(ctx, s.Pool, orderNo, 0)
	if err != nil {
		return o, err
	}
	if o.Status != "paid" && o.Status != "refund_requested" {
		return o, httpx.Conflict("invalid_status", "只有已支付的订单可以退款")
	}
	if o.Channel == AppleIAP {
		return o, httpx.BadRequest("manage_in_app_store", "App Store 订单需由用户向 Apple 申请退款")
	}
	prov, ok := s.Providers[o.Channel]
	if !ok {
		return o, httpx.BadRequest("channel_not_allowed", "支付渠道未配置")
	}
	if err := prov.Refund(ctx, o, reason); err != nil {
		s.Log.Error("refund", "order", orderNo, "err", err)
		return o, httpx.E(http.StatusBadGateway, "provider_error", "退款请求失败：%v", err)
	}
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE src.src_ord_order SET status='refunded', refund_time=now(), refund_reason=$2 WHERE order_no=$1`, orderNo, reason); err != nil {
			return err
		}
		return revoke(ctx, tx, orderNo)
	})
	if err != nil {
		return o, err
	}
	return s.GetOrder(ctx, s.Pool, orderNo, 0)
}

// SetAutoRenew turns auto-renew on/off for WeChat/Alipay/mock memberships.
func (s *Service) SetAutoRenew(ctx context.Context, user int64, enabled bool) error {
	var channel, plan string
	err := s.Pool.QueryRow(ctx, `SELECT channel, plan_code FROM src.src_ord_membership WHERE user_id=$1`, user).Scan(&channel, &plan)
	if db.IsNoRows(err) {
		return httpx.NotFound("会员")
	}
	if err != nil {
		return err
	}
	if channel == AppleIAP {
		return httpx.Conflict("manage_in_app_store", "请在 iPhone「设置 > Apple ID > 订阅」中管理自动续费")
	}
	p, err := s.Plan(ctx, s.Pool, plan)
	if err != nil {
		return err
	}
	if enabled && !p.AutoRenew {
		return httpx.BadRequest("plan_not_renewable", "这个套餐不支持自动续费")
	}
	_, err = s.Pool.Exec(ctx, `UPDATE src.src_ord_membership SET is_auto_renew=$2, next_charge_time=CASE WHEN $2 THEN expire_time END, update_time=now() WHERE user_id=$1`, user, enabled)
	return err
}

// GiftDays extends a membership (admin 赠送 7 天会员).
func (s *Service) GiftDays(ctx context.Context, tx pgx.Tx, user int64, days int) error {
	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_ord_membership WHERE user_id=$1)`, user).Scan(&exists); err != nil {
		return err
	}
	if exists {
		_, err := tx.Exec(ctx, `UPDATE src.src_ord_membership SET expire_time=GREATEST(expire_time, now()) + make_interval(days => $2),
			next_charge_time=CASE WHEN is_auto_renew THEN GREATEST(expire_time, now()) + make_interval(days => $2) END, update_time=now() WHERE user_id=$1`, user, days)
		return err
	}
	_, err := tx.Exec(ctx, `INSERT INTO src.src_ord_membership (user_id, plan_code, channel, expire_time) VALUES ($1, 'month', 'gift', now() + make_interval(days => $2))`, user, days)
	return err
}

// ---------------------------------------------------------------- jobs

// RunRenewals charges due auto-renewing memberships (non-Apple). Channels
// that cannot charge without the user mark the renewal failed and keep
// benefits for a 3-day grace period.
func (s *Service) RunRenewals(ctx context.Context) error {
	rows, err := s.Pool.Query(ctx, `SELECT m.user_id FROM src.src_ord_membership m WHERE m.is_auto_renew AND m.channel IN ('wechat_app','alipay_app','mock')
		AND m.next_charge_time <= now() LIMIT 200`)
	if err != nil {
		return err
	}
	users, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	for _, u := range users {
		if err := s.renew(ctx, u); err != nil {
			s.Log.Error("renewal", "user", u, "err", err)
		}
	}
	return nil
}

func (s *Service) renew(ctx context.Context, user int64) error {
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var channel, planCode string
		var next *time.Time
		var exp time.Time
		err := tx.QueryRow(ctx, `SELECT channel, plan_code, next_charge_time, expire_time FROM src.src_ord_membership WHERE user_id=$1 FOR UPDATE`, user).
			Scan(&channel, &planCode, &next, &exp)
		if err != nil {
			return err
		}
		if next == nil || next.After(time.Now()) {
			return nil
		}
		plan, err := s.Plan(ctx, tx, planCode)
		if err != nil {
			return err
		}
		o := Order{OrderNo: newOrderNo(), UserID: user, PlanCode: plan.Code, PlanName: plan.Name, AmountFen: plan.RenewPriceFen, Channel: channel, Kind: "renewal"}
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_ord_order (order_no, user_id, plan_code, plan_name, order_amt, channel, order_type) VALUES ($1,$2,$3,$4,$5,$6,'renewal')`,
			o.OrderNo, user, plan.Code, plan.Name, o.AmountFen, channel); err != nil {
			return err
		}
		prov := s.Providers[channel]
		var trade string
		if prov != nil {
			trade, err = prov.Charge(ctx, o)
		} else {
			err = ErrUnsupported
		}
		if err != nil {
			if _, err := tx.Exec(ctx, `UPDATE src.src_ord_order SET status='renew_failed' WHERE order_no=$1`, o.OrderNo); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE src.src_ord_membership SET next_charge_time=NULL, is_auto_renew=false, grace_end_time=expire_time + interval '3 days', update_time=now() WHERE user_id=$1`, user); err != nil {
				return err
			}
			return inbox.Notify(ctx, tx, user, inbox.System, "自动续费失败",
				"会员自动续费没有成功，权益为你保留 3 天，请在「我的 > 会员」重新开通。", map[string]any{"order_no": o.OrderNo})
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_ord_order SET status='paid', trade_no=$2, pay_time=now() WHERE order_no=$1`, o.OrderNo, trade); err != nil {
			return err
		}
		return grant(ctx, tx, user, plan, channel, nil, nil)
	})
}

// RunReminders sends the 扣费前 5 天提醒 once per charge date.
func (s *Service) RunReminders(ctx context.Context) error {
	rows, err := s.Pool.Query(ctx, `UPDATE src.src_ord_membership SET reminded_charge_time=next_charge_time
		WHERE is_auto_renew AND channel <> 'apple_iap' AND next_charge_time BETWEEN now() AND now() + interval '5 days'
		  AND reminded_charge_time IS DISTINCT FROM next_charge_time
		RETURNING user_id, next_charge_time, (SELECT renew_price_amt FROM src.src_ord_plan WHERE code=plan_code)`)
	if err != nil {
		return err
	}
	type due struct {
		user  int64
		at    time.Time
		price int
	}
	ds, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (due, error) {
		var d due
		return d, r.Scan(&d.user, &d.at, &d.price)
	})
	if err != nil {
		return err
	}
	for _, d := range ds {
		if err := inbox.Notify(ctx, s.Pool, d.user, inbox.System, "自动续费提醒",
			fmt.Sprintf("你的会员将于 %s 自动续费 ¥%.2f，如不需要可在「我的 > 会员」关闭自动续费。", d.at.In(clock.Shanghai).Format("01-02"), float64(d.price)/100),
			map[string]any{}); err != nil {
			return err
		}
	}
	return nil
}

// CloseStale closes unpaid orders older than 2 hours.
func (s *Service) CloseStale(ctx context.Context) error {
	_, err := s.Pool.Exec(ctx, `UPDATE src.src_ord_order SET status='closed' WHERE status='created' AND create_time < now() - interval '2 hours'`)
	return err
}
