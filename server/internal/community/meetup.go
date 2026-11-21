package community

import (
	"context"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/realtime"
)

// Meetup is 组局.
type Meetup struct {
	ID             int64        `json:"id"`
	Type           string       `json:"type"`
	Title          string       `json:"title"`
	Description    string       `json:"description"`
	StartTime      time.Time    `json:"start_time"`
	EndTime        time.Time    `json:"end_time"`
	Place          Place        `json:"place"`
	District       *string      `json:"district"`
	Capacity       int          `json:"capacity"`
	JoinedCount    int          `json:"joined_count"`
	Requirement    string       `json:"requirement"`
	Creator        UserBrief    `json:"creator"`
	Status         string       `json:"status"`
	ReviewStatus   string       `json:"review_status"`
	Joined         bool         `json:"joined"`
	ConversationID *int64       `json:"conversation_id"`
	DistanceM      *float64     `json:"distance_m"`
	CreatedAt      time.Time    `json:"created_at"`
	Members        *[]UserBrief `json:"members,omitempty"`

	creatorID int64
}

var meetupTypes = map[string]bool{"run": true, "ball": true, "ride": true}

const meetupJoined = `(SELECT count(*) FROM src.src_soc_loop_meetup_join j WHERE j.meetup_id=m.id)`

// meetupStatusSQL is the computed status (open | full | cancelled | ended).
const meetupStatusSQL = `CASE WHEN m.meetup_status='cancelled' THEN 'cancelled'
	WHEN m.meetup_status='ended' OR m.end_time <= now() THEN 'ended'
	WHEN ` + meetupJoined + ` >= m.capacity_qty THEN 'full' ELSE 'open' END`

// meetupCols uses $1 = viewer; dist is the distance expression (or NULL).
func meetupCols(dist string) string {
	return `m.id, m.meetup_type, m.title, m.description, m.start_time, m.end_time, m.place_name, ST_Y(m.place_geom), ST_X(m.place_geom),
		m.district, m.capacity_qty, ` + meetupJoined + `, m.requirement, m.creator_id, ` + meetupStatusSQL + `, m.review_status,
		EXISTS (SELECT 1 FROM src.src_soc_loop_meetup_join j WHERE j.meetup_id=m.id AND j.user_id=$1), m.conversation_id, ` + dist + `, m.create_time`
}

