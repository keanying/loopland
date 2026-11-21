package gameplay

import (
	"encoding/json"
	"testing"
)

func TestRallySettings(t *testing.T) {
	d := Default()
	if d.Rally.BonusRate != 0.2 || d.Rally.MinCheckins != 2 || d.Rally.CheckinRadiusM != 300 {
		t.Fatalf("defaults: %+v", d.Rally)
	}
	var old Config
	if err := json.Unmarshal([]byte(`{"relay":{"leg_km":3}}`), &old); err != nil {
		t.Fatal(err)
	}
	old.Normalize()
	if old.Rally != d.Rally {
		t.Fatalf("normalized: %+v", old.Rally)
	}
	for _, bad := range []RallySettings{{BonusRate: -0.1, MinCheckins: 2, CheckinRadiusM: 300}, {BonusRate: 0.2, MinCheckins: 0, CheckinRadiusM: 300},
		{BonusRate: 0.2, MinCheckins: 2, CheckinRadiusM: 0}} {
		c := Default()
		c.Rally = bad
		if c.Validate() == nil {
			t.Fatalf("accepted %+v", bad)
		}
	}
}
