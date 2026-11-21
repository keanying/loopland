package social

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/crew"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/media"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// PostImage is an image of a post.
type PostImage struct {
	URL    string `json:"url"`
	Width  *int   `json:"width"`
	Height *int   `json:"height"`
}

// storedImage is an element of images_json.
type storedImage struct {
	ID int64 `json:"id"`
	PostImage
}

// PostActivity is the activity attached to a post.
type PostActivity struct {
	ID            int64        `json:"id"`
	Sport         string       `json:"sport"`
	DistanceM     float64      `json:"distance_m"`
	DurationSec   int          `json:"duration_sec"`
	PaceSecPerKm  *int         `json:"pace_sec_per_km"`
	ClaimedAreaM2 float64      `json:"claimed_area_m2"`
	StartTime     time.Time    `json:"start_time"`
	Track         [][2]float64 `json:"track"`
}

// Post is the API object.
type Post struct {
	ID           int64         `json:"id"`
	Author       UserBrief     `json:"author"`
	Content      string        `json:"content"`
	Images       []PostImage   `json:"images"`
	Activity     *PostActivity `json:"activity"`
	Visibility   string        `json:"visibility"`
	ReviewStatus string        `json:"review_status"`
	RejectReason *string       `json:"reject_reason"`
	LikeCount    int           `json:"like_count"`
	CommentCount int           `json:"comment_count"`
	CollectCount int           `json:"collect_count"`
	ShareCount   int           `json:"share_count"`
	Liked        bool          `json:"liked"`
	Collected    bool          `json:"collected"`
	// AIReport is the attached AI battle report (docs/api/v2-3-AI.md).
	AIReport  *PostAIReport `json:"ai_report"`
	CreatedAt time.Time     `json:"created_at"`
	// Deleted is only set in the admin list.
	Deleted *bool `json:"deleted,omitempty"`

	authorID   int64
	activityID *int64
	aiReport   *string
	// hideM overrides the author's endpoint radius for this post (审核
	// 「隐藏起终点后通过」).
	hideM *float64
}

// PostAIReport is the AI battle report shown in a post.
type PostAIReport struct {
	Text        string `json:"text"`
	AIGenerated bool   `json:"ai_generated"`
}

// Visibilities.
var visibilities = map[string]bool{"public": true, "fans": true, "crew": true, "private": true}

// visibleSQL is the condition for post p being visible to viewer $1:
// authors see their own (any review state); others only approved posts
// without a block between them, within the visibility range.
const visibleSQL = `p.delete_time IS NULL AND (p.user_id = $1 OR (p.review_status = 'approved'
	AND NOT EXISTS (SELECT 1 FROM src.src_soc_loop_block b WHERE (b.user_id=$1 AND b.blocked_user_id=p.user_id) OR (b.user_id=p.user_id AND b.blocked_user_id=$1))
	AND (p.visibility_type = 'public'
	  OR (p.visibility_type = 'fans' AND EXISTS (SELECT 1 FROM src.src_soc_loop_follow f WHERE f.follower_id=$1 AND f.followee_id=p.user_id))
	  OR (p.visibility_type = 'crew' AND EXISTS (SELECT 1 FROM src.src_soc_loop_crew_member m1 JOIN src.src_soc_loop_crew_member m2 ON m2.crew_id=m1.crew_id
	        WHERE m1.user_id=p.user_id AND m2.user_id=$1)))))`

// notBlockedSQL excludes authors in a block relation with viewer $1.
const notBlockedSQL = `NOT EXISTS (SELECT 1 FROM src.src_soc_loop_block b WHERE (b.user_id=$1 AND b.blocked_user_id=p.user_id) OR (b.user_id=p.user_id AND b.blocked_user_id=$1))`

// postCols are scanned by scanPost; $1 is the viewer.
const postCols = `p.id, p.user_id, p.content_text, p.images_json, p.activity_id, p.visibility_type, p.review_status, p.reject_reason,
	p.like_qty, p.comment_qty, p.collect_qty, p.share_qty, p.create_time, p.delete_time IS NOT NULL,
	EXISTS (SELECT 1 FROM src.src_soc_loop_post_like l WHERE l.post_id=p.id AND l.user_id=$1),
	EXISTS (SELECT 1 FROM src.src_soc_loop_post_collect c WHERE c.post_id=p.id AND c.user_id=$1),
	p.ai_report_text, p.hide_endpoints_m`

