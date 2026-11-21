package app

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/keanying/loopland/server/internal/geo"
)

// ---------------------------------------------------------------- fake OpenAI-compatible model

type fakeLLM struct {
	srv  *httptest.Server
	slow atomic.Bool // moderation requests for "慢慢跑" hang

	mu   sync.Mutex
	reqs []fakeReq
}

type fakeReq struct {
	Model   string
	System  string
	Last    string
	Stream  bool
	Images  []string
	HasTool bool
}

func newFakeLLM(t *testing.T) *fakeLLM {
	f := &fakeLLM{}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeLLM) requests(marker string) []fakeReq {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []fakeReq
	for _, r := range f.reqs {
		if strings.Contains(r.System, marker) {
			out = append(out, r)
		}
	}
	return out
}

func text(content any) (string, []string) {
	switch c := content.(type) {
	case string:
		return c, nil
	case []any:
		var b strings.Builder
		var imgs []string
		for _, p := range c {
			m, _ := p.(map[string]any)
			if s, ok := m["text"].(string); ok {
				b.WriteString(s)
			}
			if iu, ok := m["image_url"].(map[string]any); ok {
				imgs = append(imgs, iu["url"].(string))
			}
		}
		return b.String(), imgs
	}
	return "", nil
}

func (f *fakeLLM) serve(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Authorization") != "Bearer sk-fake-123456789" {
		w.WriteHeader(401)
		io.WriteString(w, `{"error":{"message":"invalid api key"}}`)
		return
	}
	var body struct {
		Model      string           `json:"model"`
		Messages   []map[string]any `json:"messages"`
		Tools      []any            `json:"tools"`
		ToolChoice string           `json:"tool_choice"`
		Stream     bool             `json:"stream"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	sys, _ := text(body.Messages[0]["content"])
	lastMsg := body.Messages[len(body.Messages)-1]
	last, imgs := text(lastMsg["content"])
	f.mu.Lock()
	f.reqs = append(f.reqs, fakeReq{Model: body.Model, System: sys, Last: last, Stream: body.Stream, Images: imgs, HasTool: len(body.Tools) > 0})
	f.mu.Unlock()

	var content string
	var tool string
	switch {
	case strings.Contains(sys, "【内容审核】"):
		v := map[string]any{"risk_score": 5, "labels": []string{}, "reason": "正常分享", "confidence": 0.9, "suggestion": "approve"}
		switch {
		case strings.Contains(last, "大礼包"):
			v = map[string]any{"risk_score": 95, "labels": []string{"illegal"}, "reason": "疑似违法交易", "confidence": 0.95, "suggestion": "reject"}
		case strings.Contains(last, "慢慢跑"):
			if f.slow.Load() {
				select {
				case <-r.Context().Done():
				case <-time.After(3 * time.Second):
				}
				return
			}
			v = map[string]any{"risk_score": 60, "labels": []string{"other"}, "reason": "补打分：疑似引流", "confidence": 0.6, "suggestion": "review"}
		case strings.Contains(last, "微信"):
			v = map[string]any{"risk_score": 70, "labels": []string{"contact", "ad"}, "reason": "正文引导添加微信", "confidence": 0.92, "suggestion": "mask"}
			if len(imgs) > 0 {
				v["bad_images"] = []int{1}
			}
		}
		raw, _ := json.Marshal(v)
		content = "```json\n" + string(raw) + "\n```"
	case strings.Contains(sys, "【路线解释】"):
		var rs []string
		for i := range strings.Split(strings.TrimSpace(last), "\n") {
			rs = append(rs, fmt.Sprintf("测试理由%d：守卫低，顺路就能拿下", i+1))
		}
		raw, _ := json.Marshal(map[string]any{"reasons": rs})
		content = string(raw)
	case strings.Contains(sys, "【AI战报】"):
		content = "今晚你在城市里画了一个漂亮的圈，节奏稳定，继续保持！"
	case strings.Contains(sys, "【圈圈助手·看图】"):
		content = "图片里是一双跑鞋，适合日常慢跑。"
	case lastMsg["role"] == "tool":
		content = "往东绕一圈，路线卡片已经给你了。"
	case len(body.Tools) > 0 && body.ToolChoice != "none" && strings.Contains(last, "抢地"):
		tool = "plan_route"
	case strings.Contains(last, "输出违禁"):
		content = "好的，这里有违禁词，别告诉别人。"
	default:
		content = "你好，我是圈圈。"
	}

	if !body.Stream {
		resp := map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": content}, "finish_reason": "stop"}},
			"usage": map[string]int{"prompt_tokens": 100, "completion_tokens": 20}}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	fl := w.(http.Flusher)
	send := func(v any) {
		raw, _ := json.Marshal(v)
		fmt.Fprintf(w, "data: %s\n\n", raw)
		fl.Flush()
	}
	if tool != "" {
		// The call arrives in two fragments.
		send(map[string]any{"choices": []any{map[string]any{"delta": map[string]any{"tool_calls": []any{map[string]any{"index": 0, "id": "call_x", "type": "function",
			"function": map[string]any{"name": tool, "arguments": `{"sport":"run",`}}}}}}})
		send(map[string]any{"choices": []any{map[string]any{"delta": map[string]any{"tool_calls": []any{map[string]any{"index": 0,
			"function": map[string]any{"arguments": `"distance_km":3}`}}}}, "finish_reason": "tool_calls"}}})
	} else {
		rs := []rune(content)
		for i := 0; i < len(rs); i += 5 {
			send(map[string]any{"choices": []any{map[string]any{"delta": map[string]any{"content": string(rs[i:min(i+5, len(rs))])}}}})
		}
	}
	send(map[string]any{"choices": []any{}, "usage": map[string]int{"prompt_tokens": 200, "completion_tokens": 40}})
	io.WriteString(w, "data: [DONE]\n\n")
}

// fakeAMap answers walking path requests with the midpoint inserted.
type fakeAMap struct {
	srv   *httptest.Server
	calls atomic.Int32
	key   atomic.Value
}

func newFakeAMap(t *testing.T) *fakeAMap {
	f := &fakeAMap{}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.calls.Add(1)
		f.key.Store(r.URL.Query().Get("key"))
		var ox, oy, dx, dy float64
		fmt.Sscanf(r.URL.Query().Get("origin"), "%f,%f", &ox, &oy)
		fmt.Sscanf(r.URL.Query().Get("destination"), "%f,%f", &dx, &dy)
		poly := fmt.Sprintf("%.6f,%.6f;%.6f,%.6f;%.6f,%.6f", ox, oy, (ox+dx)/2+0.0003, (oy+dy)/2, dx, dy)
		d := geo.Haversine(geo.LatLng{Lat: oy, Lng: ox}, geo.LatLng{Lat: dy, Lng: dx}) * 1.1
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"status":"1","info":"OK","route":{"paths":[{"distance":"%.0f","steps":[{"polyline":"%s"}]}]}}`, d, poly)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

