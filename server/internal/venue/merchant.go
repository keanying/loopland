package venue

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"

	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/platform/secure"
)

// Merchant is a partner (商户).
type Merchant struct {
	ID                    int64     `json:"id"`
	Name                  string    `json:"name"`
	Type                  string    `json:"type"`
	Status                string    `json:"status"`
	ContactName           *string   `json:"contact_name"`
	ContactPhone          *string   `json:"contact_phone"`
	LicenseImages         []string  `json:"license_images"`
	BookingCommissionRate float64   `json:"booking_commission_rate"`
	ProductCommissionRate float64   `json:"product_commission_rate"`
	VenueCount            int       `json:"venue_count"`
	DropCount             int       `json:"drop_count"`
	TodayRedemptions      int       `json:"today_redemptions"`
	CreatedAt             time.Time `json:"created_at"`
}

// Staff is a merchant staff account. Venues: the stores it is bound to
// (empty = not bound, may redeem for every store of the merchant).
type Staff struct {
	ID         int64      `json:"id"`
	Username   string     `json:"username"`
	IsDisabled bool       `json:"is_disabled"`
	VenueIDs   []int64    `json:"venue_ids"`
	Venues     []VenueRef `json:"venues"`
}

// VenueRef is {id, name}.
type VenueRef struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// MerchantDetail is GET /admin/v1/merchants/{id}.
type MerchantDetail struct {
	Merchant
	Venues []AdminVenue `json:"venues"`
	Drops  any          `json:"drops"`
	Staff  []Staff      `json:"staff"`
}

var (
	merchantTypes    = map[string]bool{"venue": true, "brand": true, "store": true}
	merchantStatuses = map[string]bool{"partner": true, "pending_sign": true, "reviewing": true, "suspended": true}
	rePhone          = regexp.MustCompile(`^1\d{10}$`)
)

const merchantCols = `m.id, m.merchant_name, m.merchant_type, m.merchant_status, m.contact_name, m.contact_phone_enc, m.license_images_json,
	m.booking_commission_rate::float8, m.product_commission_rate::float8, (SELECT count(*) FROM src.src_mer_loop_venue v WHERE v.merchant_id=m.id), m.create_time`

func (s *Service) queryMerchants(ctx context.Context, q db.Querier, where string, args ...any) ([]Merchant, error) {
	rows, err := q.Query(ctx, `SELECT `+merchantCols+` FROM src.src_mer_loop_merchant m WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	ms, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Merchant, error) {
		var m Merchant
		var enc, images []byte
		err := r.Scan(&m.ID, &m.Name, &m.Type, &m.Status, &m.ContactName, &enc, &images, &m.BookingCommissionRate, &m.ProductCommissionRate, &m.VenueCount, &m.CreatedAt)
		if err != nil {
			return m, err
		}
		_ = json.Unmarshal(images, &m.LicenseImages)
		if m.LicenseImages == nil {
			m.LicenseImages = []string{}
		}
		if enc != nil {
			if p, err := s.Box.Open(enc); err == nil {
				masked := secure.MaskPhone(p)
				m.ContactPhone = &masked
			}
		}
		return m, nil
	})
	if err != nil {
		return nil, err
	}
	if ms == nil {
		ms = []Merchant{}
	}
	if s.Extras != nil && len(ms) > 0 {
		ids := make([]int64, len(ms))
		for i, m := range ms {
			ids[i] = m.ID
		}
		counts, err := s.Extras.MerchantCounts(ctx, ids)
		if err != nil {
			return nil, err
		}
		for i := range ms {
			c := counts[ms[i].ID]
			ms[i].DropCount, ms[i].TodayRedemptions = c.Drops, c.TodayRedemptions
		}
	}
	return ms, nil
}

// Merchants is GET /admin/v1/merchants (scope: the merchant a staff account
// is bound to, nil for everyone else).
func (s *Service) Merchants(ctx context.Context, scope *int64, status, q string, p httpx.Page) ([]Merchant, int, error) {
	where := `($1='' OR m.merchant_status=$1) AND ($2='' OR m.merchant_name ILIKE '%' || $2 || '%' OR m.id::text=$2) AND ($3::bigint IS NULL OR m.id=$3)`
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_mer_loop_merchant m WHERE `+where, status, q, scope).Scan(&total); err != nil {
		return nil, 0, err
	}
	ms, err := s.queryMerchants(ctx, s.Pool, where+` ORDER BY m.id DESC LIMIT $4 OFFSET $5`, status, q, scope, p.Size, p.Offset())
	return ms, total, err
}

