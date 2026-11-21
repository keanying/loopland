package community

import (
	"context"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/activity"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Race is 赛事.
type Race struct {
	ID               int64              `json:"id"`
	Type             string             `json:"type"`
	Title            string             `json:"title"`
	CoverURL         *string            `json:"cover_url"`
	Description      string             `json:"description"`
	Sport            string             `json:"sport"`
	DistanceM        float64            `json:"distance_m"`
	StartTime        time.Time          `json:"start_time"`
	EndTime          time.Time          `json:"end_time"`
	SignupEndTime    time.Time          `json:"signup_end_time"`
	Place            *Place             `json:"place"`
	Capacity         int                `json:"capacity"`
	SignedCount      int                `json:"signed_count"`
	RequiresWearable bool               `json:"requires_wearable"`
	Medal            activity.RaceMedal `json:"medal"`
	Status           string             `json:"status"`
	MyEntry          *Entry             `json:"my_entry"`
	Leaderboard      *[]LeaderRow       `json:"leaderboard,omitempty"`
	Published        *bool              `json:"published,omitempty"`
}

// Entry is the viewer's sign-up.
type Entry struct {
	Status     string     `json:"status"`
	ResultSec  *int       `json:"result_sec"`
	FinishedAt *time.Time `json:"finished_at"`
	Rank       *int       `json:"rank"`
}

// LeaderRow is one leaderboard line.
type LeaderRow struct {
	Rank      int       `json:"rank"`
	User      UserBrief `json:"user"`
	ResultSec int       `json:"result_sec"`
}

// raceStatusSQL is the computed status.
const raceStatusSQL = `CASE WHEN r.race_status='cancelled' THEN 'cancelled' WHEN now() >= r.end_time THEN 'finished'
	WHEN now() >= r.start_time THEN 'running' WHEN now() < r.signup_end_time THEN 'signup' ELSE 'upcoming' END`

// entryStatusSQL shows signed entries of a finished race as dnf.
const entryStatusSQL = `CASE WHEN e.entry_status='signed' AND now() >= r.end_time THEN 'dnf' ELSE e.entry_status END`

// raceCols uses $1 = viewer (0: nobody).
const raceCols = `r.id, r.race_type, r.title, r.cover_url, r.description, r.sport, r.distance_m, r.start_time, r.end_time, r.signup_end_time,
	r.place_name, ST_Y(r.place_geom), ST_X(r.place_geom), r.capacity_qty,
	(SELECT count(*) FROM src.src_mkt_loop_race_entry x WHERE x.race_id=r.id), r.is_wearable_required,
	r.medal_key, r.medal_name, r.medal_image_url, ` + raceStatusSQL + `, r.is_published,
	` + entryStatusSQL + `, e.result_sec, e.finish_time,
	CASE WHEN e.entry_status='finished' AND e.result_sec IS NOT NULL THEN 1 + (SELECT count(*) FROM src.src_mkt_loop_race_entry o
		WHERE o.race_id=r.id AND o.entry_status='finished' AND (o.result_sec < e.result_sec OR (o.result_sec = e.result_sec AND o.finish_time < e.finish_time))) END`

func queryRaces(ctx context.Context, q db.Querier, where string, args ...any) ([]Race, error) {
	rows, err := q.Query(ctx, `SELECT `+raceCols+` FROM src.src_mkt_loop_race r
		LEFT JOIN src.src_mkt_loop_race_entry e ON e.race_id=r.id AND e.user_id=$1 WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Race, error) {
		var r Race
		var pname *string
		var lat, lng *float64
		var published bool
		var est *string
		var e Entry
		err := row.Scan(&r.ID, &r.Type, &r.Title, &r.CoverURL, &r.Description, &r.Sport, &r.DistanceM, &r.StartTime, &r.EndTime, &r.SignupEndTime,
			&pname, &lat, &lng, &r.Capacity, &r.SignedCount, &r.RequiresWearable, &r.Medal.Key, &r.Medal.Name, &r.Medal.ImageURL, &r.Status, &published,
			&est, &e.ResultSec, &e.FinishedAt, &e.Rank)
		if pname != nil && lat != nil && lng != nil {
			r.Place = &Place{Name: *pname, Lat: *lat, Lng: *lng}
		}
		if est != nil {
			e.Status = *est
			r.MyEntry = &e
		}
		r.Published = &published
		return r, err
	})
	if out == nil {
		out = []Race{}
	}
	return out, err
}

func hidePublished(rs []Race) {
	for i := range rs {
		rs[i].Published = nil
	}
}

// Races is GET /v1/races: published, active ones first.
func (s *Service) Races(ctx context.Context, viewer int64, status string, c cursor) (CursorList[Race], error) {
	rs, err := queryRaces(ctx, s.Pool, `r.is_published AND ($2='' OR (`+raceStatusSQL+`)=$2)
		ORDER BY (r.race_status='cancelled' OR now() >= r.end_time), CASE WHEN now() >= r.end_time THEN -extract(epoch FROM r.end_time) ELSE extract(epoch FROM r.start_time) END, r.id
		LIMIT $3 OFFSET $4`, viewer, status, c.limit+1, c.offset)
	if err != nil {
		return CursorList[Race]{}, err
	}
	hidePublished(rs)
	return page(rs, c), nil
}

// Race is GET /v1/races/{id} with the top-50 leaderboard (admin: viewer 0
// and unpublished races too).
func (s *Service) Race(ctx context.Context, viewer, id int64, admin bool) (Race, error) {
	rs, err := queryRaces(ctx, s.Pool, `r.id=$2 AND (r.is_published OR $3)`, viewer, id, admin)
	if err != nil {
		return Race{}, err
	}
	if len(rs) == 0 {
		return Race{}, httpx.NotFound("赛事")
	}
	r := rs[0]
	if !admin {
		r.Published = nil
	}
	rows, err := s.Pool.Query(ctx, `SELECT user_id, result_sec FROM src.src_mkt_loop_race_entry
		WHERE race_id=$1 AND entry_status='finished' AND result_sec IS NOT NULL ORDER BY result_sec, finish_time, user_id LIMIT 50`, id)
	if err != nil {
		return r, err
	}
	type lr struct {
		user int64
		sec  int
	}
	ls, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (lr, error) {
		var x lr
		return x, row.Scan(&x.user, &x.sec)
	})
	if err != nil {
		return r, err
	}
	ids := make([]int64, len(ls))
	for i, x := range ls {
		ids[i] = x.user
	}
	bs, err := briefs(ctx, s.Pool, ids)
	if err != nil {
		return r, err
	}
	board := make([]LeaderRow, 0, len(ls))
	for i, x := range ls {
		board = append(board, LeaderRow{Rank: i + 1, User: bs[x.user], ResultSec: x.sec})
	}
	r.Leaderboard = &board
	return r, nil
}

// Signup is POST /v1/races/{id}/signup.
func (s *Service) Signup(ctx context.Context, user, id int64) (Race, error) {
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var status string
		var capacity, signed int
		var signupEnd, end time.Time
		var mine bool
		err := tx.QueryRow(ctx, `SELECT race_status, capacity_qty, signup_end_time, end_time,
				EXISTS (SELECT 1 FROM src.src_mkt_loop_race_entry e WHERE e.race_id=r.id AND e.user_id=$2)
			FROM src.src_mkt_loop_race r WHERE id=$1 AND is_published FOR UPDATE`, id, user).Scan(&status, &capacity, &signupEnd, &end, &mine)
		if db.IsNoRows(err) {
			return httpx.NotFound("赛事")
		}
		if err != nil || mine {
			return err
		}
		now := time.Now()
		if status == "cancelled" || !now.Before(signupEnd) || !now.Before(end) {
			return httpx.Conflict("signup_closed", "报名已截止")
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM src.src_mkt_loop_race_entry WHERE race_id=$1`, id).Scan(&signed); err != nil {
			return err
		}
		if signed >= capacity {
			return httpx.Conflict("race_full", "名额已满")
		}
		_, err = tx.Exec(ctx, `INSERT INTO src.src_mkt_loop_race_entry (race_id, user_id) VALUES ($1,$2)`, id, user)
		return err
	})
	if err != nil {
		return Race{}, err
	}
	return s.Race(ctx, user, id, false)
}

