package app

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/keanying/loopland/server/internal/platform/clock"
)

// ---------------------------------------------------------------- helpers

type couponView struct {
	ID   int64  `json:"id"`
	Code string `json:"code"`
	Perk struct {
		Title     string `json:"title"`
		ValidDays int    `json:"valid_days"`
	} `json:"perk"`
	Merchant struct {
		ID int64 `json:"id"`
	} `json:"merchant"`
	Source struct {
		Type   string `json:"type"`
		DropID int64  `json:"drop_id"`
		Name   string `json:"name"`
	} `json:"source"`
	Status    string    `json:"status"`
	ExpiresAt time.Time `json:"expires_at"`
	UsedStore *string   `json:"used_store"`
}

type perkSettlement struct {
	activityID int64
	Status     string       `json:"status"`
	Coupons    []couponView `json:"coupons"`
	Chests     []struct {
		ChestID int64 `json:"chest_id"`
		Energy  int   `json:"energy"`
	} `json:"chests"`
	Claims []struct {
		TerritoryID int64 `json:"territory_id"`
	} `json:"claims"`
}

// perkRun uploads a run that ended half a minute ago (so it counts as
// today's activity for redemption) with the user's own device.
func (c *client) perkRun(device string, wps ...[2]float64) perkSettlement {
	c.e.t.Helper()
	body := run(3, wps...)
	pts := body["points"].([]pt)
	shift := time.Now().Add(-30 * time.Second).Sub(body["ended_at"].(time.Time))
	for i := range pts {
		pts[i].T += shift.Milliseconds()
	}
	body["started_at"] = body["started_at"].(time.Time).Add(shift)
	body["ended_at"] = body["ended_at"].(time.Time).Add(shift)
	body["device"] = map[string]any{"id": device, "model": "test", "os": "test"}
	var res struct {
		Activity struct {
			ID int64 `json:"id"`
		} `json:"activity"`
		Settlement perkSettlement `json:"settlement"`
	}
	c.must("POST", "/v1/activities", body, &res)
	res.Settlement.activityID = res.Activity.ID
	if res.Settlement.Status != "settled" {
		c.e.t.Fatalf("run not settled: %+v", res.Settlement)
	}
	return res.Settlement
}

func (e *env) scalar(q string, args ...any) int64 {
	e.t.Helper()
	var n int64
	if err := e.app.Pool.QueryRow(context.Background(), q, args...).Scan(&n); err != nil {
		e.t.Fatal(err)
	}
	return n
}

// staff creates a merchant-role admin bound to merchant m and logs in.
func (e *env) staff(ad *client, name string, m int64) *client {
	e.t.Helper()
	var row struct {
		ID int64 `json:"id"`
	}
	ad.must("POST", "/admin/v1/admins", map[string]string{"username": name, "password": "staff-password-1", "role": "merchant"}, &row)
	e.sql(`UPDATE src.src_sys_loop_admin SET merchant_id=$2 WHERE id=$1`, row.ID, m)
	c := e.anon()
	var login struct {
		Token string `json:"token"`
	}
	c.must("POST", "/admin/v1/login", map[string]string{"username": name, "password": "staff-password-1"}, &login)
	c.token = login.Token
	return c
}

func (e *env) resolveVoid(ad *client, activityID, userID int64) {
	e.t.Helper()
	aid := e.scalar(`INSERT INTO src.src_ris_loop_alert (activity_id, user_id, alert_type, confidence, detail) VALUES ($1,$2,'multi_account',0.5,'x') RETURNING id`,
		activityID, userID)
	ad.must("POST", fmt.Sprintf("/admin/v1/risk/alerts/%d/resolve", aid), map[string]string{"action": "void"}, nil)
}

type dropView struct {
	ID            int64  `json:"id"`
	Type          string `json:"type"`
	Status        string `json:"status"`
	CampaignID    *int64 `json:"campaign_id"`
	DailyCap      int    `json:"daily_cap"`
	IssuedToday   int    `json:"issued_today"`
	RedeemedToday int    `json:"redeemed_today"`
	Perk          struct {
		Title string `json:"title"`
	} `json:"perk"`
}

type campaignView struct {
	ID      int64   `json:"id"`
	Status  string  `json:"status"`
	DropIDs []int64 `json:"drop_ids"`
	Stats   struct {
		Issued       int     `json:"issued"`
		Redeemed     int     `json:"redeemed"`
		NewUsers     int     `json:"new_users"`
		ProgressRate float64 `json:"progress_rate"`
	} `json:"stats"`
	StartTime time.Time `json:"start_time"`
}

type redemptionView struct {
	Redemption struct {
		ID     int64      `json:"id"`
		Coupon couponView `json:"coupon"`
		User   struct {
			ID int64 `json:"id"`
		} `json:"user"`
		Store string `json:"store"`
	} `json:"redemption"`
}

