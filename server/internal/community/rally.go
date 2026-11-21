package community

import (
	"context"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/activity"
	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/realtime"
)

// Rally timing: check-in from 30 minutes before to 60 minutes after the
// start; the bonus applies to activities that end within 3 hours of the
// start, after which the rally is ended.
const (
	checkinBefore  = 30 * time.Minute
	checkinAfter   = 60 * time.Minute
	rallyWindow    = 3 * time.Hour
	maxOpenRallies = 3
)

// Rally is 集结跑.
type Rally struct {
	ID             int64     `json:"id"`
	Crew           CrewRef   `json:"crew"`
	Creator        UserBrief `json:"creator"`
	Title          string    `json:"title"`
	StartTime      time.Time `json:"start_time"`
	Place          Place     `json:"place"`
	DistanceGoalM  float64   `json:"distance_goal_m"`
	Status         string    `json:"status"`
	JoinedCount    int       `json:"joined_count"`
	CheckedInCount int       `json:"checked_in_count"`
	Joined         bool      `json:"joined"`
	CheckedIn      bool      `json:"checked_in"`
	BonusActive    bool      `json:"bonus_active"`
	ConversationID *int64    `json:"conversation_id"`
	CreatedAt      time.Time `json:"created_at"`

	creatorID int64
}

// rallyStatusSQL is the computed status (open | cancelled | ended).
const rallyStatusSQL = `CASE WHEN r.rally_status='cancelled' THEN 'cancelled'
	WHEN r.rally_status='ended' OR r.start_time + interval '3 hours' <= now() THEN 'ended' ELSE 'open' END`

const rallyCols = `r.id, c.id, c.name, r.creator_id, r.title, r.start_time, r.place_name, ST_Y(r.place_geom), ST_X(r.place_geom), r.distance_goal_m,
	` + rallyStatusSQL + `,
	(SELECT count(*) FROM src.src_soc_loop_rally_join j WHERE j.rally_id=r.id),
	(SELECT count(*) FROM src.src_soc_loop_rally_join j WHERE j.rally_id=r.id AND j.checkin_time IS NOT NULL),
	EXISTS (SELECT 1 FROM src.src_soc_loop_rally_join j WHERE j.rally_id=r.id AND j.user_id=$1),
	EXISTS (SELECT 1 FROM src.src_soc_loop_rally_join j WHERE j.rally_id=r.id AND j.user_id=$1 AND j.checkin_time IS NOT NULL),
	r.conversation_id, r.create_time`

// queryRallies uses $1 = viewer.
func (s *Service) queryRallies(ctx context.Context, q db.Querier, viewer int64, where string, args ...any) ([]Rally, error) {
	rows, err := q.Query(ctx, `SELECT `+rallyCols+` FROM src.src_soc_loop_rally r JOIN src.src_soc_loop_crew c ON c.id=r.crew_id WHERE `+where,
		append([]any{viewer}, args...)...)
	if err != nil {
		return nil, err
	}
	rs, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Rally, error) {
		var r Rally
		err := row.Scan(&r.ID, &r.Crew.ID, &r.Crew.Name, &r.creatorID, &r.Title, &r.StartTime, &r.Place.Name, &r.Place.Lat, &r.Place.Lng,
			&r.DistanceGoalM, &r.Status, &r.JoinedCount, &r.CheckedInCount, &r.Joined, &r.CheckedIn, &r.ConversationID, &r.CreatedAt)
		return r, err
	})
	if err != nil {
		return nil, err
	}
	ids := make([]int64, len(rs))
	for i, r := range rs {
		ids[i] = r.creatorID
	}
	bs, err := briefs(ctx, q, ids)
	if err != nil {
		return nil, err
	}
	need := s.Config.For(viewer).Rally.MinCheckins
	for i := range rs {
		rs[i].Creator = bs[rs[i].creatorID]
		rs[i].BonusActive = rs[i].Status != "cancelled" && rs[i].CheckedInCount >= need
	}
	if rs == nil {
		rs = []Rally{}
	}
	return rs, nil
}