// CancelSignup is DELETE /v1/races/{id}/signup (before the start).
func (s *Service) CancelSignup(ctx context.Context, user, id int64) (Race, error) {
	var started bool
	err := s.Pool.QueryRow(ctx, `SELECT now() >= start_time FROM src.src_mkt_loop_race WHERE id=$1 AND is_published`, id).Scan(&started)
	if db.IsNoRows(err) {
		return Race{}, httpx.NotFound("赛事")
	}
	if err != nil {
		return Race{}, err
	}
	if started {
		return Race{}, httpx.Conflict("race_started", "赛事已经开始，不能取消报名")
	}
	if _, err := s.Pool.Exec(ctx, `DELETE FROM src.src_mkt_loop_race_entry WHERE race_id=$1 AND user_id=$2 AND entry_status='signed'`, id, user); err != nil {
		return Race{}, err
	}
	return s.Race(ctx, user, id, false)
}

// finish records a result, awards the medal and notifies the runner. It
// returns false when the entry was already finished.
func finish(ctx context.Context, tx pgx.Tx, race, user int64, resultSec int, activityID *int64) (bool, error) {
	var title, key, name string
	err := tx.QueryRow(ctx, `UPDATE src.src_mkt_loop_race_entry e SET entry_status='finished', result_sec=$3, finish_time=now(), activity_id=$4
		FROM src.src_mkt_loop_race r WHERE r.id=e.race_id AND e.race_id=$1 AND e.user_id=$2 AND e.entry_status='signed'
		RETURNING r.title, r.medal_key, r.medal_name`, race, user, resultSec, activityID).Scan(&title, &key, &name)
	if db.IsNoRows(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO src.src_ply_loop_codex_item (user_id, item_type, item) VALUES ($1,'medal',$2) ON CONFLICT DO NOTHING`, user, key); err != nil {
		return false, err
	}
	return true, inbox.Notify(ctx, tx, user, inbox.Interaction, "赛事完赛",
		fmt.Sprintf("恭喜完成「%s」，成绩 %s，获得奖牌「%s」！", title, fmtDuration(resultSec), name),
		map[string]any{"type": "race_finished", "race_id": race, "medal": key})
}

func fmtDuration(sec int) string {
	if sec >= 3600 {
		return fmt.Sprintf("%d:%02d:%02d", sec/3600, sec/60%60, sec%60)
	}
	return fmt.Sprintf("%d:%02d", sec/60, sec%60)
}

// FinishRaces implements activity.Community: online races this activity
// completes (signed up, same sport, inside the window, far enough, with
// wearable data when required; first finish only).
func (s *Service) FinishRaces(ctx context.Context, tx pgx.Tx, in activity.HookInput) ([]activity.RaceDone, error) {
	out := []activity.RaceDone{}
	if in.DistanceM <= 0 || in.DurationS <= 0 {
		return out, nil
	}
	rows, err := tx.Query(ctx, `SELECT r.id, r.title, r.distance_m, r.medal_key, r.medal_name, r.medal_image_url
		FROM src.src_mkt_loop_race_entry e JOIN src.src_mkt_loop_race r ON r.id=e.race_id
		WHERE e.user_id=$1 AND e.entry_status='signed' AND r.race_type='online' AND r.race_status='normal' AND r.is_published
		  AND r.sport=$2 AND r.start_time <= $3 AND $4 <= r.end_time AND r.distance_m <= $5 AND (NOT r.is_wearable_required OR $6)
		ORDER BY r.id FOR UPDATE OF e`, in.UserID, string(in.Sport), in.StartedAt, in.EndedAt, in.DistanceM, in.Wearable)
	if err != nil {
		return out, err
	}
	type cand struct {
		done activity.RaceDone
		dist float64
	}
	cs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (cand, error) {
		var c cand
		return c, r.Scan(&c.done.ID, &c.done.Title, &c.dist, &c.done.Medal.Key, &c.done.Medal.Name, &c.done.Medal.ImageURL)
	})
	if err != nil {
		return out, err
	}
	aid := in.ActivityID
	for _, c := range cs {
		c.done.ResultSec = max(1, int(math.Round(float64(in.DurationS)*c.dist/in.DistanceM)))
		ok, err := finish(ctx, tx, c.done.ID, in.UserID, c.done.ResultSec, &aid)
		if err != nil {
			return out, err
		}
		if ok {
			out = append(out, c.done)
		}
	}
	return out, nil
}

// ---------------------------------------------------------------- admin

// RaceInput is the editable part of a race (admin).
type RaceInput struct {
	Type             string             `json:"type"`
	Title            string             `json:"title"`
	CoverURL         *string            `json:"cover_url"`
	Description      string             `json:"description"`
	Sport            string             `json:"sport"`
	DistanceM        float64            `json:"distance_m"`
	StartTime        time.Time          `json:"start_time"`
	EndTime          time.Time          `json:"end_time"`
	SignupEndTime    time.Time          `json:"signup_end_time"`
	Place            *Place             `json:"place"`
	Capacity         int                `json:"capacity"`
	RequiresWearable bool               `json:"requires_wearable"`
	Medal            activity.RaceMedal `json:"medal"`
	Published        bool               `json:"published"`
}

var reMedalKey = regexp.MustCompile(`^[a-z0-9_]{3,64}$`)

func (in *RaceInput) validate(cfg gameplay.Config) error {
	bad := func(msg string) error { return httpx.BadRequest("invalid_body", msg) }
	in.Title, in.Description = strings.TrimSpace(in.Title), strings.TrimSpace(in.Description)
	in.Medal.Key, in.Medal.Name = strings.TrimSpace(in.Medal.Key), strings.TrimSpace(in.Medal.Name)
	if in.Type != "online" && in.Type != "offline" {
		return bad("type 取值错误")
	}
	if n := utf8.RuneCountInString(in.Title); n < 1 || n > 40 {
		return bad("标题 1–40 字")
	}
	if !gameplay.GPSSports[gameplay.Sport(in.Sport)] {
		return bad("赛事运动类型只能是跑步、骑行、徒步、健走")
	}
	if in.DistanceM <= 0 || in.DistanceM > 500000 {
		return bad("赛事距离不合法")
	}
	if in.StartTime.IsZero() || !in.EndTime.After(in.StartTime) {
		return bad("结束时间需晚于开始时间")
	}
	if in.SignupEndTime.IsZero() {
		in.SignupEndTime = in.StartTime
	}
	if in.SignupEndTime.After(in.EndTime) {
		return bad("报名截止时间不能晚于结束时间")
	}
	if in.Capacity <= 0 {
		return bad("名额必须为正")
	}
	if in.Type == "offline" {
		if in.Place == nil || strings.TrimSpace(in.Place.Name) == "" || !in.Place.valid() {
			return bad("线下赛需要地点")
		}
		in.RequiresWearable = false
	} else {
		in.Place = nil
	}
	if in.Medal.Key == "" {
		in.Medal.Key = "race_" + strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	if !reMedalKey.MatchString(in.Medal.Key) {
		return bad("奖牌 key 只能用小写字母、数字、下划线（3–64 位）")
	}
	for _, m := range cfg.Medals {
		if m.Key == in.Medal.Key {
			return httpx.Conflict("medal_key_taken", "奖牌 key 和玩法配置里的奖牌重复")
		}
	}
	if in.Medal.Name == "" {
		in.Medal.Name = in.Title + " 完赛奖牌"
	}
	return nil
}

func placeArgs(p *Place) (*string, *float64, *float64) {
	if p == nil {
		return nil, nil, nil
	}
	name := strings.TrimSpace(p.Name)
	return &name, &p.Lat, &p.Lng
}

// CreateRace is POST /admin/v1/races.
func (s *Service) CreateRace(ctx context.Context, adminID int64, in RaceInput) (int64, error) {
	if err := in.validate(s.Config.For(0)); err != nil {
		return 0, err
	}
	name, lat, lng := placeArgs(in.Place)
	var id int64
	err := s.Pool.QueryRow(ctx, `INSERT INTO src.src_mkt_loop_race (race_type, title, cover_url, description, sport, distance_m, start_time, end_time,
			signup_end_time, place_name, place_geom, capacity_qty, is_wearable_required, medal_key, medal_name, medal_image_url, is_published, created_by)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10, CASE WHEN $11::float8 IS NULL THEN NULL ELSE ST_SetSRID(ST_MakePoint($12,$11),4326) END,
			$13,$14,$15,$16,$17,$18,$19) RETURNING id`,
		in.Type, in.Title, in.CoverURL, in.Description, in.Sport, in.DistanceM, in.StartTime, in.EndTime, in.SignupEndTime, name, lat, lng,
		in.Capacity, in.RequiresWearable, in.Medal.Key, in.Medal.Name, in.Medal.ImageURL, in.Published, adminID).Scan(&id)
	if db.IsUniqueViolation(err) {
		return 0, httpx.Conflict("medal_key_taken", "奖牌 key 已被其他赛事使用")
	}
	return id, err
}

// RaceInputOf returns a race's editable fields (PATCH starts from them).
func (s *Service) RaceInputOf(ctx context.Context, id int64) (RaceInput, error) {
	r, err := s.Race(ctx, 0, id, true)
	if err != nil {
		return RaceInput{}, err
	}
	return RaceInput{Type: r.Type, Title: r.Title, CoverURL: r.CoverURL, Description: r.Description, Sport: r.Sport, DistanceM: r.DistanceM,
		StartTime: r.StartTime, EndTime: r.EndTime, SignupEndTime: r.SignupEndTime, Place: r.Place, Capacity: r.Capacity,
		RequiresWearable: r.RequiresWearable, Medal: r.Medal, Published: *r.Published}, nil
}

// UpdateRace is PATCH /admin/v1/races/{id}.
func (s *Service) UpdateRace(ctx context.Context, id int64, oldKey string, in RaceInput) error {
	if err := in.validate(s.Config.For(0)); err != nil {
		return err
	}
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if in.Medal.Key != oldKey {
			var finished bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_mkt_loop_race_entry WHERE race_id=$1 AND entry_status='finished')`, id).Scan(&finished); err != nil {
				return err
			}
			if finished {
				return httpx.Conflict("medal_awarded", "已经有人完赛，不能再改奖牌 key")
			}
		}
		name, lat, lng := placeArgs(in.Place)
		_, err := tx.Exec(ctx, `UPDATE src.src_mkt_loop_race SET race_type=$2, title=$3, cover_url=$4, description=$5, sport=$6, distance_m=$7, start_time=$8,
				end_time=$9, signup_end_time=$10, place_name=$11, place_geom=CASE WHEN $12::float8 IS NULL THEN NULL ELSE ST_SetSRID(ST_MakePoint($13,$12),4326) END,
				capacity_qty=$14, is_wearable_required=$15, medal_key=$16, medal_name=$17, medal_image_url=$18, is_published=$19, update_time=now()
			WHERE id=$1`, id, in.Type, in.Title, in.CoverURL, in.Description, in.Sport, in.DistanceM, in.StartTime, in.EndTime, in.SignupEndTime,
			name, lat, lng, in.Capacity, in.RequiresWearable, in.Medal.Key, in.Medal.Name, in.Medal.ImageURL, in.Published)
		if db.IsUniqueViolation(err) {
			return httpx.Conflict("medal_key_taken", "奖牌 key 已被其他赛事使用")
		}
		return err
	})
}

