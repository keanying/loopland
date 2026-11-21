package gameplay

import (
	"fmt"
	"math"
)

// BossDamage converts an amount of a sport into boss damage.
type BossDamage struct {
	Sport  Sport   `json:"sport"`
	Per    float64 `json:"per"`
	Unit   Unit    `json:"unit"`
	Damage int     `json:"damage"`
}

// BossSettings tune city monsters (城市怪兽).
type BossSettings struct {
	StrikeCost      int          `json:"strike_cost"`
	StrikeDamage    int          `json:"strike_damage"`
	StrikeCooldownS int          `json:"strike_cooldown_s"`
	ComboWindowS    int          `json:"combo_window_s"`
	ComboPct        float64      `json:"combo_pct"`
	ComboMaxPct     float64      `json:"combo_max_pct"`
	Damage          []BossDamage `json:"damage"`
	DefaultHP       int          `json:"default_hp"`
	RadiusM         float64      `json:"radius_m"`
	DurationH       float64      `json:"duration_h"`
	AutoSpawnMax    int          `json:"auto_spawn_max"`
	EngageH         float64      `json:"engage_h"`
	ExpireRefundPct float64      `json:"expire_refund_pct"`
	TopExtraRolls   int          `json:"top_extra_rolls"`
	DropEnergy      int          `json:"drop_energy"`
	YieldPenaltyPct float64      `json:"yield_penalty_pct"`
}

// ChestSettings tune energy chests (能量宝箱).
type ChestSettings struct {
	EnergyMin  int     `json:"energy_min"`
	EnergyMax  int     `json:"energy_max"`
	RadiusM    float64 `json:"radius_m"`
	DailySpawn int     `json:"daily_spawn"`
	DurationH  float64 `json:"duration_h"`
}

// DefenseSettings tune 守地挑战.
type DefenseSettings struct {
	WindowH  float64 `json:"window_h"`
	MaxGuard int     `json:"max_guard"`
}

// Tier is a season rank band.
type Tier struct {
	Name   string  `json:"name"`
	MinKm2 float64 `json:"min_km2"`
}

// SeasonSettings tune seasons.
type SeasonSettings struct {
	Tiers []Tier `json:"tiers"`
}

// Task types.
const (
	TaskWeeklyCount    = "weekly_count"
	TaskWeeklyAreaM2   = "weekly_area_m2"
	TaskWeeklyDistance = "weekly_distance_km"
	TaskNewSport       = "new_sport"
)

// SeasonTask is a weekly season task.
type SeasonTask struct {
	Key          string  `json:"key"`
	Name         string  `json:"name"`
	Type         string  `json:"type"`
	Target       float64 `json:"target"`
	RewardEnergy int     `json:"reward_energy"`
}

// Medal types.
const (
	MedalDistanceKm  = "distance_km"
	MedalDefends     = "defends"
	MedalLoopsSingle = "loops_single"
	MedalBossDefeats = "boss_defeats"
	MedalChests      = "chests"
	MedalRoutes      = "routes"
)

// MedalTypes are all known medal types.
var MedalTypes = []string{MedalDistanceKm, MedalDefends, MedalLoopsSingle, MedalBossDefeats, MedalChests, MedalRoutes}

// CompanionSettings tune 跑步伙伴养成.
type CompanionSettings struct {
	FeedCost    int `json:"feed_cost"`
	FeedExp     int `json:"feed_exp"`
	ExpPer100m  int `json:"exp_per_100m"`
	ExpPerLevel int `json:"exp_per_level"`
}

// RelaySettings tune 跑团接力.
type RelaySettings struct {
	DefaultLegs  int     `json:"default_legs"`
	LegKm        float64 `json:"leg_km"`
	DurationH    float64 `json:"duration_h"`
	RewardEnergy int     `json:"reward_energy"`
}