// Rally loads one rally.
func (s *Service) Rally(ctx context.Context, viewer, id int64) (Rally, error) {
	rs, err := s.queryRallies(ctx, s.Pool, viewer, `r.id=$2`, id)
	if err != nil {
		return Rally{}, err
	}
	if len(rs) == 0 {
		return Rally{}, httpx.NotFound("集结跑")
	}
	return rs[0], nil
}

const rallyOrder = ` ORDER BY (` + rallyStatusSQL + `) <> 'open',
	CASE WHEN (` + rallyStatusSQL + `) = 'open' THEN extract(epoch FROM r.start_time) ELSE -extract(epoch FROM r.start_time) END, r.id`

func inCrew(ctx context.Context, q db.Querier, user, crew int64) (bool, error) {
	var ok bool
	err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_soc_loop_crew_member WHERE crew_id=$1 AND user_id=$2)`, crew, user).Scan(&ok)
	return ok, err
}

// CrewRallies is GET /v1/crews/{id}/rallies: the last 30 days, not ended first.
func (s *Service) CrewRallies(ctx context.Context, viewer, crew int64) ([]Rally, error) {
	if ok, err := inCrew(ctx, s.Pool, viewer, crew); err != nil {
		return nil, err
	} else if !ok {
		return nil, errNotInCrew
	}
	return s.queryRallies(ctx, s.Pool, viewer, `r.crew_id=$2 AND r.start_time > now() - interval '30 days'`+rallyOrder+` LIMIT 100`, crew)
}

// RallyInput is POST /v1/crews/{id}/rallies.
type RallyInput struct {
	Title         string    `json:"title"`
	StartTime     time.Time `json:"start_time"`
	Place         Place     `json:"place"`
	DistanceGoalM float64   `json:"distance_goal_m"`
}

// CreateRally is the leader's call to a rally; every member is notified.
func (s *Service) CreateRally(ctx context.Context, user, crew int64, in RallyInput) (Rally, error) {
	bad := func(msg string) error { return httpx.BadRequest("invalid_body", msg) }
	in.Title, in.Place.Name = strings.TrimSpace(in.Title), strings.TrimSpace(in.Place.Name)
	now := time.Now()
	switch {
	case utf8.RuneCountInString(in.Title) < 1 || utf8.RuneCountInString(in.Title) > 30:
		return Rally{}, bad("标题 1–30 字")
	case !in.StartTime.After(now) || in.StartTime.After(now.Add(30*24*time.Hour)):
		return Rally{}, bad("开始时间需在 30 天内")
	case in.Place.Name == "" || !in.Place.valid():
		return Rally{}, bad("请选择集合地点")
	case in.DistanceGoalM < 0 || in.DistanceGoalM > 100000:
		return Rally{}, bad("目标距离不合法")
	}
	if s.Mod.Check(ctx, in.Title, false).Blocked {
		return Rally{}, moderation.ErrBlocked
	}
	var id int64
	err := s.tx(ctx, func(tx pgx.Tx, evs *[]realtime.Event) error {
		var leader int64
		var crewName string
		err := tx.QueryRow(ctx, `SELECT leader_id, name FROM src.src_soc_loop_crew WHERE id=$1 FOR UPDATE`, crew).Scan(&leader, &crewName)
		if db.IsNoRows(err) {
			return httpx.NotFound("跑团")
		}
		if err != nil {
			return err
		}
		if leader != user {
			return httpx.Forbidden("not_leader", "只有团长可以发起集结跑")
		}
		var open int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM src.src_soc_loop_rally r WHERE r.crew_id=$1 AND (`+rallyStatusSQL+`)='open'`, crew).Scan(&open); err != nil {
			return err
		}
		if open >= maxOpenRallies {
			return httpx.Conflict("rally_limit", "同一跑团最多同时有 3 个未结束的集结跑")
		}
		if err := tx.QueryRow(ctx, `INSERT INTO src.src_soc_loop_rally (crew_id, creator_id, title, start_time, place_name, place_geom, distance_goal_m)
			VALUES ($1,$2,$3,$4,$5, ST_SetSRID(ST_MakePoint($7,$6),4326), $8) RETURNING id`,
			crew, user, in.Title, in.StartTime, in.Place.Name, in.Place.Lat, in.Place.Lng, in.DistanceGoalM).Scan(&id); err != nil {
			return err
		}
		conv, err := createGroup(ctx, tx, in.Title, "rally", id, user)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_rally SET conversation_id=$2 WHERE id=$1`, id, conv); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_soc_loop_rally_join (rally_id, user_id) VALUES ($1,$2)`, id, user); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT user_id FROM src.src_soc_loop_crew_member WHERE crew_id=$1 AND user_id<>$2`, crew, user)
		if err != nil {
			return err
		}
		mates, err := pgx.CollectRows(rows, pgx.RowTo[int64])
		if err != nil {
			return err
		}
		body := fmt.Sprintf("「%s」团长发起了集结跑「%s」，%s 在%s集合，快来报名。", crewName, in.Title,
			in.StartTime.In(clock.Shanghai).Format("1月2日 15:04"), in.Place.Name)
		for _, u := range mates {
			if err := inbox.Notify(ctx, tx, u, inbox.Interaction, "跑团集结跑", body, map[string]any{"type": "rally_created", "rally_id": id, "crew_id": crew}); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return Rally{}, err
	}
	return s.Rally(ctx, user, id)
}

type rallyRow struct {
	crew, creator int64
	status        string
	start         time.Time
	conv          *int64
	lat, lng      float64
	joined        bool
}

func lockRally(ctx context.Context, tx pgx.Tx, user, id int64) (rallyRow, error) {
	var r rallyRow
	err := tx.QueryRow(ctx, `SELECT r.crew_id, r.creator_id, `+rallyStatusSQL+`, r.start_time, r.conversation_id, ST_Y(r.place_geom), ST_X(r.place_geom),
			EXISTS (SELECT 1 FROM src.src_soc_loop_rally_join j WHERE j.rally_id=r.id AND j.user_id=$2)
		FROM src.src_soc_loop_rally r WHERE r.id=$1 FOR UPDATE`, id, user).
		Scan(&r.crew, &r.creator, &r.status, &r.start, &r.conv, &r.lat, &r.lng, &r.joined)
	if db.IsNoRows(err) {
		return r, httpx.NotFound("集结跑")
	}
	return r, err
}

var errRallyClosed = httpx.Conflict("rally_closed", "集结跑已取消或已结束")

// JoinRally signs a crew member up and adds them to the group chat.
func (s *Service) JoinRally(ctx context.Context, user, id int64) (Rally, error) {
	err := s.tx(ctx, func(tx pgx.Tx, evs *[]realtime.Event) error {
		r, err := lockRally(ctx, tx, user, id)
		if err != nil || r.joined {
			return err
		}
		if ok, err := inCrew(ctx, tx, user, r.crew); err != nil {
			return err
		} else if !ok {
			return errNotInCrew
		}
		if r.status != "open" {
			return errRallyClosed
		}
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_soc_loop_rally_join (rally_id, user_id) VALUES ($1,$2)`, id, user); err != nil {
			return err
		}
		if r.conv != nil {
			return joinGroup(ctx, tx, *r.conv, user, evs)
		}
		return nil
	})
	if err != nil {
		return Rally{}, err
	}
	return s.Rally(ctx, user, id)
}

