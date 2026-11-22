package app

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/keanying/loopland/server/internal/platform/clock"
)

// ---------------------------------------------------------------- helpers

type productView struct {
	ID       int64  `json:"id"`
	Type     string `json:"type"`
	Title    string `json:"title"`
	Status   string `json:"status"`
	Merchant struct {
		ID int64 `json:"id"`
	} `json:"merchant"`
	PriceAmt          int     `json:"price_amt"`
	StockQty          *int    `json:"stock_qty"`
	SoldQty           int     `json:"sold_qty"`
	SoldOut           *bool   `json:"sold_out"`
	ReviewNote        *string `json:"review_note"`
	HasPendingChanges *bool   `json:"has_pending_changes"`
	AllowPromotion    bool    `json:"allow_promotion"`
	Refundable        bool    `json:"refundable"`
	Promotion         *struct {
		ID            int64 `json:"id"`
		PromoPriceAmt int   `json:"promo_price_amt"`
		PromoLeftQty  *int  `json:"promo_left_qty"`
	} `json:"promotion"`
	Venues []struct {
		ID   int64  `json:"id"`
		Name string `json:"name"`
	} `json:"venues"`
	Pending *struct {
		Title string `json:"title"`
	} `json:"pending"`
	MyBoughtQty *int `json:"my_bought_qty"`
}

type productCoupon struct {
	ID     int64  `json:"id"`
	Code   string `json:"code"`
	Status string `json:"status"`
	Source struct {
		Type      string `json:"type"`
		ProductID int64  `json:"product_id"`
		OrderID   int64  `json:"order_id"`
	} `json:"source"`
	UsesTotal int `json:"uses_total"`
	UsesLeft  int `json:"uses_left"`
	Perk      struct {
		Title     string `json:"title"`
		ValueText string `json:"value_text"`
	} `json:"perk"`
}

type productOrderView struct {
	ID           int64           `json:"id"`
	OrderNo      string          `json:"order_no"`
	Qty          int             `json:"qty"`
	UnitPriceAmt int             `json:"unit_price_amt"`
	AmountAmt    int             `json:"amount_amt"`
	RefundAmt    int             `json:"refund_amt"`
	Refundable   bool            `json:"refundable"`
	Status       string          `json:"status"`
	Coupons      []productCoupon `json:"coupons"`
	Promotion    *struct {
		ID int64 `json:"id"`
	} `json:"promotion"`
	Pay *struct {
		OrderNo string `json:"order_no"`
	} `json:"pay"`
	User *struct {
		ID int64 `json:"id"`
	} `json:"user"`
}

// merchant inserts a partner merchant.
func (e *env) merchant(name string) int64 {
	return e.scalar(`INSERT INTO src.src_mer_loop_merchant (merchant_name, merchant_type, merchant_status, booking_commission_rate)
		VALUES ($1, 'venue', 'partner', 0.1) RETURNING id`, name)
}

func productBody(typ, title string, price int, extra map[string]any) map[string]any {
	b := map[string]any{"type": typ, "title": title, "subtitle": "含球拍租借", "description": "周一至周五可用", "images": []string{"https://cdn.test/p.png"},
		"sports": []string{"badminton"}, "price_amt": price, "original_amt": price + 2000, "valid_days": 30, "rules": "到店出示券码，店员扫码核销"}
	for k, v := range extra {
		b[k] = v
	}
	return b
}

// onSale creates a product as staff and submits it (low risk: on sale at once).
func (c *client) onSale(body map[string]any) productView {
	c.e.t.Helper()
	var p productView
	c.must("POST", "/admin/v1/products", body, &p)
	c.must("POST", fmt.Sprintf("/admin/v1/products/%d/submit", p.ID), nil, &p)
	if p.Status != "on_sale" {
		c.e.t.Fatalf("submitted product: %+v", p)
	}
	return p
}

// buy orders and pays (mock) a product.
func (c *client) buy(product int64, qty int) productOrderView {
	c.e.t.Helper()
	var res struct {
		Order productOrderView `json:"order"`
	}
	c.must("POST", fmt.Sprintf("/v1/products/%d/orders", product), map[string]any{"qty": qty, "channel": "mock"}, &res)
	if res.Order.Status != "pending" || res.Order.Pay == nil {
		c.e.t.Fatalf("order: %+v", res.Order)
	}
	c.must("POST", "/v1/dev/orders/"+res.Order.Pay.OrderNo+"/pay", nil, nil)
	var o productOrderView
	c.must("GET", fmt.Sprintf("/v1/product-orders/%d", res.Order.ID), nil, &o)
	if o.Status != "paid" || len(o.Coupons) != qty {
		c.e.t.Fatalf("paid order: %+v", o)
	}
	var p productView
	c.must("GET", fmt.Sprintf("/v1/products/%d", product), nil, &p)
	if o.Refundable != p.Refundable {
		c.e.t.Fatalf("order refundable %v, product %v", o.Refundable, p.Refundable)
	}
	return o
}

