package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// Mock is the deterministic dev model (「开发环境模拟 AI」): template answers,
// a minimal tool loop (it calls the matching tool once, then summarises the
// result) and streamed deltas, so every AI feature can be demonstrated
// without a configured model.
type Mock struct{}

var mockToolRules = []struct {
	words []string
	tool  string
}{
	{[]string{"路线", "抢地", "去哪", "圈地", "规划", "闭环", "开跑"}, "plan_route"},
	{[]string{"怪兽", "怪物", "boss", "宝箱", "打怪"}, "get_nearby_bosses"},
	{[]string{"附近", "守卫", "被抢", "加固"}, "get_nearby_targets"},
	{[]string{"规则", "怎么玩", "合击", "守地", "换算"}, "get_game_rules"},
	{[]string{"跑多少", "训练", "计划", "建议", "配速"}, "get_training_advice"},
	{[]string{"状态", "能量", "排名", "战报", "领地", "跑团"}, "get_my_status"},
}

// Chat implements LLM.
func (Mock) Chat(ctx context.Context, req Request, onDelta func(string)) (Response, error) {
	if err := ctx.Err(); err != nil {
		return Response{}, err
	}
	sys := ""
	if len(req.Messages) > 0 && req.Messages[0].Role == "system" {
		sys = req.Messages[0].Text()
	}
	last := Message{}
	if len(req.Messages) > 0 {
		last = req.Messages[len(req.Messages)-1]
	}
	var resp Response
	switch {
	case strings.Contains(sys, "【内容审核】"):
		resp.Content = mockModeration(req.Messages)
	case strings.Contains(sys, "【路线解释】"):
		n := strings.Count(strings.TrimSpace(last.Text()), "\n") + 1
		var rs []string
		for i := 0; i < n; i++ {
			rs = append(rs, "（模拟）这条路线距离合适，顺路还能拿下目标，冲！")
		}
		raw, _ := json.Marshal(map[string]any{"reasons": rs})
		resp.Content = string(raw)
	case strings.Contains(sys, "【AI战报】"):
		facts := last.Text()
		if i := strings.Index(facts, "事实："); i >= 0 {
			facts = facts[i+len("事实："):]
		}
		facts = strings.TrimSpace(strings.SplitN(facts, "\n", 2)[0])
		resp.Content = "（模拟战报）" + facts + "，干得漂亮，下次继续圈！"
	case last.Role == "tool":
		resp.Content = mockSummary(req.Messages)
	case len(req.Tools) > 0 && req.ToolChoice != "none":
		q := strings.ToLower(last.Text())
		for _, r := range mockToolRules {
			for _, w := range r.words {
				if strings.Contains(q, w) {
					args := "{}"
					if r.tool == "plan_route" {
						args = `{"sport":"run"}`
					}
					resp.ToolCalls = []ToolCall{{ID: "call_mock_1", Type: "function", Function: FunctionCall{Name: r.tool, Arguments: args}}}
					resp.FinishReason = "tool_calls"
					return resp, nil
				}
			}
		}
		resp.Content = mockDefault(last)
	default:
		resp.Content = mockDefault(last)
	}
	resp.FinishReason = "stop"
	if onDelta != nil {
		r := []rune(resp.Content)
		for i := 0; i < len(r); i += 6 {
			onDelta(string(r[i:min(i+6, len(r))]))
		}
	}
	return resp, nil
}

func mockDefault(last Message) string {
	if last.HasImage() {
		return "（模拟 AI）我看到你发来的图片了。开发环境不会真的识别图片内容，配置视觉模型后我就能看懂它。"
	}
	return "（模拟 AI）我是圈圈，可以帮你规划圈地路线、找附近好抢的地和怪兽、看看今天该跑多少。试试问我「今晚去哪抢地」吧！"
}

