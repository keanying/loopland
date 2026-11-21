package social

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// AdminHandler serves 内容审核, 举报 and 动态管理 (M-16).
type AdminHandler struct {
	Svc   *Service
	Audit func(ctx context.Context, q db.Querier, action, target string, detail map[string]any) error
	// RemoveMessage takes down a chat message (package community) and
	// returns its sender; nil means reports on messages can only be
	// dismissed or answered with a mute.
	RemoveMessage func(ctx context.Context, tx pgx.Tx, id int64) (sender int64, err error)
}

// Routes registers the endpoints. reviewers is admin/ops/reviewer,
// adminOnly guards the moderation settings.
func (h *AdminHandler) Routes(mux *http.ServeMux, reviewers, adminOnly func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /admin/v1/reviews", reviewers(h.reviews))
	mux.Handle("GET /admin/v1/reviews/stats", reviewers(h.reviewStats))
	mux.Handle("POST /admin/v1/reviews/batch", reviewers(h.reviewBatch))
	mux.Handle("POST /admin/v1/reviews/{id}/approve", reviewers(h.approve))
	mux.Handle("POST /admin/v1/reviews/{id}/reject", reviewers(h.reject))
	mux.Handle("POST /admin/v1/reviews/{id}/decide", reviewers(h.decideAction))

	mux.Handle("GET /admin/v1/reports", reviewers(h.reports))
	mux.Handle("POST /admin/v1/reports/{id}/handle", reviewers(h.handleReport))

	mux.Handle("GET /admin/v1/posts", reviewers(h.posts))
	mux.Handle("DELETE /admin/v1/posts/{id}", reviewers(h.deletePost))

	mux.Handle("GET /admin/v1/moderation/settings", adminOnly(h.settings))
	mux.Handle("PUT /admin/v1/moderation/settings", adminOnly(h.saveSettings))
	mux.Handle("GET /admin/v1/moderation/estimate", adminOnly(h.estimate))
}

// UserRef is {id, nickname}.
type UserRef struct {
	ID       int64  `json:"id"`
	Nickname string `json:"nickname"`
}

// AdminRef is {id, username}.
type AdminRef struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
}

// ReviewTask is the review queue item.
type ReviewTask struct {
	ID           int64      `json:"id"`
	TargetType   string     `json:"target_type"`
	TargetID     int64      `json:"target_id"`
	User         *UserRef   `json:"user"`
	Text         string     `json:"text"`
	Images       []string   `json:"images"`
	RiskScore    int        `json:"risk_score"`
	RiskReasons  []string   `json:"risk_reasons"`
	ReportCount  int        `json:"report_count"`
	Status       string     `json:"status"`
	RejectReason *string    `json:"reject_reason"`
	Reviewer     *AdminRef  `json:"reviewer"`
	ReviewedAt   *time.Time `json:"reviewed_at"`
	CreatedAt    time.Time  `json:"created_at"`
	// AI is the model's judgment (null without one, docs/api/v2-3-AI.md).
	AI *ReviewAI `json:"ai"`
	// UserViolationCount is how often the author's content was rejected or
	// taken down before.
	UserViolationCount int `json:"user_violation_count"`
	// HasActivity marks posts with an activity (approve_hide_endpoints).
	HasActivity bool `json:"has_activity"`
}

// ReviewAI is the AI part of a review task.
type ReviewAI struct {
	RiskScore  int      `json:"risk_score"`
	Labels     []string `json:"labels"`
	Reason     string   `json:"reason"`
	Confidence float64  `json:"confidence"`
	Suggestion string   `json:"suggestion"`
	ModelName  string   `json:"model_name"`
}

const taskCols = `t.id, t.target_type, t.target_id, u.id, u.nickname, COALESCE(t.content_text, ''), t.images_json, t.risk_score, t.risk_reasons_json,
	t.report_qty, t.review_status, t.reject_reason, a.id, a.username, t.review_time, t.create_time,
	t.ai_score, t.ai_labels_json, COALESCE(t.ai_reason, ''), COALESCE(t.ai_confidence_rate, 0), COALESCE(t.ai_suggestion_type, ''), COALESCE(t.ai_model, ''),
	(SELECT count(*) FROM src.src_cnt_loop_review_task v WHERE v.user_id=t.user_id AND v.review_status='rejected')
	  + (SELECT count(*) FROM src.src_soc_loop_post dp WHERE dp.user_id=t.user_id AND dp.delete_reason IS NOT NULL
	     AND NOT EXISTS (SELECT 1 FROM src.src_cnt_loop_review_task v2 WHERE v2.target_type='post' AND v2.target_id=dp.id AND v2.review_status='rejected')),
	t.target_type='post' AND EXISTS (SELECT 1 FROM src.src_soc_loop_post hp WHERE hp.id=t.target_id AND hp.activity_id IS NOT NULL)`

