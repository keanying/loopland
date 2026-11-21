// Package crew is 跑团: create, join or apply, leave, manage members and the
// weekly in-crew ranking. Land claimed by members counts for the crew.
package crew

import (
	"context"
	"crypto/rand"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/media"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// UserRef is a compact user.
type UserRef struct {
	ID        int64   `json:"id"`
	Nickname  string  `json:"nickname"`
	AvatarURL *string `json:"avatar_url,omitempty"`
}

// Rank is one row of the weekly ranking.
type Rank struct {
	User      UserRef `json:"user"`
	DistanceM float64 `json:"distance_m"`
	AreaM2    float64 `json:"area_m2"`
}

// Crew is the API object.
type Crew struct {
	ID              int64   `json:"id"`
	Name            string  `json:"name"`
	AvatarURL       *string `json:"avatar_url"`
	District        string  `json:"district"`
	JoinMode        string  `json:"join_mode"`
	Leader          UserRef `json:"leader"`
	MemberCount     int     `json:"member_count"`
	TerritoryCount  int     `json:"territory_count"`
	TerritoryAreaM2 float64 `json:"territory_area_m2"`
	MyRole          *string `json:"my_role"`
	WeekRank        []Rank  `json:"week_rank,omitempty"`
}

// Of returns the user's crew id.
func Of(ctx context.Context, q db.Querier, user int64) (*int64, error) {
	var id int64
	err := q.QueryRow(ctx, `SELECT crew_id FROM src.src_soc_loop_crew_member WHERE user_id=$1`, user).Scan(&id)
	if db.IsNoRows(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// Handler serves /v1/crews.
type Handler struct {
	Pool *pgxpool.Pool
	// Mod scores crew names and queues name / avatar changes for review
	// after they take effect (先生效后审核).
	Mod *moderation.Moderator
}

// Routes registers the endpoints.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("POST /v1/crews", auth(h.create))
	mux.Handle("GET /v1/crews", auth(h.list))
	mux.Handle("GET /v1/crews/{id}", auth(h.get))
	mux.Handle("GET /v1/crews/{id}/members", auth(h.members))
	mux.Handle("GET /v1/crews/{id}/applications", auth(h.applications))
	mux.Handle("POST /v1/crews/{id}/join", auth(h.join))
	mux.Handle("POST /v1/crews/{id}/applications/{user}/approve", auth(h.approve))
	mux.Handle("POST /v1/crews/{id}/applications/{user}/reject", auth(h.reject))
	mux.Handle("POST /v1/crews/{id}/leave", auth(h.leave))
	mux.Handle("DELETE /v1/crews/{id}/members/{user}", auth(h.kick))
	mux.Handle("POST /v1/crews/{id}/transfer", auth(h.transfer))
	mux.Handle("PATCH /v1/crews/{id}", auth(h.patch))
	mux.Handle("POST /v1/crews/{id}/invites", auth(h.invite))
	mux.Handle("POST /v1/crews/join-by-code", auth(h.joinByCode))
}

const crewCols = `c.id, c.name, c.avatar_url, c.district, c.join_mode, u.id, u.nickname, u.avatar_url,
	(SELECT count(*) FROM src.src_soc_loop_crew_member m WHERE m.crew_id=c.id),
	(SELECT count(*) FROM src.src_ter_loop_territory t WHERE t.owner_crew_id=c.id),
	(SELECT COALESCE(sum(area_m2),0) FROM src.src_ter_loop_territory t WHERE t.owner_crew_id=c.id),
	CASE WHEN c.leader_id=$1 THEN 'leader'
	     WHEN EXISTS (SELECT 1 FROM src.src_soc_loop_crew_member m WHERE m.crew_id=c.id AND m.user_id=$1) THEN 'member'
	     WHEN EXISTS (SELECT 1 FROM src.src_soc_loop_crew_apply a WHERE a.crew_id=c.id AND a.user_id=$1) THEN 'applicant' END`

func scanCrew(row pgx.Row) (Crew, error) {
	var c Crew
	err := row.Scan(&c.ID, &c.Name, &c.AvatarURL, &c.District, &c.JoinMode, &c.Leader.ID, &c.Leader.Nickname, &c.Leader.AvatarURL,
		&c.MemberCount, &c.TerritoryCount, &c.TerritoryAreaM2, &c.MyRole)
	return c, err
}

func (h *Handler) load(ctx context.Context, viewer, id int64) (Crew, error) {
	c, err := scanCrew(h.Pool.QueryRow(ctx, `SELECT `+crewCols+` FROM src.src_soc_loop_crew c JOIN src.src_usr_loop_user u ON u.id=c.leader_id WHERE c.id=$2`, viewer, id))
	if db.IsNoRows(err) {
		return c, httpx.NotFound("跑团")
	}
	if err != nil {
		return c, err
	}
	weekStart := clock.Today()
	weekStart = weekStart.AddDate(0, 0, -((int(weekStart.Weekday()) + 6) % 7))
	rows, err := h.Pool.Query(ctx, `SELECT u.id, u.nickname, u.avatar_url,
			COALESCE((SELECT sum(distance_m) FROM src.src_act_loop_activity a WHERE a.user_id=u.id AND a.status='settled' AND a.start_time >= $2), 0) AS d,
			COALESCE((SELECT sum(claimed_area_m2) FROM src.src_act_loop_activity a WHERE a.user_id=u.id AND a.status='settled' AND a.start_time >= $2), 0) AS ar
		FROM src.src_soc_loop_crew_member m JOIN src.src_usr_loop_user u ON u.id=m.user_id WHERE m.crew_id=$1 ORDER BY ar DESC, d DESC LIMIT 50`, id, weekStart)
	if err != nil {
		return c, err
	}
	c.WeekRank, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Rank, error) {
		var k Rank
		return k, r.Scan(&k.User.ID, &k.User.Nickname, &k.User.AvatarURL, &k.DistanceM, &k.AreaM2)
	})
	if c.WeekRank == nil {
		c.WeekRank = []Rank{}
	}
	return c, err
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Name     string `json:"name"`
		District string `json:"district"`
		JoinMode string `json:"join_mode"`
		// AvatarURL is kept for older clients: only empty or the url of
		// one of the user's uploads.
		AvatarURL *string `json:"avatar_url"`
		AvatarID  *int64  `json:"avatar_id"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	req.Name = strings.TrimSpace(req.Name)
	if err := validName(req.Name); err != nil {
		return err
	}
	if strings.TrimSpace(req.District) == "" {
		return httpx.BadRequest("invalid_body", "请选择所在城区")
	}
	if req.JoinMode == "" {
		req.JoinMode = "open"
	}
	if req.JoinMode != "open" && req.JoinMode != "apply" && req.JoinMode != "invite" {
		return httpx.BadRequest("invalid_body", "join_mode 取值错误")
	}
	uid := httpx.UserID(r.Context())
	var id int64
	err := pgx.BeginFunc(r.Context(), h.Pool, func(tx pgx.Tx) error {
		if c, err := Of(r.Context(), tx, uid); err != nil {
			return err
		} else if c != nil {
			return httpx.Conflict("already_in_crew", "你已经在一个跑团里了")
		}
		avatar, err := ownedAvatar(r.Context(), tx, uid, req.AvatarID, req.AvatarURL)
		if err != nil {
			return err
		}
		sc, err := h.score(r.Context(), req.Name)
		if err != nil {
			return err
		}
		if taken, err := nameTaken(r.Context(), tx, req.Name, 0); err != nil {
			return err
		} else if taken {
			return errNameTaken
		}
		if err := tx.QueryRow(r.Context(), `INSERT INTO src.src_soc_loop_crew (name, district, join_mode, avatar_url, leader_id) VALUES ($1,$2,$3,$4,$5) RETURNING id`,
			req.Name, req.District, req.JoinMode, avatar, uid).Scan(&id); err != nil {
			if db.IsUniqueViolation(err) {
				return errNameTaken
			}
			return err
		}
		if _, err := moderation.Submit(r.Context(), tx, moderation.CrewName, id, uid, req.Name, nil, sc); err != nil {
			return err
		}
		if avatar != nil {
			if _, err := moderation.Submit(r.Context(), tx, moderation.CrewAvatar, id, uid, "", []string{*avatar}, moderation.Score{}); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(r.Context(), `INSERT INTO src.src_soc_loop_crew_member (crew_id, user_id) VALUES ($1,$2)`, id, uid); err != nil {
			return err
		}
		_, err = tx.Exec(r.Context(), `DELETE FROM src.src_soc_loop_crew_apply WHERE user_id=$1`, uid)
		return err
	})
	if err != nil {
		return err
	}
	c, err := h.load(r.Context(), uid, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, c)
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) error {
	uid := httpx.UserID(r.Context())
	p := httpx.GetPage(r)
	q, district := r.URL.Query().Get("q"), r.URL.Query().Get("district")
	where := `($2='' OR c.name ILIKE '%' || $2 || '%') AND ($3='' OR c.district=$3)`
	var total int
	if err := h.Pool.QueryRow(r.Context(), `SELECT count(*) FROM src.src_soc_loop_crew c WHERE `+where+` AND $1::bigint IS NOT NULL`, uid, q, district).Scan(&total); err != nil {
		return err
	}
	rows, err := h.Pool.Query(r.Context(), `SELECT `+crewCols+` FROM src.src_soc_loop_crew c JOIN src.src_usr_loop_user u ON u.id=c.leader_id WHERE `+where+`
		ORDER BY (SELECT COALESCE(sum(area_m2),0) FROM src.src_ter_loop_territory t WHERE t.owner_crew_id=c.id) DESC, c.id LIMIT $4 OFFSET $5`,
		uid, q, district, p.Size, p.Offset())
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Crew, error) { return scanCrew(r) })
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	c, err := h.load(r.Context(), httpx.UserID(r.Context()), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, c)
}

type member struct {
	User     UserRef   `json:"user"`
	Role     string    `json:"role,omitempty"`
	JoinedAt time.Time `json:"joined_at,omitempty"`
}

func (h *Handler) members(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	rows, err := h.Pool.Query(r.Context(), `SELECT u.id, u.nickname, u.avatar_url, CASE WHEN c.leader_id=u.id THEN 'leader' ELSE 'member' END, m.join_time
		FROM src.src_soc_loop_crew_member m JOIN src.src_usr_loop_user u ON u.id=m.user_id JOIN src.src_soc_loop_crew c ON c.id=m.crew_id WHERE m.crew_id=$1 ORDER BY m.join_time`, id)
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (member, error) {
		var m member
		return m, r.Scan(&m.User.ID, &m.User.Nickname, &m.User.AvatarURL, &m.Role, &m.JoinedAt)
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func requireLeader(ctx context.Context, q db.Querier, crew, uid int64) error {
	var leader int64
	err := q.QueryRow(ctx, `SELECT leader_id FROM src.src_soc_loop_crew WHERE id=$1`, crew).Scan(&leader)
	if db.IsNoRows(err) {
		return httpx.NotFound("跑团")
	}
	if err != nil {
		return err
	}
	if leader != uid {
		return httpx.Forbidden("not_leader", "只有团长可以这样做")
	}
	return nil
}

func (h *Handler) applications(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	if err := requireLeader(r.Context(), h.Pool, id, httpx.UserID(r.Context())); err != nil {
		return err
	}
	rows, err := h.Pool.Query(r.Context(), `SELECT u.id, u.nickname, u.avatar_url, a.create_time FROM src.src_soc_loop_crew_apply a JOIN src.src_usr_loop_user u ON u.id=a.user_id
		WHERE a.crew_id=$1 ORDER BY a.create_time`, id)
	if err != nil {
		return err
	}
	type app struct {
		User      UserRef   `json:"user"`
		CreatedAt time.Time `json:"created_at"`
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (app, error) {
		var a app
		return a, r.Scan(&a.User.ID, &a.User.Nickname, &a.User.AvatarURL, &a.CreatedAt)
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func addMember(ctx context.Context, tx pgx.Tx, crew, uid int64) error {
	if c, err := Of(ctx, tx, uid); err != nil {
		return err
	} else if c != nil {
		return httpx.Conflict("already_in_crew", "已经在一个跑团里了")
	}
	if _, err := tx.Exec(ctx, `INSERT INTO src.src_soc_loop_crew_member (crew_id, user_id) VALUES ($1,$2)`, crew, uid); err != nil {
		if db.IsUniqueViolation(err) {
			return httpx.Conflict("already_in_crew", "已经在一个跑团里了")
		}
		return err
	}
	_, err := tx.Exec(ctx, `DELETE FROM src.src_soc_loop_crew_apply WHERE user_id=$1`, uid)
	return err
}

func (h *Handler) join(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	uid := httpx.UserID(r.Context())
	status := "joined"
	err = pgx.BeginFunc(r.Context(), h.Pool, func(tx pgx.Tx) error {
		var mode string
		var leader int64
		err := tx.QueryRow(r.Context(), `SELECT join_mode, leader_id FROM src.src_soc_loop_crew WHERE id=$1 FOR UPDATE`, id).Scan(&mode, &leader)
		if db.IsNoRows(err) {
			return httpx.NotFound("跑团")
		}
		if err != nil {
			return err
		}
		switch mode {
		case "invite":
			return httpx.Forbidden("invite_only", "这个跑团只接受邀请加入")
		case "apply":
			if c, err := Of(r.Context(), tx, uid); err != nil {
				return err
			} else if c != nil {
				return httpx.Conflict("already_in_crew", "你已经在一个跑团里了")
			}
			status = "applied"
			tag, err := tx.Exec(r.Context(), `INSERT INTO src.src_soc_loop_crew_apply (crew_id, user_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`, id, uid)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 1 {
				return inbox.Notify(r.Context(), tx, leader, inbox.Interaction, "入团申请", "有新跑者申请加入你的跑团", map[string]any{"crew_id": id, "user_id": uid})
			}
			return nil
		default:
			return addMember(r.Context(), tx, id, uid)
		}
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]string{"status": status})
}

func (h *Handler) decide(w http.ResponseWriter, r *http.Request, approve bool) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	applicant, err := httpx.PathID(r, "user")
	if err != nil {
		return err
	}
	err = pgx.BeginFunc(r.Context(), h.Pool, func(tx pgx.Tx) error {
		if err := requireLeader(r.Context(), tx, id, httpx.UserID(r.Context())); err != nil {
			return err
		}
		tag, err := tx.Exec(r.Context(), `DELETE FROM src.src_soc_loop_crew_apply WHERE crew_id=$1 AND user_id=$2`, id, applicant)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return httpx.NotFound("申请")
		}
		title, body := "入团申请未通过", "跑团没有通过你的申请"
		if approve {
			if err := addMember(r.Context(), tx, id, applicant); err != nil {
				return err
			}
			title, body = "已加入跑团", "团长通过了你的入团申请"
		}
		return inbox.Notify(r.Context(), tx, applicant, inbox.Interaction, title, body, map[string]any{"crew_id": id})
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

func (h *Handler) approve(w http.ResponseWriter, r *http.Request) error { return h.decide(w, r, true) }
func (h *Handler) reject(w http.ResponseWriter, r *http.Request) error  { return h.decide(w, r, false) }

func (h *Handler) leave(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	uid := httpx.UserID(r.Context())
	err = pgx.BeginFunc(r.Context(), h.Pool, func(tx pgx.Tx) error {
		var leader int64
		if err := tx.QueryRow(r.Context(), `SELECT leader_id FROM src.src_soc_loop_crew WHERE id=$1 FOR UPDATE`, id).Scan(&leader); err != nil {
			if db.IsNoRows(err) {
				return httpx.NotFound("跑团")
			}
			return err
		}
		var n int
		if err := tx.QueryRow(r.Context(), `SELECT count(*) FROM src.src_soc_loop_crew_member WHERE crew_id=$1`, id).Scan(&n); err != nil {
			return err
		}
		if leader == uid {
			if n > 1 {
				return httpx.Conflict("leader_must_transfer", "请先把团长转让给其他成员")
			}
			_, err := tx.Exec(r.Context(), `DELETE FROM src.src_soc_loop_crew WHERE id=$1`, id) // last member: disband
			return err
		}
		tag, err := tx.Exec(r.Context(), `DELETE FROM src.src_soc_loop_crew_member WHERE crew_id=$1 AND user_id=$2`, id, uid)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return httpx.NotFound("成员")
		}
		return nil
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

func (h *Handler) kick(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	target, err := httpx.PathID(r, "user")
	if err != nil {
		return err
	}
	uid := httpx.UserID(r.Context())
	if target == uid {
		return httpx.BadRequest("invalid_body", "不能踢出自己")
	}
	err = pgx.BeginFunc(r.Context(), h.Pool, func(tx pgx.Tx) error {
		if err := requireLeader(r.Context(), tx, id, uid); err != nil {
			return err
		}
		tag, err := tx.Exec(r.Context(), `DELETE FROM src.src_soc_loop_crew_member WHERE crew_id=$1 AND user_id=$2`, id, target)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return httpx.NotFound("成员")
		}
		return inbox.Notify(r.Context(), tx, target, inbox.Interaction, "已离开跑团", "你被团长移出了跑团", map[string]any{"crew_id": id})
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

func (h *Handler) transfer(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		UserID int64 `json:"user_id"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	uid := httpx.UserID(r.Context())
	err = pgx.BeginFunc(r.Context(), h.Pool, func(tx pgx.Tx) error {
		if err := requireLeader(r.Context(), tx, id, uid); err != nil {
			return err
		}
		var ok bool
		if err := tx.QueryRow(r.Context(), `SELECT EXISTS (SELECT 1 FROM src.src_soc_loop_crew_member WHERE crew_id=$1 AND user_id=$2)`, id, req.UserID).Scan(&ok); err != nil {
			return err
		}
		if !ok || req.UserID == uid {
			return httpx.BadRequest("not_member", "只能转让给跑团里的其他成员")
		}
		if _, err := tx.Exec(r.Context(), `UPDATE src.src_soc_loop_crew SET leader_id=$2 WHERE id=$1`, id, req.UserID); err != nil {
			return err
		}
		return inbox.Notify(r.Context(), tx, req.UserID, inbox.Interaction, "你成为了团长", "原团长把跑团转让给了你", map[string]any{"crew_id": id})
	})
	if err != nil {
		return err
	}
	c, err := h.load(r.Context(), uid, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, c)
}

var errNameTaken = httpx.Conflict("name_taken", "这个跑团名称已被使用")

func validName(name string) error {
	if n := utf8.RuneCountInString(name); n < 2 || n > 16 {
		return httpx.BadRequest("invalid_name", "跑团名称 2–16 个字")
	}
	return nil
}

// nameTaken checks uniqueness up front: a unique violation would abort
// the transaction the review task is written in.
func nameTaken(ctx context.Context, q db.Querier, name string, except int64) (bool, error) {
	var taken bool
	err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_soc_loop_crew WHERE name=$1 AND id<>$2)`, name, except).Scan(&taken)
	return taken, err
}

// score checks a crew name; blocked words are refused outright.
func (h *Handler) score(ctx context.Context, name string) (moderation.Score, error) {
	if h.Mod == nil {
		return moderation.Score{Reasons: []string{}}, nil
	}
	sc := h.Mod.Check(ctx, name, false)
	if sc.Blocked {
		return sc, moderation.ErrBlocked
	}
	return sc, nil
}

// ownedAvatar resolves avatar_id (or a legacy avatar_url) to the url of
// one of the user's uploads; nil means no avatar.
func ownedAvatar(ctx context.Context, q db.Querier, uid int64, id *int64, url *string) (*string, error) {
	switch {
	case id != nil:
		ims, err := media.Owned(ctx, q, uid, []int64{*id})
		if err != nil {
			return nil, err
		}
		return &ims[0].URL, nil
	case url != nil && *url != "":
		im, err := media.OwnedURL(ctx, q, uid, *url)
		if err != nil {
			return nil, err
		}
		return &im.URL, nil
	}
	return nil, nil
}

func (h *Handler) patch(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Name     *string `json:"name"`
		AvatarID *int64  `json:"avatar_id"`
		District *string `json:"district"`
		JoinMode *string `json:"join_mode"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	err = pgx.BeginFunc(ctx, h.Pool, func(tx pgx.Tx) error {
		var curName string
		var curAvatar *string
		var leader int64
		if err := tx.QueryRow(ctx, `SELECT name, avatar_url, leader_id FROM src.src_soc_loop_crew WHERE id=$1 FOR UPDATE`, id).Scan(&curName, &curAvatar, &leader); err != nil {
			if db.IsNoRows(err) {
				return httpx.NotFound("跑团")
			}
			return err
		}
		if leader != uid {
			return httpx.Forbidden("not_leader", "只有团长可以这样做")
		}
		if req.Name != nil {
			name := strings.TrimSpace(*req.Name)
			if err := validName(name); err != nil {
				return err
			}
			if name != curName {
				sc, err := h.score(ctx, name)
				if err != nil {
					return err
				}
				if taken, err := nameTaken(ctx, tx, name, id); err != nil {
					return err
				} else if taken {
					return errNameTaken
				}
				if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_crew SET name=$2 WHERE id=$1`, id, name); err != nil {
					return err
				}
				if _, err := moderation.Submit(ctx, tx, moderation.CrewName, id, uid, name, nil, sc); err != nil {
					return err
				}
			}
		}
		if req.AvatarID != nil {
			url, err := ownedAvatar(ctx, tx, uid, req.AvatarID, nil)
			if err != nil {
				return err
			}
			if curAvatar == nil || *curAvatar != *url {
				if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_crew SET avatar_url=$2 WHERE id=$1`, id, *url); err != nil {
					return err
				}
				if _, err := moderation.Submit(ctx, tx, moderation.CrewAvatar, id, uid, "", []string{*url}, moderation.Score{}); err != nil {
					return err
				}
			}
		}
		if req.District != nil {
			d := strings.TrimSpace(*req.District)
			if d == "" {
				return httpx.BadRequest("invalid_body", "请选择所在城区")
			}
			if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_crew SET district=$2 WHERE id=$1`, id, d); err != nil {
				return err
			}
		}
		if req.JoinMode != nil {
			if m := *req.JoinMode; m != "open" && m != "apply" && m != "invite" {
				return httpx.BadRequest("invalid_body", "join_mode 取值错误")
			}
			if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_crew SET join_mode=$2 WHERE id=$1`, id, *req.JoinMode); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	c, err := h.load(ctx, uid, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, c)
}

// InviteTTL is how long an invite code works.
const InviteTTL = 7 * 24 * time.Hour

// inviteAlphabet leaves out 0/O and 1/I.
const inviteAlphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

func newInviteCode() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = inviteAlphabet[int(b[i])%len(inviteAlphabet)]
	}
	return string(b)
}

