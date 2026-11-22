package product

import (
	"context"
	"encoding/json"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/webhook"
)

// Promotion is an official promotion (官方活动).
type Promotion struct {
	ID            int64         `json:"id"`
	Title         string        `json:"title"`
	Subtitle      string        `json:"subtitle"`
	BannerURL     *string       `json:"banner_url"`
	Description   string        `json:"description"`
	StartsAt      time.Time     `json:"starts_at"`
	EndsAt        time.Time     `json:"ends_at"`
	ApplyOpen     bool          `json:"apply_open"`
	ApplyDeadline *time.Time    `json:"apply_deadline"`
	Status        string        `json:"status"`
	ProductQty    int           `json:"product_qty"`
	CreatedAt     time.Time     `json:"created_at"`
	Items         *[]AppProduct `json:"items,omitempty"`
}

// promotionStatusSQL is the shown status of promotion pr.
const promotionStatusSQL = `(CASE WHEN pr.promotion_status IN ('draft','cancelled') THEN pr.promotion_status
	WHEN pr.end_time <= now() THEN 'ended' WHEN pr.start_time > now() THEN 'scheduled' ELSE 'active' END)`

// applyOpenSQL: merchants can apply to promotion pr now.
const applyOpenSQL = `(pr.is_apply_open AND pr.promotion_status='published' AND pr.end_time > now()
	AND (pr.apply_deadline_time IS NULL OR pr.apply_deadline_time > now()))`

const promotionCols = `pr.id, pr.promotion_title, pr.subtitle, pr.banner_url, pr.description, pr.start_time, pr.end_time, pr.is_apply_open,
	pr.apply_deadline_time, ` + promotionStatusSQL + `,
	(SELECT count(*) FROM src.src_mkt_loop_promotion_entry e WHERE e.promotion_id=pr.id AND e.entry_status='active')::int, pr.create_time`

func scanPromotion(r pgx.Row) (Promotion, error) {
	var x Promotion
	err := r.Scan(&x.ID, &x.Title, &x.Subtitle, &x.BannerURL, &x.Description, &x.StartsAt, &x.EndsAt, &x.ApplyOpen, &x.ApplyDeadline, &x.Status,
		&x.ProductQty, &x.CreatedAt)
	x.StartsAt, x.EndsAt = x.StartsAt.In(clock.Shanghai), x.EndsAt.In(clock.Shanghai)
	return x, err
}

