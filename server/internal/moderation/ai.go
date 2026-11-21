package moderation

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// AI moderation (docs/api/v2-3-AI.md «内容审核升级»): a small model scores
// the content next to the rules, the final score is the higher one, and
// the thresholds approve, queue or reject it.

// Verdict is the classifier's judgment.
type Verdict struct {
	RiskScore  int      `json:"risk_score"`
	Labels     []string `json:"labels"`
	Reason     string   `json:"reason"`
	Confidence float64  `json:"confidence"`
	Suggestion string   `json:"suggestion"`
	ModelName  string   `json:"model_name"`
	// FlaggedImages are the image urls judged violating (vision only).
	FlaggedImages []string `json:"-"`
}

// Labels and suggestions the classifier may return.
var (
	Labels = map[string]string{"ad": "广告引流", "contact": "联系方式", "porn": "色情", "politics": "涉政", "abuse": "辱骂",
		"fraud": "诈骗", "illegal": "违法", "privacy": "隐私泄露", "minor": "未成年人", "other": "其他"}
	Suggestions = map[string]bool{"reject": true, "review": true, "approve": true, "mask": true, "hide_endpoints": true}
)

// Normalize clamps a verdict to the documented ranges.
func (v *Verdict) Normalize() {
	v.RiskScore = max(0, min(100, v.RiskScore))
	if math.IsNaN(v.Confidence) {
		v.Confidence = 0
	}
	v.Confidence = math.Max(0, math.Min(1, v.Confidence))
	labels := []string{}
	for _, l := range v.Labels {
		if _, ok := Labels[l]; ok && !contains(labels, l) {
			labels = append(labels, l)
		}
	}
	v.Labels = labels
	if !Suggestions[v.Suggestion] {
		switch {
		case v.RiskScore >= 90:
			v.Suggestion = "reject"
		case v.RiskScore >= 20:
			v.Suggestion = "review"
		default:
			v.Suggestion = "approve"
		}
	}
	if r := []rune(v.Reason); len(r) > 200 {
		v.Reason = string(r[:200])
	}
}

func contains(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}

// Content is what is sent for review.
type Content struct {
	Target string
	UserID int64
	Text   string
	Images []string
	// NewUserWithImages adds the new-account image rule.
	NewUserWithImages bool
}

// ErrNoAI tells the moderator that no model is available right now (AI not
// configured): the content is scored by the rules alone, without retry.
var ErrNoAI = errors.New("no ai model")

// Classifier scores content with a model.
type Classifier interface {
	Classify(ctx context.Context, c Content) (*Verdict, error)
}

// Review scores content with the rules and, when enabled, the AI
// classifier (synchronous, AITimeout). A timeout or failure is marked for
// background re-scoring.
func (m *Moderator) Review(ctx context.Context, c Content) Score {
	sc := m.Check(ctx, c.Text, c.NewUserWithImages)
	sc.Rule = sc.Value
	if sc.Blocked || m.AI == nil || !m.Settings(ctx).AIEnabled || (strings.TrimSpace(c.Text) == "" && len(c.Images) == 0) {
		return sc
	}
	timeout := m.AITimeout
	if timeout <= 0 {
		timeout = 3 * time.Second
	}
	actx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	v, err := m.AI.Classify(actx, c)
	switch {
	case errors.Is(err, ErrNoAI):
	case err != nil || v == nil:
		sc.AIRetry = true
	default:
		v.Normalize()
		sc.AI = v
		sc.Value = max(sc.Value, v.RiskScore)
	}
	return sc
}

// Outcomes of a score under the thresholds.
const (
	OutcomeApprove = "approve"
	OutcomeReview  = "review"
	OutcomeReject  = "reject"
)

// Outcome applies the thresholds: below auto_approve_below approve, at or
// above auto_reject_above reject, otherwise a reviewer decides.
func (m *Moderator) Outcome(ctx context.Context, sc Score) string {
	s := m.Settings(ctx)
	switch {
	case sc.Value >= s.AutoRejectAbove:
		return OutcomeReject
	case sc.Value >= s.AutoApproveBelow:
		return OutcomeReview
	}
	return OutcomeApprove
}

// RejectReason is what an automatically rejected author is told.
func RejectReason(sc Score) string {
	if sc.AI != nil && len(sc.AI.Labels) > 0 {
		var names []string
		for _, l := range sc.AI.Labels {
			names = append(names, Labels[l])
		}
		return "内容疑似" + strings.Join(names, "、") + "，未通过自动审核，修改后可重新发布"
	}
	return "内容不符合社区规范，未通过自动审核，修改后可重新发布"
}

