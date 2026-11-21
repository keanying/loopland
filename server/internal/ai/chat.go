package ai

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/media"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// MaxToolRounds bounds the server-side tool loop.
const MaxToolRounds = 3

// ChatRateLimit is the per-user limit of questions per minute.
const ChatRateLimit = 6

// Errors.
var (
	ErrQuota            = httpx.E(http.StatusTooManyRequests, "ai_quota_exceeded", "本周免费次数已用完，开通会员不限次数")
	ErrImageUnsupported = httpx.BadRequest("ai_image_unsupported", "当前 AI 模型不支持图片")
)

// RunTools is the server-side tool loop: the model may call tools for up
// to maxRounds rounds; after that it must answer (tool_choice none). Text
// deltas of every round are streamed to onDelta, cards produced by tools
// to onCard. The returned response carries the whole streamed text and
// the summed usage.
func RunTools(ctx context.Context, call func(context.Context, Request, func(string)) (Response, error), req Request, ts *Toolset,
	maxRounds int, onDelta func(string), onCard func(Card)) (Response, []Card, error) {
	var total Usage
	var text strings.Builder
	var cards []Card
	deltas := func(d string) {
		text.WriteString(d)
		if onDelta != nil {
			onDelta(d)
		}
	}
	msgs := append([]Message{}, req.Messages...)
	for round := 0; ; round++ {
		r := req
		r.Messages = msgs
		if ts == nil || len(ts.Defs) == 0 {
			r.Tools = nil
		} else {
			r.Tools = ts.Defs
			if round >= maxRounds {
				r.ToolChoice = "none"
			}
		}
		resp, err := call(ctx, r, deltas)
		total.PromptTokens += resp.Usage.PromptTokens
		total.CompletionTokens += resp.Usage.CompletionTokens
		if err != nil {
			return Response{Usage: total}, cards, err
		}
		if len(resp.ToolCalls) == 0 || r.Tools == nil || r.ToolChoice == "none" {
			resp.Content, resp.Usage, resp.ToolCalls = text.String(), total, nil
			return resp, cards, nil
		}
		msgs = append(msgs, Message{Role: "assistant", Content: resp.Content, ToolCalls: resp.ToolCalls})
		for _, tc := range resp.ToolCalls {
			var result any
			fn, ok := ts.Fns[tc.Function.Name]
			if !ok {
				result = map[string]string{"error": "没有这个工具：" + tc.Function.Name}
			} else {
				args := json.RawMessage(tc.Function.Arguments)
				if !json.Valid(args) {
					args = json.RawMessage(`{}`)
				}
				res, cs, err := fn(ctx, args)
				if err != nil {
					if ctx.Err() != nil {
						return Response{Usage: total}, cards, ctx.Err()
					}
					res = map[string]string{"error": "查询失败，请稍后再试"}
				}
				result = res
				for _, c := range cs {
					cards = append(cards, c)
					if onCard != nil {
						onCard(c)
					}
				}
			}
			raw, _ := json.Marshal(result)
			msgs = append(msgs, Message{Role: "tool", ToolCallID: tc.ID, Name: tc.Function.Name, Content: string(raw)})
		}
	}
}

// ---------------------------------------------------------------- messages

// AIMessage is a stored assistant conversation message.
type AIMessage struct {
	ID          int64     `json:"id"`
	Role        string    `json:"role"`
	Content     string    `json:"content"`
	ImageURL    *string   `json:"image_url"`
	Cards       []Card    `json:"cards"`
	AIGenerated bool      `json:"ai_generated"`
	CreatedAt   time.Time `json:"created_at"`
}

const messageCols = `id, role_type, content_text, image_url, cards_json, create_time`

func scanMessage(r pgx.CollectableRow) (AIMessage, error) {
	var m AIMessage
	var cards []byte
	if err := r.Scan(&m.ID, &m.Role, &m.Content, &m.ImageURL, &cards, &m.CreatedAt); err != nil {
		return m, err
	}
	_ = json.Unmarshal(cards, &m.Cards)
	if m.Cards == nil {
		m.Cards = []Card{}
	}
	m.AIGenerated = m.Role == "assistant"
	return m, nil
}