func queryPromotions(ctx context.Context, q db.Querier, where string, args ...any) ([]Promotion, error) {
	rows, err := q.Query(ctx, `SELECT `+promotionCols+` FROM src.src_mkt_loop_promotion pr WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Promotion, error) { return scanPromotion(r) })
	if out == nil {
		out = []Promotion{}
	}
	return out, err
}

// PromotionFilter filters GET /admin/v1/promotions. Merchant staff only
// see published promotions that have not ended.
type PromotionFilter struct {
	Status    string
	ApplyOpen *bool
	Merchant  bool
}

// Promotions lists promotions, newest first.
func (s *Service) Promotions(ctx context.Context, f PromotionFilter, p httpx.Page) ([]Promotion, int, error) {
	where := `($1 = '' OR ` + promotionStatusSQL + ` = $1) AND ($2::bool IS NULL OR ` + applyOpenSQL + ` = $2)
		AND (NOT $3 OR (pr.promotion_status='published' AND pr.end_time > now()))`
	args := []any{f.Status, f.ApplyOpen, f.Merchant}
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_mkt_loop_promotion pr WHERE `+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	items, err := queryPromotions(ctx, s.Pool, where+` ORDER BY pr.start_time DESC, pr.id DESC LIMIT $4 OFFSET $5`, append(args, p.Size, p.Offset())...)
	return items, total, err
}

// LoadPromotion loads one promotion (merchant=true: published only).
func (s *Service) LoadPromotion(ctx context.Context, q db.Querier, id int64, merchant bool) (Promotion, error) {
	xs, err := queryPromotions(ctx, q, `pr.id=$1 AND (NOT $2 OR pr.promotion_status='published')`, id, merchant)
	if err != nil {
		return Promotion{}, err
	}
	if len(xs) == 0 {
		return Promotion{}, httpx.NotFound("活动")
	}
	return xs[0], nil
}

// PromotionInput is POST / PATCH /admin/v1/promotions (PATCH: the fields
// sent; null clears banner_url and apply_deadline).
type PromotionInput struct {
	Title         *string    `json:"title"`
	Subtitle      *string    `json:"subtitle"`
	BannerURL     *string    `json:"banner_url"`
	Description   *string    `json:"description"`
	StartsAt      *time.Time `json:"starts_at"`
	EndsAt        *time.Time `json:"ends_at"`
	ApplyOpen     *bool      `json:"apply_open"`
	ApplyDeadline *time.Time `json:"apply_deadline"`

	present map[string]bool
}

// UnmarshalJSON records which fields were sent.
func (in *PromotionInput) UnmarshalJSON(b []byte) error {
	type plain PromotionInput
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
	*in = PromotionInput(p)
	in.present = map[string]bool{}
	for k := range keys {
		in.present[k] = true
	}
	return nil
}

type promoState struct {
	title, subtitle, description string
	banner                       *string
	start, end                   time.Time
	applyOpen                    bool
	deadline                     *time.Time
}

func (in PromotionInput) apply(st promoState) (promoState, error) {
	if in.Title != nil {
		st.title = strings.TrimSpace(*in.Title)
	}
	if in.Subtitle != nil {
		st.subtitle = strings.TrimSpace(*in.Subtitle)
	}
	if in.Description != nil {
		st.description = strings.TrimSpace(*in.Description)
	}
	if in.present["banner_url"] {
		st.banner = in.BannerURL
		if st.banner != nil && *st.banner == "" {
			st.banner = nil
		}
	}
	if in.StartsAt != nil {
		st.start = *in.StartsAt
	}
	if in.EndsAt != nil {
		st.end = *in.EndsAt
	}
	if in.ApplyOpen != nil {
		st.applyOpen = *in.ApplyOpen
	}
	if in.present["apply_deadline"] {
		st.deadline = in.ApplyDeadline
	}
	switch {
	case utf8.RuneCountInString(st.title) < 2 || utf8.RuneCountInString(st.title) > 40:
		return st, bad("活动标题 2–40 字")
	case utf8.RuneCountInString(st.subtitle) > 60:
		return st, bad("副标题最多 60 字")
	case utf8.RuneCountInString(st.description) > 2000:
		return st, bad("活动说明最多 2000 字")
	case st.banner != nil && !validImage(*st.banner):
		return st, bad("横幅图地址不合法")
	case st.start.IsZero() || st.end.IsZero() || !st.end.After(st.start):
		return st, bad("请填写活动时间，结束晚于开始")
	case st.deadline != nil && st.deadline.After(st.end):
		return st, bad("报名截止时间不能晚于活动结束")
	}
	return st, nil
}

// CreatePromotion is POST /admin/v1/promotions (a draft).
func (s *Service) CreatePromotion(ctx context.Context, tx pgx.Tx, adminID int64, in PromotionInput) (int64, error) {
	st, err := in.apply(promoState{})
	if err != nil {
		return 0, err
	}
	var id int64
	err = tx.QueryRow(ctx, `INSERT INTO src.src_mkt_loop_promotion (promotion_title, subtitle, banner_url, description, start_time, end_time, is_apply_open,
			apply_deadline_time, create_admin_id) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING id`,
		st.title, st.subtitle, st.banner, st.description, st.start, st.end, st.applyOpen, st.deadline, adminID).Scan(&id)
	return id, err
}

// UpdatePromotion is PATCH /admin/v1/promotions/{id}; new times must not
// overlap another active entry of the same products (409 promotion_conflict).
func (s *Service) UpdatePromotion(ctx context.Context, tx pgx.Tx, id int64, in PromotionInput) error {
	var st promoState
	var status string
	err := tx.QueryRow(ctx, `SELECT promotion_title, subtitle, description, banner_url, start_time, end_time, is_apply_open, apply_deadline_time, promotion_status
		FROM src.src_mkt_loop_promotion WHERE id=$1 FOR UPDATE`, id).
		Scan(&st.title, &st.subtitle, &st.description, &st.banner, &st.start, &st.end, &st.applyOpen, &st.deadline, &status)
	if db.IsNoRows(err) {
		return httpx.NotFound("活动")
	}
	if err != nil {
		return err
	}
	if status == "cancelled" {
		return httpx.Conflict("invalid_status", "已取消的活动不能修改")
	}
	if st, err = in.apply(st); err != nil {
		return err
	}
	rows, err := tx.Query(ctx, `SELECT id, product_id FROM src.src_mkt_loop_promotion_entry WHERE promotion_id=$1 AND entry_status='active'`, id)
	if err != nil {
		return err
	}
	type ep struct{ entry, product int64 }
	eps, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (ep, error) {
		var x ep
		return x, r.Scan(&x.entry, &x.product)
	})
	if err != nil {
		return err
	}
	for _, x := range eps {
		if err := conflict(ctx, tx, x.product, x.entry, st.start, st.end); err != nil {
			return err
		}
	}
	_, err = tx.Exec(ctx, `UPDATE src.src_mkt_loop_promotion SET promotion_title=$2, subtitle=$3, banner_url=$4, description=$5, start_time=$6, end_time=$7,
		is_apply_open=$8, apply_deadline_time=$9, update_time=now() WHERE id=$1`, id, st.title, st.subtitle, st.banner, st.description, st.start, st.end,
		st.applyOpen, st.deadline)
	return err
}

