package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/activity"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// MaxRegenerate is how often one activity's report may be regenerated.
const MaxRegenerate = 2

// Report is the AIReport object.
type Report struct {
	ActivityID     int64     `json:"activity_id"`
	Text           string    `json:"text"`
	ModelName      string    `json:"model_name"`
	AIGenerated    bool      `json:"ai_generated"`
	GeneratedAt    time.Time `json:"generated_at"`
	RegenerateLeft int       `json:"regenerate_left"`
}

// ErrRegenerateLimit is returned after two regenerations.
var ErrRegenerateLimit = httpx.Conflict("regenerate_limit", "这次运动的战报已经重新生成过 2 次了")

var sportNames = map[string]string{"run": "跑步", "ride": "骑行", "hike": "徒步", "walk": "健走", "strength": "力量训练", "yoga": "瑜伽",
	"rope": "跳绳", "hiit": "HIIT"}

// reportFacts summarises one settled activity for the model (no
// coordinates).
func reportFacts(sport string, distanceM float64, durationS int, amount float64, st activity.Settlement) string {
	var f []string
	name := sportNames[sport]
	if name == "" {
		name = sport
	}
	if distanceM > 0 {
		f = append(f, fmt.Sprintf("%s %.2f 公里，用时 %d 分 %02d 秒", name, distanceM/1000, durationS/60, durationS%60))
		if distanceM >= 100 && durationS > 0 {
			p := int(float64(durationS) / (distanceM / 1000))
			f = append(f, fmt.Sprintf("配速 %d'%02d\"", p/60, p%60))
		}
	} else {
		unit := "分钟"
		if sport == "rope" {
			unit = "次"
		}
		f = append(f, fmt.Sprintf("%s %.0f %s，用时 %d 分钟", name, amount, unit, durationS/60))
	}
	f = append(f, fmt.Sprintf("获得 %d 能量", st.EnergyGranted))
	if n := len(st.Claims); n > 0 {
		var area float64
		for _, c := range st.Claims {
			area += c.AreaM2
		}
		f = append(f, fmt.Sprintf("圈下 %d 块地共 %.0f 平方米", n, area))
	}
	captured := 0
	for _, a := range st.Attacks {
		if a.Captured {
			captured++
		}
	}
	if captured > 0 {
		f = append(f, fmt.Sprintf("抢下 %d 块别人的地", captured))
	}
	for _, b := range st.BossDamage {
		s := fmt.Sprintf("对怪兽「%s」造成 %d 伤害", b.Name, b.Damage)
		if b.Defeated {
			s += "并击败了它"
		}
		f = append(f, s)
	}
	if n := len(st.Chests); n > 0 {
		e := 0
		for _, c := range st.Chests {
			e += c.Energy
		}
		f = append(f, fmt.Sprintf("开了 %d 个宝箱得 %d 能量", n, e))
	}
	if n := len(st.Defended); n > 0 {
		f = append(f, fmt.Sprintf("加固了 %d 块被攻击的地", n))
	}
	for _, t := range st.Tasks {
		if t.Completed {
			f = append(f, "完成赛季任务「"+t.Name+"」")
		}
	}
	if c := st.Companion; c != nil && c.LevelUp {
		f = append(f, fmt.Sprintf("伙伴升到 %d 级", c.Level))
	}
	if st.Rally != nil {
		f = append(f, fmt.Sprintf("参加跑团集结跑，加成 %.0f%%", st.Rally.BonusRate*100))
	}
	for _, r := range st.Races {
		f = append(f, "完成赛事「"+r.Title+"」")
	}
	for _, m := range st.Medals {
		f = append(f, "获得奖牌「"+m.Name+"」")
	}
	return strings.Join(f, "，")
}

