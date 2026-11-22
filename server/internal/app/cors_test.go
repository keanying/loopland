package app

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
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

// The realtime WebSocket follows the same origin list: the App's web build on
// another localhost port can connect in dev; foreign pages cannot; phone apps
// (no Origin header) always can.
func TestWebSocketOrigin(t *testing.T) {
	e := newEnv(t)
	c, _ := e.smsLogin("13900001234")
	wsURL := "ws" + strings.TrimPrefix(e.srv.URL, "http") + "/v1/ws?token=" + c.token
	dial := func(origin string) error {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		var opts *websocket.DialOptions
		if origin != "" {
			opts = &websocket.DialOptions{HTTPHeader: http.Header{"Origin": {origin}}}
		}
		ws, _, err := websocket.Dial(ctx, wsURL, opts)
		if err == nil {
			ws.CloseNow()
		}
		return err
	}
	for _, o := range []string{"", "http://localhost:5300", "http://127.0.0.1:61234"} {
		if err := dial(o); err != nil {
			t.Fatalf("origin %q rejected: %v", o, err)
		}
	}
	if dial("https://evil.example.com") == nil {
		t.Fatal("foreign origin accepted")
	}
}