// PromotionAction publishes (draft → scheduled / active) or cancels.
func (s *Service) PromotionAction(ctx context.Context, tx pgx.Tx, id int64, action string) error {
	var status string
	var ended bool
	err := tx.QueryRow(ctx, `SELECT promotion_status, end_time <= now() FROM src.src_mkt_loop_promotion WHERE id=$1 FOR UPDATE`, id).Scan(&status, &ended)
	if db.IsNoRows(err) {
		return httpx.NotFound("活动")
	}
	if err != nil {
		return err
	}
	switch {
	case action == "publish" && status == "draft" && !ended:
		_, err = tx.Exec(ctx, `UPDATE src.src_mkt_loop_promotion SET promotion_status='published', update_time=now() WHERE id=$1`, id)
	case action == "cancel" && status != "cancelled" && !ended:
		_, err = tx.Exec(ctx, `UPDATE src.src_mkt_loop_promotion SET promotion_status='cancelled', update_time=now() WHERE id=$1`, id)
	case action == "publish":
		return httpx.Conflict("invalid_status", "只有未结束的草稿可以发布")
	default:
		return httpx.Conflict("invalid_status", "这个活动不能取消")
	}
	return err
}

// ---------------------------------------------------------------- entries

// Entry is PromotionEntry.
type Entry struct {
	ID          int64 `json:"id"`
	PromotionID int64 `json:"promotion_id"`
	// Promotion: the activity this entry belongs to (商户「我的报名」展示用)
	Promotion          EntryPromotion `json:"promotion"`
	Product            Product        `json:"product"`
	Merchant           Ref            `json:"merchant"`
	PromoPriceAmt      int            `json:"promo_price_amt"`
	PlatformSubsidyAmt int            `json:"platform_subsidy_amt"`
	PromoStockQty      *int           `json:"promo_stock_qty"`
	PromoSoldQty       int            `json:"promo_sold_qty"`
	SortNo             int            `json:"sort_no"`
	Source             string         `json:"source"`
	Status             string         `json:"status"`
	Note               string         `json:"note"`
	CreatedAt          time.Time      `json:"created_at"`
	DecidedAt          *time.Time     `json:"decided_at"`

	productID int64
}

// EntryPromotion is the brief of an entry's promotion.
type EntryPromotion struct {
	ID       int64     `json:"id"`
	Title    string    `json:"title"`
	StartsAt time.Time `json:"starts_at"`
	EndsAt   time.Time `json:"ends_at"`
	Status   string    `json:"status"`
}

// EntryFilter filters the entry lists.
type EntryFilter struct {
	PromotionID, MerchantID int64
	Status                  string
}

