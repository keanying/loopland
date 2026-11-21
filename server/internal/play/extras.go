package play

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/activity"
	"github.com/keanying/loopland/server/internal/codex"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/territory"
)

// ---------------------------------------------------------------- chests

// chestReward is deterministic per (chest, user) so retries agree.
func chestReward(cfg gameplay.Config, chest, user int64, min, max int, alchemistPct float64) (int, bool) {
	h := sha256.Sum256([]byte(fmt.Sprintf("loopland-chest:%d:%d", chest, user)))
	span := max - min + 1
	e := min + int(binary.BigEndian.Uint32(h[:4])%uint32(span))
	bonus := float64(binary.BigEndian.Uint32(h[4:8])%10000)/100 < alchemistPct
	if bonus {
		e *= 2
	}
	return e, bonus
}

func chestBuff(ctx context.Context, q db.Querier, cfg gameplay.Config, user int64) float64 {
	var pct float64
	for _, r := range cfg.Roles {
		if r.Buff != gameplay.BuffChestDropPct {
			continue
		}
		var owned bool
		if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_ply_loop_codex_item WHERE user_id=$1 AND item_type='role' AND item=$2)`, user, r.Key).Scan(&owned); err == nil && owned {
			pct += r.BuffValue
		}
	}
	return pct
}

// openChest opens a chest. A merchant chest (drop_id set, 第四批) holds a
// coupon instead of energy; the coupon (nil otherwise) is returned.
func (s *Service) openChest(ctx context.Context, tx pgx.Tx, cfg gameplay.Config, chest, user int64, activityID *int64) (int, bool, any, error) {
	var lo, hi int
	var dropID *int64
	if err := tx.QueryRow(ctx, `SELECT energy_min, energy_max, drop_id FROM src.src_ply_loop_chest WHERE id=$1 FOR UPDATE`, chest).Scan(&lo, &hi, &dropID); err != nil {
		return 0, false, nil, err
	}
	if dropID != nil && s.Perks != nil {
		tag, err := tx.Exec(ctx, `INSERT INTO src.src_ply_loop_chest_open (chest_id, user_id, energy, is_bonus, activity_id) VALUES ($1,$2,0,false,$3) ON CONFLICT DO NOTHING`,
			chest, user, activityID)
		if err != nil {
			return 0, false, nil, err
		}
		if tag.RowsAffected() == 0 {
			return 0, false, nil, httpx.Conflict("already_opened", "这个宝箱你已经开过了")
		}
		coupon, err := s.Perks.ChestCoupon(ctx, tx, chest, *dropID, user, activityID)
		if err != nil {
			return 0, false, nil, err
		}
		return 0, false, coupon, codex.IncStat(ctx, tx, user, codex.StatChests, 1)
	}
	energy, bonus := chestReward(cfg, chest, user, lo, hi, chestBuff(ctx, tx, cfg, user))
	tag, err := tx.Exec(ctx, `INSERT INTO src.src_ply_loop_chest_open (chest_id, user_id, energy, is_bonus, activity_id) VALUES ($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING`,
		chest, user, energy, bonus, activityID)
	if err != nil {
		return 0, false, nil, err
	}
	if tag.RowsAffected() == 0 {
		return 0, false, nil, httpx.Conflict("already_opened", "这个宝箱你已经开过了")
	}
	if err := grant(ctx, tx, user, energy, "chest", chest); err != nil {
		return 0, false, nil, err
	}
	return energy, bonus, nil, codex.IncStat(ctx, tx, user, codex.StatChests, 1)
}

// OpenChest opens a chest the user stands next to. coupon is set for a
// merchant chest.
func (s *Service) OpenChest(ctx context.Context, user, id int64, lat, lng float64) (energy int, bonus bool, coupon any, err error) {
	var expired bool
	err = s.Pool.QueryRow(ctx, `SELECT expire_time <= now() OR remove_time IS NOT NULL FROM src.src_ply_loop_chest WHERE id=$1`, id).Scan(&expired)
	if db.IsNoRows(err) {
		return 0, false, nil, httpx.NotFound("宝箱")
	}
	if err != nil {
		return 0, false, nil, err
	}
	if expired {
		return 0, false, nil, httpx.Conflict("chest_expired", "宝箱已经消失了")
	}
	ok, err := inRange(ctx, s.Pool, "src.src_ply_loop_chest", id, lat, lng)
	if err != nil {
		return 0, false, nil, err
	}
	if !ok {
		return 0, false, nil, errOutOfRange
	}
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var err error
		energy, bonus, coupon, err = s.openChest(ctx, tx, s.Config.For(user), id, user, nil)
		if err != nil {
			return err
		}
		_, err = codex.AwardMedals(ctx, tx, s.Config.For(user), user)
		return err
	})
	return energy, bonus, coupon, err
}

func (s *Service) chestsOnTrack(ctx context.Context, tx pgx.Tx, in activity.HookInput, track *string) ([]activity.ChestOpen, []any, error) {
	out, coupons := []activity.ChestOpen{}, []any{}
	if track == nil {
		return out, coupons, nil
	}
	rows, err := tx.Query(ctx, `SELECT c.id FROM src.src_ply_loop_chest c
		WHERE c.expire_time > now() AND c.remove_time IS NULL AND c.create_time <= $3
		  AND ST_DWithin(c.center_geom::geography, ST_GeomFromText($1,4326)::geography, c.radius_m)
		  AND NOT EXISTS (SELECT 1 FROM src.src_ply_loop_chest_open o WHERE o.chest_id=c.id AND o.user_id=$2)
		ORDER BY c.id`, *track, in.UserID, time.Now())
	if err != nil {
		return out, coupons, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return out, coupons, err
	}
	aid := in.ActivityID
	for _, id := range ids {
		e, _, coupon, err := s.openChest(ctx, tx, in.Config, id, in.UserID, &aid)
		if err != nil && s.Perks != nil && s.Perks.SoftError(err) {
			// A merchant chest with nothing for this user today: leave it
			// unopened rather than record an empty open.
			if _, err := tx.Exec(ctx, `DELETE FROM src.src_ply_loop_chest_open WHERE chest_id=$1 AND user_id=$2`, id, in.UserID); err != nil {
				return out, coupons, err
			}
			continue
		}
		if err != nil {
			return out, coupons, err
		}
		out = append(out, activity.ChestOpen{ChestID: id, Energy: e})
		if coupon != nil {
			coupons = append(coupons, coupon)
		}
	}
	return out, coupons, nil
}

// ---------------------------------------------------------------- defense

func (s *Service) defend(ctx context.Context, tx pgx.Tx, in activity.HookInput, track *string) ([]activity.Defended, error) {
	out := []activity.Defended{}
	if track == nil {
		return out, nil
	}
	rows, err := tx.Query(ctx, `SELECT t.id FROM src.src_ter_loop_defense d JOIN src.src_ter_loop_territory t ON t.id=d.territory_id
		WHERE t.owner_user_id=$1 AND d.deadline_time > now() AND ST_Intersects(t.area_geom, ST_GeomFromText($2,4326)) ORDER BY t.id`,
		in.UserID, *track)
	if err != nil {
		return out, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return out, err
	}
	for _, id := range ids {
		before, after, err := territory.Reinforce(ctx, tx, id, in.UserID, in.ActivityID, in.EnergyRaw, in.Config.Defense.MaxGuard)
		if err != nil {
			return out, err
		}
		out = append(out, activity.Defended{TerritoryID: id, GuardBefore: before, GuardAfter: after})
		if err := codex.IncStat(ctx, tx, in.UserID, codex.StatDefends, 1); err != nil {
			return out, err
		}
	}
	return out, nil
}

func codexMaxLoops(ctx context.Context, tx pgx.Tx, user int64, n int) error {
	return codex.MaxStat(ctx, tx, user, codex.StatLoopsSingle, float64(n))
}

// ---------------------------------------------------------------- routes

// Checkpoint is one orienteering point.
type Checkpoint struct {
	Name    string  `json:"name"`
	Lat     float64 `json:"lat"`
	Lng     float64 `json:"lng"`
	RadiusM float64 `json:"radius_m"`
}

func (s *Service) routeProgress(ctx context.Context, tx pgx.Tx, in activity.HookInput) ([]activity.RouteStep, error) {
	out := []activity.RouteStep{}
	if len(in.Points) == 0 {
		return out, nil
	}
	rows, err := tx.Query(ctx, `SELECT r.id, r.name, r.checkpoints_json, r.reward_energy, COALESCE(p.next_index, 0)
		FROM src.src_ply_loop_route r LEFT JOIN src.src_ply_loop_route_progress p ON p.route_id=r.id AND p.user_id=$1
		WHERE r.start_time <= now() AND r.end_time > now() AND (p.complete_time IS NULL)`, in.UserID)
	if err != nil {
		return out, err
	}
	type rt struct {
		id     int64
		name   string
		cps    []Checkpoint
		reward int
		next   int
	}
	var rts []rt
	for rows.Next() {
		var r rt
		var raw []byte
		if err := rows.Scan(&r.id, &r.name, &raw, &r.reward, &r.next); err != nil {
			rows.Close()
			return out, err
		}
		_ = json.Unmarshal(raw, &r.cps)
		rts = append(rts, r)
	}
	rows.Close()
	for _, r := range rts {
		next := r.next
		var reached []string
		for _, p := range in.Points {
			if next >= len(r.cps) {
				break
			}
			cp := r.cps[next]
			if geo.Haversine(p, geo.LatLng{Lat: cp.Lat, Lng: cp.Lng}) <= cp.RadiusM {
				reached = append(reached, cp.Name)
				next++
			}
		}
		if len(reached) == 0 {
			continue
		}
		done := next >= len(r.cps)
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_loop_route_progress (route_id, user_id, next_index, complete_time) VALUES ($1,$2,$3, CASE WHEN $4 THEN now() END)
			ON CONFLICT (route_id, user_id) DO UPDATE SET next_index=EXCLUDED.next_index, complete_time=EXCLUDED.complete_time`,
			r.id, in.UserID, next, done); err != nil {
			return out, err
		}
		if done {
			if err := grant(ctx, tx, in.UserID, r.reward, "route", r.id); err != nil {
				return out, err
			}
			if err := codex.IncStat(ctx, tx, in.UserID, codex.StatRoutes, 1); err != nil {
				return out, err
			}
			if err := inbox.Notify(ctx, tx, in.UserID, inbox.System, "城市定向完成", fmt.Sprintf("你跑完了「%s」全部打卡点，获得 %d 能量。", r.name, r.reward),
				map[string]any{"route_id": r.id}); err != nil {
				return out, err
			}
		}
		out = append(out, activity.RouteStep{RouteID: r.id, Name: r.name, Reached: reached, Completed: done})
	}
	return out, nil
}

