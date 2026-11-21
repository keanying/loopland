// Package codex is 图鉴: character recruitment, building unlocks, companion
// eggs and medals.
package codex

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// FirstEgg is given with the first piece of land (新手引导 · 第一块地奖励).
const FirstEgg = "gecko"

// Recruit is recruitment progress for one role.
type Recruit struct {
	Role      string  `json:"role"`
	Name      string  `json:"name"`
	Progress  float64 `json:"progress"`
	Threshold float64 `json:"threshold"`
	Unit      string  `json:"unit"`
	Recruited bool    `json:"recruited"`
}

// Egg is hatching progress.
type Egg struct {
	Key        string  `json:"key"`
	Name       string  `json:"name"`
	ProgressKm float64 `json:"progress_km"`
	HatchKm    float64 `json:"hatch_km"`
	Hatched    bool    `json:"hatched"`
}

// MedalRef is a newly awarded medal.
type MedalRef struct {
	Key  string `json:"key"`
	Name string `json:"name"`
}

// Progress is what one activity changed.
type Progress struct {
	Recruits []Recruit  `json:"recruits"`
	Eggs     []Egg      `json:"eggs"`
	Medals   []MedalRef `json:"medals"`
}

// AfterActivity updates totals, recruits characters, hatches eggs and
// awards medals, inside the settlement transaction.
func AfterActivity(ctx context.Context, tx pgx.Tx, cfg gameplay.Config, user int64, sport gameplay.Sport, amount, distanceM float64, firstLand bool) (Progress, error) {
	p := Progress{Recruits: []Recruit{}, Eggs: []Egg{}, Medals: []MedalRef{}}
	var total float64
	if err := tx.QueryRow(ctx, `INSERT INTO src.src_act_sport_total (user_id, sport, amount, distance_m) VALUES ($1,$2,$3,$4)
		ON CONFLICT (user_id, sport) DO UPDATE SET amount=src.src_act_sport_total.amount+EXCLUDED.amount, distance_m=src.src_act_sport_total.distance_m+EXCLUDED.distance_m
		RETURNING amount`, user, string(sport), amount, distanceM).Scan(&total); err != nil {
		return p, err
	}
	for _, r := range cfg.Roles {
		if r.Sport != sport {
			continue
		}
		rec := Recruit{Role: r.Key, Name: r.Name, Progress: total, Threshold: r.Threshold, Unit: string(r.Unit)}
		var owned bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_ply_codex_item WHERE user_id=$1 AND item_type='role' AND item=$2)`, user, r.Key).Scan(&owned); err != nil {
			return p, err
		}
		if owned {
			rec.Recruited = true
		} else if total >= r.Threshold {
			if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_codex_item (user_id, item_type, item) VALUES ($1,'role',$2) ON CONFLICT DO NOTHING`, user, r.Key); err != nil {
				return p, err
			}
			rec.Recruited = true
			if err := inbox.Notify(ctx, tx, user, inbox.System, "招募到新角色",
				fmt.Sprintf("「%s」加入了你的队伍：%s。去领地派驻吧。", r.Name, r.BuffText), map[string]any{"role": r.Key}); err != nil {
				return p, err
			}
		}
		p.Recruits = append(p.Recruits, rec)
	}

	if firstLand {
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_codex_item (user_id, item_type, item) SELECT $1,'egg',$2
			WHERE NOT EXISTS (SELECT 1 FROM src.src_ply_codex_item WHERE user_id=$1 AND item_type IN ('egg','companion') AND item=$2)`, user, FirstEgg); err != nil {
			return p, err
		}
	}

	if km := distanceM / 1000; km > 0 && gameplay.GPSSports[sport] {
		rows, err := tx.Query(ctx, `UPDATE src.src_ply_codex_item SET progress=progress+$2 WHERE user_id=$1 AND item_type='egg' RETURNING item, progress`, user, km)
		if err != nil {
			return p, err
		}
		type eg struct {
			item string
			prog float64
		}
		eggs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (eg, error) {
			var e eg
			return e, r.Scan(&e.item, &e.prog)
		})
		if err != nil {
			return p, err
		}
		for _, e := range eggs {
			c, ok := cfg.Companion(e.item)
			if !ok {
				continue
			}
			out := Egg{Key: c.Key, Name: c.Name, ProgressKm: e.prog, HatchKm: c.HatchKm}
			if e.prog >= c.HatchKm {
				out.Hatched = true
				if _, err := tx.Exec(ctx, `DELETE FROM src.src_ply_codex_item WHERE user_id=$1 AND item_type='egg' AND item=$2`, user, c.Key); err != nil {
					return p, err
				}
				if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_codex_item (user_id, item_type, item, progress) VALUES ($1,'companion',$2,$3) ON CONFLICT DO NOTHING`, user, c.Key, e.prog); err != nil {
					return p, err
				}
				if err := inbox.Notify(ctx, tx, user, inbox.System, "伙伴孵化了", fmt.Sprintf("「%s」破壳而出！可以在图鉴里设为陪跑。", c.Name), map[string]any{"companion": c.Key}); err != nil {
					return p, err
				}
			}
			p.Eggs = append(p.Eggs, out)
		}
	} else if firstLand {
		c, _ := cfg.Companion(FirstEgg)
		p.Eggs = append(p.Eggs, Egg{Key: c.Key, Name: c.Name, HatchKm: c.HatchKm})
	}

	medals, err := AwardMedals(ctx, tx, cfg, user)
	if err != nil {
		return p, err
	}
	p.Medals = append(p.Medals, medals...)
	return p, nil
}

