package perks

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

// Handler serves the app endpoints.
type Handler struct{ Svc *Service }

// Routes registers /v1 endpoints.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /v1/me/coupons", auth(h.coupons))
	mux.Handle("GET /v1/coupons/{id}/qr", auth(h.qr))
	mux.Handle("POST /v1/drops/{id}/claim", auth(h.claim))
	mux.Handle("GET /v1/brand-campaigns", auth(h.campaigns))
}

func (h *Handler) coupons(w http.ResponseWriter, r *http.Request) error {
	st := r.URL.Query().Get("status")
	switch st {
	case "", "unused", "used", "expired", "voided":
	default:
		return httpx.BadRequest("invalid_status", "status 只能是 unused / used / expired")
	}
	items, err := h.Svc.MyCoupons(r.Context(), httpx.UserID(r.Context()), st)
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *Handler) qr(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	p, err := h.Svc.QR(r.Context(), httpx.UserID(r.Context()), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"payload": p, "expires_in_sec": int(QRTTL.Seconds())})
}

func (h *Handler) claim(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var p LatLng
	if err := httpx.Decode(r, &p); err != nil {
		return err
	}
	c, err := h.Svc.Claim(r.Context(), httpx.UserID(r.Context()), id, p.Lat, p.Lng)
	if err != nil {
		return err
	}
	return httpx.OK(w, c)
}

func (h *Handler) campaigns(w http.ResponseWriter, r *http.Request) error {
	items, err := h.Svc.AppCampaigns(r.Context())
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

// ---------------------------------------------------------------- admin

// AdminHandler serves the /admin/v1 perk, campaign and settlement endpoints.
type AdminHandler struct {
	Svc   *Service
	Audit func(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error
	// Scope returns the merchant an admin is limited to (admin.MerchantScope).
	Scope func(ctx context.Context) (*int64, error)
}

// Guards for AdminHandler.Routes.
type Guards struct {
	// Ops: admin, ops. Admin: admin only. Redeem: admin, ops, merchant.
	// Settle: admin, merchant (merchant staff read their own).
	Ops, Admin, Redeem, Settle func(httpx.HandlerFunc) http.Handler
}

// Routes registers the admin endpoints.
func (h *AdminHandler) Routes(mux *http.ServeMux, g Guards) {
	mux.Handle("GET /admin/v1/drops", g.Ops(h.drops))
	mux.Handle("POST /admin/v1/drops", g.Ops(h.createDrop))
	mux.Handle("GET /admin/v1/drops/{id}", g.Ops(h.drop))
	mux.Handle("PATCH /admin/v1/drops/{id}", g.Ops(h.patchDrop))
	mux.Handle("POST /admin/v1/drops/{id}/pause", g.Ops(h.pauseDrop(true)))
	mux.Handle("POST /admin/v1/drops/{id}/resume", g.Ops(h.pauseDrop(false)))

	mux.Handle("GET /admin/v1/brand-campaigns", g.Ops(h.campaigns))
	mux.Handle("POST /admin/v1/brand-campaigns", g.Ops(h.createCampaign))
	mux.Handle("GET /admin/v1/brand-campaigns/{id}", g.Ops(h.campaign))
	mux.Handle("PATCH /admin/v1/brand-campaigns/{id}", g.Ops(h.patchCampaign))
	for _, a := range []string{"pause", "resume", "launch"} {
		mux.Handle("POST /admin/v1/brand-campaigns/{id}/"+a, g.Ops(h.campaignAction(a)))
	}

	mux.Handle("POST /admin/v1/redemptions", g.Redeem(h.redeem))
	mux.Handle("GET /admin/v1/redemptions", g.Redeem(h.redemptions))

	mux.Handle("GET /admin/v1/settlement/overview", g.Settle(h.overview))
	mux.Handle("GET /admin/v1/statements", g.Settle(h.statements))
	mux.Handle("GET /admin/v1/statements/{id}", g.Settle(h.statement))
	mux.Handle("POST /admin/v1/statements/{id}/confirm", g.Admin(h.statementAction("confirm")))
	mux.Handle("POST /admin/v1/statements/{id}/paid", g.Admin(h.statementAction("paid")))
	mux.Handle("POST /admin/v1/statements/generate", g.Admin(h.generate))
}

func qInt(r *http.Request, k string) int64 {
	n, _ := strconv.ParseInt(r.URL.Query().Get(k), 10, 64)
	return n
}

func adminID(r *http.Request) int64 {
	ad, _ := httpx.AdminFrom(r.Context())
	return ad.ID
}

// scopedMerchant applies the merchant scope to a ?merchant_id= filter.
func (h *AdminHandler) scopedMerchant(r *http.Request) (int64, *int64, error) {
	scope, err := h.Scope(r.Context())
	if err != nil {
		return 0, nil, err
	}
	if scope != nil {
		return *scope, scope, nil
	}
	return qInt(r, "merchant_id"), nil, nil
}

// --- drops

func (h *AdminHandler) drops(w http.ResponseWriter, r *http.Request) error {
	q := r.URL.Query()
	items, total, err := h.Svc.AdminDrops(r.Context(), DropFilter{MerchantID: qInt(r, "merchant_id"), CampaignID: qInt(r, "campaign_id"),
		Type: q.Get("type"), Status: q.Get("status")}, httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) drop(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	d, err := LoadDrop(r.Context(), h.Svc.Pool, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, d)
}

func (h *AdminHandler) createDrop(w http.ResponseWriter, r *http.Request) error {
	var in DropInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	var id int64
	err := pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		var err error
		if id, err = h.Svc.CreateDrop(r.Context(), tx, adminID(r), in); err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, "drop.create", "drop:"+itoa(id), map[string]any{"type": in.Type, "name": in.Name, "merchant_id": in.MerchantID})
	})
	if err != nil {
		return err
	}
	r.SetPathValue("id", itoa(id))
	return h.drop(w, r)
}

