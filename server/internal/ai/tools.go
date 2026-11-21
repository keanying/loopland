package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
)

// Card is a tappable object in an answer.
type Card struct {
	Type      string         `json:"type"` // route | territory | boss
	Route     *Route         `json:"route,omitempty"`
	Territory *TerritoryCard `json:"territory,omitempty"`
	Boss      *BossCard      `json:"boss,omitempty"`
}

// Ref is {id, nickname} / {id, name}.
type Ref struct {
	ID       int64  `json:"id"`
	Nickname string `json:"nickname,omitempty"`
	Name     string `json:"name,omitempty"`
}

// TerritoryCard is a territory in an answer.
type TerritoryCard struct {
	ID     int64  `json:"id"`
	Name   string `json:"name"`
	Owner  *Ref   `json:"owner"`
	Crew   *Ref   `json:"crew"`
	Guard  int    `json:"guard"`
	Center LatLng `json:"center"`
}

// BossCard is a monster in an answer.
type BossCard struct {
	ID     int64     `json:"id"`
	Name   string    `json:"name"`
	HP     int       `json:"hp"`
	MaxHP  int       `json:"max_hp"`
	Center LatLng    `json:"center"`
	EndsAt time.Time `json:"ends_at"`
}

// ToolFunc runs a tool: the result goes back to the model, cards to the user.
type ToolFunc func(ctx context.Context, args json.RawMessage) (result any, cards []Card, err error)

// Toolset is the tools offered in one conversation.
type Toolset struct {
	Defs []Tool
	Fns  map[string]ToolFunc
}

func (t *Toolset) add(name, desc, params string, fn ToolFunc) {
	t.Defs = append(t.Defs, Tool{Type: "function", Function: FunctionDef{Name: name, Description: desc, Parameters: json.RawMessage(params)}})
	if t.Fns == nil {
		t.Fns = map[string]ToolFunc{}
	}
	t.Fns[name] = fn
}

const noParams = `{"type":"object","properties":{}}`

// tools builds the assistant's tools for a user; pos is the best known
// position (nil when unknown).
func (s *Service) tools(user int64, pos *LatLng) *Toolset {
	ts := &Toolset{}
	needPos := map[string]any{"error": "不知道你现在的位置，请在 App 里打开定位后再问"}
	ts.add("get_my_status", "我的状态：今日/本周能量和里程、领地数、跑团和本周排名、最近被攻击的地", noParams,
		func(ctx context.Context, _ json.RawMessage) (any, []Card, error) {
			st, err := s.myStatus(ctx, user)
			return st, nil, err
		})
	ts.add("get_nearby_targets", "附近目标：附近守卫值低的别人的地、我被攻击待加固的地、我最近丢掉的地", noParams,
		func(ctx context.Context, _ json.RawMessage) (any, []Card, error) {
			if pos == nil {
				return needPos, nil, nil
			}
			return s.nearbyTargets(ctx, user, *pos)
		})
	ts.add("get_nearby_bosses", "附近正在出没的城市怪兽（血量、剩余时间）和未开的宝箱", noParams,
		func(ctx context.Context, _ json.RawMessage) (any, []Card, error) {
			if pos == nil {
				return needPos, nil, nil
			}
			return s.nearbyBosses(ctx, user, *pos)
		})
	ts.add("plan_route", "规划路线：按距离或近 4 周平均距离规划闭环、抢地、守地、打怪兽路线，返回路线卡片",
		`{"type":"object","properties":{"sport":{"type":"string","enum":["run","ride","hike","walk"],"description":"运动类型，默认 run"},"distance_km":{"type":"number","description":"目标距离（公里），不填按近 4 周平均"},"type":{"type":"string","enum":["loop","capture","defend","boss"],"description":"只要某一类路线时填写"}}}`,
		func(ctx context.Context, args json.RawMessage) (any, []Card, error) {
			if pos == nil {
				return needPos, nil, nil
			}
			var a struct {
				Sport      string   `json:"sport"`
				DistanceKm *float64 `json:"distance_km"`
				Type       string   `json:"type"`
			}
			_ = json.Unmarshal(args, &a)
			if !gpsSports[a.Sport] {
				a.Sport = "run"
			}
			maxKm := s.Config.For(user).AI.RouteMaxKm
			if a.DistanceKm != nil && (*a.DistanceKm <= 0 || *a.DistanceKm > maxKm) {
				a.DistanceKm = nil
			}
			routes, err := s.Suggest(ctx, user, *pos, a.Sport, a.DistanceKm, false)
			if err != nil {
				return nil, nil, err
			}
			var cards []Card
			var summary []map[string]any
			for i := range routes {
				r := routes[i]
				if a.Type != "" && r.Type != a.Type {
					continue
				}
				if len(cards) >= 2 {
					break
				}
				cards = append(cards, Card{Type: "route", Route: &r})
				summary = append(summary, map[string]any{"type": r.Type, "title": r.Title, "subtitle": r.Subtitle, "distance_km": math.Round(float64(r.DistanceM)/100) / 10,
					"minutes": r.EstDurationSec / 60, "targets": r.Targets})
			}
			if len(summary) == 0 {
				return map[string]any{"routes": []any{}, "note": "附近没有符合条件的路线"}, nil, nil
			}
			return map[string]any{"routes": summary, "note": "路线卡片已展示给用户，可一键开跑"}, cards, nil
		})
	ts.add("get_game_rules", "玩法规则：能量换算、每日上限、圈地最小面积、怪兽合击、守地加固等当前配置要点",
		`{"type":"object","properties":{"topic":{"type":"string","description":"energy | claim | boss | defense | all"}}}`,
		func(ctx context.Context, args json.RawMessage) (any, []Card, error) {
			return s.gameRules(user), nil, nil
		})
	ts.add("get_training_advice", "训练建议：根据最近 4 周的运动量给出今天建议的距离（一般性建议，非医疗）", noParams,
		func(ctx context.Context, _ json.RawMessage) (any, []Card, error) {
			adv, err := s.trainingAdvice(ctx, user)
			return adv, nil, err
		})
	return ts
}