// Merchant loads one merchant.
func (s *Service) Merchant(ctx context.Context, q db.Querier, id int64) (Merchant, error) {
	ms, err := s.queryMerchants(ctx, q, `m.id=$1`, id)
	if err != nil {
		return Merchant{}, err
	}
	if len(ms) == 0 {
		return Merchant{}, httpx.NotFound("商户")
	}
	return ms[0], nil
}

// MerchantDetail adds venues, drops and staff.
func (s *Service) MerchantDetail(ctx context.Context, id int64) (MerchantDetail, error) {
	m, err := s.Merchant(ctx, s.Pool, id)
	if err != nil {
		return MerchantDetail{}, err
	}
	d := MerchantDetail{Merchant: m, Drops: []any{}}
	if d.Venues, err = s.adminVenues(ctx, `v.merchant_id=$4 ORDER BY v.id`, id); err != nil {
		return d, err
	}
	if s.Extras != nil {
		drops, err := s.Extras.MerchantDrops(ctx, id)
		if err != nil {
			return d, err
		}
		if drops != nil {
			d.Drops = drops
		}
	}
	rows, err := s.Pool.Query(ctx, `SELECT a.id, a.username, a.is_disabled,
			COALESCE(array_agg(v.id ORDER BY v.id) FILTER (WHERE v.id IS NOT NULL), '{}'),
			COALESCE(array_agg(v.venue_name ORDER BY v.id) FILTER (WHERE v.id IS NOT NULL), '{}')
		FROM src.src_sys_loop_admin a
		LEFT JOIN src.src_mer_loop_staff_venue sv ON sv.admin_id=a.id
		LEFT JOIN src.src_mer_loop_venue v ON v.id=sv.venue_id
		WHERE a.merchant_id=$1 GROUP BY a.id ORDER BY a.id`, id)
	if err != nil {
		return d, err
	}
	d.Staff, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Staff, error) {
		var st Staff
		var names []string
		err := r.Scan(&st.ID, &st.Username, &st.IsDisabled, &st.VenueIDs, &names)
		st.Venues = make([]VenueRef, len(st.VenueIDs))
		for i := range st.VenueIDs {
			st.Venues[i] = VenueRef{ID: st.VenueIDs[i], Name: names[i]}
		}
		return st, err
	})
	if d.Staff == nil {
		d.Staff = []Staff{}
	}
	return d, err
}

// MerchantInput is POST / PATCH /admin/v1/merchants (PATCH: absent fields
// keep their value; contact_phone absent keeps the stored number, "" or
// null clears it).
type MerchantInput struct {
	Name                  *string   `json:"name"`
	Type                  *string   `json:"type"`
	Status                *string   `json:"status"`
	ContactName           *string   `json:"contact_name"`
	ContactPhone          *string   `json:"contact_phone"`
	LicenseImages         *[]string `json:"license_images"`
	BookingCommissionRate *float64  `json:"booking_commission_rate"`
	// ProductCommissionRate is set by admin only (default 0.08).
	ProductCommissionRate *float64 `json:"product_commission_rate"`

	phoneSet bool
}