// ---------------------------------------------------------------- client helpers

type sseEvent struct {
	Event string
	Data  json.RawMessage
}

// stream posts a chat and reads the server-sent events.
func (c *client) stream(body any) []sseEvent {
	c.e.t.Helper()
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", c.e.srv.URL+"/v1/ai/chat", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.e.t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		b, _ := io.ReadAll(resp.Body)
		c.e.t.Fatalf("stream: %d %s %s", resp.StatusCode, resp.Header.Get("Content-Type"), b)
	}
	var out []sseEvent
	sc := bufio.NewScanner(resp.Body)
	var ev sseEvent
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "event: "):
			ev.Event = strings.TrimPrefix(line, "event: ")
		case strings.HasPrefix(line, "data: "):
			ev.Data = json.RawMessage(strings.TrimPrefix(line, "data: "))
		case line == "" && ev.Event != "":
			out = append(out, ev)
			ev = sseEvent{}
		}
	}
	return out
}

type aiQuota struct {
	Unlimited  bool      `json:"unlimited"`
	WeeklyFree int       `json:"weekly_free"`
	Used       int       `json:"used"`
	Remaining  *int      `json:"remaining"`
	ResetsAt   time.Time `json:"resets_at"`
}

type aiCard struct {
	Type  string   `json:"type"`
	Route *aiRoute `json:"route"`
}

type aiMsg struct {
	ID          int64    `json:"id"`
	Role        string   `json:"role"`
	Content     string   `json:"content"`
	ImageURL    *string  `json:"image_url"`
	Cards       []aiCard `json:"cards"`
	AIGenerated bool     `json:"ai_generated"`
}

type aiChat struct {
	Message     aiMsg   `json:"message"`
	UserMessage aiMsg   `json:"user_message"`
	Quota       aiQuota `json:"quota"`
}

type aiRoute struct {
	ID             string               `json:"id"`
	Type           string               `json:"type"`
	Title          string               `json:"title"`
	Reason         string               `json:"reason"`
	DistanceM      int                  `json:"distance_m"`
	EstDurationSec int                  `json:"est_duration_sec"`
	Waypoints      []geo.LatLng         `json:"waypoints"`
	Polyline       [][2]float64         `json:"polyline"`
	Targets        []struct{ ID int64 } `json:"targets"`
	AIGenerated    bool                 `json:"ai_generated"`
}

type aiTask struct {
	reviewTask
	AI *struct {
		RiskScore  int      `json:"risk_score"`
		Labels     []string `json:"labels"`
		Reason     string   `json:"reason"`
		Confidence float64  `json:"confidence"`
		Suggestion string   `json:"suggestion"`
		ModelName  string   `json:"model_name"`
	} `json:"ai"`
	UserViolationCount int  `json:"user_violation_count"`
	HasActivity        bool `json:"has_activity"`
}

func aiTaskOf(t *testing.T, ad *client, typ string, id int64, status string) aiTask {
	t.Helper()
	var list struct {
		Items []aiTask `json:"items"`
	}
	ad.must("GET", "/admin/v1/reviews?status="+status+"&target_type="+typ+"&page_size=100", nil, &list)
	for _, it := range list.Items {
		if it.TargetID == id {
			return it
		}
	}
	t.Fatalf("no %s %s task for %d", status, typ, id)
	return aiTask{}
}

func configureAI(t *testing.T, ad *client, f *fakeLLM, extra map[string]string) {
	t.Helper()
	v := map[string]string{"vendor": "custom", "base_url": f.srv.URL + "/v1", "api_key": "sk-fake-123456789", "model": "big-m", "small_model": "small-m",
		"display_name": "测试千问", "registration_no": "Test-2026-001", "weekly_free_quota": "2", "timeout_s": "5",
		"price_input_per_mtok_fen": "200", "price_output_per_mtok_fen": "600"}
	for k, x := range extra {
		v[k] = x
	}
	ad.must("PUT", "/admin/v1/providers/ai", map[string]any{"enabled": true, "values": v}, nil)
}

func square(cx, cy, half float64) [][2]float64 {
	return [][2]float64{{cx - half, cy - half}, {cx + half, cy - half}, {cx + half, cy + half}, {cx - half, cy + half}, {cx - half, cy - half}}
}

// ---------------------------------------------------------------- scenario