func defaultPlay(c *Config) {
	c.Boss = BossSettings{
		StrikeCost: 100, StrikeDamage: 40, StrikeCooldownS: 30, ComboWindowS: 300, ComboPct: 10, ComboMaxPct: 50,
		Damage: []BossDamage{
			{SportRun, 1, UnitKm, 100}, {SportRide, 1, UnitKm, 100}, {SportHike, 1, UnitKm, 100}, {SportWalk, 1, UnitKm, 100},
			{SportRope, 100, UnitCount, 30}, {SportStrength, 10, UnitMinute, 30}, {SportYoga, 10, UnitMinute, 30}, {SportHIIT, 10, UnitMinute, 30},
		},
		DefaultHP: 10000, RadiusM: 1000, DurationH: 48, AutoSpawnMax: 3, EngageH: 6, ExpireRefundPct: 20,
		TopExtraRolls: 3, DropEnergy: 200, YieldPenaltyPct: 50,
	}
	c.Chest = ChestSettings{EnergyMin: 20, EnergyMax: 60, RadiusM: 50, DailySpawn: 20, DurationH: 24}
	c.Defense = DefenseSettings{WindowH: 24, MaxGuard: 2000}
	c.Season = SeasonSettings{Tiers: []Tier{{"青铜", 0}, {"白银", 0.5}, {"黄金", 3.6}, {"铂金", 8}, {"钻石", 15}}}
	c.SeasonTasks = []SeasonTask{
		{"weekly_runs", "本周运动 3 次", TaskWeeklyCount, 3, 60},
		{"weekly_area", "本周圈地 2 万 m²", TaskWeeklyAreaM2, 20000, 80},
		{"weekly_distance", "本周跑够 15 km", TaskWeeklyDistance, 15, 80},
		{"new_sport", "尝试一项本赛季没做过的运动", TaskNewSport, 1, 50},
	}
	c.Medals = append(c.Medals,
		Medal{Key: "guardian", Name: "守护者", Type: MedalDefends, Target: 5},
		Medal{Key: "ten_loops", Name: "一夜十圈", Type: MedalLoopsSingle, Target: 10},
		Medal{Key: "monster_hunter", Name: "怪兽猎人", Type: MedalBossDefeats, Target: 5},
		Medal{Key: "treasure", Name: "寻宝人", Type: MedalChests, Target: 20},
		Medal{Key: "orienteer", Name: "城市定向家", Type: MedalRoutes, Target: 3},
	)
	c.Pet = CompanionSettings{FeedCost: 50, FeedExp: 10, ExpPer100m: 1, ExpPerLevel: 100}
	c.Relay = RelaySettings{DefaultLegs: 6, LegKm: 3, DurationH: 168, RewardEnergy: 100}
	for i := range c.Buildings {
		if c.Buildings[i].Key == "tower" || c.Buildings[i].Key == "chapel" || c.Buildings[i].Key == "forge" {
			c.Buildings[i].BlueprintBypassLevel = true
		}
	}
}

// Normalize fills fields that older stored configurations lack.
func (c *Config) Normalize() {
	for i := range c.Medals {
		if c.Medals[i].Type == "" {
			c.Medals[i].Type = MedalDistanceKm
		}
		if c.Medals[i].Target == 0 && c.Medals[i].Type == MedalDistanceKm {
			c.Medals[i].Target = c.Medals[i].DistanceKm
		}
	}
	d := Default()
	if c.Boss.StrikeCost == 0 && len(c.Boss.Damage) == 0 {
		c.Boss = d.Boss
	}
	if c.Chest.RadiusM == 0 {
		c.Chest = d.Chest
	}
	if c.Defense.WindowH == 0 {
		c.Defense = d.Defense
	}
	if len(c.Season.Tiers) == 0 {
		c.Season = d.Season
	}
	if c.SeasonTasks == nil {
		c.SeasonTasks = d.SeasonTasks
	}
	if c.Pet.ExpPerLevel == 0 {
		c.Pet = d.Pet
	}
	if c.Relay.LegKm == 0 {
		c.Relay = d.Relay
	}
	c.normalizeCommunity()
	if c.Rally.MinCheckins == 0 {
		c.Rally = defaultRally()
	}
	c.normalizeAI()
	c.normalizeVenue()
}