func (s *Service) queryMeetups(ctx context.Context, q db.Querier, dist, where string, args ...any) ([]Meetup, error) {
	rows, err := q.Query(ctx, `SELECT `+meetupCols(dist)+` FROM src.src_soc_loop_meetup m WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	ms, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Meetup, error) {
		var m Meetup
		err := r.Scan(&m.ID, &m.Type, &m.Title, &m.Description, &m.StartTime, &m.EndTime, &m.Place.Name, &m.Place.Lat, &m.Place.Lng,
			&m.District, &m.Capacity, &m.JoinedCount, &m.Requirement, &m.creatorID, &m.Status, &m.ReviewStatus, &m.Joined,
			&m.ConversationID, &m.DistanceM, &m.CreatedAt)
		return m, err
	})
	if err != nil {
		return nil, err
	}
	ids := make([]int64, len(ms))
	for i, m := range ms {
		ids[i] = m.creatorID
	}
	bs, err := briefs(ctx, q, ids)
	if err != nil {
		return nil, err
	}
	for i := range ms {
		ms[i].Creator = bs[ms[i].creatorID]
	}
	if ms == nil {
		ms = []Meetup{}
	}
	return ms, nil
}

// visibleMeetup: approved, or the viewer created it.
const visibleMeetup = `(m.review_status='approved' OR m.creator_id=$1)`

// Meetup loads one meetup with its members (404 when not visible).
func (s *Service) Meetup(ctx context.Context, q db.Querier, viewer, id int64) (Meetup, error) {
	ms, err := s.queryMeetups(ctx, q, `NULL::float8`, `m.id=$2 AND `+visibleMeetup, viewer, id)
	if err != nil {
		return Meetup{}, err
	}
	if len(ms) == 0 {
		return Meetup{}, httpx.NotFound("组局")
	}
	m := ms[0]
	rows, err := q.Query(ctx, `SELECT user_id FROM src.src_soc_loop_meetup_join WHERE meetup_id=$1 ORDER BY join_time, user_id`, id)
	if err != nil {
		return m, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return m, err
	}
	bs, err := briefs(ctx, q, ids)
	if err != nil {
		return m, err
	}
	members := make([]UserBrief, 0, len(ids))
	for _, id := range ids {
		if b, ok := bs[id]; ok {
			members = append(members, b)
		}
	}
	m.Members = &members
	return m, nil
}

// MeetupQuery filters GET /v1/meetups.
type MeetupQuery struct {
	Type    string
	Lat     *float64
	Lng     *float64
	RadiusM float64
}

// Meetups is GET /v1/meetups: upcoming, approved, not cancelled; by
// distance when a position is given, else by start time.
func (s *Service) Meetups(ctx context.Context, viewer int64, f MeetupQuery, c cursor) (CursorList[Meetup], error) {
	where := `m.start_time > now() AND m.review_status='approved' AND m.meetup_status='open' AND ($2='' OR m.meetup_type=$2)`
	args := []any{viewer, f.Type}
	dist := `NULL::float8`
	order := `m.start_time, m.id`
	if f.Lat != nil && f.Lng != nil {
		if f.RadiusM <= 0 {
			f.RadiusM = 10000
		}
		pt := `ST_SetSRID(ST_MakePoint($4,$3),4326)::geography`
		dist = `ST_Distance(m.place_geom::geography, ` + pt + `)`
		where += ` AND ST_DWithin(m.place_geom::geography, ` + pt + `, $5)`
		args = append(args, *f.Lat, *f.Lng, min(f.RadiusM, 100000))
		order = dist + `, m.start_time, m.id`
	}
	n := len(args)
	ms, err := s.queryMeetups(ctx, s.Pool, dist, where+fmt.Sprintf(` ORDER BY %s LIMIT $%d OFFSET $%d`, order, n+1, n+2), append(args, c.limit+1, c.offset)...)
	if err != nil {
		return CursorList[Meetup]{}, err
	}
	return page(ms, c), nil
}

// MyMeetups is GET /v1/me/meetups (not ended first).
func (s *Service) MyMeetups(ctx context.Context, viewer int64) ([]Meetup, error) {
	return s.queryMeetups(ctx, s.Pool, `NULL::float8`, `(m.creator_id=$1 OR EXISTS (SELECT 1 FROM src.src_soc_loop_meetup_join j WHERE j.meetup_id=m.id AND j.user_id=$1))
		ORDER BY (`+meetupStatusSQL+`) IN ('ended','cancelled'), CASE WHEN (`+meetupStatusSQL+`) IN ('ended','cancelled') THEN -extract(epoch FROM m.start_time) ELSE extract(epoch FROM m.start_time) END, m.id
		LIMIT 100`, viewer)
}

// MeetupInput is POST /v1/meetups.
type MeetupInput struct {
	Type        string    `json:"type"`
	Title       string    `json:"title"`
	Description string    `json:"description"`
	StartTime   time.Time `json:"start_time"`
	EndTime     time.Time `json:"end_time"`
	Place       Place     `json:"place"`
	District    *string   `json:"district"`
	Capacity    int       `json:"capacity"`
	Requirement string    `json:"requirement"`
}

func (in *MeetupInput) validate(now time.Time) error {
	bad := func(msg string) error { return httpx.BadRequest("invalid_body", msg) }
	in.Title, in.Description, in.Requirement = strings.TrimSpace(in.Title), strings.TrimSpace(in.Description), strings.TrimSpace(in.Requirement)
	in.Place.Name = strings.TrimSpace(in.Place.Name)
	if !meetupTypes[in.Type] {
		return bad("type 取值错误")
	}
	if n := utf8.RuneCountInString(in.Title); n < 1 || n > 30 {
		return bad("标题 1–30 字")
	}
	if utf8.RuneCountInString(in.Description) > 300 {
		return bad("说明最多 300 字")
	}
	if utf8.RuneCountInString(in.Requirement) > 50 {
		return bad("要求最多 50 字")
	}
	if in.StartTime.Before(now.Add(time.Hour)) || in.StartTime.After(now.Add(30*24*time.Hour)) {
		return bad("开始时间需在 1 小时后、30 天内")
	}
	if !in.EndTime.After(in.StartTime) || in.EndTime.Sub(in.StartTime) > 12*time.Hour {
		return bad("结束时间需晚于开始时间，时长不超过 12 小时")
	}
	if in.Capacity < 2 || in.Capacity > 50 {
		return bad("人数 2–50")
	}
	if in.Place.Name == "" || utf8.RuneCountInString(in.Place.Name) > 50 || !in.Place.valid() {
		return bad("请选择集合地点")
	}
	if in.District != nil {
		d := strings.TrimSpace(*in.District)
		in.District = &d
		if d == "" {
			in.District = nil
		}
	}
	return nil
}

// CreateMeetup creates a meetup, its group chat and the creator's sign-up.
// Risky text waits for review (only the creator sees it meanwhile).
func (s *Service) CreateMeetup(ctx context.Context, user int64, in MeetupInput) (Meetup, error) {
	if err := in.validate(time.Now()); err != nil {
		return Meetup{}, err
	}
	if mu, err := muted(ctx, s.Pool, user); err != nil {
		return Meetup{}, err
	} else if mu {
		return Meetup{}, errMuted
	}
	text := in.Title + "\n" + in.Description + "\n" + in.Requirement
	sc := s.Mod.Check(ctx, text, false)
	if sc.Blocked {
		return Meetup{}, moderation.ErrBlocked
	}
	review := "approved"
	if s.Mod.NeedsReview(ctx, sc) {
		review = "pending"
	}
	var id int64
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `INSERT INTO src.src_soc_loop_meetup (meetup_type, title, description, start_time, end_time, place_name, place_geom,
				district, capacity_qty, requirement, creator_id, review_status)
			VALUES ($1,$2,$3,$4,$5,$6, ST_SetSRID(ST_MakePoint($8,$7),4326), $9,$10,$11,$12,$13) RETURNING id`,
			in.Type, in.Title, in.Description, in.StartTime, in.EndTime, in.Place.Name, in.Place.Lat, in.Place.Lng,
			in.District, in.Capacity, in.Requirement, user, review).Scan(&id); err != nil {
			return err
		}
		conv, err := createGroup(ctx, tx, in.Title, "meetup", id, user)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_meetup SET conversation_id=$2 WHERE id=$1`, id, conv); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_soc_loop_meetup_join (meetup_id, user_id) VALUES ($1,$2)`, id, user); err != nil {
			return err
		}
		if review == "pending" {
			_, err = moderation.Submit(ctx, tx, moderation.Meetup, id, user, text, nil, sc)
		}
		return err
	})
	if err != nil {
		return Meetup{}, err
	}
	return s.Meetup(ctx, s.Pool, user, id)
}

type meetupRow struct {
	creator          int64
	status, review   string
	start, end       time.Time
	capacity, joined int
	conv             *int64
	title            string
	isMember         bool
}

func lockMeetup(ctx context.Context, tx pgx.Tx, viewer, id int64) (meetupRow, error) {
	var m meetupRow
	err := tx.QueryRow(ctx, `SELECT creator_id, meetup_status, review_status, start_time, end_time, capacity_qty, conversation_id, title,
			EXISTS (SELECT 1 FROM src.src_soc_loop_meetup_join j WHERE j.meetup_id=m.id AND j.user_id=$2)
		FROM src.src_soc_loop_meetup m WHERE id=$1 FOR UPDATE`, id, viewer).
		Scan(&m.creator, &m.status, &m.review, &m.start, &m.end, &m.capacity, &m.conv, &m.title, &m.isMember)
	if db.IsNoRows(err) || (err == nil && m.review != "approved" && m.creator != viewer) {
		return m, httpx.NotFound("组局")
	}
	if err != nil {
		return m, err
	}
	err = tx.QueryRow(ctx, `SELECT count(*) FROM src.src_soc_loop_meetup_join WHERE meetup_id=$1`, id).Scan(&m.joined)
	if m.status == "open" && !m.end.After(time.Now()) {
		m.status = "ended"
	}
	return m, err
}

var errMeetupClosed = httpx.Conflict("meetup_closed", "组局已取消或已结束")

// JoinMeetup signs the user up and adds them to the group chat.
func (s *Service) JoinMeetup(ctx context.Context, user, id int64) (Meetup, error) {
	err := s.tx(ctx, func(tx pgx.Tx, evs *[]realtime.Event) error {
		m, err := lockMeetup(ctx, tx, user, id)
		if err != nil || m.isMember {
			return err
		}
		if m.status != "open" {
			return errMeetupClosed
		}
		if !m.start.After(time.Now()) {
			return httpx.Conflict("meetup_started", "组局已经开始了")
		}
		if m.joined >= m.capacity {
			return httpx.Conflict("meetup_full", "人数已满")
		}
		if b, err := blockedEither(ctx, tx, user, m.creator); err != nil {
			return err
		} else if b {
			return errBlocked
		}
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_soc_loop_meetup_join (meetup_id, user_id) VALUES ($1,$2)`, id, user); err != nil {
			return err
		}
		if m.conv != nil {
			return joinGroup(ctx, tx, *m.conv, user, evs)
		}
		return nil
	})
	if err != nil {
		return Meetup{}, err
	}
	return s.Meetup(ctx, s.Pool, user, id)
}