// Generate creates or regenerates an activity's report.
func (s *Service) Generate(ctx context.Context, user, activityID int64, regenerate bool) (Report, error) {
	var sport, status string
	var dist, amount float64
	var dur int
	var raw []byte
	err := s.Pool.QueryRow(ctx, `SELECT sport, status, distance_m, duration_sec, amount, result_json FROM src.src_act_loop_activity WHERE id=$1 AND user_id=$2`,
		activityID, user).Scan(&sport, &status, &dist, &dur, &amount, &raw)
	if db.IsNoRows(err) {
		return Report{}, httpx.NotFound("运动记录")
	}
	if err != nil {
		return Report{}, err
	}
	if status != "settled" {
		return Report{}, httpx.BadRequest("invalid_activity", "只能给已完成结算的运动生成战报")
	}
	cur, exists, err := loadReport(ctx, s.Pool, activityID)
	if err != nil {
		return Report{}, err
	}
	if exists && !regenerate {
		return cur, nil
	}
	if exists && cur.RegenerateLeft <= 0 {
		return Report{}, ErrRegenerateLimit
	}
	b, err := s.Backend()
	if err != nil {
		return Report{}, err
	}
	var st activity.Settlement
	_ = json.Unmarshal(raw, &st)
	facts := reportFacts(sport, dist, dur, amount, st)
	maxChars := s.Config.For(user).AI.ReportMaxChars
	resp, err := s.Call(ctx, b, FeatureReport, user, Request{Model: b.SmallModel, MaxTokens: maxChars * 2, Messages: []Message{
		{Role: "system", Content: fmt.Sprintf(promptReport, maxChars)},
		{Role: "user", Content: "这次运动的数据。事实：" + facts},
	}}, nil)
	if err != nil {
		return Report{}, httpx.E(http.StatusServiceUnavailable, "ai_unavailable", "战报生成失败，请稍后再试")
	}
	text := strings.TrimSpace(resp.Content)
	if text == "" || (s.Mod != nil && s.Mod.Check(ctx, text, false).Blocked) {
		text = "这次运动的成绩：" + facts + "。"
	}
	if r := []rune(text); len(r) > maxChars {
		text = string(r[:maxChars-1]) + "…"
	}
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO src.src_act_loop_ai_report (activity_id, user_id, report_text, model_name) VALUES ($1,$2,$3,$4)
			ON CONFLICT (activity_id) DO UPDATE SET report_text=EXCLUDED.report_text, model_name=EXCLUDED.model_name,
				regenerate_qty=src_act_loop_ai_report.regenerate_qty+1, generate_time=now(), update_time=now()`, activityID, user, text, b.ModelName)
		return err
	})
	if err != nil {
		return Report{}, err
	}
	out, _, err := loadReport(ctx, s.Pool, activityID)
	return out, err
}

func loadReport(ctx context.Context, q db.Querier, activityID int64) (Report, bool, error) {
	r := Report{ActivityID: activityID, AIGenerated: true}
	var n int
	err := q.QueryRow(ctx, `SELECT report_text, model_name, generate_time, regenerate_qty FROM src.src_act_loop_ai_report WHERE activity_id=$1`, activityID).
		Scan(&r.Text, &r.ModelName, &r.GeneratedAt, &n)
	if db.IsNoRows(err) {
		return r, false, nil
	}
	r.RegenerateLeft = max(0, MaxRegenerate-n)
	return r, err == nil, err
}

func (h *Handler) report(w http.ResponseWriter, r *http.Request) error {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		return err
	}
	regen := false
	switch r.URL.Query().Get("regenerate") {
	case "", "0", "false":
	case "1", "true":
		regen = true
	default:
		return httpx.BadRequest("invalid_body", "regenerate 只能是 0 或 1")
	}
	rep, err := h.Svc.Generate(r.Context(), httpx.UserID(r.Context()), id, regen)
	if err != nil {
		return err
	}
	return httpx.OK(w, rep)
}

func (h *Handler) workouts(w http.ResponseWriter, r *http.Request) error {
	return httpx.OK(w, httpx.NewItems(h.Svc.Config.For(httpx.UserID(r.Context())).Workouts))
}
