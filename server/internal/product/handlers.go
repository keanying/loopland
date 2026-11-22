package product

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func qInt(r *http.Request, k string) int64 {
	n, _ := strconv.ParseInt(r.URL.Query().Get(k), 10, 64)
	return n
}

func qBool(r *http.Request, k string) *bool {
	b, err := strconv.ParseBool(r.URL.Query().Get(k))
	if err != nil {
		return nil
	}
	return &b
}

// ParseDate parses an optional YYYY-MM-DD query value.
func ParseDate(v string) (*time.Time, error) {
	if v == "" {
		return nil, nil
	}
	t, err := time.ParseInLocation(time.DateOnly, v, clock.Shanghai)
	if err != nil {
		return nil, httpx.BadRequest("invalid_date", "日期格式应为 YYYY-MM-DD")
	}
	return &t, nil
}

// decodeOptional decodes a body that may be empty.
func decodeOptional(r *http.Request, v any) error {
	if r.ContentLength == 0 {
		return nil
	}
	return httpx.Decode(r, v)
}

// ---------------------------------------------------------------- app

// Handler serves the app endpoints.
type Handler struct{ Svc *Service }

// Routes registers /v1 products, product orders and promotions.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /v1/merchants/{id}/products", auth(h.merchantProducts))
	mux.Handle("GET /v1/products/{id}", auth(h.product))
	mux.Handle("POST /v1/products/{id}/orders", auth(h.buy))
	mux.Handle("GET /v1/me/product-orders", auth(h.myOrders))
	mux.Handle("GET /v1/product-orders/{id}", auth(h.order))
	mux.Handle("POST /v1/product-orders/{id}/pay", auth(h.repay))
	mux.Handle("POST /v1/product-orders/{id}/cancel", auth(h.cancel))
	mux.Handle("POST /v1/product-orders/{id}/refund", auth(h.refund))
	mux.Handle("GET /v1/promotions", auth(h.promotions))
	mux.Handle("GET /v1/promotions/{id}", auth(h.promotion))
}

func uid(r *http.Request) int64 { return httpx.UserID(r.Context()) }

func (h *Handler) merchantProducts(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	offset, _ := strconv.Atoi(r.URL.Query().Get("cursor"))
	items, next, err := h.Svc.MerchantProducts(r.Context(), id, max(offset, 0), 20)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"items": items, "next_cursor": next})
}

func (h *Handler) product(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	p, err := h.Svc.AppProduct(r.Context(), uid(r), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, p)
}

func (h *Handler) buy(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in OrderInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	o, params, err := h.Svc.CreateOrder(r.Context(), uid(r), id, in, httpx.ClientIP(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"order": o, "pay_params": params})
}

func (h *Handler) myOrders(w http.ResponseWriter, r *http.Request) error {
	items, err := h.Svc.MyOrders(r.Context(), uid(r), r.URL.Query().Get("status"))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *Handler) order(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	o, err := h.Svc.LoadOrder(r.Context(), h.Svc.Pool, uid(r), nil, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, o)
}

func (h *Handler) repay(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	o, params, err := h.Svc.Repay(r.Context(), uid(r), id, httpx.ClientIP(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"order": o, "pay_params": params})
}

func (h *Handler) cancel(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	o, err := h.Svc.Cancel(r.Context(), uid(r), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, o)
}

func (h *Handler) refund(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	o, err := h.Svc.UserRefund(r.Context(), uid(r), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, o)
}

func (h *Handler) promotions(w http.ResponseWriter, r *http.Request) error {
	items, err := h.Svc.AppPromotions(r.Context())
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *Handler) promotion(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	x, err := h.Svc.AppPromotion(r.Context(), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, x)
}

// ---------------------------------------------------------------- admin

