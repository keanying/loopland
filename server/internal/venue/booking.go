package venue

import (
	"context"
	"crypto/rand"
	"fmt"
	"math"
	"math/big"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/billing"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Slot is one bookable period of a day.
type Slot struct {
	StartTime     time.Time `json:"start_time"`
	EndTime       time.Time `json:"end_time"`
	PriceAmt      int       `json:"price_amt"`
	OwnerPriceAmt *int      `json:"owner_price_amt"`
	Available     bool      `json:"available"`
}

// activeBooking holds a slot: unpaid (until expiry), paid or completed.
const activeBooking = `b.booking_status IN ('pending_pay','paid','completed')`

// slotPrice is the price of one slot: price_amt is per hour.
func (v Venue) slotPrice() int {
	if v.PriceAmt == nil {
		return 0
	}
	return int(math.Round(float64(*v.PriceAmt) * float64(v.row.slotMinutes) / 60))
}

// ownerPrice applies the owner discount when viewer owns the venue this week.
func (v Venue) ownerPrice(viewer int64, price int) *int {
	if v.OwnerDiscountRate == nil || v.row.ownerUser == nil || *v.row.ownerUser != viewer || viewer == 0 {
		return nil
	}
	p := int(math.Round(float64(price) * *v.OwnerDiscountRate))
	return &p
}

// daySpans are the slot starts of a day (Shanghai midnight) from opening
// to closing time.
func (v Venue) daySpans(day time.Time) []time.Time {
	open, _ := parseClock(v.row.openTime)
	closing, _ := parseClock(v.row.closeTime)
	var out []time.Time
	for m := open; m+v.row.slotMinutes <= closing; m += v.row.slotMinutes {
		out = append(out, day.Add(time.Duration(m)*time.Minute))
	}
	return out
}

type held struct {
	start, end time.Time
	courts     int
}

func occupancy(ctx context.Context, q db.Querier, venue int64, from, to time.Time) ([]held, error) {
	rows, err := q.Query(ctx, `SELECT b.start_time, b.end_time, b.court_qty FROM src.src_ord_loop_booking b
		WHERE b.venue_id=$1 AND `+activeBooking+` AND b.start_time < $3 AND b.end_time > $2`, venue, from, to)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (held, error) {
		var h held
		return h, r.Scan(&h.start, &h.end, &h.courts)
	})
}

func used(hs []held, start, end time.Time) int {
	n := 0
	for _, h := range hs {
		if h.start.Before(end) && h.end.After(start) {
			n += h.courts
		}
	}
	return n
}

var errNotBookable = httpx.Conflict("not_bookable", "这个场馆暂不支持在线订场")

// Slots is GET /v1/venues/{id}/slots?date=YYYY-MM-DD (past slots left out).
func (s *Service) Slots(ctx context.Context, viewer, id int64, date string) ([]Slot, error) {
	day, err := time.ParseInLocation("2006-01-02", date, clock.Shanghai)
	if err != nil {
		return nil, httpx.BadRequest("invalid_date", "date 格式为 YYYY-MM-DD")
	}
	v, err := s.Get(ctx, s.Pool, viewer, id, false)
	if err != nil {
		return nil, err
	}
	if !v.Bookable {
		return nil, errNotBookable
	}
	out := []Slot{}
	spans := v.daySpans(day)
	if len(spans) == 0 {
		return out, nil
	}
	step := time.Duration(v.row.slotMinutes) * time.Minute
	hs, err := occupancy(ctx, s.Pool, id, spans[0], spans[len(spans)-1].Add(step))
	if err != nil {
		return nil, err
	}
	now := time.Now()
	price := v.slotPrice()
	for _, st := range spans {
		if !st.After(now) {
			continue
		}
		end := st.Add(step)
		out = append(out, Slot{StartTime: st.In(clock.Shanghai), EndTime: end.In(clock.Shanghai), PriceAmt: price,
			OwnerPriceAmt: v.ownerPrice(viewer, price), Available: used(hs, st, end) < v.row.courtQty})
	}
	return out, nil
}

// ---------------------------------------------------------------- bookings

// PayRef is the booking's payment order.
type PayRef struct {
	OrderNo string `json:"order_no"`
	Channel string `json:"channel"`
}

// UserRef is a compact user (admin lists).
type UserRef struct {
	ID       int64  `json:"id"`
	Nickname string `json:"nickname"`
}