// CancelRace is POST /admin/v1/races/{id}/cancel; entrants are notified.
func (s *Service) CancelRace(ctx context.Context, id int64) error {
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var title string
		err := tx.QueryRow(ctx, `UPDATE src.src_mkt_loop_race SET race_status='cancelled', update_time=now() WHERE id=$1 AND race_status<>'cancelled' RETURNING title`, id).Scan(&title)
		if db.IsNoRows(err) {
			var exists bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_mkt_loop_race WHERE id=$1)`, id).Scan(&exists); err != nil {
				return err
			}
			if !exists {
				return httpx.NotFound("赛事")
			}
			return nil
		}
		if err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT user_id FROM src.src_mkt_loop_race_entry WHERE race_id=$1 AND entry_status='signed'`, id)
		if err != nil {
			return err
		}
		users, err := pgx.CollectRows(rows, pgx.RowTo[int64])
		if err != nil {
			return err
		}
		for _, u := range users {
			if err := inbox.Notify(ctx, tx, u, inbox.System, "赛事已取消", fmt.Sprintf("你报名的赛事「%s」已取消。", title), map[string]any{"race_id": id}); err != nil {
				return err
			}
		}
		return nil
	})
}

// AdminEntry is a row of GET /admin/v1/races/{id}/entries.
type AdminEntry struct {
	User struct {
		ID       int64  `json:"id"`
		Nickname string `json:"nickname"`
	} `json:"user"`
	Status     string     `json:"status"`
	ResultSec  *int       `json:"result_sec"`
	FinishedAt *time.Time `json:"finished_at"`
	ActivityID *int64     `json:"activity_id"`
	SignedAt   time.Time  `json:"signed_at"`
}

