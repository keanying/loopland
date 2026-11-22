package app

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/keanying/loopland/server/internal/platform/clock"
)

type openAppView struct {
	ID        int64    `json:"id"`
	AppID     string   `json:"app_id"`
	AppSecret string   `json:"app_secret"`
	Status    string   `json:"status"`
	Scopes    []string `json:"scopes"`
}

// openClient signs /open/v1 calls like the documented examples.
type openClient struct {
	e             *env
	appID, secret string
	ts            func() int64
	nonce         func() string
}

func (e *env) openClient(a openAppView) *openClient {
	return &openClient{e: e, appID: a.AppID, secret: a.AppSecret, ts: func() int64 { return time.Now().Unix() }, nonce: func() string {
		b := make([]byte, 8)
		_, _ = rand.Read(b)
		return hex.EncodeToString(b)
	}}
}

type openResp struct {
	status int
	header http.Header
	body   []byte
}

func (r openResp) code() string {
	var e apiErr
	_ = json.Unmarshal(r.body, &e)
	return e.Error.Code
}

func (r openResp) decode(t *testing.T, v any) {
	t.Helper()
	if err := json.Unmarshal(r.body, v); err != nil {
		t.Fatalf("decode %s: %v", r.body, err)
	}
}

// call signs and sends a request; edit may change the headers after signing.
func (c *openClient) call(method, path string, query url.Values, body any, edit func(h http.Header)) openResp {
	c.e.t.Helper()
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	q := query.Encode() // keys sorted, url-encoded
	ts, nonce := strconv.FormatInt(c.ts(), 10), c.nonce()
	sum := sha256.Sum256(raw)
	s := strings.Join([]string{method, path, q, ts, nonce, hex.EncodeToString(sum[:])}, "\n")
	m := hmac.New(sha256.New, []byte(c.secret))
	m.Write([]byte(s))
	u := c.e.srv.URL + path
	if q != "" {
		u += "?" + q
	}
	req, _ := http.NewRequest(method, u, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Loop-App-Id", c.appID)
	req.Header.Set("X-Loop-Timestamp", ts)
	req.Header.Set("X-Loop-Nonce", nonce)
	req.Header.Set("X-Loop-Signature", hex.EncodeToString(m.Sum(nil)))
	if edit != nil {
		edit(req.Header)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.e.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return openResp{status: resp.StatusCode, header: resp.Header, body: b}
}

func (c *openClient) must(method, path string, query url.Values, body, out any) {
	c.e.t.Helper()
	r := c.call(method, path, query, body, nil)
	if r.status != 200 {
		c.e.t.Fatalf("%s %s: %d %s", method, path, r.status, r.body)
	}
	if out != nil {
		r.decode(c.e.t, out)
	}
}

func (c *openClient) expect(method, path string, query url.Values, body any, edit func(h http.Header), status int, code string) openResp {
	c.e.t.Helper()
	r := c.call(method, path, query, body, edit)
	if r.status != status || r.code() != code {
		c.e.t.Fatalf("%s %s: got %d %q, want %d %q (%s)", method, path, r.status, r.code(), status, code, r.body)
	}
	return r
}

// hookServer records webhook requests; fail makes it answer 500.
type hookServer struct {
	*httptest.Server
	mu   sync.Mutex
	reqs []hookReq
	fail bool
}

type hookReq struct {
	header http.Header
	body   []byte
}

func newHookServer(t *testing.T) *hookServer {
	h := &hookServer{}
	h.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		h.mu.Lock()
		h.reqs = append(h.reqs, hookReq{header: r.Header.Clone(), body: b})
		fail := h.fail
		h.mu.Unlock()
		if fail {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(h.Close)
	return h
}

func (h *hookServer) received() []hookReq {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]hookReq(nil), h.reqs...)
}

func (h *hookServer) setFail(v bool) {
	h.mu.Lock()
	h.fail = v
	h.mu.Unlock()
}

type deliveryView struct {
	ID         int64  `json:"id"`
	EventID    string `json:"event_id"`
	EventType  string `json:"event_type"`
	Status     string `json:"status"`
	AttemptQty int    `json:"attempt_qty"`
}

// ---------------------------------------------------------------- signature, scopes, limits

func TestOpenAPISignatureAndLimits(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)
	m1, m2 := e.merchant("跑野运动馆"), e.merchant("滨江网球")
	s1, s2 := e.staff(ad, "pstaff1", m1), e.staff(ad, "pstaff2", m2)
	appBody := map[string]any{"name": "收银系统", "scopes": []string{"products", "orders", "redemptions"}, "ip_allowlist": []string{}}
	ad.expectErr("POST", "/admin/v1/open-apps", appBody, 403, "forbidden")
	s1.expectErr("POST", "/admin/v1/open-apps", map[string]any{"name": "x", "scopes": []string{"everything"}}, 400, "invalid_body")
	var a openAppView
	s1.must("POST", "/admin/v1/open-apps", appBody, &a)
	if !strings.HasPrefix(a.AppID, "lpa_") || a.AppSecret == "" || a.Status != "active" {
		t.Fatalf("app: %+v", a)
	}
	var list struct {
		Items []openAppView `json:"items"`
	}
	s1.must("GET", "/admin/v1/open-apps", nil, &list)
	if len(list.Items) != 1 || list.Items[0].AppSecret != "" {
		t.Fatalf("apps (secret only shown once): %+v", list)
	}
	s2.must("GET", "/admin/v1/open-apps", nil, &list)
	if len(list.Items) != 0 {
		t.Fatalf("other merchant apps: %+v", list)
	}
	ad.must("GET", fmt.Sprintf("/admin/v1/open-apps?merchant_id=%d", m1), nil, &list)
	if len(list.Items) != 1 {
		t.Fatalf("admin apps: %+v", list)
	}
	if n := e.scalar(`SELECT count(*) FROM src.src_mer_loop_open_app WHERE position($1 in encode(app_secret_enc, 'escape')) > 0`, a.AppSecret); n != 0 {
		t.Fatal("secret stored in clear")
	}
	if n := e.scalar(`SELECT count(*) FROM src.src_sys_loop_audit_log WHERE position($1 in detail_json::text) > 0`, a.AppSecret); n != 0 {
		t.Fatal("secret in the audit log")
	}

	oc := e.openClient(a)
	var products struct {
		Items []productView `json:"items"`
		Total int           `json:"total"`
	}
	oc.must("GET", "/open/v1/products", url.Values{"status": {"on_sale"}, "page": {"1"}}, nil, &products)
	if products.Total != 0 {
		t.Fatalf("products: %+v", products)
	}
	// Signature failures.
	oc.expect("GET", "/open/v1/products", nil, nil, func(h http.Header) { h.Set("X-Loop-Signature", strings.Repeat("0", 64)) }, 401, "invalid_signature")
	oc.expect("GET", "/open/v1/products", nil, nil, func(h http.Header) { h.Del("X-Loop-Nonce") }, 401, "invalid_signature")
	oc.expect("GET", "/open/v1/products", url.Values{"status": {"on_sale"}}, nil, func(h http.Header) { h.Set("X-Loop-Timestamp", "1") }, 401, "timestamp_expired")
	oc.expect("GET", "/open/v1/products", nil, nil, func(h http.Header) { h.Set("X-Loop-App-Id", "lpa_nosuchapp") }, 401, "invalid_app")
	old := oc.ts
	oc.ts = func() int64 { return time.Now().Add(-6 * time.Minute).Unix() }
	oc.expect("GET", "/open/v1/products", nil, nil, nil, 401, "timestamp_expired")
	oc.ts = old
	// A nonce shorter than 16 characters.
	r := oc.call("POST", "/open/v1/products", nil, productBody("package", "开放接口套餐", 5000, nil), func(h http.Header) { h.Set("X-Loop-Nonce", "short") })
	if r.status != 401 || r.code() != "invalid_signature" {
		t.Fatalf("short nonce: %d %s", r.status, r.body)
	}
	// Nonce replay.
	fixedNonce := "6f1c0a9e2b7d4c31"
	nonce := oc.nonce
	oc.nonce = func() string { return fixedNonce }
	oc.must("GET", "/open/v1/products", nil, nil, nil)
	oc.expect("GET", "/open/v1/products", nil, nil, nil, 401, "nonce_reused")
	oc.nonce = nonce
	// Scope.
	oc.expect("GET", "/open/v1/statements", nil, nil, nil, 403, "scope_denied")
	oc.expect("GET", "/open/v1/venues", nil, nil, nil, 403, "scope_denied")

	// Idempotency-Key: the same key returns the first result.
	idem := func(h http.Header) { h.Set("Idempotency-Key", "create-1") }
	r1 := oc.call("POST", "/open/v1/products", nil, productBody("package", "开放接口套餐", 5000, nil), idem)
	r2 := oc.call("POST", "/open/v1/products", nil, productBody("package", "开放接口套餐", 5000, nil), idem)
	var p1, p2 productView
	r1.decode(t, &p1)
	r2.decode(t, &p2)
	if r1.status != 200 || r2.status != 200 || p1.ID == 0 || p1.ID != p2.ID || r2.header.Get("Idempotent-Replayed") != "true" {
		t.Fatalf("idempotency: %d %s / %d %s", r1.status, r1.body, r2.status, r2.body)
	}
	if n := e.scalar(`SELECT count(*) FROM src.src_mer_loop_product WHERE merchant_id=$1`, m1); n != 1 {
		t.Fatalf("products created: %d", n)
	}
	oc.expect("POST", "/open/v1/products", nil, productBody("package", "开放接口套餐", 5000, nil),
		func(h http.Header) { h.Set("Idempotency-Key", strings.Repeat("k", 65)) }, 400, "invalid_request")
	// Product lifecycle through the API; other merchants' data is 404.
	oc.must("POST", fmt.Sprintf("/open/v1/products/%d/submit", p1.ID), nil, nil, &p1)
	stock := 7
	oc.must("PUT", fmt.Sprintf("/open/v1/products/%d/stock", p1.ID), nil, map[string]any{"stock_qty": stock}, &p1)
	if p1.Status != "on_sale" || p1.StockQty == nil || *p1.StockQty != 7 {
		t.Fatalf("open product: %+v", p1)
	}
	other := s2.onSale(productBody("package", "别家的套餐", 5000, nil))
	oc.expect("GET", fmt.Sprintf("/open/v1/products/%d", other.ID), nil, nil, nil, 404, "not_found")
	oc.expect("PATCH", fmt.Sprintf("/open/v1/products/%d", other.ID), nil, map[string]any{"price_amt": 1}, nil, 404, "not_found")

	// Orders, coupon lookup and cashier redemption.
	u, _ := e.member("13800005301")
	o := u.buy(p1.ID, 1)
	var orders struct {
		Items      []productOrderView `json:"items"`
		NextCursor *string            `json:"next_cursor"`
	}
	oc.must("GET", "/open/v1/product-orders", url.Values{"status": {"paid"}}, nil, &orders)
	if len(orders.Items) != 1 || orders.Items[0].ID != o.ID || orders.NextCursor != nil {
		t.Fatalf("open orders: %+v", orders)
	}
	var c productCoupon
	oc.must("POST", "/open/v1/coupons/lookup", nil, map[string]string{"code": o.Coupons[0].Code}, &c)
	if c.ID != o.Coupons[0].ID || c.Status != "unused" {
		t.Fatalf("lookup: %+v", c)
	}
	var rd struct {
		ID     int64         `json:"id"`
		Coupon productCoupon `json:"coupon"`
	}
	oc.must("POST", "/open/v1/redemptions", nil, map[string]string{"code": o.Coupons[0].Code, "store": "收银台"}, &rd)
	if rd.ID == 0 || rd.Coupon.Status != "used" {
		t.Fatalf("open redemption: %+v", rd)
	}
	oc.expect("POST", "/open/v1/redemptions", nil, map[string]string{"code": o.Coupons[0].Code}, nil, 409, "coupon_used")
	ob := u.buy(other.ID, 1)
	oc.expect("POST", "/open/v1/coupons/lookup", nil, map[string]string{"code": ob.Coupons[0].Code}, nil, 404, "not_found")
	var rds struct {
		Items []struct {
			ID int64 `json:"id"`
		} `json:"items"`
	}
	oc.must("GET", "/open/v1/redemptions", url.Values{"from": {clock.Today().Format(time.DateOnly)}}, nil, &rds)
	if len(rds.Items) != 1 || rds.Items[0].ID != rd.ID {
		t.Fatalf("open redemptions: %+v", rds)
	}

	// IP allowlist.
	s1.must("PATCH", fmt.Sprintf("/admin/v1/open-apps/%d", a.ID), map[string]any{"ip_allowlist": []string{"203.0.113.10"}}, nil)
	oc.expect("GET", "/open/v1/products", nil, nil, nil, 403, "ip_not_allowed")
	s1.must("PATCH", fmt.Sprintf("/admin/v1/open-apps/%d", a.ID), map[string]any{"ip_allowlist": []string{"127.0.0.1", "::1"}}, nil)
	oc.must("GET", "/open/v1/products", nil, nil, nil)

	// Rate limit: 120 calls per minute per app, with Retry-After.
	key := fmt.Sprintf("open:rate:%d:%d", a.ID, time.Now().Unix()/60)
	e.app.Redis.Set(context.Background(), key, 120, time.Minute)
	rl := oc.expect("GET", "/open/v1/products", nil, nil, nil, 429, "rate_limited")
	if ra, _ := strconv.Atoi(rl.header.Get("Retry-After")); ra < 1 || ra > 60 {
		t.Fatalf("Retry-After: %q", rl.header.Get("Retry-After"))
	}
	e.app.Redis.Del(context.Background(), key, fmt.Sprintf("open:rate:%d:%d", a.ID, time.Now().Unix()/60))

	// Disabled by the platform: 403 app_disabled; the merchant cannot re-enable.
	ad.must("POST", fmt.Sprintf("/admin/v1/open-apps/%d/disable", a.ID), nil, nil)
	oc.expect("GET", "/open/v1/products", nil, nil, nil, 403, "app_disabled")
	s1.expectErr("POST", fmt.Sprintf("/admin/v1/open-apps/%d/enable", a.ID), nil, 403, "forbidden")
	ad.must("POST", fmt.Sprintf("/admin/v1/open-apps/%d/enable", a.ID), nil, nil)
	oc.must("GET", "/open/v1/products", nil, nil, nil)

	// Reset secret: the old one stops working at once.
	var reset openAppView
	s1.must("POST", fmt.Sprintf("/admin/v1/open-apps/%d/reset-secret", a.ID), nil, &reset)
	oc.expect("GET", "/open/v1/products", nil, nil, nil, 401, "invalid_signature")
	oc.secret = reset.AppSecret
	oc.must("GET", "/open/v1/products", nil, nil, nil)

	// Call log (7 days, no bodies).
	var calls struct {
		Items []struct {
			Method     string  `json:"method"`
			Path       string  `json:"path"`
			StatusCode int     `json:"status_code"`
			ErrorCode  *string `json:"error_code"`
		} `json:"items"`
		Total int `json:"total"`
	}
	s1.must("GET", fmt.Sprintf("/admin/v1/open-apps/%d/calls?page_size=100", a.ID), nil, &calls)
	codes := map[string]bool{}
	for _, x := range calls.Items {
		if x.ErrorCode != nil {
			codes[*x.ErrorCode] = true
		}
	}
	for _, want := range []string{"invalid_signature", "timestamp_expired", "nonce_reused", "scope_denied", "ip_not_allowed", "rate_limited", "app_disabled"} {
		if !codes[want] {
			t.Fatalf("call log misses %s: %+v", want, calls)
		}
	}
	s2.expectErr("GET", fmt.Sprintf("/admin/v1/open-apps/%d/calls", a.ID), nil, 404, "not_found")
	e.sql(`UPDATE src.src_mer_loop_open_call_log SET create_time=now() - interval '8 days'`)
	e.job("open_call_log_cleanup")
	if n := e.scalar(`SELECT count(*) FROM src.src_mer_loop_open_call_log`); n != 0 {
		t.Fatalf("call log kept %d rows", n)
	}
	// At most 5 apps per merchant.
	for i := 0; i < 4; i++ {
		s1.must("POST", "/admin/v1/open-apps", map[string]any{"name": fmt.Sprintf("应用%d", i), "scopes": []string{"products"}}, nil)
	}
	s1.expectErr("POST", "/admin/v1/open-apps", map[string]any{"name": "第六个", "scopes": []string{"products"}}, 409, "app_limit")
	if st := s1.do("DELETE", fmt.Sprintf("/admin/v1/open-apps/%d", a.ID), nil, nil); st != 204 {
		t.Fatalf("delete app: %d", st)
	}
	oc.expect("GET", "/open/v1/products", nil, nil, nil, 401, "invalid_app")
}

