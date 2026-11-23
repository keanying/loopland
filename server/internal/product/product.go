// Package product is V2 batch 5 「商户商品与开放平台」 part A
// (docs/api/v2-5-商户商品与开放平台.md): merchant products (套餐券、代金券、
// 次卡) kept by the merchants themselves and reviewed before sale, product
// orders paid with WeChat Pay / Alipay that issue one coupon per unit,
// refunds of unused coupons, and official promotions (官方活动) built from
// products the merchants authorised or applied with.
package product

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/adminmsg"
	"github.com/keanying/loopland/server/internal/billing"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/venue"
	"github.com/keanying/loopland/server/internal/webhook"
)

// Service implements products, product orders and promotions.
type Service struct {
	Pool    *pgxpool.Pool
	Mod     *moderation.Moderator
	Billing *billing.Service
	Config  *gameplay.Store
	Log     *slog.Logger
	// Msg sends 管理端站内信 (review results, promotions, refunds).
	Msg *adminmsg.Notifier
}

// Ref is {id, name}.
type Ref struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// Actor is who changes a product: merchant staff (AdminID) or an open
// platform app (AppID), always on behalf of MerchantID.
type Actor struct {
	MerchantID int64
	AdminID    int64
	AppID      int64
}

// Types and statuses.
var (
	productTypes = map[string]bool{"package": true, "voucher": true, "pass": true}
	statuses     = map[string]bool{"draft": true, "reviewing": true, "on_sale": true, "off_sale": true, "rejected": true, "banned": true}
)

// Content is the reviewed part of a product.
type Content struct {
	Title       string   `json:"title"`
	Subtitle    string   `json:"subtitle"`
	Description string   `json:"description"`
	Images      []string `json:"images"`
	Rules       string   `json:"rules"`
}

func (c Content) equal(o Content) bool {
	return c.Title == o.Title && c.Subtitle == o.Subtitle && c.Description == o.Description && c.Rules == o.Rules && slices.Equal(c.Images, o.Images)
}

func (c Content) text() string {
	return strings.Join([]string{c.Title, c.Subtitle, c.Description, c.Rules}, "\n")
}

// PromotionPrice is the official promotion price a product sells at now.
type PromotionPrice struct {
	ID            int64     `json:"id"`
	Title         string    `json:"title"`
	PromoPriceAmt int       `json:"promo_price_amt"`
	EndsAt        time.Time `json:"ends_at"`
	PromoLeftQty  *int      `json:"promo_left_qty"`

	entryID    int64
	subsidyAmt int
}

// Product is the back-office (and open API) product.
type Product struct {
	ID                int64           `json:"id"`
	Merchant          Ref             `json:"merchant"`
	Type              string          `json:"type"`
	Title             string          `json:"title"`
	Subtitle          string          `json:"subtitle"`
	Description       string          `json:"description"`
	Images            []string        `json:"images"`
	Sports            []string        `json:"sports"`
	PriceAmt          int             `json:"price_amt"`
	OriginalAmt       *int            `json:"original_amt"`
	UseQty            int             `json:"use_qty"`
	ValidDays         *int            `json:"valid_days"`
	ValidUntil        *string         `json:"valid_until"`
	StockQty          *int            `json:"stock_qty"`
	SoldQty           int             `json:"sold_qty"`
	PerUserLimitQty   int             `json:"per_user_limit_qty"`
	Refundable        bool            `json:"refundable"`
	AllowPromotion    bool            `json:"allow_promotion"`
	Promotion         *PromotionPrice `json:"promotion"`
	VenueIDs          []int64         `json:"venue_ids"`
	Venues            []Ref           `json:"venues"`
	Rules             string          `json:"rules"`
	Status            string          `json:"status"`
	ReviewNote        *string         `json:"review_note"`
	HasPendingChanges bool            `json:"has_pending_changes"`
	CreatedAt         time.Time       `json:"created_at"`
	UpdatedAt         time.Time       `json:"updated_at"`

	pending         *Content
	merchantStatus  string
	contentApproved bool
	archived        bool
	validUntil      *time.Time
}

// Detail is GET /admin/v1/products/{id}: the product and its pending
// content changes.
type Detail struct {
	Product
	Pending *Content `json:"pending"`
}

// AppProduct is what the app sees: on-sale products only, without the
// review state and with sold_out instead of the stock.
type AppProduct struct {
	ID              int64           `json:"id"`
	Merchant        Ref             `json:"merchant"`
	Type            string          `json:"type"`
	Title           string          `json:"title"`
	Subtitle        string          `json:"subtitle"`
	Description     string          `json:"description"`
	Images          []string        `json:"images"`
	Sports          []string        `json:"sports"`
	PriceAmt        int             `json:"price_amt"`
	OriginalAmt     *int            `json:"original_amt"`
	UseQty          int             `json:"use_qty"`
	ValidDays       *int            `json:"valid_days"`
	ValidUntil      *string         `json:"valid_until"`
	SoldOut         bool            `json:"sold_out"`
	SoldQty         int             `json:"sold_qty"`
	PerUserLimitQty int             `json:"per_user_limit_qty"`
	Refundable      bool            `json:"refundable"`
	AllowPromotion  bool            `json:"allow_promotion"`
	Promotion       *PromotionPrice `json:"promotion"`
	VenueIDs        []int64         `json:"venue_ids"`
	Venues          []Ref           `json:"venues"`
	Rules           string          `json:"rules"`
	CreatedAt       time.Time       `json:"created_at"`
	UpdatedAt       time.Time       `json:"updated_at"`
	MyBoughtQty     *int            `json:"my_bought_qty,omitempty"`
}