// ---------------------------------------------------------------- queries

// Status is the get_my_status result.
type Status struct {
	Nickname        string           `json:"nickname"`
	Energy          int              `json:"energy_balance"`
	TodayEnergy     int              `json:"today_energy"`
	WeekEnergy      int              `json:"week_energy"`
	TodayDistanceKm float64          `json:"today_distance_km"`
	WeekDistanceKm  float64          `json:"week_distance_km"`
	TerritoryCount  int              `json:"territory_count"`
	Crew            *string          `json:"crew"`
	CrewWeekRank    *int             `json:"crew_week_rank"`
	CrewMembers     int              `json:"crew_members"`
	RecentAttacks   []map[string]any `json:"recently_attacked"`
}

func (s *Service) myStatus(ctx context.Context, user int64) (Status, error) {
	var st Status
	today := clock.Today()
	ws := WeekStart(clock.Now())
	var crewID *int64
	if err := s.Pool.QueryRow(ctx, `SELECT u.nickname, u.energy,
			COALESCE((SELECT sum(delta) FROM src.src_ply_loop_energy_ledger l WHERE l.user_id=u.id AND l.ledger_date=$2 AND l.delta > 0), 0),
			COALESCE((SELECT sum(delta) FROM src.src_ply_loop_energy_ledger l WHERE l.user_id=u.id AND l.ledger_date>=$3 AND l.delta > 0), 0),
			COALESCE((SELECT sum(distance_m) FROM src.src_act_loop_activity a WHERE a.user_id=u.id AND a.status='settled' AND a.start_time >= $2), 0)/1000,
			COALESCE((SELECT sum(distance_m) FROM src.src_act_loop_activity a WHERE a.user_id=u.id AND a.status='settled' AND a.start_time >= $3), 0)/1000,
			(SELECT count(*) FROM src.src_ter_loop_territory t WHERE t.owner_user_id=u.id),
			c.id, c.name, (SELECT count(*) FROM src.src_soc_loop_crew_member m2 WHERE m2.crew_id=c.id)
		FROM src.src_usr_loop_user u LEFT JOIN src.src_soc_loop_crew_member m ON m.user_id=u.id LEFT JOIN src.src_soc_loop_crew c ON c.id=m.crew_id
		WHERE u.id=$1`, user, today, ws).Scan(&st.Nickname, &st.Energy, &st.TodayEnergy, &st.WeekEnergy, &st.TodayDistanceKm, &st.WeekDistanceKm,
		&st.TerritoryCount, &crewID, &st.Crew, &st.CrewMembers); err != nil {
		return st, err
	}
	st.TodayDistanceKm, st.WeekDistanceKm = math.Round(st.TodayDistanceKm*100)/100, math.Round(st.WeekDistanceKm*100)/100
	if crewID != nil {
		var rank int
		err := s.Pool.QueryRow(ctx, `SELECT r FROM (SELECT m.user_id, rank() OVER (ORDER BY COALESCE(sum(a.claimed_area_m2), 0) DESC, COALESCE(sum(a.distance_m), 0) DESC) r
				FROM src.src_soc_loop_crew_member m LEFT JOIN src.src_act_loop_activity a ON a.user_id=m.user_id AND a.status='settled' AND a.start_time >= $2
				WHERE m.crew_id=$1 GROUP BY m.user_id) x WHERE x.user_id=$3`, *crewID, ws, user).Scan(&rank)
		if err != nil && !db.IsNoRows(err) {
			return st, err
		}
		if err == nil {
			st.CrewWeekRank = &rank
		}
	}
	rows, err := s.Pool.Query(ctx, `SELECT e.territory_id, COALESCE(t.name, '领地 #' || t.id), e.event_type, COALESCE(u.nickname, ''), e.create_time
		FROM src.src_ter_loop_event e JOIN src.src_ter_loop_territory t ON t.id=e.territory_id LEFT JOIN src.src_usr_loop_user u ON u.id=e.actor_user_id
		WHERE e.prev_owner_id=$1 AND e.actor_user_id IS DISTINCT FROM $1 AND e.event_type IN ('capture', 'capture_whole', 'cut', 'weaken')
		  AND e.create_time > now() - interval '7 days' ORDER BY e.id DESC LIMIT 3`, user)
	if err != nil {
		return st, err
	}
	defer rows.Close()
	st.RecentAttacks = []map[string]any{}
	for rows.Next() {
		var id int64
		var name, typ, by string
		var at time.Time
		if err := rows.Scan(&id, &name, &typ, &by, &at); err != nil {
			return st, err
		}
		what := map[string]string{"capture": "被抢走", "capture_whole": "被整块抢走", "cut": "被切走一部分", "weaken": "被削弱守卫"}[typ]
		st.RecentAttacks = append(st.RecentAttacks, map[string]any{"territory_id": id, "name": name, "what": what, "by": by,
			"hours_ago": int(time.Since(at).Hours())})
	}
	return st, rows.Err()
}