// ---------------------------------------------------------------- campaigns

// CampaignRules are the type-specific conditions.
type CampaignRules struct {
	MinDistanceKm float64 `json:"min_distance_km,omitempty"`
	MaxPaceSPerKm int     `json:"max_pace_s_per_km,omitempty"`
	StartHourFrom *int    `json:"start_hour_from,omitempty"`
	StartHourTo   *int    `json:"start_hour_to,omitempty"`
}

// CampaignMet reports whether an activity satisfies a campaign.
func CampaignMet(typ string, r CampaignRules, sport gameplay.Sport, distanceM float64, durationS int, startedAt time.Time) bool {
	if !gameplay.GPSSports[sport] || distanceM/1000 < r.MinDistanceKm {
		return false
	}
	switch typ {
	case "pace":
		if distanceM <= 0 || r.MaxPaceSPerKm <= 0 {
			return false
		}
		return float64(durationS)/(distanceM/1000) <= float64(r.MaxPaceSPerKm)
	case "night_run":
		h := startedAt.In(clock.Shanghai).Hour()
		from, to := 19, 23
		if r.StartHourFrom != nil {
			from = *r.StartHourFrom
		}
		if r.StartHourTo != nil {
			to = *r.StartHourTo
		}
		return h >= from && h < to
	case "distance":
		return true
	}
	return false
}

