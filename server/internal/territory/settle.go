// Package territory owns land: settling claimed loops against existing
// territory in PostGIS (抢地判定), rollback of voided activities, the map
// viewport query, building and stationing, and admin operations.
package territory

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/inbox"
)

// ClaimRef is a piece of land the activity ended up owning.
type ClaimRef struct {
	TerritoryID int64   `json:"territory_id"`
	Kind        string  `json:"kind"` // claim | capture
	AreaM2      float64 `json:"area_m2"`
}

// UserRef is a compact user.
type UserRef struct {
	ID        int64   `json:"id"`
	Nickname  string  `json:"nickname"`
	AvatarURL *string `json:"avatar_url,omitempty"`
}

// AttackRef reports one territory the activity attacked.
type AttackRef struct {
	TerritoryID int64    `json:"territory_id"`
	Owner       *UserRef `json:"owner"`
	Captured    bool     `json:"captured"`
	GuardBefore int      `json:"guard_before"`
	GuardAfter  int      `json:"guard_after"`
	AreaM2      float64  `json:"area_m2"`
}

// ClaimInput describes one closed loop to settle.
type ClaimInput struct {
	UserID       int64
	CrewID       *int64
	ActivityID   int64
	Ring         []geo.LatLng // closed ring
	AttackEnergy int
	MinAreaM2    float64
	// DefenseWindowH opens a 守地挑战 window on every attacked territory
	// that keeps its owner (0 disables it).
	DefenseWindowH float64
}

// Outcome is the result of settling one or more loops.
type Outcome struct {
	Claims  []ClaimRef
	Attacks []AttackRef
}

// minOverlapM2 ignores slivers created by floating point noise at borders.
const minOverlapM2 = 1.0

func ringWKT(ring []geo.LatLng) string {
	var b strings.Builder
	b.WriteString("POLYGON((")
	for i, p := range ring {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(&b, "%.8f %.8f", p.Lng, p.Lat)
	}
	b.WriteString("))")
	return b.String()
}

// lockCells takes transaction-scoped advisory locks on the coarse grid cells
// covered by the ring's bounding box. Two loops that overlap always share at
// least one cell, so concurrent settlements over the same ground serialise
// even when neither can see the other's not-yet-committed territory.
func lockCells(ctx context.Context, tx pgx.Tx, ring []geo.LatLng) error {
	minLat, minLng, maxLat, maxLng := math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)
	for _, p := range ring {
		minLat, maxLat = math.Min(minLat, p.Lat), math.Max(maxLat, p.Lat)
		minLng, maxLng = math.Min(minLng, p.Lng), math.Max(maxLng, p.Lng)
	}
	step := 0.01 // ~1 km
	for (maxLat-minLat)/step*(maxLng-minLng)/step > 400 {
		step *= 10
	}
	var keys []int64
	for la := math.Floor(minLat / step); la <= math.Floor(maxLat/step); la++ {
		for ln := math.Floor(minLng / step); ln <= math.Floor(maxLng/step); ln++ {
			keys = append(keys, int64(step*1e4)<<48^int64(la)<<24^int64(ln))
		}
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	for _, k := range keys {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, k); err != nil {
			return err
		}
	}
	return nil
}

type overlapRow struct {
	id          int64
	ownerID     *int64
	ownerNick   *string
	ownerAvatar *string
	crewID      *int64
	guard       int
	frozen      bool
	overlapM2   float64
	remainderM2 float64
	areaM2      float64
}

