package app

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/keanying/loopland/server/internal/platform/clock"
)

type merchantView struct {
	ID           int64   `json:"id"`
	Name         string  `json:"name"`
	Status       string  `json:"status"`
	ContactPhone *string `json:"contact_phone"`
	VenueCount   int     `json:"venue_count"`
	Venues       []struct {
		ID int64 `json:"id"`
	} `json:"venues"`
	Staff []struct {
		Username string `json:"username"`
	} `json:"staff"`
}

type venueView struct {
	ID       int64 `json:"id"`
	Merchant *struct {
		ID int64 `json:"id"`
	} `json:"merchant"`
	Name     string   `json:"name"`
	Bookable bool     `json:"bookable"`
	PriceAmt *int     `json:"price_amt"`
	Distance *float64 `json:"distance_m"`
	Owner    *struct {
		User struct {
			ID int64 `json:"id"`
		} `json:"user"`
		Points int    `json:"points"`
		Since  string `json:"since"`
	} `json:"owner"`
	MyWeekPoints   int  `json:"my_week_points"`
	CheckedInToday bool `json:"checked_in_today"`
	WeekRank       []struct {
		Rank   int `json:"rank"`
		Points int `json:"points"`
		User   struct {
			ID int64 `json:"id"`
		} `json:"user"`
	} `json:"week_rank"`
	SlotMinutes int `json:"slot_minutes"`
}

type checkinView struct {
	ActivityID int64     `json:"activity_id"`
	Energy     int       `json:"energy"`
	Points     int       `json:"points"`
	WeekPoints int       `json:"week_points"`
	Coupon     any       `json:"coupon"`
	Venue      venueView `json:"venue"`
}

type slotView struct {
	StartTime     time.Time `json:"start_time"`
	PriceAmt      int       `json:"price_amt"`
	OwnerPriceAmt *int      `json:"owner_price_amt"`
	Available     bool      `json:"available"`
}

type bookingView struct {
	ID           int64     `json:"id"`
	BookingNo    string    `json:"booking_no"`
	StartTime    time.Time `json:"start_time"`
	AmountAmt    int       `json:"amount_amt"`
	OriginalAmt  int       `json:"original_amt"`
	DiscountType string    `json:"discount_type"`
	Status       string    `json:"status"`
	MeetupID     *int64    `json:"meetup_id"`
	Pay          *struct {
		OrderNo string `json:"order_no"`
		Channel string `json:"channel"`
	} `json:"pay"`
	CancelDeadline time.Time `json:"cancel_deadline"`
	User           *struct {
		ID int64 `json:"id"`
	} `json:"user"`
}

type bookingCreated struct {
	Booking   bookingView    `json:"booking"`
	PayParams map[string]any `json:"pay_params"`
}

func (e *env) adminLogin(user, pass string) *client {
	c := e.anon()
	var login struct {
		Token string `json:"token"`
	}
	c.must("POST", "/admin/v1/login", map[string]string{"username": user, "password": pass}, &login)
	c.token = login.Token
	return c
}

func (e *env) job(name string) {
	e.t.Helper()
	if err := e.app.Jobs.Extra[name](context.Background()); err != nil {
		e.t.Fatalf("job %s: %v", name, err)
	}
}

func (e *env) orderStatus(no string) string {
	e.t.Helper()
	var s string
	if err := e.app.Pool.QueryRow(context.Background(), `SELECT status FROM src.src_ord_loop_order WHERE order_no=$1`, no).Scan(&s); err != nil {
		e.t.Fatal(err)
	}
	return s
}

func venueBody(name string, merchant *int64, x, y float64, bookable bool) map[string]any {
	p := at(x, y)
	b := map[string]any{"merchant_id": merchant, "name": name, "sports": []string{"pickleball", "badminton"},
		"center": map[string]any{"lat": p.Lat, "lng": p.Lng}, "address": "测试路 1 号", "district": "黄浦区", "tags": []string{"室内"},
		"checkin_radius_m": 150, "bookable": bookable}
	if bookable {
		b["price_amt"], b["slot_minutes"], b["open_time"], b["close_time"], b["court_qty"], b["owner_discount_rate"] = 6000, 60, "07:00", "23:00", 1, 0.8
	}
	return b
}