const taskFrom = ` FROM src.src_cnt_loop_review_task t
	LEFT JOIN src.src_usr_loop_user u ON u.id=t.user_id
	LEFT JOIN src.src_sys_loop_admin a ON a.id=t.reviewer_id`

func scanTask(r pgx.CollectableRow) (ReviewTask, error) {
	var t ReviewTask
	var uid, aid *int64
	var nick, uname *string
	var imgs, reasons, labels []byte
	var ai ReviewAI
	var aiScore *int
	err := r.Scan(&t.ID, &t.TargetType, &t.TargetID, &uid, &nick, &t.Text, &imgs, &t.RiskScore, &reasons,
		&t.ReportCount, &t.Status, &t.RejectReason, &aid, &uname, &t.ReviewedAt, &t.CreatedAt,
		&aiScore, &labels, &ai.Reason, &ai.Confidence, &ai.Suggestion, &ai.ModelName, &t.UserViolationCount, &t.HasActivity)
	if aiScore != nil {
		ai.RiskScore = *aiScore
		_ = json.Unmarshal(labels, &ai.Labels)
		if ai.Labels == nil {
			ai.Labels = []string{}
		}
		t.AI = &ai
	}
	if uid != nil {
		t.User = &UserRef{ID: *uid, Nickname: *nick}
	}
	if aid != nil {
		t.Reviewer = &AdminRef{ID: *aid, Username: *uname}
	}
	_ = json.Unmarshal(imgs, &t.Images)
	_ = json.Unmarshal(reasons, &t.RiskReasons)
	if t.Images == nil {
		t.Images = []string{}
	}
	if t.RiskReasons == nil {
		t.RiskReasons = []string{}
	}
	return t, err
}

func (h *AdminHandler) task(ctx context.Context, id int64) (ReviewTask, error) {
	rows, err := h.Svc.Pool.Query(ctx, `SELECT `+taskCols+taskFrom+` WHERE t.id=$1`, id)
	if err != nil {
		return ReviewTask{}, err
	}
	ts, err := pgx.CollectRows(rows, scanTask)
	if err != nil {
		return ReviewTask{}, err
	}
	if len(ts) == 0 {
		return ReviewTask{}, httpx.NotFound("审核任务")
	}
	return ts[0], nil
}

var reviewStatuses = map[string]bool{"pending": true, "approved": true, "rejected": true}

