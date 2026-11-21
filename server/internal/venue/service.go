// Package venue is V2 batch 4 「本地生活与商户」 part A
// (docs/api/v2-4-本地生活与商户.md): merchants and their staff accounts,
// venues, venue check-ins (定位或扫码，生成 venue 运动记录走能量结算), weekly
// venue owners (馆主), slot booking with the owner discount, and the booking
// payment fulfilment for billing.
package venue

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"log/slog"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/activity"
	"github.com/keanying/loopland/server/internal/billing"
	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/secure"
)

// CouponIssuer is the perks module's 据点 step of a check-in: it issues the
// coupon of the venue's active stronghold drop, if any, inside the check-in
// transaction. A nil coupon means none.
type CouponIssuer interface {
	IssueStronghold(ctx context.Context, tx pgx.Tx, userID, venueID int64) (coupon any, err error)
}

// MerchantCounts are the perks numbers shown on a merchant.
type MerchantCounts struct {
	Drops            int
	TodayRedemptions int
}

// MerchantExtras is implemented by the perks module: drop and redemption
// numbers of merchants, and a merchant's drops for its detail page.
type MerchantExtras interface {
	MerchantCounts(ctx context.Context, merchantIDs []int64) (map[int64]MerchantCounts, error)
	MerchantDrops(ctx context.Context, merchantID int64) (any, error)
}

// Service implements the venue, merchant and booking endpoints.
type Service struct {
	Pool       *pgxpool.Pool
	Config     *gameplay.Store
	Box        *secure.Box
	Billing    *billing.Service
	Activities *activity.Service
	Log        *slog.Logger
	// QRKey signs venue QR codes (DeriveQRKey of the server data key).
	QRKey []byte
	// LinkBase is the public base of the venue universal link
	// (https://<domain>/v/<payload>).
	LinkBase string
	// Coupons and Extras are optional (perks module).
	Coupons CouponIssuer
	Extras  MerchantExtras
}

// DeriveQRKey derives the venue QR signing key from the data key, so the
// key itself never leaves the server and is not reused verbatim.
func DeriveQRKey(dataKey []byte) []byte {
	m := hmac.New(sha256.New, dataKey)
	m.Write([]byte("loopland/venue-qr"))
	return m.Sum(nil)
}

// Sports are the venue sport categories.
var Sports = map[string]bool{"basketball": true, "football": true, "badminton": true, "pickleball": true,
	"tennis": true, "swimming": true, "climbing": true, "gym": true}

// Ref is {id, name}.
type Ref struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// LatLng is a GCJ-02 point.
type LatLng struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

func (p LatLng) valid() bool {
	return p.Lat >= -90 && p.Lat <= 90 && p.Lng >= -180 && p.Lng <= 180 && !(p.Lat == 0 && p.Lng == 0)
}

// weekStart is Monday (Shanghai) of the week containing day d.
func weekStart(d time.Time) time.Time {
	d = clock.Day(d)
	return d.AddDate(0, 0, -((int(d.Weekday()) + 6) % 7))
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// Jobs returns the periodic jobs: weekly owners, booking expiry and
// completion, and the refund retry of non-membership orders.
func (s *Service) Jobs() map[string]func(context.Context) error {
	return map[string]func(context.Context) error{
		"venue_owners":     s.SettleOwners,
		"booking_expire":   s.ExpireBookings,
		"biz_refund_retry": s.Billing.RetryRefunds,
	}
}