func TestAI(t *testing.T) {
	t.Setenv("LOOPLAND_MEDIA_DIR", t.TempDir())
	e := newEnv(t)
	ctx := context.Background()
	ad := adminClient(t, e)
	fake := newFakeLLM(t)
	e.app.Moderation.AITimeout = 300 * time.Millisecond
	configureAI(t, ad, fake, nil)

	a, aid := e.member("13900000001")
	b, bid := e.member("13900000002")
	c, cid := e.member("13900000003")
	e.sql(`INSERT INTO src.src_ord_loop_membership (user_id, plan_code, channel, expire_time) VALUES ($1, 'month', 'gift', now() + interval '30 days')`, bid)

	// b holds land north-east of the origin; a monster is east.
	b.upload("dev-b", false, square(400, 400, 100)...)
	var bTerritory int64
	if err := e.app.Pool.QueryRow(ctx, `SELECT id FROM src.src_ter_loop_territory WHERE owner_user_id=$1`, bid).Scan(&bTerritory); err != nil {
		t.Fatalf("b claimed nothing: %v", err)
	}
	bc := at(900, 0)
	var boss struct {
		ID int64 `json:"id"`
	}
	ad.must("POST", "/admin/v1/bosses", map[string]any{"kind": "sofa", "lat": bc.Lat, "lng": bc.Lng, "location_name": "江边", "hp": 3000}, &boss)

	// --- Info and quota: free vs member.
	var info struct {
		Enabled        bool    `json:"enabled"`
		ModelName      string  `json:"model_name"`
		RegistrationNo string  `json:"registration_no"`
		Vision         bool    `json:"vision"`
		Disclaimer     string  `json:"disclaimer"`
		Quota          aiQuota `json:"quota"`
	}
	a.must("GET", "/v1/ai/info", nil, &info)
	if !info.Enabled || info.ModelName != "测试千问" || info.RegistrationNo != "Test-2026-001" || info.Vision || info.Disclaimer == "" ||
		info.Quota.Unlimited || info.Quota.WeeklyFree != 2 || info.Quota.Remaining == nil || *info.Quota.Remaining != 2 {
		t.Fatalf("free info: %+v", info)
	}
	if wd := info.Quota.ResetsAt.In(time.FixedZone("CST", 8*3600)); wd.Weekday() != time.Monday || wd.Hour() != 0 || !wd.After(time.Now()) {
		t.Fatalf("resets_at %v", info.Quota.ResetsAt)
	}
	b.must("GET", "/v1/ai/info", nil, &info)
	if !info.Quota.Unlimited || info.Quota.Remaining != nil {
		t.Fatalf("member info: %+v", info.Quota)
	}
	var greet struct {
		Text        string   `json:"text"`
		Suggestions []string `json:"suggestions"`
		AIGenerated bool     `json:"ai_generated"`
	}
	b.must("GET", fmt.Sprintf("/v1/ai/greeting?lat=%f&lng=%f", origin.Lat, origin.Lng), nil, &greet)
	if !strings.Contains(greet.Text, "能量") || !strings.Contains(greet.Text, "沙发怪") || len(greet.Suggestions) != 4 || greet.AIGenerated {
		t.Fatalf("greeting: %+v", greet)
	}

	// --- Streaming chat: the model calls plan_route, a route card comes back.
	evs := a.stream(map[string]any{"content": "今晚去哪抢地？", "lat": origin.Lat, "lng": origin.Lng})
	var deltas strings.Builder
	var card aiCard
	var done aiChat
	for _, ev := range evs {
		switch ev.Event {
		case "delta":
			var d struct{ Text string }
			_ = json.Unmarshal(ev.Data, &d)
			deltas.WriteString(d.Text)
		case "card":
			if card.Type == "" {
				_ = json.Unmarshal(ev.Data, &card)
			}
		case "done":
			_ = json.Unmarshal(ev.Data, &done)
		case "error":
			t.Fatalf("error event: %s", ev.Data)
		}
	}
	if evs[len(evs)-1].Event != "done" || deltas.String() != "往东绕一圈，路线卡片已经给你了。" {
		t.Fatalf("events: %+v", evs)
	}
	if card.Type != "route" || card.Route == nil || card.Route.Type != "loop" || len(card.Route.Polyline) == 0 {
		t.Fatalf("card: %+v", card)
	}
	if done.Message.Role != "assistant" || !done.Message.AIGenerated || done.Message.Content != deltas.String() || len(done.Message.Cards) != 2 ||
		done.UserMessage.Role != "user" || done.UserMessage.AIGenerated || len(done.UserMessage.Cards) != 0 ||
		done.Quota.Used != 1 || *done.Quota.Remaining != 1 {
		t.Fatalf("done: %+v", done)
	}
	if done.Message.Cards[1].Route.Type != "capture" || done.Message.Cards[1].Route.Targets[0].ID == 0 {
		t.Fatalf("capture card: %+v", done.Message.Cards[1].Route)
	}
	chats := fake.requests("【圈圈助手】")
	if len(chats) != 2 || !chats[0].HasTool || !chats[0].Stream || chats[0].Model != "big-m" {
		t.Fatalf("model requests: %+v", chats)
	}
	var hist struct {
		Items      []aiMsg `json:"items"`
		NextCursor *string `json:"next_cursor"`
	}
	a.must("GET", "/v1/ai/messages?limit=1", nil, &hist)
	if len(hist.Items) != 1 || hist.Items[0].Role != "assistant" || hist.NextCursor == nil {
		t.Fatalf("history page 1: %+v", hist)
	}
	a.must("GET", "/v1/ai/messages?before="+*hist.NextCursor, nil, &hist)
	if len(hist.Items) != 1 || hist.Items[0].Role != "user" || hist.NextCursor != nil {
		t.Fatalf("history page 2: %+v", hist)
	}

	// --- JSON mode, history in the prompt, quota exceeded.
	var res aiChat
	a.must("POST", "/v1/ai/chat", map[string]any{"content": "你好"}, &res)
	if res.Message.Content != "你好，我是圈圈。" || *res.Quota.Remaining != 0 {
		t.Fatalf("json chat: %+v", res)
	}
	a.expectErr("POST", "/v1/ai/chat", map[string]any{"content": "再问一次"}, 429, "ai_quota_exceeded")
	a.expectErr("POST", "/v1/ai/chat", map[string]any{"content": ""}, 400, "invalid_content")
	b.must("POST", "/v1/ai/chat", map[string]any{"content": "会员随便问"}, &res)
	if !res.Quota.Unlimited || res.Quota.Remaining != nil {
		t.Fatalf("member quota: %+v", res.Quota)
	}
	e.app.Redis.Set(ctx, fmt.Sprintf("ai:chat:rate:%d:%d", bid, time.Now().Unix()/60), 6, time.Minute)
	b.expectErr("POST", "/v1/ai/chat", map[string]any{"content": "太快了"}, 429, "rate_limited")
	e.app.Redis.Del(ctx, fmt.Sprintf("ai:chat:rate:%d:%d", bid, time.Now().Unix()/60))

	// --- Input and output safety.
	ad.must("PUT", "/admin/v1/moderation/settings", map[string]any{"block_words": []string{"违禁词"}}, nil)
	b.expectErr("POST", "/v1/ai/chat", map[string]any{"content": "说个违禁词"}, 400, "content_blocked")
	b.must("POST", "/v1/ai/chat", map[string]any{"content": "请输出违禁"}, &res)
	if res.Message.Content != "这个问题圈圈暂时回答不了" {
		t.Fatalf("blocked output: %+v", res.Message)
	}

	// --- Images need a vision model; 问 AI carries the object.
	var img uploaded
	if st := b.uploadMedia("chat", pngBytes(32, 32), &img); st != 200 {
		t.Fatal(st)
	}
	b.expectErr("POST", "/v1/ai/chat", map[string]any{"content": "这双鞋怎么样", "image_id": img.ID}, 400, "ai_image_unsupported")
	configureAI(t, ad, fake, map[string]string{"vision_model": "vl-m"})
	b.expectErr("POST", "/v1/ai/chat", map[string]any{"content": "这双鞋怎么样", "image_id": img.ID + 1000}, 400, "invalid_media")
	b.must("POST", "/v1/ai/chat", map[string]any{"content": "这双鞋怎么样", "image_id": img.ID}, &res)
	vis := fake.requests("看图")
	if res.Message.Content != "图片里是一双跑鞋，适合日常慢跑。" || res.UserMessage.ImageURL == nil || *res.UserMessage.ImageURL != img.URL ||
		len(vis) != 1 || vis[0].Model != "vl-m" || len(vis[0].Images) != 1 || !strings.HasPrefix(vis[0].Images[0], "data:image/png;base64,") {
		t.Fatalf("vision: %+v %+v", res, vis)
	}
	b.must("POST", "/v1/ai/chat", map[string]any{"content": "这块地怎么守", "context": map[string]any{"type": "territory", "id": bTerritory}}, &res)
	if last := fake.requests("【圈圈助手】"); !strings.Contains(last[len(last)-1].System, "用户正在看领地") {
		t.Fatalf("context not in the prompt: %s", last[len(last)-1].System)
	}
	b.expectErr("POST", "/v1/ai/chat", map[string]any{"content": "这只呢", "context": map[string]any{"type": "boss", "id": 99999}}, 404, "not_found")

	// --- Clear (soft delete); admin can still read it, audited, admin only.
	a.must("DELETE", "/v1/ai/messages", nil, nil)
	a.must("GET", "/v1/ai/messages", nil, &hist)
	if len(hist.Items) != 0 {
		t.Fatalf("cleared: %+v", hist.Items)
	}
	a.must("GET", "/v1/ai/info", nil, &info)
	if info.Quota.Used != 2 {
		t.Fatalf("clearing gave the quota back: %+v", info.Quota)
	}
	var adminMsgs struct {
		Items []aiMsg `json:"items"`
		Total int     `json:"total"`
	}
	ad.must("GET", fmt.Sprintf("/admin/v1/users/%d/ai-messages", aid), nil, &adminMsgs)
	if adminMsgs.Total != 4 || len(adminMsgs.Items) != 4 {
		t.Fatalf("admin messages: %+v", adminMsgs)
	}
	var audits int
	if err := e.app.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_sys_loop_audit_log WHERE action='ai.messages.view' AND target=$1`, fmt.Sprintf("user:%d", aid)).Scan(&audits); err != nil || audits != 1 {
		t.Fatalf("audit: %d %v", audits, err)
	}
	ad.must("POST", "/admin/v1/admins", map[string]string{"username": "ops-ai", "password": "ops-password-123", "role": "ops"}, nil)
	ops := e.anon()
	var login struct {
		Token string `json:"token"`
	}
	ops.must("POST", "/admin/v1/login", map[string]string{"username": "ops-ai", "password": "ops-password-123"}, &login)
	ops.token = login.Token
	ops.expectErr("GET", fmt.Sprintf("/admin/v1/users/%d/ai-messages", aid), nil, 403, "forbidden")

	// --- Routes: rule-based, explained by the small model, cached.
	var routes struct {
		Items       []aiRoute `json:"items"`
		AIGenerated bool      `json:"ai_generated"`
	}
	q := fmt.Sprintf("/v1/ai/routes?lat=%f&lng=%f&sport=run&distance_km=3", origin.Lat, origin.Lng)
	a.must("GET", q, nil, &routes)
	types := []string{}
	for _, r := range routes.Items {
		types = append(types, r.Type)
	}
	if !slices.Equal(types, []string{"loop", "capture", "boss"}) || !routes.AIGenerated {
		t.Fatalf("route types: %v", types)
	}
	loop := routes.Items[0]
	if loop.DistanceM < 2250 || loop.DistanceM > 3750 || !loop.AIGenerated || !strings.HasPrefix(loop.Reason, "测试理由1") ||
		!strings.HasPrefix(loop.ID, "r_") || loop.EstDurationSec <= 0 || len(loop.Polyline) != len(loop.Waypoints) {
		t.Fatalf("loop: %+v", loop)
	}
	if routes.Items[2].Targets[0].ID != boss.ID {
		t.Fatalf("boss route: %+v", routes.Items[2])
	}
	before := len(fake.requests("【路线解释】"))
	a.must("GET", q, nil, &routes)
	if len(fake.requests("【路线解释】")) != before {
		t.Fatal("routes not cached")
	}
	a.expectErr("GET", "/v1/ai/routes?sport=run", nil, 400, "invalid_body")
	a.expectErr("GET", q+"0", nil, 400, "invalid_body") // 30 km > route_max_km
	// With 高德 the polyline follows the (fake) road network.
	amap := newFakeAMap(t)
	e.app.AI.AMapBase = amap.srv.URL
	ad.must("PUT", "/admin/v1/providers/amap", map[string]any{"enabled": true, "values": map[string]string{"web_key": "amap-key-123"}}, nil)
	a.must("GET", fmt.Sprintf("/v1/ai/routes?lat=%f&lng=%f&sport=run&distance_km=4", origin.Lat, origin.Lng), nil, &routes)
	loop = routes.Items[0]
	if amap.calls.Load() == 0 || amap.key.Load() != "amap-key-123" || len(loop.Polyline) <= len(loop.Waypoints) || loop.DistanceM < 3000 || loop.DistanceM > 5000 {
		t.Fatalf("amap: %d calls, %d points vs %d waypoints, %d m", amap.calls.Load(), len(loop.Polyline), len(loop.Waypoints), loop.DistanceM)
	}

	// --- goal.type=ai_route on upload.
	body := run(3, square(-1200, -1200, 300)...)
	body["device"] = map[string]any{"id": "dev-a", "model": "test", "os": "test"}
	body["goal"] = map[string]any{"type": "ai_route", "route_id": loop.ID, "route_type": "loop"}
	var up struct {
		Activity struct {
			ID int64 `json:"id"`
		} `json:"activity"`
		Settlement struct {
			Status string `json:"status"`
		} `json:"settlement"`
	}
	a.must("POST", "/v1/activities", body, &up)
	actID := up.Activity.ID
	if up.Settlement.Status != "settled" {
		t.Fatalf("upload: %+v", up)
	}
	var goalType string
	if err := e.app.Pool.QueryRow(ctx, `SELECT goal_json->>'route_type' FROM src.src_act_loop_activity WHERE id=$1`, actID).Scan(&goalType); err != nil || goalType != "loop" {
		t.Fatalf("goal stored: %q %v", goalType, err)
	}
	bad := run(3, square(-1200, -1200, 300)...)
	bad["goal"] = map[string]any{"type": "ai_route", "route_id": "r_1", "route_type": "teleport"}
	a.expectErr("POST", "/v1/activities", bad, 400, "invalid_body")

	// --- AI battle report: saved, regenerated twice, then 409.
	type report struct {
		ActivityID     int64  `json:"activity_id"`
		Text           string `json:"text"`
		ModelName      string `json:"model_name"`
		AIGenerated    bool   `json:"ai_generated"`
		RegenerateLeft int    `json:"regenerate_left"`
	}
	var rep report
	path := fmt.Sprintf("/v1/activities/%d/ai-report", actID)
	a.must("POST", path, nil, &rep)
	if rep.ActivityID != actID || !strings.Contains(rep.Text, "漂亮的圈") || rep.ModelName != "测试千问" || !rep.AIGenerated || rep.RegenerateLeft != 2 {
		t.Fatalf("report: %+v", rep)
	}
	rr := fake.requests("【AI战报】")
	if len(rr) != 1 || rr[0].Model != "small-m" || !strings.Contains(rr[0].Last, "公里") || strings.Contains(rr[0].Last, "121.") {
		t.Fatalf("report prompt: %+v", rr)
	}
	a.must("POST", path+"?regenerate=0", nil, &rep)
	if len(fake.requests("【AI战报】")) != 1 {
		t.Fatal("report regenerated without asking")
	}
	a.must("POST", path+"?regenerate=1", nil, &rep)
	a.must("POST", path+"?regenerate=1", nil, &rep)
	if rep.RegenerateLeft != 0 {
		t.Fatalf("regenerate left: %+v", rep)
	}
	a.expectErr("POST", path+"?regenerate=1", nil, 409, "regenerate_limit")
	b.expectErr("POST", path, nil, 404, "not_found")
	// Posting with the report.
	var post struct {
		socPost
		AIReport *struct {
			Text        string `json:"text"`
			AIGenerated bool   `json:"ai_generated"`
		} `json:"ai_report"`
	}
	a.must("POST", "/v1/posts", map[string]any{"content": "今天的圈", "activity_id": actID, "ai_report": true}, &post)
	if post.AIReport == nil || post.AIReport.Text != rep.Text || !post.AIReport.AIGenerated || post.ReviewStatus != "approved" {
		t.Fatalf("post with report: %+v", post)
	}
	reportPost := post.ID
	a.must("POST", "/v1/posts", map[string]any{"content": "没有战报"}, &post)
	if post.AIReport != nil {
		t.Fatalf("ai_report without asking: %+v", post.AIReport)
	}
	a.expectErr("POST", "/v1/posts", map[string]any{"content": "x", "ai_report": true}, 400, "invalid_ai_report")
	var bAct int64
	if err := e.app.Pool.QueryRow(ctx, `SELECT id FROM src.src_act_loop_activity WHERE user_id=$1`, bid).Scan(&bAct); err != nil {
		t.Fatal(err)
	}
	b.expectErr("POST", "/v1/posts", map[string]any{"content": "x", "activity_id": bAct, "ai_report": true}, 400, "invalid_ai_report")

	// --- Workouts and coach_mismatch.
	var wk struct {
		Items []struct {
			Key   string `json:"key"`
			Sport string `json:"sport"`
			Steps []struct {
				Pose string `json:"pose"`
				Mode string `json:"mode"`
			} `json:"steps"`
		} `json:"items"`
	}
	c.must("GET", "/v1/ai/workouts", nil, &wk)
	keys := []string{}
	for _, w := range wk.Items {
		keys = append(keys, w.Key)
	}
	if !slices.Equal(keys, []string{"rope_basic", "hiit_burn", "pilates_core", "strength_basic"}) || wk.Items[0].Steps[0].Pose != "jump" {
		t.Fatalf("workouts: %+v", wk)
	}
	rope := func(amount, detected int) string {
		var res struct {
			Settlement struct {
				Status string `json:"status"`
				Flags  []struct {
					Rule string `json:"rule"`
				} `json:"flags"`
			} `json:"settlement"`
		}
		now := time.Now()
		c.must("POST", "/v1/activities", map[string]any{"client_id": uuid.NewString(), "sport": "rope", "started_at": now.Add(-20 * time.Minute), "ended_at": now,
			"duration_s": 1200, "amount": amount, "device": map[string]any{"id": "dev-c", "model": "t", "os": "t"},
			"coach": map[string]any{"workout_key": "rope_basic", "camera": true, "reps_detected": detected, "reps_manual": 0, "sets_done": 5}}, &res)
		if len(res.Settlement.Flags) > 0 {
			return res.Settlement.Status + ":" + res.Settlement.Flags[0].Rule
		}
		return res.Settlement.Status
	}
	if got := rope(480, 480); got != "settled" {
		t.Fatalf("matching coach upload: %s", got)
	}
	if got := rope(600, 400); got != "review:coach_mismatch" {
		t.Fatalf("mismatch: %s", got)
	}
	var coachKey string
	if err := e.app.Pool.QueryRow(ctx, `SELECT coach_json->>'workout_key' FROM src.src_act_loop_activity WHERE user_id=$1 ORDER BY id DESC LIMIT 1`, cid).Scan(&coachKey); err != nil || coachKey != "rope_basic" {
		t.Fatalf("coach stored: %q %v", coachKey, err)
	}

	// --- AI moderation.
	var set map[string]any
	ad.must("GET", "/admin/v1/moderation/settings", nil, &set)
	if set["auto_approve_below"] != float64(20) || set["auto_reject_above"] != float64(90) || set["ai_enabled"] != true || len(set["block_words"].([]any)) != 1 {
		t.Fatalf("settings: %v", set)
	}
	ad.expectErr("PUT", "/admin/v1/moderation/settings", map[string]any{"auto_approve_below": 50, "auto_reject_above": 40}, 400, "invalid_body")

	// Synchronous score: max(rule, AI); vision flags the image.
	var pimg uploaded
	if st := a.uploadMedia("post", pngBytes(40, 40), &pimg); st != 200 {
		t.Fatal(st)
	}
	var risky socPost
	a.must("POST", "/v1/posts", map[string]any{"content": "加我微信 wxid_abc12345 一起跑", "image_ids": []int64{pimg.ID}}, &risky)
	if risky.ReviewStatus != "pending" {
		t.Fatalf("risky: %+v", risky)
	}
	rt := aiTaskOf(t, ad, "post", risky.ID, "pending")
	if rt.RiskScore != 70 || rt.AI == nil || rt.AI.RiskScore != 70 || !slices.Contains(rt.AI.Labels, "contact") || rt.AI.Suggestion != "mask" ||
		rt.AI.ModelName != "测试千问" || rt.AI.Confidence != 0.92 || rt.HasActivity {
		t.Fatalf("ai task: %+v %+v", rt, rt.AI)
	}
	if mr := fake.requests("【内容审核】"); mr[len(mr)-1].Model != "vl-m" || len(mr[len(mr)-1].Images) != 1 {
		t.Fatalf("vision moderation: %+v", mr[len(mr)-1])
	}

	// Auto reject at 90+.
	var illegal socPost
	a.must("POST", "/v1/posts", map[string]any{"content": "违法违规大礼包，私聊"}, &illegal)
	if illegal.ReviewStatus != "rejected" || illegal.RejectReason == nil || !strings.Contains(*illegal.RejectReason, "违法") {
		t.Fatalf("auto reject: %+v", illegal)
	}
	if !slices.Contains(a.inboxTypes(), "review_rejected") {
		t.Fatal("author not told")
	}
	var decision string
	if err := e.app.Pool.QueryRow(ctx, `SELECT decision_type FROM src.src_cnt_loop_review_task WHERE target_type='post' AND target_id=$1`, illegal.ID).Scan(&decision); err != nil || decision != "auto_reject" {
		t.Fatalf("decision: %q %v", decision, err)
	}

	// Timeout: approved by the rules now, re-scored in the background, back to pending.
	fake.slow.Store(true)
	var slow socPost
	start := time.Now()
	a.must("POST", "/v1/posts", map[string]any{"content": "今天慢慢跑了 5 公里"}, &slow)
	if slow.ReviewStatus != "approved" || time.Since(start) > 2*time.Second {
		t.Fatalf("timeout path: %+v after %v", slow, time.Since(start))
	}
	var aiStatus string
	if err := e.app.Pool.QueryRow(ctx, `SELECT ai_status FROM src.src_cnt_loop_review_task WHERE target_type='post' AND target_id=$1`, slow.ID).Scan(&aiStatus); err != nil || aiStatus != "retry" {
		t.Fatalf("ai_status: %q %v", aiStatus, err)
	}
	fake.slow.Store(false)
	if err := e.app.Jobs.Extra["ai_moderation_rescore"](ctx); err != nil {
		t.Fatal(err)
	}
	a.must("GET", fmt.Sprintf("/v1/posts/%d", slow.ID), nil, &slow)
	st := aiTaskOf(t, ad, "post", slow.ID, "pending")
	if slow.ReviewStatus != "pending" || st.RiskScore != 60 || st.AI == nil || st.AI.Reason != "补打分：疑似引流" {
		t.Fatalf("rescored: %+v / %+v", slow, st)
	}
	b.expectErr("GET", fmt.Sprintf("/v1/posts/%d", slow.ID), nil, 404, "not_found")

	// Hide endpoints for a post with an activity.
	var withAct socPost
	a.must("POST", "/v1/posts", map[string]any{"content": "微信 runner88 跑步打卡", "activity_id": actID}, &withAct)
	ht := aiTaskOf(t, ad, "post", withAct.ID, "pending")
	if !ht.HasActivity || ht.UserViolationCount != 1 {
		t.Fatalf("task with activity: %+v", ht)
	}

	// Estimate.
	var est struct {
		PerDayManual      float64 `json:"per_day_manual"`
		PerDayAutoApprove float64 `json:"per_day_auto_approve"`
		PerDayAutoReject  float64 `json:"per_day_auto_reject"`
		Days              int     `json:"days"`
	}
	ad.must("GET", "/admin/v1/moderation/estimate?auto_approve_below=20&auto_reject_above=90", nil, &est)
	if est.Days != 7 || est.PerDayManual <= 0 || est.PerDayAutoReject <= 0 || est.PerDayAutoApprove <= 0 {
		t.Fatalf("estimate: %+v", est)
	}
	var est2 = est
	ad.must("GET", "/admin/v1/moderation/estimate?auto_approve_below=80&auto_reject_above=90", nil, &est2)
	if est2.PerDayManual >= est.PerDayManual || est2.PerDayAutoApprove <= est.PerDayAutoApprove {
		t.Fatalf("estimate at 80: %+v vs %+v", est2, est)
	}
	ad.expectErr("GET", "/admin/v1/moderation/estimate?auto_approve_below=90&auto_reject_above=20", nil, 400, "invalid_body")

	// Decide: masked approval drops the flagged image and masks the contact.
	type decided struct {
		Task aiTask  `json:"task"`
		Next *aiTask `json:"next"`
	}
	var dr decided
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/decide", rt.ID), map[string]any{"action": "approve_masked"}, &dr)
	if dr.Task.Status != "approved" || dr.Next == nil || dr.Next.Status != "pending" || dr.Next.ID == rt.ID {
		t.Fatalf("masked: %+v", dr)
	}
	b.must("GET", fmt.Sprintf("/v1/posts/%d", risky.ID), nil, &risky)
	if strings.Contains(risky.Content, "wxid") || !strings.Contains(risky.Content, "***") || len(risky.Images) != 0 {
		t.Fatalf("masked post: %+v", risky)
	}
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/reviews/%d/decide", rt.ID), map[string]any{"action": "approve"}, 409, "already_reviewed")
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/reviews/%d/decide", st.ID), map[string]any{"action": "nope"}, 400, "invalid_body")
	ad.expectErr("POST", fmt.Sprintf("/admin/v1/reviews/%d/decide", st.ID), map[string]any{"action": "approve_hide_endpoints"}, 400, "not_supported")

	// Hide endpoints: the post's track now starts ≥ 500 m from the run start.
	var startLL geo.LatLng
	if err := e.app.Pool.QueryRow(ctx, `SELECT lat, lng FROM src.src_act_loop_track_point WHERE activity_id=$1 ORDER BY seq LIMIT 1`, actID).Scan(&startLL.Lat, &startLL.Lng); err != nil {
		t.Fatal(err)
	}
	b.must("GET", fmt.Sprintf("/v1/posts/%d", reportPost), nil, &risky) // same activity, the author's 200 m
	near := geo.Haversine(startLL, geo.LatLng{Lat: risky.Activity.Track[0][1], Lng: risky.Activity.Track[0][0]})
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/decide", ht.ID), map[string]any{"action": "approve_hide_endpoints"}, &dr)
	b.must("GET", fmt.Sprintf("/v1/posts/%d", withAct.ID), nil, &withAct)
	far := geo.Haversine(startLL, geo.LatLng{Lat: withAct.Activity.Track[0][1], Lng: withAct.Activity.Track[0][0]})
	if dr.Task.Status != "approved" || withAct.ReviewStatus != "approved" || near > 400 || far < 450 {
		t.Fatalf("hide endpoints: %+v, start %.0f m vs %.0f m", dr.Task, near, far)
	}

	// Reject and mute; next is null at the end of the queue.
	var cpost socPost
	c.must("POST", "/v1/posts", map[string]any{"content": "加我微信 wxid_zzz12345 带你跑"}, &cpost)
	ct := aiTaskOf(t, ad, "post", cpost.ID, "pending")
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/decide", st.ID), map[string]any{"action": "reject", "reason": "引流"}, &dr)
	if dr.Task.Status != "rejected" || dr.Next == nil || dr.Next.ID != ct.ID {
		t.Fatalf("reject: %+v", dr)
	}
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/decide", ct.ID), map[string]any{"action": "reject_mute", "reason": "引流", "mute_days": 3}, &dr)
	if dr.Task.Status != "rejected" || dr.Next != nil {
		t.Fatalf("reject_mute: %+v", dr)
	}
	c.expectErr("POST", "/v1/posts", map[string]any{"content": "我又来了"}, 403, "muted")
	var audited int
	if err := e.app.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_sys_loop_audit_log WHERE action IN ('review.approve_masked','review.approve_hide_endpoints','review.reject_mute')`).Scan(&audited); err != nil || audited != 3 {
		t.Fatalf("decide audit: %d %v", audited, err)
	}
	// The old endpoints still work.
	var old socPost
	a.must("POST", "/v1/posts", map[string]any{"content": "微信 oldflow1 测试"}, &old)
	ad.must("POST", fmt.Sprintf("/admin/v1/reviews/%d/approve", aiTaskOf(t, ad, "post", old.ID, "pending").ID), nil, nil)

	// AI off: rules only.
	ad.must("PUT", "/admin/v1/moderation/settings", map[string]any{"ai_enabled": false}, nil)
	n := len(fake.requests("【内容审核】"))
	a.must("POST", "/v1/posts", map[string]any{"content": "违法违规大礼包 again"}, &old)
	if old.ReviewStatus != "approved" || len(fake.requests("【内容审核】")) != n {
		t.Fatalf("ai disabled: %+v", old)
	}

	// --- Usage (admin, ops).
	var usage struct {
		Days []struct {
			Date    string `json:"date"`
			Calls   int    `json:"calls"`
			Failed  int    `json:"failed"`
			CostFen *int64 `json:"cost_fen"`
		} `json:"days"`
		ByFeature []struct {
			Feature      string `json:"feature"`
			Calls        int    `json:"calls"`
			Failed       int    `json:"failed"`
			AvgLatencyMs int    `json:"avg_latency_ms"`
			PromptTokens int64  `json:"prompt_tokens"`
			CostFen      *int64 `json:"cost_fen"`
		} `json:"by_feature"`
		Quota struct {
			UsersHitLimitThisWeek int `json:"users_hit_limit_this_week"`
		} `json:"quota"`
	}
	ops.must("GET", "/admin/v1/ai/usage?days=7", nil, &usage)
	byF := map[string]int{}
	for _, f := range usage.ByFeature {
		byF[f.Feature] = f.Calls
		if f.Calls > 0 && (f.CostFen == nil || f.PromptTokens == 0) {
			t.Fatalf("feature %+v", f)
		}
	}
	if len(usage.Days) != 7 || usage.Days[6].Calls == 0 || usage.Days[6].CostFen == nil || byF["chat"] < 5 || byF["route"] < 2 || byF["report"] != 3 ||
		byF["moderation"] < 5 || usage.Quota.UsersHitLimitThisWeek != 1 {
		t.Fatalf("usage: %+v", usage)
	}
	var calls struct {
		Items []struct {
			Feature string `json:"feature"`
			User    *struct {
				ID int64 `json:"id"`
			} `json:"user"`
			Model     string  `json:"model"`
			Status    string  `json:"status"`
			Error     *string `json:"error"`
			LatencyMs int     `json:"latency_ms"`
		} `json:"items"`
		Total int `json:"total"`
	}
	ad.must("GET", "/admin/v1/ai/calls?feature=moderation&status=failed", nil, &calls)
	if calls.Total < 1 || calls.Items[0].Error == nil || *calls.Items[0].Error != "timeout" || calls.Items[0].User.ID != aid {
		t.Fatalf("failed calls: %+v", calls)
	}
	ad.must("GET", "/admin/v1/ai/calls?feature=chat", nil, &calls)
	if calls.Total < 5 || calls.Items[0].Model == "" || calls.Items[0].Status != "ok" {
		t.Fatalf("chat calls: %+v", calls)
	}
	ad.expectErr("GET", "/admin/v1/ai/calls?feature=nope", nil, 400, "invalid_body")

	// --- Unavailable outside dev without a model.
	ad.must("PUT", "/admin/v1/providers/ai", map[string]any{"enabled": false}, nil)
	e.app.AI.Dev = false
	defer func() { e.app.AI.Dev = true }()
	b.expectErr("POST", "/v1/ai/chat", map[string]any{"content": "在吗"}, 503, "ai_unavailable")
	b.expectErr("GET", q, nil, 503, "ai_unavailable")
	b.must("GET", "/v1/ai/info", nil, &info)
	var feat Features
	e.anon().must("GET", "/v1/config/features", nil, &feat)
	if info.Enabled || feat.AI {
		t.Fatalf("unavailable: %+v %+v", info, feat)
	}
}

