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