// File records scored content inside the caller's transaction, after the
// object was written (approved for OutcomeApprove, pending otherwise):
//   - approve: an approved task (decision auto_approve), kept for the daily
//     estimate and for background re-scoring;
//   - review: a pending task (Submit);
//   - reject: a rejected task (decision auto_reject) and the applier's
//     Reject, which tells the author.
func (m *Moderator) File(ctx context.Context, tx pgx.Tx, target string, targetID, userID int64, text string, images []string, sc Score, outcome string) error {
	if outcome == OutcomeReview {
		_, err := Submit(ctx, tx, target, targetID, userID, text, images, sc)
		return err
	}
	if images == nil {
		images = []string{}
	}
	if sc.Reasons == nil {
		sc.Reasons = []string{}
	}
	ij, _ := json.Marshal(images)
	rj, _ := json.Marshal(sc.Reasons)
	status, decision := "approved", "auto_approve"
	var reason *string
	if outcome == OutcomeReject {
		status, decision = "rejected", "auto_reject"
		r := RejectReason(sc)
		reason = &r
	}
	if _, err := tx.Exec(ctx, `INSERT INTO src.src_cnt_loop_review_task (target_type, target_id, user_id, content_text, images_json, risk_score, risk_reasons_json,
			rule_score, ai_score, ai_labels_json, ai_reason, ai_confidence_rate, ai_suggestion_type, ai_model, ai_flagged_images_json, ai_status,
			review_status, decision_type, reject_reason, review_time)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19, now())`,
		append(append([]any{target, targetID, nullable(userID), text, ij, sc.Value, rj}, aiCols(sc)...), status, decision, reason)...); err != nil {
		return err
	}
	if outcome != OutcomeReject {
		return nil
	}
	a, ok := m.ApplierFor(target)
	if !ok || a.Reject == nil {
		return fmt.Errorf("no applier for %s", target)
	}
	return a.Reject(ctx, tx, targetID, *reason)
}

// ---------------------------------------------------------------- actions (M-18)

// Review actions.
const (
	ActApprove       = "approve"
	ActApproveMasked = "approve_masked"
	ActHideEndpoints = "approve_hide_endpoints"
	ActReject        = "reject"
	ActRejectMute    = "reject_mute"
)

// Actions accepted by Act.
var Actions = map[string]bool{ActApprove: true, ActApproveMasked: true, ActHideEndpoints: true, ActReject: true, ActRejectMute: true}

// HideEndpointsM is the radius set by approve_hide_endpoints.
const HideEndpointsM = 500

// Action is a reviewer's decision.
type Action struct {
	Kind     string
	Reason   string
	MuteDays int
}

// Act decides a pending task and applies it to the object.
func (m *Moderator) Act(ctx context.Context, taskID, adminID int64, a Action) error {
	if !Actions[a.Kind] {
		return httpx.BadRequest("invalid_body", "action 取值错误")
	}
	if a.Kind == ActRejectMute {
		if a.MuteDays == 0 {
			a.MuteDays = 7
		}
		if a.MuteDays < 1 || a.MuteDays > 365 {
			return httpx.BadRequest("invalid_body", "禁言天数 1–365")
		}
	}
	return pgx.BeginFunc(ctx, m.Pool, func(tx pgx.Tx) error {
		var target, status string
		var targetID int64
		var author *int64
		var flaggedRaw []byte
		err := tx.QueryRow(ctx, `SELECT target_type, target_id, review_status, user_id, ai_flagged_images_json FROM src.src_cnt_loop_review_task WHERE id=$1 FOR UPDATE`, taskID).
			Scan(&target, &targetID, &status, &author, &flaggedRaw)
		if errors.Is(err, pgx.ErrNoRows) {
			return httpx.NotFound("审核任务")
		}
		if err != nil {
			return err
		}
		if status != "pending" {
			return ErrDecided
		}
		ap, ok := m.ApplierFor(target)
		if !ok {
			return fmt.Errorf("no applier for %s", target)
		}
		approve := a.Kind == ActApprove || a.Kind == ActApproveMasked || a.Kind == ActHideEndpoints
		reason := strings.TrimSpace(a.Reason)
		if !approve && reason == "" {
			reason = "内容不符合社区规范"
		}
		switch a.Kind {
		case ActApproveMasked:
			if ap.Mask == nil {
				return httpx.BadRequest("not_supported", "这类内容不能打码后通过")
			}
			var flagged []string
			_ = json.Unmarshal(flaggedRaw, &flagged)
			if err := ap.Mask(ctx, tx, targetID, m.MaskFunc(ctx), flagged); err != nil {
				return err
			}
		case ActHideEndpoints:
			if ap.HideEndpoints == nil {
				return httpx.BadRequest("not_supported", "只有附了运动的动态可以隐藏起终点后通过")
			}
			if err := ap.HideEndpoints(ctx, tx, targetID, HideEndpointsM); err != nil {
				return err
			}
		}
		newStatus := "approved"
		if !approve {
			newStatus = "rejected"
		}
		if _, err := tx.Exec(ctx, `UPDATE src.src_cnt_loop_review_task SET review_status=$2, reject_reason=$3, reviewer_id=$4, review_time=now(), decision_type='manual' WHERE id=$1`,
			taskID, newStatus, nilIfEmpty(reason, !approve), adminID); err != nil {
			return err
		}
		if approve {
			if ap.Approve != nil {
				return ap.Approve(ctx, tx, targetID)
			}
			return nil
		}
		if err := ap.Reject(ctx, tx, targetID, reason); err != nil {
			return err
		}
		if a.Kind == ActRejectMute && author != nil {
			return Mute(ctx, tx, *author, a.MuteDays, "你发布的内容违反社区规范")
		}
		return nil
	})
}

