package openapi

import (
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/perks"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/product"
	"github.com/keanying/loopland/server/internal/venue"
)

// PageSize is the cursor page size.
const PageSize = 50

// Routes registers /open/v1.
func (s *Service) Routes(mux *http.ServeMux) {
	g := s.guard
	// products
	mux.Handle("GET /open/v1/products", g("products", s.products))
	mux.Handle("POST /open/v1/products", g("products", s.createProduct))
	mux.Handle("GET /open/v1/products/{id}", g("products", s.product))
	mux.Handle("PATCH /open/v1/products/{id}", g("products", s.patchProduct))
	mux.Handle("DELETE /open/v1/products/{id}", g("products", s.deleteProduct))
	mux.Handle("POST /open/v1/products/{id}/submit", g("products", s.productAction("submit")))
	mux.Handle("POST /open/v1/products/{id}/on-sale", g("products", s.productAction("on_sale")))
	mux.Handle("POST /open/v1/products/{id}/off-sale", g("products", s.productAction("off_sale")))
	mux.Handle("PUT /open/v1/products/{id}/stock", g("products", s.stock))
	// orders
	mux.Handle("GET /open/v1/product-orders", g("orders", s.orders))
	mux.Handle("GET /open/v1/product-orders/{id}", g("orders", s.order))
	// redemptions
	mux.Handle("POST /open/v1/redemptions", g("redemptions", s.redeem))
	mux.Handle("GET /open/v1/redemptions", g("redemptions", s.redemptions))
	mux.Handle("POST /open/v1/coupons/lookup", g("redemptions", s.lookup))
	// bookings
	mux.Handle("GET /open/v1/bookings", g("bookings", s.bookings))
	mux.Handle("GET /open/v1/bookings/{id}", g("bookings", s.booking))
	// venues and blocks
	mux.Handle("GET /open/v1/venues", g("venues", s.venues))
	mux.Handle("PATCH /open/v1/venues/{id}", g("venues", s.patchVenue))
	mux.Handle("GET /open/v1/venues/{id}/slots", g("venues", s.slots))
	mux.Handle("POST /open/v1/venues/{id}/blocks", g("venues", s.createBlock))
	mux.Handle("GET /open/v1/venues/{id}/blocks", g("venues", s.blocks))
	mux.Handle("DELETE /open/v1/venues/{id}/blocks/{block_id}", g("venues", s.deleteBlock))
	// promotions
	mux.Handle("GET /open/v1/promotions", g("promotions", s.promotions))
	mux.Handle("GET /open/v1/promotion-entries", g("promotions", s.entries))
	mux.Handle("POST /open/v1/promotions/{id}/apply", g("promotions", s.applyEntry))
	for _, a := range []string{product.EntryAccept, product.EntryDecline, product.EntryWithdraw} {
		mux.Handle("POST /open/v1/promotion-entries/{id}/"+a, g("promotions", s.entryAction(a)))
	}
	// statements
	mux.Handle("GET /open/v1/statements", g("statements", s.statements))
	mux.Handle("GET /open/v1/statements/{id}", g("statements", s.statement))
	// anything else under /open/v1 is a signed 404
	mux.Handle("/open/v1/", g("", func(http.ResponseWriter, *http.Request) error { return httpx.NotFound("接口") }))
}

func merchantOf(r *http.Request) int64 { return callerOf(r.Context()).app.Merchant.ID }

func actorOf(r *http.Request) product.Actor {
	a := callerOf(r.Context()).app
	return product.Actor{MerchantID: a.Merchant.ID, AppID: a.ID}
}

// cursor is the id the next page starts below (0: first page).
func cursor(r *http.Request) (int64, error) {
	c := r.URL.Query().Get("cursor")
	if c == "" {
		return 0, nil
	}
	n, err := strconv.ParseInt(c, 10, 64)
	if err != nil || n <= 0 {
		return 0, httpx.BadRequest("invalid_request", "cursor 不合法")
	}
	return n, nil
}

// page cuts a PageSize+1 result into a page and its next cursor.
func page[T any](items []T, id func(T) int64) map[string]any {
	var next *string
	if len(items) > PageSize {
		items = items[:PageSize]
		c := strconv.FormatInt(id(items[len(items)-1]), 10)
		next = &c
	}
	if items == nil {
		items = []T{}
	}
	return map[string]any{"items": items, "next_cursor": next}
}

func decode(r *http.Request, v any) error {
	b, err := readBody(r, maxBody)
	if err != nil {
		return err
	}
	return decodeStrict(b, v)
}

// --- products