// ---------------------------------------------------------------- webhooks

func TestWebhookDeliveryAndRetry(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)
	m1 := e.merchant("跑野运动馆")
	s1 := e.staff(ad, "pstaff1", m1)
	hook := newHookServer(t)
	var a, noScope openAppView
	s1.must("POST", "/admin/v1/open-apps", map[string]any{"name": "收银系统", "scopes": []string{"products", "orders"}, "webhook_url": hook.URL,
		"webhook_events": []string{"product_order.paid", "product.reviewed"}}, &a)
	// Subscribed to redemptions without the scope: never receives them.
	s1.must("POST", "/admin/v1/open-apps", map[string]any{"name": "ERP", "scopes": []string{"orders"}, "webhook_url": hook.URL,
		"webhook_events": []string{"redemption.created", "product_order.paid"}}, &noScope)

	p := s1.onSale(productBody("package", "羽毛球 2 小时畅打套餐", 6900, nil))
	u, _ := e.member("13800005401")
	o := u.buy(p.ID, 1)
	s1.must("POST", "/admin/v1/redemptions", map[string]string{"code": o.Coupons[0].Code}, nil)
	e.job("webhook_deliver")
	got := hook.received()
	types := map[string]int{}
	for _, rq := range got {
		types[rq.header.Get("X-Loop-Event")]++
	}
	// product.reviewed (app A), product_order.paid (A and ERP); no redemption.created.
	if len(got) != 3 || types["product.reviewed"] != 1 || types["product_order.paid"] != 2 || types["redemption.created"] != 0 {
		t.Fatalf("deliveries: %v", types)
	}
	var paid *hookReq
	for i := range got {
		if got[i].header.Get("X-Loop-Event") == "product_order.paid" && got[i].header.Get("X-Loop-Signature") != "" {
			var body struct {
				ID         string `json:"id"`
				Type       string `json:"type"`
				MerchantID int64  `json:"merchant_id"`
				Data       struct {
					ID int64 `json:"id"`
				} `json:"data"`
			}
			_ = json.Unmarshal(got[i].body, &body)
			ts := got[i].header.Get("X-Loop-Timestamp")
			m := hmac.New(sha256.New, []byte(a.AppSecret))
			m.Write([]byte(ts + "." + string(got[i].body)))
			if got[i].header.Get("X-Loop-Signature") == hex.EncodeToString(m.Sum(nil)) {
				if !strings.HasPrefix(body.ID, "evt_") || body.Type != "product_order.paid" || body.MerchantID != m1 || body.Data.ID != o.ID ||
					got[i].header.Get("X-Loop-Delivery") == "" {
					t.Fatalf("paid event: %s", got[i].body)
				}
				paid = &got[i]
			}
		}
	}
	if paid == nil {
		t.Fatal("no product_order.paid signed with app A's secret")
	}
	var ds struct {
		Items []deliveryView `json:"items"`
		Total int            `json:"total"`
	}
	s1.must("GET", fmt.Sprintf("/admin/v1/open-apps/%d/deliveries", a.ID), nil, &ds)
	if ds.Total != 2 || ds.Items[0].Status != "succeeded" || ds.Items[0].AttemptQty != 1 {
		t.Fatalf("delivery records: %+v", ds)
	}
	e.job("webhook_deliver") // nothing left
	if n := len(hook.received()); n != 3 {
		t.Fatalf("redelivered without cause: %d", n)
	}

	// A failing receiver: 6 attempts on the 1m / 5m / 30m / 2h / 6h schedule, then failed.
	hook.setFail(true)
	u.buy(p.ID, 1)
	var d deliveryView
	waits := []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute, 2 * time.Hour, 6 * time.Hour}
	for attempt := 1; attempt <= 6; attempt++ {
		e.job("webhook_deliver")
		s1.must("GET", fmt.Sprintf("/admin/v1/open-apps/%d/deliveries", a.ID), nil, &ds)
		d = ds.Items[0]
		if d.AttemptQty != attempt {
			t.Fatalf("attempt %d: %+v", attempt, d)
		}
		if attempt < 6 {
			wait := time.Duration(e.scalar(`SELECT extract(epoch FROM next_retry_time - last_attempt_time)::bigint FROM src.src_mer_loop_webhook_delivery WHERE id=$1`, d.ID)) * time.Second
			if d.Status != "pending" || wait < waits[attempt-1]-5*time.Second || wait > waits[attempt-1]+5*time.Second {
				t.Fatalf("attempt %d: %+v, next in %s", attempt, d, wait)
			}
			e.sql(`UPDATE src.src_mer_loop_webhook_delivery SET next_retry_time=now() WHERE id=$1`, d.ID)
		}
	}
	if d.Status != "failed" {
		t.Fatalf("after 6 attempts: %+v", d)
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
		found = found || (td.Type == "webhook_failed" && td.Count == 1) // app A (ERP is still retrying)
	}
	if !found {
		t.Fatalf("dashboard: %+v", dash)
	}
	s1.must("GET", "/admin/v1/dashboard", nil, &dash)
	for _, td := range dash.Todos {
		if td.Type == "webhook_failed" {
			t.Fatal("webhook_failed shown to merchant staff")
		}
	}
	// Manual redelivery once the receiver is back.
	hook.setFail(false)
	var re deliveryView
	s1.must("POST", fmt.Sprintf("/admin/v1/open-apps/%d/deliveries/%d/redeliver", a.ID, d.ID), nil, &re)
	if re.Status != "succeeded" || re.AttemptQty != 7 {
		t.Fatalf("redeliver: %+v", re)
	}
	// Test ping.
	var ping deliveryView
	s1.must("POST", fmt.Sprintf("/admin/v1/open-apps/%d/test-webhook", a.ID), nil, &ping)
	if ping.Status != "succeeded" || ping.EventType != "ping" {
		t.Fatalf("ping: %+v", ping)
	}
	// Disabled apps get nothing.
	s1.must("POST", fmt.Sprintf("/admin/v1/open-apps/%d/disable", a.ID), nil, nil)
	before := len(hook.received())
	u.buy(p.ID, 1)
	e.job("webhook_deliver")
	for _, rq := range hook.received()[before:] {
		if rq.header.Get("X-Loop-Delivery") != "" {
			var n int64
			id, _ := strconv.ParseInt(rq.header.Get("X-Loop-Delivery"), 10, 64)
			n = e.scalar(`SELECT open_app_id FROM src.src_mer_loop_webhook_delivery WHERE id=$1`, id)
			if n == a.ID {
				t.Fatal("delivered to a disabled app")
			}
		}
	}
}