// LeaveMeetup cancels the user's sign-up and takes them out of the chat.
func (s *Service) LeaveMeetup(ctx context.Context, user, id int64) (Meetup, error) {
	err := s.tx(ctx, func(tx pgx.Tx, evs *[]realtime.Event) error {
		m, err := lockMeetup(ctx, tx, user, id)
		if err != nil {
			return err
		}
		if m.creator == user {
			return httpx.Conflict("creator_cannot_leave", "发起人不能退出，可以取消组局")
		}
		if _, err := tx.Exec(ctx, `DELETE FROM src.src_soc_loop_meetup_join WHERE meetup_id=$1 AND user_id=$2`, id, user); err != nil {
			return err
		}
		if m.conv != nil {
			return leaveGroup(ctx, tx, *m.conv, user, evs)
		}
		return nil
	})
	if err != nil {
		return Meetup{}, err
	}
	return s.Meetup(ctx, s.Pool, user, id)
}

// CancelMeetup is the creator's cancel (admin=true: ops, any meetup).
func (s *Service) CancelMeetup(ctx context.Context, user, id int64, admin bool, reason string) (Meetup, error) {
	err := s.tx(ctx, func(tx pgx.Tx, evs *[]realtime.Event) error {
		viewer := user
		if admin {
			var c int64
			if err := tx.QueryRow(ctx, `SELECT creator_id FROM src.src_soc_loop_meetup WHERE id=$1`, id).Scan(&c); db.IsNoRows(err) {
				return httpx.NotFound("组局")
			} else if err != nil {
				return err
			}
			viewer = c
		}
		m, err := lockMeetup(ctx, tx, viewer, id)
		if err != nil {
			return err
		}
		if !admin && m.creator != user {
			return httpx.Forbidden("not_creator", "只有发起人可以取消")
		}
		if m.status == "cancelled" {
			return nil
		}
		if m.status == "ended" {
			return errMeetupClosed
		}
		return s.cancelMeetup(ctx, tx, id, m, admin, reason, evs)
	})
	if err != nil {
		return Meetup{}, err
	}
	if admin {
		ms, err := s.queryMeetups(ctx, s.Pool, `NULL::float8`, `m.id=$2`, int64(0), id)
		if err != nil || len(ms) == 0 {
			return Meetup{}, err
		}
		return ms[0], nil
	}
	return s.Meetup(ctx, s.Pool, user, id)
}