// UnmarshalJSON tells an absent contact_phone from an explicit null.
func (in *MerchantInput) UnmarshalJSON(b []byte) error {
	type plain MerchantInput
	var p plain
	if err := json.Unmarshal(b, &p); err != nil {
		return err
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(b, &keys); err != nil {
		return err
	}
	*in = MerchantInput(p)
	_, in.phoneSet = keys["contact_phone"]
	return nil
}

func (in *MerchantInput) validate(create bool) error {
	bad := func(msg string) error { return httpx.BadRequest("invalid_body", msg) }
	if create && (in.Name == nil || in.Type == nil) {
		return bad("商户名称和类型不能为空")
	}
	if in.Name != nil {
		*in.Name = strings.TrimSpace(*in.Name)
		if n := utf8.RuneCountInString(*in.Name); n < 1 || n > 50 {
			return bad("商户名称 1–50 字")
		}
	}
	if in.Type != nil && !merchantTypes[*in.Type] {
		return bad("type 只能是 venue / brand / store")
	}
	if in.Status != nil && !merchantStatuses[*in.Status] {
		return bad("status 只能是 partner / pending_sign / reviewing / suspended")
	}
	if in.ContactName != nil {
		*in.ContactName = strings.TrimSpace(*in.ContactName)
		if utf8.RuneCountInString(*in.ContactName) > 30 {
			return bad("联系人最多 30 字")
		}
	}
	if in.ContactPhone != nil {
		*in.ContactPhone = strings.TrimSpace(*in.ContactPhone)
		if *in.ContactPhone != "" && !rePhone.MatchString(*in.ContactPhone) {
			return bad("联系人手机号格式错误")
		}
	}
	if in.LicenseImages != nil {
		if len(*in.LicenseImages) > 20 {
			return bad("资质图片最多 20 张")
		}
		for _, u := range *in.LicenseImages {
			if !strings.HasPrefix(u, "https://") && !strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "/") {
				return bad("资质图片地址不合法")
			}
		}
	}
	if r := in.BookingCommissionRate; r != nil && (*r < 0 || *r > 1) {
		return bad("订场佣金比例应在 0–1 之间")
	}
	if r := in.ProductCommissionRate; r != nil && (*r < 0 || *r > 1) {
		return bad("商品佣金比例应在 0–1 之间")
	}
	return nil
}

// phone returns the encrypted phone and its last 4 digits to store.
func (s *Service) phone(in *MerchantInput) (enc []byte, last4 *string) {
	if in.ContactPhone == nil || *in.ContactPhone == "" {
		return nil, nil
	}
	p := *in.ContactPhone
	l := p[len(p)-4:]
	return s.Box.Seal(p), &l
}

// CreateMerchant is POST /admin/v1/merchants.
func (s *Service) CreateMerchant(ctx context.Context, tx pgx.Tx, in MerchantInput) (int64, error) {
	if err := in.validate(true); err != nil {
		return 0, err
	}
	status, images, rate, productRate := "reviewing", []string{}, 0.0, 0.08
	if in.Status != nil {
		status = *in.Status
	}
	if in.LicenseImages != nil {
		images = *in.LicenseImages
	}
	if in.BookingCommissionRate != nil {
		rate = *in.BookingCommissionRate
	}
	if in.ProductCommissionRate != nil {
		productRate = *in.ProductCommissionRate
	}
	raw, _ := json.Marshal(images)
	enc, last4 := s.phone(&in)
	var id int64
	err := tx.QueryRow(ctx, `INSERT INTO src.src_mer_loop_merchant (merchant_name, merchant_type, merchant_status, contact_name, contact_phone_enc,
			contact_phone_last4, license_images_json, booking_commission_rate, product_commission_rate)
		VALUES ($1,$2,$3,NULLIF($4,''),$5,$6,$7,$8,$9) RETURNING id`, *in.Name, *in.Type, status, in.ContactName, enc, last4, raw, rate, productRate).Scan(&id)
	return id, err
}

