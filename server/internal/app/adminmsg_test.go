package app

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/keanying/loopland/server/internal/platform/clock"
)

// ---------------------------------------------------------------- helpers

type adminMsgView struct {
	ID        int64      `json:"id"`
	Category  string     `json:"category"`
	Title     string     `json:"title"`
	Body      string     `json:"body"`
	Link      *string    `json:"link"`
	Level     string     `json:"level"`
	IsRead    bool       `json:"is_read"`
	ReadAt    *time.Time `json:"read_at"`
	CreatedAt time.Time  `json:"created_at"`
}

type adminMsgList struct {
	Items       []adminMsgView `json:"items"`
	Total       int            `json:"total"`
	UnreadCount int            `json:"unread_count"`
}

func (c *client) adminMessages(query string) adminMsgList {
	c.e.t.Helper()
	var l adminMsgList
	c.must("GET", "/admin/v1/messages?page_size=100"+query, nil, &l)
	return l
}

// findMsg returns the first message of the category and level whose
// title contains part (nil when none).
func (l adminMsgList) find(category, level, part string) *adminMsgView {
	for i, m := range l.Items {
		if m.Category == category && (level == "" || m.Level == level) && strings.Contains(m.Title, part) {
			return &l.Items[i]
		}
	}
	return nil
}

func (c *client) mustMsg(category, level, part, link string) adminMsgView {
	c.e.t.Helper()
	l := c.adminMessages("")
	m := l.find(category, level, part)
	if m == nil {
		var titles []string
		for _, x := range l.Items {
			titles = append(titles, x.Category+"/"+x.Level+": "+x.Title)
		}
		c.e.t.Fatalf("no %s/%s message %q in %q", category, level, part, titles)
	}
	if link != "" && (m.Link == nil || *m.Link != link) {
		c.e.t.Fatalf("message %q link %v, want %s", m.Title, m.Link, link)
	}
	return *m
}

func (c *client) noMsg(category, part string) {
	c.e.t.Helper()
	if m := c.adminMessages("").find(category, "", part); m != nil {
		c.e.t.Fatalf("unexpected message: %+v", *m)
	}
}

func multipartImage(purpose string, data []byte) ([]byte, string) {
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	_ = mw.WriteField("purpose", purpose)
	fw, _ := mw.CreateFormFile("file", "photo.png")
	_, _ = fw.Write(data)
	_ = mw.Close()
	return body.Bytes(), mw.FormDataContentType()
}

// uploadTo posts a multipart image to path (e.g. /admin/v1/media).
func (c *client) uploadTo(path, purpose string, data []byte, out any) (int, string) {
	c.e.t.Helper()
	body, ct := multipartImage(purpose, data)
	req, _ := http.NewRequest("POST", c.e.srv.URL+path, bytes.NewReader(body))
	req.Header.Set("Content-Type", ct)
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.e.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if out != nil {
		_ = json.Unmarshal(raw, out)
	}
	var e apiErr
	_ = json.Unmarshal(raw, &e)
	return resp.StatusCode, e.Error.Code
}

