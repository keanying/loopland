package billing

import (
	"encoding/json"
	"io"
	"net/http"
	"time"

	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/user"
)

// Handler serves the app billing endpoints and payment callbacks.
type Handler struct{ Svc *Service }

// Routes registers the endpoints.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler, me func(w http.ResponseWriter, r *http.Request) error) {
	mux.Handle("GET /v1/plans", auth(h.plans))
	mux.Handle("POST /v1/orders", auth(h.create))
	mux.Handle("GET /v1/orders/{no}", auth(h.order))
	mux.Handle("POST /v1/iap/apple", auth(func(w http.ResponseWriter, r *http.Request) error {
		var req struct {
			SignedTransaction string `json:"signed_transaction"`
		}
		if err := httpx.Decode(r, &req); err != nil {
			return err
		}
		if err := h.Svc.AppleTransaction(r.Context(), httpx.UserID(r.Context()), req.SignedTransaction); err != nil {
			return err
		}
		return me(w, r)
	}))
	mux.Handle("GET /v1/membership", auth(h.membership))
	mux.Handle("POST /v1/membership/auto-renew", auth(h.autoRenew))
	mux.HandleFunc("POST /v1/pay/notify/wechat", func(w http.ResponseWriter, r *http.Request) { h.Svc.Notify(w, r, WeChatApp) })
	mux.HandleFunc("POST /v1/pay/notify/alipay", func(w http.ResponseWriter, r *http.Request) { h.Svc.Notify(w, r, AlipayApp) })
	mux.HandleFunc("POST /v1/pay/notify/apple", h.appleNotify)
	if h.Svc.Dev {
		mux.Handle("POST /v1/dev/orders/{no}/pay", auth(h.devPay))
	}
}

type planView struct {
	Plan
	OnSale *bool `json:"on_sale,omitempty"`
	Sort   *int  `json:"sort,omitempty"`
}

func (h *Handler) plans(w http.ResponseWriter, r *http.Request) error {
	var adult *bool
	if err := h.Svc.Pool.QueryRow(r.Context(), `SELECT is_adult FROM src.src_usr_user WHERE id=$1`, httpx.UserID(r.Context())).Scan(&adult); err != nil {
		return err
	}
	if adult != nil && !*adult {
		return httpx.OK(w, map[string]any{"items": []Plan{}, "minor_blocked": true})
	}
	ps, err := h.Svc.Plans(r.Context(), true)
	if err != nil {
		return err
	}
	items := make([]planView, len(ps))
	for i, p := range ps {
		items[i] = planView{Plan: p}
	}
	return httpx.OK(w, map[string]any{"items": items, "minor_blocked": false})
}

// MarshalJSON hides admin-only fields from the app.
func (p planView) MarshalJSON() ([]byte, error) {
	type alias struct {
		Code           string   `json:"code"`
		Name           string   `json:"name"`
		Period         string   `json:"period"`
		AutoRenew      bool     `json:"auto_renew"`
		PriceFen       int      `json:"price_fen"`
		FirstPriceFen  *int     `json:"first_price_fen"`
		RenewPriceFen  int      `json:"renew_price_fen"`
		Seats          int      `json:"seats"`
		Recommended    bool     `json:"recommended"`
		AppleProductID *string  `json:"apple_product_id"`
		Entitlements   []string `json:"entitlements"`
	}
	return json.Marshal(alias{p.Code, p.Name, p.Period, p.AutoRenew, p.PriceFen, p.FirstPriceFen, p.RenewPriceFen, p.Seats, p.Recommended, p.AppleProductID, p.Entitlements})
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		PlanCode string `json:"plan_code"`
		Channel  string `json:"channel"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	o, params, err := h.Svc.CreateOrder(r.Context(), httpx.UserID(r.Context()), req.PlanCode, req.Channel, r.Header.Get("X-Platform"), httpx.ClientIP(r))
	if err != nil {
		return err
	}
	o.User = nil
	return httpx.OK(w, map[string]any{"order": o, "pay_params": params})
}

func (h *Handler) order(w http.ResponseWriter, r *http.Request) error {
	o, err := h.Svc.GetOrder(r.Context(), h.Svc.Pool, r.PathValue("no"), httpx.UserID(r.Context()))
	if err != nil {
		return err
	}
	o.User = nil
	return httpx.OK(w, o)
}

func (h *Handler) membership(w http.ResponseWriter, r *http.Request) error {
	m, err := user.LoadMembership(r.Context(), h.Svc.Pool, httpx.UserID(r.Context()))
	if err != nil {
		return err
	}
	return httpx.OK(w, m)
}

func (h *Handler) autoRenew(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Enabled bool `json:"enabled"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if err := h.Svc.SetAutoRenew(r.Context(), httpx.UserID(r.Context()), req.Enabled); err != nil {
		return err
	}
	return h.membership(w, r)
}

func (h *Handler) appleNotify(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	var req struct {
		SignedPayload string `json:"signedPayload"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if err := h.Svc.AppleNotification(r.Context(), req.SignedPayload); err != nil {
		h.Svc.Log.Warn("apple notification", "err", err)
		http.Error(w, "retry", http.StatusInternalServerError) // Apple retries
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (h *Handler) devPay(w http.ResponseWriter, r *http.Request) error {
	o, err := h.Svc.GetOrder(r.Context(), h.Svc.Pool, r.PathValue("no"), httpx.UserID(r.Context()))
	if err != nil {
		return err
	}
	if o.Channel != Mock {
		return httpx.BadRequest("channel_not_allowed", "只有 mock 渠道的订单可以模拟支付")
	}
	if err := h.Svc.MarkPaid(r.Context(), Paid{OrderNo: o.OrderNo, TradeNo: "MOCK-" + o.OrderNo, AmountFen: o.AmountFen, PaidAt: time.Now()}, nil); err != nil {
		return err
	}
	return h.order(w, r)
}
