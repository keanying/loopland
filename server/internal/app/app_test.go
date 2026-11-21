package app

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"

	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/platform/config"
	"github.com/keanying/loopland/server/internal/platform/testdb"
)

// ---------------------------------------------------------------- harness

type env struct {
	t   *testing.T
	srv *httptest.Server
	app *App
}

func newEnv(t *testing.T) *env {
	pool := testdb.New(t)
	url := os.Getenv("LOOPLAND_TEST_REDIS_URL")
	if url == "" {
		url = "redis://localhost:6379/15"
	}
	opts, _ := redis.ParseURL(url)
	rdb := redis.NewClient(opts)
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		if os.Getenv("LOOPLAND_TEST_REQUIRE_DB") == "1" {
			t.Fatal(err)
		}
		t.Skip("no redis:", err)
	}
	rdb.FlushDB(context.Background())
	t.Setenv("LOOPLAND_ENV", "dev")
	t.Setenv("LOOPLAND_BOOTSTRAP_ADMIN", "root:root-password-123")
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	cfg.BootstrapAdmin = "root:root-password-123"
	var logOut io.Writer = io.Discard
	if os.Getenv("LOOPLAND_TEST_LOG") == "1" {
		logOut = os.Stderr
	}
	log := slog.New(slog.NewTextHandler(logOut, nil))
	a, err := New(context.Background(), cfg, pool, rdb, log, Options{})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(a.Handler)
	hubCtx, stopHub := context.WithCancel(context.Background())
	go a.Hub.Run(hubCtx)
	t.Cleanup(func() { stopHub(); srv.Close(); rdb.Close() })
	return &env{t: t, srv: srv, app: a}
}

type client struct {
	e     *env
	token string
	hdr   map[string]string
}

func (e *env) anon() *client { return &client{e: e} }

// do sends a request and decodes the response into out (if non-nil).
func (c *client) do(method, path string, body, out any) int {
	c.e.t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, c.e.srv.URL+path, rd)
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	for k, v := range c.hdr {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.e.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if out != nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, out); err != nil {
			c.e.t.Fatalf("%s %s: decode %q: %v", method, path, raw, err)
		}
	}
	return resp.StatusCode
}

// must is do() that fails the test unless the status is 200.
func (c *client) must(method, path string, body, out any) {
	c.e.t.Helper()
	var raw json.RawMessage
	if st := c.do(method, path, body, &raw); st != http.StatusOK {
		c.e.t.Fatalf("%s %s: status %d: %s", method, path, st, raw)
	}
	if out != nil {
		if err := json.Unmarshal(raw, out); err != nil {
			c.e.t.Fatal(err)
		}
	}
}

type apiErr struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func (c *client) expectErr(method, path string, body any, status int, code string) {
	c.e.t.Helper()
	var e apiErr
	if st := c.do(method, path, body, &e); st != status || e.Error.Code != code {
		c.e.t.Fatalf("%s %s: got %d %q, want %d %q (%s)", method, path, st, e.Error.Code, status, code, e.Error.Message)
	}
}

type authResult struct {
	AccessToken   string `json:"access_token"`
	RefreshToken  string `json:"refresh_token"`
	IsNew         bool   `json:"is_new"`
	NeedBindPhone bool   `json:"need_bind_phone"`
	User          struct {
		ID     int64  `json:"id"`
		Energy int    `json:"energy"`
		Status string `json:"status"`
	} `json:"user"`
}

func (e *env) smsLogin(phone string) (*client, authResult) {
	c := e.anon()
	c.must("POST", "/v1/auth/sms/send", map[string]string{"phone": phone}, nil)
	var res authResult
	c.must("POST", "/v1/auth/login", map[string]any{"provider": "sms", "credential": map[string]string{"phone": phone, "code": "000000"},
		"device_id": "dev-" + phone, "platform": "android"}, &res)
	c.token = res.AccessToken
	return c, res
}

func (c *client) consent() {
	c.must("POST", "/v1/me/consents", map[string]any{"privacy_version": "2026-11", "location": true, "health": true}, nil)
}

