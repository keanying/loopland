// Command loopland-api is the Loopland backend: a modular monolith, split
// into services only after 50 万 DAU (技术选型 · 后端与数据).
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/keanying/loopland/server/internal/app"
	"github.com/keanying/loopland/server/internal/platform/config"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if !cfg.Dev() {
		if err := cfg.ValidateProd(); err != nil {
			return err
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, rdb, err := app.Open(ctx, cfg)
	if err != nil {
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