// App returns the app view.
func (p Product) App() AppProduct {
	return AppProduct{ID: p.ID, Merchant: p.Merchant, Type: p.Type, Title: p.Title, Subtitle: p.Subtitle, Description: p.Description,
		Images: p.Images, Sports: p.Sports, PriceAmt: p.PriceAmt, OriginalAmt: p.OriginalAmt, UseQty: p.UseQty, ValidDays: p.ValidDays,
		ValidUntil: p.ValidUntil, SoldOut: p.StockQty != nil && *p.StockQty <= 0, SoldQty: p.SoldQty, PerUserLimitQty: p.PerUserLimitQty,
		Refundable: p.Refundable, AllowPromotion: p.AllowPromotion, Promotion: p.Promotion, VenueIDs: p.VenueIDs, Venues: p.Venues, Rules: p.Rules,
		CreatedAt: p.CreatedAt, UpdatedAt: p.UpdatedAt}
}

// sellable: on sale, not archived, merchant not suspended (App 可见可买).
func (p Product) sellable() bool {
	return p.Status == "on_sale" && !p.archived && p.merchantStatus != "suspended"
}

// activeEntrySQL selects the promotion entry a product (alias p) sells at
// now: entry and promotion active, promotion stock left; products banned,
// archived or of a suspended merchant (alias m) have none.
const activeEntrySQL = `SELECT e.id AS entry_id, pr.id AS promotion_id, pr.promotion_title AS promotion_title, e.promo_price_amt, pr.end_time AS promo_end,
		e.promo_stock_qty, e.promo_sold_qty, e.platform_subsidy_amt
	FROM src.src_mkt_loop_promotion_entry e JOIN src.src_mkt_loop_promotion pr ON pr.id=e.promotion_id
	WHERE e.product_id=p.id AND e.entry_status='active' AND pr.promotion_status='published' AND pr.start_time <= now() AND pr.end_time > now()
	  AND (e.promo_stock_qty IS NULL OR e.promo_sold_qty < e.promo_stock_qty)
	ORDER BY e.promo_price_amt, e.id LIMIT 1`

const productCols = `p.id, p.merchant_id, m.merchant_name, m.merchant_status, p.product_type, p.product_title, p.subtitle, p.description, p.images_json,
	p.rules, p.sports, p.price_amt, p.original_amt, p.use_qty, p.valid_days, p.valid_until_date, p.stock_qty, p.sold_qty, p.per_user_limit_qty,
	p.is_refundable, p.is_allow_promotion, p.venue_ids, p.product_status, p.review_note, p.is_content_approved, p.pending_content_json, p.is_archived,
	p.create_time, p.update_time, pe.entry_id, pe.promotion_id, pe.promotion_title, pe.promo_price_amt, pe.promo_end, pe.promo_stock_qty,
	pe.promo_sold_qty, pe.platform_subsidy_amt`

const productFrom = ` FROM src.src_mer_loop_product p JOIN src.src_mer_loop_merchant m ON m.id=p.merchant_id
	LEFT JOIN LATERAL (` + activeEntrySQL + `) pe ON p.product_status='on_sale' AND NOT p.is_archived AND m.merchant_status <> 'suspended' `

func scanProduct(r pgx.Row) (Product, error) {
	var p Product
	var images, pending []byte
	var validUntil *time.Time
	var entryID, promoID *int64
	var promoTitle *string
	var promoPrice, promoStock, promoSold, subsidy *int
	var promoEnd *time.Time
	err := r.Scan(&p.ID, &p.Merchant.ID, &p.Merchant.Name, &p.merchantStatus, &p.Type, &p.Title, &p.Subtitle, &p.Description, &images,
		&p.Rules, &p.Sports, &p.PriceAmt, &p.OriginalAmt, &p.UseQty, &p.ValidDays, &validUntil, &p.StockQty, &p.SoldQty, &p.PerUserLimitQty,
		&p.Refundable, &p.AllowPromotion, &p.VenueIDs, &p.Status, &p.ReviewNote, &p.contentApproved, &pending, &p.archived,
		&p.CreatedAt, &p.UpdatedAt, &entryID, &promoID, &promoTitle, &promoPrice, &promoEnd, &promoStock, &promoSold, &subsidy)
	if err != nil {
		return p, err
	}
	_ = json.Unmarshal(images, &p.Images)
	if p.Images == nil {
		p.Images = []string{}
	}
	if p.Sports == nil {
		p.Sports = []string{}
	}
	if p.VenueIDs == nil {
		p.VenueIDs = []int64{}
	}
	if validUntil != nil {
		s := validUntil.Format(time.DateOnly)
		p.ValidUntil, p.validUntil = &s, validUntil
	}
	if pending != nil {
		var c Content
		if json.Unmarshal(pending, &c) == nil {
			p.pending = &c
			p.HasPendingChanges = true
		}
	}
	if entryID != nil {
		pp := &PromotionPrice{ID: *promoID, Title: *promoTitle, PromoPriceAmt: *promoPrice, EndsAt: promoEnd.In(clock.Shanghai), entryID: *entryID, subsidyAmt: *subsidy}
		if promoStock != nil {
			left := *promoStock - *promoSold
			pp.PromoLeftQty = &left
		}
		p.Promotion = pp
	}
	return p, nil
}