type statementView struct {
	ID                   int64  `json:"id"`
	StatementNo          string `json:"statement_no"`
	PeriodStart          string `json:"period_start"`
	PeriodEnd            string `json:"period_end"`
	RedemptionQty        int    `json:"redemption_qty"`
	VoidedQty            int    `json:"voided_qty"`
	RedemptionAmt        int64  `json:"redemption_amt"`
	RedemptionDirection  string `json:"redemption_direction"`
	BookingQty           int    `json:"booking_qty"`
	BookingAmt           int64  `json:"booking_amt"`
	BookingCommissionAmt int64  `json:"booking_commission_amt"`
	NetAmt               int64  `json:"net_amt"`
	Status               string `json:"status"`
	ConfirmedBy          *struct {
		Username string `json:"username"`
	} `json:"confirmed_by"`
	Merchant struct {
		ID int64 `json:"id"`
	} `json:"merchant"`
	Lines []struct {
		Type   string `json:"type"`
		RefNo  string `json:"ref_no"`
		Voided bool   `json:"voided"`
	} `json:"lines"`
}

func (c *client) coupons(status string) []couponView {
	c.e.t.Helper()
	var out struct {
		Items []couponView `json:"items"`
	}
	c.must("GET", "/v1/me/coupons?status="+status, nil, &out)
	return out.Items
}

func findCoupon(cs []couponView, typ string) couponView {
	for _, c := range cs {
		if c.Source.Type == typ {
			return c
		}
	}
	return couponView{}
}

// ---------------------------------------------------------------- scenario

