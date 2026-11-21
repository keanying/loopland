package app

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/keanying/loopland/server/internal/moderation"
)

// ---------------------------------------------------------------- helpers

func (e *env) member(phone string) (*client, int64) {
	c, res := e.smsLogin(phone)
	c.consent()
	return c, res.User.ID
}

func (e *env) block(user, target int64) {
	e.sql(`INSERT INTO src.src_soc_loop_block (user_id, blocked_user_id) VALUES ($1,$2)`, user, target)
}

func (e *env) follow(user, target int64) {
	e.sql(`INSERT INTO src.src_soc_loop_follow (follower_id, followee_id) VALUES ($1,$2)`, user, target)
}

// upload runs the waypoints with this user's own device (so several test
// accounts don't trip the multi-account rule) and returns the settlement.
func (c *client) upload(device string, wearable bool, wps ...[2]float64) commSettlement {
	c.e.t.Helper()
	body := run(3, wps...)
	body["device"] = map[string]any{"id": device, "model": "test", "os": "test"}
	if wearable {
		body["wearable"] = map[string]string{"brand": "apple"}
	}
	var res struct {
		Activity struct {
			ID        int64   `json:"id"`
			DistanceM float64 `json:"distance_m"`
			DurationS int     `json:"duration_s"`
		} `json:"activity"`
		Settlement commSettlement `json:"settlement"`
	}
	c.must("POST", "/v1/activities", body, &res)
	res.Settlement.activityID, res.Settlement.distanceM, res.Settlement.durationS = res.Activity.ID, res.Activity.DistanceM, res.Activity.DurationS
	return res.Settlement
}

type commSettlement struct {
	Status     string `json:"status"`
	EnergyRaw  int    `json:"energy_raw"`
	BossDamage []struct {
		BossID int64 `json:"boss_id"`
		Damage int   `json:"damage"`
	} `json:"boss_damage"`
	Rally *struct {
		ID        int64   `json:"id"`
		BonusRate float64 `json:"bonus_rate"`
	} `json:"rally"`
	Races []struct {
		ID        int64  `json:"id"`
		Title     string `json:"title"`
		ResultSec int    `json:"result_sec"`
		Medal     struct {
			Key  string `json:"key"`
			Name string `json:"name"`
		} `json:"medal"`
	} `json:"races"`

	activityID int64
	distanceM  float64
	durationS  int
}

type convView struct {
	ID          int64  `json:"id"`
	Type        string `json:"type"`
	Title       string `json:"title"`
	UnreadCount int    `json:"unread_count"`
	Muted       bool   `json:"muted"`
	Peer        *struct {
		ID       int64  `json:"id"`
		Nickname string `json:"nickname"`
	} `json:"peer"`
	Ref *struct {
		Type string `json:"type"`
		ID   int64  `json:"id"`
	} `json:"ref"`
	LastMessage *msgView `json:"last_message"`
}

type msgView struct {
	ID             int64           `json:"id"`
	ConversationID int64           `json:"conversation_id"`
	Type           string          `json:"type"`
	Content        string          `json:"content"`
	Payload        json.RawMessage `json:"payload"`
	Sender         *struct {
		ID int64 `json:"id"`
	} `json:"sender"`
}

type cursorList[T any] struct {
	Items      []T     `json:"items"`
	NextCursor *string `json:"next_cursor"`
}

func (c *client) convs() []convView {
	c.e.t.Helper()
	var l cursorList[convView]
	c.must("GET", "/v1/conversations", nil, &l)
	return l.Items
}

func (c *client) summary() map[string]int {
	c.e.t.Helper()
	var m map[string]int
	c.must("GET", "/v1/inbox/summary", nil, &m)
	return m
}

