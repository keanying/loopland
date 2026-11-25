package config

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// File is config.yaml: every system-level setting in one place. Each field
// maps to an environment variable (shown in the comment); a set environment
// variable always wins, so containers can still override single values.
//
// Secrets should not be written inline in a committed file: use the *_file
// fields (path to a file holding the secret, e.g. a mounted Kubernetes
// secret) or the environment.
type File struct {
	Env  string `yaml:"env"` // LOOPLAND_ENV: dev | prod
	HTTP struct {
		Addr          string   `yaml:"addr"`            // LOOPLAND_HTTP_ADDR
		PublicBaseURL string   `yaml:"public_base_url"` // LOOPLAND_PUBLIC_BASE_URL
		CORSOrigins   []string `yaml:"cors_origins"`    // LOOPLAND_CORS_ORIGINS（逗号分隔）
	} `yaml:"http"`
	Database struct {
		URL string `yaml:"url"` // LOOPLAND_DATABASE_URL
	} `yaml:"database"`
	Redis struct {
		URL string `yaml:"url"` // LOOPLAND_REDIS_URL
	} `yaml:"redis"`
	Auth struct {
		AccessTTL          string `yaml:"access_ttl"`            // LOOPLAND_ACCESS_TTL
		RefreshTTL         string `yaml:"refresh_ttl"`           // LOOPLAND_REFRESH_TTL
		JWTSecret          string `yaml:"jwt_secret"`            // LOOPLAND_JWT_SECRET
		JWTSecretFile      string `yaml:"jwt_secret_file"`       // LOOPLAND_JWT_SECRET_FILE
		AdminJWTSecret     string `yaml:"admin_jwt_secret"`      // LOOPLAND_ADMIN_JWT_SECRET
		AdminJWTSecretFile string `yaml:"admin_jwt_secret_file"` // LOOPLAND_ADMIN_JWT_SECRET_FILE
		DataKey            string `yaml:"data_key"`              // LOOPLAND_DATA_KEY
		DataKeyFile        string `yaml:"data_key_file"`         // LOOPLAND_DATA_KEY_FILE
		BootstrapAdmin     string `yaml:"bootstrap_admin"`       // LOOPLAND_BOOTSTRAP_ADMIN
	} `yaml:"auth"`
	Jobs struct {
		Enabled *bool `yaml:"enabled"` // LOOPLAND_JOBS_OFF=1 when false
	} `yaml:"jobs"`
	Media struct {
		Dir string `yaml:"dir"` // LOOPLAND_MEDIA_DIR: local upload storage without OSS (dev)
	} `yaml:"media"`
	Features struct {
		Disabled []string `yaml:"disabled"` // LOOPLAND_DISABLE
		Wearable bool     `yaml:"wearable"` // LOOPLAND_FEATURE_WEARABLE=1：穿戴设备数据（预留，见 docs/设备接入预留.md）
	} `yaml:"features"`
	Aliyun struct {
		AccessKeyID         string `yaml:"access_key_id"`          // ALIYUN_ACCESS_KEY_ID
		AccessKeySecret     string `yaml:"access_key_secret"`      // ALIYUN_ACCESS_KEY_SECRET
		AccessKeySecretFile string `yaml:"access_key_secret_file"` // ALIYUN_ACCESS_KEY_SECRET_FILE
		SMS                 struct {
			SignName     string `yaml:"sign_name"`     // ALIYUN_SMS_SIGN_NAME
			TemplateCode string `yaml:"template_code"` // ALIYUN_SMS_TEMPLATE_CODE
		} `yaml:"sms"`
		Captcha struct {
			SceneID string `yaml:"scene_id"` // ALIYUN_CAPTCHA_SCENE_ID
		} `yaml:"captcha"`
	} `yaml:"aliyun"`
	WeChat struct {
		AppID         string `yaml:"app_id"`          // WECHAT_APP_ID
		AppSecret     string `yaml:"app_secret"`      // WECHAT_APP_SECRET
		AppSecretFile string `yaml:"app_secret_file"` // WECHAT_APP_SECRET_FILE
		Pay           struct {
			MchID          string `yaml:"mch_id"`           // WECHAT_MCH_ID
			SerialNo       string `yaml:"serial_no"`        // WECHAT_MCH_SERIAL_NO
			PrivateKeyFile string `yaml:"private_key_file"` // WECHAT_MCH_PRIVATE_KEY_FILE
			APIv3KeyFile   string `yaml:"apiv3_key_file"`   // WECHAT_APIV3_KEY_FILE
			PublicKeyFile  string `yaml:"public_key_file"`  // WECHAT_PAY_PUBLIC_KEY_FILE
			PublicKeyID    string `yaml:"public_key_id"`    // WECHAT_PAY_PUBLIC_KEY_ID
		} `yaml:"pay"`
	} `yaml:"wechat"`
	Alipay struct {
		AppID          string `yaml:"app_id"`           // ALIPAY_APP_ID
		PrivateKeyFile string `yaml:"private_key_file"` // ALIPAY_PRIVATE_KEY_FILE
		PublicKeyFile  string `yaml:"public_key_file"`  // ALIPAY_PUBLIC_KEY_FILE
		Sandbox        bool   `yaml:"sandbox"`          // ALIPAY_SANDBOX
	} `yaml:"alipay"`
	Apple struct {
		BundleID string `yaml:"bundle_id"` // APPLE_BUNDLE_ID
		IAP      struct {
			IssuerID       string `yaml:"issuer_id"`        // APPLE_IAP_ISSUER_ID
			KeyID          string `yaml:"key_id"`           // APPLE_IAP_KEY_ID
			PrivateKeyFile string `yaml:"private_key_file"` // APPLE_IAP_PRIVATE_KEY_FILE
			Sandbox        bool   `yaml:"sandbox"`          // APPLE_IAP_SANDBOX
		} `yaml:"iap"`
	} `yaml:"apple"`
}

