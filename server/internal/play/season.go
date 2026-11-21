package play

import (
	"context"
	"fmt"
	"math"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/activity"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// weekStart is Monday 00:00 (Shanghai) of the week containing t.
func weekStart(t time.Time) time.Time {
	d := clock.Day(t)
	return d.AddDate(0, 0, -((int(d.Weekday()) + 6) % 7))
}

// Season is a season.
type Season struct {
	ID        int64      `json:"id"`
	Name      string     `json:"name"`
	StartsAt  time.Time  `json:"starts_at"`
	EndsAt    time.Time  `json:"ends_at"`
	DaysLeft  int        `json:"days_left"`
	SettledAt *time.Time `json:"settled_at,omitempty"`
}

func currentSeason(ctx context.Context, q db.Querier, at time.Time) (*Season, error) {
	var s Season
	err := q.QueryRow(ctx, `SELECT id, name, starts_at, ends_at, settled_at FROM seasons WHERE starts_at <= $1 AND ends_at > $1`, at).
		Scan(&s.ID, &s.Name, &s.StartsAt, &s.EndsAt, &s.SettledAt)
	if db.IsNoRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	s.DaysLeft = int(math.Ceil(time.Until(s.EndsAt).Hours() / 24))
	return &s, nil
}

// taskProgress computes a task's progress for the week containing at. The
// current (not yet settled) activity is included through extra.
func taskProgress(ctx context.Context, q db.Querier, user int64, t gameplay.SeasonTask, week time.Time, season *Season, cur *activity.HookInput) (float64, error) {
	end := week.AddDate(0, 0, 7)
	var v float64
	var err error
	switch t.Type {
	case gameplay.TaskWeeklyCount:
		err = q.QueryRow(ctx, `SELECT count(*) FROM activities WHERE user_id=$1 AND status='settled' AND started_at >= $2 AND started_at < $3`,
			user, week, end).Scan(&v)
		if cur != nil {
			v++
		}
	case gameplay.TaskWeeklyAreaM2:
		err = q.QueryRow(ctx, `SELECT COALESCE(sum(claimed_area_m2),0) FROM activities WHERE user_id=$1 AND status='settled' AND started_at >= $2 AND started_at < $3`,
			user, week, end).Scan(&v)
		if cur != nil {
			for _, c := range cur.Claims {
				v += c.AreaM2
			}
		}
	case gameplay.TaskWeeklyDistance:
		err = q.QueryRow(ctx, `SELECT COALESCE(sum(distance_m),0)/1000 FROM activities WHERE user_id=$1 AND status='settled' AND started_at >= $2 AND started_at < $3`,
			user, week, end).Scan(&v)
		if cur != nil {
			v += cur.DistanceM / 1000
		}
	case gameplay.TaskNewSport:
		// Completed by an activity this week whose sport the user had not
		// done earlier in the season.
		from := week
		if season != nil {
			from = season.StartsAt
		}
		err = q.QueryRow(ctx, `SELECT count(*) FROM activities a WHERE a.user_id=$1 AND a.status='settled' AND a.started_at >= $2 AND a.started_at < $3
			AND NOT EXISTS (SELECT 1 FROM activities b WHERE b.user_id=a.user_id AND b.status='settled' AND b.sport=a.sport
			                 AND b.started_at >= $4 AND b.started_at < a.started_at)`, user, week, end, from).Scan(&v)
		if cur != nil && v == 0 {
			var seen bool
			err = q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM activities WHERE user_id=$1 AND status='settled' AND sport=$2 AND started_at >= $3 AND id<>$4)`,
				user, string(cur.Sport), from, cur.ActivityID).Scan(&seen)
			if !seen {
				v = 1
			}
		}
	}
	return math.Min(v, t.Target), err
}

func (s *Service) tasks(ctx context.Context, tx pgx.Tx, in activity.HookInput) ([]activity.TaskProgress, error) {
	out := []activity.TaskProgress{}
	season, err := currentSeason(ctx, tx, in.StartedAt)
	if err != nil || season == nil {
		return out, err
	}
	week := weekStart(in.StartedAt)
	for _, t := range in.Config.SeasonTasks {
		var done bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM task_completions WHERE user_id=$1 AND task_key=$2 AND period=$3)`,
			in.UserID, t.Key, week).Scan(&done); err != nil {
			return out, err
		}
		if done {
			continue
		}
		p, err := taskProgress(ctx, tx, in.UserID, t, week, season, &in)
		if err != nil {
			return out, err
		}
		tp := activity.TaskProgress{Key: t.Key, Name: t.Name, Progress: p, Target: t.Target, RewardEnergy: t.RewardEnergy}
		if p >= t.Target {
			tp.Completed = true
			if _, err := tx.Exec(ctx, `INSERT INTO task_completions (user_id, task_key, period, reward_energy) VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING`,
				in.UserID, t.Key, week, t.RewardEnergy); err != nil {
				return out, err
			}
			if err := grant(ctx, tx, in.UserID, t.RewardEnergy, "task", 0); err != nil {
				return out, err
			}
		}
		out = append(out, tp)
	}
	return out, nil
}

