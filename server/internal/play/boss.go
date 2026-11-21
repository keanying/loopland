package play

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/activity"
	"github.com/keanying/loopland/server/internal/codex"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/realtime"
)

func errNotEnoughEnergy(need, have int) error {
	return httpx.Forbidden("not_enough_energy", fmt.Sprintf("需要 %d 能量，当前 %d", need, have))
}

var (
	errOutOfRange    = httpx.Forbidden("out_of_range", "离得太远了，到范围内才能出手")
	errBossNotActive = httpx.Conflict("boss_not_active", "怪兽已经离开了")
)

// Monster descriptions (the four bad habits).
var bossDesc = map[string]string{
	"sofa":  "它代表「懒得动」。霸占附近的领地，让能量产出减半。",
	"bat":   "它代表「熬夜」。只在夜里出没，偷走大家的精力。",
	"smog":  "它代表「闷在屋里」。雾蒙蒙地罩住街区，让人不想出门。",
	"sugar": "它代表「管不住嘴」。用甜食把跑者困在原地。",
}

// LatLng is a coordinate.
type LatLng struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

// UserRef is a compact user.
type UserRef struct {
	ID        int64   `json:"id"`
	Nickname  string  `json:"nickname"`
	AvatarURL *string `json:"avatar_url,omitempty"`
}

// BossSummary is a monster on the map.
type BossSummary struct {
	ID           int64     `json:"id"`
	Kind         string    `json:"kind"`
	Name         string    `json:"name"`
	Level        int       `json:"level"`
	Center       LatLng    `json:"center"`
	RadiusM      float64   `json:"radius_m"`
	HP           int       `json:"hp"`
	HPMax        int       `json:"hp_max"`
	Status       string    `json:"status"`
	SpawnedAt    time.Time `json:"spawned_at"`
	ExpiresAt    time.Time `json:"expires_at"`
	LocationName string    `json:"location_name"`
	Participants int       `json:"participants"`
	SpawnedBy    *int64    `json:"spawned_by"`
}

// DropView is one entry of the published drop table.
type DropView struct {
	Item    string  `json:"item"`
	Kind    string  `json:"kind"`
	Name    string  `json:"name"`
	Percent float64 `json:"percent"`
}

// RankRow is one leaderboard row.
type RankRow struct {
	Rank   int     `json:"rank"`
	User   UserRef `json:"user"`
	Damage int     `json:"damage"`
}

// RewardItem is one drop someone received.
type RewardItem struct {
	Item            string `json:"item"`
	Kind            string `json:"kind"`
	Name            string `json:"name"`
	ConvertedEnergy *int   `json:"converted_energy"`
}

// BossView is GET /v1/bosses/{id}.
type BossView struct {
	BossSummary
	Description         string        `json:"description"`
	DefeatedAt          *time.Time    `json:"defeated_at"`
	OccupiedTerritories int           `json:"occupied_territories"`
	EffectText          string        `json:"effect_text"`
	DamageRules         []DamageRule  `json:"damage_rules"`
	Strike              StrikeInfo    `json:"strike"`
	Rank                []RankRow     `json:"rank"`
	Me                  MyBoss        `json:"me"`
	Drops               []DropView    `json:"drops"`
	MyRewards           []RewardItem  `json:"my_rewards"`
	Rewards             []AdminReward `json:"rewards,omitempty"`
}

// DamageRule is shown on the boss page.
type DamageRule struct {
	Sport  string  `json:"sport"`
	Label  string  `json:"label"`
	Per    float64 `json:"per"`
	Unit   string  `json:"unit"`
	Damage int     `json:"damage"`
}

// StrikeInfo describes 合击.
type StrikeInfo struct {
	Cost         int `json:"cost"`
	Damage       int `json:"damage"`
	CooldownS    int `json:"cooldown_s"`
	AvailableInS int `json:"available_in_s"`
}

// MyBoss is the viewer's standing.
type MyBoss struct {
	Damage       int        `json:"damage"`
	Rank         *int       `json:"rank"`
	EngagedUntil *time.Time `json:"engaged_until"`
}

