package app

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/keanying/loopland/server/internal/providers"
)

type providerView struct {
	Code       string         `json:"code"`
	Enabled    bool           `json:"enabled"`
	Configured bool           `json:"configured"`
	Source     string         `json:"source"`
	Values     map[string]any `json:"values"`
	LastCheck  *struct {
		Status  string `json:"status"`
		Message string `json:"message"`
	} `json:"last_check"`
}

func TestProviderConfig(t *testing.T) {
	e := newEnv(t)
	ad := adminClient(t, e)

	// A fake OpenAI-compatible endpoint that accepts one key.
	var calls atomic.Int32
	ai := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/v1/chat/completions" || r.Header.Get("Authorization") != "Bearer sk-test-abcdef123456" {
			w.WriteHeader(http.StatusUnauthorized)
			io.WriteString(w, `{"error":{"message":"invalid api key"}}`)
			return
		}
		io.WriteString(w, `{"choices":[]}`)
	}))
	defer ai.Close()

	var feat Features
	e.anon().must("GET", "/v1/config/features", nil, &feat)
	if feat.AI {
		t.Fatal("AI enabled before configuration")
	}

	var list struct {
		Items []providerView `json:"items"`
	}
	ad.must("GET", "/admin/v1/providers", nil, &list)
	if len(list.Items) != len(providers.Defs) {
		t.Fatalf("got %d services", len(list.Items))
	}
	byCode := func() map[string]providerView {
		ad.must("GET", "/admin/v1/providers", nil, &list)
		m := map[string]providerView{}
		for _, v := range list.Items {
			m[v.Code] = v
		}
		return m
	}
	if v := byCode()[providers.Aliyun]; v.Source != "none" || v.Values["access_key_secret"].(map[string]any)["set"] != false {
		t.Fatalf("aliyun view: %+v", v)
	}

	// Validation.
	ad.expectErr("PUT", "/admin/v1/providers/ai", map[string]any{"enabled": true, "values": map[string]string{}}, 400, "invalid_config")
	ad.expectErr("PUT", "/admin/v1/providers/ai", map[string]any{"values": map[string]string{"nope": "1"}}, 400, "invalid_config")
	ad.expectErr("PUT", "/admin/v1/providers/ai", map[string]any{"values": map[string]string{"timeout_s": "abc"}}, 400, "invalid_config")
	ad.expectErr("PUT", "/admin/v1/providers/sms", map[string]any{"enabled": true, "values": map[string]string{"template_code": "SMS_1"}}, 400, "invalid_config")
	ad.expectErr("PUT", "/admin/v1/providers/nope", map[string]any{}, 404, "not_found")

	// Save AI.
	var saved providerView
	ad.must("PUT", "/admin/v1/providers/ai", map[string]any{"enabled": true, "values": map[string]string{
		"vendor": "custom", "base_url": ai.URL + "/v1", "api_key": "sk-test-abcdef123456", "model": "m1",
		"display_name": "测试模型", "registration_no": "Beijing-Test-2026"}}, &saved)
	mk := saved.Values["api_key"].(map[string]any)
	if !saved.Enabled || saved.Source != "db" || mk["set"] != true || mk["hint"] != "sk****56" {
		t.Fatalf("saved view: %+v", saved)
	}
	raw, _ := json.Marshal(saved)
	if bytes.Contains(raw, []byte("abcdef123456")) {
		t.Fatal("secret returned to the admin console")
	}

	// Stored encrypted; the audit log names fields only.
	var cfgJSON, enc []byte
	if err := e.app.Pool.QueryRow(context.Background(), `SELECT config_json, secret_enc FROM src.src_sys_loop_provider_config WHERE provider_code='ai'`).Scan(&cfgJSON, &enc); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(cfgJSON, []byte("abcdef")) || bytes.Contains(enc, []byte("abcdef")) || len(enc) == 0 {
		t.Fatalf("secret stored in plain text: %s / %x", cfgJSON, enc)
	}
	var detail string
	if err := e.app.Pool.QueryRow(context.Background(), `SELECT detail_json::text FROM src.src_sys_loop_audit_log WHERE action='provider.save' ORDER BY id DESC LIMIT 1`).Scan(&detail); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(detail, "abcdef") || !strings.Contains(detail, "api_key") {
		t.Fatalf("audit detail: %s", detail)
	}

	// Applies without a restart.
	e.anon().must("GET", "/v1/config/features", nil, &feat)
	if !feat.AI {
		t.Fatal("AI not enabled after saving")
	}
	if s := e.app.Providers.Current().AI; s == nil || s.APIKey != "sk-test-abcdef123456" || s.WeeklyFreeQuota != 3 {
		t.Fatalf("live AI config: %+v", s)
	}

	// An empty secret keeps the stored one; the test passes.
	ad.must("PUT", "/admin/v1/providers/ai", map[string]any{"enabled": true, "values": map[string]string{"api_key": "", "model": "m2"}}, nil)
	var res struct {
		Status  string `json:"status"`
		Message string `json:"message"`
	}
	ad.must("POST", "/admin/v1/providers/ai/test", nil, &res)
	if res.Status != "ok" {
		t.Fatalf("test: %+v", res)
	}

	// A wrong key fails the test, and the result is shown on the page.
	ad.must("PUT", "/admin/v1/providers/ai", map[string]any{"enabled": true, "values": map[string]string{"api_key": "sk-wrong-000000000"}}, nil)
	ad.must("POST", "/admin/v1/providers/ai/test", nil, &res)
	if res.Status != "fail" || !strings.Contains(res.Message, "invalid api key") {
		t.Fatalf("test with wrong key: %+v", res)
	}
	if v := byCode()["ai"]; v.LastCheck == nil || v.LastCheck.Status != "fail" || v.Values["model"] != "m2" {
		t.Fatalf("after failed test: %+v", v)
	}
	if calls.Load() != 2 {
		t.Fatalf("fake AI called %d times", calls.Load())
	}

	// Testing a service never saved does not take over its configuration.
	ad.must("POST", "/admin/v1/providers/wechat_login/test", nil, &res)
	if v := byCode()["wechat_login"]; v.Source == "db" || v.LastCheck == nil {
		t.Fatalf("test changed the source: %+v", v)
	}

	// Disabling takes effect immediately; clear removes a secret.
	ad.must("PUT", "/admin/v1/providers/ai", map[string]any{"enabled": false, "clear": []string{"api_key"}}, nil)
	e.anon().must("GET", "/v1/config/features", nil, &feat)
	if feat.AI || e.app.Providers.Current().AI != nil {
		t.Fatal("AI still enabled")
	}
	if v := byCode()["ai"]; v.Values["api_key"].(map[string]any)["set"] != false {
		t.Fatalf("secret not cleared: %+v", v)
	}

	// Another instance picks the saved rows up.
	other := &providers.Registry{Pool: e.app.Pool, Box: e.app.Providers.Box, Cfg: e.app.Providers.Cfg, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if err := other.Load(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := other.Current().Eff["ai"]; got.Source != "db" || got.Enabled || got.Values["model"] != "m2" {
		t.Fatalf("other instance: %+v", got)
	}

	// Ops staff can't see or change third-party keys.
	ad.must("POST", "/admin/v1/admins", map[string]string{"username": "ops1", "password": "ops-password-123", "role": "ops"}, nil)
	ops := e.anon()
	var login struct {
		Token string `json:"token"`
	}
	ops.must("POST", "/admin/v1/login", map[string]string{"username": "ops1", "password": "ops-password-123"}, &login)
	ops.token = login.Token
	if st := ops.do("GET", "/admin/v1/providers", nil, nil); st != http.StatusForbidden {
		t.Fatalf("ops got %d", st)
	}

	// Dev fallbacks still work with nothing configured.
	e.anon().must("GET", "/v1/config/features", nil, &feat)
	if !slices.Contains(feat.Login, "sms") || !slices.Contains(feat.Pay, "mock") {
		t.Fatalf("dev features: %+v", feat)
	}
}