func (h *AdminHandler) reviews(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	p := httpx.GetPage(r)
	status := r.URL.Query().Get("status")
	if status == "" {
		status = "pending"
	}
	if !reviewStatuses[status] {
		return httpx.BadRequest("invalid_body", "status 取值错误")
	}
	typ := r.URL.Query().Get("target_type")
	// decision filters decided tasks: manual | auto (auto_approve / auto_reject).
	decision := r.URL.Query().Get("decision")
	if decision != "" && decision != "manual" && decision != "auto" {
		return httpx.BadRequest("invalid_body", "decision 只能是 manual 或 auto")
	}
	where := ` WHERE t.review_status=$1 AND ($2='' OR t.target_type=$2) AND ($5='' OR ($5='manual' AND t.decision_type IS DISTINCT FROM 'auto_approve' AND t.decision_type IS DISTINCT FROM 'auto_reject')
		OR ($5='auto' AND t.decision_type IN ('auto_approve', 'auto_reject')))`
	var total int
	if err := h.Svc.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_cnt_loop_review_task t`+where+` AND $3::int IS NOT NULL AND $4::int IS NOT NULL`, status, typ, 0, 0, decision).Scan(&total); err != nil {
		return err
	}
	order := ` ORDER BY t.risk_score DESC, t.create_time, t.id`
	if status != "pending" {
		order = ` ORDER BY t.review_time DESC NULLS LAST, t.id DESC`
	}
	rows, err := h.Svc.Pool.Query(ctx, `SELECT `+taskCols+taskFrom+where+order+` LIMIT $3 OFFSET $4`, status, typ, p.Size, p.Offset(), decision)
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, scanTask)
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) decide(w http.ResponseWriter, r *http.Request, approve bool) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	var req struct {
		Reason string `json:"reason"`
	}
	if r.ContentLength != 0 {
		if err := httpx.Decode(r, &req); err != nil {
			return err
		}
	}
	ctx := r.Context()
	ad, _ := httpx.AdminFrom(ctx)
	if err := h.Svc.Mod.Decide(ctx, id, ad.ID, approve, strings.TrimSpace(req.Reason)); err != nil {
		return err
	}
	t, err := h.task(ctx, id)
	if err != nil {
		return err
	}
	action := "review.approve"
	if !approve {
		action = "review.reject"
	}
	if err := h.Audit(ctx, h.Svc.Pool, action, t.TargetType+":"+strconv.FormatInt(t.TargetID, 10), map[string]any{"task_id": id, "reason": req.Reason}); err != nil {
		return err
	}
	return httpx.OK(w, t)
}

// decideAction is POST /admin/v1/reviews/{id}/decide (M-18): the task
// after the action and the next pending one (optionally of ?target_type=).
func (h *AdminHandler) decideAction(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	var req struct {
		Action   string `json:"action"`
		Reason   string `json:"reason"`
		MuteDays int    `json:"mute_days"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	ad, _ := httpx.AdminFrom(ctx)
	if err := h.Svc.Mod.Act(ctx, id, ad.ID, moderation.Action{Kind: req.Action, Reason: req.Reason, MuteDays: req.MuteDays}); err != nil {
		return err
	}
	t, err := h.task(ctx, id)
	if err != nil {
		return err
	}
	detail := map[string]any{"task_id": id, "reason": req.Reason}
	if req.Action == moderation.ActRejectMute {
		detail["mute_days"] = max(req.MuteDays, 0)
	}
	if err := h.Audit(ctx, h.Svc.Pool, "review."+req.Action, t.TargetType+":"+strconv.FormatInt(t.TargetID, 10), detail); err != nil {
		return err
	}
	rows, err := h.Svc.Pool.Query(ctx, `SELECT `+taskCols+taskFrom+` WHERE t.review_status='pending' AND t.id<>$1 AND ($2='' OR t.target_type=$2)
		ORDER BY t.risk_score DESC, t.create_time, t.id LIMIT 1`, id, r.URL.Query().Get("target_type"))
	if err != nil {
		return err
	}
	next, err := pgx.CollectRows(rows, scanTask)
	if err != nil {
		return err
	}
	var nt *ReviewTask
	if len(next) > 0 {
		nt = &next[0]
	}
	return httpx.OK(w, map[string]any{"task": t, "next": nt})
}

func (h *AdminHandler) approve(w http.ResponseWriter, r *http.Request) error {
	return h.decide(w, r, true)
}
func (h *AdminHandler) reject(w http.ResponseWriter, r *http.Request) error {
	return h.decide(w, r, false)
}

func (h *AdminHandler) reviewBatch(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		IDs    []int64 `json:"ids"`
		Action string  `json:"action"`
		Reason string  `json:"reason"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if req.Action != "approve" && req.Action != "reject" {
		return httpx.BadRequest("invalid_body", "action 取值错误")
	}
	if len(req.IDs) == 0 || len(req.IDs) > 100 {
		return httpx.BadRequest("invalid_body", "一次处理 1–100 条")
	}
	ctx := r.Context()
	ad, _ := httpx.AdminFrom(ctx)
	done := 0
	for _, id := range req.IDs {
		err := h.Svc.Mod.Decide(ctx, id, ad.ID, req.Action == "approve", strings.TrimSpace(req.Reason))
		var he *httpx.Error
		if errors.As(err, &he) { // already decided or gone: skip
			continue
		}
		if err != nil {
			return err
		}
		done++
	}
	if err := h.Audit(ctx, h.Svc.Pool, "review.batch", req.Action, map[string]any{"ids": req.IDs, "done": done, "reason": req.Reason}); err != nil {
		return err
	}
	return httpx.OK(w, map[string]int{"done": done})
}

func (h *AdminHandler) reviewStats(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	var pending, today int
	if err := h.Svc.Pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE review_status='pending'), count(*) FILTER (WHERE review_status<>'pending' AND review_time >= $1 AND decision_type IS DISTINCT FROM 'auto_approve' AND decision_type IS DISTINCT FROM 'auto_reject')
		FROM src.src_cnt_loop_review_task`, clock.Today()).Scan(&pending, &today); err != nil {
		return err
	}
	rows, err := h.Svc.Pool.Query(ctx, `SELECT target_type, count(*) FROM src.src_cnt_loop_review_task WHERE review_status='pending' GROUP BY target_type`)
	if err != nil {
		return err
	}
	by := map[string]int{}
	for rows.Next() {
		var t string
		var n int
		if err := rows.Scan(&t, &n); err != nil {
			rows.Close()
			return err
		}
		by[t] = n
	}
	rows.Close()
	return httpx.OK(w, map[string]any{"pending": pending, "today_done": today, "by_type": by})
}