func (c Config) validatePlay() error {
	b := c.Boss
	if b.StrikeCost <= 0 || b.StrikeDamage <= 0 || b.DefaultHP <= 0 || b.RadiusM <= 0 || b.DurationH <= 0 || b.EngageH <= 0 {
		return fmt.Errorf("boss: 合击消耗、伤害、血量、范围、时长必须是正数")
	}
	if b.ExpireRefundPct < 0 || b.ExpireRefundPct > 100 || b.YieldPenaltyPct < 0 || b.YieldPenaltyPct > 100 || b.ComboPct < 0 || b.ComboMaxPct < 0 {
		return fmt.Errorf("boss: 百分比必须在 0–100 之间")
	}
	for _, d := range b.Damage {
		if d.Per <= 0 || d.Damage < 0 {
			return fmt.Errorf("boss damage %s: per 必须为正", d.Sport)
		}
	}
	ch := c.Chest
	if ch.EnergyMin <= 0 || ch.EnergyMax < ch.EnergyMin || ch.RadiusM <= 0 || ch.DurationH <= 0 || ch.DailySpawn < 0 {
		return fmt.Errorf("chest: 能量范围、半径、时长不合法")
	}
	if c.Defense.WindowH <= 0 || c.Defense.MaxGuard <= 0 {
		return fmt.Errorf("defense: 时长和守卫上限必须为正")
	}
	if len(c.Season.Tiers) == 0 || c.Season.Tiers[0].MinKm2 != 0 {
		return fmt.Errorf("season: 第一个段位必须从 0 开始")
	}
	for i := 1; i < len(c.Season.Tiers); i++ {
		if c.Season.Tiers[i].MinKm2 <= c.Season.Tiers[i-1].MinKm2 {
			return fmt.Errorf("season: 段位门槛必须递增")
		}
	}
	keys := map[string]bool{}
	for _, t := range c.SeasonTasks {
		if t.Key == "" || keys[t.Key] || t.Target <= 0 || t.RewardEnergy < 0 {
			return fmt.Errorf("season task %q: key 必须唯一，目标为正", t.Key)
		}
		keys[t.Key] = true
		switch t.Type {
		case TaskWeeklyCount, TaskWeeklyAreaM2, TaskWeeklyDistance, TaskNewSport:
		default:
			return fmt.Errorf("season task %q: 未知类型 %q", t.Key, t.Type)
		}
	}
	keys = map[string]bool{}
	for _, m := range c.Medals {
		if m.Key == "" || keys[m.Key] || m.Target <= 0 {
			return fmt.Errorf("medal %q: key 必须唯一，目标为正", m.Key)
		}
		keys[m.Key] = true
		known := false
		for _, t := range MedalTypes {
			known = known || t == m.Type
		}
		if !known {
			return fmt.Errorf("medal %q: 未知类型 %q", m.Key, m.Type)
		}
	}
	if c.Pet.FeedCost <= 0 || c.Pet.FeedExp <= 0 || c.Pet.ExpPerLevel <= 0 || c.Pet.ExpPer100m < 0 {
		return fmt.Errorf("companion: 数值必须为正")
	}
	if c.Relay.DefaultLegs < 2 || c.Relay.LegKm <= 0 || c.Relay.DurationH <= 0 || c.Relay.RewardEnergy < 0 {
		return fmt.Errorf("relay: 至少 2 棒，单棒距离和时长为正")
	}
	return nil
}

// BossDamageFor converts an amount of sport into damage.
func (c Config) BossDamageFor(s Sport, amount float64) int {
	for _, d := range c.Boss.Damage {
		if d.Sport == s {
			return int(math.Floor(amount / d.Per * float64(d.Damage)))
		}
	}
	return 0
}

// TierFor returns the tier name, sub-level (III/II/I) and the area still
// needed to reach the next sub-level (0 at the very top).
func (c Config) TierFor(areaM2 float64) (name, level string, nextName, nextLevel string, needM2 float64) {
	km2 := areaM2 / 1e6
	tiers := c.Season.Tiers
	idx := 0
	for i, t := range tiers {
		if km2 >= t.MinKm2 {
			idx = i
		}
	}
	name = tiers[idx].Name
	if idx == len(tiers)-1 {
		return name, "I", "", "", 0
	}
	lo, hi := tiers[idx].MinKm2, tiers[idx+1].MinKm2
	step := (hi - lo) / 3
	sub := int(math.Min(2, math.Floor((km2-lo)/step)))
	levels := []string{"III", "II", "I"}
	level = levels[sub]
	if sub < 2 {
		nextName, nextLevel = name, levels[sub+1]
		needM2 = (lo + step*float64(sub+1) - km2) * 1e6
	} else {
		nextName, nextLevel = tiers[idx+1].Name, "III"
		needM2 = (hi - km2) * 1e6
	}
	return name, level, nextName, nextLevel, math.Max(0, needM2)
}

// CompanionLevel converts experience to level.
func (c Config) CompanionLevel(exp int) int { return exp/c.Pet.ExpPerLevel + 1 }
