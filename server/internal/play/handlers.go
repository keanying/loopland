package play

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/codex"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/territory"
)

// MapObjects is GET /v1/map/objects.
type MapObjects struct {
	Bosses      []BossSummary   `json:"bosses"`
	Chests      []ChestView     `json:"chests"`
	Checkpoints []CheckpointPin `json:"checkpoints"`
}

// ChestView is a chest on the map.
type ChestView struct {
	ID        int64     `json:"id"`
	Center    LatLng    `json:"center"`
	RadiusM   float64   `json:"radius_m"`
	ExpiresAt time.Time `json:"expires_at"`
	EnergyMin int       `json:"energy_min,omitempty"`
	EnergyMax int       `json:"energy_max,omitempty"`
	Opens     *int      `json:"opens,omitempty"`
	Source    string    `json:"source,omitempty"`
	Status    string    `json:"status,omitempty"`
}

// CheckpointPin is an orienteering point on the map.
type CheckpointPin struct {
	RouteID int64   `json:"route_id"`
	Index   int     `json:"index"`
	Name    string  `json:"name"`
	Center  LatLng  `json:"center"`
	RadiusM float64 `json:"radius_m"`
	State   string  `json:"state"`
}

const env = `ST_MakeEnvelope($1,$2,$3,$4,4326)`

// Objects lists monsters, chests and checkpoints in the viewport (user=0: admin).
func (s *Service) Objects(ctx context.Context, b territory.BBox, user int64) (MapObjects, error) {
	out := MapObjects{Bosses: []BossSummary{}, Chests: []ChestView{}, Checkpoints: []CheckpointPin{}}
	rows, err := s.Pool.Query(ctx, `SELECT `+bossCols+` FROM bosses b WHERE b.status='active'
		AND ST_DWithin(b.center::geography, `+env+`::geography, b.radius_m) ORDER BY b.id LIMIT 100`, b[0], b[1], b[2], b[3])
	if err != nil {
		return out, err
	}
	if out.Bosses, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (BossSummary, error) { return scanBoss(r) }); err != nil {
		return out, err
	}
	if out.Bosses == nil {
		out.Bosses = []BossSummary{}
	}
	rows, err = s.Pool.Query(ctx, `SELECT c.id, ST_Y(c.center), ST_X(c.center), c.radius_m, c.expires_at FROM chests c
		WHERE c.expires_at > now() AND c.removed_at IS NULL AND c.center && `+env+`
		  AND ($5 = 0 OR NOT EXISTS (SELECT 1 FROM chest_opens o WHERE o.chest_id=c.id AND o.user_id=$5))
		ORDER BY c.id LIMIT 300`, b[0], b[1], b[2], b[3], user)
	if err != nil {
		return out, err
	}
	out.Chests, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (ChestView, error) {
		var c ChestView
		return c, r.Scan(&c.ID, &c.Center.Lat, &c.Center.Lng, &c.RadiusM, &c.ExpiresAt)
	})
	if err != nil {
		return out, err
	}
	if out.Chests == nil {
		out.Chests = []ChestView{}
	}
	routes, err := s.Routes(ctx, user)
	if err != nil {
		return out, err
	}
	for _, r := range routes {
		for _, c := range r.Checkpoints {
			if c.Center.Lng < b[0] || c.Center.Lng > b[2] || c.Center.Lat < b[1] || c.Center.Lat > b[3] {
				continue
			}
			if user > 0 && c.State != "next" {
				continue // the app shows only the next point of each route
			}
			out.Checkpoints = append(out.Checkpoints, CheckpointPin{RouteID: r.ID, Index: c.Index, Name: c.Name, Center: c.Center, RadiusM: c.RadiusM, State: c.State})
		}
	}
	return out, nil
}

// ---------------------------------------------------------------- campaigns & routes views