// AdminHandler serves /admin/v1 products, product orders and promotions.
type AdminHandler struct {
	Svc   *Service
	Audit func(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error
	// Scope returns the merchant a staff account is limited to (admin.MerchantScope).
	Scope func(ctx context.Context) (*int64, error)
}

// Guards for AdminHandler.Routes (docs: product.read / product.write /
// product.ban / product_order.refund / promotion.manage / promotion.join).
type Guards struct {
	// Read: admin, ops, merchant (merchant staff see their own).
	Read func(httpx.HandlerFunc) http.Handler
	// Merchant: merchant staff only (product.write, promotion.join).
	Merchant func(httpx.HandlerFunc) http.Handler
	// Ops: admin, ops (product.ban, promotion.manage).
	Ops func(httpx.HandlerFunc) http.Handler
	// Admin: admin only (product_order.refund).
	Admin func(httpx.HandlerFunc) http.Handler
}

// Routes registers the admin endpoints.
func (h *AdminHandler) Routes(mux *http.ServeMux, g Guards) {
	mux.Handle("GET /admin/v1/products", g.Read(h.products))
	mux.Handle("POST /admin/v1/products", g.Merchant(h.create))
	mux.Handle("GET /admin/v1/products/{id}", g.Read(h.product))
	mux.Handle("PATCH /admin/v1/products/{id}", g.Merchant(h.patch))
	mux.Handle("DELETE /admin/v1/products/{id}", g.Merchant(h.delete))
	mux.Handle("POST /admin/v1/products/{id}/submit", g.Merchant(h.lifecycle("submit")))
	mux.Handle("POST /admin/v1/products/{id}/on-sale", g.Merchant(h.lifecycle("on_sale")))
	mux.Handle("POST /admin/v1/products/{id}/off-sale", g.Merchant(h.lifecycle("off_sale")))
	mux.Handle("POST /admin/v1/products/{id}/ban", g.Ops(h.ban))

	mux.Handle("GET /admin/v1/product-orders", g.Read(h.orders))
	mux.Handle("POST /admin/v1/product-orders/{id}/refund", g.Admin(h.refund))

	mux.Handle("GET /admin/v1/promotions", g.Read(h.promotions))
	mux.Handle("POST /admin/v1/promotions", g.Ops(h.createPromotion))
	mux.Handle("GET /admin/v1/promotions/{id}", g.Read(h.promotion))
	mux.Handle("PATCH /admin/v1/promotions/{id}", g.Ops(h.patchPromotion))
	mux.Handle("POST /admin/v1/promotions/{id}/publish", g.Ops(h.promotionAction("publish")))
	mux.Handle("POST /admin/v1/promotions/{id}/cancel", g.Ops(h.promotionAction("cancel")))
	mux.Handle("GET /admin/v1/promotions/{id}/entries", g.Ops(h.promotionEntries))
	mux.Handle("POST /admin/v1/promotions/{id}/entries", g.Ops(h.pick))
	mux.Handle("POST /admin/v1/promotions/{id}/apply", g.Merchant(h.apply))
	mux.Handle("GET /admin/v1/promotion-entries", g.Read(h.entries))
	for _, a := range []string{EntryApprove, EntryReject, EntryRemove} {
		mux.Handle("POST /admin/v1/promotion-entries/{id}/"+a, g.Ops(h.entryAction(a)))
	}
	mux.Handle("PATCH /admin/v1/promotion-entries/{id}", g.Ops(h.entryAction(EntryPatch)))
	for _, a := range []string{EntryAccept, EntryDecline, EntryWithdraw} {
		mux.Handle("POST /admin/v1/promotion-entries/{id}/"+a, g.Merchant(h.entryAction(a)))
	}
}

func adminID(r *http.Request) int64 {
	ad, _ := httpx.AdminFrom(r.Context())
	return ad.ID
}

// actor is the merchant staff account behind a write.
func (h *AdminHandler) actor(r *http.Request) (Actor, error) {
	scope, err := h.Scope(r.Context())
	if err != nil {
		return Actor{}, err
	}
	if scope == nil {
		return Actor{}, httpx.ErrForbidden
	}
	return Actor{MerchantID: *scope, AdminID: adminID(r)}, nil
}

func (h *AdminHandler) products(w http.ResponseWriter, r *http.Request) error {
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	q := r.URL.Query()
	f := ListFilter{MerchantID: qInt(r, "merchant_id"), Status: q.Get("status"), Q: q.Get("q"), AllowPromotion: qBool(r, "allow_promotion")}
	if scope != nil {
		f.MerchantID = *scope
	}
	items, total, err := h.Svc.List(r.Context(), f, httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) product(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	d, err := h.Svc.LoadDetail(r.Context(), scope, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, d)
}

// write runs fn and its audit record in one transaction, then answers with
// the product.
func (h *AdminHandler) write(w http.ResponseWriter, r *http.Request, scope *int64, action string, fn func(tx pgx.Tx) (int64, map[string]any, error)) error {
	var id int64
	err := pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		var detail map[string]any
		var err error
		if id, detail, err = fn(tx); err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, action, "product:"+itoa(id), detail)
	})
	if err != nil {
		return err
	}
	p, err := h.Svc.Load(r.Context(), scope, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, p)
}