// Messages lists a user's messages newest first; deleted=true includes
// the ones the user cleared (admin).
func (s *Service) Messages(ctx context.Context, user, before int64, limit, offset int, deleted bool) ([]AIMessage, error) {
	rows, err := s.Pool.Query(ctx, `SELECT `+messageCols+` FROM src.src_msg_loop_ai_message
		WHERE user_id=$1 AND ($2::bigint = 0 OR id < $2) AND ($3 OR delete_time IS NULL) ORDER BY id DESC LIMIT $4 OFFSET $5`,
		user, before, deleted, limit, offset)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, scanMessage)
	if out == nil {
		out = []AIMessage{}
	}
	return out, err
}

func (h *Handler) messages(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	limit := 30
	if n, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && n > 0 {
		limit = min(n, 50)
	}
	var before int64
	if v := r.URL.Query().Get("before"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n <= 0 {
			return httpx.BadRequest("invalid_cursor", "before 无法识别")
		}
		before = n
	}
	items, err := h.Svc.Messages(ctx, httpx.UserID(ctx), before, limit+1, 0, false)
	if err != nil {
		return err
	}
	var next *string
	if len(items) > limit {
		items = items[:limit]
		c := strconv.FormatInt(items[limit-1].ID, 10)
		next = &c
	}
	return httpx.OK(w, map[string]any{"items": items, "next_cursor": next})
}

func (h *Handler) clear(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	if _, err := h.Svc.Pool.Exec(ctx, `UPDATE src.src_msg_loop_ai_message SET delete_time=now() WHERE user_id=$1 AND delete_time IS NULL`, httpx.UserID(ctx)); err != nil {
		return err
	}
	return httpx.OK(w, httpx.Empty)
}

// ---------------------------------------------------------------- greeting