// postDest are the scan targets of postCols.
func postDest(p *Post, raw *[]byte, deleted *bool) []any {
	return []any{&p.ID, &p.authorID, &p.Content, raw, &p.activityID, &p.Visibility, &p.ReviewStatus, &p.RejectReason,
		&p.LikeCount, &p.CommentCount, &p.CollectCount, &p.ShareCount, &p.CreatedAt, deleted, &p.Liked, &p.Collected, &p.aiReport, &p.hideM}
}

// finish decodes the stored images and the report.
func (p *Post) finish(raw []byte) {
	var imgs []storedImage
	_ = json.Unmarshal(raw, &imgs)
	p.Images = make([]PostImage, 0, len(imgs))
	for _, im := range imgs {
		p.Images = append(p.Images, im.PostImage)
	}
	if p.aiReport != nil {
		p.AIReport = &PostAIReport{Text: *p.aiReport, AIGenerated: true}
	}
}

func scanPost(row pgx.Row) (Post, bool, error) {
	var p Post
	var raw []byte
	var deleted bool
	if err := row.Scan(postDest(&p, &raw, &deleted)...); err != nil {
		return p, false, err
	}
	p.finish(raw)
	return p, deleted, nil
}

// queryPosts runs a query selecting postCols and hydrates the results.
func (s *Service) queryPosts(ctx context.Context, viewer int64, sql string, args ...any) ([]Post, error) {
	rows, err := s.Pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	posts, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Post, error) {
		p, _, err := scanPost(r)
		return p, err
	})
	if err != nil {
		return nil, err
	}
	return posts, s.hydrate(ctx, viewer, posts)
}

// hydrate fills authors and activities.
func (s *Service) hydrate(ctx context.Context, viewer int64, posts []Post) error {
	if len(posts) == 0 {
		return nil
	}
	var uids, aids []int64
	for _, p := range posts {
		uids = append(uids, p.authorID)
		if p.activityID != nil {
			aids = append(aids, *p.activityID)
		}
	}
	briefs, err := Briefs(ctx, s.Pool, uids)
	if err != nil {
		return err
	}
	acts, err := s.postActivities(ctx, aids)
	if err != nil {
		return err
	}
	for i := range posts {
		p := &posts[i]
		p.Author = briefs[p.authorID]
		if p.activityID != nil {
			if a, ok := acts[*p.activityID]; ok {
				v := a.view
				radius := a.radius
				if p.hideM != nil {
					radius = *p.hideM
				}
				v.Track = [][2]float64{}
				for _, pt := range Simplify(HideEndpoints(a.pts, radius), PostTrackMax) {
					v.Track = append(v.Track, [2]float64{round6(pt.Lng), round6(pt.Lat)})
				}
				p.Activity = &v
			}
		}
		if p.authorID != viewer {
			p.RejectReason = nil
		}
	}
	return nil
}

// hideRadius is the endpoint radius for an author (0 when they show them).
func (s *Service) hideRadius(author int64, hide bool) float64 {
	if !hide {
		return 0
	}
	return s.Config.For(author).Community.HideEndpointsM
}

// postActivity is an attached activity before its track is cut per post.
type postActivity struct {
	view   PostActivity
	pts    []TPoint
	radius float64 // the author's setting
}