// query loads products and resolves their venues.
func (s *Service) query(ctx context.Context, q db.Querier, where string, args ...any) ([]Product, error) {
	rows, err := q.Query(ctx, `SELECT `+productCols+productFrom+` WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	ps, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Product, error) { return scanProduct(r) })
	if err != nil {
		return nil, err
	}
	if ps == nil {
		ps = []Product{}
	}
	return ps, s.fillVenues(ctx, q, ps)
}

// fillVenues names each product's venues: its venue_ids, or every venue of
// the merchant when the list is empty (本商户所有场馆都可用).
func (s *Service) fillVenues(ctx context.Context, q db.Querier, ps []Product) error {
	if len(ps) == 0 {
		return nil
	}
	var merchants []int64
	for _, p := range ps {
		merchants = append(merchants, p.Merchant.ID)
	}
	rows, err := q.Query(ctx, `SELECT id, venue_name, merchant_id FROM src.src_mer_loop_venue WHERE merchant_id = ANY($1) AND NOT is_disabled ORDER BY id`, merchants)
	if err != nil {
		return err
	}
	type vrow struct {
		ref      Ref
		merchant int64
	}
	vs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (vrow, error) {
		var v vrow
		return v, r.Scan(&v.ref.ID, &v.ref.Name, &v.merchant)
	})
	if err != nil {
		return err
	}
	for i := range ps {
		ps[i].Venues = []Ref{}
		for _, v := range vs {
			if v.merchant == ps[i].Merchant.ID && (len(ps[i].VenueIDs) == 0 || slices.Contains(ps[i].VenueIDs, v.ref.ID)) {
				ps[i].Venues = append(ps[i].Venues, v.ref)
			}
		}
	}
	return nil
}

// load loads one product that is not archived; scope (a merchant) makes
// other merchants' products 404.
func (s *Service) load(ctx context.Context, q db.Querier, scope *int64, id int64) (Product, error) {
	ps, err := s.query(ctx, q, `p.id=$1 AND NOT p.is_archived AND ($2::bigint IS NULL OR p.merchant_id=$2)`, id, scope)
	if err != nil {
		return Product{}, err
	}
	if len(ps) == 0 {
		return Product{}, httpx.NotFound("商品")
	}
	return ps[0], nil
}

// Load is a product for the back office or the open API.
func (s *Service) Load(ctx context.Context, scope *int64, id int64) (Product, error) {
	return s.load(ctx, s.Pool, scope, id)
}

// LoadDetail adds the pending content changes.
func (s *Service) LoadDetail(ctx context.Context, scope *int64, id int64) (Detail, error) {
	p, err := s.load(ctx, s.Pool, scope, id)
	return Detail{Product: p, Pending: p.pending}, err
}

// ListFilter filters GET /admin/v1/products.
type ListFilter struct {
	MerchantID     int64
	Status         string
	Q              string
	AllowPromotion *bool
}

// List lists products that are not archived, newest first.
func (s *Service) List(ctx context.Context, f ListFilter, p httpx.Page) ([]Product, int, error) {
	if f.Status != "" && !statuses[f.Status] {
		return nil, 0, httpx.BadRequest("invalid_status", "status 取值错误")
	}
	where := `NOT p.is_archived AND ($1 = 0 OR p.merchant_id=$1) AND ($2 = '' OR p.product_status=$2)
		AND ($3 = '' OR p.product_title ILIKE '%' || $3 || '%' OR p.id::text=$3) AND ($4::bool IS NULL OR p.is_allow_promotion=$4)`
	args := []any{f.MerchantID, f.Status, strings.TrimSpace(f.Q), f.AllowPromotion}
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_mer_loop_product p WHERE `+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	items, err := s.query(ctx, s.Pool, where+` ORDER BY p.id DESC LIMIT $5 OFFSET $6`, append(args, p.Size, p.Offset())...)
	return items, total, err
}

// ---------------------------------------------------------------- input

// Input is POST / PATCH of a product: PATCH changes only the fields sent
// (null clears original_amt, stock_qty and the validity fields).
type Input struct {
	Type            *string   `json:"type"`
	Title           *string   `json:"title"`
	Subtitle        *string   `json:"subtitle"`
	Description     *string   `json:"description"`
	Images          *[]string `json:"images"`
	Rules           *string   `json:"rules"`
	Sports          *[]string `json:"sports"`
	PriceAmt        *int      `json:"price_amt"`
	OriginalAmt     *int      `json:"original_amt"`
	UseQty          *int      `json:"use_qty"`
	ValidDays       *int      `json:"valid_days"`
	ValidUntil      *string   `json:"valid_until"`
	StockQty        *int      `json:"stock_qty"`
	PerUserLimitQty *int      `json:"per_user_limit_qty"`
	Refundable      *bool     `json:"refundable"`
	AllowPromotion  *bool     `json:"allow_promotion"`
	VenueIDs        *[]int64  `json:"venue_ids"`

	present map[string]bool
}

// UnmarshalJSON records which fields were sent (null vs absent) and
// rejects unknown ones.
func (in *Input) UnmarshalJSON(b []byte) error {
	type plain Input
	var p plain
	dec := json.NewDecoder(strings.NewReader(string(b)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&p); err != nil {
		return err
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(b, &keys); err != nil {
		return err
	}
	*in = Input(p)
	in.present = map[string]bool{}
	for k := range keys {
		in.present[k] = true
	}
	return nil
}

func (in Input) has(k string) bool { return in.present[k] }

// state is the editable state of a product.
type state struct {
	Type            string
	Content         Content
	Sports          []string
	PriceAmt        int
	OriginalAmt     *int
	UseQty          int
	ValidDays       *int
	ValidUntil      *time.Time
	StockQty        *int
	PerUserLimitQty int
	Refundable      bool
	AllowPromotion  bool
	VenueIDs        []int64
}

func stateOf(p Product) state {
	return state{Type: p.Type, Content: Content{Title: p.Title, Subtitle: p.Subtitle, Description: p.Description, Images: p.Images, Rules: p.Rules},
		Sports: p.Sports, PriceAmt: p.PriceAmt, OriginalAmt: p.OriginalAmt, UseQty: p.UseQty, ValidDays: p.ValidDays, ValidUntil: p.validUntil,
		StockQty: p.StockQty, PerUserLimitQty: p.PerUserLimitQty, Refundable: p.Refundable, AllowPromotion: p.AllowPromotion, VenueIDs: p.VenueIDs}
}

var bad = func(msg string) error { return httpx.BadRequest("invalid_body", msg) }

// apply puts the sent fields onto st (content onto c, the content being
// edited: the pending version of an on-sale product).
func (in Input) apply(st state, c Content) (state, Content, error) {
	if in.Type != nil {
		st.Type = *in.Type
	}
	if in.Title != nil {
		c.Title = strings.TrimSpace(*in.Title)
	}
	if in.Subtitle != nil {
		c.Subtitle = strings.TrimSpace(*in.Subtitle)
	}
	if in.Description != nil {
		c.Description = strings.TrimSpace(*in.Description)
	}
	if in.Images != nil {
		c.Images = *in.Images
	}
	if in.Rules != nil {
		c.Rules = strings.TrimSpace(*in.Rules)
	}
	if in.Sports != nil {
		st.Sports = *in.Sports
	}
	if in.PriceAmt != nil {
		st.PriceAmt = *in.PriceAmt
	}
	if in.has("original_amt") {
		st.OriginalAmt = in.OriginalAmt
	}
	if in.UseQty != nil {
		st.UseQty = *in.UseQty
	}
	if in.has("valid_days") || in.has("valid_until") {
		st.ValidDays, st.ValidUntil = nil, nil
		if in.ValidDays != nil {
			st.ValidDays = in.ValidDays
		}
		if in.ValidUntil != nil && *in.ValidUntil != "" {
			d, err := time.ParseInLocation(time.DateOnly, *in.ValidUntil, clock.Shanghai)
			if err != nil {
				return st, c, bad("valid_until 格式为 YYYY-MM-DD")
			}
			st.ValidUntil = &d
		}
	}
	if in.has("stock_qty") {
		st.StockQty = in.StockQty
	}
	if in.PerUserLimitQty != nil {
		st.PerUserLimitQty = *in.PerUserLimitQty
	}
	if in.Refundable != nil {
		st.Refundable = *in.Refundable
	}
	if in.AllowPromotion != nil {
		st.AllowPromotion = *in.AllowPromotion
	}
	if in.VenueIDs != nil {
		st.VenueIDs = *in.VenueIDs
	}
	if st.Type != "pass" && in.UseQty == nil {
		st.UseQty = 1
	}
	st.Content = c
	return st, c, nil
}

func validImage(u string) bool {
	return strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://") || strings.HasPrefix(u, "/")
}

func (st *state) validate(ctx context.Context, q db.Querier, merchantID int64) error {
	c := &st.Content
	if !productTypes[st.Type] {
		return bad("type 只能是 package / voucher / pass")
	}
	if n := utf8.RuneCountInString(c.Title); n < 2 || n > 40 {
		return bad("标题 2–40 字")
	}
	if utf8.RuneCountInString(c.Subtitle) > 40 {
		return bad("副标题最多 40 字")
	}
	if utf8.RuneCountInString(c.Description) > 1000 {
		return bad("商品说明最多 1000 字")
	}
	if utf8.RuneCountInString(c.Rules) > 500 {
		return bad("使用规则最多 500 字")
	}
	if c.Images == nil {
		c.Images = []string{}
	}
	if len(c.Images) < 1 || len(c.Images) > 9 {
		return bad("商品图片 1–9 张")
	}
	for _, u := range c.Images {
		if !validImage(u) {
			return bad("图片地址不合法")
		}
	}
	if st.Sports == nil {
		st.Sports = []string{}
	}
	for _, sp := range st.Sports {
		if !venue.Sports[sp] {
			return bad("运动分类取值错误：" + sp)
		}
	}
	if st.PriceAmt < 1 || st.PriceAmt > 1_000_000 {
		return bad("价格应在 1–1000000 分之间")
	}
	if st.OriginalAmt != nil && *st.OriginalAmt < st.PriceAmt {
		return bad("门市价（面值）不能低于售价")
	}
	if st.Type == "pass" {
		if st.UseQty < 2 || st.UseQty > 100 {
			return bad("次卡次数 2–100")
		}
	} else {
		st.UseQty = 1
	}
	switch {
	case st.ValidDays != nil && st.ValidUntil != nil, st.ValidDays == nil && st.ValidUntil == nil:
		return bad("有效期请在 valid_days 和 valid_until 中二选一")
	case st.ValidDays != nil && (*st.ValidDays < 1 || *st.ValidDays > 365):
		return bad("有效天数 1–365")
	case st.ValidUntil != nil && st.ValidUntil.Before(clock.Today()):
		return bad("截止日期不能早于今天")
	}
	if st.StockQty != nil && (*st.StockQty < 0 || *st.StockQty > 1_000_000) {
		return bad("库存应在 0–1000000 之间（不限请传 null）")
	}
	if st.PerUserLimitQty < 0 || st.PerUserLimitQty > 1000 {
		return bad("限购 0–1000（0 为不限）")
	}
	if st.VenueIDs == nil {
		st.VenueIDs = []int64{}
	}
	slices.Sort(st.VenueIDs)
	st.VenueIDs = slices.Compact(st.VenueIDs)
	if len(st.VenueIDs) > 0 {
		var n int
		if err := q.QueryRow(ctx, `SELECT count(*) FROM src.src_mer_loop_venue WHERE id = ANY($1) AND merchant_id=$2`, st.VenueIDs, merchantID).Scan(&n); err != nil {
			return err
		}
		if n != len(st.VenueIDs) {
			return bad("适用门店只能选本商户的场馆")
		}
	}
	return nil
}

// ---------------------------------------------------------------- writes

// lock locks a product of the merchant (not archived) and loads it.
func (s *Service) lock(ctx context.Context, tx pgx.Tx, merchantID, id int64) (Product, error) {
	var ok bool
	err := tx.QueryRow(ctx, `SELECT true FROM src.src_mer_loop_product WHERE id=$1 AND merchant_id=$2 AND NOT is_archived FOR UPDATE`, id, merchantID).Scan(&ok)
	if db.IsNoRows(err) {
		return Product{}, httpx.NotFound("商品")
	}
	if err != nil {
		return Product{}, err
	}
	return s.load(ctx, tx, &merchantID, id)
}

func nullDate(t *time.Time) any {
	if t == nil {
		return nil
	}
	return *t
}

// save writes the non-content fields and (when content is non-nil) the
// content of a product.
func save(ctx context.Context, tx pgx.Tx, id int64, st state, content *Content) error {
	if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET product_type=$2, sports=$3, price_amt=$4, original_amt=$5, use_qty=$6, valid_days=$7,
			valid_until_date=$8, stock_qty=$9, per_user_limit_qty=$10, is_refundable=$11, is_allow_promotion=$12, venue_ids=$13, update_time=now()
		WHERE id=$1`, id, st.Type, st.Sports, st.PriceAmt, st.OriginalAmt, st.UseQty, st.ValidDays, nullDate(st.ValidUntil), st.StockQty,
		st.PerUserLimitQty, st.Refundable, st.AllowPromotion, st.VenueIDs); err != nil {
		return err
	}
	if content == nil {
		return nil
	}
	images, _ := json.Marshal(content.Images)
	_, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET product_title=$2, subtitle=$3, description=$4, images_json=$5, rules=$6 WHERE id=$1`,
		id, content.Title, content.Subtitle, content.Description, images, content.Rules)
	return err
}

// Create is POST /admin/v1/products (merchant staff) and POST
// /open/v1/products: a draft.
func (s *Service) Create(ctx context.Context, tx pgx.Tx, a Actor, in Input) (int64, error) {
	st := state{Refundable: true}
	if in.Type == nil {
		return 0, bad("type 不能为空")
	}
	if in.PriceAmt == nil {
		return 0, bad("price_amt 不能为空")
	}
	st, _, err := in.apply(st, Content{})
	if err != nil {
		return 0, err
	}
	if err := st.validate(ctx, tx, a.MerchantID); err != nil {
		return 0, err
	}
	images, _ := json.Marshal(st.Content.Images)
	var adminID, appID any
	if a.AdminID != 0 {
		adminID = a.AdminID
	}
	if a.AppID != 0 {
		appID = a.AppID
	}
	var id int64
	err = tx.QueryRow(ctx, `INSERT INTO src.src_mer_loop_product (merchant_id, product_type, product_title, subtitle, description, images_json, rules, sports,
			price_amt, original_amt, use_qty, valid_days, valid_until_date, stock_qty, per_user_limit_qty, is_refundable, is_allow_promotion, venue_ids,
			create_admin_id, create_app_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20) RETURNING id`,
		a.MerchantID, st.Type, st.Content.Title, st.Content.Subtitle, st.Content.Description, images, st.Content.Rules, st.Sports,
		st.PriceAmt, st.OriginalAmt, st.UseQty, st.ValidDays, nullDate(st.ValidUntil), st.StockQty, st.PerUserLimitQty, st.Refundable,
		st.AllowPromotion, st.VenueIDs, adminID, appID).Scan(&id)
	return id, err
}

func hasOrders(ctx context.Context, q db.Querier, id int64) (bool, error) {
	var n bool
	err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_ord_loop_product_order WHERE product_id=$1)`, id).Scan(&n)
	return n, err
}

// Update is PATCH: other fields apply at once (to later purchases);
// content changes of an on-sale product wait for review as a pending
// version while the old content stays on sale.
func (s *Service) Update(ctx context.Context, tx pgx.Tx, a Actor, id int64, in Input) error {
	p, err := s.lock(ctx, tx, a.MerchantID, id)
	if err != nil {
		return err
	}
	cur := stateOf(p)
	base := cur.Content
	if p.pending != nil {
		base = *p.pending
	}
	st, c, err := in.apply(cur, base)
	if err != nil {
		return err
	}
	if err := st.validate(ctx, tx, a.MerchantID); err != nil {
		return err
	}
	c = st.Content
	if st.Type != p.Type {
		sold, err := hasOrders(ctx, tx, id)
		if err != nil {
			return err
		}
		if sold {
			return bad("卖出过的商品不能修改类型")
		}
	}
	changed := !c.equal(base)
	switch p.Status {
	case "on_sale":
		if err := save(ctx, tx, id, st, nil); err != nil {
			return err
		}
		if !changed {
			return nil
		}
		if c.equal(cur.Content) { // edited back to the live content
			_, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET pending_content_json=NULL WHERE id=$1`, id)
			if err == nil {
				err = dropPendingTask(ctx, tx, id)
			}
			return err
		}
		raw, _ := json.Marshal(c)
		if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET pending_content_json=$2 WHERE id=$1`, id, raw); err != nil {
			return err
		}
		return s.review(ctx, tx, id, c, true)
	case "reviewing":
		if err := save(ctx, tx, id, st, &c); err != nil {
			return err
		}
		if changed {
			return s.review(ctx, tx, id, c, false)
		}
		return nil
	default: // draft, off_sale, rejected, banned: written directly, reviewed when (re)submitted
		if err := save(ctx, tx, id, st, &c); err != nil {
			return err
		}
		if changed {
			_, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET is_content_approved=false WHERE id=$1`, id)
			return err
		}
		return nil
	}
}

