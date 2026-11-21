// Package media stores user uploads (图片上传, docs/api/v2-2-社区.md) and
// resolves upload ids. Other modules only reference media by id through
// Owned, which also checks that the caller uploaded it.
package media

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Image is an uploaded image as returned to the app.
type Image struct {
	ID     int64  `json:"id"`
	URL    string `json:"url"`
	Width  *int   `json:"width"`
	Height *int   `json:"height"`
}

// ErrInvalid is returned for ids that don't exist or belong to someone else.
var ErrInvalid = httpx.BadRequest("invalid_media", "图片无效，请重新上传")

// Owned loads images by id, in the given order, checking they were
// uploaded by user (any purpose).
func Owned(ctx context.Context, q db.Querier, user int64, ids []int64) ([]Image, error) {
	out := make([]Image, 0, len(ids))
	for _, id := range ids {
		var im Image
		err := q.QueryRow(ctx, `SELECT id, url, width_px, height_px FROM src.src_cnt_loop_media WHERE id=$1 AND user_id=$2`, id, user).
			Scan(&im.ID, &im.URL, &im.Width, &im.Height)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrInvalid
		}
		if err != nil {
			return nil, err
		}
		out = append(out, im)
	}
	return out, nil
}

// OwnedURL finds one of the user's uploads by its url (for clients that
// still send avatar_url instead of avatar_id).
func OwnedURL(ctx context.Context, q db.Querier, user int64, url string) (Image, error) {
	var im Image
	err := q.QueryRow(ctx, `SELECT id, url, width_px, height_px FROM src.src_cnt_loop_media WHERE url=$1 AND user_id=$2 ORDER BY id DESC LIMIT 1`, url, user).
		Scan(&im.ID, &im.URL, &im.Width, &im.Height)
	if errors.Is(err, pgx.ErrNoRows) {
		return im, ErrInvalid
	}
	return im, err
}
