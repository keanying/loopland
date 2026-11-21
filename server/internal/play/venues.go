package play

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/territory"
)

// VenuePin is a venue (据点) on the map with this week's owner
// (docs/api/v2-4-本地生活与商户.md «地图»).
type VenuePin struct {
	ID             int64    `json:"id"`
	Name           string   `json:"name"`
	Center         LatLng   `json:"center"`
	Sports         []string `json:"sports"`
	OwnerAvatarURL *string  `json:"owner_avatar_url"`
	OwnerNickname  *string  `json:"owner_nickname"`
	Bookable       bool     `json:"bookable"`
}

// venuePins lists the enabled venues in the viewport.
func (s *Service) venuePins(ctx context.Context, b territory.BBox) ([]VenuePin, error) {
	rows, err := s.Pool.Query(ctx, `SELECT v.id, v.venue_name, ST_Y(v.center_geom), ST_X(v.center_geom), v.sports,
			CASE WHEN u.status='deleted' THEN NULL ELSE u.avatar_url END, CASE WHEN u.status='deleted' THEN '已注销用户' ELSE u.nickname END,
			v.is_bookable AND m.merchant_status IS NOT DISTINCT FROM 'partner'
		FROM src.src_mer_loop_venue v LEFT JOIN src.src_mer_loop_merchant m ON m.id=v.merchant_id
		LEFT JOIN src.src_mer_loop_venue_owner o ON o.venue_id=v.id AND o.week_start_date=$5
		LEFT JOIN src.src_usr_loop_user u ON u.id=o.user_id
		WHERE NOT v.is_disabled AND v.center_geom && `+env+` ORDER BY v.id LIMIT 300`, b[0], b[1], b[2], b[3], weekStart(time.Now()))
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (VenuePin, error) {
		var v VenuePin
		return v, r.Scan(&v.ID, &v.Name, &v.Center.Lat, &v.Center.Lng, &v.Sports, &v.OwnerAvatarURL, &v.OwnerNickname, &v.Bookable)
	})
	if out == nil {
		out = []VenuePin{}
	}
	return out, err
}
