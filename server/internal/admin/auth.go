// Package admin is the back-office API (/admin/v1) used by 运营, 审核, 风控
// and 策划. Every write is recorded in the audit log.
package admin

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/golang-jwt/jwt/v5"
	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"

	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Roles.
const (
	RoleAdmin    = "admin"
	RoleOps      = "ops"
	RoleReviewer = "reviewer"
	RoleMerchant = "merchant"
)

var roles = []string{RoleAdmin, RoleOps, RoleReviewer, RoleMerchant}

const tokenTTL = 12 * time.Hour

func (a *API) token(ad httpx.Admin) (string, error) {
	return jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": strconv.FormatInt(ad.ID, 10), "aud": "admin", "exp": time.Now().Add(tokenTTL).Unix(), "iat": time.Now().Unix(),
	}).SignedString(a.Secret)
}

// guard authenticates and checks the role.
func (a *API) guard(allowed ...string) func(httpx.HandlerFunc) http.Handler {
	return func(h httpx.HandlerFunc) http.Handler {
		return httpx.Wrap(func(w http.ResponseWriter, r *http.Request) error {
			tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok {
				return httpx.ErrUnauthorized
			}
			var c jwt.RegisteredClaims
			if _, err := jwt.ParseWithClaims(tok, &c, func(*jwt.Token) (any, error) { return a.Secret, nil },
				jwt.WithValidMethods([]string{"HS256"}), jwt.WithAudience("admin"), jwt.WithExpirationRequired()); err != nil {
				return httpx.ErrUnauthorized
			}
			id, _ := strconv.ParseInt(c.Subject, 10, 64)
			var ad httpx.Admin
			var disabled bool
			err := a.Pool.QueryRow(r.Context(), `SELECT id, username, role, is_disabled FROM src.src_sys_loop_admin WHERE id=$1`, id).Scan(&ad.ID, &ad.Username, &ad.Role, &disabled)
			if db.IsNoRows(err) || disabled {
				return httpx.ErrUnauthorized
			}
			if err != nil {
				return err
			}
			if len(allowed) > 0 && !slices.Contains(allowed, ad.Role) {
				return httpx.ErrForbidden
			}
			return h(w, r.WithContext(httpx.WithAdmin(r.Context(), ad)))
		})
	}
}

// Guard exposes the role guard to other modules' admin routes.
func (a *API) Guard(allowed ...string) func(httpx.HandlerFunc) http.Handler {
	return a.guard(allowed...)
}

// Audit exposes the audit logger to other modules.
func Audit(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error {
	return audit(ctx, q, action, target, detail)
}

// audit records an admin action.
func audit(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error {
	ad, _ := httpx.AdminFrom(ctx)
	if detail == nil {
		detail = map[string]any{}
	}
	raw, _ := json.Marshal(detail)
	_, err := q.Exec(ctx, `INSERT INTO src.src_sys_loop_audit_log (admin_id, action, target, detail_json) VALUES ($1,$2,$3,$4)`, ad.ID, action, target, raw)
	return err
}

// Bootstrap creates the first admin when none exists.
func Bootstrap(ctx context.Context, q db.Querier, spec string) error {
	user, pass, ok := strings.Cut(spec, ":")
	if !ok || user == "" || len(pass) < 8 {
		return nil
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(pass), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	_, err = q.Exec(ctx, `INSERT INTO src.src_sys_loop_admin (username, password_hash, role) SELECT $1,$2,'admin'
		WHERE NOT EXISTS (SELECT 1 FROM src.src_sys_loop_admin)`, user, string(hash))
	return err
}

func (a *API) login(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	key := "admin:login:" + httpx.ClientIP(r)
	if n, _ := a.Redis.Incr(r.Context(), key).Result(); n == 1 {
		a.Redis.Expire(r.Context(), key, 15*time.Minute)
	} else if n > 20 {
		return httpx.ErrRateLimited
	}
	var ad httpx.Admin
	var hash string
	var disabled bool
	err := a.Pool.QueryRow(r.Context(), `SELECT id, username, role, password_hash, is_disabled FROM src.src_sys_loop_admin WHERE username=$1`, req.Username).
		Scan(&ad.ID, &ad.Username, &ad.Role, &hash, &disabled)
	if err != nil && !db.IsNoRows(err) {
		return err
	}
	if err != nil || disabled || bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)) != nil {
		return httpx.E(http.StatusUnauthorized, "invalid_credentials", "用户名或密码错误")
	}
	tok, err := a.token(ad)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"token": tok, "admin": ad})
}

func (a *API) me(w http.ResponseWriter, r *http.Request) error {
	ad, _ := httpx.AdminFrom(r.Context())
	return httpx.OK(w, ad)
}

type adminRow struct {
	ID        int64     `json:"id"`
	Username  string    `json:"username"`
	Role      string    `json:"role"`
	Disabled  bool      `json:"disabled"`
	CreatedAt time.Time `json:"created_at"`
}

