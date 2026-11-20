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
	for name, job := range map[string]func(context.Context) error{
		"renewals":         r.Billing.RunRenewals,
		"renewal_reminder": r.Billing.RunReminders,
		"close_orders":     r.Billing.CloseStale,
		"territory_yield":  r.TerritoryYield,
		"purge_deleted":    r.PurgeDeleted,
	} {
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
		tag, err := tx.Exec(ctx, `INSERT INTO settings (key, value) VALUES ('territory_yield_day', to_jsonb($1::text))
			ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now()
			WHERE settings.value <> to_jsonb($1::text)`, today.Format("2006-01-02"))
		if err != nil || tag.RowsAffected() == 0 {
			return err // already done today
		}
		rows, err := tx.Query(ctx, `SELECT t.owner_user_id,
				COALESCE((SELECT array_agg(building) FROM territory_buildings b WHERE b.territory_id=t.id), '{}'),
				COALESCE((SELECT array_agg(role) FROM territory_stationed s WHERE s.territory_id=t.id), '{}')
			FROM territories t JOIN users u ON u.id=t.owner_user_id
			WHERE NOT t.frozen AND u.status='active'`)
		if err != nil {
			return err
		}
		perUser := map[int64]int{}
		for rows.Next() {
			var owner int64
			var buildings, roles []string
			if err := rows.Scan(&owner, &buildings, &roles); err != nil {
				rows.Close()
				return err
			}
			perUser[owner] += r.Config.For(owner).DailyEnergy(gameplay.Territory{Buildings: buildings, Stationed: roles})
		}
		rows.Close()
		for u, e := range perUser {
			if e <= 0 {
				continue
			}
			if _, err := tx.Exec(ctx, `UPDATE users SET energy=energy+$2 WHERE id=$1`, u, e); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO energy_ledger (user_id, day, delta, reason) VALUES ($1,$2,$3,'territory_yield')`, u, today, e); err != nil {
				return err
			}
		}
		return nil
	})
}

// PurgeDeleted finishes account deletion after the 7-day cooling-off period:
// tracks and personal data are deleted, land becomes unowned.
func (r *Runner) PurgeDeleted(ctx context.Context) error {
	rows, err := r.Pool.Query(ctx, `SELECT id FROM users WHERE status='deleting' AND delete_after <= now() LIMIT 100`)
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
				`DELETE FROM track_points WHERE activity_id IN (SELECT id FROM activities WHERE user_id=$1)`,
				`UPDATE activities SET track=NULL, device=NULL, goal=NULL WHERE user_id=$1`,
				`INSERT INTO territory_events (territory_id, kind, prev_owner_id) SELECT id, 'owner_deleted', owner_user_id FROM territories WHERE owner_user_id=$1`,
				`DELETE FROM territory_buildings WHERE territory_id IN (SELECT id FROM territories WHERE owner_user_id=$1)`,
				`DELETE FROM territory_stationed WHERE user_id=$1`,
				`UPDATE territories SET owner_user_id=NULL, owner_crew_id=NULL, guard=0, updated_at=now() WHERE owner_user_id=$1`,
				`DELETE FROM crew_members WHERE user_id=$1`,
				`DELETE FROM crew_applications WHERE user_id=$1`,
				`DELETE FROM user_identities WHERE user_id=$1`,
				`DELETE FROM user_devices WHERE user_id=$1`,
				`DELETE FROM refresh_tokens WHERE user_id=$1`,
				`DELETE FROM notifications WHERE user_id=$1`,
				`DELETE FROM codex_items WHERE user_id=$1`,
				`DELETE FROM memberships WHERE user_id=$1`,
				`UPDATE users SET status='deleted', phone_enc=NULL, phone_hash=NULL, phone_last4=NULL, nickname='已注销用户', avatar_url=NULL,
					birth_year=NULL, is_adult=NULL, consents='{}', settings='{}' WHERE id=$1`,
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
		UPDATE crews c SET leader_id = (SELECT user_id FROM crew_members m WHERE m.crew_id=c.id ORDER BY joined_at LIMIT 1)
		WHERE NOT EXISTS (SELECT 1 FROM crew_members m WHERE m.crew_id=c.id AND m.user_id=c.leader_id)
		  AND EXISTS (SELECT 1 FROM crew_members m WHERE m.crew_id=c.id)`)
	if err != nil {
		return err
	}
	_, err = r.Pool.Exec(ctx, `DELETE FROM crews c WHERE NOT EXISTS (SELECT 1 FROM crew_members m WHERE m.crew_id=c.id)`)
	return err
}