// Claim settles one loop inside tx.
//
// Rules (产品文档 · 自由圈地, 技术选型 · 圈地怎么算):
//   - Own land and land of the claimer's crew is left alone.
//   - Frozen land cannot be attacked.
//   - Any other overlapped territory (including 无主 land with a guard) is
//     attacked with the activity's energy: if the energy exceeds its guard the
//     overlapped part is captured, otherwise the guard is weakened by it.
//     If what would remain of the victim is below the minimum area, the whole
//     territory changes hands and its buildings and stationed characters are
//     cleared (kept in the event log for rollback).
//   - Whatever part of the loop is not covered by any territory afterwards
//     becomes a new territory if it is at least the minimum area.
func Claim(ctx context.Context, tx pgx.Tx, in ClaimInput) (Outcome, error) {
	var out Outcome
	if len(in.Ring) < 4 {
		return out, nil
	}
	if err := lockCells(ctx, tx, in.Ring); err != nil {
		return out, err
	}
	wkt := ringWKT(in.Ring)
	const loop = `lp_clean(ST_GeomFromText($1, 4326))`

	rows, err := tx.Query(ctx, `
		SELECT t.id, t.owner_user_id, u.nickname, u.avatar_url, t.owner_crew_id, t.guard, t.frozen,
		       lp_area(ST_Intersection(t.geom, `+loop+`)),
		       lp_area(ST_Difference(t.geom, `+loop+`)),
		       t.area_m2
		FROM territories t LEFT JOIN users u ON u.id = t.owner_user_id
		WHERE ST_Intersects(t.geom, `+loop+`)
		ORDER BY t.id
		FOR UPDATE OF t`, wkt)
	if err != nil {
		return out, err
	}
	victims, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (overlapRow, error) {
		var v overlapRow
		err := r.Scan(&v.id, &v.ownerID, &v.ownerNick, &v.ownerAvatar, &v.crewID, &v.guard, &v.frozen, &v.overlapM2, &v.remainderM2, &v.areaM2)
		return v, err
	})
	if err != nil {
		return out, err
	}

	for _, v := range victims {
		if v.frozen || v.overlapM2 < minOverlapM2 {
			continue
		}
		if v.ownerID != nil && *v.ownerID == in.UserID {
			continue
		}
		if v.ownerID != nil && in.CrewID != nil && v.crewID != nil && *v.crewID == *in.CrewID {
			continue
		}
		res := gameplay.Attack(in.AttackEnergy, v.guard)
		ref := AttackRef{TerritoryID: v.id, Captured: res.Captured, GuardBefore: v.guard, GuardAfter: res.GuardAfter, AreaM2: v.overlapM2}
		if v.ownerID != nil {
			ref.Owner = &UserRef{ID: *v.ownerID, Nickname: deref(v.ownerNick), AvatarURL: v.ownerAvatar}
		}
		switch {
		case !res.Captured:
			if _, err := tx.Exec(ctx, `UPDATE territories SET guard=$2, updated_at=now() WHERE id=$1`, v.id, res.GuardAfter); err != nil {
				return out, err
			}
			if err := event(ctx, tx, eventRow{territoryID: v.id, activityID: &in.ActivityID, kind: "weaken", actor: &in.UserID,
				prevOwner: v.ownerID, newOwner: v.ownerID, prevGuard: &v.guard, newGuard: &res.GuardAfter}); err != nil {
				return out, err
			}
		case v.remainderM2 < in.MinAreaM2:
			id, err := captureWhole(ctx, tx, in, v)
			if err != nil {
				return out, err
			}
			out.Claims = append(out.Claims, ClaimRef{TerritoryID: id, Kind: "capture", AreaM2: v.areaM2})
		default:
			id, area, err := captureCut(ctx, tx, in, v, wkt)
			if err != nil {
				return out, err
			}
			out.Claims = append(out.Claims, ClaimRef{TerritoryID: id, Kind: "capture", AreaM2: area})
		}
		// The victim keeps the territory after a weaken or a cut: give the
		// owner a window to reinforce it.
		if v.ownerID != nil && in.DefenseWindowH > 0 && (!res.Captured || v.remainderM2 >= in.MinAreaM2) {
			if _, err := tx.Exec(ctx, `INSERT INTO territory_defenses (territory_id, attacker_id, deadline)
				VALUES ($1, $2, now() + make_interval(secs => $3))
				ON CONFLICT (territory_id) DO UPDATE SET attacker_id=EXCLUDED.attacker_id, opened_at=now(), deadline=EXCLUDED.deadline`,
				v.id, in.UserID, in.DefenseWindowH*3600); err != nil {
				return out, err
			}
		}
		out.Attacks = append(out.Attacks, ref)
		if v.ownerID != nil {
			title, body := "领地被削弱", fmt.Sprintf("「领地 #%d」被攻击，守卫值降到 %d，快去跑一圈加固吧", v.id, res.GuardAfter)
			if res.Captured {
				title, body = "领地被抢", fmt.Sprintf("「领地 #%d」的一部分被抢走了，去夺回来！", v.id)
			}
			if err := inbox.Notify(ctx, tx, *v.ownerID, inbox.Territory, title, body,
				map[string]any{"territory_id": v.id, "captured": res.Captured, "by_user_id": in.UserID}); err != nil {
				return out, err
			}
		}
	}

	// The free part: the loop minus every territory now touching it.
	var freeArea float64
	if err := tx.QueryRow(ctx, `
		WITH f AS (
		  SELECT lp_clean(ST_Difference(`+loop+`, COALESCE(
		    (SELECT ST_Union(geom) FROM territories WHERE ST_Intersects(geom, `+loop+`)),
		    ST_GeomFromText('POLYGON EMPTY', 4326)))) AS g)
		SELECT lp_area(g) FROM f`, wkt).Scan(&freeArea); err != nil {
		return out, err
	}
	if freeArea >= in.MinAreaM2 {
		var id int64
		err := tx.QueryRow(ctx, `
			INSERT INTO territories (owner_user_id, owner_crew_id, geom, area_m2, guard, source_activity)
			SELECT $2, $3, g, lp_area(g), 0, $4 FROM (
			  SELECT lp_clean(ST_Difference(`+loop+`, COALESCE(
			    (SELECT ST_Union(geom) FROM territories WHERE ST_Intersects(geom, `+loop+`)),
			    ST_GeomFromText('POLYGON EMPTY', 4326)))) AS g) f
			RETURNING id`, wkt, in.UserID, in.CrewID, in.ActivityID).Scan(&id)
		if err != nil {
			return out, err
		}
		if err := event(ctx, tx, eventRow{territoryID: id, activityID: &in.ActivityID, kind: "claim", actor: &in.UserID, newOwner: &in.UserID}); err != nil {
			return out, err
		}
		out.Claims = append(out.Claims, ClaimRef{TerritoryID: id, Kind: "claim", AreaM2: freeArea})
	}
	return out, nil
}