// Booking is 订场.
type Booking struct {
	ID             int64     `json:"id"`
	BookingNo      string    `json:"booking_no"`
	Venue          Ref       `json:"venue"`
	StartTime      time.Time `json:"start_time"`
	EndTime        time.Time `json:"end_time"`
	CourtQty       int       `json:"court_qty"`
	AmountAmt      int       `json:"amount_amt"`
	OriginalAmt    int       `json:"original_amt"`
	DiscountType   string    `json:"discount_type"`
	Status         string    `json:"status"`
	MeetupID       *int64    `json:"meetup_id"`
	Pay            *PayRef   `json:"pay"`
	CancelDeadline time.Time `json:"cancel_deadline"`
	CreatedAt      time.Time `json:"created_at"`
	User           *UserRef  `json:"user,omitempty"`

	userID  int64
	orderNo *string
}

const bookingCols = `b.id, b.booking_no, b.venue_id, v.venue_name, b.start_time, b.end_time, b.court_qty, b.amount_amt, b.original_amt, b.discount_type,
	b.booking_status, b.meetup_id, b.order_no, b.channel, b.create_time, b.user_id, u.nickname`

const bookingFrom = ` FROM src.src_ord_loop_booking b JOIN src.src_mer_loop_venue v ON v.id=b.venue_id JOIN src.src_usr_loop_user u ON u.id=b.user_id`

func (s *Service) queryBookings(ctx context.Context, q db.Querier, where string, args ...any) ([]Booking, error) {
	rows, err := q.Query(ctx, `SELECT `+bookingCols+bookingFrom+` WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	bs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Booking, error) {
		var b Booking
		var channel, nick string
		err := r.Scan(&b.ID, &b.BookingNo, &b.Venue.ID, &b.Venue.Name, &b.StartTime, &b.EndTime, &b.CourtQty, &b.AmountAmt, &b.OriginalAmt,
			&b.DiscountType, &b.Status, &b.MeetupID, &b.orderNo, &channel, &b.CreatedAt, &b.userID, &nick)
		if b.orderNo != nil {
			b.Pay = &PayRef{OrderNo: *b.orderNo, Channel: channel}
		}
		b.User = &UserRef{ID: b.userID, Nickname: nick}
		hours := s.Config.For(b.userID).Booking.FreeCancelHours
		b.StartTime, b.EndTime = b.StartTime.In(clock.Shanghai), b.EndTime.In(clock.Shanghai)
		b.CancelDeadline = b.StartTime.Add(-time.Duration(hours) * time.Hour)
		return b, err
	})
	if bs == nil {
		bs = []Booking{}
	}
	return bs, err
}

func hideUser(bs []Booking) []Booking {
	for i := range bs {
		bs[i].User = nil
	}
	return bs
}

// Booking loads one booking (user 0: admin).
func (s *Service) Booking(ctx context.Context, q db.Querier, user, id int64) (Booking, error) {
	bs, err := s.queryBookings(ctx, q, `b.id=$1 AND ($2=0 OR b.user_id=$2)`, id, user)
	if err != nil {
		return Booking{}, err
	}
	if len(bs) == 0 {
		return Booking{}, httpx.NotFound("订场")
	}
	if user != 0 {
		hideUser(bs)
	}
	return bs[0], nil
}

// MyBookings is GET /v1/me/bookings.
func (s *Service) MyBookings(ctx context.Context, user int64, status string) ([]Booking, error) {
	bs, err := s.queryBookings(ctx, s.Pool, `b.user_id=$1 AND ($2='' OR b.booking_status=$2) ORDER BY b.create_time DESC LIMIT 100`, user, status)
	return hideUser(bs), err
}

// AdminBookings is GET /admin/v1/bookings (merchant: the staff scope).
func (s *Service) AdminBookings(ctx context.Context, merchant *int64, venue int64, status, date string, p httpx.Page) ([]Booking, int, error) {
	var from, to *time.Time
	if date != "" {
		d, err := time.ParseInLocation("2006-01-02", date, clock.Shanghai)
		if err != nil {
			return nil, 0, httpx.BadRequest("invalid_date", "date 格式为 YYYY-MM-DD")
		}
		e := d.AddDate(0, 0, 1)
		from, to = &d, &e
	}
	where := `($1::bigint IS NULL OR b.merchant_id=$1) AND ($2=0 OR b.venue_id=$2) AND ($3='' OR b.booking_status=$3)
		AND ($4::timestamptz IS NULL OR (b.start_time >= $4 AND b.start_time < $5))`
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_ord_loop_booking b WHERE `+where, merchant, venue, status, from, to).Scan(&total); err != nil {
		return nil, 0, err
	}
	bs, err := s.queryBookings(ctx, s.Pool, where+` ORDER BY b.create_time DESC LIMIT $6 OFFSET $7`, merchant, venue, status, from, to, p.Size, p.Offset())
	return bs, total, err
}