// Campaign is a limited-time campaign.
type Campaign struct {
	ID              int64           `json:"id"`
	Title           string          `json:"title"`
	Type            string          `json:"type"`
	Description     string          `json:"description"`
	Rules           json.RawMessage `json:"rules"`
	StartsAt        time.Time       `json:"starts_at"`
	EndsAt          time.Time       `json:"ends_at"`
	RewardEnergy    int             `json:"reward_energy"`
	RewardMedalName *string         `json:"reward_medal_name,omitempty"`
	RewardMedal     *struct {
		Key  string `json:"key"`
		Name string `json:"name"`
	} `json:"reward_medal"`
	Completed    bool `json:"completed"`
	Participants int  `json:"participants"`
}

// Campaigns lists campaigns (activeOnly for the app).
func (s *Service) Campaigns(ctx context.Context, user int64, activeOnly bool) ([]Campaign, error) {
	rows, err := s.Pool.Query(ctx, `SELECT c.id, c.title, c.type, c.description, c.rules, c.starts_at, c.ends_at, c.reward_energy, c.reward_medal_name,
			EXISTS (SELECT 1 FROM campaign_completions x WHERE x.campaign_id=c.id AND x.user_id=$1),
			(SELECT count(*) FROM campaign_completions x WHERE x.campaign_id=c.id)
		FROM campaigns c WHERE ($2 = false OR (c.starts_at <= now() AND c.ends_at > now())) ORDER BY c.starts_at DESC LIMIT 200`, user, activeOnly)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Campaign, error) {
		var c Campaign
		var rules []byte
		err := r.Scan(&c.ID, &c.Title, &c.Type, &c.Description, &rules, &c.StartsAt, &c.EndsAt, &c.RewardEnergy, &c.RewardMedalName, &c.Completed, &c.Participants)
		c.Rules = rules
		if c.RewardMedalName != nil && *c.RewardMedalName != "" {
			c.RewardMedal = &struct {
				Key  string `json:"key"`
				Name string `json:"name"`
			}{"campaign:" + *c.RewardMedalName, *c.RewardMedalName}
		}
		return c, err
	})
	if out == nil {
		out = []Campaign{}
	}
	return out, err
}

// RouteView is an orienteering route.
type RouteView struct {
	ID           int64            `json:"id"`
	Name         string           `json:"name"`
	Description  string           `json:"description"`
	RewardEnergy int              `json:"reward_energy"`
	StartsAt     time.Time        `json:"starts_at"`
	EndsAt       time.Time        `json:"ends_at"`
	Checkpoints  []CheckpointView `json:"checkpoints"`
	Completed    bool             `json:"completed"`
	CompletedAt  *time.Time       `json:"completed_at"`
	Finishers    int              `json:"finishers"`
}

// CheckpointView is a point with the viewer's state.
type CheckpointView struct {
	Index   int     `json:"index"`
	Name    string  `json:"name"`
	Center  LatLng  `json:"center"`
	RadiusM float64 `json:"radius_m"`
	State   string  `json:"state"`
}

func (s *Service) routes(ctx context.Context, user int64, where string, args ...any) ([]RouteView, error) {
	rows, err := s.Pool.Query(ctx, `SELECT r.id, r.name, r.description, r.reward_energy, r.starts_at, r.ends_at, r.checkpoints,
			COALESCE(p.next_index,0), p.completed_at, (SELECT count(*) FROM route_progress x WHERE x.route_id=r.id AND x.completed_at IS NOT NULL)
		FROM routes r LEFT JOIN route_progress p ON p.route_id=r.id AND p.user_id=$1 WHERE `+where+` ORDER BY r.starts_at DESC`, append([]any{user}, args...)...)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (RouteView, error) {
		var v RouteView
		var raw []byte
		var next int
		err := r.Scan(&v.ID, &v.Name, &v.Description, &v.RewardEnergy, &v.StartsAt, &v.EndsAt, &raw, &next, &v.CompletedAt, &v.Finishers)
		var cps []Checkpoint
		_ = json.Unmarshal(raw, &cps)
		v.Completed = v.CompletedAt != nil
		for i, c := range cps {
			st := "todo"
			switch {
			case i < next || v.Completed:
				st = "done"
			case i == next:
				st = "next"
			}
			v.Checkpoints = append(v.Checkpoints, CheckpointView{Index: i, Name: c.Name, Center: LatLng{c.Lat, c.Lng}, RadiusM: c.RadiusM, State: st})
		}
		return v, err
	})
	if out == nil {
		out = []RouteView{}
	}
	return out, err
}

