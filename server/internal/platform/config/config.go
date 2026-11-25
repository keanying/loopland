// Package config loads service configuration from environment variables.
// Secrets (keys, certificates) are expected to be injected by the platform
// (KMS / Kubernetes secrets), never committed.
package config

import (
	"encoding/base64"
	"fmt"
	"net/url"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
)

// Config is everything the service reads at start-up.
type Config struct {
	Env         string // dev | prod
	HTTPAddr    string
	DatabaseURL string
	RedisURL    string

	JWTSecret      []byte // app access tokens
	AdminJWTSecret []byte // admin tokens
	DataKey        []byte // 32 bytes, AES-256-GCM for phone numbers
	AccessTTL      time.Duration
	RefreshTTL     time.Duration

	BootstrapAdmin string // "username:password"
	PublicBaseURL  string // for payment notify URLs and share links
	// CORSOrigins are web origins allowed to call the API from a browser
	// (App 的 Web 版、H5 页面). In dev every http://localhost / 127.0.0.1
	// origin is allowed as well.
	CORSOrigins []string
	// MediaDir is where uploads are stored when 对象存储 OSS is not enabled
	// (dev); relative paths in config.yaml are against the file's directory.
	MediaDir string
	// Legal fills the 用户协议 / 隐私政策 pages served at /legal/terms and
	// /legal/privacy (operator, contact, effective date).
	Legal Legal

	Aliyun  Aliyun
	WeChat  WeChat
	Apple   Apple
	Alipay  Alipay
	JobsOff bool
	// Wearable turns on the reserved wearable-device data path (心率、步频、
	// 穿戴设备赛事; docs/设备接入预留.md). Off: the app and admin hide it.
	Wearable bool
	// Disabled lists features switched off for this deployment
	// (LOOPLAND_DISABLE=wechat_login,alipay,...). See Features.
	Disabled []string
}

// Legal is the operator information on the 用户协议 / 隐私政策 pages.
type Legal struct {
	Company, Email, Address, EffectiveDate string
}

// Features that need external credentials. Production refuses to start
// while an enabled feature lacks its configuration.
var Features = []string{"sms", "captcha", "oneclick", "realname", "wechat_login", "apple_login", "wechat_pay", "alipay", "apple_iap"}

// Enabled reports whether a feature is on.
func (c Config) Enabled(f string) bool { return !slices.Contains(c.Disabled, f) }

// Missing lists, per enabled feature, the environment variables that are
// not set. Empty means the deployment is complete.
func (c Config) Missing() map[string][]string {
	need := map[string]map[string]string{
		"sms": {"ALIYUN_ACCESS_KEY_ID": c.Aliyun.AccessKeyID, "ALIYUN_ACCESS_KEY_SECRET": c.Aliyun.AccessKeySecret,
			"ALIYUN_SMS_SIGN_NAME": c.Aliyun.SMSSignName, "ALIYUN_SMS_TEMPLATE_CODE": c.Aliyun.SMSTemplateCode},
		"captcha":      {"ALIYUN_ACCESS_KEY_ID": c.Aliyun.AccessKeyID, "ALIYUN_CAPTCHA_SCENE_ID": c.Aliyun.CaptchaSceneID},
		"oneclick":     {"ALIYUN_ACCESS_KEY_ID": c.Aliyun.AccessKeyID, "ALIYUN_ACCESS_KEY_SECRET": c.Aliyun.AccessKeySecret},
		"realname":     {"ALIYUN_ACCESS_KEY_ID": c.Aliyun.AccessKeyID, "ALIYUN_ACCESS_KEY_SECRET": c.Aliyun.AccessKeySecret},
		"wechat_login": {"WECHAT_APP_ID": c.WeChat.AppID, "WECHAT_APP_SECRET": c.WeChat.AppSecret},
		"apple_login":  {"APPLE_BUNDLE_ID": c.Apple.BundleID},
		"wechat_pay": {"WECHAT_APP_ID": c.WeChat.AppID, "WECHAT_MCH_ID": c.WeChat.MchID, "WECHAT_MCH_SERIAL_NO": c.WeChat.MchSerialNo,
			"WECHAT_MCH_PRIVATE_KEY": c.WeChat.MchPrivateKey, "WECHAT_APIV3_KEY": c.WeChat.APIv3Key,
			"WECHAT_PAY_PUBLIC_KEY": c.WeChat.PlatformPubKey, "WECHAT_PAY_PUBLIC_KEY_ID": c.WeChat.PlatformPubKeyID},
		"alipay":    {"ALIPAY_APP_ID": c.Alipay.AppID, "ALIPAY_PRIVATE_KEY": c.Alipay.PrivateKey, "ALIPAY_PUBLIC_KEY": c.Alipay.PublicKey},
		"apple_iap": {"APPLE_BUNDLE_ID": c.Apple.BundleID},
	}
	out := map[string][]string{}
	for _, f := range Features {
		if !c.Enabled(f) {
			continue
		}
		for k, v := range need[f] {
			if v == "" {
				out[f] = append(out[f], k)
			}
		}
		slices.Sort(out[f])
	}
	return out
}