// ---------------------------------------------------------------- reports

// ReportItem is a row of the admin report list.
type ReportItem struct {
	ID            int64      `json:"id"`
	TargetType    string     `json:"target_type"`
	TargetID      int64      `json:"target_id"`
	TargetPreview string     `json:"target_preview"`
	Reporter      UserRef    `json:"reporter"`
	Reason        string     `json:"reason"`
	Detail        *string    `json:"detail"`
	Status        string     `json:"status"`
	HandledBy     *AdminRef  `json:"handled_by"`
	HandledAt     *time.Time `json:"handled_at"`
	CreatedAt     time.Time  `json:"created_at"`
	ReportCount   int        `json:"report_count"`
}

// previewSQL summarises the reported object (messages belong to package
// community and show only their id).
const previewSQL = `COALESCE(CASE rp.target_type
	WHEN 'post' THEN (SELECT left(content_text, 100) FROM src.src_soc_loop_post WHERE id=rp.target_id)
	WHEN 'comment' THEN (SELECT left(content_text, 100) FROM src.src_soc_loop_comment WHERE id=rp.target_id)
	WHEN 'user' THEN (SELECT nickname FROM src.src_usr_loop_user WHERE id=rp.target_id)
	WHEN 'crew' THEN (SELECT name FROM src.src_soc_loop_crew WHERE id=rp.target_id)
	ELSE '消息 #' || rp.target_id END, '')`

var reportStatuses = map[string]bool{"pending": true, "handled": true, "dismissed": true}

