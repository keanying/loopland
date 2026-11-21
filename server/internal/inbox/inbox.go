// Package inbox stores in-app notifications (消息). Push delivery through
// 个推/极光 is V2; when it lands it hooks in here and must respect the
// no-push-late-at-night rule.
package inbox

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Categories.
const (
	Interaction = "interaction"
	Territory   = "territory"
	Monster     = "monster"
	System      = "system"
)

// Notify inserts a notification inside the caller's transaction.
func Notify(ctx context.Context, q db.Querier, userID int64, category, title, body string, data map[string]any) error {
	if data == nil {
		data = map[string]any{}
	}
	raw, _ := json.Marshal(data)
	_, err := q.Exec(ctx, `INSERT INTO src.src_msg_notification (user_id, category, title, body, data_json) VALUES ($1,$2,$3,$4,$5)`,
		userID, category, title, body, raw)
	return err
}

// Item is one notification.
type Item struct {
	ID        int64          `json:"id"`
	Category  string         `json:"category"`
	Title     string         `json:"title"`
	Body      string         `json:"body"`
	Data      map[string]any `json:"data"`
	Read      bool           `json:"read"`
	CreatedAt time.Time      `json:"created_at"`
}

// Handler serves /v1/inbox.
type Handler struct{ Pool *pgxpool.Pool }

// Routes registers the endpoints; auth is applied by the caller.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /v1/inbox", auth(h.list))
	mux.Handle("POST /v1/inbox/read", auth(h.read))
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) error {
	uid := httpx.UserID(r.Context())
	p := httpx.GetPage(r)
	cat := r.URL.Query().Get("category")
	if cat == "all" {
		cat = ""
	}
	rows, err := h.Pool.Query(r.Context(), `SELECT id, category, title, body, data_json, read_time IS NOT NULL, create_time
		FROM src.src_msg_notification WHERE user_id=$1 AND ($2='' OR category=$2) ORDER BY id DESC LIMIT $3 OFFSET $4`,
		uid, cat, p.Size, p.Offset())
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Item, error) {
		var it Item
		var data []byte
		err := row.Scan(&it.ID, &it.Category, &it.Title, &it.Body, &data, &it.Read, &it.CreatedAt)
		_ = json.Unmarshal(data, &it.Data)
		return it, err
	})
	if err != nil {
		return err
	}
	var total, unread int
	if err := h.Pool.QueryRow(r.Context(), `SELECT count(*) FILTER (WHERE $2='' OR category=$2), count(*) FILTER (WHERE read_time IS NULL)
		FROM src.src_msg_notification WHERE user_id=$1`, uid, cat).Scan(&total, &unread); err != nil {
		return err
	}
	if items == nil {
		items = []Item{}
	}
	return httpx.OK(w, map[string]any{"items": items, "total": total, "unread": unread})
}

func (h *Handler) read(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		IDs []int64 `json:"ids"`
		All bool    `json:"all"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	uid := httpx.UserID(r.Context())
	if req.All {
		_, err := h.Pool.Exec(r.Context(), `UPDATE src.src_msg_notification SET read_time=now() WHERE user_id=$1 AND read_time IS NULL`, uid)
		if err != nil {
			return err
		}
	} else if len(req.IDs) > 0 {
		_, err := h.Pool.Exec(r.Context(), `UPDATE src.src_msg_notification SET read_time=now() WHERE user_id=$1 AND id=ANY($2) AND read_time IS NULL`, uid, req.IDs)
		if err != nil {
			return err
		}
	}
	var unread int
	if err := h.Pool.QueryRow(r.Context(), `SELECT count(*) FROM src.src_msg_notification WHERE user_id=$1 AND read_time IS NULL`, uid).Scan(&unread); err != nil {
		return err
	}
	return httpx.OK(w, map[string]int{"unread": unread})
}