func (s *Service) postActivities(ctx context.Context, ids []int64) (map[int64]postActivity, error) {
	out := map[int64]postActivity{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := s.Pool.Query(ctx, `SELECT a.id, a.user_id, a.sport, a.distance_m, a.duration_sec, a.claimed_area_m2, a.start_time,
			ST_AsGeoJSON(a.track_geom, 6), COALESCE((u.settings_json->>'hide_endpoints')::boolean, true)
		FROM src.src_act_loop_activity a JOIN src.src_usr_loop_user u ON u.id=a.user_id
		WHERE a.id = ANY($1) AND a.status='settled'`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var pa postActivity
		a := &pa.view
		var owner int64
		var geom *string
		var hide bool
		if err := rows.Scan(&a.ID, &owner, &a.Sport, &a.DistanceM, &a.DurationSec, &a.ClaimedAreaM2, &a.StartTime, &geom, &hide); err != nil {
			return nil, err
		}
		a.PaceSecPerKm = pace(a.DistanceM, a.DurationSec)
		pa.radius = s.hideRadius(owner, hide)
		if geom != nil {
			var g struct {
				Coordinates [][]float64 `json:"coordinates"`
			}
			_ = json.Unmarshal([]byte(*geom), &g)
			pa.pts = make([]TPoint, 0, len(g.Coordinates))
			for _, c := range g.Coordinates {
				if len(c) >= 2 {
					pa.pts = append(pa.pts, TPoint{Lng: c[0], Lat: c[1]})
				}
			}
		}
		out[a.ID] = pa
	}
	return out, rows.Err()
}

func pace(distanceM float64, durationSec int) *int {
	if distanceM < 10 || durationSec <= 0 {
		return nil
	}
	p := int(float64(durationSec) / (distanceM / 1000))
	return &p
}

// loadPost returns a post visible to viewer (404 otherwise).
func (s *Service) loadPost(ctx context.Context, viewer, id int64) (Post, error) {
	posts, err := s.queryPosts(ctx, viewer, `SELECT `+postCols+` FROM src.src_soc_loop_post p WHERE p.id=$2 AND `+visibleSQL, viewer, id)
	if err != nil {
		return Post{}, err
	}
	if len(posts) == 0 {
		return Post{}, httpx.NotFound("动态")
	}
	return posts[0], nil
}

// ---------------------------------------------------------------- create / delete / get

func (h *Handler) createPost(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Content    string  `json:"content"`
		ImageIDs   []int64 `json:"image_ids"`
		ActivityID *int64  `json:"activity_id"`
		Visibility string  `json:"visibility"`
		// AIReport attaches the activity's AI battle report.
		AIReport bool `json:"ai_report"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	req.Content = strings.TrimSpace(req.Content)
	if utf8.RuneCountInString(req.Content) > 500 {
		return httpx.BadRequest("invalid_content", "正文最多 500 字")
	}
	if req.Content == "" && len(req.ImageIDs) == 0 && req.ActivityID == nil {
		return httpx.BadRequest("invalid_content", "写点什么，或者加张图片、附一次运动")
	}
	if len(req.ImageIDs) > 9 {
		return httpx.BadRequest("invalid_media", "最多 9 张图片")
	}
	if req.Visibility == "" {
		req.Visibility = "public"
	}
	if !visibilities[req.Visibility] {
		return httpx.BadRequest("invalid_body", "visibility 取值错误")
	}
	s := h.Svc
	// Checks that do not need the author lock, then the (possibly slow)
	// AI scoring outside the transaction.
	muted, newUser, err := authorState(ctx, s.Pool, uid)
	if err != nil {
		return err
	}
	if muted {
		return ErrMuted
	}
	imgs, err := media.Owned(ctx, s.Pool, uid, req.ImageIDs)
	if err != nil {
		return err
	}
	if req.ActivityID != nil {
		var ok bool
		if err := s.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_act_loop_activity WHERE id=$1 AND user_id=$2 AND status='settled')`,
			*req.ActivityID, uid).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return httpx.BadRequest("invalid_activity", "只能附自己已完成结算的运动")
		}
	}
	var report *string
	if req.AIReport {
		if req.ActivityID == nil {
			return httpx.BadRequest("invalid_ai_report", "带 AI 战报时必须附上这次运动")
		}
		var text string
		err := s.Pool.QueryRow(ctx, `SELECT report_text FROM src.src_act_loop_ai_report WHERE activity_id=$1 AND user_id=$2`, *req.ActivityID, uid).Scan(&text)
		if db.IsNoRows(err) {
			return httpx.BadRequest("invalid_ai_report", "这次运动还没有生成 AI 战报")
		}
		if err != nil {
			return err
		}
		report = &text
	}
	if req.Visibility == "crew" {
		if c, err := crew.Of(ctx, s.Pool, uid); err != nil {
			return err
		} else if c == nil {
			return httpx.BadRequest("not_in_crew", "加入跑团后才能选「仅跑团」")
		}
	}
	urls := make([]string, len(imgs))
	stored := make([]storedImage, len(imgs))
	for i, im := range imgs {
		stored[i] = storedImage{ID: im.ID, PostImage: PostImage{URL: im.URL, Width: im.Width, Height: im.Height}}
		urls[i] = im.URL
	}
	text := req.Content
	if report != nil {
		text = strings.TrimSpace(text + "\n" + *report)
	}
	sc := s.Mod.Review(ctx, moderation.Content{Target: moderation.Post, UserID: uid, Text: text, Images: urls, NewUserWithImages: newUser && len(imgs) > 0})
	if sc.Blocked {
		return moderation.ErrBlocked
	}
	outcome := s.Mod.Outcome(ctx, sc)
	var id int64
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		muted, _, err := author(ctx, tx, uid)
		if err != nil {
			return err
		}
		if muted {
			return ErrMuted
		}
		var today int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM src.src_soc_loop_post WHERE user_id=$1 AND create_time >= $2`, uid, clock.Today()).Scan(&today); err != nil {
			return err
		}
		if today >= s.Config.For(uid).Community.DailyPostLimit {
			return httpx.E(http.StatusTooManyRequests, "rate_limited", "今天发的动态太多了，明天再来")
		}
		status := "approved"
		if outcome != moderation.OutcomeApprove {
			status = "pending"
		}
		raw, _ := json.Marshal(stored)
		if err := tx.QueryRow(ctx, `INSERT INTO src.src_soc_loop_post (user_id, content_text, images_json, activity_id, visibility_type, review_status, ai_report_text)
			VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`, uid, req.Content, raw, req.ActivityID, req.Visibility, status, report).Scan(&id); err != nil {
			return err
		}
		return s.Mod.File(ctx, tx, moderation.Post, id, uid, text, urls, sc, outcome)
	})
	if err != nil {
		return err
	}
	p, err := s.loadPost(ctx, uid, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, p)
}

func (h *Handler) getPost(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	p, err := h.Svc.loadPost(r.Context(), httpx.UserID(r.Context()), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, p)
}

func (h *Handler) deletePost(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	tag, err := h.Svc.Pool.Exec(r.Context(), `UPDATE src.src_soc_loop_post SET delete_time=now(), update_time=now() WHERE id=$1 AND user_id=$2 AND delete_time IS NULL`,
		id, httpx.UserID(r.Context()))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return httpx.NotFound("动态")
	}
	return httpx.OK(w, httpx.Empty)
}

// ---------------------------------------------------------------- lists

func (h *Handler) userPosts(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	c, limit, err := pageArgs(r)
	if err != nil {
		return err
	}
	uid := httpx.UserID(r.Context())
	t, last := c.keysetDesc()
	posts, err := h.Svc.queryPosts(r.Context(), uid, `SELECT `+postCols+` FROM src.src_soc_loop_post p
		WHERE p.user_id=$2 AND `+visibleSQL+` AND (p.create_time, p.id) < ($3, $4)
		ORDER BY p.create_time DESC, p.id DESC LIMIT $5`, uid, id, t, last, limit+1)
	if err != nil {
		return err
	}
	return httpx.OK(w, timePage(posts, limit))
}

func timePage(posts []Post, limit int) Page[Post] {
	var next *cursor
	if len(posts) > limit {
		posts = posts[:limit]
		lp := posts[len(posts)-1]
		next = keysetNext(true, lp.CreatedAt, lp.ID)
	}
	return newPage(posts, next)
}

// hotSQL is the recommend score (热度 ÷ (小时数 + 2)^1.5) at snapshot $2.
const hotSQL = `(p.like_qty*2 + p.comment_qty*3 + p.collect_qty*2 + 1)::float8 / power(GREATEST(extract(epoch FROM ($2::timestamptz - p.create_time)), 0)/3600 + 2, 1.5)`

// ranked returns a page of public, approved posts from the last 7 days in
// recommend order (or newest first when personalized is off). withReplay
// keeps only posts with an attached activity.
func (s *Service) ranked(ctx context.Context, viewer int64, c cursor, limit int, personalized, withReplay bool) ([]Post, *cursor, error) {
	snap := time.UnixMicro(time.Now().UnixMicro()) // the database keeps microseconds
	if c.Snap != 0 {
		snap = time.UnixMicro(c.Snap)
	}
	order := hotSQL + ` DESC, p.id DESC`
	if !personalized {
		order = `p.create_time DESC, p.id DESC`
	}
	extra := ""
	if withReplay {
		extra = ` AND p.activity_id IS NOT NULL AND EXISTS (SELECT 1 FROM src.src_act_loop_activity a WHERE a.id=p.activity_id AND a.status='settled' AND a.track_geom IS NOT NULL)`
	}
	posts, err := s.queryPosts(ctx, viewer, `SELECT `+postCols+` FROM src.src_soc_loop_post p
		WHERE p.delete_time IS NULL AND p.review_status='approved' AND p.visibility_type='public'
		  AND p.create_time > $2::timestamptz - interval '7 days' AND p.create_time <= $2 AND `+notBlockedSQL+extra+`
		ORDER BY `+order+` OFFSET $3 LIMIT $4`, viewer, snap, c.Off, limit+1)
	if err != nil {
		return nil, nil, err
	}
	var next *cursor
	if len(posts) > limit {
		posts = posts[:limit]
		next = &cursor{Off: c.Off + limit, Snap: snap.UnixMicro()}
	}
	return posts, next, nil
}

func (s *Service) personalized(ctx context.Context, uid int64) (bool, error) {
	var on bool
	err := s.Pool.QueryRow(ctx, `SELECT COALESCE((settings_json->>'personalized')::boolean, true) FROM src.src_usr_loop_user WHERE id=$1`, uid).Scan(&on)
	return on, err
}

func (h *Handler) feed(w http.ResponseWriter, r *http.Request) error {
	c, limit, err := pageArgs(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	switch r.URL.Query().Get("tab") {
	case "", "following":
		t, last := c.keysetDesc()
		posts, err := h.Svc.queryPosts(ctx, uid, `SELECT `+postCols+` FROM src.src_soc_loop_post p
			WHERE (p.user_id=$1 OR p.user_id IN (SELECT followee_id FROM src.src_soc_loop_follow WHERE follower_id=$1))
			  AND `+visibleSQL+` AND (p.create_time, p.id) < ($2, $3)
			ORDER BY p.create_time DESC, p.id DESC LIMIT $4`, uid, t, last, limit+1)
		if err != nil {
			return err
		}
		return httpx.OK(w, timePage(posts, limit))
	case "recommend":
		on, err := h.Svc.personalized(ctx, uid)
		if err != nil {
			return err
		}
		posts, next, err := h.Svc.ranked(ctx, uid, c, limit, on, false)
		if err != nil {
			return err
		}
		return httpx.OK(w, newPage(posts, next))
	}
	return httpx.BadRequest("invalid_body", "tab 取值错误")
}

// ---------------------------------------------------------------- like / collect / share

// postFor returns the author of a post visible to uid.
func (s *Service) visibleAuthor(ctx context.Context, q db.Querier, uid, id int64) (int64, error) {
	var author int64
	err := q.QueryRow(ctx, `SELECT p.user_id FROM src.src_soc_loop_post p WHERE p.id=$2 AND `+visibleSQL, uid, id).Scan(&author)
	return author, notFoundOr(err, "动态")
}

func (h *Handler) likePost(w http.ResponseWriter, r *http.Request) error {
	return h.toggle(w, r, true, "src_soc_loop_post_like", "like_qty", "liked", "like_count")
}

func (h *Handler) unlikePost(w http.ResponseWriter, r *http.Request) error {
	return h.toggle(w, r, false, "src_soc_loop_post_like", "like_qty", "liked", "like_count")
}

func (h *Handler) collect(w http.ResponseWriter, r *http.Request) error {
	return h.toggle(w, r, true, "src_soc_loop_post_collect", "collect_qty", "collected", "collect_count")
}

func (h *Handler) uncollect(w http.ResponseWriter, r *http.Request) error {
	return h.toggle(w, r, false, "src_soc_loop_post_collect", "collect_qty", "collected", "collect_count")
}

// toggle adds or removes a like/collect row and keeps the counter.
func (h *Handler) toggle(w http.ResponseWriter, r *http.Request, on bool, table, counter, flag, countKey string) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	s := h.Svc
	var n int
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if on {
			authorID, err := s.visibleAuthor(ctx, tx, uid, id)
			if err != nil {
				return err
			}
			tag, err := tx.Exec(ctx, `INSERT INTO src.`+table+` (post_id, user_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`, id, uid)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 1 {
				if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_post SET `+counter+`=`+counter+`+1 WHERE id=$1`, id); err != nil {
					return err
				}
				if counter == "like_qty" && authorID != uid && s.once(ctx, fmt.Sprintf("like_post:%d:%d", id, uid), 24*time.Hour) {
					b, err := brief(ctx, tx, uid)
					if err != nil {
						return err
					}
					if err := inbox.Notify(ctx, tx, authorID, inbox.Interaction, "收到点赞", b.Nickname+" 赞了你的动态",
						map[string]any{"type": "like_post", "post_id": id, "user_id": uid}); err != nil {
						return err
					}
				}
			}
		} else {
			var exists bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_soc_loop_post WHERE id=$1 AND delete_time IS NULL)`, id).Scan(&exists); err != nil {
				return err
			}
			if !exists {
				return httpx.NotFound("动态")
			}
			tag, err := tx.Exec(ctx, `DELETE FROM src.`+table+` WHERE post_id=$1 AND user_id=$2`, id, uid)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 1 {
				if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_post SET `+counter+`=GREATEST(`+counter+`-1, 0) WHERE id=$1`, id); err != nil {
					return err
				}
			}
		}
		return tx.QueryRow(ctx, `SELECT `+counter+` FROM src.src_soc_loop_post WHERE id=$1`, id).Scan(&n)
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{flag: on, countKey: n})
}

