package seed

import (
	"fmt"
	"time"

	"github.com/keanying/loopland/server/internal/geo"
)

// seedPerks adds V2 batch 4 part B data: a brand merchant with a running
// brand campaign, a supply station, a merchant chest and (when part A
// seeded a venue) a stronghold; a hand-claimed coupon and a few shop
// purchases.
func seedPerks(users []*client, ad *client) {
	proj := geo.NewProjection(origin)
	at := func(x, y float64) map[string]any {
		p := proj.Inverse(geo.Point{X: x, Y: y})
		return map[string]any{"lat": p.Lat, "lng": p.Lng}
	}
	var brand struct {
		ID int64 `json:"id"`
	}
	ad.do("POST", "/admin/v1/merchants", map[string]any{"name": "瑞幸咖啡", "type": "brand", "status": "partner", "contact_name": "李店长"}, &brand)
	if brand.ID == 0 {
		return
	}
	now := time.Now()
	var camp struct {
		ID int64 `json:"id"`
	}
	ad.do("POST", "/admin/v1/brand-campaigns", map[string]any{"merchant_id": brand.ID, "title": "跑完来杯咖啡", "description": "跑步经过补给站或开商户宝箱领咖啡券，到店出示券码核销",
		"start_time": now.AddDate(0, 0, -2), "end_time": now.AddDate(0, 0, 28), "store_count": 12, "target_redemptions": 5000,
		"merchant_investment_amt": 2000000}, &camp)
	perk := func(title, value string) map[string]any {
		return map[string]any{"title": title, "description": "限滨江店，每人每天 1 次", "value_text": value, "valid_days": 7,
			"rules": "到店出示券码，店员扫码核销；需要当天有一条运动记录"}
	}
	drop := func(typ, name string, center map[string]any, venueID *int64, p map[string]any, price int64, dir string) int64 {
		var d struct {
			ID int64 `json:"id"`
		}
		ad.do("POST", "/admin/v1/drops", map[string]any{"merchant_id": brand.ID, "campaign_id": camp.ID, "type": typ, "name": name, "center": center,
			"radius_m": 80, "venue_id": venueID, "store_name": "滨江店", "perk": p, "daily_cap": 100, "start_time": now.AddDate(0, 0, -2),
			"end_time": now.AddDate(0, 0, 28), "settle_price_amt": price, "settle_direction": dir}, &d)
		return d.ID
	}
	supplyAt := at(150, 0)
	supply := drop("supply", "补给站 · 瑞幸滨江店", supplyAt, nil, perk("美式咖啡 5 折", "5 折"), 200, "merchant_pays")
	drop("chest", "宝箱 · 瑞幸", at(-300, 450), nil, perk("拿铁立减 5 元", "减 5 元"), 300, "platform_pays")
	var venues struct {
		Items []struct {
			ID int64 `json:"id"`
		} `json:"items"`
	}
	ad.do("GET", "/admin/v1/venues?page_size=1", nil, &venues)
	if len(venues.Items) > 0 {
		v := venues.Items[0].ID
		drop("stronghold", "据点 · 签到送咖啡", nil, &v, perk("签到送冷萃一杯", "免费"), 500, "platform_pays")
	}
	if len(users) > 1 && supply != 0 {
		users[1].do("POST", fmt.Sprintf("/v1/drops/%d/claim", supply), supplyAt, nil)
	}
	// 能量商城: cheap items so the seeded runs' energy covers them.
	for i, key := range []string{"marker_star", "frame_runner"} {
		if i < len(users) {
			users[i].do("POST", "/v1/shop/items/"+key+"/buy", nil, nil)
			users[i].do("POST", "/v1/shop/items/"+key+"/equip", nil, nil)
		}
	}
}