func (s *Service) queryEntries(ctx context.Context, q db.Querier, where string, args ...any) ([]Entry, error) {
	rows, err := q.Query(ctx, `SELECT e.id, e.promotion_id, e.product_id, e.merchant_id, m.merchant_name, e.promo_price_amt, e.platform_subsidy_amt,
			e.promo_stock_qty, e.promo_sold_qty, e.sort_no, e.source_type, e.entry_status, e.note, e.create_time, e.decide_time,
			pr.promotion_title, pr.start_time, pr.end_time, `+promotionStatusSQL+`
		FROM src.src_mkt_loop_promotion_entry e JOIN src.src_mer_loop_merchant m ON m.id=e.merchant_id
		JOIN src.src_mkt_loop_promotion pr ON pr.id=e.promotion_id WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	es, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Entry, error) {
		var x Entry
		err := r.Scan(&x.ID, &x.PromotionID, &x.productID, &x.Merchant.ID, &x.Merchant.Name, &x.PromoPriceAmt, &x.PlatformSubsidyAmt,
			&x.PromoStockQty, &x.PromoSoldQty, &x.SortNo, &x.Source, &x.Status, &x.Note, &x.CreatedAt, &x.DecidedAt,
			&x.Promotion.Title, &x.Promotion.StartsAt, &x.Promotion.EndsAt, &x.Promotion.Status)
		x.Promotion.ID = x.PromotionID
		return x, err
	})
	if err != nil {
		return nil, err
	}
	if len(es) == 0 {
		return []Entry{}, nil
	}
	ids := make([]int64, len(es))
	for i, x := range es {
		ids[i] = x.productID
	}
	ps, err := s.query(ctx, q, `p.id = ANY($1)`, ids)
	if err != nil {
		return nil, err
	}
	byID := map[int64]Product{}
	for _, p := range ps {
		byID[p.ID] = p
	}
	for i := range es {
		es[i].Product = byID[es[i].productID]
	}
	return es, nil
}

// Entries lists entries (sort_no order within a promotion).
func (s *Service) Entries(ctx context.Context, f EntryFilter) ([]Entry, error) {
	return s.queryEntries(ctx, s.Pool, `($1 = 0 OR e.promotion_id=$1) AND ($2 = 0 OR e.merchant_id=$2) AND ($3 = '' OR e.entry_status=$3)
		ORDER BY e.promotion_id DESC, e.sort_no, e.id LIMIT 500`, f.PromotionID, f.MerchantID, f.Status)
}

// LoadEntry loads one entry (scope: a merchant's own).
func (s *Service) LoadEntry(ctx context.Context, q db.Querier, scope *int64, id int64) (Entry, error) {
	es, err := s.queryEntries(ctx, q, `e.id=$1 AND ($2::bigint IS NULL OR e.merchant_id=$2)`, id, scope)
	if err != nil {
		return Entry{}, err
	}
	if len(es) == 0 {
		return Entry{}, httpx.NotFound("活动条目")
	}
	return es[0], nil
}

// conflict: the product may be in one active entry at a time over
// overlapping promotion times (409 promotion_conflict).
func conflict(ctx context.Context, tx pgx.Tx, product, entry int64, start, end time.Time) error {
	var clash bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_mkt_loop_promotion_entry e JOIN src.src_mkt_loop_promotion pr ON pr.id=e.promotion_id
		WHERE e.product_id=$1 AND e.id<>$2 AND e.entry_status='active' AND pr.promotion_status <> 'cancelled' AND pr.start_time < $4 AND pr.end_time > $3)`,
		product, entry, start, end).Scan(&clash); err != nil {
		return err
	}
	if clash {
		return httpx.Conflict("promotion_conflict", "这个商品在同一时间已经参加了别的官方活动")
	}
	return nil
}

// EntryInput is the body of the entry endpoints.
type EntryInput struct {
	ProductID          int64   `json:"product_id"`
	PromoPriceAmt      *int    `json:"promo_price_amt"`
	PlatformSubsidyAmt *int    `json:"platform_subsidy_amt"`
	PromoStockQty      *int    `json:"promo_stock_qty"`
	SortNo             *int    `json:"sort_no"`
	Note               *string `json:"note"`
}

// promoFor locks a promotion open for entries (not cancelled or ended).
func promoFor(ctx context.Context, tx pgx.Tx, id int64, merchant bool) (start, end time.Time, applyOpen bool, err error) {
	var status string
	err = tx.QueryRow(ctx, `SELECT promotion_status, start_time, end_time, `+applyOpenSQL+` FROM src.src_mkt_loop_promotion pr WHERE id=$1 FOR UPDATE`, id).
		Scan(&status, &start, &end, &applyOpen)
	if db.IsNoRows(err) || (err == nil && merchant && status != "published") {
		return start, end, false, httpx.NotFound("活动")
	}
	if err != nil {
		return
	}
	if status == "cancelled" || !end.After(time.Now()) {
		return start, end, false, httpx.Conflict("invalid_status", "活动已取消或已结束")
	}
	return
}

