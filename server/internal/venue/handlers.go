package venue

import (
	"context"
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Handler serves the app endpoints.
type Handler struct{ Svc *Service }

// Routes registers /v1/venues and /v1/bookings.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /v1/venues", auth(h.list))
	mux.Handle("GET /v1/venues/{id}", auth(h.detail))
	mux.Handle("POST /v1/venues/{id}/checkin", auth(h.checkin))
	mux.Handle("GET /v1/venues/{id}/slots", auth(h.slots))
	mux.Handle("POST /v1/bookings", auth(h.book))
	mux.Handle("GET /v1/me/bookings", auth(h.myBookings))
	mux.Handle("GET /v1/bookings/{id}", auth(h.booking))
	mux.Handle("POST /v1/bookings/{id}/cancel", auth(h.cancel))
	mux.Handle("POST /v1/bookings/{id}/pay", auth(h.repay))
}

func uid(r *http.Request) int64 { return httpx.UserID(r.Context()) }

func floatQuery(r *http.Request, k string) *float64 {
	v, err := strconv.ParseFloat(r.URL.Query().Get(k), 64)
	if err != nil {
		return nil
	}
	return &v
}

func position(r *http.Request) *LatLng {
	lat, lng := floatQuery(r, "lat"), floatQuery(r, "lng")
	if lat == nil || lng == nil {
		return nil
	}
	p := LatLng{Lat: *lat, Lng: *lng}
	if !p.valid() {
		return nil
	}
	return &p
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) error {
	q := r.URL.Query()
	f := ListQuery{Sport: q.Get("sport"), At: position(r), Limit: 20}
	if rad := floatQuery(r, "radius_m"); rad != nil {
		f.RadiusM = *rad
	}
	if b, err := strconv.ParseBool(q.Get("bookable")); err == nil {
		f.Bookable = &b
	}
	if n, err := strconv.Atoi(q.Get("cursor")); err == nil && n > 0 {
		f.Offset = n
	}
	if n, err := strconv.Atoi(q.Get("limit")); err == nil && n > 0 {
		f.Limit = min(n, 50)
	}
	items, next, err := h.Svc.List(r.Context(), uid(r), f)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"items": items, "next_cursor": next})
}

func (h *Handler) detail(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	v, err := h.Svc.Detail(r.Context(), uid(r), id, position(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *Handler) checkin(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in CheckinInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	res, err := h.Svc.Checkin(r.Context(), uid(r), id, in)
	if err != nil {
		return err
	}
	return httpx.OK(w, res)
}

func (h *Handler) slots(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	date := r.URL.Query().Get("date")
	items, err := h.Svc.Slots(r.Context(), uid(r), id, date)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"date": date, "items": items})
}

func (h *Handler) book(w http.ResponseWriter, r *http.Request) error {
	var in BookingInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	b, params, err := h.Svc.CreateBooking(r.Context(), uid(r), in, httpx.ClientIP(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"booking": b, "pay_params": params})
}

func (h *Handler) myBookings(w http.ResponseWriter, r *http.Request) error {
	items, err := h.Svc.MyBookings(r.Context(), uid(r), r.URL.Query().Get("status"))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *Handler) booking(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	b, err := h.Svc.Booking(r.Context(), h.Svc.Pool, uid(r), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, b)
}

func (h *Handler) repay(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	b, params, err := h.Svc.Repay(r.Context(), uid(r), id, httpx.ClientIP(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"booking": b, "pay_params": params})
}

func (h *Handler) cancel(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	b, err := h.Svc.Cancel(r.Context(), uid(r), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, b)
}

// ---------------------------------------------------------------- admin