// SeasonView is GET /v1/season.
type SeasonView struct {
	Season  *Season         `json:"season"`
	Me      *SeasonMe       `json:"me"`
	Crew    *SeasonCrew     `json:"crew"`
	Tiers   []TierView      `json:"tiers"`
	Top     []SeasonRankRow `json:"top"`
	CrewTop []CrewRankRow   `json:"crew_top"`
	Tasks   []TaskView      `json:"tasks"`
	Medals  any             `json:"medals"`
}

// SeasonMe is the viewer's standing.
type SeasonMe struct {
	AreaM2 float64  `json:"area_m2"`
	Tier   TierRef  `json:"tier"`
	Next   *NextRef `json:"next"`
	Rank   *int     `json:"rank"`
}

// TierRef is a tier and sub-level.
type TierRef struct {
	Name  string `json:"name"`
	Level string `json:"level"`
}

// NextRef is the next sub-level.
type NextRef struct {
	Name   string  `json:"name"`
	Level  string  `json:"level"`
	NeedM2 float64 `json:"need_m2"`
}

// SeasonCrew is the viewer's crew standing.
type SeasonCrew struct {
	ID     int64   `json:"id"`
	Name   string  `json:"name"`
	AreaM2 float64 `json:"area_m2"`
	Rank   int     `json:"rank"`
}

// TierView is a tier threshold.
type TierView struct {
	Name  string  `json:"name"`
	MinM2 float64 `json:"min_m2"`
}

// SeasonRankRow is a user leaderboard row.
type SeasonRankRow struct {
	Rank   int     `json:"rank"`
	User   UserRef `json:"user"`
	AreaM2 float64 `json:"area_m2"`
}

// CrewRankRow is a crew leaderboard row.
type CrewRankRow struct {
	Rank   int     `json:"rank"`
	Crew   CrewRef `json:"crew"`
	AreaM2 float64 `json:"area_m2"`
}

// CrewRef is a compact crew.
type CrewRef struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// TaskView is a weekly task.
type TaskView struct {
	Key          string  `json:"key"`
	Name         string  `json:"name"`
	Type         string  `json:"type"`
	Progress     float64 `json:"progress"`
	Target       float64 `json:"target"`
	RewardEnergy int     `json:"reward_energy"`
	Completed    bool    `json:"completed"`
}

const seasonAreaSQL = `SELECT a.user_id, sum(a.claimed_area_m2) AS area FROM activities a
	WHERE a.status='settled' AND a.started_at >= $1 AND a.started_at < $2 GROUP BY a.user_id HAVING sum(a.claimed_area_m2) > 0`