// AdminReward is a participant's rewards (admin view).
type AdminReward struct {
	User   UserRef      `json:"user"`
	Rank   int          `json:"rank"`
	Damage int          `json:"damage"`
	Items  []RewardItem `json:"items"`
	Energy int          `json:"energy"`
}

const bossCols = `b.id, b.boss_type, b.name, b.level, ST_Y(b.center_geom), ST_X(b.center_geom), b.radius_m, b.hp, b.hp_max, b.status,
	b.spawn_time, b.expire_time, b.location_name, (SELECT count(DISTINCT user_id) FROM src.src_ply_boss_hit h WHERE h.boss_id=b.id), b.spawned_by`

func scanBoss(r pgx.Row) (BossSummary, error) {
	var b BossSummary
	err := r.Scan(&b.ID, &b.Kind, &b.Name, &b.Level, &b.Center.Lat, &b.Center.Lng, &b.RadiusM, &b.HP, &b.HPMax, &b.Status,
		&b.SpawnedAt, &b.ExpiresAt, &b.LocationName, &b.Participants, &b.SpawnedBy)
	return b, err
}

var sportLabel = map[gameplay.Sport]string{gameplay.SportRun: "跑步", gameplay.SportRide: "骑行", gameplay.SportHike: "徒步",
	gameplay.SportWalk: "健走", gameplay.SportRope: "跳绳", gameplay.SportStrength: "力量跟练", gameplay.SportYoga: "瑜伽跟练", gameplay.SportHIIT: "HIIT 跟练"}

// SpawnInput creates a monster.
type SpawnInput struct {
	Kind         string  `json:"kind"`
	Lat          float64 `json:"lat"`
	Lng          float64 `json:"lng"`
	LocationName string  `json:"location_name"`
	Level        int     `json:"level"`
	HP           int     `json:"hp"`
	RadiusM      float64 `json:"radius_m"`
	DurationH    float64 `json:"duration_h"`
}

// Spawn places a monster (admin id 0 = system).
func (s *Service) Spawn(ctx context.Context, in SpawnInput, adminID int64) (int64, error) {
	cfg := s.Config.For(0)
	var def *gameplay.Boss
	for i := range cfg.Bosses {
		if cfg.Bosses[i].Key == in.Kind {
			def = &cfg.Bosses[i]
		}
	}
	if def == nil {
		return 0, httpx.BadRequest("unknown_boss", "没有这种怪兽")
	}
	if in.Lat < -90 || in.Lat > 90 || in.Lng < -180 || in.Lng > 180 || (in.Lat == 0 && in.Lng == 0) {
		return 0, httpx.BadRequest("invalid_point", "位置不合法")
	}
	if in.HP <= 0 {
		in.HP = cfg.Boss.DefaultHP
	}
	if in.RadiusM <= 0 {
		in.RadiusM = cfg.Boss.RadiusM
	}
	if in.DurationH <= 0 {
		in.DurationH = cfg.Boss.DurationH
	}
	if in.Level <= 0 {
		in.Level = max(1, in.HP/1000+2)
	}
	drops, _ := json.Marshal(def.Drops)
	var by *int64
	if adminID > 0 {
		by = &adminID
	}
	var id int64
	err := s.Pool.QueryRow(ctx, `INSERT INTO src.src_ply_boss (boss_type, name, level, location_name, center_geom, radius_m, hp_max, hp, drops_json, spawned_by, expire_time)
		VALUES ($1,$2,$3,$4, ST_SetSRID(ST_MakePoint($5,$6),4326), $7, $8, $8, $9, $10, now() + make_interval(secs => $11)) RETURNING id`,
		in.Kind, def.Name, in.Level, in.LocationName, in.Lng, in.Lat, in.RadiusM, in.HP, drops, by, in.DurationH*3600).Scan(&id)
	return id, err
}

