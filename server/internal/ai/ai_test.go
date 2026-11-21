package ai

import (
	"context"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/platform/clock"
)

func TestParseStream(t *testing.T) {
	stream := strings.Join([]string{
		": keep-alive",
		`data: {"choices":[{"delta":{"role":"assistant","content":"往东"}}]}`,
		"",
		`data: {"choices":[{"delta":{"content":"绕一圈"}}]}`,
		"",
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"plan_","arguments":"{\"sport\":"}}]}}]}`,
		"",
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"route","arguments":"\"run\"}"}}]}}]}`,
		"",
		`data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_2","function":{"name":"get_my_status","arguments":"{}"}}]}}]}`,
		"",
		`data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
		"",
		`data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":30}}`,
		"",
		"data: [DONE]",
		"",
		`data: {"choices":[{"delta":{"content":"after done"}}]}`,
		"",
	}, "\n")
	var deltas []string
	resp, err := ParseStream(strings.NewReader(stream), func(d string) { deltas = append(deltas, d) })
	if err != nil {
		t.Fatal(err)
	}
	if resp.Content != "往东绕一圈" || strings.Join(deltas, "|") != "往东|绕一圈" {
		t.Fatalf("content %q deltas %v", resp.Content, deltas)
	}
	if len(resp.ToolCalls) != 2 || resp.ToolCalls[0].ID != "call_1" || resp.ToolCalls[0].Function.Name != "plan_route" ||
		resp.ToolCalls[0].Function.Arguments != `{"sport":"run"}` || resp.ToolCalls[1].Function.Name != "get_my_status" || resp.ToolCalls[1].Type != "function" {
		t.Fatalf("tool calls: %+v", resp.ToolCalls)
	}
	if resp.FinishReason != "tool_calls" || resp.Usage.PromptTokens != 120 || resp.Usage.CompletionTokens != 30 {
		t.Fatalf("finish/usage: %+v", resp)
	}

	// CRLF line ends, a stream without [DONE], an error chunk.
	resp, err = ParseStream(strings.NewReader("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}"), nil)
	if err != nil || resp.Content != "ab" {
		t.Fatalf("crlf: %q %v", resp.Content, err)
	}
	if _, err := ParseStream(strings.NewReader("data: {\"error\":{\"message\":\"quota\"}}\n\n"), nil); err == nil || !strings.Contains(err.Error(), "quota") {
		t.Fatalf("error chunk: %v", err)
	}
	if _, err := ParseStream(strings.NewReader("data: {not json}\n\n"), nil); err == nil {
		t.Fatal("bad chunk accepted")
	}
}