// SetStock is PUT /open/v1/products/{id}/stock.
func (s *Service) SetStock(ctx context.Context, tx pgx.Tx, a Actor, id int64, stock *int) error {
	in := Input{StockQty: stock, present: map[string]bool{"stock_qty": true}}
	return s.Update(ctx, tx, a, id, in)
}

// Submit sends a draft, rejected or banned product to review.
func (s *Service) Submit(ctx context.Context, tx pgx.Tx, a Actor, id int64) error {
	p, err := s.lock(ctx, tx, a.MerchantID, id)
	if err != nil {
		return err
	}
	switch p.Status {
	case "draft", "rejected", "banned":
	default:
		return httpx.Conflict("invalid_status", "只有草稿、被驳回或被下架的商品可以提交审核")
	}
	c := stateOf(p).Content
	if p.pending != nil { // pending changes of a product taken off sale become its content
		c = *p.pending
		if err := save(ctx, tx, id, stateOf(p), &c); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET pending_content_json=NULL WHERE id=$1`, id); err != nil {
			return err
		}
	}
	return s.review(ctx, tx, id, c, false)
}

// OnSale puts an off-sale product back on sale; content changed since its
// last approval is reviewed first.
func (s *Service) OnSale(ctx context.Context, tx pgx.Tx, a Actor, id int64) error {
	p, err := s.lock(ctx, tx, a.MerchantID, id)
	if err != nil {
		return err
	}
	if p.Status != "off_sale" {
		return httpx.Conflict("invalid_status", "只有已下架的商品可以上架")
	}
	if p.contentApproved {
		_, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET product_status='on_sale', update_time=now() WHERE id=$1`, id)
		return err
	}
	return s.review(ctx, tx, id, stateOf(p).Content, false)
}