func (h *Handler) collections(w http.ResponseWriter, r *http.Request) error {
	c, limit, err := pageArgs(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	t, last := c.keysetDesc()
	rows, err := h.Svc.Pool.Query(ctx, `SELECT `+postCols+`, k.create_time FROM src.src_soc_loop_post_collect k
		JOIN src.src_soc_loop_post p ON p.id=k.post_id
		WHERE k.user_id=$1 AND `+visibleSQL+` AND (k.create_time, k.post_id) < ($2, $3)
		ORDER BY k.create_time DESC, k.post_id DESC LIMIT $4`, uid, t, last, limit+1)
	if err != nil {
		return err
	}
	var times []time.Time
	posts, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Post, error) {
		var p Post
		var raw []byte
		var deleted bool
		var at time.Time
		err := r.Scan(append(postDest(&p, &raw, &deleted), &at)...)
		p.finish(raw)
		times = append(times, at)
		return p, err
	})
	if err != nil {
		return err
	}
	if err := h.Svc.hydrate(ctx, uid, posts); err != nil {
		return err
	}
	var next *cursor
	if len(posts) > limit {
		posts = posts[:limit]
		next = keysetNext(true, times[limit-1], posts[limit-1].ID)
	}
	return httpx.OK(w, newPage(posts, next))
}

