package social

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Comment is the API object.
type Comment struct {
	ID           int64      `json:"id"`
	PostID       int64      `json:"post_id"`
	Author       UserBrief  `json:"author"`
	Content      string     `json:"content"`
	ReplyTo      *UserBrief `json:"reply_to"`
	ParentID     *int64     `json:"parent_id"`
	LikeCount    int        `json:"like_count"`
	Liked        bool       `json:"liked"`
	ReviewStatus string     `json:"review_status"`
	ReplyCount   int        `json:"reply_count"`
	Replies      []Comment  `json:"replies"`
	CreatedAt    time.Time  `json:"created_at"`

	authorID  int64
	replyToID *int64
}

// commentVisibleSQL: comment c is visible to viewer $1 (the post's own
// visibility is checked separately).
const commentVisibleSQL = `c.delete_time IS NULL AND (c.user_id=$1 OR (c.review_status='approved'
	AND NOT EXISTS (SELECT 1 FROM src.src_soc_loop_block b WHERE (b.user_id=$1 AND b.blocked_user_id=c.user_id) OR (b.user_id=c.user_id AND b.blocked_user_id=$1))))`

const commentCols = `c.id, c.post_id, c.user_id, c.content_text, c.reply_to_user_id, c.parent_id, c.like_qty,
	EXISTS (SELECT 1 FROM src.src_soc_loop_comment_like l WHERE l.comment_id=c.id AND l.user_id=$1),
	c.review_status, c.reply_qty, c.create_time`

func scanComment(r pgx.CollectableRow) (Comment, error) {
	var c Comment
	err := r.Scan(&c.ID, &c.PostID, &c.authorID, &c.Content, &c.replyToID, &c.ParentID, &c.LikeCount, &c.Liked, &c.ReviewStatus, &c.ReplyCount, &c.CreatedAt)
	c.Replies = []Comment{}
	if c.ParentID != nil {
		c.ReplyCount = 0
	}
	return c, err
}

func (s *Service) queryComments(ctx context.Context, sql string, args ...any) ([]Comment, error) {
	rows, err := s.Pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanComment)
}

// fillComments loads authors, reply targets and (for top-level comments)
// the first 3 visible replies.
func (s *Service) fillComments(ctx context.Context, viewer int64, cs []Comment, withReplies bool) error {
	if len(cs) == 0 {
		return nil
	}
	if withReplies {
		ids := make([]int64, len(cs))
		for i, c := range cs {
			ids[i] = c.ID
		}
		replies, err := s.queryComments(ctx, `SELECT `+commentCols+` FROM (
				SELECT c.*, row_number() OVER (PARTITION BY c.parent_id ORDER BY c.create_time, c.id) AS rn
				FROM src.src_soc_loop_comment c WHERE c.parent_id = ANY($2) AND `+commentVisibleSQL+`) c
			WHERE c.rn <= 3 ORDER BY c.create_time, c.id`, viewer, ids)
		if err != nil {
			return err
		}
		if err := s.fillComments(ctx, viewer, replies, false); err != nil {
			return err
		}
		idx := map[int64]int{}
		for i, c := range cs {
			idx[c.ID] = i
		}
		for _, rp := range replies {
			i := idx[*rp.ParentID]
			cs[i].Replies = append(cs[i].Replies, rp)
		}
	}
	var uids []int64
	for _, c := range cs {
		uids = append(uids, c.authorID)
		if c.replyToID != nil {
			uids = append(uids, *c.replyToID)
		}
	}
	m, err := Briefs(ctx, s.Pool, uids)
	if err != nil {
		return err
	}
	for i := range cs {
		cs[i].Author = m[cs[i].authorID]
		if cs[i].replyToID != nil {
			b := m[*cs[i].replyToID]
			cs[i].ReplyTo = &b
		}
	}
	return nil
}

func ascPage(cs []Comment, limit int) Page[Comment] {
	var next *cursor
	if len(cs) > limit {
		cs = cs[:limit]
		next = keysetNext(true, cs[limit-1].CreatedAt, cs[limit-1].ID)
	}
	return newPage(cs, next)
}

