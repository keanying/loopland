package billing

import (
	"context"
	"fmt"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Business types of an order (src.src_ord_loop_order.biz_type). Membership
// orders go through the V1 path (plans, grants, renewals); the others are
// delivered by the Fulfiller registered for their type
// (docs/api/v2-4-本地生活与商户.md «支付实现»).
const (
	BizMembership = "membership"
	BizBooking    = "booking"
	BizRaceFee    = "race_fee"
	BizProduct    = "product"
)

// RefundGuard is implemented by fulfillers whose orders may only be
// refunded in full in some states (商品订单 refund unused coupons through
// their own partial refunds instead).
type RefundGuard interface {
	CanRefund(ctx context.Context, q db.Querier, o Order) error
}

// PartialRefunder is a channel that can refund part of an order. Each
// refund has its own refundNo (the channel's out_refund_no) so it can be
// retried safely.
type PartialRefunder interface {
	RefundPart(ctx context.Context, o Order, refundNo string, amountFen int, reason string) error
}

// RefundPart refunds amountFen of a paid non-membership order through its
// channel. It does not change the order: the caller records the refund and
// calls MarkRefunded once everything was refunded.
func (s *Service) RefundPart(ctx context.Context, orderNo, refundNo string, amountFen int, reason string) error {
	o, err := s.GetOrder(ctx, s.Pool, orderNo, 0)
	if err != nil {
		return err
	}
	if o.Status != "paid" || o.BizType == BizMembership {
		return httpx.Conflict("invalid_status", "只有已支付的订单可以退款")
	}
	if amountFen <= 0 || amountFen > o.AmountFen {
		return fmt.Errorf("refund %d of order %s (%d)", amountFen, orderNo, o.AmountFen)
	}
	prov, ok := s.provider(o.Channel)
	if !ok {
		return httpx.BadRequest("channel_not_allowed", "支付渠道未配置")
	}
	if pr, ok := prov.(PartialRefunder); ok {
		err = pr.RefundPart(ctx, o, refundNo, amountFen, reason)
	} else if amountFen == o.AmountFen {
		err = prov.Refund(ctx, o, reason)
	} else {
		return httpx.BadRequest("channel_not_allowed", "这个支付方式不支持部分退款")
	}
	if err != nil {
		s.Log.Error("partial refund", "order", orderNo, "refund", refundNo, "err", err)
		return httpx.E(http.StatusBadGateway, "provider_error", "退款请求失败：%v", err)
	}
	return nil
}

// MarkRefunded closes a fully refunded non-membership order inside the
// caller's transaction (after its partial refunds succeeded).
func MarkRefunded(ctx context.Context, tx pgx.Tx, orderNo, reason string) error {
	_, err := tx.Exec(ctx, `UPDATE src.src_ord_loop_order SET status='refunded', refund_time=now(), refund_reason=$2
		WHERE order_no=$1 AND status IN ('paid','refund_requested') AND biz_type <> 'membership'`, orderNo, reason)
	return err
}

// Fulfiller delivers what a non-membership order bought.
type Fulfiller interface {
	// Paid runs inside the payment transaction, after the order is marked
	// paid. refund=true means the thing paid for is gone (the booking
	// expired or the race was cancelled before the money arrived): the order
	// is then refunded right after commit.
	Paid(ctx context.Context, tx pgx.Tx, o Order) (refund bool, err error)
	// Refunded runs inside the refund transaction, after the order is marked
	// refunded.
	Refunded(ctx context.Context, tx pgx.Tx, o Order, reason string) error
}

// Register sets the fulfiller of a business type. Call it while wiring,
// before serving requests.
func (s *Service) Register(bizType string, f Fulfiller) {
	if s.fulfillers == nil {
		s.fulfillers = map[string]Fulfiller{}
	}
	s.fulfillers[bizType] = f
}

func (s *Service) fulfiller(bizType string) (Fulfiller, error) {
	f, ok := s.fulfillers[bizType]
	if !ok {
		return nil, fmt.Errorf("no fulfiller for biz_type %q", bizType)
	}
	return f, nil
}

func (s *Service) fulfilPaid(ctx context.Context, tx pgx.Tx, o Order) (bool, error) {
	f, err := s.fulfiller(o.BizType)
	if err != nil {
		return false, err
	}
	refund, err := f.Paid(ctx, tx, o)
	if err != nil || !refund {
		return false, err
	}
	_, err = tx.Exec(ctx, `UPDATE src.src_ord_loop_order SET status='refund_requested', refund_reason=$2 WHERE order_no=$1`, o.OrderNo, lateReason)
	return true, err
}

func (s *Service) fulfilRefunded(ctx context.Context, tx pgx.Tx, o Order, reason string) error {
	f, err := s.fulfiller(o.BizType)
	if err != nil {
		return err
	}
	return f.Refunded(ctx, tx, o, reason)
}

const lateReason = "支付时订单已失效，自动原路退款"

// refundLate refunds an order paid after it lapsed; RetryRefunds picks it
// up again when the channel fails now.
func (s *Service) refundLate(ctx context.Context, orderNo string) {
	if _, err := s.Refund(ctx, orderNo, lateReason); err != nil {
		s.Log.Error("refund late payment", "order", orderNo, "err", err)
	}
}

// BizOrder is a non-membership purchase.
type BizOrder struct {
	UserID  int64
	BizType string
	BizID   int64
	// Title is stored as plan_name and shown on the payment sheet.
	Title     string
	AmountFen int
	Channel   string
}

// CheckBizChannel: bookings and race fees are offline services, paid with
// WeChat Pay or Alipay on every platform, iOS included (mock in dev).
func (s *Service) CheckBizChannel(channel string) error {
	switch channel {
	case WeChatApp, AlipayApp:
	case Mock:
		if !s.Dev {
			return httpx.BadRequest("channel_not_allowed", "不支持的支付方式")
		}
	default:
		return httpx.BadRequest("channel_not_allowed", "请选择微信或支付宝支付")
	}
	if _, ok := s.provider(channel); !ok {
		return httpx.BadRequest("channel_not_allowed", "这个支付方式暂未开通")
	}
	return nil
}

// NewBizOrder inserts an unpaid order inside the caller's transaction (the
// caller has checked the channel with CheckBizChannel).
func (s *Service) NewBizOrder(ctx context.Context, tx pgx.Tx, b BizOrder) (Order, error) {
	if b.BizType == BizMembership || b.AmountFen <= 0 {
		return Order{}, fmt.Errorf("invalid biz order %+v", b)
	}
	id := b.BizID
	o := Order{OrderNo: newOrderNo(), UserID: b.UserID, PlanName: b.Title, AmountFen: b.AmountFen, Channel: b.Channel, Kind: "purchase",
		Status: "created", BizType: b.BizType, BizID: &id}
	err := tx.QueryRow(ctx, `INSERT INTO src.src_ord_loop_order (order_no, user_id, plan_code, plan_name, order_amt, channel, biz_type, biz_id)
		VALUES ($1,$2,NULL,$3,$4,$5,$6,$7) RETURNING create_time`, o.OrderNo, o.UserID, o.PlanName, o.AmountFen, o.Channel, o.BizType, id).Scan(&o.CreatedAt)
	return o, err
}

// PayParams asks the channel for what the app needs to open the payment
// sheet. On a channel error the order is closed and the error is a 502 the
// caller returns after undoing its own record.
func (s *Service) PayParams(ctx context.Context, o Order, ip string) (map[string]any, error) {
	prov, ok := s.provider(o.Channel)
	if !ok {
		return nil, httpx.BadRequest("channel_not_allowed", "不支持的支付方式")
	}
	params, err := prov.Create(ctx, o, Plan{Name: o.PlanName}, ip)
	if err != nil {
		s.Log.Error("create payment", "channel", o.Channel, "order", o.OrderNo, "err", err)
		_ = CloseUnpaid(ctx, s.Pool, o.OrderNo)
		return nil, httpx.E(http.StatusBadGateway, "provider_error", "支付渠道暂时不可用，请稍后再试")
	}
	if params == nil {
		params = map[string]any{}
	}
	return params, nil
}

// CloseUnpaid closes an order that is still waiting for payment.
func CloseUnpaid(ctx context.Context, q db.Querier, orderNo string) error {
	_, err := q.Exec(ctx, `UPDATE src.src_ord_loop_order SET status='closed' WHERE order_no=$1 AND status='created'`, orderNo)
	return err
}

// RequestRefund marks a paid non-membership order for refund inside the
// caller's transaction; call Refund after commit (RetryRefunds retries when
// the channel fails). It reports whether the order was paid.
func RequestRefund(ctx context.Context, tx pgx.Tx, orderNo, reason string) (bool, error) {
	tag, err := tx.Exec(ctx, `UPDATE src.src_ord_loop_order SET status='refund_requested', refund_reason=$2
		WHERE order_no=$1 AND status='paid' AND biz_type <> 'membership'`, orderNo, reason)
	return tag.RowsAffected() > 0, err
}

// RetryRefunds refunds non-membership orders still waiting for their refund
// (membership refund requests wait for an admin instead).
func (s *Service) RetryRefunds(ctx context.Context) error {
	rows, err := s.Pool.Query(ctx, `SELECT order_no, COALESCE(refund_reason, '退款') FROM src.src_ord_loop_order
		WHERE status='refund_requested' AND biz_type <> 'membership' ORDER BY create_time LIMIT 100`)
	if err != nil {
		return err
	}
	type due struct{ no, reason string }
	ds, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (due, error) {
		var d due
		return d, r.Scan(&d.no, &d.reason)
	})
	if err != nil {
		return err
	}
	for _, d := range ds {
		if _, err := s.Refund(ctx, d.no, d.reason); err != nil {
			s.Log.Error("retry refund", "order", d.no, "err", err)
		}
	}
	return nil
}
