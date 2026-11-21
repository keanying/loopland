package providers

import (
	"context"
	"errors"
	"net/http"

	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// AdminHandler serves 系统配置 · 第三方服务 (admin role only).
type AdminHandler struct {
	Reg   *Registry
	Audit func(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error
}

// Routes registers the endpoints behind the given guard.
func (h *AdminHandler) Routes(mux *http.ServeMux, adminOnly func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /admin/v1/providers", adminOnly(h.list))
	mux.Handle("PUT /admin/v1/providers/{code}", adminOnly(h.save))
	mux.Handle("POST /admin/v1/providers/{code}/test", adminOnly(h.test))
}

func (h *AdminHandler) list(w http.ResponseWriter, r *http.Request) error {
	v, err := h.Reg.Views(r.Context())
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(v))
}

func (h *AdminHandler) view(ctx context.Context, code string) (View, error) {
	vs, err := h.Reg.Views(ctx)
	if err != nil {
		return View{}, err
	}
	for _, v := range vs {
		if v.Code == code {
			return v, nil
		}
	}
	return View{}, httpx.NotFound("服务")
}

func asHTTP(err error) error {
	var inv ErrInvalid
	if errors.As(err, &inv) {
		return httpx.BadRequest("invalid_config", inv.Msg)
	}
	return err
}

func (h *AdminHandler) save(w http.ResponseWriter, r *http.Request) error {
	code := r.PathValue("code")
	if _, ok := DefOf(code); !ok {
		return httpx.NotFound("服务")
	}
	var in struct {
		Enabled bool              `json:"enabled"`
		Values  map[string]string `json:"values"`
		Clear   []string          `json:"clear"`
	}
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	ad, _ := httpx.AdminFrom(r.Context())
	before := h.Reg.Current().Eff[code].Enabled
	changed, err := h.Reg.Save(r.Context(), code, in.Enabled, in.Values, in.Clear, ad.ID)
	if err != nil {
		return asHTTP(err)
	}
	// Field names only: values (secret or not) never go to the audit log.
	if changed == nil {
		changed = []string{}
	}
	if err := h.Audit(r.Context(), h.Reg.Pool, "provider.save", code, map[string]any{
		"enabled_before": before, "enabled": in.Enabled, "changed_fields": changed}); err != nil {
		return err
	}
	v, err := h.view(r.Context(), code)
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}

func (h *AdminHandler) test(w http.ResponseWriter, r *http.Request) error {
	code := r.PathValue("code")
	if _, ok := DefOf(code); !ok {
		return httpx.NotFound("服务")
	}
	var in struct {
		Input string `json:"input"`
	}
	if r.ContentLength != 0 {
		if err := httpx.Decode(r, &in); err != nil {
			return err
		}
	}
	res, err := h.Reg.Test(r.Context(), code, in.Input)
	if err != nil {
		return asHTTP(err)
	}
	if err := h.Audit(r.Context(), h.Reg.Pool, "provider.test", code, map[string]any{"status": res.Status}); err != nil {
		return err
	}
	return httpx.OK(w, res)
}
