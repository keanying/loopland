package social

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

var (
	reportTargets = map[string]bool{"post": true, "comment": true, "user": true, "crew": true, "message": true}
	reportReasons = map[string]bool{"spam": true, "porn": true, "abuse": true, "fraud": true, "illegal": true, "other": true}
)

func (h *Handler) report(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		TargetType string `json:"target_type"`
		TargetID   int64  `json:"target_id"`
		Reason     string `json:"reason"`
		Detail     string `json:"detail"`
	}
	if err := httpx.Decode(r, &req); err != nil {
		return err
	}
	if !reportTargets[req.TargetType] || req.TargetID <= 0 {
		return httpx.BadRequest("invalid_target", "举报对象错误")
	}
	if !reportReasons[req.Reason] {
		return httpx.BadRequest("invalid_body", "reason 取值错误")
	}
	req.Detail = strings.TrimSpace(req.Detail)
	if utf8.RuneCountInString(req.Detail) > 200 {
		return httpx.BadRequest("invalid_body", "补充说明最多 200 字")
	}
	ctx := r.Context()
	uid := httpx.UserID(ctx)
	s := h.Svc
	var id int64
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		owner, err := targetOwner(ctx, tx, req.TargetType, req.TargetID)
		if err != nil {
			return err
		}
		if owner == uid && owner != 0 {
			return httpx.BadRequest("invalid_target", "不能举报自己")
		}
		var detail *string
		if req.Detail != "" {
			detail = &req.Detail
		}
		err = tx.QueryRow(ctx, `INSERT INTO src.src_cnt_loop_report (reporter_id, target_type, target_id, reason_type, detail_text)
			VALUES ($1,$2,$3,$4,$5) ON CONFLICT (reporter_id, target_type, target_id) DO NOTHING RETURNING id`,
			uid, req.TargetType, req.TargetID, req.Reason, detail).Scan(&id)
		if db.IsNoRows(err) { // reported before: same id
			return tx.QueryRow(ctx, `SELECT id FROM src.src_cnt_loop_report WHERE reporter_id=$1 AND target_type=$2 AND target_id=$3`,
				uid, req.TargetType, req.TargetID).Scan(&id)
		}
		if err != nil {
			return err
		}
		if req.TargetType == "post" || req.TargetType == "comment" {
			return s.reported(ctx, tx, req.TargetType, req.TargetID, owner)
		}
		return nil
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, map[string]int64{"id": id})
}

// targetOwner checks the reported object exists and returns its author
// (0 when unknown: messages belong to package community).
func targetOwner(ctx context.Context, q db.Querier, typ string, id int64) (int64, error) {
	var sql, what string
	switch typ {
	case "post":
		sql, what = `SELECT user_id FROM src.src_soc_loop_post WHERE id=$1 AND delete_time IS NULL`, "动态"
	case "comment":
		sql, what = `SELECT user_id FROM src.src_soc_loop_comment WHERE id=$1 AND delete_time IS NULL`, "评论"
	case "user":
		sql, what = `SELECT id FROM src.src_usr_loop_user WHERE id=$1 AND status <> 'deleted'`, "用户"
	case "crew":
		sql, what = `SELECT leader_id FROM src.src_soc_loop_crew WHERE id=$1`, "跑团"
	default:
		return 0, nil
	}
	var owner int64
	err := q.QueryRow(ctx, sql, id).Scan(&owner)
	return owner, notFoundOr(err, what)
}

// reported updates the report counter of a post or comment and, once
// report_auto_hide distinct users reported it, takes it back to pending
// review (the review task carries the report count).
func (s *Service) reported(ctx context.Context, tx pgx.Tx, typ string, id, author int64) error {
	table := "src.src_soc_loop_post"
	if typ == "comment" {
		table = "src.src_soc_loop_comment"
	}
	var n int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM src.src_cnt_loop_report WHERE target_type=$1 AND target_id=$2`, typ, id).Scan(&n); err != nil {
		return err
	}
	var status, text string
	var images []byte
	imagesSQL := `'[]'::jsonb`
	if typ == "post" {
		imagesSQL = `images_json`
	}
	if err := tx.QueryRow(ctx, `UPDATE `+table+` SET report_qty=$2 WHERE id=$1 RETURNING review_status, content_text, `+imagesSQL, id, n).Scan(&status, &text, &images); err != nil {
		return err
	}
	switch {
	case status == "pending":
		// Already waiting for a reviewer: just show the report count.
	case status == "approved" && n >= s.Mod.Settings(ctx).ReportAutoHide:
		if typ == "post" {
			if _, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_post SET review_status='pending', update_time=now() WHERE id=$1`, id); err != nil {
				return err
			}
		} else if err := hideComment(ctx, tx, id, "pending", "", false); err != nil {
			return err
		}
	default:
		return nil
	}
	if err := moderation.Reported(ctx, tx, typ, id, author, text, n); err != nil {
		return err
	}
	var imgs []storedImage
	_ = json.Unmarshal(images, &imgs)
	if len(imgs) == 0 {
		return nil
	}
	urls := make([]string, len(imgs))
	for i, im := range imgs {
		urls[i] = im.URL
	}
	raw, _ := json.Marshal(urls)
	_, err := tx.Exec(ctx, `UPDATE src.src_cnt_loop_review_task SET images_json=$3
		WHERE target_type=$1 AND target_id=$2 AND review_status='pending' AND images_json='[]'::jsonb`, typ, id, raw)
	return err
}