func (h *Handler) comments(w http.ResponseWriter, r *http.Request) error {
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
	if _, err := h.Svc.visibleAuthor(ctx, h.Svc.Pool, uid, id); err != nil {
		return err
	}
	t, last := c.keysetAsc()
	cs, err := h.Svc.queryComments(ctx, `SELECT `+commentCols+` FROM src.src_soc_loop_comment c
		WHERE c.post_id=$2 AND c.parent_id IS NULL AND `+commentVisibleSQL+` AND (c.create_time, c.id) > ($3, $4)
		ORDER BY c.create_time, c.id LIMIT $5`, uid, id, t, last, limit+1)
	if err != nil {
		return err
	}
	page := ascPage(cs, limit)
	if err := h.Svc.fillComments(ctx, uid, page.Items, true); err != nil {
		return err
	}
	return httpx.OK(w, page)
}

func (h *Handler) replies(w http.ResponseWriter, r *http.Request) error {
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
	s := h.Svc
	var postID int64
	err = s.Pool.QueryRow(ctx, `SELECT c.post_id FROM src.src_soc_loop_comment c WHERE c.id=$2 AND c.parent_id IS NULL AND `+commentVisibleSQL, uid, id).Scan(&postID)
	if err != nil {
		return notFoundOr(err, "评论")
	}
	if _, err := s.visibleAuthor(ctx, s.Pool, uid, postID); err != nil {
		return err
	}
	t, last := c.keysetAsc()
	cs, err := s.queryComments(ctx, `SELECT `+commentCols+` FROM src.src_soc_loop_comment c
		WHERE c.parent_id=$2 AND `+commentVisibleSQL+` AND (c.create_time, c.id) > ($3, $4)
		ORDER BY c.create_time, c.id LIMIT $5`, uid, id, t, last, limit+1)
	if err != nil {
		return err
	}
	page := ascPage(cs, limit)
	if err := s.fillComments(ctx, uid, page.Items, false); err != nil {
		return err
	}
	return httpx.OK(w, page)
}

