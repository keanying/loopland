package gameplay

import "fmt"

// VenueSettings tune 场馆签到与馆主 (docs/api/v2-4-本地生活与商户.md «玩法配置新增»).
type VenueSettings struct {
	// CheckinEnergy is what one check-in earns; it overrides the venue row
	// of the energy table (以 venue.checkin_energy 为准).
	CheckinEnergy int `json:"checkin_energy"`
	// CheckinPoints are the 馆主积分 of one check-in.
	CheckinPoints int `json:"checkin_points"`
	// DailyCheckinVenues is how many different venues one user may check
	// in at per day.
	DailyCheckinVenues int `json:"daily_checkin_venues"`
	// DefaultCheckinRadiusM is the radius of a new venue.
	DefaultCheckinRadiusM float64 `json:"default_checkin_radius_m"`
}

// BookingSettings tune 订场.
type BookingSettings struct {
	// FreeCancelHours: cancelling at least this long before the start is
	// refunded in full; later the app gets cancel_too_late.
	FreeCancelHours int `json:"free_cancel_hours"`
	// PayTimeoutMin: unpaid bookings (and paid-race sign-ups) expire after it.
	PayTimeoutMin int `json:"pay_timeout_min"`
	// MaxSlots is the most consecutive slots in one booking.
	MaxSlots int `json:"max_slots"`
}

func defaultVenue() VenueSettings {
	return VenueSettings{CheckinEnergy: 20, CheckinPoints: 10, DailyCheckinVenues: 3, DefaultCheckinRadiusM: 150}
}

func defaultBooking() BookingSettings {
	return BookingSettings{FreeCancelHours: 2, PayTimeoutMin: 15, MaxSlots: 4}
}

// normalizeVenue fills the sections for configurations stored before them
// and keeps the venue energy rule equal to venue.checkin_energy.
func (c *Config) normalizeVenue() {
	if c.Venue == (VenueSettings{}) {
		c.Venue = defaultVenue()
		if r, ok := c.energyRule(SportVenue); ok {
			c.Venue.CheckinEnergy = r.Energy // keep what 策划 had set
		}
	}
	if c.Booking == (BookingSettings{}) {
		c.Booking = defaultBooking()
	}
	c.syncVenueEnergy()
}

func (c *Config) syncVenueEnergy() {
	for i := range c.Energy {
		if c.Energy[i].Sport == SportVenue {
			c.Energy[i].Unit, c.Energy[i].Per, c.Energy[i].Energy = UnitCheckin, 1, c.Venue.CheckinEnergy
			return
		}
	}
	c.Energy = append(c.Energy, EnergyRule{Sport: SportVenue, Name: "场馆签到", Unit: UnitCheckin, Per: 1, Energy: c.Venue.CheckinEnergy})
}

func (c Config) validateVenue() error {
	v, b := c.Venue, c.Booking
	if v.CheckinEnergy < 0 || v.CheckinEnergy > 1000 {
		return fmt.Errorf("venue: checkin_energy 应在 0–1000 之间")
	}
	if v.CheckinPoints < 0 || v.CheckinPoints > 1000 {
		return fmt.Errorf("venue: checkin_points 应在 0–1000 之间")
	}
	if v.DailyCheckinVenues < 1 || v.DailyCheckinVenues > 20 {
		return fmt.Errorf("venue: daily_checkin_venues 应在 1–20 之间")
	}
	if v.DefaultCheckinRadiusM <= 0 || v.DefaultCheckinRadiusM > 2000 {
		return fmt.Errorf("venue: default_checkin_radius_m 应在 0–2000 米之间")
	}
	if b.FreeCancelHours < 0 || b.FreeCancelHours > 72 {
		return fmt.Errorf("booking: free_cancel_hours 应在 0–72 之间")
	}
	if b.PayTimeoutMin < 5 || b.PayTimeoutMin > 120 {
		return fmt.Errorf("booking: pay_timeout_min 应在 5–120 之间")
	}
	if b.MaxSlots < 1 || b.MaxSlots > 12 {
		return fmt.Errorf("booking: max_slots 应在 1–12 之间")
	}
	return nil
}