type prevState struct {
	CrewID    *int64            `json:"crew_id"`
	Buildings []stateBuilding   `json:"buildings"`
	Stationed []stateStationing `json:"stationed"`
}

type stateBuilding struct {
	Slot     int    `json:"slot"`
	Building string `json:"building"`
	BuiltBy  int64  `json:"built_by"`
}

type stateStationing struct {
	UserID int64  `json:"user_id"`
	Role   string `json:"role"`
}

func snapshot(ctx context.Context, tx pgx.Tx, id int64, crew *int64) (prevState, error) {
	st := prevState{CrewID: crew, Buildings: []stateBuilding{}, Stationed: []stateStationing{}}
	rows, err := tx.Query(ctx, `SELECT slot, building, built_by FROM territory_buildings WHERE territory_id=$1`, id)
	if err != nil {
		return st, err
	}
	st.Buildings, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (stateBuilding, error) {
		var b stateBuilding
		return b, r.Scan(&b.Slot, &b.Building, &b.BuiltBy)
	})
	if err != nil {
		return st, err
	}
	rows, err = tx.Query(ctx, `SELECT user_id, role FROM territory_stationed WHERE territory_id=$1`, id)
	if err != nil {
		return st, err
	}
	st.Stationed, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (stateStationing, error) {
		var s stateStationing
		return s, r.Scan(&s.UserID, &s.Role)
	})
	return st, err
}

