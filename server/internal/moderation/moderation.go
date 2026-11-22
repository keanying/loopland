// Package moderation scores user text for risk and keeps the review queue
// (内容审核, docs/api/v2-2-社区.md «内容审核规则»). Modules that own reviewed
// content register an Applier per target type; the admin review endpoints
// call it when a task is decided.
package moderation

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Target types.
const (
	Post       = "post"
	Comment    = "comment"
	Nickname   = "nickname"
	Avatar     = "avatar"
	CrewName   = "crew_name"
	CrewAvatar = "crew_avatar"
	Bio        = "bio"
	Meetup     = "meetup"
	// Product is a merchant product (第五批): new submissions and content
	// changes of on-sale products; there is no author user.
	Product = "product"
)

// Settings are maintained in the admin console (敏感词与审核设置) and stored
// in src.src_sys_loop_setting under the key "moderation".
type Settings struct {
	BlockWords       []string `json:"block_words"`
	ReviewWords      []string `json:"review_words"`
	AutoApproveBelow int      `json:"auto_approve_below"`
	// AutoRejectAbove: a final score at or above it is rejected without a
	// reviewer (docs/api/v2-3-AI.md «阈值»).
	AutoRejectAbove int  `json:"auto_reject_above"`
	AIEnabled       bool `json:"ai_enabled"`
	ReportAutoHide  int  `json:"report_auto_hide"`
}

// DefaultSettings applies until an admin saves the page.
var DefaultSettings = Settings{BlockWords: []string{}, ReviewWords: []string{}, AutoApproveBelow: 20, AutoRejectAbove: 90, AIEnabled: true, ReportAutoHide: 3}

// Score is the result of a check: the rule score and, when the AI
// classifier answered, its verdict; Value is the higher of the two.
type Score struct {
	Value   int      `json:"risk_score"`
	Reasons []string `json:"risk_reasons"`
	Blocked bool     `json:"-"`
	// Rule is the rule-based part of Value.
	Rule int `json:"-"`
	// AI is the classifier's verdict (nil without one).
	AI *Verdict `json:"-"`
	// AIRetry is set when the classifier timed out or failed: the task is
	// re-scored in the background.
	AIRetry bool `json:"-"`
}

// Thresholds.
const (
	BlockScore  = 100
	ReviewScore = 70
	ChatReject  = 70
)

// ErrBlocked is returned (as an HTTP 400 content_blocked) for blocked text.
var ErrBlocked = httpx.BadRequest("content_blocked", "内容包含违规信息，请修改后再发")

var (
	rePhone  = regexp.MustCompile(`1[3-9]\d{9}`)
	reURL    = regexp.MustCompile(`(?i)(https?://|www\.)\S+|\b[a-z0-9-]+\.(com|cn|net|top|xyz|vip)\b`)
	reWeChat = regexp.MustCompile(`(?i)(微信|vx|v信|wx|weixin|加v|qq|扣扣)\s*[:：号]?\s*[a-z0-9_-]{5,}`)
)

// Moderator scores text with the current settings.
type Moderator struct {
	Pool *pgxpool.Pool
	// AI classifies content (nil: rules only).
	AI Classifier
	// AITimeout bounds the synchronous classification (default 3 s).
	AITimeout time.Duration
	// RescoreTimeout bounds one background re-scoring call (default 30 s).
	RescoreTimeout time.Duration

	mu       sync.RWMutex
	settings Settings
	loaded   time.Time
	appliers map[string]Applier
}

// Applier changes the reviewed object when its task is decided. Every
// function runs inside the reviewing transaction; the optional ones are nil
// for objects they do not apply to.
type Applier struct {
	Approve func(ctx context.Context, tx pgx.Tx, targetID int64) error
	Reject  func(ctx context.Context, tx pgx.Tx, targetID int64, reason string) error
	// Pend takes automatically approved content back to pending (the
	// background AI re-scoring found it riskier).
	Pend func(ctx context.Context, tx pgx.Tx, targetID int64) error
	// Mask rewrites the object's text with mask and drops the listed images
	// (images of single-image objects such as avatars are reset), before
	// approval (approve_masked).
	Mask func(ctx context.Context, tx pgx.Tx, targetID int64, mask func(string) string, dropImages []string) error
	// HideEndpoints sets a per-object track endpoint radius before approval
	// (approve_hide_endpoints, posts with an activity).
	HideEndpoints func(ctx context.Context, tx pgx.Tx, targetID int64, radiusM float64) error
}