// Entries lists a race's sign-ups (finished by result first).
func (s *Service) Entries(ctx context.Context, id int64, p httpx.Page) ([]AdminEntry, int, error) {
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_mkt_loop_race_entry WHERE race_id=$1`, id).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT u.id, u.nickname, `+entryStatusSQL+`, e.result_sec, e.finish_time, e.activity_id, e.signup_time
		FROM src.src_mkt_loop_race_entry e JOIN src.src_mkt_loop_race r ON r.id=e.race_id JOIN src.src_usr_loop_user u ON u.id=e.user_id
		WHERE e.race_id=$1 ORDER BY e.entry_status='finished' DESC, e.result_sec NULLS LAST, e.signup_time, u.id LIMIT $2 OFFSET $3`, id, p.Size, p.Offset())
	if err != nil {
		return nil, 0, err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (AdminEntry, error) {
		var x AdminEntry
		return x, r.Scan(&x.User.ID, &x.User.Nickname, &x.Status, &x.ResultSec, &x.FinishedAt, &x.ActivityID, &x.SignedAt)
	})
	return items, total, err
}

// FinishOffline marks an entrant as finished (线下赛) and awards the medal.
func (s *Service) FinishOffline(ctx context.Context, race, user int64, resultSec int) error {
	if resultSec <= 0 {
		return httpx.BadRequest("invalid_body", "成绩必须为正")
	}
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var status string
		err := tx.QueryRow(ctx, `SELECT entry_status FROM src.src_mkt_loop_race_entry WHERE race_id=$1 AND user_id=$2 FOR UPDATE`, race, user).Scan(&status)
		if db.IsNoRows(err) {
			return httpx.NotFound("报名记录")
		}
		if err != nil {
			return err
		}
		if status == "finished" { // correct the result, no second medal
			_, err := tx.Exec(ctx, `UPDATE src.src_mkt_loop_race_entry SET result_sec=$3 WHERE race_id=$1 AND user_id=$2`, race, user, resultSec)
			return err
		}
		_, err = finish(ctx, tx, race, user, resultSec, nil)
		return err
	})
}

// AdminRaces is GET /admin/v1/races.
func (s *Service) AdminRaces(ctx context.Context, p httpx.Page) ([]Race, int, error) {
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_mkt_loop_race`).Scan(&total); err != nil {
		return nil, 0, err
	}
	rs, err := queryRaces(ctx, s.Pool, `TRUE ORDER BY r.start_time DESC, r.id DESC LIMIT $2 OFFSET $3`, int64(0), p.Size, p.Offset())
	return rs, total, err
}

var _ activity.Community = (*Service)(nil)
