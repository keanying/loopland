// Package clock centralises "today" in China time, which energy caps,
// dashboards and daily jobs are based on.
package clock

import (
	"time"
	_ "time/tzdata" // containers often lack zoneinfo
)

// Shanghai is the business time zone.
var Shanghai = mustLoad("Asia/Shanghai")

func mustLoad(name string) *time.Location {
	l, err := time.LoadLocation(name)
	if err != nil {
		panic(err)
	}
	return l
}

// Now is overridable in tests.
var Now = time.Now

// Day returns the business date (midnight, Shanghai) containing t.
func Day(t time.Time) time.Time {
	t = t.In(Shanghai)
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, Shanghai)
}

// Today is Day(Now()).
func Today() time.Time { return Day(Now()) }
