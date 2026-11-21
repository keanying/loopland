// Package app wires configuration, infrastructure and modules into the HTTP
// handler and background jobs.
package app

import (
	"bufio"
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"runtime/debug"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/keanying/loopland/server/internal/activity"
	"github.com/keanying/loopland/server/internal/admin"
	"github.com/keanying/loopland/server/internal/auth"
	"github.com/keanying/loopland/server/internal/billing"
	"github.com/keanying/loopland/server/internal/codex"
	"github.com/keanying/loopland/server/internal/crew"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/jobs"
	"github.com/keanying/loopland/server/internal/platform/config"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/platform/secure"
	"github.com/keanying/loopland/server/internal/play"
	"github.com/keanying/loopland/server/internal/providers"
	"github.com/keanying/loopland/server/internal/realtime"
	"github.com/keanying/loopland/server/internal/territory"
	"github.com/keanying/loopland/server/internal/user"
)

// App is the assembled service.
type App struct {
	Hub     *realtime.Hub
	Play    *play.Service
	Handler http.Handler
	Jobs    *jobs.Runner
	Config  *gameplay.Store
	Pool    *pgxpool.Pool
	Redis   *redis.Client
	// Providers holds the third-party service configuration (管理端「系统配置」).
	Providers *providers.Registry
}

// Options allow tests to replace external services.
type Options struct {
	SMS      auth.SMSSender
	OneClick auth.OneClick
	WeChat   auth.WeChat
	Apple    auth.Apple
	Captcha  auth.Captcha
	Realname user.Realname
	Payments map[string]billing.Provider
	AppleIAP *billing.AppleStore
}

// New builds the app on an open pool and redis client.
func New(ctx context.Context, cfg config.Config, pool *pgxpool.Pool, rdb *redis.Client, log *slog.Logger, opt Options) (*App, error) {
	httpx.Logger = log
	box, err := secure.NewBox(cfg.DataKey)
	if err != nil {
		return nil, err
	}
	store, err := gameplay.NewStore(ctx, pool)
	if err != nil {
		return nil, err
	}
	if cfg.BootstrapAdmin != "" {
		if err := admin.Bootstrap(ctx, pool, cfg.BootstrapAdmin); err != nil {
			return nil, err
		}
	}
	reg := &providers.Registry{Pool: pool, Box: box, Cfg: cfg, Log: log, HTTP: &http.Client{Timeout: 15 * time.Second}}
	if err := reg.Load(ctx); err != nil {
		return nil, err
	}
	live(reg, &opt)

	authSvc := &auth.Service{Pool: pool, Redis: rdb, Box: box, Config: store, SMS: opt.SMS, OneTap: opt.OneClick, WeChat: opt.WeChat,
		Apple: opt.Apple, Captcha: opt.Captcha, JWTSecret: cfg.JWTSecret, AccessTTL: cfg.AccessTTL, RefreshTTL: cfg.RefreshTTL}
	if cfg.Dev() {
		authSvc.DevCode = "000000"
	}
	terrSvc := &territory.Service{Pool: pool, Config: store}
	hub := &realtime.Hub{Redis: rdb, Log: log, Auth: authSvc.Parse}
	playSvc := &play.Service{Pool: pool, Redis: rdb, Config: store, Hub: hub, Log: log}
	actSvc := &activity.Service{Pool: pool, Config: store, Hook: playSvc}
	billSvc := &billing.Service{Pool: pool, Providers: opt.Payments, Apple: opt.AppleIAP, Log: log, Dev: cfg.Dev()}
	if opt.Payments == nil {
		billSvc.PaymentFn = reg.Payment
	}
	if opt.AppleIAP == nil {
		billSvc.AppleFn = reg.AppleStore
	}
	userH := &user.Handler{Pool: pool, Config: store, Box: box, Realname: opt.Realname}

	mux := http.NewServeMux()
	authed, authAny := authSvc.Middleware(true), authSvc.Middleware(false)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		if err := pool.Ping(r.Context()); err != nil {
			http.Error(w, "db", http.StatusServiceUnavailable)
			return
		}
		httpx.JSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.Handle("GET /v1/config/gameplay", httpx.Wrap(func(w http.ResponseWriter, r *http.Request) error {
		var uid int64
		if tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer "); ok {
			uid, _ = authSvc.Parse(tok)
		}
		return httpx.OK(w, store.For(uid))
	}))
	mux.Handle("GET /v1/config/features", httpx.Wrap(func(w http.ResponseWriter, r *http.Request) error {
		return httpx.OK(w, features(reg.Current(), opt))
	}))
	(&auth.Handler{Svc: authSvc}).Routes(mux)
	userH.Routes(mux, authed, authAny)
	(&activity.Handler{Svc: actSvc}).Routes(mux, authed)
	(&territory.Handler{Svc: terrSvc, CrewOf: func(ctx context.Context, u int64) (*int64, error) { return crew.Of(ctx, pool, u) }}).Routes(mux, authed)
	(&codex.Handler{Pool: pool, Config: store}).Routes(mux, authed)
	(&crew.Handler{Pool: pool}).Routes(mux, authed)
	(&inbox.Handler{Pool: pool}).Routes(mux, authAny)
	meJSON := func(w http.ResponseWriter, r *http.Request) error {
		u, err := user.Load(r.Context(), pool, store, box, httpx.UserID(r.Context()))
		if err != nil {
			return err
		}
		return httpx.OK(w, u)
	}
	(&billing.Handler{Svc: billSvc}).Routes(mux, authed, meJSON)
	adminAPI := &admin.API{Pool: pool, Redis: rdb, Secret: cfg.AdminJWTSecret, Box: box, Config: store, Billing: billSvc, Territory: terrSvc, Activities: actSvc}
	adminAPI.Routes(mux)
	(&play.Handler{Svc: playSvc, Medals: func(ctx context.Context, u int64) (any, error) {
		v, err := codex.Load(ctx, pool, store.For(u), u)
		return v.Medals, err
	}}).Routes(mux, authed)
	(&play.AdminHandler{Svc: playSvc, Audit: admin.Audit}).Routes(mux, adminAPI.Guard(admin.RoleAdmin, admin.RoleOps))
	(&providers.AdminHandler{Reg: reg, Audit: admin.Audit}).Routes(mux, adminAPI.Guard(admin.RoleAdmin))
	mux.Handle("GET /v1/ws", hub)

	return &App{
		Handler: withMiddleware(mux, log),
		Jobs:    &jobs.Runner{Pool: pool, Billing: billSvc, Config: store, Log: log, Extra: playSvc.Jobs()},
		Hub:     hub,
		Play:    playSvc,
		Config:  store, Pool: pool, Redis: rdb,
		Providers: reg,
	}, nil
}