func captureWhole(ctx context.Context, tx pgx.Tx, in ClaimInput, v overlapRow) (int64, error) {
	st, err := snapshot(ctx, tx, v.id, v.crewID)
	if err != nil {
		return 0, err
	}
	raw, _ := json.Marshal(st)
	if _, err := tx.Exec(ctx, `DELETE FROM territory_buildings WHERE territory_id=$1`, v.id); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM territory_stationed WHERE territory_id=$1`, v.id); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `UPDATE territories SET owner_user_id=$2, owner_crew_id=$3, guard=0, source_activity=$4,
		captured_at=now(), updated_at=now() WHERE id=$1`, v.id, in.UserID, in.CrewID, in.ActivityID); err != nil {
		return 0, err
	}
	zero := 0
	return v.id, event(ctx, tx, eventRow{territoryID: v.id, activityID: &in.ActivityID, kind: "capture_whole", actor: &in.UserID,
		prevOwner: v.ownerID, newOwner: &in.UserID, prevGuard: &v.guard, newGuard: &zero, prevState: raw})
}

func captureCut(ctx context.Context, tx pgx.Tx, in ClaimInput, v overlapRow, wkt string) (int64, float64, error) {
	const loop = `lp_clean(ST_GeomFromText($2, 4326))`
	var id int64
	var area float64
	// New territory from the overlap, taken before the victim is cut.
	err := tx.QueryRow(ctx, `
		INSERT INTO territories (owner_user_id, owner_crew_id, geom, area_m2, guard, source_activity)
		SELECT $3, $4, g, lp_area(g), 0, $5 FROM (
		  SELECT lp_clean(ST_Intersection(geom, `+loop+`)) AS g FROM territories WHERE id=$1) x
		RETURNING id, area_m2`, v.id, wkt, in.UserID, in.CrewID, in.ActivityID).Scan(&id, &area)
	if err != nil {
		return 0, 0, err
	}
	if err := event(ctx, tx, eventRow{territoryID: v.id, activityID: &in.ActivityID, kind: "cut", actor: &in.UserID,
		prevOwner: v.ownerID, newOwner: v.ownerID, prevGeomFrom: &v.id}); err != nil {
		return 0, 0, err
	}
	if _, err := tx.Exec(ctx, `UPDATE territories SET geom=lp_clean(ST_Difference(geom, `+loop+`)),
		area_m2=lp_area(ST_Difference(geom, `+loop+`)), updated_at=now() WHERE id=$1`, v.id, wkt); err != nil {
		return 0, 0, err
	}
	zero := 0
	return id, area, event(ctx, tx, eventRow{territoryID: id, activityID: &in.ActivityID, kind: "capture", actor: &in.UserID,
		prevOwner: v.ownerID, newOwner: &in.UserID, newGuard: &zero})
}

type eventRow struct {
	territoryID  int64
	activityID   *int64
	kind         string
	actor        *int64
	prevOwner    *int64
	newOwner     *int64
	prevGuard    *int
	newGuard     *int
	prevGeomFrom *int64 // copy the territory's current geometry as prev_geom
	prevState    []byte
	adminID      *int64
}

func event(ctx context.Context, q interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}, e eventRow) error {
	var id int64
	return q.QueryRow(ctx, `INSERT INTO territory_events
		(territory_id, activity_id, kind, actor_user_id, prev_owner_id, new_owner_id, prev_guard, new_guard, prev_geom, prev_state, admin_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,(SELECT geom FROM territories WHERE id=$9),$10,$11) RETURNING id`,
		e.territoryID, e.activityID, e.kind, e.actor, e.prevOwner, e.newOwner, e.prevGuard, e.newGuard, e.prevGeomFrom, e.prevState, e.adminID).Scan(&id)
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// Rollback undoes everything an activity did to territory, newest first.
// It is exact when nothing else touched those territories since; otherwise
// it restores as much as still applies (a restored cut never overlaps land
// that others claimed in the meantime).
func Rollback(ctx context.Context, tx pgx.Tx, activityID int64) error {
	type ev struct {
		id, territoryID     int64
		kind                string
		prevOwner, newOwner *int64
		prevGuard, newGuard *int
		prevState           []byte
	}
	rows, err := tx.Query(ctx, `SELECT id, territory_id, kind, prev_owner_id, new_owner_id, prev_guard, new_guard, prev_state
		FROM territory_events WHERE activity_id=$1 ORDER BY id DESC`, activityID)
	if err != nil {
		return err
	}
	evs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (ev, error) {
		var e ev
		return e, r.Scan(&e.id, &e.territoryID, &e.kind, &e.prevOwner, &e.newOwner, &e.prevGuard, &e.newGuard, &e.prevState)
	})
	if err != nil {
		return err
	}
	// Lock what we're about to touch in id order to avoid deadlocks.
	ids := make([]int64, 0, len(evs))
	for _, e := range evs {
		ids = append(ids, e.territoryID)
	}
	if _, err := tx.Exec(ctx, `SELECT 1 FROM territories WHERE id = ANY($1) ORDER BY id FOR UPDATE`, ids); err != nil {
		return err
	}
	notified := map[int64]bool{}
	for _, e := range evs {
		switch e.kind {
		case "claim", "capture":
			if _, err := tx.Exec(ctx, `DELETE FROM territories WHERE id=$1`, e.territoryID); err != nil {
				return err
			}
		case "cut":
			if _, err := tx.Exec(ctx, `
				UPDATE territories t SET geom = g, area_m2 = lp_area(g), updated_at = now()
				FROM (SELECT lp_clean(ST_Difference(ev.prev_geom, COALESCE(
				        (SELECT ST_Union(o.geom) FROM territories o WHERE o.id <> ev.territory_id AND ST_Intersects(o.geom, ev.prev_geom)),
				        ST_GeomFromText('POLYGON EMPTY', 4326)))) AS g
				      FROM territory_events ev WHERE ev.id = $1) x
				WHERE t.id = $2 AND NOT ST_IsEmpty(g)`, e.id, e.territoryID); err != nil {
				return err
			}
		case "capture_whole":
			var st prevState
			_ = json.Unmarshal(e.prevState, &st)
			if _, err := tx.Exec(ctx, `UPDATE territories SET owner_user_id=$2, owner_crew_id=$3, guard=COALESCE($4,0), updated_at=now() WHERE id=$1`,
				e.territoryID, e.prevOwner, st.CrewID, e.prevGuard); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `DELETE FROM territory_buildings WHERE territory_id=$1`, e.territoryID); err != nil {
				return err
			}
			for _, b := range st.Buildings {
				if _, err := tx.Exec(ctx, `INSERT INTO territory_buildings (territory_id, slot, building, built_by) VALUES ($1,$2,$3,$4)
					ON CONFLICT DO NOTHING`, e.territoryID, b.Slot, b.Building, b.BuiltBy); err != nil {
					return err
				}
			}
			for _, s := range st.Stationed {
				if _, err := tx.Exec(ctx, `INSERT INTO territory_stationed (user_id, role, territory_id) VALUES ($1,$2,$3)
					ON CONFLICT DO NOTHING`, s.UserID, s.Role, e.territoryID); err != nil {
					return err
				}
			}
		case "weaken":
			if e.prevGuard != nil && e.newGuard != nil {
				if _, err := tx.Exec(ctx, `UPDATE territories SET guard = guard + $2, updated_at=now() WHERE id=$1`,
					e.territoryID, *e.prevGuard-*e.newGuard); err != nil {
					return err
				}
			}
		default:
			continue
		}
		if e.kind != "claim" && e.kind != "capture" {
			if err := event(ctx, tx, eventRow{territoryID: e.territoryID, activityID: &activityID, kind: "rollback"}); err != nil {
				return err
			}
		}
		if e.prevOwner != nil && e.kind != "claim" && !notified[*e.prevOwner] {
			notified[*e.prevOwner] = true
			if err := inbox.Notify(ctx, tx, *e.prevOwner, inbox.Territory, "领地已恢复",
				"攻击你领地的一次运动被判定为作弊，已作废，领地和守卫值已恢复。", map[string]any{"territory_id": e.territoryID}); err != nil {
				return err
			}
		}
	}
	return nil
}

// Reinforce adds energy to a defended territory's guard (守地挑战), capped
// at maxGuard, and closes its defense window. It returns the guard before
// and after.
func Reinforce(ctx context.Context, tx pgx.Tx, territoryID, user, activityID int64, energy, maxGuard int) (int, int, error) {
	var before int
	if err := tx.QueryRow(ctx, `SELECT guard FROM territories WHERE id=$1 FOR UPDATE`, territoryID).Scan(&before); err != nil {
		return 0, 0, err
	}
	after := min(maxGuard, before+max(0, energy))
	if after < before {
		after = before // already above the cap: never lower it
	}
	if _, err := tx.Exec(ctx, `UPDATE territories SET guard=$2, updated_at=now() WHERE id=$1`, territoryID, after); err != nil {
		return 0, 0, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM territory_defenses WHERE territory_id=$1`, territoryID); err != nil {
		return 0, 0, err
	}
	return before, after, event(ctx, tx, eventRow{territoryID: territoryID, activityID: &activityID, kind: "reinforce", actor: &user,
		prevOwner: &user, newOwner: &user, prevGuard: &before, newGuard: &after})
}