// OffSale takes an on-sale product off sale.
func (s *Service) OffSale(ctx context.Context, tx pgx.Tx, a Actor, id int64) error {
	p, err := s.lock(ctx, tx, a.MerchantID, id)
	if err != nil {
		return err
	}
	if p.Status != "on_sale" {
		return httpx.Conflict("invalid_status", "只有在售的商品可以下架")
	}
	_, err = tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET product_status='off_sale', update_time=now() WHERE id=$1`, id)
	return err
}

// Delete deletes a product never ordered, or archives one that was (sold
// coupons stay valid). It reports whether it archived.
func (s *Service) Delete(ctx context.Context, tx pgx.Tx, a Actor, id int64) (bool, error) {
	if _, err := s.lock(ctx, tx, a.MerchantID, id); err != nil {
		return false, err
	}
	sold, err := hasOrders(ctx, tx, id)
	if err != nil {
		return false, err
	}
	if err := dropPendingTask(ctx, tx, id); err != nil {
		return false, err
	}
	if !sold {
		_, err := tx.Exec(ctx, `DELETE FROM src.src_mer_loop_product WHERE id=$1`, id)
		return false, err
	}
	_, err = tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET is_archived=true, archive_time=now(), pending_content_json=NULL,
		product_status=CASE WHEN product_status IN ('on_sale','reviewing') THEN 'off_sale' ELSE product_status END, update_time=now() WHERE id=$1`, id)
	return true, err
}

