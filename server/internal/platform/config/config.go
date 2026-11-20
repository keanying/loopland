// Package config loads service configuration from environment variables.
// Secrets (keys, certificates) are expected to be injected by the platform
// (KMS / Kubernetes secrets), never committed.
package config

import (
	"encoding/base64"
	"fmt"
	"os"
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
	PublicBaseURL  string // for payment notify URLs

	Aliyun  Aliyun
	WeChat  WeChat
	Apple   Apple
	Alipay  Alipay
	JobsOff bool
}

// Aliyun covers SMS (短信) and 号码认证 (one-click login).
type Aliyun struct {
	AccessKeyID     string
	AccessKeySecret string
	SMSSignName     string
	SMSTemplateCode string
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

// Load reads the environment. In dev every secret has a safe default.
func Load() (Config, error) {
	c := Config{
		Env:            env("LOOPLAND_ENV", "dev"),
		HTTPAddr:       env("LOOPLAND_HTTP_ADDR", ":8080"),
		DatabaseURL:    env("LOOPLAND_DATABASE_URL", "postgres://loopland:loopland@localhost:5432/loopland?sslmode=disable"),
		RedisURL:       env("LOOPLAND_REDIS_URL", "redis://localhost:6379/0"),
		AccessTTL:      dur("LOOPLAND_ACCESS_TTL", 2*time.Hour),
		RefreshTTL:     dur("LOOPLAND_REFRESH_TTL", 30*24*time.Hour),
		BootstrapAdmin: os.Getenv("LOOPLAND_BOOTSTRAP_ADMIN"),
		PublicBaseURL:  strings.TrimRight(env("LOOPLAND_PUBLIC_BASE_URL", "http://localhost:8080"), "/"),
		JobsOff:        os.Getenv("LOOPLAND_JOBS_OFF") == "1",
		Aliyun: Aliyun{
			AccessKeyID:     os.Getenv("ALIYUN_ACCESS_KEY_ID"),
			AccessKeySecret: os.Getenv("ALIYUN_ACCESS_KEY_SECRET"),
			SMSSignName:     os.Getenv("ALIYUN_SMS_SIGN_NAME"),
			SMSTemplateCode: os.Getenv("ALIYUN_SMS_TEMPLATE_CODE"),
		},
		WeChat: WeChat{
			AppID:            os.Getenv("WECHAT_APP_ID"),
			AppSecret:        os.Getenv("WECHAT_APP_SECRET"),
			MchID:            os.Getenv("WECHAT_MCH_ID"),
			MchSerialNo:      os.Getenv("WECHAT_MCH_SERIAL_NO"),
			MchPrivateKey:    os.Getenv("WECHAT_MCH_PRIVATE_KEY"),
			APIv3Key:         os.Getenv("WECHAT_APIV3_KEY"),
			PlatformPubKey:   os.Getenv("WECHAT_PAY_PUBLIC_KEY"),
			PlatformPubKeyID: os.Getenv("WECHAT_PAY_PUBLIC_KEY_ID"),
		},
		Apple: Apple{
			BundleID:   env("APPLE_BUNDLE_ID", "com.loopland.app"),
			IssuerID:   os.Getenv("APPLE_IAP_ISSUER_ID"),
			KeyID:      os.Getenv("APPLE_IAP_KEY_ID"),
			PrivateKey: os.Getenv("APPLE_IAP_PRIVATE_KEY"),
			Sandbox:    os.Getenv("APPLE_IAP_SANDBOX") == "1",
		},
		Alipay: Alipay{
			AppID:      os.Getenv("ALIPAY_APP_ID"),
			PrivateKey: os.Getenv("ALIPAY_PRIVATE_KEY"),
			PublicKey:  os.Getenv("ALIPAY_PUBLIC_KEY"),
			Sandbox:    os.Getenv("ALIPAY_SANDBOX") == "1",
		},
	}
	var err error
	if c.JWTSecret, err = secret("LOOPLAND_JWT_SECRET", c.Dev(), "dev-app-jwt-secret-change-me-0123456789"); err != nil {
		return c, err
	}
	if c.AdminJWTSecret, err = secret("LOOPLAND_ADMIN_JWT_SECRET", c.Dev(), "dev-admin-jwt-secret-change-me-012345678"); err != nil {
		return c, err
	}
	key := os.Getenv("LOOPLAND_DATA_KEY") // base64 of 32 bytes
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
	return c, nil
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func dur(k string, def time.Duration) time.Duration {
	if v := os.Getenv(k); v != "" {
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
	v := os.Getenv(k)
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