// Mute silences a user for days and tells them.
func Mute(ctx context.Context, tx pgx.Tx, user int64, days int, why string) error {
	if _, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET mute_end_time = GREATEST(COALESCE(mute_end_time, now()), now()) + make_interval(days => $2) WHERE id=$1`,
		user, days); err != nil {
		return err
	}
	return inbox.Notify(ctx, tx, user, inbox.System, "你已被禁言", why+"，禁言 "+strconv.Itoa(days)+" 天。", map[string]any{"type": "muted", "days": days})
}

// MaskFunc returns a function that replaces block / review words and
// contact details with '*'.
func (m *Moderator) MaskFunc(ctx context.Context) func(string) string {
	s := m.Settings(ctx)
	var words []string
	words = append(words, s.BlockWords...)
	words = append(words, s.ReviewWords...)
	return func(text string) string { return Mask(text, words) }
}

// Mask replaces the words (case-insensitive) and contact details in text
// with as many '*' as they have characters.
func Mask(text string, words []string) string {
	stars := func(s string) string { return strings.Repeat("*", utf8.RuneCountInString(s)) }
	for _, w := range words {
		if w == "" {
			continue
		}
		re, err := regexp.Compile(`(?i)` + regexp.QuoteMeta(w))
		if err == nil {
			text = re.ReplaceAllStringFunc(text, stars)
		}
	}
	for _, re := range []*regexp.Regexp{reWeChat, reURL, rePhone} {
		text = re.ReplaceAllStringFunc(text, stars)
	}
	return text
}

// ---------------------------------------------------------------- background re-scoring

// Rescore re-runs the classifier for tasks whose synchronous scoring timed
// out or failed (job ai_moderation_rescore). A higher score updates the
// task; content that was approved automatically and now reaches the review
// line goes back to pending.
func (m *Moderator) Rescore(ctx context.Context) error {
	if _, err := m.Pool.Exec(ctx, `UPDATE src.src_cnt_loop_review_task SET ai_status='failed' WHERE ai_status='retry' AND create_time <= now() - interval '1 day'`); err != nil {
		return err
	}
	if m.AI == nil {
		return nil
	}
	rows, err := m.Pool.Query(ctx, `SELECT id, target_type, COALESCE(user_id, 0), COALESCE(content_text, ''), images_json
		FROM src.src_cnt_loop_review_task WHERE ai_status='retry' ORDER BY id LIMIT 20`)
	if err != nil {
		return err
	}
	type item struct {
		id     int64
		c      Content
		images []byte
	}
	var items []item
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.id, &it.c.Target, &it.c.UserID, &it.c.Text, &it.images); err != nil {
			rows.Close()
			return err
		}
		_ = json.Unmarshal(it.images, &it.c.Images)
		items = append(items, it)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	timeout := m.RescoreTimeout
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	for _, it := range items {
		cctx, cancel := context.WithTimeout(ctx, timeout)
		v, err := m.AI.Classify(cctx, it.c)
		cancel()
		if errors.Is(err, ErrNoAI) {
			if _, err := m.Pool.Exec(ctx, `UPDATE src.src_cnt_loop_review_task SET ai_status='none' WHERE id=$1`, it.id); err != nil {
				return err
			}
			continue
		}
		if err != nil || v == nil {
			if _, err := m.Pool.Exec(ctx, `UPDATE src.src_cnt_loop_review_task SET ai_retry_qty=ai_retry_qty+1,
				ai_status=CASE WHEN ai_retry_qty+1 >= 5 THEN 'failed' ELSE 'retry' END WHERE id=$1`, it.id); err != nil {
				return err
			}
			continue
		}
		v.Normalize()
		if err := m.applyRescore(ctx, it.id, v); err != nil {
			return err
		}
	}
	return nil
}

func (m *Moderator) applyRescore(ctx context.Context, id int64, v *Verdict) error {
	approveBelow := m.Settings(ctx).AutoApproveBelow
	return pgx.BeginFunc(ctx, m.Pool, func(tx pgx.Tx) error {
		var target, status string
		var decision *string
		var targetID int64
		var old, rule int
		if err := tx.QueryRow(ctx, `SELECT target_type, target_id, review_status, decision_type, risk_score, COALESCE(rule_score, risk_score)
			FROM src.src_cnt_loop_review_task WHERE id=$1 FOR UPDATE`, id).Scan(&target, &targetID, &status, &decision, &old, &rule); err != nil {
			return err
		}
		final := max(rule, v.RiskScore)
		a := aiCols(Score{Rule: rule, AI: v})
		if _, err := tx.Exec(ctx, `UPDATE src.src_cnt_loop_review_task SET risk_score=GREATEST(risk_score, $2), ai_score=$3, ai_labels_json=$4, ai_reason=$5,
				ai_confidence_rate=$6, ai_suggestion_type=$7, ai_model=$8, ai_flagged_images_json=$9, ai_status='ok' WHERE id=$1`,
			id, final, a[1], a[2], a[3], a[4], a[5], a[6], a[7]); err != nil {
			return err
		}
		if status != "approved" || decision == nil || *decision != "auto_approve" || final <= old || final < approveBelow {
			return nil
		}
		// Back to the queue: merge into an existing pending task (e.g. from a
		// report) or reopen this one.
		tag, err := tx.Exec(ctx, `UPDATE src.src_cnt_loop_review_task SET risk_score=GREATEST(risk_score, $3), ai_score=$4, ai_labels_json=$5, ai_reason=$6,
				ai_confidence_rate=$7, ai_suggestion_type=$8, ai_model=$9, ai_flagged_images_json=$10, ai_status='ok'
			WHERE target_type=$1 AND target_id=$2 AND review_status='pending'`, target, targetID, final, a[1], a[2], a[3], a[4], a[5], a[6], a[7])
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			if _, err := tx.Exec(ctx, `UPDATE src.src_cnt_loop_review_task SET review_status='pending', decision_type=NULL, review_time=NULL WHERE id=$1`, id); err != nil {
				return err
			}
		}
		if ap, ok := m.ApplierFor(target); ok && ap.Pend != nil {
			return ap.Pend(ctx, tx, targetID)
		}
		return nil
	})
}

// ---------------------------------------------------------------- estimate (M-19)

// Estimate is the expected daily volume under two thresholds.
type Estimate struct {
	PerDayManual      float64 `json:"per_day_manual"`
	PerDayAutoApprove float64 `json:"per_day_auto_approve"`
	PerDayAutoReject  float64 `json:"per_day_auto_reject"`
	Days              int     `json:"days"`
}

// EstimateDays is the look-back of Estimate.
const EstimateDays = 7

// Estimate applies the thresholds to the risk scores submitted in the last
// 7 days.
func (m *Moderator) Estimate(ctx context.Context, approveBelow, rejectAbove int) (Estimate, error) {
	var ap, rj, man int
	err := m.Pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE risk_score < $1), count(*) FILTER (WHERE risk_score >= $2 AND risk_score >= $1),
			count(*) FILTER (WHERE risk_score >= $1 AND risk_score < $2)
		FROM src.src_cnt_loop_review_task WHERE submit_type='submit' AND create_time >= now() - make_interval(days => $3)`,
		approveBelow, rejectAbove, EstimateDays).Scan(&ap, &rj, &man)
	per := func(n int) float64 { return math.Round(float64(n)/EstimateDays*10) / 10 }
	return Estimate{PerDayManual: per(man), PerDayAutoApprove: per(ap), PerDayAutoReject: per(rj), Days: EstimateDays}, err
}