// Ban is the platform's forced take-down (admin, ops): the merchant can
// only edit and resubmit it.
func (s *Service) Ban(ctx context.Context, tx pgx.Tx, id int64, reason string) error {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return bad("请填写下架原因")
	}
	if utf8.RuneCountInString(reason) > 200 {
		return bad("下架原因最多 200 字")
	}
	var status string
	err := tx.QueryRow(ctx, `SELECT product_status FROM src.src_mer_loop_product WHERE id=$1 AND NOT is_archived FOR UPDATE`, id).Scan(&status)
	if db.IsNoRows(err) {
		return httpx.NotFound("商品")
	}
	if err != nil {
		return err
	}
	if status == "banned" {
		return httpx.Conflict("invalid_status", "这个商品已经被下架了")
	}
	if err := dropPendingTask(ctx, tx, id); err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET product_status='banned', review_note=$2, pending_content_json=NULL, is_content_approved=false,
		update_time=now() WHERE id=$1`, id, reason)
	if err != nil {
		return err
	}
	b, err := brief(ctx, tx, id)
	if err != nil {
		return err
	}
	s.Msg.ToMerchant(ctx, b.merchantID, adminmsg.Msg{Category: adminmsg.CatProduct, Level: adminmsg.Error,
		Title: "商品「" + b.title + "」已被平台下架：" + reason, Body: "下架原因：" + reason + "。修改后可重新提交审核。",
		Link: productLink(id), RefType: "product", RefID: id})
	return nil
}

// productBrief names a product in messages.
type productBrief struct {
	title, merchantName string
	merchantID          int64
}

func brief(ctx context.Context, q db.Querier, id int64) (productBrief, error) {
	var b productBrief
	err := q.QueryRow(ctx, `SELECT p.product_title, m.merchant_name, m.id FROM src.src_mer_loop_product p JOIN src.src_mer_loop_merchant m ON m.id=p.merchant_id
		WHERE p.id=$1`, id).Scan(&b.title, &b.merchantName, &b.merchantID)
	return b, err
}

func productLink(id int64) string { return fmt.Sprintf("/merchant/products?id=%d", id) }

// ---------------------------------------------------------------- review

// dropPendingTask removes the product's undecided review task (its
// content was replaced or the product is gone).
func dropPendingTask(ctx context.Context, tx pgx.Tx, id int64) error {
	_, err := tx.Exec(ctx, `DELETE FROM src.src_cnt_loop_review_task WHERE target_type=$1 AND target_id=$2 AND review_status='pending'`, moderation.Product, id)
	return err
}

// review scores content (the product's, or with pending=true its pending
// changes) and applies the thresholds: low risk is approved at once, high
// risk rejected with the reason, the rest waits in the review queue.
func (s *Service) review(ctx context.Context, tx pgx.Tx, id int64, c Content, pending bool) error {
	if err := dropPendingTask(ctx, tx, id); err != nil {
		return err
	}
	sc := s.Mod.Review(ctx, moderation.Content{Target: moderation.Product, Text: c.text(), Images: c.Images})
	outcome := s.Mod.Outcome(ctx, sc)
	if sc.Blocked {
		outcome = moderation.OutcomeReject
	}
	if !pending { // under review until the outcome applies (approve → on_sale, reject → rejected)
		if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET product_status='reviewing', review_note=NULL, update_time=now() WHERE id=$1`, id); err != nil {
			return err
		}
	}
	if outcome == moderation.OutcomeApprove {
		if err := s.approve(ctx, tx, id); err != nil {
			return err
		}
	}
	if err := s.Mod.File(ctx, tx, moderation.Product, id, 0, c.text(), c.Images, sc, outcome); err != nil {
		return err
	}
	if outcome == moderation.OutcomeReview {
		return s.notifyReview(ctx, tx, id, c.Title, pending)
	}
	return nil
}

