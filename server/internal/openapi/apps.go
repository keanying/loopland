// Package openapi is the merchant open platform (docs/api/v2-5-商户商品与开放
// 平台.md «开放平台»): app credentials managed in the back office, HMAC-signed
// /open/v1 calls (timestamp window, nonce replay, IP allowlist, scopes,
// per-app rate limit, Idempotency-Key, call log) and the endpoints merchant
// systems use for products, orders, redemptions, bookings, venues and
// blocks, promotions and statements.
package openapi

import (
	"context"
	"crypto/rand"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/keanying/loopland/server/internal/adminmsg"
	"github.com/keanying/loopland/server/internal/media"
	"github.com/keanying/loopland/server/internal/perks"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/platform/secure"
	"github.com/keanying/loopland/server/internal/product"
	"github.com/keanying/loopland/server/internal/venue"
	"github.com/keanying/loopland/server/internal/webhook"
)

// Scopes an app can hold.
var Scopes = []string{"products", "orders", "bookings", "redemptions", "statements", "venues", "promotions"}

// MaxApps is the number of apps a merchant may have.
const MaxApps = 5

// Service holds the open platform.
type Service struct {
	Pool     *pgxpool.Pool
	Redis    *redis.Client
	Box      *secure.Box
	Webhooks *webhook.Dispatcher
	Products *product.Service
	Perks    *perks.Service
	Venues   *venue.Service
	// Media stores POST /open/v1/media uploads.
	Media *media.Handler
	// Msg notifies merchant staff (应用被平台停用 / 启用).
	Msg *adminmsg.Notifier
	// Dev allows http:// webhook URLs (local receivers).
	Dev bool
	// Now is overridable in tests.
	Now func() time.Time
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Ref is {id, name}.
type Ref struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// App is OpenApp.
type App struct {
	ID            int64      `json:"id"`
	AppID         string     `json:"app_id"`
	Name          string     `json:"name"`
	Merchant      Ref        `json:"merchant"`
	Scopes        []string   `json:"scopes"`
	IPAllowlist   []string   `json:"ip_allowlist"`
	WebhookURL    *string    `json:"webhook_url"`
	WebhookEvents []string   `json:"webhook_events"`
	Status        string     `json:"status"`
	LastUsedAt    *time.Time `json:"last_used_at"`
	CreatedAt     time.Time  `json:"created_at"`
	// AppSecret is returned once, on create and reset-secret.
	AppSecret string `json:"app_secret,omitempty"`

	merchantStatus string
	disableType    *string
	secretEnc      []byte
}

const appCols = `a.id, a.app_code, a.app_name, a.merchant_id, m.merchant_name, m.merchant_status, a.scopes, a.ip_allowlist, a.webhook_url, a.webhook_events,
	a.app_status, a.disable_type, a.last_use_time, a.create_time, a.app_secret_enc`

const appFrom = ` FROM src.src_mer_loop_open_app a JOIN src.src_mer_loop_merchant m ON m.id=a.merchant_id `

func scanApp(r pgx.Row) (App, error) {
	var a App
	err := r.Scan(&a.ID, &a.AppID, &a.Name, &a.Merchant.ID, &a.Merchant.Name, &a.merchantStatus, &a.Scopes, &a.IPAllowlist, &a.WebhookURL, &a.WebhookEvents,
		&a.Status, &a.disableType, &a.LastUsedAt, &a.CreatedAt, &a.secretEnc)
	if a.Scopes == nil {
		a.Scopes = []string{}
	}
	if a.IPAllowlist == nil {
		a.IPAllowlist = []string{}
	}
	if a.WebhookEvents == nil {
		a.WebhookEvents = []string{}
	}
	return a, err
}

// Apps lists apps (merchant 0: all).
func (s *Service) Apps(ctx context.Context, merchant int64) ([]App, error) {
	rows, err := s.Pool.Query(ctx, `SELECT `+appCols+appFrom+` WHERE ($1 = 0 OR a.merchant_id=$1) ORDER BY a.id DESC LIMIT 200`, merchant)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (App, error) { return scanApp(r) })
	if out == nil {
		out = []App{}
	}
	return out, err
}

