// Package legal serves the 用户协议 and 隐私政策 pages at /legal/terms and
// /legal/privacy. The App links here by default (its api.base_url +
// /legal/…); behind nginx, route /legal/ to the backend (docs/上线接入清单.md).
// Operator details come from server config (legal.*).
package legal

import (
	"bytes"
	"embed"
	"html/template"
	"net/http"
	"strings"

	"github.com/keanying/loopland/server/internal/platform/config"
)

// Version of the privacy policy the App asks users to accept. It must match
// the App's Env.privacyVersion (consents.privacy_version).
const Version = "2026-11"

//go:embed pages/*.html
var pages embed.FS

// page is one rendered document.
type page struct {
	Title, Short, Page                     string
	Company, Email, Address, EffectiveDate string
	Version                                string
}

// Handler serves the rendered pages (rendered once at startup).
type Handler struct {
	html map[string][]byte
}

// New renders both pages with the operator details.
func New(info config.Legal) (*Handler, error) {
	effective := strings.TrimSpace(info.EffectiveDate)
	if effective == "" {
		effective = Version
	}
	funcs := template.FuncMap{
		// field shows a configured value, or a visible 「待填写」 marker.
		"field": func(v, label string) template.HTML {
			if s := strings.TrimSpace(v); s != "" {
				return template.HTML(template.HTMLEscapeString(s))
			}
			return template.HTML(`<span class="todo">【待填写：` + template.HTMLEscapeString(label) + `】</span>`)
		},
	}
	h := &Handler{html: map[string][]byte{}}
	for name, title := range map[string][2]string{"terms": {"用户协议", "协议"}, "privacy": {"隐私政策", "政策"}} {
		t, err := template.New("layout").Funcs(funcs).ParseFS(pages, "pages/layout.html", "pages/"+name+".html")
		if err != nil {
			return nil, err
		}
		var buf bytes.Buffer
		if err := t.ExecuteTemplate(&buf, "layout", page{
			Title: title[0], Short: title[1], Page: name,
			Company: info.Company, Email: info.Email, Address: info.Address,
			EffectiveDate: effective, Version: Version,
		}); err != nil {
			return nil, err
		}
		h.html[name] = buf.Bytes()
	}
	return h, nil
}

// Routes registers GET /legal/terms and /legal/privacy (also with .html).
func (h *Handler) Routes(mux *http.ServeMux) {
	for name, body := range h.html {
		serve := func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Header().Set("Cache-Control", "public, max-age=300")
			w.Header().Set("X-Content-Type-Options", "nosniff")
			_, _ = w.Write(body)
		}
		mux.HandleFunc("GET /legal/"+name, serve)
		mux.HandleFunc("GET /legal/"+name+".html", serve)
	}
	mux.HandleFunc("GET /legal/{$}", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/legal/privacy", http.StatusFound)
	})
}
