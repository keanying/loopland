package app

import (
	"net/http"
	"testing"
)

// The App's web build (flutter run -d chrome / web-server on another
// localhost port) calls the API cross-origin: preflights must succeed in dev.
func TestCORS(t *testing.T) {
	e := newEnv(t)
	do := func(method, origin string, hdr map[string]string) *http.Response {
		req, _ := http.NewRequest(method, e.srv.URL+"/v1/auth/login", nil)
		req.Header.Set("Origin", origin)
		for k, v := range hdr {
			req.Header.Set(k, v)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp
	}
	pre := map[string]string{"Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type,authorization"}
	r := do("OPTIONS", "http://localhost:5300", pre)
	if r.StatusCode != http.StatusNoContent || r.Header.Get("Access-Control-Allow-Origin") != "http://localhost:5300" ||
		r.Header.Get("Access-Control-Allow-Headers") != "content-type,authorization" {
		t.Fatalf("preflight: %d %v", r.StatusCode, r.Header)
	}
	r = do("GET", "http://127.0.0.1:61234", nil)
	if r.Header.Get("Access-Control-Allow-Origin") != "http://127.0.0.1:61234" {
		t.Fatalf("simple request: %v", r.Header)
	}
	r = do("OPTIONS", "https://evil.example.com", pre)
	if r.Header.Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("foreign origin allowed: %v", r.Header)
	}
}
