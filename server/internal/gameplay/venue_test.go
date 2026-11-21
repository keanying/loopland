package gameplay

import "testing"

func TestVenueSettings(t *testing.T) {
	c := Default()
	if c.Venue != defaultVenue() || c.Booking != defaultBooking() {
		t.Fatalf("defaults: %+v %+v", c.Venue, c.Booking)
	}
	if e, _ := c.RawEnergy(SportVenue, 1); e != 20 {
		t.Fatalf("venue energy %d", e)
	}
	// A configuration stored before the section keeps its venue energy.
	old := Default()
	old.Venue, old.Booking = VenueSettings{}, BookingSettings{}
	for i := range old.Energy {
		if old.Energy[i].Sport == SportVenue {
			old.Energy[i].Energy = 25
		}
	}
	old.Normalize()
	if old.Venue.CheckinEnergy != 25 || old.Booking.MaxSlots != 4 {
		t.Fatalf("normalized: %+v %+v", old.Venue, old.Booking)
	}
	// venue.checkin_energy wins over the energy table.
	c.Venue.CheckinEnergy = 30
	c.Normalize()
	if e, _ := c.RawEnergy(SportVenue, 1); e != 30 {
		t.Fatalf("synced venue energy %d", e)
	}
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	c.Booking.PayTimeoutMin = 0
	if c.Validate() == nil {
		t.Fatal("pay_timeout_min 0 accepted")
	}
}