func (s *Service) territoryCard(ctx context.Context, id int64) (*TerritoryCard, error) {
	var c TerritoryCard
	var oid, cid *int64
	var onick, cname *string
	err := s.Pool.QueryRow(ctx, `SELECT t.id, COALESCE(t.name, '领地 #' || t.id), t.owner_user_id, u.nickname, t.owner_crew_id, cr.name, t.guard,
			ST_Y(ST_PointOnSurface(t.area_geom)), ST_X(ST_PointOnSurface(t.area_geom))
		FROM src.src_ter_loop_territory t LEFT JOIN src.src_usr_loop_user u ON u.id=t.owner_user_id LEFT JOIN src.src_soc_loop_crew cr ON cr.id=t.owner_crew_id
		WHERE t.id=$1`, id).Scan(&c.ID, &c.Name, &oid, &onick, &cid, &cname, &c.Guard, &c.Center.Lat, &c.Center.Lng)
	if db.IsNoRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if oid != nil {
		c.Owner = &Ref{ID: *oid, Nickname: deref(onick)}
	}
	if cid != nil {
		c.Crew = &Ref{ID: *cid, Name: deref(cname)}
	}
	c.Center = round(c.Center)
	return &c, nil
}

func (s *Service) bossCard(ctx context.Context, id int64) (*BossCard, error) {
	var b BossCard
	err := s.Pool.QueryRow(ctx, `SELECT id, name, hp, hp_max, ST_Y(center_geom), ST_X(center_geom), expire_time FROM src.src_ply_loop_boss WHERE id=$1`, id).
		Scan(&b.ID, &b.Name, &b.HP, &b.MaxHP, &b.Center.Lat, &b.Center.Lng, &b.EndsAt)
	if db.IsNoRows(err) {
		return nil, nil
	}
	b.Center = round(b.Center)
	return &b, err
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func (s *Service) nearbyTargets(ctx context.Context, user int64, pos LatLng) (any, []Card, error) {
	weak, err := s.captureCandidates(ctx, user, pos, 3000, 5)
	if err != nil {
		return nil, nil, err
	}
	defend, err := s.defendCandidates(ctx, user, pos)
	if err != nil {
		return nil, nil, err
	}
	var cards []Card
	list := func(cs []Candidate, withCards bool) []map[string]any {
		out := []map[string]any{}
		for _, c := range cs {
			m := map[string]any{"id": c.ID, "name": c.Name, "guard": c.Guard, "distance_km": math.Round(c.DistanceM/100) / 10, "area_m2": math.Round(c.AreaM2)}
			if c.Owner != "" {
				m["owner"] = c.Owner
			}
			if c.Crew != "" {
				m["crew"] = c.Crew
			}
			if !c.Deadline.IsZero() {
				m["reinforce_hours_left"] = math.Ceil(time.Until(c.Deadline).Hours())
			}
			out = append(out, m)
			if withCards && len(cards) < 3 {
				if tc, err := s.territoryCard(ctx, c.ID); err == nil && tc != nil {
					cards = append(cards, Card{Type: "territory", Territory: tc})
				}
			}
		}
		return out
	}
	var lost []Candidate
	for _, c := range weak {
		if c.Lost {
			lost = append(lost, c)
		}
	}
	res := map[string]any{"weak_nearby": list(weak, true), "my_under_attack": list(defend, true), "my_lost": list(lost, false)}
	return res, cards, nil
}

func (s *Service) nearbyBosses(ctx context.Context, user int64, pos LatLng) (any, []Card, error) {
	bosses, err := s.bossCandidates(ctx, pos, 5000)
	if err != nil {
		return nil, nil, err
	}
	var cards []Card
	bl := []map[string]any{}
	for _, b := range bosses {
		bl = append(bl, map[string]any{"id": b.ID, "name": b.Name, "hp": b.HP, "max_hp": b.MaxHP, "distance_km": math.Round(b.DistanceM/100) / 10,
			"hours_left": math.Ceil(time.Until(b.EndsAt).Hours())})
		if len(cards) < 2 {
			cards = append(cards, Card{Type: "boss", Boss: &BossCard{ID: b.ID, Name: b.Name, HP: b.HP, MaxHP: b.MaxHP, Center: round(b.Center), EndsAt: b.EndsAt}})
		}
	}
	rows, err := s.Pool.Query(ctx, `SELECT c.id, ST_Distance(c.center_geom::geography, `+pointSQL+`::geography), c.energy_min, c.energy_max, c.expire_time
		FROM src.src_ply_loop_chest c WHERE c.remove_time IS NULL AND c.expire_time > now()
		  AND ST_DWithin(c.center_geom::geography, `+pointSQL+`::geography, 3000)
		  AND NOT EXISTS (SELECT 1 FROM src.src_ply_loop_chest_open o WHERE o.chest_id=c.id AND o.user_id=$1)
		ORDER BY 2 LIMIT 5`, user, pos.Lng, pos.Lat)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	chests := []map[string]any{}
	for rows.Next() {
		var id int64
		var d float64
		var lo, hi int
		var exp time.Time
		if err := rows.Scan(&id, &d, &lo, &hi, &exp); err != nil {
			return nil, nil, err
		}
		chests = append(chests, map[string]any{"id": id, "distance_km": math.Round(d/100) / 10, "energy": fmt.Sprintf("%d-%d", lo, hi),
			"hours_left": math.Ceil(time.Until(exp).Hours())})
	}
	return map[string]any{"bosses": bl, "chests": chests}, cards, rows.Err()
}

func (s *Service) gameRules(user int64) map[string]any {
	c := s.Config.For(user)
	var energy []string
	for _, e := range c.Energy {
		if e.Pending {
			continue
		}
		energy = append(energy, fmt.Sprintf("%s 每 %g%s 得 %d 能量", e.Name, e.Per, unitName(string(e.Unit)), e.Energy))
	}
	return map[string]any{
		"energy":           energy,
		"daily_energy_cap": c.DailyEnergyCap,
		"claim":            fmt.Sprintf("GPS 运动（跑步、骑行、徒步、健走）的轨迹闭合成圈即圈地，最小面积 %.0f m²；圈住别人的地按能量和守卫值抢地", c.MinClaimAreaM2),
		"boss":             fmt.Sprintf("怪兽出没 %g 小时；轨迹进入范围按距离造成伤害，居家运动先「出战」后 %g 小时内也算；合击每次消耗 %d 能量", c.Boss.DurationH, c.Boss.EngageH, c.Boss.StrikeCost),
		"defense":          fmt.Sprintf("领地被攻击后 %g 小时内，跑进这块地即可加固，守卫值上限 %d", c.Defense.WindowH, c.Defense.MaxGuard),
		"rally":            fmt.Sprintf("跑团集结跑签到满 %d 人，这次运动能量和合击伤害 +%.0f%%", c.Rally.MinCheckins, c.Rally.BonusRate*100),
	}
}

func unitName(u string) string {
	return map[string]string{"km": " 公里", "m": " 米", "min": " 分钟", "count": " 次", "checkin": " 次签到"}[u]
}

func (s *Service) trainingAdvice(ctx context.Context, user int64) (map[string]any, error) {
	var n int
	var total, longest float64
	var weeks [4]float64
	rows, err := s.Pool.Query(ctx, `SELECT distance_m, start_time FROM src.src_act_loop_activity WHERE user_id=$1 AND status='settled' AND sport IN ('run','hike','walk')
		AND start_time > now() - interval '28 days'`, user)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var d float64
		var t time.Time
		if err := rows.Scan(&d, &t); err != nil {
			rows.Close()
			return nil, err
		}
		n++
		total += d
		longest = math.Max(longest, d)
		if w := int(time.Since(t).Hours() / (24 * 7)); w >= 0 && w < 4 {
			weeks[w] += d
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := map[string]any{"runs_4w": n, "total_km_4w": math.Round(total/100) / 10, "longest_km": math.Round(longest/100) / 10,
		"weekly_km":  []float64{math.Round(weeks[3]/100) / 10, math.Round(weeks[2]/100) / 10, math.Round(weeks[1]/100) / 10, math.Round(weeks[0]/100) / 10},
		"disclaimer": "一般性建议，不构成医疗意见；身体不适请停止运动并就医"}
	if n == 0 {
		out["suggest_km"] = 3.0
		out["note"] = "最近 4 周没有记录，建议从 3 公里轻松跑或快走开始"
		return out, nil
	}
	avg := total / float64(n)
	// Grow at most ~10% over the recent average; cap at the longest run.
	suggest := math.Min(avg*1.1, math.Max(longest, avg))
	out["avg_km"] = math.Round(avg/100) / 10
	out["suggest_km"] = math.Round(suggest/100) / 10
	out["note"] = "每周总量增加不超过 10%，一周安排 1-2 天休息"
	return out, nil
}

// position is the best known location: the request, the context object or
// the end of the latest GPS activity.
func (s *Service) position(ctx context.Context, user int64, req *LatLng, ctxCenter *LatLng) *LatLng {
	if req != nil {
		return req
	}
	if ctxCenter != nil {
		return ctxCenter
	}
	var p LatLng
	err := s.Pool.QueryRow(ctx, `SELECT ST_Y(ST_EndPoint(track_geom)), ST_X(ST_EndPoint(track_geom)) FROM src.src_act_loop_activity
		WHERE user_id=$1 AND track_geom IS NOT NULL ORDER BY start_time DESC LIMIT 1`, user).Scan(&p.Lat, &p.Lng)
	if err != nil {
		return nil
	}
	return &p
}

func describeContext(t *TerritoryCard, b *BossCard) string {
	var sb strings.Builder
	if t != nil {
		owner := "无人占领"
		if t.Owner != nil {
			owner = t.Owner.Nickname + " 占领"
		}
		if t.Crew != nil {
			owner += "（跑团「" + t.Crew.Name + "」）"
		}
		fmt.Fprintf(&sb, "用户正在看领地「%s」（id %d）：%s，守卫值 %d。", t.Name, t.ID, owner, t.Guard)
	}
	if b != nil {
		fmt.Fprintf(&sb, "用户正在看怪兽「%s」（id %d）：血量 %d / %d，%s 结束。", b.Name, b.ID, b.HP, b.MaxHP, b.EndsAt.In(clock.Shanghai).Format("1月2日 15:04"))
	}
	return sb.String()
}
