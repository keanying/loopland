package adminmsg

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Message is AdminMessage.
type Message struct {
	ID        int64      `json:"id"`
	Category  string     `json:"category"`
	Title     string     `json:"title"`
	Body      string     `json:"body"`
	Link      *string    `json:"link"`
	Level     string     `json:"level"`
	IsRead    bool       `json:"is_read"`
	ReadAt    *time.Time `json:"read_at"`
	CreatedAt time.Time  `json:"created_at"`
}

const cols = `id, category_type, title, body_text, link_url, level_type, is_read, read_time, create_time`

func scan(r pgx.Row) (Message, error) {
	var m Message
	err := r.Scan(&m.ID, &m.Category, &m.Title, &m.Body, &m.Link, &m.Level, &m.IsRead, &m.ReadAt, &m.CreatedAt)
	return m, err
}

// Yuan formats an amount in fen: ¥49, ¥1,801.35.
func Yuan(amt int64) string {
	neg := amt < 0
	if neg {
		amt = -amt
	}
	whole := strconv.FormatInt(amt/100, 10)
	var b strings.Builder
	for i, c := range whole {
		if i > 0 && (len(whole)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	s := "¥" + b.String()
	if amt%100 != 0 {
		s += fmt.Sprintf(".%02d", amt%100)
	}
	if neg {
		s = "-" + s
	}
	return s
}

// Handler serves /admin/v1/messages (every back-office account, own messages only).
type Handler struct {
	Notifier *Notifier
}

// Routes registers the endpoints; any is the guard for all admin roles.
func (h *Handler) Routes(mux *http.ServeMux, any func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /admin/v1/messages", any(h.list))
	mux.Handle("GET /admin/v1/messages/unread-count", any(h.unreadCount))
	mux.Handle("POST /admin/v1/messages/read-all", any(h.readAll))
	mux.Handle("POST /admin/v1/messages/{id}/read", any(h.read))
}

func me(r *http.Request) int64 {
	ad, _ := httpx.AdminFrom(r.Context())
	return ad.ID
}

func category(v string) (string, error) {
	if v != "" && !Categories[v] {
		return "", httpx.BadRequest("invalid_body", "category 取值错误")
	}
	return v, nil
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) error {
	ctx, pool := r.Context(), h.Notifier.Pool
	cat, err := category(r.URL.Query().Get("category"))
	if err != nil {
		return err
	}
	unread := r.URL.Query().Get("unread") == "true" || r.URL.Query().Get("unread") == "1"
	p := httpx.GetPage(r)
	where := `admin_id=$1 AND ($2 = '' OR category_type=$2) AND (NOT $3 OR NOT is_read)`
	var total, unreadQty int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM src.src_msg_loop_admin_message WHERE admin_id=$1 AND NOT is_read`, me(r)).Scan(&unreadQty); err != nil {
		return err
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM src.src_msg_loop_admin_message WHERE `+where, me(r), cat, unread).Scan(&total); err != nil {
		return err
	}
	rows, err := pool.Query(ctx, `SELECT `+cols+` FROM src.src_msg_loop_admin_message WHERE `+where+` ORDER BY create_time DESC, id DESC LIMIT $4 OFFSET $5`,
		me(r), cat, unread, p.Size, p.Offset())
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Message, error) { return scan(r) })
	if err != nil {
		return err
	}
	if items == nil {
		items = []Message{}
	}
	return httpx.OK(w, map[string]any{"items": items, "total": total, "unread_count": unreadQty})
}

func (h *Handler) unreadCount(w http.ResponseWriter, r *http.Request) error {
	rows, err := h.Notifier.Pool.Query(r.Context(), `SELECT category_type, count(*)::int FROM src.src_msg_loop_admin_message
		WHERE admin_id=$1 AND NOT is_read GROUP BY category_type`, me(r))
	if err != nil {
		return err
	}
	by := map[string]int{}
	n := 0
	for rows.Next() {
		var c string
		var k int
		if err := rows.Scan(&c, &k); err != nil {
			rows.Close()
			return err
		}
		by[c] = k
		n += k
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"count": n, "by_category": by})
}

func (h *Handler) read(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	m, err := scan(h.Notifier.Pool.QueryRow(r.Context(), `UPDATE src.src_msg_loop_admin_message SET is_read=true, read_time=COALESCE(read_time, now())
		WHERE id=$1 AND admin_id=$2 RETURNING `+cols, id, me(r)))
	if db.IsNoRows(err) {
		return httpx.NotFound("消息")
	}
	if err != nil {
		return err
	}
	return httpx.OK(w, m)
}

func (h *Handler) readAll(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Category string `json:"category"`
	}
	if r.ContentLength != 0 {
		if err := httpx.Decode(r, &req); err != nil {
			return err
		}
	}
	cat, err := category(req.Category)
	if err != nil {
		return err
	}
	tag, err := h.Notifier.Pool.Exec(r.Context(), `UPDATE src.src_msg_loop_admin_message SET is_read=true, read_time=now()
		WHERE admin_id=$1 AND NOT is_read AND ($2 = '' OR category_type=$2)`, me(r), cat)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"updated": tag.RowsAffected()})
}

// Cleanup deletes messages older than 180 days, once a day.
func (n *Notifier) Cleanup(ctx context.Context) error {
	tag, err := n.Pool.Exec(ctx, `INSERT INTO src.src_sys_loop_setting (setting_key, setting_value) VALUES ('admin_message_cleanup_day', to_jsonb($1::text))
		ON CONFLICT (setting_key) DO UPDATE SET setting_value=EXCLUDED.setting_value, update_time=now() WHERE src_sys_loop_setting.setting_value <> to_jsonb($1::text)`,
		clock.Today().Format(time.DateOnly))
	if err != nil || tag.RowsAffected() == 0 {
		return err
	}
	_, err = n.Pool.Exec(ctx, `DELETE FROM src.src_msg_loop_admin_message WHERE create_time < $1`, time.Now().Add(-Retention))
	return err
}

// Jobs are the periodic jobs of the inbox.
func (n *Notifier) Jobs() map[string]func(context.Context) error {
	return map[string]func(context.Context) error{"admin_message_cleanup": n.Cleanup}
}