// mockSummary answers from the last tool result.
func mockSummary(msgs []Message) string {
	var name, content string
	for i := len(msgs) - 1; i >= 0; i-- {
		if msgs[i].Role == "tool" {
			name, content = msgs[i].Name, msgs[i].Text()
			break
		}
	}
	var m map[string]any
	_ = json.Unmarshal([]byte(content), &m)
	if e, ok := m["error"].(string); ok {
		return "（模拟 AI）" + e
	}
	switch name {
	case "plan_route":
		routes, _ := m["routes"].([]any)
		if len(routes) == 0 {
			return "（模拟 AI）附近暂时没有合适的路线，换个地方再试试。"
		}
		var parts []string
		for _, r := range routes {
			rm, _ := r.(map[string]any)
			parts = append(parts, fmt.Sprintf("「%v」约 %v 公里、%v 分钟", rm["title"], rm["distance_km"], rm["minutes"]))
		}
		return fmt.Sprintf("（模拟 AI）给你规划了 %d 条路线：%s。点下面的卡片就能一键开跑！", len(routes), strings.Join(parts, "；"))
	case "get_nearby_targets":
		weak, _ := m["weak_nearby"].([]any)
		if len(weak) == 0 {
			return "（模拟 AI）附近 3 公里内没有别人的地，先自己圈一块吧。"
		}
		w0, _ := weak[0].(map[string]any)
		return fmt.Sprintf("（模拟 AI）附近有 %d 块别人的地，最好抢的是「%v」，守卫值 %v，离你 %v 公里。", len(weak), w0["name"], w0["guard"], w0["distance_km"])
	case "get_nearby_bosses":
		bosses, _ := m["bosses"].([]any)
		chests, _ := m["chests"].([]any)
		if len(bosses) == 0 {
			return fmt.Sprintf("（模拟 AI）附近暂时没有怪兽出没，有 %d 个宝箱可以顺路开。", len(chests))
		}
		b0, _ := bosses[0].(map[string]any)
		return fmt.Sprintf("（模拟 AI）「%v」就在 %v 公里外，还剩 %v 血，跑进它的范围就能造成伤害！附近还有 %d 个宝箱。", b0["name"], b0["distance_km"], b0["hp"], len(chests))
	case "get_game_rules":
		return fmt.Sprintf("（模拟 AI）简单说：%v；%v。", m["claim"], m["boss"])
	case "get_training_advice":
		return fmt.Sprintf("（模拟 AI）%v 今天建议跑 %v 公里左右。%v", m["note"], m["suggest_km"], m["disclaimer"])
	case "get_my_status":
		return fmt.Sprintf("（模拟 AI）今天你拿了 %v 能量，本周跑了 %v 公里，手里有 %v 块地。", m["today_energy"], m["week_distance_km"], m["territory_count"])
	}
	return "（模拟 AI）查到了，你可以看看上面的卡片。"
}

var (
	mockContact = regexp.MustCompile(`(?i)1[3-9]\d{9}|微信|vx|wx|qq|https?://`)
	mockHigh    = []string{"博彩", "赌球", "裸聊", "代开发票"}
	mockMid     = []string{"代跑", "刷单", "返利", "兼职"}
)

func mockModeration(msgs []Message) string {
	var text string
	var images []string
	for _, m := range msgs {
		if m.Role != "user" {
			continue
		}
		text += m.Text()
		if ps, ok := m.Content.([]Part); ok {
			for _, p := range ps {
				if p.ImageURL != nil {
					images = append(images, p.ImageURL.URL)
				}
			}
		}
	}
	v := map[string]any{"risk_score": 3, "labels": []string{}, "reason": "（模拟）正常的运动分享", "confidence": 0.6, "suggestion": "approve", "bad_images": []int{}}
	hit := func(words []string) bool {
		for _, w := range words {
			if strings.Contains(text, w) {
				return true
			}
		}
		return false
	}
	switch {
	case hit(mockHigh):
		v = map[string]any{"risk_score": 95, "labels": []string{"illegal", "fraud"}, "reason": "（模拟）疑似违法或诈骗内容", "confidence": 0.9, "suggestion": "reject"}
	case hit(mockMid):
		v = map[string]any{"risk_score": 80, "labels": []string{"ad"}, "reason": "（模拟）疑似广告引流", "confidence": 0.8, "suggestion": "review"}
	case mockContact.MatchString(text):
		v = map[string]any{"risk_score": 50, "labels": []string{"contact"}, "reason": "（模拟）含联系方式", "confidence": 0.7, "suggestion": "mask"}
	}
	var bad []int
	for i, u := range images {
		if strings.Contains(u, "nsfw") {
			bad = append(bad, i+1)
		}
	}
	if len(bad) > 0 {
		v["bad_images"] = bad
		v["risk_score"], v["labels"], v["suggestion"] = 92, []string{"porn"}, "mask"
	}
	raw, _ := json.Marshal(v)
	return string(raw)
}
