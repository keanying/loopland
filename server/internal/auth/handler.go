package auth

import (
	"net/http"

	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/user"
)

// Handler serves /v1/auth and phone binding.
type Handler struct{ Svc *Service }

// Routes registers the endpoints.
func (h *Handler) Routes(mux *http.ServeMux) {
	authAny := h.Svc.Middleware(false)
	mux.Handle("POST /v1/auth/sms/send", httpx.Wrap(h.sendCode))
	mux.Handle("POST /v1/auth/login", httpx.Wrap(h.login))
	mux.Handle("POST /v1/auth/refresh", httpx.Wrap(h.refresh))
	mux.Handle("POST /v1/auth/logout", httpx.Wrap(h.logout))
	mux.Handle("POST /v1/me/phone", authAny(h.bindPhone))
}

func (h *Handler) sendCode(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Phone        string `json:"phone"`
		CaptchaToken string `json:"captcha_token"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if err := h.Svc.SendCode(r.Context(), req.Phone, req.CaptchaToken, httpx.ClientIP(r)); err != nil {
		return err
	}
	return httpx.OK(w, map[string]int{"cooldown_s": int(smsCooldown.Seconds())})
}

func (h *Handler) login(w http.ResponseWriter, r *http.Request) error {
	var req LoginRequest
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	res, err := h.Svc.Login(r.Context(), req)
	if err != nil {
		return err
	}
	return httpx.OK(w, res)
}

func (h *Handler) refresh(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	res, err := h.Svc.Refresh(r.Context(), req.RefreshToken)
	if err != nil {
		return err
	}
	return httpx.OK(w, res)
}

func (h *Handler) logout(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if err := h.Svc.Logout(r.Context(), req.RefreshToken); err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

func (h *Handler) bindPhone(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Phone         string `json:"phone"`
		Code          string `json:"code"`
		OneClickToken string `json:"oneclick_token"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	phone := req.Phone
	if req.OneClickToken != "" {
		p, err := h.Svc.OneTap.Mobile(r.Context(), req.OneClickToken)
		if err != nil {
			return providerErr(err)
		}
		phone = p
	} else if err := h.Svc.CheckCode(r.Context(), req.Phone, req.Code); err != nil {
		return err
	}
	if !phoneRe.MatchString(phone) {
		return errInvalidPhone
	}
	uid := httpx.UserID(r.Context())
	if err := h.Svc.BindPhone(r.Context(), uid, phone); err != nil {
		return err
	}
	u, err := user.Load(r.Context(), h.Svc.Pool, h.Svc.Config, h.Svc.Box, uid)
	if err != nil {
		return err
	}
	return httpx.OK(w, u)
}