func (s *Service) campaigns(ctx context.Context, tx pgx.Tx, in activity.HookInput) ([]activity.CampaignDone, error) {
	out := []activity.CampaignDone{}
	rows, err := tx.Query(ctx, `SELECT c.id, c.title, c.campaign_type, c.rules_json, c.reward_energy, c.reward_medal_name FROM src.src_mkt_loop_campaign c
		WHERE c.start_time <= $2 AND c.end_time > $2
		  AND NOT EXISTS (SELECT 1 FROM src.src_mkt_loop_campaign_done x WHERE x.campaign_id=c.id AND x.user_id=$1)`, in.UserID, in.StartedAt)
	if err != nil {
		return out, err
	}
	type camp struct {
		id     int64
		title  string
		typ    string
		rules  CampaignRules
		reward int
		medal  *string
	}
	var cs []camp
	for rows.Next() {
		var c camp
		var raw []byte
		if err := rows.Scan(&c.id, &c.title, &c.typ, &raw, &c.reward, &c.medal); err != nil {
			rows.Close()
			return out, err
		}
		_ = json.Unmarshal(raw, &c.rules)
		cs = append(cs, c)
	}
	rows.Close()
	for _, c := range cs {
		if !CampaignMet(c.typ, c.rules, in.Sport, in.DistanceM, in.DurationS, in.StartedAt) {
			continue
		}
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_mkt_loop_campaign_done (campaign_id, user_id, activity_id) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`,
			c.id, in.UserID, in.ActivityID); err != nil {
			return out, err
		}
		if err := grant(ctx, tx, in.UserID, c.reward, "campaign", c.id); err != nil {
			return out, err
		}
		if c.medal != nil && *c.medal != "" {
			if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_loop_codex_item (user_id, item_type, item) VALUES ($1,'medal',$2) ON CONFLICT DO NOTHING`,
				in.UserID, "campaign:"+*c.medal); err != nil {
				return out, err
			}
		}
		if err := inbox.Notify(ctx, tx, in.UserID, inbox.System, "活动完成", fmt.Sprintf("你完成了「%s」，获得 %d 能量。", c.title, c.reward),
			map[string]any{"campaign_id": c.id}); err != nil {
			return out, err
		}
		out = append(out, activity.CampaignDone{CampaignID: c.id, Title: c.title, RewardEnergy: c.reward})
	}
	return out, nil
}

