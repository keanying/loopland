package admin

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/keanying/loopland/server/internal/activity"
	"github.com/keanying/loopland/server/internal/anticheat"
	"github.com/keanying/loopland/server/internal/auth"
	"github.com/keanying/loopland/server/internal/billing"
	"github.com/keanying/loopland/server/internal/codex"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/platform/secure"
	"github.com/keanying/loopland/server/internal/territory"
	"github.com/keanying/loopland/server/internal/user"
)

// API wires the admin endpoints.
type API struct {
	Pool       *pgxpool.Pool
	Redis      *redis.Client
	Secret     []byte
	Box        *secure.Box
	Config     *gameplay.Store
	Billing    *billing.Service
	Territory  *territory.Service
	Activities *activity.Service
}

// Routes registers /admin/v1.
func (a *API) Routes(mux *http.ServeMux) {
	any := a.guard()
	adminOnly := a.guard(RoleAdmin)
	ops := a.guard(RoleAdmin, RoleOps)
	risk := a.guard(RoleAdmin, RoleOps, RoleReviewer)

	mux.Handle("POST /admin/v1/login", httpx.Wrap(a.login))
	mux.Handle("GET /admin/v1/me", any(a.me))
	mux.Handle("GET /admin/v1/dashboard", any(a.dashboard))

	mux.Handle("GET /admin/v1/users/stats", ops(a.userStats))
	mux.Handle("GET /admin/v1/users", risk(a.users))
	mux.Handle("GET /admin/v1/users/{id}", risk(a.userDetail))
	mux.Handle("POST /admin/v1/users/{id}/reveal-phone", ops(a.revealPhone))
	mux.Handle("POST /admin/v1/users/{id}/actions", risk(a.userAction))

	mux.Handle("GET /admin/v1/entitlements", ops(a.entitlements))
	mux.Handle("GET /admin/v1/plans", ops(a.plans))
	mux.Handle("PUT /admin/v1/plans/{code}", ops(a.updatePlan))
	mux.Handle("PUT /admin/v1/plans/{code}/entitlements", ops(a.updateEntitlements))
	mux.Handle("GET /admin/v1/orders", ops(a.orders))
	mux.Handle("GET /admin/v1/orders/stats", ops(a.orderStats))
	mux.Handle("POST /admin/v1/orders/{no}/refund", adminOnly(a.refund))
	mux.Handle("POST /admin/v1/orders/{no}/remind", ops(a.remind))

	mux.Handle("GET /admin/v1/territories", ops(a.territories))
	mux.Handle("GET /admin/v1/territories/geo", ops(a.territoryGeo))
	mux.Handle("GET /admin/v1/territories/{id}", ops(a.territoryDetail))
	mux.Handle("POST /admin/v1/territories/{id}/guard", ops(a.territoryGuard))
	mux.Handle("POST /admin/v1/territories/{id}/freeze", ops(a.territoryFreeze))
	mux.Handle("POST /admin/v1/territories/{id}/reset", ops(a.territoryReset))

	mux.Handle("GET /admin/v1/risk/alerts", risk(a.alerts))
	mux.Handle("GET /admin/v1/risk/alerts/{id}", risk(a.alertDetail))
	mux.Handle("POST /admin/v1/risk/alerts/{id}/resolve", risk(a.resolveAlert))
	mux.Handle("GET /admin/v1/risk/rules", risk(a.rules))
	mux.Handle("PUT /admin/v1/risk/rules", ops(a.updateRules))

	mux.Handle("GET /admin/v1/gameplay", ops(a.gameplay))
	mux.Handle("POST /admin/v1/gameplay/publish", adminOnly(a.publish))
	mux.Handle("POST /admin/v1/gameplay/rollout", adminOnly(a.rollout))
	mux.Handle("POST /admin/v1/gameplay/rollback", adminOnly(a.rollback))

	mux.Handle("GET /admin/v1/audit", ops(a.auditLog))
	mux.Handle("GET /admin/v1/admins", adminOnly(a.listAdmins))
	mux.Handle("POST /admin/v1/admins", adminOnly(a.createAdmin))
	mux.Handle("PATCH /admin/v1/admins/{id}", adminOnly(a.patchAdmin))
}

// ---------------------------------------------------------------- dashboard

type dayStats struct {
	ActiveUsers    int `json:"active_users"`
	Activities     int `json:"activities"`
	NewTerritories int `json:"new_territories"`
	PendingRisk    int `json:"pending_risk"`
}

func (a *API) day(ctx context.Context, d time.Time) (dayStats, error) {
	var s dayStats
	end := d.AddDate(0, 0, 1)
	err := a.Pool.QueryRow(ctx, `SELECT
		(SELECT count(DISTINCT user_id) FROM src.src_act_loop_activity WHERE create_time >= $1 AND create_time < $2),
		(SELECT count(*) FROM src.src_act_loop_activity WHERE create_time >= $1 AND create_time < $2),
		(SELECT count(*) FROM src.src_ter_loop_event WHERE event_type IN ('claim','capture') AND create_time >= $1 AND create_time < $2),
		(SELECT count(*) FROM src.src_ris_loop_alert WHERE status='open' AND create_time < $2)`, d, end).
		Scan(&s.ActiveUsers, &s.Activities, &s.NewTerritories, &s.PendingRisk)
	return s, err
}