// Get builds the boss page for viewer (0 = admin: full rank and rewards).
func (s *Service) Get(ctx context.Context, id, viewer int64) (BossView, error) {
	var v BossView
	b, err := scanBoss(s.Pool.QueryRow(ctx, `SELECT `+bossCols+` FROM src.src_ply_boss b WHERE b.id=$1`, id))
	if db.IsNoRows(err) {
		return v, httpx.NotFound("怪兽")
	}
	if err != nil {
		return v, err
	}
	v.BossSummary = b
	cfg := s.Config.For(viewer)
	v.Description = bossDesc[b.Kind]
	var dropsRaw []byte
	if err := s.Pool.QueryRow(ctx, `SELECT drops_json, CASE WHEN status='defeated' THEN end_time END,
			(SELECT count(*) FROM src.src_ter_territory t WHERE t.owner_user_id IS NOT NULL
			   AND ST_DWithin(ST_PointOnSurface(t.area_geom)::geography, b.center_geom::geography, b.radius_m))
		FROM src.src_ply_boss b WHERE id=$1`, id).Scan(&dropsRaw, &v.DefeatedAt, &v.OccupiedTerritories); err != nil {
		return v, err
	}
	v.EffectText = fmt.Sprintf("范围内领地每日能量产出减少 %.0f%%", cfg.Boss.YieldPenaltyPct)
	var drops []gameplay.Drop
	_ = json.Unmarshal(dropsRaw, &drops)
	v.Drops = []DropView{}
	for _, d := range drops {
		v.Drops = append(v.Drops, DropView{Item: d.Item, Kind: d.Kind, Name: itemName(cfg, d.Kind, d.Item), Percent: d.Percent})
	}
	v.DamageRules = []DamageRule{}
	for _, d := range cfg.Boss.Damage {
		v.DamageRules = append(v.DamageRules, DamageRule{Sport: string(d.Sport), Label: sportLabel[d.Sport], Per: d.Per, Unit: string(d.Unit), Damage: d.Damage})
	}
	v.Strike = StrikeInfo{Cost: cfg.Boss.StrikeCost, Damage: cfg.Boss.StrikeDamage, CooldownS: cfg.Boss.StrikeCooldownS}
	if viewer > 0 && s.Redis != nil {
		if ttl, err := s.Redis.TTL(ctx, cooldownKey(id, viewer)).Result(); err == nil && ttl > 0 {
			v.Strike.AvailableInS = int(math.Ceil(ttl.Seconds()))
		}
	}
	limit := 20
	if viewer == 0 {
		limit = 10000
	}
	rows, err := s.Pool.Query(ctx, `SELECT u.id, u.nickname, u.avatar_url, sum(h.damage)::int AS dmg
		FROM src.src_ply_boss_hit h JOIN src.src_usr_user u ON u.id=h.user_id WHERE h.boss_id=$1 GROUP BY u.id ORDER BY dmg DESC, min(h.id) LIMIT $2`, id, limit)
	if err != nil {
		return v, err
	}
	v.Rank, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (RankRow, error) {
		var x RankRow
		return x, r.Scan(&x.User.ID, &x.User.Nickname, &x.User.AvatarURL, &x.Damage)
	})
	if err != nil {
		return v, err
	}
	for i := range v.Rank {
		v.Rank[i].Rank = i + 1
	}
	if v.Rank == nil {
		v.Rank = []RankRow{}
	}
	v.MyRewards = []RewardItem{}
	if viewer > 0 {
		if err := s.Pool.QueryRow(ctx, `SELECT COALESCE(sum(damage),0) FROM src.src_ply_boss_hit WHERE boss_id=$1 AND user_id=$2`, id, viewer).Scan(&v.Me.Damage); err != nil {
			return v, err
		}
		if v.Me.Damage > 0 {
			var r int
			if err := s.Pool.QueryRow(ctx, `SELECT count(*)+1 FROM (SELECT user_id, sum(damage) d FROM src.src_ply_boss_hit WHERE boss_id=$1 GROUP BY user_id) x
				WHERE x.d > $2`, id, v.Me.Damage).Scan(&r); err != nil {
				return v, err
			}
			v.Me.Rank = &r
		}
		var until time.Time
		if err := s.Pool.QueryRow(ctx, `SELECT engage_end_time FROM src.src_ply_boss_engage WHERE boss_id=$1 AND user_id=$2 AND engage_end_time > now()`, id, viewer).Scan(&until); err == nil {
			v.Me.EngagedUntil = &until
		}
		var items []byte
		if err := s.Pool.QueryRow(ctx, `SELECT items_json FROM src.src_ply_boss_reward WHERE boss_id=$1 AND user_id=$2`, id, viewer).Scan(&items); err == nil {
			_ = json.Unmarshal(items, &v.MyRewards)
		}
	} else {
		rows, err := s.Pool.Query(ctx, `SELECT u.id, u.nickname, r.rank, r.damage, r.items_json, r.energy FROM src.src_ply_boss_reward r JOIN src.src_usr_user u ON u.id=r.user_id
			WHERE r.boss_id=$1 ORDER BY r.rank`, id)
		if err != nil {
			return v, err
		}
		v.Rewards, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (AdminReward, error) {
			var x AdminReward
			var items []byte
			err := r.Scan(&x.User.ID, &x.User.Nickname, &x.Rank, &x.Damage, &items, &x.Energy)
			_ = json.Unmarshal(items, &x.Items)
			return x, err
		})
		if err != nil {
			return v, err
		}
		if v.Rewards == nil {
			v.Rewards = []AdminReward{}
		}
	}
	return v, nil
}

