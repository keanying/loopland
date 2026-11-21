package territory

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Service implements reads and the owner/admin operations.
type Service struct {
	Pool   *pgxpool.Pool
	Config *gameplay.Store
}

// CrewRef is a compact crew.
type CrewRef struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// LatLng is a coordinate.
type LatLng struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

// Summary is what the map shows.
type Summary struct {
	ID        int64           `json:"id"`
	Name      string          `json:"name"`
	Relation  string          `json:"relation"`
	Owner     *UserRef        `json:"owner"`
	Crew      *CrewRef        `json:"crew"`
	Geometry  json.RawMessage `json:"geometry"`
	Center    LatLng          `json:"center"`
	AreaM2    float64         `json:"area_m2"`
	Guard     int             `json:"guard"`
	Frozen    bool            `json:"frozen"`
	UpdatedAt time.Time       `json:"updated_at"`
}

// Slot is one building slot.
type Slot struct {
	Slot     int     `json:"slot"`
	Building *string `json:"building"`
	Name     *string `json:"name"`
}

// Stationed is a character on the territory.
type Stationed struct {
	Role     string `json:"role"`
	Name     string `json:"name"`
	BuffText string `json:"buff_text"`
	UserID   int64  `json:"user_id"`
}

// Event is one history entry.
type Event struct {
	Kind      string    `json:"kind"`
	Actor     *UserRef  `json:"actor"`
	PrevOwner *UserRef  `json:"prev_owner,omitempty"`
	NewOwner  *UserRef  `json:"new_owner,omitempty"`
	PrevGuard *int      `json:"prev_guard,omitempty"`
	NewGuard  *int      `json:"new_guard,omitempty"`
	AdminID   *int64    `json:"admin,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// Defense is an open 守地挑战 window.
type Defense struct {
	Deadline   time.Time `json:"deadline"`
	AttackedBy *UserRef  `json:"attacked_by"`
}

// Detail is the full territory.
type Detail struct {
	Summary
	DailyEnergy  int         `json:"daily_energy"`
	Slots        []Slot      `json:"slots"`
	StationSlots int         `json:"station_slots"`
	Stationed    []Stationed `json:"stationed"`
	CapturedAt   time.Time   `json:"captured_at"`
	Defense      *Defense    `json:"defense"`
	Events       []Event     `json:"events"`
}

const summaryCols = `t.id, COALESCE(t.name, '领地 #' || t.id), t.owner_user_id, u.nickname, u.avatar_url, t.owner_crew_id, c.name,
	ST_AsGeoJSON(t.geom, 7)::text, ST_Y(ST_PointOnSurface(t.geom)), ST_X(ST_PointOnSurface(t.geom)), t.area_m2, t.guard, t.frozen, t.updated_at`

const summaryFrom = ` FROM territories t LEFT JOIN users u ON u.id=t.owner_user_id LEFT JOIN crews c ON c.id=t.owner_crew_id `

func scanSummary(row pgx.Row, viewer int64, viewerCrew *int64) (Summary, error) {
	var s Summary
	var ownerID, crewID *int64
	var nick, avatar, crewName *string
	var geom string
	if err := row.Scan(&s.ID, &s.Name, &ownerID, &nick, &avatar, &crewID, &crewName, &geom, &s.Center.Lat, &s.Center.Lng,
		&s.AreaM2, &s.Guard, &s.Frozen, &s.UpdatedAt); err != nil {
		return s, err
	}
	s.Geometry = json.RawMessage(geom)
	if ownerID != nil {
		s.Owner = &UserRef{ID: *ownerID, Nickname: deref(nick), AvatarURL: avatar}
	}
	if crewID != nil {
		s.Crew = &CrewRef{ID: *crewID, Name: deref(crewName)}
	}
	switch {
	case ownerID == nil:
		s.Relation = "unowned"
	case *ownerID == viewer:
		s.Relation = "mine"
	case viewerCrew != nil && crewID != nil && *viewerCrew == *crewID:
		s.Relation = "crew"
	default:
		s.Relation = "enemy"
	}
	return s, nil
}

// BBox is minLng,minLat,maxLng,maxLat.
type BBox [4]float64

// ParseBBox parses the ?bbox= value.
func ParseBBox(v string) (BBox, error) {
	var b BBox
	if _, err := fmt.Sscanf(v, "%g,%g,%g,%g", &b[0], &b[1], &b[2], &b[3]); err != nil {
		return b, httpx.BadRequest("invalid_bbox", "bbox 格式应为 minLng,minLat,maxLng,maxLat")
	}
	if b[0] >= b[2] || b[1] >= b[3] || b[2]-b[0] > 2 || b[3]-b[1] > 2 {
		return b, httpx.BadRequest("invalid_bbox", "bbox 范围无效或过大（最多 2 度）")
	}
	return b, nil
}

// Viewport returns up to 500 territories intersecting bbox.
func (s *Service) Viewport(ctx context.Context, b BBox, scope string, viewer int64, viewerCrew *int64) ([]Summary, error) {
	where := `t.geom && ST_MakeEnvelope($1,$2,$3,$4,4326)`
	args := []any{b[0], b[1], b[2], b[3]}
	switch scope {
	case "mine":
		where += ` AND t.owner_user_id = $5`
		args = append(args, viewer)
	case "crew":
		if viewerCrew == nil {
			return []Summary{}, nil
		}
		where += ` AND t.owner_crew_id = $5`
		args = append(args, *viewerCrew)
	}
	rows, err := s.Pool.Query(ctx, `SELECT `+summaryCols+summaryFrom+` WHERE `+where+` ORDER BY t.area_m2 DESC LIMIT 500`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Summary{}
	for rows.Next() {
		sm, err := scanSummary(rows, viewer, viewerCrew)
		if err != nil {
			return nil, err
		}
		out = append(out, sm)
	}
	return out, rows.Err()
}

// Get returns the full territory.
func (s *Service) Get(ctx context.Context, q db.Querier, id, viewer int64, viewerCrew *int64, allEvents bool) (Detail, error) {
	var d Detail
	sm, err := scanSummary(q.QueryRow(ctx, `SELECT `+summaryCols+summaryFrom+` WHERE t.id=$1`, id), viewer, viewerCrew)
	if db.IsNoRows(err) {
		return d, httpx.NotFound("领地")
	}
	if err != nil {
		return d, err
	}
	d.Summary = sm
	if err := q.QueryRow(ctx, `SELECT captured_at FROM territories WHERE id=$1`, id).Scan(&d.CapturedAt); err != nil {
		return d, err
	}
	var dl time.Time
	var att *int64
	var attNick *string
	err = q.QueryRow(ctx, `SELECT d.deadline, d.attacker_id, u.nickname FROM territory_defenses d LEFT JOIN users u ON u.id=d.attacker_id
		WHERE d.territory_id=$1 AND d.deadline > now()`, id).Scan(&dl, &att, &attNick)
	if err == nil {
		d.Defense = &Defense{Deadline: dl, AttackedBy: ref(att, attNick)}
	} else if !db.IsNoRows(err) {
		return d, err
	}
	cfgUser := viewer
	if sm.Owner != nil {
		cfgUser = sm.Owner.ID
	}
	cfg := s.Config.For(cfgUser)
	buildings, stationed, err := loadState(ctx, q, id)
	if err != nil {
		return d, err
	}
	d.Slots = make([]Slot, cfg.SlotsPerTerritory)
	for i := range d.Slots {
		d.Slots[i].Slot = i
	}
	var keys []string
	for slot, key := range buildings {
		keys = append(keys, key)
		if slot < len(d.Slots) {
			k := key
			name := key
			if b, ok := cfg.Building(key); ok {
				name = b.Name
			}
			d.Slots[slot].Building, d.Slots[slot].Name = &k, &name
		}
	}
	d.Stationed = []Stationed{}
	var roles []string
	for _, st := range stationed {
		roles = append(roles, st.Role)
		r, _ := cfg.Role(st.Role)
		d.Stationed = append(d.Stationed, Stationed{Role: st.Role, Name: r.Name, BuffText: r.BuffText, UserID: st.UserID})
	}
	d.StationSlots = cfg.StationSlots(keys)
	d.DailyEnergy = cfg.DailyEnergy(gameplay.Territory{Buildings: keys, Stationed: roles})
	limit := 20
	if allEvents {
		limit = 500
	}
	rows, err := q.Query(ctx, `SELECT e.kind, e.actor_user_id, ua.nickname, e.prev_owner_id, up.nickname, e.new_owner_id, un.nickname,
			e.prev_guard, e.new_guard, e.admin_id, e.created_at
		FROM territory_events e
		LEFT JOIN users ua ON ua.id=e.actor_user_id LEFT JOIN users up ON up.id=e.prev_owner_id LEFT JOIN users un ON un.id=e.new_owner_id
		WHERE e.territory_id=$1 ORDER BY e.id DESC LIMIT $2`, id, limit)
	if err != nil {
		return d, err
	}
	d.Events, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Event, error) {
		var e Event
		var a, p, n *int64
		var an, pn, nn *string
		err := r.Scan(&e.Kind, &a, &an, &p, &pn, &n, &nn, &e.PrevGuard, &e.NewGuard, &e.AdminID, &e.CreatedAt)
		e.Actor, e.PrevOwner, e.NewOwner = ref(a, an), ref(p, pn), ref(n, nn)
		return e, err
	})
	if d.Events == nil {
		d.Events = []Event{}
	}
	return d, err
}

func ref(id *int64, nick *string) *UserRef {
	if id == nil {
		return nil
	}
	return &UserRef{ID: *id, Nickname: deref(nick)}
}

type stationRow struct {
	UserID int64
	Role   string
}

func loadState(ctx context.Context, q db.Querier, id int64) (map[int]string, []stationRow, error) {
	buildings := map[int]string{}
	rows, err := q.Query(ctx, `SELECT slot, building FROM territory_buildings WHERE territory_id=$1`, id)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var slot int
		var b string
		if err := rows.Scan(&slot, &b); err != nil {
			rows.Close()
			return nil, nil, err
		}
		buildings[slot] = b
	}
	rows.Close()
	rows, err = q.Query(ctx, `SELECT user_id, role FROM territory_stationed WHERE territory_id=$1 ORDER BY role`, id)
	if err != nil {
		return nil, nil, err
	}
	st, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (stationRow, error) {
		var s stationRow
		return s, r.Scan(&s.UserID, &s.Role)
	})
	return buildings, st, err
}

func keysOf(m map[int]string) []string {
	out := make([]string, 0, len(m))
	for _, v := range m {
		out = append(out, v)
	}
	return out
}

func rolesOf(st []stationRow) []string {
	out := make([]string, 0, len(st))
	for _, s := range st {
		out = append(out, s.Role)
	}
	return out
}

// Owner errors.
var (
	errNotOwner = httpx.Forbidden("not_owner", "这不是你的领地")
	errFrozen   = httpx.Forbidden("frozen", "领地已被冻结")
)

func lockOwned(ctx context.Context, tx pgx.Tx, id, user int64) error {
	var owner *int64
	var frozen bool
	err := tx.QueryRow(ctx, `SELECT owner_user_id, frozen FROM territories WHERE id=$1 FOR UPDATE`, id).Scan(&owner, &frozen)
	if db.IsNoRows(err) {
		return httpx.NotFound("领地")
	}
	if err != nil {
		return err
	}
	if owner == nil || *owner != user {
		return errNotOwner
	}
	if frozen {
		return errFrozen
	}
	return nil
}

// Build constructs a building in a slot, paying energy.
func (s *Service) Build(ctx context.Context, user int64, id int64, slot int, key string) (int, error) {
	cfg := s.Config.For(user)
	var energy int
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if err := lockOwned(ctx, tx, id, user); err != nil {
			return err
		}
		if slot < 0 || slot >= cfg.SlotsPerTerritory {
			return httpx.BadRequest("invalid_slot", "建造位不存在")
		}
		buildings, stationed, err := loadState(ctx, tx, id)
		if err != nil {
			return err
		}
		if _, taken := buildings[slot]; taken {
			return httpx.Conflict("slot_taken", "这个建造位已经有建筑了")
		}
		var earned int64
		if err := tx.QueryRow(ctx, `SELECT energy, energy_earned_total FROM users WHERE id=$1 FOR UPDATE`, user).Scan(&energy, &earned); err != nil {
			return err
		}
		t := gameplay.Territory{Buildings: keysOf(buildings), Stationed: rolesOf(stationed)}
		var blueprint bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM codex_items WHERE user_id=$1 AND kind='blueprint' AND item=$2)`, user, key).Scan(&blueprint); err != nil {
			return err
		}
		cost, err := cfg.CheckBuildWith(t, key, cfg.Level(earned), energy, blueprint)
		switch {
		case errors.Is(err, gameplay.ErrUnknownBuilding):
			return httpx.BadRequest("unknown_building", "没有这种建筑")
		case errors.Is(err, gameplay.ErrLevelTooLow):
			b, _ := cfg.Building(key)
			return httpx.Forbidden("level_too_low", fmt.Sprintf("%s需要 Lv.%d 才能建造", b.Name, b.UnlockLevel))
		case errors.Is(err, gameplay.ErrNotEnoughEnergy):
			c, _ := cfg.BuildCost(t, key)
			return httpx.Forbidden("not_enough_energy", fmt.Sprintf("需要 %d 能量，当前 %d", c, energy))
		case errors.Is(err, gameplay.ErrNoFreeSlot):
			return httpx.Conflict("no_free_slot", "建造位已满")
		case err != nil:
			return err
		}
		b, _ := cfg.Building(key)
		guardAdd := int(math.Floor(float64(b.Guard) * (1 + guardPct(cfg, rolesOf(stationed))/100)))
		energy -= cost
		if _, err := tx.Exec(ctx, `UPDATE users SET energy=$2 WHERE id=$1`, user, energy); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO energy_ledger (user_id, day, delta, reason, ref_id) VALUES ($1,$2,$3,'build',$4)`,
			user, clock.Today(), -cost, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO territory_buildings (territory_id, slot, building, built_by) VALUES ($1,$2,$3,$4)`, id, slot, key, user); err != nil {
			return err
		}
		var prev, next int
		if err := tx.QueryRow(ctx, `UPDATE territories SET guard=guard+$2, updated_at=now() WHERE id=$1 RETURNING guard-$2, guard`, id, guardAdd).Scan(&prev, &next); err != nil {
			return err
		}
		return event(ctx, tx, eventRow{territoryID: id, kind: "build", actor: &user, prevGuard: &prev, newGuard: &next})
	})
	return energy, err
}

