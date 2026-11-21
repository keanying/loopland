// Command loopland-doctor checks a deployment's configuration and every
// external service with harmless requests (query a non-existent order,
// exchange a dummy code), so wrong keys show up before users hit them.
//
// Run it with the same environment as the API:
//
//	loopland-doctor                    # everything except paid calls
//	loopland-doctor -sms-to 138xxxx    # also send a real test SMS
//	loopland-doctor -realname '张三,110105...'   # also run one paid 实名核验
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/keanying/loopland/server/internal/auth"
	"github.com/keanying/loopland/server/internal/billing"
	"github.com/keanying/loopland/server/internal/platform/config"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/user"
)

var (
	smsTo    = flag.String("sms-to", "", "send a real test SMS to this phone")
	realname = flag.String("realname", "", "run one paid realname check: 'name,id_number'")
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
	check := func(name string, enabled bool, f func() error) {
		if !enabled {
			rs = append(rs, result{name: name, skip: "已在 LOOPLAND_DISABLE 中关闭"})
			return
		}
		rs = append(rs, result{name: name, err: f()})
	}
	checkProd := func(name string, f func() error) {
		if cfg.Env != "prod" {
			rs = append(rs, result{name: name, skip: "仅正式环境检查"})
			return
		}
		rs = append(rs, result{name: name, err: f()})
	}

	fmt.Printf("环境：%s\n\n", cfg.Env)
	if cfg.Env == "prod" {
		rs = append(rs, result{name: "正式环境配置完整性", err: cfg.ValidateProd()})
	} else if m := cfg.Missing(); len(m) > 0 {
		rs = append(rs, result{name: "配置完整性（dev 模式下缺失项会用假实现代替）", err: fmt.Errorf("%v", m)})
	}

	check("PostgreSQL + PostGIS", true, func() error {
		pool, err := db.Open(ctx, cfg.DatabaseURL)
		if err != nil {
			return err
		}
		defer pool.Close()
		var v string
		return pool.QueryRow(ctx, `SELECT postgis_full_version()`).Scan(&v)
	})
	check("Redis", true, func() error {
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

	al := cfg.Aliyun
	check("阿里云短信（AccessKey + 签名已审核）", cfg.Enabled("sms"), func() error {
		s, err := auth.NewAliyunSMS(al.AccessKeyID, al.AccessKeySecret, al.SMSSignName, al.SMSTemplateCode)
		if err != nil {
			return err
		}
		if err := s.Check(ctx); err != nil {
			return err
		}
		if *smsTo != "" {
			return s.Send(ctx, *smsTo, "123456")
		}
		return nil
	})
	check("阿里云验证码 2.0", cfg.Enabled("captcha"), func() error {
		c, err := auth.NewAliyunCaptcha(al.AccessKeyID, al.AccessKeySecret, al.CaptchaSceneID)
		if err != nil {
			return err
		}
		return c.Check(ctx)
	})
	check("阿里云号码认证（一键登录）", cfg.Enabled("oneclick"), func() error {
		c, err := auth.NewAliyunOneClick(al.AccessKeyID, al.AccessKeySecret)
		if err != nil {
			return err
		}
		return c.Check(ctx)
	})
	if *realname != "" {
		check("阿里云身份证二要素（付费调用 1 次）", cfg.Enabled("realname"), func() error {
			r, err := user.NewAliyunRealname(al.AccessKeyID, al.AccessKeySecret)
			if err != nil {
				return err
			}
			name, id, _ := strings.Cut(*realname, ",")
			_, err = r.Verify(ctx, name, id)
			return err
		})
	} else {
		rs = append(rs, result{name: "阿里云身份证二要素", skip: "每次调用收费，加 -realname '姓名,身份证号' 才会测试"})
	}
	check("微信开放平台（App 登录）", cfg.Enabled("wechat_login"), func() error {
		return (&auth.WeChatOpen{AppID: cfg.WeChat.AppID, Secret: cfg.WeChat.AppSecret}).Check(ctx)
	})
	check("Sign in with Apple（下载 Apple 公钥）", cfg.Enabled("apple_login"), func() error {
		return (&auth.AppleJWKS{BundleID: cfg.Apple.BundleID}).Check(ctx)
	})
	wc := cfg.WeChat
	check("微信支付 V3（商户号、证书、私钥、平台公钥）", cfg.Enabled("wechat_pay"), func() error {
		p, err := billing.NewWeChatPay(wc.AppID, wc.MchID, wc.MchSerialNo, wc.APIv3Key, wc.MchPrivateKey, wc.PlatformPubKey, wc.PlatformPubKeyID, cfg.PublicBaseURL+"/v1/pay/notify/wechat")
		if err != nil {
			return err
		}
		return p.Check(ctx)
	})
	check("支付宝（应用私钥、支付宝公钥）", cfg.Enabled("alipay"), func() error {
		p, err := billing.NewAlipay(cfg.Alipay.AppID, cfg.Alipay.PrivateKey, cfg.Alipay.PublicKey, cfg.PublicBaseURL+"/v1/pay/notify/alipay", cfg.Alipay.Sandbox)
		if err != nil {
			return err
		}
		return p.Check(ctx)
	})
	check("Apple 内购（Bundle ID）", cfg.Enabled("apple_iap"), func() error {
		if cfg.Apple.BundleID == "" {
			return fmt.Errorf("APPLE_BUNDLE_ID 未设置")
		}
		return nil
	})

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
