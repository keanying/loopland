package legal

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/keanying/loopland/server/internal/platform/config"
)

func get(t *testing.T, h *Handler, path string) (int, string, http.Header) {
	t.Helper()
	mux := http.NewServeMux()
	h.Routes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec.Code, rec.Body.String(), rec.Header()
}

func TestPagesShowPlaceholdersUntilConfigured(t *testing.T) {
	h, err := New(config.Legal{})
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"/legal/terms", "/legal/privacy", "/legal/terms.html", "/legal/privacy.html"} {
		code, body, hdr := get(t, h, p)
		if code != http.StatusOK || !strings.HasPrefix(hdr.Get("Content-Type"), "text/html") {
			t.Fatalf("%s: %d %v", p, code, hdr)
		}
		if !strings.Contains(body, "【待填写：运营主体名称】") || !strings.Contains(body, "版本 "+Version) {
			t.Fatalf("%s: placeholders / version missing", p)
		}
	}
	_, terms, _ := get(t, h, "/legal/terms")
	_, privacy, _ := get(t, h, "/legal/privacy")
	if !strings.Contains(terms, "<h1>用户协议</h1>") || !strings.Contains(privacy, "<h1>隐私政策</h1>") {
		t.Fatal("titles")
	}
	if !strings.Contains(privacy, "起点和终点 200 米") || !strings.Contains(terms, "7 天冷静期") {
		t.Fatal("key facts missing")
	}
	if code, _, hdr := get(t, h, "/legal/"); code != http.StatusFound || hdr.Get("Location") != "/legal/privacy" {
		t.Fatalf("index: %d %v", code, hdr)
	}
}

func TestPagesUseOperatorDetails(t *testing.T) {
	h, err := New(config.Legal{Company: "上海圈圈运动科技有限公司", Email: "privacy@loopland.cn", Address: "上海市<浦东>新区", EffectiveDate: "2026-12-01"})
	if err != nil {
		t.Fatal(err)
	}
	_, body, _ := get(t, h, "/legal/privacy")
	for _, want := range []string{"上海圈圈运动科技有限公司", "privacy@loopland.cn", "生效日期 2026-12-01", "上海市&lt;浦东&gt;新区"} {
		if !strings.Contains(body, want) {
			t.Fatalf("missing %q", want)
		}
	}
	if strings.Contains(body, "待填写") {
		t.Fatal("placeholder left")
	}
}