func (s *Service) cancelMeetup(ctx context.Context, tx pgx.Tx, id int64, m meetupRow, byOps bool, reason string, evs *[]realtime.Event) error {
	var r *string
	if reason = strings.TrimSpace(reason); reason != "" {
		r = &reason
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_meetup SET meetup_status='cancelled', cancel_reason=$2, update_time=now() WHERE id=$1`, id, r); err != nil {
		return err
	}
	rows, err := tx.Query(ctx, `SELECT user_id FROM src.src_soc_loop_meetup_join WHERE meetup_id=$1`, id)
	if err != nil {
		return err
	}
	users, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	body := fmt.Sprintf("你报名的组局「%s」已取消。", m.title)
	if byOps && reason != "" {
		body = fmt.Sprintf("你报名的组局「%s」已被取消：%s", m.title, reason)
	}
	for _, u := range users {
		if u == m.creator && !byOps {
			continue
		}
		if err := inbox.Notify(ctx, tx, u, inbox.Interaction, "组局已取消", body, map[string]any{"type": "meetup_cancelled", "meetup_id": id}); err != nil {
			return err
		}
	}
	if m.conv != nil {
		_, err = post(ctx, tx, *m.conv, nil, "system", "组局已取消", map[string]any{"event": "cancelled"}, evs)
	}
	return err
}

// MeetupApplier is the moderation.Meetup applier: approval makes the
// meetup visible, rejection cancels it and tells the creator.
func (s *Service) MeetupApplier() moderation.Applier {
	return moderation.Applier{
		Approve: func(ctx context.Context, tx pgx.Tx, id int64) error {
			_, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_meetup SET review_status='approved', update_time=now() WHERE id=$1`, id)
			return err
		},
		Reject: func(ctx context.Context, tx pgx.Tx, id int64, reason string) error {
			var creator int64
			var title string
			err := tx.QueryRow(ctx, `UPDATE src.src_soc_loop_meetup SET review_status='rejected', meetup_status='cancelled', cancel_reason=$2, update_time=now()
				WHERE id=$1 RETURNING creator_id, title`, id, reason).Scan(&creator, &title)
			if db.IsNoRows(err) {
				return nil
			}
			if err != nil {
				return err
			}
			return inbox.Notify(ctx, tx, creator, inbox.Interaction, "组局未通过审核",
				fmt.Sprintf("你发起的组局「%s」未通过审核：%s", title, reason), map[string]any{"type": "review_rejected", "meetup_id": id})
		},
	}
}

// AdminMeetups is GET /admin/v1/meetups.
func (s *Service) AdminMeetups(ctx context.Context, status, typ string, p httpx.Page) ([]Meetup, int, error) {
	where := `($2='' OR (` + meetupStatusSQL + `)=$2 OR m.review_status=$2) AND ($3='' OR m.meetup_type=$3)`
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_soc_loop_meetup m WHERE $1::bigint IS NOT NULL AND `+where, int64(0), status, typ).Scan(&total); err != nil {
		return nil, 0, err
	}
	ms, err := s.queryMeetups(ctx, s.Pool, `NULL::float8`, where+` ORDER BY m.start_time DESC, m.id DESC LIMIT $4 OFFSET $5`, int64(0), status, typ, p.Size, p.Offset())
	return ms, total, err
}