func TestMerchantsAndStaff(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)

	ad.expectErr("POST", "/admin/v1/merchants", map[string]any{"name": "x", "type": "shop"}, 400, "invalid_body")
	var m1, m2 merchantView
	ad.must("POST", "/admin/v1/merchants", map[string]any{"name": "城南全民健身中心", "type": "venue", "status": "partner", "contact_name": "王经理",
		"contact_phone": "13812341234", "license_images": []string{"https://cdn.test/l.png"}, "booking_commission_rate": 0.1}, &m1)
	if m1.ContactPhone == nil || *m1.ContactPhone != "138****1234" || m1.Status != "partner" {
		t.Fatalf("merchant: %+v", m1)
	}
	ad.must("POST", "/admin/v1/merchants", map[string]any{"name": "瑞幸咖啡", "type": "brand"}, &m2)
	if m2.Status != "reviewing" || m2.ContactPhone != nil {
		t.Fatalf("merchant 2: %+v", m2)
	}
	ad.must("PATCH", fmt.Sprintf("/admin/v1/merchants/%d", m2.ID), map[string]any{"status": "pending_sign"}, &m2)
	if m2.Status != "pending_sign" || m2.Name != "瑞幸咖啡" {
		t.Fatalf("patched: %+v", m2)
	}
	var phone struct {
		Phone string `json:"phone"`
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/merchants/%d/reveal-phone", m1.ID), nil, &phone)
	if phone.Phone != "13812341234" {
		t.Fatalf("reveal: %+v", phone)
	}
	var audits int
	if err := e.app.Pool.QueryRow(context.Background(), `SELECT count(*) FROM src.src_sys_loop_audit_log WHERE action='merchant.reveal_phone'`).Scan(&audits); err != nil || audits != 1 {
		t.Fatalf("reveal audited: %d %v", audits, err)
	}
	var list struct {
		Items []merchantView `json:"items"`
		Total int            `json:"total"`
	}
	ad.must("GET", "/admin/v1/merchants?status=partner", nil, &list)
	if list.Total != 1 || list.Items[0].ID != m1.ID {
		t.Fatalf("filtered: %+v", list)
	}

	// Staff accounts: admin only; staff see their own merchant only.
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/merchants/%d/staff", m1.ID), map[string]string{"username": "staff1", "password": "short"}, 400, "weak_password")
	ad.must("POST", fmt.Sprintf("/admin/v1/merchants/%d/staff", m1.ID), map[string]string{"username": "staff1", "password": "staff-password-1"}, nil)
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/merchants/%d/staff", m2.ID), map[string]string{"username": "staff1", "password": "staff-password-1"}, 409, "username_taken")
	var d merchantView
	ad.must("GET", fmt.Sprintf("/admin/v1/merchants/%d", m1.ID), nil, &d)
	if len(d.Staff) != 1 || d.Staff[0].Username != "staff1" || d.Venues == nil {
		t.Fatalf("detail: %+v", d)
	}
	st := e.adminLogin("staff1", "staff-password-1")
	st.must("GET", "/admin/v1/merchants", nil, &list)
	if list.Total != 1 || list.Items[0].ID != m1.ID {
		t.Fatalf("staff scope: %+v", list)
	}
	st.must("GET", fmt.Sprintf("/admin/v1/merchants/%d", m1.ID), nil, nil)
	st.expectErr("GET", fmt.Sprintf("/admin/v1/merchants/%d", m2.ID), nil, 404, "not_found")
	st.expectErr("POST", "/admin/v1/merchants", map[string]any{"name": "x", "type": "brand"}, 403, "forbidden")
	st.expectErr("GET", "/admin/v1/venues", nil, 403, "forbidden")
	st.expectErr("POST", fmt.Sprintf("/admin/v1/merchants/%d/staff", m1.ID), map[string]string{"username": "s2", "password": "staff-password-2"}, 403, "forbidden")
	st.must("GET", "/admin/v1/bookings", nil, nil)
}

