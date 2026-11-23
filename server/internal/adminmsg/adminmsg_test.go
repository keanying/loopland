package adminmsg

import (
	"context"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestYuan(t *testing.T) {
	for amt, want := range map[int64]string{0: "¥0", 4900: "¥49", 6900: "¥69", 180135: "¥1,801.35", 123456789: "¥1,234,567.89", -500: "-¥5", 5: "¥0.05"} {
		if got := Yuan(amt); got != want {
			t.Errorf("Yuan(%d) = %s, want %s", amt, got, want)
		}
	}
}

func TestClip(t *testing.T) {
	long := strings.Repeat("商", 100)
	if c := clip(long, MaxTitle); utf8.RuneCountInString(c) != MaxTitle || !strings.HasSuffix(c, "…") {
		t.Fatalf("clip: %d runes", utf8.RuneCountInString(c))
	}
	if c := clip(" 短 ", MaxTitle); c != "短" {
		t.Fatalf("clip short: %q", c)
	}
}

func TestOutbox(t *testing.T) {
	ctx := WithOutbox(context.Background())
	ran := 0
	ob := ctx.Value(outboxKey{}).(*outbox)
	ob.add(func(context.Context) { ran++ })
	Settle(ctx, false) // dropped
	ob.add(func(context.Context) { ran++ })
	Settle(ctx, true)
	Settle(ctx, true) // nothing left
	if ran != 1 {
		t.Fatalf("ran %d", ran)
	}
	var n *Notifier
	n.ToMerchant(ctx, 1, Msg{}) // nil notifier is a no-op
	n.ToPlatform(ctx, Msg{}, true)
}
