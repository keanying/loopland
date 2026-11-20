// Package gameplay holds the tunable numbers (玩法配置) and the pure rules
// that use them: energy conversion, daily cap, building, guard and attacks.
//
// Defaults mirror the admin prototype (docs/资料包/02_交互原型/pages/
// AdminConfig.html) and 产品文档. At runtime they will come from the config
// centre so 策划 can change them without a release (功能清单 M-28..M-32).
package gameplay

import (
	"fmt"
	"math"
)

// Sport identifies an activity type.
type Sport string

const (
	SportRun      Sport = "run"      // 跑步
	SportRide     Sport = "ride"     // 骑行
	SportHike     Sport = "hike"     // 徒步
	SportWalk     Sport = "walk"     // 健走
	SportSwim     Sport = "swim"     // 游泳
	SportVenue    Sport = "venue"    // 场馆签到（球类、攀岩、健身房）
	SportStrength Sport = "strength" // 力量
	SportYoga     Sport = "yoga"     // 瑜伽
	SportRope     Sport = "rope"     // 跳绳
	SportHIIT     Sport = "hiit"     // HIIT
	SportRally    Sport = "rally"    // 集结跑（只用于旗手招募计数）
)

// GPSSports can claim land (居家训练 and venue check-ins cannot).
var GPSSports = map[Sport]bool{SportRun: true, SportRide: true, SportHike: true, SportWalk: true}

// Unit is the base unit an amount is measured in.
type Unit string

const (
	UnitKm      Unit = "km"
	UnitMeter   Unit = "m"
	UnitMinute  Unit = "min"
	UnitCount   Unit = "count"
	UnitCheckin Unit = "checkin"
)

// EnergyRule: every Per units of Unit earn Energy.
type EnergyRule struct {
	Sport  Sport   `json:"sport"`
	Name   string  `json:"name"`
	Unit   Unit    `json:"unit"`
	Per    float64 `json:"per"`
	Energy int     `json:"energy"`
	// Pending marks numbers the product docs do not give yet.
	Pending bool `json:"pending,omitempty"`
}

// Building is one of the 8 buildings a territory slot can hold.
type Building struct {
	Key         string `json:"key"`
	Name        string `json:"name"`
	Note        string `json:"note"`
	Cost        int    `json:"cost"`
	Guard       int    `json:"guard"`
	DailyEnergy int    `json:"daily_energy"`
	UnlockLevel int    `json:"unlock_level"`
}

// BuffKind is what a stationed character improves.
type BuffKind string

const (
	BuffGuardPct       BuffKind = "guard_pct"         // 领地守卫 +x%
	BuffCaptureSpeed   BuffKind = "capture_speed"     // 攻占速度 +x%
	BuffBuildCostPct   BuffKind = "build_cost_pct"    // 建造费用 -x%
	BuffDailyEnergy    BuffKind = "daily_energy"      // 每日 +x 能量
	BuffVision         BuffKind = "vision"            // 地图视野 +x 格
	BuffCrewBossDmgPct BuffKind = "crew_boss_dmg_pct" // 跑团合击伤害 +x%
	BuffChestDropPct   BuffKind = "chest_drop_pct"    // 宝箱额外掉落 +x%
	BuffMillYieldPct   BuffKind = "mill_yield_pct"    // 磨坊产出 +x%
)

// Role is a collectible character recruited by doing a sport.
type Role struct {
	Key       string   `json:"key"`
	Name      string   `json:"name"`
	Sport     Sport    `json:"sport"`
	Threshold float64  `json:"threshold"`
	Unit      Unit     `json:"unit"`
	Buff      BuffKind `json:"buff"`
	BuffValue float64  `json:"buff_value"`
	BuffText  string   `json:"buff_text"`
}

// Drop is one entry in a boss loot table.
type Drop struct {
	Item    string  `json:"item"`
	Kind    string  `json:"kind"` // role | blueprint | egg | energy
	Percent float64 `json:"percent"`
}

// Boss is a city monster (bad habit).
type Boss struct {
	Key   string `json:"key"`
	Name  string `json:"name"`
	Drops []Drop `json:"drops"`
}

