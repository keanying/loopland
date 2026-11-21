package territory

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/platform/testdb"
)

var origin = geo.LatLng{Lat: 31.2304, Lng: 121.4737}

// rect returns a closed ring for the rectangle [x0,x1]x[y0,y1] in metres.
func rect(x0, y0, x1, y1 float64) []geo.LatLng {
	p := geo.NewProjection(origin)
	pts := [][2]float64{{x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}, {x0, y0}}
	out := make([]geo.LatLng, len(pts))
	for i, xy := range pts {
		out[i] = p.Inverse(geo.Point{X: xy[0], Y: xy[1]})
	}
	return out
}

type fixture struct {
	pool *pgxpool.Pool
	ctx  context.Context
}

func (f fixture) user(t *testing.T, nick string) int64 {
	var id int64
	if err := f.pool.QueryRow(f.ctx, `INSERT INTO src.src_usr_loop_user (nickname, source) VALUES ($1,'sms') RETURNING id`, nick).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func (f fixture) activity(t *testing.T, user int64) int64 {
	var id int64
	if err := f.pool.QueryRow(f.ctx, `INSERT INTO src.src_act_loop_activity (user_id, client_id, sport, start_time, end_time)
		VALUES ($1, gen_random_uuid(), 'run', now(), now()) RETURNING id`, user).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func (f fixture) claim(t *testing.T, in ClaimInput) Outcome {
	t.Helper()
	if in.MinAreaM2 == 0 {
		in.MinAreaM2 = 500
	}
	var out Outcome
	err := pgx.BeginFunc(f.ctx, f.pool, func(tx pgx.Tx) error {
		var err error
		out, err = Claim(f.ctx, tx, in)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

type terr struct {
	owner *int64
	area  float64
	guard int
}

func (f fixture) get(t *testing.T, id int64) (terr, bool) {
	var x terr
	err := f.pool.QueryRow(f.ctx, `SELECT owner_user_id, area_m2, guard FROM src.src_ter_loop_territory WHERE id=$1`, id).Scan(&x.owner, &x.area, &x.guard)
	if err == pgx.ErrNoRows {
		return x, false
	}
	if err != nil {
		t.Fatal(err)
	}
	return x, true
}

func near(a, b, tol float64) bool { return a-b <= tol && b-a <= tol }

func setup(t *testing.T) fixture {
	return fixture{pool: testdb.New(t), ctx: context.Background()}
}

func TestClaimFreeLand(t *testing.T) {
	f := setup(t)
	a := f.user(t, "a")
	out := f.claim(t, ClaimInput{UserID: a, ActivityID: f.activity(t, a), Ring: rect(0, 0, 100, 100), AttackEnergy: 50})
	if len(out.Claims) != 1 || out.Claims[0].Kind != "claim" || !near(out.Claims[0].AreaM2, 10000, 30) {
		t.Fatalf("claims = %+v", out.Claims)
	}
	if len(out.Attacks) != 0 {
		t.Fatal("no attacks on free land")
	}
	// Claiming the same ground again creates nothing.
	out = f.claim(t, ClaimInput{UserID: a, ActivityID: f.activity(t, a), Ring: rect(0, 0, 100, 100), AttackEnergy: 50})
	if len(out.Claims) != 0 {
		t.Fatalf("re-claim of own land: %+v", out.Claims)
	}
}

func TestTooSmallIsIgnored(t *testing.T) {
	f := setup(t)
	a := f.user(t, "a")
	out := f.claim(t, ClaimInput{UserID: a, ActivityID: f.activity(t, a), Ring: rect(0, 0, 20, 20), AttackEnergy: 50})
	if len(out.Claims) != 0 {
		t.Fatalf("claims = %+v", out.Claims)
	}
}

func TestWeakenThenCaptureCut(t *testing.T) {
	f := setup(t)
	a, b := f.user(t, "a"), f.user(t, "b")
	first := f.claim(t, ClaimInput{UserID: a, ActivityID: f.activity(t, a), Ring: rect(0, 0, 200, 100), AttackEnergy: 50})
	tid := first.Claims[0].TerritoryID
	if _, err := f.pool.Exec(f.ctx, `UPDATE src.src_ter_loop_territory SET guard=100 WHERE id=$1`, tid); err != nil {
		t.Fatal(err)
	}

	// b overlaps the right half plus free land, but only has 40 energy.
	weak := f.claim(t, ClaimInput{UserID: b, ActivityID: f.activity(t, b), Ring: rect(100, 0, 300, 100), AttackEnergy: 40})
	if len(weak.Attacks) != 1 || weak.Attacks[0].Captured || weak.Attacks[0].GuardAfter != 60 {
		t.Fatalf("attacks = %+v", weak.Attacks)
	}
	if len(weak.Claims) != 1 || weak.Claims[0].Kind != "claim" || !near(weak.Claims[0].AreaM2, 10000, 30) {
		t.Fatalf("only the free half is claimed: %+v", weak.Claims)
	}
	if x, _ := f.get(t, tid); x.guard != 60 || !near(x.area, 20000, 60) {
		t.Fatalf("victim = %+v", x)
	}

	// b comes back with 70 energy > guard 60 over the middle strip.
	strong := f.claim(t, ClaimInput{UserID: b, ActivityID: f.activity(t, b), Ring: rect(50, 0, 150, 100), AttackEnergy: 70})
	if len(strong.Attacks) != 1 || !strong.Attacks[0].Captured {
		t.Fatalf("attacks = %+v", strong.Attacks)
	}
	if len(strong.Claims) != 1 || strong.Claims[0].Kind != "capture" || !near(strong.Claims[0].AreaM2, 10000, 30) {
		t.Fatalf("claims = %+v", strong.Claims)
	}
	x, _ := f.get(t, tid)
	if *x.owner != a || !near(x.area, 10000, 30) { // keeps 0–50 m and 150–200 m
		t.Fatalf("victim keeps both ends: %+v", x)
	}
	var unread int
	f.pool.QueryRow(f.ctx, `SELECT count(*) FROM src.src_msg_loop_notification WHERE user_id=$1`, a).Scan(&unread)
	if unread != 2 {
		t.Fatalf("victim notifications = %d, want 2", unread)
	}
}

func TestCaptureWholeAndRollback(t *testing.T) {
	f := setup(t)
	a, b := f.user(t, "a"), f.user(t, "b")
	first := f.claim(t, ClaimInput{UserID: a, ActivityID: f.activity(t, a), Ring: rect(0, 0, 100, 100), AttackEnergy: 50})
	tid := first.Claims[0].TerritoryID
	if _, err := f.pool.Exec(f.ctx, `UPDATE src.src_ter_loop_territory SET guard=50 WHERE id=$1;`, tid); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(f.ctx, `INSERT INTO src.src_ter_loop_building (territory_id, slot, building, built_by) VALUES ($1, 0, 'campfire', $2)`, tid, a); err != nil {
		t.Fatal(err)
	}

	act := f.activity(t, b)
	out := f.claim(t, ClaimInput{UserID: b, ActivityID: act, Ring: rect(-10, -10, 150, 110), AttackEnergy: 80})
	if len(out.Attacks) != 1 || !out.Attacks[0].Captured {
		t.Fatalf("attacks = %+v", out.Attacks)
	}
	x, _ := f.get(t, tid)
	if *x.owner != b || x.guard != 0 {
		t.Fatalf("whole capture: %+v", x)
	}
	var n int
	f.pool.QueryRow(f.ctx, `SELECT count(*) FROM src.src_ter_loop_building WHERE territory_id=$1`, tid).Scan(&n)
	if n != 0 {
		t.Fatal("buildings cleared on whole capture")
	}
	var total int
	f.pool.QueryRow(f.ctx, `SELECT count(*) FROM src.src_ter_loop_territory`).Scan(&total)
	if total != 2 { // a's (now b's) + the free ring around it
		t.Fatalf("territories = %d, want 2", total)
	}

	if err := pgx.BeginFunc(f.ctx, f.pool, func(tx pgx.Tx) error { return Rollback(f.ctx, tx, act) }); err != nil {
		t.Fatal(err)
	}
	x, ok := f.get(t, tid)
	if !ok || *x.owner != a || x.guard != 50 {
		t.Fatalf("restored: %+v ok=%v", x, ok)
	}
	f.pool.QueryRow(f.ctx, `SELECT count(*) FROM src.src_ter_loop_building WHERE territory_id=$1`, tid).Scan(&n)
	if n != 1 {
		t.Fatal("buildings restored")
	}
	f.pool.QueryRow(f.ctx, `SELECT count(*) FROM src.src_ter_loop_territory`).Scan(&total)
	if total != 1 {
		t.Fatalf("free claim removed: territories = %d", total)
	}
}

func TestRollbackCutAndWeaken(t *testing.T) {
	f := setup(t)
	a, b := f.user(t, "a"), f.user(t, "b")
	first := f.claim(t, ClaimInput{UserID: a, ActivityID: f.activity(t, a), Ring: rect(0, 0, 200, 100), AttackEnergy: 50})
	tid := first.Claims[0].TerritoryID
	act := f.activity(t, b)
	f.claim(t, ClaimInput{UserID: b, ActivityID: act, Ring: rect(100, 0, 300, 100), AttackEnergy: 10})
	if x, _ := f.get(t, tid); !near(x.area, 10000, 30) {
		t.Fatalf("cut: %+v", x)
	}
	if err := pgx.BeginFunc(f.ctx, f.pool, func(tx pgx.Tx) error { return Rollback(f.ctx, tx, act) }); err != nil {
		t.Fatal(err)
	}
	if x, _ := f.get(t, tid); !near(x.area, 20000, 60) || *x.owner != a {
		t.Fatalf("restored cut: %+v", x)
	}

	// Weaken and roll back.
	if _, err := f.pool.Exec(f.ctx, `UPDATE src.src_ter_loop_territory SET guard=100 WHERE id=$1`, tid); err != nil {
		t.Fatal(err)
	}
	act2 := f.activity(t, b)
	f.claim(t, ClaimInput{UserID: b, ActivityID: act2, Ring: rect(50, 0, 150, 100), AttackEnergy: 30})
	if x, _ := f.get(t, tid); x.guard != 70 {
		t.Fatalf("weakened: %+v", x)
	}
	if err := pgx.BeginFunc(f.ctx, f.pool, func(tx pgx.Tx) error { return Rollback(f.ctx, tx, act2) }); err != nil {
		t.Fatal(err)
	}
	if x, _ := f.get(t, tid); x.guard != 100 {
		t.Fatalf("guard restored: %+v", x)
	}
}

func TestCrewMatesAreNotAttacked(t *testing.T) {
	f := setup(t)
	a, b := f.user(t, "a"), f.user(t, "b")
	var crew int64
	f.pool.QueryRow(f.ctx, `INSERT INTO src.src_soc_loop_crew (name, district, leader_id) VALUES ('c','徐汇区',$1) RETURNING id`, a).Scan(&crew)
	f.claim(t, ClaimInput{UserID: a, CrewID: &crew, ActivityID: f.activity(t, a), Ring: rect(0, 0, 100, 100), AttackEnergy: 50})
	out := f.claim(t, ClaimInput{UserID: b, CrewID: &crew, ActivityID: f.activity(t, b), Ring: rect(0, 0, 200, 100), AttackEnergy: 500})
	if len(out.Attacks) != 0 || len(out.Claims) != 1 || !near(out.Claims[0].AreaM2, 10000, 30) {
		t.Fatalf("out = %+v", out)
	}
}