func (a *API) dashboard(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	today := clock.Today()
	t, err := a.day(ctx, today)
	if err != nil {
		return err
	}
	lw, err := a.day(ctx, today.AddDate(0, 0, -7))
	if err != nil {
		return err
	}
	start := today.AddDate(0, 0, -29)
	rows, err := a.Pool.Query(ctx, `
		SELECT d::date,
		  (SELECT count(DISTINCT user_id) FROM src.src_act_loop_activity WHERE create_time >= d AND create_time < d + interval '1 day'),
		  (SELECT COALESCE(sum(distance_m),0)/1000 FROM src.src_act_loop_activity WHERE status='settled' AND create_time >= d AND create_time < d + interval '1 day'),
		  (SELECT count(*) FROM src.src_ter_loop_event WHERE event_type IN ('claim','capture') AND create_time >= d AND create_time < d + interval '1 day')
		FROM generate_series($1::timestamptz, $2::timestamptz, interval '1 day') d ORDER BY d`, start, today)
	if err != nil {
		return err
	}
	trend := struct {
		Days           []string  `json:"days"`
		ActiveUsers    []int     `json:"active_users"`
		DistanceKm     []float64 `json:"distance_km"`
		NewTerritories []int     `json:"new_territories"`
	}{[]string{}, []int{}, []float64{}, []int{}}
	for rows.Next() {
		var d time.Time
		var au, nt int
		var km float64
		if err := rows.Scan(&d, &au, &km, &nt); err != nil {
			rows.Close()
			return err
		}
		trend.Days = append(trend.Days, d.Format("2006-01-02"))
		trend.ActiveUsers = append(trend.ActiveUsers, au)
		trend.DistanceKm = append(trend.DistanceKm, float64(int(km*10))/10)
		trend.NewTerritories = append(trend.NewTerritories, nt)
	}
	rows.Close()
	type todo struct {
		Type     string `json:"type"`
		Title    string `json:"title"`
		Count    int    `json:"count"`
		Priority int    `json:"priority"`
		Link     string `json:"link"`
	}
	var risk, refunds, renewFailed int
	if err := a.Pool.QueryRow(ctx, `SELECT
		(SELECT count(*) FROM src.src_ris_loop_alert WHERE status='open'),
		(SELECT count(*) FROM src.src_ord_loop_order WHERE status='refund_requested'),
		(SELECT count(*) FROM src.src_ord_loop_order WHERE status='renew_failed' AND create_time > now() - interval '3 days')`).Scan(&risk, &refunds, &renewFailed); err != nil {
		return err
	}
	// 内容审核 (M-01): pending reviews now and a week ago.
	var pendingReviews, pendingLastWeek int
	if err := a.Pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE review_status='pending'),
			count(*) FILTER (WHERE create_time < now() - interval '7 days' AND (review_status='pending' OR review_time >= now() - interval '7 days'))
		FROM src.src_cnt_loop_review_task`).Scan(&pendingReviews, &pendingLastWeek); err != nil {
		return err
	}
	var pendingWoW *float64
	if pendingLastWeek > 0 {
		v := math.Round(float64(pendingReviews-pendingLastWeek)/float64(pendingLastWeek)*1000) / 1000
		pendingWoW = &v
	}
	todos := []todo{}
	if pendingReviews > 0 {
		todos = append(todos, todo{"review", fmt.Sprintf("%d 条内容待审核", pendingReviews), pendingReviews, 1, "/review"})
	}
	if risk > 0 {
		todos = append(todos, todo{"risk", fmt.Sprintf("%d 条风控告警待处理", risk), risk, 1, "/risk"})
	}
	if refunds > 0 {
		todos = append(todos, todo{"refund", fmt.Sprintf("%d 个退款申请待处理", refunds), refunds, 2, "/plans?tab=orders&status=refund_requested"})
	}
	if renewFailed > 0 {
		todos = append(todos, todo{"renew_failed", fmt.Sprintf("%d 个续费失败订单可提醒", renewFailed), renewFailed, 3, "/plans?tab=orders&status=renew_failed"})
	}
	// 本地生活 (M-04): weekly merchant statements waiting for confirmation.
	var pendingStatements int
	if err := a.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_fin_loop_statement WHERE statement_status='draft'`).Scan(&pendingStatements); err != nil {
		return err
	}
	if pendingStatements > 0 {
		todos = append(todos, todo{"statement_confirm", fmt.Sprintf("%d 张结算单待确认", pendingStatements), pendingStatements, 2, "/merchant/settlement"})
	}
	// 本地生活 (M-04): merchants waiting for qualification review, and
	// booking / race-fee refunds the channel hasn't confirmed within 1 hour.
	var reviewing, stuckRefunds int
	if err := a.Pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM src.src_mer_loop_merchant WHERE merchant_status='reviewing'),
		(SELECT count(*) FROM src.src_ord_loop_booking WHERE booking_status='refunding' AND update_time < now() - interval '1 hour')`).
		Scan(&reviewing, &stuckRefunds); err != nil {
		return err
	}
	if reviewing > 0 {
		todos = append(todos, todo{"merchant_review", fmt.Sprintf("%d 家商户待审核资质", reviewing), reviewing, 3, "/merchant/merchants?status=reviewing"})
	}
	if stuckRefunds > 0 {
		todos = append(todos, todo{"booking_refund", fmt.Sprintf("%d 笔订场退款超过 1 小时未到账", stuckRefunds), stuckRefunds, 1, "/merchant/bookings?status=refunding"})
	}
	return httpx.OK(w, map[string]any{"today": t, "last_week": lw, "trend": trend, "todos": todos,
		"pending_reviews": pendingReviews, "pending_reviews_wow": pendingWoW})
}

// ---------------------------------------------------------------- users

func (a *API) userStats(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	today := clock.Today()
	var total, todayNew, members int
	var cohort, retained int
	err := a.Pool.QueryRow(ctx, `SELECT
		(SELECT count(*) FROM src.src_usr_loop_user WHERE status <> 'deleted'),
		(SELECT count(*) FROM src.src_usr_loop_user WHERE create_time >= $1),
		(SELECT count(*) FROM src.src_ord_loop_membership WHERE expire_time > now() OR grace_end_time > now()),
		(SELECT count(*) FROM src.src_usr_loop_user WHERE create_time >= $2 AND create_time < $3),
		(SELECT count(*) FROM src.src_usr_loop_user u WHERE u.create_time >= $2 AND u.create_time < $3
		   AND EXISTS (SELECT 1 FROM src.src_act_loop_activity a WHERE a.user_id=u.id AND a.create_time >= u.create_time + interval '1 day'
		                AND a.create_time < u.create_time + interval '8 days'))`,
		today, today.AddDate(0, 0, -14), today.AddDate(0, 0, -7)).Scan(&total, &todayNew, &members, &cohort, &retained)
	if err != nil {
		return err
	}
	ret := 0.0
	if cohort > 0 {
		ret = float64(retained) / float64(cohort)
	}
	rows, err := a.Pool.Query(ctx, `SELECT source, count(*) FROM src.src_usr_loop_user WHERE create_time >= now() - interval '30 days' GROUP BY source ORDER BY 2 DESC`)
	if err != nil {
		return err
	}
	type src struct {
		Provider string `json:"provider"`
		Count    int    `json:"count"`
	}
	sources, err := pgx.CollectRows(rows, pgx.RowToStructByPos[src])
	if err != nil {
		return err
	}
	if sources == nil {
		sources = []src{}
	}
	return httpx.OK(w, map[string]any{"total": total, "today_new": todayNew, "retention_7d": ret, "members": members, "sources": sources})
}

type userRow struct {
	ID          int64      `json:"id"`
	Nickname    string     `json:"nickname"`
	PhoneMasked *string    `json:"phone_masked"`
	Source      string     `json:"source"`
	CreatedAt   time.Time  `json:"created_at"`
	Member      bool       `json:"member"`
	Status      string     `json:"status"`
	DeleteAfter *time.Time `json:"delete_after"`
}

func (a *API) maskPhone(enc []byte) *string {
	if enc == nil {
		return nil
	}
	p, err := a.Box.Open(enc)
	if err != nil {
		return nil
	}
	m := secure.MaskPhone(p)
	return &m
}

func (a *API) users(w http.ResponseWriter, r *http.Request) error {
	p := httpx.GetPage(r)
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	filter := r.URL.Query().Get("filter")
	where := `u.status <> 'deleted'`
	args := []any{}
	if q != "" {
		args = append(args, q)
		where += ` AND (u.nickname ILIKE '%' || $1 || '%' OR u.id::text = $1 OR u.phone_last4 = $1)`
	}
	switch filter {
	case "member":
		where += ` AND EXISTS (SELECT 1 FROM src.src_ord_loop_membership m WHERE m.user_id=u.id AND (m.expire_time > now() OR m.grace_end_time > now()))`
	case "today":
		args = append(args, clock.Today())
		where += fmt.Sprintf(` AND u.create_time >= $%d`, len(args))
	case "abnormal":
		where += ` AND (u.status='banned' OR u.mute_end_time > now() OR EXISTS (SELECT 1 FROM src.src_ris_loop_alert ra WHERE ra.user_id=u.id AND ra.status='open'))`
	}
	var total int
	if err := a.Pool.QueryRow(r.Context(), `SELECT count(*) FROM src.src_usr_loop_user u WHERE `+where, args...).Scan(&total); err != nil {
		return err
	}
	args = append(args, p.Size, p.Offset())
	rows, err := a.Pool.Query(r.Context(), fmt.Sprintf(`SELECT u.id, u.nickname, u.phone_enc, u.source, u.create_time,
			EXISTS (SELECT 1 FROM src.src_ord_loop_membership m WHERE m.user_id=u.id AND (m.expire_time > now() OR m.grace_end_time > now())),
			CASE WHEN u.status='active' AND u.mute_end_time > now() THEN 'muted' ELSE u.status END, u.delete_time
		FROM src.src_usr_loop_user u WHERE %s ORDER BY u.id DESC LIMIT $%d OFFSET $%d`, where, len(args)-1, len(args)), args...)
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (userRow, error) {
		var u userRow
		var enc []byte
		err := row.Scan(&u.ID, &u.Nickname, &enc, &u.Source, &u.CreatedAt, &u.Member, &u.Status, &u.DeleteAfter)
		u.PhoneMasked = a.maskPhone(enc)
		return u, err
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

type alertRow struct {
	ID         int64  `json:"id"`
	ActivityID *int64 `json:"activity_id"`
	User       struct {
		ID       int64  `json:"id"`
		Nickname string `json:"nickname"`
	} `json:"user"`
	Type       string    `json:"type"`
	Confidence float64   `json:"confidence"`
	Detail     string    `json:"detail"`
	Status     string    `json:"status"`
	Resolution *string   `json:"resolution"`
	Note       *string   `json:"note"`
	CreatedAt  time.Time `json:"created_at"`
}

const alertCols = `ra.id, ra.activity_id, u.id, u.nickname, ra.alert_type, ra.confidence, ra.detail, ra.status, ra.resolution, ra.note, ra.create_time`

func scanAlert(row pgx.Row) (alertRow, error) {
	var x alertRow
	var c float32
	err := row.Scan(&x.ID, &x.ActivityID, &x.User.ID, &x.User.Nickname, &x.Type, &c, &x.Detail, &x.Status, &x.Resolution, &x.Note, &x.CreatedAt)
	x.Confidence = float64(int(c*100+0.5)) / 100
	return x, err
}

type userDetail struct {
	user.User
	Source      string     `json:"source"`
	LastLoginAt *time.Time `json:"last_login_at"`
	CodexCount  int        `json:"codex_count"`
	RiskAlerts  []alertRow `json:"risk_alerts"`
}

func (a *API) userDetail(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	u, err := user.Load(r.Context(), a.Pool, a.Config, a.Box, id)
	if err != nil {
		return err
	}
	var source string
	var lastLogin *time.Time
	if err := a.Pool.QueryRow(r.Context(), `SELECT source, last_login_time FROM src.src_usr_loop_user WHERE id=$1`, id).Scan(&source, &lastLogin); err != nil {
		return err
	}
	n, err := codex.Count(r.Context(), a.Pool, id)
	if err != nil {
		return err
	}
	rows, err := a.Pool.Query(r.Context(), `SELECT `+alertCols+` FROM src.src_ris_loop_alert ra JOIN src.src_usr_loop_user u ON u.id=ra.user_id WHERE ra.user_id=$1 ORDER BY ra.id DESC LIMIT 50`, id)
	if err != nil {
		return err
	}
	alerts, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (alertRow, error) { return scanAlert(row) })
	if err != nil {
		return err
	}
	if alerts == nil {
		alerts = []alertRow{}
	}
	return httpx.OK(w, userDetail{User: u, Source: source, LastLoginAt: lastLogin, CodexCount: n, RiskAlerts: alerts})
}

func (a *API) revealPhone(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var enc []byte
	if err := a.Pool.QueryRow(r.Context(), `SELECT phone_enc FROM src.src_usr_loop_user WHERE id=$1`, id).Scan(&enc); err != nil {
		if db.IsNoRows(err) {
			return httpx.NotFound("用户")
		}
		return err
	}
	if enc == nil {
		return httpx.NotFound("手机号")
	}
	phone, err := a.Box.Open(enc)
	if err != nil {
		return err
	}
	if err := audit(r.Context(), a.Pool, "user.reveal_phone", "user:"+strconv.FormatInt(id, 10), nil); err != nil {
		return err
	}
	return httpx.OK(w, map[string]string{"phone": phone})
}

func (a *API) userAction(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Action  string `json:"action"`
		Message string `json:"message"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	ad, _ := httpx.AdminFrom(ctx)
	err = pgx.BeginFunc(ctx, a.Pool, func(tx pgx.Tx) error {
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_usr_loop_user WHERE id=$1 AND status <> 'deleted')`, id).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return httpx.NotFound("用户")
		}
		switch req.Action {
		case "gift_member_7d":
			if ad.Role != RoleAdmin && ad.Role != RoleOps {
				return httpx.ErrForbidden
			}
			if err := a.Billing.GiftDays(ctx, tx, id, 7); err != nil {
				return err
			}
			if err := inbox.Notify(ctx, tx, id, inbox.System, "获得 7 天会员", "运营赠送了你 7 天会员，快去试试手绘地图吧。", nil); err != nil {
				return err
			}
		case "notify":
			if strings.TrimSpace(req.Message) == "" {
				return httpx.BadRequest("invalid_body", "请填写通知内容")
			}
			if err := inbox.Notify(ctx, tx, id, inbox.System, "系统通知", req.Message, nil); err != nil {
				return err
			}
		case "mute_7d":
			if _, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET mute_end_time=now() + interval '7 days' WHERE id=$1`, id); err != nil {
				return err
			}
			if err := inbox.Notify(ctx, tx, id, inbox.System, "你已被禁言 7 天", "因违反社区规范，你在 7 天内不能修改资料和发布内容。", nil); err != nil {
				return err
			}
		case "unmute":
			if _, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET mute_end_time=NULL WHERE id=$1`, id); err != nil {
				return err
			}
		case "ban", "unban":
			if err := a.setBan(ctx, tx, id, req.Action == "ban", nil); err != nil {
				return err
			}
		default:
			return httpx.BadRequest("invalid_body", "未知操作")
		}
		return audit(ctx, tx, "user."+req.Action, "user:"+strconv.FormatInt(id, 10), map[string]any{"message": req.Message})
	})
	if err != nil {
		return err
	}
	return a.userDetail(w, r)
}

// setBan bans (freezing the user's land) or unbans (unfreezing it).
func (a *API) setBan(ctx context.Context, tx pgx.Tx, id int64, ban bool, until *time.Time) error {
	ad, _ := httpx.AdminFrom(ctx)
	if ban {
		if _, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET status='banned', ban_end_time=$2 WHERE id=$1 AND status <> 'deleted'`, id, until); err != nil {
			return err
		}
		if err := auth.RevokeAll(ctx, tx, id); err != nil {
			return err
		}
	} else if _, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET status='active', ban_end_time=NULL WHERE id=$1 AND status='banned'`, id); err != nil {
		return err
	}
	rows, err := tx.Query(ctx, `SELECT id FROM src.src_ter_loop_territory WHERE owner_user_id=$1 AND is_frozen<>$2`, id, ban)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	for _, t := range ids {
		if err := a.Territory.SetFrozen(ctx, tx, t, ban, &ad.ID); err != nil {
			return err
		}
	}
	return nil
}

// ---------------------------------------------------------------- billing

func (a *API) entitlements(w http.ResponseWriter, _ *http.Request) error {
	type ent struct {
		Key    string `json:"key"`
		Name   string `json:"name"`
		Locked bool   `json:"locked"`
	}
	out := []ent{}
	for _, e := range billing.Entitlements {
		out = append(out, ent{e.Key, e.Name, e.Locked})
	}
	return httpx.OK(w, httpx.NewItems(out))
}

func (a *API) plans(w http.ResponseWriter, r *http.Request) error {
	ps, err := a.Billing.Plans(r.Context(), false)
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(ps))
}

func (a *API) updatePlan(w http.ResponseWriter, r *http.Request) error {
	code := r.PathValue("code")
	var req struct {
		Name          *string `json:"name"`
		PriceFen      *int    `json:"price_fen"`
		FirstPriceFen *int    `json:"first_price_fen"`
		RenewPriceFen *int    `json:"renew_price_fen"`
		OnSale        *bool   `json:"on_sale"`
		Recommended   *bool   `json:"recommended"`
		Sort          *int    `json:"sort"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	for _, p := range []*int{req.PriceFen, req.RenewPriceFen} {
		if p != nil && (*p <= 0 || *p > 1_000_000) {
			return httpx.BadRequest("invalid_price", "价格必须在 ¥0.01–¥10000 之间")
		}
	}
	if req.FirstPriceFen != nil && *req.FirstPriceFen < 0 {
		return httpx.BadRequest("invalid_price", "首期价不能为负")
	}
	ctx := r.Context()
	err := pgx.BeginFunc(ctx, a.Pool, func(tx pgx.Tx) error {
		before, err := a.Billing.Plan(ctx, tx, code)
		if err != nil {
			return err
		}
		if req.Recommended != nil && *req.Recommended {
			if _, err := tx.Exec(ctx, `UPDATE src.src_ord_loop_plan SET is_recommended=false`); err != nil {
				return err
			}
		}
		// first_price_fen: 0 clears the introductory price.
		if _, err := tx.Exec(ctx, `UPDATE src.src_ord_loop_plan SET name=COALESCE($2,name), price_amt=COALESCE($3,price_amt),
				first_price_amt=CASE WHEN $4::int IS NULL THEN first_price_amt WHEN $4 = 0 THEN NULL ELSE $4 END,
				renew_price_amt=COALESCE($5,renew_price_amt), is_on_sale=COALESCE($6,is_on_sale), is_recommended=COALESCE($7,is_recommended), sort=COALESCE($8,sort)
			WHERE code=$1`, code, req.Name, req.PriceFen, req.FirstPriceFen, req.RenewPriceFen, req.OnSale, req.Recommended, req.Sort); err != nil {
			return err
		}
		return audit(ctx, tx, "plan.update", "plan:"+code, map[string]any{"before": before, "change": req})
	})
	if err != nil {
		return err
	}
	p, err := a.Billing.Plan(ctx, a.Pool, code)
	if err != nil {
		return err
	}
	return httpx.OK(w, p)
}