func TestOpenAIClient(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer k" || r.URL.Path != "/v1/chat/completions" {
			w.WriteHeader(401)
			io.WriteString(w, `{"error":{"message":"bad key"}}`)
			return
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		if got["stream"] == true {
			w.Header().Set("Content-Type", "text/event-stream")
			io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\"嗨\"}}]}\n\ndata: [DONE]\n\n")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"choices":[{"message":{"content":"{\"risk_score\":5}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":3}}`)
	}))
	defer srv.Close()
	c := &OpenAI{BaseURL: srv.URL + "/v1/", APIKey: "k"}
	resp, err := c.Chat(context.Background(), Request{Model: "m", JSON: true, Messages: []Message{{Role: "user", Content: []Part{
		{Type: "text", Text: "看图"}, {Type: "image_url", ImageURL: &ImageURL{URL: "data:image/png;base64,AAAA"}}}}}}, nil)
	if err != nil || resp.Content != `{"risk_score":5}` || resp.Usage.PromptTokens != 9 {
		t.Fatalf("%+v %v", resp, err)
	}
	if rf, _ := got["response_format"].(map[string]any); rf["type"] != "json_object" {
		t.Fatalf("json mode not requested: %v", got)
	}
	parts := got["messages"].([]any)[0].(map[string]any)["content"].([]any)
	if parts[1].(map[string]any)["image_url"].(map[string]any)["url"] != "data:image/png;base64,AAAA" {
		t.Fatalf("image part: %v", parts)
	}
	var d strings.Builder
	resp, err = c.Chat(context.Background(), Request{Model: "m", Messages: []Message{{Role: "user", Content: "hi"}},
		Tools: []Tool{{Type: "function", Function: FunctionDef{Name: "x", Parameters: json.RawMessage(noParams)}}}, ToolChoice: "none"}, func(s string) { d.WriteString(s) })
	if err != nil || resp.Content != "嗨" || d.String() != "嗨" || got["tool_choice"] != "none" || got["stream_options"] == nil {
		t.Fatalf("stream: %+v %v %v", resp, err, got)
	}
	bad := &OpenAI{BaseURL: srv.URL + "/v1", APIKey: "wrong"}
	if _, err := bad.Chat(context.Background(), Request{Model: "m"}, nil); err == nil || !strings.Contains(err.Error(), "401 bad key") {
		t.Fatalf("api error: %v", err)
	}
}

// scripted is an LLM that asks for a tool every round.
type scripted struct {
	reqs []Request
	// tools is how many rounds ask for a tool before answering.
	tools int
}

func (s *scripted) Chat(_ context.Context, req Request, onDelta func(string)) (Response, error) {
	s.reqs = append(s.reqs, req)
	if len(s.reqs) <= s.tools && req.ToolChoice != "none" {
		return Response{ToolCalls: []ToolCall{{ID: "c", Type: "function", Function: FunctionCall{Name: "plan_route", Arguments: `{"x":1}`}},
			{ID: "d", Type: "function", Function: FunctionCall{Name: "nope", Arguments: "not json"}}}, Usage: Usage{PromptTokens: 10, CompletionTokens: 2}}, nil
	}
	if onDelta != nil {
		onDelta("好的")
		onDelta("，出发")
	}
	return Response{Content: "好的，出发", Usage: Usage{PromptTokens: 10, CompletionTokens: 2}}, nil
}

func TestRunTools(t *testing.T) {
	ts := &Toolset{}
	calls := 0
	ts.add("plan_route", "", noParams, func(_ context.Context, args json.RawMessage) (any, []Card, error) {
		calls++
		if string(args) != `{"x":1}` {
			t.Errorf("args %s", args)
		}
		return map[string]int{"routes": 1}, []Card{{Type: "route", Route: &Route{ID: "r_1"}}}, nil
	})
	run := func(llm *scripted) (Response, []Card, []Card, string) {
		var streamed []Card
		var text strings.Builder
		call := func(ctx context.Context, r Request, d func(string)) (Response, error) { return llm.Chat(ctx, r, d) }
		resp, cards, err := RunTools(context.Background(), call, Request{Model: "m", Messages: []Message{{Role: "user", Content: "去哪抢地"}}}, ts, MaxToolRounds,
			func(d string) { text.WriteString(d) }, func(c Card) { streamed = append(streamed, c) })
		if err != nil {
			t.Fatal(err)
		}
		return resp, cards, streamed, text.String()
	}

	// One tool round, then the answer.
	llm := &scripted{tools: 1}
	resp, cards, streamed, text := run(llm)
	if len(llm.reqs) != 2 || resp.Content != "好的，出发" || text != "好的，出发" || len(cards) != 1 || len(streamed) != 1 || calls != 1 {
		t.Fatalf("one round: %d reqs, %+v, %d cards", len(llm.reqs), resp, len(cards))
	}
	if resp.Usage.PromptTokens != 20 || resp.Usage.CompletionTokens != 4 {
		t.Fatalf("usage: %+v", resp.Usage)
	}
	second := llm.reqs[1].Messages
	if len(second) != 4 || second[1].Role != "assistant" || len(second[1].ToolCalls) != 2 || second[2].Role != "tool" || second[2].ToolCallID != "c" ||
		second[3].Text() != `{"error":"没有这个工具：nope"}` {
		t.Fatalf("tool messages: %+v", second)
	}

	// A model that never stops calling tools gets 3 rounds, then must answer.
	calls = 0
	llm = &scripted{tools: 99}
	resp, cards, _, _ = run(llm)
	if len(llm.reqs) != MaxToolRounds+1 || llm.reqs[MaxToolRounds].ToolChoice != "none" || calls != MaxToolRounds || len(cards) != MaxToolRounds || resp.Content == "" {
		t.Fatalf("bounded loop: %d reqs, %d calls, last choice %q", len(llm.reqs), calls, llm.reqs[len(llm.reqs)-1].ToolChoice)
	}
	for _, r := range llm.reqs[:MaxToolRounds] {
		if r.ToolChoice != "" || len(r.Tools) != 1 {
			t.Fatalf("tools not offered: %+v", r)
		}
	}
}

func TestPlan(t *testing.T) {
	origin := LatLng{Lat: 31.2304, Lng: 121.4737}
	proj := geo.NewProjection(origin)
	at := func(x, y float64) LatLng { return proj.Inverse(geo.Point{X: x, Y: y}) }
	now := time.Now()
	in := PlanInput{Origin: origin, Sport: "run", DistanceM: 5000, PaceSecPerKm: 360, MaxM: 15000, Now: now,
		Capture: []Candidate{
			{ID: 1, Name: "远处弱地", Center: at(2500, 0), DistanceM: 2500, Guard: 10, AreaM2: 10000},
			{ID: 2, Name: "近处弱地", Center: at(0, 600), DistanceM: 600, Guard: 20, AreaM2: 10000, Crew: "城西跑团"},
			{ID: 3, Name: "近处强地", Center: at(0, -500), DistanceM: 500, Guard: 900, AreaM2: 10000},
		},
		Defend: []Candidate{{ID: 7, Name: "我的地", Center: at(-300, 0), DistanceM: 300, AreaM2: 4000, Guard: 40, Deadline: now.Add(5 * time.Hour)},
			{ID: 8, Name: "更急的地", Center: at(-800, 0), DistanceM: 800, AreaM2: 4000, Guard: 30, Deadline: now.Add(2 * time.Hour)}},
		Bosses: []Candidate{{ID: 5, Name: "沙发怪", Center: at(1500, 1500), DistanceM: 2121, HP: 1200, MaxHP: 5000, RadiusM: 500, EndsAt: now.Add(3 * time.Hour)},
			{ID: 6, Name: "熬夜蝠", Center: at(-900, 0), DistanceM: 900, HP: 100, MaxHP: 3000, RadiusM: 300, EndsAt: now.Add(time.Hour)}},
	}
	routes := Plan(in)
	if len(routes) != 4 || routes[0].Type != RouteLoop || routes[1].Type != RouteCapture || routes[2].Type != RouteDefend || routes[3].Type != RouteBoss {
		t.Fatalf("routes: %+v", routes)
	}
	loop := routes[0]
	if math.Abs(float64(loop.DistanceM)-5000) > 5000*0.25 {
		t.Fatalf("loop length %d", loop.DistanceM)
	}
	first, last := loop.Waypoints[0], loop.Waypoints[len(loop.Waypoints)-1]
	if geo.Haversine(first, origin) > 1 || geo.Haversine(last, origin) > 1 || len(loop.Polyline) != len(loop.Waypoints) {
		t.Fatalf("loop not closed at the origin: %v … %v", first, last)
	}
	if loop.EstAreaM2 < 1_000_000 || loop.EstAreaM2 > 2_500_000 || loop.EstDurationSec != int(math.Round(float64(loop.DistanceM)/1000*360)) {
		t.Fatalf("loop area/duration: %d / %d", loop.EstAreaM2, loop.EstDurationSec)
	}
	if routes[1].Targets[0].ID != 2 || !strings.Contains(routes[1].Targets[0].Note, "城西跑团") || routes[1].Title != "抢下「近处弱地」" {
		t.Fatalf("capture: %+v", routes[1])
	}
	if routes[2].Targets[0].ID != 8 || routes[3].Targets[0].ID != 6 {
		t.Fatalf("defend/boss: %+v / %+v", routes[2].Targets, routes[3].Targets)
	}
	for _, r := range routes[1:] {
		if geo.Haversine(r.Waypoints[0], origin) > 1 || geo.Haversine(r.Waypoints[len(r.Waypoints)-1], origin) > 1 {
			t.Fatalf("%s does not start and end at the origin", r.Type)
		}
	}

	// Lost land is preferred; long routes are dropped; nothing → loop only.
	in.Capture[0].Lost = true
	in.Capture[0].DistanceM = 650
	in.Capture[0].Center = at(650, 0)
	if r := Plan(in)[1]; r.Targets[0].ID != 1 || r.Title != "夺回「远处弱地」" {
		t.Fatalf("lost land: %+v", r)
	}
	far := PlanInput{Origin: origin, Sport: "ride", DistanceM: 50000, MaxM: 15000,
		Bosses: []Candidate{{ID: 9, Name: "远怪", Center: at(20000, 0), DistanceM: 20000, RadiusM: 500}}}
	rs := Plan(far)
	if len(rs) != 1 || rs[0].Type != RouteLoop || rs[0].DistanceM > 15000*1.01 {
		t.Fatalf("far: %+v", rs)
	}
}

func TestWeekStart(t *testing.T) {
	sh := clock.Shanghai
	cases := []struct{ at, want time.Time }{
		{time.Date(2026, 11, 22, 23, 59, 59, 0, sh), time.Date(2026, 11, 16, 0, 0, 0, 0, sh)},      // Sunday night
		{time.Date(2026, 11, 23, 0, 0, 0, 0, sh), time.Date(2026, 11, 23, 0, 0, 0, 0, sh)},         // Monday 00:00
		{time.Date(2026, 11, 22, 16, 30, 0, 0, time.UTC), time.Date(2026, 11, 23, 0, 0, 0, 0, sh)}, // Monday 00:30 in Shanghai
		{time.Date(2026, 11, 22, 15, 59, 0, 0, time.UTC), time.Date(2026, 11, 16, 0, 0, 0, 0, sh)}, // still Sunday in Shanghai
		{time.Date(2026, 11, 25, 12, 0, 0, 0, sh), time.Date(2026, 11, 23, 0, 0, 0, 0, sh)},
	}
	for _, c := range cases {
		if got := WeekStart(c.at); !got.Equal(c.want) {
			t.Errorf("WeekStart(%v) = %v, want %v", c.at, got, c.want)
		}
	}
	if got := WeekStart(time.Date(2026, 11, 21, 10, 0, 0, 0, sh)).AddDate(0, 0, 7).UTC().Format(time.RFC3339); got != "2026-11-22T16:00:00Z" {
		t.Errorf("resets_at %s", got)
	}
}

func TestMockToolLoop(t *testing.T) {
	ts := &Toolset{}
	ts.add("plan_route", "", noParams, func(context.Context, json.RawMessage) (any, []Card, error) {
		return map[string]any{"routes": []map[string]any{{"title": "AI 推荐闭环", "distance_km": 5, "minutes": 32}}}, []Card{{Type: "route"}}, nil
	})
	var deltas []string
	call := func(ctx context.Context, r Request, d func(string)) (Response, error) { return Mock{}.Chat(ctx, r, d) }
	resp, cards, err := RunTools(context.Background(), call, Request{Messages: []Message{{Role: "system", Content: promptAssistant}, {Role: "user", Content: "今晚去哪抢地？"}}},
		ts, MaxToolRounds, func(d string) { deltas = append(deltas, d) }, nil)
	if err != nil || len(cards) != 1 || !strings.Contains(resp.Content, "AI 推荐闭环") || len(deltas) < 2 {
		t.Fatalf("mock: %+v %v %d deltas", resp, err, len(deltas))
	}
}