var origin = geo.LatLng{Lat: 31.2304, Lng: 121.4737}

type pt struct {
	T   int64   `json:"t"`
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
	Src string  `json:"src,omitempty"`
}

// run walks the waypoints (metres from origin) at speed m/s, sampling every
// 5 m, and returns the upload body.
func run(speed float64, waypoints ...[2]float64) map[string]any {
	proj := geo.NewProjection(origin)
	start := time.Now().Add(-2 * time.Hour)
	var pts []pt
	t := 0.0
	add := func(x, y float64) {
		ll := proj.Inverse(geo.Point{X: x, Y: y})
		pts = append(pts, pt{T: start.Add(time.Duration(t * float64(time.Second))).UnixMilli(), Lat: ll.Lat, Lng: ll.Lng, Src: "gps"})
	}
	add(waypoints[0][0], waypoints[0][1])
	for i := 1; i < len(waypoints); i++ {
		a, b := waypoints[i-1], waypoints[i]
		d := math.Hypot(b[0]-a[0], b[1]-a[1])
		n := int(math.Ceil(d / 5))
		for k := 1; k <= n; k++ {
			f := float64(k) / float64(n)
			t += d / float64(n) / speed
			add(a[0]+(b[0]-a[0])*f, a[1]+(b[1]-a[1])*f)
		}
	}
	end := start.Add(time.Duration(t * float64(time.Second)))
	return map[string]any{"client_id": uuid.NewString(), "sport": "run", "started_at": start, "ended_at": end,
		"duration_s": int(t), "points": pts, "device": map[string]any{"id": "device-1", "model": "test", "os": "test"}}
}

type settlement struct {
	Activity struct {
		ID     int64  `json:"id"`
		Status string `json:"status"`
	} `json:"activity"`
	Settlement struct {
		Status        string `json:"status"`
		EnergyRaw     int    `json:"energy_raw"`
		EnergyGranted int    `json:"energy_granted"`
		Claims        []struct {
			TerritoryID int64   `json:"territory_id"`
			Kind        string  `json:"kind"`
			AreaM2      float64 `json:"area_m2"`
		} `json:"claims"`
		Attacks []struct {
			TerritoryID int64 `json:"territory_id"`
			Captured    bool  `json:"captured"`
			GuardBefore int   `json:"guard_before"`
			GuardAfter  int   `json:"guard_after"`
		} `json:"attacks"`
		Eggs []struct {
			Key string `json:"key"`
		} `json:"eggs"`
		Flags []struct {
			Rule string `json:"rule"`
		} `json:"flags"`
	} `json:"settlement"`
}

// idNumber builds a checksum-valid 18-digit ID for a birth date.
func idNumber(birth string) string {
	base := "110105" + birth + "123"
	w := []int{7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2}
	s := 0
	for i := 0; i < 17; i++ {
		s += int(base[i]-'0') * w[i]
	}
	return base + string("10X98765432"[s%11])
}

func (e *env) sql(q string, args ...any) {
	if _, err := e.app.Pool.Exec(context.Background(), q, args...); err != nil {
		e.t.Fatal(err)
	}
}

// ---------------------------------------------------------------- scenario

