package app

import (
	"fmt"
	"testing"
	"time"

	"github.com/keanying/loopland/server/internal/platform/clock"
)

type promotionView struct {
	ID         int64  `json:"id"`
	Title      string `json:"title"`
	Status     string `json:"status"`
	ApplyOpen  bool   `json:"apply_open"`
	ProductQty int    `json:"product_qty"`
	Items      []productView
}

type entryView struct {
	ID                 int64  `json:"id"`
	PromotionID        int64  `json:"promotion_id"`
	Status             string `json:"status"`
	Source             string `json:"source"`
	PromoPriceAmt      int    `json:"promo_price_amt"`
	PlatformSubsidyAmt int    `json:"platform_subsidy_amt"`
	PromoSoldQty       int    `json:"promo_sold_qty"`
	Note               string `json:"note"`
	Promotion          struct {
		ID    int64  `json:"id"`
		Title string `json:"title"`
	} `json:"promotion"`
	Product struct {
		ID int64 `json:"id"`
	} `json:"product"`
}

func TestPromotions(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)
	m1, m2 := e.merchant("跑野运动馆"), e.merchant("滨江网球")
	s1, s2 := e.staff(ad, "pstaff1", m1), e.staff(ad, "pstaff2", m2)
	plain := s1.onSale(productBody("package", "羽毛球 2 小时畅打套餐", 6900, nil))
	authorised := s1.onSale(productBody("package", "游泳单次票", 6900, map[string]any{"allow_promotion": true}))

	now := time.Now()
	promoBody := map[string]any{"title": "双 12 运动狂欢", "subtitle": "羽毛球、游泳 5 折起", "banner_url": "https://cdn.test/b.png",
		"description": "活动说明", "starts_at": now.Add(-time.Hour), "ends_at": now.AddDate(0, 0, 7), "apply_open": true,
		"apply_deadline": now.AddDate(0, 0, 3)}
	s1.expectErr("POST", "/admin/v1/promotions", promoBody, 403, "forbidden")
	var pr promotionView
	ad.must("POST", "/admin/v1/promotions", promoBody, &pr)
	if pr.Status != "draft" {
		t.Fatalf("promotion: %+v", pr)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/promotions/%d/publish", pr.ID), nil, &pr)
	if pr.Status != "active" {
		t.Fatalf("published: %+v", pr)
	}
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/promotions/%d/publish", pr.ID), nil, 409, "invalid_status")
	var allowed struct {
		Items []productView `json:"items"`
	}
	ad.must("GET", "/admin/v1/products?allow_promotion=true", nil, &allowed)
	if len(allowed.Items) != 1 || allowed.Items[0].ID != authorised.ID {
		t.Fatalf("authorised products: %+v", allowed)
	}

	// Platform pick: authorised products only; a lower price waits for the merchant.
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/promotions/%d/entries", pr.ID), map[string]any{"product_id": plain.ID, "promo_price_amt": 4900}, 409, "not_authorized")
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/promotions/%d/entries", pr.ID), map[string]any{"product_id": authorised.ID, "promo_price_amt": 7000}, 400, "invalid_body")
	var en entryView
	ad.must("POST", fmt.Sprintf("/admin/v1/promotions/%d/entries", pr.ID), map[string]any{"product_id": authorised.ID, "promo_price_amt": 4900,
		"platform_subsidy_amt": 500, "promo_stock_qty": 3, "sort_no": 1}, &en)
	if en.Status != "pending_merchant" || en.Source != "platform" {
		t.Fatalf("pick: %+v", en)
	}
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/promotions/%d/entries", pr.ID), map[string]any{"product_id": authorised.ID}, 409, "entry_exists")
	u, _ := e.member("13800005201")
	var ap productView
	u.must("GET", fmt.Sprintf("/v1/products/%d", authorised.ID), nil, &ap)
	if ap.Promotion != nil {
		t.Fatalf("not yet accepted: %+v", ap)
	}
	var mine struct {
		Items []entryView `json:"items"`
	}
	s1.must("GET", "/admin/v1/promotion-entries?status=pending_merchant", nil, &mine)
	if len(mine.Items) != 1 || mine.Items[0].ID != en.ID || mine.Items[0].Promotion.ID != en.PromotionID || mine.Items[0].Promotion.Title == "" {
		t.Fatalf("invitations: %+v", mine)
	}
	s2.expectErr("POST", fmt.Sprintf("/admin/v1/promotion-entries/%d/accept", en.ID), nil, 404, "not_found")
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/promotion-entries/%d/accept", en.ID), nil, 403, "forbidden")
	s1.must("POST", fmt.Sprintf("/admin/v1/promotion-entries/%d/accept", en.ID), nil, &en)
	if en.Status != "active" {
		t.Fatalf("accepted: %+v", en)
	}

	// The app shows and sells at the promotion price.
	u.must("GET", fmt.Sprintf("/v1/products/%d", authorised.ID), nil, &ap)
	if ap.Promotion == nil || ap.Promotion.ID != pr.ID || ap.Promotion.PromoPriceAmt != 4900 || ap.Promotion.PromoLeftQty == nil || *ap.Promotion.PromoLeftQty != 3 {
		t.Fatalf("promotion price: %+v", ap)
	}
	var appList struct {
		Items []promotionView `json:"items"`
	}
	u.must("GET", "/v1/promotions", nil, &appList)
	if len(appList.Items) != 1 || appList.Items[0].ProductQty != 1 {
		t.Fatalf("app promotions: %+v", appList)
	}
	var appPromo struct {
		promotionView
		Items []productView `json:"items"`
	}
	u.must("GET", fmt.Sprintf("/v1/promotions/%d", pr.ID), nil, &appPromo)
	if len(appPromo.Items) != 1 || appPromo.Items[0].Promotion == nil || appPromo.Items[0].Promotion.PromoPriceAmt != 4900 {
		t.Fatalf("app promotion: %+v", appPromo)
	}
	o := u.buy(authorised.ID, 1)
	if o.UnitPriceAmt != 4900 || o.Promotion == nil || o.Promotion.ID != pr.ID {
		t.Fatalf("promo order: %+v", o)
	}
	u2, _ := e.member("13800005202")
	u2.expectErr("POST", fmt.Sprintf("/v1/products/%d/orders", authorised.ID), map[string]any{"qty": 3, "channel": "mock"}, 409, "sold_out")
	u2.buy(authorised.ID, 2) // promotion stock used up
	u2.must("GET", fmt.Sprintf("/v1/products/%d", authorised.ID), nil, &ap)
	if ap.Promotion != nil {
		t.Fatalf("promotion stock used up: %+v", ap)
	}
	if full := u2.buy(authorised.ID, 1); full.UnitPriceAmt != 6900 || full.Promotion != nil {
		t.Fatalf("after promotion stock: %+v", full)
	}

	// One active promotion price at a time.
	var pr2 promotionView
	b2 := map[string]any{"title": "周末专场", "starts_at": now, "ends_at": now.AddDate(0, 0, 2)}
	ad.must("POST", "/admin/v1/promotions", b2, &pr2)
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/promotions/%d/entries", pr2.ID), map[string]any{"product_id": authorised.ID}, 409, "promotion_conflict")

	// Merchant application (no authorisation needed) and platform review.
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/promotions/%d/apply", pr.ID), map[string]any{"product_id": plain.ID}, 403, "forbidden")
	s1.expectErr("POST", fmt.Sprintf("/admin/v1/promotions/%d/apply", pr2.ID), map[string]any{"product_id": plain.ID}, 404, "not_found") // draft
	var open struct {
		Items []promotionView `json:"items"`
	}
	s1.must("GET", "/admin/v1/promotions?apply_open=true", nil, &open)
	if len(open.Items) != 1 || open.Items[0].ID != pr.ID {
		t.Fatalf("open promotions: %+v", open)
	}
	var app entryView
	s1.must("POST", fmt.Sprintf("/admin/v1/promotions/%d/apply", pr.ID), map[string]any{"product_id": plain.ID, "promo_price_amt": 5000}, &app)
	if app.Status != "pending_platform" || app.Source != "merchant" {
		t.Fatalf("application: %+v", app)
	}
	var dash struct {
		Todos []struct {
			Type string `json:"type"`
		} `json:"todos"`
	}
	ad.must("GET", "/admin/v1/dashboard", nil, &dash)
	found := false
	for _, td := range dash.Todos {
		found = found || td.Type == "promotion_apply"
	}
	if !found {
		t.Fatalf("dashboard: %+v", dash)
	}
	s1.expectErr("POST", fmt.Sprintf("/admin/v1/promotion-entries/%d/approve", app.ID), nil, 403, "forbidden")
	ad.must("POST", fmt.Sprintf("/admin/v1/promotion-entries/%d/approve", app.ID), map[string]any{"platform_subsidy_amt": 300}, &app)
	if app.Status != "active" || app.PlatformSubsidyAmt != 300 {
		t.Fatalf("approved: %+v", app)
	}
	ad.must("PATCH", fmt.Sprintf("/admin/v1/promotion-entries/%d", app.ID), map[string]any{"sort_no": 5}, nil)
	var list struct {
		Items []entryView `json:"items"`
	}
	ad.must("GET", fmt.Sprintf("/admin/v1/promotions/%d/entries?status=active", pr.ID), nil, &list)
	if len(list.Items) != 2 || list.Items[0].ID != en.ID {
		t.Fatalf("entries: %+v", list)
	}
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/promotion-entries/%d/remove", app.ID), map[string]any{}, 400, "invalid_body")
	ad.must("POST", fmt.Sprintf("/admin/v1/promotion-entries/%d/remove", app.ID), map[string]any{"note": "价格不符"}, &app)
	if app.Status != "removed" || app.Note != "价格不符" {
		t.Fatalf("removed: %+v", app)
	}
	s1.must("POST", fmt.Sprintf("/admin/v1/promotion-entries/%d/withdraw", en.ID), nil, &en)
	if en.Status != "withdrawn" {
		t.Fatalf("withdrawn: %+v", en)
	}

	// Subsidy goes into the statement, per redemption.
	s1.must("POST", "/admin/v1/redemptions", map[string]string{"code": o.Coupons[0].Code}, nil)
	day := clock.Today()
	lastMon := day.AddDate(0, 0, -((int(day.Weekday())+6)%7)-7)
	e.sql(`UPDATE src.src_mer_loop_redemption SET redeem_date=$1::date + 1`, lastMon)
	var gen struct {
		Items []struct {
			ID                   int64 `json:"id"`
			ProductQty           int   `json:"product_qty"`
			ProductAmt           int64 `json:"product_amt"`
			ProductCommissionAmt int64 `json:"product_commission_amt"`
			ProductSubsidyAmt    int64 `json:"product_subsidy_amt"`
			NetAmt               int64 `json:"net_amt"`
		} `json:"items"`
	}
	ad.must("POST", "/admin/v1/statements/generate", map[string]string{"period_start": lastMon.Format(time.DateOnly)}, &gen)
	if len(gen.Items) != 1 {
		t.Fatalf("statements: %+v", gen)
	}
	g := gen.Items[0]
	if g.ProductQty != 1 || g.ProductAmt != 4900 || g.ProductCommissionAmt != 392 || g.ProductSubsidyAmt != 500 || g.NetAmt != -(4900-392)-500 {
		t.Fatalf("statement: %+v", g)
	}

	// Cancelled promotions disappear from the app.
	ad.must("POST", fmt.Sprintf("/admin/v1/promotions/%d/cancel", pr.ID), nil, &pr)
	u.must("GET", "/v1/promotions", nil, &appList)
	if pr.Status != "cancelled" || len(appList.Items) != 0 {
		t.Fatalf("cancelled: %+v %+v", pr, appList)
	}
}