func TestVenueCheckinOwnersBooking(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	ad := adminClient(t, e)
	a, aid := e.member("13800000501")
	b, bid := e.member("13800000502")

	var cfg struct {
		Venue struct {
			CheckinEnergy int `json:"checkin_energy"`
			CheckinPoints int `json:"checkin_points"`
		} `json:"venue"`
		Booking struct {
			FreeCancelHours int `json:"free_cancel_hours"`
		} `json:"booking"`
	}
	a.must("GET", "/v1/config/gameplay", nil, &cfg)
	if cfg.Venue.CheckinEnergy != 20 || cfg.Venue.CheckinPoints != 10 || cfg.Booking.FreeCancelHours != 2 {
		t.Fatalf("config: %+v", cfg)
	}

	var m merchantView
	ad.must("POST", "/admin/v1/merchants", map[string]any{"name": "城南全民健身中心", "type": "venue", "status": "partner"}, &m)
	ad.expectErr("POST", "/admin/v1/venues", venueBody("缺商户", nil, 0, 0, true), 400, "invalid_body")
	var va, vb, vc, vd venueView
	ad.must("POST", "/admin/v1/venues", venueBody("城南 · 匹克球", &m.ID, 0, 0, true), &va)
	ad.must("POST", "/admin/v1/venues", venueBody("滨江攀岩", nil, 3000, 0, false), &vb)
	ad.must("POST", "/admin/v1/venues", venueBody("江边篮球场", nil, 0, 3000, false), &vc)
	ad.must("POST", "/admin/v1/venues", venueBody("社区健身房", nil, 0, -3000, false), &vd)
	if !va.Bookable || va.SlotMinutes != 60 || va.Merchant == nil || vb.Bookable || vb.Merchant != nil {
		t.Fatalf("venues: %+v %+v", va, vb)
	}

	// App list by distance.
	var list cursorList[venueView]
	a.must("GET", fmt.Sprintf("/v1/venues?lat=%f&lng=%f&radius_m=5000", origin.Lat, origin.Lng), nil, &list)
	if len(list.Items) != 4 || list.Items[0].ID != va.ID || list.Items[0].Distance == nil || *list.Items[0].Distance > 5 {
		t.Fatalf("list: %+v", list.Items)
	}
	a.must("GET", "/v1/venues?bookable=true&sport=pickleball", nil, &list)
	if len(list.Items) != 1 || list.Items[0].ID != va.ID {
		t.Fatalf("bookable list: %+v", list.Items)
	}

	// Check-in by radius: a venue activity through the settlement.
	path := func(v venueView) string { return fmt.Sprintf("/v1/venues/%d/checkin", v.ID) }
	o := at(0, 0)
	far := at(1000, 0)
	a.expectErr("POST", path(va), map[string]any{}, 400, "checkin_not_allowed")
	a.expectErr("POST", path(va), map[string]any{"lat": far.Lat, "lng": far.Lng}, 400, "checkin_not_allowed")
	var ci checkinView
	a.must("POST", path(va), map[string]any{"lat": o.Lat, "lng": o.Lng}, &ci)
	if ci.Energy != 20 || ci.Points != 10 || ci.WeekPoints != 10 || ci.ActivityID == 0 || ci.Coupon != nil || !ci.Venue.CheckedInToday ||
		ci.Venue.MyWeekPoints != 10 {
		t.Fatalf("checkin: %+v", ci)
	}
	var act struct {
		Sport         string `json:"sport"`
		Status        string `json:"status"`
		EnergyGranted int    `json:"energy_granted"`
	}
	a.must("GET", fmt.Sprintf("/v1/activities/%d", ci.ActivityID), nil, &act)
	if act.Sport != "venue" || act.Status != "settled" || act.EnergyGranted != 20 {
		t.Fatalf("activity: %+v", act)
	}
	var me struct {
		Energy int `json:"energy"`
	}
	a.must("GET", "/v1/me", nil, &me)
	if me.Energy != 20 {
		t.Fatalf("energy: %+v", me)
	}
	a.expectErr("POST", path(va), map[string]any{"lat": o.Lat, "lng": o.Lng}, 409, "already_checked_in")
	// App uploads of sport venue stay rejected.
	up := run(3, [2]float64{0, 0}, [2]float64{10, 0})
	up["sport"], up["points"], up["amount"] = "venue", nil, 1
	a.expectErr("POST", "/v1/activities", up, 400, "sport_not_supported")

	// QR check-in; rotating the code invalidates the old one.
	var qr struct {
		Payload string `json:"payload"`
		URL     string `json:"url"`
	}
	ad.must("GET", fmt.Sprintf("/admin/v1/venues/%d/qr", vb.ID), nil, &qr)
	old := qr.Payload
	ad.must("POST", fmt.Sprintf("/admin/v1/venues/%d/qr/rotate", vb.ID), nil, &qr)
	if qr.Payload == old || qr.URL == "" {
		t.Fatalf("rotate: %+v", qr)
	}
	a.expectErr("POST", path(vb), map[string]any{"qr": old}, 400, "checkin_not_allowed")
	var vcQR struct {
		Payload string `json:"payload"`
	}
	ad.must("GET", fmt.Sprintf("/admin/v1/venues/%d/qr", vc.ID), nil, &vcQR)
	a.expectErr("POST", path(vb), map[string]any{"qr": vcQR.Payload}, 400, "checkin_not_allowed") // another venue's code
	a.must("POST", path(vb), map[string]any{"qr": qr.URL}, &ci)                                   // the universal link works too
	a.must("POST", path(vc), map[string]any{"qr": vcQR.Payload}, &ci)
	if ci.Points != 10 {
		t.Fatalf("qr checkin: %+v", ci)
	}
	near := at(0, -3000)
	a.expectErr("POST", path(vd), map[string]any{"lat": near.Lat, "lng": near.Lng}, 429, "rate_limited") // 3 venues a day

	// B ties A at venue A but later: A becomes the owner next Monday.
	b.must("POST", path(va), map[string]any{"lat": o.Lat, "lng": o.Lng}, nil)
	var detail venueView
	a.must("GET", fmt.Sprintf("/v1/venues/%d", va.ID), nil, &detail)
	if len(detail.WeekRank) != 2 || detail.WeekRank[0].User.ID != aid || detail.WeekRank[1].User.ID != bid || detail.Owner != nil {
		t.Fatalf("week rank: %+v", detail)
	}
	e.sql(`UPDATE src.src_mer_loop_venue_checkin SET week_start_date=week_start_date-7, checkin_date=checkin_date-7`)
	e.job("venue_owners")
	e.job("venue_owners") // once a week
	var owners int
	if err := e.app.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_mer_loop_venue_owner`).Scan(&owners); err != nil || owners != 3 {
		t.Fatalf("owners: %d %v", owners, err)
	}
	a.must("GET", fmt.Sprintf("/v1/venues/%d", va.ID), nil, &detail)
	monday := clock.Today().AddDate(0, 0, -((int(clock.Today().Weekday()) + 6) % 7)).Format("2006-01-02")
	if detail.Owner == nil || detail.Owner.User.ID != aid || detail.Owner.Points != 10 || detail.Owner.Since != monday || len(detail.WeekRank) != 0 {
		t.Fatalf("owner: %+v", detail)
	}
	var inbox struct {
		Items []struct {
			Title string `json:"title"`
		} `json:"items"`
	}
	a.must("GET", "/v1/inbox", nil, &inbox)
	if len(inbox.Items) == 0 || inbox.Items[0].Title != "你成为了本周馆主" {
		t.Fatalf("owner notified: %+v", inbox)
	}
	var hist struct {
		Items []struct {
			WeekStart string `json:"week_start"`
			Points    int    `json:"points"`
		} `json:"items"`
	}
	ad.must("GET", fmt.Sprintf("/admin/v1/venues/%d/owners", va.ID), nil, &hist)
	if len(hist.Items) != 1 || hist.Items[0].WeekStart != monday || hist.Items[0].Points != 10 {
		t.Fatalf("owner history: %+v", hist)
	}
	var objs struct {
		Venues []struct {
			ID            int64   `json:"id"`
			OwnerNickname *string `json:"owner_nickname"`
			Bookable      bool    `json:"bookable"`
		} `json:"venues"`
	}
	sw, ne := at(-500, -500), at(500, 500)
	a.must("GET", fmt.Sprintf("/v1/map/objects?bbox=%f,%f,%f,%f", sw.Lng, sw.Lat, ne.Lng, ne.Lat), nil, &objs)
	if len(objs.Venues) != 1 || objs.Venues[0].ID != va.ID || objs.Venues[0].OwnerNickname == nil || !objs.Venues[0].Bookable {
		t.Fatalf("map venues: %+v", objs.Venues)
	}

	// ---------------------------------------------------------------- booking
	tomorrow := clock.Today().AddDate(0, 0, 1)
	slotAt := func(h int) time.Time { return tomorrow.Add(time.Duration(h) * time.Hour) }
	book := func(c *client, v venueView, h, slots int, meetup *int64) map[string]any {
		return map[string]any{"venue_id": v.ID, "start_time": slotAt(h), "slots": slots, "channel": "mock", "meetup_id": meetup}
	}
	a.expectErr("POST", "/v1/bookings", book(a, va, 10, 2, nil), 403, "realname_required")
	a.must("POST", "/v1/me/realname", map[string]string{"name": "张三", "id_number": idNumber("19900307")}, nil)
	b.must("POST", "/v1/me/realname", map[string]string{"name": "李四", "id_number": idNumber("19920101")}, nil)
	kid, _ := e.member("13800000503")
	kid.must("POST", "/v1/me/realname", map[string]string{"name": "小明", "id_number": idNumber("20150101")}, nil)
	kid.expectErr("POST", "/v1/bookings", book(kid, va, 10, 1, nil), 403, "minor_not_allowed")
	a.expectErr("POST", "/v1/bookings", map[string]any{"venue_id": va.ID, "start_time": slotAt(10), "slots": 1, "channel": "apple_iap"}, 400, "channel_not_allowed")
	a.expectErr("POST", "/v1/bookings", book(a, va, 10, 5, nil), 400, "invalid_body")
	a.expectErr("POST", "/v1/bookings", book(a, va, 22, 2, nil), 400, "invalid_slot") // past closing
	a.expectErr("POST", "/v1/bookings", book(a, vb, 10, 1, nil), 409, "not_bookable")
	a.expectErr("GET", fmt.Sprintf("/v1/venues/%d/slots?date=%s", vb.ID, tomorrow.Format("2006-01-02")), nil, 409, "not_bookable")

	var slots struct {
		Date  string     `json:"date"`
		Items []slotView `json:"items"`
	}
	day := tomorrow.Format("2006-01-02")
	a.must("GET", fmt.Sprintf("/v1/venues/%d/slots?date=%s", va.ID, day), nil, &slots)
	if slots.Date != day || len(slots.Items) != 16 || slots.Items[0].PriceAmt != 6000 || slots.Items[0].OwnerPriceAmt == nil ||
		*slots.Items[0].OwnerPriceAmt != 4800 || !slots.Items[0].StartTime.Equal(slotAt(7)) {
		t.Fatalf("owner slots: %+v", slots)
	}
	b.must("GET", fmt.Sprintf("/v1/venues/%d/slots?date=%s", va.ID, day), nil, &slots)
	if slots.Items[0].OwnerPriceAmt != nil {
		t.Fatalf("non-owner slots: %+v", slots.Items[0])
	}

	// Owner books 10:00–12:00 at the owner price and pays.
	var bk bookingCreated
	a.must("POST", "/v1/bookings", book(a, va, 10, 2, nil), &bk)
	if bk.Booking.Status != "pending_pay" || bk.Booking.AmountAmt != 9600 || bk.Booking.OriginalAmt != 12000 || bk.Booking.DiscountType != "owner" ||
		bk.Booking.Pay == nil || bk.Booking.Pay.Channel != "mock" || bk.PayParams == nil || bk.Booking.User != nil ||
		!bk.Booking.CancelDeadline.Equal(slotAt(8)) || len(bk.Booking.BookingNo) != 21 {
		t.Fatalf("booking: %+v", bk)
	}
	b.expectErr("POST", "/v1/bookings", book(b, va, 11, 1, nil), 409, "slot_unavailable")
	b.must("GET", fmt.Sprintf("/v1/venues/%d/slots?date=%s", va.ID, day), nil, &slots)
	if slots.Items[3].Available || slots.Items[4].Available || !slots.Items[5].Available { // 10:00, 11:00 taken
		t.Fatalf("held slots: %+v", slots.Items[3:6])
	}
	a.must("POST", "/v1/dev/orders/"+bk.Booking.Pay.OrderNo+"/pay", nil, nil)
	var got bookingView
	a.must("GET", fmt.Sprintf("/v1/bookings/%d", bk.Booking.ID), nil, &got)
	if got.Status != "paid" {
		t.Fatalf("paid: %+v", got)
	}
	b.expectErr("GET", fmt.Sprintf("/v1/bookings/%d", bk.Booking.ID), nil, 404, "not_found")

	// B's unpaid booking expires after the timeout; paying late is refunded.
	var bb bookingCreated
	b.must("POST", "/v1/bookings", book(b, va, 14, 1, nil), &bb)
	if bb.Booking.AmountAmt != 6000 || bb.Booking.DiscountType != "none" {
		t.Fatalf("b booking: %+v", bb.Booking)
	}
	e.sql(`UPDATE src.src_ord_loop_order SET create_time=now() - interval '20 minutes' WHERE order_no=$1`, bb.Booking.Pay.OrderNo)
	e.job("booking_expire")
	b.must("GET", fmt.Sprintf("/v1/bookings/%d", bb.Booking.ID), nil, &got)
	if got.Status != "expired" || e.orderStatus(bb.Booking.Pay.OrderNo) != "closed" {
		t.Fatalf("expired: %+v", got)
	}
	b.must("POST", "/v1/dev/orders/"+bb.Booking.Pay.OrderNo+"/pay", nil, nil)
	if s := e.orderStatus(bb.Booking.Pay.OrderNo); s != "refunded" {
		t.Fatalf("late payment: %s", s)
	}
	var mine struct {
		Items []bookingView `json:"items"`
	}
	b.must("GET", "/v1/me/bookings?status=expired", nil, &mine)
	if len(mine.Items) != 1 || mine.Items[0].ID != bb.Booking.ID {
		t.Fatalf("my bookings: %+v", mine)
	}

	// Cancel in time: full refund through the channel.
	a.must("POST", fmt.Sprintf("/v1/bookings/%d/cancel", bk.Booking.ID), nil, &got)
	if got.Status != "refunded" || e.orderStatus(bk.Booking.Pay.OrderNo) != "refunded" {
		t.Fatalf("cancelled: %+v", got)
	}
	a.expectErr("POST", fmt.Sprintf("/v1/bookings/%d/cancel", bk.Booking.ID), nil, 409, "invalid_status")
	// Cancelling an unpaid booking closes the order.
	a.must("POST", "/v1/bookings", book(a, va, 10, 1, nil), &bk)
	a.must("POST", fmt.Sprintf("/v1/bookings/%d/cancel", bk.Booking.ID), nil, &got)
	if got.Status != "cancelled" || e.orderStatus(bk.Booking.Pay.OrderNo) != "closed" {
		t.Fatalf("unpaid cancel: %+v", got)
	}

	// Too late to cancel: an admin refunds (merchant staff cannot).
	a.must("POST", "/v1/bookings", book(a, va, 16, 1, nil), &bk)
	a.must("POST", "/v1/dev/orders/"+bk.Booking.Pay.OrderNo+"/pay", nil, nil)
	e.sql(`UPDATE src.src_ord_loop_booking SET start_time=now() + interval '1 hour', end_time=now() + interval '2 hours' WHERE id=$1`, bk.Booking.ID)
	a.expectErr("POST", fmt.Sprintf("/v1/bookings/%d/cancel", bk.Booking.ID), nil, 409, "cancel_too_late")
	ad.must("POST", fmt.Sprintf("/admin/v1/merchants/%d/staff", m.ID), map[string]string{"username": "front", "password": "front-desk-pass"}, nil)
	st := e.adminLogin("front", "front-desk-pass")
	var al struct {
		Items []bookingView `json:"items"`
		Total int           `json:"total"`
	}
	st.must("GET", fmt.Sprintf("/admin/v1/bookings?venue_id=%d&status=paid", va.ID), nil, &al)
	if al.Total != 1 || al.Items[0].ID != bk.Booking.ID || al.Items[0].User == nil || al.Items[0].User.ID != aid {
		t.Fatalf("staff bookings: %+v", al)
	}
	st.expectErr("POST", fmt.Sprintf("/admin/v1/bookings/%d/refund", bk.Booking.ID), map[string]string{"reason": "x"}, 403, "forbidden")
	ad.must("POST", fmt.Sprintf("/admin/v1/bookings/%d/refund", bk.Booking.ID), map[string]string{"reason": "场馆临时维修"}, &got)
	if got.Status != "refunded" || e.orderStatus(bk.Booking.Pay.OrderNo) != "refunded" {
		t.Fatalf("admin refund: %+v", got)
	}
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/bookings/%d/refund", bk.Booking.ID), nil, 409, "invalid_status")
	ad.must("GET", "/admin/v1/bookings?date="+tomorrow.Format("2006-01-02"), nil, &al)
	if al.Total < 3 {
		t.Fatalf("admin bookings by date: %+v", al.Total)
	}

	// Paid bookings complete once they start.
	a.must("POST", "/v1/bookings", book(a, va, 18, 1, nil), &bk)
	a.must("POST", "/v1/dev/orders/"+bk.Booking.Pay.OrderNo+"/pay", nil, nil)
	e.sql(`UPDATE src.src_ord_loop_booking SET start_time=now() - interval '1 minute', end_time=now() + interval '59 minutes' WHERE id=$1`, bk.Booking.ID)
	e.job("booking_expire")
	a.must("GET", fmt.Sprintf("/v1/bookings/%d", bk.Booking.ID), nil, &got)
	if got.Status != "completed" {
		t.Fatalf("completed: %+v", got)
	}

	// D-11: book for my own ball meetup; it shows on the meetup.
	var run, ball meetupView
	a.must("POST", "/v1/meetups", meetupBody("约跑", 0, 0, 5), &run)
	mb := meetupBody("周六匹克球", 0, 0, 4)
	mb["type"] = "ball"
	a.must("POST", "/v1/meetups", mb, &ball)
	b.expectErr("POST", "/v1/bookings", book(b, va, 20, 1, &ball.ID), 403, "not_creator")
	a.expectErr("POST", "/v1/bookings", book(a, va, 20, 1, &run.ID), 400, "invalid_meetup")
	a.must("POST", "/v1/bookings", book(a, va, 20, 1, &ball.ID), &bk)
	if bk.Booking.MeetupID == nil || *bk.Booking.MeetupID != ball.ID {
		t.Fatalf("meetup booking: %+v", bk.Booking)
	}
	var md struct {
		Booking *struct {
			Venue struct {
				ID int64 `json:"id"`
			} `json:"venue"`
			StartTime time.Time `json:"start_time"`
			Status    string    `json:"status"`
		} `json:"booking"`
	}
	b.must("GET", fmt.Sprintf("/v1/meetups/%d", ball.ID), nil, &md)
	if md.Booking != nil {
		t.Fatalf("unpaid booking shown to others: %+v", md.Booking)
	}
	a.must("POST", "/v1/dev/orders/"+bk.Booking.Pay.OrderNo+"/pay", nil, nil)
	b.must("GET", fmt.Sprintf("/v1/meetups/%d", ball.ID), nil, &md)
	if md.Booking == nil || md.Booking.Venue.ID != va.ID || !md.Booking.StartTime.Equal(slotAt(20)) || md.Booking.Status != "paid" {
		t.Fatalf("meetup shows booking: %+v", md.Booking)
	}

	// Cancelling the meetup cancels and refunds the court booked with it.
	a.must("POST", fmt.Sprintf("/v1/meetups/%d/cancel", ball.ID), nil, nil)
	a.must("GET", fmt.Sprintf("/v1/bookings/%d", bk.Booking.ID), nil, &got)
	if got.Status != "refunded" || e.orderStatus(bk.Booking.Pay.OrderNo) != "refunded" {
		t.Fatalf("meetup cancel → booking: %+v", got)
	}

	// 继续支付: an unpaid booking can get its payment parameters again.
	var rp bookingCreated
	a.must("POST", "/v1/bookings", book(a, va, 19, 1, nil), &bk)
	a.must("POST", fmt.Sprintf("/v1/bookings/%d/pay", bk.Booking.ID), nil, &rp)
	if rp.Booking.ID != bk.Booking.ID || rp.PayParams == nil || rp.Booking.Pay.OrderNo != bk.Booking.Pay.OrderNo {
		t.Fatalf("repay: %+v", rp)
	}
	b.expectErr("POST", fmt.Sprintf("/v1/bookings/%d/pay", bk.Booking.ID), nil, 404, "not_found")
	a.must("POST", "/v1/dev/orders/"+bk.Booking.Pay.OrderNo+"/pay", nil, nil)
	a.expectErr("POST", fmt.Sprintf("/v1/bookings/%d/pay", bk.Booking.ID), nil, 409, "invalid_status")

	// Dashboard todos: refunds stuck for over an hour, merchants under review.
	e.sql(`UPDATE src.src_ord_loop_booking SET booking_status='refunding', update_time=now() - interval '2 hours' WHERE id=$1`, bk.Booking.ID)
	ad.must("POST", "/admin/v1/merchants", map[string]any{"name": "待审核商户", "type": "store", "status": "reviewing"}, nil)
	var dash struct {
		Todos []struct {
			Type  string `json:"type"`
			Count int    `json:"count"`
		} `json:"todos"`
	}
	ad.must("GET", "/admin/v1/dashboard", nil, &dash)
	kinds := map[string]int{}
	for _, td := range dash.Todos {
		kinds[td.Type] = td.Count
	}
	if kinds["booking_refund"] != 1 || kinds["merchant_review"] < 1 {
		t.Fatalf("todos: %+v", dash.Todos)
	}

	// A suspended merchant's venues cannot be booked.
	ad.must("PATCH", fmt.Sprintf("/admin/v1/merchants/%d", m.ID), map[string]any{"status": "suspended"}, nil)
	a.expectErr("POST", "/v1/bookings", book(a, va, 21, 1, nil), 409, "not_bookable")
}

func TestRaceFees(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)
	a, _ := e.member("13800000601")
	b, _ := e.member("13800000602")
	now := time.Now()
	p := at(0, 0)
	var race struct {
		raceView
		FeeAmt int `json:"fee_amt"`
	}
	ad.must("POST", "/admin/v1/races", map[string]any{"type": "offline", "title": "城市 10K", "sport": "run", "distance_m": 10000,
		"start_time": now.Add(48 * time.Hour), "end_time": now.Add(52 * time.Hour), "signup_end_time": now.Add(24 * time.Hour),
		"place": map[string]any{"name": "外滩", "lat": p.Lat, "lng": p.Lng}, "capacity": 2, "fee_amt": 3900, "published": true}, &race)
	if race.FeeAmt != 3900 {
		t.Fatalf("race fee: %+v", race)
	}
	ad.must("PATCH", fmt.Sprintf("/admin/v1/races/%d", race.ID), map[string]any{"fee_amt": 4900}, &race)
	if race.FeeAmt != 4900 {
		t.Fatalf("race fee edit: %+v", race)
	}
	type entry struct {
		Status  string  `json:"status"`
		OrderNo *string `json:"order_no"`
	}
	type signed struct {
		Race struct {
			SignedCount int    `json:"signed_count"`
			MyEntry     *entry `json:"my_entry"`
		} `json:"race"`
		PayParams map[string]any `json:"pay_params"`
	}
	path := fmt.Sprintf("/v1/races/%d/signup", race.ID)
	a.expectErr("POST", path, nil, 400, "channel_not_allowed")
	var sa signed
	a.must("POST", path, map[string]string{"channel": "mock"}, &sa)
	if sa.Race.MyEntry == nil || sa.Race.MyEntry.Status != "pending_pay" || sa.Race.MyEntry.OrderNo == nil || sa.PayParams == nil || sa.Race.SignedCount != 0 {
		t.Fatalf("pending: %+v", sa)
	}
	aOrder := *sa.Race.MyEntry.OrderNo
	a.must("POST", path, map[string]string{"channel": "mock"}, &sa) // asking again reuses the order
	if *sa.Race.MyEntry.OrderNo != aOrder {
		t.Fatalf("reused order: %+v", sa)
	}
	a.must("POST", "/v1/dev/orders/"+aOrder+"/pay", nil, nil)
	var r struct {
		SignedCount int    `json:"signed_count"`
		MyEntry     *entry `json:"my_entry"`
	}
	a.must("GET", fmt.Sprintf("/v1/races/%d", race.ID), nil, &r)
	if r.MyEntry == nil || r.MyEntry.Status != "signed" || r.SignedCount != 1 {
		t.Fatalf("signed: %+v", r)
	}

	// B does not pay in time: the entry is dropped.
	var sb signed
	b.must("POST", path, map[string]string{"channel": "mock"}, &sb)
	e.sql(`UPDATE src.src_ord_loop_order SET create_time=now() - interval '20 minutes' WHERE order_no=$1`, *sb.Race.MyEntry.OrderNo)
	e.job("race_fee_expire")
	b.must("GET", fmt.Sprintf("/v1/races/%d", race.ID), nil, &r)
	if r.MyEntry != nil || e.orderStatus(*sb.Race.MyEntry.OrderNo) != "closed" {
		t.Fatalf("expired entry: %+v", r)
	}
	// B pays, then withdraws before the start: refunded.
	b.must("POST", path, map[string]string{"channel": "mock"}, &sb)
	b.must("POST", "/v1/dev/orders/"+*sb.Race.MyEntry.OrderNo+"/pay", nil, nil)
	b.must("DELETE", path, nil, &r)
	if r.MyEntry != nil || e.orderStatus(*sb.Race.MyEntry.OrderNo) != "refunded" {
		t.Fatalf("withdrawn: %+v", r)
	}

	// The race is cancelled: A's fee comes back.
	ad.must("POST", fmt.Sprintf("/admin/v1/races/%d/cancel", race.ID), nil, nil)
	if s := e.orderStatus(aOrder); s != "refunded" {
		t.Fatalf("race cancel refund: %s", s)
	}
	var inbox struct {
		Items []struct {
			Title string `json:"title"`
		} `json:"items"`
	}
	a.must("GET", "/v1/inbox", nil, &inbox)
	if len(inbox.Items) == 0 || inbox.Items[0].Title != "报名费已退款" {
		t.Fatalf("refund notified: %+v", inbox)
	}
	// Membership orders still list as before (the regression of the order table).
	var orders struct {
		Total int `json:"total"`
	}
	ad.must("GET", "/admin/v1/orders", nil, &orders)
	if orders.Total != 3 {
		t.Fatalf("orders: %+v", orders)
	}
}