// LeaveRally cancels a sign-up (the creator cancels instead).
func (s *Service) LeaveRally(ctx context.Context, user, id int64) (Rally, error) {
	err := s.tx(ctx, func(tx pgx.Tx, evs *[]realtime.Event) error {
		r, err := lockRally(ctx, tx, user, id)
		if err != nil {
			return err
		}
		if r.creator == user {
			return httpx.Conflict("creator_cannot_leave", "发起人不能退出，可以取消集结跑")
		}
		if _, err := tx.Exec(ctx, `DELETE FROM src.src_soc_loop_rally_join WHERE rally_id=$1 AND user_id=$2`, id, user); err != nil {
			return err
		}
		if r.conv != nil {
			return leaveGroup(ctx, tx, *r.conv, user, evs)
		}
		return nil
	})
	if err != nil {
		return Rally{}, err
	}
	return s.Rally(ctx, user, id)
}

// CancelRally is the leader's (or creator's) cancel.
func (s *Service) CancelRally(ctx context.Context, user, id int64) (Rally, error) {
	err := s.tx(ctx, func(tx pgx.Tx, evs *[]realtime.Event) error {
		r, err := lockRally(ctx, tx, user, id)
		if err != nil {
			return err
		}
		var leader int64
		if err := tx.QueryRow(ctx, `SELECT leader_id FROM src.src_soc_loop_crew WHERE id=$1`, r.crew).Scan(&leader); err != nil {
			return err
		}
		if user != leader && user != r.creator {
			return httpx.Forbidden("not_leader", "只有团长可以取消集结跑")
		}
		if r.status == "cancelled" {
			return nil
		}
		if r.status == "ended" {
			return errRallyClosed
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_rally SET rally_status='cancelled', update_time=now() WHERE id=$1`, id); err != nil {
			return err
		}
		if r.conv != nil {
			_, err = post(ctx, tx, *r.conv, nil, "system", "集结跑已取消", map[string]any{"event": "cancelled"}, evs)
		}
		return err
	})
	if err != nil {
		return Rally{}, err
	}
	return s.Rally(ctx, user, id)
}

// Checkin records arrival at the meeting point (within the time window and
// rally.checkin_radius_m).
func (s *Service) Checkin(ctx context.Context, user, id int64, at geo.LatLng) (Rally, error) {
	cfg := s.Config.For(user).Rally
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		r, err := lockRally(ctx, tx, user, id)
		if err != nil {
			return err
		}
		no := func(msg string) error { return httpx.BadRequest("checkin_not_allowed", msg) }
		if r.status != "open" {
			return no("集结跑已取消或已结束")
		}
		if !r.joined {
			return no("请先报名这次集结跑")
		}
		now := time.Now()
		if now.Before(r.start.Add(-checkinBefore)) {
			return no("开始前 30 分钟才能签到")
		}
		if now.After(r.start.Add(checkinAfter)) {
			return no("签到时间已过（开始后 60 分钟内）")
		}
		if d := geo.Haversine(at, geo.LatLng{Lat: r.lat, Lng: r.lng}); d > cfg.CheckinRadiusM {
			return no(fmt.Sprintf("离集合点还有 %.0f 米，到 %.0f 米内才能签到", d, cfg.CheckinRadiusM))
		}
		_, err = tx.Exec(ctx, `UPDATE src.src_soc_loop_rally_join SET checkin_time=now() WHERE rally_id=$1 AND user_id=$2 AND checkin_time IS NULL`, id, user)
		return err
	})
	if err != nil {
		return Rally{}, err
	}
	return s.Rally(ctx, user, id)
}

// RallyBonus implements activity.Community: the rally the user checked in
// to whose start is at most 3 hours before the activity ended, once enough
// members checked in.
func (s *Service) RallyBonus(ctx context.Context, tx pgx.Tx, in activity.HookInput) (*activity.RallyBonus, error) {
	rate := in.Config.Rally.BonusRate
	if rate <= 0 {
		return nil, nil
	}
	var id int64
	err := tx.QueryRow(ctx, `SELECT r.id FROM src.src_soc_loop_rally r
		JOIN src.src_soc_loop_rally_join j ON j.rally_id=r.id AND j.user_id=$1 AND j.checkin_time IS NOT NULL
		WHERE r.rally_status <> 'cancelled' AND $2 BETWEEN r.start_time AND r.start_time + make_interval(secs => $4)
		  AND (SELECT count(*) FROM src.src_soc_loop_rally_join k WHERE k.rally_id=r.id AND k.checkin_time IS NOT NULL) >= $3
		ORDER BY r.start_time DESC LIMIT 1`, in.UserID, in.EndedAt, in.Config.Rally.MinCheckins, rallyWindow.Seconds()).Scan(&id)
	if db.IsNoRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &activity.RallyBonus{ID: id, BonusRate: rate}, nil
}
