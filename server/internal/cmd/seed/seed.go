// Package seed fills a dev backend with demo users, runs, land, a
// crew, a cheating run and an order, through the public API (so every rule
// applies). Usage (API running): go run . seed -api http://localhost:8080
package seed

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/keanying/loopland/server/internal/geo"
)

var (
	fs       = flag.NewFlagSet("seed", flag.ExitOnError)
	api      = fs.String("api", "http://localhost:8080", "backend base URL (dev mode)")
	adminCrd = fs.String("admin", "admin:admin-password-1", "admin username:password for V2 gameplay seed data (empty to skip)")
)

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

// Main runs the command with its arguments (without the command name).
func Main(args []string) {
	_ = fs.Parse(args)
	// seed writes through the API, so the backend must already be running.
	// Wait up to 60 s, so it can start together with the API (IDE compound
	// run configuration, scripts).
	var err error
	for i := 0; ; i++ {
		var resp *http.Response
		resp, err = http.Get(*api + "/healthz")
		if resp != nil {
			resp.Body.Close()
			if resp.StatusCode != 200 {
				err = fmt.Errorf("healthz HTTP %d", resp.StatusCode)
			}
		}
		if err == nil || i >= 60 {
			break
		}
		if i == 0 {
			fmt.Printf("等待后端 %s 启动…\n", *api)
		}
		time.Sleep(time.Second)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, `连不上后端 %s（%v）

seed 是通过后端接口写演示数据的，需要先把后端跑起来：
  1. 启动数据库和缓存：scripts/dev.sh deps（Windows：.\scripts\dev.ps1 deps，需要 Docker Desktop）
  2. 启动后端：在 server/ 下 go run .（GoLand：运行配置「后端 API」），看到 msg=listening 再继续
  3. 另开一个终端：go run . seed（GoLand：运行配置「后端 写演示数据」）
后端不在 8080 时用 -api 指定地址。
`, *api, err)
		os.Exit(1)
	}
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
	var ad *client
	if *adminCrd != "" {
		ad = seedPlay()
	}
	seedCommunity(users, crew.ID, ad)
	fmt.Println("seed done")
}

// seedPlay adds a season, a campaign, a route, monsters and chests (V2)
// and returns the logged-in admin client (nil if login failed).
func seedPlay() *client {
	user, pass, _ := strings.Cut(*adminCrd, ":")
	ad := &client{}
	var login struct {
		Token string `json:"token"`
	}
	ad.do("POST", "/admin/v1/login", map[string]string{"username": user, "password": pass}, &login)
	if login.Token == "" {
		log.Print("admin login failed; skipping V2 seed data")
		return nil
	}
	ad.token = login.Token
	now := time.Now()
	proj := geo.NewProjection(origin)
	at := func(x, y float64) geo.LatLng { return proj.Inverse(geo.Point{X: x, Y: y}) }
	ad.do("POST", "/admin/v1/seasons", map[string]any{"name": "S1 冬季赛", "starts_at": now.AddDate(0, 0, -20), "ends_at": now.AddDate(0, 0, 40)}, nil)
	ad.do("POST", "/admin/v1/campaigns", map[string]any{"title": "夜跑专场", "type": "night_run", "description": "19 点到 23 点开跑 5 km",
		"rules": map[string]any{"min_distance_km": 5, "start_hour_from": 19, "start_hour_to": 23}, "starts_at": now.AddDate(0, 0, -1),
		"ends_at": now.AddDate(0, 0, 14), "reward_energy": 100, "reward_medal_name": "夜行者"}, nil)
	ad.do("POST", "/admin/v1/campaigns", map[string]any{"title": "配速挑战", "type": "pace", "description": "5 km 配速快于 6 分",
		"rules": map[string]any{"min_distance_km": 5, "max_pace_s_per_km": 360}, "starts_at": now.AddDate(0, 0, -1),
		"ends_at": now.AddDate(0, 0, 7), "reward_energy": 80}, nil)
	var cps []map[string]any
	for i, xy := range [][2]float64{{-600, 400}, {-200, 700}, {300, 600}, {700, 200}, {500, -300}} {
		p := at(xy[0], xy[1])
		cps = append(cps, map[string]any{"name": []string{"拱桥", "老街口", "滨江码头", "城南体育场", "终点站"}[i], "lat": p.Lat, "lng": p.Lng, "radius_m": 60})
	}
	ad.do("POST", "/admin/v1/routes", map[string]any{"name": "城南线", "description": "按顺序经过 5 个点", "checkpoints": cps,
		"reward_energy": 150, "starts_at": now.AddDate(0, 0, -1), "ends_at": now.AddDate(0, 0, 30)}, nil)
	for i, b := range []struct {
		kind, place string
		x, y        float64
		hp          int
	}{{"sofa", "人民广场一带", 200, 100, 10000}, {"bat", "外滩一带", 1500, 300, 6000}, {"sugar", "新天地一带", -500, -1200, 8000}} {
		p := at(b.x, b.y)
		ad.do("POST", "/admin/v1/bosses", map[string]any{"kind": b.kind, "lat": p.Lat, "lng": p.Lng, "location_name": b.place, "hp": b.hp, "level": 8 + i*2}, nil)
	}
	sw, ne := at(-2500, -2500), at(2500, 2500)
	ad.do("POST", "/admin/v1/chests/scatter", map[string]any{"bbox": fmt.Sprintf("%f,%f,%f,%f", sw.Lng, sw.Lat, ne.Lng, ne.Lat), "count": 12}, nil)
	for _, xy := range [][2]float64{{100, 50}, {-300, 300}, {600, -200}} {
		p := at(xy[0], xy[1])
		ad.do("POST", "/admin/v1/chests", map[string]any{"lat": p.Lat, "lng": p.Lng}, nil)
	}
	return ad
}