// ---------------------------------------------------------------- venues: self-service and blocks

func TestOpenVenuesAndBlocks(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)
	m1, m2 := e.merchant("跑野运动馆"), e.merchant("滨江网球")
	s1, s2 := e.staff(ad, "pstaff1", m1), e.staff(ad, "pstaff2", m2)
	var va venueView
	ad.must("POST", "/admin/v1/venues", venueBody("跑野 · 张江", &m1, 0, 0, true), &va)

	// Merchant self-service PATCH: whitelisted fields only, own venues only.
	var own venueView
	s1.must("PATCH", fmt.Sprintf("/admin/v1/venues/%d", va.ID), map[string]any{"price_amt": 8000, "tags": []string{"室内", "空调"}}, &own)
	if own.PriceAmt == nil || *own.PriceAmt != 8000 {
		t.Fatalf("self patch: %+v", own)
	}
	s1.expectErr("PATCH", fmt.Sprintf("/admin/v1/venues/%d", va.ID), map[string]any{"name": "改名"}, 403, "field_not_allowed")
	s1.expectErr("PATCH", fmt.Sprintf("/admin/v1/venues/%d", va.ID), map[string]any{"price_amt": 1, "merchant_id": m2}, 403, "field_not_allowed")
	s2.expectErr("PATCH", fmt.Sprintf("/admin/v1/venues/%d", va.ID), map[string]any{"price_amt": 1}, 404, "not_found")
	s2.expectErr("GET", fmt.Sprintf("/admin/v1/venues/%d", va.ID), nil, 404, "not_found")
	s1.must("GET", fmt.Sprintf("/admin/v1/venues/%d", va.ID), nil, &own)

	var a openAppView
	s1.must("POST", "/admin/v1/open-apps", map[string]any{"name": "自有订场系统", "scopes": []string{"venues", "bookings"}}, &a)
	oc := e.openClient(a)
	var vs struct {
		Items []venueView `json:"items"`
	}
	oc.must("GET", "/open/v1/venues", nil, nil, &vs)
	if len(vs.Items) != 1 || vs.Items[0].ID != va.ID {
		t.Fatalf("open venues: %+v", vs)
	}
	oc.expect("PATCH", fmt.Sprintf("/open/v1/venues/%d", va.ID), nil, map[string]any{"address": "x"}, nil, 403, "field_not_allowed")
	oc.must("PATCH", fmt.Sprintf("/open/v1/venues/%d", va.ID), nil, map[string]any{"court_qty": 2}, nil)

	day := clock.Today().AddDate(0, 0, 1).Format(time.DateOnly)
	path := fmt.Sprintf("/open/v1/venues/%d/blocks", va.ID)
	oc.expect("POST", path, nil, map[string]any{"date": day, "start": "18:30", "end": "20:00"}, nil, 400, "invalid_slot")
	oc.expect("POST", path, nil, map[string]any{"date": day, "start": "06:00", "end": "08:00"}, nil, 400, "invalid_slot")
	oc.expect("POST", path, nil, map[string]any{"date": "tomorrow", "start": "18:00", "end": "20:00"}, nil, 400, "invalid_date")
	var b1, again struct {
		ID          int64   `json:"id"`
		VenueID     int64   `json:"venue_id"`
		Date        string  `json:"date"`
		Start       string  `json:"start"`
		End         string  `json:"end"`
		CourtQty    int     `json:"court_qty"`
		ExternalRef *string `json:"external_ref"`
	}
	oc.must("POST", path, nil, map[string]any{"date": day, "start": "18:00", "end": "20:00", "court_qty": 2, "external_ref": "POS-8812", "note": "前台订场"}, &b1)
	if b1.Start != "18:00" || b1.End != "20:00" || b1.CourtQty != 2 || b1.Date != day || b1.ExternalRef == nil || *b1.ExternalRef != "POS-8812" {
		t.Fatalf("block: %+v", b1)
	}
	oc.must("POST", path, nil, map[string]any{"date": day, "start": "18:00", "end": "20:00", "court_qty": 2, "external_ref": "POS-8812"}, &again)
	if again.ID != b1.ID {
		t.Fatalf("same external_ref: %+v", again)
	}
	oc.expect("POST", path, nil, map[string]any{"date": day, "start": "19:00", "end": "20:00", "external_ref": "POS-8813"}, nil, 409, "slot_full")

	// The app cannot book blocked slots.
	u, _ := e.member("13800005501")
	slots := func() map[string]bool {
		var res struct {
			Items []slotView `json:"items"`
		}
		u.must("GET", fmt.Sprintf("/v1/venues/%d/slots?date=%s", va.ID, day), nil, &res)
		out := map[string]bool{}
		for _, s := range res.Items {
			out[s.StartTime.In(clock.Shanghai).Format("15:04")] = s.Available
		}
		return out
	}
	av := slots()
	if av["18:00"] || av["19:00"] || !av["17:00"] || !av["20:00"] {
		t.Fatalf("slots with block: %v", av)
	}
	u.must("POST", "/v1/me/realname", map[string]string{"name": "张三", "id_number": idNumber("19900307")}, nil)
	start, _ := time.ParseInLocation("2006-01-02 15:04", day+" 18:00", clock.Shanghai)
	u.expectErr("POST", "/v1/bookings", map[string]any{"venue_id": va.ID, "start_time": start, "slots": 1, "channel": "mock"}, 409, "slot_unavailable")
	var ob struct {
		Items []slotView `json:"items"`
	}
	oc.must("GET", fmt.Sprintf("/open/v1/venues/%d/slots", va.ID), url.Values{"date": {day}}, nil, &ob)
	var blocks struct {
		Items []struct {
			ID int64 `json:"id"`
		} `json:"items"`
	}
	s1.must("GET", fmt.Sprintf("/admin/v1/venues/%d/blocks?date=%s", va.ID, day), nil, &blocks)
	if len(blocks.Items) != 1 {
		t.Fatalf("admin blocks: %+v", blocks)
	}
	oc.must("GET", path, url.Values{"date": {day}}, nil, &blocks)
	if len(blocks.Items) != 1 {
		t.Fatalf("open blocks: %+v", blocks)
	}
	r := oc.call("DELETE", fmt.Sprintf("%s/%d", path, b1.ID), nil, nil, nil)
	if r.status != 204 {
		t.Fatalf("delete block: %d %s", r.status, r.body)
	}
	if av := slots(); !av["18:00"] || !av["19:00"] {
		t.Fatalf("slots after release: %v", av)
	}
	// Bookings through the API (own merchant only), cursor pages.
	var bk bookingCreated
	u.must("POST", "/v1/bookings", map[string]any{"venue_id": va.ID, "start_time": start, "slots": 1, "channel": "mock"}, &bk)
	var obs struct {
		Items      []bookingView `json:"items"`
		NextCursor *string       `json:"next_cursor"`
	}
	oc.must("GET", "/open/v1/bookings", url.Values{"venue_id": {strconv.FormatInt(va.ID, 10)}, "date": {day}}, nil, &obs)
	if len(obs.Items) != 1 || obs.Items[0].ID != bk.Booking.ID || obs.NextCursor != nil {
		t.Fatalf("open bookings: %+v", obs)
	}
	oc.must("GET", fmt.Sprintf("/open/v1/bookings/%d", bk.Booking.ID), nil, nil, nil)
	var other openAppView
	s2.must("POST", "/admin/v1/open-apps", map[string]any{"name": "别家", "scopes": []string{"venues", "bookings"}}, &other)
	oc2 := e.openClient(other)
	oc2.expect("GET", fmt.Sprintf("/open/v1/bookings/%d", bk.Booking.ID), nil, nil, nil, 404, "not_found")
	oc2.expect("POST", path, nil, map[string]any{"date": day, "start": "10:00", "end": "11:00"}, nil, 404, "not_found")
}