func productTask(e *env, product int64) int64 {
	return e.scalar(`SELECT id FROM src.src_cnt_loop_review_task WHERE target_type='product' AND target_id=$1 AND review_status='pending'`, product)
}

// ---------------------------------------------------------------- lifecycle

func TestProductLifecycleAndPermissions(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)
	m1, m2 := e.merchant("跑野运动馆"), e.merchant("滨江网球")
	s1, s2 := e.staff(ad, "pstaff1", m1), e.staff(ad, "pstaff2", m2)
	var opsRow struct {
		ID int64 `json:"id"`
	}
	ad.must("POST", "/admin/v1/admins", map[string]string{"username": "ops1", "password": "ops-password-1", "role": "ops"}, &opsRow)
	ops := e.adminLogin("ops1", "ops-password-1")
	var va venueView
	ad.must("POST", "/admin/v1/venues", venueBody("跑野 · 张江", &m1, 0, 0, true), &va)

	body := productBody("package", "羽毛球 2 小时畅打套餐", 6900, map[string]any{"venue_ids": []int64{va.ID}, "stock_qty": 200, "per_user_limit_qty": 2})
	// product.write is merchant-only; the platform reads and bans.
	ad.expectErr("POST", "/admin/v1/products", body, 403, "forbidden")
	ops.expectErr("POST", "/admin/v1/products", body, 403, "forbidden")
	s1.expectErr("POST", "/admin/v1/products", productBody("package", "x", 6900, nil), 400, "invalid_body")
	s1.expectErr("POST", "/admin/v1/products", productBody("pass", "十次卡", 6900, map[string]any{"use_qty": 1}), 400, "invalid_body")
	s1.expectErr("POST", "/admin/v1/products", productBody("package", "别家门店", 6900, map[string]any{"venue_ids": []int64{va.ID + 100}}), 400, "invalid_body")
	var p productView
	s1.must("POST", "/admin/v1/products", body, &p)
	if p.Status != "draft" || len(p.Venues) != 1 || p.Venues[0].ID != va.ID {
		t.Fatalf("created: %+v", p)
	}
	s2.expectErr("GET", fmt.Sprintf("/admin/v1/products/%d", p.ID), nil, 404, "not_found")
	s2.expectErr("PATCH", fmt.Sprintf("/admin/v1/products/%d", p.ID), map[string]any{"price_amt": 1}, 404, "not_found")
	ops.expectErr("PATCH", fmt.Sprintf("/admin/v1/products/%d", p.ID), map[string]any{"price_amt": 1}, 403, "forbidden")
	ops.expectErr("POST", fmt.Sprintf("/admin/v1/products/%d/submit", p.ID), nil, 403, "forbidden")
	s1.expectErr("POST", fmt.Sprintf("/admin/v1/products/%d/off-sale", p.ID), nil, 409, "invalid_status")
	var list struct {
		Items []productView `json:"items"`
		Total int           `json:"total"`
	}
	ops.must("GET", fmt.Sprintf("/admin/v1/products?merchant_id=%d", m1), nil, &list)
	if list.Total != 1 {
		t.Fatalf("ops list: %+v", list)
	}
	s2.must("GET", "/admin/v1/products", nil, &list)
	if list.Total != 0 {
		t.Fatalf("other merchant list: %+v", list)
	}

	// Not on sale yet: invisible in the app.
	u, _ := e.member("13800005001")
	u.expectErr("GET", fmt.Sprintf("/v1/products/%d", p.ID), nil, 404, "not_found")
	s1.must("POST", fmt.Sprintf("/admin/v1/products/%d/submit", p.ID), nil, &p)
	if p.Status != "on_sale" {
		t.Fatalf("auto approved: %+v", p)
	}
	s1.expectErr("POST", fmt.Sprintf("/admin/v1/products/%d/submit", p.ID), nil, 409, "invalid_status")
	var ap productView
	u.must("GET", fmt.Sprintf("/v1/products/%d", p.ID), nil, &ap)
	if ap.Status != "" || ap.StockQty != nil || ap.HasPendingChanges != nil || ap.SoldOut == nil || *ap.SoldOut || ap.MyBoughtQty == nil {
		t.Fatalf("app product: %+v", ap)
	}
	var vd struct {
		Products []productView `json:"products"`
	}
	u.must("GET", fmt.Sprintf("/v1/venues/%d", va.ID), nil, &vd)
	if len(vd.Products) != 1 || vd.Products[0].ID != p.ID {
		t.Fatalf("venue products: %+v", vd)
	}
	var mp struct {
		Items []productView `json:"items"`
	}
	u.must("GET", fmt.Sprintf("/v1/merchants/%d/products", m1), nil, &mp)
	if len(mp.Items) != 1 {
		t.Fatalf("merchant products: %+v", mp)
	}

	// Content change of an on-sale product: pending until reviewed (medium risk).
	s1.must("PATCH", fmt.Sprintf("/admin/v1/products/%d", p.ID), map[string]any{"title": "代跑羽毛球套餐", "price_amt": 5900}, &p)
	if p.Status != "on_sale" || p.Title != "羽毛球 2 小时畅打套餐" || p.HasPendingChanges == nil || !*p.HasPendingChanges || p.PriceAmt != 5900 {
		t.Fatalf("pending change: %+v", p)
	}
	var detail productView
	s1.must("GET", fmt.Sprintf("/admin/v1/products/%d", p.ID), nil, &detail)
	if detail.Pending == nil || detail.Pending.Title != "代跑羽毛球套餐" {
		t.Fatalf("detail pending: %+v", detail)
	}
	u.must("GET", fmt.Sprintf("/v1/products/%d", p.ID), nil, &ap)
	if ap.Title != "羽毛球 2 小时畅打套餐" || ap.PriceAmt != 5900 {
		t.Fatalf("app keeps old content: %+v", ap)
	}
	var dash struct {
		Todos []struct {
			Type  string `json:"type"`
			Count int    `json:"count"`
		} `json:"todos"`
	}
	ad.must("GET", "/admin/v1/dashboard", nil, &dash)
	found := false
	for _, td := range dash.Todos {
		found = found || (td.Type == "product_review" && td.Count == 1)
	}
	if !found {
		t.Fatalf("dashboard todos: %+v", dash)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/reject", productTask(e, p.ID)), map[string]string{"reason": "标题含违规词"}, nil)
	s1.must("GET", fmt.Sprintf("/admin/v1/products/%d", p.ID), nil, &detail)
	if detail.Status != "on_sale" || detail.Pending != nil || detail.Title != "羽毛球 2 小时畅打套餐" || detail.ReviewNote == nil || *detail.ReviewNote != "标题含违规词" {
		t.Fatalf("rejected pending: %+v", detail)
	}
	s1.must("PATCH", fmt.Sprintf("/admin/v1/products/%d", p.ID), map[string]any{"title": "代跑羽毛球周末套餐"}, nil)
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/approve", productTask(e, p.ID)), nil, nil)
	s1.must("GET", fmt.Sprintf("/admin/v1/products/%d", p.ID), nil, &detail)
	if detail.Title != "代跑羽毛球周末套餐" || detail.Pending != nil || detail.Status != "on_sale" {
		t.Fatalf("approved pending: %+v", detail)
	}

	// Off sale and back without review; ban by ops; resubmit.
	s1.must("POST", fmt.Sprintf("/admin/v1/products/%d/off-sale", p.ID), nil, &p)
	u.expectErr("GET", fmt.Sprintf("/v1/products/%d", p.ID), nil, 404, "not_found")
	s1.must("POST", fmt.Sprintf("/admin/v1/products/%d/on-sale", p.ID), nil, &p)
	if p.Status != "on_sale" {
		t.Fatalf("back on sale: %+v", p)
	}
	ops.expectErr("POST", fmt.Sprintf("/admin/v1/products/%d/ban", p.ID), map[string]string{"reason": ""}, 400, "invalid_body")
	s1.expectErr("POST", fmt.Sprintf("/admin/v1/products/%d/ban", p.ID), map[string]string{"reason": "x"}, 403, "forbidden")
	ops.must("POST", fmt.Sprintf("/admin/v1/products/%d/ban", p.ID), map[string]string{"reason": "虚假宣传"}, &p)
	if p.Status != "banned" || p.ReviewNote == nil || *p.ReviewNote != "虚假宣传" {
		t.Fatalf("banned: %+v", p)
	}
	s1.expectErr("POST", fmt.Sprintf("/admin/v1/products/%d/on-sale", p.ID), nil, 409, "invalid_status")
	u.expectErr("GET", fmt.Sprintf("/v1/products/%d", p.ID), nil, 404, "not_found")
	s1.must("PATCH", fmt.Sprintf("/admin/v1/products/%d", p.ID), map[string]any{"title": "羽毛球 2 小时套餐（新）"}, nil)
	s1.must("POST", fmt.Sprintf("/admin/v1/products/%d/submit", p.ID), nil, &p)
	if p.Status != "on_sale" || p.ReviewNote != nil {
		t.Fatalf("resubmitted: %+v", p)
	}

	// High risk is rejected automatically with the reason.
	var bad productView
	s1.must("POST", "/admin/v1/products", productBody("voucher", "代开发票 100 元代金券", 9000, nil), &bad)
	s1.must("POST", fmt.Sprintf("/admin/v1/products/%d/submit", bad.ID), nil, &bad)
	if bad.Status != "rejected" || bad.ReviewNote == nil {
		t.Fatalf("auto rejected: %+v", bad)
	}
	// Medium risk waits for a reviewer.
	var mid productView
	s1.must("POST", "/admin/v1/products", productBody("package", "代跑陪练体验课", 9000, nil), &mid)
	s1.must("POST", fmt.Sprintf("/admin/v1/products/%d/submit", mid.ID), nil, &mid)
	if mid.Status != "reviewing" {
		t.Fatalf("reviewing: %+v", mid)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/approve", productTask(e, mid.ID)), nil, nil)
	s1.must("GET", fmt.Sprintf("/admin/v1/products/%d", mid.ID), nil, &mid)
	if mid.Status != "on_sale" {
		t.Fatalf("approved: %+v", mid)
	}

	// Delete: never sold → gone; sold → archived (hidden, coupons stay).
	if st := s1.do("DELETE", fmt.Sprintf("/admin/v1/products/%d", bad.ID), nil, nil); st != 204 {
		t.Fatalf("delete: %d", st)
	}
	s1.expectErr("GET", fmt.Sprintf("/admin/v1/products/%d", bad.ID), nil, 404, "not_found")
	o := u.buy(mid.ID, 1)
	if st := s1.do("DELETE", fmt.Sprintf("/admin/v1/products/%d", mid.ID), nil, nil); st != 204 {
		t.Fatalf("delete sold: %d", st)
	}
	if n := e.scalar(`SELECT count(*) FROM src.src_mer_loop_product WHERE id=$1 AND is_archived`, mid.ID); n != 1 {
		t.Fatal("sold product should be archived")
	}
	s1.must("GET", "/admin/v1/products", nil, &list)
	for _, x := range list.Items {
		if x.ID == mid.ID {
			t.Fatal("archived product listed")
		}
	}
	var r struct {
		Redemption struct {
			ID int64 `json:"id"`
		} `json:"redemption"`
	}
	s1.must("POST", "/admin/v1/redemptions", map[string]string{"code": o.Coupons[0].Code}, &r)

	// Audit trail.
	if n := e.scalar(`SELECT count(*) FROM src.src_sys_loop_audit_log WHERE action LIKE 'product.%'`); n < 10 {
		t.Fatalf("audit rows: %d", n)
	}
	// Commission rate is admin-only.
	ops.expectErr("PATCH", fmt.Sprintf("/admin/v1/merchants/%d", m1), map[string]any{"product_commission_rate": 0.05}, 403, "forbidden")
	var mv struct {
		ProductCommissionRate float64 `json:"product_commission_rate"`
	}
	ad.must("PATCH", fmt.Sprintf("/admin/v1/merchants/%d", m1), map[string]any{"product_commission_rate": 0.05}, &mv)
	if mv.ProductCommissionRate != 0.05 {
		t.Fatalf("commission: %+v", mv)
	}
}

// ---------------------------------------------------------------- purchase, redemption, refunds, statement

func TestProductPurchaseRedeemRefundStatement(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	ad := adminClient(t, e)
	m1, m2 := e.merchant("跑野运动馆"), e.merchant("滨江网球")
	s1, s2 := e.staff(ad, "pstaff1", m1), e.staff(ad, "pstaff2", m2)
	var va, vb venueView
	ad.must("POST", "/admin/v1/venues", venueBody("跑野 · 张江", &m1, 0, 0, true), &va)
	ad.must("POST", "/admin/v1/venues", venueBody("跑野 · 世纪公园", &m1, 1000, 0, true), &vb)
	pkg := s1.onSale(productBody("package", "羽毛球 2 小时畅打套餐", 6900, map[string]any{"venue_ids": []int64{va.ID}, "stock_qty": 5,
		"per_user_limit_qty": 3}))
	pass := s1.onSale(productBody("pass", "游泳三次卡", 9000, map[string]any{"use_qty": 3}))
	fixed := s1.onSale(productBody("voucher", "100 元代金券", 8000, map[string]any{"original_amt": 10000, "refundable": false}))

	u, _ := e.member("13800005101")
	u.expectErr("POST", fmt.Sprintf("/v1/products/%d/orders", pkg.ID), map[string]any{"qty": 11, "channel": "mock"}, 400, "invalid_request")
	u.expectErr("POST", fmt.Sprintf("/v1/products/%d/orders", pkg.ID), map[string]any{"qty": 1, "channel": "apple_iap"}, 400, "channel_not_allowed")
	u.expectErr("POST", fmt.Sprintf("/v1/products/%d/orders", pkg.ID), map[string]any{"qty": 6, "channel": "mock"}, 409, "limit_reached")
	o := u.buy(pkg.ID, 2)
	if o.AmountAmt != 13800 || o.Coupons[0].Source.Type != "product" || o.Coupons[0].Source.OrderID != o.ID || o.Coupons[0].UsesTotal != 1 ||
		o.Coupons[0].Perk.Title != "羽毛球 2 小时畅打套餐" {
		t.Fatalf("order: %+v", o)
	}
	u.expectErr("POST", fmt.Sprintf("/v1/products/%d/orders", pkg.ID), map[string]any{"qty": 2, "channel": "mock"}, 409, "limit_reached")
	// Stock: 5 − 2 sold; a second buyer locks 3, a third finds it sold out.
	u2, _ := e.member("13800005102")
	var pend struct {
		Order productOrderView `json:"order"`
	}
	u2.must("POST", fmt.Sprintf("/v1/products/%d/orders", pkg.ID), map[string]any{"qty": 3, "channel": "mock"}, &pend)
	u3, _ := e.member("13800005103")
	u3.expectErr("POST", fmt.Sprintf("/v1/products/%d/orders", pkg.ID), map[string]any{"qty": 1, "channel": "mock"}, 409, "sold_out")
	var ap productView
	u3.must("GET", fmt.Sprintf("/v1/products/%d", pkg.ID), nil, &ap)
	if ap.SoldOut == nil || !*ap.SoldOut || ap.SoldQty != 2 {
		t.Fatalf("sold out view: %+v", ap)
	}
	// Cancelling (or the 15-minute expiry) releases the stock.
	u2.must("POST", fmt.Sprintf("/v1/product-orders/%d/cancel", pend.Order.ID), nil, &pend.Order)
	if pend.Order.Status != "cancelled" {
		t.Fatalf("cancelled: %+v", pend.Order)
	}
	u2.expectErr("POST", fmt.Sprintf("/v1/product-orders/%d/pay", pend.Order.ID), nil, 409, "invalid_status")
	var exp struct {
		Order productOrderView `json:"order"`
	}
	u3.must("POST", fmt.Sprintf("/v1/products/%d/orders", pkg.ID), map[string]any{"qty": 1, "channel": "mock"}, &exp)
	u3.must("POST", fmt.Sprintf("/v1/product-orders/%d/pay", exp.Order.ID), nil, nil)
	e.sql(`UPDATE src.src_ord_loop_product_order SET pay_expire_time=now() - interval '1 minute' WHERE id=$1`, exp.Order.ID)
	e.job("product_order_expire")
	u3.must("GET", fmt.Sprintf("/v1/product-orders/%d", exp.Order.ID), nil, &exp.Order)
	if exp.Order.Status != "cancelled" || e.orderStatus(exp.Order.Pay.OrderNo) != "closed" {
		t.Fatalf("expired: %+v", exp.Order)
	}
	if n := e.scalar(`SELECT stock_qty FROM src.src_mer_loop_product WHERE id=$1`, pkg.ID); n != 3 {
		t.Fatalf("stock after release: %d", n)
	}
	// Paying an expired order refunds it at once.
	u3.must("POST", "/v1/dev/orders/"+exp.Order.Pay.OrderNo+"/pay", nil, nil)
	if st := e.orderStatus(exp.Order.Pay.OrderNo); st != "refunded" {
		t.Fatalf("late payment: %s", st)
	}

	// Redemption: no activity needed; store checked against the venues.
	s2.expectErr("POST", "/admin/v1/redemptions", map[string]string{"code": o.Coupons[0].Code}, 403, "wrong_merchant")
	s1.expectErr("POST", "/admin/v1/redemptions", map[string]string{"code": o.Coupons[0].Code, "store": "跑野 · 世纪公园"}, 403, "wrong_store")
	var rd struct {
		Redemption struct {
			ID         int64  `json:"id"`
			Store      string `json:"store"`
			ActivityID *int64 `json:"activity_id"`
			Coupon     productCoupon
		} `json:"redemption"`
	}
	s1.must("POST", "/admin/v1/redemptions", map[string]string{"code": o.Coupons[0].Code}, &rd)
	if rd.Redemption.Store != "跑野 · 张江" || rd.Redemption.ActivityID != nil {
		t.Fatalf("redemption: %+v", rd)
	}
	s1.expectErr("POST", "/admin/v1/redemptions", map[string]string{"code": o.Coupons[0].Code}, 409, "coupon_used")

	// User refund: the unused coupon only.
	u.must("POST", fmt.Sprintf("/v1/product-orders/%d/refund", o.ID), nil, &o)
	if o.RefundAmt != 6900 || o.Status != "completed" {
		t.Fatalf("refund: %+v", o)
	}
	u.expectErr("POST", fmt.Sprintf("/v1/product-orders/%d/refund", o.ID), nil, 409, "nothing_to_refund")
	var cs struct {
		Items []productCoupon `json:"items"`
	}
	u.must("GET", "/v1/me/coupons?status=refunded", nil, &cs)
	if len(cs.Items) != 1 || cs.Items[0].Status != "refunded" {
		t.Fatalf("refunded coupons: %+v", cs)
	}
	u.expectErr("GET", fmt.Sprintf("/v1/coupons/%d/qr", cs.Items[0].ID), nil, 409, "coupon_refunded")
	s1.expectErr("POST", "/admin/v1/redemptions", map[string]string{"code": cs.Items[0].Code}, 400, "invalid_coupon")
	if st := e.orderStatus(o.Pay.OrderNo); st != "paid" {
		t.Fatalf("partially refunded payment order: %s", st)
	}
	// The generic order refund refuses product orders (would refund used coupons).
	ad.expectErr("POST", "/admin/v1/orders/"+o.Pay.OrderNo+"/refund", map[string]any{"reason": "x", "confirm": true}, 409, "use_product_refund")

	// Pass: three uses, one redemption each (scanning the QR code).
	po := u.buy(pass.ID, 1)
	c := po.Coupons[0]
	if c.UsesTotal != 3 || c.UsesLeft != 3 || c.Perk.ValueText != "¥90 · 3 次" {
		t.Fatalf("pass coupon: %+v", c)
	}
	for i := 2; i >= 0; i-- {
		var q struct {
			Payload string `json:"payload"`
		}
		u.must("GET", fmt.Sprintf("/v1/coupons/%d/qr", c.ID), nil, &q)
		s1.must("POST", "/admin/v1/redemptions", map[string]string{"payload": q.Payload}, &rd)
		if rd.Redemption.Coupon.UsesLeft != i {
			t.Fatalf("pass use: %+v", rd.Redemption.Coupon)
		}
	}
	if rd.Redemption.Coupon.Status != "used" {
		t.Fatalf("pass used up: %+v", rd.Redemption.Coupon)
	}
	s1.expectErr("POST", "/admin/v1/redemptions", map[string]string{"code": c.Code}, 409, "coupon_used")
	if n := e.scalar(`SELECT count(*) FROM src.src_mer_loop_redemption WHERE coupon_id=$1`, c.ID); n != 3 {
		t.Fatalf("pass redemptions: %d", n)
	}
	u.must("GET", fmt.Sprintf("/v1/product-orders/%d", po.ID), nil, &po)
	if po.Status != "completed" {
		t.Fatalf("pass order: %+v", po)
	}

	// Not refundable: user refund refused; admin refund allowed.
	fo := u.buy(fixed.ID, 1)
	u.expectErr("POST", fmt.Sprintf("/v1/product-orders/%d/refund", fo.ID), nil, 409, "not_refundable")
	s1.expectErr("POST", fmt.Sprintf("/admin/v1/product-orders/%d/refund", fo.ID), map[string]string{"reason": "x"}, 403, "forbidden")
	ad.must("POST", fmt.Sprintf("/admin/v1/product-orders/%d/refund", fo.ID), map[string]string{"reason": "客诉"}, &fo)
	if fo.Status != "refunded" || fo.RefundAmt != 8000 || e.orderStatus(fo.Pay.OrderNo) != "refunded" {
		t.Fatalf("admin refund: %+v", fo)
	}

	// Expired unused refundable coupons are refunded by the 02:00 job.
	eo := u.buy(pkg.ID, 1)
	e.sql(`UPDATE src.src_mkt_loop_coupon SET expire_time=now() - interval '1 hour' WHERE product_order_id=$1`, eo.ID)
	e.job("coupon_expire")                                                                         // leaves refundable product coupons for the refund
	if err := e.app.Products.DailyAutoRefund(ctx, clock.Today().Add(90*time.Minute)); err != nil { // before 02:00: nothing
		t.Fatal(err)
	}
	if err := e.app.Products.DailyAutoRefund(ctx, clock.Today().Add(2*time.Hour+time.Minute)); err != nil {
		t.Fatal(err)
	}
	u.must("GET", fmt.Sprintf("/v1/product-orders/%d", eo.ID), nil, &eo)
	if eo.Status != "refunded" || eo.Coupons[0].Status != "refunded" {
		t.Fatalf("auto refund: %+v", eo)
	}
	// Expired non-refundable coupons just expire and complete the order.
	nf := u.buy(fixed.ID, 1)
	e.sql(`UPDATE src.src_mkt_loop_coupon SET expire_time=now() - interval '1 hour' WHERE product_order_id=$1`, nf.ID)
	e.job("coupon_expire")
	e.job("product_order_sync")
	u.must("GET", fmt.Sprintf("/v1/product-orders/%d", nf.ID), nil, &nf)
	if nf.Status != "completed" || nf.Coupons[0].Status != "expired" {
		t.Fatalf("expired non-refundable: %+v", nf)
	}

	// Admin list with the user; merchant staff see their own.
	var orders struct {
		Items []productOrderView `json:"items"`
		Total int                `json:"total"`
	}
	s1.must("GET", "/admin/v1/product-orders", nil, &orders)
	if orders.Total < 6 || orders.Items[0].User == nil {
		t.Fatalf("admin orders: %+v", orders)
	}
	s2.must("GET", "/admin/v1/product-orders", nil, &orders)
	if orders.Total != 0 {
		t.Fatalf("other merchant orders: %+v", orders)
	}

	// Statement: move the product redemptions to last week and generate.
	day := clock.Today()
	lastMon := day.AddDate(0, 0, -((int(day.Weekday())+6)%7)-7)
	e.sql(`UPDATE src.src_mer_loop_redemption SET redeem_date=$1::date + 1, create_time=$1::date + interval '30 hours'`, lastMon)
	var gen struct {
		Items []statementView `json:"items"`
	}
	ad.must("POST", "/admin/v1/statements/generate", map[string]string{"period_start": lastMon.Format(time.DateOnly)}, &gen)
	if len(gen.Items) != 1 {
		t.Fatalf("generated: %+v", gen)
	}
	var st struct {
		statementView
		ProductQty           int   `json:"product_qty"`
		ProductAmt           int64 `json:"product_amt"`
		ProductCommissionAmt int64 `json:"product_commission_amt"`
		ProductSubsidyAmt    int64 `json:"product_subsidy_amt"`
	}
	s1.must("GET", fmt.Sprintf("/admin/v1/statements/%d", gen.Items[0].ID), nil, &st)
	// package 6900 + pass 3 × round(9000 / 3) = 15900; 8 % commission = 1272.
	if st.ProductQty != 4 || st.ProductAmt != 15900 || st.ProductCommissionAmt != 1272 || st.ProductSubsidyAmt != 0 || st.RedemptionQty != 0 ||
		st.NetAmt != -(15900-1272) || len(st.Lines) != 4 || st.Lines[0].Type != "product" {
		t.Fatalf("statement: %+v", st)
	}
}
