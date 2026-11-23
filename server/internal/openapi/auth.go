package openapi

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Signature rules (docs «签名»).
const (
	TimestampWindow = 300 * time.Second
	NonceTTL        = 10 * time.Minute
	RateLimit       = 120 // calls per app per minute
	IdempotencyTTL  = 24 * time.Hour
	// IdempotencyPendingTTL bounds the "in progress" marker: if the process
	// dies mid-request the key frees itself instead of blocking for 24 h.
	IdempotencyPendingTTL = 2 * time.Minute
	maxBody               = 1 << 20
)

func strconvItoa(n int64) string { return strconv.FormatInt(n, 10) }

func qInt(r *http.Request, k string) int64 {
	n, _ := strconv.ParseInt(r.URL.Query().Get(k), 10, 64)
	return n
}

func readBody(r *http.Request, limit int64) ([]byte, error) {
	return readBodyOr(r, limit, httpx.BadRequest("invalid_body", "请求体太大"))
}

func readBodyOr(r *http.Request, limit int64, tooLarge error) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, tooLarge
	}
	return b, nil
}

func jsonUnmarshal(b []byte, v any) error { return json.Unmarshal(b, v) }

// decodeStrict decodes a JSON body rejecting unknown fields.
func decodeStrict(b []byte, v any) error {
	if len(bytes.TrimSpace(b)) == 0 {
		return httpx.BadRequest("invalid_body", "请求体为空")
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return httpx.BadRequest("invalid_body", "请求格式错误："+err.Error())
	}
	return nil
}

// StringToSign is METHOD \n path \n sorted query \n timestamp \n nonce \n hex(SHA256(body)).
func StringToSign(method, path, query, ts, nonce string, body []byte) string {
	sum := sha256.Sum256(body)
	return strings.Join([]string{method, path, query, ts, nonce, hex.EncodeToString(sum[:])}, "\n")
}

// Sign is hex(HMAC-SHA256(secret, string to sign)).
func Sign(secret, s string) string {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(s))
	return hex.EncodeToString(m.Sum(nil))
}

type ctxKey struct{}

// caller is the authenticated app of an /open/v1 request.
type caller struct {
	app App
}

func callerOf(ctx context.Context) caller {
	c, _ := ctx.Value(ctxKey{}).(caller)
	return c
}

// recorder captures the status and (for errors and idempotent requests)
// the body of a response.
type recorder struct {
	http.ResponseWriter
	status  int
	body    bytes.Buffer
	keepAll bool
}

func (w *recorder) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (w *recorder) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	if w.keepAll || (w.status >= 400 && w.body.Len() < 4096) {
		w.body.Write(b)
	}
	return w.ResponseWriter.Write(b)
}

func errCode(body []byte) *string {
	var e struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &e) == nil && e.Error.Code != "" {
		return &e.Error.Code
	}
	return nil
}

var (
	errInvalidSignature = httpx.E(http.StatusUnauthorized, "invalid_signature", "签名错误或缺少签名头")
	errTimestamp        = httpx.E(http.StatusUnauthorized, "timestamp_expired", "X-Loop-Timestamp 与服务器时间相差超过 300 秒")
	errNonce            = httpx.E(http.StatusUnauthorized, "nonce_reused", "X-Loop-Nonce 在 10 分钟内已经用过")
	errInvalidApp       = httpx.E(http.StatusUnauthorized, "invalid_app", "app_id 不存在")
	errAppDisabled      = httpx.Forbidden("app_disabled", "应用已停用或商户已暂停合作")
	errIP               = httpx.Forbidden("ip_not_allowed", "调用方 IP 不在白名单内")
	errScope            = httpx.Forbidden("scope_denied", "应用没有这个接口的权限（scope）")
)

func ipAllowed(list []string, ip string) bool {
	if len(list) == 0 {
		return true
	}
	addr := net.ParseIP(strings.TrimSpace(ip))
	for _, x := range list {
		if x == ip {
			return true
		}
		if _, n, err := net.ParseCIDR(x); err == nil && addr != nil && n.Contains(addr) {
			return true
		}
	}
	return false
}

// guard authenticates a signed call and checks the scope, then runs h.
// Every call of a known app is logged (without the body).
func (s *Service) guard(scope string, h httpx.HandlerFunc) http.Handler {
	return s.guardBody(scope, maxBody, httpx.BadRequest("invalid_body", "请求体太大"), h)
}

// guardBody is guard with another body limit (uploads): the whole raw body
// is read and signed, tooLarge is returned past limit.
func (s *Service) guardBody(scope string, limit int64, tooLarge error, h httpx.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &recorder{ResponseWriter: w}
		var app *App
		err := s.authenticate(rec, r, scope, limit, tooLarge, &app, h)
		if err != nil {
			if he, ok := err.(*httpx.Error); ok && he.Status == http.StatusTooManyRequests {
				rec.Header().Set("Retry-After", strconv.Itoa(60-int(s.now().Unix()%60)))
			}
			httpx.WriteError(rec, r, err)
		}
		if app == nil {
			return
		}
		status := rec.status
		if status == 0 {
			status = http.StatusOK
		}
		var code *string
		if status >= 400 {
			code = errCode(rec.body.Bytes())
		}
		ctx := context.WithoutCancel(r.Context())
		_, _ = s.Pool.Exec(ctx, `INSERT INTO src.src_mer_loop_open_call_log (open_app_id, http_method, request_path, status_code, error_code, latency_ms, client_ip)
			VALUES ($1,$2,$3,$4,$5,$6,$7)`, app.ID, r.Method, r.URL.Path, status, code, int(time.Since(start).Milliseconds()), httpx.ClientIP(r))
		_, _ = s.Pool.Exec(ctx, `UPDATE src.src_mer_loop_open_app SET last_use_time=now() WHERE id=$1 AND (last_use_time IS NULL OR last_use_time < now() - interval '1 minute')`, app.ID)
	})
}