func guardPct(cfg gameplay.Config, roles []string) float64 {
	var p float64
	for _, k := range roles {
		if r, ok := cfg.Role(k); ok && r.Buff == gameplay.BuffGuardPct {
			p += r.BuffValue
		}
	}
	return p
}

func buildingGuard(cfg gameplay.Config, keys []string) int {
	var g int
	for _, k := range keys {
		if b, ok := cfg.Building(k); ok {
			g += b.Guard
		}
	}
	return g
}

// adjustGuardForRole adds (sign=+1) or removes (sign=-1) a guard_pct role's
// share of the territory's building guard.
func adjustGuardForRole(ctx context.Context, tx pgx.Tx, cfg gameplay.Config, territoryID int64, role string, sign int) error {
	r, ok := cfg.Role(role)
	if !ok || r.Buff != gameplay.BuffGuardPct {
		return nil
	}
	buildings, _, err := loadState(ctx, tx, territoryID)
	if err != nil {
		return err
	}
	delta := int(math.Floor(float64(buildingGuard(cfg, keysOf(buildings))) * r.BuffValue / 100))
	_, err = tx.Exec(ctx, `UPDATE territories SET guard=GREATEST(0, guard + $2), updated_at=now() WHERE id=$1`, territoryID, sign*delta)
	return err
}

