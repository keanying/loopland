package moderation

import (
	"context"
	"testing"
	"time"
)

func TestCheck(t *testing.T) {
	m := &Moderator{settings: Settings{BlockWords: []string{"赌博"}, ReviewWords: []string{"代跑"}, AutoApproveBelow: 30}, loaded: time.Now().Add(time.Hour)}
	ctx := context.Background()
	cases := []struct {
		text    string
		img     bool
		score   int
		blocked bool
	}{
		{"今天绕世纪公园跑了 5 公里", false, 0, false},
		{"线上赌 博 来", false, 100, true},
		{"接单代-跑，价格私聊", false, 70, false},
		{"加微信 run_abc123 一起跑", false, 50, false},
		{"打我电话13812345678", false, 50, false},
		{"看这里 https://x.cn/a", false, 50, false},
		{"新人报到", true, 20, false},
	}
	for _, c := range cases {
		sc := m.Check(ctx, c.text, c.img)
		if sc.Value != c.score || sc.Blocked != c.blocked {
			t.Errorf("%q: got %d blocked=%v, want %d blocked=%v (%v)", c.text, sc.Value, sc.Blocked, c.score, c.blocked, sc.Reasons)
		}
	}
	if !m.NeedsReview(ctx, Score{Value: 30}) || m.NeedsReview(ctx, Score{Value: 29}) {
		t.Error("threshold")
	}
}

func TestMaskAndOutcome(t *testing.T) {
	got := Mask("加我微信 wxid_abc12345，电话13812345678，代跑便宜", []string{"代跑"})
	if got != "加我****************，电话***********，**便宜" {
		t.Fatalf("mask: %q", got)
	}
	m := &Moderator{settings: DefaultSettings, loaded: time.Now().Add(time.Hour)}
	ctx := context.Background()
	for score, want := range map[int]string{0: OutcomeApprove, 19: OutcomeApprove, 20: OutcomeReview, 89: OutcomeReview, 90: OutcomeReject, 100: OutcomeReject} {
		if o := m.Outcome(ctx, Score{Value: score}); o != want {
			t.Errorf("outcome(%d) = %s, want %s", score, o, want)
		}
	}
	v := Verdict{RiskScore: 130, Labels: []string{"ad", "bogus", "ad"}, Confidence: 3, Suggestion: "nope"}
	v.Normalize()
	if v.RiskScore != 100 || len(v.Labels) != 1 || v.Confidence != 1 || v.Suggestion != "reject" {
		t.Fatalf("normalize: %+v", v)
	}
}

type fakeClassifier struct {
	v   *Verdict
	err error
}

func (f fakeClassifier) Classify(ctx context.Context, c Content) (*Verdict, error) {
	return f.v, f.err
}

func TestReviewWithAI(t *testing.T) {
	ctx := context.Background()
	m := &Moderator{settings: DefaultSettings, loaded: time.Now().Add(time.Hour), AITimeout: 50 * time.Millisecond}
	m.AI = fakeClassifier{v: &Verdict{RiskScore: 85, Labels: []string{"ad"}, Suggestion: "reject"}}
	sc := m.Review(ctx, Content{Target: Post, Text: "加我微信 wxid_abc12345"})
	if sc.Rule != 50 || sc.Value != 85 || sc.AI == nil || sc.AIRetry {
		t.Fatalf("ai score: %+v", sc)
	}
	m.AI = fakeClassifier{v: &Verdict{RiskScore: 5}}
	if sc := m.Review(ctx, Content{Target: Post, Text: "加我微信 wxid_abc12345"}); sc.Value != 50 {
		t.Fatalf("max(rule, ai): %+v", sc)
	}
	m.AI = slowClassifier{}
	if sc := m.Review(ctx, Content{Target: Post, Text: "你好"}); !sc.AIRetry || sc.AI != nil || sc.Value != 0 {
		t.Fatalf("timeout: %+v", sc)
	}
	m.AI = fakeClassifier{err: ErrNoAI}
	if sc := m.Review(ctx, Content{Target: Post, Text: "你好"}); sc.AIRetry || sc.AI != nil {
		t.Fatalf("no ai: %+v", sc)
	}
	m.settings.AIEnabled = false
	m.AI = fakeClassifier{v: &Verdict{RiskScore: 99}}
	if sc := m.Review(ctx, Content{Target: Post, Text: "你好"}); sc.AI != nil {
		t.Fatalf("ai disabled: %+v", sc)
	}
}

type slowClassifier struct{}

func (slowClassifier) Classify(ctx context.Context, c Content) (*Verdict, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}