// UpdateMerchant is PATCH /admin/v1/merchants/{id}.
func (s *Service) UpdateMerchant(ctx context.Context, tx pgx.Tx, id int64, in MerchantInput) error {
	if err := in.validate(false); err != nil {
		return err
	}
	var images []byte
	if in.LicenseImages != nil {
		images, _ = json.Marshal(*in.LicenseImages)
	}
	enc, last4 := s.phone(&in)
	tag, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_merchant SET merchant_name=COALESCE($2, merchant_name), merchant_type=COALESCE($3, merchant_type),
			merchant_status=COALESCE($4, merchant_status), contact_name=CASE WHEN $5::text IS NULL THEN contact_name ELSE NULLIF($5,'') END,
			contact_phone_enc=CASE WHEN $6 THEN $7 ELSE contact_phone_enc END, contact_phone_last4=CASE WHEN $6 THEN $8 ELSE contact_phone_last4 END,
			license_images_json=COALESCE($9, license_images_json), booking_commission_rate=COALESCE($10, booking_commission_rate),
			product_commission_rate=COALESCE($11, product_commission_rate), update_time=now()
		WHERE id=$1`, id, in.Name, in.Type, in.Status, in.ContactName, in.phoneSet, enc, last4, images, in.BookingCommissionRate, in.ProductCommissionRate)
	if err == nil && tag.RowsAffected() == 0 {
		return httpx.NotFound("商户")
	}
	return err
}

// RevealPhone decrypts a merchant's contact phone (the caller audits it).
func (s *Service) RevealPhone(ctx context.Context, id int64) (string, error) {
	var enc []byte
	err := s.Pool.QueryRow(ctx, `SELECT contact_phone_enc FROM src.src_mer_loop_merchant WHERE id=$1`, id).Scan(&enc)
	if db.IsNoRows(err) {
		return "", httpx.NotFound("商户")
	}
	if err != nil {
		return "", err
	}
	if enc == nil {
		return "", httpx.NotFound("联系人手机号")
	}
	return s.Box.Open(enc)
}

// SetStaffVenues binds a staff account to stores of its merchant (replaces
// the list; empty = not bound). Venues of other merchants are 400.
func (s *Service) SetStaffVenues(ctx context.Context, tx pgx.Tx, merchant, staff int64, venueIDs []int64) error {
	var ok bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_sys_loop_admin WHERE id=$1 AND role='merchant' AND merchant_id=$2)`, staff, merchant).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return httpx.NotFound("员工账号")
	}
	if len(venueIDs) > 0 {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(DISTINCT id) FROM src.src_mer_loop_venue WHERE id = ANY($1) AND merchant_id=$2`, venueIDs, merchant).Scan(&n); err != nil {
			return err
		}
		if n != len(uniq(venueIDs)) {
			return httpx.BadRequest("invalid_body", "只能绑定本商户的场馆")
		}
	}
	if _, err := tx.Exec(ctx, `DELETE FROM src.src_mer_loop_staff_venue WHERE admin_id=$1`, staff); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `INSERT INTO src.src_mer_loop_staff_venue (admin_id, venue_id) SELECT $1, x FROM unnest($2::bigint[]) x ON CONFLICT DO NOTHING`, staff, uniq(venueIDs))
	return err
}

func uniq(ids []int64) []int64 {
	seen := map[int64]bool{}
	out := []int64{}
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}

// CreateStaff creates a merchant-role admin account bound to the merchant.
func (s *Service) CreateStaff(ctx context.Context, tx pgx.Tx, merchant int64, username, password string) (int64, error) {
	username = strings.TrimSpace(username)
	if username == "" || utf8.RuneCountInString(username) > 32 {
		return 0, httpx.BadRequest("invalid_body", "用户名 1–32 位")
	}
	if utf8.RuneCountInString(password) < 10 {
		return 0, httpx.BadRequest("weak_password", "密码至少 10 位")
	}
	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_mer_loop_merchant WHERE id=$1)`, merchant).Scan(&exists); err != nil {
		return 0, err
	}
	if !exists {
		return 0, httpx.NotFound("商户")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return 0, err
	}
	var id int64
	err = tx.QueryRow(ctx, `INSERT INTO src.src_sys_loop_admin (username, password_hash, role, merchant_id) VALUES ($1,$2,'merchant',$3) RETURNING id`,
		username, string(hash), merchant).Scan(&id)
	if db.IsUniqueViolation(err) {
		return 0, httpx.Conflict("username_taken", "用户名已存在")
	}
	return id, err
}