func (h *AdminHandler) reports(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	p := httpx.GetPage(r)
	status := r.URL.Query().Get("status")
	if status == "" {
		status = "pending"
	}
	if !reportStatuses[status] {
		return httpx.BadRequest("invalid_body", "status 取值错误")
	}
	typ := r.URL.Query().Get("target_type")
	where := ` WHERE rp.report_status=$1 AND ($2='' OR rp.target_type=$2)`
	var total int
	if err := h.Svc.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_cnt_loop_report rp`+where, status, typ).Scan(&total); err != nil {
		return err
	}
	order := ` ORDER BY rp.create_time, rp.id`
	if status != "pending" {
		order = ` ORDER BY rp.handle_time DESC NULLS LAST, rp.id DESC`
	}
	rows, err := h.Svc.Pool.Query(ctx, `SELECT rp.id, rp.target_type, rp.target_id, `+previewSQL+`, u.id, u.nickname, rp.reason_type, rp.detail_text,
			rp.report_status, a.id, a.username, rp.handle_time, rp.create_time,
			(SELECT count(*) FROM src.src_cnt_loop_report o WHERE o.target_type=rp.target_type AND o.target_id=rp.target_id)
		FROM src.src_cnt_loop_report rp JOIN src.src_usr_loop_user u ON u.id=rp.reporter_id
		LEFT JOIN src.src_sys_loop_admin a ON a.id=rp.handler_id`+where+order+` LIMIT $3 OFFSET $4`, status, typ, p.Size, p.Offset())
	if err != nil {
		return err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (ReportItem, error) {
		var it ReportItem
		var aid *int64
		var uname *string
		err := row.Scan(&it.ID, &it.TargetType, &it.TargetID, &it.TargetPreview, &it.Reporter.ID, &it.Reporter.Nickname, &it.Reason, &it.Detail,
			&it.Status, &aid, &uname, &it.HandledAt, &it.CreatedAt, &it.ReportCount)
		if aid != nil {
			it.HandledBy = &AdminRef{ID: *aid, Username: *uname}
		}
		return it, err
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.NewList(items, total))
}

func (h *AdminHandler) handleReport(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	var req struct {
		Action   string `json:"action"`
		MuteDays int    `json:"mute_days"`
		Note     string `json:"note"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if req.Action != "remove" && req.Action != "dismiss" {
		return httpx.BadRequest("invalid_body", "action 取值错误")
	}
	if req.MuteDays < 0 || req.MuteDays > 365 {
		return httpx.BadRequest("invalid_body", "禁言天数 0–365")
	}
	ctx := r.Context()
	ad, _ := httpx.AdminFrom(ctx)
	var typ string
	var target int64
	err = pgx.BeginFunc(ctx, h.Svc.Pool, func(tx pgx.Tx) error {
		var status string
		if err := tx.QueryRow(ctx, `SELECT target_type, target_id, report_status FROM src.src_cnt_loop_report WHERE id=$1 FOR UPDATE`, id).
			Scan(&typ, &target, &status); err != nil {
			return notFoundOr(err, "举报")
		}
		if status != "pending" {
			return httpx.Conflict("already_handled", "这条举报已经处理过了")
		}
		author, err := h.ownerAnyState(ctx, tx, typ, target)
		if err != nil {
			return err
		}
		newStatus := "dismissed"
		if req.Action == "remove" {
			newStatus = "handled"
			if author, err = h.remove(ctx, tx, typ, target, "被举报核实", ad.ID); err != nil {
				return err
			}
		}
		if req.MuteDays > 0 && author != 0 {
			if _, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET mute_end_time = GREATEST(COALESCE(mute_end_time, now()), now()) + make_interval(days => $2) WHERE id=$1`,
				author, req.MuteDays); err != nil {
				return err
			}
			if err := inbox.Notify(ctx, tx, author, inbox.System, "你已被禁言", "你发布的内容被举报并经核实违规，禁言 "+strconv.Itoa(req.MuteDays)+" 天。",
				map[string]any{"type": "muted", "days": req.MuteDays}); err != nil {
				return err
			}
		}
		var note *string
		if n := strings.TrimSpace(req.Note); n != "" {
			note = &n
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_cnt_loop_report SET report_status=$4, handle_action_type=$5, handler_id=$6, handle_note=$7, handle_time=now(),
				mute_day_qty = CASE WHEN id=$3 THEN $8 ELSE mute_day_qty END
			WHERE target_type=$1 AND target_id=$2 AND (id=$3 OR report_status='pending')`,
			typ, target, id, newStatus, req.Action, ad.ID, note, req.MuteDays); err != nil {
			return err
		}
		return h.Audit(ctx, tx, "report.handle", typ+":"+strconv.FormatInt(target, 10),
			map[string]any{"report_id": id, "action": req.Action, "mute_days": req.MuteDays, "note": req.Note})
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

// ownerAnyState returns the author of a reported object even if it was
// deleted since (0 when unknown).
func (h *AdminHandler) ownerAnyState(ctx context.Context, q db.Querier, typ string, id int64) (int64, error) {
	var sql string
	switch typ {
	case "post":
		sql = `SELECT user_id FROM src.src_soc_loop_post WHERE id=$1`
	case "comment":
		sql = `SELECT user_id FROM src.src_soc_loop_comment WHERE id=$1`
	case "user":
		sql = `SELECT id FROM src.src_usr_loop_user WHERE id=$1`
	case "crew":
		sql = `SELECT leader_id FROM src.src_soc_loop_crew WHERE id=$1`
	default:
		return 0, nil
	}
	var owner int64
	err := q.QueryRow(ctx, sql, id).Scan(&owner)
	if db.IsNoRows(err) {
		return 0, nil
	}
	return owner, err
}

// remove takes an object down (下架) and tells its author; it returns the
// author (0 when unknown).
func (h *AdminHandler) remove(ctx context.Context, tx pgx.Tx, typ string, id int64, reason string, adminID int64) (int64, error) {
	notify := func(user int64, what string, data map[string]any) error {
		data["type"] = "content_removed"
		return inbox.Notify(ctx, tx, user, inbox.System, "内容已下架", what+"违反社区规范，已被下架。", data)
	}
	closeTasks := func(target string) error {
		_, err := tx.Exec(ctx, `UPDATE src.src_cnt_loop_review_task SET review_status='rejected', reject_reason=$3, reviewer_id=$4, review_time=now()
			WHERE target_type=$1 AND target_id=$2 AND review_status='pending'`, target, id, reason, adminID)
		return err
	}
	switch typ {
	case "post":
		var author int64
		err := tx.QueryRow(ctx, `UPDATE src.src_soc_loop_post SET delete_time=COALESCE(delete_time, now()), delete_reason=$2, update_time=now() WHERE id=$1 RETURNING user_id`,
			id, reason).Scan(&author)
		if err != nil {
			return 0, notFoundOr(err, "动态")
		}
		if err := closeTasks(moderation.Post); err != nil {
			return 0, err
		}
		return author, notify(author, "你的动态", map[string]any{"post_id": id})
	case "comment":
		var author, post int64
		if err := tx.QueryRow(ctx, `SELECT user_id, post_id FROM src.src_soc_loop_comment WHERE id=$1`, id).Scan(&author, &post); err != nil {
			return 0, notFoundOr(err, "评论")
		}
		if err := hideComment(ctx, tx, id, "", "", true); err != nil {
			return 0, err
		}
		if err := closeTasks(moderation.Comment); err != nil {
			return 0, err
		}
		return author, notify(author, "你的评论", map[string]any{"post_id": post, "comment_id": id})
	case "user":
		tag, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET nickname=$2, avatar_url=NULL, bio=NULL WHERE id=$1`, id, DefaultNickname(id))
		if err != nil {
			return 0, err
		}
		if tag.RowsAffected() == 0 {
			return 0, httpx.NotFound("用户")
		}
		return id, notify(id, "你的昵称、头像或简介", map[string]any{"user_id": id})
	case "crew":
		leader, err := ResetCrewName(ctx, tx, id)
		if err != nil {
			return 0, err
		}
		if leader == 0 {
			return 0, httpx.NotFound("跑团")
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_crew SET avatar_url=NULL WHERE id=$1`, id); err != nil {
			return 0, err
		}
		return leader, notify(leader, "你的跑团名称或头像", map[string]any{"crew_id": id})
	case "message":
		if h.RemoveMessage == nil {
			return 0, httpx.BadRequest("not_supported", "消息下架暂未接入，请驳回或只禁言")
		}
		sender, err := h.RemoveMessage(ctx, tx, id)
		if err != nil {
			return 0, err
		}
		return sender, notify(sender, "你发送的消息", map[string]any{"message_id": id})
	}
	return 0, httpx.BadRequest("invalid_target", "举报对象错误")
}

// ---------------------------------------------------------------- posts

func (h *AdminHandler) posts(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	p := httpx.GetPage(r)
	q := r.URL.Query()
	var userID int64
	if v := q.Get("user_id"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return httpx.BadRequest("invalid_body", "user_id 错误")
		}
		userID = n
	}
	rs := q.Get("review_status")
	if rs != "" && !reviewStatuses[rs] {
		return httpx.BadRequest("invalid_body", "review_status 取值错误")
	}
	where := ` WHERE ($2='' OR p.content_text ILIKE '%' || $2 || '%') AND ($3::bigint=0 OR p.user_id=$3) AND ($4='' OR p.review_status=$4)`
	args := []any{int64(0), q.Get("q"), userID, rs}
	var total int
	if err := h.Svc.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_soc_loop_post p`+where+` AND $1::bigint=0`, args...).Scan(&total); err != nil {
		return err
	}
	rows, err := h.Svc.Pool.Query(ctx, `SELECT `+postCols+` FROM src.src_soc_loop_post p`+where+` ORDER BY p.create_time DESC, p.id DESC LIMIT $5 OFFSET $6`,
		append(args, p.Size, p.Offset())...)
	if err != nil {
		return err
	}
	var reasons []*string
	posts, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Post, error) {
		post, deleted, err := scanPost(row)
		post.Deleted = &deleted
		reasons = append(reasons, post.RejectReason)
		return post, err
	})
	if err != nil {
		return err
	}
	if err := h.Svc.hydrate(ctx, 0, posts); err != nil {
		return err
	}
	for i := range posts {
		posts[i].RejectReason = reasons[i]
	}
	return httpx.OK(w, httpx.NewList(posts, total))
}

func (h *AdminHandler) deletePost(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	var req struct {
		Reason string `json:"reason"`
	}
	if r.ContentLength != 0 {
		if err := httpx.Decode(r, &req); err != nil {
			return err
		}
	}
	reason := strings.TrimSpace(req.Reason)
	if reason == "" {
		reason = "违反社区规范"
	}
	ctx := r.Context()
	ad, _ := httpx.AdminFrom(ctx)
	err = pgx.BeginFunc(ctx, h.Svc.Pool, func(tx pgx.Tx) error {
		if _, err := h.remove(ctx, tx, "post", id, reason, ad.ID); err != nil {
			return err
		}
		return h.Audit(ctx, tx, "post.delete", "post:"+strconv.FormatInt(id, 10), map[string]any{"reason": reason})
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

// ---------------------------------------------------------------- settings

func (h *AdminHandler) settings(w http.ResponseWriter, r *http.Request) error {
	return httpx.OK(w, h.Svc.Mod.Settings(r.Context()))
}

func (h *AdminHandler) saveSettings(w http.ResponseWriter, r *http.Request) error {
	// Fields left out keep their value (clients from before 第三批 do not
	// send auto_reject_above / ai_enabled).
	var req struct {
		BlockWords       *[]string `json:"block_words"`
		ReviewWords      *[]string `json:"review_words"`
		AutoApproveBelow *int      `json:"auto_approve_below"`
		AutoRejectAbove  *int      `json:"auto_reject_above"`
		AIEnabled        *bool     `json:"ai_enabled"`
		ReportAutoHide   *int      `json:"report_auto_hide"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	in := h.Svc.Mod.Settings(ctx)
	if req.BlockWords != nil {
		in.BlockWords = *req.BlockWords
	}
	if req.ReviewWords != nil {
		in.ReviewWords = *req.ReviewWords
	}
	if req.AutoApproveBelow != nil {
		in.AutoApproveBelow = *req.AutoApproveBelow
	}
	if req.AutoRejectAbove != nil {
		in.AutoRejectAbove = *req.AutoRejectAbove
		if in.AutoRejectAbove == 0 {
			return httpx.BadRequest("invalid_body", "自动拦截线应在 1–100 之间，且高于自动放行线")
		}
	}
	if req.AIEnabled != nil {
		in.AIEnabled = *req.AIEnabled
	}
	if req.ReportAutoHide != nil {
		in.ReportAutoHide = *req.ReportAutoHide
	}
	out, err := h.Svc.Mod.SaveSettings(ctx, in)
	if err != nil {
		return err
	}
	if err := h.Audit(ctx, h.Svc.Pool, "moderation.settings", "moderation", map[string]any{
		"block_words": len(out.BlockWords), "review_words": len(out.ReviewWords), "auto_approve_below": out.AutoApproveBelow,
		"auto_reject_above": out.AutoRejectAbove, "ai_enabled": out.AIEnabled, "report_auto_hide": out.ReportAutoHide}); err != nil {
		return err
	}
	return httpx.OK(w, out)
}

// estimate is GET /admin/v1/moderation/estimate (M-19).
func (h *AdminHandler) estimate(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	cur := h.Svc.Mod.Settings(ctx)
	get := func(key string, def int) (int, error) {
		v := r.URL.Query().Get(key)
		if v == "" {
			return def, nil
		}
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 || n > 101 {
			return 0, httpx.BadRequest("invalid_body", key+" 应在 0–100 之间")
		}
		return n, nil
	}
	ap, err := get("auto_approve_below", cur.AutoApproveBelow)
	if err != nil {
		return err
	}
	rj, err := get("auto_reject_above", cur.AutoRejectAbove)
	if err != nil {
		return err
	}
	if rj <= ap {
		return httpx.BadRequest("invalid_body", "自动拦截线应高于自动放行线")
	}
	est, err := h.Svc.Mod.Estimate(ctx, ap, rj)
	if err != nil {
		return err
	}
	return httpx.OK(w, est)
}
