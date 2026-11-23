package app

import (
	"fmt"
	"testing"
)

// Staff bound to stores only redeem product coupons usable at their stores;
// the store defaults to the bound one. Unbound staff are not limited.
func TestStaffBoundToStore(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)
	m := e.merchant("跑野运动馆")
	other := e.merchant("滨江网球")
	front := e.staff(ad, "zj-front", m)
	free := e.staff(ad, "floater", m)
	var zj, sj, far venueView
	ad.must("POST", "/admin/v1/venues", venueBody("跑野 · 张江", &m, 0, 0, true), &zj)
	ad.must("POST", "/admin/v1/venues", venueBody("跑野 · 世纪公园", &m, 1000, 0, true), &sj)
	ad.must("POST", "/admin/v1/venues", venueBody("滨江 · 一号馆", &other, 2000, 0, true), &far)

	var detail struct {
		Staff []struct {
			ID       int64   `json:"id"`
			Username string  `json:"username"`
			VenueIDs []int64 `json:"venue_ids"`
			Venues   []struct {
				Name string `json:"name"`
			} `json:"venues"`
		} `json:"staff"`
	}
	ad.must("GET", fmt.Sprintf("/admin/v1/merchants/%d", m), nil, &detail)
	var frontID int64
	for _, s := range detail.Staff {
		if s.Username == "zj-front" {
			frontID = s.ID
		}
		if len(s.VenueIDs) != 0 {
			t.Fatalf("staff bound before binding: %+v", s)
		}
	}
	path := fmt.Sprintf("/admin/v1/merchants/%d/staff/%d/venues", m, frontID)
	ad.expectErr("PUT", path, map[string]any{"venue_ids": []int64{far.ID}}, 400, "invalid_body") // other merchant's venue
	front.expectErr("PUT", path, map[string]any{"venue_ids": []int64{zj.ID}}, 403, "forbidden")  // admin only
	var bound struct {
		VenueIDs []int64 `json:"venue_ids"`
		Venues   []struct {
			Name string `json:"name"`
		} `json:"venues"`
	}
	ad.must("PUT", path, map[string]any{"venue_ids": []int64{zj.ID}}, &bound)
	if len(bound.VenueIDs) != 1 || bound.VenueIDs[0] != zj.ID || bound.Venues[0].Name != "跑野 · 张江" {
		t.Fatalf("bound: %+v", bound)
	}

	zjOnly := front.onSale(productBody("package", "张江羽毛球套餐", 6900, map[string]any{"venue_ids": []int64{zj.ID}}))
	sjOnly := front.onSale(productBody("package", "世纪公园游泳套餐", 5900, map[string]any{"venue_ids": []int64{sj.ID}}))
	anywhere := front.onSale(productBody("voucher", "全店代金券", 8000, map[string]any{"original_amt": 10000}))
	u, _ := e.member("13800005201")
	a, b, c := u.buy(zjOnly.ID, 1), u.buy(sjOnly.ID, 1), u.buy(anywhere.ID, 1)

	var rd struct {
		Redemption struct {
			Store string `json:"store"`
		} `json:"redemption"`
	}
	// Bound to 张江: a 张江 coupon redeems there by default.
	front.must("POST", "/admin/v1/redemptions", map[string]string{"code": a.Coupons[0].Code}, &rd)
	if rd.Redemption.Store != "跑野 · 张江" {
		t.Fatalf("default store: %+v", rd)
	}
	// A 世纪公园-only coupon is refused at 张江, even when the staff names it.
	front.expectErr("POST", "/admin/v1/redemptions", map[string]string{"code": b.Coupons[0].Code}, 403, "wrong_store")
	front.expectErr("POST", "/admin/v1/redemptions", map[string]string{"code": b.Coupons[0].Code, "store": "跑野 · 世纪公园"}, 403, "wrong_store")
	// A coupon for every store is recorded at the staff's store.
	front.must("POST", "/admin/v1/redemptions", map[string]string{"code": c.Coupons[0].Code}, &rd)
	if rd.Redemption.Store != "跑野 · 张江" {
		t.Fatalf("store for an any-store coupon: %+v", rd)
	}
	// Unbound staff are not limited.
	free.must("POST", "/admin/v1/redemptions", map[string]string{"code": b.Coupons[0].Code}, &rd)
	if rd.Redemption.Store != "跑野 · 世纪公园" {
		t.Fatalf("unbound staff: %+v", rd)
	}

	// Clearing the binding removes the limit.
	ad.must("PUT", path, map[string]any{"venue_ids": []int64{}}, &bound)
	if len(bound.VenueIDs) != 0 {
		t.Fatalf("cleared: %+v", bound)
	}
	// Creating staff with stores binds them at once.
	ad.must("POST", fmt.Sprintf("/admin/v1/merchants/%d/staff", m), map[string]any{"username": "sj-front", "password": "sj-front-pass-1", "venue_ids": []int64{sj.ID}}, nil)
	ad.must("GET", fmt.Sprintf("/admin/v1/merchants/%d", m), nil, &detail)
	for _, s := range detail.Staff {
		if s.Username == "sj-front" && (len(s.VenueIDs) != 1 || s.VenueIDs[0] != sj.ID) {
			t.Fatalf("created with stores: %+v", s)
		}
	}
}