func (s *Service) products(w http.ResponseWriter, r *http.Request) error {
	items, total, err := s.Products.List(r.Context(), product.ListFilter{MerchantID: merchantOf(r), Status: r.URL.Query().Get("status")}, httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (s *Service) product(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	m := merchantOf(r)
	d, err := s.Products.LoadDetail(r.Context(), &m, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, d)
}

// writeProduct runs fn in a transaction and answers with the product.
func (s *Service) writeProduct(w http.ResponseWriter, r *http.Request, fn func(tx pgx.Tx) (int64, error)) error {
	var id int64
	err := pgx.BeginFunc(r.Context(), s.Pool, func(tx pgx.Tx) error {
		var err error
		id, err = fn(tx)
		return err
	})
	if err != nil {
		return err
	}
	m := merchantOf(r)
	p, err := s.Products.Load(r.Context(), &m, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, p)
}

func (s *Service) createProduct(w http.ResponseWriter, r *http.Request) error {
	var in product.Input
	if err := decode(r, &in); err != nil {
		return err
	}
	return s.writeProduct(w, r, func(tx pgx.Tx) (int64, error) { return s.Products.Create(r.Context(), tx, actorOf(r), in) })
}

func (s *Service) patchProduct(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in product.Input
	if err := decode(r, &in); err != nil {
		return err
	}
	return s.writeProduct(w, r, func(tx pgx.Tx) (int64, error) { return id, s.Products.Update(r.Context(), tx, actorOf(r), id, in) })
}

func (s *Service) deleteProduct(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	err = pgx.BeginFunc(r.Context(), s.Pool, func(tx pgx.Tx) error {
		_, err := s.Products.Delete(r.Context(), tx, actorOf(r), id)
		return err
	})
	if err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Service) productAction(action string) httpx.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		id, err := httpx.PathID(r, "id")
		if err != nil {
			return err
		}
		return s.writeProduct(w, r, func(tx pgx.Tx) (int64, error) {
			switch action {
			case "submit":
				return id, s.Products.Submit(r.Context(), tx, actorOf(r), id)
			case "on_sale":
				return id, s.Products.OnSale(r.Context(), tx, actorOf(r), id)
			default:
				return id, s.Products.OffSale(r.Context(), tx, actorOf(r), id)
			}
		})
	}
}