// Routes lists active routes for a user (user 0 = admin, all routes).
func (s *Service) Routes(ctx context.Context, user int64) ([]RouteView, error) {
	if user == 0 {
		return s.routes(ctx, 0, `TRUE`)
	}
	return s.routes(ctx, user, `r.starts_at <= now() AND r.ends_at > now()`)
}

// ---------------------------------------------------------------- app handler

// Handler serves the app endpoints.
type Handler struct {
	Svc    *Service
	Medals func(ctx context.Context, user int64) (any, error)
}

// Routes registers /v1 endpoints.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /v1/map/objects", auth(h.objects))
	mux.Handle("GET /v1/bosses/{id}", auth(h.boss))
	mux.Handle("POST /v1/bosses/{id}/strike", auth(h.strike))
	mux.Handle("POST /v1/bosses/{id}/engage", auth(h.engage))
	mux.Handle("POST /v1/chests/{id}/open", auth(h.openChest))
	mux.Handle("GET /v1/season", auth(h.season))
	mux.Handle("GET /v1/league", auth(h.league))
	mux.Handle("GET /v1/campaigns", auth(h.campaigns))
	mux.Handle("GET /v1/routes", auth(h.routesList))
	mux.Handle("GET /v1/routes/{id}", auth(h.route))
	mux.Handle("POST /v1/codex/companions/{key}/feed", auth(h.feed))
	mux.Handle("POST /v1/crews/{id}/relays", auth(h.startRelay))
	mux.Handle("GET /v1/crews/{id}/relays/current", auth(h.relay))
}

type point struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

func (h *Handler) objects(w http.ResponseWriter, r *http.Request) error {
	b, err := territory.ParseBBox(r.URL.Query().Get("bbox"))
	if err != nil {
		return err
	}
	o, err := h.Svc.Objects(r.Context(), b, httpx.UserID(r.Context()))
	if err != nil {
		return err
	}
	return httpx.OK(w, o)
}

func (h *Handler) boss(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	v, err := h.Svc.Get(r.Context(), id, httpx.UserID(r.Context()))
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *Handler) strike(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var p point
	if err := httpx.Decode(r, &p); err != nil {
		return err
	}
	res, err := h.Svc.Strike(r.Context(), httpx.UserID(r.Context()), id, p.Lat, p.Lng)
	if err != nil {
		return err
	}
	return httpx.OK(w, res)
}

func (h *Handler) engage(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var p point
	if err := httpx.Decode(r, &p); err != nil {
		return err
	}
	until, err := h.Svc.Engage(r.Context(), httpx.UserID(r.Context()), id, p.Lat, p.Lng)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]time.Time{"engaged_until": until})
}

func (h *Handler) openChest(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var p point
	if err := httpx.Decode(r, &p); err != nil {
		return err
	}
	e, bonus, err := h.Svc.OpenChest(r.Context(), httpx.UserID(r.Context()), id, p.Lat, p.Lng)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"energy": e, "bonus": bonus})
}

