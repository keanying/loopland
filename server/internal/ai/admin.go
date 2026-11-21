package ai

import (
	"context"
	"math"
	"net/http"
	"slices"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// RetentionDays is how long assistant conversations are kept.
const RetentionDays = 180

// Jobs returns the periodic jobs: conversations older than 180 days are
// deleted, and moderation tasks whose AI scoring timed out are re-scored.
func (s *Service) Jobs() map[string]func(context.Context) error {
	jobs := map[string]func(context.Context) error{"ai_retention": s.PurgeOld}
	if s.Mod != nil {
		jobs["ai_moderation_rescore"] = s.Mod.Rescore
	}
	return jobs
}

// PurgeOld deletes conversations past the retention period.
func (s *Service) PurgeOld(ctx context.Context) error {
	_, err := s.Pool.Exec(ctx, `DELETE FROM src.src_msg_loop_ai_message WHERE create_time < now() - make_interval(days => $1)`, RetentionDays)
	return err
}

// AdminHandler serves the AI usage pages (管理端 · AI 用量).
type AdminHandler struct {
	Svc   *Service
	Audit func(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error
}

// Routes registers the endpoints: usage and calls for admin/ops, a user's
// conversation for admin only.
func (h *AdminHandler) Routes(mux *http.ServeMux, ops, adminOnly func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /admin/v1/ai/usage", ops(h.usage))
	mux.Handle("GET /admin/v1/ai/calls", ops(h.calls))
	mux.Handle("GET /admin/v1/users/{id}/ai-messages", adminOnly(h.userMessages))
}

// UsageDay is one day of calls.
type UsageDay struct {
	Date             string `json:"date"`
	Calls            int    `json:"calls"`
	Failed           int    `json:"failed"`
	PromptTokens     int64  `json:"prompt_tokens"`
	CompletionTokens int64  `json:"completion_tokens"`
	CostFen          *int64 `json:"cost_fen"`
}

// UsageFeature is one feature over the period.
type UsageFeature struct {
	Feature          string `json:"feature"`
	Calls            int    `json:"calls"`
	Failed           int    `json:"failed"`
	AvgLatencyMs     int    `json:"avg_latency_ms"`
	PromptTokens     int64  `json:"prompt_tokens"`
	CompletionTokens int64  `json:"completion_tokens"`
	CostFen          *int64 `json:"cost_fen"`
}

var featureOrder = []string{FeatureChat, FeatureRoute, FeatureReport, FeatureModeration, FeatureWorkout}

func (h *AdminHandler) usage(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	days := 7
	if v := r.URL.Query().Get("days"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 90 {
			return httpx.BadRequest("invalid_body", "days 应在 1–90 之间")
		}
		days = n
	}
	pin, pout := 0, 0
	weekly := 3
	if b, err := h.Svc.Backend(); err == nil {
		pin, pout, weekly = b.PriceIn, b.PriceOut, b.WeeklyFree
	}
	cost := func(in, out int64) *int64 {
		if pin == 0 && pout == 0 {
			return nil
		}
		c := int64(math.Round((float64(in)*float64(pin) + float64(out)*float64(pout)) / 1e6))
		return &c
	}
	from := clock.Today().AddDate(0, 0, -(days - 1))
	rows, err := h.Svc.Pool.Query(ctx, `SELECT to_char(d.day, 'YYYY-MM-DD'), count(c.id), count(c.id) FILTER (WHERE c.call_status='failed'),
			COALESCE(sum(c.prompt_token_qty), 0), COALESCE(sum(c.completion_token_qty), 0),
			COALESCE(sum(c.prompt_token_qty) FILTER (WHERE NOT c.is_mock), 0), COALESCE(sum(c.completion_token_qty) FILTER (WHERE NOT c.is_mock), 0)
		FROM generate_series($1::date, $2::date, interval '1 day') d(day)
		LEFT JOIN src.src_sys_loop_ai_call c ON (c.create_time AT TIME ZONE 'Asia/Shanghai')::date = d.day::date
		GROUP BY d.day ORDER BY d.day`, from.Format("2006-01-02"), clock.Today().Format("2006-01-02"))
	if err != nil {
		return err
	}
	dayList, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (UsageDay, error) {
		var d UsageDay
		var bin, bout int64
		err := row.Scan(&d.Date, &d.Calls, &d.Failed, &d.PromptTokens, &d.CompletionTokens, &bin, &bout)
		d.CostFen = cost(bin, bout)
		return d, err
	})
	if err != nil {
		return err
	}
	rows, err = h.Svc.Pool.Query(ctx, `SELECT feature_type, count(*), count(*) FILTER (WHERE call_status='failed'), COALESCE(avg(latency_ms), 0),
			COALESCE(sum(prompt_token_qty), 0), COALESCE(sum(completion_token_qty), 0),
			COALESCE(sum(prompt_token_qty) FILTER (WHERE NOT is_mock), 0), COALESCE(sum(completion_token_qty) FILTER (WHERE NOT is_mock), 0)
		FROM src.src_sys_loop_ai_call WHERE create_time >= $1 GROUP BY feature_type`, from)
	if err != nil {
		return err
	}
	byF := map[string]UsageFeature{}
	for rows.Next() {
		var f UsageFeature
		var avg float64
		var bin, bout int64
		if err := rows.Scan(&f.Feature, &f.Calls, &f.Failed, &avg, &f.PromptTokens, &f.CompletionTokens, &bin, &bout); err != nil {
			rows.Close()
			return err
		}
		f.AvgLatencyMs = int(math.Round(avg))
		f.CostFen = cost(bin, bout)
		byF[f.Feature] = f
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	features := make([]UsageFeature, 0, len(featureOrder))
	for _, k := range featureOrder {
		f, ok := byF[k]
		if !ok {
			f = UsageFeature{Feature: k, CostFen: cost(0, 0)}
		}
		features = append(features, f)
	}
	hit, err := h.Svc.UsersHitLimit(ctx, h.Svc.Pool, weekly)
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]any{"days": dayList, "by_feature": features, "quota": map[string]int{"users_hit_limit_this_week": hit}})
}

