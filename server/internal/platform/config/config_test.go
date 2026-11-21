package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProdValidation(t *testing.T) {
	t.Setenv("LOOPLAND_ENV", "prod")
	t.Setenv("LOOPLAND_JWT_SECRET", strings.Repeat("a", 40))
	t.Setenv("LOOPLAND_ADMIN_JWT_SECRET", strings.Repeat("b", 40))
	t.Setenv("LOOPLAND_DATA_KEY", "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")
	t.Setenv("LOOPLAND_PUBLIC_BASE_URL", "https://api.loopland.cn")
	t.Setenv("LOOPLAND_DISABLE", "wechat_login,wechat_pay,alipay,apple_login,apple_iap,oneclick,realname,captcha")
	t.Setenv("ALIYUN_ACCESS_KEY_ID", "ak")
	t.Setenv("ALIYUN_SMS_SIGN_NAME", "圈圈")
	t.Setenv("ALIYUN_SMS_TEMPLATE_CODE", "SMS_1")
	// The secret comes from a mounted file.
	f := filepath.Join(t.TempDir(), "sk")
	os.WriteFile(f, []byte("secret-from-file\n"), 0o600)
	t.Setenv("ALIYUN_ACCESS_KEY_SECRET_FILE", f)

	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.Aliyun.AccessKeySecret != "secret-from-file" {
		t.Fatalf("secret file: %q", c.Aliyun.AccessKeySecret)
	}
	if err := c.ValidateProd(); err != nil {
		t.Fatalf("only sms enabled and configured: %v", err)
	}

	t.Setenv("LOOPLAND_DISABLE", "")
	t.Setenv("LOOPLAND_PUBLIC_BASE_URL", "http://localhost:8080")
	c, _ = Load()
	err = c.ValidateProd()
	if err == nil {
		t.Fatal("incomplete prod config accepted")
	}
	for _, want := range []string{"LOOPLAND_PUBLIC_BASE_URL", "wechat_pay needs", "ALIYUN_CAPTCHA_SCENE_ID"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error lacks %q:\n%v", want, err)
		}
	}
}

func TestProdRequiresSecrets(t *testing.T) {
	t.Setenv("LOOPLAND_ENV", "prod")
	t.Setenv("LOOPLAND_JWT_SECRET", "")
	if _, err := Load(); err == nil {
		t.Fatal("prod without JWT secret accepted")
	}
}

func TestYAMLFile(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "secrets"), 0o700)
	os.WriteFile(filepath.Join(dir, "secrets", "sk"), []byte("yaml-secret\n"), 0o600)
	p := filepath.Join(dir, "config.yaml")
	os.WriteFile(p, []byte(`
env: dev
http:
  addr: ":9999"
  public_base_url: https://api.example.com/
database:
  url: postgres://from-yaml
jobs:
  enabled: false
features:
  disabled: [alipay, apple_iap]
aliyun:
  access_key_id: ak-yaml
  access_key_secret_file: secrets/sk
alipay:
  sandbox: true
`), 0o600)
	t.Setenv("LOOPLAND_CONFIG", p)
	t.Setenv("LOOPLAND_DATABASE_URL", "postgres://from-env") // env wins
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.HTTPAddr != ":9999" || c.PublicBaseURL != "https://api.example.com" || c.DatabaseURL != "postgres://from-env" ||
		!c.JobsOff || len(c.Disabled) != 2 || c.Aliyun.AccessKeyID != "ak-yaml" || c.Aliyun.AccessKeySecret != "yaml-secret" || !c.Alipay.Sandbox {
		t.Fatalf("%+v", c)
	}
	if Source != p {
		t.Fatalf("source %q", Source)
	}

	os.WriteFile(p, []byte("htpp:\n  addr: \":1\"\n"), 0o600) // typo
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "htpp") {
		t.Fatalf("unknown key must fail: %v", err)
	}
}

func TestCommittedConfigFilesParse(t *testing.T) {
	for _, f := range []string{"../../../config.yaml", "../../../config.prod.example.yaml"} {
		if _, err := readFile(f); err != nil {
			t.Errorf("%s: %v", f, err)
		}
	}
}