// LoadApp loads an app (scope: a merchant's own; others are 404).
func (s *Service) LoadApp(ctx context.Context, q db.Querier, scope *int64, id int64) (App, error) {
	a, err := scanApp(q.QueryRow(ctx, `SELECT `+appCols+appFrom+` WHERE a.id=$1 AND ($2::bigint IS NULL OR a.merchant_id=$2)`, id, scope))
	if db.IsNoRows(err) {
		return a, httpx.NotFound("应用")
	}
	return a, err
}

// AppInput is POST / PATCH /admin/v1/open-apps (PATCH: the fields sent;
// webhook_url null or "" clears it).
type AppInput struct {
	Name          *string   `json:"name"`
	Scopes        *[]string `json:"scopes"`
	IPAllowlist   *[]string `json:"ip_allowlist"`
	WebhookURL    *string   `json:"webhook_url"`
	WebhookEvents *[]string `json:"webhook_events"`
}

type appState struct {
	name          string
	scopes, ips   []string
	webhookURL    *string
	webhookEvents []string
}

func (s *Service) apply(in AppInput, st appState, urlSent bool) (appState, error) {
	bad := func(msg string) error { return httpx.BadRequest("invalid_body", msg) }
	if in.Name != nil {
		st.name = strings.TrimSpace(*in.Name)
	}
	if in.Scopes != nil {
		st.scopes = *in.Scopes
	}
	if in.IPAllowlist != nil {
		st.ips = *in.IPAllowlist
	}
	if urlSent {
		st.webhookURL = in.WebhookURL
		if st.webhookURL != nil && strings.TrimSpace(*st.webhookURL) == "" {
			st.webhookURL = nil
		}
	}
	if in.WebhookEvents != nil {
		st.webhookEvents = *in.WebhookEvents
	}
	if n := utf8.RuneCountInString(st.name); n < 1 || n > 30 {
		return st, bad("应用名称 1–30 字")
	}
	clean := func(xs []string) []string {
		out := []string{}
		for _, x := range xs {
			if x = strings.TrimSpace(x); x != "" && !slices.Contains(out, x) {
				out = append(out, x)
			}
		}
		return out
	}
	st.scopes, st.ips, st.webhookEvents = clean(st.scopes), clean(st.ips), clean(st.webhookEvents)
	for _, sc := range st.scopes {
		if !slices.Contains(Scopes, sc) {
			return st, bad("scope 取值错误：" + sc)
		}
	}
	if len(st.ips) > 20 {
		return st, bad("IP 白名单最多 20 个")
	}
	for _, ip := range st.ips {
		if net.ParseIP(ip) == nil {
			if _, _, err := net.ParseCIDR(ip); err != nil {
				return st, bad("IP 白名单格式错误：" + ip)
			}
		}
	}
	for _, ev := range st.webhookEvents {
		if _, ok := webhook.Scope[ev]; !ok || ev == webhook.Ping {
			return st, bad("事件类型取值错误：" + ev)
		}
	}
	if st.webhookURL != nil {
		u, err := url.Parse(strings.TrimSpace(*st.webhookURL))
		if err != nil || u.Host == "" || (u.Scheme != "https" && !(s.Dev && u.Scheme == "http")) || len(*st.webhookURL) > 500 {
			return st, bad("Webhook 地址须为 https:// 开头的完整网址")
		}
		v := u.String()
		st.webhookURL = &v
	}
	return st, nil
}

const secretAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"

func randomString(n int, alphabet string) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return string(b)
}

func newSecret() string { return "lps_" + randomString(40, secretAlphabet) }