func (in EntryInput) check(price int) error {
	if in.PromoPriceAmt != nil && (*in.PromoPriceAmt < 1 || *in.PromoPriceAmt > price) {
		return bad("活动价应在 1 分到商品售价之间")
	}
	if in.PlatformSubsidyAmt != nil && (*in.PlatformSubsidyAmt < 0 || *in.PlatformSubsidyAmt > 1_000_000) {
		return bad("平台补贴应在 0–1000000 分之间")
	}
	if in.PromoStockQty != nil && (*in.PromoStockQty < 0 || *in.PromoStockQty > 1_000_000) {
		return bad("活动库存应在 0–1000000 之间（不限请传 null）")
	}
	return nil
}

// PickEntry is POST /admin/v1/promotions/{id}/entries: the platform picks
// an on-sale product the merchant authorised (409 not_authorized). At the
// product's price the entry is active at once; below it the merchant has
// to accept first (pending_merchant).
func (s *Service) PickEntry(ctx context.Context, tx pgx.Tx, adminID, promotionID int64, in EntryInput) (int64, error) {
	start, end, _, err := promoFor(ctx, tx, promotionID, false)
	if err != nil {
		return 0, err
	}
	p, err := s.lockAny(ctx, tx, in.ProductID)
	if err != nil {
		return 0, err
	}
	if !p.AllowPromotion {
		return 0, httpx.Conflict("not_authorized", "商户没有授权这个商品进入官方活动")
	}
	if !p.sellable() {
		return 0, errNotOnSale
	}
	if err := in.check(p.PriceAmt); err != nil {
		return 0, err
	}
	price := p.PriceAmt
	if in.PromoPriceAmt != nil {
		price = *in.PromoPriceAmt
	}
	status, event := "active", webhook.PromotionEntryApproved
	if price < p.PriceAmt {
		status, event = "pending_merchant", webhook.PromotionEntryInvited
	} else if err := conflict(ctx, tx, p.ID, 0, start, end); err != nil {
		return 0, err
	}
	subsidy, sortNo := 0, 0
	if in.PlatformSubsidyAmt != nil {
		subsidy = *in.PlatformSubsidyAmt
	}
	if in.SortNo != nil {
		sortNo = *in.SortNo
	}
	var decide any
	if status == "active" {
		decide = time.Now()
	}
	return s.insertEntry(ctx, tx, `INSERT INTO src.src_mkt_loop_promotion_entry (promotion_id, product_id, merchant_id, promo_price_amt, platform_subsidy_amt,
			promo_stock_qty, sort_no, source_type, entry_status, decide_time, create_admin_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7,'platform',$8,$9,$10) RETURNING id`, p.Merchant.ID, event,
		promotionID, p.ID, p.Merchant.ID, price, subsidy, in.PromoStockQty, sortNo, status, decide, adminID)
}

func (s *Service) insertEntry(ctx context.Context, tx pgx.Tx, sql string, merchant int64, event string, args ...any) (int64, error) {
	var id int64
	err := tx.QueryRow(ctx, sql, args...).Scan(&id)
	if db.IsUniqueViolation(err) {
		return 0, httpx.Conflict("entry_exists", "这个商品已经在活动里了")
	}
	if err != nil {
		return 0, err
	}
	if event == "" {
		return id, nil
	}
	return id, s.emitEntry(ctx, tx, merchant, id, event)
}

func (s *Service) emitEntry(ctx context.Context, tx pgx.Tx, merchant, id int64, event string) error {
	x, err := s.LoadEntry(ctx, tx, nil, id)
	if err != nil {
		return err
	}
	return webhook.Emit(ctx, tx, merchant, event, x)
}

