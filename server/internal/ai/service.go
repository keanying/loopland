package ai

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/providers"
)

// Features recorded in src.src_sys_loop_ai_call.
const (
	FeatureChat       = "chat"
	FeatureRoute      = "route"
	FeatureReport     = "report"
	FeatureModeration = "moderation"
	FeatureWorkout    = "workout"
)

// Fixed texts.
const (
	Disclaimer   = "内容由 AI 生成，仅供参考"
	MockName     = "开发环境模拟 AI"
	MockModel    = "mock"
	BlockedReply = "这个问题圈圈暂时回答不了"
)

// ErrUnavailable is returned outside dev while no model is configured.
var ErrUnavailable = httpx.E(http.StatusServiceUnavailable, "ai_unavailable", "AI 功能暂未开通")

// Service implements the AI endpoints, the moderation classifier and the
// AI jobs.
type Service struct {
	Pool   *pgxpool.Pool
	Redis  *redis.Client
	Config *gameplay.Store
	Mod    *moderation.Moderator
	Log    *slog.Logger
	// AIConf returns the live model configuration (nil when the AI service
	// is not enabled in 系统配置).
	AIConf func() *providers.AIConfig
	// AMapKey returns the 高德 Web 服务 key ("" when not configured).
	AMapKey func() string
	// AMapBase is the 高德 API root (tests point it at a fake server).
	AMapBase string
	// HTTP is used for the model and 高德 (nil: a client without timeout;
	// every call carries its own deadline).
	HTTP *http.Client
	// Dev enables the mock model when nothing is configured.
	Dev bool
	// MediaDir holds local uploads (dev without OSS): such images are sent
	// to the model as data URLs because the model cannot reach this host.
	MediaDir string
	// LLM, when set, replaces the configured model (tests).
	LLM LLM
}

// Backend is the model setup for one request.
type Backend struct {
	LLM            LLM
	Mock           bool
	ChatModel      string
	SmallModel     string
	VisionModel    string
	ModelName      string
	RegistrationNo string
	WeeklyFree     int
	Timeout        time.Duration
	PriceIn        int // fen per million input tokens (0: not set)
	PriceOut       int
}

// Vision reports whether images can be sent.
func (b *Backend) Vision() bool { return b.VisionModel != "" }

// Backend returns the live model or ErrUnavailable.
func (s *Service) Backend() (*Backend, error) {
	var c *providers.AIConfig
	if s.AIConf != nil {
		c = s.AIConf()
	}
	if c == nil {
		if !s.Dev {
			return nil, ErrUnavailable
		}
		return &Backend{LLM: Mock{}, Mock: true, ChatModel: MockModel, SmallModel: MockModel, VisionModel: MockModel,
			ModelName: MockName, RegistrationNo: "开发环境（未备案）", WeeklyFree: 3, Timeout: 30 * time.Second}, nil
	}
	b := &Backend{ChatModel: c.Model, SmallModel: c.SmallModel, VisionModel: c.VisionModel, ModelName: c.DisplayName,
		RegistrationNo: c.RegistrationNo, WeeklyFree: c.WeeklyFreeQuota, Timeout: time.Duration(c.TimeoutS) * time.Second,
		PriceIn: c.PriceInputPerMTokFen, PriceOut: c.PriceOutputPerMTokFen}
	if b.SmallModel == "" {
		b.SmallModel = b.ChatModel
	}
	if b.Timeout <= 0 {
		b.Timeout = 30 * time.Second
	}
	if b.WeeklyFree < 0 {
		b.WeeklyFree = 0
	}
	if s.LLM != nil {
		b.LLM = s.LLM
	} else {
		b.LLM = &OpenAI{BaseURL: c.Endpoint(), APIKey: c.APIKey, HTTP: s.HTTP}
	}
	return b, nil
}

// Available reports whether the AI features work now (features.ai).
func (s *Service) Available() bool {
	_, err := s.Backend()
	return err == nil
}

// Call runs one model call within the backend timeout and records it in
// src.src_sys_loop_ai_call (metadata only).
func (s *Service) Call(ctx context.Context, b *Backend, feature string, user int64, req Request, onDelta func(string)) (Response, error) {
	cctx, cancel := context.WithTimeout(ctx, b.Timeout)
	defer cancel()
	start := time.Now()
	resp, err := b.LLM.Chat(cctx, req, onDelta)
	latency := time.Since(start)
	if err == nil && resp.Usage.PromptTokens == 0 && resp.Usage.CompletionTokens == 0 {
		resp.Usage = estimateUsage(req, resp)
	}
	s.record(ctx, b, feature, user, req.Model, resp.Usage, latency, err)
	return resp, err
}

