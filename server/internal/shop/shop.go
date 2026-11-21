// Package shop is the 能量商城 (E-05, docs/api/v2-4-本地生活与商户.md):
// territory skins, avatar frames and map markers bought with energy only,
// equipped one per type. It is a leaf package: the profile, community and
// territory modules import its SQL helpers to show what a user equipped.
package shop

import (
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Item types.
const (
	TerritorySkin = "territory_skin"
	AvatarFrame   = "avatar_frame"
	MapMarker     = "map_marker"
)

// Types lists the item types.
var Types = []string{TerritorySkin, AvatarFrame, MapMarker}

func validType(t string) bool { return t == TerritorySkin || t == AvatarFrame || t == MapMarker }

// LedgerReason is the energy ledger reason of a purchase.
const LedgerReason = "shop"

// equippedKeySQL is a scalar subquery: the key of the item of type typ the
// user (SQL expression userCol) has equipped, or NULL.
func equippedKeySQL(userCol, typ string) string {
	return `(SELECT si.item_key FROM src.src_ply_loop_user_item ui JOIN src.src_ply_loop_shop_item si ON si.id=ui.item_id
		WHERE ui.user_id=` + userCol + ` AND ui.item_type='` + typ + `' AND ui.is_equipped)`
}

// FrameSQL selects the equipped avatar frame key (text, NULL when none) of
// the user in userCol, for UserBrief.avatar_frame.
func FrameSQL(userCol string) string { return equippedKeySQL(userCol, AvatarFrame) }

// SkinSQL selects the equipped territory skin of the user in userCol as
// jsonb {"key","fill","stroke","pattern"} (NULL when none); scan it into
// []byte and decode with ParseSkin.
func SkinSQL(userCol string) string {
	return `(SELECT jsonb_build_object('key', si.item_key, 'fill', si.preview_json->>'fill', 'stroke', si.preview_json->>'stroke',
			'pattern', si.preview_json->>'pattern')
		FROM src.src_ply_loop_user_item ui JOIN src.src_ply_loop_shop_item si ON si.id=ui.item_id
		WHERE ui.user_id=` + userCol + ` AND ui.item_type='` + TerritorySkin + `' AND ui.is_equipped)`
}

// Skin is a territory's look (领地对象的 skin).
type Skin struct {
	Key     string  `json:"key"`
	Fill    *string `json:"fill"`
	Stroke  *string `json:"stroke"`
	Pattern *string `json:"pattern"`
}

// ParseSkin decodes a SkinSQL value (nil for none).
func ParseSkin(raw []byte) *Skin {
	if len(raw) == 0 {
		return nil
	}
	var s Skin
	if json.Unmarshal(raw, &s) != nil || s.Key == "" {
		return nil
	}
	return &s
}

// Equipped is GET /v1/me «equipped»: the key per type, null when none.
type Equipped struct {
	TerritorySkin *string `json:"territory_skin"`
	AvatarFrame   *string `json:"avatar_frame"`
	MapMarker     *string `json:"map_marker"`
}

// LoadEquipped returns what the user has equipped.
func LoadEquipped(ctx context.Context, q db.Querier, user int64) (Equipped, error) {
	var e Equipped
	err := q.QueryRow(ctx, `SELECT `+equippedKeySQL("$1", TerritorySkin)+`, `+equippedKeySQL("$1", AvatarFrame)+`, `+equippedKeySQL("$1", MapMarker),
		user).Scan(&e.TerritorySkin, &e.AvatarFrame, &e.MapMarker)
	return e, err
}

// Item is ShopItem.
type Item struct {
	Key          string          `json:"key"`
	Name         string          `json:"name"`
	Type         string          `json:"type"`
	PriceEnergy  int             `json:"price_energy"`
	ImageURL     *string         `json:"image_url"`
	Preview      json.RawMessage `json:"preview"`
	Description  string          `json:"description"`
	Owned        bool            `json:"owned"`
	Equipped     bool            `json:"equipped"`
	LimitedUntil *time.Time      `json:"limited_until"`
	// Admin only.
	OnSale *bool `json:"on_sale,omitempty"`
	Sort   *int  `json:"sort,omitempty"`

	id int64
}

const itemCols = `si.id, si.item_key, si.item_name, si.item_type, si.price_energy_qty, si.image_url, si.preview_json, si.description,
	si.limited_end_time, si.is_on_sale, si.sort_no,
	ui.user_id IS NOT NULL, COALESCE(ui.is_equipped, false)`

func scanItem(r pgx.Row, admin bool) (Item, error) {
	var it Item
	var onSale bool
	var sort int
	var preview []byte
	err := r.Scan(&it.id, &it.Key, &it.Name, &it.Type, &it.PriceEnergy, &it.ImageURL, &preview, &it.Description, &it.LimitedUntil, &onSale, &sort,
		&it.Owned, &it.Equipped)
	it.Preview = json.RawMessage(preview)
	if len(preview) == 0 {
		it.Preview = json.RawMessage(`{}`)
	}
	if admin {
		it.OnSale, it.Sort = &onSale, &sort
	}
	return it, err
}

// Service runs the shop.
type Service struct {
	Pool *pgxpool.Pool
}

// List returns the catalogue for a user: items on sale (and within their
// limited window) plus everything the user owns.
func (s *Service) List(ctx context.Context, user int64, typ string) ([]Item, int, error) {
	rows, err := s.Pool.Query(ctx, `SELECT `+itemCols+` FROM src.src_ply_loop_shop_item si
		LEFT JOIN src.src_ply_loop_user_item ui ON ui.item_id=si.id AND ui.user_id=$1
		WHERE ($2 = '' OR si.item_type=$2)
		  AND (ui.user_id IS NOT NULL OR (si.is_on_sale AND (si.limited_end_time IS NULL OR si.limited_end_time > now())))
		ORDER BY si.sort_no, si.id`, user, typ)
	if err != nil {
		return nil, 0, err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Item, error) { return scanItem(r, false) })
	if err != nil {
		return nil, 0, err
	}
	if items == nil {
		items = []Item{}
	}
	var energy int
	err = s.Pool.QueryRow(ctx, `SELECT energy FROM src.src_usr_loop_user WHERE id=$1`, user).Scan(&energy)
	return items, energy, err
}