func cooldownKey(boss, user int64) string { return fmt.Sprintf("boss:cd:%d:%d", boss, user) }

func inRange(ctx context.Context, q db.Querier, table string, id int64, lat, lng float64) (bool, error) {
	var ok bool
	err := q.QueryRow(ctx, `SELECT ST_DWithin(center_geom::geography, ST_SetSRID(ST_MakePoint($2,$3),4326)::geography, radius_m) FROM `+table+` WHERE id=$1`,
		id, lng, lat).Scan(&ok)
	if db.IsNoRows(err) {
		return false, httpx.NotFound("目标")
	}
	return ok, err
}

// StrikeResult is POST /v1/bosses/{id}/strike.
type StrikeResult struct {
	Damage   int     `json:"damage"`
	ComboPct float64 `json:"combo_pct"`
	Energy   int     `json:"energy"`
	Boss     struct {
		ID     int64  `json:"id"`
		HP     int    `json:"hp"`
		Status string `json:"status"`
	} `json:"boss"`
}

// Strike is 合击: spend energy to damage a monster in range.
func (s *Service) Strike(ctx context.Context, user, id int64, lat, lng float64) (StrikeResult, error) {
	cfg := s.Config.For(user)
	var res StrikeResult
	ok, err := inRange(ctx, s.Pool, "src.src_ply_boss", id, lat, lng)
	if err != nil {
		return res, err
	}
	if !ok {
		return res, errOutOfRange
	}
	set, err := s.Redis.SetNX(ctx, cooldownKey(id, user), 1, time.Duration(cfg.Boss.StrikeCooldownS)*time.Second).Result()
	if err != nil {
		return res, err
	}
	if !set {
		ttl, _ := s.Redis.TTL(ctx, cooldownKey(id, user)).Result()
		e := httpx.E(http.StatusTooManyRequests, "cooldown", "合击冷却中")
		e.Extra = map[string]any{"retry_after_s": int(math.Ceil(ttl.Seconds()))}
		return res, e
	}
	var events []realtime.Event
	var crew *int64
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var status string
		var hp int
		if err := tx.QueryRow(ctx, `SELECT status, hp FROM src.src_ply_boss WHERE id=$1 FOR UPDATE`, id).Scan(&status, &hp); err != nil {
			return err
		}
		if status != "active" || hp <= 0 {
			return errBossNotActive
		}
		energy, err := spend(ctx, tx, user, cfg.Boss.StrikeCost, "boss_strike", id)
		if err != nil {
			return err
		}
		res.Energy = energy
		err = tx.QueryRow(ctx, `SELECT crew_id FROM src.src_soc_crew_member WHERE user_id=$1`, user).Scan(&crew)
		if err != nil && !db.IsNoRows(err) {
			return err
		}
		bonus := 0.0
		if crew != nil {
			var mates int
			if err := tx.QueryRow(ctx, `SELECT count(DISTINCT user_id) FROM src.src_ply_boss_hit WHERE boss_id=$1 AND crew_id=$2 AND user_id<>$3
				AND source='strike' AND create_time > now() - make_interval(secs => $4)`, id, *crew, user, cfg.Boss.ComboWindowS).Scan(&mates); err != nil {
				return err
			}
			res.ComboPct = math.Min(cfg.Boss.ComboMaxPct, float64(mates)*cfg.Boss.ComboPct)
			bonus += res.ComboPct
			bonus += crewBossBuff(ctx, tx, cfg, user)
		}
		dmg := int(math.Floor(float64(cfg.Boss.StrikeDamage) * (1 + bonus/100)))
		hits, evs, err := s.hit(ctx, tx, cfg, id, user, crew, "strike", nil, dmg, cfg.Boss.StrikeCost)
		if err != nil {
			return err
		}
		events = evs
		res.Damage = hits.Damage
		return tx.QueryRow(ctx, `SELECT id, hp, status FROM src.src_ply_boss WHERE id=$1`, id).Scan(&res.Boss.ID, &res.Boss.HP, &res.Boss.Status)
	})
	if err != nil {
		s.Redis.Del(ctx, cooldownKey(id, user))
		return res, err
	}
	s.Hub.Publish(ctx, events...)
	if crew != nil && res.Boss.Status == "active" {
		s.rally(ctx, *crew, id, user)
	}
	return res, nil
}