// lockAny locks and loads a product of any merchant (not archived).
func (s *Service) lockAny(ctx context.Context, tx pgx.Tx, id int64) (Product, error) {
	var merchant int64
	err := tx.QueryRow(ctx, `SELECT merchant_id FROM src.src_mer_loop_product WHERE id=$1 AND NOT is_archived FOR UPDATE`, id).Scan(&merchant)
	if db.IsNoRows(err) {
		return Product{}, httpx.NotFound("商品")
	}
	if err != nil {
		return Product{}, err
	}
	return s.load(ctx, tx, &merchant, id)
}

// Apply is POST /admin/v1/promotions/{id}/apply (merchant staff, open API):
// an on-sale product of the merchant applies while the promotion is open
// for applications; the platform reviews it (pending_platform).
func (s *Service) Apply(ctx context.Context, tx pgx.Tx, a Actor, promotionID int64, in EntryInput) (int64, error) {
	_, _, open, err := promoFor(ctx, tx, promotionID, true)
	if err != nil {
		return 0, err
	}
	if !open {
		return 0, httpx.Conflict("apply_closed", "这个活动现在不接受报名")
	}
	p, err := s.lock(ctx, tx, a.MerchantID, in.ProductID)
	if err != nil {
		return 0, err
	}
	if !p.sellable() {
		return 0, errNotOnSale
	}
	in.PlatformSubsidyAmt, in.SortNo = nil, nil
	if err := in.check(p.PriceAmt); err != nil {
		return 0, err
	}
	price := p.PriceAmt
	if in.PromoPriceAmt != nil {
		price = *in.PromoPriceAmt
	}
	var admin any
	if a.AdminID != 0 {
		admin = a.AdminID
	}
	return s.insertEntry(ctx, tx, `INSERT INTO src.src_mkt_loop_promotion_entry (promotion_id, product_id, merchant_id, promo_price_amt, promo_stock_qty,
			source_type, entry_status, create_admin_id) VALUES ($1,$2,$3,$4,$5,'merchant','pending_platform',$6) RETURNING id`, a.MerchantID, "",
		promotionID, p.ID, a.MerchantID, price, in.PromoStockQty, admin)
}

// Entry actions: the platform's (approve, reject, remove, patch) and the
// merchant's (accept, decline, withdraw).
const (
	EntryApprove  = "approve"
	EntryReject   = "reject"
	EntryRemove   = "remove"
	EntryPatch    = "patch"
	EntryAccept   = "accept"
	EntryDecline  = "decline"
	EntryWithdraw = "withdraw"
)