// Stat counter keys (user_stats). distance_km is derived from sport totals.
const (
	StatDefends     = "defends"
	StatLoopsSingle = "loops_single" // best number of loops in one activity
	StatBossDefeats = "boss_defeats"
	StatChests      = "chests"
	StatRoutes      = "routes"
)

// IncStat adds delta to a counter.
func IncStat(ctx context.Context, q db.Querier, user int64, key string, delta float64) error {
	_, err := q.Exec(ctx, `INSERT INTO src.src_usr_stat (user_id, stat_key, stat_value) VALUES ($1,$2,$3)
		ON CONFLICT (user_id, stat_key) DO UPDATE SET stat_value = src.src_usr_stat.stat_value + EXCLUDED.stat_value`, user, key, delta)
	return err
}

// MaxStat raises a counter to v if it is higher.
func MaxStat(ctx context.Context, q db.Querier, user int64, key string, v float64) error {
	_, err := q.Exec(ctx, `INSERT INTO src.src_usr_stat (user_id, stat_key, stat_value) VALUES ($1,$2,$3)
		ON CONFLICT (user_id, stat_key) DO UPDATE SET stat_value = GREATEST(src.src_usr_stat.stat_value, EXCLUDED.stat_value)`, user, key, v)
	return err
}

// medalValues returns the current value of every medal type.
func medalValues(ctx context.Context, q db.Querier, user int64) (map[string]float64, error) {
	vals := map[string]float64{}
	var dist float64
	if err := q.QueryRow(ctx, `SELECT COALESCE(sum(distance_m),0) FROM src.src_act_sport_total WHERE user_id=$1`, user).Scan(&dist); err != nil {
		return nil, err
	}
	vals[gameplay.MedalDistanceKm] = dist / 1000
	rows, err := q.Query(ctx, `SELECT stat_key, stat_value FROM src.src_usr_stat WHERE user_id=$1`, user)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var k string
		var v float64
		if err := rows.Scan(&k, &v); err != nil {
			return nil, err
		}
		vals[k] = v
	}
	return vals, rows.Err()
}