func TestEndToEnd(t *testing.T) {
	e := newEnv(t)

	var feats struct {
		Login   []string `json:"login"`
		Pay     []string `json:"pay"`
		Captcha bool     `json:"captcha"`
	}
	e.anon().must("GET", "/v1/config/features", nil, &feats)
	if len(feats.Login) != 4 || feats.Captcha || !slices.Contains(feats.Pay, "mock") || !slices.Contains(feats.Pay, "apple_iap") {
		t.Fatalf("features: %+v", feats)
	}

	// --- A signs up with SMS, must consent before uploading.
	a, ares := e.smsLogin("13800000001")
	if !ares.IsNew || ares.NeedBindPhone {
		t.Fatalf("login: %+v", ares)
	}
	square := [][2]float64{{0, 0}, {300, 0}, {300, 300}, {150, 300}, {150, -50}}
	body := run(3, square...)
	a.expectErr("POST", "/v1/activities", body, 403, "consent_required")
	a.consent()

	var s1 settlement
	a.must("POST", "/v1/activities", body, &s1)
	if s1.Settlement.Status != "settled" || len(s1.Settlement.Claims) != 1 || s1.Settlement.Claims[0].Kind != "claim" {
		t.Fatalf("first run: %+v", s1.Settlement)
	}
	if area := s1.Settlement.Claims[0].AreaM2; area < 44000 || area > 46000 {
		t.Fatalf("claimed area %.0f, want ≈ 45000", area)
	}
	if g := s1.Settlement.EnergyGranted; g < 10 || g > 11 { // ≈1100 m
		t.Fatalf("energy %d", s1.Settlement.EnergyGranted)
	}
	if len(s1.Settlement.Eggs) != 1 || s1.Settlement.Eggs[0].Key != "gecko" {
		t.Fatalf("first land egg: %+v", s1.Settlement.Eggs)
	}
	tid := s1.Settlement.Claims[0].TerritoryID

	// Idempotent re-upload.
	var again settlement
	a.must("POST", "/v1/activities", body, &again)
	if again.Activity.ID != s1.Activity.ID || len(again.Settlement.Claims) != 1 {
		t.Fatalf("idempotency: %+v vs %+v", again.Activity, s1.Activity)
	}

	// Map viewport.
	var vp struct {
		Items []struct {
			ID       int64  `json:"id"`
			Relation string `json:"relation"`
		} `json:"items"`
	}
	a.must("GET", "/v1/territories?bbox=121.46,31.22,121.49,31.24&scope=all", nil, &vp)
	if len(vp.Items) != 1 || vp.Items[0].Relation != "mine" {
		t.Fatalf("viewport: %+v", vp)
	}

	// Build: not enough energy, then with energy.
	a.expectErr("POST", fmt.Sprintf("/v1/territories/%d/buildings", tid), map[string]any{"slot": 0, "building": "campfire"}, 403, "not_enough_energy")
	e.sql(`UPDATE src.src_usr_user SET energy=500 WHERE id=$1`, ares.User.ID)
	a.expectErr("POST", fmt.Sprintf("/v1/territories/%d/buildings", tid), map[string]any{"slot": 0, "building": "tower"}, 403, "level_too_low")
	var built struct {
		Territory struct {
			Guard       int `json:"guard"`
			DailyEnergy int `json:"daily_energy"`
		} `json:"territory"`
		Energy int `json:"energy"`
	}
	a.must("POST", fmt.Sprintf("/v1/territories/%d/buildings", tid), map[string]any{"slot": 0, "building": "campfire"}, &built)
	if built.Territory.Guard != 50 || built.Energy != 420 || built.Territory.DailyEnergy != 10 {
		t.Fatalf("built: %+v", built)
	}
	a.expectErr("POST", fmt.Sprintf("/v1/territories/%d/buildings", tid), map[string]any{"slot": 0, "building": "tent"}, 409, "slot_taken")

	// --- B signs up with WeChat: must bind a phone first.
	b := e.anon()
	var bres authResult
	b.must("POST", "/v1/auth/login", map[string]any{"provider": "wechat", "credential": map[string]string{"code": "dev:openid-b"}, "device_id": "dev-b"}, &bres)
	if !bres.NeedBindPhone {
		t.Fatal("wechat login needs phone binding")
	}
	b.token = bres.AccessToken
	b.expectErr("GET", "/v1/codex", nil, 403, "phone_required")
	b.expectErr("POST", "/v1/me/phone", map[string]string{"phone": "13800000001", "code": "000000"}, 409, "phone_taken")
	b.must("POST", "/v1/me/phone", map[string]string{"phone": "13800000002", "code": "000000"}, nil)
	b.must("GET", "/v1/codex", nil, nil)
	b.consent()

	// B runs across A's land with less energy than its guard: weakens it.
	var s2 settlement
	b.must("POST", "/v1/activities", run(3, [2]float64{200, 100}, [2]float64{500, 100}, [2]float64{500, 200}, [2]float64{250, 200}, [2]float64{250, 50}), &s2)
	if len(s2.Settlement.Attacks) != 1 || s2.Settlement.Attacks[0].Captured || s2.Settlement.Attacks[0].GuardBefore != 50 {
		t.Fatalf("attack: %+v", s2.Settlement.Attacks)
	}
	var inbox struct {
		Unread int `json:"unread"`
		Items  []struct {
			Title string `json:"title"`
		} `json:"items"`
	}
	a.must("GET", "/v1/inbox?category=territory", nil, &inbox)
	if inbox.Unread < 1 || inbox.Items[0].Title != "领地被削弱" {
		t.Fatalf("inbox: %+v", inbox)
	}

	// B drives a car: voided automatically with an alert.
	var s3 settlement
	b.must("POST", "/v1/activities", run(15, [2]float64{1000, 1000}, [2]float64{2000, 1000}, [2]float64{2000, 1500}, [2]float64{1500, 1500}, [2]float64{1500, 900}), &s3)
	if s3.Settlement.Status != "voided" || s3.Settlement.Flags[0].Rule != "speed" {
		t.Fatalf("cheat: %+v", s3.Settlement)
	}
	// B runs a bit fast: goes to review.
	var s4 settlement
	b.must("POST", "/v1/activities", run(6.5, [2]float64{1000, -1000}, [2]float64{1400, -1000}, [2]float64{1400, -700}, [2]float64{1200, -700}, [2]float64{1200, -1100}), &s4)
	if s4.Settlement.Status != "review" || len(s4.Settlement.Claims) != 0 {
		t.Fatalf("review: %+v", s4.Settlement)
	}

	// --- Admin.
	ad := e.anon()
	var login struct {
		Token string `json:"token"`
	}
	ad.expectErr("POST", "/admin/v1/login", map[string]string{"username": "root", "password": "nope"}, 401, "invalid_credentials")
	ad.must("POST", "/admin/v1/login", map[string]string{"username": "root", "password": "root-password-123"}, &login)
	ad.token = login.Token
	a.expectErr("GET", "/admin/v1/dashboard", nil, 401, "unauthorized") // app tokens don't work

	var dash struct {
		Today struct {
			Activities  int `json:"activities"`
			PendingRisk int `json:"pending_risk"`
		} `json:"today"`
		Trend struct {
			Days []string `json:"days"`
		} `json:"trend"`
	}
	ad.must("GET", "/admin/v1/dashboard", nil, &dash)
	if dash.Today.PendingRisk != 1 || // only the review run; the voided one is auto-resolved
		len(dash.Trend.Days) != 30 {
		t.Fatalf("dashboard: %+v", dash)
	}

	var ul struct {
		Items []struct {
			PhoneMasked *string `json:"phone_masked"`
		} `json:"items"`
	}
	ad.must("GET", "/admin/v1/users?q=0001", nil, &ul)
	if len(ul.Items) != 1 || ul.Items[0].PhoneMasked == nil || *ul.Items[0].PhoneMasked != "138****0001" {
		t.Fatalf("admin user list masking: %+v", ul)
	}

	var alerts struct {
		Items []struct {
			ID         int64   `json:"id"`
			ActivityID int64   `json:"activity_id"`
			Type       string  `json:"type"`
			Confidence float64 `json:"confidence"`
		} `json:"items"`
		Total int `json:"total"`
	}
	ad.must("GET", "/admin/v1/risk/alerts?status=open", nil, &alerts)
	var reviewAlert int64
	for _, al := range alerts.Items {
		if al.ActivityID == s4.Activity.ID {
			reviewAlert = al.ID
		}
	}
	if reviewAlert == 0 || alerts.Items[0].Confidence < alerts.Items[len(alerts.Items)-1].Confidence {
		t.Fatalf("alerts: %+v", alerts)
	}
	var detail struct {
		Speeds []struct {
			Over bool `json:"over"`
		} `json:"speeds"`
		Sources map[string]int `json:"sources"`
	}
	ad.must("GET", fmt.Sprintf("/admin/v1/risk/alerts/%d", reviewAlert), nil, &detail)
	if len(detail.Speeds) == 0 || !detail.Speeds[0].Over || detail.Sources["gps"] == 0 {
		t.Fatalf("evidence: %+v", detail)
	}
	// False positive: the reviewed run gets settled and claims land.
	ad.must("POST", fmt.Sprintf("/admin/v1/risk/alerts/%d/resolve", reviewAlert), map[string]string{"action": "false_positive"}, nil)
	var act struct {
		Status        string  `json:"status"`
		ClaimedAreaM2 float64 `json:"claimed_area_m2"`
		Claims        []struct {
			TerritoryID int64 `json:"territory_id"`
		} `json:"claims"`
	}
	b.must("GET", fmt.Sprintf("/v1/activities/%d", s4.Activity.ID), nil, &act)
	if act.Status != "settled" || act.ClaimedAreaM2 < 50000 {
		t.Fatalf("released activity: %+v", act)
	}

	// Void B's first (settled) run: A's guard comes back.
	var aid int64
	e.app.Pool.QueryRow(context.Background(), `INSERT INTO src.src_ris_alert (activity_id, user_id, alert_type, confidence, detail) VALUES ($1,$2,'multi_account',0.5,'x') RETURNING id`,
		s2.Activity.ID, bres.User.ID).Scan(&aid)
	ad.must("POST", fmt.Sprintf("/admin/v1/risk/alerts/%d/resolve", aid), map[string]string{"action": "void"}, nil)
	var terr struct {
		Guard int `json:"guard"`
	}
	a.must("GET", fmt.Sprintf("/v1/territories/%d", tid), nil, &terr)
	if terr.Guard != 50 {
		t.Fatalf("guard after rollback = %d", terr.Guard)
	}

	// Territory admin: guard step validation and freeze.
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/territories/%d/guard", tid), map[string]int{"guard": 75}, 400, "invalid_guard")
	ad.must("POST", fmt.Sprintf("/admin/v1/territories/%d/guard", tid), map[string]int{"guard": 500}, nil)
	ad.must("POST", fmt.Sprintf("/admin/v1/territories/%d/freeze", tid), map[string]bool{"frozen": true}, nil)
	a.expectErr("POST", fmt.Sprintf("/v1/territories/%d/buildings", tid), map[string]any{"slot": 1, "building": "campfire"}, 403, "frozen")
	var tl struct {
		Total int `json:"total"`
	}
	ad.must("GET", "/admin/v1/territories?status=frozen", nil, &tl)
	ad.must("GET", "/admin/v1/territories?status=frozen&q=1", nil, nil) // ILIKE % in a formatted query
	ad.must("GET", "/admin/v1/users?filter=today&q=0001", nil, nil)
	if tl.Total != 1 {
		t.Fatalf("frozen list: %+v", tl)
	}

	// --- Billing with the mock channel.
	a.expectErr("POST", "/v1/orders", map[string]string{"plan_code": "auto_month", "channel": "mock"}, 403, "realname_required")
	a.expectErr("POST", "/v1/me/realname", map[string]string{"name": "张三", "id_number": "110105199003071230"}, 400, "realname_failed")
	a.must("POST", "/v1/me/realname", map[string]string{"name": "张三", "id_number": idNumber("19900307")}, nil)
	var plans struct {
		Items []struct {
			Code          string `json:"code"`
			FirstPriceFen *int   `json:"first_price_fen"`
		} `json:"items"`
	}
	a.must("GET", "/v1/plans", nil, &plans)
	if len(plans.Items) != 5 || plans.Items[0].Code != "auto_month" {
		t.Fatalf("plans: %+v", plans)
	}
	a.hdr = map[string]string{"X-Platform": "ios"}
	a.expectErr("POST", "/v1/orders", map[string]string{"plan_code": "auto_month", "channel": "alipay_app"}, 400, "channel_not_allowed")
	a.hdr = nil
	var ord struct {
		Order struct {
			OrderNo   string `json:"order_no"`
			AmountFen int    `json:"amount_fen"`
			Status    string `json:"status"`
		} `json:"order"`
	}
	a.must("POST", "/v1/orders", map[string]string{"plan_code": "auto_month", "channel": "mock"}, &ord)
	if ord.Order.AmountFen != 1500 {
		t.Fatalf("first-period price: %+v", ord)
	}
	a.must("POST", "/v1/dev/orders/"+ord.Order.OrderNo+"/pay", nil, nil)
	a.must("POST", "/v1/dev/orders/"+ord.Order.OrderNo+"/pay", nil, nil) // duplicate callback is harmless
	var mem struct {
		Active    bool `json:"active"`
		AutoRenew bool `json:"auto_renew"`
	}
	a.must("GET", "/v1/membership", nil, &mem)
	if !mem.Active || !mem.AutoRenew {
		t.Fatalf("membership: %+v", mem)
	}
	a.must("POST", "/v1/membership/auto-renew", map[string]bool{"enabled": false}, &mem)
	if mem.AutoRenew {
		t.Fatal("auto-renew off")
	}
	// Second purchase pays the full price.
	a.must("POST", "/v1/orders", map[string]string{"plan_code": "auto_month", "channel": "mock"}, &ord)
	if ord.Order.AmountFen != 1800 {
		t.Fatalf("renewal price: %+v", ord)
	}
	// Refund the first order: admin only, needs confirm.
	var orders struct {
		Items []struct {
			OrderNo string `json:"order_no"`
			Status  string `json:"status"`
		} `json:"items"`
	}
	ad.must("GET", "/admin/v1/orders?status=paid", nil, &orders)
	if len(orders.Items) != 1 {
		t.Fatalf("paid orders: %+v", orders)
	}
	ad.expectErr("POST", "/admin/v1/orders/"+orders.Items[0].OrderNo+"/refund", map[string]any{"reason": "x"}, 400, "confirm_required")
	ad.must("POST", "/admin/v1/orders/"+orders.Items[0].OrderNo+"/refund", map[string]any{"reason": "用户申请", "confirm": true}, nil)
	a.must("GET", "/v1/membership", nil, &mem)
	if mem.Active {
		t.Fatal("membership revoked after refund")
	}
	ad.expectErr("PUT", "/admin/v1/plans/month/entitlements", map[string]any{"entitlements": []string{"guard_bonus"}}, 400, "entitlement_locked")

	// Minors see no plans.
	b.must("POST", "/v1/me/realname", map[string]string{"name": "李四", "id_number": idNumber("20150101")}, nil)
	var bp struct {
		MinorBlocked bool `json:"minor_blocked"`
	}
	b.must("GET", "/v1/plans", nil, &bp)
	if !bp.MinorBlocked {
		t.Fatal("minor should be blocked")
	}

	// --- Gameplay config publish with rollout and validation.
	var gp struct {
		Current struct {
			Version string          `json:"version"`
			Body    json.RawMessage `json:"body"`
		} `json:"current"`
	}
	ad.must("GET", "/admin/v1/gameplay", nil, &gp)
	var cfgBody map[string]any
	json.Unmarshal(gp.Current.Body, &cfgBody)
	bosses := cfgBody["bosses"].([]any)
	drops := bosses[0].(map[string]any)["drops"].([]any)
	drops[0].(map[string]any)["percent"] = 40.0
	ad.expectErr("POST", "/admin/v1/gameplay/publish", map[string]any{"body": cfgBody, "note": "bad", "rollout_pct": 100}, 400, "invalid_config")
	drops[0].(map[string]any)["percent"] = 35.0
	cfgBody["buildings"].([]any)[0].(map[string]any)["cost"] = 70.0
	ad.must("POST", "/admin/v1/gameplay/publish", map[string]any{"body": cfgBody, "note": "营火降价", "rollout_pct": 100}, &gp)
	if gp.Current.Version != "v3.13" {
		t.Fatalf("version %s", gp.Current.Version)
	}
	var appCfg struct {
		Buildings []struct {
			Cost int `json:"cost"`
		} `json:"buildings"`
	}
	a.must("GET", "/v1/config/gameplay", nil, &appCfg)
	if appCfg.Buildings[0].Cost != 70 {
		t.Fatalf("published config not served: %+v", appCfg.Buildings[0])
	}
	ad.must("POST", "/admin/v1/gameplay/rollback", nil, &gp)
	if gp.Current.Version != "v3.12" {
		t.Fatalf("rollback to %s", gp.Current.Version)
	}

	// --- Crew.
	var crewRes struct {
		ID          int64   `json:"id"`
		MemberCount int     `json:"member_count"`
		MyRole      *string `json:"my_role"`
	}
	a.must("POST", "/v1/crews", map[string]any{"name": "城西跑团", "district": "徐汇区", "join_mode": "open"}, &crewRes)
	b.must("POST", fmt.Sprintf("/v1/crews/%d/join", crewRes.ID), nil, nil)
	a.must("GET", fmt.Sprintf("/v1/crews/%d", crewRes.ID), nil, &crewRes)
	if crewRes.MemberCount != 2 || *crewRes.MyRole != "leader" {
		t.Fatalf("crew: %+v", crewRes)
	}
	a.expectErr("POST", fmt.Sprintf("/v1/crews/%d/leave", crewRes.ID), nil, 409, "leader_must_transfer")

	// --- Ban B; B is locked out, B's land frozen.
	ad.must("POST", fmt.Sprintf("/admin/v1/users/%d/actions", bres.User.ID), map[string]string{"action": "ban"}, nil)
	b.expectErr("GET", "/v1/me", nil, 403, "account_banned")
	var frozen int
	e.app.Pool.QueryRow(context.Background(), `SELECT count(*) FROM src.src_ter_territory WHERE owner_user_id=$1 AND NOT is_frozen`, bres.User.ID).Scan(&frozen)
	if frozen != 0 {
		t.Fatal("banned user's land must be frozen")
	}
	var audit struct {
		Total int `json:"total"`
	}
	ad.must("GET", "/admin/v1/audit", nil, &audit)
	if audit.Total < 8 {
		t.Fatalf("audit entries: %d", audit.Total)
	}

	// --- Token refresh rotation and reuse detection.
	var r1 authResult
	a.e.anon().must("POST", "/v1/auth/refresh", map[string]string{"refresh_token": ares.RefreshToken}, &r1)
	a.e.anon().expectErr("POST", "/v1/auth/refresh", map[string]string{"refresh_token": ares.RefreshToken}, 401, "unauthorized")
	a.e.anon().expectErr("POST", "/v1/auth/refresh", map[string]string{"refresh_token": r1.RefreshToken}, 401, "unauthorized") // family revoked

	// --- Deletion request and undo; export.
	var del struct {
		DeleteAfter time.Time `json:"delete_after"`
	}
	a.must("POST", "/v1/me/deletion", nil, &del)
	if time.Until(del.DeleteAfter) < 6*24*time.Hour {
		t.Fatalf("cooling-off: %v", del.DeleteAfter)
	}
	a.must("DELETE", "/v1/me/deletion", nil, nil)
	var export map[string]json.RawMessage
	a.must("GET", "/v1/me/export", nil, &export)
	if len(export["activities"]) < 10 || len(export["territories"]) < 10 {
		t.Fatalf("export: %v", export)
	}

	// Jobs run cleanly.
	e.app.Jobs.Tick(context.Background())
}

func TestSMSRateLimit(t *testing.T) {
	e := newEnv(t)
	c := e.anon()
	c.must("POST", "/v1/auth/sms/send", map[string]string{"phone": "13900000000"}, nil)
	c.expectErr("POST", "/v1/auth/sms/send", map[string]string{"phone": "13900000000"}, 429, "rate_limited")
	c.expectErr("POST", "/v1/auth/sms/send", map[string]string{"phone": "12345"}, 400, "invalid_phone")
	c.expectErr("POST", "/v1/auth/login", map[string]any{"provider": "sms", "credential": map[string]string{"phone": "13900000000", "code": "111111"}}, 400, "invalid_code")
}
