package activity

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/anticheat"
)

// SettleCheckin records a venue check-in (场馆签到, docs/api/v2-4-本地生活与商户.md)
// as an activity of sport venue with amount 1 (unit checkin) and settles it
// inside the caller's transaction, so the energy rule, the daily cap and the
// gameplay hooks apply as for any upload. App uploads of sport venue stay
// rejected: check-ins only come through the venue module, which has
// verified the position or the venue's signed QR code.
func (s *Service) SettleCheckin(ctx context.Context, tx pgx.Tx, user int64, at time.Time) (int64, Settlement, func(context.Context), error) {
	var id int64
	if err := tx.QueryRow(ctx, `INSERT INTO src.src_act_loop_activity (user_id, client_id, sport, start_time, end_time, amount)
		VALUES ($1,$2,'venue',$3,$3,1) RETURNING id`, user, uuid.New(), at).Scan(&id); err != nil {
		return 0, Settlement{}, nil, err
	}
	st, after, err := s.settle(ctx, tx, id)
	if err != nil {
		return 0, st, nil, err
	}
	st.Flags = []anticheat.Flag{}
	if err := saveResult(ctx, tx, id, st); err != nil {
		return 0, st, nil, err
	}
	return id, st, after, nil
}
