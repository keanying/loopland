package app

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// TestCommunityIntegration covers the seams between the two community
// packages: leaving a crew drops rally membership and its chat, reported
// chat messages can be removed by an admin, and profiles count posts.
func TestCommunityIntegration(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	ad := adminClient(t, e)
	a, aid := e.member("13800000401")
	b, bid := e.member("13800000402")

	var crew struct {
		ID int64 `json:"id"`
	}
	a.must("POST", "/v1/crews", map[string]any{"name": "整合测试团", "district": "黄浦区", "join_mode": "open"}, &crew)
	b.must("POST", fmt.Sprintf("/v1/crews/%d/join", crew.ID), nil, nil)
	p := at(100, 0)
	var r rallyView
	a.must("POST", fmt.Sprintf("/v1/crews/%d/rallies", crew.ID), map[string]any{"title": "周三夜跑", "start_time": time.Now().Add(time.Hour),
		"place": map[string]any{"name": "人民广场", "lat": p.Lat, "lng": p.Lng}, "distance_goal_m": 5000}, &r)
	b.must("POST", fmt.Sprintf("/v1/rallies/%d/join", r.ID), nil, &r)
	if r.JoinedCount != 2 {
		t.Fatalf("joined: %+v", r)
	}

	// b reports a message a sent in the rally chat; the admin removes it.
	m := a.say(*r.ConversationID, "集合地点改到 2 号口")
	var rep struct {
		ID int64 `json:"id"`
	}
	b.must("POST", "/v1/reports", map[string]any{"target_type": "message", "target_id": m.ID, "reason": "abuse"}, &rep)
	ad.must("POST", fmt.Sprintf("/admin/v1/reports/%d/handle", rep.ID), map[string]any{"action": "remove"}, nil)
	var typ, content string
	var sender *int64
	if err := e.app.Pool.QueryRow(ctx, `SELECT message_type, content, sender_id FROM src.src_msg_loop_message WHERE id=$1`, m.ID).Scan(&typ, &content, &sender); err != nil {
		t.Fatal(err)
	}
	if typ != "system" || content == "集合地点改到 2 号口" {
		t.Fatalf("message not removed: %s %q", typ, content)
	}

	// Leaving the crew drops b from the rally and its chat.
	b.must("POST", fmt.Sprintf("/v1/crews/%d/leave", crew.ID), nil, nil)
	var list struct {
		Items []rallyView `json:"items"`
	}
	a.must("GET", fmt.Sprintf("/v1/crews/%d/rallies", crew.ID), nil, &list)
	if len(list.Items) != 1 || list.Items[0].JoinedCount != 1 {
		t.Fatalf("still joined after leaving the crew: %+v", list.Items)
	}
	var inChat bool
	if err := e.app.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_msg_loop_conv_member WHERE conversation_id=$1 AND user_id=$2)`, *r.ConversationID, bid).Scan(&inChat); err != nil {
		t.Fatal(err)
	}
	if inChat {
		t.Fatal("still in the rally chat after leaving the crew")
	}

	// Profiles count approved posts (own pending ones only for the author).
	a.must("POST", "/v1/posts", map[string]any{"content": "今天天气不错"}, nil)
	var prof struct {
		PostCount int `json:"post_count"`
	}
	b.must("GET", fmt.Sprintf("/v1/users/%d", aid), nil, &prof)
	if prof.PostCount != 1 {
		t.Fatalf("post_count: %+v", prof)
	}
}