// ValidateProd checks the system-level settings production needs. Third-party
// credentials are not checked here: they are maintained in the admin console
// (系统配置 · 第三方服务) and a service without them is simply turned off.
func (c Config) ValidateProd() error {
	var problems []string
	if u, err := url.Parse(c.PublicBaseURL); err != nil || u.Scheme != "https" || strings.Contains(u.Host, "localhost") {
		problems = append(problems, "LOOPLAND_PUBLIC_BASE_URL must be the public https address (payment callbacks)")
	}
	for _, d := range c.Disabled {
		if !slices.Contains(Features, d) {
			problems = append(problems, "unknown feature in LOOPLAND_DISABLE: "+d)
		}
	}
	if len(problems) == 0 {
		return nil
	}
	slices.Sort(problems)
	return fmt.Errorf("production configuration incomplete:\n  - %s", strings.Join(problems, "\n  - "))
}

// Aliyun covers SMS (短信) and 号码认证 (one-click login).
type Aliyun struct {
	AccessKeyID     string
	AccessKeySecret string
	SMSSignName     string
	SMSTemplateCode string
	CaptchaSceneID  string
}

// WeChat open platform (mobile app login) and WeChat Pay V3.
type WeChat struct {
	AppID            string
	AppSecret        string
	MchID            string
	MchSerialNo      string
	MchPrivateKey    string // PEM
	APIv3Key         string
	PlatformPubKey   string // PEM, 微信支付公钥
	PlatformPubKeyID string
}

// Apple: Sign in with Apple and In-App Purchase.
type Apple struct {
	BundleID string
	// App Store Server API credentials, used for refunds lookups (optional).
	IssuerID   string
	KeyID      string
	PrivateKey string
	Sandbox    bool
}

// Alipay app payment.
type Alipay struct {
	AppID      string
	PrivateKey string
	PublicKey  string // 支付宝公钥
	Sandbox    bool
}

// Dev reports whether dev-only shortcuts are enabled.
func (c Config) Dev() bool { return c.Env == "dev" }

// fileValues holds config.yaml flattened to environment-variable names;
// the real environment always takes precedence (see get).
var fileValues map[string]string

// get reads a setting: environment variable first, then config.yaml.
func get(k string) string {
	if v, ok := os.LookupEnv(k); ok && v != "" {
		return v
	}
	return fileValues[k]
}

// Origin says where setting k came from: "环境变量 K", the config file, or "默认值".
func Origin(k string) string {
	if v, ok := os.LookupEnv(k); ok && v != "" {
		return "环境变量 " + k
	}
	if fileValues[k] != "" && Source != "" {
		return Source
	}
	return "内置默认值"
}

// Source is the config file Load used ("" when none).
var Source string

