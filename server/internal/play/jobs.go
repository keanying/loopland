package play

import (
	"context"
	"math/rand/v2"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/territory"
)

func strconvItoa(n int64) string { return strconv.FormatInt(n, 10) }

// Night is 23:00–05:00 Shanghai: no automatic monsters or chests then
// (深夜不刷宝箱和怪兽).
func Night(t time.Time) bool {
	h := t.In(clock.Shanghai).Hour()
	return h >= 23 || h < 5
}

// PlaceChest puts one chest on the map.
func (s *Service) PlaceChest(ctx context.Context, lat, lng float64, emin, emax int, durationH, radiusM float64, source string, by int64) (int64, error) {
	cfg := s.Config.For(0).Chest
	if emin <= 0 {
		emin = cfg.EnergyMin
	}
	if emax < emin {
		emax = max(emin, cfg.EnergyMax)
	}
	if durationH <= 0 {
		durationH = cfg.DurationH
	}
	if radiusM <= 0 {
		radiusM = cfg.RadiusM
	}
	if lat < -90 || lat > 90 || lng < -180 || lng > 180 || (lat == 0 && lng == 0) {
		return 0, httpx.BadRequest("invalid_point", "位置不合法")
	}
	var placedBy *int64
	if by > 0 {
		placedBy = &by
	}
	var id int64
	err := s.Pool.QueryRow(ctx, `INSERT INTO src.src_ply_loop_chest (center_geom, radius_m, energy_min, energy_max, source, placed_by, expire_time)
		VALUES (ST_SetSRID(ST_MakePoint($1,$2),4326), $3, $4, $5, $6, $7, now() + make_interval(secs => $8)) RETURNING id`,
		lng, lat, radiusM, emin, emax, source, placedBy, durationH*3600).Scan(&id)
	return id, err
}

// Scatter drops chests on points runners actually pass (recent tracks),
// optionally limited to a bbox. Returns how many were placed.
func (s *Service) Scatter(ctx context.Context, b *territory.BBox, count int, durationH float64, source string, by int64) (int, error) {
	where, args := `TRUE`, []any{count}
	if b != nil {
		where = `track_geom && ST_MakeEnvelope($2,$3,$4,$5,4326)`
		args = append(args, b[0], b[1], b[2], b[3])
	}
	rows, err := s.Pool.Query(ctx, `SELECT ST_Y(p), ST_X(p) FROM (
		  SELECT ST_LineInterpolatePoint(track_geom, random()) AS p FROM src.src_act_loop_activity
		  WHERE status='settled' AND track_geom IS NOT NULL AND create_time > now() - interval '30 days' AND `+where+`
		  ORDER BY random() LIMIT $1) x`, args...)
	if err != nil {
		return 0, err
	}
	type pt struct{ lat, lng float64 }
	pts, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (pt, error) {
		var p pt
		return p, r.Scan(&p.lat, &p.lng)
	})
	if err != nil {
		return 0, err
	}
	n := 0
	for _, p := range pts {
		if b != nil && (p.lng < b[0] || p.lng > b[2] || p.lat < b[1] || p.lat > b[3]) {
			continue
		}
		if _, err := s.PlaceChest(ctx, p.lat, p.lng, 0, 0, durationH, 0, source, by); err != nil {
			return n, err
		}
		n++
	}
	return n, nil
}

// AutoSpawn keeps up to auto_spawn_max monsters around where people ran in
// the last 24 hours, never at night and never on top of another monster.
func (s *Service) AutoSpawn(ctx context.Context, now time.Time) error {
	if Night(now) {
		return nil
	}
	cfg := s.Config.For(0)
	var active int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_ply_loop_boss WHERE status='active'`).Scan(&active); err != nil {
		return err
	}
	if active >= cfg.Boss.AutoSpawnMax || len(cfg.Bosses) == 0 {
		return nil
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT ST_Y(c), ST_X(c), n FROM (
		  SELECT ST_Centroid(ST_Collect(ST_StartPoint(track_geom))) AS c, count(*) AS n
		  FROM src.src_act_loop_activity WHERE status='settled' AND track_geom IS NOT NULL AND create_time > now() - interval '24 hours'
		  GROUP BY ST_SnapToGrid(ST_StartPoint(track_geom), 0.02)) g
		WHERE NOT EXISTS (SELECT 1 FROM src.src_ply_loop_boss b WHERE b.status='active' AND ST_DWithin(b.center_geom::geography, g.c::geography, 3000))
		ORDER BY n DESC LIMIT $1`, cfg.Boss.AutoSpawnMax-active)
	if err != nil {
		return err
	}
	type spot struct {
		lat, lng float64
		n        int
	}
	spots, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (spot, error) {
		var x spot
		return x, r.Scan(&x.lat, &x.lng, &x.n)
	})
	if err != nil {
		return err
	}
	for _, sp := range spots {
		kind := cfg.Bosses[rand.IntN(len(cfg.Bosses))].Key
		// More runners nearby → more HP, between 0.5× and 3× the default.
		hp := int(float64(cfg.Boss.DefaultHP) * min(3, max(0.5, float64(sp.n)/10)))
		if _, err := s.Spawn(ctx, SpawnInput{Kind: kind, Lat: sp.lat, Lng: sp.lng, HP: hp}, 0); err != nil {
			return err
		}
	}
	return nil
}

// DailyChests scatters the day's chests once, after 06:00.
func (s *Service) DailyChests(ctx context.Context, now time.Time) error {
	if now.In(clock.Shanghai).Hour() < 6 || Night(now) {
		return nil
	}
	tag, err := s.Pool.Exec(ctx, `INSERT INTO src.src_sys_loop_setting (setting_key, setting_value) VALUES ('chests_day', to_jsonb($1::text))
		ON CONFLICT (setting_key) DO UPDATE SET setting_value=EXCLUDED.setting_value, update_time=now() WHERE src_sys_loop_setting.setting_value <> to_jsonb($1::text)`,
		clock.Day(now).Format("2006-01-02"))
	if err != nil || tag.RowsAffected() == 0 {
		return err
	}
	_, err = s.Scatter(ctx, nil, s.Config.For(0).Chest.DailySpawn, 0, "system", 0)
	return err
}

// ExpireRelays closes relays past their deadline.
func (s *Service) ExpireRelays(ctx context.Context) error {
	_, err := s.Pool.Exec(ctx, `UPDATE src.src_soc_loop_relay SET status='expired' WHERE status='running' AND expire_time <= now()`)
	return err
}

// Jobs returns the periodic jobs for the job runner.
func (s *Service) Jobs() map[string]func(context.Context) error {
	return map[string]func(context.Context) error{
		"boss_expire":   func(ctx context.Context) error { return s.Expire(ctx, 0) },
		"boss_spawn":    func(ctx context.Context) error { return s.AutoSpawn(ctx, time.Now()) },
		"chests_daily":  func(ctx context.Context) error { return s.DailyChests(ctx, time.Now()) },
		"season_settle": func(ctx context.Context) error { return s.SettleSeasons(ctx, 0) },
		"league_settle": s.SettleLeague,
		"relay_expire":  s.ExpireRelays,
		"defense_expire": func(ctx context.Context) error {
			_, err := s.Pool.Exec(ctx, `DELETE FROM src.src_ter_loop_defense WHERE deadline_time <= now()`)
			return err
		},
	}
}