func (h *Handler) greeting(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	p, err := point(r)
	if err != nil {
		return err
	}
	st, err := h.Svc.myStatus(ctx, uid)
	if err != nil {
		return err
	}
	hour := clock.Now().In(clock.Shanghai).Hour()
	hello := "晚上好"
	switch {
	case hour < 5:
		hello = "夜深了"
	case hour < 11:
		hello = "早上好"
	case hour < 13:
		hello = "中午好"
	case hour < 18:
		hello = "下午好"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%s%s！", hello, st.Nickname)
	if st.TodayEnergy > 0 {
		fmt.Fprintf(&b, "今天你已经拿了 %d 能量", st.TodayEnergy)
	} else {
		b.WriteString("今天还没运动，出去圈一圈吧")
	}
	if st.Crew != nil {
		if st.CrewWeekRank != nil {
			fmt.Fprintf(&b, "，在「%s」本周排第 %d", *st.Crew, *st.CrewWeekRank)
		} else {
			fmt.Fprintf(&b, "，「%s」等你一起跑", *st.Crew)
		}
	}
	b.WriteString("。")
	if p != nil {
		if bosses, err := h.Svc.bossCandidates(ctx, *p, 5000); err == nil && len(bosses) > 0 {
			fmt.Fprintf(&b, "附近 %.1f 公里有「%s」出没，还剩 %d 血。", bosses[0].DistanceM/1000, bosses[0].Name, bosses[0].HP)
		}
	}
	if len(st.RecentAttacks) > 0 {
		fmt.Fprintf(&b, "你的「%v」%v，要去看看吗？", st.RecentAttacks[0]["name"], st.RecentAttacks[0]["what"])
	}
	return httpx.OK(w, map[string]any{"text": b.String(), "suggestions": []string{"规划圈地路线", "今晚去哪抢地", "生成今日战报", "帮我排一周计划"},
		"ai_generated": false})
}

// ---------------------------------------------------------------- chat

type chatRequest struct {
	Content string `json:"content"`
	ImageID *int64 `json:"image_id"`
	Context *struct {
		Type string `json:"type"`
		ID   int64  `json:"id"`
	} `json:"context"`
	Lat *float64 `json:"lat"`
	Lng *float64 `json:"lng"`
}

// ChatResult is the final payload (done event / JSON body).
type ChatResult struct {
	Message     AIMessage `json:"message"`
	UserMessage AIMessage `json:"user_message"`
	Quota       Quota     `json:"quota"`
}

// sseWriter writes server-sent events and flushes each one.
type sseWriter struct {
	mu sync.Mutex
	w  http.ResponseWriter
	rc *http.ResponseController
}

func (s *sseWriter) send(event string, data any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, _ := json.Marshal(data)
	fmt.Fprintf(s.w, "event: %s\ndata: %s\n\n", event, raw)
	_ = s.rc.Flush()
}

func (h *Handler) chat(w http.ResponseWriter, r *http.Request) error {
	var req chatRequest
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	s := h.Svc
	req.Content = strings.TrimSpace(req.Content)
	if n := utf8.RuneCountInString(req.Content); n < 1 || n > 500 {
		return httpx.BadRequest("invalid_content", "问题 1–500 字")
	}
	var reqPos *LatLng
	if req.Lat != nil && req.Lng != nil {
		p := LatLng{Lat: *req.Lat, Lng: *req.Lng}
		if !validLL(p) {
			return httpx.BadRequest("invalid_body", "坐标不合法")
		}
		reqPos = &p
	}
	b, err := s.Backend()
	if err != nil {
		return err
	}
	// Image (vision model only).
	var img *chatImage
	if req.ImageID != nil {
		if !b.Vision() {
			return ErrImageUnsupported
		}
		if img, err = s.loadImage(ctx, uid, *req.ImageID); err != nil {
			return err
		}
	}
	// Context object (问 AI).
	var tc *TerritoryCard
	var bc *BossCard
	var ctxCenter *LatLng
	if req.Context != nil {
		switch req.Context.Type {
		case "territory":
			tc, err = s.territoryCard(ctx, req.Context.ID)
			if err == nil && tc == nil {
				err = httpx.NotFound("领地")
			}
			if tc != nil {
				ctxCenter = &tc.Center
			}
		case "boss":
			bc, err = s.bossCard(ctx, req.Context.ID)
			if err == nil && bc == nil {
				err = httpx.NotFound("怪兽")
			}
			if bc != nil {
				ctxCenter = &bc.Center
			}
		default:
			err = httpx.BadRequest("invalid_body", "context.type 只能是 territory 或 boss")
		}
		if err != nil {
			return err
		}
	}
	if s.Mod != nil && s.Mod.Check(ctx, req.Content, false).Blocked {
		return moderation.ErrBlocked
	}
	// Rate limit, one answer at a time, weekly quota.
	if s.Redis != nil {
		key := fmt.Sprintf("ai:chat:rate:%d:%d", uid, time.Now().Unix()/60)
		n, err := s.Redis.Incr(ctx, key).Result()
		if err == nil {
			s.Redis.Expire(ctx, key, 70*time.Second)
			if n > ChatRateLimit {
				return httpx.ErrRateLimited
			}
		}
		lock := fmt.Sprintf("ai:chat:busy:%d", uid)
		if ok, err := s.Redis.SetNX(ctx, lock, 1, 2*time.Minute).Result(); err == nil {
			if !ok {
				return httpx.E(http.StatusTooManyRequests, "rate_limited", "上一个问题还在回答中")
			}
			defer s.Redis.Del(context.WithoutCancel(ctx), lock)
		}
	}
	quota, err := s.QuotaOf(ctx, uid, b.WeeklyFree)
	if err != nil {
		return err
	}
	if !quota.Unlimited && *quota.Remaining <= 0 {
		return ErrQuota
	}

	msgs, err := s.chatMessages(ctx, uid, b, req, img, tc, bc, reqPos)
	if err != nil {
		return err
	}
	model := b.ChatModel
	var ts *Toolset
	if img != nil {
		model = b.VisionModel
	} else {
		ts = s.tools(uid, s.position(ctx, uid, reqPos, ctxCenter))
	}

	stream := strings.Contains(r.Header.Get("Accept"), "text/event-stream")
	var sw *sseWriter
	var onDelta func(string)
	var onCard func(Card)
	// Output safety: stop streaming as soon as the text hits a block word.
	var shown strings.Builder
	blocked := false
	if stream {
		rc := http.NewResponseController(w)
		_ = rc.SetWriteDeadline(time.Now().Add(b.Timeout*(MaxToolRounds+1) + 30*time.Second))
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("X-Accel-Buffering", "no")
		w.WriteHeader(http.StatusOK)
		_ = rc.Flush()
		sw = &sseWriter{w: w, rc: rc}
		onDelta = func(d string) {
			if blocked {
				return
			}
			shown.WriteString(d)
			if s.Mod != nil && s.Mod.Check(ctx, shown.String(), false).Blocked {
				blocked = true
				return
			}
			sw.send("delta", map[string]string{"text": d})
		}
		onCard = func(c Card) { sw.send("card", c) }
	}
	call := func(ctx context.Context, r Request, d func(string)) (Response, error) {
		return s.Call(ctx, b, FeatureChat, uid, r, d)
	}
	if onDelta == nil {
		onDelta = func(string) {} // still accumulate per round
	}
	resp, cards, err := RunTools(ctx, call, Request{Model: model, Messages: msgs, MaxTokens: 800}, ts, MaxToolRounds, onDelta, onCard)
	if err == nil && strings.TrimSpace(resp.Content) == "" {
		err = errors.New("empty answer")
	}
	if err != nil {
		if ctx.Err() != nil && !errors.Is(err, context.DeadlineExceeded) {
			return nil // client went away
		}
		if s.Log != nil {
			s.Log.Warn("ai chat failed", "user", uid, "err", err)
		}
		e := httpx.E(http.StatusServiceUnavailable, "ai_unavailable", "圈圈开小差了，请稍后再试（本次不扣次数）")
		if sw != nil {
			sw.send("error", map[string]string{"code": e.Code, "message": e.Message})
			return nil
		}
		return e
	}
	answer := strings.TrimSpace(resp.Content)
	outBlocked := blocked || (s.Mod != nil && s.Mod.Check(ctx, answer, false).Blocked)
	if outBlocked {
		answer, cards = BlockedReply, nil
	}
	if cards == nil {
		cards = []Card{}
	}
	res, err := s.saveChat(ctx, uid, req, img, answer, cards, b, resp.Usage, !quota.Unlimited, outBlocked)
	if err != nil {
		if sw != nil {
			sw.send("error", map[string]string{"code": "internal", "message": "服务器开小差了，请稍后再试"})
			return nil
		}
		return err
	}
	if sw != nil {
		sw.send("done", res)
		return nil
	}
	return httpx.OK(w, res)
}

type chatImage struct {
	id  int64
	url string // as stored (shown to the user)
	src string // sent to the model (url or data URL)
}

// loadImage checks ownership and prepares the model URL: local uploads
// (dev) become data URLs, OSS uploads are sent by URL.
func (s *Service) loadImage(ctx context.Context, uid, id int64) (*chatImage, error) {
	if _, err := media.Owned(ctx, s.Pool, uid, []int64{id}); err != nil {
		return nil, err
	}
	var url, storage, key, ct string
	if err := s.Pool.QueryRow(ctx, `SELECT url, storage_type, object_key, content_type FROM src.src_cnt_loop_media WHERE id=$1`, id).Scan(&url, &storage, &key, &ct); err != nil {
		return nil, err
	}
	return &chatImage{id: id, url: url, src: s.imageSource(url, storage, key, ct)}, nil
}

// imageSource is the URL the model can open.
func (s *Service) imageSource(url, storage, key, ct string) string {
	if storage != "local" || s.MediaDir == "" {
		return url
	}
	b, err := os.ReadFile(filepath.Join(s.MediaDir, filepath.FromSlash(key)))
	if err != nil {
		return url
	}
	return "data:" + ct + ";base64," + base64.StdEncoding.EncodeToString(b)
}

// chatMessages is the system prompt, the recent history and the question.
func (s *Service) chatMessages(ctx context.Context, uid int64, b *Backend, req chatRequest, img *chatImage, tc *TerritoryCard, bc *BossCard, pos *LatLng) ([]Message, error) {
	cfg := s.Config.For(uid)
	var nick string
	if err := s.Pool.QueryRow(ctx, `SELECT nickname FROM src.src_usr_loop_user WHERE id=$1`, uid).Scan(&nick); err != nil {
		return nil, err
	}
	sys := promptAssistant
	if img != nil {
		sys = promptVision
	}
	sys += fmt.Sprintf("\n当前时间：%s（北京时间）。用户昵称：%s。", clock.Now().In(clock.Shanghai).Format("2006-01-02 15:04 Monday"), nick)
	if pos != nil {
		sys += "用户提供了当前位置。"
	}
	if d := describeContext(tc, bc); d != "" {
		sys += d
	}
	msgs := []Message{{Role: "system", Content: sys}}
	if n := cfg.AI.ChatHistoryTurns; n > 0 {
		hist, err := s.Messages(ctx, uid, 0, n*2, 0, false)
		if err != nil {
			return nil, err
		}
		for i := len(hist) - 1; i >= 0; i-- {
			m := hist[i]
			txt := m.Content
			if m.ImageURL != nil {
				txt = "[图片] " + txt
			}
			msgs = append(msgs, Message{Role: m.Role, Content: txt})
		}
		// The history must start with a question.
		for len(msgs) > 1 && msgs[1].Role != "user" {
			msgs = append(msgs[:1], msgs[2:]...)
		}
	}
	if img != nil {
		msgs = append(msgs, Message{Role: "user", Content: []Part{{Type: "text", Text: req.Content}, {Type: "image_url", ImageURL: &ImageURL{URL: img.src}}}})
	} else {
		msgs = append(msgs, Message{Role: "user", Content: req.Content})
	}
	return msgs, nil
}

func (s *Service) saveChat(ctx context.Context, uid int64, req chatRequest, img *chatImage, answer string, cards []Card, b *Backend, u Usage,
	counted, blocked bool) (ChatResult, error) {
	var res ChatResult
	ctx = context.WithoutCancel(ctx)
	var ctxType *string
	var ctxID *int64
	if req.Context != nil {
		ctxType, ctxID = &req.Context.Type, &req.Context.ID
	}
	var imgID *int64
	var imgURL *string
	if img != nil {
		imgID, imgURL = &img.id, &img.url
	}
	cj, _ := json.Marshal(cards)
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var uidMsg, aidMsg int64
		if err := tx.QueryRow(ctx, `INSERT INTO src.src_msg_loop_ai_message (user_id, role_type, content_text, image_id, image_url, context_type, context_id)
			VALUES ($1,'user',$2,$3,$4,$5,$6) RETURNING id`, uid, req.Content, imgID, imgURL, ctxType, ctxID).Scan(&uidMsg); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `INSERT INTO src.src_msg_loop_ai_message (user_id, role_type, content_text, cards_json, context_type, context_id, model_name,
				prompt_token_qty, completion_token_qty, is_quota_counted, is_output_blocked)
			VALUES ($1,'assistant',$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING id`, uid, answer, cj, ctxType, ctxID, b.ModelName,
			u.PromptTokens, u.CompletionTokens, counted, blocked).Scan(&aidMsg); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT `+messageCols+` FROM src.src_msg_loop_ai_message WHERE id = ANY($1) ORDER BY id`, []int64{uidMsg, aidMsg})
		if err != nil {
			return err
		}
		ms, err := pgx.CollectRows(rows, scanMessage)
		if err != nil {
			return err
		}
		res.UserMessage, res.Message = ms[0], ms[1]
		return nil
	})
	if err != nil {
		return res, err
	}
	res.Quota, err = s.QuotaOf(ctx, uid, b.WeeklyFree)
	return res, err
}

// UsersHitLimit counts users who used up the free quota this week.
func (s *Service) UsersHitLimit(ctx context.Context, q db.Querier, weeklyFree int) (int, error) {
	var n int
	if weeklyFree <= 0 {
		weeklyFree = 1
	}
	err := q.QueryRow(ctx, `SELECT count(*) FROM (SELECT user_id FROM src.src_msg_loop_ai_message WHERE is_quota_counted AND create_time >= $1
		GROUP BY user_id HAVING count(*) >= $2) x`, WeekStart(clock.Now()), weeklyFree).Scan(&n)
	return n, err
}