// Register sets the applier for a target type.
func (m *Moderator) Register(target string, a Applier) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.appliers == nil {
		m.appliers = map[string]Applier{}
	}
	m.appliers[target] = a
}

// ApplierFor returns the registered applier.
func (m *Moderator) ApplierFor(target string) (Applier, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	a, ok := m.appliers[target]
	return a, ok
}

// Settings returns the current settings (cached for 10 s).
func (m *Moderator) Settings(ctx context.Context) Settings {
	m.mu.RLock()
	s, fresh := m.settings, time.Since(m.loaded) < 10*time.Second
	m.mu.RUnlock()
	if fresh {
		return s
	}
	s = DefaultSettings
	var raw []byte
	if err := m.Pool.QueryRow(ctx, `SELECT setting_value FROM src.src_sys_loop_setting WHERE setting_key='moderation'`).Scan(&raw); err == nil {
		_ = json.Unmarshal(raw, &s)
	}
	if s.BlockWords == nil {
		s.BlockWords = []string{}
	}
	if s.ReviewWords == nil {
		s.ReviewWords = []string{}
	}
	if s.AutoRejectAbove == 0 {
		s.AutoRejectAbove = DefaultSettings.AutoRejectAbove
	}
	m.mu.Lock()
	m.settings, m.loaded = s, time.Now()
	m.mu.Unlock()
	return s
}

// SaveSettings stores new settings and applies them at once.
func (m *Moderator) SaveSettings(ctx context.Context, s Settings) (Settings, error) {
	clean := func(ws []string) []string {
		out := []string{}
		seen := map[string]bool{}
		for _, w := range ws {
			w = strings.TrimSpace(w)
			if w != "" && !seen[strings.ToLower(w)] {
				seen[strings.ToLower(w)] = true
				out = append(out, w)
			}
		}
		return out
	}
	s.BlockWords, s.ReviewWords = clean(s.BlockWords), clean(s.ReviewWords)
	if s.AutoApproveBelow < 0 || s.AutoApproveBelow > 100 {
		return s, httpx.BadRequest("invalid_body", "自动通过阈值应在 0–100 之间")
	}
	if s.AutoRejectAbove == 0 { // clients from before 第三批
		s.AutoRejectAbove = DefaultSettings.AutoRejectAbove
	}
	if s.AutoRejectAbove < 1 || s.AutoRejectAbove > 100 || s.AutoRejectAbove <= s.AutoApproveBelow {
		return s, httpx.BadRequest("invalid_body", "自动拦截线应在 1–100 之间，且高于自动放行线")
	}
	if s.ReportAutoHide < 1 {
		return s, httpx.BadRequest("invalid_body", "举报自动隐藏次数至少为 1")
	}
	raw, _ := json.Marshal(s)
	if _, err := m.Pool.Exec(ctx, `INSERT INTO src.src_sys_loop_setting (setting_key, setting_value) VALUES ('moderation', $1)
		ON CONFLICT (setting_key) DO UPDATE SET setting_value=EXCLUDED.setting_value, update_time=now()`, raw); err != nil {
		return s, err
	}
	m.mu.Lock()
	m.settings, m.loaded = s, time.Now()
	m.mu.Unlock()
	return s, nil
}

// Check scores text. newUserWithImages adds the new-account image rule.
func (m *Moderator) Check(ctx context.Context, text string, newUserWithImages bool) Score {
	s := m.Settings(ctx)
	norm := normalize(text)
	sc := Score{Reasons: []string{}}
	add := func(v int, why string) {
		if v > sc.Value {
			sc.Value = v
		}
		sc.Reasons = append(sc.Reasons, why)
	}
	for _, w := range s.BlockWords {
		if strings.Contains(norm, normalize(w)) {
			add(BlockScore, "命中拦截词")
			sc.Blocked = true
			break
		}
	}
	for _, w := range s.ReviewWords {
		if strings.Contains(norm, normalize(w)) {
			add(ReviewScore, "命中审核词")
			break
		}
	}
	if rePhone.MatchString(norm) || reURL.MatchString(text) || reWeChat.MatchString(norm) {
		add(50, "含联系方式或网址")
	}
	if newUserWithImages {
		sc.Value = min(100, sc.Value+20)
		sc.Reasons = append(sc.Reasons, "新用户发图")
	}
	return sc
}