func (a *API) updateEntitlements(w http.ResponseWriter, r *http.Request) error {
	code := r.PathValue("code")
	var req struct {
		Entitlements []string `json:"entitlements"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	known := map[string]bool{}
	for _, e := range billing.Entitlements {
		known[e.Key] = !e.Locked
	}
	for _, e := range req.Entitlements {
		allowed, ok := known[e]
		if !ok {
			return httpx.BadRequest("invalid_body", "未知权益 "+e)
		}
		if !allowed {
			return httpx.BadRequest("entitlement_locked", "抢地守卫加成和额外能量不能放进任何套餐")
		}
	}
	if req.Entitlements == nil {
		req.Entitlements = []string{}
	}
	ctx := r.Context()
	err := pgx.BeginFunc(ctx, a.Pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE src.src_ord_loop_plan SET entitlements=$2 WHERE code=$1`, code, req.Entitlements)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return httpx.NotFound("套餐")
		}
		return audit(ctx, tx, "plan.entitlements", "plan:"+code, map[string]any{"entitlements": req.Entitlements})
	})
	if err != nil {
		return err
	}
	p, err := a.Billing.Plan(ctx, a.Pool, code)
	if err != nil {
		return err
	}
	return httpx.OK(w, p)
}

func (a *API) orders(w http.ResponseWriter, r *http.Request) error {
	p := httpx.GetPage(r)
	status := r.URL.Query().Get("status")
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	where := `($1='' OR o.status=$1) AND ($2='' OR o.order_no=$2 OR u.nickname ILIKE '%' || $2 || '%' OR o.user_id::text=$2)`
	var total int
	if err := a.Pool.QueryRow(r.Context(), `SELECT count(*) FROM src.src_ord_loop_order o JOIN src.src_usr_loop_user u ON u.id=o.user_id WHERE `+where, status, q).Scan(&total); err != nil {
		return err
	}
	rows, err := a.Pool.Query(r.Context(), `SELECT o.order_no, o.user_id, u.nickname, COALESCE(o.plan_code, ''), o.plan_name, o.order_amt, o.channel, o.order_type, o.status,
			o.create_time, o.pay_time, o.refund_time
		FROM src.src_ord_loop_order o JOIN src.src_usr_loop_user u ON u.id=o.user_id WHERE `+where+` ORDER BY o.create_time DESC LIMIT $3 OFFSET $4`, status, q, p.Size, p.Offset())
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (billing.Order, error) {
		var o billing.Order
		var nick string
		err := row.Scan(&o.OrderNo, &o.UserID, &nick, &o.PlanCode, &o.PlanName, &o.AmountFen, &o.Channel, &o.Kind, &o.Status, &o.CreatedAt, &o.PaidAt, &o.RefundedAt)
		o.User = &billing.UserRef{ID: o.UserID, Nickname: nick}
		return o, err
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (a *API) orderStats(w http.ResponseWriter, r *http.Request) error {
	today := clock.Today()
	month := time.Date(today.Year(), today.Month(), 1, 0, 0, 0, 0, clock.Shanghai)
	var revenue, members, renewOK, renewAll, paidToday, refundToday int
	err := a.Pool.QueryRow(r.Context(), `SELECT
		(SELECT COALESCE(sum(order_amt),0) FROM src.src_ord_loop_order WHERE status='paid' AND pay_time >= $1),
		(SELECT count(*) FROM src.src_ord_loop_membership WHERE expire_time > now() OR grace_end_time > now()),
		(SELECT count(*) FROM src.src_ord_loop_order WHERE order_type='renewal' AND status='paid' AND create_time >= $1),
		(SELECT count(*) FROM src.src_ord_loop_order WHERE order_type='renewal' AND status IN ('paid','renew_failed') AND create_time >= $1),
		(SELECT count(*) FROM src.src_ord_loop_order WHERE pay_time >= $2),
		(SELECT count(*) FROM src.src_ord_loop_order WHERE refund_time >= $2)`, month, today).Scan(&revenue, &members, &renewOK, &renewAll, &paidToday, &refundToday)
	if err != nil {
		return err
	}
	rate, refund := 1.0, 0.0
	if renewAll > 0 {
		rate = float64(renewOK) / float64(renewAll)
	}
	if paidToday > 0 {
		refund = float64(refundToday) / float64(paidToday)
	}
	return httpx.OK(w, map[string]any{"month_revenue_fen": revenue, "active_members": members, "renew_success_rate": rate, "refund_rate_today": refund})
}

func (a *API) refund(w http.ResponseWriter, r *http.Request) error {
	no := r.PathValue("no")
	var req struct {
		Reason  string `json:"reason"`
		Confirm bool   `json:"confirm"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if !req.Confirm {
		return httpx.BadRequest("confirm_required", "退款需要二次确认")
	}
	if strings.TrimSpace(req.Reason) == "" {
		return httpx.BadRequest("invalid_body", "请填写退款原因")
	}
	o, err := a.Billing.Refund(r.Context(), no, req.Reason)
	if err != nil {
		return err
	}
	if err := audit(r.Context(), a.Pool, "order.refund", "order:"+no, map[string]any{"reason": req.Reason, "amount_fen": o.AmountFen}); err != nil {
		return err
	}
	return httpx.OK(w, o)
}

func (a *API) remind(w http.ResponseWriter, r *http.Request) error {
	no := r.PathValue("no")
	o, err := a.Billing.GetOrder(r.Context(), a.Pool, no, 0)
	if err != nil {
		return err
	}
	if o.Status != "renew_failed" {
		return httpx.Conflict("invalid_status", "只有续费失败的订单可以提醒")
	}
	err = pgx.BeginFunc(r.Context(), a.Pool, func(tx pgx.Tx) error {
		if err := inbox.Notify(r.Context(), tx, o.UserID, inbox.System, "会员续费提醒",
			"你的会员自动续费没有成功，权益保留 3 天，请在「我的 > 会员」重新开通。", map[string]any{"order_no": no}); err != nil {
			return err
		}
		return audit(r.Context(), tx, "order.remind", "order:"+no, nil)
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

// ---------------------------------------------------------------- territory

func (a *API) territories(w http.ResponseWriter, r *http.Request) error {
	items, total, err := a.Territory.AdminList(r.Context(), r.URL.Query().Get("status"), strings.TrimSpace(r.URL.Query().Get("q")), httpx.GetPage(r))
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (a *API) territoryGeo(w http.ResponseWriter, r *http.Request) error {
	b, err := territory.ParseBBox(r.URL.Query().Get("bbox"))
	if err != nil {
		return err
	}
	items, err := a.Territory.Viewport(r.Context(), b, "all", 0, nil)
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewItems(items))
}

func (a *API) territoryDetail(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	d, err := a.Territory.Get(r.Context(), a.Pool, id, 0, nil, true)
	if err != nil {
		return err
	}
	return httpx.OK(w, d)
}

func (a *API) territoryGuard(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Guard int `json:"guard"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	ad, _ := httpx.AdminFrom(r.Context())
	if err := a.Territory.SetGuard(r.Context(), id, req.Guard, ad.ID); err != nil {
		return err
	}
	if err := audit(r.Context(), a.Pool, "territory.guard", "territory:"+strconv.FormatInt(id, 10), map[string]any{"guard": req.Guard}); err != nil {
		return err
	}
	return a.territoryDetail(w, r)
}

func (a *API) territoryFreeze(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Frozen bool `json:"frozen"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	ad, _ := httpx.AdminFrom(r.Context())
	err = pgx.BeginFunc(r.Context(), a.Pool, func(tx pgx.Tx) error {
		if err := a.Territory.SetFrozen(r.Context(), tx, id, req.Frozen, &ad.ID); err != nil {
			return err
		}
		return audit(r.Context(), tx, "territory.freeze", "territory:"+strconv.FormatInt(id, 10), map[string]any{"frozen": req.Frozen})
	})
	if err != nil {
		return err
	}
	return a.territoryDetail(w, r)
}

func (a *API) territoryReset(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	ad, _ := httpx.AdminFrom(r.Context())
	if err := a.Territory.Reset(r.Context(), id, ad.ID); err != nil {
		return err
	}
	if err := audit(r.Context(), a.Pool, "territory.reset", "territory:"+strconv.FormatInt(id, 10), nil); err != nil {
		return err
	}
	return a.territoryDetail(w, r)
}

// ---------------------------------------------------------------- risk

func (a *API) alerts(w http.ResponseWriter, r *http.Request) error {
	p := httpx.GetPage(r)
	status, typ := r.URL.Query().Get("status"), r.URL.Query().Get("type")
	if status == "" {
		status = "open"
	}
	where := `ra.status=$1 AND ($2='' OR ra.alert_type=$2)`
	var total int
	if err := a.Pool.QueryRow(r.Context(), `SELECT count(*) FROM src.src_ris_loop_alert ra WHERE `+where, status, typ).Scan(&total); err != nil {
		return err
	}
	rows, err := a.Pool.Query(r.Context(), `SELECT `+alertCols+` FROM src.src_ris_loop_alert ra JOIN src.src_usr_loop_user u ON u.id=ra.user_id WHERE `+where+`
		ORDER BY ra.confidence DESC, ra.id DESC LIMIT $3 OFFSET $4`, status, typ, p.Size, p.Offset())
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (alertRow, error) { return scanAlert(row) })
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (a *API) loadAlert(ctx context.Context, q db.Querier, id int64) (alertRow, error) {
	x, err := scanAlert(q.QueryRow(ctx, `SELECT `+alertCols+` FROM src.src_ris_loop_alert ra JOIN src.src_usr_loop_user u ON u.id=ra.user_id WHERE ra.id=$1`, id))
	if db.IsNoRows(err) {
		return x, httpx.NotFound("告警")
	}
	return x, err
}

func (a *API) alertDetail(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	ctx := r.Context()
	al, err := a.loadAlert(ctx, a.Pool, id)
	if err != nil {
		return err
	}
	out := map[string]any{"alert": al}
	rules, err := anticheat.LoadRules(ctx, a.Pool)
	if err != nil {
		return err
	}
	if al.ActivityID != nil {
		v, err := activity.LoadView(ctx, a.Pool, 0, *al.ActivityID, true)
		if err != nil {
			return err
		}
		out["activity"] = v
		pts, err := activity.LoadPoints(ctx, a.Pool, *al.ActivityID)
		if err != nil {
			return err
		}
		sport := gameplay.Sport(v.Sport)
		out["speeds"] = anticheat.Speeds(rules, sport, pts)
		tp := anticheat.Teleports(rules, sport, pts)
		if tp == nil {
			tp = []anticheat.Jump{}
		}
		out["teleports"] = tp
		sources := map[string]int{"gps": 0, "network": 0, "mock": 0}
		var hrSum, hrN, cadSum, cadN int
		for _, p := range pts {
			sources[p.Src]++
			if p.HR != nil {
				hrSum, hrN = hrSum+*p.HR, hrN+1
			}
			if p.Cad != nil {
				cadSum, cadN = cadSum+*p.Cad, cadN+1
			}
		}
		out["sources"] = sources
		out["hr_avg"] = avgOrNil(hrSum, hrN)
		out["cadence_avg"] = avgOrNil(cadSum, cadN)
		var dev []byte
		if err := a.Pool.QueryRow(ctx, `SELECT device_json FROM src.src_act_loop_activity WHERE id=$1`, *al.ActivityID).Scan(&dev); err != nil {
			return err
		}
		var device anticheat.Device
		_ = json.Unmarshal(dev, &device)
		out["device"] = device
		same := 0
		if device.ID != "" {
			if err := a.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_usr_loop_device WHERE device_id=$1`, device.ID).Scan(&same); err != nil {
				return err
			}
		}
		out["same_device_accounts"] = same
	}
	rows, err := a.Pool.Query(ctx, `SELECT `+alertCols+` FROM src.src_ris_loop_alert ra JOIN src.src_usr_loop_user u ON u.id=ra.user_id WHERE ra.user_id=$1 AND ra.id<>$2 ORDER BY ra.id DESC LIMIT 20`, al.User.ID, id)
	if err != nil {
		return err
	}
	hist, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (alertRow, error) { return scanAlert(row) })
	if err != nil {
		return err
	}
	if hist == nil {
		hist = []alertRow{}
	}
	out["history"] = hist
	return httpx.OK(w, out)
}