// CreateApp creates an app of the merchant and returns it with its secret.
func (s *Service) CreateApp(ctx context.Context, tx pgx.Tx, merchant, adminID int64, in AppInput) (App, error) {
	st, err := s.apply(in, appState{}, true)
	if err != nil {
		return App{}, err
	}
	var n int
	if _, err := tx.Exec(ctx, `SELECT 1 FROM src.src_mer_loop_merchant WHERE id=$1 FOR UPDATE`, merchant); err != nil {
		return App{}, err
	}
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM src.src_mer_loop_open_app WHERE merchant_id=$1`, merchant).Scan(&n); err != nil {
		return App{}, err
	}
	if n >= MaxApps {
		return App{}, httpx.Conflict("app_limit", "每个商户最多创建 5 个应用")
	}
	secret := newSecret()
	var id int64
	for attempt := 0; ; attempt++ {
		err = tx.QueryRow(ctx, `INSERT INTO src.src_mer_loop_open_app (app_code, merchant_id, app_name, scopes, ip_allowlist, webhook_url, webhook_events,
				app_secret_enc, create_admin_id) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT (app_code) DO NOTHING RETURNING id`,
			"lpa_"+randomString(8, "abcdefghijkmnpqrstuvwxyz23456789"), merchant, st.name, st.scopes, st.ips, st.webhookURL, st.webhookEvents,
			s.Box.Seal(secret), adminID).Scan(&id)
		if err == nil {
			break
		}
		if !db.IsNoRows(err) || attempt >= 5 {
			return App{}, err
		}
	}
	a, err := s.LoadApp(ctx, tx, nil, id)
	a.AppSecret = secret
	return a, err
}

// UpdateApp is PATCH /admin/v1/open-apps/{id}.
func (s *Service) UpdateApp(ctx context.Context, tx pgx.Tx, scope *int64, id int64, in AppInput, urlSent bool) error {
	a, err := s.LoadApp(ctx, tx, scope, id)
	if err != nil {
		return err
	}
	st, err := s.apply(in, appState{name: a.Name, scopes: a.Scopes, ips: a.IPAllowlist, webhookURL: a.WebhookURL, webhookEvents: a.WebhookEvents}, urlSent)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE src.src_mer_loop_open_app SET app_name=$2, scopes=$3, ip_allowlist=$4, webhook_url=$5, webhook_events=$6, update_time=now()
		WHERE id=$1`, id, st.name, st.scopes, st.ips, st.webhookURL, st.webhookEvents)
	return err
}