// normalize lowercases and drops spaces and common separators, so that
// "微 信" or "w.x" still match.
func normalize(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		switch r {
		case ' ', '\t', '\n', '\r', '.', '-', '_', '*', '·', '|', '/', '\\', '　':
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// NeedsReview reports whether a post or comment with this score waits for
// a reviewer.
func (m *Moderator) NeedsReview(ctx context.Context, sc Score) bool {
	return sc.Value >= m.Settings(ctx).AutoApproveBelow
}

// Submit queues a review task (one pending task per object: a newer
// submission replaces the text and keeps the higher score).
func Submit(ctx context.Context, q db.Querier, target string, targetID, userID int64, text string, images []string, sc Score) (int64, error) {
	if images == nil {
		images = []string{}
	}
	if sc.Reasons == nil {
		sc.Reasons = []string{}
	}
	ij, _ := json.Marshal(images)
	rj, _ := json.Marshal(sc.Reasons)
	a := aiCols(sc)
	var id int64
	err := q.QueryRow(ctx, `INSERT INTO src.src_cnt_loop_review_task (target_type, target_id, user_id, content_text, images_json, risk_score, risk_reasons_json,
			rule_score, ai_score, ai_labels_json, ai_reason, ai_confidence_rate, ai_suggestion_type, ai_model, ai_flagged_images_json, ai_status)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)
		ON CONFLICT (target_type, target_id) WHERE review_status='pending'
		DO UPDATE SET content_text=EXCLUDED.content_text, images_json=EXCLUDED.images_json,
			risk_score=GREATEST(src_cnt_loop_review_task.risk_score, EXCLUDED.risk_score), risk_reasons_json=EXCLUDED.risk_reasons_json,
			rule_score=EXCLUDED.rule_score, ai_score=EXCLUDED.ai_score, ai_labels_json=EXCLUDED.ai_labels_json, ai_reason=EXCLUDED.ai_reason,
			ai_confidence_rate=EXCLUDED.ai_confidence_rate, ai_suggestion_type=EXCLUDED.ai_suggestion_type, ai_model=EXCLUDED.ai_model,
			ai_flagged_images_json=EXCLUDED.ai_flagged_images_json, ai_status=EXCLUDED.ai_status, ai_retry_qty=0, submit_type='submit'
		RETURNING id`, append([]any{target, targetID, nullable(userID), text, ij, sc.Value, rj}, a...)...).Scan(&id)
	return id, err
}

// aiCols are rule_score .. ai_status for an insert.
func aiCols(sc Score) []any {
	status := "none"
	var score *int
	var reason, sugg, model *string
	var conf *float64
	labels, flagged := []byte("[]"), []byte("[]")
	switch {
	case sc.AI != nil:
		v := sc.AI
		status, score, conf = "ok", &v.RiskScore, &v.Confidence
		reason, sugg, model = strPtr(v.Reason), strPtr(v.Suggestion), strPtr(v.ModelName)
		if v.Labels != nil {
			labels, _ = json.Marshal(v.Labels)
		}
		if v.FlaggedImages != nil {
			flagged, _ = json.Marshal(v.FlaggedImages)
		}
	case sc.AIRetry:
		status = "retry"
	}
	return []any{sc.Rule, score, labels, reason, conf, sugg, model, flagged, status}
}

func strPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// Reported bumps the report counter of an object and makes sure it is in
// the queue; it returns the number of distinct reports.
func Reported(ctx context.Context, q db.Querier, target string, targetID, userID int64, text string, reports int) error {
	_, err := q.Exec(ctx, `INSERT INTO src.src_cnt_loop_review_task (target_type, target_id, user_id, content_text, report_qty, risk_reasons_json, submit_type)
		VALUES ($1,$2,$3,$4,$5,'["被举报"]','report')
		ON CONFLICT (target_type, target_id) WHERE review_status='pending'
		DO UPDATE SET report_qty=EXCLUDED.report_qty`, target, targetID, nullable(userID), text, reports)
	return err
}

func nullable(id int64) *int64 {
	if id == 0 {
		return nil
	}
	return &id
}

// ErrDecided is returned when a task is no longer pending.
var ErrDecided = httpx.Conflict("already_reviewed", "这条已经审核过了")

// Decide approves or rejects a pending task and applies it to the object.
func (m *Moderator) Decide(ctx context.Context, taskID, adminID int64, approve bool, reason string) error {
	a := Action{Kind: ActApprove, Reason: reason}
	if !approve {
		a.Kind = ActReject
	}
	return m.Act(ctx, taskID, adminID, a)
}

func nilIfEmpty(s string, keep bool) *string {
	if !keep {
		return nil
	}
	return &s
}