func avgOrNil(sum, n int) *int {
	if n == 0 {
		return nil
	}
	v := sum / n
	return &v
}

func (a *API) resolveAlert(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Action string `json:"action"`
		Note   string `json:"note"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	ad, _ := httpx.AdminFrom(ctx)
	err = pgx.BeginFunc(ctx, a.Pool, func(tx pgx.Tx) error {
		var status string
		var actID *int64
		var uid int64
		err := tx.QueryRow(ctx, `SELECT status, activity_id, user_id FROM src.src_ris_loop_alert WHERE id=$1 FOR UPDATE`, id).Scan(&status, &actID, &uid)
		if db.IsNoRows(err) {
			return httpx.NotFound("告警")
		}
		if err != nil {
			return err
		}
		if status == "resolved" {
			return httpx.Conflict("already_resolved", "这条告警已经处理过了")
		}
		switch req.Action {
		case "void":
			if actID != nil {
				if err := a.Activities.Void(ctx, tx, *actID); err != nil {
					return err
				}
			}
		case "warn":
			if err := inbox.Notify(ctx, tx, uid, inbox.System, "运动数据异常警告",
				"系统检测到你的运动数据存在异常。请勿使用模拟定位、乘车等方式刷数据，再次发现将封禁账号。", nil); err != nil {
				return err
			}
		case "ban_30d":
			until := time.Now().Add(30 * 24 * time.Hour)
			if actID != nil {
				if err := a.Activities.Void(ctx, tx, *actID); err != nil {
					return err
				}
			}
			if err := a.setBan(ctx, tx, uid, true, &until); err != nil {
				return err
			}
		case "false_positive":
			if actID != nil {
				if err := a.Activities.SettleReviewed(ctx, tx, *actID); err != nil {
					return err
				}
			}
		default:
			return httpx.BadRequest("invalid_body", "未知处置方式")
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_ris_loop_alert SET status='resolved', resolution=$2, note=NULLIF($3,''), resolved_by=$4, resolve_time=now() WHERE id=$1`,
			id, req.Action, req.Note, ad.ID); err != nil {
			return err
		}
		// One decision settles every open alert of the same activity.
		if actID != nil {
			if _, err := tx.Exec(ctx, `UPDATE src.src_ris_loop_alert SET status='resolved', resolution=$2, note='同一运动记录已处理', resolved_by=$3, resolve_time=now()
				WHERE activity_id=$1 AND status='open'`, *actID, req.Action, ad.ID); err != nil {
				return err
			}
		}
		return audit(ctx, tx, "risk."+req.Action, "alert:"+strconv.FormatInt(id, 10), map[string]any{"note": req.Note, "activity_id": actID, "user_id": uid})
	})
	if err != nil {
		return err
	}
	al, err := a.loadAlert(ctx, a.Pool, id)
	if err != nil {
		return err
	}
	return httpx.OK(w, al)
}