func (s *Service) record(ctx context.Context, b *Backend, feature string, user int64, model string, u Usage, latency time.Duration, callErr error) {
	status := "ok"
	var errText *string
	if callErr != nil {
		status = "failed"
		msg := callErr.Error()
		if errors.Is(callErr, context.DeadlineExceeded) {
			msg = "timeout"
		}
		if len(msg) > 300 {
			msg = msg[:300]
		}
		errText = &msg
		u = Usage{}
	}
	var uid *int64
	if user != 0 {
		uid = &user
	}
	rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if _, err := s.Pool.Exec(rctx, `INSERT INTO src.src_sys_loop_ai_call (feature_type, user_id, model_name, call_status, error_text, prompt_token_qty,
			completion_token_qty, latency_ms, is_mock) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
		feature, uid, model, status, errText, u.PromptTokens, u.CompletionTokens, latency.Milliseconds(), b.Mock); err != nil && s.Log != nil {
		s.Log.Error("record ai call", "err", err)
	}
}

// estimateUsage counts roughly 1.5 Chinese characters per token when the
// endpoint did not report usage.
func estimateUsage(req Request, resp Response) Usage {
	n := 0
	for _, m := range req.Messages {
		n += utf8.RuneCountInString(m.Text())
		if m.HasImage() {
			n += 1000
		}
	}
	out := utf8.RuneCountInString(resp.Content)
	for _, c := range resp.ToolCalls {
		out += len(c.Function.Arguments)
	}
	return Usage{PromptTokens: n*2/3 + 1, CompletionTokens: out*2/3 + 1}
}

// ---------------------------------------------------------------- quota

// Quota is the assistant's weekly allowance.
type Quota struct {
	Unlimited  bool      `json:"unlimited"`
	WeeklyFree int       `json:"weekly_free"`
	Used       int       `json:"used"`
	Remaining  *int      `json:"remaining"`
	ResetsAt   time.Time `json:"resets_at"`
}

// WeekStart is Monday 00:00 Asia/Shanghai of the week containing t.
func WeekStart(t time.Time) time.Time {
	d := clock.Day(t)
	return d.AddDate(0, 0, -((int(d.Weekday()) + 6) % 7))
}

// Unlimited reports an active membership whose plan has ai_coach_unlimited
// (a failed renewal keeps it during the grace period).
func Unlimited(ctx context.Context, q db.Querier, user int64) (bool, error) {
	var ok bool
	err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_ord_loop_membership m JOIN src.src_ord_loop_plan p ON p.code=m.plan_code
		WHERE m.user_id=$1 AND (m.expire_time > now() OR m.grace_end_time > now()) AND 'ai_coach_unlimited' = ANY (p.entitlements))`, user).Scan(&ok)
	return ok, err
}

// QuotaOf computes the user's quota this week.
func (s *Service) QuotaOf(ctx context.Context, user int64, weeklyFree int) (Quota, error) {
	now := clock.Now()
	ws := WeekStart(now)
	q := Quota{WeeklyFree: weeklyFree, ResetsAt: ws.AddDate(0, 0, 7).UTC()}
	var err error
	if q.Unlimited, err = Unlimited(ctx, s.Pool, user); err != nil {
		return q, err
	}
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_msg_loop_ai_message WHERE user_id=$1 AND is_quota_counted AND create_time >= $2`,
		user, ws).Scan(&q.Used); err != nil {
		return q, err
	}
	if !q.Unlimited {
		left := max(0, weeklyFree-q.Used)
		q.Remaining = &left
	}
	return q, nil
}

// ---------------------------------------------------------------- handlers

// Handler serves /v1/ai/* and POST /v1/activities/{id}/ai-report.
type Handler struct{ Svc *Service }

// Routes registers the app endpoints.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("GET /v1/ai/info", auth(h.info))
	mux.Handle("GET /v1/ai/greeting", auth(h.greeting))
	mux.Handle("GET /v1/ai/messages", auth(h.messages))
	mux.Handle("DELETE /v1/ai/messages", auth(h.clear))
	mux.Handle("POST /v1/ai/chat", auth(h.chat))
	mux.Handle("GET /v1/ai/routes", auth(h.routes))
	mux.Handle("GET /v1/ai/workouts", auth(h.workouts))
	mux.Handle("POST /v1/activities/{id}/ai-report", auth(h.report))
}

// Info is GET /v1/ai/info.
type Info struct {
	Enabled        bool   `json:"enabled"`
	ModelName      string `json:"model_name"`
	RegistrationNo string `json:"registration_no"`
	Vision         bool   `json:"vision"`
	Disclaimer     string `json:"disclaimer"`
	Quota          Quota  `json:"quota"`
}

func (h *Handler) info(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	b, err := h.Svc.Backend()
	if err != nil { // not configured outside dev: the app hides the entry
		q, qerr := h.Svc.QuotaOf(ctx, uid, 0)
		if qerr != nil {
			return qerr
		}
		return httpx.OK(w, Info{Disclaimer: Disclaimer, Quota: q})
	}
	q, err := h.Svc.QuotaOf(ctx, uid, b.WeeklyFree)
	if err != nil {
		return err
	}
	return httpx.OK(w, Info{Enabled: true, ModelName: b.ModelName, RegistrationNo: b.RegistrationNo, Vision: b.Vision(), Disclaimer: Disclaimer, Quota: q})
}

func queryFloat(r *http.Request, key string) (*float64, error) {
	v := r.URL.Query().Get(key)
	if v == "" {
		return nil, nil
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return nil, httpx.BadRequest("invalid_body", key+" 不是数字")
	}
	return &f, nil
}

// point parses optional lat/lng query parameters.
func point(r *http.Request) (*LatLng, error) {
	lat, err := queryFloat(r, "lat")
	if err != nil {
		return nil, err
	}
	lng, err := queryFloat(r, "lng")
	if err != nil {
		return nil, err
	}
	if lat == nil || lng == nil {
		return nil, nil
	}
	p := LatLng{Lat: *lat, Lng: *lng}
	if !validLL(p) {
		return nil, httpx.BadRequest("invalid_body", "坐标不合法")
	}
	return &p, nil
}
