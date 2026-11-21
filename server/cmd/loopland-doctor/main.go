// Command loopland-doctor checks a deployment's configuration and every
// external service with harmless requests (query a non-existent order,
// exchange a dummy code), so wrong keys show up before users hit them.
//
// Run it with the same environment as the API:
//
//	loopland-doctor                    # everything except paid calls
//	loopland-doctor -sms-to 138xxxx    # also send a real test SMS
//	loopland-doctor -realname '张三,110105...'   # also run one paid 实名核验
//	loopland-doctor -mail-to ops@example.com     # also send a test email
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/keanying/loopland/server/internal/platform/config"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/secure"
	"github.com/keanying/loopland/server/internal/providers"
)

var (
	smsTo    = flag.String("sms-to", "", "send a real test SMS to this phone")
	realname = flag.String("realname", "", "run one paid realname check: 'name,id_number'")
	mailTo   = flag.String("mail-to", "", "send a test email to this address")
)

type result struct {
	name string
	err  error
	skip string
}

func main() {
	flag.Parse()
	cfg, err := config.Load()
	if err != nil {
		fmt.Println("✗ 配置读取失败：", err)
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	var rs []result
	check := func(name string, f func() error) { rs = append(rs, result{name: name, err: f()}) }
	checkProd := func(name string, f func() error) {
		if cfg.Env != "prod" {
			rs = append(rs, result{name: name, skip: "仅正式环境检查"})
			return
		}
		rs = append(rs, result{name: name, err: f()})
	}

	src := config.Source
	if src == "" {
		src = "无（仅环境变量）"
	}
	fmt.Printf("环境：%s\n配置文件：%s\n\n", cfg.Env, src)
	if cfg.Env == "prod" {
		rs = append(rs, result{name: "正式环境配置完整性", err: cfg.ValidateProd()})
	}

	check("PostgreSQL + PostGIS", func() error {
		pool, err := db.Open(ctx, cfg.DatabaseURL)
		if err != nil {
			return err
		}
		defer pool.Close()
		var v string
		return pool.QueryRow(ctx, `SELECT postgis_full_version()`).Scan(&v)
	})
	check("Redis", func() error {
		opts, err := redis.ParseURL(cfg.RedisURL)
		if err != nil {
			return err
		}
		c := redis.NewClient(opts)
		defer c.Close()
		return c.Ping(ctx).Err()
	})
	checkProd("公网回调地址 "+cfg.PublicBaseURL+"/healthz", func() error {
		resp, err := http.Get(cfg.PublicBaseURL + "/healthz")
		if err != nil {
			return err
		}
		resp.Body.Close()
		if resp.StatusCode != 200 {
			return fmt.Errorf("HTTP %d", resp.StatusCode)
		}
		return nil
	})

	// Third-party services: the effective configuration (admin console rows
	// first, then config.yaml / environment), the same the API uses.
	if pool, err := db.Open(ctx, cfg.DatabaseURL); err != nil {
		rs = append(rs, result{name: "第三方服务", err: fmt.Errorf("连不上数据库，无法读取管理端配置：%w", err)})
	} else {
		defer pool.Close()
		box, err := secure.NewBox(cfg.DataKey)
		if err != nil {
			rs = append(rs, result{name: "数据加密密钥", err: err})
		} else {
			reg := &providers.Registry{Pool: pool, Box: box, Cfg: cfg, Log: slog.New(slog.NewTextHandler(io.Discard, nil)), HTTP: &http.Client{Timeout: 15 * time.Second}}
			if err := reg.Load(ctx); err != nil {
				rs = append(rs, result{name: "读取第三方服务配置", err: err})
			} else {
				inputs := map[string]string{providers.SMS: *smsTo, providers.Realname: *realname, providers.Email: *mailTo}
				for _, d := range providers.Defs {
					e := reg.Current().Eff[d.Code]
					name := fmt.Sprintf("%s（配置来源：%s）", d.Name, map[string]string{"db": "管理端", "config": "配置文件", "none": "未配置"}[e.Source])
					switch {
					case !e.Enabled:
						rs = append(rs, result{name: d.Name, skip: "未启用"})
					case d.Code == providers.Realname && *realname == "":
						rs = append(rs, result{name: d.Name, skip: "每次调用收费，加 -realname '姓名,身份证号' 才会测试"})
					case d.Code == providers.Email && *mailTo == "":
						rs = append(rs, result{name: d.Name, skip: "加 -mail-to 收件邮箱 才会发送测试邮件"})
					default:
						rs = append(rs, result{name: name, err: reg.Check(ctx, d.Code, inputs[d.Code])})
					}
				}
			}
		}
	}

	failed := 0
	for _, r := range rs {
		switch {
		case r.skip != "":
			fmt.Printf("–  %s：跳过（%s）\n", r.name, r.skip)
		case r.err != nil:
			failed++
			fmt.Printf("✗  %s\n   %v\n", r.name, r.err)
		default:
			fmt.Printf("✓  %s\n", r.name)
		}
	}
	fmt.Println()
	if failed > 0 {
		fmt.Printf("%d 项未通过\n", failed)
		os.Exit(1)
	}
	fmt.Println("全部通过")
}