func (s *Service) item(ctx context.Context, q db.Querier, user int64, key string) (Item, error) {
	it, err := scanItem(q.QueryRow(ctx, `SELECT `+itemCols+` FROM src.src_ply_loop_shop_item si
		LEFT JOIN src.src_ply_loop_user_item ui ON ui.item_id=si.id AND ui.user_id=$1 WHERE si.item_key=$2`, user, key), false)
	if db.IsNoRows(err) {
		return it, httpx.NotFound("商品")
	}
	return it, err
}

// Buy exchanges energy for an item (能量只能运动获得：没有任何付费入口).
func (s *Service) Buy(ctx context.Context, user int64, key string) (Item, int, error) {
	var out Item
	var left int
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		it, err := s.item(ctx, tx, user, key)
		if err != nil {
			return err
		}
		if it.Owned {
			return httpx.Conflict("already_owned", "你已经拥有这件装扮了")
		}
		var onSale bool
		if err := tx.QueryRow(ctx, `SELECT is_on_sale AND (limited_end_time IS NULL OR limited_end_time > now()) FROM src.src_ply_loop_shop_item WHERE id=$1`,
			it.id).Scan(&onSale); err != nil {
			return err
		}
		if !onSale {
			return httpx.Conflict("item_unavailable", "这件商品已下架")
		}
		var have int
		if err := tx.QueryRow(ctx, `SELECT energy FROM src.src_usr_loop_user WHERE id=$1 FOR UPDATE`, user).Scan(&have); err != nil {
			return err
		}
		if have < it.PriceEnergy {
			return httpx.E(http.StatusConflict, "not_enough_energy", "能量不足：需要 %d，当前 %d", it.PriceEnergy, have)
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET energy = energy - $2 WHERE id=$1`, user, it.PriceEnergy); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_loop_energy_ledger (user_id, ledger_date, delta, reason, ref_id) VALUES ($1,$2,$3,$4,$5)`,
			user, clock.Today(), -it.PriceEnergy, LedgerReason, it.id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_loop_user_item (user_id, item_id, item_type, price_energy_qty) VALUES ($1,$2,$3,$4)`,
			user, it.id, it.Type, it.PriceEnergy); err != nil {
			return err
		}
		left = have - it.PriceEnergy
		out, err = s.item(ctx, tx, user, key)
		return err
	})
	return out, left, err
}

// Equip wears an owned item (on=false takes it off). Only one item per type
// is equipped at a time.
func (s *Service) Equip(ctx context.Context, user int64, key string, on bool) (Item, error) {
	var out Item
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		it, err := s.item(ctx, tx, user, key)
		if err != nil {
			return err
		}
		if !it.Owned {
			return httpx.Conflict("not_owned", "先兑换才能装备")
		}
		if on {
			if _, err := tx.Exec(ctx, `UPDATE src.src_ply_loop_user_item SET is_equipped=false, update_time=now()
				WHERE user_id=$1 AND item_type=$2 AND is_equipped AND item_id<>$3`, user, it.Type, it.id); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_ply_loop_user_item SET is_equipped=$3, update_time=now() WHERE user_id=$1 AND item_id=$2`,
			user, it.id, on); err != nil {
			return err
		}
		out, err = s.item(ctx, tx, user, key)
		return err
	})
	return out, err
}