// callRaw signs signed (the raw body unless tampering) and sends raw.
func (c *openClient) callRaw(method, path, contentType string, raw, signed []byte) openResp {
	c.e.t.Helper()
	if signed == nil {
		signed = raw
	}
	ts, nonce := strconv.FormatInt(c.ts(), 10), c.nonce()
	sum := sha256.Sum256(signed)
	s := strings.Join([]string{method, path, "", ts, nonce, hex.EncodeToString(sum[:])}, "\n")
	m := hmac.New(sha256.New, []byte(c.secret))
	m.Write([]byte(s))
	req, _ := http.NewRequest(method, c.e.srv.URL+path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("X-Loop-App-Id", c.appID)
	req.Header.Set("X-Loop-Timestamp", ts)
	req.Header.Set("X-Loop-Nonce", nonce)
	req.Header.Set("X-Loop-Signature", hex.EncodeToString(m.Sum(nil)))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.e.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return openResp{status: resp.StatusCode, header: resp.Header, body: b}
}

func (e *env) newAdmin(ad *client, name, role string) (*client, int64) {
	e.t.Helper()
	var row struct {
		ID int64 `json:"id"`
	}
	ad.must("POST", "/admin/v1/admins", map[string]string{"username": name, "password": name + "-password-1", "role": role}, &row)
	return e.adminLogin(name, name+"-password-1"), row.ID
}

// ---------------------------------------------------------------- uploads

func TestAdminMediaUpload(t *testing.T) {
	t.Setenv("LOOPLAND_MEDIA_DIR", t.TempDir())
	e := newEnv(t)
	ad := adminClient(t, e)
	m1 := e.merchant("跑野运动馆")
	s1 := e.staff(ad, "mstaff1", m1)
	ops, opsID := e.newAdmin(ad, "ops1", "ops")
	rev, _ := e.newAdmin(ad, "rev1", "reviewer")

	var im uploaded
	if st, code := s1.uploadTo("/admin/v1/media", "product", pngBytes(60, 40), &im); st != 200 || im.ID == 0 || im.Width == nil || *im.Width != 60 ||
		*im.Height != 40 || !strings.Contains(im.URL, "/v1/media/files/product/") {
		t.Fatalf("staff product upload: %d %s %+v", st, code, im)
	}
	if n := e.scalar(`SELECT count(*) FROM src.src_cnt_loop_media WHERE id=$1 AND user_id IS NULL AND admin_id IS NOT NULL AND merchant_id=$2
		AND open_app_id IS NULL AND purpose_type='product'`, im.ID, m1); n != 1 {
		t.Fatal("staff upload row: uploader not recorded")
	}
	expect := func(c *client, purpose string, data []byte, status int, code string) {
		t.Helper()
		if st, got := c.uploadTo("/admin/v1/media", purpose, data, nil); st != status || got != code {
			t.Fatalf("upload %s: got %d %q, want %d %q", purpose, st, got, status, code)
		}
	}
	img := pngBytes(20, 20)
	expect(s1, "promotion_banner", img, 403, "forbidden")
	expect(s1, "merchant_license", img, 403, "forbidden")
	expect(s1, "venue_cover", img, 200, "")
	expect(s1, "post", img, 400, "invalid_body")
	expect(s1, "", img, 400, "invalid_body")
	expect(s1, "product", []byte("GIF89a not supported"), 400, "unsupported_media")
	expect(s1, "product", append(pngBytes(10, 10), make([]byte, 10<<20)...), 413, "file_too_large")
	for _, p := range []string{"promotion_banner", "venue_cover", "merchant_license", "campaign_banner", "shop_item"} {
		expect(ops, p, img, 200, "")
		expect(ad, p, img, 200, "")
	}
	expect(ops, "product", img, 403, "forbidden")
	expect(rev, "venue_cover", img, 403, "forbidden")
	expect(e.anon(), "product", img, 401, "unauthorized")
	// Admin uploads are not the user's: the app cannot attach them.
	if n := e.scalar(`SELECT count(*) FROM src.src_cnt_loop_media WHERE admin_id=$1 AND merchant_id IS NULL`, opsID); n != 5 {
		t.Fatalf("ops uploads: %d", n)
	}
	// 500 a day per account.
	e.sql(`INSERT INTO src.src_cnt_loop_media (admin_id, purpose_type, storage_type, object_key, url, content_type, size_byte_qty)
		SELECT $1, 'shop_item', 'local', 'shop_item/seeded/' || g, 'https://cdn.test/x.png', 'image/png', 1 FROM generate_series(1, 495) g`, opsID)
	expect(ops, "shop_item", img, 429, "rate_limited")
	expect(s1, "product", img, 200, "")

	// Open platform: products scope, purpose product, signed over the raw multipart body.
	var a, noScope openAppView
	s1.must("POST", "/admin/v1/open-apps", map[string]any{"name": "收银系统", "scopes": []string{"products"}}, &a)
	s1.must("POST", "/admin/v1/open-apps", map[string]any{"name": "ERP", "scopes": []string{"orders"}}, &noScope)
	oc := e.openClient(a)
	raw, ct := multipartImage("product", pngBytes(30, 30))
	r := oc.callRaw("POST", "/open/v1/media", ct, raw, nil)
	if r.status != 200 {
		t.Fatalf("open upload: %d %s", r.status, r.body)
	}
	var oim uploaded
	r.decode(t, &oim)
	if oim.ID == 0 || oim.Width == nil || *oim.Width != 30 {
		t.Fatalf("open upload: %s", r.body)
	}
	if n := e.scalar(`SELECT count(*) FROM src.src_cnt_loop_media WHERE id=$1 AND open_app_id=$2 AND merchant_id=$3 AND admin_id IS NULL AND user_id IS NULL`,
		oim.ID, a.ID, m1); n != 1 {
		t.Fatal("open upload row: uploader not recorded")
	}
	if r := oc.callRaw("POST", "/open/v1/media", ct, raw, append([]byte("x"), raw...)); r.status != 401 || r.code() != "invalid_signature" {
		t.Fatalf("tampered body: %d %s", r.status, r.body)
	}
	bannerRaw, bannerCT := multipartImage("promotion_banner", pngBytes(30, 30))
	if r := oc.callRaw("POST", "/open/v1/media", bannerCT, bannerRaw, nil); r.status != 400 || r.code() != "invalid_body" {
		t.Fatalf("open banner: %d %s", r.status, r.body)
	}
	gifRaw, gifCT := multipartImage("product", []byte("GIF89a......"))
	if r := oc.callRaw("POST", "/open/v1/media", gifCT, gifRaw, nil); r.status != 400 || r.code() != "unsupported_media" {
		t.Fatalf("open gif: %d %s", r.status, r.body)
	}
	if r := e.openClient(noScope).callRaw("POST", "/open/v1/media", ct, raw, nil); r.status != 403 || r.code() != "scope_denied" {
		t.Fatalf("no products scope: %d %s", r.status, r.body)
	}
	// The uploaded url goes into a product.
	var p productView
	oc.must("POST", "/open/v1/products", nil, productBody("package", "羽毛球 2 小时畅打套餐", 6900, map[string]any{"images": []string{oim.URL}}), &p)
	if p.ID == 0 {
		t.Fatal("open product with uploaded image")
	}
}

// ---------------------------------------------------------------- inbox

func TestAdminMessages(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)
	m1, m2 := e.merchant("跑野运动馆"), e.merchant("滨江网球")
	s1, s1b, s2 := e.staff(ad, "mstaff1", m1), e.staff(ad, "mstaff1b", m1), e.staff(ad, "mstaff2", m2)
	e.staff(ad, "mstaffoff", m1)
	offID := e.scalar(`SELECT id FROM src.src_sys_loop_admin WHERE username='mstaffoff'`)
	e.sql(`UPDATE src.src_sys_loop_admin SET is_disabled=true WHERE id=$1`, offID)
	ops, _ := e.newAdmin(ad, "ops1", "ops")
	rev, _ := e.newAdmin(ad, "rev1", "reviewer")

	// Products: auto approve, auto reject, manual review (platform + reviewer), reviewer reject.
	p := s1.onSale(productBody("package", "羽毛球 2 小时畅打套餐", 6900, nil))
	link := fmt.Sprintf("/merchant/products?id=%d", p.ID)
	s1.mustMsg("product", "success", "商品「羽毛球 2 小时畅打套餐」审核通过，已上架", link)
	s1b.mustMsg("product", "success", "商品「羽毛球 2 小时畅打套餐」审核通过，已上架", link)
	if l := s2.adminMessages(""); l.Total != 0 {
		t.Fatalf("other merchant's staff got: %+v", l)
	}
	if l := ops.adminMessages(""); l.Total != 0 {
		t.Fatalf("ops got merchant messages: %+v", l)
	}
	if n := e.scalar(`SELECT count(*) FROM src.src_msg_loop_admin_message WHERE admin_id=$1`, offID); n != 0 {
		t.Fatal("disabled account got messages")
	}
	var bad productView
	s1.must("POST", "/admin/v1/products", productBody("voucher", "代开发票 100 元代金券", 9000, nil), &bad)
	s1.must("POST", fmt.Sprintf("/admin/v1/products/%d/submit", bad.ID), nil, &bad)
	s1.mustMsg("product", "warning", "商品「代开发票 100 元代金券」未通过审核：", fmt.Sprintf("/merchant/products?id=%d", bad.ID))
	var mid productView
	s1.must("POST", "/admin/v1/products", productBody("package", "代跑陪练体验课", 9000, nil), &mid)
	s1.must("POST", fmt.Sprintf("/admin/v1/products/%d/submit", mid.ID), nil, &mid)
	if mid.Status != "reviewing" {
		t.Fatalf("reviewing: %+v", mid)
	}
	for _, c := range []*client{ad, ops, rev} {
		c.mustMsg("review", "info", "商户「跑野运动馆」提交了商品「代跑陪练体验课」，待审核", "/review?type=product")
	}
	s1.noMsg("review", "")
	rev.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/reject", productTask(e, mid.ID)), map[string]string{"reason": "描述不清"}, nil)
	s1.mustMsg("product", "warning", "商品「代跑陪练体验课」未通过审核：描述不清", "")
	// Pending change of an on-sale product: approved; then a ban.
	s1.must("PATCH", fmt.Sprintf("/admin/v1/products/%d", p.ID), map[string]any{"title": "代跑羽毛球套餐"}, nil)
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/approve", productTask(e, p.ID)), nil, nil)
	s1.mustMsg("product", "success", "商品「代跑羽毛球套餐」的修改已生效", link)
	ops.must("POST", fmt.Sprintf("/admin/v1/products/%d/ban", p.ID), map[string]string{"reason": "虚假宣传"}, nil)
	s1.mustMsg("product", "error", "商品「代跑羽毛球套餐」已被平台下架：虚假宣传", link)

	// Promotions: invitation → decline (platform), application → approve / remove (merchant).
	invited := s1.onSale(productBody("package", "游泳单次票", 6900, map[string]any{"allow_promotion": true}))
	applied := s1.onSale(productBody("pass", "匹克球 10 次卡", 45000, map[string]any{"use_qty": 10}))
	now := time.Now()
	var pr promotionView
	ad.must("POST", "/admin/v1/promotions", map[string]any{"title": "双 12 运动狂欢", "banner_url": "https://cdn.test/b.png", "description": "活动说明",
		"starts_at": now.Add(-time.Hour), "ends_at": now.AddDate(0, 0, 7), "apply_open": true, "apply_deadline": now.AddDate(0, 0, 3)}, &pr)
	ad.must("POST", fmt.Sprintf("/admin/v1/promotions/%d/publish", pr.ID), nil, nil)
	var inv entryView
	ad.must("POST", fmt.Sprintf("/admin/v1/promotions/%d/entries", pr.ID), map[string]any{"product_id": invited.ID, "promo_price_amt": 4900}, &inv)
	s1.mustMsg("promotion", "info", "「双 12 运动狂欢」邀请你的商品「游泳单次票」参加，活动价 ¥49", "/merchant/promotions?tab=invites")
	s1.must("POST", fmt.Sprintf("/admin/v1/promotion-entries/%d/decline", inv.ID), nil, nil)
	promoLink := fmt.Sprintf("/merchant/promotions?id=%d", pr.ID)
	ad.mustMsg("promotion", "info", "商户「跑野运动馆」拒绝了「双 12 运动狂欢」的邀请", promoLink)
	rev.noMsg("promotion", "")
	var app entryView
	s1.must("POST", fmt.Sprintf("/admin/v1/promotions/%d/apply", pr.ID), map[string]any{"product_id": applied.ID, "promo_price_amt": 39900}, &app)
	ops.mustMsg("promotion", "info", "商户「跑野运动馆」报名「双 12 运动狂欢」：商品「匹克球 10 次卡」", promoLink)
	ad.must("POST", fmt.Sprintf("/admin/v1/promotion-entries/%d/approve", app.ID), map[string]any{}, nil)
	s1.mustMsg("promotion", "success", "商品「匹克球 10 次卡」报名「双 12 运动狂欢」已通过", "/merchant/promotions?tab=mine")
	ad.must("POST", fmt.Sprintf("/admin/v1/promotion-entries/%d/remove", app.ID), map[string]any{"note": "库存不足"}, nil)
	s1.mustMsg("promotion", "warning", "商品「匹克球 10 次卡」已被移出「双 12 运动狂欢」：库存不足", "")
	direct := s1.onSale(productBody("voucher", "100 元运动代金券", 8000, map[string]any{"allow_promotion": true}))
	ad.must("POST", fmt.Sprintf("/admin/v1/promotions/%d/entries", pr.ID), map[string]any{"product_id": direct.ID}, nil)
	s1.mustMsg("promotion", "info", "商品「100 元运动代金券」已加入「双 12 运动狂欢」", "/merchant/promotions?tab=mine")

	// Platform refund of a product order.
	u, _ := e.member("13800006001")
	o := u.buy(invited.ID, 1)
	ad.must("POST", fmt.Sprintf("/admin/v1/product-orders/%d/refund", o.ID), map[string]string{"reason": "重复下单"}, nil)
	s1.mustMsg("product", "info", "订单 "+o.OrderNo+" 已由平台退款 ¥69：重复下单", fmt.Sprintf("/merchant/product-orders?id=%d", o.ID))

	// Statements: generated, confirmed, paid.
	day := clock.Today()
	lastMon := day.AddDate(0, 0, -((int(day.Weekday())+6)%7)-7)
	venueID := e.scalar(`INSERT INTO src.src_mer_loop_venue (merchant_id, venue_name, center_geom, is_bookable, price_amt)
		VALUES ($1, '跑野 · 张江', ST_SetSRID(ST_MakePoint(121.47, 31.23), 4326), true, 6000) RETURNING id`, m1)
	_, uid := e.member("13800006002")
	e.sql(`INSERT INTO src.src_ord_loop_booking (booking_no, user_id, venue_id, merchant_id, start_time, end_time, slot_qty, amount_amt, original_amt,
			booking_status, channel, paid_time) VALUES ('BKM1',$1,$2,$3,$4,$4::timestamptz + interval '1 hour',1,200000,200000,'paid','mock',now())`,
		uid, venueID, m1, lastMon.Add(34*time.Hour))
	var gen struct {
		Items []statementView `json:"items"`
	}
	ad.must("POST", "/admin/v1/statements/generate", map[string]string{"period_start": lastMon.Format(time.DateOnly)}, &gen)
	if len(gen.Items) != 1 {
		t.Fatalf("generated: %+v", gen)
	}
	_, week := lastMon.ISOWeek()
	stLink := fmt.Sprintf("/merchant/settlement?id=%d", gen.Items[0].ID)
	s1.mustMsg("settlement", "info", fmt.Sprintf("第 %d 周结算单已生成，待平台确认", week), stLink)
	ad.must("POST", fmt.Sprintf("/admin/v1/statements/%d/confirm", gen.Items[0].ID), nil, nil)
	s1.mustMsg("settlement", "success", fmt.Sprintf("第 %d 周结算单已确认", week), stLink)
	ad.must("POST", fmt.Sprintf("/admin/v1/statements/%d/paid", gen.Items[0].ID), nil, nil)
	// 2000 yuan of bookings, 10 % commission: the platform pays 1800.
	s1.mustMsg("settlement", "success", fmt.Sprintf("第 %d 周结算单平台已付款 ¥1,800", week), stLink)
	s2.noMsg("settlement", "")

	// Open platform apps: the platform disables / enables; the merchant's own switch sends nothing.
	var oa openAppView
	s1.must("POST", "/admin/v1/open-apps", map[string]any{"name": "收银系统", "scopes": []string{"products"}}, &oa)
	s1.must("POST", fmt.Sprintf("/admin/v1/open-apps/%d/disable", oa.ID), nil, nil)
	s1.noMsg("openapi", "")
	s1.must("POST", fmt.Sprintf("/admin/v1/open-apps/%d/enable", oa.ID), nil, nil)
	ad.must("POST", fmt.Sprintf("/admin/v1/open-apps/%d/disable", oa.ID), nil, nil)
	s1.mustMsg("openapi", "warning", "应用「收银系统」已被平台停用", "/merchant/open-apps")
	ad.must("POST", fmt.Sprintf("/admin/v1/open-apps/%d/enable", oa.ID), nil, nil)
	s1.mustMsg("openapi", "info", "应用「收银系统」已被平台重新启用", "/merchant/open-apps")

	// Reading: unread count, read one, other accounts' are 404, read all by category, then all.
	var cnt struct {
		Count      int            `json:"count"`
		ByCategory map[string]int `json:"by_category"`
	}
	s1.must("GET", "/admin/v1/messages/unread-count", nil, &cnt)
	all := s1.adminMessages("")
	if cnt.Count != all.Total || all.UnreadCount != all.Total || cnt.ByCategory["product"] == 0 || cnt.ByCategory["promotion"] != 4 ||
		cnt.ByCategory["settlement"] != 3 || cnt.ByCategory["openapi"] != 2 || cnt.ByCategory["review"] != 0 {
		t.Fatalf("unread count %+v, list total %d unread %d", cnt, all.Total, all.UnreadCount)
	}
	for i := 1; i < len(all.Items); i++ {
		if all.Items[i].CreatedAt.After(all.Items[i-1].CreatedAt) {
			t.Fatal("messages not newest first")
		}
	}
	first := all.Items[0]
	s2.expectErr("POST", fmt.Sprintf("/admin/v1/messages/%d/read", first.ID), nil, 404, "not_found")
	ops.expectErr("POST", fmt.Sprintf("/admin/v1/messages/%d/read", first.ID), nil, 404, "not_found")
	var read adminMsgView
	s1.must("POST", fmt.Sprintf("/admin/v1/messages/%d/read", first.ID), nil, &read)
	if !read.IsRead || read.ReadAt == nil || read.ID != first.ID || read.Title != first.Title {
		t.Fatalf("read: %+v", read)
	}
	if l := s1b.adminMessages("&unread=true"); l.Total != all.Total {
		t.Fatalf("read state shared with another staff account: %d of %d", l.Total, all.Total)
	}
	promos := s1.adminMessages("&category=promotion")
	if promos.Total != 4 || promos.UnreadCount != all.Total-1 {
		t.Fatalf("promotion filter: %+v", promos)
	}
	s1.expectErr("GET", "/admin/v1/messages?category=bogus", nil, 400, "invalid_body")
	var upd struct {
		Updated int `json:"updated"`
	}
	s1.must("POST", "/admin/v1/messages/read-all", map[string]string{"category": "promotion"}, &upd)
	if upd.Updated != 4 {
		t.Fatalf("read-all promotion: %+v", upd)
	}
	cnt.ByCategory = nil
	s1.must("GET", "/admin/v1/messages/unread-count", nil, &cnt)
	if _, ok := cnt.ByCategory["promotion"]; ok || cnt.Count != all.Total-5 {
		t.Fatalf("after read-all promotion: %+v", cnt)
	}
	s1.must("POST", "/admin/v1/messages/read-all", nil, &upd)
	if upd.Updated != all.Total-5 {
		t.Fatalf("read-all: %+v", upd)
	}
	if l := s1.adminMessages("&unread=true"); l.Total != 0 || l.UnreadCount != 0 || len(l.Items) != 0 {
		t.Fatalf("unread after read-all: %+v", l)
	}
	var page adminMsgList
	s1.must("GET", "/admin/v1/messages?page=2&page_size=5", nil, &page)
	if len(page.Items) != 5 || page.Total != all.Total || page.Items[0].ID != all.Items[5].ID {
		t.Fatalf("page 2: %d items of %d", len(page.Items), page.Total)
	}

	// 180-day retention, cleaned once a day.
	e.sql(`UPDATE src.src_msg_loop_admin_message SET create_time=now() - interval '181 days' WHERE id=$1`, first.ID)
	e.job("admin_message_cleanup")
	if n := e.scalar(`SELECT count(*) FROM src.src_msg_loop_admin_message WHERE id=$1`, first.ID); n != 0 {
		t.Fatal("old message kept")
	}
	if n := e.scalar(`SELECT count(*) FROM src.src_msg_loop_admin_message WHERE admin_id=(SELECT id FROM src.src_sys_loop_admin WHERE username='mstaff1')`); n != int64(all.Total-1) {
		t.Fatalf("cleanup removed recent messages: %d left", n)
	}
}