// crewBossBuff is 旗手's crew damage bonus if the user owns the role.
func crewBossBuff(ctx context.Context, tx pgx.Tx, cfg gameplay.Config, user int64) float64 {
	var pct float64
	for _, r := range cfg.Roles {
		if r.Buff != gameplay.BuffCrewBossDmgPct {
			continue
		}
		var owned bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_ply_codex_item WHERE user_id=$1 AND item_type='role' AND item=$2)`, user, r.Key).Scan(&owned); err == nil && owned {
			pct += r.BuffValue
		}
	}
	return pct
}

// rally calls the crew to join, at most once per 5 minutes per crew and boss.
func (s *Service) rally(ctx context.Context, crew, boss, by int64) {
	ok, err := s.Redis.SetNX(ctx, fmt.Sprintf("boss:rally:%d:%d", crew, boss), 1, 5*time.Minute).Result()
	if err != nil || !ok {
		return
	}
	var nick, name string
	_ = s.Pool.QueryRow(ctx, `SELECT u.nickname, b.name FROM src.src_usr_user u, src.src_ply_boss b WHERE u.id=$1 AND b.id=$2`, by, boss).Scan(&nick, &name)
	rows, err := s.Pool.Query(ctx, `SELECT user_id FROM src.src_soc_crew_member WHERE crew_id=$1 AND user_id<>$2`, crew, by)
	if err != nil {
		return
	}
	mates, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil || len(mates) == 0 {
		return
	}
	for _, m := range mates {
		_ = inbox.Notify(ctx, s.Pool, m, inbox.Monster, "跑团合击召集", fmt.Sprintf("%s 正在合击%s，快来一起出手！", nick, name), map[string]any{"boss_id": boss})
	}
	s.Hub.Publish(ctx, realtime.NewEvent("", mates, map[string]any{"type": "rally", "boss_id": boss, "by": map[string]any{"id": by, "nickname": nick}}))
}

// hit applies damage inside tx and finishes the boss when its HP hits 0.
func (s *Service) hit(ctx context.Context, tx pgx.Tx, cfg gameplay.Config, boss, user int64, crew *int64, source string, activityID *int64, dmg, spent int) (activity.BossHit, []realtime.Event, error) {
	var out activity.BossHit
	var hp int
	var status, kind, nick string
	if err := tx.QueryRow(ctx, `SELECT b.hp, b.status, b.boss_type, b.name, u.nickname FROM src.src_ply_boss b, src.src_usr_user u WHERE b.id=$1 AND u.id=$2 FOR UPDATE OF b`,
		boss, user).Scan(&hp, &status, &kind, &out.Name, &nick); err != nil {
		return out, nil, err
	}
	if status != "active" || dmg <= 0 {
		return out, nil, nil
	}
	dmg = min(dmg, hp)
	out.BossID, out.Damage = boss, dmg
	if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_boss_hit (boss_id, user_id, crew_id, source, activity_id, damage, energy_spent) VALUES ($1,$2,$3,$4,$5,$6,$7)`,
		boss, user, crew, source, activityID, dmg, spent); err != nil {
		return out, nil, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_user_monster (user_id, boss_type, strikes) VALUES ($1,$2,1)
		ON CONFLICT (user_id, boss_type) DO UPDATE SET strikes = src.src_ply_user_monster.strikes + 1`, user, kind); err != nil {
		return out, nil, err
	}
	hp -= dmg
	newStatus := "active"
	if hp <= 0 {
		newStatus = "defeated"
		out.Defeated = true
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_ply_boss SET hp=$2, status=$3, end_time=CASE WHEN $3='defeated' THEN now() END WHERE id=$1`, boss, hp, newStatus); err != nil {
		return out, nil, err
	}
	events := []realtime.Event{realtime.NewEvent(fmt.Sprintf("boss:%d", boss), nil, map[string]any{
		"type": "boss", "boss": map[string]any{"id": boss, "hp": hp, "status": newStatus}, "by": map[string]any{"id": user, "nickname": nick}, "damage": dmg})}
	if out.Defeated {
		if err := s.finish(ctx, tx, cfg, boss, true); err != nil {
			return out, nil, err
		}
	}
	return out, events, nil
}

