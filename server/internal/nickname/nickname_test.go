package nickname

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestDefaultNicknames(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < Count; i++ {
		n := pick(i)
		if !strings.HasPrefix(n, Prefix) {
			t.Fatalf("%q has no prefix", n)
		}
		if l := utf8.RuneCountInString(n); l < 2 || l > 16 {
			t.Fatalf("%q length %d outside 2–16", n, l)
		}
		seen[n] = true
	}
	if len(seen) != Count {
		t.Fatalf("%d distinct of %d", len(seen), Count)
	}
	if ForID(42) != ForID(42) || ForID(1) == ForID(2) {
		t.Fatal("ForID not stable / not spread")
	}
	for i := 0; i < 50; i++ {
		if n := Random(); !seen[n] {
			t.Fatalf("Random gave %q", n)
		}
	}
}