func (s *Service) stock(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		StockQty *int `json:"stock_qty"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	return s.writeProduct(w, r, func(tx pgx.Tx) (int64, error) {
		return id, s.Products.SetStock(r.Context(), tx, actorOf(r), id, req.StockQty)
	})
}

// --- orders

func (s *Service) orders(w http.ResponseWriter, r *http.Request) error {
	c, err := cursor(r)
	if err != nil {
		return err
	}
	from, err := product.ParseDate(r.URL.Query().Get("from"))
	if err != nil {
		return err
	}
	to, err := product.ParseDate(r.URL.Query().Get("to"))
	if err != nil {
		return err
	}
	items, err := s.Products.OrdersBefore(r.Context(), product.OrderFilter{MerchantID: merchantOf(r), Status: r.URL.Query().Get("status"), From: from, To: to,
		BeforeID: c}, PageSize+1)
	if err != nil {
		return err
	}
	return httpx.OK(w, page(items, func(o product.Order) int64 { return o.ID }))
}

func (s *Service) order(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	m := merchantOf(r)
	o, err := s.Products.LoadOrder(r.Context(), s.Pool, 0, &m, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, o)
}

// --- redemptions

func (s *Service) redeem(w http.ResponseWriter, r *http.Request) error {
	var in perks.RedeemInput
	if err := decode(r, &in); err != nil {
		return err
	}
	m, app := merchantOf(r), callerOf(r.Context()).app.ID
	x, err := s.Perks.RedeemAs(r.Context(), perks.Operator{Scope: &m, AppID: app}, in)
	if err != nil {
		return err
	}
	return httpx.OK(w, x)
}

func (s *Service) redemptions(w http.ResponseWriter, r *http.Request) error {
	c, err := cursor(r)
	if err != nil {
		return err
	}
	from, err := product.ParseDate(r.URL.Query().Get("from"))
	if err != nil {
		return err
	}
	to, err := product.ParseDate(r.URL.Query().Get("to"))
	if err != nil {
		return err
	}
	items, _, err := s.Perks.Redemptions(r.Context(), perks.RedemptionFilter{MerchantID: merchantOf(r), From: from, To: to, BeforeID: c},
		httpx.Page{Page: 1, Size: PageSize + 1})
	if err != nil {
		return err
	}
	return httpx.OK(w, page(items, func(x perks.Redemption) int64 { return x.ID }))
}

func (s *Service) lookup(w http.ResponseWriter, r *http.Request) error {
	var in perks.RedeemInput
	if err := decode(r, &in); err != nil {
		return err
	}
	c, err := s.Perks.LookupCoupon(r.Context(), merchantOf(r), in)
	if err != nil {
		return err
	}
	return httpx.OK(w, c)
}

// --- bookings

func (s *Service) bookings(w http.ResponseWriter, r *http.Request) error {
	c, err := cursor(r)
	if err != nil {
		return err
	}
	q := r.URL.Query()
	venueID, _ := strconv.ParseInt(q.Get("venue_id"), 10, 64)
	items, err := s.Venues.BookingsBefore(r.Context(), merchantOf(r), venueID, q.Get("status"), q.Get("date"), c, PageSize+1)
	if err != nil {
		return err
	}
	return httpx.OK(w, page(items, func(b venue.Booking) int64 { return b.ID }))
}

func (s *Service) booking(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	b, err := s.Venues.MerchantBooking(r.Context(), merchantOf(r), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, b)
}

// --- venues

func (s *Service) venues(w http.ResponseWriter, r *http.Request) error {
	items, err := s.Venues.MerchantVenues(r.Context(), merchantOf(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (s *Service) patchVenue(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	body, err := readBody(r, maxBody)
	if err != nil {
		return err
	}
	err = pgx.BeginFunc(r.Context(), s.Pool, func(tx pgx.Tx) error {
		_, err := s.Venues.SelfUpdate(r.Context(), tx, merchantOf(r), id, body)
		return err
	})
	if err != nil {
		return err
	}
	v, err := s.Venues.OwnAdminVenue(r.Context(), merchantOf(r), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (s *Service) slots(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	if _, err := s.Venues.OwnAdminVenue(r.Context(), merchantOf(r), id); err != nil {
		return err
	}
	date := r.URL.Query().Get("date")
	items, err := s.Venues.Slots(r.Context(), 0, id, date)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"date": date, "items": items})
}

func (s *Service) createBlock(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in venue.BlockInput
	if err := decode(r, &in); err != nil {
		return err
	}
	b, _, err := s.Venues.CreateBlock(r.Context(), merchantOf(r), id, callerOf(r.Context()).app.ID, in)
	if err != nil {
		return err
	}
	return httpx.OK(w, b)
}

func (s *Service) blocks(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	m := merchantOf(r)
	items, err := s.Venues.Blocks(r.Context(), &m, id, r.URL.Query().Get("date"))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (s *Service) deleteBlock(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	bid, err := httpx.PathID(r, "block_id")
	if err != nil {
		return err
	}
	if err := s.Venues.DeleteBlock(r.Context(), merchantOf(r), id, bid); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// --- promotions

func (s *Service) promotions(w http.ResponseWriter, r *http.Request) error {
	var open *bool
	if b, err := strconv.ParseBool(r.URL.Query().Get("apply_open")); err == nil {
		open = &b
	}
	items, total, err := s.Products.Promotions(r.Context(), product.PromotionFilter{ApplyOpen: open, Merchant: true, Status: r.URL.Query().Get("status")},
		httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (s *Service) entries(w http.ResponseWriter, r *http.Request) error {
	items, err := s.Products.Entries(r.Context(), product.EntryFilter{MerchantID: merchantOf(r), Status: r.URL.Query().Get("status"),
		PromotionID: qInt(r, "promotion_id")})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (s *Service) writeEntry(w http.ResponseWriter, r *http.Request, fn func(tx pgx.Tx) (int64, error)) error {
	var id int64
	err := pgx.BeginFunc(r.Context(), s.Pool, func(tx pgx.Tx) error {
		var err error
		id, err = fn(tx)
		return err
	})
	if err != nil {
		return err
	}
	m := merchantOf(r)
	x, err := s.Products.LoadEntry(r.Context(), s.Pool, &m, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, x)
}

func (s *Service) applyEntry(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in product.EntryInput
	if err := decode(r, &in); err != nil {
		return err
	}
	return s.writeEntry(w, r, func(tx pgx.Tx) (int64, error) { return s.Products.Apply(r.Context(), tx, actorOf(r), id, in) })
}

func (s *Service) entryAction(action string) httpx.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		id, err := httpx.PathID(r, "id")
		if err != nil {
			return err
		}
		var in product.EntryInput
		if b, err := readBody(r, maxBody); err != nil {
			return err
		} else if len(b) > 0 {
			if err := decodeStrict(b, &in); err != nil {
				return err
			}
		}
		m := merchantOf(r)
		return s.writeEntry(w, r, func(tx pgx.Tx) (int64, error) {
			return id, s.Products.EntryAction(r.Context(), tx, &m, id, action, in)
		})
	}
}

// --- statements

func (s *Service) statements(w http.ResponseWriter, r *http.Request) error {
	c, err := cursor(r)
	if err != nil {
		return err
	}
	items, err := s.Perks.StatementsBefore(r.Context(), merchantOf(r), r.URL.Query().Get("status"), c, PageSize+1)
	if err != nil {
		return err
	}
	return httpx.OK(w, page(items, func(x perks.Statement) int64 { return x.ID }))
}

func (s *Service) statement(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	m := merchantOf(r)
	x, err := s.Perks.LoadStatement(r.Context(), s.Pool, &m, id, true)
	if err != nil {
		return err
	}
	return httpx.OK(w, x)
}