// env flattens the file into environment-variable names. Relative *_file
// paths are resolved against the config file's directory.
func (f File) env(dir string) map[string]string {
	path := func(p string) string {
		if p == "" || filepath.IsAbs(p) {
			return p
		}
		return filepath.Join(dir, p)
	}
	b := func(v bool) string {
		if v {
			return "1"
		}
		return ""
	}
	m := map[string]string{
		"LOOPLAND_ENV":                   f.Env,
		"LOOPLAND_HTTP_ADDR":             f.HTTP.Addr,
		"LOOPLAND_PUBLIC_BASE_URL":       f.HTTP.PublicBaseURL,
		"LOOPLAND_CORS_ORIGINS":          strings.Join(f.HTTP.CORSOrigins, ","),
		"LOOPLAND_DATABASE_URL":          f.Database.URL,
		"LOOPLAND_REDIS_URL":             f.Redis.URL,
		"LOOPLAND_ACCESS_TTL":            f.Auth.AccessTTL,
		"LOOPLAND_REFRESH_TTL":           f.Auth.RefreshTTL,
		"LOOPLAND_JWT_SECRET":            f.Auth.JWTSecret,
		"LOOPLAND_JWT_SECRET_FILE":       path(f.Auth.JWTSecretFile),
		"LOOPLAND_ADMIN_JWT_SECRET":      f.Auth.AdminJWTSecret,
		"LOOPLAND_ADMIN_JWT_SECRET_FILE": path(f.Auth.AdminJWTSecretFile),
		"LOOPLAND_DATA_KEY":              f.Auth.DataKey,
		"LOOPLAND_DATA_KEY_FILE":         path(f.Auth.DataKeyFile),
		"LOOPLAND_BOOTSTRAP_ADMIN":       f.Auth.BootstrapAdmin,
		"LOOPLAND_DISABLE":               strings.Join(f.Features.Disabled, ","),
		"LOOPLAND_MEDIA_DIR":             path(f.Media.Dir),
		"ALIYUN_ACCESS_KEY_ID":           f.Aliyun.AccessKeyID,
		"ALIYUN_ACCESS_KEY_SECRET":       f.Aliyun.AccessKeySecret,
		"ALIYUN_ACCESS_KEY_SECRET_FILE":  path(f.Aliyun.AccessKeySecretFile),
		"ALIYUN_SMS_SIGN_NAME":           f.Aliyun.SMS.SignName,
		"ALIYUN_SMS_TEMPLATE_CODE":       f.Aliyun.SMS.TemplateCode,
		"ALIYUN_CAPTCHA_SCENE_ID":        f.Aliyun.Captcha.SceneID,
		"WECHAT_APP_ID":                  f.WeChat.AppID,
		"WECHAT_APP_SECRET":              f.WeChat.AppSecret,
		"WECHAT_APP_SECRET_FILE":         path(f.WeChat.AppSecretFile),
		"WECHAT_MCH_ID":                  f.WeChat.Pay.MchID,
		"WECHAT_MCH_SERIAL_NO":           f.WeChat.Pay.SerialNo,
		"WECHAT_MCH_PRIVATE_KEY_FILE":    path(f.WeChat.Pay.PrivateKeyFile),
		"WECHAT_APIV3_KEY_FILE":          path(f.WeChat.Pay.APIv3KeyFile),
		"WECHAT_PAY_PUBLIC_KEY_FILE":     path(f.WeChat.Pay.PublicKeyFile),
		"WECHAT_PAY_PUBLIC_KEY_ID":       f.WeChat.Pay.PublicKeyID,
		"ALIPAY_APP_ID":                  f.Alipay.AppID,
		"ALIPAY_PRIVATE_KEY_FILE":        path(f.Alipay.PrivateKeyFile),
		"ALIPAY_PUBLIC_KEY_FILE":         path(f.Alipay.PublicKeyFile),
		"ALIPAY_SANDBOX":                 b(f.Alipay.Sandbox),
		"APPLE_BUNDLE_ID":                f.Apple.BundleID,
		"APPLE_IAP_ISSUER_ID":            f.Apple.IAP.IssuerID,
		"APPLE_IAP_KEY_ID":               f.Apple.IAP.KeyID,
		"APPLE_IAP_PRIVATE_KEY_FILE":     path(f.Apple.IAP.PrivateKeyFile),
		"APPLE_IAP_SANDBOX":              b(f.Apple.IAP.Sandbox),
	}
	if f.Jobs.Enabled != nil && !*f.Jobs.Enabled {
		m["LOOPLAND_JOBS_OFF"] = "1"
	}
	if f.Features.Wearable {
		m["LOOPLAND_FEATURE_WEARABLE"] = "1"
	}
	for k, v := range m {
		if v == "" {
			delete(m, k)
		}
	}
	return m
}

