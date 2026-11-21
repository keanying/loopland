package gameplay

import (
	"errors"
	"fmt"
	"math"
)

// ErrUnknownSport is returned for a sport without an energy rule.
var ErrUnknownSport = errors.New("unknown sport")

// RawEnergy converts an amount of a sport (in the rule's Unit) to energy,
// rounding down: 5.37 km of running is 53 energy.
func (c Config) RawEnergy(s Sport, amount float64) (int, error) {
	r, ok := c.energyRule(s)
	if !ok {
		return 0, fmt.Errorf("%w: %s", ErrUnknownSport, s)
	}
	if amount <= 0 {
		return 0, nil
	}
	return int(math.Floor(amount / r.Per * float64(r.Energy))), nil
}

// Grant applies the per-person daily cap (每人每天最多 600) to raw energy.
func (c Config) Grant(raw, earnedToday int) int {
	left := c.DailyEnergyCap - earnedToday
	if left <= 0 || raw <= 0 {
		return 0
	}
	return min(raw, left)
}

// Affordable lists the buildings a given amount of energy can pay for, the
// "跑 5 km 能建什么" example on the config page.
func (c Config) Affordable(energy int) []Building {
	var out []Building
	for _, b := range c.Buildings {
		if b.Cost <= energy {
			out = append(out, b)
		}
	}
	return out
}

// Territory is the gameplay state of one piece of land.
type Territory struct {
	Buildings []string // building keys, one per used slot
	Stationed []string // role keys stationed here
}

func (c Config) buffSum(roles []string, kind BuffKind) float64 {
	var s float64
	for _, k := range roles {
		if r, ok := c.Role(k); ok && r.Buff == kind {
			s += r.BuffValue
		}
	}
	return s
}

// Guard is the territory's guard value: building guard, scaled by stationed
// guard buffs (弓箭手 +5%), rounded down.
func (c Config) Guard(t Territory) int {
	var base int
	for _, k := range t.Buildings {
		if b, ok := c.Building(k); ok {
			base += b.Guard
		}
	}
	return int(math.Floor(float64(base) * (1 + c.buffSum(t.Stationed, BuffGuardPct)/100)))
}

// DailyEnergy is what the territory produces per day: building output, with
// 农夫 boosting mills, plus flat per-character bonuses (修士).
func (c Config) DailyEnergy(t Territory) int {
	millPct := c.buffSum(t.Stationed, BuffMillYieldPct)
	var total float64
	for _, k := range t.Buildings {
		b, ok := c.Building(k)
		if !ok {
			continue
		}
		y := float64(b.DailyEnergy)
		if k == "mill" {
			y *= 1 + millPct/100
		}
		total += y
	}
	total += c.buffSum(t.Stationed, BuffDailyEnergy)
	return int(math.Floor(total))
}

// Build errors.
var (
	ErrNoFreeSlot      = errors.New("no free building slot")
	ErrUnknownBuilding = errors.New("unknown building")
	ErrLevelTooLow     = errors.New("level too low for this building")
	ErrNotEnoughEnergy = errors.New("not enough energy")
)

// BuildCost is the energy needed to build key here, after 铁匠's discount.
// The discount rounds in the player's disfavour (ceil) so it never pays less
// than the configured fraction.
func (c Config) BuildCost(t Territory, key string) (int, error) {
	b, ok := c.Building(key)
	if !ok {
		return 0, fmt.Errorf("%w: %s", ErrUnknownBuilding, key)
	}
	pct := math.Min(c.buffSum(t.Stationed, BuffBuildCostPct), 100)
	return int(math.Ceil(float64(b.Cost) * (1 - pct/100))), nil
}

// CheckBuild validates a build and returns its cost.
func (c Config) CheckBuild(t Territory, key string, level, energy int) (int, error) {
	return c.CheckBuildWith(t, key, level, energy, false)
}

// CheckBuildWith is CheckBuild for a player who may own the building's
// blueprint, which lifts the level requirement for flagged buildings.
func (c Config) CheckBuildWith(t Territory, key string, level, energy int, blueprint bool) (int, error) {
	if len(t.Buildings) >= c.SlotsPerTerritory {
		return 0, ErrNoFreeSlot
	}
	b, ok := c.Building(key)
	if !ok {
		return 0, fmt.Errorf("%w: %s", ErrUnknownBuilding, key)
	}
	if level < b.UnlockLevel && !(blueprint && b.BlueprintBypassLevel) {
		return 0, fmt.Errorf("%w: %s needs Lv.%d", ErrLevelTooLow, b.Name, b.UnlockLevel)
	}
	cost, err := c.BuildCost(t, key)
	if err != nil {
		return 0, err
	}
	if energy < cost {
		return 0, fmt.Errorf("%w: need %d, have %d", ErrNotEnoughEnergy, cost, energy)
	}
	return cost, nil
}

// AttackResult is the outcome of one activity's energy against one territory.
type AttackResult struct {
	Captured   bool `json:"captured"`
	GuardAfter int  `json:"guard_after"`
}

// Attack applies 抢地判定 (功能清单 A-06): the activity's energy must exceed
// the territory's guard to take it; otherwise the guard is weakened by that
// energy. Unowned land has guard 0, so any positive energy takes it.
//
// Open question for 策划: the guard a captured territory starts with, and
// whether its buildings transfer. For now the guard goes to 0.
func Attack(energy, guard int) AttackResult {
	if energy > guard {
		return AttackResult{Captured: true, GuardAfter: 0}
	}
	return AttackResult{Captured: false, GuardAfter: max(0, guard-energy)}
}