// Load reads config.yaml (see File) and the environment. In dev every
// secret has a safe default.
func Load() (Config, error) {
	p, err := findFile()
	if err != nil {
		return Config{}, err
	}
	fileValues, Source = nil, p
	if p != "" {
		files := []string{p}
		if l := localFile(p); l != "" {
			files = append(files, l)
			Source = p + " + " + l
		}
		if fileValues, err = readFile(files...); err != nil {
			return Config{}, err
		}
	}
	c := Config{
		Env:            env("LOOPLAND_ENV", "dev"),
		HTTPAddr:       env("LOOPLAND_HTTP_ADDR", ":8080"),
		DatabaseURL:    env("LOOPLAND_DATABASE_URL", "postgres://loopland:loopland@localhost:5433/loopland?sslmode=disable"),
		RedisURL:       env("LOOPLAND_REDIS_URL", "redis://localhost:6378/0"),
		AccessTTL:      dur("LOOPLAND_ACCESS_TTL", 2*time.Hour),
		RefreshTTL:     dur("LOOPLAND_REFRESH_TTL", 30*24*time.Hour),
		BootstrapAdmin: get("LOOPLAND_BOOTSTRAP_ADMIN"),
		PublicBaseURL:  strings.TrimRight(env("LOOPLAND_PUBLIC_BASE_URL", "http://localhost:8080"), "/"),
		CORSOrigins:    splitList(get("LOOPLAND_CORS_ORIGINS")),
		JobsOff:        get("LOOPLAND_JOBS_OFF") == "1",
		Wearable:       get("LOOPLAND_FEATURE_WEARABLE") == "1",
		MediaDir:       env("LOOPLAND_MEDIA_DIR", "data/media"),
		Legal: Legal{
			Company:       get("LOOPLAND_LEGAL_COMPANY"),
			Email:         get("LOOPLAND_LEGAL_EMAIL"),
			Address:       get("LOOPLAND_LEGAL_ADDRESS"),
			EffectiveDate: get("LOOPLAND_LEGAL_EFFECTIVE_DATE"),
		},
		Aliyun: Aliyun{
			AccessKeyID:     get("ALIYUN_ACCESS_KEY_ID"),
			AccessKeySecret: secretEnv("ALIYUN_ACCESS_KEY_SECRET"),
			SMSSignName:     get("ALIYUN_SMS_SIGN_NAME"),
			SMSTemplateCode: get("ALIYUN_SMS_TEMPLATE_CODE"),
			CaptchaSceneID:  get("ALIYUN_CAPTCHA_SCENE_ID"),
		},
		WeChat: WeChat{
			AppID:            get("WECHAT_APP_ID"),
			AppSecret:        secretEnv("WECHAT_APP_SECRET"),
			MchID:            get("WECHAT_MCH_ID"),
			MchSerialNo:      get("WECHAT_MCH_SERIAL_NO"),
			MchPrivateKey:    secretEnv("WECHAT_MCH_PRIVATE_KEY"),
			APIv3Key:         secretEnv("WECHAT_APIV3_KEY"),
			PlatformPubKey:   secretEnv("WECHAT_PAY_PUBLIC_KEY"),
			PlatformPubKeyID: get("WECHAT_PAY_PUBLIC_KEY_ID"),
		},
		Apple: Apple{
			BundleID:   env("APPLE_BUNDLE_ID", "com.loopland.app"),
			IssuerID:   get("APPLE_IAP_ISSUER_ID"),
			KeyID:      get("APPLE_IAP_KEY_ID"),
			PrivateKey: secretEnv("APPLE_IAP_PRIVATE_KEY"),
			Sandbox:    get("APPLE_IAP_SANDBOX") == "1",
		},
		Alipay: Alipay{
			AppID:      get("ALIPAY_APP_ID"),
			PrivateKey: secretEnv("ALIPAY_PRIVATE_KEY"),
			PublicKey:  secretEnv("ALIPAY_PUBLIC_KEY"),
			Sandbox:    get("ALIPAY_SANDBOX") == "1",
		},
	}
	if c.JWTSecret, err = secret("LOOPLAND_JWT_SECRET", c.Dev(), "dev-app-jwt-secret-change-me-0123456789"); err != nil {
		return c, err
	}
	if c.AdminJWTSecret, err = secret("LOOPLAND_ADMIN_JWT_SECRET", c.Dev(), "dev-admin-jwt-secret-change-me-012345678"); err != nil {
		return c, err
	}
	key := secretEnv("LOOPLAND_DATA_KEY") // base64 of 32 bytes
	switch {
	case key != "":
		if c.DataKey, err = base64.StdEncoding.DecodeString(key); err != nil || len(c.DataKey) != 32 {
			return c, fmt.Errorf("LOOPLAND_DATA_KEY must be base64 of 32 bytes")
		}
	case c.Dev():
		c.DataKey = []byte("dev-data-key-32-bytes-long-00000")
	default:
		return c, fmt.Errorf("LOOPLAND_DATA_KEY is required outside dev")
	}
	if c.Env != "dev" && c.Env != "prod" {
		return c, fmt.Errorf("LOOPLAND_ENV must be dev or prod")
	}
	for _, f := range strings.Split(get("LOOPLAND_DISABLE"), ",") {
		if f = strings.TrimSpace(f); f != "" {
			c.Disabled = append(c.Disabled, f)
		}
	}
	return c, nil
}

// secretEnv reads K, or the file named by K_FILE (Kubernetes secret mounts,
// PEM keys). Trailing newlines from files are trimmed.
func secretEnv(k string) string {
	if v := get(k); v != "" {
		return v
	}
	if p := get(k + "_FILE"); p != "" {
		if b, err := os.ReadFile(p); err == nil {
			return strings.TrimRight(string(b), "\r\n")
		}
	}
	return ""
}

func env(k, def string) string {
	if v := get(k); v != "" {
		return v
	}
	return def
}

func dur(k string, def time.Duration) time.Duration {
	if v := get(k); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
		if n, err := strconv.Atoi(v); err == nil {
			return time.Duration(n) * time.Second
		}
	}
	return def
}

func secret(k string, dev bool, devDefault string) ([]byte, error) {
	v := secretEnv(k)
	if v == "" {
		if !dev {
			return nil, fmt.Errorf("%s is required outside dev", k)
		}
		v = devDefault
	}
	if len(v) < 32 {
		return nil, fmt.Errorf("%s must be at least 32 characters", k)
	}
	return []byte(v), nil
}

func splitList(v string) []string {
	out := []string{}
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimRight(strings.TrimSpace(p), "/"); p != "" {
			out = append(out, p)
		}
	}
	return out
}