// GetSeason builds the season page.
func (s *Service) GetSeason(ctx context.Context, user int64, medals any) (SeasonView, error) {
	cfg := s.Config.For(user)
	v := SeasonView{Tiers: []TierView{}, Top: []SeasonRankRow{}, CrewTop: []CrewRankRow{}, Tasks: []TaskView{}, Medals: medals}
	for _, t := range cfg.Season.Tiers {
		v.Tiers = append(v.Tiers, TierView{Name: t.Name, MinM2: t.MinKm2 * 1e6})
	}
	season, err := currentSeason(ctx, s.Pool, time.Now())
	if err != nil || season == nil {
		return v, err
	}
	v.Season = season
	from, to := season.StartsAt, season.EndsAt

	var area float64
	if err := s.Pool.QueryRow(ctx, `SELECT COALESCE(sum(claimed_area_m2),0) FROM activities WHERE user_id=$1 AND status='settled' AND started_at >= $2 AND started_at < $3`,
		user, from, to).Scan(&area); err != nil {
		return v, err
	}
	name, level, nn, nl, need := cfg.TierFor(area)
	v.Me = &SeasonMe{AreaM2: area, Tier: TierRef{name, level}}
	if nn != "" {
		v.Me.Next = &NextRef{Name: nn, Level: nl, NeedM2: need}
	}
	if area > 0 {
		var r int
		if err := s.Pool.QueryRow(ctx, `SELECT count(*)+1 FROM (`+seasonAreaSQL+`) x WHERE x.area > $3`, from, to, area).Scan(&r); err != nil {
			return v, err
		}
		v.Me.Rank = &r
	}
	rows, err := s.Pool.Query(ctx, `SELECT u.id, u.nickname, u.avatar_url, x.area FROM (`+seasonAreaSQL+`) x JOIN users u ON u.id=x.user_id
		ORDER BY x.area DESC LIMIT 50`, from, to)
	if err != nil {
		return v, err
	}
	top, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (SeasonRankRow, error) {
		var x SeasonRankRow
		return x, r.Scan(&x.User.ID, &x.User.Nickname, &x.User.AvatarURL, &x.AreaM2)
	})
	if err != nil {
		return v, err
	}
	for i := range top {
		top[i].Rank = i + 1
	}
	if top != nil {
		v.Top = top
	}
	crewSQL := `SELECT c.id, c.name, sum(x.area) AS area FROM (` + seasonAreaSQL + `) x
		JOIN crew_members m ON m.user_id=x.user_id JOIN crews c ON c.id=m.crew_id GROUP BY c.id`
	rows, err = s.Pool.Query(ctx, crewSQL+` ORDER BY area DESC LIMIT 50`, from, to)
	if err != nil {
		return v, err
	}
	ctop, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (CrewRankRow, error) {
		var x CrewRankRow
		return x, r.Scan(&x.Crew.ID, &x.Crew.Name, &x.AreaM2)
	})
	if err != nil {
		return v, err
	}
	for i := range ctop {
		ctop[i].Rank = i + 1
	}
	if ctop != nil {
		v.CrewTop = ctop
	}
	var crewID int64
	var crewName string
	err = s.Pool.QueryRow(ctx, `SELECT c.id, c.name FROM crew_members m JOIN crews c ON c.id=m.crew_id WHERE m.user_id=$1`, user).Scan(&crewID, &crewName)
	if err == nil {
		sc := &SeasonCrew{ID: crewID, Name: crewName}
		err = s.Pool.QueryRow(ctx, `WITH t AS (`+crewSQL+`) SELECT COALESCE((SELECT area FROM t WHERE id=$3),0),
			(SELECT count(*)+1 FROM t WHERE area > COALESCE((SELECT area FROM t WHERE id=$3),0))`, from, to, crewID).Scan(&sc.AreaM2, &sc.Rank)
		if err != nil {
			return v, err
		}
		v.Crew = sc
	} else if !db.IsNoRows(err) {
		return v, err
	}
	week := weekStart(time.Now())
	for _, t := range cfg.SeasonTasks {
		tv := TaskView{Key: t.Key, Name: t.Name, Type: t.Type, Target: t.Target, RewardEnergy: t.RewardEnergy}
		if err := s.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM task_completions WHERE user_id=$1 AND task_key=$2 AND period=$3)`,
			user, t.Key, week).Scan(&tv.Completed); err != nil {
			return v, err
		}
		if tv.Completed {
			tv.Progress = t.Target
		} else if tv.Progress, err = taskProgress(ctx, s.Pool, user, t, week, season, nil); err != nil {
			return v, err
		}
		v.Tasks = append(v.Tasks, tv)
	}
	return v, nil
}

// SettleSeasons settles every ended season: final tiers become season
// medals in the codex; buildings and the codex are not reset.
func (s *Service) SettleSeasons(ctx context.Context, only int64) error {
	rows, err := s.Pool.Query(ctx, `SELECT id FROM seasons WHERE settled_at IS NULL AND (ends_at <= now() OR id=$1)`, only)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	cfg := s.Config.For(0)
	for _, id := range ids {
		err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
			var name string
			var from, to time.Time
			if err := tx.QueryRow(ctx, `SELECT name, starts_at, ends_at FROM seasons WHERE id=$1 AND settled_at IS NULL FOR UPDATE`, id).Scan(&name, &from, &to); err != nil {
				if db.IsNoRows(err) {
					return nil
				}
				return err
			}
			if to.After(time.Now()) {
				to = time.Now() // early settlement by admin
			}
			rows, err := tx.Query(ctx, seasonAreaSQL+` ORDER BY area DESC`, from, to)
			if err != nil {
				return err
			}
			type res struct {
				user int64
				area float64
			}
			rs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (res, error) {
				var x res
				return x, r.Scan(&x.user, &x.area)
			})
			if err != nil {
				return err
			}
			for i, r := range rs {
				tier, _, _, _, _ := cfg.TierFor(r.area)
				if _, err := tx.Exec(ctx, `INSERT INTO season_results (season_id, user_id, area_m2, rank, tier) VALUES ($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING`,
					id, r.user, r.area, i+1, tier); err != nil {
					return err
				}
				if _, err := tx.Exec(ctx, `INSERT INTO codex_items (user_id, kind, item) VALUES ($1,'medal',$2) ON CONFLICT DO NOTHING`,
					r.user, fmt.Sprintf("season:%s·%s", name, tier)); err != nil {
					return err
				}
				if err := inbox.Notify(ctx, tx, r.user, inbox.System, name+"结束了", fmt.Sprintf("你在%s排第 %d 名，最终段位%s，赛季奖牌已放入图鉴。", name, i+1, tier),
					map[string]any{"season_id": id}); err != nil {
					return err
				}
			}
			_, err = tx.Exec(ctx, `UPDATE seasons SET settled_at=now() WHERE id=$1`, id)
			return err
		})
		if err != nil {
			return err
		}
	}
	return nil
}

// ---------------------------------------------------------------- league

// LeagueRow is one crew in the district standings.
type LeagueRow struct {
	Rank          int     `json:"rank"`
	Crew          CrewRef `json:"crew"`
	ScoreM2       float64 `json:"score_m2"`
	ActiveMembers int     `json:"active_members"`
}

// LeagueView is GET /v1/league.
type LeagueView struct {
	WeekStart string      `json:"week_start"`
	District  string      `json:"district"`
	Standings []LeagueRow `json:"standings"`
	MyCrew    *struct {
		Rank    int     `json:"rank"`
		ScoreM2 float64 `json:"score_m2"`
	} `json:"my_crew"`
	LastWeek []LeagueRow `json:"last_week"`
}

func liveStandings(ctx context.Context, q db.Querier, district string, week time.Time) ([]LeagueRow, error) {
	rows, err := q.Query(ctx, `SELECT c.id, c.name, COALESCE(sum(a.claimed_area_m2),0) AS score, count(DISTINCT a.user_id)
		FROM crews c JOIN crew_members m ON m.crew_id=c.id
		LEFT JOIN activities a ON a.user_id=m.user_id AND a.status='settled' AND a.started_at >= $2 AND a.started_at < $3
		WHERE c.district=$1 GROUP BY c.id ORDER BY score DESC, c.id`, district, week, week.AddDate(0, 0, 7))
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (LeagueRow, error) {
		var x LeagueRow
		return x, r.Scan(&x.Crew.ID, &x.Crew.Name, &x.ScoreM2, &x.ActiveMembers)
	})
	for i := range out {
		out[i].Rank = i + 1
	}
	if out == nil {
		out = []LeagueRow{}
	}
	return out, err
}

// League builds the district league page.
func (s *Service) League(ctx context.Context, user int64, district string, week time.Time) (LeagueView, error) {
	var myCrew int64
	var myDistrict string
	err := s.Pool.QueryRow(ctx, `SELECT c.id, c.district FROM crew_members m JOIN crews c ON c.id=m.crew_id WHERE m.user_id=$1`, user).Scan(&myCrew, &myDistrict)
	if err != nil && !db.IsNoRows(err) {
		return LeagueView{}, err
	}
	if district == "" {
		district = myDistrict
	}
	if week.IsZero() {
		week = weekStart(time.Now())
	}
	v := LeagueView{WeekStart: week.Format("2006-01-02"), District: district, Standings: []LeagueRow{}, LastWeek: []LeagueRow{}}
	if district == "" {
		return v, nil
	}
	if week.Equal(weekStart(time.Now())) {
		if v.Standings, err = liveStandings(ctx, s.Pool, district, week); err != nil {
			return v, err
		}
	} else if v.Standings, err = storedStandings(ctx, s.Pool, district, week); err != nil {
		return v, err
	}
	for _, r := range v.Standings {
		if r.Crew.ID == myCrew {
			v.MyCrew = &struct {
				Rank    int     `json:"rank"`
				ScoreM2 float64 `json:"score_m2"`
			}{r.Rank, r.ScoreM2}
		}
	}
	v.LastWeek, err = storedStandings(ctx, s.Pool, district, week.AddDate(0, 0, -7))
	return v, err
}

func storedStandings(ctx context.Context, q db.Querier, district string, week time.Time) ([]LeagueRow, error) {
	rows, err := q.Query(ctx, `SELECT r.rank, c.id, c.name, r.score_m2, r.active_members FROM league_results r JOIN crews c ON c.id=r.crew_id
		WHERE r.district=$1 AND r.week_start=$2 ORDER BY r.rank`, district, week)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (LeagueRow, error) {
		var x LeagueRow
		return x, r.Scan(&x.Rank, &x.Crew.ID, &x.Crew.Name, &x.ScoreM2, &x.ActiveMembers)
	})
	if out == nil {
		out = []LeagueRow{}
	}
	return out, err
}

// SettleLeague stores last week's standings for every district (once).
func (s *Service) SettleLeague(ctx context.Context) error {
	last := weekStart(time.Now()).AddDate(0, 0, -7)
	var done bool
	if err := s.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM settings WHERE key='league_settled' AND value = to_jsonb($1::text))`,
		last.Format("2006-01-02")).Scan(&done); err != nil || done {
		return err
	}
	rows, err := s.Pool.Query(ctx, `SELECT DISTINCT district FROM crews`)
	if err != nil {
		return err
	}
	districts, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		for _, d := range districts {
			st, err := liveStandings(ctx, tx, d, last)
			if err != nil {
				return err
			}
			for _, r := range st {
				if r.ScoreM2 <= 0 {
					continue
				}
				if _, err := tx.Exec(ctx, `INSERT INTO league_results (week_start, district, crew_id, rank, score_m2, active_members) VALUES ($1,$2,$3,$4,$5,$6)
					ON CONFLICT DO NOTHING`, last, d, r.Crew.ID, r.Rank, r.ScoreM2, r.ActiveMembers); err != nil {
					return err
				}
				if r.Rank == 1 {
					rows, err := tx.Query(ctx, `SELECT user_id FROM crew_members WHERE crew_id=$1`, r.Crew.ID)
					if err != nil {
						return err
					}
					members, err := pgx.CollectRows(rows, pgx.RowTo[int64])
					if err != nil {
						return err
					}
					for _, m := range members {
						if err := inbox.Notify(ctx, tx, m, inbox.Interaction, "城区联赛冠军", fmt.Sprintf("上周%s城区联赛，你的跑团「%s」拿下第一！", d, r.Crew.Name),
							map[string]any{"crew_id": r.Crew.ID}); err != nil {
							return err
						}
					}
				}
			}
		}
		_, err := tx.Exec(ctx, `INSERT INTO settings (key, value) VALUES ('league_settled', to_jsonb($1::text))
			ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now()`, last.Format("2006-01-02"))
		return err
	})
}

// ---------------------------------------------------------------- admin seasons

// SeasonInput creates or edits a season.
type SeasonInput struct {
	Name     string    `json:"name"`
	StartsAt time.Time `json:"starts_at"`
	EndsAt   time.Time `json:"ends_at"`
}

func (in SeasonInput) validate() error {
	if in.Name == "" || !in.EndsAt.After(in.StartsAt) {
		return httpx.BadRequest("invalid_body", "请填写名称，结束时间要晚于开始时间")
	}
	return nil
}

func overlapErr(err error) error {
	if err != nil && (db.IsUniqueViolation(err) || isExclusion(err)) {
		return httpx.Conflict("season_overlap", "和已有赛季时间重叠")
	}
	return err
}

func isExclusion(err error) bool { return db.IsExclusionViolation(err) }