// ResetSecret issues a new secret (the old one stops working at once).
func (s *Service) ResetSecret(ctx context.Context, tx pgx.Tx, scope *int64, id int64) (App, error) {
	if _, err := s.LoadApp(ctx, tx, scope, id); err != nil {
		return App{}, err
	}
	secret := newSecret()
	if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_open_app SET app_secret_enc=$2, update_time=now() WHERE id=$1`, id, s.Box.Seal(secret)); err != nil {
		return App{}, err
	}
	a, err := s.LoadApp(ctx, tx, scope, id)
	a.AppSecret = secret
	return a, err
}

// SetStatus disables or enables an app. An app the platform disabled can
// only be enabled by the platform.
func (s *Service) SetStatus(ctx context.Context, tx pgx.Tx, scope *int64, id int64, enable bool) error {
	a, err := s.LoadApp(ctx, tx, scope, id)
	if err != nil {
		return err
	}
	if enable {
		if scope != nil && a.disableType != nil && *a.disableType == "platform" {
			return httpx.Forbidden("forbidden", "这个应用被平台停用，请联系平台处理")
		}
		_, err = tx.Exec(ctx, `UPDATE src.src_mer_loop_open_app SET app_status='active', disable_type=NULL, update_time=now() WHERE id=$1`, id)
		if err == nil && scope == nil && a.Status != "active" {
			s.Msg.ToMerchant(ctx, a.Merchant.ID, adminmsg.Msg{Category: adminmsg.CatOpenAPI, Level: adminmsg.Info,
				Title: "应用「" + a.Name + "」已被平台重新启用", Body: "接口调用和 Webhook 推送已恢复。", Link: "/merchant/open-apps",
				RefType: "open_app", RefID: a.ID})
		}
		return err
	}
	by := "platform"
	if scope != nil {
		by = "merchant"
	}
	_, err = tx.Exec(ctx, `UPDATE src.src_mer_loop_open_app SET app_status='disabled', disable_type=$2, update_time=now() WHERE id=$1`, id, by)
	if err == nil && scope == nil && a.Status == "active" {
		s.Msg.ToMerchant(ctx, a.Merchant.ID, adminmsg.Msg{Category: adminmsg.CatOpenAPI, Level: adminmsg.Warning,
			Title: "应用「" + a.Name + "」已被平台停用", Body: "接口调用会返回 403 app_disabled，Webhook 停止推送；如有疑问请联系平台。", Link: "/merchant/open-apps",
			RefType: "open_app", RefID: a.ID})
	}
	return err
}

// DeleteApp deletes an app with its call log and deliveries.
func (s *Service) DeleteApp(ctx context.Context, tx pgx.Tx, scope *int64, id int64) error {
	if _, err := s.LoadApp(ctx, tx, scope, id); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `DELETE FROM src.src_mer_loop_open_app WHERE id=$1`, id)
	return err
}

// Call is a call log row.
type Call struct {
	ID         int64     `json:"id"`
	Method     string    `json:"method"`
	Path       string    `json:"path"`
	StatusCode int       `json:"status_code"`
	ErrorCode  *string   `json:"error_code"`
	LatencyMs  int       `json:"latency_ms"`
	IP         string    `json:"ip"`
	CreatedAt  time.Time `json:"created_at"`
}

// Calls lists the last 7 days of an app's calls.
func (s *Service) Calls(ctx context.Context, appID int64, p httpx.Page) ([]Call, int, error) {
	where := `open_app_id=$1 AND create_time > now() - interval '7 days'`
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_mer_loop_open_call_log WHERE `+where, appID).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT id, http_method, request_path, status_code, error_code, latency_ms, client_ip, create_time
		FROM src.src_mer_loop_open_call_log WHERE `+where+` ORDER BY id DESC LIMIT $2 OFFSET $3`, appID, p.Size, p.Offset())
	if err != nil {
		return nil, 0, err
	}
	items, err := pgx.CollectRows(rows, pgx.RowToStructByPos[Call])
	if items == nil {
		items = []Call{}
	}
	return items, total, err
}

// ---------------------------------------------------------------- admin

// AdminHandler serves /admin/v1/open-apps.
type AdminHandler struct {
	Svc   *Service
	Audit func(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error
	// Scope returns the merchant a staff account is limited to (admin.MerchantScope).
	Scope func(ctx context.Context) (*int64, error)
}

// Routes registers the endpoints; manage is admin + merchant
// (openapi.manage). Credentials are created and changed by merchant staff;
// the platform sees all apps and can disable them.
func (h *AdminHandler) Routes(mux *http.ServeMux, manage func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /admin/v1/open-apps", manage(h.list))
	mux.Handle("POST /admin/v1/open-apps", manage(h.create))
	mux.Handle("GET /admin/v1/open-apps/{id}", manage(h.get))
	mux.Handle("PATCH /admin/v1/open-apps/{id}", manage(h.patch))
	mux.Handle("DELETE /admin/v1/open-apps/{id}", manage(h.delete))
	mux.Handle("POST /admin/v1/open-apps/{id}/reset-secret", manage(h.resetSecret))
	mux.Handle("POST /admin/v1/open-apps/{id}/disable", manage(h.status(false)))
	mux.Handle("POST /admin/v1/open-apps/{id}/enable", manage(h.status(true)))
	mux.Handle("GET /admin/v1/open-apps/{id}/calls", manage(h.calls))
	mux.Handle("GET /admin/v1/open-apps/{id}/deliveries", manage(h.deliveries))
	mux.Handle("POST /admin/v1/open-apps/{id}/deliveries/{did}/redeliver", manage(h.redeliver))
	mux.Handle("POST /admin/v1/open-apps/{id}/test-webhook", manage(h.testWebhook))
}

func itoa(n int64) string { return strconvItoa(n) }

func adminID(r *http.Request) int64 {
	ad, _ := httpx.AdminFrom(r.Context())
	return ad.ID
}

// merchantOnly returns the staff's merchant (platform accounts: 403).
func (h *AdminHandler) merchantOnly(r *http.Request) (*int64, error) {
	scope, err := h.Scope(r.Context())
	if err != nil {
		return nil, err
	}
	if scope == nil {
		return nil, httpx.Forbidden("forbidden", "应用凭证由商户账号管理，平台只能查看和停用")
	}
	return scope, nil
}

func (h *AdminHandler) list(w http.ResponseWriter, r *http.Request) error {
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	m := qInt(r, "merchant_id")
	if scope != nil {
		m = *scope
	}
	items, err := h.Svc.Apps(r.Context(), m)
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (h *AdminHandler) get(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	scope, err := h.Scope(r.Context())
	if err != nil {
		return err
	}
	a, err := h.Svc.LoadApp(r.Context(), h.Svc.Pool, scope, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, a)
}

func (h *AdminHandler) create(w http.ResponseWriter, r *http.Request) error {
	scope, err := h.merchantOnly(r)
	if err != nil {
		return err
	}
	var in AppInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	var a App
	err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		var err error
		if a, err = h.Svc.CreateApp(r.Context(), tx, *scope, adminID(r), in); err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, "open_app.create", "open_app:"+itoa(a.ID), map[string]any{"name": a.Name, "scopes": a.Scopes, "app_id": a.AppID})
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, a)
}

func (h *AdminHandler) patch(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	scope, err := h.merchantOnly(r)
	if err != nil {
		return err
	}
	var raw map[string]any
	var in AppInput
	body, err := readBody(r, 64<<10)
	if err != nil {
		return err
	}
	if err := decodeStrict(body, &in); err != nil {
		return err
	}
	_ = jsonUnmarshal(body, &raw)
	_, urlSent := raw["webhook_url"]
	err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		if err := h.Svc.UpdateApp(r.Context(), tx, scope, id, in, urlSent); err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, "open_app.update", "open_app:"+itoa(id), map[string]any{"name": in.Name, "scopes": in.Scopes, "webhook_events": in.WebhookEvents})
	})
	if err != nil {
		return err
	}
	return h.get(w, r)
}

func (h *AdminHandler) delete(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	scope, err := h.merchantOnly(r)
	if err != nil {
		return err
	}
	err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		if err := h.Svc.DeleteApp(r.Context(), tx, scope, id); err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, "open_app.delete", "open_app:"+itoa(id), nil)
	})
	if err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (h *AdminHandler) resetSecret(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	scope, err := h.merchantOnly(r)
	if err != nil {
		return err
	}
	var a App
	err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
		var err error
		if a, err = h.Svc.ResetSecret(r.Context(), tx, scope, id); err != nil {
			return err
		}
		return h.Audit(r.Context(), tx, "open_app.reset_secret", "open_app:"+itoa(id), nil)
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, a)
}

func (h *AdminHandler) status(enable bool) httpx.HandlerFunc {
	action := "open_app.disable"
	if enable {
		action = "open_app.enable"
	}
	return func(w http.ResponseWriter, r *http.Request) error {
		id, err := httpx.PathID(r, "id")
		if err != nil {
			return err
		}
		scope, err := h.Scope(r.Context())
		if err != nil {
			return err
		}
		err = pgx.BeginFunc(r.Context(), h.Svc.Pool, func(tx pgx.Tx) error {
			if err := h.Svc.SetStatus(r.Context(), tx, scope, id, enable); err != nil {
				return err
			}
			return h.Audit(r.Context(), tx, action, "open_app:"+itoa(id), nil)
		})
		if err != nil {
			return err
		}
		return h.get(w, r)
	}
}

// scopedApp checks the caller may see the app.
func (h *AdminHandler) scopedApp(r *http.Request) (int64, error) {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return 0, err
	}
	scope, err := h.Scope(r.Context())
	if err != nil {
		return 0, err
	}
	if _, err := h.Svc.LoadApp(r.Context(), h.Svc.Pool, scope, id); err != nil {
		return 0, err
	}
	return id, nil
}

func (h *AdminHandler) calls(w http.ResponseWriter, r *http.Request) error {
	id, err := h.scopedApp(r)
	if err != nil {
		return err
	}
	items, total, err := h.Svc.Calls(r.Context(), id, httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) deliveries(w http.ResponseWriter, r *http.Request) error {
	id, err := h.scopedApp(r)
	if err != nil {
		return err
	}
	items, total, err := webhook.Deliveries(r.Context(), h.Svc.Pool, id, httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) redeliver(w http.ResponseWriter, r *http.Request) error {
	id, err := h.scopedApp(r)
	if err != nil {
		return err
	}
	did, err := httpx.PathID(r, "did")
	if err != nil {
		return err
	}
	d, err := h.Svc.Webhooks.Redeliver(r.Context(), id, did)
	if err != nil {
		return err
	}
	if err := h.Audit(r.Context(), h.Svc.Pool, "open_app.redeliver", "open_app:"+itoa(id), map[string]any{"delivery_id": did, "status": d.Status}); err != nil {
		return err
	}
	return httpx.OK(w, d)
}

func (h *AdminHandler) testWebhook(w http.ResponseWriter, r *http.Request) error {
	id, err := h.scopedApp(r)
	if err != nil {
		return err
	}
	d, err := h.Svc.Webhooks.Ping(r.Context(), id)
	if err != nil {
		return err
	}
	if err := h.Audit(r.Context(), h.Svc.Pool, "open_app.test_webhook", "open_app:"+itoa(id), map[string]any{"status": d.Status}); err != nil {
		return err
	}
	return httpx.OK(w, d)
}
