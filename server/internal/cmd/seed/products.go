package seed

import (
	"fmt"
	"log"
	"time"
)

// seedProducts adds V2 batch 5 data: the gym merchant's staff account (from
// seedVenues) puts one product of each type on sale (two authorised for
// official promotions), the platform runs an active promotion with one
// entry at the product price and one invitation the merchant accepts, and
// a user buys a product through the mock channel. No open platform app is
// created (secrets are only shown when a merchant creates one).
func seedProducts(users []*client, ad *client) {
	staff := &client{}
	var login struct {
		Token string `json:"token"`
	}
	staff.do("POST", "/admin/v1/login", map[string]string{"username": "gym-staff", "password": "gym-staff-pass-1"}, &login)
	if login.Token == "" {
		log.Print("merchant staff login failed; skipping product seed data")
		return
	}
	staff.token = login.Token
	var venues struct {
		Items []struct {
			ID int64 `json:"id"`
		} `json:"items"`
	}
	staff.do("GET", "/admin/v1/venues", nil, &venues)
	venueIDs := []int64{}
	if len(venues.Items) > 0 {
		venueIDs = append(venueIDs, venues.Items[0].ID)
	}
	type product struct {
		ID       int64 `json:"id"`
		PriceAmt int   `json:"price_amt"`
	}
	create := func(body map[string]any) product {
		var p product
		staff.do("POST", "/admin/v1/products", body, &p)
		if p.ID != 0 {
			staff.do("POST", fmt.Sprintf("/admin/v1/products/%d/submit", p.ID), nil, &p)
		}
		return p
	}
	images := []string{"https://picsum.photos/seed/loopland-badminton/800/600"}
	pkg := create(map[string]any{"type": "package", "title": "羽毛球 2 小时畅打套餐", "subtitle": "含球拍租借", "description": "周一至周五 9:00–18:00 可用，节假日通用",
		"images": images, "sports": []string{"badminton"}, "price_amt": 6900, "original_amt": 9000, "valid_days": 30, "stock_qty": 200,
		"per_user_limit_qty": 2, "venue_ids": venueIDs, "allow_promotion": true, "rules": "到店出示券码，店员扫码核销；每次限 1 人使用"})
	voucher := create(map[string]any{"type": "voucher", "title": "100 元运动代金券", "subtitle": "订场、租拍通用", "description": "单笔消费满 150 元可用",
		"images": images, "sports": []string{"badminton", "pickleball"}, "price_amt": 8000, "original_amt": 10000, "valid_days": 90,
		"allow_promotion": true, "rules": "到店出示券码，店员扫码核销；不找零"})
	pass := create(map[string]any{"type": "pass", "title": "匹克球 10 次卡", "subtitle": "每次 1 小时", "description": "有效期内任意时段可用",
		"images": images, "sports": []string{"pickleball"}, "price_amt": 45000, "original_amt": 60000, "use_qty": 10,
		"valid_until": time.Now().AddDate(0, 6, 0).Format("2006-01-02"), "refundable": true, "rules": "每次核销用掉 1 次，剩余次数在卡券包查看"})
	if pkg.ID == 0 {
		return
	}
	// An active official promotion: the voucher at its price (active at
	// once), the package invited at a lower price and accepted.
	now := time.Now()
	var promo struct {
		ID int64 `json:"id"`
	}
	ad.do("POST", "/admin/v1/promotions", map[string]any{"title": "双 12 运动狂欢", "subtitle": "羽毛球、匹克球 7 折起",
		"banner_url": "https://picsum.photos/seed/loopland-promo/1200/400", "description": "活动期间指定商品享活动价，平台补贴，数量有限",
		"starts_at": now.Add(-time.Hour), "ends_at": now.AddDate(0, 0, 14), "apply_open": true, "apply_deadline": now.AddDate(0, 0, 7)}, &promo)
	if promo.ID == 0 {
		return
	}
	ad.do("POST", fmt.Sprintf("/admin/v1/promotions/%d/publish", promo.ID), nil, nil)
	if voucher.ID != 0 {
		ad.do("POST", fmt.Sprintf("/admin/v1/promotions/%d/entries", promo.ID), map[string]any{"product_id": voucher.ID, "sort_no": 2}, nil)
	}
	var invite struct {
		ID int64 `json:"id"`
	}
	ad.do("POST", fmt.Sprintf("/admin/v1/promotions/%d/entries", promo.ID), map[string]any{"product_id": pkg.ID, "promo_price_amt": 4900,
		"platform_subsidy_amt": 500, "promo_stock_qty": 100, "sort_no": 1}, &invite)
	if invite.ID != 0 {
		staff.do("POST", fmt.Sprintf("/admin/v1/promotion-entries/%d/accept", invite.ID), nil, nil)
	}
	// The pass applies to the promotion and waits for the platform (总览待办).
	if pass.ID != 0 {
		staff.do("POST", fmt.Sprintf("/admin/v1/promotions/%d/apply", promo.ID), map[string]any{"product_id": pass.ID, "promo_price_amt": 39900}, nil)
	}
	// 阿青 buys the package at the promotion price.
	if len(users) > 0 {
		var res struct {
			Order struct {
				Pay *struct {
					OrderNo string `json:"order_no"`
				} `json:"pay"`
			} `json:"order"`
		}
		users[0].do("POST", fmt.Sprintf("/v1/products/%d/orders", pkg.ID), map[string]any{"qty": 1, "channel": "mock"}, &res)
		if res.Order.Pay != nil {
			users[0].do("POST", "/v1/dev/orders/"+res.Order.Pay.OrderNo+"/pay", nil, nil)
		}
	}
}
