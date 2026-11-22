// Package api is the Loopland backend server: a modular monolith, split
// into services only after 50 万 DAU (技术选型 · 后端与数据).
package api

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/keanying/loopland/server/internal/app"
	"github.com/keanying/loopland/server/internal/platform/config"
)

// Main runs the command with its arguments (without the command name).
//
//	-config path   use this config file (same as LOOPLAND_CONFIG)
func Main(args []string) {
	fs := flag.NewFlagSet("api", flag.ExitOnError)
	cfgFile := fs.String("config", "", "config file (default: ./config.yaml or ./server/config.yaml)")
	_ = fs.Parse(args)
	if *cfgFile != "" {
		_ = os.Setenv("LOOPLAND_CONFIG", *cfgFile)
	}
	cfg, err := config.Load()
	if err != nil {
		slog.Error("配置读取失败", "err", err)
		os.Exit(1)
	}
	// Readable logs in dev (IDE console / terminal); JSON in production.
	var h slog.Handler = slog.NewJSONHandler(os.Stdout, nil)
	if cfg.Dev() {
		h = slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelDebug})
	}
	log := slog.New(h)
	if err := run(cfg, log); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(cfg config.Config, log *slog.Logger) error {
	if !cfg.Dev() {
		if err := cfg.ValidateProd(); err != nil {
			return err
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, rdb, err := app.Open(ctx, cfg)
	if err != nil {
		if cfg.Dev() {
			return fmt.Errorf("%w\n  → 正在连接 数据库 %s（来自 %s）、Redis %s（来自 %s）\n"+
				"  → 本机开发需要 PostgreSQL(PostGIS) 和 Redis：运行 scripts/dev.sh deps（Windows：scripts\\dev.ps1 deps）；地址不对就改上面写的来源",
				err, hostOf(cfg.DatabaseURL), config.Origin("LOOPLAND_DATABASE_URL"), hostOf(cfg.RedisURL), config.Origin("LOOPLAND_REDIS_URL"))
		}
		return err
	}
	defer pool.Close()
	defer rdb.Close()

	a, err := app.New(ctx, cfg, pool, rdb, log, app.Options{})
	if err != nil {
		return err
	}
	go a.Config.Watch(ctx, 30*time.Second)
	go a.Hub.Run(ctx)
	// Pick up 第三方服务 changes saved on another instance.
	go a.Providers.Watch(ctx, 30*time.Second)
	if !cfg.JobsOff {
		go a.Jobs.Run(ctx, time.Minute)
	}

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           a.Handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      60 * time.Second,
	}
	errc := make(chan error, 1)
	go func() {
		src := config.Source
		if src == "" {
			src = "(无配置文件，仅环境变量)"
		}
		log.Info("listening", "addr", cfg.HTTPAddr, "env", cfg.Env, "config", src)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errc <- err
		}
	}()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return srv.Shutdown(shutdown)
}

// hostOf returns host:port of a connection URL (without credentials).
func hostOf(raw string) string {
	if u, err := url.Parse(raw); err == nil && u.Host != "" {
		return u.Host
	}
	return "（无法解析）"
}