var shareChannels = map[string]bool{"wechat": true, "moments": true, "poster": true, "link": true}

func (h *Handler) share(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	var req struct {
		Channel string `json:"channel"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if !shareChannels[req.Channel] {
		return httpx.BadRequest("invalid_body", "channel 取值错误")
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	p, err := h.Svc.loadPost(ctx, uid, id)
	if err != nil {
		return err
	}
	if err := h.Svc.Pool.QueryRow(ctx, `UPDATE src.src_soc_loop_post SET share_qty=share_qty+1 WHERE id=$1 RETURNING share_qty`, id).Scan(&p.ShareCount); err != nil {
		return err
	}
	title := []rune(p.Content)
	if len(title) > 30 {
		title = append(title[:30], '…')
	}
	if len(title) == 0 {
		title = []rune(p.Author.Nickname + " 的动态")
	}
	subtitle := ""
	if a := p.Activity; a != nil {
		subtitle = fmt.Sprintf("%.2f km", a.DistanceM/1000)
		if a.PaceSecPerKm != nil {
			subtitle += fmt.Sprintf(" · %d'%02d\"", *a.PaceSecPerKm/60, *a.PaceSecPerKm%60)
		}
	}
	var image *string
	if len(p.Images) > 0 {
		image = &p.Images[0].URL
	}
	return httpx.OK(w, map[string]any{
		"share_count": p.ShareCount,
		"url":         fmt.Sprintf("%s/p/%d", strings.TrimRight(h.Svc.ShareBase, "/"), id),
		"poster":      map[string]any{"title": string(title), "subtitle": subtitle, "image_url": image},
	})
}
