// Package httpx holds the HTTP plumbing shared by every module: JSON in/out,
// the error envelope, pagination and authenticated principals.
package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
)

// Error is an API error with a stable code (see docs/api/v1.md).
type Error struct {
	Status  int
	Code    string
	Message string
	Extra   map[string]any
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

// E builds an Error.
func E(status int, code, format string, args ...any) *Error {
	return &Error{Status: status, Code: code, Message: fmt.Sprintf(format, args...)}
}

// Common errors.
func BadRequest(code, msg string) *Error { return E(http.StatusBadRequest, code, "%s", msg) }
func NotFound(what string) *Error        { return E(http.StatusNotFound, "not_found", "%s不存在", what) }
func Forbidden(code, msg string) *Error  { return E(http.StatusForbidden, code, "%s", msg) }
func Conflict(code, msg string) *Error   { return E(http.StatusConflict, code, "%s", msg) }

var (
	ErrUnauthorized = E(http.StatusUnauthorized, "unauthorized", "请先登录")
	ErrForbidden    = E(http.StatusForbidden, "forbidden", "没有权限")
	ErrRateLimited  = E(http.StatusTooManyRequests, "rate_limited", "操作太频繁，请稍后再试")
)

// HandlerFunc is an http handler that returns an error.
type HandlerFunc func(w http.ResponseWriter, r *http.Request) error

// Logger is used by Wrap for unexpected errors.
var Logger = slog.Default()

// Wrap adapts a HandlerFunc, rendering errors as the JSON envelope.
func Wrap(h HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := h(w, r); err != nil {
			WriteError(w, r, err)
		}
	}
}

// WriteError renders any error. Non-API errors become 500 and are logged.
func WriteError(w http.ResponseWriter, r *http.Request, err error) {
	var e *Error
	if !errors.As(err, &e) {
		Logger.Error("request failed", "method", r.Method, "path", r.URL.Path, "err", err)
		e = E(http.StatusInternalServerError, "internal", "服务器开小差了，请稍后再试")
	}
	body := map[string]any{"code": e.Code, "message": e.Message}
	for k, v := range e.Extra {
		body[k] = v
	}
	JSON(w, e.Status, map[string]any{"error": body})
}

// JSON writes v.
func JSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// OK writes v with 200.
func OK(w http.ResponseWriter, v any) error {
	JSON(w, http.StatusOK, v)
	return nil
}

// Empty is the {} response.
var Empty = struct{}{}

// Decode reads a JSON body (max 8 MB) into v, rejecting unknown fields.
func Decode(r *http.Request, v any) error {
	return DecodeLimit(r, v, 8<<20)
}

// DecodeLimit is Decode with a custom size limit.
func DecodeLimit(r *http.Request, v any, limit int64) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, limit))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		if errors.Is(err, io.EOF) {
			return BadRequest("invalid_body", "请求体为空")
		}
		return BadRequest("invalid_body", "请求格式错误："+err.Error())
	}
	return nil
}

// Page is ?page=&page_size=.
type Page struct{ Page, Size int }

// Offset returns the SQL offset.
func (p Page) Offset() int { return (p.Page - 1) * p.Size }

// GetPage parses pagination with defaults (1, 20) and a max size of 100.
func GetPage(r *http.Request) Page {
	p := Page{Page: atoiDefault(r.URL.Query().Get("page"), 1), Size: atoiDefault(r.URL.Query().Get("page_size"), 20)}
	if p.Page < 1 {
		p.Page = 1
	}
	if p.Size < 1 {
		p.Size = 20
	}
	if p.Size > 100 {
		p.Size = 100
	}
	return p
}

// List is the paginated envelope.
type List[T any] struct {
	Items []T `json:"items"`
	Total int `json:"total"`
}

// NewList never returns null items.
func NewList[T any](items []T, total int) List[T] {
	if items == nil {
		items = []T{}
	}
	return List[T]{Items: items, Total: total}
}

// Items is {"items": [...]} without a total.
type Items[T any] struct {
	Items []T `json:"items"`
}

// NewItems never returns null items.
func NewItems[T any](items []T) Items[T] {
	if items == nil {
		items = []T{}
	}
	return Items[T]{Items: items}
}

func atoiDefault(s string, def int) int {
	if n, err := strconv.Atoi(s); err == nil {
		return n
	}
	return def
}

// PathID parses a numeric path value.
func PathID(r *http.Request, name string) (int64, error) {
	id, err := strconv.ParseInt(r.PathValue(name), 10, 64)
	if err != nil || id <= 0 {
		return 0, NotFound("记录")
	}
	return id, nil
}

type ctxKey int

const (
	userKey ctxKey = iota
	adminKey
)

// WithUser stores the authenticated app user id.
func WithUser(ctx context.Context, id int64) context.Context {
	return context.WithValue(ctx, userKey, id)
}

// UserID returns the authenticated app user id (0 if none).
func UserID(ctx context.Context) int64 {
	id, _ := ctx.Value(userKey).(int64)
	return id
}

// Admin is the authenticated back-office user.
type Admin struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
	Role     string `json:"role"`
	// MerchantID is set for merchant staff (role merchant): they may only
	// see and act on their own merchant's data.
	MerchantID *int64 `json:"merchant_id,omitempty"`
}

// WithAdmin stores the admin principal.
func WithAdmin(ctx context.Context, a Admin) context.Context {
	return context.WithValue(ctx, adminKey, a)
}

// AdminFrom returns the admin principal.
func AdminFrom(ctx context.Context) (Admin, bool) {
	a, ok := ctx.Value(adminKey).(Admin)
	return a, ok
}

// ClientIP returns the caller IP, trusting the first X-Forwarded-For hop
// (set by the API gateway).
func ClientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		for i := 0; i < len(xff); i++ {
			if xff[i] == ',' {
				return xff[:i]
			}
		}
		return xff
	}
	host := r.RemoteAddr
	for i := len(host) - 1; i >= 0; i-- {
		if host[i] == ':' {
			return host[:i]
		}
	}
	return host
}