// TestAIDevMock: in dev with nothing configured the mock model demonstrates
// every feature.
func TestAIDevMock(t *testing.T) {
	e := newEnv(t)
	a, _ := e.member("13900000011")
	var feat Features
	e.anon().must("GET", "/v1/config/features", nil, &feat)
	if !feat.AI {
		t.Fatal("features.ai off in dev")
	}
	var info struct {
		Enabled   bool   `json:"enabled"`
		ModelName string `json:"model_name"`
		Vision    bool   `json:"vision"`
	}
	a.must("GET", "/v1/ai/info", nil, &info)
	if !info.Enabled || info.ModelName != "开发环境模拟 AI" || !info.Vision {
		t.Fatalf("mock info: %+v", info)
	}
	evs := a.stream(map[string]any{"content": "帮我规划圈地路线", "lat": origin.Lat, "lng": origin.Lng})
	var kinds []string
	var done aiChat
	for _, ev := range evs {
		if len(kinds) == 0 || kinds[len(kinds)-1] != ev.Event {
			kinds = append(kinds, ev.Event)
		}
		if ev.Event == "done" {
			_ = json.Unmarshal(ev.Data, &done)
		}
	}
	if !slices.Equal(kinds, []string{"card", "delta", "done"}) || len(done.Message.Cards) == 0 || !strings.Contains(done.Message.Content, "模拟 AI") {
		t.Fatalf("mock stream: %v %+v", kinds, done.Message)
	}
	var res aiChat
	a.must("POST", "/v1/ai/chat", map[string]any{"content": "附近有怪兽吗"}, &res)
	if !strings.Contains(res.Message.Content, "模拟 AI") {
		t.Fatalf("mock tool answer: %+v", res.Message)
	}
	var routes struct {
		Items []aiRoute `json:"items"`
	}
	a.must("GET", fmt.Sprintf("/v1/ai/routes?lat=%f&lng=%f", origin.Lat, origin.Lng), nil, &routes)
	if len(routes.Items) != 1 || !routes.Items[0].AIGenerated || !strings.Contains(routes.Items[0].Reason, "模拟") {
		t.Fatalf("mock routes: %+v", routes)
	}
	st := a.upload("dev-mock", false, square(0, 300, 150)...)
	var rep struct {
		Text string `json:"text"`
	}
	a.must("POST", fmt.Sprintf("/v1/activities/%d/ai-report", st.activityID), nil, &rep)
	if !strings.Contains(rep.Text, "模拟战报") || !strings.Contains(rep.Text, "公里") {
		t.Fatalf("mock report: %q", rep.Text)
	}
	var p socPost
	a.must("POST", "/v1/posts", map[string]any{"content": "今天跑得很开心"}, &p)
	var model string
	if err := e.app.Pool.QueryRow(context.Background(), `SELECT ai_model FROM src.src_cnt_loop_review_task WHERE target_type='post' AND target_id=$1`, p.ID).Scan(&model); err != nil ||
		p.ReviewStatus != "approved" || model != "开发环境模拟 AI" {
		t.Fatalf("mock moderation: %+v %q %v", p, model, err)
	}
	var mocked int
	if err := e.app.Pool.QueryRow(context.Background(), `SELECT count(*) FROM src.src_sys_loop_ai_call WHERE is_mock`).Scan(&mocked); err != nil || mocked < 4 {
		t.Fatalf("mock calls recorded: %d %v", mocked, err)
	}
}
