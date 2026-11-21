package community

import (
	"context"
	"net/http"
	"strconv"

	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// AdminHandler serves the /admin/v1 meetup and race operations.
type AdminHandler struct {
	Svc   *Service
	Audit func(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error
}

// Routes registers the endpoints; ops is the admin+ops guard.
func (h *AdminHandler) Routes(mux *http.ServeMux, ops func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /admin/v1/meetups", ops(h.meetups))
	mux.Handle("POST /admin/v1/meetups/{id}/cancel", ops(h.cancelMeetup))
	mux.Handle("GET /admin/v1/races", ops(h.races))
	mux.Handle("POST /admin/v1/races", ops(h.createRace))
	mux.Handle("GET /admin/v1/races/{id}", ops(h.race))
	mux.Handle("PATCH /admin/v1/races/{id}", ops(h.patchRace))
	mux.Handle("POST /admin/v1/races/{id}/cancel", ops(h.cancelRace))
	mux.Handle("GET /admin/v1/races/{id}/entries", ops(h.entries))
	mux.Handle("POST /admin/v1/races/{id}/entries/{user}/finish", ops(h.finish))
}

func (h *AdminHandler) audit(r *http.Request, action, target string, detail map[string]any) error {
	return h.Audit(r.Context(), h.Svc.Pool, action, target, detail)
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func (h *AdminHandler) meetups(w http.ResponseWriter, r *http.Request) error {
	items, total, err := h.Svc.AdminMeetups(r.Context(), r.URL.Query().Get("status"), r.URL.Query().Get("type"), httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) cancelMeetup(w http.ResponseWriter, r *http.Request) error {
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
	m, err := h.Svc.CancelMeetup(r.Context(), 0, id, true, req.Reason)
	if err != nil {
		return err
	}
	if err := h.audit(r, "meetup.cancel", "meetup:"+itoa(id), map[string]any{"reason": req.Reason}); err != nil {
		return err
	}
	return httpx.OK(w, m)
}

func (h *AdminHandler) races(w http.ResponseWriter, r *http.Request) error {
	items, total, err := h.Svc.AdminRaces(r.Context(), httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) race(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	v, err := h.Svc.Race(r.Context(), 0, id, true)
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *AdminHandler) createRace(w http.ResponseWriter, r *http.Request) error {
	var in RaceInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	ad, _ := httpx.AdminFrom(r.Context())
	id, err := h.Svc.CreateRace(r.Context(), ad.ID, in)
	if err != nil {
		return err
	}
	if err := h.audit(r, "race.create", "race:"+itoa(id), map[string]any{"title": in.Title}); err != nil {
		return err
	}
	r.SetPathValue("id", itoa(id))
	return h.race(w, r)
}

func (h *AdminHandler) patchRace(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	in, err := h.Svc.RaceInputOf(r.Context(), id)
	if err != nil {
		return err
	}
	oldKey := in.Medal.Key
	if err := httpx.Decode(r, &in); err != nil { // fields left out keep their value
		return err
	}
	if err := h.Svc.UpdateRace(r.Context(), id, oldKey, in); err != nil {
		return err
	}
	if err := h.audit(r, "race.update", "race:"+itoa(id), map[string]any{"title": in.Title}); err != nil {
		return err
	}
	return h.race(w, r)
}

func (h *AdminHandler) cancelRace(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	if err := h.Svc.CancelRace(r.Context(), id); err != nil {
		return err
	}
	if err := h.audit(r, "race.cancel", "race:"+itoa(id), nil); err != nil {
		return err
	}
	return h.race(w, r)
}

func (h *AdminHandler) entries(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	items, total, err := h.Svc.Entries(r.Context(), id, httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) finish(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	user, err := httpx.PathID(r, "user")
	if err != nil {
		return err
	}
	var req struct {
		ResultSec int `json:"result_sec"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if err := h.Svc.FinishOffline(r.Context(), id, user, req.ResultSec); err != nil {
		return err
	}
	if err := h.audit(r, "race.finish", "race:"+itoa(id), map[string]any{"user_id": user, "result_sec": req.ResultSec}); err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}
