// Package social is the community content of V2 batch 2 (docs/api/v2-2-社区.md):
// profiles, follows and blocks, posts and the feed, comments, likes,
// collections, shares, reports, track replays, and the admin review and
// report endpoints. Chat, meetups, rallies and races live in package
// community.
package social

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Service holds the dependencies shared by the handlers.
type Service struct {
	Pool   *pgxpool.Pool
	Redis  *redis.Client
	Config *gameplay.Store
	Mod    *moderation.Moderator
	// ShareBase is the public base URL for share links (http.public_base_url).
	ShareBase string
}

// Handler serves the app endpoints.
type Handler struct{ Svc *Service }

// Routes registers the app endpoints.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /v1/users/{id}", auth(h.profile))
	mux.Handle("GET /v1/users/{id}/posts", auth(h.userPosts))
	mux.Handle("POST /v1/users/{id}/follow", auth(h.follow))
	mux.Handle("DELETE /v1/users/{id}/follow", auth(h.unfollow))
	mux.Handle("GET /v1/users/{id}/followers", auth(h.followers))
	mux.Handle("GET /v1/users/{id}/following", auth(h.following))
	mux.Handle("POST /v1/users/{id}/block", auth(h.block))
	mux.Handle("DELETE /v1/users/{id}/block", auth(h.unblock))
	mux.Handle("GET /v1/me/blocks", auth(h.blocks))

	mux.Handle("POST /v1/posts", auth(h.createPost))
	mux.Handle("GET /v1/posts/{id}", auth(h.getPost))
	mux.Handle("DELETE /v1/posts/{id}", auth(h.deletePost))
	mux.Handle("GET /v1/feed", auth(h.feed))
	mux.Handle("POST /v1/posts/{id}/like", auth(h.likePost))
	mux.Handle("DELETE /v1/posts/{id}/like", auth(h.unlikePost))
	mux.Handle("POST /v1/posts/{id}/collect", auth(h.collect))
	mux.Handle("DELETE /v1/posts/{id}/collect", auth(h.uncollect))
	mux.Handle("GET /v1/me/collections", auth(h.collections))
	mux.Handle("POST /v1/posts/{id}/share", auth(h.share))

	mux.Handle("GET /v1/posts/{id}/comments", auth(h.comments))
	mux.Handle("POST /v1/posts/{id}/comments", auth(h.createComment))
	mux.Handle("GET /v1/comments/{id}/replies", auth(h.replies))
	mux.Handle("DELETE /v1/comments/{id}", auth(h.deleteComment))
	mux.Handle("POST /v1/comments/{id}/like", auth(h.likeComment))
	mux.Handle("DELETE /v1/comments/{id}/like", auth(h.unlikeComment))

	mux.Handle("POST /v1/reports", auth(h.report))

	mux.Handle("GET /v1/replays", auth(h.replays))
	mux.Handle("GET /v1/activities/{id}/replay", auth(h.activityReplay))
}

// ---------------------------------------------------------------- users

// CrewRef is a compact crew.
type CrewRef struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// UserBrief is how a user appears everywhere in the community.
type UserBrief struct {
	ID        int64    `json:"id"`
	Nickname  string   `json:"nickname"`
	AvatarURL *string  `json:"avatar_url"`
	Crew      *CrewRef `json:"crew"`
}

// DeletedNickname is shown for deleted accounts.
const DeletedNickname = "已注销用户"