// roll picks a drop deterministically from (boss, user, n), so the outcome
// can be audited and re-derived.
func roll(drops []gameplay.Drop, boss, user int64, n int) gameplay.Drop {
	h := sha256.Sum256([]byte(fmt.Sprintf("loopland-drop:%d:%d:%d", boss, user, n)))
	x := float64(binary.BigEndian.Uint64(h[:8])%1_000_000) / 10_000 // 0..100
	acc := 0.0
	for _, d := range drops {
		acc += d.Percent
		if x < acc {
			return d
		}
	}
	return drops[len(drops)-1]
}

const duplicateEnergy = 50

// finish distributes rewards: defeated → drops by damage rank; expired →
// partial refund of strike energy. It is idempotent per (boss, user).
func (s *Service) finish(ctx context.Context, tx pgx.Tx, cfg gameplay.Config, boss int64, defeated bool) error {
	var raw []byte
	var kind, name string
	if err := tx.QueryRow(ctx, `SELECT drops_json, boss_type, name FROM src.src_ply_boss WHERE id=$1`, boss).Scan(&raw, &kind, &name); err != nil {
		return err
	}
	var drops []gameplay.Drop
	_ = json.Unmarshal(raw, &drops)
	rows, err := tx.Query(ctx, `SELECT user_id, sum(damage)::int, sum(energy_spent)::int FROM src.src_ply_boss_hit WHERE boss_id=$1
		GROUP BY user_id ORDER BY sum(damage) DESC, min(id)`, boss)
	if err != nil {
		return err
	}
	type part struct {
		user          int64
		damage, spent int
	}
	parts, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (part, error) {
		var p part
		return p, r.Scan(&p.user, &p.damage, &p.spent)
	})
	if err != nil {
		return err
	}
	for i, p := range parts {
		rank := i + 1
		items := []RewardItem{}
		energy := 0
		if defeated && len(drops) > 0 {
			rolls := 1
			if rank <= cfg.Boss.TopExtraRolls {
				rolls = 2
			}
			for n := 0; n < rolls; n++ {
				d := roll(drops, boss, p.user, n)
				it := RewardItem{Item: d.Item, Kind: d.Kind, Name: itemName(cfg, d.Kind, d.Item)}
				switch d.Kind {
				case "energy":
					energy += cfg.Boss.DropEnergy
				case "role", "blueprint", "egg":
					codexKind := d.Kind
					var tag int64
					q := `INSERT INTO src.src_ply_codex_item (user_id, item_type, item) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`
					if d.Kind == "egg" { // an egg is a duplicate if the companion already exists in any state
						q = `INSERT INTO src.src_ply_codex_item (user_id, item_type, item) SELECT $1,$2,$3
							WHERE NOT EXISTS (SELECT 1 FROM src.src_ply_codex_item WHERE user_id=$1 AND item_type IN ('egg','companion') AND item=$3)`
					}
					ct, err := tx.Exec(ctx, q, p.user, codexKind, d.Item)
					if err != nil {
						return err
					}
					tag = ct.RowsAffected()
					if tag == 0 {
						c := duplicateEnergy
						it.ConvertedEnergy = &c
						energy += c
					}
				}
				items = append(items, it)
			}
			if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_user_monster (user_id, boss_type, defeats, best_rank) VALUES ($1,$2,1,$3)
				ON CONFLICT (user_id, boss_type) DO UPDATE SET defeats = src.src_ply_user_monster.defeats + 1,
				  best_rank = LEAST(COALESCE(src.src_ply_user_monster.best_rank, $3), $3)`, p.user, kind, rank); err != nil {
				return err
			}
			if err := codex.IncStat(ctx, tx, p.user, codex.StatBossDefeats, 1); err != nil {
				return err
			}
		} else if !defeated {
			energy = int(math.Floor(float64(p.spent) * cfg.Boss.ExpireRefundPct / 100))
		}
		itemsRaw, _ := json.Marshal(items)
		tag, err := tx.Exec(ctx, `INSERT INTO src.src_ply_boss_reward (boss_id, user_id, rank, damage, items_json, energy) VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING`,
			boss, p.user, rank, p.damage, itemsRaw, energy)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			continue
		}
		if err := grant(ctx, tx, p.user, energy, "boss_reward", boss); err != nil {
			return err
		}
		if defeated {
			if _, err := codex.AwardMedals(ctx, tx, cfg, p.user); err != nil {
				return err
			}
			names := ""
			for j, it := range items {
				if j > 0 {
					names += "、"
				}
				names += it.Name
			}
			if err := inbox.Notify(ctx, tx, p.user, inbox.Monster, "击退成功！", fmt.Sprintf("%s被击退了，你排第 %d 名，获得：%s。", name, rank, names),
				map[string]any{"boss_id": boss}); err != nil {
				return err
			}
		} else if err := inbox.Notify(ctx, tx, p.user, inbox.Monster, "怪兽离开了", fmt.Sprintf("%s没有被击退就离开了，返还你 %d 能量。", name, energy),
			map[string]any{"boss_id": boss}); err != nil {
			return err
		}
	}
	return nil
}

// Expire ends monsters past their time (or early, by admin).
func (s *Service) Expire(ctx context.Context, only int64) error {
	rows, err := s.Pool.Query(ctx, `SELECT id FROM src.src_ply_boss WHERE status='active' AND (expire_time <= now() OR id=$1)`, only)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	cfg := s.Config.For(0)
	for _, id := range ids {
		err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
			tag, err := tx.Exec(ctx, `UPDATE src.src_ply_boss SET status='expired', end_time=now() WHERE id=$1 AND status='active'`, id)
			if err != nil || tag.RowsAffected() == 0 {
				return err
			}
			return s.finish(ctx, tx, cfg, id, false)
		})
		if err != nil {
			return err
		}
		s.Hub.Publish(ctx, realtime.NewEvent(fmt.Sprintf("boss:%d", id), nil, map[string]any{"type": "boss", "boss": map[string]any{"id": id, "status": "expired"}}))
	}
	return nil
}

// Engage marks the user as fighting a monster (for indoor activities).
func (s *Service) Engage(ctx context.Context, user, id int64, lat, lng float64) (time.Time, error) {
	cfg := s.Config.For(user)
	var status string
	if err := s.Pool.QueryRow(ctx, `SELECT status FROM src.src_ply_boss WHERE id=$1`, id).Scan(&status); err != nil {
		if db.IsNoRows(err) {
			return time.Time{}, httpx.NotFound("怪兽")
		}
		return time.Time{}, err
	}
	if status != "active" {
		return time.Time{}, errBossNotActive
	}
	ok, err := inRange(ctx, s.Pool, "src.src_ply_boss", id, lat, lng)
	if err != nil {
		return time.Time{}, err
	}
	if !ok {
		return time.Time{}, errOutOfRange
	}
	var until time.Time
	err = s.Pool.QueryRow(ctx, `INSERT INTO src.src_ply_boss_engage (boss_id, user_id, engage_end_time) VALUES ($1,$2, now() + make_interval(secs => $3))
		ON CONFLICT (boss_id, user_id) DO UPDATE SET engage_end_time=EXCLUDED.engage_end_time RETURNING engage_end_time`, id, user, cfg.Boss.EngageH*3600).Scan(&until)
	return until, err
}

// bossActivity deals activity damage: GPS by distance inside each active
// monster's range, indoor training to engaged monsters.
func (s *Service) bossActivity(ctx context.Context, tx pgx.Tx, in activity.HookInput, track *string) ([]activity.BossHit, []realtime.Event, error) {
	out := []activity.BossHit{}
	var events []realtime.Event
	type target struct {
		id     int64
		amount float64
	}
	var targets []target
	if gameplay.GPSSports[in.Sport] {
		if track == nil {
			return out, nil, nil
		}
		rows, err := tx.Query(ctx, `SELECT id, ST_Length(ST_Intersection(ST_GeomFromText($1,4326)::geography,
				ST_Buffer(center_geom::geography, radius_m)))
			FROM src.src_ply_boss WHERE status='active' AND ST_DWithin(center_geom::geography, ST_GeomFromText($1,4326)::geography, radius_m)
			ORDER BY id`, *track)
		if err != nil {
			return out, nil, err
		}
		for rows.Next() {
			var t target
			var meters float64
			if err := rows.Scan(&t.id, &meters); err != nil {
				rows.Close()
				return out, nil, err
			}
			t.amount = meters / 1000
			targets = append(targets, t)
		}
		rows.Close()
	} else {
		rows, err := tx.Query(ctx, `SELECT e.boss_id FROM src.src_ply_boss_engage e JOIN src.src_ply_boss b ON b.id=e.boss_id
			WHERE e.user_id=$1 AND e.engage_end_time > $2 AND b.status='active' ORDER BY e.boss_id`, in.UserID, in.StartedAt)
		if err != nil {
			return out, nil, err
		}
		ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
		if err != nil {
			return out, nil, err
		}
		for _, id := range ids {
			targets = append(targets, target{id: id, amount: in.Amount})
		}
	}
	aid := in.ActivityID
	for _, t := range targets {
		dmg := in.Config.BossDamageFor(in.Sport, t.amount)
		h, evs, err := s.hit(ctx, tx, in.Config, t.id, in.UserID, in.CrewID, "activity", &aid, dmg, 0)
		if err != nil {
			return out, nil, err
		}
		if h.Damage > 0 {
			out = append(out, h)
			events = append(events, evs...)
		}
	}
	return out, events, nil
}

// List returns monsters for admin.
func (s *Service) List(ctx context.Context, status string, p httpx.Page) ([]BossSummary, int, error) {
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_ply_boss WHERE ($1='' OR status=$1)`, status).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT `+bossCols+` FROM src.src_ply_boss b WHERE ($1='' OR b.status=$1) ORDER BY b.spawn_time DESC LIMIT $2 OFFSET $3`,
		status, p.Size, p.Offset())
	if err != nil {
		return nil, 0, err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (BossSummary, error) { return scanBoss(r) })
	return items, total, err
}