// Config is the whole gameplay configuration, versioned as one unit.
type Config struct {
	Version           string       `json:"version"`
	SlotsPerTerritory int          `json:"slots_per_territory"`
	DailyEnergyCap    int          `json:"daily_energy_cap"`
	BossStrikeCost    int          `json:"boss_strike_cost"`
	Energy            []EnergyRule `json:"energy"`
	Buildings         []Building   `json:"buildings"`
	Roles             []Role       `json:"roles"`
	Bosses            []Boss       `json:"bosses"`
}

// Default returns the launch numbers from the product documents.
func Default() Config {
	return Config{
		Version:           "v3.12",
		SlotsPerTerritory: 6,
		DailyEnergyCap:    600,
		BossStrikeCost:    100,
		Energy: []EnergyRule{
			{Sport: SportRun, Name: "跑步", Unit: UnitKm, Per: 1, Energy: 10},
			{Sport: SportRide, Name: "骑行", Unit: UnitKm, Per: 1, Energy: 4},
			{Sport: SportHike, Name: "徒步", Unit: UnitKm, Per: 1, Energy: 6},
			// 健走 and HIIT appear as sports but have no rate in the docs yet.
			{Sport: SportWalk, Name: "健走", Unit: UnitKm, Per: 1, Energy: 6, Pending: true},
			{Sport: SportSwim, Name: "游泳", Unit: UnitMeter, Per: 100, Energy: 3},
			{Sport: SportVenue, Name: "场馆签到", Unit: UnitCheckin, Per: 1, Energy: 20},
			{Sport: SportStrength, Name: "力量", Unit: UnitMinute, Per: 10, Energy: 5},
			{Sport: SportYoga, Name: "瑜伽", Unit: UnitMinute, Per: 10, Energy: 4},
			{Sport: SportRope, Name: "跳绳", Unit: UnitCount, Per: 100, Energy: 2},
			{Sport: SportHIIT, Name: "HIIT", Unit: UnitMinute, Per: 10, Energy: 5, Pending: true},
		},
		Buildings: []Building{
			{Key: "campfire", Name: "营火", Note: "基础", Cost: 80, Guard: 50, DailyEnergy: 10, UnlockLevel: 1},
			{Key: "tent", Name: "营帐", Note: "扩充驻扎", Cost: 120, Guard: 80, DailyEnergy: 15, UnlockLevel: 1},
			{Key: "well", Name: "水井", Note: "恢复体力", Cost: 150, Guard: 60, DailyEnergy: 25, UnlockLevel: 2},
			{Key: "mill", Name: "磨坊", Note: "能量产出", Cost: 200, Guard: 40, DailyEnergy: 40, UnlockLevel: 2},
			{Key: "house", Name: "民居", Note: "驻扎 +2 角色", Cost: 180, Guard: 100, DailyEnergy: 20, UnlockLevel: 3},
			{Key: "forge", Name: "铁匠铺", Note: "角色升级", Cost: 260, Guard: 150, DailyEnergy: 30, UnlockLevel: 4},
			{Key: "tower", Name: "箭塔", Note: "防守主力", Cost: 320, Guard: 300, DailyEnergy: 10, UnlockLevel: 5},
			{Key: "chapel", Name: "礼拜堂", Note: "跑团加成", Cost: 400, Guard: 200, DailyEnergy: 50, UnlockLevel: 6},
		},
		Roles: []Role{
			{Key: "archer", Name: "弓箭手", Sport: SportRun, Threshold: 30, Unit: UnitKm, Buff: BuffGuardPct, BuffValue: 5, BuffText: "领地守卫 +5%"},
			{Key: "knight", Name: "骑士", Sport: SportRide, Threshold: 80, Unit: UnitKm, Buff: BuffCaptureSpeed, BuffValue: 8, BuffText: "攻占速度 +8%"},
			{Key: "smith", Name: "铁匠", Sport: SportStrength, Threshold: 300, Unit: UnitMinute, Buff: BuffBuildCostPct, BuffValue: 6, BuffText: "建造费用 -6%"},
			{Key: "monk", Name: "修士", Sport: SportYoga, Threshold: 300, Unit: UnitMinute, Buff: BuffDailyEnergy, BuffValue: 10, BuffText: "每日恢复 +10 能量"},
			{Key: "scout", Name: "斥候", Sport: SportHike, Threshold: 20, Unit: UnitKm, Buff: BuffVision, BuffValue: 1, BuffText: "地图视野 +1 格"},
			{Key: "banner", Name: "旗手", Sport: SportRally, Threshold: 5, Unit: UnitCount, Buff: BuffCrewBossDmgPct, BuffValue: 10, BuffText: "跑团合击伤害 +10%"},
			{Key: "alchemist", Name: "药剂师", Sport: SportRope, Threshold: 3000, Unit: UnitCount, Buff: BuffChestDropPct, BuffValue: 5, BuffText: "宝箱额外掉落 +5%"},
			{Key: "farmer", Name: "农夫", Sport: SportWalk, Threshold: 15, Unit: UnitKm, Buff: BuffMillYieldPct, BuffValue: 12, BuffText: "磨坊产出 +12%"},
		},
		Bosses: []Boss{
			{Key: "sofa", Name: "沙发怪", Drops: []Drop{
				{"banner", "role", 35}, {"knight", "role", 20}, {"tent", "blueprint", 10}, {"firetail", "egg", 5}, {"energy", "energy", 30}}},
			{Key: "bat", Name: "熬夜蝠", Drops: []Drop{
				{"scout", "role", 30}, {"archer", "role", 25}, {"tower", "blueprint", 8}, {"nightnewt", "egg", 4}, {"energy", "energy", 33}}},
			{Key: "smog", Name: "雾霾怪", Drops: []Drop{
				{"monk", "role", 25}, {"well", "blueprint", 15}, {"chapel", "blueprint", 6}, {"axolotl", "egg", 4}, {"energy", "energy", 50}}},
			{Key: "sugar", Name: "糖分怪", Drops: []Drop{
				{"farmer", "role", 30}, {"mill", "blueprint", 15}, {"house", "blueprint", 10}, {"frog", "egg", 5}, {"energy", "energy", 40}}},
		},
	}
}