// ---------------------------------------------------------------- companion

func (s *Service) companionGrowth(ctx context.Context, tx pgx.Tx, in activity.HookInput) (*activity.CompanionGain, error) {
	if !gameplay.GPSSports[in.Sport] || in.DistanceM <= 0 {
		return nil, nil
	}
	var key *string
	if err := tx.QueryRow(ctx, `SELECT escort_companion_key FROM src.src_usr_loop_user WHERE id=$1`, in.UserID).Scan(&key); err != nil || key == nil {
		return nil, err
	}
	var exp int
	var meters float64
	err := tx.QueryRow(ctx, `SELECT exp, meters FROM src.src_ply_loop_companion_growth WHERE user_id=$1 AND companion=$2`, in.UserID, *key).Scan(&exp, &meters)
	if err != nil && !db.IsNoRows(err) {
		return nil, err
	}
	gain := (int(meters+in.DistanceM)/100 - int(meters)/100) * in.Config.Pet.ExpPer100m
	newExp := exp + gain
	if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_loop_companion_growth (user_id, companion, exp, meters) VALUES ($1,$2,$3,$4)
		ON CONFLICT (user_id, companion) DO UPDATE SET exp=EXCLUDED.exp, meters=EXCLUDED.meters`, in.UserID, *key, newExp, meters+in.DistanceM); err != nil {
		return nil, err
	}
	before, after := in.Config.CompanionLevel(exp), in.Config.CompanionLevel(newExp)
	return &activity.CompanionGain{Key: *key, Exp: newExp, Level: after, LevelUp: after > before}, nil
}

// Feed spends energy on a hatched companion's experience.
func (s *Service) Feed(ctx context.Context, user int64, key string) error {
	cfg := s.Config.For(user)
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var hatched bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_ply_loop_codex_item WHERE user_id=$1 AND item_type='companion' AND item=$2)`, user, key).Scan(&hatched); err != nil {
			return err
		}
		if !hatched {
			return httpx.Forbidden("companion_not_hatched", "这个伙伴还没有孵化")
		}
		if _, err := spend(ctx, tx, user, cfg.Pet.FeedCost, "companion_feed", 0); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO src.src_ply_loop_companion_growth (user_id, companion, exp) VALUES ($1,$2,$3)
			ON CONFLICT (user_id, companion) DO UPDATE SET exp = src.src_ply_loop_companion_growth.exp + EXCLUDED.exp`, user, key, cfg.Pet.FeedExp)
		return err
	})
}

// ---------------------------------------------------------------- relay

// Relay is a crew relay.
type Relay struct {
	ID        int64      `json:"id"`
	Legs      int        `json:"legs"`
	LegKm     float64    `json:"leg_km"`
	Status    string     `json:"status"`
	StartedAt time.Time  `json:"started_at"`
	ExpiresAt time.Time  `json:"expires_at"`
	Runs      []RelayRun `json:"runs"`
}

// RelayRun is one leg.
type RelayRun struct {
	Leg        int       `json:"leg"`
	User       UserRef   `json:"user"`
	ActivityID *int64    `json:"activity_id"`
	DistanceM  float64   `json:"distance_m"`
	At         time.Time `json:"at"`
}

// StartRelay starts a crew relay (leader only).
func (s *Service) StartRelay(ctx context.Context, user, crew int64, legs int, legKm float64) (Relay, error) {
	cfg := s.Config.For(user)
	if legs == 0 {
		legs = cfg.Relay.DefaultLegs
	}
	if legKm == 0 {
		legKm = cfg.Relay.LegKm
	}
	if legs < 2 || legs > 20 || legKm <= 0 || legKm > 50 {
		return Relay{}, httpx.BadRequest("invalid_body", "接力 2–20 棒，单棒 0–50 km")
	}
	var leader int64
	err := s.Pool.QueryRow(ctx, `SELECT leader_id FROM src.src_soc_loop_crew WHERE id=$1`, crew).Scan(&leader)
	if db.IsNoRows(err) {
		return Relay{}, httpx.NotFound("跑团")
	}
	if err != nil {
		return Relay{}, err
	}
	if leader != user {
		return Relay{}, httpx.Forbidden("not_leader", "只有团长可以发起接力")
	}
	_, err = s.Pool.Exec(ctx, `INSERT INTO src.src_soc_loop_relay (crew_id, legs, leg_km, started_by, expire_time) VALUES ($1,$2,$3,$4, now() + make_interval(secs => $5))`,
		crew, legs, legKm, user, cfg.Relay.DurationH*3600)
	if db.IsUniqueViolation(err) {
		return Relay{}, httpx.Conflict("relay_running", "已经有一场接力在进行中")
	}
	if err != nil {
		return Relay{}, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT user_id FROM src.src_soc_loop_crew_member WHERE crew_id=$1 AND user_id<>$2`, crew, user)
	if err == nil {
		if mates, err := pgx.CollectRows(rows, pgx.RowTo[int64]); err == nil {
			for _, m := range mates {
				_ = inbox.Notify(ctx, s.Pool, m, inbox.Interaction, "跑团接力开始了", fmt.Sprintf("团长发起了 %d 棒接力，每棒 %.1f km，去跑一棒吧！", legs, legKm), map[string]any{"crew_id": crew})
			}
		}
	}
	r, err := s.CurrentRelay(ctx, crew)
	if err != nil || r == nil {
		return Relay{}, err
	}
	return *r, nil
}