func (h *Handler) invite(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	if err := requireLeader(ctx, h.Pool, id, uid); err != nil {
		return err
	}
	exp := time.Now().Add(InviteTTL)
	for range 5 {
		code := newInviteCode()
		tag, err := h.Pool.Exec(ctx, `INSERT INTO src.src_soc_loop_crew_invite (crew_id, invite_code, creator_id, expire_time) VALUES ($1,$2,$3,$4)
			ON CONFLICT (invite_code) DO NOTHING`, id, code, uid, exp)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 1 {
			return httpx.OK(w, map[string]any{"code": code, "expires_at": exp})
		}
	}
	return httpx.Conflict("try_again", "邀请码生成失败，请重试")
}

func (h *Handler) joinByCode(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Code string `json:"code"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	code := strings.ToUpper(strings.TrimSpace(req.Code))
	var crewID int64
	err := pgx.BeginFunc(ctx, h.Pool, func(tx pgx.Tx) error {
		var inviteID int64
		err := tx.QueryRow(ctx, `SELECT i.id, i.crew_id FROM src.src_soc_loop_crew_invite i JOIN src.src_soc_loop_crew c ON c.id=i.crew_id
			WHERE i.invite_code=$1 AND i.expire_time > now() FOR UPDATE OF c`, code).Scan(&inviteID, &crewID)
		if db.IsNoRows(err) {
			return httpx.BadRequest("invalid_invite", "邀请码无效或已过期")
		}
		if err != nil {
			return err
		}
		if err := addMember(ctx, tx, crewID, uid); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE src.src_soc_loop_crew_invite SET use_qty=use_qty+1 WHERE id=$1`, inviteID)
		return err
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"status": "joined", "crew_id": crewID})
}