// notifyReview tells the platform (reviewers included) a product waits
// in the review queue.
func (s *Service) notifyReview(ctx context.Context, q db.Querier, id int64, title string, change bool) error {
	b, err := brief(ctx, q, id)
	if err != nil {
		return err
	}
	if title == "" {
		title = b.title
	}
	body := "新商品待审核，请在「审核」里处理。"
	if change {
		body = "在售商品修改了内容，待审核；审核前仍按原内容售卖。"
	}
	s.Msg.ToPlatform(ctx, adminmsg.Msg{Category: adminmsg.CatReview, Level: adminmsg.Info,
		Title: "商户「" + b.merchantName + "」提交了商品「" + title + "」，待审核", Body: body,
		Link: "/review?type=product", RefType: "product", RefID: id}, true)
	return nil
}

// approve applies a passed review: pending changes replace the content; a
// product under review goes on sale.
func (s *Service) approve(ctx context.Context, tx pgx.Tx, id int64) error {
	var pending []byte
	var status string
	err := tx.QueryRow(ctx, `SELECT pending_content_json, product_status FROM src.src_mer_loop_product WHERE id=$1 FOR UPDATE`, id).Scan(&pending, &status)
	if db.IsNoRows(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if pending != nil {
		var c Content
		if err := json.Unmarshal(pending, &c); err != nil {
			return err
		}
		images, _ := json.Marshal(c.Images)
		if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET product_title=$2, subtitle=$3, description=$4, images_json=$5, rules=$6,
			pending_content_json=NULL WHERE id=$1`, id, c.Title, c.Subtitle, c.Description, images, c.Rules); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET is_content_approved=true,
			product_status=CASE WHEN product_status='reviewing' THEN 'on_sale' ELSE product_status END,
			review_note=CASE WHEN product_status='reviewing' THEN NULL ELSE review_note END, update_time=now() WHERE id=$1`, id); err != nil {
		return err
	}
	if status == "reviewing" || pending != nil {
		b, err := brief(ctx, tx, id)
		if err != nil {
			return err
		}
		m := adminmsg.Msg{Category: adminmsg.CatProduct, Level: adminmsg.Success, Title: "商品「" + b.title + "」审核通过，已上架",
			Body: "用户现在可以在 App 里看到并购买。", Link: productLink(id), RefType: "product", RefID: id}
		if status != "reviewing" {
			m.Title, m.Body = "商品「"+b.title+"」的修改已生效", "新的标题、图片和说明已经在 App 里展示。"
		}
		s.Msg.ToMerchant(ctx, b.merchantID, m)
	}
	return s.emitReviewed(ctx, tx, id, "approved", "")
}

// reject applies a failed review: a product under review is rejected, a
// pending change is discarded; review_note says why.
func (s *Service) reject(ctx context.Context, tx pgx.Tx, id int64, reason string) error {
	var status string
	var hadPending bool
	err := tx.QueryRow(ctx, `SELECT product_status, pending_content_json IS NOT NULL FROM src.src_mer_loop_product WHERE id=$1 FOR UPDATE`, id).
		Scan(&status, &hadPending)
	if db.IsNoRows(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET
			product_status=CASE WHEN product_status='reviewing' THEN 'rejected' ELSE product_status END,
			pending_content_json=NULL, review_note=$2, update_time=now() WHERE id=$1`, id, reason); err != nil {
		return err
	}
	if status == "reviewing" || hadPending {
		b, err := brief(ctx, tx, id)
		if err != nil {
			return err
		}
		m := adminmsg.Msg{Category: adminmsg.CatProduct, Level: adminmsg.Warning, Title: "商品「" + b.title + "」未通过审核：" + reason,
			Body: "原因：" + reason + "。修改后可重新提交审核。", Link: productLink(id), RefType: "product", RefID: id}
		if status != "reviewing" {
			m.Title, m.Body = "商品「"+b.title+"」的修改未通过："+reason, "原因："+reason+"。商品仍按原内容在售，可修改后重新提交。"
		}
		s.Msg.ToMerchant(ctx, b.merchantID, m)
	}
	return s.emitReviewed(ctx, tx, id, "rejected", reason)
}

// Reviewed is the data of the product.reviewed webhook.
type Reviewed struct {
	Result  string  `json:"result"`
	Note    string  `json:"note"`
	Product Product `json:"product"`
}

func (s *Service) emitReviewed(ctx context.Context, tx pgx.Tx, id int64, result, note string) error {
	ps, err := s.query(ctx, tx, `p.id=$1`, id)
	if err != nil || len(ps) == 0 {
		return err
	}
	return webhook.Emit(ctx, tx, ps[0].Merchant.ID, webhook.ProductReviewed, Reviewed{Result: result, Note: note, Product: ps[0]})
}

// Applier is the moderation.Product applier (管理端审核队列).
func (s *Service) Applier() moderation.Applier {
	return moderation.Applier{
		Approve: func(ctx context.Context, tx pgx.Tx, id int64) error { return s.approve(ctx, tx, id) },
		Reject: func(ctx context.Context, tx pgx.Tx, id int64, reason string) error {
			return s.reject(ctx, tx, id, reason)
		},
		Pend: func(ctx context.Context, tx pgx.Tx, id int64) error {
			tag, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_product SET product_status='reviewing', update_time=now() WHERE id=$1 AND product_status='on_sale'`, id)
			if err != nil || tag.RowsAffected() == 0 {
				return err
			}
			return s.notifyReview(ctx, tx, id, "", false)
		},
	}
}