// Validate enforces the rules the admin "发布" button must check.
func (c Config) Validate() error {
	if c.SlotsPerTerritory <= 0 {
		return fmt.Errorf("slots_per_territory must be > 0")
	}
	if c.DailyEnergyCap <= 0 {
		return fmt.Errorf("daily_energy_cap must be > 0")
	}
	if c.BossStrikeCost <= 0 {
		return fmt.Errorf("boss_strike_cost must be > 0")
	}
	seen := map[Sport]bool{}
	for _, e := range c.Energy {
		if e.Per <= 0 || e.Energy < 0 {
			return fmt.Errorf("energy rule %s: per must be > 0 and energy >= 0", e.Sport)
		}
		if seen[e.Sport] {
			return fmt.Errorf("energy rule %s defined twice", e.Sport)
		}
		seen[e.Sport] = true
	}
	for _, b := range c.Buildings {
		if b.Cost <= 0 || b.Guard < 0 || b.DailyEnergy < 0 || b.UnlockLevel < 1 {
			return fmt.Errorf("building %s has invalid numbers", b.Key)
		}
	}
	for _, r := range c.Roles {
		if r.Threshold <= 0 {
			return fmt.Errorf("role %s: threshold must be > 0", r.Key)
		}
	}
	for _, b := range c.Bosses {
		var sum float64
		for _, d := range b.Drops {
			if d.Percent < 0 {
				return fmt.Errorf("boss %s: negative drop rate for %s", b.Key, d.Item)
			}
			sum += d.Percent
		}
		// 合计必须等于 100% 才能发布 (功能清单 M-30).
		if math.Abs(sum-100) > 1e-6 {
			return fmt.Errorf("boss %s: drop rates add up to %.2f%%, must be 100%%", b.Key, sum)
		}
	}
	return nil
}

// Building looks up a building by key.
func (c Config) Building(key string) (Building, bool) {
	for _, b := range c.Buildings {
		if b.Key == key {
			return b, true
		}
	}
	return Building{}, false
}

// Role looks up a role by key.
func (c Config) Role(key string) (Role, bool) {
	for _, r := range c.Roles {
		if r.Key == key {
			return r, true
		}
	}
	return Role{}, false
}

func (c Config) energyRule(s Sport) (EnergyRule, bool) {
	for _, e := range c.Energy {
		if e.Sport == s {
			return e, true
		}
	}
	return EnergyRule{}, false
}