func (c *client) say(conv int64, text string) msgView {
	c.e.t.Helper()
	var m msgView
	c.must("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv), map[string]any{"type": "text", "content": text}, &m)
	return m
}

func (c *client) notifications(category string) []struct {
	Title string         `json:"title"`
	Data  map[string]any `json:"data"`
} {
	c.e.t.Helper()
	var l struct {
		Items []struct {
			Title string         `json:"title"`
			Data  map[string]any `json:"data"`
		} `json:"items"`
	}
	c.must("GET", "/v1/inbox?category="+category, nil, &l)
	return l.Items
}

func hasNotice(items []struct {
	Title string         `json:"title"`
	Data  map[string]any `json:"data"`
}, typ string) bool {
	for _, it := range items {
		if it.Data["type"] == typ {
			return true
		}
	}
	return false
}

// readEvent waits for a WebSocket event of the given type.
func readEvent(t *testing.T, ctx context.Context, ws *websocket.Conn, typ string) map[string]json.RawMessage {
	t.Helper()
	for {
		_, raw, err := ws.Read(ctx)
		if err != nil {
			t.Fatalf("no %s event over websocket: %v", typ, err)
		}
		var m map[string]json.RawMessage
		_ = json.Unmarshal(raw, &m)
		if string(m["type"]) == `"`+typ+`"` {
			return m
		}
	}
}

// ---------------------------------------------------------------- chat

func TestCommunityChat(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	a, aid := e.member("13800000101")
	b, bid := e.member("13800000102")
	c, cid := e.member("13800000103")

	// B listens over WebSocket.
	wsURL := strings.Replace(e.srv.URL, "http", "ws", 1) + "/v1/ws?token=" + b.token
	wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(wctx, wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	time.Sleep(200 * time.Millisecond)

	a.expectErr("POST", "/v1/conversations/direct", map[string]int64{"user_id": aid}, 400, "invalid_target")
	var conv convView
	a.must("POST", "/v1/conversations/direct", map[string]int64{"user_id": bid}, &conv)
	if conv.Type != "direct" || conv.Peer == nil || conv.Peer.ID != bid || conv.Title != conv.Peer.Nickname || conv.Ref != nil {
		t.Fatalf("direct: %+v", conv)
	}
	var again convView
	a.must("POST", "/v1/conversations/direct", map[string]int64{"user_id": bid}, &again)
	if again.ID != conv.ID {
		t.Fatal("direct conversation must be reused")
	}
	if len(b.convs()) != 0 {
		t.Fatal("peer sees an empty conversation before the first message")
	}

	// Stranger limit: B doesn't follow A and hasn't replied.
	m1 := a.say(conv.ID, "你好")
	ev := readEvent(t, wctx, ws, "chat_message")
	var evMsg msgView
	json.Unmarshal(ev["message"], &evMsg)
	if evMsg.ID != m1.ID || evMsg.Content != "你好" || evMsg.Sender == nil || evMsg.Sender.ID != aid {
		t.Fatalf("ws chat_message: %s", ev["message"])
	}
	a.say(conv.ID, "在吗")
	a.say(conv.ID, "周六一起跑？")
	a.expectErr("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "text", "content": "？"}, 403, "stranger_limit")
	bc := b.convs()
	if len(bc) != 1 || bc[0].UnreadCount != 3 || bc[0].LastMessage == nil || bc[0].LastMessage.Content != "周六一起跑？" || bc[0].Peer.ID != aid {
		t.Fatalf("B's conversations: %+v", bc)
	}
	if s := b.summary(); s["chat"] != 3 || s["interaction"] != 0 {
		t.Fatalf("summary: %v", s)
	}
	reply := b.say(conv.ID, "好呀")
	a.say(conv.ID, "七点见") // B replied: no more limit
	b.must("POST", fmt.Sprintf("/v1/conversations/%d/read", conv.ID), map[string]int64{"message_id": reply.ID + 100}, nil)
	if s := b.summary(); s["chat"] != 0 {
		t.Fatalf("read all: %v", s)
	}
	// A sees B's read receipt? A is not on WebSocket; B gets its own read event.
	rd := readEvent(t, wctx, ws, "conversation_read")
	if string(rd["conversation_id"]) != fmt.Sprint(conv.ID) || string(rd["user_id"]) != fmt.Sprint(bid) {
		t.Fatalf("conversation_read: %v", rd)
	}

	// History, newest first, paged by before=.
	var hist cursorList[msgView]
	a.must("GET", fmt.Sprintf("/v1/conversations/%d/messages?limit=2", conv.ID), nil, &hist)
	if len(hist.Items) != 2 || hist.Items[0].Content != "七点见" || hist.NextCursor == nil {
		t.Fatalf("history: %+v", hist)
	}
	a.must("GET", fmt.Sprintf("/v1/conversations/%d/messages?before=%s&limit=10", conv.ID, *hist.NextCursor), nil, &hist)
	if len(hist.Items) != 3 || hist.Items[2].Content != "你好" || hist.NextCursor != nil {
		t.Fatalf("older history: %+v", hist)
	}
	c.expectErr("GET", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), nil, 403, "not_member")

	// Content rules: block words and review words are rejected, contacts pass.
	if _, err := e.app.Moderation.SaveSettings(ctx, moderation.Settings{BlockWords: []string{"违禁词"}, ReviewWords: []string{"审核词"},
		AutoApproveBelow: 30, ReportAutoHide: 3}); err != nil {
		t.Fatal(err)
	}
	a.expectErr("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "text", "content": "这是违禁词"}, 400, "content_blocked")
	a.expectErr("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "text", "content": "有个审核词"}, 400, "content_blocked")
	a.say(conv.ID, "电话 13912345678")
	a.expectErr("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "text", "content": "  "}, 400, "invalid_body")

	// Images must be the sender's own uploads.
	var imgID, otherImg int64
	e.app.Pool.QueryRow(ctx, `INSERT INTO src.src_cnt_loop_media (user_id, purpose_type, storage_type, object_key, url, content_type, size_byte_qty, width_px, height_px)
		VALUES ($1,'chat','local','chat/a.jpg','https://cdn.test/chat/a.jpg','image/jpeg',100,640,480) RETURNING id`, aid).Scan(&imgID)
	e.app.Pool.QueryRow(ctx, `INSERT INTO src.src_cnt_loop_media (user_id, purpose_type, storage_type, object_key, url, content_type, size_byte_qty)
		VALUES ($1,'chat','local','chat/c.jpg','https://cdn.test/chat/c.jpg','image/jpeg',100) RETURNING id`, cid).Scan(&otherImg)
	var im msgView
	a.must("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "image", "image_id": imgID}, &im)
	var payload struct {
		URL   string `json:"url"`
		Width int    `json:"width"`
	}
	json.Unmarshal(im.Payload, &payload)
	if im.Type != "image" || payload.URL != "https://cdn.test/chat/a.jpg" || payload.Width != 640 {
		t.Fatalf("image message: %+v %s", im, im.Payload)
	}
	a.expectErr("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "image", "image_id": otherImg}, 400, "invalid_media")
	// Sharing a post.
	var postID int64
	e.app.Pool.QueryRow(ctx, `INSERT INTO src.src_soc_loop_post (user_id, content_text) VALUES ($1, '今天跑了 5 公里') RETURNING id`, cid).Scan(&postID)
	var pm msgView
	a.must("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "post", "post_id": postID}, &pm)
	if pm.Type != "post" || string(pm.Payload) != fmt.Sprintf(`{"post_id":%d}`, postID) {
		t.Fatalf("post message: %+v %s", pm, pm.Payload)
	}
	a.expectErr("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "post", "post_id": postID + 99}, 404, "not_found")
	a.expectErr("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "system", "content": "x"}, 400, "invalid_body")

	// Mute keeps the per-conversation count out of the total.
	if s := b.summary(); s["chat"] != 3 {
		t.Fatalf("unread before mute: %v", s)
	}
	b.must("POST", fmt.Sprintf("/v1/conversations/%d/mute", conv.ID), map[string]bool{"muted": true}, nil)
	if s := b.summary(); s["chat"] != 0 {
		t.Fatalf("muted conversation counts: %v", s)
	}
	if bc := b.convs(); !bc[0].Muted || bc[0].UnreadCount != 3 {
		t.Fatalf("muted conv: %+v", bc[0])
	}

	// Rate limit: 30 a minute.
	e.app.Redis.Set(ctx, fmt.Sprintf("chat:rate:%d:%d", aid, time.Now().Unix()/60), 30, time.Minute)
	a.expectErr("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "text", "content": "刷屏"}, 429, "rate_limited")
	e.app.Redis.Del(ctx, fmt.Sprintf("chat:rate:%d:%d", aid, time.Now().Unix()/60))

	// Deleting a direct chat hides it until the next message.
	b.must("DELETE", fmt.Sprintf("/v1/conversations/%d", conv.ID), nil, nil)
	if len(b.convs()) != 0 {
		t.Fatal("deleted conversation still listed")
	}
	a.say(conv.ID, "还在吗")
	if bc := b.convs(); len(bc) != 1 || bc[0].UnreadCount != 1 {
		t.Fatalf("conversation back after new message: %+v", bc)
	}

	// Following lifts the stranger limit.
	var ac convView
	c.must("POST", "/v1/conversations/direct", map[string]int64{"user_id": aid}, &ac)
	e.follow(aid, cid)
	for i := 0; i < 4; i++ {
		c.say(ac.ID, fmt.Sprintf("第 %d 条", i+1))
	}

	// Blocks stop both opening and sending.
	e.block(bid, aid)
	a.expectErr("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "text", "content": "hi"}, 403, "blocked")
	b.expectErr("POST", fmt.Sprintf("/v1/conversations/%d/messages", conv.ID), map[string]any{"type": "text", "content": "hi"}, 403, "blocked")
	a.expectErr("POST", "/v1/conversations/direct", map[string]int64{"user_id": bid}, 403, "blocked")

	// Muted accounts can't send.
	e.sql(`UPDATE src.src_usr_loop_user SET mute_end_time=now() + interval '1 day' WHERE id=$1`, cid)
	c.expectErr("POST", fmt.Sprintf("/v1/conversations/%d/messages", ac.ID), map[string]any{"type": "text", "content": "hi"}, 403, "muted")
}

// ---------------------------------------------------------------- meetups

type meetupView struct {
	ID             int64    `json:"id"`
	Title          string   `json:"title"`
	Status         string   `json:"status"`
	ReviewStatus   string   `json:"review_status"`
	JoinedCount    int      `json:"joined_count"`
	Joined         bool     `json:"joined"`
	ConversationID *int64   `json:"conversation_id"`
	DistanceM      *float64 `json:"distance_m"`
	District       *string  `json:"district"`
	Place          struct {
		Name string  `json:"name"`
		Lat  float64 `json:"lat"`
		Lng  float64 `json:"lng"`
	} `json:"place"`
	Creator struct {
		ID int64 `json:"id"`
	} `json:"creator"`
	Members []struct {
		ID int64 `json:"id"`
	} `json:"members"`
}

func meetupBody(title string, x, y float64, capacity int) map[string]any {
	p := at(x, y)
	start := time.Now().Add(3 * time.Hour)
	return map[string]any{"type": "run", "title": title, "description": "配速 6 分左右", "start_time": start, "end_time": start.Add(2 * time.Hour),
		"place": map[string]any{"name": "世纪公园 3 号门", "lat": p.Lat, "lng": p.Lng}, "capacity": capacity, "requirement": "配速 5'30\"–6'30\"",
		"district": "黄浦区"}
}

func TestCommunityMeetups(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	ad := adminClient(t, e)
	a, aid := e.member("13800000201")
	b, bid := e.member("13800000202")
	c, _ := e.member("13800000203")

	// Validation.
	bad := meetupBody("太早", 0, 0, 5)
	bad["start_time"] = time.Now().Add(30 * time.Minute)
	a.expectErr("POST", "/v1/meetups", bad, 400, "invalid_body")
	bad = meetupBody("人数", 0, 0, 1)
	a.expectErr("POST", "/v1/meetups", bad, 400, "invalid_body")
	bad = meetupBody("太长", 0, 0, 5)
	bad["end_time"] = bad["start_time"].(time.Time).Add(13 * time.Hour)
	a.expectErr("POST", "/v1/meetups", bad, 400, "invalid_body")
	bad = meetupBody(strings.Repeat("长", 31), 0, 0, 5)
	a.expectErr("POST", "/v1/meetups", bad, 400, "invalid_body")

	// Three meetups at 2 km, 500 m and 20 km.
	var far2, near, farAway meetupView
	a.must("POST", "/v1/meetups", meetupBody("两公里外", 2000, 0, 2), &far2)
	a.must("POST", "/v1/meetups", meetupBody("五百米", 500, 0, 10), &near)
	a.must("POST", "/v1/meetups", meetupBody("二十公里", 20000, 0, 10), &farAway)
	if !near.Joined || near.JoinedCount != 1 || near.Status != "open" || near.ReviewStatus != "approved" || near.ConversationID == nil ||
		near.Creator.ID != aid || len(near.Members) != 1 || near.District == nil || *near.District != "黄浦区" {
		t.Fatalf("created meetup: %+v", near)
	}
	var list cursorList[meetupView]
	b.must("GET", fmt.Sprintf("/v1/meetups?lat=%f&lng=%f&radius_m=10000", origin.Lat, origin.Lng), nil, &list)
	if len(list.Items) != 2 || list.Items[0].ID != near.ID || list.Items[1].ID != far2.ID || list.Items[0].DistanceM == nil ||
		*list.Items[0].DistanceM < 450 || *list.Items[0].DistanceM > 550 {
		t.Fatalf("nearby: %+v", list.Items)
	}
	b.must("GET", "/v1/meetups?limit=2", nil, &list)
	if len(list.Items) != 2 || list.NextCursor == nil || list.Items[0].DistanceM != nil {
		t.Fatalf("by time: %+v", list)
	}
	b.must("GET", "/v1/meetups?limit=2&cursor="+*list.NextCursor, nil, &list)
	if len(list.Items) != 1 || list.NextCursor != nil {
		t.Fatalf("page 2: %+v", list)
	}

	// Joining puts B in the group chat; capacity 2 is then full.
	var m meetupView
	b.must("POST", fmt.Sprintf("/v1/meetups/%d/join", far2.ID), nil, &m)
	if !m.Joined || m.JoinedCount != 2 || m.Status != "full" {
		t.Fatalf("joined: %+v", m)
	}
	c.expectErr("POST", fmt.Sprintf("/v1/meetups/%d/join", far2.ID), nil, 409, "meetup_full")
	var group convView
	for _, cv := range b.convs() {
		if cv.Type == "group" {
			group = cv
		}
	}
	if group.ID != *far2.ConversationID || group.Ref == nil || group.Ref.Type != "meetup" || group.Ref.ID != far2.ID || group.Title != "两公里外" ||
		group.Peer != nil || group.LastMessage == nil || group.LastMessage.Type != "system" || group.LastMessage.Sender != nil {
		t.Fatalf("group chat: %+v", group)
	}
	b.say(group.ID, "几点集合？")
	if ac := a.convs(); len(ac) != 3 {
		t.Fatalf("A is in the three meetup chats: %+v", ac)
	}
	// Leaving the meetup leaves the chat; deleting the chat leaves the meetup.
	b.must("POST", fmt.Sprintf("/v1/meetups/%d/leave", far2.ID), nil, &m)
	if m.Joined || m.JoinedCount != 1 || m.Status != "open" {
		t.Fatalf("left: %+v", m)
	}
	b.expectErr("GET", fmt.Sprintf("/v1/conversations/%d/messages", group.ID), nil, 403, "not_member")
	a.expectErr("POST", fmt.Sprintf("/v1/meetups/%d/leave", far2.ID), nil, 409, "creator_cannot_leave")
	c.must("POST", fmt.Sprintf("/v1/meetups/%d/join", near.ID), nil, nil)
	c.must("DELETE", fmt.Sprintf("/v1/conversations/%d", *near.ConversationID), nil, nil)
	c.must("GET", fmt.Sprintf("/v1/meetups/%d", near.ID), nil, &m)
	if m.Joined || m.JoinedCount != 1 {
		t.Fatalf("deleting the group chat leaves the meetup: %+v", m)
	}
	var hist cursorList[msgView]
	a.must("GET", fmt.Sprintf("/v1/conversations/%d/messages", *near.ConversationID), nil, &hist)
	if len(hist.Items) != 2 || !strings.Contains(hist.Items[0].Content, "退出") || !strings.Contains(hist.Items[1].Content, "加入") {
		t.Fatalf("system messages: %+v", hist.Items)
	}

	// My meetups.
	var mine struct {
		Items []meetupView `json:"items"`
	}
	b.must("POST", fmt.Sprintf("/v1/meetups/%d/join", near.ID), nil, nil)
	b.must("GET", "/v1/me/meetups", nil, &mine)
	if len(mine.Items) != 1 || mine.Items[0].ID != near.ID {
		t.Fatalf("my meetups: %+v", mine)
	}

	// Cancel notifies the sign-ups.
	b.expectErr("POST", fmt.Sprintf("/v1/meetups/%d/cancel", near.ID), nil, 403, "not_creator")
	a.must("POST", fmt.Sprintf("/v1/meetups/%d/cancel", near.ID), nil, &m)
	if m.Status != "cancelled" {
		t.Fatalf("cancelled: %+v", m)
	}
	if !hasNotice(b.notifications("interaction"), "meetup_cancelled") {
		t.Fatal("B was not told about the cancellation")
	}
	c.expectErr("POST", fmt.Sprintf("/v1/meetups/%d/join", near.ID), nil, 409, "meetup_closed")

	// Started and ended.
	e.sql(`UPDATE src.src_soc_loop_meetup SET start_time=now() - interval '10 minutes', end_time=now() + interval '1 hour' WHERE id=$1`, farAway.ID)
	c.expectErr("POST", fmt.Sprintf("/v1/meetups/%d/join", farAway.ID), nil, 409, "meetup_started")
	e.sql(`UPDATE src.src_soc_loop_meetup SET start_time=now() - interval '3 hours', end_time=now() - interval '1 hour' WHERE id=$1`, farAway.ID)
	a.must("GET", fmt.Sprintf("/v1/meetups/%d", farAway.ID), nil, &m)
	if m.Status != "ended" {
		t.Fatalf("ended: %+v", m)
	}
	if err := e.app.Jobs.Extra["community_end"](ctx); err != nil {
		t.Fatal(err)
	}
	var st string
	e.app.Pool.QueryRow(ctx, `SELECT meetup_status FROM src.src_soc_loop_meetup WHERE id=$1`, farAway.ID).Scan(&st)
	if st != "ended" {
		t.Fatalf("job: %s", st)
	}

	// Moderation: contact details wait for review, blocked words are refused.
	if _, err := e.app.Moderation.SaveSettings(ctx, moderation.Settings{BlockWords: []string{"违禁词"}, ReviewWords: []string{},
		AutoApproveBelow: 30, ReportAutoHide: 3}); err != nil {
		t.Fatal(err)
	}
	a.expectErr("POST", "/v1/meetups", meetupBody("违禁词约跑", 100, 0, 5), 400, "content_blocked")
	var pend, pend2 meetupView
	body := meetupBody("加微信 vx123456 约跑", 100, 0, 5)
	a.must("POST", "/v1/meetups", body, &pend)
	a.must("POST", "/v1/meetups", meetupBody("电话 13912345678", 100, 0, 5), &pend2)
	if pend.ReviewStatus != "pending" || pend2.ReviewStatus != "pending" {
		t.Fatalf("pending: %+v", pend)
	}
	b.expectErr("GET", fmt.Sprintf("/v1/meetups/%d", pend.ID), nil, 404, "not_found")
	b.expectErr("POST", fmt.Sprintf("/v1/meetups/%d/join", pend.ID), nil, 404, "not_found")
	task := func(id int64) int64 {
		var tid int64
		if err := e.app.Pool.QueryRow(ctx, `SELECT id FROM src.src_cnt_loop_review_task WHERE target_type='meetup' AND target_id=$1 AND review_status='pending'`, id).Scan(&tid); err != nil {
			t.Fatal(err)
		}
		return tid
	}
	if err := e.app.Moderation.Decide(ctx, task(pend.ID), 1, true, ""); err != nil {
		t.Fatal(err)
	}
	b.must("GET", fmt.Sprintf("/v1/meetups/%d", pend.ID), nil, &m)
	if m.ReviewStatus != "approved" {
		t.Fatalf("approved: %+v", m)
	}
	if err := e.app.Moderation.Decide(ctx, task(pend2.ID), 1, false, "含联系方式"); err != nil {
		t.Fatal(err)
	}
	a.must("GET", fmt.Sprintf("/v1/meetups/%d", pend2.ID), nil, &m)
	if m.ReviewStatus != "rejected" || m.Status != "cancelled" || !hasNotice(a.notifications("interaction"), "review_rejected") {
		t.Fatalf("rejected: %+v", m)
	}

	// Admin list and cancel.
	var al struct {
		Items []meetupView `json:"items"`
		Total int          `json:"total"`
	}
	ad.must("GET", "/admin/v1/meetups", nil, &al)
	if al.Total != 5 || len(al.Items) != 5 {
		t.Fatalf("admin meetups: %d", al.Total)
	}
	ad.must("GET", "/admin/v1/meetups?status=cancelled", nil, &al)
	if al.Total != 2 {
		t.Fatalf("admin cancelled: %d", al.Total)
	}
	b.must("POST", fmt.Sprintf("/v1/meetups/%d/join", pend.ID), nil, nil)
	ad.must("POST", fmt.Sprintf("/admin/v1/meetups/%d/cancel", pend.ID), map[string]string{"reason": "场地封闭"}, &m)
	if m.Status != "cancelled" {
		t.Fatalf("admin cancel: %+v", m)
	}
	if n := len(b.notifications("interaction")); n != 2 {
		t.Fatalf("B notices: %d", n)
	}
	_ = bid
}

// ---------------------------------------------------------------- rallies

type rallyView struct {
	ID             int64  `json:"id"`
	Status         string `json:"status"`
	JoinedCount    int    `json:"joined_count"`
	CheckedInCount int    `json:"checked_in_count"`
	Joined         bool   `json:"joined"`
	CheckedIn      bool   `json:"checked_in"`
	BonusActive    bool   `json:"bonus_active"`
	ConversationID *int64 `json:"conversation_id"`
	Crew           struct {
		ID   int64  `json:"id"`
		Name string `json:"name"`
	} `json:"crew"`
}

func TestCommunityRally(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	ad := adminClient(t, e)
	a, _ := e.member("13800000301")
	b, bid := e.member("13800000302")
	c, _ := e.member("13800000303")
	d, _ := e.member("13800000304")
	var crew struct {
		ID int64 `json:"id"`
	}
	a.must("POST", "/v1/crews", map[string]any{"name": "集结跑团", "district": "黄浦区", "join_mode": "open"}, &crew)
	b.must("POST", fmt.Sprintf("/v1/crews/%d/join", crew.ID), nil, nil)
	c.must("POST", fmt.Sprintf("/v1/crews/%d/join", crew.ID), nil, nil)

	p := at(100, 0)
	body := func(title string, start time.Time) map[string]any {
		return map[string]any{"title": title, "start_time": start, "place": map[string]any{"name": "人民广场", "lat": p.Lat, "lng": p.Lng}, "distance_goal_m": 5000}
	}
	b.expectErr("POST", fmt.Sprintf("/v1/crews/%d/rallies", crew.ID), body("夜跑", time.Now().Add(10*time.Minute)), 403, "not_leader")
	var r, later rallyView
	a.must("POST", fmt.Sprintf("/v1/crews/%d/rallies", crew.ID), body("周三夜跑", time.Now().Add(10*time.Minute)), &r)
	a.must("POST", fmt.Sprintf("/v1/crews/%d/rallies", crew.ID), body("周末长距离", time.Now().Add(5*time.Hour)), &later)
	if r.Status != "open" || !r.Joined || r.JoinedCount != 1 || r.Crew.ID != crew.ID || r.Crew.Name != "集结跑团" || r.ConversationID == nil || r.BonusActive {
		t.Fatalf("rally: %+v", r)
	}
	if !hasNotice(b.notifications("interaction"), "rally_created") {
		t.Fatal("members are told about the rally")
	}
	a.must("POST", fmt.Sprintf("/v1/crews/%d/rallies", crew.ID), body("第三个", time.Now().Add(6*time.Hour)), nil)
	a.expectErr("POST", fmt.Sprintf("/v1/crews/%d/rallies", crew.ID), body("第四个", time.Now().Add(7*time.Hour)), 409, "rally_limit")
	d.expectErr("GET", fmt.Sprintf("/v1/crews/%d/rallies", crew.ID), nil, 403, "not_in_crew")
	d.expectErr("POST", fmt.Sprintf("/v1/rallies/%d/join", r.ID), nil, 403, "not_in_crew")

	// Check-in rules.
	far, near := at(1000, 0), at(150, 50)
	b.expectErr("POST", fmt.Sprintf("/v1/rallies/%d/checkin", r.ID), near, 400, "checkin_not_allowed") // not joined
	b.must("POST", fmt.Sprintf("/v1/rallies/%d/join", r.ID), nil, nil)
	c.must("POST", fmt.Sprintf("/v1/rallies/%d/join", r.ID), nil, nil)
	b.expectErr("POST", fmt.Sprintf("/v1/rallies/%d/checkin", r.ID), far, 400, "checkin_not_allowed")
	b.must("POST", fmt.Sprintf("/v1/rallies/%d/join", later.ID), nil, nil)
	b.expectErr("POST", fmt.Sprintf("/v1/rallies/%d/checkin", later.ID), near, 400, "checkin_not_allowed") // too early
	b.must("POST", fmt.Sprintf("/v1/rallies/%d/checkin", r.ID), near, &r)
	if !r.CheckedIn || r.CheckedInCount != 1 || r.BonusActive {
		t.Fatalf("one check-in: %+v", r)
	}
	a.must("POST", fmt.Sprintf("/v1/rallies/%d/checkin", r.ID), p, &r)
	if r.CheckedInCount != 2 || !r.BonusActive || r.JoinedCount != 3 {
		t.Fatalf("bonus active: %+v", r)
	}
	var crewRallies struct {
		Items []rallyView `json:"items"`
	}
	c.must("GET", fmt.Sprintf("/v1/crews/%d/rallies", crew.ID), nil, &crewRallies)
	if len(crewRallies.Items) != 3 || crewRallies.Items[0].ID != r.ID || !crewRallies.Items[0].Joined || crewRallies.Items[0].CheckedIn {
		t.Fatalf("crew rallies: %+v", crewRallies.Items)
	}
	// The group chat follows sign-ups.
	var hist cursorList[msgView]
	c.must("GET", fmt.Sprintf("/v1/conversations/%d/messages", *r.ConversationID), nil, &hist)
	if len(hist.Items) != 2 {
		t.Fatalf("rally chat: %+v", hist.Items)
	}

	// The run happened during the rally (move the rally back in time; the
	// test runs started 2 hours ago).
	e.sql(`UPDATE src.src_soc_loop_rally SET start_time=now() - interval '150 minutes' WHERE id=$1`, r.ID)
	bc := at(150, 0)
	var boss struct {
		ID int64 `json:"id"`
	}
	ad.must("POST", "/admin/v1/bosses", map[string]any{"kind": "sofa", "lat": bc.Lat, "lng": bc.Lng, "hp": 100000}, &boss)
	route := [][2]float64{{0, 0}, {600, 0}, {0, 0}}
	withBonus := b.upload("dev-b", false, route...)
	without := c.upload("dev-c", false, route...) // joined but did not check in
	if withBonus.Rally == nil || withBonus.Rally.ID != r.ID || withBonus.Rally.BonusRate != 0.2 || without.Rally != nil {
		t.Fatalf("rally in settlement: %+v / %+v", withBonus.Rally, without.Rally)
	}
	if len(withBonus.BossDamage) != 1 || len(without.BossDamage) != 1 || without.BossDamage[0].Damage == 0 ||
		withBonus.BossDamage[0].Damage != int(float64(without.BossDamage[0].Damage)*1.2) {
		t.Fatalf("boss damage: %+v vs %+v", withBonus.BossDamage, without.BossDamage)
	}
	if without.EnergyRaw == 0 || withBonus.EnergyRaw != int(float64(without.EnergyRaw)*1.2) {
		t.Fatalf("energy: %d vs %d", withBonus.EnergyRaw, without.EnergyRaw)
	}
	var hits int
	e.app.Pool.QueryRow(ctx, `SELECT sum(damage) FROM src.src_ply_loop_boss_hit WHERE boss_id=$1 AND user_id=$2`, boss.ID, bid).Scan(&hits)
	if hits != withBonus.BossDamage[0].Damage {
		t.Fatalf("stored damage %d", hits)
	}
	var stored commSettlement
	var raw []byte
	e.app.Pool.QueryRow(ctx, `SELECT result_json FROM src.src_act_loop_activity WHERE id=$1`, withBonus.activityID).Scan(&raw)
	json.Unmarshal(raw, &stored)
	if stored.Rally == nil || stored.Rally.ID != r.ID {
		t.Fatalf("stored settlement lacks rally: %s", raw)
	}

	// Below min_checkins there is no bonus.
	e.sql(`UPDATE src.src_soc_loop_rally_join SET checkin_time=NULL WHERE rally_id=$1 AND user_id<>$2`, r.ID, bid)
	if again := b.upload("dev-b", false, route...); again.Rally != nil {
		t.Fatalf("bonus with one check-in: %+v", again.Rally)
	}

	// Leave, cancel, ended.
	c.must("POST", fmt.Sprintf("/v1/rallies/%d/leave", later.ID), nil, nil)
	b.expectErr("POST", fmt.Sprintf("/v1/rallies/%d/cancel", later.ID), nil, 403, "not_leader")
	a.must("POST", fmt.Sprintf("/v1/rallies/%d/cancel", later.ID), nil, &later)
	if later.Status != "cancelled" || later.BonusActive {
		t.Fatalf("cancelled: %+v", later)
	}
	c.expectErr("POST", fmt.Sprintf("/v1/rallies/%d/join", later.ID), nil, 409, "rally_closed")
	e.sql(`UPDATE src.src_soc_loop_rally SET start_time=now() - interval '4 hours' WHERE id=$1`, r.ID)
	b.must("POST", fmt.Sprintf("/v1/rallies/%d/leave", r.ID), nil, nil)
	a.must("GET", fmt.Sprintf("/v1/crews/%d/rallies", crew.ID), nil, &crewRallies)
	if crewRallies.Items[0].Status != "open" || crewRallies.Items[len(crewRallies.Items)-1].Status == "open" {
		t.Fatalf("open first: %+v", crewRallies.Items)
	}
}

// ---------------------------------------------------------------- races, inbox, home

type raceView struct {
	ID          int64      `json:"id"`
	Type        string     `json:"type"`
	Title       string     `json:"title"`
	Status      string     `json:"status"`
	SignedCount int        `json:"signed_count"`
	Published   *bool      `json:"published"`
	Place       *racePlace `json:"place"`
	Medal       struct {
		Key  string `json:"key"`
		Name string `json:"name"`
	} `json:"medal"`
	MyEntry *struct {
		Status    string `json:"status"`
		ResultSec *int   `json:"result_sec"`
		Rank      *int   `json:"rank"`
	} `json:"my_entry"`
	Leaderboard []struct {
		Rank      int `json:"rank"`
		ResultSec int `json:"result_sec"`
		User      struct {
			ID int64 `json:"id"`
		} `json:"user"`
	} `json:"leaderboard"`
}

type racePlace struct {
	Name string `json:"name"`
}

func TestCommunityRacesHome(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	ad := adminClient(t, e)
	a, aid := e.member("13800000401")
	b, bid := e.member("13800000402")
	now := time.Now()

	// Admin CRUD.
	online := map[string]any{"type": "online", "title": "城市 1K 线上赛", "description": "时间窗内跑满 1 公里", "sport": "run", "distance_m": 1000,
		"start_time": now.Add(-3 * time.Hour), "end_time": now.Add(24 * time.Hour), "signup_end_time": now.Add(20 * time.Hour),
		"capacity": 2, "requires_wearable": true, "medal": map[string]any{"key": "race_test_1k", "name": "1K 完赛奖牌", "image_url": "https://cdn.test/m.png"},
		"published": true}
	ad.expectErr("POST", "/admin/v1/races", map[string]any{"type": "online", "title": "x", "sport": "swim", "distance_m": 1000,
		"start_time": now, "end_time": now.Add(time.Hour), "capacity": 1}, 400, "invalid_body")
	var on raceView
	ad.must("POST", "/admin/v1/races", online, &on)
	if on.Status != "running" || on.Published == nil || !*on.Published || on.Place != nil || on.Medal.Key != "race_test_1k" {
		t.Fatalf("online race: %+v", on)
	}
	online["title"] = "重复奖牌"
	ad.expectErr("POST", "/admin/v1/races", online, 409, "medal_key_taken")
	var off raceView
	p := at(0, 0)
	ad.must("POST", "/admin/v1/races", map[string]any{"type": "offline", "title": "草稿线下赛", "sport": "run", "distance_m": 21097,
		"start_time": now.Add(48 * time.Hour), "end_time": now.Add(54 * time.Hour), "signup_end_time": now.Add(24 * time.Hour),
		"place": map[string]any{"name": "外滩", "lat": p.Lat, "lng": p.Lng}, "capacity": 100}, &off)
	if off.Status != "signup" || *off.Published || off.Place == nil || off.Medal.Key == "" || off.Medal.Name != "草稿线下赛 完赛奖牌" {
		t.Fatalf("offline race: %+v", off)
	}
	a.expectErr("GET", fmt.Sprintf("/v1/races/%d", off.ID), nil, 404, "not_found")
	ad.must("PATCH", fmt.Sprintf("/admin/v1/races/%d", off.ID), map[string]any{"title": "城市半马", "published": true}, &off)
	if off.Title != "城市半马" || !*off.Published || off.Type != "offline" {
		t.Fatalf("patched: %+v", off)
	}
	var rl struct {
		Items []raceView `json:"items"`
		Total int        `json:"total"`
	}
	ad.must("GET", "/admin/v1/races", nil, &rl)
	if rl.Total != 2 || rl.Items[0].Published == nil {
		t.Fatalf("admin races: %+v", rl)
	}

	// App list and sign-up.
	var list cursorList[raceView]
	a.must("GET", "/v1/races", nil, &list)
	if len(list.Items) != 2 || list.Items[0].ID != on.ID || list.Items[0].Published != nil || list.Items[0].MyEntry != nil {
		t.Fatalf("app races: %+v", list.Items)
	}
	a.must("GET", "/v1/races?status=signup", nil, &list)
	if len(list.Items) != 1 || list.Items[0].ID != off.ID {
		t.Fatalf("signup races: %+v", list.Items)
	}
	var r raceView
	a.must("POST", fmt.Sprintf("/v1/races/%d/signup", on.ID), nil, &r)
	if r.MyEntry == nil || r.MyEntry.Status != "signed" || r.SignedCount != 1 {
		t.Fatalf("signed: %+v", r)
	}
	a.expectErr("DELETE", fmt.Sprintf("/v1/races/%d/signup", on.ID), nil, 409, "race_started")
	b.must("POST", fmt.Sprintf("/v1/races/%d/signup", on.ID), nil, nil)
	c, _ := e.member("13800000403")
	c.expectErr("POST", fmt.Sprintf("/v1/races/%d/signup", on.ID), nil, 409, "race_full")
	b.must("POST", fmt.Sprintf("/v1/races/%d/signup", off.ID), nil, nil)
	b.must("DELETE", fmt.Sprintf("/v1/races/%d/signup", off.ID), nil, &r)
	if r.MyEntry != nil {
		t.Fatalf("signup cancelled: %+v", r.MyEntry)
	}
	b.must("POST", fmt.Sprintf("/v1/races/%d/signup", off.ID), nil, nil)

	// Online completion needs wearable data; the result is scaled to 1 km.
	route := [][2]float64{{0, 0}, {700, 0}, {0, 0}}
	if s := a.upload("dev-a", false, route...); len(s.Races) != 0 {
		t.Fatalf("finished without wearable: %+v", s.Races)
	}
	s := a.upload("dev-a", true, route...)
	if len(s.Races) != 1 || s.Races[0].ID != on.ID || s.Races[0].Medal.Key != "race_test_1k" {
		t.Fatalf("race finished: %+v", s.Races)
	}
	want := int(float64(s.durationS)*1000/s.distanceM + 0.5)
	if s.Races[0].ResultSec != want {
		t.Fatalf("result %d, want %d", s.Races[0].ResultSec, want)
	}
	if again := a.upload("dev-a", true, route...); len(again.Races) != 0 {
		t.Fatal("only the first finish counts")
	}
	fast := b.upload("dev-b", true, [][2]float64{{0, 0}, {1200, 0}}...)
	if len(fast.Races) != 1 {
		t.Fatalf("B finished: %+v", fast.Races)
	}
	a.must("GET", fmt.Sprintf("/v1/races/%d", on.ID), nil, &r)
	if r.MyEntry == nil || r.MyEntry.Status != "finished" || r.MyEntry.ResultSec == nil || len(r.Leaderboard) != 2 {
		t.Fatalf("race after finish: %+v", r)
	}
	first, second := aid, bid
	if fast.Races[0].ResultSec < s.Races[0].ResultSec {
		first, second = bid, aid
	}
	if r.Leaderboard[0].User.ID != first || r.Leaderboard[1].User.ID != second || r.Leaderboard[0].Rank != 1 {
		t.Fatalf("leaderboard: %+v", r.Leaderboard)
	}
	if (first == aid) != (*r.MyEntry.Rank == 1) {
		t.Fatalf("my rank: %d", *r.MyEntry.Rank)
	}
	var codex struct {
		Medals []struct {
			Key      string  `json:"key"`
			Name     string  `json:"name"`
			Type     string  `json:"type"`
			Obtained bool    `json:"obtained"`
			ImageURL *string `json:"image_url"`
		} `json:"medals"`
	}
	a.must("GET", "/v1/codex", nil, &codex)
	found := false
	for _, m := range codex.Medals {
		if m.Key == "race_test_1k" {
			found = m.Obtained && m.Type == "race" && m.Name == "1K 完赛奖牌" && m.ImageURL != nil
		}
	}
	if !found {
		t.Fatalf("race medal in codex: %+v", codex.Medals)
	}
	if !hasNotice(a.notifications("interaction"), "race_finished") {
		t.Fatal("finish notification")
	}

	// Offline finish by ops.
	var entries struct {
		Items []struct {
			User struct {
				ID int64 `json:"id"`
			} `json:"user"`
			Status string `json:"status"`
		} `json:"items"`
		Total int `json:"total"`
	}
	ad.must("GET", fmt.Sprintf("/admin/v1/races/%d/entries", off.ID), nil, &entries)
	if entries.Total != 1 || entries.Items[0].User.ID != bid || entries.Items[0].Status != "signed" {
		t.Fatalf("entries: %+v", entries)
	}
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/races/%d/entries/%d/finish", off.ID, aid), map[string]int{"result_sec": 5400}, 404, "not_found")
	ad.must("POST", fmt.Sprintf("/admin/v1/races/%d/entries/%d/finish", off.ID, bid), map[string]int{"result_sec": 5400}, nil)
	b.must("GET", fmt.Sprintf("/v1/races/%d", off.ID), nil, &r)
	if r.MyEntry == nil || r.MyEntry.Status != "finished" || *r.MyEntry.ResultSec != 5400 || len(r.Leaderboard) != 1 {
		t.Fatalf("offline finish: %+v", r)
	}
	var n int
	e.app.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_ply_loop_codex_item WHERE user_id=$1 AND item_type='medal' AND item=$2`, bid, off.Medal.Key).Scan(&n)
	if n != 1 {
		t.Fatal("offline medal")
	}
	ad.expectErr("PATCH", fmt.Sprintf("/admin/v1/races/%d", off.ID), map[string]any{"medal": map[string]any{"key": "other_key", "name": "x"}}, 409, "medal_awarded")

	// Ending: unfinished entries show as dnf; cancel.
	e.sql(`UPDATE src.src_mkt_loop_race SET start_time=now() - interval '2 days', end_time=now() - interval '1 day', signup_end_time=now() - interval '2 days' WHERE id=$1`, off.ID)
	ad.must("POST", fmt.Sprintf("/admin/v1/races/%d/cancel", on.ID), nil, &r)
	if r.Status != "cancelled" {
		t.Fatalf("cancelled race: %+v", r)
	}

	// Inbox summary and community home.
	var crew struct {
		ID int64 `json:"id"`
	}
	a.must("POST", "/v1/crews", map[string]any{"name": "首页跑团", "district": "黄浦区", "join_mode": "open"}, &crew)
	b.must("POST", fmt.Sprintf("/v1/crews/%d/join", crew.ID), nil, nil)
	rp := at(0, 0)
	a.must("POST", fmt.Sprintf("/v1/crews/%d/rallies", crew.ID), map[string]any{"title": "夜跑", "start_time": now.Add(2 * time.Hour),
		"place": map[string]any{"name": "外滩", "lat": rp.Lat, "lng": rp.Lng}}, nil)
	var mt meetupView
	a.must("POST", "/v1/meetups", meetupBody("首页组局", 0, 0, 5), &mt)
	b.must("POST", fmt.Sprintf("/v1/meetups/%d/join", mt.ID), nil, nil)
	b.say(*mt.ConversationID, "我来了")
	ad.must("POST", "/admin/v1/races", map[string]any{"type": "online", "title": "报名中", "sport": "run", "distance_m": 5000,
		"start_time": now.Add(24 * time.Hour), "end_time": now.Add(48 * time.Hour), "capacity": 10, "published": true}, nil)

	sum := b.summary()
	// Two race_finished (online, offline) and rally_created.
	if _, ok := sum["system"]; sum["interaction"] != 3 || sum["chat"] != 0 || !ok || sum["territory"] != 0 || sum["monster"] != 0 {
		t.Fatalf("B summary: %v", sum)
	}
	if sa := a.summary(); sa["chat"] != 2 { // B joined (system) + B's message
		t.Fatalf("A summary: %v", sa)
	}
	var home struct {
		Crew *struct {
			ID          int64   `json:"id"`
			Name        string  `json:"name"`
			MemberCount int     `json:"member_count"`
			WeekAreaM2  float64 `json:"week_area_m2"`
			MyRank      *int    `json:"my_rank"`
		} `json:"crew"`
		Unread struct {
			Interaction int `json:"interaction"`
			Chat        int `json:"chat"`
		} `json:"unread"`
		Rallies []rallyView  `json:"rallies"`
		Meetups []meetupView `json:"meetups"`
		Races   []raceView   `json:"races"`
	}
	b.must("GET", "/v1/community/home", nil, &home)
	if home.Crew == nil || home.Crew.ID != crew.ID || home.Crew.MemberCount != 2 || home.Crew.MyRank == nil || len(home.Rallies) != 1 ||
		len(home.Meetups) != 1 || home.Meetups[0].ID != mt.ID || len(home.Races) != 1 || home.Races[0].Title != "报名中" || home.Races[0].Published != nil ||
		home.Unread.Interaction != sum["interaction"] {
		t.Fatalf("home: %+v", home)
	}
	if home.Crew.WeekAreaM2 != 0 {
		t.Fatalf("out-and-back runs claim nothing: %v", home.Crew.WeekAreaM2)
	}
	c.must("GET", "/v1/community/home", nil, &home)
	if home.Crew != nil || len(home.Rallies) != 0 || len(home.Meetups) != 0 || len(home.Races) != 1 {
		t.Fatalf("home without crew: %+v", home)
	}
}
