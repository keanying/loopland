package app

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/keanying/loopland/server/internal/geo"
)

func adminClient(t *testing.T, e *env) *client {
	ad := e.anon()
	var login struct {
		Token string `json:"token"`
	}
	ad.must("POST", "/admin/v1/login", map[string]string{"username": "root", "password": "root-password-123"}, &login)
	ad.token = login.Token
	return ad
}

func at(x, y float64) geo.LatLng { return geo.NewProjection(origin).Inverse(geo.Point{X: x, Y: y}) }

type extra struct {
	BossDamage []struct {
		BossID   int64 `json:"boss_id"`
		Damage   int   `json:"damage"`
		Defeated bool  `json:"defeated"`
	} `json:"boss_damage"`
	Chests []struct {
		ChestID int64 `json:"chest_id"`
		Energy  int   `json:"energy"`
	} `json:"chests"`
	Defended []struct {
		TerritoryID int64 `json:"territory_id"`
		GuardBefore int   `json:"guard_before"`
		GuardAfter  int   `json:"guard_after"`
	} `json:"defended"`
	Routes []struct {
		Completed bool     `json:"completed"`
		Reached   []string `json:"reached"`
	} `json:"routes"`
	Campaigns []struct {
		Title string `json:"title"`
	} `json:"campaigns"`
	Tasks []struct {
		Key       string  `json:"key"`
		Progress  float64 `json:"progress"`
		Completed bool    `json:"completed"`
	} `json:"tasks"`
	Companion *struct {
		Key string `json:"key"`
		Exp int    `json:"exp"`
	} `json:"companion"`
	Relay *struct {
		Leg       int  `json:"leg"`
		Completed bool `json:"completed"`
	} `json:"relay"`
	Claims []struct {
		TerritoryID int64 `json:"territory_id"`
	} `json:"claims"`
	Attacks []struct {
		Captured bool `json:"captured"`
	} `json:"attacks"`
}

func (c *client) runAt(wps ...[2]float64) extra {
	c.e.t.Helper()
	var res struct {
		Settlement extra `json:"settlement"`
	}
	c.must("POST", "/v1/activities", run(3, wps...), &res)
	return res.Settlement
}