func (s *Service) authenticate(w *recorder, r *http.Request, scope string, limit int64, tooLarge error, out **App, h httpx.HandlerFunc) error {
	ctx := r.Context()
	appID, ts, nonce, sig := r.Header.Get("X-Loop-App-Id"), r.Header.Get("X-Loop-Timestamp"), r.Header.Get("X-Loop-Nonce"), r.Header.Get("X-Loop-Signature")
	if appID == "" || ts == "" || nonce == "" || sig == "" {
		return errInvalidSignature
	}
	a, err := scanApp(s.Pool.QueryRow(ctx, `SELECT `+appCols+appFrom+` WHERE a.app_code=$1`, appID))
	if db.IsNoRows(err) {
		return errInvalidApp
	}
	if err != nil {
		return err
	}
	*out = &a
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return errInvalidSignature
	}
	if d := s.now().Sub(time.Unix(sec, 0)); d > TimestampWindow || d < -TimestampWindow {
		return errTimestamp
	}
	if len(nonce) < 16 || len(nonce) > 64 {
		return errInvalidSignature
	}
	body, err := readBodyOr(r, limit, tooLarge)
	if err != nil {
		return err
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	secret, err := s.Box.Open(a.secretEnc)
	if err != nil {
		return err
	}
	want := Sign(secret, StringToSign(r.Method, r.URL.Path, r.URL.Query().Encode(), ts, nonce, body))
	if !hmac.Equal([]byte(strings.ToLower(sig)), []byte(want)) {
		return errInvalidSignature
	}
	ok, err := s.Redis.SetNX(ctx, fmt.Sprintf("open:nonce:%d:%s", a.ID, nonce), 1, NonceTTL).Result()
	if err != nil {
		return err
	}
	if !ok {
		return errNonce
	}
	if a.Status != "active" || a.merchantStatus == "suspended" {
		return errAppDisabled
	}
	if !ipAllowed(a.IPAllowlist, httpx.ClientIP(r)) {
		return errIP
	}
	key := fmt.Sprintf("open:rate:%d:%d", a.ID, s.now().Unix()/60)
	n, err := s.Redis.Incr(ctx, key).Result()
	if err != nil {
		return err
	}
	if n == 1 {
		s.Redis.Expire(ctx, key, 70*time.Second)
	}
	if n > RateLimit {
		return httpx.ErrRateLimited
	}
	if scope != "" && !containsStr(a.Scopes, scope) {
		return errScope
	}
	r = r.WithContext(context.WithValue(ctx, ctxKey{}, caller{app: a}))
	idem := r.Header.Get("Idempotency-Key")
	if r.Method != http.MethodPost || idem == "" {
		return h(w, r)
	}
	return s.idempotent(w, r, a.ID, idem, h)
}

func containsStr(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

type stored struct {
	Status int             `json:"status"`
	Body   json.RawMessage `json:"body"`
}

// idempotent answers a repeated Idempotency-Key with the first result (24
// hours); a request still running with the same key is 409.
func (s *Service) idempotent(w *recorder, r *http.Request, appID int64, idem string, h httpx.HandlerFunc) error {
	if len(idem) > 64 {
		return httpx.BadRequest("invalid_request", "Idempotency-Key 最多 64 个字符")
	}
	ctx := r.Context()
	key := fmt.Sprintf("open:idem:%d:%s", appID, idem)
	ok, err := s.Redis.SetNX(ctx, key, "pending", IdempotencyPendingTTL).Result()
	if err != nil {
		return err
	}
	if !ok {
		raw, err := s.Redis.Get(ctx, key).Bytes()
		if err != nil {
			return err
		}
		var st stored
		if string(raw) == "pending" || json.Unmarshal(raw, &st) != nil {
			return httpx.Conflict("idempotency_conflict", "同一个 Idempotency-Key 的请求还在处理中")
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Idempotent-Replayed", "true")
		w.WriteHeader(st.Status)
		if st.Status != http.StatusNoContent {
			_, _ = w.Write(st.Body)
		}
		return nil
	}
	w.keepAll = true
	bg := context.WithoutCancel(ctx)
	// A panic in the handler must not leave the key locked: release it and
	// let the panic reach the normal recovery (500).
	defer func() {
		if p := recover(); p != nil {
			s.Redis.Del(bg, key)
			panic(p)
		}
	}()
	if err := h(w, r); err != nil {
		httpx.WriteError(w, r, err)
	}
	if w.status == 0 {
		w.status = http.StatusOK
	}
	if w.status >= 500 {
		s.Redis.Del(bg, key)
		return nil
	}
	body := bytes.TrimSpace(w.body.Bytes())
	if len(body) == 0 {
		body = []byte("null")
	}
	raw, _ := json.Marshal(stored{Status: w.status, Body: body})
	s.Redis.Set(bg, key, raw, IdempotencyTTL)
	return nil
}
