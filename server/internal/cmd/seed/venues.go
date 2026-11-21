package seed

import (
	"fmt"

	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/platform/clock"
)

// seedVenues adds V2 batch 4 part A data: two merchants (one with a staff
// account), two bookable venues and a check-in point near 人民广场, a few
// check-ins and a booking.
func seedVenues(users []*client, ad *client) {
	proj := geo.NewProjection(origin)
	at := func(x, y float64) map[string]any {
		p := proj.Inverse(geo.Point{X: x, Y: y})
		return map[string]any{"lat": p.Lat, "lng": p.Lng}
	}
	var gym, club struct {
		ID int64 `json:"id"`
	}
	ad.do("POST", "/admin/v1/merchants", map[string]any{"name": "城南全民健身中心", "type": "venue", "status": "partner", "contact_name": "王经理",
		"contact_phone": "13800138000", "booking_commission_rate": 0.1}, &gym)
	ad.do("POST", "/admin/v1/merchants", map[string]any{"name": "滨江网球俱乐部", "type": "venue", "status": "partner", "booking_commission_rate": 0.08}, &club)
	if gym.ID == 0 {
		return
	}
	ad.do("POST", fmt.Sprintf("/admin/v1/merchants/%d/staff", gym.ID), map[string]string{"username": "gym-staff", "password": "gym-staff-pass-1"}, nil)
	type venue struct {
		ID int64 `json:"id"`
	}
	var pickle, wall venue
	ad.do("POST", "/admin/v1/venues", map[string]any{"merchant_id": gym.ID, "name": "城南全民健身中心 · 匹克球", "sports": []string{"pickleball", "badminton"},
		"center": at(300, -200), "address": "人民大道 100 号", "district": "黄浦区", "tags": []string{"室内", "可租拍"}, "bookable": true,
		"price_amt": 6000, "slot_minutes": 60, "open_time": "07:00", "close_time": "23:00", "court_qty": 2, "owner_discount_rate": 0.8}, &pickle)
	if club.ID != 0 {
		ad.do("POST", "/admin/v1/venues", map[string]any{"merchant_id": club.ID, "name": "滨江网球俱乐部", "sports": []string{"tennis"},
			"center": at(1600, 400), "address": "滨江大道 8 号", "district": "黄浦区", "tags": []string{"室外", "夜场灯光"}, "bookable": true,
			"price_amt": 12000, "slot_minutes": 60, "open_time": "08:00", "close_time": "22:00", "court_qty": 3}, nil)
	}
	ad.do("POST", "/admin/v1/venues", map[string]any{"name": "人民公园攀岩墙", "sports": []string{"climbing"}, "center": at(-400, 300),
		"address": "南京西路 231 号", "district": "黄浦区", "checkin_radius_m": 120}, &wall)
	// Check-ins (inside the radius) make a week ranking at the pickleball venue.
	for i, u := range users[:3] {
		u.do("POST", fmt.Sprintf("/v1/venues/%d/checkin", pickle.ID), at(300, -200), nil)
		if i == 0 && wall.ID != 0 {
			u.do("POST", fmt.Sprintf("/v1/venues/%d/checkin", wall.ID), at(-400, 300), nil)
		}
	}
	// 阿青 (verified in the billing seed) books a paid slot for tomorrow evening.
	var slots struct {
		Items []struct {
			StartTime string `json:"start_time"`
			Available bool   `json:"available"`
		} `json:"items"`
	}
	tomorrow := clock.Today().AddDate(0, 0, 1).Format("2006-01-02")
	users[0].do("GET", fmt.Sprintf("/v1/venues/%d/slots?date=%s", pickle.ID, tomorrow), nil, &slots)
	if n := len(slots.Items); n > 2 && slots.Items[n-3].Available {
		var bk struct {
			Booking struct {
				Pay *struct {
					OrderNo string `json:"order_no"`
				} `json:"pay"`
			} `json:"booking"`
		}
		users[0].do("POST", "/v1/bookings", map[string]any{"venue_id": pickle.ID, "start_time": slots.Items[n-3].StartTime, "slots": 2, "channel": "mock"}, &bk)
		if bk.Booking.Pay != nil {
			users[0].do("POST", "/v1/dev/orders/"+bk.Booking.Pay.OrderNo+"/pay", nil, nil)
		}
	}
}
