package social

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/inbox"
	"github.com/keanying/loopland/server/internal/moderation"
	"github.com/keanying/loopland/server/internal/nickname"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Default names restored when a reviewer rejects a name.
func DefaultNickname(id int64) string { return nickname.ForID(id) }

// DefaultCrewName is the crew name restored on rejection.
func DefaultCrewName(id int64) string { return fmt.Sprintf("跑团%d", id) }

func rejected(ctx context.Context, q db.Querier, user int64, what, reason string, data map[string]any) error {
	data["type"] = "review_rejected"
	return inbox.Notify(ctx, q, user, inbox.Interaction, "审核未通过", what+"未通过审核："+reason, data)
}

// Register sets the appliers of the content this package and its
// neighbours own: posts, comments, user nickname / avatar / bio and crew
// name / avatar. Names and avatars are live before review (先生效后审核),
// so approval changes nothing and rejection restores the default.
func Register(m *moderation.Moderator) {
	m.Register(moderation.Post, moderation.Applier{
		Approve: func(ctx context.Context, tx pgx.Tx, id int64) error {
			_, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_post SET review_status='approved', reject_reason=NULL, update_time=now() WHERE id=$1 AND delete_time IS NULL`, id)
			return err
		},
		Reject: func(ctx context.Context, tx pgx.Tx, id int64, reason string) error {
			var author int64
			err := tx.QueryRow(ctx, `UPDATE src.src_soc_loop_post SET review_status='rejected', reject_reason=$2, update_time=now() WHERE id=$1 RETURNING user_id`, id, reason).Scan(&author)
			if db.IsNoRows(err) {
				return nil
			}
			if err != nil {
				return err
			}
			return rejected(ctx, tx, author, "你的动态", reason, map[string]any{"post_id": id})
		},
		Pend: func(ctx context.Context, tx pgx.Tx, id int64) error {
			_, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_post SET review_status='pending', update_time=now() WHERE id=$1 AND review_status='approved'`, id)
			return err
		},
		Mask: maskPost,
		HideEndpoints: func(ctx context.Context, tx pgx.Tx, id int64, radiusM float64) error {
			tag, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_post SET hide_endpoints_m=$2, update_time=now() WHERE id=$1 AND activity_id IS NOT NULL`, id, radiusM)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return httpx.BadRequest("not_supported", "这条动态没有附运动，不能隐藏起终点")
			}
			return nil
		},
	})
	m.Register(moderation.Comment, moderation.Applier{
		Approve: func(ctx context.Context, tx pgx.Tx, id int64) error { return approveComment(ctx, tx, id) },
		Reject: func(ctx context.Context, tx pgx.Tx, id int64, reason string) error {
			if err := hideComment(ctx, tx, id, "rejected", reason, false); err != nil {
				return err
			}
			var author, post int64
			if err := tx.QueryRow(ctx, `SELECT user_id, post_id FROM src.src_soc_loop_comment WHERE id=$1`, id).Scan(&author, &post); err != nil {
				return notFoundOr(err, "评论")
			}
			return rejected(ctx, tx, author, "你的评论", reason, map[string]any{"post_id": post, "comment_id": id})
		},
		Pend: func(ctx context.Context, tx pgx.Tx, id int64) error {
			var st string
			if err := tx.QueryRow(ctx, `SELECT review_status FROM src.src_soc_loop_comment WHERE id=$1`, id).Scan(&st); err != nil {
				return notFoundOr(err, "评论")
			}
			if st != "approved" {
				return nil
			}
			return hideComment(ctx, tx, id, "pending", "", false)
		},
		Mask: func(ctx context.Context, tx pgx.Tx, id int64, mask func(string) string, _ []string) error {
			return maskText(ctx, tx, `SELECT content_text FROM src.src_soc_loop_comment WHERE id=$1`,
				`UPDATE src.src_soc_loop_comment SET content_text=$2, update_time=now() WHERE id=$1`, id, mask)
		},
	})
	m.Register(moderation.Nickname, moderation.Applier{Reject: func(ctx context.Context, tx pgx.Tx, id int64, reason string) error {
		if _, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET nickname=$2 WHERE id=$1`, id, DefaultNickname(id)); err != nil {
			return err
		}
		return rejected(ctx, tx, id, "你的昵称", reason+"，已恢复为默认昵称", map[string]any{"user_id": id, "field": "nickname"})
	}, Mask: func(ctx context.Context, tx pgx.Tx, id int64, mask func(string) string, _ []string) error {
		return maskText(ctx, tx, `SELECT nickname FROM src.src_usr_loop_user WHERE id=$1`, `UPDATE src.src_usr_loop_user SET nickname=$2 WHERE id=$1`, id, mask)
	}})
	clearAvatar := func(ctx context.Context, tx pgx.Tx, id int64, _ func(string) string, _ []string) error {
		_, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET avatar_url=NULL WHERE id=$1`, id)
		return err
	}
	m.Register(moderation.Avatar, moderation.Applier{Reject: func(ctx context.Context, tx pgx.Tx, id int64, reason string) error {
		if _, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET avatar_url=NULL WHERE id=$1`, id); err != nil {
			return err
		}
		return rejected(ctx, tx, id, "你的头像", reason+"，已恢复为默认头像", map[string]any{"user_id": id, "field": "avatar"})
	}, Mask: clearAvatar})
	m.Register(moderation.Bio, moderation.Applier{Reject: func(ctx context.Context, tx pgx.Tx, id int64, reason string) error {
		if _, err := tx.Exec(ctx, `UPDATE src.src_usr_loop_user SET bio=NULL WHERE id=$1`, id); err != nil {
			return err
		}
		return rejected(ctx, tx, id, "你的个人简介", reason+"，已清空", map[string]any{"user_id": id, "field": "bio"})
	}, Mask: func(ctx context.Context, tx pgx.Tx, id int64, mask func(string) string, _ []string) error {
		return maskText(ctx, tx, `SELECT COALESCE(bio, '') FROM src.src_usr_loop_user WHERE id=$1`, `UPDATE src.src_usr_loop_user SET bio=NULLIF($2, '') WHERE id=$1`, id, mask)
	}})
	m.Register(moderation.CrewName, moderation.Applier{Reject: func(ctx context.Context, tx pgx.Tx, id int64, reason string) error {
		leader, err := ResetCrewName(ctx, tx, id)
		if err != nil || leader == 0 {
			return err
		}
		return rejected(ctx, tx, leader, "你的跑团名称", reason+"，已恢复为默认名称", map[string]any{"crew_id": id, "field": "crew_name"})
	}, Mask: func(ctx context.Context, tx pgx.Tx, id int64, mask func(string) string, _ []string) error {
		var name string
		if err := tx.QueryRow(ctx, `SELECT name FROM src.src_soc_loop_crew WHERE id=$1`, id).Scan(&name); err != nil {
			return notFoundOr(err, "跑团")
		}
		masked := mask(name)
		if masked == name {
			return nil
		}
		var taken bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_soc_loop_crew WHERE name=$2 AND id<>$1)`, id, masked).Scan(&taken); err != nil {
			return err
		}
		if taken { // names are unique: fall back to the default
			_, err := ResetCrewName(ctx, tx, id)
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_crew SET name=$2 WHERE id=$1`, id, masked)
		return err
	}})
	m.Register(moderation.CrewAvatar, moderation.Applier{Mask: func(ctx context.Context, tx pgx.Tx, id int64, _ func(string) string, _ []string) error {
		_, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_crew SET avatar_url=NULL WHERE id=$1`, id)
		return err
	}, Reject: func(ctx context.Context, tx pgx.Tx, id int64, reason string) error {
		var leader int64
		err := tx.QueryRow(ctx, `UPDATE src.src_soc_loop_crew SET avatar_url=NULL WHERE id=$1 RETURNING leader_id`, id).Scan(&leader)
		if db.IsNoRows(err) {
			return nil
		}
		if err != nil {
			return err
		}
		return rejected(ctx, tx, leader, "你的跑团头像", reason+"，已恢复为默认头像", map[string]any{"crew_id": id, "field": "crew_avatar"})
	}})
}

// ResetCrewName restores 跑团<id> (names are unique; a taken default gets
// a suffix) and returns the leader (0 when the crew is gone).
func ResetCrewName(ctx context.Context, tx pgx.Tx, id int64) (int64, error) {
	var leader int64
	err := tx.QueryRow(ctx, `UPDATE src.src_soc_loop_crew c SET name = CASE
			WHEN EXISTS (SELECT 1 FROM src.src_soc_loop_crew o WHERE o.name=$2 AND o.id<>$1) THEN $2 || '-' || substr(md5(random()::text), 1, 4)
			ELSE $2 END
		WHERE c.id=$1 RETURNING leader_id`, id, DefaultCrewName(id)).Scan(&leader)
	if db.IsNoRows(err) {
		return 0, nil
	}
	return leader, err
}

// maskText rewrites one text column with mask.
func maskText(ctx context.Context, tx pgx.Tx, sel, upd string, id int64, mask func(string) string) error {
	var text string
	if err := tx.QueryRow(ctx, sel, id).Scan(&text); err != nil {
		return notFoundOr(err, "内容")
	}
	if m := mask(text); m != text {
		_, err := tx.Exec(ctx, upd, id, m)
		return err
	}
	return nil
}

// maskPost masks the text and the attached report and removes the flagged
// images (approve_masked).
func maskPost(ctx context.Context, tx pgx.Tx, id int64, mask func(string) string, drop []string) error {
	var text string
	var report *string
	var raw []byte
	if err := tx.QueryRow(ctx, `SELECT content_text, ai_report_text, images_json FROM src.src_soc_loop_post WHERE id=$1 FOR UPDATE`, id).Scan(&text, &report, &raw); err != nil {
		return notFoundOr(err, "动态")
	}
	var imgs, kept []storedImage
	_ = json.Unmarshal(raw, &imgs)
	for _, im := range imgs {
		if !slices.Contains(drop, im.URL) {
			kept = append(kept, im)
		}
	}
	if kept == nil {
		kept = []storedImage{}
	}
	if report != nil {
		r := mask(*report)
		report = &r
	}
	nj, _ := json.Marshal(kept)
	_, err := tx.Exec(ctx, `UPDATE src.src_soc_loop_post SET content_text=$2, ai_report_text=$3, images_json=$4, update_time=now() WHERE id=$1`, id, mask(text), report, nj)
	return err
}