// CurrentRelay returns the running (or most recent) relay.
func (s *Service) CurrentRelay(ctx context.Context, crew int64) (*Relay, error) {
	var r Relay
	err := s.Pool.QueryRow(ctx, `SELECT id, legs, leg_km, status, start_time, expire_time FROM src.src_soc_loop_relay WHERE crew_id=$1
		ORDER BY (status='running') DESC, id DESC LIMIT 1`, crew).Scan(&r.ID, &r.Legs, &r.LegKm, &r.Status, &r.StartedAt, &r.ExpiresAt)
	if db.IsNoRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT x.leg, u.id, u.nickname, u.avatar_url, x.activity_id, x.distance_m, x.run_time FROM src.src_soc_loop_relay_run x
		JOIN src.src_usr_loop_user u ON u.id=x.user_id WHERE x.relay_id=$1 ORDER BY x.leg`, r.ID)
	if err != nil {
		return nil, err
	}
	r.Runs, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (RelayRun, error) {
		var x RelayRun
		return x, row.Scan(&x.Leg, &x.User.ID, &x.User.Nickname, &x.User.AvatarURL, &x.ActivityID, &x.DistanceM, &x.At)
	})
	if r.Runs == nil {
		r.Runs = []RelayRun{}
	}
	return &r, err
}

func (s *Service) relayLeg(ctx context.Context, tx pgx.Tx, in activity.HookInput) (*activity.RelayLeg, error) {
	if in.CrewID == nil || !gameplay.GPSSports[in.Sport] {
		return nil, nil
	}
	var id int64
	var legs int
	var legKm float64
	err := tx.QueryRow(ctx, `SELECT id, legs, leg_km FROM src.src_soc_loop_relay WHERE crew_id=$1 AND status='running' AND expire_time > now() FOR UPDATE`, *in.CrewID).
		Scan(&id, &legs, &legKm)
	if db.IsNoRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if in.DistanceM/1000 < legKm {
		return nil, nil
	}
	var done int
	var mine bool
	if err := tx.QueryRow(ctx, `SELECT count(*), COALESCE(bool_or(user_id=$2), false) FROM src.src_soc_loop_relay_run WHERE relay_id=$1`, id, in.UserID).Scan(&done, &mine); err != nil {
		return nil, err
	}
	if mine || done >= legs {
		return nil, nil
	}
	leg := done + 1
	if _, err := tx.Exec(ctx, `INSERT INTO src.src_soc_loop_relay_run (relay_id, leg, user_id, activity_id, distance_m) VALUES ($1,$2,$3,$4,$5)`,
		id, leg, in.UserID, in.ActivityID, in.DistanceM); err != nil {
		return nil, err
	}
	out := &activity.RelayLeg{RelayID: id, Leg: leg, Legs: legs}
	if leg == legs {
		out.Completed = true
		if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_relay SET status='completed', complete_time=now() WHERE id=$1`, id); err != nil {
			return nil, err
		}
		rows, err := tx.Query(ctx, `SELECT user_id FROM src.src_soc_loop_relay_run WHERE relay_id=$1`, id)
		if err != nil {
			return nil, err
		}
		runners, err := pgx.CollectRows(rows, pgx.RowTo[int64])
		if err != nil {
			return nil, err
		}
		for _, u := range runners {
			if err := grant(ctx, tx, u, in.Config.Relay.RewardEnergy, "relay", id); err != nil {
				return nil, err
			}
			if err := inbox.Notify(ctx, tx, u, inbox.Interaction, "接力完成！", fmt.Sprintf("跑团 %d 棒接力全部跑完，每人获得 %d 能量。", legs, in.Config.Relay.RewardEnergy),
				map[string]any{"relay_id": id}); err != nil {
				return nil, err
			}
		}
	}
	return out, nil
}