// ---------------------------------------------------------------- handlers

// Handler serves /v1/shop.
type Handler struct{ Svc *Service }

// Routes registers the app endpoints.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /v1/shop/items", auth(h.list))
	mux.Handle("POST /v1/shop/items/{key}/buy", auth(h.buy))
	mux.Handle("POST /v1/shop/items/{key}/equip", auth(h.equip(true)))
	mux.Handle("DELETE /v1/shop/items/{key}/equip", auth(h.equip(false)))
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) error {
	typ := r.URL.Query().Get("type")
	if typ != "" && !validType(typ) {
		return httpx.BadRequest("invalid_type", "type 只能是 territory_skin / avatar_frame / map_marker")
	}
	items, energy, err := h.Svc.List(r.Context(), httpx.UserID(r.Context()), typ)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"items": items, "energy": energy})
}

func (h *Handler) buy(w http.ResponseWriter, r *http.Request) error {
	it, left, err := h.Svc.Buy(r.Context(), httpx.UserID(r.Context()), r.PathValue("key"))
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"item": it, "energy": left})
}

func (h *Handler) equip(on bool) httpx.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		it, err := h.Svc.Equip(r.Context(), httpx.UserID(r.Context()), r.PathValue("key"), on)
		if err != nil {
			return err
		}
		return httpx.OK(w, it)
	}
}