func (a *API) listAdmins(w http.ResponseWriter, r *http.Request) error {
	rows, err := a.Pool.Query(r.Context(), `SELECT id, username, role, is_disabled, create_time FROM src.src_sys_loop_admin ORDER BY id`)
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, pgx.RowToStructByPos[adminRow])
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func validPassword(p string) error {
	if utf8.RuneCountInString(p) < 10 {
		return httpx.BadRequest("weak_password", "密码至少 10 位")
	}
	return nil
}

func (a *API) createAdmin(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
		Role     string `json:"role"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if !slices.Contains(roles, req.Role) || strings.TrimSpace(req.Username) == "" {
		return httpx.BadRequest("invalid_body", "用户名或角色错误")
	}
	if err := validPassword(req.Password); err != nil {
		return err
	}
	hash, _ := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	var row adminRow
	err := pgx.BeginFunc(r.Context(), a.Pool, func(tx pgx.Tx) error {
		err := tx.QueryRow(r.Context(), `INSERT INTO src.src_sys_loop_admin (username, password_hash, role) VALUES ($1,$2,$3)
			RETURNING id, username, role, is_disabled, create_time`, req.Username, string(hash), req.Role).
			Scan(&row.ID, &row.Username, &row.Role, &row.Disabled, &row.CreatedAt)
		if db.IsUniqueViolation(err) {
			return httpx.Conflict("username_taken", "用户名已存在")
		}
		if err != nil {
			return err
		}
		return audit(r.Context(), tx, "admin.create", "admin:"+strconv.FormatInt(row.ID, 10), map[string]any{"username": req.Username, "role": req.Role})
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, row)
}

func (a *API) patchAdmin(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Role     *string `json:"role"`
		Disabled *bool   `json:"disabled"`
		Password *string `json:"password"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	me, _ := httpx.AdminFrom(r.Context())
	if id == me.ID && ((req.Disabled != nil && *req.Disabled) || (req.Role != nil && *req.Role != RoleAdmin)) {
		return httpx.BadRequest("invalid_body", "不能停用自己或降低自己的权限")
	}
	var row adminRow
	err = pgx.BeginFunc(r.Context(), a.Pool, func(tx pgx.Tx) error {
		if req.Role != nil {
			if !slices.Contains(roles, *req.Role) {
				return httpx.BadRequest("invalid_body", "角色错误")
			}
			if _, err := tx.Exec(r.Context(), `UPDATE src.src_sys_loop_admin SET role=$2 WHERE id=$1`, id, *req.Role); err != nil {
				return err
			}
		}
		if req.Disabled != nil {
			if _, err := tx.Exec(r.Context(), `UPDATE src.src_sys_loop_admin SET is_disabled=$2 WHERE id=$1`, id, *req.Disabled); err != nil {
				return err
			}
		}
		if req.Password != nil {
			if err := validPassword(*req.Password); err != nil {
				return err
			}
			hash, _ := bcrypt.GenerateFromPassword([]byte(*req.Password), bcrypt.DefaultCost)
			if _, err := tx.Exec(r.Context(), `UPDATE src.src_sys_loop_admin SET password_hash=$2 WHERE id=$1`, id, string(hash)); err != nil {
				return err
			}
		}
		err := tx.QueryRow(r.Context(), `SELECT id, username, role, is_disabled, create_time FROM src.src_sys_loop_admin WHERE id=$1`, id).
			Scan(&row.ID, &row.Username, &row.Role, &row.Disabled, &row.CreatedAt)
		if db.IsNoRows(err) {
			return httpx.NotFound("后台账号")
		}
		if err != nil {
			return err
		}
		return audit(r.Context(), tx, "admin.update", "admin:"+strconv.FormatInt(id, 10),
			map[string]any{"role": req.Role, "disabled": req.Disabled, "password_changed": req.Password != nil})
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, row)
}

type auditRow struct {
	ID    int64 `json:"id"`
	Admin struct {
		ID       int64  `json:"id"`
		Username string `json:"username"`
	} `json:"admin"`
	Action    string         `json:"action"`
	Target    string         `json:"target"`
	Detail    map[string]any `json:"detail"`
	CreatedAt time.Time      `json:"created_at"`
}

func (a *API) auditLog(w http.ResponseWriter, r *http.Request) error {
	p := httpx.GetPage(r)
	adminID, _ := strconv.ParseInt(r.URL.Query().Get("admin_id"), 10, 64)
	var total int
	if err := a.Pool.QueryRow(r.Context(), `SELECT count(*) FROM src.src_sys_loop_audit_log WHERE ($1=0 OR admin_id=$1)`, adminID).Scan(&total); err != nil {
		return err
	}
	rows, err := a.Pool.Query(r.Context(), `SELECT l.id, a.id, a.username, l.action, l.target, l.detail_json, l.create_time
		FROM src.src_sys_loop_audit_log l JOIN src.src_sys_loop_admin a ON a.id=l.admin_id WHERE ($1=0 OR l.admin_id=$1) ORDER BY l.id DESC LIMIT $2 OFFSET $3`,
		adminID, p.Size, p.Offset())
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (auditRow, error) {
		var x auditRow
		var raw []byte
		err := row.Scan(&x.ID, &x.Admin.ID, &x.Admin.Username, &x.Action, &x.Target, &raw, &x.CreatedAt)
		_ = json.Unmarshal(raw, &x.Detail)
		return x, err
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}