func (h *Handler) season(w http.ResponseWriter, r *http.Request) error {
	uid := httpx.UserID(r.Context())
	medals, err := h.Medals(r.Context(), uid)
	if err != nil {
		return err
	}
	v, err := h.Svc.GetSeason(r.Context(), uid, medals)
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *Handler) league(w http.ResponseWriter, r *http.Request) error {
	v, err := h.Svc.League(r.Context(), httpx.UserID(r.Context()), r.URL.Query().Get("district"), time.Time{})
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *Handler) campaigns(w http.ResponseWriter, r *http.Request) error {
	items, err := h.Svc.Campaigns(r.Context(), httpx.UserID(r.Context()), true)
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *Handler) routesList(w http.ResponseWriter, r *http.Request) error {
	items, err := h.Svc.Routes(r.Context(), httpx.UserID(r.Context()))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *Handler) route(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	items, err := h.Svc.routes(r.Context(), httpx.UserID(r.Context()), `r.id=$2`, id)
	if err != nil {
		return err
	}
	if len(items) == 0 {
		return httpx.NotFound("路线")
	}
	return httpx.OK(w, items[0])
}

func (h *Handler) feed(w http.ResponseWriter, r *http.Request) error {
	uid := httpx.UserID(r.Context())
	if err := h.Svc.Feed(r.Context(), uid, r.PathValue("key")); err != nil {
		return err
	}
	v, err := codex.Load(r.Context(), h.Svc.Pool, h.Svc.Config.For(uid), uid)
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *Handler) startRelay(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Legs  int     `json:"legs"`
		LegKm float64 `json:"leg_km"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	rel, err := h.Svc.StartRelay(r.Context(), httpx.UserID(r.Context()), id, req.Legs, req.LegKm)
	if err != nil {
		return err
	}
	return httpx.OK(w, rel)
}

func (h *Handler) relay(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	rel, err := h.Svc.CurrentRelay(r.Context(), id)
	if err != nil {
		return err
	}
	if rel == nil {
		return httpx.OK(w, nil)
	}
	return httpx.OK(w, rel)
}

// ---------------------------------------------------------------- admin

// AdminHandler serves the /admin/v1 gameplay operations.
type AdminHandler struct {
	Svc   *Service
	Audit func(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error
}

// Routes registers the endpoints; ops is the admin+ops guard.
func (h *AdminHandler) Routes(mux *http.ServeMux, ops func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /admin/v1/map/objects", ops(h.objects))
	mux.Handle("GET /admin/v1/bosses", ops(h.bosses))
	mux.Handle("POST /admin/v1/bosses", ops(h.spawn))
	mux.Handle("GET /admin/v1/bosses/{id}", ops(h.boss))
	mux.Handle("POST /admin/v1/bosses/{id}/end", ops(h.endBoss))
	mux.Handle("GET /admin/v1/chests", ops(h.chests))
	mux.Handle("POST /admin/v1/chests", ops(h.placeChest))
	mux.Handle("POST /admin/v1/chests/scatter", ops(h.scatter))
	mux.Handle("DELETE /admin/v1/chests/{id}", ops(h.removeChest))
	mux.Handle("GET /admin/v1/seasons", ops(h.seasons))
	mux.Handle("POST /admin/v1/seasons", ops(h.createSeason))
	mux.Handle("PATCH /admin/v1/seasons/{id}", ops(h.patchSeason))
	mux.Handle("POST /admin/v1/seasons/{id}/settle", ops(h.settleSeason))
	mux.Handle("GET /admin/v1/campaigns", ops(h.campaignsList))
	mux.Handle("POST /admin/v1/campaigns", ops(h.createCampaign))
	mux.Handle("PATCH /admin/v1/campaigns/{id}", ops(h.patchCampaign))
	mux.Handle("DELETE /admin/v1/campaigns/{id}", ops(h.deleteCampaign))
	mux.Handle("GET /admin/v1/routes", ops(h.routesList))
	mux.Handle("POST /admin/v1/routes", ops(h.createRoute))
	mux.Handle("PATCH /admin/v1/routes/{id}", ops(h.patchRoute))
	mux.Handle("DELETE /admin/v1/routes/{id}", ops(h.deleteRoute))
	mux.Handle("GET /admin/v1/league", ops(h.league))
}

func (h *AdminHandler) audit(r *http.Request, action, target string, detail map[string]any) error {
	return h.Audit(r.Context(), h.Svc.Pool, action, target, detail)
}

func (h *AdminHandler) objects(w http.ResponseWriter, r *http.Request) error {
	b, err := territory.ParseBBox(r.URL.Query().Get("bbox"))
	if err != nil {
		return err
	}
	o, err := h.Svc.Objects(r.Context(), b, 0)
	if err != nil {
		return err
	}
	return httpx.OK(w, o)
}

func (h *AdminHandler) bosses(w http.ResponseWriter, r *http.Request) error {
	items, total, err := h.Svc.List(r.Context(), r.URL.Query().Get("status"), httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) spawn(w http.ResponseWriter, r *http.Request) error {
	var in SpawnInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	ad, _ := httpx.AdminFrom(r.Context())
	id, err := h.Svc.Spawn(r.Context(), in, ad.ID)
	if err != nil {
		return err
	}
	if err := h.audit(r, "boss.spawn", "boss:"+itoa(id), map[string]any{"input": in}); err != nil {
		return err
	}
	v, err := h.Svc.Get(r.Context(), id, 0)
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *AdminHandler) boss(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	v, err := h.Svc.Get(r.Context(), id, 0)
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *AdminHandler) endBoss(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	if err := h.Svc.Expire(r.Context(), id); err != nil {
		return err
	}
	if err := h.audit(r, "boss.end", "boss:"+itoa(id), nil); err != nil {
		return err
	}
	return h.boss(w, r)
}

func (h *AdminHandler) chests(w http.ResponseWriter, r *http.Request) error {
	p := httpx.GetPage(r)
	where := map[string]string{
		"active":  `c.expires_at > now() AND c.removed_at IS NULL`,
		"expired": `(c.expires_at <= now() OR c.removed_at IS NOT NULL)`,
	}[r.URL.Query().Get("status")]
	if where == "" {
		where = "TRUE"
	}
	var total int
	if err := h.Svc.Pool.QueryRow(r.Context(), `SELECT count(*) FROM chests c WHERE `+where).Scan(&total); err != nil {
		return err
	}
	rows, err := h.Svc.Pool.Query(r.Context(), `SELECT c.id, ST_Y(c.center), ST_X(c.center), c.radius_m, c.expires_at, c.energy_min, c.energy_max,
			(SELECT count(*) FROM chest_opens o WHERE o.chest_id=c.id), c.source,
			CASE WHEN c.removed_at IS NOT NULL THEN 'removed' WHEN c.expires_at <= now() THEN 'expired' ELSE 'active' END
		FROM chests c WHERE `+where+` ORDER BY c.id DESC LIMIT $1 OFFSET $2`, p.Size, p.Offset())
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (ChestView, error) {
		var c ChestView
		var opens int
		err := row.Scan(&c.ID, &c.Center.Lat, &c.Center.Lng, &c.RadiusM, &c.ExpiresAt, &c.EnergyMin, &c.EnergyMax, &opens, &c.Source, &c.Status)
		c.Opens = &opens
		return c, err
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) placeChest(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Lat       float64 `json:"lat"`
		Lng       float64 `json:"lng"`
		EnergyMin int     `json:"energy_min"`
		EnergyMax int     `json:"energy_max"`
		DurationH float64 `json:"duration_h"`
		RadiusM   float64 `json:"radius_m"`
	}
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	ad, _ := httpx.AdminFrom(r.Context())
	id, err := h.Svc.PlaceChest(r.Context(), in.Lat, in.Lng, in.EnergyMin, in.EnergyMax, in.DurationH, in.RadiusM, "admin", ad.ID)
	if err != nil {
		return err
	}
	if err := h.audit(r, "chest.place", "chest:"+itoa(id), map[string]any{"input": in}); err != nil {
		return err
	}
	return httpx.OK(w, map[string]int64{"id": id})
}

func (h *AdminHandler) scatter(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		BBox      string  `json:"bbox"`
		Count     int     `json:"count"`
		DurationH float64 `json:"duration_h"`
	}
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	b, err := territory.ParseBBox(in.BBox)
	if err != nil {
		return err
	}
	if in.Count <= 0 || in.Count > 200 {
		return httpx.BadRequest("invalid_body", "数量 1–200")
	}
	ad, _ := httpx.AdminFrom(r.Context())
	n, err := h.Svc.Scatter(r.Context(), &b, in.Count, in.DurationH, "admin", ad.ID)
	if err != nil {
		return err
	}
	if err := h.audit(r, "chest.scatter", "chests", map[string]any{"bbox": in.BBox, "placed": n}); err != nil {
		return err
	}
	return httpx.OK(w, map[string]int{"placed": n})
}

func (h *AdminHandler) removeChest(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	if _, err := h.Svc.Pool.Exec(r.Context(), `UPDATE chests SET removed_at=now() WHERE id=$1 AND removed_at IS NULL`, id); err != nil {
		return err
	}
	if err := h.audit(r, "chest.remove", "chest:"+itoa(id), nil); err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

func (h *AdminHandler) seasons(w http.ResponseWriter, r *http.Request) error {
	rows, err := h.Svc.Pool.Query(r.Context(), `SELECT id, name, starts_at, ends_at, settled_at FROM seasons ORDER BY starts_at DESC`)
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Season, error) {
		var s Season
		err := row.Scan(&s.ID, &s.Name, &s.StartsAt, &s.EndsAt, &s.SettledAt)
		if d := time.Until(s.EndsAt).Hours() / 24; d > 0 {
			s.DaysLeft = int(d + 0.999)
		}
		return s, err
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *AdminHandler) createSeason(w http.ResponseWriter, r *http.Request) error {
	var in SeasonInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	if err := in.validate(); err != nil {
		return err
	}
	var id int64
	err := h.Svc.Pool.QueryRow(r.Context(), `INSERT INTO seasons (name, starts_at, ends_at) VALUES ($1,$2,$3) RETURNING id`, in.Name, in.StartsAt, in.EndsAt).Scan(&id)
	if err := overlapErr(err); err != nil {
		return err
	}
	if err := h.audit(r, "season.create", "season:"+itoa(id), map[string]any{"input": in}); err != nil {
		return err
	}
	return h.seasons(w, r)
}

func (h *AdminHandler) patchSeason(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in SeasonInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	if err := in.validate(); err != nil {
		return err
	}
	tag, err := h.Svc.Pool.Exec(r.Context(), `UPDATE seasons SET name=$2, starts_at=$3, ends_at=$4 WHERE id=$1 AND settled_at IS NULL`, id, in.Name, in.StartsAt, in.EndsAt)
	if err := overlapErr(err); err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return httpx.Conflict("season_settled", "赛季不存在或已结算，不能修改")
	}
	if err := h.audit(r, "season.update", "season:"+itoa(id), map[string]any{"input": in}); err != nil {
		return err
	}
	return h.seasons(w, r)
}

func (h *AdminHandler) settleSeason(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	if err := h.Svc.SettleSeasons(r.Context(), id); err != nil {
		return err
	}
	if err := h.audit(r, "season.settle", "season:"+itoa(id), nil); err != nil {
		return err
	}
	return h.seasons(w, r)
}

type campaignInput struct {
	Title           string          `json:"title"`
	Type            string          `json:"type"`
	Description     string          `json:"description"`
	Rules           json.RawMessage `json:"rules"`
	StartsAt        time.Time       `json:"starts_at"`
	EndsAt          time.Time       `json:"ends_at"`
	RewardEnergy    int             `json:"reward_energy"`
	RewardMedalName *string         `json:"reward_medal_name"`
}

func (in campaignInput) validate() error {
	if strings.TrimSpace(in.Title) == "" || !in.EndsAt.After(in.StartsAt) || in.RewardEnergy < 0 || in.RewardEnergy > 10000 {
		return httpx.BadRequest("invalid_body", "请填写标题、合法的起止时间和奖励")
	}
	var r CampaignRules
	if err := json.Unmarshal(in.Rules, &r); err != nil {
		return httpx.BadRequest("invalid_body", "rules 格式错误")
	}
	switch in.Type {
	case "pace":
		if r.MaxPaceSPerKm <= 0 || r.MinDistanceKm <= 0 {
			return httpx.BadRequest("invalid_body", "配速挑战需要最低距离和最慢配速")
		}
	case "night_run":
		if r.StartHourFrom == nil || r.StartHourTo == nil || *r.StartHourFrom < 0 || *r.StartHourTo > 23 || *r.StartHourFrom >= *r.StartHourTo {
			return httpx.BadRequest("invalid_body", "夜跑专场需要开始时段（时，0–23，不跨零点）")
		}
	case "distance":
		if r.MinDistanceKm <= 0 {
			return httpx.BadRequest("invalid_body", "距离挑战需要最低距离")
		}
	default:
		return httpx.BadRequest("invalid_body", "type 取值 pace / night_run / distance")
	}
	return nil
}

func (h *AdminHandler) campaignsList(w http.ResponseWriter, r *http.Request) error {
	items, err := h.Svc.Campaigns(r.Context(), 0, false)
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *AdminHandler) createCampaign(w http.ResponseWriter, r *http.Request) error {
	var in campaignInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	if err := in.validate(); err != nil {
		return err
	}
	ad, _ := httpx.AdminFrom(r.Context())
	var id int64
	if err := h.Svc.Pool.QueryRow(r.Context(), `INSERT INTO campaigns (title, type, description, rules, starts_at, ends_at, reward_energy, reward_medal_name, created_by)
		VALUES ($1,$2,$3,$4,$5,$6,$7,NULLIF($8,''),$9) RETURNING id`, in.Title, in.Type, in.Description, []byte(in.Rules), in.StartsAt, in.EndsAt,
		in.RewardEnergy, deref(in.RewardMedalName), ad.ID).Scan(&id); err != nil {
		return err
	}
	if err := h.audit(r, "campaign.create", "campaign:"+itoa(id), map[string]any{"title": in.Title}); err != nil {
		return err
	}
	return h.campaignsList(w, r)
}

func (h *AdminHandler) patchCampaign(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in campaignInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	if err := in.validate(); err != nil {
		return err
	}
	tag, err := h.Svc.Pool.Exec(r.Context(), `UPDATE campaigns SET title=$2, type=$3, description=$4, rules=$5, starts_at=$6, ends_at=$7, reward_energy=$8,
		reward_medal_name=NULLIF($9,'') WHERE id=$1`, id, in.Title, in.Type, in.Description, []byte(in.Rules), in.StartsAt, in.EndsAt, in.RewardEnergy, deref(in.RewardMedalName))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return httpx.NotFound("活动")
	}
	if err := h.audit(r, "campaign.update", "campaign:"+itoa(id), map[string]any{"title": in.Title}); err != nil {
		return err
	}
	return h.campaignsList(w, r)
}

func (h *AdminHandler) deleteCampaign(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	tag, err := h.Svc.Pool.Exec(r.Context(), `DELETE FROM campaigns WHERE id=$1 AND starts_at > now()`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return httpx.Conflict("campaign_started", "活动不存在或已经开始，不能删除")
	}
	if err := h.audit(r, "campaign.delete", "campaign:"+itoa(id), nil); err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

type routeInput struct {
	Name         string       `json:"name"`
	Description  string       `json:"description"`
	Checkpoints  []Checkpoint `json:"checkpoints"`
	RewardEnergy int          `json:"reward_energy"`
	StartsAt     time.Time    `json:"starts_at"`
	EndsAt       time.Time    `json:"ends_at"`
}

func (in routeInput) validate() error {
	if utf8.RuneCountInString(strings.TrimSpace(in.Name)) == 0 || !in.EndsAt.After(in.StartsAt) || in.RewardEnergy < 0 {
		return httpx.BadRequest("invalid_body", "请填写名称、合法的起止时间和奖励")
	}
	if len(in.Checkpoints) < 2 || len(in.Checkpoints) > 12 {
		return httpx.BadRequest("invalid_body", "打卡点 2–12 个")
	}
	for i, c := range in.Checkpoints {
		if strings.TrimSpace(c.Name) == "" || c.Lat < -90 || c.Lat > 90 || c.Lng < -180 || c.Lng > 180 || c.RadiusM < 10 || c.RadiusM > 500 {
			return httpx.BadRequest("invalid_body", "第 "+itoa(int64(i+1))+" 个打卡点不合法（名称、坐标、半径 10–500 m）")
		}
	}
	return nil
}

func (h *AdminHandler) routesList(w http.ResponseWriter, r *http.Request) error {
	items, err := h.Svc.Routes(r.Context(), 0)
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *AdminHandler) createRoute(w http.ResponseWriter, r *http.Request) error {
	var in routeInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	if err := in.validate(); err != nil {
		return err
	}
	cps, _ := json.Marshal(in.Checkpoints)
	ad, _ := httpx.AdminFrom(r.Context())
	var id int64
	if err := h.Svc.Pool.QueryRow(r.Context(), `INSERT INTO routes (name, description, checkpoints, reward_energy, starts_at, ends_at, created_by)
		VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`, in.Name, in.Description, cps, in.RewardEnergy, in.StartsAt, in.EndsAt, ad.ID).Scan(&id); err != nil {
		return err
	}
	if err := h.audit(r, "route.create", "route:"+itoa(id), map[string]any{"name": in.Name}); err != nil {
		return err
	}
	return h.routesList(w, r)
}

func (h *AdminHandler) patchRoute(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in routeInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	if err := in.validate(); err != nil {
		return err
	}
	cps, _ := json.Marshal(in.Checkpoints)
	tag, err := h.Svc.Pool.Exec(r.Context(), `UPDATE routes SET name=$2, description=$3, checkpoints=$4, reward_energy=$5, starts_at=$6, ends_at=$7 WHERE id=$1`,
		id, in.Name, in.Description, cps, in.RewardEnergy, in.StartsAt, in.EndsAt)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return httpx.NotFound("路线")
	}
	// Changing the points invalidates partial progress.
	if _, err := h.Svc.Pool.Exec(r.Context(), `UPDATE route_progress SET next_index=0 WHERE route_id=$1 AND completed_at IS NULL`, id); err != nil {
		return err
	}
	if err := h.audit(r, "route.update", "route:"+itoa(id), map[string]any{"name": in.Name}); err != nil {
		return err
	}
	return h.routesList(w, r)
}

func (h *AdminHandler) deleteRoute(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	tag, err := h.Svc.Pool.Exec(r.Context(), `DELETE FROM routes WHERE id=$1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return httpx.NotFound("路线")
	}
	if err := h.audit(r, "route.delete", "route:"+itoa(id), nil); err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

func (h *AdminHandler) league(w http.ResponseWriter, r *http.Request) error {
	var week time.Time
	if ws := r.URL.Query().Get("week_start"); ws != "" {
		t, err := time.ParseInLocation("2006-01-02", ws, time.UTC)
		if err != nil {
			return httpx.BadRequest("invalid_body", "week_start 格式 YYYY-MM-DD")
		}
		week = weekStart(t.Add(12 * time.Hour))
	}
	district := r.URL.Query().Get("district")
	if district == "" {
		return httpx.BadRequest("invalid_body", "请选择城区")
	}
	v, err := h.Svc.League(r.Context(), 0, district, week)
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func itoa(n int64) string { return strconvItoa(n) }

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