func TestPlayEndToEnd(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	ad := adminClient(t, e)
	a, ares := e.smsLogin("13800000011")
	a.consent()
	b, bres := e.smsLogin("13800000012")
	b.consent()

	// --- Season, campaign, route, chest set up by ops.
	now := time.Now()
	ad.must("POST", "/admin/v1/seasons", map[string]any{"name": "S1 测试赛", "starts_at": now.Add(-24 * time.Hour), "ends_at": now.Add(30 * 24 * time.Hour)}, nil)
	ad.expectErr("POST", "/admin/v1/seasons", map[string]any{"name": "重叠", "starts_at": now, "ends_at": now.Add(time.Hour)}, 409, "season_overlap")
	ad.must("POST", "/admin/v1/campaigns", map[string]any{"title": "一公里挑战", "type": "distance", "rules": map[string]any{"min_distance_km": 1},
		"starts_at": now.Add(-time.Hour * 5), "ends_at": now.Add(24 * time.Hour), "reward_energy": 30}, nil)
	ad.expectErr("POST", "/admin/v1/campaigns", map[string]any{"title": "x", "type": "night_run", "rules": map[string]any{},
		"starts_at": now, "ends_at": now.Add(time.Hour)}, 400, "invalid_body")
	p1, p2 := at(300, 0), at(300, 300)
	ad.must("POST", "/admin/v1/routes", map[string]any{"name": "测试线", "checkpoints": []map[string]any{
		{"name": "东南角", "lat": p1.Lat, "lng": p1.Lng, "radius_m": 30}, {"name": "东北角", "lat": p2.Lat, "lng": p2.Lng, "radius_m": 30}},
		"reward_energy": 40, "starts_at": now.Add(-5 * time.Hour), "ends_at": now.Add(24 * time.Hour)}, nil)
	c := at(300, 150) // on the east leg of the run
	var chest struct {
		ID int64 `json:"id"`
	}
	ad.must("POST", "/admin/v1/chests", map[string]any{"lat": c.Lat, "lng": c.Lng, "energy_min": 25, "energy_max": 25}, &chest)

	// --- A monster near the square.
	bc := at(150, 150)
	var boss struct {
		ID    int64 `json:"id"`
		HP    int   `json:"hp"`
		Drops []struct {
			Percent float64 `json:"percent"`
		} `json:"drops"`
	}
	ad.must("POST", "/admin/v1/bosses", map[string]any{"kind": "sofa", "lat": bc.Lat, "lng": bc.Lng, "location_name": "人民广场一带", "hp": 2000}, &boss)
	sum := 0.0
	for _, d := range boss.Drops {
		sum += d.Percent
	}
	if boss.HP != 2000 || sum != 100 {
		t.Fatalf("boss: %+v", boss)
	}
	var objs struct {
		Bosses []struct {
			ID int64 `json:"id"`
		} `json:"bosses"`
		Chests []struct {
			ID int64 `json:"id"`
		} `json:"chests"`
		Checkpoints []struct {
			Name  string `json:"name"`
			State string `json:"state"`
		} `json:"checkpoints"`
	}
	a.must("GET", "/v1/map/objects?bbox=121.46,31.22,121.49,31.24", nil, &objs)
	if len(objs.Bosses) != 1 || len(objs.Chests) != 1 || len(objs.Checkpoints) != 1 || objs.Checkpoints[0].State != "next" {
		t.Fatalf("map objects: %+v", objs)
	}

	// --- A's first run: claims the square, hits the boss, opens the chest,
	// reaches both route checkpoints, completes the campaign and a task.
	r1 := a.runAt([2]float64{0, 0}, [2]float64{300, 0}, [2]float64{300, 300}, [2]float64{150, 300}, [2]float64{150, -50})
	if len(r1.BossDamage) != 1 || r1.BossDamage[0].Damage < 90 || r1.BossDamage[0].Damage > 120 {
		t.Fatalf("activity damage ≈ 1.1 km × 100: %+v", r1.BossDamage)
	}
	if len(r1.Chests) != 1 || r1.Chests[0].Energy != 25 {
		t.Fatalf("chest: %+v", r1.Chests)
	}
	if len(r1.Routes) != 1 || !r1.Routes[0].Completed || len(r1.Routes[0].Reached) != 2 {
		t.Fatalf("route: %+v", r1.Routes)
	}
	if len(r1.Campaigns) != 1 {
		t.Fatalf("campaign: %+v", r1.Campaigns)
	}
	var runsTask bool
	for _, tk := range r1.Tasks {
		if tk.Key == "new_sport" && tk.Completed {
			runsTask = true
		}
	}
	if !runsTask {
		t.Fatalf("new sport task: %+v", r1.Tasks)
	}
	a.expectErr("POST", fmt.Sprintf("/v1/chests/%d/open", chest.ID), map[string]float64{"lat": c.Lat, "lng": c.Lng}, 409, "already_opened")
	tid := r1.Claims[0].TerritoryID

	// --- Realtime: B watches the boss over WebSocket.
	wsURL := strings.Replace(e.srv.URL, "http", "ws", 1) + "/v1/ws?token=" + b.token
	wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(wctx, wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	if err := ws.Write(wctx, websocket.MessageText, []byte(fmt.Sprintf(`{"sub":"boss:%d"}`, boss.ID))); err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond) // let the subscription register

	// --- Strikes: range, energy, cooldown.
	e.sql(`UPDATE src.src_usr_user SET energy=1000 WHERE id IN ($1,$2)`, ares.User.ID, bres.User.ID)
	far := at(5000, 5000)
	a.expectErr("POST", fmt.Sprintf("/v1/bosses/%d/strike", boss.ID), map[string]float64{"lat": far.Lat, "lng": far.Lng}, 403, "out_of_range")
	var st struct {
		Damage int `json:"damage"`
		Energy int `json:"energy"`
		Boss   struct {
			HP int `json:"hp"`
		} `json:"boss"`
	}
	a.must("POST", fmt.Sprintf("/v1/bosses/%d/strike", boss.ID), map[string]float64{"lat": bc.Lat, "lng": bc.Lng}, &st)
	if st.Damage != 40 || st.Energy != 900 {
		t.Fatalf("strike: %+v", st)
	}
	a.expectErr("POST", fmt.Sprintf("/v1/bosses/%d/strike", boss.ID), map[string]float64{"lat": bc.Lat, "lng": bc.Lng}, 429, "cooldown")
	for {
		_, msg, err := ws.Read(wctx)
		if err != nil {
			t.Fatalf("no boss event over websocket: %v", err)
		}
		var m struct {
			Type string `json:"type"`
			Boss struct {
				HP int `json:"hp"`
			} `json:"boss"`
		}
		json.Unmarshal(msg, &m)
		if m.Type == "boss" {
			if m.Boss.HP != st.Boss.HP {
				t.Fatalf("ws hp %d, want %d", m.Boss.HP, st.Boss.HP)
			}
			break
		}
	}

	// --- Crew + combo: B joins A's crew; B's strike gets +10%.
	var crew struct {
		ID int64 `json:"id"`
	}
	a.must("POST", "/v1/crews", map[string]any{"name": "玩法测试团", "district": "黄浦区", "join_mode": "open"}, &crew)
	b.must("POST", fmt.Sprintf("/v1/crews/%d/join", crew.ID), nil, nil)
	e.sql(`UPDATE src.src_ply_boss_hit SET crew_id=$1 WHERE user_id=$2`, crew.ID, ares.User.ID)
	b.must("POST", fmt.Sprintf("/v1/bosses/%d/strike", boss.ID), map[string]float64{"lat": bc.Lat, "lng": bc.Lng}, &st)
	if st.Damage != 44 {
		t.Fatalf("combo strike damage = %d, want 44", st.Damage)
	}
	var inbox struct {
		Items []struct {
			Title string `json:"title"`
		} `json:"items"`
	}
	a.must("GET", "/v1/inbox?category=monster", nil, &inbox)
	if len(inbox.Items) == 0 || inbox.Items[0].Title != "跑团合击召集" {
		t.Fatalf("rally: %+v", inbox)
	}

	// --- Defeat: drop the HP and finish with B's strike after cooldown.
	e.sql(`UPDATE src.src_ply_boss SET hp=10 WHERE id=$1`, boss.ID)
	e.app.Redis.Del(ctx, fmt.Sprintf("boss:cd:%d:%d", boss.ID, bres.User.ID))
	b.must("POST", fmt.Sprintf("/v1/bosses/%d/strike", boss.ID), map[string]float64{"lat": bc.Lat, "lng": bc.Lng}, &st)
	var view struct {
		Status    string `json:"status"`
		Rank      []any  `json:"rank"`
		MyRewards []struct {
			Name string `json:"name"`
		} `json:"my_rewards"`
	}
	a.must("GET", fmt.Sprintf("/v1/bosses/%d", boss.ID), nil, &view)
	if view.Status != "defeated" || len(view.Rank) != 2 || len(view.MyRewards) != 2 { // A ranks top-3 → two rolls
		t.Fatalf("defeated view: %+v", view)
	}
	var cx struct {
		Monsters []struct {
			Key     string `json:"key"`
			Defeats int    `json:"defeats"`
		} `json:"monsters"`
		Companions []struct {
			Key   string `json:"key"`
			State string `json:"state"`
			Exp   int    `json:"exp"`
		} `json:"companions"`
		Medals []struct {
			Key      string  `json:"key"`
			Progress float64 `json:"progress"`
		} `json:"medals"`
	}
	a.must("GET", "/v1/codex", nil, &cx)
	if cx.Monsters[0].Key != "sofa" || cx.Monsters[0].Defeats != 1 {
		t.Fatalf("monster codex: %+v", cx.Monsters)
	}

	// --- Expiry refund on a second monster.
	var boss2 struct {
		ID int64 `json:"id"`
	}
	ad.must("POST", "/admin/v1/bosses", map[string]any{"kind": "bat", "lat": bc.Lat, "lng": bc.Lng}, &boss2)
	e.app.Redis.Del(ctx, fmt.Sprintf("boss:cd:%d:%d", boss2.ID, ares.User.ID))
	a.must("POST", fmt.Sprintf("/v1/bosses/%d/strike", boss2.ID), map[string]float64{"lat": bc.Lat, "lng": bc.Lng}, &st)
	before := st.Energy
	ad.must("POST", fmt.Sprintf("/admin/v1/bosses/%d/end", boss2.ID), nil, nil)
	var me struct {
		Energy int `json:"energy"`
	}
	a.must("GET", "/v1/me", nil, &me)
	if me.Energy != before+20 { // 20% of 100
		t.Fatalf("refund: %d → %d", before, me.Energy)
	}

	// --- Defense: B weakens A's land, A runs over it within the window.
	e.sql(`UPDATE src.src_ter_territory SET guard=500 WHERE id=$1`, tid)
	r2 := b.runAt([2]float64{200, 100}, [2]float64{500, 100}, [2]float64{500, 200}, [2]float64{250, 200}, [2]float64{250, 50})
	if len(r2.Attacks) == 0 {
		// same crew now: crew mates don't attack each other — leave the crew and retry
		b.must("POST", fmt.Sprintf("/v1/crews/%d/leave", crew.ID), nil, nil)
		r2 = b.runAt([2]float64{200, 120}, [2]float64{520, 120}, [2]float64{520, 220}, [2]float64{260, 220}, [2]float64{260, 60})
		if len(r2.Attacks) == 0 || r2.Attacks[0].Captured {
			t.Fatalf("expected a weaken: %+v", r2.Attacks)
		}
		b.must("POST", fmt.Sprintf("/v1/crews/%d/join", crew.ID), nil, nil)
	}
	var terr struct {
		Defense *struct {
			Deadline time.Time `json:"deadline"`
		} `json:"defense"`
	}
	a.must("GET", fmt.Sprintf("/v1/territories/%d", tid), nil, &terr)
	if terr.Defense == nil {
		t.Fatal("defense window should be open")
	}
	// Hatch A's egg and make it the escort, for companion growth below.
	e.sql(`DELETE FROM src.src_ply_codex_item WHERE user_id=$1 AND item_type='egg' AND item='gecko'`, ares.User.ID)
	e.sql(`INSERT INTO src.src_ply_codex_item (user_id, item_type, item) VALUES ($1,'companion','gecko')`, ares.User.ID)
	a.must("POST", "/v1/codex/companions/gecko/escort", nil, nil)
	// Relay: two legs of 1 km.
	var relay struct {
		ID int64 `json:"id"`
	}
	a.must("POST", fmt.Sprintf("/v1/crews/%d/relays", crew.ID), map[string]any{"legs": 2, "leg_km": 1}, &relay)
	b.expectErr("POST", fmt.Sprintf("/v1/crews/%d/relays", crew.ID), map[string]any{"legs": 2, "leg_km": 1}, 403, "not_leader")

	r3 := a.runAt([2]float64{100, 100}, [2]float64{200, 100}, [2]float64{200, 200}, [2]float64{100, 200}, [2]float64{100, 50}, [2]float64{100, -600}) // ≈1.1 km
	if len(r3.Defended) != 1 || r3.Defended[0].GuardAfter <= r3.Defended[0].GuardBefore {
		t.Fatalf("defended: %+v", r3.Defended)
	}
	if r3.Companion == nil || r3.Companion.Key != "gecko" || r3.Companion.Exp < 7 {
		t.Fatalf("companion: %+v", r3.Companion)
	}
	if r3.Relay == nil || r3.Relay.Leg != 1 || r3.Relay.Completed {
		t.Fatalf("relay leg 1: %+v", r3.Relay)
	}
	r4 := b.runAt([2]float64{-1000, -1000}, [2]float64{-1000, 200})
	if r4.Relay == nil || !r4.Relay.Completed {
		t.Fatalf("relay done: %+v", r4.Relay)
	}

	// Feeding costs energy and adds experience.
	a.must("POST", "/v1/codex/companions/gecko/feed", nil, &cx)
	for _, cp := range cx.Companions {
		if cp.Key == "gecko" && cp.Exp < 17 {
			t.Fatalf("fed companion: %+v", cp)
		}
	}

	// --- Season and league views.
	var season struct {
		Season *struct {
			Name string `json:"name"`
		} `json:"season"`
		Me *struct {
			AreaM2 float64 `json:"area_m2"`
			Tier   struct {
				Name string `json:"name"`
			} `json:"tier"`
			Rank *int `json:"rank"`
		} `json:"me"`
		Tasks  []any `json:"tasks"`
		Medals []any `json:"medals"`
	}
	a.must("GET", "/v1/season", nil, &season)
	if season.Season == nil || season.Me == nil || season.Me.AreaM2 < 40000 || season.Me.Tier.Name != "青铜" || season.Me.Rank == nil || len(season.Tasks) != 4 {
		t.Fatalf("season: %+v", season)
	}
	var league struct {
		District  string `json:"district"`
		Standings []struct {
			ScoreM2 float64 `json:"score_m2"`
		} `json:"standings"`
		MyCrew *struct {
			Rank int `json:"rank"`
		} `json:"my_crew"`
	}
	a.must("GET", "/v1/league", nil, &league)
	if league.District != "黄浦区" || league.MyCrew == nil || league.MyCrew.Rank != 1 {
		t.Fatalf("league: %+v", league)
	}

	// --- Config validation for the new sections.
	var gp struct {
		Current struct {
			Body map[string]any `json:"body"`
		} `json:"current"`
	}
	ad.must("GET", "/admin/v1/gameplay", nil, &gp)
	tiers := gp.Current.Body["season"].(map[string]any)["tiers"].([]any)
	tiers[2].(map[string]any)["min_km2"] = 0.1 // not increasing
	ad.expectErr("POST", "/admin/v1/gameplay/publish", map[string]any{"body": gp.Current.Body, "note": "bad", "rollout_pct": 100}, 400, "invalid_config")

	// --- Jobs: auto spawn and daily chests run cleanly.
	e.app.Jobs.Tick(ctx)
	if err := e.app.Play.AutoSpawn(ctx, time.Date(2026, 11, 21, 4, 0, 0, 0, time.UTC)); err != nil { // 12:00 in Shanghai
		t.Fatal(err)
	}
	var auto int
	e.app.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_ply_boss WHERE spawned_by IS NULL AND status='active'`).Scan(&auto)
	if auto == 0 {
		t.Fatal("auto spawn placed no monster near recent runs")
	}
}
