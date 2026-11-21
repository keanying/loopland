package perks

import (
	"context"

	"github.com/keanying/loopland/server/internal/venue"
)

// The perks service plugs into the venue module (part A): the 据点 coupon of
// a check-in (IssueStronghold) and the drop / redemption numbers on merchants.
var (
	_ venue.CouponIssuer   = (*Service)(nil)
	_ venue.MerchantExtras = (*Service)(nil)
)

// MerchantCounts implements venue.MerchantExtras: drops and today's valid
// redemptions per merchant.
func (s *Service) MerchantCounts(ctx context.Context, merchantIDs []int64) (map[int64]venue.MerchantCounts, error) {
	out := make(map[int64]venue.MerchantCounts, len(merchantIDs))
	rows, err := s.Pool.Query(ctx, `SELECT m.id,
			(SELECT count(*) FROM src.src_mer_loop_drop d WHERE d.merchant_id=m.id)::int,
			(SELECT count(*) FROM src.src_mer_loop_redemption r WHERE r.merchant_id=m.id AND r.redeem_date=`+todaySQL+` AND r.redemption_status='valid')::int
		FROM unnest($1::bigint[]) AS m(id)`, merchantIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var c venue.MerchantCounts
		if err := rows.Scan(&id, &c.Drops, &c.TodayRedemptions); err != nil {
			return nil, err
		}
		out[id] = c
	}
	return out, rows.Err()
}

// MerchantDrops implements venue.MerchantExtras: the merchant's drops.
func (s *Service) MerchantDrops(ctx context.Context, merchantID int64) (any, error) {
	return DropsOfMerchant(ctx, s.Pool, merchantID)
}
