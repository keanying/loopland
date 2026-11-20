// Package app wires configuration, infrastructure and modules into the HTTP
// handler and background jobs.
package app

import (
	"context"
	"log/slog"
	"net/http"
	"runtime/debug"
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
	"github.com/keanying/loopland/server/internal/territory"
	"github.com/keanying/loopland/server/internal/user"
)

// App is the assembled service.
type App struct {
	Handler http.Handler
	Jobs    *jobs.Runner
	Config  *gameplay.Store
	Pool    *pgxpool.Pool
	Redis   *redis.Client
}

// Options allow tests to replace external services.
type Options struct {
	SMS      auth.SMSSender
	OneClick auth.OneClick
	WeChat   auth.WeChat
	Apple    auth.Apple
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
	providers(cfg, log, &opt)

	authSvc := &auth.Service{Pool: pool, Redis: rdb, Box: box, Config: store, SMS: opt.SMS, OneTap: opt.OneClick, WeChat: opt.WeChat,
		Apple: opt.Apple, Captcha: auth.NoCaptcha{}, JWTSecret: cfg.JWTSecret, AccessTTL: cfg.AccessTTL, RefreshTTL: cfg.RefreshTTL}
	if cfg.Dev() {
		authSvc.DevCode = "000000"
	}
	terrSvc := &territory.Service{Pool: pool, Config: store}
	actSvc := &activity.Service{Pool: pool, Config: store}
	billSvc := &billing.Service{Pool: pool, Providers: opt.Payments, Apple: opt.AppleIAP, Log: log, Dev: cfg.Dev()}
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
	(&admin.API{Pool: pool, Redis: rdb, Secret: cfg.AdminJWTSecret, Box: box, Config: store, Billing: billSvc, Territory: terrSvc, Activities: actSvc}).Routes(mux)

	return &App{
		Handler: withMiddleware(mux, log),
		Jobs:    &jobs.Runner{Pool: pool, Billing: billSvc, Config: store, Log: log},
		Config:  store, Pool: pool, Redis: rdb,
	}, nil
}

// providers fills in external services from configuration: real ones when
// credentials exist, dev fakes in dev, and "disabled" otherwise.
func providers(cfg config.Config, log *slog.Logger, opt *Options) {
	al := cfg.Aliyun
	if opt.SMS == nil {
		switch {
		case al.AccessKeyID != "" && al.SMSSignName != "":
			if s, err := auth.NewAliyunSMS(al.AccessKeyID, al.AccessKeySecret, al.SMSSignName, al.SMSTemplateCode); err == nil {
				opt.SMS = s
			} else {
				log.Error("aliyun sms", "err", err)
			}
		case cfg.Dev():
			opt.SMS = auth.LogSMS{Log: log}
		}
		if opt.SMS == nil {
			opt.SMS = auth.Disabled{Name: "sms"}
		}
	}
	if opt.OneClick == nil {
		switch {
		case al.AccessKeyID != "":
			if c, err := auth.NewAliyunOneClick(al.AccessKeyID, al.AccessKeySecret); err == nil {
				opt.OneClick = c
			}
		case cfg.Dev():
			opt.OneClick = auth.DevOneClick{}
		}
		if opt.OneClick == nil {
			opt.OneClick = auth.Disabled{Name: "oneclick"}
		}
	}
	if opt.WeChat == nil {
		switch {
		case cfg.WeChat.AppID != "" && cfg.WeChat.AppSecret != "":
			opt.WeChat = &auth.WeChatOpen{AppID: cfg.WeChat.AppID, Secret: cfg.WeChat.AppSecret}
		case cfg.Dev():
			opt.WeChat = auth.DevWeChat{}
		default:
			opt.WeChat = auth.Disabled{Name: "wechat"}
		}
	}
	if opt.Apple == nil {
		if cfg.Dev() {
			opt.Apple = devOrReal{dev: auth.DevApple{}, real: &auth.AppleJWKS{BundleID: cfg.Apple.BundleID}}
		} else {
			opt.Apple = &auth.AppleJWKS{BundleID: cfg.Apple.BundleID}
		}
	}
	if opt.Realname == nil {
		if cfg.Dev() {
			opt.Realname = user.ChecksumRealname{}
		} else {
			opt.Realname = user.UnconfiguredRealname{}
		}
	}
	if opt.Payments == nil {
		opt.Payments = map[string]billing.Provider{}
		wc := cfg.WeChat
		if wc.MchID != "" && wc.MchPrivateKey != "" {
			p, err := billing.NewWeChatPay(wc.AppID, wc.MchID, wc.MchSerialNo, wc.APIv3Key, wc.MchPrivateKey, wc.PlatformPubKey, wc.PlatformPubKeyID,
				cfg.PublicBaseURL+"/v1/pay/notify/wechat")
			if err != nil {
				log.Error("wechat pay", "err", err)
			} else {
				opt.Payments[billing.WeChatApp] = p
			}
		}
		ap := cfg.Alipay
		if ap.AppID != "" && ap.PrivateKey != "" {
			p, err := billing.NewAlipay(ap.AppID, ap.PrivateKey, ap.PublicKey, cfg.PublicBaseURL+"/v1/pay/notify/alipay", ap.Sandbox)
			if err != nil {
				log.Error("alipay", "err", err)
			} else {
				opt.Payments[billing.AlipayApp] = p
			}
		}
		if cfg.Dev() {
			opt.Payments[billing.Mock] = billing.MockPay{}
		}
	}
	if opt.AppleIAP == nil {
		opt.AppleIAP = billing.NewAppleStore(cfg.Apple.BundleID)
	}
	if _, ok := opt.Payments[billing.AppleIAP]; !ok {
		opt.Payments[billing.AppleIAP] = opt.AppleIAP
	}
}

// devOrReal accepts dev:<sub> tokens and real Apple tokens in dev.
type devOrReal struct {
	dev  auth.Apple
	real auth.Apple
}

func (d devOrReal) Verify(ctx context.Context, tok string) (string, error) {
	if strings.HasPrefix(tok, "dev:") {
		return d.dev.Verify(ctx, tok)
	}
	return d.real.Verify(ctx, tok)
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (s *statusWriter) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
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