// AdminHandler serves /admin/v1/shop.
type AdminHandler struct {
	Svc   *Service
	Audit func(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error
}

// Routes registers the admin endpoints; ops is the admin+ops guard.
func (h *AdminHandler) Routes(mux *http.ServeMux, ops func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /admin/v1/shop/items", ops(h.items))
	mux.Handle("POST /admin/v1/shop/items", ops(h.create))
	mux.Handle("PATCH /admin/v1/shop/items/{key}", ops(h.patch))
	mux.Handle("GET /admin/v1/shop/stats", ops(h.stats))
}

// ItemInput is the admin create / update body.
type ItemInput struct {
	Key          string          `json:"key"`
	Name         string          `json:"name"`
	Type         string          `json:"type"`
	PriceEnergy  int             `json:"price_energy"`
	ImageURL     *string         `json:"image_url"`
	Preview      json.RawMessage `json:"preview"`
	Description  string          `json:"description"`
	OnSale       *bool           `json:"on_sale"`
	LimitedUntil *time.Time      `json:"limited_until"`
	Sort         int             `json:"sort"`
}

var keyRe = regexp.MustCompile(`^[a-z0-9_]{2,40}$`)

func (in *ItemInput) validate() error {
	in.Name = strings.TrimSpace(in.Name)
	switch {
	case !keyRe.MatchString(in.Key):
		return httpx.BadRequest("invalid_body", "key 只能是 2-40 位小写字母、数字和下划线")
	case in.Name == "":
		return httpx.BadRequest("invalid_body", "名称不能为空")
	case !validType(in.Type):
		return httpx.BadRequest("invalid_body", "type 只能是 territory_skin / avatar_frame / map_marker")
	case in.PriceEnergy <= 0:
		return httpx.BadRequest("invalid_body", "价格必须大于 0 能量")
	}
	if len(in.Preview) == 0 || string(in.Preview) == "null" {
		in.Preview = json.RawMessage(`{}`)
	}
	var m map[string]any
	if json.Unmarshal(in.Preview, &m) != nil {
		return httpx.BadRequest("invalid_body", "preview 必须是对象")
	}
	return nil
}

func (h *AdminHandler) audit(r *http.Request, action, target string, detail map[string]any) error {
	return h.Audit(r.Context(), h.Svc.Pool, action, target, detail)
}

func (h *AdminHandler) adminItem(ctx context.Context, key string) (Item, error) {
	it, err := scanItem(h.Svc.Pool.QueryRow(ctx, `SELECT `+itemCols+` FROM src.src_ply_loop_shop_item si
		LEFT JOIN src.src_ply_loop_user_item ui ON false WHERE si.item_key=$1`, key), true)
	if db.IsNoRows(err) {
		return it, httpx.NotFound("商品")
	}
	return it, err
}

func (h *AdminHandler) items(w http.ResponseWriter, r *http.Request) error {
	typ := r.URL.Query().Get("type")
	rows, err := h.Svc.Pool.Query(r.Context(), `SELECT `+itemCols+` FROM src.src_ply_loop_shop_item si
		LEFT JOIN src.src_ply_loop_user_item ui ON false WHERE ($1 = '' OR si.item_type=$1) ORDER BY si.sort_no, si.id`, typ)
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Item, error) { return scanItem(r, true) })
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *AdminHandler) create(w http.ResponseWriter, r *http.Request) error {
	var in ItemInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	if err := in.validate(); err != nil {
		return err
	}
	onSale := in.OnSale == nil || *in.OnSale
	err := pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		_, err := tx.Exec(r.Context(), `INSERT INTO src.src_ply_loop_shop_item (item_key, item_name, item_type, price_energy_qty, image_url, preview_json,
				description, is_on_sale, limited_end_time, sort_no) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
			in.Key, in.Name, in.Type, in.PriceEnergy, in.ImageURL, in.Preview, in.Description, onSale, in.LimitedUntil, in.Sort)
		if db.IsUniqueViolation(err) {
			return httpx.Conflict("key_taken", "商品标识已存在")
		}
		if err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, "shop.create", "shop_item:"+in.Key, map[string]any{"name": in.Name, "price_energy": in.PriceEnergy})
	})
	if err != nil {
		return err
	}
	it, err := h.adminItem(r.Context(), in.Key)
	if err != nil {
		return err
	}
	return httpx.OK(w, it)
}

func (h *AdminHandler) patch(w http.ResponseWriter, r *http.Request) error {
	key := r.PathValue("key")
	cur, err := h.adminItem(r.Context(), key)
	if err != nil {
		return err
	}
	in := ItemInput{Key: cur.Key, Name: cur.Name, Type: cur.Type, PriceEnergy: cur.PriceEnergy, ImageURL: cur.ImageURL, Preview: cur.Preview,
		Description: cur.Description, OnSale: cur.OnSale, LimitedUntil: cur.LimitedUntil, Sort: *cur.Sort}
	var raw map[string]json.RawMessage
	if err := httpx.Decode(r, &raw); err != nil {
		return err
	}
	b, _ := json.Marshal(raw)
	if err := json.Unmarshal(b, &in); err != nil {
		return httpx.BadRequest("invalid_body", "参数格式错误")
	}
	in.Key = cur.Key // the key is the item's identity
	if _, ok := raw["type"]; ok && in.Type != cur.Type {
		return httpx.BadRequest("invalid_body", "商品类型不能修改")
	}
	if err := in.validate(); err != nil {
		return err
	}
	err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(r.Context(), `UPDATE src.src_ply_loop_shop_item SET item_name=$2, price_energy_qty=$3, image_url=$4, preview_json=$5,
				description=$6, is_on_sale=$7, limited_end_time=$8, sort_no=$9, update_time=now() WHERE item_key=$1`,
			key, in.Name, in.PriceEnergy, in.ImageURL, in.Preview, in.Description, in.OnSale == nil || *in.OnSale, in.LimitedUntil, in.Sort); err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, "shop.update", "shop_item:"+key, map[string]any{"fields": keys(raw)})
	})
	if err != nil {
		return err
	}
	it, err := h.adminItem(r.Context(), key)
	if err != nil {
		return err
	}
	return httpx.OK(w, it)
}

func keys(m map[string]json.RawMessage) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// Stat is one item's exchange numbers.
type Stat struct {
	Key         string `json:"key"`
	Name        string `json:"name"`
	Type        string `json:"type"`
	Exchanged   int    `json:"redemptions"`
	EnergySpent int64  `json:"energy_spent"`
	Equipped    int    `json:"equipped"`
}

func (h *AdminHandler) stats(w http.ResponseWriter, r *http.Request) error {
	rows, err := h.Svc.Pool.Query(r.Context(), `SELECT si.item_key, si.item_name, si.item_type, count(ui.user_id)::int,
			COALESCE(sum(ui.price_energy_qty),0)::bigint, count(ui.user_id) FILTER (WHERE ui.is_equipped)::int
		FROM src.src_ply_loop_shop_item si LEFT JOIN src.src_ply_loop_user_item ui ON ui.item_id=si.id
		GROUP BY si.id ORDER BY si.sort_no, si.id`)
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, pgx.RowToStructByPos[Stat])
	if err != nil {
		return err
	}
	if items == nil {
		items = []Stat{}
	}
	var total Stat
	for _, s := range items {
		total.Exchanged += s.Exchanged
		total.EnergySpent += s.EnergySpent
	}
	return httpx.OK(w, map[string]any{"items": items, "total_redemptions": total.Exchanged, "total_energy_spent": total.EnergySpent})
}