// Briefs loads users by id; unknown or deleted ids get the deleted look.
func Briefs(ctx context.Context, q db.Querier, ids []int64) (map[int64]UserBrief, error) {
	out := make(map[int64]UserBrief, len(ids))
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := q.Query(ctx, `SELECT u.id, u.nickname, u.avatar_url, u.status, c.id, c.name
		FROM src.src_usr_loop_user u
		LEFT JOIN src.src_soc_loop_crew_member m ON m.user_id=u.id
		LEFT JOIN src.src_soc_loop_crew c ON c.id=m.crew_id
		WHERE u.id = ANY($1)`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var b UserBrief
		var status string
		var cid *int64
		var cname *string
		if err := rows.Scan(&b.ID, &b.Nickname, &b.AvatarURL, &status, &cid, &cname); err != nil {
			return nil, err
		}
		if status == "deleted" {
			b = UserBrief{ID: b.ID, Nickname: DeletedNickname}
		} else if cid != nil {
			b.Crew = &CrewRef{ID: *cid, Name: *cname}
		}
		out[b.ID] = b
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, id := range ids {
		if _, ok := out[id]; !ok {
			out[id] = UserBrief{ID: id, Nickname: DeletedNickname}
		}
	}
	return out, nil
}

func brief(ctx context.Context, q db.Querier, id int64) (UserBrief, error) {
	m, err := Briefs(ctx, q, []int64{id})
	return m[id], err
}

// blockedEither reports whether a and b are in a block relation.
func blockedEither(ctx context.Context, q db.Querier, a, b int64) (bool, error) {
	var x bool
	err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_soc_loop_block WHERE (user_id=$1 AND blocked_user_id=$2) OR (user_id=$2 AND blocked_user_id=$1))`, a, b).Scan(&x)
	return x, err
}

// ErrBlocked is returned when a block relation forbids the action.
var ErrBlocked = httpx.Forbidden("blocked", "你们之间存在拉黑关系，无法操作")

// ErrMuted is returned to muted users.
var ErrMuted = httpx.Forbidden("muted", "你已被禁言，暂时不能发布内容")

// author loads the facts the publishing checks need, locking the user row
// so that per-day limits are counted without races.
// authorState is author without the lock.
func authorState(ctx context.Context, q db.Querier, uid int64) (muted, newUser bool, err error) {
	err = q.QueryRow(ctx, `SELECT COALESCE(mute_end_time > now(), false), create_time > now() - interval '24 hours'
		FROM src.src_usr_loop_user WHERE id=$1`, uid).Scan(&muted, &newUser)
	return
}

func author(ctx context.Context, tx pgx.Tx, uid int64) (muted, newUser bool, err error) {
	err = tx.QueryRow(ctx, `SELECT COALESCE(mute_end_time > now(), false), create_time > now() - interval '24 hours'
		FROM src.src_usr_loop_user WHERE id=$1 FOR UPDATE`, uid).Scan(&muted, &newUser)
	return
}

// rateLimit allows n events per window per key (Redis).
func (s *Service) rateLimit(ctx context.Context, key string, n int64, window time.Duration) error {
	k := "soc:rl:" + key
	c, err := s.Redis.Incr(ctx, k).Result()
	if err != nil {
		return err
	}
	if c == 1 {
		s.Redis.Expire(ctx, k, window)
	}
	if c > n {
		return httpx.ErrRateLimited
	}
	return nil
}

// once reports whether key was not seen within ttl (notification de-dup).
func (s *Service) once(ctx context.Context, key string, ttl time.Duration) bool {
	ok, err := s.Redis.SetNX(ctx, "soc:once:"+key, 1, ttl).Result()
	return err != nil || ok // when Redis is down, prefer sending
}

// ---------------------------------------------------------------- cursor pages

// Page is a cursor page.
type Page[T any] struct {
	Items      []T     `json:"items"`
	NextCursor *string `json:"next_cursor"`
}

func newPage[T any](items []T, next *cursor) Page[T] {
	if items == nil {
		items = []T{}
	}
	p := Page[T]{Items: items}
	if next != nil {
		s := next.encode()
		p.NextCursor = &s
	}
	return p
}

// cursor is the opaque position in a list: a keyset (time, id) or, for
// ranked lists, an offset into a ranking frozen at Snap.
type cursor struct {
	T    *time.Time `json:"t,omitempty"`
	ID   int64      `json:"i,omitempty"`
	Off  int        `json:"o,omitempty"`
	Snap int64      `json:"s,omitempty"`
}

func (c cursor) encode() string {
	b, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(b)
}

var errCursor = httpx.BadRequest("invalid_cursor", "cursor 无效，请从头加载")

func decodeCursor(s string) (cursor, error) {
	var c cursor
	if s == "" {
		return c, nil
	}
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || json.Unmarshal(b, &c) != nil || c.Off < 0 || c.ID < 0 {
		return cursor{}, errCursor
	}
	return c, nil
}

// pageArgs reads ?cursor=&limit= (limit 1–50, default 20).
func pageArgs(r *http.Request) (cursor, int, error) {
	c, err := decodeCursor(r.URL.Query().Get("cursor"))
	if err != nil {
		return c, 0, err
	}
	limit := 20
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return c, 0, httpx.BadRequest("invalid_body", "limit 取值错误")
		}
		limit = min(n, 50)
	}
	return c, limit, nil
}

// keysetNext returns the cursor after the last of n+1 fetched rows.
func keysetNext(more bool, t time.Time, id int64) *cursor {
	if !more {
		return nil
	}
	return &cursor{T: &t, ID: id}
}

// keyset returns SQL args for a (time, id) position; the zero cursor is
// "from the start" for descending lists.
func (c cursor) keysetDesc() (time.Time, int64) {
	if c.T == nil {
		return time.Date(9999, 1, 1, 0, 0, 0, 0, time.UTC), 0
	}
	return *c.T, c.ID
}

func (c cursor) keysetAsc() (time.Time, int64) {
	if c.T == nil {
		return time.Date(1970, 1, 1, 0, 0, 0, 0, time.UTC), 0
	}
	return *c.T, c.ID
}

func notFoundOr(err error, what string) error {
	if db.IsNoRows(err) {
		return httpx.NotFound(what)
	}
	return err
}

func pathID(r *http.Request) (int64, error) { return httpx.PathID(r, "id") }