// BookingInput is POST /v1/bookings.
type BookingInput struct {
	VenueID   int64     `json:"venue_id"`
	StartTime time.Time `json:"start_time"`
	Slots     int       `json:"slots"`
	Channel   string    `json:"channel"`
	MeetupID  *int64    `json:"meetup_id"`
}

func newBookingNo() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(100_000))
	return fmt.Sprintf("BK%s%05d", time.Now().In(clock.Shanghai).Format("20060102150405"), n.Int64())
}

// CreateBooking books consecutive slots and starts the payment. It needs a
// verified adult; the owner of the week pays the owner price.
func (s *Service) CreateBooking(ctx context.Context, user int64, in BookingInput, ip string) (Booking, map[string]any, error) {
	cfg := s.Config.For(user).Booking
	if in.Slots < 1 || in.Slots > cfg.MaxSlots {
		return Booking{}, nil, httpx.BadRequest("invalid_body", fmt.Sprintf("一次可订 1–%d 个连续时段", cfg.MaxSlots))
	}
	if err := s.Billing.CheckBizChannel(in.Channel); err != nil {
		return Booking{}, nil, err
	}
	var verified bool
	var adult *bool
	if err := s.Pool.QueryRow(ctx, `SELECT is_realname_verified, is_adult FROM src.src_usr_loop_user WHERE id=$1`, user).Scan(&verified, &adult); err != nil {
		return Booking{}, nil, err
	}
	if !verified {
		return Booking{}, nil, httpx.Forbidden("realname_required", "订场前请先完成实名认证")
	}
	if adult == nil || !*adult {
		return Booking{}, nil, httpx.Forbidden("minor_not_allowed", "未成年用户不能在线订场")
	}
	var b Booking
	var order billing.Order
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT 1 FROM src.src_mer_loop_venue WHERE id=$1 FOR UPDATE`, in.VenueID); err != nil {
			return err
		}
		v, err := s.Get(ctx, tx, user, in.VenueID, false)
		if err != nil {
			return err
		}
		if !v.Bookable || v.PriceAmt == nil {
			return errNotBookable
		}
		start := in.StartTime.In(clock.Shanghai)
		spans := v.daySpans(clock.Day(start))
		first := -1
		for i, st := range spans {
			if st.Equal(start) {
				first = i
			}
		}
		if first < 0 || first+in.Slots > len(spans) {
			return httpx.BadRequest("invalid_slot", "请选择营业时间内的整段时段")
		}
		if !start.After(time.Now()) {
			return httpx.Conflict("slot_unavailable", "这个时段已经开始，换一个吧")
		}
		step := time.Duration(v.row.slotMinutes) * time.Minute
		end := start.Add(time.Duration(in.Slots) * step)
		hs, err := occupancy(ctx, tx, v.ID, start, end)
		if err != nil {
			return err
		}
		for i := 0; i < in.Slots; i++ {
			st := spans[first+i]
			if used(hs, st, st.Add(step)) >= v.row.courtQty {
				return httpx.Conflict("slot_unavailable", "所选时段已订满，换一个吧")
			}
		}
		if in.MeetupID != nil {
			if err := checkMeetup(ctx, tx, user, *in.MeetupID); err != nil {
				return err
			}
		}
		original := v.slotPrice() * in.Slots
		amount, discount := original, "none"
		if p := v.ownerPrice(user, original); p != nil && *p < original {
			amount, discount = max(1, *p), "owner"
		}
		var id int64
		if err := tx.QueryRow(ctx, `INSERT INTO src.src_ord_loop_booking (booking_no, user_id, venue_id, merchant_id, start_time, end_time, slot_qty, court_qty,
				amount_amt, original_amt, discount_type, meetup_id, channel)
			VALUES ($1,$2,$3,$4,$5,$6,$7,1,$8,$9,$10,$11,$12) RETURNING id`, newBookingNo(), user, v.ID, *v.row.merchantID, start, end, in.Slots,
			amount, original, discount, in.MeetupID, in.Channel).Scan(&id); err != nil {
			return err
		}
		order, err = s.Billing.NewBizOrder(ctx, tx, billing.BizOrder{UserID: user, BizType: billing.BizBooking, BizID: id,
			Title: fmt.Sprintf("订场·%s %s", v.Name, start.Format("01-02 15:04")), AmountFen: amount, Channel: in.Channel})
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_ord_loop_booking SET order_no=$2 WHERE id=$1`, id, order.OrderNo); err != nil {
			return err
		}
		b, err = s.Booking(ctx, tx, user, id)
		return err
	})
	if err != nil {
		return Booking{}, nil, err
	}
	params, err := s.Billing.PayParams(ctx, order, ip)
	if err != nil {
		_, _ = s.Pool.Exec(ctx, `UPDATE src.src_ord_loop_booking SET booking_status='cancelled', update_time=now() WHERE id=$1 AND booking_status='pending_pay'`, b.ID)
		return Booking{}, nil, err
	}
	return b, params, nil
}

