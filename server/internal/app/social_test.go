package app

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/nickname"
)

type socUser struct {
	ID        int64   `json:"id"`
	Nickname  string  `json:"nickname"`
	AvatarURL *string `json:"avatar_url"`
	Crew      *struct {
		ID   int64  `json:"id"`
		Name string `json:"name"`
	} `json:"crew"`
}

type socPost struct {
	ID      int64   `json:"id"`
	Author  socUser `json:"author"`
	Content string  `json:"content"`
	Images  []struct {
		URL    string `json:"url"`
		Width  *int   `json:"width"`
		Height *int   `json:"height"`
	} `json:"images"`
	Activity *struct {
		ID           int64        `json:"id"`
		DistanceM    float64      `json:"distance_m"`
		PaceSecPerKm *int         `json:"pace_sec_per_km"`
		Track        [][2]float64 `json:"track"`
	} `json:"activity"`
	Visibility   string  `json:"visibility"`
	ReviewStatus string  `json:"review_status"`
	RejectReason *string `json:"reject_reason"`
	LikeCount    int     `json:"like_count"`
	CommentCount int     `json:"comment_count"`
	CollectCount int     `json:"collect_count"`
	ShareCount   int     `json:"share_count"`
	Liked        bool    `json:"liked"`
	Collected    bool    `json:"collected"`
	Deleted      *bool   `json:"deleted"`
}

type socComment struct {
	ID           int64        `json:"id"`
	PostID       int64        `json:"post_id"`
	Author       socUser      `json:"author"`
	Content      string       `json:"content"`
	ReplyTo      *socUser     `json:"reply_to"`
	ParentID     *int64       `json:"parent_id"`
	LikeCount    int          `json:"like_count"`
	Liked        bool         `json:"liked"`
	ReviewStatus string       `json:"review_status"`
	ReplyCount   int          `json:"reply_count"`
	Replies      []socComment `json:"replies"`
}

type page[T any] struct {
	Items      []T     `json:"items"`
	NextCursor *string `json:"next_cursor"`
}

type uploaded struct {
	ID     int64  `json:"id"`
	URL    string `json:"url"`
	Width  *int   `json:"width"`
	Height *int   `json:"height"`
}

func pngBytes(w, h int) []byte {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := 0; x < w; x++ {
		img.Set(x, x%h, color.RGBA{R: 200, A: 255})
	}
	var b bytes.Buffer
	_ = png.Encode(&b, img)
	return b.Bytes()
}

