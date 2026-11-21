// Package jobs runs periodic background work inside the service. A Postgres
// advisory lock makes sure only one instance runs each tick.
package jobs

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/billing"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/platform/clock"
)

// Runner owns the periodic jobs.
type Runner struct {
	Pool    *pgxpool.Pool
	Billing *billing.Service
	Config  *gameplay.Store
	Log     *slog.Logger
	// Extra jobs contributed by other modules (V2 gameplay).
	Extra map[string]func(context.Context) error
}

const lockKey = 7310002

// Run ticks every interval until ctx ends.
func (r *Runner) Run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		r.Tick(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Tick runs every job once if this instance gets the lock.
func (r *Runner) Tick(ctx context.Context) {
	conn, err := r.Pool.Acquire(ctx)
	if err != nil {
		return
	}
	defer conn.Release()
	var got bool
	if err := conn.QueryRow(ctx, `SELECT pg_try_advisory_lock($1)`, lockKey).Scan(&got); err != nil || !got {
		return
	}
	defer conn.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, lockKey) //nolint:errcheck
	all := map[string]func(context.Context) error{
		"renewals":         r.Billing.RunRenewals,
		"renewal_reminder": r.Billing.RunReminders,
		"close_orders":     r.Billing.CloseStale,
		"territory_yield":  r.TerritoryYield,
		"purge_deleted":    r.PurgeDeleted,
	}
	for k, v := range r.Extra {
		all[k] = v
	}
	for name, job := range all {
		if err := job(ctx); err != nil {
			r.Log.Error("job failed", "job", name, "err", err)
		}
	}
}

// TerritoryYield credits each owner's daily territory energy once per
// business day. It is not subject to the activity energy cap.
func (r *Runner) TerritoryYield(ctx context.Context) error {
	today := clock.Today()
	return pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO src.src_sys_setting (setting_key, setting_value) VALUES ('territory_yield_day', to_jsonb($1::text))
			ON CONFLICT (setting_key) DO UPDATE SET setting_value=EXCLUDED.setting_value, update_time=now()
			WHERE src_sys_setting.setting_value <> to_jsonb($1::text)`, today.Format("2006-01-02"))
		if err != nil || tag.RowsAffected() == 0 {
			return err // already done today
		}
		// Territories inside an active monster's range produce less (城市怪兽).
		rows, err := tx.Query(ctx, `SELECT t.owner_user_id,
				COALESCE((SELECT array_agg(building) FROM src.src_ter_building b WHERE b.territory_id=t.id), '{}'),
				COALESCE((SELECT array_agg(role) FROM src.src_ter_station s WHERE s.territory_id=t.id), '{}'),
				EXISTS (SELECT 1 FROM src.src_ply_boss m WHERE m.status='active'
				        AND ST_DWithin(ST_PointOnSurface(t.area_geom)::geography, m.center_geom::geography, m.radius_m))
			FROM src.src_ter_territory t JOIN src.src_usr_user u ON u.id=t.owner_user_id
			WHERE NOT t.is_frozen AND u.status='active'`)
		if err != nil {
			return err
		}
		perUser := map[int64]int{}
		for rows.Next() {
			var owner int64
			var buildings, roles []string
			var penalized bool
			if err := rows.Scan(&owner, &buildings, &roles, &penalized); err != nil {
				rows.Close()
				return err
			}
			cfg := r.Config.For(owner)
			y := cfg.DailyEnergy(gameplay.Territory{Buildings: buildings, Stationed: roles})
			if penalized {
				y = int(float64(y) * (1 - cfg.Boss.YieldPenaltyPct/100))
			}
			perUser[owner] += y
		}
		rows.Close()
		for u, e := range perUser {
			if e <= 0 {
				continue
			}
			if _, err := tx.Exec(ctx, `UPDATE src.src_usr_user SET energy=energy+$2 WHERE id=$1`, u, e); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_energy_ledger (user_id, ledger_date, delta, reason) VALUES ($1,$2,$3,'territory_yield')`, u, today, e); err != nil {
				return err
			}
		}
		return nil
	})
}

// PurgeDeleted finishes account deletion after the 7-day cooling-off period:
// tracks and personal data are deleted, land becomes unowned.
func (r *Runner) PurgeDeleted(ctx context.Context) error {
	rows, err := r.Pool.Query(ctx, `SELECT id FROM src.src_usr_user WHERE status='deleting' AND delete_time <= now() LIMIT 100`)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	for _, id := range ids {
		err := pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
			stmts := []string{
				`DELETE FROM src.src_act_track_point WHERE activity_id IN (SELECT id FROM src.src_act_activity WHERE user_id=$1)`,
				`UPDATE src.src_act_activity SET track_geom=NULL, device_json=NULL, goal_json=NULL WHERE user_id=$1`,
				`INSERT INTO src.src_ter_event (territory_id, event_type, prev_owner_id) SELECT id, 'owner_deleted', owner_user_id FROM src.src_ter_territory WHERE owner_user_id=$1`,
				`DELETE FROM src.src_ter_building WHERE territory_id IN (SELECT id FROM src.src_ter_territory WHERE owner_user_id=$1)`,
				`DELETE FROM src.src_ter_station WHERE user_id=$1`,
				`UPDATE src.src_ter_territory SET owner_user_id=NULL, owner_crew_id=NULL, guard=0, update_time=now() WHERE owner_user_id=$1`,
				`DELETE FROM src.src_soc_crew_member WHERE user_id=$1`,
				`DELETE FROM src.src_soc_crew_apply WHERE user_id=$1`,
				`DELETE FROM src.src_usr_identity WHERE user_id=$1`,
				`DELETE FROM src.src_usr_device WHERE user_id=$1`,
				`DELETE FROM src.src_usr_refresh_token WHERE user_id=$1`,
				`DELETE FROM src.src_msg_notification WHERE user_id=$1`,
				`DELETE FROM src.src_ply_codex_item WHERE user_id=$1`,
				`DELETE FROM src.src_ord_membership WHERE user_id=$1`,
				`UPDATE src.src_usr_user SET status='deleted', phone_enc=NULL, phone_hash=NULL, phone_last4=NULL, nickname='已注销用户', avatar_url=NULL,
					birth_year=NULL, is_adult=NULL, consents_json='{}', settings_json='{}' WHERE id=$1`,
			}
			for _, s := range stmts {
				if _, err := tx.Exec(ctx, s, id); err != nil {
					return err
				}
			}
			return nil
		})
		if err != nil {
			return err
		}
		r.Log.Info("account purged", "user", id)
	}
	// Crews whose leader left by deletion: hand over to the oldest member or disband.
	_, err = r.Pool.Exec(ctx, `
		UPDATE src.src_soc_crew c SET leader_id = (SELECT user_id FROM src.src_soc_crew_member m WHERE m.crew_id=c.id ORDER BY join_time LIMIT 1)
		WHERE NOT EXISTS (SELECT 1 FROM src.src_soc_crew_member m WHERE m.crew_id=c.id AND m.user_id=c.leader_id)
		  AND EXISTS (SELECT 1 FROM src.src_soc_crew_member m WHERE m.crew_id=c.id)`)
	if err != nil {
		return err
	}
	_, err = r.Pool.Exec(ctx, `DELETE FROM src.src_soc_crew c WHERE NOT EXISTS (SELECT 1 FROM src.src_soc_crew_member m WHERE m.crew_id=c.id)`)
	return err
}
