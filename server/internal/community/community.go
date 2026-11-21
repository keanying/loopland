// Package community is V2 batch 2 「社区」 part B (docs/api/v2-2-社区.md):
// private messages and group chats, meetups (组局), crew rallies (集结跑) with
// their settlement bonus, races (赛事) with online completion during
// settlement, the inbox summary and the community home.
package community

import (
	"context"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/keanying/loopland/server/internal/billing"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/realtime"
	"github.com/keanying/loopland/server/internal/shop"
)

// Service implements the community endpoints, the settlement step
// (activity.Community) and the background jobs.
type Service struct {
	Pool   *pgxpool.Pool
	Redis  *redis.Client
	Config *gameplay.Store
	Hub    *realtime.Hub
	Mod    *moderation.Moderator
	Log    *slog.Logger
	// Billing takes race fees (docs/api/v2-4-本地生活与商户.md D-12); nil:
	// paid races cannot be signed up for.
	Billing *billing.Service
	// MeetupCancelled runs after a meetup is cancelled (e.g. to cancel and
	// refund the court booked with it). Optional.
	MeetupCancelled func(ctx context.Context, meetupID int64)
}

// CrewRef is a compact crew.
type CrewRef struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// UserBrief is the shared user object (docs/api/v2-2-社区.md «通用对象»).
type UserBrief struct {
	ID        int64    `json:"id"`
	Nickname  string   `json:"nickname"`
	AvatarURL *string  `json:"avatar_url"`
	Crew      *CrewRef `json:"crew"`
	// AvatarFrame is the equipped avatar frame key (能量商城), null if none.
	AvatarFrame *string `json:"avatar_frame"`
}

// Place is a named point.
type Place struct {
	Name string  `json:"name"`
	Lat  float64 `json:"lat"`
	Lng  float64 `json:"lng"`
}

func (p Place) valid() bool {
	return p.Lat >= -90 && p.Lat <= 90 && p.Lng >= -180 && p.Lng <= 180 && !(p.Lat == 0 && p.Lng == 0)
}

var (
	errBlocked   = httpx.Forbidden("blocked", "你们之间存在拉黑关系")
	errMuted     = httpx.Forbidden("muted", "你已被禁言，暂时不能发言")
	errNotMember = httpx.Forbidden("not_member", "你不在这个会话里")
	errNotInCrew = httpx.Forbidden("not_in_crew", "你不在这个跑团里")
)

// briefs loads UserBriefs by id.
func briefs(ctx context.Context, q db.Querier, ids []int64) (map[int64]UserBrief, error) {
	out := map[int64]UserBrief{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := q.Query(ctx, `SELECT u.id, CASE WHEN u.status='deleted' THEN '已注销用户' ELSE u.nickname END,
			CASE WHEN u.status='deleted' THEN NULL ELSE u.avatar_url END, c.id, c.name,
			CASE WHEN u.status='deleted' THEN NULL ELSE `+shop.FrameSQL("u.id")+` END
		FROM src.src_usr_loop_user u
		LEFT JOIN src.src_soc_loop_crew_member m ON m.user_id=u.id LEFT JOIN src.src_soc_loop_crew c ON c.id=m.crew_id
		WHERE u.id = ANY($1)`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var b UserBrief
		var cid *int64
		var cname *string
		if err := rows.Scan(&b.ID, &b.Nickname, &b.AvatarURL, &cid, &cname, &b.AvatarFrame); err != nil {
			return nil, err
		}
		if cid != nil {
			b.Crew = &CrewRef{ID: *cid, Name: *cname}
		}
		out[b.ID] = b
	}
	return out, rows.Err()
}

func brief(ctx context.Context, q db.Querier, id int64) (UserBrief, error) {
	m, err := briefs(ctx, q, []int64{id})
	if err != nil {
		return UserBrief{}, err
	}
	b, ok := m[id]
	if !ok {
		return b, httpx.NotFound("用户")
	}
	return b, nil
}

// blockedEither reports a block in either direction (src.src_soc_loop_block).
func blockedEither(ctx context.Context, q db.Querier, a, b int64) (bool, error) {
	var x bool
	err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_soc_loop_block
		WHERE (user_id=$1 AND blocked_user_id=$2) OR (user_id=$2 AND blocked_user_id=$1))`, a, b).Scan(&x)
	return x, err
}

func muted(ctx context.Context, q db.Querier, user int64) (bool, error) {
	var m bool
	err := q.QueryRow(ctx, `SELECT COALESCE(mute_end_time > now(), false) FROM src.src_usr_loop_user WHERE id=$1`, user).Scan(&m)
	return m, err
}

// cursor is the opaque cursor of the infinite lists: an offset.
type cursor struct{ offset, limit int }

func getCursor(r *http.Request, def int) cursor {
	c := cursor{limit: def}
	if n, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && n > 0 {
		c.limit = min(n, 50)
	}
	if n, err := strconv.Atoi(r.URL.Query().Get("cursor")); err == nil && n > 0 {
		c.offset = n
	}
	return c
}

// CursorList is {"items":[...],"next_cursor":...}.
type CursorList[T any] struct {
	Items      []T     `json:"items"`
	NextCursor *string `json:"next_cursor"`
}

// page trims one extra fetched row into the next cursor.
func page[T any](items []T, c cursor) CursorList[T] {
	out := CursorList[T]{Items: items}
	if len(items) > c.limit {
		out.Items = items[:c.limit]
		next := strconv.Itoa(c.offset + c.limit)
		out.NextCursor = &next
	}
	if out.Items == nil {
		out.Items = []T{}
	}
	return out
}

func (s *Service) publish(ctx context.Context, evs []realtime.Event) {
	if len(evs) > 0 {
		s.Hub.Publish(ctx, evs...)
	}
}

// tx runs fn in a transaction and publishes the collected events after commit.
func (s *Service) tx(ctx context.Context, fn func(tx pgx.Tx, evs *[]realtime.Event) error) error {
	var evs []realtime.Event
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		evs = nil
		return fn(tx, &evs)
	})
	if err == nil {
		s.publish(ctx, evs)
	}
	return err
}

func weekStart() time.Time {
	d := clock.Today()
	return d.AddDate(0, 0, -((int(d.Weekday()) + 6) % 7))
}

// Jobs returns the periodic jobs for the job runner: meetups past their end
// time and rallies 3 hours after their start are marked ended.
func (s *Service) Jobs() map[string]func(context.Context) error {
	return map[string]func(context.Context) error{
		"community_end":   s.EndPast,
		"race_fee_expire": s.ExpireRaceFees,
	}
}

// EndPast persists the ended status (reads compute it on the fly too).
func (s *Service) EndPast(ctx context.Context) error {
	if _, err := s.Pool.Exec(ctx, `UPDATE src.src_soc_loop_meetup SET meetup_status='ended', update_time=now()
		WHERE meetup_status='open' AND end_time <= now()`); err != nil {
		return err
	}
	_, err := s.Pool.Exec(ctx, `UPDATE src.src_soc_loop_rally SET rally_status='ended', update_time=now()
		WHERE rally_status='open' AND start_time + make_interval(secs => $1) <= now()`, rallyWindow.Seconds())
	return err
}