// live fills services the caller did not replace (tests do) with wrappers
// that always use the current registry snapshot, so a change saved in the
// admin console applies to the next request without a restart.
func live(reg *providers.Registry, opt *Options) {
	sms, captcha, oneclick, wechat, apple, realname := reg.Live()
	if opt.SMS == nil {
		opt.SMS = sms
	}
	if opt.Captcha == nil {
		opt.Captcha = captcha
	}
	if opt.OneClick == nil {
		opt.OneClick = oneclick
	}
	if opt.WeChat == nil {
		opt.WeChat = wechat
	}
	if opt.Apple == nil {
		opt.Apple = apple
	}
	if opt.Realname == nil {
		opt.Realname = realname
	}
}

// Features tells the app which login and payment options work in this
// deployment, so it can hide the rest.
type Features struct {
	Login   []string `json:"login"`
	Pay     []string `json:"pay"`
	Captcha bool     `json:"captcha"`
	AI      bool     `json:"ai"`
}

// features is computed per request from the live snapshot; test
// replacements in opt take precedence.
func features(s providers.Snapshot, opt Options) Features {
	pick := func(override, cur any) any {
		if override != nil && !isLive(override) {
			return override
		}
		return cur
	}
	f := Features{Login: []string{}, Pay: []string{}, AI: s.AI != nil}
	_, captchaOff := pick(opt.Captcha, s.Captcha).(auth.NoCaptcha)
	f.Captcha = !captchaOff
	for name, p := range map[string]any{"sms": pick(opt.SMS, s.SMS), "oneclick": pick(opt.OneClick, s.OneClick),
		"wechat": pick(opt.WeChat, s.WeChat), "apple": pick(opt.Apple, s.Apple)} {
		if _, off := p.(auth.Disabled); !off {
			f.Login = append(f.Login, name)
		}
	}
	pay := s.Payments
	if opt.Payments != nil {
		pay = opt.Payments
	}
	for ch := range pay {
		f.Pay = append(f.Pay, ch)
	}
	if opt.AppleIAP != nil && !slices.Contains(f.Pay, billing.AppleIAP) {
		f.Pay = append(f.Pay, billing.AppleIAP)
	}
	slices.Sort(f.Login)
	slices.Sort(f.Pay)
	return f
}

func isLive(v any) bool { return providers.IsLive(v) }

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (s *statusWriter) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// Unwrap lets http.ResponseController reach the connection (WebSocket
// upgrade, per-request deadlines).
func (s *statusWriter) Unwrap() http.ResponseWriter { return s.ResponseWriter }

// Hijack supports the WebSocket upgrade.
func (s *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := s.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("hijack not supported")
	}
	s.status = http.StatusSwitchingProtocols
	return h.Hijack()
}

func withMiddleware(next http.Handler, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		defer func() {
			if rec := recover(); rec != nil {
				log.Error("panic", "err", rec, "path", r.URL.Path, "stack", string(debug.Stack()))
				httpx.WriteError(sw, r, httpx.E(http.StatusInternalServerError, "internal", "服务器开小差了，请稍后再试"))
			}
			if r.URL.Path != "/healthz" {
				log.Info("http", "method", r.Method, "path", r.URL.Path, "status", sw.status, "ms", time.Since(start).Milliseconds())
			}
		}()
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(sw, r)
	})
}

// Open connects to Postgres (migrating it) and Redis.
func Open(ctx context.Context, cfg config.Config) (*pgxpool.Pool, *redis.Client, error) {
	pool, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		return nil, nil, err
	}
	if err := db.Migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, nil, err
	}
	opts, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		pool.Close()
		return nil, nil, err
	}
	rdb := redis.NewClient(opts)
	if err := rdb.Ping(ctx).Err(); err != nil {
		pool.Close()
		return nil, nil, err
	}
	return pool, rdb, nil
}