// Station moves one of the user's characters onto the territory.
func (s *Service) Station(ctx context.Context, user, id int64, role string) error {
	cfg := s.Config.For(user)
	if _, ok := cfg.Role(role); !ok {
		return httpx.BadRequest("role_not_owned", "没有这个角色")
	}
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if err := lockOwned(ctx, tx, id, user); err != nil {
			return err
		}
		var owned bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM codex_items WHERE user_id=$1 AND kind='role' AND item=$2)`, user, role).Scan(&owned); err != nil {
			return err
		}
		if !owned {
			return httpx.Forbidden("role_not_owned", "还没有招募到这个角色")
		}
		var current *int64
		err := tx.QueryRow(ctx, `SELECT territory_id FROM territory_stationed WHERE user_id=$1 AND role=$2`, user, role).Scan(&current)
		if err != nil && !db.IsNoRows(err) {
			return err
		}
		if current != nil && *current == id {
			return nil
		}
		buildings, stationed, err := loadState(ctx, tx, id)
		if err != nil {
			return err
		}
		if len(stationed) >= cfg.StationSlots(keysOf(buildings)) {
			return httpx.Conflict("no_station_slot", "驻扎位已满，建造营帐或民居可以增加驻扎位")
		}
		if current != nil {
			if _, err := tx.Exec(ctx, `SELECT 1 FROM territories WHERE id=$1 FOR UPDATE`, *current); err != nil {
				return err
			}
			if err := adjustGuardForRole(ctx, tx, cfg, *current, role, -1); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `INSERT INTO territory_stationed (user_id, role, territory_id) VALUES ($1,$2,$3)
			ON CONFLICT (user_id, role) DO UPDATE SET territory_id=EXCLUDED.territory_id`, user, role, id); err != nil {
			return err
		}
		return adjustGuardForRole(ctx, tx, cfg, id, role, +1)
	})
}

// Unstation removes a character from the territory.
func (s *Service) Unstation(ctx context.Context, user, id int64, role string) error {
	cfg := s.Config.For(user)
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if err := lockOwned(ctx, tx, id, user); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `DELETE FROM territory_stationed WHERE user_id=$1 AND role=$2 AND territory_id=$3`, user, role, id)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return httpx.NotFound("驻扎角色")
		}
		return adjustGuardForRole(ctx, tx, cfg, id, role, -1)
	})
}

// ---------------------------------------------------------------- admin ops

// SetGuard sets the guard value (0–2000, step 50).
func (s *Service) SetGuard(ctx context.Context, id int64, guard int, adminID int64) error {
	if guard < 0 || guard > 2000 || guard%50 != 0 {
		return httpx.BadRequest("invalid_guard", "守卫值范围 0–2000，步长 50")
	}
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var prev int
		err := tx.QueryRow(ctx, `SELECT guard FROM territories WHERE id=$1 FOR UPDATE`, id).Scan(&prev)
		if db.IsNoRows(err) {
			return httpx.NotFound("领地")
		}
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE territories SET guard=$2, updated_at=now() WHERE id=$1`, id, guard); err != nil {
			return err
		}
		return event(ctx, tx, eventRow{territoryID: id, kind: "admin_guard", prevGuard: &prev, newGuard: &guard, adminID: &adminID})
	})
}