func (h *AdminHandler) patchDrop(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	in, err := h.Svc.DropInputOf(r.Context(), id)
	if err != nil {
		return err
	}
	typ := in.Type
	if err := httpx.Decode(r, &in); err != nil { // fields left out keep their value
		return err
	}
	if in.Type != typ {
		return bad("投放类型不能修改")
	}
	err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		if err := h.Svc.UpdateDrop(r.Context(), tx, id, in); err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, "drop.update", "drop:"+itoa(id), map[string]any{"name": in.Name})
	})
	if err != nil {
		return err
	}
	return h.drop(w, r)
}

func (h *AdminHandler) pauseDrop(on bool) httpx.HandlerFunc {
	action := "drop.resume"
	if on {
		action = "drop.pause"
	}
	return func(w http.ResponseWriter, r *http.Request) error {
		id, err := httpx.PathID(r, "id")
		if err != nil {
			return err
		}
		err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
			if err := h.Svc.PauseDrop(r.Context(), tx, id, on); err != nil {
				return err
			}
			return h.Audit(r.Context(), tx, action, "drop:"+itoa(id), nil)
		})
		if err != nil {
			return err
		}
		return h.drop(w, r)
	}
}

// --- campaigns

func (h *AdminHandler) campaigns(w http.ResponseWriter, r *http.Request) error {
	items, total, err := h.Svc.AdminCampaigns(r.Context(), r.URL.Query().Get("status"), qInt(r, "merchant_id"), httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) campaign(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	c, err := LoadCampaign(r.Context(), h.Svc.Pool, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, c)
}

func (h *AdminHandler) createCampaign(w http.ResponseWriter, r *http.Request) error {
	var in CampaignInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	var id int64
	err := pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		var err error
		if id, err = h.Svc.CreateCampaign(r.Context(), tx, adminID(r), in); err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, "brand_campaign.create", "brand_campaign:"+itoa(id), map[string]any{"title": in.Title, "merchant_id": in.MerchantID})
	})
	if err != nil {
		return err
	}
	r.SetPathValue("id", itoa(id))
	return h.campaign(w, r)
}

func (h *AdminHandler) patchCampaign(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	in, err := h.Svc.CampaignInputOf(r.Context(), id)
	if err != nil {
		return err
	}
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		if err := h.Svc.UpdateCampaign(r.Context(), tx, id, in); err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, "brand_campaign.update", "brand_campaign:"+itoa(id), map[string]any{"title": in.Title})
	})
	if err != nil {
		return err
	}
	return h.campaign(w, r)
}