func (h *Handler) createComment(w http.ResponseWriter, r *http.Request) error {
	postID, err := pathID(r)
	if err != nil {
		return err
	}
	var req struct {
		Content       string `json:"content"`
		ParentID      *int64 `json:"parent_id"`
		ReplyToUserID *int64 `json:"reply_to_user_id"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	req.Content = strings.TrimSpace(req.Content)
	if n := utf8.RuneCountInString(req.Content); n < 1 || n > 200 {
		return httpx.BadRequest("invalid_content", "评论 1–200 字")
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	s := h.Svc
	var id int64
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var postAuthor int64
		if err := tx.QueryRow(ctx, `SELECT user_id FROM src.src_soc_loop_post WHERE id=$1 AND delete_time IS NULL`, postID).Scan(&postAuthor); err != nil {
			return notFoundOr(err, "动态")
		}
		if b, err := blockedEither(ctx, tx, uid, postAuthor); err != nil {
			return err
		} else if b {
			return ErrBlocked
		}
		if _, err := s.visibleAuthor(ctx, tx, uid, postID); err != nil {
			if db.IsNoRows(err) || isNotFound(err) {
				return httpx.Forbidden("forbidden", "这条动态暂时不能评论")
			}
			return err
		}
		muted, _, err := author(ctx, tx, uid)
		if err != nil {
			return err
		}
		if muted {
			return ErrMuted
		}
		if err := s.rateLimit(ctx, fmt.Sprintf("comment:%d", uid), 5, time.Minute); err != nil {
			return err
		}
		if req.ParentID == nil {
			req.ReplyToUserID = nil
		} else {
			var parentAuthor int64
			err := tx.QueryRow(ctx, `SELECT c.user_id FROM src.src_soc_loop_comment c WHERE c.id=$2 AND c.post_id=$3 AND c.parent_id IS NULL AND `+commentVisibleSQL,
				uid, *req.ParentID, postID).Scan(&parentAuthor)
			if db.IsNoRows(err) {
				return httpx.BadRequest("invalid_parent", "要回复的评论不存在")
			}
			if err != nil {
				return err
			}
			if req.ReplyToUserID != nil {
				var ok bool
				if err := tx.QueryRow(ctx, `SELECT $3::bigint=$4::bigint OR EXISTS (SELECT 1 FROM src.src_soc_loop_comment WHERE parent_id=$1 AND user_id=$2 AND delete_time IS NULL)`,
					*req.ParentID, *req.ReplyToUserID, *req.ReplyToUserID, parentAuthor).Scan(&ok); err != nil {
					return err
				}
				if !ok {
					return httpx.BadRequest("invalid_body", "reply_to_user_id 不在这条评论下")
				}
				if b, err := blockedEither(ctx, tx, uid, *req.ReplyToUserID); err != nil {
					return err
				} else if b {
					return ErrBlocked
				}
			}
		}
		sc := s.Mod.Check(ctx, req.Content, false)
		if sc.Blocked {
			return moderation.ErrBlocked
		}
		pending := s.Mod.NeedsReview(ctx, sc)
		if err := tx.QueryRow(ctx, `INSERT INTO src.src_soc_loop_comment (post_id, user_id, parent_id, reply_to_user_id, content_text, review_status)
			VALUES ($1,$2,$3,$4,$5,'pending') RETURNING id`, postID, uid, req.ParentID, req.ReplyToUserID, req.Content).Scan(&id); err != nil {
			return err
		}
		if pending {
			_, err := moderation.Submit(ctx, tx, moderation.Comment, id, uid, req.Content, nil, sc)
			return err
		}
		return approveComment(ctx, tx, id)
	})
	if err != nil {
		return err
	}
	cs, err := s.queryComments(ctx, `SELECT `+commentCols+` FROM src.src_soc_loop_comment c WHERE c.id=$2`, uid, id)
	if err != nil {
		return err
	}
	if err := s.fillComments(ctx, uid, cs, false); err != nil {
		return err
	}
	return httpx.OK(w, cs[0])
}

func isNotFound(err error) bool {
	e, ok := err.(*httpx.Error)
	return ok && e.Status == http.StatusNotFound
}

// countComment moves the post and parent counters by delta.
func countComment(ctx context.Context, tx pgx.Tx, postID int64, parentID *int64, delta int) error {
	if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_post SET comment_qty=GREATEST(comment_qty+$2, 0) WHERE id=$1`, postID, delta); err != nil {
		return err
	}
	if parentID != nil {
		if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_comment SET reply_qty=GREATEST(reply_qty+$2, 0) WHERE id=$1`, *parentID, delta); err != nil {
			return err
		}
	}
	return nil
}

// approveComment publishes a comment: counters, and on its first approval
// the interaction notifications to the post author and the replied user.
func approveComment(ctx context.Context, tx pgx.Tx, id int64) error {
	var postID, uid int64
	var parentID, replyTo *int64
	var status, content string
	var approvedBefore, deleted bool
	err := tx.QueryRow(ctx, `SELECT post_id, user_id, parent_id, reply_to_user_id, review_status, approve_time IS NOT NULL, delete_time IS NOT NULL, content_text
		FROM src.src_soc_loop_comment WHERE id=$1 FOR UPDATE`, id).Scan(&postID, &uid, &parentID, &replyTo, &status, &approvedBefore, &deleted, &content)
	if err != nil {
		return notFoundOr(err, "评论")
	}
	if status == "approved" || deleted {
		return nil
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_comment SET review_status='approved', reject_reason=NULL, approve_time=COALESCE(approve_time, now()), update_time=now() WHERE id=$1`, id); err != nil {
		return err
	}
	if err := countComment(ctx, tx, postID, parentID, 1); err != nil {
		return err
	}
	if approvedBefore {
		return nil
	}
	var postAuthor int64
	if err := tx.QueryRow(ctx, `SELECT user_id FROM src.src_soc_loop_post WHERE id=$1`, postID).Scan(&postAuthor); err != nil {
		return err
	}
	replied := replyTo
	if parentID != nil && replied == nil {
		var pa int64
		if err := tx.QueryRow(ctx, `SELECT user_id FROM src.src_soc_loop_comment WHERE id=$1`, *parentID).Scan(&pa); err != nil {
			return err
		}
		replied = &pa
	}
	me, err := brief(ctx, tx, uid)
	if err != nil {
		return err
	}
	preview := []rune(content)
	if len(preview) > 40 {
		preview = append(preview[:40], '…')
	}
	if replied != nil && *replied != uid {
		data := map[string]any{"type": "reply", "post_id": postID, "comment_id": id, "user_id": uid}
		if err := inbox.Notify(ctx, tx, *replied, inbox.Interaction, "收到回复", me.Nickname+" 回复了你："+string(preview), data); err != nil {
			return err
		}
	}
	if postAuthor != uid && (replied == nil || *replied != postAuthor) {
		data := map[string]any{"type": "comment", "post_id": postID, "comment_id": id, "user_id": uid}
		if err := inbox.Notify(ctx, tx, postAuthor, inbox.Interaction, "收到评论", me.Nickname+" 评论了你的动态："+string(preview), data); err != nil {
			return err
		}
	}
	return nil
}