// checkMeetup: a booking can be attached to the caller's own open ball meetup.
func checkMeetup(ctx context.Context, q db.Querier, user, id int64) error {
	var creator int64
	var typ, status string
	err := q.QueryRow(ctx, `SELECT creator_id, meetup_type, meetup_status FROM src.src_soc_loop_meetup WHERE id=$1`, id).Scan(&creator, &typ, &status)
	if db.IsNoRows(err) {
		return httpx.NotFound("组局")
	}
	if err != nil {
		return err
	}
	if creator != user {
		return httpx.Forbidden("not_creator", "只能给自己发起的组局订场")
	}
	if typ != "ball" || status != "open" {
		return httpx.BadRequest("invalid_meetup", "只能给进行中的约球组局订场")
	}
	return nil
}

// lockBooking locks the payment order before the booking, the order the
// payment callback takes them in.
func lockBooking(ctx context.Context, tx pgx.Tx, user, id int64) (status string, orderNo *string, start time.Time, err error) {
	if err = tx.QueryRow(ctx, `SELECT order_no FROM src.src_ord_loop_booking WHERE id=$1 AND ($2=0 OR user_id=$2)`, id, user).Scan(&orderNo); db.IsNoRows(err) {
		return "", nil, start, httpx.NotFound("订场")
	}
	if err != nil {
		return
	}
	if orderNo != nil {
		if _, err = tx.Exec(ctx, `SELECT 1 FROM src.src_ord_loop_order WHERE order_no=$1 FOR UPDATE`, *orderNo); err != nil {
			return
		}
	}
	err = tx.QueryRow(ctx, `SELECT booking_status, start_time FROM src.src_ord_loop_booking WHERE id=$1 FOR UPDATE`, id).Scan(&status, &start)
	return
}

// Cancel is POST /v1/bookings/{id}/cancel: unpaid bookings are cancelled;
// paid ones are refunded in full when at least free_cancel_hours remain.
func (s *Service) Cancel(ctx context.Context, user, id int64) (Booking, error) {
	hours := s.Config.For(user).Booking.FreeCancelHours
	var refundNo *string
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		status, orderNo, start, err := lockBooking(ctx, tx, user, id)
		if err != nil {
			return err
		}
		switch status {
		case "pending_pay":
			if _, err := tx.Exec(ctx, `UPDATE src.src_ord_loop_booking SET booking_status='cancelled', update_time=now() WHERE id=$1`, id); err != nil {
				return err
			}
			if orderNo != nil {
				return billing.CloseUnpaid(ctx, tx, *orderNo)
			}
			return nil
		case "paid":
			if time.Now().After(start.Add(-time.Duration(hours) * time.Hour)) {
				return httpx.Conflict("cancel_too_late", fmt.Sprintf("开始前 %d 小时内不能自助取消，可以联系客服处理", hours))
			}
			refundNo = orderNo
			return s.markRefunding(ctx, tx, id, orderNo, "用户取消订场")
		default:
			return httpx.Conflict("invalid_status", "当前状态不能取消")
		}
	})
	if err != nil {
		return Booking{}, err
	}
	if refundNo != nil {
		if _, err := s.Billing.Refund(ctx, *refundNo, "用户取消订场"); err != nil {
			s.Log.Error("booking refund", "booking", id, "err", err) // stays refunding; RetryRefunds retries
		}
	}
	return s.Booking(ctx, s.Pool, user, id)
}

func (s *Service) markRefunding(ctx context.Context, tx pgx.Tx, id int64, orderNo *string, reason string) error {
	if _, err := tx.Exec(ctx, `UPDATE src.src_ord_loop_booking SET booking_status='refunding', refund_reason=$2, update_time=now() WHERE id=$1`, id, reason); err != nil {
		return err
	}
	if orderNo == nil {
		return nil
	}
	_, err := billing.RequestRefund(ctx, tx, *orderNo, reason)
	return err
}

