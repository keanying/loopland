package community

import (
	"context"
	"net/http"
	"strconv"

	"github.com/keanying/loopland/server/internal/crew"
	"github.com/keanying/loopland/server/internal/geo"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Handler serves the app endpoints.
type Handler struct{ Svc *Service }

// Routes registers the endpoints; auth requires a bound phone, authAny
// does not (inbox).
func (h *Handler) Routes(mux *http.ServeMux, auth, authAny func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /v1/conversations", auth(h.conversations))
	mux.Handle("POST /v1/conversations/direct", auth(h.direct))
	mux.Handle("GET /v1/conversations/{id}", auth(h.conversation))
	mux.Handle("GET /v1/conversations/{id}/messages", auth(h.messages))
	mux.Handle("POST /v1/conversations/{id}/messages", auth(h.send))
	mux.Handle("POST /v1/conversations/{id}/read", auth(h.read))
	mux.Handle("POST /v1/conversations/{id}/mute", auth(h.mute))
	mux.Handle("DELETE /v1/conversations/{id}", auth(h.deleteConversation))

	mux.Handle("GET /v1/meetups", auth(h.meetups))
	mux.Handle("GET /v1/me/meetups", auth(h.myMeetups))
	mux.Handle("POST /v1/meetups", auth(h.createMeetup))
	mux.Handle("GET /v1/meetups/{id}", auth(h.meetup))
	mux.Handle("POST /v1/meetups/{id}/join", auth(h.meetupAction(h.Svc.JoinMeetup)))
	mux.Handle("POST /v1/meetups/{id}/leave", auth(h.meetupAction(h.Svc.LeaveMeetup)))
	mux.Handle("POST /v1/meetups/{id}/cancel", auth(h.meetupAction(func(ctx context.Context, u, id int64) (Meetup, error) {
		return h.Svc.CancelMeetup(ctx, u, id, false, "")
	})))

	mux.Handle("GET /v1/crews/{id}/rallies", auth(h.rallies))
	mux.Handle("POST /v1/crews/{id}/rallies", auth(h.createRally))
	mux.Handle("POST /v1/rallies/{id}/join", auth(h.rallyAction(h.Svc.JoinRally)))
	mux.Handle("POST /v1/rallies/{id}/leave", auth(h.rallyAction(h.Svc.LeaveRally)))
	mux.Handle("POST /v1/rallies/{id}/cancel", auth(h.rallyAction(h.Svc.CancelRally)))
	mux.Handle("POST /v1/rallies/{id}/checkin", auth(h.checkin))

	mux.Handle("GET /v1/races", auth(h.races))
	mux.Handle("GET /v1/races/{id}", auth(h.race))
	mux.Handle("POST /v1/races/{id}/signup", auth(h.signup))
	mux.Handle("DELETE /v1/races/{id}/signup", auth(h.raceAction(h.Svc.CancelSignup)))

	mux.Handle("GET /v1/inbox/summary", authAny(h.summary))
	mux.Handle("GET /v1/community/home", auth(h.home))
}

func uid(r *http.Request) int64 { return httpx.UserID(r.Context()) }

// ---------------------------------------------------------------- chat

func (h *Handler) conversations(w http.ResponseWriter, r *http.Request) error {
	l, err := h.Svc.ListConversations(r.Context(), uid(r), getCursor(r, 20))
	if err != nil {
		return err
	}
	return httpx.OK(w, l)
}

func (h *Handler) conversation(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	c, err := h.Svc.Conversation(r.Context(), uid(r), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, c)
}

func (h *Handler) direct(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		UserID int64 `json:"user_id"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	c, err := h.Svc.OpenDirect(r.Context(), uid(r), req.UserID)
	if err != nil {
		return err
	}
	return httpx.OK(w, c)
}

func (h *Handler) messages(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	before, _ := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
	if before == 0 {
		before, _ = strconv.ParseInt(r.URL.Query().Get("cursor"), 10, 64)
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	l, err := h.Svc.Messages(r.Context(), uid(r), id, max(0, before), limit)
	if err != nil {
		return err
	}
	return httpx.OK(w, l)
}

func (h *Handler) send(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in SendInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	m, err := h.Svc.Send(r.Context(), uid(r), id, in)
	if err != nil {
		return err
	}
	return httpx.OK(w, m)
}

func (h *Handler) read(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		MessageID int64 `json:"message_id"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if err := h.Svc.Read(r.Context(), uid(r), id, req.MessageID); err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

func (h *Handler) mute(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Muted bool `json:"muted"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if err := h.Svc.Mute(r.Context(), uid(r), id, req.Muted); err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

func (h *Handler) deleteConversation(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	if err := h.Svc.Delete(r.Context(), uid(r), id); err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

// ---------------------------------------------------------------- meetups

func optFloat(r *http.Request, name string) *float64 {
	v, err := strconv.ParseFloat(r.URL.Query().Get(name), 64)
	if err != nil {
		return nil
	}
	return &v
}

func (h *Handler) meetups(w http.ResponseWriter, r *http.Request) error {
	f := MeetupQuery{Type: r.URL.Query().Get("type"), Lat: optFloat(r, "lat"), Lng: optFloat(r, "lng")}
	if v := optFloat(r, "radius_m"); v != nil {
		f.RadiusM = *v
	}
	l, err := h.Svc.Meetups(r.Context(), uid(r), f, getCursor(r, 20))
	if err != nil {
		return err
	}
	return httpx.OK(w, l)
}

func (h *Handler) myMeetups(w http.ResponseWriter, r *http.Request) error {
	ms, err := h.Svc.MyMeetups(r.Context(), uid(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(ms))
}

func (h *Handler) createMeetup(w http.ResponseWriter, r *http.Request) error {
	var in MeetupInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	m, err := h.Svc.CreateMeetup(r.Context(), uid(r), in)
	if err != nil {
		return err
	}
	return httpx.OK(w, m)
}

func (h *Handler) meetup(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	m, err := h.Svc.Meetup(r.Context(), h.Svc.Pool, uid(r), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, m)
}

func (h *Handler) meetupAction(fn func(ctx context.Context, user, id int64) (Meetup, error)) httpx.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		id, err := httpx.PathID(r, "id")
		if err != nil {
			return err
		}
		m, err := fn(r.Context(), uid(r), id)
		if err != nil {
			return err
		}
		return httpx.OK(w, m)
	}
}

// ---------------------------------------------------------------- rallies

func (h *Handler) rallies(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	rs, err := h.Svc.CrewRallies(r.Context(), uid(r), id)
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(rs))
}

func (h *Handler) createRally(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var in RallyInput
	if err := httpx.Decode(r, &in); err != nil {
		return err
	}
	ra, err := h.Svc.CreateRally(r.Context(), uid(r), id, in)
	if err != nil {
		return err
	}
	return httpx.OK(w, ra)
}

func (h *Handler) rallyAction(fn func(ctx context.Context, user, id int64) (Rally, error)) httpx.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		id, err := httpx.PathID(r, "id")
		if err != nil {
			return err
		}
		ra, err := fn(r.Context(), uid(r), id)
		if err != nil {
			return err
		}
		return httpx.OK(w, ra)
	}
}

func (h *Handler) checkin(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var at geo.LatLng
	if err := httpx.Decode(r, &at); err != nil {
		return err
	}
	ra, err := h.Svc.Checkin(r.Context(), uid(r), id, at)
	if err != nil {
		return err
	}
	return httpx.OK(w, ra)
}

// ---------------------------------------------------------------- races

func (h *Handler) races(w http.ResponseWriter, r *http.Request) error {
	l, err := h.Svc.Races(r.Context(), uid(r), r.URL.Query().Get("status"), getCursor(r, 20))
	if err != nil {
		return err
	}
	return httpx.OK(w, l)
}

func (h *Handler) race(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	ra, err := h.Svc.Race(r.Context(), uid(r), id, false)
	if err != nil {
		return err
	}
	return httpx.OK(w, ra)
}

// signup returns the Race for free races and {"race","pay_params"} for
// paid ones (docs/api/v2-4-本地生活与商户.md D-12).
func (h *Handler) signup(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Channel string `json:"channel"`
	}
	if r.ContentLength != 0 {
		if err := httpx.Decode(r, &req); err != nil {
			return err
		}
	}
	ra, params, err := h.Svc.SignupWith(r.Context(), uid(r), id, req.Channel, httpx.ClientIP(r))
	if err != nil {
		return err
	}
	if ra.FeeAmt > 0 {
		return httpx.OK(w, map[string]any{"race": ra, "pay_params": params})
	}
	return httpx.OK(w, ra)
}

func (h *Handler) raceAction(fn func(ctx context.Context, user, id int64) (Race, error)) httpx.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		id, err := httpx.PathID(r, "id")
		if err != nil {
			return err
		}
		ra, err := fn(r.Context(), uid(r), id)
		if err != nil {
			return err
		}
		return httpx.OK(w, ra)
	}
}

// ---------------------------------------------------------------- inbox & home

// Summary is GET /v1/inbox/summary.
func (s *Service) Summary(ctx context.Context, user int64) (map[string]int, error) {
	out, err := inbox.UnreadByCategory(ctx, s.Pool, user)
	if err != nil {
		return nil, err
	}
	out["chat"], err = ChatUnread(ctx, s.Pool, user)
	return out, err
}

func (h *Handler) summary(w http.ResponseWriter, r *http.Request) error {
	m, err := h.Svc.Summary(r.Context(), uid(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, m)
}

// HomeCrew is the crew card on the community home.
type HomeCrew struct {
	ID          int64   `json:"id"`
	Name        string  `json:"name"`
	AvatarURL   *string `json:"avatar_url"`
	MemberCount int     `json:"member_count"`
	WeekAreaM2  float64 `json:"week_area_m2"`
	MyRank      *int    `json:"my_rank"`
}

// Home is GET /v1/community/home.
type Home struct {
	Crew   *HomeCrew `json:"crew"`
	Unread struct {
		Interaction int `json:"interaction"`
		Chat        int `json:"chat"`
	} `json:"unread"`
	Rallies []Rally  `json:"rallies"`
	Meetups []Meetup `json:"meetups"`
	Races   []Race   `json:"races"`
}

// Home builds the community home.
func (s *Service) Home(ctx context.Context, user int64) (Home, error) {
	var out Home
	sum, err := s.Summary(ctx, user)
	if err != nil {
		return out, err
	}
	out.Unread.Interaction, out.Unread.Chat = sum[inbox.Interaction], sum["chat"]
	out.Rallies = []Rally{}
	cid, err := crew.Of(ctx, s.Pool, user)
	if err != nil {
		return out, err
	}
	if cid != nil {
		c := HomeCrew{ID: *cid}
		err := s.Pool.QueryRow(ctx, `WITH mem AS (
				SELECT m.user_id, COALESCE(sum(a.claimed_area_m2),0) AS ar, COALESCE(sum(a.distance_m),0) AS d
				FROM src.src_soc_loop_crew_member m
				LEFT JOIN src.src_act_loop_activity a ON a.user_id=m.user_id AND a.status='settled' AND a.start_time >= $2
				WHERE m.crew_id=$1 GROUP BY m.user_id)
			SELECT c.name, c.avatar_url, (SELECT count(*) FROM mem), (SELECT COALESCE(sum(ar),0) FROM mem),
				(SELECT rk FROM (SELECT user_id, row_number() OVER (ORDER BY ar DESC, d DESC, user_id) AS rk FROM mem) x WHERE x.user_id=$3)
			FROM src.src_soc_loop_crew c WHERE c.id=$1`, *cid, weekStart(), user).
			Scan(&c.Name, &c.AvatarURL, &c.MemberCount, &c.WeekAreaM2, &c.MyRank)
		if err != nil && !db.IsNoRows(err) {
			return out, err
		}
		if err == nil {
			out.Crew = &c
			if out.Rallies, err = s.queryRallies(ctx, s.Pool, user, `r.crew_id=$2 AND (`+rallyStatusSQL+`)='open' ORDER BY r.start_time, r.id LIMIT 3`, *cid); err != nil {
				return out, err
			}
		}
	}
	if out.Meetups, err = s.queryMeetups(ctx, s.Pool, `NULL::float8`, `EXISTS (SELECT 1 FROM src.src_soc_loop_meetup_join j WHERE j.meetup_id=m.id AND j.user_id=$1)
		AND (`+meetupStatusSQL+`) IN ('open','full') ORDER BY m.start_time, m.id LIMIT 3`, user); err != nil {
		return out, err
	}
	if out.Races, err = queryRaces(ctx, s.Pool, `r.is_published AND (`+raceStatusSQL+`) IN ('signup','running')
		ORDER BY (`+raceStatusSQL+`)='running' DESC, r.start_time, r.id LIMIT 3`, user); err != nil {
		return out, err
	}
	hidePublished(out.Races)
	return out, nil
}

func (h *Handler) home(w http.ResponseWriter, r *http.Request) error {
	v, err := h.Svc.Home(r.Context(), uid(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, v)
}