// CallItem is a row of GET /admin/v1/ai/calls.
type CallItem struct {
	ID               int64     `json:"id"`
	Feature          string    `json:"feature"`
	User             *Ref      `json:"user"`
	Model            string    `json:"model"`
	Status           string    `json:"status"`
	Error            *string   `json:"error"`
	PromptTokens     int       `json:"prompt_tokens"`
	CompletionTokens int       `json:"completion_tokens"`
	LatencyMs        int       `json:"latency_ms"`
	CreatedAt        time.Time `json:"created_at"`
}

func (h *AdminHandler) calls(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	q := r.URL.Query()
	feature, status := q.Get("feature"), q.Get("status")
	if feature != "" && !slices.Contains(featureOrder, feature) {
		return httpx.BadRequest("invalid_body", "feature 取值错误")
	}
	if status != "" && status != "ok" && status != "failed" {
		return httpx.BadRequest("invalid_body", "status 只能是 ok 或 failed")
	}
	p := httpx.GetPage(r)
	where := ` WHERE ($1='' OR c.feature_type=$1) AND ($2='' OR c.call_status=$2)`
	var total int
	if err := h.Svc.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_sys_loop_ai_call c`+where, feature, status).Scan(&total); err != nil {
		return err
	}
	rows, err := h.Svc.Pool.Query(ctx, `SELECT c.id, c.feature_type, u.id, u.nickname, c.model_name, c.call_status, c.error_text, c.prompt_token_qty,
			c.completion_token_qty, c.latency_ms, c.create_time
		FROM src.src_sys_loop_ai_call c LEFT JOIN src.src_usr_loop_user u ON u.id=c.user_id`+where+` ORDER BY c.id DESC LIMIT $3 OFFSET $4`,
		feature, status, p.Size, p.Offset())
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (CallItem, error) {
		var it CallItem
		var uid *int64
		var nick *string
		err := row.Scan(&it.ID, &it.Feature, &uid, &nick, &it.Model, &it.Status, &it.Error, &it.PromptTokens, &it.CompletionTokens, &it.LatencyMs, &it.CreatedAt)
		if uid != nil {
			it.User = &Ref{ID: *uid, Nickname: deref(nick)}
		}
		return it, err
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) userMessages(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	ctx := r.Context()
	var exists bool
	if err := h.Svc.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_usr_loop_user WHERE id=$1)`, id).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return httpx.NotFound("用户")
	}
	p := httpx.GetPage(r)
	var total int
	if err := h.Svc.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_msg_loop_ai_message WHERE user_id=$1`, id).Scan(&total); err != nil {
		return err
	}
	items, err := h.Svc.Messages(ctx, id, 0, p.Size, p.Offset(), true)
	if err != nil {
		return err
	}
	if err := h.Audit(ctx, h.Svc.Pool, "ai.messages.view", "user:"+strconv.FormatInt(id, 10), map[string]any{"page": p.Page}); err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}