func (h *AdminHandler) create(w http.ResponseWriter, r *http.Request) error {
	a, err := h.actor(r)
	if err != nil {
		return err
	}
	var in Input
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	return h.write(w, r, &a.MerchantID, "product.create", func(tx pgx.Tx) (int64, map[string]any, error) {
		id, err := h.Svc.Create(r.Context(), tx, a, in)
		return id, map[string]any{"title": in.Title, "type": in.Type}, err
	})
}

func (h *AdminHandler) patch(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	a, err := h.actor(r)
	if err != nil {
		return err
	}
	var in Input
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	return h.write(w, r, &a.MerchantID, "product.update", func(tx pgx.Tx) (int64, map[string]any, error) {
		fields := make([]string, 0, len(in.present))
		for k := range in.present {
			fields = append(fields, k)
		}
		return id, map[string]any{"fields": fields}, h.Svc.Update(r.Context(), tx, a, id, in)
	})
}

func (h *AdminHandler) delete(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	a, err := h.actor(r)
	if err != nil {
		return err
	}
	err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		archived, err := h.Svc.Delete(r.Context(), tx, a, id)
		if err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, "product.delete", "product:"+itoa(id), map[string]any{"archived": archived})
	})
	if err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (h *AdminHandler) lifecycle(action string) httpx.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		id, err := httpx.PathID(r, "id")
		if err != nil {
			return err
		}
		a, err := h.actor(r)
		if err != nil {
			return err
		}
		return h.write(w, r, &a.MerchantID, "product."+action, func(tx pgx.Tx) (int64, map[string]any, error) {
			switch action {
			case "submit":
				return id, nil, h.Svc.Submit(r.Context(), tx, a, id)
			case "on_sale":
				return id, nil, h.Svc.OnSale(r.Context(), tx, a, id)
			default:
				return id, nil, h.Svc.OffSale(r.Context(), tx, a, id)
			}
		})
	}
}