// PendingReviews counts products waiting in the review queue (总览待办).
func PendingReviews(ctx context.Context, q db.Querier) (int, error) {
	var n int
	err := q.QueryRow(ctx, `SELECT count(*) FROM src.src_cnt_loop_review_task WHERE target_type=$1 AND review_status='pending'`, moderation.Product).Scan(&n)
	return n, err
}

// ---------------------------------------------------------------- app reads

// VenueProducts implements venue.ProductLister: up to 10 on-sale products
// usable at the venue, best sellers first.
func (s *Service) VenueProducts(ctx context.Context, viewer, merchantID, venueID int64) (any, error) {
	ps, err := s.query(ctx, s.Pool, `p.merchant_id=$1 AND p.product_status='on_sale' AND NOT p.is_archived AND m.merchant_status <> 'suspended'
		AND (cardinality(p.venue_ids) = 0 OR $2 = ANY(p.venue_ids)) ORDER BY p.sold_qty DESC, p.id DESC LIMIT 10`, merchantID, venueID)
	if err != nil {
		return nil, err
	}
	return apps(ps), nil
}

func apps(ps []Product) []AppProduct {
	out := make([]AppProduct, len(ps))
	for i, p := range ps {
		out[i] = p.App()
	}
	return out
}

// MerchantProducts is GET /v1/merchants/{id}/products (offset cursor).
func (s *Service) MerchantProducts(ctx context.Context, merchantID int64, offset, limit int) ([]AppProduct, *string, error) {
	ps, err := s.query(ctx, s.Pool, `p.merchant_id=$1 AND p.product_status='on_sale' AND NOT p.is_archived AND m.merchant_status <> 'suspended'
		ORDER BY p.sold_qty DESC, p.id DESC LIMIT $2 OFFSET $3`, merchantID, limit+1, offset)
	if err != nil {
		return nil, nil, err
	}
	var next *string
	if len(ps) > limit {
		ps = ps[:limit]
		n := fmt.Sprint(offset + limit)
		next = &n
	}
	return apps(ps), next, nil
}

// AppProduct is GET /v1/products/{id}: on-sale products only, with how
// many the viewer bought.
func (s *Service) AppProduct(ctx context.Context, user, id int64) (AppProduct, error) {
	ps, err := s.query(ctx, s.Pool, `p.id=$1`, id)
	if err != nil {
		return AppProduct{}, err
	}
	if len(ps) == 0 || !ps[0].sellable() {
		return AppProduct{}, httpx.NotFound("商品")
	}
	a := ps[0].App()
	n, err := boughtQty(ctx, s.Pool, user, id, `'paid','completed','refunding'`)
	if err != nil {
		return a, err
	}
	a.MyBoughtQty = &n
	return a, nil
}

// boughtQty counts the user's units of a product in orders of statuses.
func boughtQty(ctx context.Context, q db.Querier, user, product int64, statuses string) (int, error) {
	var n int
	err := q.QueryRow(ctx, `SELECT COALESCE(sum(qty), 0)::int FROM src.src_ord_loop_product_order WHERE user_id=$1 AND product_id=$2
		AND order_status IN (`+statuses+`)`, user, product).Scan(&n)
	return n, err
}
