package play

import (
	"math"
	"testing"
	"time"

	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/platform/clock"
)

func ptr(i int) *int { return &i }

func TestCampaignMet(t *testing.T) {
	eve := time.Date(2026, 11, 20, 20, 0, 0, 0, clock.Shanghai)
	noon := time.Date(2026, 11, 20, 12, 0, 0, 0, clock.Shanghai)
	run := gameplay.SportRun
	cases := []struct {
		name  string
		typ   string
		rules CampaignRules
		sport gameplay.Sport
		dist  float64
		dur   int
		at    time.Time
		want  bool
	}{
		{"pace ok", "pace", CampaignRules{MinDistanceKm: 5, MaxPaceSPerKm: 360}, run, 5000, 1750, noon, true},
		{"pace slow", "pace", CampaignRules{MinDistanceKm: 5, MaxPaceSPerKm: 360}, run, 5000, 1900, noon, false},
		{"pace short", "pace", CampaignRules{MinDistanceKm: 5, MaxPaceSPerKm: 360}, run, 4000, 1000, noon, false},
		{"night ok", "night_run", CampaignRules{MinDistanceKm: 3, StartHourFrom: ptr(19), StartHourTo: ptr(23)}, run, 3000, 1200, eve, true},
		{"night at noon", "night_run", CampaignRules{MinDistanceKm: 3, StartHourFrom: ptr(19), StartHourTo: ptr(23)}, run, 3000, 1200, noon, false},
		{"distance", "distance", CampaignRules{MinDistanceKm: 10}, gameplay.SportRide, 10000, 1800, noon, true},
		{"indoor never", "distance", CampaignRules{MinDistanceKm: 0}, gameplay.SportYoga, 0, 1800, noon, false},
	}
	for _, c := range cases {
		if got := CampaignMet(c.typ, c.rules, c.sport, c.dist, c.dur, c.at); got != c.want {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}

func TestNight(t *testing.T) {
	for h, want := range map[int]bool{22: false, 23: true, 0: true, 4: true, 5: false, 12: false} {
		if Night(time.Date(2026, 11, 20, h, 30, 0, 0, clock.Shanghai)) != want {
			t.Errorf("hour %d", h)
		}
	}
}

func TestRollIsDeterministicAndFollowsRates(t *testing.T) {
	drops := gameplay.Default().Bosses[0].Drops // 35/20/10/5/30
	if roll(drops, 7, 9, 0) != roll(drops, 7, 9, 0) {
		t.Fatal("roll must be reproducible")
	}
	counts := map[string]int{}
	n := 20000
	for u := 0; u < n; u++ {
		counts[roll(drops, 1, int64(u), 0).Item]++
	}
	for _, d := range drops {
		got := float64(counts[d.Item]) / float64(n) * 100
		if math.Abs(got-d.Percent) > 1.5 {
			t.Errorf("%s: %.1f%%, want %.0f%%", d.Item, got, d.Percent)
		}
	}
}
