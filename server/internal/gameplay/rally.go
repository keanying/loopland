package gameplay

import "fmt"

// RallySettings tune 跑团集结跑 (docs/api/v2-2-社区.md): members who check
// in at the meeting point get BonusRate more energy and monster damage from
// the run, once at least MinCheckins members are there.
type RallySettings struct {
	BonusRate      float64 `json:"bonus_rate"`
	MinCheckins    int     `json:"min_checkins"`
	CheckinRadiusM float64 `json:"checkin_radius_m"`
}

func defaultRally() RallySettings {
	return RallySettings{BonusRate: 0.2, MinCheckins: 2, CheckinRadiusM: 300}
}

func (r RallySettings) validate() error {
	if r.BonusRate < 0 || r.BonusRate > 2 {
		return fmt.Errorf("rally: bonus_rate 应在 0–2 之间")
	}
	if r.MinCheckins < 1 || r.CheckinRadiusM <= 0 {
		return fmt.Errorf("rally: 最少签到人数至少 1，签到半径为正")
	}
	return nil
}