// AwardMedals grants every configured medal whose target is reached and
// returns the newly awarded ones.
func AwardMedals(ctx context.Context, tx pgx.Tx, cfg gameplay.Config, user int64) ([]MedalRef, error) {
	vals, err := medalValues(ctx, tx, user)
	if err != nil {
		return nil, err
	}
	out := []MedalRef{}
	for _, m := range cfg.Medals {
		if vals[m.Type] < m.Target {
			continue
		}
		tag, err := tx.Exec(ctx, `INSERT INTO src.src_ply_codex_item (user_id, item_type, item) VALUES ($1,'medal',$2) ON CONFLICT DO NOTHING`, user, m.Key)
		if err != nil {
			return nil, err
		}
		if tag.RowsAffected() == 1 {
			out = append(out, MedalRef{Key: m.Key, Name: m.Name})
			if err := inbox.Notify(ctx, tx, user, inbox.System, "获得新奖牌", fmt.Sprintf("恭喜获得奖牌「%s」！", m.Name), map[string]any{"medal": m.Key}); err != nil {
				return nil, err
			}
		}
	}
	return out, nil
}

// View is GET /v1/codex.
type View struct {
	Progress   map[string]string `json:"progress"`
	Roles      []RoleCard        `json:"roles"`
	Buildings  []BuildingCard    `json:"buildings"`
	Companions []CompanionCard   `json:"companions"`
	Medals     []MedalCard       `json:"medals"`
	Monsters   []MonsterCard     `json:"monsters"`
}

// MonsterCard is a city monster the user has (or hasn't) fought.
type MonsterCard struct {
	Key      string `json:"key"`
	Name     string `json:"name"`
	Strikes  int    `json:"strikes"`
	Defeats  int    `json:"defeats"`
	BestRank *int   `json:"best_rank"`
	Seen     bool   `json:"seen"`
}

// RoleCard is a character in the codex.
type RoleCard struct {
	Key         string     `json:"key"`
	Name        string     `json:"name"`
	Sport       string     `json:"sport"`
	Threshold   float64    `json:"threshold"`
	Unit        string     `json:"unit"`
	Progress    float64    `json:"progress"`
	Obtained    bool       `json:"obtained"`
	ObtainedAt  *time.Time `json:"obtained_at"`
	BuffText    string     `json:"buff_text"`
	StationedAt *int64     `json:"stationed_at"`
}

// BuildingCard is a building blueprint.
type BuildingCard struct {
	Key         string `json:"key"`
	Name        string `json:"name"`
	UnlockLevel int    `json:"unlock_level"`
	Unlocked    bool   `json:"unlocked"`
	Cost        int    `json:"cost"`
	Guard       int    `json:"guard"`
	DailyEnergy int    `json:"daily_energy"`
	// Blueprint: the user owns this building's blueprint (boss drop).
	Blueprint bool `json:"blueprint"`
}

// CompanionCard is a running partner.
type CompanionCard struct {
	Key        string  `json:"key"`
	Name       string  `json:"name"`
	State      string  `json:"state"`
	ProgressKm float64 `json:"progress_km"`
	HatchKm    float64 `json:"hatch_km"`
	Escort     bool    `json:"escort"`
	Level      int     `json:"level"`
	Exp        int     `json:"exp"`
	ExpToNext  int     `json:"exp_to_next"`
	Meters     float64 `json:"meters"`
}

// MedalCard is a medal.
type MedalCard struct {
	Key        string     `json:"key"`
	Name       string     `json:"name"`
	Type       string     `json:"type"`
	Progress   float64    `json:"progress"`
	Target     float64    `json:"target"`
	Obtained   bool       `json:"obtained"`
	ObtainedAt *time.Time `json:"obtained_at"`
}

type item struct {
	kind, key string
	progress  float64
	at        time.Time
}