// hideComment takes a comment out of view (pending, rejected or deleted)
// and keeps the counters. Deleting a top-level comment deletes its
// replies with it.
func hideComment(ctx context.Context, tx pgx.Tx, id int64, status, reason string, del bool) error {
	var postID int64
	var parentID *int64
	var cur string
	var deleted bool
	err := tx.QueryRow(ctx, `SELECT post_id, parent_id, review_status, delete_time IS NOT NULL FROM src.src_soc_loop_comment WHERE id=$1 FOR UPDATE`, id).
		Scan(&postID, &parentID, &cur, &deleted)
	if err != nil {
		return notFoundOr(err, "评论")
	}
	if deleted {
		return nil
	}
	if cur == "approved" {
		if err := countComment(ctx, tx, postID, parentID, -1); err != nil {
			return err
		}
	}
	if del {
		if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_comment SET delete_time=now(), update_time=now() WHERE id=$1`, id); err != nil {
			return err
		}
		if parentID == nil {
			var n int
			if err := tx.QueryRow(ctx, `WITH d AS (UPDATE src.src_soc_loop_comment SET delete_time=now(), update_time=now()
					WHERE parent_id=$1 AND delete_time IS NULL RETURNING review_status)
				SELECT count(*) FROM d WHERE review_status='approved'`, id).Scan(&n); err != nil {
				return err
			}
			if n > 0 {
				if err := countComment(ctx, tx, postID, nil, -n); err != nil {
					return err
				}
			}
		}
		return nil
	}
	var rr *string
	if reason != "" {
		rr = &reason
	}
	_, err = tx.Exec(ctx, `UPDATE src.src_soc_loop_comment SET review_status=$2, reject_reason=$3, update_time=now() WHERE id=$1`, id, status, rr)
	return err
}

func (h *Handler) deleteComment(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	err = pgx.BeginFunc(ctx, h.Svc.Pool, func(tx pgx.Tx) error {
		var ok bool
		err := tx.QueryRow(ctx, `SELECT c.user_id=$2 OR p.user_id=$2 FROM src.src_soc_loop_comment c JOIN src.src_soc_loop_post p ON p.id=c.post_id
			WHERE c.id=$1 AND c.delete_time IS NULL`, id, uid).Scan(&ok)
		if err != nil {
			return notFoundOr(err, "评论")
		}
		if !ok {
			return httpx.Forbidden("forbidden", "只有评论作者或动态作者可以删除")
		}
		return hideComment(ctx, tx, id, "", "", true)
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

func (h *Handler) likeComment(w http.ResponseWriter, r *http.Request) error {
	return h.toggleCommentLike(w, r, true)
}

func (h *Handler) unlikeComment(w http.ResponseWriter, r *http.Request) error {
	return h.toggleCommentLike(w, r, false)
}

func (h *Handler) toggleCommentLike(w http.ResponseWriter, r *http.Request, on bool) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	s := h.Svc
	var n int
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var postID, author int64
		err := tx.QueryRow(ctx, `SELECT c.post_id, c.user_id FROM src.src_soc_loop_comment c WHERE c.id=$2 AND `+commentVisibleSQL, uid, id).Scan(&postID, &author)
		if err != nil {
			return notFoundOr(err, "评论")
		}
		if on {
			if _, err := s.visibleAuthor(ctx, tx, uid, postID); err != nil {
				return err
			}
			tag, err := tx.Exec(ctx, `INSERT INTO src.src_soc_loop_comment_like (comment_id, user_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`, id, uid)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 1 {
				if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_comment SET like_qty=like_qty+1 WHERE id=$1`, id); err != nil {
					return err
				}
				if author != uid && s.once(ctx, fmt.Sprintf("like_comment:%d:%d", id, uid), 24*time.Hour) {
					me, err := brief(ctx, tx, uid)
					if err != nil {
						return err
					}
					if err := inbox.Notify(ctx, tx, author, inbox.Interaction, "收到点赞", me.Nickname+" 赞了你的评论",
						map[string]any{"type": "like_comment", "post_id": postID, "comment_id": id, "user_id": uid}); err != nil {
						return err
					}
				}
			}
		} else {
			tag, err := tx.Exec(ctx, `DELETE FROM src.src_soc_loop_comment_like WHERE comment_id=$1 AND user_id=$2`, id, uid)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 1 {
				if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_comment SET like_qty=GREATEST(like_qty-1, 0) WHERE id=$1`, id); err != nil {
					return err
				}
			}
		}
		return tx.QueryRow(ctx, `SELECT like_qty FROM src.src_soc_loop_comment WHERE id=$1`, id).Scan(&n)
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"liked": on, "like_count": n})
}