func (a *API) rules(w http.ResponseWriter, r *http.Request) error {
	rules, err := anticheat.LoadRules(r.Context(), a.Pool)
	if err != nil {
		return err
	}
	return httpx.OK(w, rules)
}

func (a *API) updateRules(w http.ResponseWriter, r *http.Request) error {
	var rules anticheat.Rules
	if err := httpx.Decode(r, &rules); err != nil {
		return err
	}
	if err := rules.Validate(); err != nil {
		return httpx.BadRequest("invalid_rules", err.Error())
	}
	err := pgx.BeginFunc(r.Context(), a.Pool, func(tx pgx.Tx) error {
		if err := anticheat.SaveRules(r.Context(), tx, rules); err != nil {
			return err
		}
		return audit(r.Context(), tx, "risk.rules", "settings:risk_rules", map[string]any{"rules": rules})
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, rules)
}

// ---------------------------------------------------------------- gameplay

func (a *API) gameplay(w http.ResponseWriter, r *http.Request) error {
	cur, prev := a.Config.Current()
	hist, err := a.Config.History(r.Context())
	if err != nil {
		return err
	}
	type histRow struct {
		Version     string    `json:"version"`
		Note        string    `json:"note"`
		RolloutPct  int       `json:"rollout_pct"`
		PublishedBy *int64    `json:"published_by"`
		PublishedAt time.Time `json:"published_at"`
	}
	h := []histRow{}
	for _, v := range hist {
		h = append(h, histRow{v.Version, v.Note, v.RolloutPct, v.PublishedBy, v.PublishedAt})
	}
	return httpx.OK(w, map[string]any{"current": cur, "previous": prev, "history": h})
}

func (a *API) publish(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Body       gameplay.Config `json:"body"`
		Note       string          `json:"note"`
		RolloutPct int             `json:"rollout_pct"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if req.RolloutPct == 0 {
		req.RolloutPct = 100
	}
	ad, _ := httpx.AdminFrom(r.Context())
	v, err := a.Config.Publish(r.Context(), req.Body, req.Note, req.RolloutPct, ad.ID)
	if err != nil {
		return httpx.BadRequest("invalid_config", err.Error())
	}
	if err := audit(r.Context(), a.Pool, "gameplay.publish", "gameplay:"+v.Version, map[string]any{"note": req.Note, "rollout_pct": req.RolloutPct}); err != nil {
		return err
	}
	return a.gameplay(w, r)
}

func (a *API) rollout(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		RolloutPct int `json:"rollout_pct"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if err := a.Config.Rollout(r.Context(), req.RolloutPct); err != nil {
		return httpx.BadRequest("invalid_body", err.Error())
	}
	cur, _ := a.Config.Current()
	if err := audit(r.Context(), a.Pool, "gameplay.rollout", "gameplay:"+cur.Version, map[string]any{"rollout_pct": req.RolloutPct}); err != nil {
		return err
	}
	return a.gameplay(w, r)
}

func (a *API) rollback(w http.ResponseWriter, r *http.Request) error {
	cur, _ := a.Config.Current()
	if err := a.Config.Rollback(r.Context()); err != nil {
		return httpx.Conflict("no_previous_version", err.Error())
	}
	if err := audit(r.Context(), a.Pool, "gameplay.rollback", "gameplay:"+cur.Version, nil); err != nil {
		return err
	}
	return a.gameplay(w, r)
}
