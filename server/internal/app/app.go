// Package app wires configuration, infrastructure and modules into the HTTP
// handler and background jobs.
package app

import (
	"context"
	"fmt"
	"log/slog"
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
	if err := providers(cfg, log, &opt); err != nil {
		return nil, err
	}

	authSvc := &auth.Service{Pool: pool, Redis: rdb, Box: box, Config: store, SMS: opt.SMS, OneTap: opt.OneClick, WeChat: opt.WeChat,
		Apple: opt.Apple, Captcha: opt.Captcha, JWTSecret: cfg.JWTSecret, AccessTTL: cfg.AccessTTL, RefreshTTL: cfg.RefreshTTL}
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
	features := enabledFeatures(cfg, opt)
	mux.Handle("GET /v1/config/features", httpx.Wrap(func(w http.ResponseWriter, r *http.Request) error {
		return httpx.OK(w, features)
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

// providers fills in external services from configuration: the real
// provider when credentials exist, dev fakes in dev, and "disabled"
// otherwise. Production start-up refuses incomplete configuration before
// this runs (see config.ValidateProd), so "disabled" in prod only happens
// for features listed in LOOPLAND_DISABLE.
func providers(cfg config.Config, log *slog.Logger, opt *Options) error {
	al := cfg.Aliyun
	on := cfg.Enabled
	fail := func(what string, err error) error { return fmt.Errorf("%s: %w", what, err) }

	if opt.SMS == nil {
		switch {
		case on("sms") && al.AccessKeyID != "" && al.SMSSignName != "":
			s, err := auth.NewAliyunSMS(al.AccessKeyID, al.AccessKeySecret, al.SMSSignName, al.SMSTemplateCode)
			if err != nil {
				return fail("aliyun sms", err)
			}
			opt.SMS = s
		case cfg.Dev():
			opt.SMS = auth.LogSMS{Log: log}
		default:
			opt.SMS = auth.Disabled{Name: "sms"}
		}
	}
	if opt.Captcha == nil {
		switch {
		case on("captcha") && al.AccessKeyID != "" && al.CaptchaSceneID != "":
			c, err := auth.NewAliyunCaptcha(al.AccessKeyID, al.AccessKeySecret, al.CaptchaSceneID)
			if err != nil {
				return fail("aliyun captcha", err)
			}
			opt.Captcha = c
		default:
			// dev, or explicitly disabled: rate limits still apply.
			opt.Captcha = auth.NoCaptcha{}
		}
	}
	if opt.OneClick == nil {
		switch {
		case on("oneclick") && al.AccessKeyID != "":
			c, err := auth.NewAliyunOneClick(al.AccessKeyID, al.AccessKeySecret)
			if err != nil {
				return fail("aliyun one-click", err)
			}
			opt.OneClick = c
		case cfg.Dev():
			opt.OneClick = auth.DevOneClick{}
		default:
			opt.OneClick = auth.Disabled{Name: "oneclick"}
		}
	}
	if opt.WeChat == nil {
		switch {
		case on("wechat_login") && cfg.WeChat.AppID != "" && cfg.WeChat.AppSecret != "":
			opt.WeChat = &auth.WeChatOpen{AppID: cfg.WeChat.AppID, Secret: cfg.WeChat.AppSecret}
		case cfg.Dev():
			opt.WeChat = auth.DevWeChat{}
		default:
			opt.WeChat = auth.Disabled{Name: "wechat"}
		}
	}
	if opt.Apple == nil {
		real := &auth.AppleJWKS{BundleID: cfg.Apple.BundleID}
		switch {
		case cfg.Dev():
			opt.Apple = devOrReal{dev: auth.DevApple{}, real: real}
		case on("apple_login"):
			opt.Apple = real
		default:
			opt.Apple = auth.Disabled{Name: "apple"}
		}
	}
	if opt.Realname == nil {
		switch {
		case on("realname") && al.AccessKeyID != "":
			r, err := user.NewAliyunRealname(al.AccessKeyID, al.AccessKeySecret)
			if err != nil {
				return fail("aliyun realname", err)
			}
			opt.Realname = r
		case cfg.Dev():
			opt.Realname = user.ChecksumRealname{}
		default:
			opt.Realname = user.UnconfiguredRealname{}
		}
	}
	if opt.Payments == nil {
		opt.Payments = map[string]billing.Provider{}
		wc := cfg.WeChat
		if on("wechat_pay") && wc.MchID != "" && wc.MchPrivateKey != "" {
			p, err := billing.NewWeChatPay(wc.AppID, wc.MchID, wc.MchSerialNo, wc.APIv3Key, wc.MchPrivateKey, wc.PlatformPubKey, wc.PlatformPubKeyID,
				cfg.PublicBaseURL+"/v1/pay/notify/wechat")
			if err != nil {
				return fail("wechat pay", err)
			}
			opt.Payments[billing.WeChatApp] = p
		}
		ap := cfg.Alipay
		if on("alipay") && ap.AppID != "" && ap.PrivateKey != "" {
			p, err := billing.NewAlipay(ap.AppID, ap.PrivateKey, ap.PublicKey, cfg.PublicBaseURL+"/v1/pay/notify/alipay", ap.Sandbox)
			if err != nil {
				return fail("alipay", err)
			}
			opt.Payments[billing.AlipayApp] = p
		}
		if cfg.Dev() {
			opt.Payments[billing.Mock] = billing.MockPay{}
		}
	}
	if opt.AppleIAP == nil && on("apple_iap") {
		opt.AppleIAP = billing.NewAppleStore(cfg.Apple.BundleID)
	}
	if _, ok := opt.Payments[billing.AppleIAP]; !ok && opt.AppleIAP != nil {
		opt.Payments[billing.AppleIAP] = opt.AppleIAP
	}
	return nil
}

// Features tells the app which login and payment options work in this
// deployment, so it can hide the rest.
type Features struct {
	Login   []string `json:"login"`
	Pay     []string `json:"pay"`
	Captcha bool     `json:"captcha"`
}

func enabledFeatures(cfg config.Config, opt Options) Features {
	f := Features{Login: []string{}, Pay: []string{}}
	_, captchaOff := opt.Captcha.(auth.NoCaptcha)
	f.Captcha = !captchaOff
	for name, p := range map[string]any{"sms": opt.SMS, "oneclick": opt.OneClick, "wechat": opt.WeChat, "apple": opt.Apple} {
		if _, off := p.(auth.Disabled); !off {
			f.Login = append(f.Login, name)
		}
	}
	for ch := range opt.Payments {
		f.Pay = append(f.Pay, ch)
	}
	slices.Sort(f.Login)
	slices.Sort(f.Pay)
	return f
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
