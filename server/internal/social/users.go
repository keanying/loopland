package social

import (
	"fmt"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Relation is how the viewer and a user relate.
type Relation struct {
	Following  bool `json:"following"`
	FollowedBy bool `json:"followed_by"`
	Blocked    bool `json:"blocked"`
	BlockedBy  bool `json:"blocked_by"`
}

// Profile is 他人主页 (also 我的 with the viewer's own id).
type Profile struct {
	User              UserBrief `json:"user"`
	Bio               string    `json:"bio"`
	FollowerCount     int       `json:"follower_count"`
	FollowingCount    int       `json:"following_count"`
	LikeReceivedCount int       `json:"like_received_count"`
	TotalDistanceM    float64   `json:"total_distance_m"`
	TerritoryCount    int       `json:"territory_count"`
	TerritoryAreaM2   float64   `json:"territory_area_m2"`
	CodexCount        int       `json:"codex_count"`
	Relation          Relation  `json:"relation"`
	IsSelf            bool      `json:"is_self"`
}

// existingUser checks that id is a live account.
func existingUser(r *http.Request, q db.Querier, id int64) error {
	var ok bool
	if err := q.QueryRow(r.Context(), `SELECT EXISTS (SELECT 1 FROM src.src_usr_loop_user WHERE id=$1 AND status <> 'deleted')`, id).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return httpx.NotFound("用户")
	}
	return nil
}

func (h *Handler) profile(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	pool := h.Svc.Pool
	if err := existingUser(r, pool, id); err != nil {
		return err
	}
	p := Profile{IsSelf: id == uid}
	if p.User, err = brief(ctx, pool, id); err != nil {
		return err
	}
	err = pool.QueryRow(ctx, `SELECT COALESCE(u.bio, ''),
			(SELECT count(*) FROM src.src_soc_loop_follow WHERE followee_id=u.id),
			(SELECT count(*) FROM src.src_soc_loop_follow WHERE follower_id=u.id),
			(SELECT COALESCE(sum(like_qty),0) FROM src.src_soc_loop_post WHERE user_id=u.id AND delete_time IS NULL)
			  + (SELECT COALESCE(sum(like_qty),0) FROM src.src_soc_loop_comment WHERE user_id=u.id AND delete_time IS NULL),
			(SELECT COALESCE(sum(distance_m),0) FROM src.src_act_loop_activity WHERE user_id=u.id AND status='settled'),
			(SELECT count(*) FROM src.src_ter_loop_territory WHERE owner_user_id=u.id),
			(SELECT COALESCE(sum(area_m2),0) FROM src.src_ter_loop_territory WHERE owner_user_id=u.id),
			(SELECT count(*) FROM src.src_ply_loop_codex_item WHERE user_id=u.id),
			EXISTS (SELECT 1 FROM src.src_soc_loop_follow WHERE follower_id=$2 AND followee_id=u.id),
			EXISTS (SELECT 1 FROM src.src_soc_loop_follow WHERE follower_id=u.id AND followee_id=$2),
			EXISTS (SELECT 1 FROM src.src_soc_loop_block WHERE user_id=$2 AND blocked_user_id=u.id),
			EXISTS (SELECT 1 FROM src.src_soc_loop_block WHERE user_id=u.id AND blocked_user_id=$2)
		FROM src.src_usr_loop_user u WHERE u.id=$1`, id, uid).
		Scan(&p.Bio, &p.FollowerCount, &p.FollowingCount, &p.LikeReceivedCount, &p.TotalDistanceM, &p.TerritoryCount, &p.TerritoryAreaM2,
			&p.CodexCount, &p.Relation.Following, &p.Relation.FollowedBy, &p.Relation.Blocked, &p.Relation.BlockedBy)
	if err != nil {
		return err
	}
	return httpx.OK(w, p)
}

func (h *Handler) follow(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	if id == uid {
		return httpx.BadRequest("invalid_target", "不能关注自己")
	}
	s := h.Svc
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if err := existingUser(r, tx, id); err != nil {
			return err
		}
		if b, err := blockedEither(ctx, tx, uid, id); err != nil {
			return err
		} else if b {
			return ErrBlocked
		}
		tag, err := tx.Exec(ctx, `INSERT INTO src.src_soc_loop_follow (follower_id, followee_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`, uid, id)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 || !s.once(ctx, fmt.Sprintf("follow:%d:%d", uid, id), 24*time.Hour) {
			return nil
		}
		me, err := brief(ctx, tx, uid)
		if err != nil {
			return err
		}
		return inbox.Notify(ctx, tx, id, inbox.Interaction, "新粉丝", me.Nickname+" 关注了你", map[string]any{"type": "follow", "user_id": uid})
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]bool{"following": true})
}