func TestPerksEndToEnd(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	ad := adminClient(t, e)
	now := time.Now()

	m1 := e.scalar(`INSERT INTO src.src_mer_loop_merchant (merchant_name, merchant_type, merchant_status, booking_commission_rate)
		VALUES ('瑞幸咖啡', 'brand', 'partner', 0.1) RETURNING id`)
	m2 := e.scalar(`INSERT INTO src.src_mer_loop_merchant (merchant_name, merchant_type, merchant_status) VALUES ('隔壁面馆', 'store', 'partner') RETURNING id`)
	staff1, staff2 := e.staff(ad, "luckin-staff", m1), e.staff(ad, "noodle-staff", m2)

	// --- Campaign and drops (M-25, M-26).
	var c1 campaignView
	ad.must("POST", "/admin/v1/brand-campaigns", map[string]any{"merchant_id": m1, "title": "跑完来杯咖啡", "description": "跑步经过补给站领券",
		"start_time": now.Add(-time.Hour), "end_time": now.Add(7 * 24 * time.Hour), "store_count": 12, "target_redemptions": 10,
		"merchant_investment_amt": 2000000}, &c1)
	if c1.Status != "running" {
		t.Fatalf("campaign: %+v", c1)
	}
	sp, kp := at(300, 150), at(150, 0) // on the east and south legs of the square
	dropBody := func(typ, name string, p [2]float64, cap int, price int64, dir string, campaign *int64) map[string]any {
		ll := at(p[0], p[1])
		return map[string]any{"merchant_id": m1, "campaign_id": campaign, "type": typ, "name": name, "center": map[string]float64{"lat": ll.Lat, "lng": ll.Lng},
			"radius_m": 30, "store_name": "滨江店", "perk": map[string]any{"title": name + "券", "description": "每人每天 1 次", "value_text": "5 折", "valid_days": 7,
				"rules": "到店出示券码"}, "daily_cap": cap, "start_time": now.Add(-time.Hour), "end_time": now.Add(7 * 24 * time.Hour),
			"settle_price_amt": price, "settle_direction": dir}
	}
	var supply, chestDrop, spare dropView
	ad.must("POST", "/admin/v1/drops", dropBody("supply", "补给站 · 瑞幸滨江店", [2]float64{300, 150}, 2, 200, "merchant_pays", &c1.ID), &supply)
	ad.must("POST", "/admin/v1/drops", dropBody("chest", "宝箱 · 瑞幸", [2]float64{150, 0}, 2, 300, "platform_pays", &c1.ID), &chestDrop)
	ad.must("POST", "/admin/v1/drops", dropBody("supply", "补给站 · 远处", [2]float64{5000, 5000}, 0, 0, "merchant_pays", nil), &spare)
	if supply.Status != "active" || supply.CampaignID == nil || supply.DailyCap != 2 || supply.Perk.Title != "补给站 · 瑞幸滨江店券" {
		t.Fatalf("drop: %+v", supply)
	}
	bad := dropBody("stronghold", "据点", [2]float64{0, 0}, 0, 0, "merchant_pays", nil)
	ad.expectErr("POST", "/admin/v1/drops", bad, 400, "invalid_body") // no venue
	bad = dropBody("supply", "错商户", [2]float64{0, 0}, 0, 0, "merchant_pays", &c1.ID)
	bad["merchant_id"] = m2
	ad.expectErr("POST", "/admin/v1/drops", bad, 400, "invalid_body")
	staff1.expectErr("GET", "/admin/v1/drops", nil, 403, "forbidden")

	// Merchant chests: none at night, one per chest drop by day.
	day := clock.Today()
	if err := e.app.Perks.SpawnChests(ctx, day.Add(2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if n := e.scalar(`SELECT count(*) FROM src.src_ply_loop_chest WHERE drop_id=$1`, chestDrop.ID); n != 0 {
		t.Fatalf("chest spawned at night: %d", n)
	}
	for range 2 {
		if err := e.app.Perks.SpawnChests(ctx, day.Add(12*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	chestID := e.scalar(`SELECT id FROM src.src_ply_loop_chest WHERE drop_id=$1`, chestDrop.ID) // exactly one
	e.sql(`UPDATE src.src_ply_loop_chest SET expire_time=now() + interval '2 hours', create_time=now() - interval '1 hour' WHERE id=$1`, chestID)

	// --- A runs the square: the supply and the merchant chest give coupons.
	a, ares := e.member("13900000401")
	b, bres := e.member("13900000402")
	cc, _ := e.member("13900000403")
	d, _ := e.member("13900000404")
	square := [][2]float64{{0, 0}, {300, 0}, {300, 300}, {0, 300}, {0, 0}}
	run1 := a.perkRun("dev-a", square...)
	if len(run1.Coupons) != 2 || findCoupon(run1.Coupons, "supply").Source.DropID != supply.ID || findCoupon(run1.Coupons, "chest").Source.DropID != chestDrop.ID {
		t.Fatalf("run coupons: %+v", run1.Coupons)
	}
	if len(run1.Chests) != 1 || run1.Chests[0].ChestID != chestID || run1.Chests[0].Energy != 0 {
		t.Fatalf("merchant chest open: %+v", run1.Chests)
	}
	cSA, cKA := findCoupon(run1.Coupons, "supply"), findCoupon(run1.Coupons, "chest")
	if cSA.Status != "unused" || len(cSA.Code) != 8 || cSA.Merchant.ID != m1 || cSA.ExpiresAt.Before(now.Add(6*24*time.Hour)) {
		t.Fatalf("coupon: %+v", cSA)
	}
	type mapObjs struct {
		Supplies []struct {
			ID           int64  `json:"id"`
			PerkTitle    string `json:"perk_title"`
			ClaimedToday bool   `json:"claimed_today"`
		} `json:"supplies"`
		Chests []struct {
			ID       int64 `json:"id"`
			Merchant *struct {
				Name string `json:"name"`
			} `json:"merchant"`
		} `json:"chests"`
	}
	bbox := "/v1/map/objects?bbox=121.46,31.22,121.49,31.24"
	var objs mapObjs
	a.must("GET", bbox, nil, &objs)
	if len(objs.Supplies) != 1 || objs.Supplies[0].ID != supply.ID || !objs.Supplies[0].ClaimedToday || len(objs.Chests) != 0 {
		t.Fatalf("A map: %+v", objs)
	}
	b.must("GET", bbox, nil, &objs)
	if len(objs.Supplies) != 1 || objs.Supplies[0].ClaimedToday || len(objs.Chests) != 1 || objs.Chests[0].Merchant == nil || objs.Chests[0].Merchant.Name != "瑞幸咖啡" {
		t.Fatalf("B map: %+v", objs)
	}
	run2 := a.perkRun("dev-a", square...) // one coupon per drop per day
	if len(run2.Coupons) != 0 {
		t.Fatalf("second run coupons: %+v", run2.Coupons)
	}

	// --- Manual claim limits (B), daily cap (C).
	far := at(1000, 1000)
	b.expectErr("POST", fmt.Sprintf("/v1/drops/%d/claim", supply.ID), map[string]float64{"lat": far.Lat, "lng": far.Lng}, 400, "too_far")
	var cSB couponView
	b.must("POST", fmt.Sprintf("/v1/drops/%d/claim", supply.ID), map[string]float64{"lat": sp.Lat, "lng": sp.Lng}, &cSB)
	b.expectErr("POST", fmt.Sprintf("/v1/drops/%d/claim", supply.ID), map[string]float64{"lat": sp.Lat, "lng": sp.Lng}, 409, "already_claimed")
	cc.expectErr("POST", fmt.Sprintf("/v1/drops/%d/claim", supply.ID), map[string]float64{"lat": sp.Lat, "lng": sp.Lng}, 409, "sold_out")
	cc.expectErr("POST", fmt.Sprintf("/v1/drops/%d/claim", chestDrop.ID), map[string]float64{"lat": kp.Lat, "lng": kp.Lng}, 404, "not_found")
	cc.must("GET", bbox, nil, &objs)
	if len(objs.Supplies) != 0 {
		t.Fatalf("sold-out supply still on the map: %+v", objs.Supplies)
	}

	// --- Merchant chest opened by hand (D); the cap takes it off the map.
	var opened struct {
		Energy int         `json:"energy"`
		Coupon *couponView `json:"coupon"`
	}
	d.must("POST", fmt.Sprintf("/v1/chests/%d/open", chestID), map[string]float64{"lat": kp.Lat, "lng": kp.Lng}, &opened)
	if opened.Energy != 0 || opened.Coupon == nil || opened.Coupon.Source.Type != "chest" {
		t.Fatalf("chest open: %+v", opened)
	}
	cKD := *opened.Coupon
	cc.expectErr("POST", fmt.Sprintf("/v1/chests/%d/open", chestID), map[string]float64{"lat": kp.Lat, "lng": kp.Lng}, 409, "chest_expired")
	var dv dropView
	ad.must("GET", fmt.Sprintf("/admin/v1/drops/%d", chestDrop.ID), nil, &dv)
	if dv.IssuedToday != 2 {
		t.Fatalf("chest drop issued: %+v", dv)
	}

	// --- Campaign stats so far; pause / resume / launch cascade.
	var c2 campaignView
	ad.must("POST", "/admin/v1/brand-campaigns", map[string]any{"merchant_id": m1, "title": "周末联名", "status": "draft",
		"start_time": now.Add(24 * time.Hour), "end_time": now.Add(9 * 24 * time.Hour), "target_redemptions": 100}, &c2)
	var later dropView
	lb := dropBody("supply", "补给站 · 周末", [2]float64{6000, 6000}, 0, 0, "merchant_pays", &c2.ID)
	lb["start_time"] = now.Add(24 * time.Hour)
	ad.must("POST", "/admin/v1/drops", lb, &later)
	lp := at(6000, 6000)
	if c2.Status != "draft" || later.Status != "scheduled" {
		t.Fatalf("draft campaign %+v / drop %+v", c2, later)
	}
	cc.expectErr("POST", fmt.Sprintf("/v1/drops/%d/claim", later.ID), map[string]float64{"lat": lp.Lat, "lng": lp.Lng}, 404, "not_found")
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/brand-campaigns/%d/resume", c2.ID), nil, 409, "invalid_status")
	ad.must("POST", fmt.Sprintf("/admin/v1/brand-campaigns/%d/launch", c2.ID), nil, &c2)
	ad.must("GET", fmt.Sprintf("/admin/v1/drops/%d", later.ID), nil, &later)
	if c2.Status != "running" || !c2.StartTime.Before(time.Now()) || later.Status != "active" || len(c2.DropIDs) != 1 {
		t.Fatalf("launched: %+v / %+v", c2, later)
	}
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/brand-campaigns/%d/launch", c2.ID), nil, 409, "invalid_status")
	ad.must("POST", fmt.Sprintf("/admin/v1/brand-campaigns/%d/pause", c2.ID), nil, &c2)
	ad.must("GET", fmt.Sprintf("/admin/v1/drops/%d", later.ID), nil, &later)
	if c2.Status != "paused" || later.Status != "paused" {
		t.Fatalf("paused: %+v / %+v", c2, later)
	}
	cc.expectErr("POST", fmt.Sprintf("/v1/drops/%d/claim", later.ID), map[string]float64{"lat": lp.Lat, "lng": lp.Lng}, 404, "not_found")
	var list struct {
		Items []campaignView `json:"items"`
		Total int            `json:"total"`
	}
	ad.must("GET", "/admin/v1/brand-campaigns?status=paused", nil, &list)
	if list.Total != 1 || list.Items[0].ID != c2.ID {
		t.Fatalf("paused list: %+v", list)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/brand-campaigns/%d/resume", c2.ID), nil, &c2)
	var cCL couponView
	cc.must("POST", fmt.Sprintf("/v1/drops/%d/claim", later.ID), map[string]float64{"lat": lp.Lat, "lng": lp.Lng}, &cCL)
	// A drop paused on its own.
	ad.must("POST", fmt.Sprintf("/admin/v1/drops/%d/pause", spare.ID), nil, &spare)
	if spare.Status != "paused" {
		t.Fatalf("drop pause: %+v", spare)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/drops/%d/resume", spare.ID), nil, &spare)
	if spare.Status != "active" {
		t.Fatalf("drop resume: %+v", spare)
	}
	ad.must("PATCH", fmt.Sprintf("/admin/v1/drops/%d", spare.ID), map[string]any{"daily_cap": 5, "name": "补给站 · 远处改名"}, &spare)
	if spare.DailyCap != 5 {
		t.Fatalf("drop patch: %+v", spare)
	}

	// App list: running campaigns with their drops, no investment.
	var raw json.RawMessage
	a.must("GET", "/v1/brand-campaigns", nil, &raw)
	if strings.Contains(string(raw), "merchant_investment_amt") || !strings.Contains(string(raw), `"drops":[{`) {
		t.Fatalf("app campaigns: %s", raw)
	}
	var appList struct {
		Items []campaignView `json:"items"`
	}
	_ = json.Unmarshal(raw, &appList)
	if len(appList.Items) != 2 {
		t.Fatalf("app campaigns: %s", raw)
	}

	// --- QR and redemption checks (A-16, E-04).
	var qr struct {
		Payload      string `json:"payload"`
		ExpiresInSec int    `json:"expires_in_sec"`
	}
	a.must("GET", fmt.Sprintf("/v1/coupons/%d/qr", cSA.ID), nil, &qr)
	if !strings.HasPrefix(qr.Payload, fmt.Sprintf("LPC.%d.", cSA.ID)) || qr.ExpiresInSec != 60 {
		t.Fatalf("qr: %+v", qr)
	}
	b.expectErr("GET", fmt.Sprintf("/v1/coupons/%d/qr", cSA.ID), nil, 404, "not_found")
	staff2.expectErr("POST", "/admin/v1/redemptions", map[string]string{"payload": qr.Payload}, 403, "wrong_merchant")
	stale := e.app.Perks.QRPayload(cSA.ID, time.Now().Add(-61*time.Second))
	staff1.expectErr("POST", "/admin/v1/redemptions", map[string]string{"payload": stale}, 400, "invalid_coupon")
	staff1.expectErr("POST", "/admin/v1/redemptions", map[string]string{"payload": qr.Payload[:len(qr.Payload)-2] + "xx"}, 400, "invalid_coupon")
	staff1.expectErr("POST", "/admin/v1/redemptions", map[string]string{"code": "NOPE0000"}, 400, "invalid_coupon")
	var redA redemptionView
	staff1.must("POST", "/admin/v1/redemptions", map[string]string{"payload": qr.Payload}, &redA)
	if redA.Redemption.Coupon.Status != "used" || redA.Redemption.User.ID != ares || redA.Redemption.Store != "滨江店" {
		t.Fatalf("redemption: %+v", redA)
	}
	staff1.expectErr("POST", "/admin/v1/redemptions", map[string]string{"code": cSA.Code}, 409, "coupon_used")
	a.expectErr("GET", fmt.Sprintf("/v1/coupons/%d/qr", cSA.ID), nil, 409, "coupon_used")
	found := false
	for _, n := range a.notifications("system") {
		found = found || n.Title == "券已核销"
	}
	if !found {
		t.Fatal("no redemption notification")
	}
	// B claimed by hand and has not exercised today.
	staff1.expectErr("POST", "/admin/v1/redemptions", map[string]string{"code": cSB.Code}, 409, "no_activity_today")
	runB := b.perkRun("dev-b", [2]float64{1000, 1000}, [2]float64{1600, 1000})
	staff1.must("POST", "/admin/v1/redemptions", map[string]string{"code": strings.ToLower(cSB.Code), "store": "滨江二店"}, nil)
	// Daily cap on redemptions: D's chest coupon fits, A's does not once the cap is 1.
	d.perkRun("dev-d", [2]float64{1000, 2000}, [2]float64{1600, 2000})
	staff1.must("POST", "/admin/v1/redemptions", map[string]string{"code": cKD.Code}, nil)
	e.sql(`UPDATE src.src_mer_loop_drop SET daily_cap_qty=1 WHERE id=$1`, chestDrop.ID)
	staff1.expectErr("POST", "/admin/v1/redemptions", map[string]string{"code": cKA.Code}, 409, "daily_cap_reached")
	e.sql(`UPDATE src.src_mer_loop_drop SET daily_cap_qty=2 WHERE id=$1`, chestDrop.ID)
	// Expired (C's weekend coupon, merchant m1 as well).
	e.sql(`UPDATE src.src_mkt_loop_coupon SET expire_time=now() - interval '1 minute' WHERE id=$1`, cCL.ID)
	staff1.expectErr("POST", "/admin/v1/redemptions", map[string]string{"code": cCL.Code}, 409, "coupon_expired")
	if err := e.app.Perks.ExpireCoupons(ctx); err != nil {
		t.Fatal(err)
	}
	if ex := cc.coupons("expired"); len(ex) != 1 || ex[0].ID != cCL.ID || len(cc.coupons("unused")) != 0 {
		t.Fatalf("expired coupons: %+v", ex)
	}
	if mine := a.coupons(""); len(mine) != 2 || mine[0].Status != "unused" || mine[1].Status != "used" {
		t.Fatalf("A coupons: %+v", mine)
	}

	var reds struct {
		Items []struct {
			ID     int64  `json:"id"`
			Status string `json:"status"`
			Store  string `json:"store"`
		} `json:"items"`
		Total int `json:"total"`
	}
	staff2.must("GET", "/admin/v1/redemptions?merchant_id="+fmt.Sprint(m1), nil, &reds) // scoped to m2
	if reds.Total != 0 {
		t.Fatalf("m2 sees m1 redemptions: %+v", reds)
	}
	staff1.must("GET", "/admin/v1/redemptions", nil, &reds)
	if reds.Total != 3 || reds.Items[1].Store != "滨江二店" {
		t.Fatalf("redemptions: %+v", reds)
	}
	ad.must("GET", fmt.Sprintf("/admin/v1/brand-campaigns/%d", c1.ID), nil, &c1)
	if c1.Stats.Issued != 4 || c1.Stats.Redeemed != 3 || c1.Stats.NewUsers != 3 || c1.Stats.ProgressRate != 0.3 {
		t.Fatalf("campaign stats: %+v", c1.Stats)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/brand-campaigns/%d/pause", c1.ID), nil, &c1)
	ad.must("GET", fmt.Sprintf("/admin/v1/drops/%d", supply.ID), nil, &dv)
	if dv.Status != "paused" || dv.RedeemedToday != 2 {
		t.Fatalf("paused campaign drop: %+v", dv)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/brand-campaigns/%d/resume", c1.ID), nil, &c1)

	// --- Risk voiding: A's redemption relied on run2 (the latest).
	e.resolveVoid(ad, run2.activityID, ares)
	if st := e.scalar(`SELECT count(*) FROM src.src_mer_loop_redemption WHERE id=$1 AND redemption_status='valid' AND activity_id=$2`,
		redA.Redemption.ID, run1.activityID); st != 1 {
		t.Fatal("redemption not moved to the other activity of the day")
	}
	e.resolveVoid(ad, run1.activityID, ares)
	if st := e.scalar(`SELECT count(*) FROM src.src_mer_loop_redemption WHERE id=$1 AND redemption_status='voided'`, redA.Redemption.ID); st != 1 {
		t.Fatal("redemption not voided")
	}
	if mine := a.coupons(""); findCoupon(mine, "chest").Status != "voided" {
		t.Fatalf("A's unused coupon from the voided run: %+v", mine)
	}

	// --- Statements (M-27): move the redemptions to last week; bookings by SQL.
	lastMon := day.AddDate(0, 0, -((int(day.Weekday())+6)%7)-7)
	prevMon := lastMon.AddDate(0, 0, -7)
	e.sql(`UPDATE src.src_mer_loop_redemption SET redeem_date=$1::date + 2`, lastMon)
	venueID := e.scalar(`INSERT INTO src.src_mer_loop_venue (merchant_id, venue_name, center_geom, is_bookable, price_amt)
		VALUES ($1, '瑞幸跑步驿站', ST_SetSRID(ST_MakePoint(121.47, 31.23), 4326), true, 6000) RETURNING id`, m1)
	booking := func(no string, start time.Time, amt int, status string) {
		e.sql(`INSERT INTO src.src_ord_loop_booking (booking_no, user_id, venue_id, merchant_id, start_time, end_time, slot_qty, amount_amt, original_amt,
				booking_status, channel, paid_time) VALUES ($1,$2,$3,$4,$5,$5::timestamptz + interval '1 hour',1,$6,$6,$7,'mock',now())`,
			no, bres, venueID, m1, start, amt, status)
	}
	booking("BK1", lastMon.Add(34*time.Hour), 6000, "paid")
	booking("BK2", lastMon.Add(6*24*time.Hour+20*time.Hour), 4000, "completed")
	booking("BK3", lastMon.Add(50*time.Hour), 5000, "refunded")
	booking("BK4", lastMon.Add(7*24*time.Hour+time.Hour), 7000, "paid") // this week
	booking("BK5", prevMon.Add(30*time.Hour), 3000, "paid")
	if err := e.app.Perks.WeeklyStatements(ctx, day.AddDate(0, 0, -((int(day.Weekday())+6)%7)).Add(4*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := e.app.Perks.WeeklyStatements(ctx, time.Now()); err != nil { // once per week
		t.Fatal(err)
	}
	var sts struct {
		Items []statementView `json:"items"`
		Total int             `json:"total"`
	}
	ad.must("GET", "/admin/v1/statements", nil, &sts)
	if sts.Total != 1 {
		t.Fatalf("statements: %+v", sts)
	}
	st := sts.Items[0]
	y, w := lastMon.ISOWeek()
	// redemptions: B +200 (merchant pays), D −300 (platform pays), A voided;
	// bookings 6000 + 4000, 10 % commission → net = −100 − (10000 − 1000).
	if st.StatementNo != fmt.Sprintf("ST%dW%02d-%03d", y, w, m1) || st.PeriodStart != lastMon.Format(time.DateOnly) ||
		st.PeriodEnd != lastMon.AddDate(0, 0, 6).Format(time.DateOnly) || st.RedemptionQty != 2 || st.VoidedQty != 1 ||
		st.RedemptionAmt != 100 || st.RedemptionDirection != "platform_pays" || st.BookingQty != 2 || st.BookingAmt != 10000 ||
		st.BookingCommissionAmt != 1000 || st.NetAmt != -9100 || st.Status != "draft" {
		t.Fatalf("statement: %+v", st)
	}
	// Voiding B's run now updates the draft statement.
	e.resolveVoid(ad, runB.activityID, bres)
	ad.must("GET", fmt.Sprintf("/admin/v1/statements/%d", st.ID), nil, &st)
	if st.RedemptionQty != 1 || st.VoidedQty != 2 || st.RedemptionAmt != 300 || st.NetAmt != -9300 || len(st.Lines) != 5 {
		t.Fatalf("statement after void: %+v", st)
	}
	// Manual generation of the week before.
	ad.expectErr("POST", "/admin/v1/statements/generate", map[string]string{"period_start": prevMon.AddDate(0, 0, 1).Format(time.DateOnly)}, 400, "invalid_period")
	ad.expectErr("POST", "/admin/v1/statements/generate", map[string]string{"period_start": lastMon.AddDate(0, 0, 7).Format(time.DateOnly)}, 400, "invalid_period")
	var gen struct {
		Items []statementView `json:"items"`
	}
	ad.must("POST", "/admin/v1/statements/generate", map[string]string{"period_start": prevMon.Format(time.DateOnly)}, &gen)
	if len(gen.Items) != 1 || gen.Items[0].BookingQty != 1 || gen.Items[0].NetAmt != -2700 {
		t.Fatalf("generated: %+v", gen)
	}
	ad.expectErr("POST", "/admin/v1/statements/generate", map[string]string{"period_start": prevMon.Format(time.DateOnly)}, 409, "statement_exists")
	staff1.expectErr("POST", "/admin/v1/statements/generate", map[string]string{"period_start": prevMon.Format(time.DateOnly)}, 403, "forbidden")

	// Merchant staff read their own only; confirm / paid are admin only.
	staff1.must("GET", "/admin/v1/statements", nil, &sts)
	if sts.Total != 2 {
		t.Fatalf("staff1 statements: %+v", sts)
	}
	staff2.must("GET", "/admin/v1/statements", nil, &sts)
	if sts.Total != 0 {
		t.Fatalf("staff2 statements: %+v", sts)
	}
	staff2.expectErr("GET", fmt.Sprintf("/admin/v1/statements/%d", st.ID), nil, 404, "not_found")
	staff1.expectErr("POST", fmt.Sprintf("/admin/v1/statements/%d/confirm", st.ID), nil, 403, "forbidden")
	var dash struct {
		Todos []struct {
			Type  string `json:"type"`
			Count int    `json:"count"`
		} `json:"todos"`
	}
	ad.must("GET", "/admin/v1/dashboard", nil, &dash)
	todo := 0
	for _, x := range dash.Todos {
		if x.Type == "statement_confirm" {
			todo = x.Count
		}
	}
	if todo != 2 {
		t.Fatalf("dashboard todos: %+v", dash.Todos)
	}
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/statements/%d/paid", st.ID), nil, 409, "invalid_status")
	ad.must("POST", fmt.Sprintf("/admin/v1/statements/%d/confirm", st.ID), nil, &st)
	if st.Status != "confirmed" || st.ConfirmedBy == nil || st.ConfirmedBy.Username != "root" {
		t.Fatalf("confirmed: %+v", st)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/statements/%d/paid", st.ID), nil, &st)
	if st.Status != "paid" {
		t.Fatalf("paid: %+v", st)
	}
	var ov struct {
		Days []struct {
			Date        string `json:"date"`
			Redemptions int    `json:"redemptions"`
		} `json:"days"`
		PendingStatements int `json:"pending_statements"`
	}
	staff1.must("GET", "/admin/v1/settlement/overview?days=14", nil, &ov)
	if len(ov.Days) != 14 || ov.PendingStatements != 1 || ov.Days[13].Date != day.Format(time.DateOnly) {
		t.Fatalf("overview: %+v", ov)
	}

	// --- Stronghold: a check-in at the venue gives its coupon, and counts as
	// today's activity for redemption.
	vc := e.scalar(`SELECT id FROM src.src_mer_loop_venue WHERE id=$1`, venueID)
	var sh dropView
	sb := dropBody("stronghold", "据点 · 跑步驿站", [2]float64{0, 0}, 0, 100, "merchant_pays", nil)
	sb["venue_id"], sb["center"] = vc, nil
	// Another merchant's venue can't be used as this merchant's stronghold.
	other := map[string]any{}
	for k, v := range sb {
		other[k] = v
	}
	other["merchant_id"] = m2
	ad.expectErr("POST", "/admin/v1/drops", other, 400, "invalid_body")
	ad.must("POST", "/admin/v1/drops", sb, &sh)
	f, _ := e.member("13900000406")
	var checkin struct {
		Coupon *couponView `json:"coupon"`
	}
	f.must("POST", fmt.Sprintf("/v1/venues/%d/checkin", vc), map[string]float64{"lat": 31.23, "lng": 121.47}, &checkin)
	if checkin.Coupon == nil || checkin.Coupon.Source.Type != "stronghold" || checkin.Coupon.Source.DropID != sh.ID {
		t.Fatalf("check-in coupon: %+v", checkin)
	}
	staff1.must("POST", "/admin/v1/redemptions", map[string]string{"code": checkin.Coupon.Code}, nil)
}

func TestShopEndToEnd(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)
	u, uid := e.member("13900000501")
	v, vid := e.member("13900000502")

	run := u.perkRun("dev-u", [2]float64{0, 0}, [2]float64{300, 0}, [2]float64{300, 300}, [2]float64{0, 300}, [2]float64{0, 0})
	if len(run.Claims) == 0 {
		t.Fatalf("no territory: %+v", run)
	}
	tid := run.Claims[0].TerritoryID

	type item struct {
		Key         string `json:"key"`
		Type        string `json:"type"`
		PriceEnergy int    `json:"price_energy"`
		Owned       bool   `json:"owned"`
		Equipped    bool   `json:"equipped"`
	}
	var cat struct {
		Items  []item `json:"items"`
		Energy int    `json:"energy"`
	}
	e.sql(`UPDATE src.src_usr_loop_user SET energy=100 WHERE id=$1`, uid)
	u.must("GET", "/v1/shop/items", nil, &cat)
	if len(cat.Items) != 9 || cat.Energy != 100 {
		t.Fatalf("catalogue: %+v", cat)
	}
	u.must("GET", "/v1/shop/items?type=avatar_frame", nil, &cat)
	if len(cat.Items) != 3 {
		t.Fatalf("frames: %+v", cat)
	}
	u.expectErr("POST", "/v1/shop/items/skin_neon/buy", nil, 409, "not_enough_energy")
	u.expectErr("POST", "/v1/shop/items/skin_neon/equip", nil, 409, "not_owned")
	e.sql(`UPDATE src.src_usr_loop_user SET energy=3000 WHERE id=$1`, uid)
	var bought struct {
		Item   item `json:"item"`
		Energy int  `json:"energy"`
	}
	u.must("POST", "/v1/shop/items/skin_neon/buy", nil, &bought)
	if !bought.Item.Owned || bought.Energy != 2200 {
		t.Fatalf("bought: %+v", bought)
	}
	u.expectErr("POST", "/v1/shop/items/skin_neon/buy", nil, 409, "already_owned")
	u.expectErr("POST", "/v1/shop/items/nope/buy", nil, 404, "not_found")
	u.must("POST", "/v1/shop/items/skin_ocean/buy", nil, nil)
	u.must("POST", "/v1/shop/items/frame_gold/buy", nil, nil)
	if n := e.scalar(`SELECT count(*) FROM src.src_ply_loop_energy_ledger WHERE user_id=$1 AND reason='shop' AND delta < 0`, uid); n != 3 {
		t.Fatalf("shop ledger rows: %d", n)
	}

	var it item
	u.must("POST", "/v1/shop/items/skin_neon/equip", nil, &it)
	u.must("POST", "/v1/shop/items/frame_gold/equip", nil, &it)
	if !it.Equipped {
		t.Fatalf("equip: %+v", it)
	}
	type terr struct {
		Skin *struct {
			Key  string `json:"key"`
			Fill string `json:"fill"`
		} `json:"skin"`
	}
	var td terr
	v.must("GET", fmt.Sprintf("/v1/territories/%d", tid), nil, &td)
	if td.Skin == nil || td.Skin.Key != "skin_neon" || td.Skin.Fill != "#D9F26B" {
		t.Fatalf("territory skin: %+v", td)
	}
	var vp struct {
		Items []terr `json:"items"`
	}
	v.must("GET", "/v1/territories?bbox=121.46,31.22,121.49,31.24", nil, &vp)
	if len(vp.Items) == 0 || vp.Items[0].Skin == nil || vp.Items[0].Skin.Key != "skin_neon" {
		t.Fatalf("viewport skin: %+v", vp)
	}
	// Same type: equipping another skin takes the first off.
	u.must("POST", "/v1/shop/items/skin_ocean/equip", nil, nil)
	u.must("GET", "/v1/shop/items?type=territory_skin", nil, &cat)
	for _, x := range cat.Items {
		if x.Equipped != (x.Key == "skin_ocean") {
			t.Fatalf("one skin at a time: %+v", cat.Items)
		}
	}
	var me struct {
		Equipped struct {
			TerritorySkin *string `json:"territory_skin"`
			AvatarFrame   *string `json:"avatar_frame"`
			MapMarker     *string `json:"map_marker"`
		} `json:"equipped"`
	}
	u.must("GET", "/v1/me", nil, &me)
	if me.Equipped.TerritorySkin == nil || *me.Equipped.TerritorySkin != "skin_ocean" || me.Equipped.AvatarFrame == nil ||
		*me.Equipped.AvatarFrame != "frame_gold" || me.Equipped.MapMarker != nil {
		t.Fatalf("me equipped: %+v", me.Equipped)
	}
	u.must("DELETE", "/v1/shop/items/skin_ocean/equip", nil, &it)
	v.must("GET", fmt.Sprintf("/v1/territories/%d", tid), nil, &td)
	if it.Equipped || td.Skin != nil {
		t.Fatalf("unequipped: %+v %+v", it, td)
	}

	// avatar_frame on UserBrief: social (following list) and community (meetup creator).
	e.follow(vid, uid)
	var following struct {
		Items []struct {
			User struct {
				ID          int64   `json:"id"`
				AvatarFrame *string `json:"avatar_frame"`
			} `json:"user"`
		} `json:"items"`
	}
	v.must("GET", fmt.Sprintf("/v1/users/%d/following", vid), nil, &following)
	if len(following.Items) != 1 || following.Items[0].User.AvatarFrame == nil || *following.Items[0].User.AvatarFrame != "frame_gold" {
		t.Fatalf("following brief: %+v", following)
	}
	var mt struct {
		Creator struct {
			AvatarFrame *string `json:"avatar_frame"`
		} `json:"creator"`
	}
	u.must("POST", "/v1/meetups", meetupBody("一起跑", 500, 0, 5), &mt)
	if mt.Creator.AvatarFrame == nil || *mt.Creator.AvatarFrame != "frame_gold" {
		t.Fatalf("meetup creator brief: %+v", mt)
	}

	// Admin: stats, off-sale and limited items.
	var stats struct {
		Items []struct {
			Key         string `json:"key"`
			Redemptions int    `json:"redemptions"`
			EnergySpent int64  `json:"energy_spent"`
		} `json:"items"`
		TotalEnergySpent int64 `json:"total_energy_spent"`
	}
	ad.must("GET", "/admin/v1/shop/stats", nil, &stats)
	if stats.Items[0].Key != "skin_neon" || stats.Items[0].Redemptions != 1 || stats.Items[0].EnergySpent != 800 || stats.TotalEnergySpent != 2200 {
		t.Fatalf("shop stats: %+v", stats)
	}
	ad.must("POST", "/admin/v1/shop/items", map[string]any{"key": "frame_limited", "name": "限定头像框", "type": "avatar_frame", "price_energy": 100,
		"preview": map[string]string{"color": "#F5222D"}, "limited_until": time.Now().Add(time.Hour)}, nil)
	ad.expectErr("POST", "/admin/v1/shop/items", map[string]any{"key": "frame_limited", "name": "重复", "type": "avatar_frame", "price_energy": 1}, 409, "key_taken")
	ad.expectErr("POST", "/admin/v1/shop/items", map[string]any{"key": "Bad Key", "name": "x", "type": "avatar_frame", "price_energy": 1}, 400, "invalid_body")
	ad.must("PATCH", "/admin/v1/shop/items/skin_sunset", map[string]any{"on_sale": false}, nil)
	u.must("GET", "/v1/shop/items?type=territory_skin", nil, &cat)
	if len(cat.Items) != 2 { // sunset off sale and not owned
		t.Fatalf("off-sale item listed: %+v", cat.Items)
	}
	u.expectErr("POST", "/v1/shop/items/skin_sunset/buy", nil, 409, "item_unavailable")
	u.must("GET", "/v1/shop/items?type=avatar_frame", nil, &cat)
	if len(cat.Items) != 4 {
		t.Fatalf("limited item missing: %+v", cat.Items)
	}
}
