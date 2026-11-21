package perks

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/testdb"
)

func TestQRPayload(t *testing.T) {
	s := &Service{QRKey: DeriveKey([]byte("0123456789abcdef0123456789abcdef"))}
	now := time.Now()
	p := s.QRPayload(77, now)
	if !strings.HasPrefix(p, "LPC.77.") || strings.Count(p, ".") != 3 {
		t.Fatalf("payload %q", p)
	}
	if id, err := s.parseQR(p, now.Add(59*time.Second)); err != nil || id != 77 {
		t.Fatalf("fresh payload: %d %v", id, err)
	}
	if _, err := s.parseQR(p, now.Add(61*time.Second)); !errors.Is(err, errQRExpired) {
		t.Fatalf("expired payload: %v", err)
	}
	if _, err := s.parseQR(strings.Replace(p, "LPC.77.", "LPC.78.", 1), now); !errors.Is(err, errInvalidCoupon) {
		t.Fatalf("other coupon id: %v", err)
	}
	other := &Service{QRKey: DeriveKey([]byte("another-key-another-key-another-k"))}
	if _, err := other.parseQR(p, now); !errors.Is(err, errInvalidCoupon) {
		t.Fatalf("other key: %v", err)
	}
	for _, bad := range []string{"", "LPC", "LPV.1.2.x", "LPC.a.b.c"} {
		if _, err := s.parseQR(bad, now); !errors.Is(err, errInvalidCoupon) {
			t.Fatalf("%q: %v", bad, err)
		}
	}
}

func TestIssueStronghold(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	s := &Service{Pool: pool}
	var user, merchant, drop int64
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(pool.QueryRow(ctx, `INSERT INTO src.src_usr_loop_user (nickname, source) VALUES ('跑者', 'sms') RETURNING id`).Scan(&user))
	must(pool.QueryRow(ctx, `INSERT INTO src.src_mer_loop_merchant (merchant_name, merchant_type, merchant_status) VALUES ('球馆', 'venue', 'partner') RETURNING id`).Scan(&merchant))
	must(pool.QueryRow(ctx, `INSERT INTO src.src_mer_loop_drop (merchant_id, drop_type, drop_name, venue_id, perk_title, daily_cap_qty, start_time, end_time)
		VALUES ($1, 'stronghold', '据点 · 球馆', 42, '饮料一瓶', 1, now() - interval '1 hour', now() + interval '1 day') RETURNING id`, merchant).Scan(&drop))

	issue := func(u, venue int64) any {
		t.Helper()
		var c any
		must(pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
			var err error
			c, err = s.IssueStronghold(ctx, tx, u, venue)
			return err
		}))
		return c
	}
	c := issue(user, 42)
	cp, ok := c.(*Coupon)
	if !ok || cp.Source.Type != "stronghold" || cp.Source.DropID != drop || cp.Perk.Title != "饮料一瓶" || cp.Status != "unused" {
		t.Fatalf("coupon: %#v", c)
	}
	if c := issue(user, 42); c != nil { // once a day
		t.Fatalf("second coupon: %#v", c)
	}
	if c := issue(user, 43); c != nil { // no stronghold at that venue
		t.Fatalf("other venue: %#v", c)
	}
	var other int64
	must(pool.QueryRow(ctx, `INSERT INTO src.src_usr_loop_user (nickname, source) VALUES ('另一个', 'sms') RETURNING id`).Scan(&other))
	if c := issue(other, 42); c != nil { // daily cap 1 reached
		t.Fatalf("over the cap: %#v", c)
	}
	_, err := pool.Exec(ctx, `UPDATE src.src_mer_loop_drop SET daily_cap_qty=0, is_paused=true WHERE id=$1`, drop)
	must(err)
	if c := issue(other, 42); c != nil { // paused
		t.Fatalf("paused drop: %#v", c)
	}
	_, err = pool.Exec(ctx, `UPDATE src.src_mer_loop_drop SET is_paused=false WHERE id=$1`, drop)
	must(err)
	_, err = pool.Exec(ctx, `UPDATE src.src_mer_loop_merchant SET merchant_status='suspended' WHERE id=$1`, merchant)
	must(err)
	if c := issue(other, 42); c != nil { // suspended merchant
		t.Fatalf("suspended merchant: %#v", c)
	}
	_, err = pool.Exec(ctx, `UPDATE src.src_mer_loop_merchant SET merchant_status='partner' WHERE id=$1`, merchant)
	must(err)
	if c := issue(other, 42); c == nil {
		t.Fatal("no coupon after resuming")
	}
}