// findFile returns the config file to use: $LOOPLAND_CONFIG, else
// ./config.yaml, else ./server/config.yaml (running from the repo root).
// An empty result means "no file": defaults and the environment only.
func findFile() (string, error) {
	if p := os.Getenv("LOOPLAND_CONFIG"); p != "" {
		if _, err := os.Stat(p); err != nil {
			return "", fmt.Errorf("LOOPLAND_CONFIG=%s: %w", p, err)
		}
		return p, nil
	}
	for _, p := range []string{"config.yaml", filepath.Join("server", "config.yaml")} {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	return "", nil
}

// readFile parses a config file strictly: unknown keys are errors, so a
// typo cannot silently fall back to a default. Later files (the local
// override) are deep-merged over earlier ones key by key.
func readFile(paths ...string) (map[string]string, error) {
	merged := map[string]any{}
	for _, p := range paths {
		raw, err := os.ReadFile(p)
		if err != nil {
			return nil, err
		}
		var m map[string]any
		if err := yaml.Unmarshal(raw, &m); err != nil {
			return nil, fmt.Errorf("%s: %w", p, err)
		}
		// Validate each file on its own so errors name the right file.
		var f File
		dec := yaml.NewDecoder(bytes.NewReader(raw))
		dec.KnownFields(true)
		if err := dec.Decode(&f); err != nil && err.Error() != "EOF" {
			return nil, fmt.Errorf("%s: %w", p, err)
		}
		deepMerge(merged, m)
	}
	raw, _ := yaml.Marshal(merged)
	var f File
	if err := yaml.Unmarshal(raw, &f); err != nil {
		return nil, err
	}
	abs, _ := filepath.Abs(paths[0])
	return f.env(filepath.Dir(abs)), nil
}

func deepMerge(dst, src map[string]any) {
	for k, v := range src {
		if sm, ok := v.(map[string]any); ok {
			if dm, ok := dst[k].(map[string]any); ok {
				deepMerge(dm, sm)
				continue
			}
		}
		dst[k] = v
	}
}

// localFile is the gitignored per-machine override next to config.yaml.
func localFile(p string) string {
	if os.Getenv("LOOPLAND_CONFIG") != "" {
		return "" // an explicit file is used as is
	}
	l := filepath.Join(filepath.Dir(p), "config.local.yaml")
	if _, err := os.Stat(l); err != nil {
		return ""
	}
	return l
}
