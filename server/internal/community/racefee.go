package community

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/billing"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// 赛事报名费 (docs/api/v2-4-本地生活与商户.md D-12): a race with fee_amt > 0
// is signed up for by paying. The entry is pending_pay until the payment
// arrives (then signed), dropped after booking.pay_timeout_min unpaid, and
// refunded through the original channel when the runner withdraws before
// the start or the race is cancelled.

// SignupWith is POST /v1/races/{id}/signup. Free races sign up at once
// (params nil); paid races create the fee order and return the payment
// parameters (an unpaid entry is reused, an already signed one returns nil
// params).
func (s *Service) SignupWith(ctx context.Context, user, id int64, channel, ip string) (Race, map[string]any, error) {
	var fee int
	err := s.Pool.QueryRow(ctx, `SELECT fee_amt FROM src.src_mkt_loop_race WHERE id=$1 AND is_published`, id).Scan(&fee)
	if db.IsNoRows(err) {
		return Race{}, nil, httpx.NotFound("赛事")
	}
	if err != nil {
		return Race{}, nil, err
	}
	if fee == 0 {
		r, err := s.Signup(ctx, user, id)
		return r, nil, err
	}
	if s.Billing == nil {
		return Race{}, nil, httpx.BadRequest("channel_not_allowed", "暂不支持在线支付报名费")
	}
	if err := s.Billing.CheckBizChannel(channel); err != nil {
		return Race{}, nil, err
	}
	var order *billing.Order
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		order = nil
		var status, title string
		var capacity, taken int
		var signupEnd, end time.Time
		err := tx.QueryRow(ctx, `SELECT race_status, title, capacity_qty, signup_end_time, end_time, fee_amt FROM src.src_mkt_loop_race WHERE id=$1 FOR UPDATE`, id).
			Scan(&status, &title, &capacity, &signupEnd, &end, &fee)
		if err != nil {
			return err
		}
		var entry string
		var orderNo *string
		err = tx.QueryRow(ctx, `SELECT entry_status, order_no FROM src.src_mkt_loop_race_entry WHERE race_id=$1 AND user_id=$2`, id, user).Scan(&entry, &orderNo)
		if err != nil && !db.IsNoRows(err) {
			return err
		}
		if entry == "signed" || entry == "finished" {
			return nil
		}
		now := time.Now()
		if status == "cancelled" || !now.Before(signupEnd) || !now.Before(end) {
			return httpx.Conflict("signup_closed", "报名已截止")
		}
		if entry == "pending_pay" && orderNo != nil {
			o, err := s.Billing.GetOrder(ctx, tx, *orderNo, user)
			if err != nil {
				return err
			}
			if o.Status == "created" && o.Channel == channel && o.AmountFen == fee {
				order = &o
				return nil
			}
			// Another channel (or a stale order): start over.
			if err := billing.CloseUnpaid(ctx, tx, *orderNo); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `DELETE FROM src.src_mkt_loop_race_entry WHERE race_id=$1 AND user_id=$2 AND entry_status='pending_pay'`, id, user); err != nil {
				return err
			}
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM src.src_mkt_loop_race_entry WHERE race_id=$1`, id).Scan(&taken); err != nil {
			return err
		}
		if taken >= capacity {
			return httpx.Conflict("race_full", "名额已满")
		}
		o, err := s.Billing.NewBizOrder(ctx, tx, billing.BizOrder{UserID: user, BizType: billing.BizRaceFee, BizID: id,
			Title: "赛事报名费·" + title, AmountFen: fee, Channel: channel})
		if err != nil {
			return err
		}
		order = &o
		_, err = tx.Exec(ctx, `INSERT INTO src.src_mkt_loop_race_entry (race_id, user_id, entry_status, order_no) VALUES ($1,$2,'pending_pay',$3)`, id, user, o.OrderNo)
		return err
	})
	if err != nil {
		return Race{}, nil, err
	}
	var params map[string]any
	if order != nil {
		if params, err = s.Billing.PayParams(ctx, *order, ip); err != nil {
			_, _ = s.Pool.Exec(ctx, `DELETE FROM src.src_mkt_loop_race_entry WHERE race_id=$1 AND user_id=$2 AND order_no=$3 AND entry_status='pending_pay'`,
				id, user, order.OrderNo)
			return Race{}, nil, err
		}
	}
	r, err := s.Race(ctx, user, id, false)
	return r, params, err
}

// withdraw is the sign-up cancellation before the start: an unpaid entry
// closes its order, a paid one is refunded after commit.
func (s *Service) withdraw(ctx context.Context, user, id int64) error {
	var refund []string
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		refund = nil
		var orderNo *string
		err := tx.QueryRow(ctx, `SELECT order_no FROM src.src_mkt_loop_race_entry WHERE race_id=$1 AND user_id=$2`, id, user).Scan(&orderNo)
		if db.IsNoRows(err) {
			return nil
		}
		if err != nil {
			return err
		}
		if orderNo != nil { // the payment callback locks the order first, then the entry
			if _, err := tx.Exec(ctx, `SELECT 1 FROM src.src_ord_loop_order WHERE order_no=$1 FOR UPDATE`, *orderNo); err != nil {
				return err
			}
		}
		var status string
		err = tx.QueryRow(ctx, `DELETE FROM src.src_mkt_loop_race_entry WHERE race_id=$1 AND user_id=$2 AND entry_status IN ('pending_pay','signed')
			RETURNING entry_status`, id, user).Scan(&status)
		if db.IsNoRows(err) || orderNo == nil {
			return nil
		}
		if err != nil {
			return err
		}
		if status == "pending_pay" {
			return billing.CloseUnpaid(ctx, tx, *orderNo)
		}
		paid, err := billing.RequestRefund(ctx, tx, *orderNo, "取消报名")
		if paid {
			refund = append(refund, *orderNo)
		}
		return err
	})
	if err == nil {
		s.refundFees(ctx, refund, "取消报名")
	}
	return err
}

// cancelFees runs inside the race cancellation: unpaid entries are dropped,
// paid fees are marked for refund (returned, refunded after commit).
func cancelFees(ctx context.Context, tx pgx.Tx, race int64) ([]string, error) {
	rows, err := tx.Query(ctx, `SELECT order_no, entry_status FROM src.src_mkt_loop_race_entry
		WHERE race_id=$1 AND order_no IS NOT NULL AND entry_status IN ('pending_pay','signed')`, race)
	if err != nil {
		return nil, err
	}
	type fee struct{ no, status string }
	fs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (fee, error) {
		var f fee
		return f, r.Scan(&f.no, &f.status)
	})
	if err != nil {
		return nil, err
	}
	var out []string
	for _, f := range fs {
		if f.status == "pending_pay" {
			if _, err := tx.Exec(ctx, `DELETE FROM src.src_mkt_loop_race_entry WHERE order_no=$1 AND entry_status='pending_pay'`, f.no); err != nil {
				return nil, err
			}
			if err := billing.CloseUnpaid(ctx, tx, f.no); err != nil {
				return nil, err
			}
			continue
		}
		paid, err := billing.RequestRefund(ctx, tx, f.no, "赛事取消")
		if err != nil {
			return nil, err
		}
		if paid {
			out = append(out, f.no)
		}
	}
	return out, nil
}

// refundFees refunds after commit; failures stay refund_requested and are
// retried by the billing refund job.
func (s *Service) refundFees(ctx context.Context, orders []string, reason string) {
	if s.Billing == nil {
		return
	}
	for _, no := range orders {
		if _, err := s.Billing.Refund(ctx, no, reason); err != nil {
			s.Log.Error("race fee refund", "order", no, "err", err)
		}
	}
}

// ExpireRaceFees drops paid-race entries left unpaid for
// booking.pay_timeout_min and closes their orders.
func (s *Service) ExpireRaceFees(ctx context.Context) error {
	_, err := s.Pool.Exec(ctx, `WITH closed AS (
			UPDATE src.src_ord_loop_order SET status='closed' WHERE status='created' AND biz_type='race_fee' AND create_time < now() - make_interval(mins => $1)
			RETURNING order_no)
		DELETE FROM src.src_mkt_loop_race_entry WHERE entry_status='pending_pay' AND order_no IN (SELECT order_no FROM closed)`,
		s.Config.For(0).Booking.PayTimeoutMin)
	return err
}

// RaceFeeFulfiller is the billing fulfiller of biz_type race_fee.
func (s *Service) RaceFeeFulfiller() billing.Fulfiller { return raceFee{} }

type raceFee struct{}

// Paid turns the pending entry into a sign-up; a lapsed entry or a
// cancelled race is refunded.
func (raceFee) Paid(ctx context.Context, tx pgx.Tx, o billing.Order) (bool, error) {
	var title string
	err := tx.QueryRow(ctx, `UPDATE src.src_mkt_loop_race_entry e SET entry_status='signed' FROM src.src_mkt_loop_race r
		WHERE r.id=e.race_id AND e.order_no=$1 AND e.entry_status='pending_pay' AND r.race_status <> 'cancelled' RETURNING r.title`, o.OrderNo).Scan(&title)
	if db.IsNoRows(err) {
		_, err := tx.Exec(ctx, `DELETE FROM src.src_mkt_loop_race_entry WHERE order_no=$1 AND entry_status='pending_pay'`, o.OrderNo)
		return true, err
	}
	if err != nil {
		return false, err
	}
	return false, inbox.Notify(ctx, tx, o.UserID, inbox.Interaction, "赛事报名成功", fmt.Sprintf("报名费已支付，你已成功报名「%s」。", title),
		map[string]any{"type": "race_signed", "race_id": o.BizID})
}

// Refunded removes the entry (not a finished one) and tells the runner.
func (raceFee) Refunded(ctx context.Context, tx pgx.Tx, o billing.Order, reason string) error {
	if _, err := tx.Exec(ctx, `DELETE FROM src.src_mkt_loop_race_entry WHERE order_no=$1 AND entry_status <> 'finished'`, o.OrderNo); err != nil {
		return err
	}
	return inbox.Notify(ctx, tx, o.UserID, inbox.System, "报名费已退款",
		fmt.Sprintf("「%s」¥%.2f 已原路退回（%s）。", o.PlanName, float64(o.AmountFen)/100, reason), map[string]any{"type": "race_fee_refunded", "race_id": o.BizID})
}
