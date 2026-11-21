package social

import (
	"context"
	"net/http"

	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// ReplayActivity is the activity summary of a replay.
type ReplayActivity struct {
	ID            int64   `json:"id"`
	Sport         string  `json:"sport"`
	DistanceM     float64 `json:"distance_m"`
	DurationSec   int     `json:"duration_sec"`
	ClaimedAreaM2 float64 `json:"claimed_area_m2"`
}

// ReplayPoint is a point of the replay: seconds from the first shown point.
type ReplayPoint struct {
	Lng float64 `json:"lng"`
	Lat float64 `json:"lat"`
	T   int     `json:"t"`
}

// Replay is one item of 轨迹回放.
type Replay struct {
	PostID    *int64         `json:"post_id"`
	Author    UserBrief      `json:"author"`
	Activity  ReplayActivity `json:"activity"`
	Points    []ReplayPoint  `json:"points"`
	LikeCount int            `json:"like_count"`
	Liked     bool           `json:"liked"`
}

// replay builds the replay of an activity (any status but voided).
func (s *Service) replay(ctx context.Context, q db.Querier, activityID int64) (Replay, error) {
	var rp Replay
	var owner int64
	var hide bool
	err := q.QueryRow(ctx, `SELECT a.id, a.user_id, a.sport, a.distance_m, a.duration_sec, a.claimed_area_m2,
			COALESCE((u.settings_json->>'hide_endpoints')::boolean, true)
		FROM src.src_act_loop_activity a JOIN src.src_usr_loop_user u ON u.id=a.user_id WHERE a.id=$1 AND a.status <> 'voided'`, activityID).
		Scan(&rp.Activity.ID, &owner, &rp.Activity.Sport, &rp.Activity.DistanceM, &rp.Activity.DurationSec, &rp.Activity.ClaimedAreaM2, &hide)
	if err != nil {
		return rp, notFoundOr(err, "运动记录")
	}
	rows, err := q.Query(ctx, `SELECT extract(epoch FROM record_time)::float8, lat, lng FROM src.src_act_loop_track_point WHERE activity_id=$1 ORDER BY seq`, activityID)
	if err != nil {
		return rp, err
	}
	var pts []TPoint
	for rows.Next() {
		var p TPoint
		if err := rows.Scan(&p.T, &p.Lat, &p.Lng); err != nil {
			rows.Close()
			return rp, err
		}
		pts = append(pts, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return rp, err
	}
	pts = Simplify(HideEndpoints(pts, s.hideRadius(owner, hide)), ReplayTrackMax)
	rp.Points = make([]ReplayPoint, 0, len(pts))
	for _, p := range pts {
		rp.Points = append(rp.Points, ReplayPoint{Lng: round6(p.Lng), Lat: round6(p.Lat), T: int(p.T - pts[0].T + 0.5)})
	}
	if rp.Author, err = brief(ctx, q, owner); err != nil {
		return rp, err
	}
	return rp, nil
}

func (h *Handler) replays(w http.ResponseWriter, r *http.Request) error {
	c, limit, err := pageArgs(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	on, err := h.Svc.personalized(ctx, uid)
	if err != nil {
		return err
	}
	posts, next, err := h.Svc.ranked(ctx, uid, c, limit, on, true)
	if err != nil {
		return err
	}
	items := make([]Replay, 0, len(posts))
	for _, p := range posts {
		if p.activityID == nil {
			continue
		}
		rp, err := h.Svc.replay(ctx, h.Svc.Pool, *p.activityID)
		if err != nil {
			if isNotFound(err) {
				continue
			}
			return err
		}
		id := p.ID
		rp.PostID, rp.LikeCount, rp.Liked = &id, p.LikeCount, p.Liked
		items = append(items, rp)
	}
	return httpx.OK(w, newPage(items, next))
}

func (h *Handler) activityReplay(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	s := h.Svc
	var owner int64
	if err := s.Pool.QueryRow(ctx, `SELECT user_id FROM src.src_act_loop_activity WHERE id=$1 AND status <> 'voided'`, id).Scan(&owner); err != nil {
		return notFoundOr(err, "运动记录")
	}
	// The newest post carrying the activity that the viewer can see.
	posts, err := s.queryPosts(ctx, uid, `SELECT `+postCols+` FROM src.src_soc_loop_post p
		WHERE p.activity_id=$2 AND `+visibleSQL+` ORDER BY p.create_time DESC LIMIT 1`, uid, id)
	if err != nil {
		return err
	}
	if owner != uid && len(posts) == 0 {
		return httpx.NotFound("运动记录")
	}
	rp, err := s.replay(ctx, s.Pool, id)
	if err != nil {
		return err
	}
	if len(posts) > 0 {
		p := posts[0]
		rp.PostID, rp.LikeCount, rp.Liked = &p.ID, p.LikeCount, p.Liked
	}
	return httpx.OK(w, rp)
}
