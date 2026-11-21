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