// seedCommunity adds V2 batch 2 data: follows, posts with runs, comments,
// likes, a risky post for the review queue, a meetup, a crew rally, a DM
// and (with an admin) an online race.
func seedCommunity(users []*client, crewID int64, ad *client) {
	myRuns := func(c *client) []int64 {
		var res struct {
			Items []struct {
				ID     int64  `json:"id"`
				Status string `json:"status"`
			} `json:"items"`
		}
		c.do("GET", "/v1/activities?page=1&page_size=5", nil, &res)
		var ids []int64
		for _, a := range res.Items {
			if a.Status == "settled" {
				ids = append(ids, a.ID)
			}
		}
		return ids
	}
	ids := make([]int64, len(users))
	for i, u := range users {
		var me struct {
			ID int64 `json:"id"`
		}
		u.do("GET", "/v1/me", nil, &me)
		ids[i] = me.ID
	}
	// Everyone follows 阿青; a few follow each other.
	for i := 1; i < len(users); i++ {
		users[i].do("POST", fmt.Sprintf("/v1/users/%d/follow", ids[0]), nil, nil)
	}
	users[0].do("POST", fmt.Sprintf("/v1/users/%d/follow", ids[1]), nil, nil)
	users[2].do("POST", fmt.Sprintf("/v1/users/%d/follow", ids[5]), nil, nil)
	users[0].do("PATCH", "/v1/me", map[string]any{"bio": "每天 5 公里，圈地爱好者"}, nil)

	texts := []string{
		"今晚绕人民广场圈了一大块，风有点大但很爽 🏃",
		"城西跑团周三夜跑，配速 6 分，新人友好",
		"晨跑打卡第 30 天，图鉴又多了一只伙伴",
		"骑行 20 公里，外滩的夜景太好看了",
		"抢回了被切走的那块地，守地挑战完成",
		"滨江步道是真的适合跑步",
	}
	var postIDs []int64
	for i, u := range users {
		body := map[string]any{"content": texts[i], "visibility": "public"}
		if runs := myRuns(u); len(runs) > 0 {
			body["activity_id"] = runs[0]
			// 阿青 posts with an AI battle report (第三批; the dev mock writes it).
			if i == 0 {
				var rep struct {
					Text string `json:"text"`
				}
				u.do("POST", fmt.Sprintf("/v1/activities/%d/ai-report", runs[0]), nil, &rep)
				if rep.Text != "" {
					body["ai_report"] = true
				}
			}
		}
		var p struct {
			ID int64 `json:"id"`
		}
		u.do("POST", "/v1/posts", body, &p)
		if p.ID != 0 {
			postIDs = append(postIDs, p.ID)
		}
	}
	// Likes and a comment thread on the first post.
	if len(postIDs) > 0 {
		first := postIDs[0]
		for i := 1; i < len(users); i++ {
			users[i].do("POST", fmt.Sprintf("/v1/posts/%d/like", first), nil, nil)
		}
		var c struct {
			ID int64 `json:"id"`
		}
		users[1].do("POST", fmt.Sprintf("/v1/posts/%d/comments", first), map[string]any{"content": "这块地好大，下次一起跑"}, &c)
		if c.ID != 0 {
			users[0].do("POST", fmt.Sprintf("/v1/posts/%d/comments", first), map[string]any{"content": "好呀，周三见", "parent_id": c.ID}, nil)
			users[2].do("POST", fmt.Sprintf("/v1/comments/%d/like", c.ID), nil, nil)
		}
		users[3].do("POST", fmt.Sprintf("/v1/posts/%d/collect", first), nil, nil)
	}
	// A question for the AI assistant 圈圈 (dev mock unless a model is configured).
	users[0].do("POST", "/v1/ai/chat", map[string]any{"content": "今晚去哪抢地？", "lat": origin.Lat, "lng": origin.Lng}, nil)
	// Content for the review queue: contact details in a post and a comment.
	users[4].do("POST", "/v1/posts", map[string]any{"content": "代跑接单，加微信 run_helper888 详聊", "visibility": "public"}, nil)
	if len(postIDs) > 1 {
		users[5].do("POST", fmt.Sprintf("/v1/posts/%d/comments", postIDs[1]), map[string]any{"content": "想加入的打我电话13912345678"}, nil)
	}

	// A meetup, a crew rally and a direct message.
	proj := geo.NewProjection(origin)
	park := proj.Inverse(geo.Point{X: 800, Y: -600})
	start := time.Now().Add(26 * time.Hour).Truncate(time.Hour)
	users[1].do("POST", "/v1/meetups", map[string]any{"type": "run", "title": "周末世纪公园约跑", "description": "配速 6 分左右，跑 10 公里，跑完一起吃早饭",
		"start_time": start, "end_time": start.Add(2 * time.Hour), "place": map[string]any{"name": "人民公园 2 号门", "lat": park.Lat, "lng": park.Lng},
		"district": "黄浦区", "capacity": 10, "requirement": "配速 5'30\"–6'30\""}, nil)
	if crewID != 0 {
		users[0].do("POST", fmt.Sprintf("/v1/crews/%d/rallies", crewID), map[string]any{"title": "周三夜跑", "start_time": start.Add(48 * time.Hour),
			"place": map[string]any{"name": "人民广场", "lat": origin.Lat, "lng": origin.Lng}, "distance_goal_m": 5000}, nil)
	}
	var conv struct {
		ID int64 `json:"id"`
	}
	users[2].do("POST", "/v1/conversations/direct", map[string]any{"user_id": ids[0]}, &conv)
	if conv.ID != 0 {
		users[2].do("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "text", "content": "阿青，周三夜跑我能带朋友吗？"}, nil)
	}

	if ad == nil {
		return
	}
	now := time.Now()
	ad.do("POST", "/admin/v1/races", map[string]any{"type": "online", "title": "城市 10K 线上赛", "description": "活动期间单次跑满 10 公里即完赛",
		"sport": "run", "distance_m": 10000, "start_time": now.Add(-24 * time.Hour), "end_time": now.AddDate(0, 0, 14),
		"signup_end_time": now.AddDate(0, 0, 7), "capacity": 5000, "requires_wearable": false,
		"medal": map[string]any{"name": "城市 10K 完赛奖牌"}, "published": true}, nil)
	ad.do("POST", "/admin/v1/races", map[string]any{"type": "offline", "title": "滨江半程马拉松", "description": "线下赛，现场检录",
		"sport": "run", "distance_m": 21097, "start_time": now.AddDate(0, 1, 0), "end_time": now.AddDate(0, 1, 0).Add(4 * time.Hour),
		"signup_end_time": now.AddDate(0, 0, 20), "capacity": 2000,
		"place": map[string]any{"name": "徐汇滨江", "lat": park.Lat, "lng": park.Lng}, "published": true}, nil)
}
