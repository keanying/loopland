// Command loopland-seed fills a dev backend with demo users, runs, land, a
// crew, a cheating run and an order, through the public API (so every rule
// applies). Usage: go run ./cmd/loopland-seed -api http://localhost:8080
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/keanying/loopland/server/internal/geo"
)

var api = flag.String("api", "http://localhost:8080", "backend base URL (dev mode)")

type client struct{ token string }

func (c *client) do(method, path string, body, out any) {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, *api+path, rd)
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		log.Printf("%s %s: %d %s", method, path, resp.StatusCode, raw)
		return
	}
	if out != nil {
		_ = json.Unmarshal(raw, out)
	}
}

func login(phone, nick string) *client {
	c := &client{}
	var res struct {
		AccessToken string `json:"access_token"`
	}
	c.do("POST", "/v1/auth/login", map[string]any{"provider": "sms", "credential": map[string]string{"phone": phone, "code": "000000"},
		"device_id": "seed-" + phone, "platform": "android"}, &res)
	c.token = res.AccessToken
	c.do("PATCH", "/v1/me", map[string]any{"nickname": nick}, nil)
	c.do("POST", "/v1/me/consents", map[string]any{"privacy_version": "2026-11", "location": true, "health": true}, nil)
	return c
}

var origin = geo.LatLng{Lat: 31.2304, Lng: 121.4737} // 人民广场

// loop returns a run around a rectangle that overshoots its start so it closes.
func loop(cx, cy, w, h, speed float64, ago time.Duration) map[string]any {
	wps := [][2]float64{{cx - w/2, cy - h/2}, {cx + w/2, cy - h/2}, {cx + w/2, cy + h/2}, {cx - w/2 + 20, cy + h/2}, {cx - w/2 + 20, cy - h/2 - 40}}
	proj := geo.NewProjection(origin)
	start := time.Now().Add(-ago)
	var pts []map[string]any
	t := 0.0
	add := func(x, y float64) {
		ll := proj.Inverse(geo.Point{X: x, Y: y})
		pts = append(pts, map[string]any{"t": start.Add(time.Duration(t * float64(time.Second))).UnixMilli(), "lat": ll.Lat, "lng": ll.Lng,
			"acc": 5, "hr": 150, "cad": 170, "src": "gps"})
	}
	add(wps[0][0], wps[0][1])
	for i := 1; i < len(wps); i++ {
		a, b := wps[i-1], wps[i]
		d := math.Hypot(b[0]-a[0], b[1]-a[1])
		n := int(math.Ceil(d / 8))
		for k := 1; k <= n; k++ {
			t += d / float64(n) / speed
			f := float64(k) / float64(n)
			add(a[0]+(b[0]-a[0])*f, a[1]+(b[1]-a[1])*f)
		}
	}
	return map[string]any{"client_id": uuid.NewString(), "sport": "run", "started_at": start, "ended_at": start.Add(time.Duration(t) * time.Second),
		"duration_s": int(t), "points": pts, "goal": map[string]any{"type": "free"}, "device": map[string]any{"id": uuid.NewString(), "model": "seed", "os": "seed"}}
}

func main() {
	flag.Parse()
	users := []*client{
		login("13800000001", "夜跑的阿青"), login("13800000002", "城西老周"), login("13800000003", "晨跑小林"),
		login("13800000004", "徐汇骑士"), login("13800000005", "外滩跑者"), login("13800000006", "滨江阿梅"),
	}
	// Spread loops around 人民广场; some overlap so there are attacks.
	plan := []struct {
		u                 int
		cx, cy, w, h, spd float64
	}{
		{0, 0, 0, 500, 400, 3.2}, {0, 900, 200, 400, 400, 3.0}, {1, 300, 100, 500, 300, 3.4}, {1, -900, -300, 600, 500, 3.1},
		{2, -400, 700, 450, 350, 2.9}, {3, 1200, -700, 700, 500, 5.5}, {4, 200, -900, 500, 450, 3.3}, {5, -1200, 600, 500, 500, 3.0},
		{2, -300, 650, 300, 300, 3.5}, {4, 600, -800, 400, 300, 3.2},
	}
	for i, p := range plan {
		var res struct {
			Settlement struct {
				Status  string `json:"status"`
				Claims  []any  `json:"claims"`
				Attacks []any  `json:"attacks"`
			} `json:"settlement"`
		}
		users[p.u].do("POST", "/v1/activities", loop(p.cx, p.cy, p.w, p.h, p.spd, time.Duration(24*(len(plan)-i))*time.Hour/3), &res)
		fmt.Printf("run %d: %s, %d claims, %d attacks\n", i+1, res.Settlement.Status, len(res.Settlement.Claims), len(res.Settlement.Attacks))
	}
	// A suspicious run (review) and a car ride (voided).
	users[5].do("POST", "/v1/activities", loop(-2000, -1500, 600, 500, 6.4, 3*time.Hour), nil)
	users[3].do("POST", "/v1/activities", loop(2500, 1500, 1500, 1000, 14, 2*time.Hour), nil)

	// A crew.
	var crew struct {
		ID int64 `json:"id"`
	}
	users[0].do("POST", "/v1/crews", map[string]any{"name": "城西跑团", "district": "黄浦区", "join_mode": "open"}, &crew)
	users[1].do("POST", fmt.Sprintf("/v1/crews/%d/join", crew.ID), nil, nil)
	users[2].do("POST", fmt.Sprintf("/v1/crews/%d/join", crew.ID), nil, nil)

	// A paid membership through the mock channel (实名 first).
	users[0].do("POST", "/v1/me/realname", map[string]string{"name": "张三", "id_number": "110105199003071239"}, nil)
	var ord struct {
		Order struct {
			OrderNo string `json:"order_no"`
		} `json:"order"`
	}
	users[0].do("POST", "/v1/orders", map[string]string{"plan_code": "auto_month", "channel": "mock"}, &ord)
	if ord.Order.OrderNo != "" {
		users[0].do("POST", "/v1/dev/orders/"+ord.Order.OrderNo+"/pay", nil, nil)
	}
	fmt.Println("seed done")
}