// EntryAction changes an entry; scope is the merchant for merchant
// actions (other merchants' entries are 404).
func (s *Service) EntryAction(ctx context.Context, tx pgx.Tx, scope *int64, id int64, action string, in EntryInput) error {
	var status string
	var merchant, product, promotion int64
	err := tx.QueryRow(ctx, `SELECT entry_status, merchant_id, product_id, promotion_id FROM src.src_mkt_loop_promotion_entry
		WHERE id=$1 AND ($2::bigint IS NULL OR merchant_id=$2) FOR UPDATE`, id, scope).Scan(&status, &merchant, &product, &promotion)
	if db.IsNoRows(err) {
		return httpx.NotFound("活动条目")
	}
	if err != nil {
		return err
	}
	note := ""
	if in.Note != nil {
		note = strings.TrimSpace(*in.Note)
	}
	if utf8.RuneCountInString(note) > 200 {
		return bad("备注最多 200 字")
	}
	set := func(to, event string) error {
		if _, err := tx.Exec(ctx, `UPDATE src.src_mkt_loop_promotion_entry SET entry_status=$2, note=CASE WHEN $3 = '' THEN note ELSE $3 END,
			decide_time=now(), update_time=now() WHERE id=$1`, id, to, note); err != nil {
			return err
		}
		if event == "" {
			return nil
		}
		return s.emitEntry(ctx, tx, merchant, id, event)
	}
	activate := func() error {
		var start, end time.Time
		var promoStatus string
		if err := tx.QueryRow(ctx, `SELECT start_time, end_time, promotion_status FROM src.src_mkt_loop_promotion WHERE id=$1`, promotion).
			Scan(&start, &end, &promoStatus); err != nil {
			return err
		}
		if promoStatus == "cancelled" || !end.After(time.Now()) {
			return httpx.Conflict("invalid_status", "活动已取消或已结束")
		}
		if _, err := tx.Exec(ctx, `SELECT 1 FROM src.src_mer_loop_product WHERE id=$1 FOR UPDATE`, product); err != nil {
			return err
		}
		return conflict(ctx, tx, product, id, start, end)
	}
	wrong := httpx.Conflict("invalid_status", "当前状态不能这样操作")
	switch action {
	case EntryApprove:
		if status != "pending_platform" {
			return wrong
		}
		if err := in.check(1 << 30); err != nil {
			return err
		}
		if err := activate(); err != nil {
			return err
		}
		if in.PlatformSubsidyAmt != nil {
			if _, err := tx.Exec(ctx, `UPDATE src.src_mkt_loop_promotion_entry SET platform_subsidy_amt=$2 WHERE id=$1`, id, *in.PlatformSubsidyAmt); err != nil {
				return err
			}
		}
		return set("active", webhook.PromotionEntryApproved)
	case EntryReject:
		if status != "pending_platform" {
			return wrong
		}
		if note == "" {
			note = "未通过活动审核"
		}
		return set("rejected", webhook.PromotionEntryRejected)
	case EntryRemove:
		if status != "active" && status != "pending_merchant" && status != "pending_platform" {
			return wrong
		}
		if note == "" {
			return bad("请填写移除原因")
		}
		return set("removed", webhook.PromotionEntryRemoved)
	case EntryAccept:
		if status != "pending_merchant" {
			return wrong
		}
		if err := activate(); err != nil {
			return err
		}
		return set("active", webhook.PromotionEntryApproved)
	case EntryDecline:
		if status != "pending_merchant" {
			return wrong
		}
		return set("rejected", webhook.PromotionEntryRejected)
	case EntryWithdraw:
		if status != "active" && status != "pending_merchant" && status != "pending_platform" {
			return wrong
		}
		return set("withdrawn", "")
	case EntryPatch:
		if status != "active" && status != "pending_merchant" && status != "pending_platform" {
			return wrong
		}
		if err := in.check(1 << 30); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE src.src_mkt_loop_promotion_entry SET sort_no=COALESCE($2, sort_no), platform_subsidy_amt=COALESCE($3, platform_subsidy_amt),
			update_time=now() WHERE id=$1`, id, in.SortNo, in.PlatformSubsidyAmt)
		return err
	}
	return bad("未知操作")
}

// PendingApplications counts merchant applications waiting for the
// platform (总览待办 promotion_apply).
func PendingApplications(ctx context.Context, q db.Querier) (int, error) {
	var n int
	err := q.QueryRow(ctx, `SELECT count(*) FROM src.src_mkt_loop_promotion_entry e JOIN src.src_mkt_loop_promotion pr ON pr.id=e.promotion_id
		WHERE e.entry_status='pending_platform' AND pr.promotion_status <> 'cancelled' AND pr.end_time > now()`).Scan(&n)
	return n, err
}

// ---------------------------------------------------------------- app

// AppPromotions is GET /v1/promotions: active and upcoming promotions.
func (s *Service) AppPromotions(ctx context.Context) ([]Promotion, error) {
	return queryPromotions(ctx, s.Pool, `pr.promotion_status='published' AND pr.end_time > now() ORDER BY pr.start_time, pr.id LIMIT 50`)
}

// AppPromotion is GET /v1/promotions/{id}: the promotion and the products
// of its active entries, each with this promotion's price.
func (s *Service) AppPromotion(ctx context.Context, id int64) (Promotion, error) {
	x, err := s.LoadPromotion(ctx, s.Pool, id, true)
	if err != nil {
		return x, err
	}
	es, err := s.queryEntries(ctx, s.Pool, `e.promotion_id=$1 AND e.entry_status='active' ORDER BY e.sort_no, e.id`, id)
	if err != nil {
		return x, err
	}
	items := []AppProduct{}
	for _, e := range es {
		if !e.Product.sellable() {
			continue
		}
		a := e.Product.App()
		pp := &PromotionPrice{ID: x.ID, Title: x.Title, PromoPriceAmt: e.PromoPriceAmt, EndsAt: x.EndsAt}
		if e.PromoStockQty != nil {
			left := max(0, *e.PromoStockQty-e.PromoSoldQty)
			pp.PromoLeftQty = &left
		}
		a.Promotion = pp
		items = append(items, a)
	}
	x.Items = &items
	return x, nil
}