// SetFrozen freezes or unfreezes a territory.
func (s *Service) SetFrozen(ctx context.Context, q db.Querier, id int64, frozen bool, adminID *int64) error {
	tag, err := q.Exec(ctx, `UPDATE territories SET frozen=$2, updated_at=now() WHERE id=$1 AND frozen<>$2`, id, frozen)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		var exists bool
		if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM territories WHERE id=$1)`, id).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return httpx.NotFound("领地")
		}
		return nil
	}
	kind := "unfreeze"
	if frozen {
		kind = "freeze"
	}
	return event(ctx, q, eventRow{territoryID: id, kind: kind, adminID: adminID})
}

// Reset makes a territory unowned and clears its buildings.
func (s *Service) Reset(ctx context.Context, id int64, adminID int64) error {
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var owner, crew *int64
		var guard int
		err := tx.QueryRow(ctx, `SELECT owner_user_id, owner_crew_id, guard FROM territories WHERE id=$1 FOR UPDATE`, id).Scan(&owner, &crew, &guard)
		if db.IsNoRows(err) {
			return httpx.NotFound("领地")
		}
		if err != nil {
			return err
		}
		st, err := snapshot(ctx, tx, id, crew)
		if err != nil {
			return err
		}
		raw, _ := json.Marshal(st)
		if _, err := tx.Exec(ctx, `DELETE FROM territory_buildings WHERE territory_id=$1`, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM territory_stationed WHERE territory_id=$1`, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE territories SET owner_user_id=NULL, owner_crew_id=NULL, guard=0, updated_at=now() WHERE id=$1`, id); err != nil {
			return err
		}
		zero := 0
		if err := event(ctx, tx, eventRow{territoryID: id, kind: "reset", prevOwner: owner, prevGuard: &guard, newGuard: &zero, prevState: raw, adminID: &adminID}); err != nil {
			return err
		}
		if owner != nil {
			return inbox.Notify(ctx, tx, *owner, inbox.Territory, "领地被重置",
				fmt.Sprintf("「领地 #%d」经运营核查已重置为无主。如有疑问请联系客服。", id), map[string]any{"territory_id": id})
		}
		return nil
	})
}

// AdminItem is a row of the admin territory list.
type AdminItem struct {
	ID            int64     `json:"id"`
	Name          string    `json:"name"`
	Owner         *UserRef  `json:"owner"`
	Crew          *CrewRef  `json:"crew"`
	AreaM2        float64   `json:"area_m2"`
	Guard         int       `json:"guard"`
	Frozen        bool      `json:"frozen"`
	ChangesToday  int       `json:"changes_today"`
	BuildingCount int       `json:"building_count"`
	Center        LatLng    `json:"center"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// AdminList lists territories for the back office.