// uploadMedia posts a multipart file and returns the status and body.
func (c *client) uploadMedia(purpose string, data []byte, out any) int {
	c.e.t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	_ = mw.WriteField("purpose", purpose)
	fw, _ := mw.CreateFormFile("file", "photo.jpg")
	_, _ = fw.Write(data)
	_ = mw.Close()
	req, _ := http.NewRequest("POST", c.e.srv.URL+"/v1/media", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.e.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if out != nil {
		_ = json.Unmarshal(raw, out)
	}
	return resp.StatusCode
}

// inboxTypes lists data.type of the user's interaction notifications.
func (c *client) inboxTypes() []string {
	c.e.t.Helper()
	var res struct {
		Items []struct {
			Data map[string]any `json:"data"`
		} `json:"items"`
	}
	c.must("GET", "/v1/inbox?category=interaction&page_size=100", nil, &res)
	out := []string{}
	for _, it := range res.Items {
		if s, ok := it.Data["type"].(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func postIDs(ps []socPost) []int64 {
	out := []int64{}
	for _, p := range ps {
		out = append(out, p.ID)
	}
	return out
}

type reviewTask struct {
	ID          int64    `json:"id"`
	TargetType  string   `json:"target_type"`
	TargetID    int64    `json:"target_id"`
	Text        string   `json:"text"`
	Images      []string `json:"images"`
	RiskScore   int      `json:"risk_score"`
	RiskReasons []string `json:"risk_reasons"`
	ReportCount int      `json:"report_count"`
	Status      string   `json:"status"`
	User        *struct {
		ID int64 `json:"id"`
	} `json:"user"`
	Reviewer *struct {
		Username string `json:"username"`
	} `json:"reviewer"`
}

// task finds the pending review task of an object.
func task(t *testing.T, ad *client, typ string, id int64) reviewTask {
	t.Helper()
	var list struct {
		Items []reviewTask `json:"items"`
		Total int          `json:"total"`
	}
	ad.must("GET", "/admin/v1/reviews?status=pending&target_type="+typ+"&page_size=100", nil, &list)
	for _, it := range list.Items {
		if it.TargetID == id {
			return it
		}
	}
	t.Fatalf("no pending %s task for %d in %+v", typ, id, list.Items)
	return reviewTask{}
}

func TestSocialEndToEnd(t *testing.T) {
	t.Setenv("LOOPLAND_MEDIA_DIR", t.TempDir())
	e := newEnv(t)
	ad := adminClient(t, e)
	a, ares := e.smsLogin("13800000021")
	a.consent()
	b, bres := e.smsLogin("13800000022")
	c, cres := e.smsLogin("13800000023")
	d, _ := e.smsLogin("13800000024")
	aid, bid, cid := ares.User.ID, bres.User.ID, cres.User.ID
	// Accounts older than a day (the new-user image rule is tested by the moderation unit tests).
	e.sql(`UPDATE src.src_usr_loop_user SET create_time = now() - interval '3 days'`)

	// --- Upload.
	var img uploaded
	if st := a.uploadMedia("post", pngBytes(120, 80), &img); st != 200 || img.Width == nil || *img.Width != 120 || *img.Height != 80 {
		t.Fatalf("upload: %d %+v", st, img)
	}
	path := img.URL[strings.Index(img.URL, "/v1/media/files/"):]
	resp, err := http.Get(e.srv.URL + path)
	if err != nil || resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "image/png" {
		t.Fatalf("serve file: %v %+v", err, resp)
	}
	resp.Body.Close()
	if resp, _ := http.Get(e.srv.URL + "/v1/media/files/../config.yaml"); resp.StatusCode != 404 {
		t.Fatalf("path traversal: %d", resp.StatusCode)
	}
	var ae apiErr
	if st := a.uploadMedia("post", []byte("<html>not an image</html>"), &ae); st != 400 || ae.Error.Code != "unsupported_media" {
		t.Fatalf("sniff: %d %+v", st, ae)
	}
	if st := a.uploadMedia("banner", pngBytes(10, 10), &ae); st != 400 {
		t.Fatalf("purpose: %d", st)
	}
	if st := a.uploadMedia("post", append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, 10<<20)...), &ae); st != 413 || ae.Error.Code != "file_too_large" {
		t.Fatalf("size: %d %+v", st, ae)
	}
	b.expectErr("POST", "/v1/posts", map[string]any{"content": "偷图", "image_ids": []int64{img.ID}}, 400, "invalid_media")

	// --- Post with images and an activity; endpoints hidden.
	var act struct {
		Activity struct {
			ID     int64  `json:"id"`
			Status string `json:"status"`
		} `json:"activity"`
	}
	a.must("POST", "/v1/activities", run(3, [2]float64{0, 0}, [2]float64{600, 0}, [2]float64{600, 600}, [2]float64{0, 600}, [2]float64{0, 0}), &act)
	if act.Activity.Status != "settled" {
		t.Fatalf("activity: %+v", act)
	}
	b.expectErr("POST", "/v1/posts", map[string]any{"content": "别人的运动", "activity_id": act.Activity.ID}, 400, "invalid_activity")
	a.expectErr("POST", "/v1/posts", map[string]any{"content": "  "}, 400, "invalid_content")
	a.expectErr("POST", "/v1/posts", map[string]any{"content": "跑团", "visibility": "crew"}, 400, "not_in_crew")
	var p1 socPost
	a.must("POST", "/v1/posts", map[string]any{"content": "今天绕公园圈了一大块", "image_ids": []int64{img.ID}, "activity_id": act.Activity.ID}, &p1)
	if p1.ReviewStatus != "approved" || p1.Visibility != "public" || len(p1.Images) != 1 || p1.Activity == nil || len(p1.Activity.Track) < 4 ||
		p1.Author.ID != aid || p1.Activity.PaceSecPerKm == nil {
		t.Fatalf("post: %+v", p1)
	}
	for _, pt := range [][2]float64{p1.Activity.Track[0], p1.Activity.Track[len(p1.Activity.Track)-1]} {
		if d := geo.Haversine(origin, geo.LatLng{Lat: pt[1], Lng: pt[0]}); d < 195 {
			t.Fatalf("endpoint not hidden: %.0f m from start", d)
		}
	}
	if len(p1.Activity.Track) > 300 {
		t.Fatalf("track not simplified: %d", len(p1.Activity.Track))
	}

	// --- Follow and feeds.
	var fol map[string]bool
	b.must("POST", fmt.Sprintf("/v1/users/%d/follow", aid), nil, &fol)
	b.must("POST", fmt.Sprintf("/v1/users/%d/follow", aid), nil, &fol) // idempotent, one notification
	if !fol["following"] {
		t.Fatal(fol)
	}
	b.expectErr("POST", fmt.Sprintf("/v1/users/%d/follow", bid), nil, 400, "invalid_target")
	if n := slices.Index(a.inboxTypes(), "follow"); n < 0 || len(a.inboxTypes()) != 1 {
		t.Fatalf("follow notification: %v", a.inboxTypes())
	}
	var feed page[socPost]
	b.must("GET", "/v1/feed?tab=following", nil, &feed)
	if !slices.Contains(postIDs(feed.Items), p1.ID) || feed.NextCursor != nil {
		t.Fatalf("following feed: %+v", feed)
	}
	c.must("GET", "/v1/feed?tab=following", nil, &feed)
	if len(feed.Items) != 0 {
		t.Fatalf("c following feed: %v", postIDs(feed.Items))
	}
	c.must("GET", "/v1/feed?tab=recommend", nil, &feed)
	if !slices.Contains(postIDs(feed.Items), p1.ID) {
		t.Fatalf("recommend: %v", postIDs(feed.Items))
	}

	// Cursor paging over a's posts.
	for i := 0; i < 3; i++ {
		a.must("POST", "/v1/posts", map[string]any{"content": fmt.Sprintf("第 %d 条", i)}, nil)
	}
	var seen []int64
	cur := ""
	for {
		var pg page[socPost]
		b.must("GET", fmt.Sprintf("/v1/users/%d/posts?limit=2&cursor=%s", aid, cur), nil, &pg)
		seen = append(seen, postIDs(pg.Items)...)
		if pg.NextCursor == nil {
			break
		}
		cur = *pg.NextCursor
	}
	if len(seen) != 4 || seen[3] != p1.ID {
		t.Fatalf("paging: %v", seen)
	}
	b.expectErr("GET", "/v1/feed?tab=recommend&cursor=bad*cursor", nil, 400, "invalid_cursor")
	var rec1, rec2 page[socPost]
	c.must("GET", "/v1/feed?tab=recommend&limit=2", nil, &rec1)
	c.must("GET", "/v1/feed?tab=recommend&limit=2&cursor="+*rec1.NextCursor, nil, &rec2)
	if len(rec1.Items) != 2 || len(rec2.Items) != 2 || slices.Contains(postIDs(rec1.Items), rec2.Items[0].ID) {
		t.Fatalf("recommend paging: %v %v", postIDs(rec1.Items), postIDs(rec2.Items))
	}

	// --- Visibility.
	var fans, private socPost
	a.must("POST", "/v1/posts", map[string]any{"content": "粉丝可见", "visibility": "fans"}, &fans)
	a.must("POST", "/v1/posts", map[string]any{"content": "自己可见", "visibility": "private"}, &private)
	b.must("GET", fmt.Sprintf("/v1/posts/%d", fans.ID), nil, nil)
	c.expectErr("GET", fmt.Sprintf("/v1/posts/%d", fans.ID), nil, 404, "not_found")
	b.expectErr("GET", fmt.Sprintf("/v1/posts/%d", private.ID), nil, 404, "not_found")
	a.must("GET", fmt.Sprintf("/v1/posts/%d", private.ID), nil, nil)

	// --- Blocks.
	c.must("POST", fmt.Sprintf("/v1/users/%d/block", aid), nil, nil)
	c.expectErr("GET", fmt.Sprintf("/v1/posts/%d", p1.ID), nil, 404, "not_found")
	c.expectErr("POST", fmt.Sprintf("/v1/users/%d/follow", aid), nil, 403, "blocked")
	a.expectErr("POST", fmt.Sprintf("/v1/users/%d/follow", cid), nil, 403, "blocked")
	c.must("GET", "/v1/feed?tab=recommend", nil, &feed)
	if slices.Contains(postIDs(feed.Items), p1.ID) {
		t.Fatal("blocked author in recommend")
	}
	var rel map[string]any
	a.must("GET", fmt.Sprintf("/v1/users/%d", cid), nil, &rel)
	if r := rel["relation"].(map[string]any); r["blocked_by"] != true || r["blocked"] != false {
		t.Fatalf("relation: %v", rel)
	}
	var pg page[socPost]
	c.must("GET", fmt.Sprintf("/v1/users/%d/posts", aid), nil, &pg)
	if len(pg.Items) != 0 {
		t.Fatalf("blocked user's posts listed: %v", postIDs(pg.Items))
	}
	var blocks struct {
		Items []struct {
			User socUser `json:"user"`
		} `json:"items"`
	}
	c.must("GET", "/v1/me/blocks", nil, &blocks)
	if len(blocks.Items) != 1 || blocks.Items[0].User.ID != aid {
		t.Fatalf("blocks: %+v", blocks)
	}
	c.expectErr("POST", fmt.Sprintf("/v1/posts/%d/comments", p1.ID), map[string]any{"content": "hi"}, 403, "blocked")
	c.must("DELETE", fmt.Sprintf("/v1/users/%d/block", aid), nil, nil)
	c.must("GET", fmt.Sprintf("/v1/posts/%d", p1.ID), nil, nil)

	// --- Comments, replies, likes.
	var cm, rp1, rp2 socComment
	b.must("POST", fmt.Sprintf("/v1/posts/%d/comments", p1.ID), map[string]any{"content": "厉害"}, &cm)
	a.must("POST", fmt.Sprintf("/v1/posts/%d/comments", p1.ID), map[string]any{"content": "谢谢", "parent_id": cm.ID}, &rp1)
	c.must("POST", fmt.Sprintf("/v1/posts/%d/comments", p1.ID), map[string]any{"content": "一起跑", "parent_id": cm.ID, "reply_to_user_id": aid}, &rp2)
	if cm.ReviewStatus != "approved" || rp1.ParentID == nil || *rp1.ParentID != cm.ID || rp1.ReplyTo != nil || rp2.ReplyTo == nil || rp2.ReplyTo.ID != aid {
		t.Fatalf("comments: %+v %+v %+v", cm, rp1, rp2)
	}
	c.expectErr("POST", fmt.Sprintf("/v1/posts/%d/comments", p1.ID), map[string]any{"content": "x", "parent_id": rp1.ID}, 400, "invalid_parent")
	var cl struct {
		Liked     bool `json:"liked"`
		LikeCount int  `json:"like_count"`
	}
	c.must("POST", fmt.Sprintf("/v1/comments/%d/like", cm.ID), nil, &cl)
	if !cl.Liked || cl.LikeCount != 1 {
		t.Fatal(cl)
	}
	b.must("POST", fmt.Sprintf("/v1/posts/%d/like", p1.ID), nil, &cl)
	b.must("DELETE", fmt.Sprintf("/v1/posts/%d/like", p1.ID), nil, &cl)
	b.must("POST", fmt.Sprintf("/v1/posts/%d/like", p1.ID), nil, &cl)
	if !cl.Liked || cl.LikeCount != 1 {
		t.Fatal(cl)
	}
	var cms page[socComment]
	b.must("GET", fmt.Sprintf("/v1/posts/%d/comments", p1.ID), nil, &cms)
	if len(cms.Items) != 1 || cms.Items[0].ReplyCount != 2 || len(cms.Items[0].Replies) != 2 || cms.Items[0].LikeCount != 1 || cms.Items[0].Liked {
		t.Fatalf("comment list: %+v", cms)
	}
	var reps page[socComment]
	b.must("GET", fmt.Sprintf("/v1/comments/%d/replies?limit=1", cm.ID), nil, &reps)
	if len(reps.Items) != 1 || reps.NextCursor == nil || reps.Items[0].ID != rp1.ID {
		t.Fatalf("replies: %+v", reps)
	}
	var p1v socPost
	b.must("GET", fmt.Sprintf("/v1/posts/%d", p1.ID), nil, &p1v)
	if p1v.CommentCount != 3 || p1v.LikeCount != 1 || !p1v.Liked {
		t.Fatalf("counters: %+v", p1v)
	}
	if got := a.inboxTypes(); !slices.Contains(got, "comment") || !slices.Contains(got, "reply") || !slices.Contains(got, "like_post") ||
		len(slices.DeleteFunc(slices.Clone(got), func(s string) bool { return s != "like_post" })) != 1 {
		t.Fatalf("a notifications: %v", got)
	}
	if got := b.inboxTypes(); !slices.Contains(got, "reply") || !slices.Contains(got, "like_comment") {
		t.Fatalf("b notifications: %v", got)
	}
	// Only the comment or post author may delete.
	b.expectErr("DELETE", fmt.Sprintf("/v1/comments/%d", rp2.ID), nil, 403, "forbidden")
	a.must("DELETE", fmt.Sprintf("/v1/comments/%d", rp2.ID), nil, nil)
	b.must("GET", fmt.Sprintf("/v1/posts/%d", p1.ID), nil, &p1v)
	if p1v.CommentCount != 2 {
		t.Fatalf("after delete: %d", p1v.CommentCount)
	}
	// 5 comments per minute.
	for i := 0; i < 4; i++ {
		d.must("POST", fmt.Sprintf("/v1/posts/%d/comments", fans.ID-1), map[string]any{"content": fmt.Sprintf("刷屏 %d", i)}, nil)
	}
	d.must("POST", fmt.Sprintf("/v1/posts/%d/comments", fans.ID-1), map[string]any{"content": "第五条"}, nil)
	d.expectErr("POST", fmt.Sprintf("/v1/posts/%d/comments", fans.ID-1), map[string]any{"content": "第六条"}, 429, "rate_limited")

	// --- Moderation: settings, risky posts and comments, review decisions.
	var set map[string]any
	ad.must("PUT", "/admin/v1/moderation/settings", map[string]any{"block_words": []string{"违禁词"}, "review_words": []string{"代跑"},
		"auto_approve_below": 30, "report_auto_hide": 3}, &set)
	ad.must("GET", "/admin/v1/moderation/settings", nil, &set)
	if set["auto_approve_below"] != float64(30) || len(set["block_words"].([]any)) != 1 {
		t.Fatal(set)
	}
	b.expectErr("POST", "/v1/posts", map[string]any{"content": "这里有违禁词"}, 400, "content_blocked")
	var risky socPost
	b.must("POST", "/v1/posts", map[string]any{"content": "加我微信 wxid_abc12345 一起跑"}, &risky)
	if risky.ReviewStatus != "pending" {
		t.Fatalf("risky post: %+v", risky)
	}
	c.expectErr("GET", fmt.Sprintf("/v1/posts/%d", risky.ID), nil, 404, "not_found")
	var rc socComment
	c.must("POST", fmt.Sprintf("/v1/posts/%d/comments", p1.ID), map[string]any{"content": "可以代跑，私聊"}, &rc)
	if rc.ReviewStatus != "pending" {
		t.Fatalf("risky comment: %+v", rc)
	}
	a.must("GET", fmt.Sprintf("/v1/posts/%d/comments", p1.ID), nil, &cms)
	if len(cms.Items) != 1 {
		t.Fatalf("pending comment visible to others: %+v", cms.Items)
	}
	pt := task(t, ad, "post", risky.ID)
	if pt.RiskScore != 50 || pt.User == nil || pt.User.ID != bid || len(pt.RiskReasons) == 0 {
		t.Fatalf("post task: %+v", pt)
	}
	var stats struct {
		Pending int            `json:"pending"`
		ByType  map[string]int `json:"by_type"`
	}
	ad.must("GET", "/admin/v1/reviews/stats", nil, &stats)
	if stats.ByType["post"] != 1 || stats.ByType["comment"] != 1 {
		t.Fatalf("stats: %+v", stats)
	}
	var decided reviewTask
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/approve", pt.ID), nil, &decided)
	if decided.Status != "approved" || decided.Reviewer == nil || decided.Reviewer.Username != "root" {
		t.Fatalf("approve: %+v", decided)
	}
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/reviews/%d/reject", pt.ID), map[string]string{"reason": "x"}, 409, "already_reviewed")
	c.must("GET", fmt.Sprintf("/v1/posts/%d", risky.ID), nil, nil)
	ct := task(t, ad, "comment", rc.ID)
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/reject", ct.ID), map[string]string{"reason": "含广告"}, &decided)
	if !slices.Contains(c.inboxTypes(), "review_rejected") {
		t.Fatalf("c notifications: %v", c.inboxTypes())
	}
	b.must("GET", fmt.Sprintf("/v1/posts/%d", p1.ID), nil, &p1v)
	if p1v.CommentCount != 2 {
		t.Fatalf("rejected comment counted: %d", p1v.CommentCount)
	}

	// Nickname, bio, avatar: live at once, reviewed afterwards.
	var me struct {
		Nickname  string  `json:"nickname"`
		Bio       string  `json:"bio"`
		AvatarURL *string `json:"avatar_url"`
	}
	b.expectErr("PATCH", "/v1/me", map[string]any{"nickname": "违禁词大王"}, 400, "content_blocked")
	b.must("PATCH", "/v1/me", map[string]any{"nickname": "城西小马", "bio": "每天 5 公里"}, &me)
	if me.Nickname != "城西小马" || me.Bio != "每天 5 公里" {
		t.Fatalf("patch me: %+v", me)
	}
	var av uploaded
	if st := b.uploadMedia("avatar", pngBytes(64, 64), &av); st != 200 {
		t.Fatal(st)
	}
	b.expectErr("PATCH", "/v1/me", map[string]any{"avatar_id": img.ID}, 400, "invalid_media")
	b.expectErr("PATCH", "/v1/me", map[string]any{"avatar_url": "https://evil.example/x.jpg"}, 400, "invalid_media")
	b.must("PATCH", "/v1/me", map[string]any{"avatar_id": av.ID}, &me)
	if me.AvatarURL == nil || *me.AvatarURL != av.URL {
		t.Fatalf("avatar: %+v", me)
	}
	nt := task(t, ad, "nickname", bid)
	if nt.Text != "城西小马" {
		t.Fatalf("nickname task: %+v", nt)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/reject", nt.ID), map[string]string{"reason": "冒充他人"}, nil)
	at := task(t, ad, "avatar", bid)
	if len(at.Images) != 1 || at.Images[0] != av.URL {
		t.Fatalf("avatar task: %+v", at)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/reject", at.ID), map[string]string{"reason": "不适宜"}, nil)
	b.must("GET", "/v1/me", nil, &me)
	if me.Nickname != nickname.ForID(bid) || me.AvatarURL != nil || me.Bio != "每天 5 公里" {
		t.Fatalf("after reject: %+v", me)
	}
	if n := len(slices.DeleteFunc(b.inboxTypes(), func(s string) bool { return s != "review_rejected" })); n != 2 {
		t.Fatalf("b review_rejected: %d", n)
	}
	bt := task(t, ad, "bio", bid)
	var batch map[string]int
	ad.must("POST", "/admin/v1/reviews/batch", map[string]any{"ids": []int64{bt.ID, nt.ID}, "action": "approve"}, &batch)
	if batch["done"] != 1 {
		t.Fatalf("batch: %v", batch)
	}
	var dash map[string]any
	ad.must("GET", "/admin/v1/dashboard", nil, &dash)
	if _, ok := dash["pending_reviews"].(float64); !ok {
		t.Fatalf("dashboard: %v", dash["pending_reviews"])
	}
	if _, ok := dash["pending_reviews_wow"]; !ok {
		t.Fatal("no pending_reviews_wow")
	}

	// --- Collections and share.
	var col struct {
		Collected    bool `json:"collected"`
		CollectCount int  `json:"collect_count"`
	}
	c.must("POST", fmt.Sprintf("/v1/posts/%d/collect", p1.ID), nil, &col)
	if !col.Collected || col.CollectCount != 1 {
		t.Fatal(col)
	}
	var cols page[socPost]
	c.must("GET", "/v1/me/collections", nil, &cols)
	if len(cols.Items) != 1 || cols.Items[0].ID != p1.ID || !cols.Items[0].Collected {
		t.Fatalf("collections: %+v", cols)
	}
	var sh struct {
		ShareCount int    `json:"share_count"`
		URL        string `json:"url"`
		Poster     struct {
			Title    string  `json:"title"`
			Subtitle string  `json:"subtitle"`
			ImageURL *string `json:"image_url"`
		} `json:"poster"`
	}
	b.must("POST", fmt.Sprintf("/v1/posts/%d/share", p1.ID), map[string]string{"channel": "wechat"}, &sh)
	if sh.ShareCount != 1 || !strings.HasSuffix(sh.URL, fmt.Sprintf("/p/%d", p1.ID)) || !strings.Contains(sh.Poster.Subtitle, "km") || sh.Poster.ImageURL == nil {
		t.Fatalf("share: %+v", sh)
	}
	b.expectErr("POST", fmt.Sprintf("/v1/posts/%d/share", p1.ID), map[string]string{"channel": "qq"}, 400, "invalid_body")

	// --- Replays.
	type replay struct {
		PostID   *int64 `json:"post_id"`
		Activity struct {
			ID int64 `json:"id"`
		} `json:"activity"`
		Points []struct {
			Lng, Lat float64
			T        int `json:"t"`
		} `json:"points"`
		LikeCount int  `json:"like_count"`
		Liked     bool `json:"liked"`
	}
	var reps2 page[replay]
	b.must("GET", "/v1/replays", nil, &reps2)
	if len(reps2.Items) != 1 || *reps2.Items[0].PostID != p1.ID || len(reps2.Items[0].Points) < 4 || reps2.Items[0].Points[0].T != 0 ||
		!reps2.Items[0].Liked || reps2.Items[0].LikeCount != 1 {
		t.Fatalf("replays: %+v", reps2)
	}
	pts := reps2.Items[0].Points
	for i := 1; i < len(pts); i++ {
		if pts[i].T < pts[i-1].T {
			t.Fatal("replay time not increasing")
		}
	}
	if d := geo.Haversine(origin, geo.LatLng{Lat: pts[0].Lat, Lng: pts[0].Lng}); d < 195 {
		t.Fatalf("replay start not hidden: %.0f", d)
	}
	var one replay
	c.must("GET", fmt.Sprintf("/v1/activities/%d/replay", act.Activity.ID), nil, &one)
	if one.PostID == nil || *one.PostID != p1.ID {
		t.Fatalf("activity replay: %+v", one)
	}
	var act2 struct {
		Activity struct {
			ID int64 `json:"id"`
		} `json:"activity"`
	}
	a.must("POST", "/v1/activities", run(3, [2]float64{0, 0}, [2]float64{0, 500}), &act2)
	a.must("GET", fmt.Sprintf("/v1/activities/%d/replay", act2.Activity.ID), nil, &one)
	if one.PostID != nil {
		t.Fatalf("own replay without post: %+v", one)
	}
	b.expectErr("GET", fmt.Sprintf("/v1/activities/%d/replay", act2.Activity.ID), nil, 404, "not_found")

	// --- Profile and follow lists.
	var full struct {
		User              socUser `json:"user"`
		Bio               string  `json:"bio"`
		FollowerCount     int     `json:"follower_count"`
		FollowingCount    int     `json:"following_count"`
		LikeReceivedCount int     `json:"like_received_count"`
		TotalDistanceM    float64 `json:"total_distance_m"`
		IsSelf            bool    `json:"is_self"`
		Relation          struct {
			Following bool `json:"following"`
		} `json:"relation"`
	}
	b.must("GET", fmt.Sprintf("/v1/users/%d", aid), nil, &full)
	if full.FollowerCount != 1 || full.LikeReceivedCount != 1 || full.TotalDistanceM < 2000 || !full.Relation.Following || full.IsSelf {
		t.Fatalf("profile: %+v", full)
	}
	b.must("GET", fmt.Sprintf("/v1/users/%d", bid), nil, &full)
	if !full.IsSelf || full.FollowingCount != 1 || full.Bio != "每天 5 公里" || full.LikeReceivedCount != 1 {
		t.Fatalf("own profile: %+v", full)
	}
	var fl page[struct {
		User      socUser `json:"user"`
		Following bool    `json:"following"`
	}]
	c.must("GET", fmt.Sprintf("/v1/users/%d/followers", aid), nil, &fl)
	if len(fl.Items) != 1 || fl.Items[0].User.ID != bid || fl.Items[0].Following {
		t.Fatalf("followers: %+v", fl)
	}
	b.must("GET", fmt.Sprintf("/v1/users/%d/following", bid), nil, &fl)
	if len(fl.Items) != 1 || fl.Items[0].User.ID != aid || !fl.Items[0].Following {
		t.Fatalf("following: %+v", fl)
	}

	// --- Crew: invites, crew-only posts, name review.
	var cr struct {
		ID   int64  `json:"id"`
		Name string `json:"name"`
	}
	a.must("POST", "/v1/crews", map[string]any{"name": "城西跑团", "district": "徐汇区", "join_mode": "invite"}, &cr)
	b.expectErr("POST", fmt.Sprintf("/v1/crews/%d/invites", cr.ID), nil, 403, "not_leader")
	var inv struct {
		Code      string `json:"code"`
		ExpiresAt string `json:"expires_at"`
	}
	a.must("POST", fmt.Sprintf("/v1/crews/%d/invites", cr.ID), nil, &inv)
	if len(inv.Code) != 6 || inv.ExpiresAt == "" {
		t.Fatal(inv)
	}
	b.expectErr("POST", "/v1/crews/join-by-code", map[string]string{"code": "ZZZZZZ"}, 400, "invalid_invite")
	var joined map[string]any
	b.must("POST", "/v1/crews/join-by-code", map[string]string{"code": strings.ToLower(inv.Code)}, &joined)
	if joined["status"] != "joined" || joined["crew_id"] != float64(cr.ID) {
		t.Fatal(joined)
	}
	var crewPost socPost
	a.must("POST", "/v1/posts", map[string]any{"content": "团内通知", "visibility": "crew"}, &crewPost)
	b.must("GET", fmt.Sprintf("/v1/posts/%d", crewPost.ID), nil, nil)
	c.expectErr("GET", fmt.Sprintf("/v1/posts/%d", crewPost.ID), nil, 404, "not_found")
	b.expectErr("PATCH", fmt.Sprintf("/v1/crews/%d", cr.ID), map[string]any{"name": "改名"}, 403, "not_leader")
	var crAv uploaded
	a.uploadMedia("crew_avatar", pngBytes(32, 32), &crAv)
	a.must("PATCH", fmt.Sprintf("/v1/crews/%d", cr.ID), map[string]any{"name": "城西夜跑团", "avatar_id": crAv.ID, "join_mode": "open"}, &cr)
	if cr.Name != "城西夜跑团" {
		t.Fatal(cr)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/reject", task(t, ad, "crew_name", cr.ID).ID), map[string]string{"reason": "不合规"}, nil)
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/reject", task(t, ad, "crew_avatar", cr.ID).ID), map[string]string{"reason": "不合规"}, nil)
	var crew struct {
		Name      string  `json:"name"`
		AvatarURL *string `json:"avatar_url"`
	}
	a.must("GET", fmt.Sprintf("/v1/crews/%d", cr.ID), nil, &crew)
	if crew.Name != fmt.Sprintf("跑团%d", cr.ID) || crew.AvatarURL != nil {
		t.Fatalf("crew after reject: %+v", crew)
	}

	// --- Reports: 3 distinct users take a post back to review.
	var target socPost
	a.must("POST", "/v1/posts", map[string]any{"content": "被举报的动态"}, &target)
	var rid1, rid2 map[string]int64
	b.must("POST", "/v1/reports", map[string]any{"target_type": "post", "target_id": target.ID, "reason": "spam"}, &rid1)
	b.must("POST", "/v1/reports", map[string]any{"target_type": "post", "target_id": target.ID, "reason": "abuse"}, &rid2)
	if rid1["id"] == 0 || rid1["id"] != rid2["id"] {
		t.Fatalf("duplicate report: %v %v", rid1, rid2)
	}
	a.expectErr("POST", "/v1/reports", map[string]any{"target_type": "post", "target_id": target.ID, "reason": "spam"}, 400, "invalid_target")
	c.must("POST", "/v1/reports", map[string]any{"target_type": "post", "target_id": target.ID, "reason": "spam", "detail": "广告"}, nil)
	c.must("GET", fmt.Sprintf("/v1/posts/%d", target.ID), nil, nil) // 2 reports: still visible
	d.must("POST", "/v1/reports", map[string]any{"target_type": "post", "target_id": target.ID, "reason": "fraud"}, nil)
	c.expectErr("GET", fmt.Sprintf("/v1/posts/%d", target.ID), nil, 404, "not_found")
	var mine socPost
	a.must("GET", fmt.Sprintf("/v1/posts/%d", target.ID), nil, &mine)
	if mine.ReviewStatus != "pending" {
		t.Fatalf("reported post: %+v", mine)
	}
	if rt := task(t, ad, "post", target.ID); rt.ReportCount != 3 {
		t.Fatalf("report task: %+v", rt)
	}
	d.must("POST", "/v1/reports", map[string]any{"target_type": "user", "target_id": aid, "reason": "abuse"}, nil)
	var reports struct {
		Items []struct {
			ID            int64   `json:"id"`
			TargetType    string  `json:"target_type"`
			TargetID      int64   `json:"target_id"`
			TargetPreview string  `json:"target_preview"`
			ReportCount   int     `json:"report_count"`
			Detail        *string `json:"detail"`
		} `json:"items"`
		Total int `json:"total"`
	}
	ad.must("GET", "/admin/v1/reports?status=pending&target_type=post", nil, &reports)
	if reports.Total != 3 || reports.Items[0].ReportCount != 3 || reports.Items[0].TargetPreview != "被举报的动态" {
		t.Fatalf("reports: %+v", reports)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/reports/%d/handle", reports.Items[0].ID), map[string]any{"action": "remove", "mute_days": 1, "note": "广告"}, nil)
	ad.must("GET", "/admin/v1/reports?status=handled", nil, &reports)
	if reports.Total != 3 {
		t.Fatalf("handled: %+v", reports)
	}
	a.expectErr("GET", fmt.Sprintf("/v1/posts/%d", target.ID), nil, 404, "not_found")
	a.expectErr("POST", "/v1/posts", map[string]any{"content": "禁言中"}, 403, "muted")
	a.expectErr("POST", fmt.Sprintf("/v1/posts/%d/comments", p1.ID), map[string]any{"content": "禁言中"}, 403, "muted")
	ad.must("GET", "/admin/v1/reports?status=pending&target_type=user", nil, &reports)
	ad.must("POST", fmt.Sprintf("/admin/v1/reports/%d/handle", reports.Items[0].ID), map[string]any{"action": "dismiss"}, nil)
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/reports/%d/handle", reports.Items[0].ID), map[string]any{"action": "dismiss"}, 409, "already_handled")

	// --- Admin post management.
	var aposts struct {
		Items []socPost `json:"items"`
		Total int       `json:"total"`
	}
	ad.must("GET", fmt.Sprintf("/admin/v1/posts?user_id=%d", aid), nil, &aposts)
	deleted := 0
	for _, p := range aposts.Items {
		if p.Deleted == nil {
			t.Fatal("deleted flag missing")
		}
		if *p.Deleted {
			deleted++
		}
	}
	if aposts.Total != 8 || deleted != 1 {
		t.Fatalf("admin posts: total %d deleted %d", aposts.Total, deleted)
	}
	ad.must("DELETE", fmt.Sprintf("/admin/v1/posts/%d", fans.ID), map[string]string{"reason": "测试下架"}, nil)
	b.expectErr("GET", fmt.Sprintf("/v1/posts/%d", fans.ID), nil, 404, "not_found")
	ad.must("GET", "/admin/v1/posts?q=微信", nil, &aposts)
	if aposts.Total != 1 || aposts.Items[0].ID != risky.ID {
		t.Fatalf("admin search: %+v", aposts)
	}

	// Author deletes their own post; others cannot.
	b.expectErr("DELETE", fmt.Sprintf("/v1/posts/%d", p1.ID), nil, 404, "not_found")
	a.must("DELETE", fmt.Sprintf("/v1/posts/%d", private.ID), nil, nil)

	// Reviewer role: queue yes, settings no.
	ad.must("POST", "/admin/v1/admins", map[string]string{"username": "rev", "password": "reviewer-pass-123", "role": "reviewer"}, nil)
	rv := e.anon()
	var login struct {
		Token string `json:"token"`
	}
	rv.must("POST", "/admin/v1/login", map[string]string{"username": "rev", "password": "reviewer-pass-123"}, &login)
	rv.token = login.Token
	rv.must("GET", "/admin/v1/reviews", nil, nil)
	rv.expectErr("GET", "/admin/v1/moderation/settings", nil, 403, "forbidden")
}