// Load builds the codex for a user.
func Load(ctx context.Context, q db.Querier, cfg gameplay.Config, user int64) (View, error) {
	v := View{Progress: map[string]string{}}
	rows, err := q.Query(ctx, `SELECT item_type, item, progress, obtain_time FROM src.src_ply_codex_item WHERE user_id=$1`, user)
	if err != nil {
		return v, err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (item, error) {
		var it item
		return it, r.Scan(&it.kind, &it.key, &it.progress, &it.at)
	})
	if err != nil {
		return v, err
	}
	have := map[string]item{}
	for _, it := range items {
		have[it.kind+":"+it.key] = it
	}
	totals := map[string]float64{}
	rows, err = q.Query(ctx, `SELECT sport, amount FROM src.src_act_sport_total WHERE user_id=$1`, user)
	if err != nil {
		return v, err
	}
	for rows.Next() {
		var s string
		var a float64
		if err := rows.Scan(&s, &a); err != nil {
			rows.Close()
			return v, err
		}
		totals[s] = a
	}
	rows.Close()
	stationed := map[string]int64{}
	rows, err = q.Query(ctx, `SELECT role, territory_id FROM src.src_ter_station WHERE user_id=$1`, user)
	if err != nil {
		return v, err
	}
	for rows.Next() {
		var r string
		var t int64
		if err := rows.Scan(&r, &t); err != nil {
			rows.Close()
			return v, err
		}
		stationed[r] = t
	}
	rows.Close()
	var earned int64
	var escort *string
	if err := q.QueryRow(ctx, `SELECT energy_earned_total, escort_companion_key FROM src.src_usr_user WHERE id=$1`, user).Scan(&earned, &escort); err != nil {
		return v, err
	}
	level := cfg.Level(earned)

	n := 0
	for _, r := range cfg.Roles {
		c := RoleCard{Key: r.Key, Name: r.Name, Sport: string(r.Sport), Threshold: r.Threshold, Unit: string(r.Unit),
			Progress: totals[string(r.Sport)], BuffText: r.BuffText}
		if it, ok := have["role:"+r.Key]; ok {
			c.Obtained, c.ObtainedAt = true, &it.at
			n++
		}
		if t, ok := stationed[r.Key]; ok {
			c.StationedAt = &t
		}
		v.Roles = append(v.Roles, c)
	}
	v.Progress["roles"] = fmt.Sprintf("%d/%d", n, len(cfg.Roles))

	n = 0
	for _, b := range cfg.Buildings {
		_, bp := have["blueprint:"+b.Key]
		c := BuildingCard{Key: b.Key, Name: b.Name, UnlockLevel: b.UnlockLevel, Unlocked: level >= b.UnlockLevel || (bp && b.BlueprintBypassLevel),
			Cost: b.Cost, Guard: b.Guard, DailyEnergy: b.DailyEnergy, Blueprint: bp}
		if c.Unlocked {
			n++
		}
		v.Buildings = append(v.Buildings, c)
	}
	v.Progress["buildings"] = fmt.Sprintf("%d/%d", n, len(cfg.Buildings))

	n = 0
	growth := map[string][2]float64{}
	rows, err = q.Query(ctx, `SELECT companion, exp, meters FROM src.src_ply_companion_growth WHERE user_id=$1`, user)
	if err != nil {
		return v, err
	}
	for rows.Next() {
		var k string
		var exp int
		var m float64
		if err := rows.Scan(&k, &exp, &m); err != nil {
			rows.Close()
			return v, err
		}
		growth[k] = [2]float64{float64(exp), m}
	}
	rows.Close()
	for _, cp := range cfg.Companions {
		c := CompanionCard{Key: cp.Key, Name: cp.Name, State: "none", HatchKm: cp.HatchKm}
		g := growth[cp.Key]
		c.Exp, c.Meters = int(g[0]), g[1]
		c.Level = cfg.CompanionLevel(c.Exp)
		c.ExpToNext = c.Level*cfg.Pet.ExpPerLevel - c.Exp
		if it, ok := have["egg:"+cp.Key]; ok {
			c.State, c.ProgressKm = "egg", it.progress
		}
		if it, ok := have["companion:"+cp.Key]; ok {
			c.State, c.ProgressKm = "hatched", it.progress
			c.Escort = escort != nil && *escort == cp.Key
			n++
		}
		v.Companions = append(v.Companions, c)
	}
	v.Progress["companions"] = fmt.Sprintf("%d/%d", n, len(cfg.Companions))

	n = 0
	vals, err := medalValues(ctx, q, user)
	if err != nil {
		return v, err
	}
	for _, m := range cfg.Medals {
		c := MedalCard{Key: m.Key, Name: m.Name, Type: m.Type, Target: m.Target, Progress: min(vals[m.Type], m.Target)}
		if it, ok := have["medal:"+m.Key]; ok {
			c.Obtained, c.ObtainedAt = true, &it.at
			c.Progress = m.Target
			n++
		}
		v.Medals = append(v.Medals, c)
	}
	// Season medals are awarded at settlement and named after the season.
	for _, it := range items {
		if it.kind == "medal" && strings.HasPrefix(it.key, "season:") {
			at := it.at
			v.Medals = append(v.Medals, MedalCard{Key: it.key, Name: strings.TrimPrefix(it.key, "season:"), Type: "season", Progress: 1, Target: 1, Obtained: true, ObtainedAt: &at})
			n++
		}
	}
	v.Progress["medals"] = fmt.Sprintf("%d/%d", n, len(v.Medals))

	type mon struct {
		strikes, defeats int
		best             *int
	}
	mons := map[string]mon{}
	rows, err = q.Query(ctx, `SELECT boss_type, strikes, defeats, best_rank FROM src.src_ply_user_monster WHERE user_id=$1`, user)
	if err != nil {
		return v, err
	}
	for rows.Next() {
		var k string
		var m mon
		if err := rows.Scan(&k, &m.strikes, &m.defeats, &m.best); err != nil {
			rows.Close()
			return v, err
		}
		mons[k] = m
	}
	rows.Close()
	seen := 0
	for _, b := range cfg.Bosses {
		m, ok := mons[b.Key]
		v.Monsters = append(v.Monsters, MonsterCard{Key: b.Key, Name: b.Name, Strikes: m.strikes, Defeats: m.defeats, BestRank: m.best, Seen: ok})
		if ok {
			seen++
		}
	}
	if v.Monsters == nil {
		v.Monsters = []MonsterCard{}
	}
	v.Progress["monsters"] = fmt.Sprintf("%d/%d", seen, len(cfg.Bosses))
	return v, nil
}

