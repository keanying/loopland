// Package play is V2 batch 1 「玩法深化」: city monsters, chests, territory
// defense, seasons and tasks, district league, limited campaigns,
// orienteering routes, companion growth and crew relays
// (docs/api/v2-1-玩法.md).
package play

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/keanying/loopland/server/internal/activity"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/realtime"
	"github.com/keanying/loopland/server/internal/territory"
)

// Service implements the gameplay hook, the app and admin endpoints and the
// background jobs.
type Service struct {
	Pool   *pgxpool.Pool
	Redis  *redis.Client
	Config *gameplay.Store
	Hub    *realtime.Hub
	Log    *slog.Logger
	// Perks is optional 第四批联名权益 (internal/perks): supply stations on
	// the map and along the track, merchant chests whose reward is a coupon.
	Perks Perks
}

// Perks issues merchant coupons during gameplay. Coupons are opaque JSON
// objects here.
type Perks interface {
	// Supplies lists the supply stations in the viewport (a JSON array).
	Supplies(ctx context.Context, b territory.BBox, user int64) (any, error)
	// SuppliesOnTrack issues the coupons of supply stations the track passed.
	SuppliesOnTrack(ctx context.Context, tx pgx.Tx, in activity.HookInput, track *string) ([]any, error)
	// ChestCoupon issues the coupon of a merchant chest.
	ChestCoupon(ctx context.Context, tx pgx.Tx, chestID, dropID, user int64, activityID *int64) (any, error)
	// SoftError reports a ChestCoupon error that only means "no coupon this
	// time" (sold out, already got one today, drop paused).
	SoftError(err error) bool
}

// grant adds reward energy (not counted against the daily activity cap).
func grant(ctx context.Context, q db.Querier, user int64, energy int, reason string, ref int64) error {
	if energy == 0 {
		return nil
	}
	if _, err := q.Exec(ctx, `UPDATE src.src_usr_loop_user SET energy = GREATEST(0, energy + $2) WHERE id=$1`, user, energy); err != nil {
		return err
	}
	_, err := q.Exec(ctx, `INSERT INTO src.src_ply_loop_energy_ledger (user_id, ledger_date, delta, reason, ref_id) VALUES ($1,$2,$3,$4,$5)`,
		user, clock.Today(), energy, reason, ref)
	return err
}

// spend takes energy, failing when there isn't enough.
func spend(ctx context.Context, tx pgx.Tx, user int64, energy int, reason string, ref int64) (int, error) {
	var have int
	if err := tx.QueryRow(ctx, `SELECT energy FROM src.src_usr_loop_user WHERE id=$1 FOR UPDATE`, user).Scan(&have); err != nil {
		return 0, err
	}
	if have < energy {
		return have, errNotEnoughEnergy(energy, have)
	}
	if err := grant(ctx, tx, user, -energy, reason, ref); err != nil {
		return 0, err
	}
	return have - energy, nil
}

// itemName names a drop item.
func itemName(cfg gameplay.Config, kind, key string) string {
	switch kind {
	case "role":
		if r, ok := cfg.Role(key); ok {
			return r.Name + "卡"
		}
	case "blueprint":
		if b, ok := cfg.Building(key); ok {
			return b.Name + "图纸"
		}
	case "egg":
		if c, ok := cfg.Companion(key); ok {
			return c.Name + "蛋"
		}
	case "energy":
		return fmt.Sprintf("能量 +%d", cfg.Boss.DropEnergy)
	}
	return key
}

// lineWKT renders a track as WKT (nil for fewer than 2 points).
func lineWKT(pts []geo.LatLng) *string {
	if len(pts) < 2 {
		return nil
	}
	var b strings.Builder
	b.WriteString("LINESTRING(")
	for i, p := range pts {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(&b, "%.7f %.7f", p.Lng, p.Lat)
	}
	b.WriteByte(')')
	s := b.String()
	return &s
}

// AfterSettle implements activity.Hook.
func (s *Service) AfterSettle(ctx context.Context, tx pgx.Tx, in activity.HookInput) (activity.Extra, func(context.Context), error) {
	ex := activity.Extra{BossDamage: []activity.BossHit{}, Chests: []activity.ChestOpen{}, Defended: []activity.Defended{},
		Routes: []activity.RouteStep{}, Campaigns: []activity.CampaignDone{}, Tasks: []activity.TaskProgress{}, Coupons: []any{}}
	var events []realtime.Event
	track := lineWKT(in.Points)
	steps := []func() error{
		func() error {
			hits, evs, err := s.bossActivity(ctx, tx, in, track)
			ex.BossDamage, events = hits, append(events, evs...)
			return err
		},
		func() (err error) { ex.Chests, ex.Coupons, err = s.chestsOnTrack(ctx, tx, in, track); return },
		func() error {
			if s.Perks == nil {
				return nil
			}
			cs, err := s.Perks.SuppliesOnTrack(ctx, tx, in, track)
			ex.Coupons = append(ex.Coupons, cs...)
			return err
		},
		func() (err error) { ex.Defended, err = s.defend(ctx, tx, in, track); return },
		func() (err error) { ex.Routes, err = s.routeProgress(ctx, tx, in); return },
		func() (err error) { ex.Campaigns, err = s.campaigns(ctx, tx, in); return },
		func() (err error) { ex.Tasks, err = s.tasks(ctx, tx, in); return },
		func() (err error) { ex.Companion, err = s.companionGrowth(ctx, tx, in); return },
		func() (err error) { ex.Relay, err = s.relayLeg(ctx, tx, in); return },
		func() error {
			if n := len(in.Claims); n > 0 {
				return codexMaxLoops(ctx, tx, in.UserID, n)
			}
			return nil
		},
	}
	for _, f := range steps {
		if err := f(); err != nil {
			return ex, nil, err
		}
	}
	for _, a := range in.Attacks {
		if a.Owner != nil {
			events = append(events, realtime.NewEvent("", []int64{a.Owner.ID}, map[string]any{
				"type": "territory_attacked", "territory_id": a.TerritoryID, "captured": a.Captured, "guard_after": a.GuardAfter}))
		}
	}
	after := func(ctx context.Context) { s.Hub.Publish(ctx, events...) }
	return ex, after, nil
}