func (h *AdminHandler) campaignAction(action string) httpx.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		id, err := httpx.PathID(r, "id")
		if err != nil {
			return err
		}
		err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
			if err := h.Svc.CampaignAction(r.Context(), tx, id, action); err != nil {
				return err
			}
			return h.Audit(r.Context(), tx, "brand_campaign."+action, "brand_campaign:"+itoa(id), nil)
		})
		if err != nil {
			return err
		}
		return h.campaign(w, r)
	}
}

// --- redemptions

func (h *AdminHandler) redeem(w http.ResponseWriter, r *http.Request) error {
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	var in RedeemInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	x, err := h.Svc.Redeem(r.Context(), scope, adminID(r), in)
	if err != nil {
		return err
	}
	if err := h.Audit(r.Context(), h.Svc.Pool, "redemption.create", "redemption:"+itoa(x.ID),
		map[string]any{"coupon_id": x.Coupon.ID, "merchant_id": x.Merchant.ID, "input": map[bool]string{true: "code", false: "payload"}[in.Payload == ""]}); err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"redemption": x})
}

func parseDate(v string) (*time.Time, error) {
	if v == "" {
		return nil, nil
	}
	t, err := time.ParseInLocation(time.DateOnly, v, clock.Shanghai)
	if err != nil {
		return nil, httpx.BadRequest("invalid_date", "日期格式应为 YYYY-MM-DD")
	}
	return &t, nil
}

func (h *AdminHandler) redemptions(w http.ResponseWriter, r *http.Request) error {
	m, _, err := h.scopedMerchant(r)
	if err != nil {
		return err
	}
	from, err := parseDate(r.URL.Query().Get("from"))
	if err != nil {
		return err
	}
	to, err := parseDate(r.URL.Query().Get("to"))
	if err != nil {
		return err
	}
	items, total, err := h.Svc.Redemptions(r.Context(), RedemptionFilter{MerchantID: m, From: from, To: to, Status: r.URL.Query().Get("status")}, httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

// --- settlement

func (h *AdminHandler) overview(w http.ResponseWriter, r *http.Request) error {
	m, _, err := h.scopedMerchant(r)
	if err != nil {
		return err
	}
	days := int(qInt(r, "days"))
	if days <= 0 {
		days = 7
	}
	days = min(days, 90)
	items, pending, err := h.Svc.Overview(r.Context(), m, days)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"days": items, "pending_statements": pending})
}

func (h *AdminHandler) statements(w http.ResponseWriter, r *http.Request) error {
	m, _, err := h.scopedMerchant(r)
	if err != nil {
		return err
	}
	items, total, err := h.Svc.Statements(r.Context(), m, r.URL.Query().Get("status"), httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) statement(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	x, err := h.Svc.LoadStatement(r.Context(), h.Svc.Pool, scope, id, true)
	if err != nil {
		return err
	}
	return httpx.OK(w, x)
}

func (h *AdminHandler) statementAction(action string) httpx.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		id, err := httpx.PathID(r, "id")
		if err != nil {
			return err
		}
		err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
			if err := h.Svc.StatementAction(r.Context(), tx, id, adminID(r), action); err != nil {
				return err
			}
			return h.Audit(r.Context(), tx, "statement."+action, "statement:"+itoa(id), nil)
		})
		if err != nil {
			return err
		}
		x, err := h.Svc.LoadStatement(r.Context(), h.Svc.Pool, nil, id, false)
		if err != nil {
			return err
		}
		return httpx.OK(w, x)
	}
}

func (h *AdminHandler) generate(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		PeriodStart string `json:"period_start"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	start, err := parseDate(req.PeriodStart)
	if err != nil || start == nil {
		return httpx.BadRequest("invalid_period", "period_start 格式应为 YYYY-MM-DD（周一）")
	}
	ids, err := h.Svc.Generate(r.Context(), *start, true)
	if err != nil {
		return err
	}
	if err := h.Audit(r.Context(), h.Svc.Pool, "statement.generate", "statements:"+req.PeriodStart, map[string]any{"generated": len(ids)}); err != nil {
		return err
	}
	items := make([]Statement, 0, len(ids))
	for _, id := range ids {
		x, err := h.Svc.LoadStatement(r.Context(), h.Svc.Pool, nil, id, false)
		if err != nil {
			return err
		}
		items = append(items, x)
	}
	return httpx.OK(w, httpx.NewItems(items))
}