// A failed business transaction sends nothing.
func TestAdminMessagesOnlyAfterCommit(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)
	m1 := e.merchant("跑野运动馆")
	s1 := e.staff(ad, "mstaff1", m1)
	p := s1.onSale(productBody("package", "羽毛球 2 小时畅打套餐", 6900, nil))
	ad.must("POST", fmt.Sprintf("/admin/v1/products/%d/ban", p.ID), map[string]string{"reason": "虚假宣传"}, nil)
	before := s1.adminMessages("").Total
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/products/%d/ban", p.ID), map[string]string{"reason": "再次下架"}, 409, "invalid_status")
	if after := s1.adminMessages("").Total; after != before {
		t.Fatalf("messages %d → %d after a failed request", before, after)
	}
}

func TestWebhookFailureMessage(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)
	m1 := e.merchant("跑野运动馆")
	s1 := e.staff(ad, "mstaff1", m1)
	hook := newHookServer(t)
	hook.setFail(true)
	var a openAppView
	s1.must("POST", "/admin/v1/open-apps", map[string]any{"name": "收银系统", "scopes": []string{"products"}, "webhook_url": hook.URL,
		"webhook_events": []string{"product.reviewed"}}, &a)
	failAll := func() {
		t.Helper()
		for i := 0; i < 6; i++ {
			e.sql(`UPDATE src.src_mer_loop_webhook_delivery SET next_retry_time=now() WHERE delivery_status='pending'`)
			e.job("webhook_deliver")
		}
		if n := e.scalar(`SELECT count(*) FROM src.src_mer_loop_webhook_delivery WHERE delivery_status='pending'`); n != 0 {
			t.Fatalf("%d deliveries still pending", n)
		}
	}
	count := func() int {
		n := 0
		for _, m := range s1.adminMessages("&category=openapi").Items {
			if strings.Contains(m.Title, "回调推送失败") {
				n++
			}
		}
		return n
	}
	s1.onSale(productBody("package", "羽毛球 2 小时畅打套餐", 6900, nil))
	e.sql(`UPDATE src.src_mer_loop_webhook_delivery SET next_retry_time=now()`)
	e.job("webhook_deliver")
	if count() != 0 {
		t.Fatal("message before the 6th attempt")
	}
	failAll()
	m := s1.mustMsg("openapi", "error", "应用「收银系统」有 1 条回调推送失败", fmt.Sprintf("/merchant/open-apps?id=%d", a.ID))
	if !strings.Contains(m.Body, "product.reviewed") {
		t.Fatalf("body: %s", m.Body)
	}
	// More failures within 24 hours: still one message.
	s1.onSale(productBody("package", "游泳单次票", 6900, nil))
	s1.onSale(productBody("package", "网球 1 小时", 6900, nil))
	failAll()
	if n := count(); n != 1 {
		t.Fatalf("%d failure messages within 24h", n)
	}
	// A manual redelivery that fails again sends nothing.
	d := e.scalar(`SELECT id FROM src.src_mer_loop_webhook_delivery ORDER BY id LIMIT 1`)
	s1.must("POST", fmt.Sprintf("/admin/v1/open-apps/%d/deliveries/%d/redeliver", a.ID, d), nil, nil)
	if n := count(); n != 1 {
		t.Fatalf("%d failure messages after a manual redelivery", n)
	}
	// A day later the next final failure is reported again.
	e.sql(`UPDATE src.src_msg_loop_admin_message SET create_time=now() - interval '25 hours'`)
	s1.onSale(productBody("package", "匹克球 1 小时", 6900, nil))
	failAll()
	if n := count(); n != 2 {
		t.Fatalf("%d failure messages after 24h", n)
	}
}