func (h *Handler) unfollow(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	if _, err := h.Svc.Pool.Exec(r.Context(), `DELETE FROM src.src_soc_loop_follow WHERE follower_id=$1 AND followee_id=$2`, httpx.UserID(r.Context()), id); err != nil {
		return err
	}
	return httpx.OK(w, map[string]bool{"following": false})
}

// FollowEntry is a row of the follower / following lists.
type FollowEntry struct {
	User       UserBrief `json:"user"`
	Following  bool      `json:"following"`
	FollowedAt time.Time `json:"followed_at"`

	uid int64
}

func (h *Handler) followers(w http.ResponseWriter, r *http.Request) error {
	return h.followList(w, r, "followee_id", "follower_id")
}

func (h *Handler) following(w http.ResponseWriter, r *http.Request) error {
	return h.followList(w, r, "follower_id", "followee_id")
}

// followList lists users in column other of rows where column self is the
// profile user, newest first.
func (h *Handler) followList(w http.ResponseWriter, r *http.Request, self, other string) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	c, limit, err := pageArgs(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	if err := existingUser(r, h.Svc.Pool, id); err != nil {
		return err
	}
	t, last := c.keysetDesc()
	rows, err := h.Svc.Pool.Query(ctx, `SELECT f.`+other+`, f.create_time,
			EXISTS (SELECT 1 FROM src.src_soc_loop_follow m WHERE m.follower_id=$1 AND m.followee_id=f.`+other+`)
		FROM src.src_soc_loop_follow f JOIN src.src_usr_loop_user u ON u.id=f.`+other+`
		WHERE f.`+self+`=$2 AND u.status <> 'deleted' AND (f.create_time, f.`+other+`) < ($3, $4)
		ORDER BY f.create_time DESC, f.`+other+` DESC LIMIT $5`, uid, id, t, last, limit+1)
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (FollowEntry, error) {
		var e FollowEntry
		return e, r.Scan(&e.uid, &e.FollowedAt, &e.Following)
	})
	if err != nil {
		return err
	}
	var next *cursor
	if len(items) > limit {
		items = items[:limit]
		next = keysetNext(true, items[limit-1].FollowedAt, items[limit-1].uid)
	}
	if err := fillBriefs(r, h.Svc.Pool, items, func(e *FollowEntry) (int64, *UserBrief) { return e.uid, &e.User }); err != nil {
		return err
	}
	return httpx.OK(w, newPage(items, next))
}

// fillBriefs loads UserBriefs into a slice.
func fillBriefs[T any](r *http.Request, q db.Querier, items []T, ref func(*T) (int64, *UserBrief)) error {
	ids := make([]int64, 0, len(items))
	for i := range items {
		id, _ := ref(&items[i])
		ids = append(ids, id)
	}
	m, err := Briefs(r.Context(), q, ids)
	if err != nil {
		return err
	}
	for i := range items {
		id, dst := ref(&items[i])
		*dst = m[id]
	}
	return nil
}

func (h *Handler) block(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	if id == uid {
		return httpx.BadRequest("invalid_target", "不能拉黑自己")
	}
	err = pgx.BeginFunc(ctx, h.Svc.Pool, func(tx pgx.Tx) error {
		if err := existingUser(r, tx, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_soc_loop_block (user_id, blocked_user_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`, uid, id); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `DELETE FROM src.src_soc_loop_follow WHERE (follower_id=$1 AND followee_id=$2) OR (follower_id=$2 AND followee_id=$1)`, uid, id)
		return err
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

func (h *Handler) unblock(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	if _, err := h.Svc.Pool.Exec(r.Context(), `DELETE FROM src.src_soc_loop_block WHERE user_id=$1 AND blocked_user_id=$2`, httpx.UserID(r.Context()), id); err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

// BlockEntry is a row of /v1/me/blocks.
type BlockEntry struct {
	User      UserBrief `json:"user"`
	BlockedAt time.Time `json:"blocked_at"`

	uid int64
}

func (h *Handler) blocks(w http.ResponseWriter, r *http.Request) error {
	rows, err := h.Svc.Pool.Query(r.Context(), `SELECT blocked_user_id, create_time FROM src.src_soc_loop_block WHERE user_id=$1 ORDER BY create_time DESC`,
		httpx.UserID(r.Context()))
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (BlockEntry, error) {
		var e BlockEntry
		return e, r.Scan(&e.uid, &e.BlockedAt)
	})
	if err != nil {
		return err
	}
	if err := fillBriefs(r, h.Svc.Pool, items, func(e *BlockEntry) (int64, *UserBrief) { return e.uid, &e.User }); err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}