// Count is the number of collected items (for admin user detail).
func Count(ctx context.Context, q db.Querier, user int64) (int, error) {
	var n int
	err := q.QueryRow(ctx, `SELECT count(*) FROM src.src_ply_codex_item WHERE user_id=$1 AND item_type IN ('role','companion','medal')`, user).Scan(&n)
	return n, err
}

// Handler serves /v1/codex.
type Handler struct {
	Pool   *pgxpool.Pool
	Config *gameplay.Store
}

// Routes registers the endpoints.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /v1/codex", auth(h.get))
	mux.Handle("POST /v1/codex/companions/{key}/escort", auth(h.escort))
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) error {
	uid := httpx.UserID(r.Context())
	v, err := Load(r.Context(), h.Pool, h.Config.For(uid), uid)
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *Handler) escort(w http.ResponseWriter, r *http.Request) error {
	uid := httpx.UserID(r.Context())
	key := r.PathValue("key")
	tag, err := h.Pool.Exec(r.Context(), `UPDATE src.src_usr_user SET escort_companion_key=$2 WHERE id=$1
		AND EXISTS (SELECT 1 FROM src.src_ply_codex_item WHERE user_id=$1 AND item_type='companion' AND item=$2)`, uid, key)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return httpx.Forbidden("companion_not_hatched", "这个伙伴还没有孵化")
	}
	return h.get(w, r)
}