// AdminRefund is POST /admin/v1/bookings/{id}/refund (also after the free
// cancellation window, and for completed bookings).
func (s *Service) AdminRefund(ctx context.Context, id int64, reason string) (Booking, error) {
	if reason == "" {
		reason = "客服退款"
	}
	var orderNo *string
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		status, no, _, err := lockBooking(ctx, tx, 0, id)
		if err != nil {
			return err
		}
		if status != "paid" && status != "completed" && status != "refunding" {
			return httpx.Conflict("invalid_status", "只有已支付的订场可以退款")
		}
		if no == nil {
			return httpx.Conflict("invalid_status", "这个订场没有支付订单")
		}
		orderNo = no
		return s.markRefunding(ctx, tx, id, no, reason)
	})
	if err != nil {
		return Booking{}, err
	}
	if _, err := s.Billing.Refund(ctx, *orderNo, reason); err != nil {
		return Booking{}, err
	}
	return s.Booking(ctx, s.Pool, 0, id)
}

// ---------------------------------------------------------------- payment

// BookingFulfiller is the billing fulfiller of biz_type booking.
func (s *Service) BookingFulfiller() billing.Fulfiller { return bookingFulfiller{s} }

type bookingFulfiller struct{ s *Service }

// Paid confirms the booking; a booking that expired or was cancelled
// before the money arrived is refunded.
func (f bookingFulfiller) Paid(ctx context.Context, tx pgx.Tx, o billing.Order) (bool, error) {
	var id, venue int64
	var name string
	var start time.Time
	err := tx.QueryRow(ctx, `UPDATE src.src_ord_loop_booking b SET booking_status='paid', paid_time=now(), update_time=now()
		FROM src.src_mer_loop_venue v WHERE v.id=b.venue_id AND b.order_no=$1 AND b.booking_status='pending_pay'
		RETURNING b.id, b.venue_id, v.venue_name, b.start_time`, o.OrderNo).Scan(&id, &venue, &name, &start)
	if db.IsNoRows(err) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	return false, inbox.Notify(ctx, tx, o.UserID, inbox.System, "订场成功",
		fmt.Sprintf("「%s」%s 的场地已为你预留，记得准时到场。", name, start.In(clock.Shanghai).Format("01-02 15:04")),
		map[string]any{"type": "booking_paid", "booking_id": id, "venue_id": venue})
}

// Refunded closes the booking and tells the user.
func (f bookingFulfiller) Refunded(ctx context.Context, tx pgx.Tx, o billing.Order, reason string) error {
	if _, err := tx.Exec(ctx, `UPDATE src.src_ord_loop_booking SET booking_status='refunded', refund_time=now(), refund_reason=COALESCE(refund_reason, $2),
		update_time=now() WHERE order_no=$1 AND booking_status IN ('paid','refunding','completed')`, o.OrderNo, reason); err != nil {
		return err
	}
	var id int64
	var name string
	err := tx.QueryRow(ctx, `SELECT b.id, v.venue_name FROM src.src_ord_loop_booking b JOIN src.src_mer_loop_venue v ON v.id=b.venue_id WHERE b.order_no=$1`,
		o.OrderNo).Scan(&id, &name)
	if db.IsNoRows(err) {
		return nil
	}
	if err != nil {
		return err
	}
	return inbox.Notify(ctx, tx, o.UserID, inbox.System, "订场已退款",
		fmt.Sprintf("「%s」的订场费用 ¥%.2f 已原路退回（%s）。", name, float64(o.AmountFen)/100, reason),
		map[string]any{"type": "booking_refunded", "booking_id": id})
}

// ExpireBookings expires unpaid bookings after booking.pay_timeout_min
// (closing their orders) and completes paid ones whose start has passed.
func (s *Service) ExpireBookings(ctx context.Context) error {
	timeout := s.Config.For(0).Booking.PayTimeoutMin
	if _, err := s.Pool.Exec(ctx, `WITH closed AS (
			UPDATE src.src_ord_loop_order SET status='closed' WHERE status='created' AND biz_type='booking' AND create_time < now() - make_interval(mins => $1)
			RETURNING order_no)
		UPDATE src.src_ord_loop_booking SET booking_status='expired', update_time=now()
		WHERE booking_status='pending_pay' AND order_no IN (SELECT order_no FROM closed)`, timeout); err != nil {
		return err
	}
	_, err := s.Pool.Exec(ctx, `UPDATE src.src_ord_loop_booking SET booking_status='completed', update_time=now() WHERE booking_status='paid' AND start_time <= now()`)
	return err
}