func (h *AdminHandler) ban(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Reason string `json:"reason"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	return h.write(w, r, nil, "product.ban", func(tx pgx.Tx) (int64, map[string]any, error) {
		return id, map[string]any{"reason": req.Reason}, h.Svc.Ban(r.Context(), tx, id, req.Reason)
	})
}

func (h *AdminHandler) orders(w http.ResponseWriter, r *http.Request) error {
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	from, err := ParseDate(r.URL.Query().Get("from"))
	if err != nil {
		return err
	}
	to, err := ParseDate(r.URL.Query().Get("to"))
	if err != nil {
		return err
	}
	f := OrderFilter{MerchantID: qInt(r, "merchant_id"), ProductID: qInt(r, "product_id"), Status: r.URL.Query().Get("status"), From: from, To: to}
	if scope != nil {
		f.MerchantID = *scope
	}
	items, total, err := h.Svc.AdminOrders(r.Context(), f, httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) refund(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Reason string `json:"reason"`
	}
	if err := decodeOptional(r, &req); err != nil {
		return err
	}
	o, err := h.Svc.AdminRefund(r.Context(), adminID(r), id, req.Reason)
	if err != nil {
		return err
	}
	if err := h.Audit(r.Context(), h.Svc.Pool, "product_order.refund", "product_order:"+itoa(id),
		map[string]any{"reason": req.Reason, "order_no": o.OrderNo, "refund_amt": o.RefundAmt}); err != nil {
		return err
	}
	return httpx.OK(w, o)
}

// --- promotions

func (h *AdminHandler) promotions(w http.ResponseWriter, r *http.Request) error {
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	items, total, err := h.Svc.Promotions(r.Context(), PromotionFilter{Status: r.URL.Query().Get("status"), ApplyOpen: qBool(r, "apply_open"),
		Merchant: scope != nil}, httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) promotion(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	x, err := h.Svc.LoadPromotion(r.Context(), h.Svc.Pool, id, scope != nil)
	if err != nil {
		return err
	}
	return httpx.OK(w, x)
}

func (h *AdminHandler) savePromotion(w http.ResponseWriter, r *http.Request, action string, fn func(tx pgx.Tx) (int64, error)) error {
	var id int64
	err := pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		var err error
		if id, err = fn(tx); err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, action, "promotion:"+itoa(id), nil)
	})
	if err != nil {
		return err
	}
	x, err := h.Svc.LoadPromotion(r.Context(), h.Svc.Pool, id, false)
	if err != nil {
		return err
	}
	return httpx.OK(w, x)
}

func (h *AdminHandler) createPromotion(w http.ResponseWriter, r *http.Request) error {
	var in PromotionInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	return h.savePromotion(w, r, "promotion.create", func(tx pgx.Tx) (int64, error) {
		return h.Svc.CreatePromotion(r.Context(), tx, adminID(r), in)
	})
}

func (h *AdminHandler) patchPromotion(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in PromotionInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	return h.savePromotion(w, r, "promotion.update", func(tx pgx.Tx) (int64, error) {
		return id, h.Svc.UpdatePromotion(r.Context(), tx, id, in)
	})
}

func (h *AdminHandler) promotionAction(action string) httpx.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		id, err := httpx.PathID(r, "id")
		if err != nil {
			return err
		}
		return h.savePromotion(w, r, "promotion."+action, func(tx pgx.Tx) (int64, error) {
			return id, h.Svc.PromotionAction(r.Context(), tx, id, action)
		})
	}
}

func (h *AdminHandler) promotionEntries(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	if _, err := h.Svc.LoadPromotion(r.Context(), h.Svc.Pool, id, false); err != nil {
		return err
	}
	items, err := h.Svc.Entries(r.Context(), EntryFilter{PromotionID: id, Status: r.URL.Query().Get("status")})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *AdminHandler) entries(w http.ResponseWriter, r *http.Request) error {
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	f := EntryFilter{PromotionID: qInt(r, "promotion_id"), MerchantID: qInt(r, "merchant_id"), Status: r.URL.Query().Get("status")}
	if scope != nil {
		f.MerchantID = *scope
	}
	items, err := h.Svc.Entries(r.Context(), f)
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

// saveEntry runs fn and its audit record in one transaction, then answers
// with the entry.
func (h *AdminHandler) saveEntry(w http.ResponseWriter, r *http.Request, scope *int64, action string, fn func(tx pgx.Tx) (int64, error)) error {
	var id int64
	err := pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		var err error
		if id, err = fn(tx); err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, action, "promotion_entry:"+itoa(id), nil)
	})
	if err != nil {
		return err
	}
	x, err := h.Svc.LoadEntry(r.Context(), h.Svc.Pool, scope, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, x)
}

func (h *AdminHandler) pick(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in EntryInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	return h.saveEntry(w, r, nil, "promotion_entry.pick", func(tx pgx.Tx) (int64, error) {
		return h.Svc.PickEntry(r.Context(), tx, adminID(r), id, in)
	})
}

func (h *AdminHandler) apply(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	a, err := h.actor(r)
	if err != nil {
		return err
	}
	var in EntryInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	return h.saveEntry(w, r, &a.MerchantID, "promotion_entry.apply", func(tx pgx.Tx) (int64, error) {
		return h.Svc.Apply(r.Context(), tx, a, id, in)
	})
}

func (h *AdminHandler) entryAction(action string) httpx.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		id, err := httpx.PathID(r, "id")
		if err != nil {
			return err
		}
		scope, err := h.Scope(r.Context())
		if err != nil {
			return err
		}
		var in EntryInput
		if err := decodeOptional(r, &in); err != nil {
			return err
		}
		return h.saveEntry(w, r, scope, "promotion_entry."+action, func(tx pgx.Tx) (int64, error) {
			return id, h.Svc.EntryAction(r.Context(), tx, scope, id, action, in)
		})
	}
}