func (s *Service) AdminList(ctx context.Context, status, q string, p httpx.Page) ([]AdminItem, int, error) {
	today := clock.Today()
	where := `TRUE`
	args := []any{today}
	switch status {
	case "frozen":
		where = `t.frozen`
	case "contested":
		where = `EXISTS (SELECT 1 FROM territory_events e WHERE e.territory_id=t.id AND e.created_at >= $1 AND e.kind IN ('capture','capture_whole','cut','weaken'))`
	}
	if q != "" {
		args = append(args, q)
		where += fmt.Sprintf(` AND (t.id::text = $%d OR u.nickname ILIKE '%%' || $%d || '%%' OR c.name ILIKE '%%' || $%d || '%%')`, len(args), len(args), len(args))
	}
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*)`+summaryFrom+` WHERE `+where+` AND $1::timestamptz IS NOT NULL`, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	args = append(args, p.Size, p.Offset())
	rows, err := s.Pool.Query(ctx, fmt.Sprintf(`SELECT t.id, COALESCE(t.name, '领地 #' || t.id), t.owner_user_id, u.nickname, t.owner_crew_id, c.name,
			t.area_m2, t.guard, t.frozen,
			(SELECT count(*) FROM territory_events e WHERE e.territory_id=t.id AND e.created_at >= $1 AND e.kind IN ('capture','capture_whole','cut','weaken')),
			(SELECT count(*) FROM territory_buildings b WHERE b.territory_id=t.id),
			ST_Y(ST_PointOnSurface(t.geom)), ST_X(ST_PointOnSurface(t.geom)), t.updated_at
		`+summaryFrom+` WHERE `+where+` ORDER BY t.updated_at DESC LIMIT $%d OFFSET $%d`, len(args)-1, len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (AdminItem, error) {
		var it AdminItem
		var oid, cid *int64
		var on, cn *string
		err := r.Scan(&it.ID, &it.Name, &oid, &on, &cid, &cn, &it.AreaM2, &it.Guard, &it.Frozen, &it.ChangesToday, &it.BuildingCount,
			&it.Center.Lat, &it.Center.Lng, &it.UpdatedAt)
		it.Owner = ref(oid, on)
		if cid != nil {
			it.Crew = &CrewRef{ID: *cid, Name: deref(cn)}
		}
		return it, err
	})
	return items, total, err
}

// Handler serves the app territory endpoints.
type Handler struct {
	Svc    *Service
	CrewOf func(ctx context.Context, user int64) (*int64, error)
	Energy func(ctx context.Context, user int64) (int, error)
}

// Routes registers /v1/territories.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /v1/territories", auth(h.viewport))
	mux.Handle("GET /v1/territories/{id}", auth(h.get))
	mux.Handle("POST /v1/territories/{id}/buildings", auth(h.build))
	mux.Handle("POST /v1/territories/{id}/stationed", auth(h.station))
	mux.Handle("DELETE /v1/territories/{id}/stationed/{role}", auth(h.unstation))
}

func (h *Handler) viewport(w http.ResponseWriter, r *http.Request) error {
	b, err := ParseBBox(r.URL.Query().Get("bbox"))
	if err != nil {
		return err
	}
	uid := httpx.UserID(r.Context())
	crew, err := h.CrewOf(r.Context(), uid)
	if err != nil {
		return err
	}
	items, err := h.Svc.Viewport(r.Context(), b, r.URL.Query().Get("scope"), uid, crew)
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *Handler) detail(r *http.Request, id int64) (Detail, error) {
	uid := httpx.UserID(r.Context())
	crew, err := h.CrewOf(r.Context(), uid)
	if err != nil {
		return Detail{}, err
	}
	return h.Svc.Get(r.Context(), h.Svc.Pool, id, uid, crew, false)
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	d, err := h.detail(r, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, d)
}

func (h *Handler) build(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Slot     int    `json:"slot"`
		Building string `json:"building"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	energy, err := h.Svc.Build(r.Context(), httpx.UserID(r.Context()), id, req.Slot, req.Building)
	if err != nil {
		return err
	}
	d, err := h.detail(r, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"territory": d, "energy": energy})
}

func (h *Handler) station(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Role string `json:"role"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if err := h.Svc.Station(r.Context(), httpx.UserID(r.Context()), id, req.Role); err != nil {
		return err
	}
	d, err := h.detail(r, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, d)
}

func (h *Handler) unstation(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	if err := h.Svc.Unstation(r.Context(), httpx.UserID(r.Context()), id, r.PathValue("role")); err != nil {
		return err
	}
	d, err := h.detail(r, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, d)
}