// AdminHandler serves /admin/v1 merchants, venues and bookings.
type AdminHandler struct {
	Svc   *Service
	Audit func(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error
	// Scope returns the merchant a staff account is limited to
	// (admin.MerchantScope).
	Scope func(ctx context.Context) (*int64, error)
}

// Routes registers the endpoints. ops is admin+ops, scoped admin+ops+merchant
// (merchant staff read their own merchant only), adminOnly admin.
func (h *AdminHandler) Routes(mux *http.ServeMux, ops, scoped, adminOnly func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /admin/v1/merchants", scoped(h.merchants))
	mux.Handle("POST /admin/v1/merchants", ops(h.createMerchant))
	mux.Handle("GET /admin/v1/merchants/{id}", scoped(h.merchant))
	mux.Handle("PATCH /admin/v1/merchants/{id}", ops(h.patchMerchant))
	mux.Handle("POST /admin/v1/merchants/{id}/reveal-phone", adminOnly(h.revealPhone))
	mux.Handle("POST /admin/v1/merchants/{id}/staff", adminOnly(h.createStaff))

	mux.Handle("GET /admin/v1/venues", ops(h.venues))
	mux.Handle("POST /admin/v1/venues", ops(h.createVenue))
	mux.Handle("GET /admin/v1/venues/{id}", ops(h.venue))
	mux.Handle("PATCH /admin/v1/venues/{id}", ops(h.patchVenue))
	mux.Handle("GET /admin/v1/venues/{id}/qr", ops(h.qr))
	mux.Handle("POST /admin/v1/venues/{id}/qr/rotate", ops(h.rotateQR))
	mux.Handle("GET /admin/v1/venues/{id}/owners", ops(h.owners))

	mux.Handle("GET /admin/v1/bookings", scoped(h.bookings))
	mux.Handle("POST /admin/v1/bookings/{id}/refund", adminOnly(h.refund))
}

func (h *AdminHandler) audit(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error {
	return h.Audit(ctx, q, action, target, detail)
}

func (h *AdminHandler) merchants(w http.ResponseWriter, r *http.Request) error {
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	items, total, err := h.Svc.Merchants(r.Context(), scope, r.URL.Query().Get("status"), r.URL.Query().Get("q"), httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) merchant(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	if scope != nil && *scope != id {
		return httpx.NotFound("商户")
	}
	d, err := h.Svc.MerchantDetail(r.Context(), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, d)
}

func (h *AdminHandler) createMerchant(w http.ResponseWriter, r *http.Request) error {
	var in MerchantInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	var m Merchant
	err := pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		id, err := h.Svc.CreateMerchant(r.Context(), tx, in)
		if err != nil {
			return err
		}
		if err := h.audit(r.Context(), tx, "merchant.create", "merchant:"+itoa(id), map[string]any{"name": in.Name}); err != nil {
			return err
		}
		m, err = h.Svc.Merchant(r.Context(), tx, id)
		return err
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, m)
}

func (h *AdminHandler) patchMerchant(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in MerchantInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	var m Merchant
	err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		if err := h.Svc.UpdateMerchant(r.Context(), tx, id, in); err != nil {
			return err
		}
		if err := h.audit(r.Context(), tx, "merchant.update", "merchant:"+itoa(id), map[string]any{"name": in.Name, "status": in.Status,
			"phone_changed": in.phoneSet}); err != nil {
			return err
		}
		m, err = h.Svc.Merchant(r.Context(), tx, id)
		return err
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, m)
}

func (h *AdminHandler) revealPhone(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	p, err := h.Svc.RevealPhone(r.Context(), id)
	if err != nil {
		return err
	}
	if err := h.audit(r.Context(), h.Svc.Pool, "merchant.reveal_phone", "merchant:"+itoa(id), nil); err != nil {
		return err
	}
	return httpx.OK(w, map[string]string{"phone": p})
}

func (h *AdminHandler) createStaff(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		staff, err := h.Svc.CreateStaff(r.Context(), tx, id, req.Username, req.Password)
		if err != nil {
			return err
		}
		return h.audit(r.Context(), tx, "merchant.staff_create", "admin:"+itoa(staff), map[string]any{"merchant_id": id, "username": req.Username})
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{})
}

func (h *AdminHandler) venues(w http.ResponseWriter, r *http.Request) error {
	q := r.URL.Query()
	var merchant *int64
	if n, err := strconv.ParseInt(q.Get("merchant_id"), 10, 64); err == nil && n > 0 {
		merchant = &n
	}
	items, total, err := h.Svc.AdminVenues(r.Context(), merchant, q.Get("sport"), q.Get("q"), httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) venue(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	v, err := h.Svc.AdminVenue(r.Context(), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *AdminHandler) saveVenue(w http.ResponseWriter, r *http.Request, id int64, in VenueInput) error {
	action := "venue.update"
	if id == 0 {
		action = "venue.create"
	}
	err := pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		var err error
		if id, err = h.Svc.SaveVenue(r.Context(), tx, id, in); err != nil {
			return err
		}
		return h.audit(r.Context(), tx, action, "venue:"+itoa(id), map[string]any{"input": in})
	})
	if err != nil {
		return err
	}
	v, err := h.Svc.AdminVenue(r.Context(), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *AdminHandler) createVenue(w http.ResponseWriter, r *http.Request) error {
	in := h.Svc.NewVenueInput()
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	return h.saveVenue(w, r, 0, in)
}

func (h *AdminHandler) patchVenue(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	in, err := h.Svc.InputOf(r.Context(), id)
	if err != nil {
		return err
	}
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	return h.saveVenue(w, r, id, in)
}

func (h *AdminHandler) qr(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	q, err := h.Svc.QRCode(r.Context(), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, q)
}

func (h *AdminHandler) rotateQR(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var q QR
	err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		var err error
		if q, err = h.Svc.RotateQR(r.Context(), tx, id); err != nil {
			return err
		}
		return h.audit(r.Context(), tx, "venue.qr_rotate", "venue:"+itoa(id), nil)
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, q)
}

func (h *AdminHandler) owners(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	items, err := h.Svc.Owners(r.Context(), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *AdminHandler) bookings(w http.ResponseWriter, r *http.Request) error {
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	q := r.URL.Query()
	venue, _ := strconv.ParseInt(q.Get("venue_id"), 10, 64)
	items, total, err := h.Svc.AdminBookings(r.Context(), scope, venue, q.Get("status"), q.Get("date"), httpx.GetPage(r))
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
	if r.ContentLength != 0 {
		if err := httpx.Decode(r, &req); err != nil {
			return err
		}
	}
	b, err := h.Svc.AdminRefund(r.Context(), id, req.Reason)
	if err != nil {
		return err
	}
	if err := h.audit(r.Context(), h.Svc.Pool, "booking.refund", "booking:"+itoa(id), map[string]any{"reason": req.Reason, "booking_no": b.BookingNo}); err != nil {
		return err
	}
	return httpx.OK(w, b)
}
