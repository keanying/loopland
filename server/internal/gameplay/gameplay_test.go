package gameplay

import (
	"errors"
	"testing"
)

func TestDefaultConfigIsValid(t *testing.T) {
	if err := Default().Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestValidateRejectsDropTableNot100(t *testing.T) {
	c := Default()
	c.Bosses[0].Drops[0].Percent += 1
	if err := c.Validate(); err == nil {
		t.Fatal("expected error for drop table summing to 101%")
	}
}

func TestRawEnergy(t *testing.T) {
	c := Default()
	cases := []struct {
		s    Sport
		amt  float64
		want int
	}{
		{SportRun, 5, 50},     // 跑 5 km 得 50 能量
		{SportRun, 5.37, 53},  // rounds down
		{SportRide, 20, 80},   // 4 / km
		{SportSwim, 1500, 45}, // 3 / 100 m
		{SportVenue, 1, 20},   // 20 / 次
		{SportStrength, 45, 22},
		{SportRope, 1000, 20},
		{SportRun, -1, 0},
	}
	for _, tc := range cases {
		got, err := c.RawEnergy(tc.s, tc.amt)
		if err != nil || got != tc.want {
			t.Errorf("RawEnergy(%s, %v) = %d, %v; want %d", tc.s, tc.amt, got, err, tc.want)
		}
	}
	if _, err := c.RawEnergy("curling", 1); !errors.Is(err, ErrUnknownSport) {
		t.Fatalf("err = %v", err)
	}
}

func TestGrantDailyCap(t *testing.T) {
	c := Default()
	if g := c.Grant(100, 0); g != 100 {
		t.Fatal(g)
	}
	if g := c.Grant(100, 550); g != 50 {
		t.Fatal(g)
	}
	if g := c.Grant(100, 600); g != 0 {
		t.Fatal(g)
	}
	if g := c.Grant(100, 700); g != 0 {
		t.Fatal(g)
	}
}

func TestFiveKmIsNotQuiteACampfire(t *testing.T) {
	// 数值节奏: 跑 5 km 得 50 能量，刚好不够建一座营火（80），跑 2 次能建。
	c := Default()
	e, _ := c.RawEnergy(SportRun, 5)
	if len(c.Affordable(e)) != 0 {
		t.Fatal("5 km should not afford anything")
	}
	if a := c.Affordable(2 * e); len(a) != 1 || a[0].Key != "campfire" {
		t.Fatalf("10 km affords %+v", a)
	}
}

func TestGuardAndYield(t *testing.T) {
	c := Default()
	tr := Territory{Buildings: []string{"tower", "mill", "chapel"}, Stationed: []string{"archer", "farmer", "monk"}}
	// (300+40+200) * 1.05 = 567
	if g := c.Guard(tr); g != 567 {
		t.Fatalf("guard = %d", g)
	}
	// mill 40*1.12=44.8 + chapel 50 + tower 10 + monk 10 = 114.8 → 114
	if y := c.DailyEnergy(tr); y != 114 {
		t.Fatalf("daily = %d", y)
	}
}

func TestBuild(t *testing.T) {
	c := Default()
	tr := Territory{Stationed: []string{"smith"}}
	cost, err := c.CheckBuild(tr, "campfire", 1, 100)
	if err != nil || cost != 76 { // ceil(80*0.94)=76
		t.Fatalf("cost=%d err=%v", cost, err)
	}
	if _, err := c.CheckBuild(tr, "tower", 4, 1000); !errors.Is(err, ErrLevelTooLow) {
		t.Fatalf("err = %v", err)
	}
	if _, err := c.CheckBuild(Territory{}, "tower", 5, 319); !errors.Is(err, ErrNotEnoughEnergy) {
		t.Fatalf("err = %v", err)
	}
	full := Territory{Buildings: []string{"campfire", "campfire", "tent", "tent", "well", "well"}}
	if _, err := c.CheckBuild(full, "campfire", 9, 1000); !errors.Is(err, ErrNoFreeSlot) {
		t.Fatalf("err = %v", err)
	}
}

func TestAttack(t *testing.T) {
	if r := Attack(50, 0); !r.Captured {
		t.Fatal("unowned land is taken by any energy")
	}
	if r := Attack(50, 50); r.Captured || r.GuardAfter != 0 {
		t.Fatalf("equal energy must not capture: %+v", r)
	}
	if r := Attack(50, 120); r.Captured || r.GuardAfter != 70 {
		t.Fatalf("got %+v", r)
	}
	if r := Attack(121, 120); !r.Captured {
		t.Fatal("energy above guard captures")
	}
}

func TestLevelAndStationSlots(t *testing.T) {
	c := Default()
	for earned, want := range map[int64]int{0: 1, 199: 1, 200: 2, 3199: 5, 3200: 6, 99999: 6} {
		if got := c.Level(earned); got != want {
			t.Errorf("Level(%d) = %d, want %d", earned, got, want)
		}
	}
	if n := c.StationSlots([]string{"tent", "house", "campfire"}); n != 4 {
		t.Fatalf("station slots = %d, want 4", n)
	}
}
