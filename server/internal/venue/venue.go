package venue

import (
	"context"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/social"
)

// Owner is the venue's owner (馆主) of the current week.
type Owner struct {
	User   social.UserBrief `json:"user"`
	Points int              `json:"points"`
	Since  string           `json:"since"`
}

// RankRow is a line of the week's points ranking.
type RankRow struct {
	Rank   int              `json:"rank"`
	User   social.UserBrief `json:"user"`
	Points int              `json:"points"`
}

// Venue is the app's venue object.
type Venue struct {
	ID                int64      `json:"id"`
	Merchant          *Ref       `json:"merchant"`
	Name              string     `json:"name"`
	Sports            []string   `json:"sports"`
	Center            LatLng     `json:"center"`
	Address           string     `json:"address"`
	District          string     `json:"district"`
	Tags              []string   `json:"tags"`
	CoverURL          *string    `json:"cover_url"`
	CheckinRadiusM    float64    `json:"checkin_radius_m"`
	Bookable          bool       `json:"bookable"`
	PriceAmt          *int       `json:"price_amt"`
	PriceUnit         string     `json:"price_unit"`
	Owner             *Owner     `json:"owner"`
	OwnerDiscountRate *float64   `json:"owner_discount_rate"`
	DistanceM         *float64   `json:"distance_m"`
	MyWeekPoints      int        `json:"my_week_points"`
	CheckedInToday    bool       `json:"checked_in_today"`
	WeekRank          *[]RankRow `json:"week_rank,omitempty"`
	// Products are the on-sale products usable at the venue (detail only,
	// 第五批; filled by the product module).
	Products any `json:"products,omitempty"`

	row venueRow
}

// venueRow holds the stored settings behind a Venue.
type venueRow struct {
	merchantID     *int64
	merchantStatus *string
	isBookable     bool
	slotMinutes    int
	openTime       string // HH:MM
	closeTime      string
	courtQty       int
	isDisabled     bool
	qrVersion      int
	ownerUser      *int64
}

// AdminVenue is the back-office venue: Bookable is the stored switch (the
// app's bookable also needs a partner merchant), plus the booking settings.
type AdminVenue struct {
	Venue
	MerchantID  *int64 `json:"merchant_id"`
	SlotMinutes int    `json:"slot_minutes"`
	OpenTime    string `json:"open_time"`
	CloseTime   string `json:"close_time"`
	CourtQty    int    `json:"court_qty"`
	IsDisabled  bool   `json:"is_disabled"`
}

// venueSQL: $1 viewer, $2 this week's Monday, $3 today; dist is the distance
// expression (or NULL::float8).
func venueSQL(dist string) string {
	return `SELECT v.id, v.merchant_id, m.merchant_name, m.merchant_status, v.venue_name, v.sports, ST_Y(v.center_geom), ST_X(v.center_geom),
		v.address, v.district, v.tags, v.cover_url, v.checkin_radius_m, v.is_bookable, v.price_amt, v.owner_discount_rate::float8,
		v.slot_minutes, to_char(v.open_time, 'HH24:MI'), to_char(v.close_time, 'HH24:MI'), v.court_qty, v.is_disabled, v.qr_version,
		o.user_id, o.points_qty, o.week_start_date, ` + dist + `,
		(SELECT COALESCE(sum(c.points_qty), 0) FROM src.src_mer_loop_venue_checkin c WHERE c.venue_id=v.id AND c.user_id=$1 AND c.week_start_date=$2),
		EXISTS (SELECT 1 FROM src.src_mer_loop_venue_checkin c WHERE c.venue_id=v.id AND c.user_id=$1 AND c.checkin_date=$3)
	FROM src.src_mer_loop_venue v LEFT JOIN src.src_mer_loop_merchant m ON m.id=v.merchant_id
	LEFT JOIN src.src_mer_loop_venue_owner o ON o.venue_id=v.id AND o.week_start_date=$2`
}

// queryVenues runs venueSQL; args start at $4.
func (s *Service) queryVenues(ctx context.Context, q db.Querier, viewer int64, dist, where string, args ...any) ([]Venue, error) {
	today := clock.Today()
	rows, err := q.Query(ctx, venueSQL(dist)+` WHERE `+where, append([]any{viewer, weekStart(today), today}, args...)...)
	if err != nil {
		return nil, err
	}
	vs, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Venue, error) {
		var v Venue
		var mname *string
		var ownerPts *int
		var since *time.Time
		err := r.Scan(&v.ID, &v.row.merchantID, &mname, &v.row.merchantStatus, &v.Name, &v.Sports, &v.Center.Lat, &v.Center.Lng,
			&v.Address, &v.District, &v.Tags, &v.CoverURL, &v.CheckinRadiusM, &v.row.isBookable, &v.PriceAmt, &v.OwnerDiscountRate,
			&v.row.slotMinutes, &v.row.openTime, &v.row.closeTime, &v.row.courtQty, &v.row.isDisabled, &v.row.qrVersion,
			&v.row.ownerUser, &ownerPts, &since, &v.DistanceM, &v.MyWeekPoints, &v.CheckedInToday)
		if err != nil {
			return v, err
		}
		if v.row.merchantID != nil && mname != nil {
			v.Merchant = &Ref{ID: *v.row.merchantID, Name: *mname}
		}
		v.Bookable = v.row.bookable()
		v.PriceUnit = "hour"
		if v.row.ownerUser != nil {
			v.Owner = &Owner{Points: *ownerPts, Since: since.Format("2006-01-02")}
		}
		if v.Sports == nil {
			v.Sports = []string{}
		}
		if v.Tags == nil {
			v.Tags = []string{}
		}
		return v, nil
	})
	if err != nil {
		return nil, err
	}
	var ids []int64
	for _, v := range vs {
		if v.row.ownerUser != nil {
			ids = append(ids, *v.row.ownerUser)
		}
	}
	bs, err := social.Briefs(ctx, q, ids)
	if err != nil {
		return nil, err
	}
	for i := range vs {
		if vs[i].Owner != nil {
			vs[i].Owner.User = bs[*vs[i].row.ownerUser]
		}
	}
	if vs == nil {
		vs = []Venue{}
	}
	return vs, nil
}

// bookable: the switch is on, the merchant is a partner and the venue is
// not disabled (暂停合作的商户其场馆不可预订).
func (r venueRow) bookable() bool {
	return r.isBookable && !r.isDisabled && r.merchantStatus != nil && *r.merchantStatus == "partner"
}

// Get loads one venue as the viewer sees it (disabled venues: 404 unless admin).
func (s *Service) Get(ctx context.Context, q db.Querier, viewer, id int64, withDisabled bool) (Venue, error) {
	vs, err := s.queryVenues(ctx, q, viewer, `NULL::float8`, `v.id=$4 AND (NOT v.is_disabled OR $5)`, id, withDisabled)
	if err != nil {
		return Venue{}, err
	}
	if len(vs) == 0 {
		return Venue{}, httpx.NotFound("场馆")
	}
	return vs[0], nil
}

// Detail is GET /v1/venues/{id}: the venue with this week's top 10.
func (s *Service) Detail(ctx context.Context, viewer, id int64, at *LatLng) (Venue, error) {
	v, err := s.Get(ctx, s.Pool, viewer, id, false)
	if err != nil {
		return v, err
	}
	if at != nil {
		var d float64
		if err := s.Pool.QueryRow(ctx, `SELECT ST_Distance(center_geom::geography, ST_SetSRID(ST_MakePoint($2,$3),4326)::geography)
			FROM src.src_mer_loop_venue WHERE id=$1`, id, at.Lng, at.Lat).Scan(&d); err != nil {
			return v, err
		}
		v.DistanceM = &d
	}
	rank, err := s.weekRank(ctx, s.Pool, id, weekStart(clock.Today()), 10)
	if err != nil {
		return v, err
	}
	v.WeekRank = &rank
	v.Products = []any{}
	if s.Products != nil && v.row.merchantID != nil {
		ps, err := s.Products.VenueProducts(ctx, viewer, *v.row.merchantID, id)
		if err != nil {
			return v, err
		}
		if ps != nil {
			v.Products = ps
		}
	}
	return v, nil
}

// weekRank ranks a week's points (ties: who reached the total first).
func (s *Service) weekRank(ctx context.Context, q db.Querier, venue int64, week time.Time, limit int) ([]RankRow, error) {
	rows, err := q.Query(ctx, `SELECT user_id, sum(points_qty)::int FROM src.src_mer_loop_venue_checkin WHERE venue_id=$1 AND week_start_date=$2
		GROUP BY user_id HAVING sum(points_qty) > 0 ORDER BY sum(points_qty) DESC, max(create_time), user_id LIMIT $3`, venue, week, limit)
	if err != nil {
		return nil, err
	}
	type up struct {
		user int64
		pts  int
	}
	ups, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (up, error) {
		var x up
		return x, r.Scan(&x.user, &x.pts)
	})
	if err != nil {
		return nil, err
	}
	ids := make([]int64, len(ups))
	for i, x := range ups {
		ids[i] = x.user
	}
	bs, err := social.Briefs(ctx, q, ids)
	if err != nil {
		return nil, err
	}
	out := make([]RankRow, len(ups))
	for i, x := range ups {
		out[i] = RankRow{Rank: i + 1, User: bs[x.user], Points: x.pts}
	}
	return out, nil
}

// ListQuery filters GET /v1/venues.
type ListQuery struct {
	Sport    string
	At       *LatLng
	RadiusM  float64
	Bookable *bool
	Offset   int
	Limit    int
}

// List is GET /v1/venues: by distance when a position is given.
func (s *Service) List(ctx context.Context, viewer int64, f ListQuery) ([]Venue, *string, error) {
	where := `NOT v.is_disabled AND ($4='' OR $4 = ANY(v.sports))
		AND ($5::bool IS NULL OR $5 = (v.is_bookable AND m.merchant_status IS NOT DISTINCT FROM 'partner'))`
	args := []any{f.Sport, f.Bookable}
	dist, order := `NULL::float8`, `v.id`
	if f.At != nil {
		if f.RadiusM <= 0 {
			f.RadiusM = 10000
		}
		pt := `ST_SetSRID(ST_MakePoint($7,$6),4326)::geography`
		dist = `ST_Distance(v.center_geom::geography, ` + pt + `)`
		where += ` AND ST_DWithin(v.center_geom::geography, ` + pt + `, $8)`
		args = append(args, f.At.Lat, f.At.Lng, min(f.RadiusM, 100000))
		order = dist + `, v.id`
	}
	n := len(args) + 3
	vs, err := s.queryVenues(ctx, s.Pool, viewer, dist, where+fmt.Sprintf(` ORDER BY %s LIMIT $%d OFFSET $%d`, order, n+1, n+2),
		append(args, f.Limit+1, f.Offset)...)
	if err != nil {
		return nil, nil, err
	}
	var next *string
	if len(vs) > f.Limit {
		vs = vs[:f.Limit]
		c := fmt.Sprint(f.Offset + f.Limit)
		next = &c
	}
	return vs, next, nil
}

func (s *Service) adminVenues(ctx context.Context, where string, args ...any) ([]AdminVenue, error) {
	vs, err := s.queryVenues(ctx, s.Pool, 0, `NULL::float8`, where, args...)
	if err != nil {
		return nil, err
	}
	out := make([]AdminVenue, len(vs))
	for i, v := range vs {
		out[i] = adminView(v)
	}
	return out, nil
}

func adminView(v Venue) AdminVenue {
	a := AdminVenue{Venue: v, MerchantID: v.row.merchantID, SlotMinutes: v.row.slotMinutes, OpenTime: v.row.openTime, CloseTime: v.row.closeTime,
		CourtQty: v.row.courtQty, IsDisabled: v.row.isDisabled}
	a.Bookable = v.row.isBookable
	return a
}

// AdminVenues is GET /admin/v1/venues.
func (s *Service) AdminVenues(ctx context.Context, merchant *int64, sport, q string, p httpx.Page) ([]AdminVenue, int, error) {
	where := `($4::bigint IS NULL OR v.merchant_id=$4) AND ($5='' OR $5 = ANY(v.sports)) AND ($6='' OR v.venue_name ILIKE '%' || $6 || '%' OR v.id::text=$6)`
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_mer_loop_venue v WHERE ($1::bigint IS NULL OR v.merchant_id=$1)
		AND ($2='' OR $2 = ANY(v.sports)) AND ($3='' OR v.venue_name ILIKE '%' || $3 || '%' OR v.id::text=$3)`, merchant, sport, q).Scan(&total); err != nil {
		return nil, 0, err
	}
	items, err := s.adminVenues(ctx, where+` ORDER BY v.id DESC LIMIT $7 OFFSET $8`, merchant, sport, q, p.Size, p.Offset())
	return items, total, err
}

// AdminVenue loads one venue for the back office.
func (s *Service) AdminVenue(ctx context.Context, id int64) (AdminVenue, error) {
	v, err := s.Get(ctx, s.Pool, 0, id, true)
	if err != nil {
		return AdminVenue{}, err
	}
	return adminView(v), nil
}

// VenueInput is the editable part of a venue (admin). PATCH decodes the
// body onto the stored values.
type VenueInput struct {
	MerchantID        *int64   `json:"merchant_id"`
	Name              string   `json:"name"`
	Sports            []string `json:"sports"`
	Center            LatLng   `json:"center"`
	Address           string   `json:"address"`
	District          string   `json:"district"`
	Tags              []string `json:"tags"`
	CoverURL          *string  `json:"cover_url"`
	CheckinRadiusM    float64  `json:"checkin_radius_m"`
	Bookable          bool     `json:"bookable"`
	PriceAmt          *int     `json:"price_amt"`
	SlotMinutes       int      `json:"slot_minutes"`
	OpenTime          string   `json:"open_time"`
	CloseTime         string   `json:"close_time"`
	CourtQty          int      `json:"court_qty"`
	OwnerDiscountRate *float64 `json:"owner_discount_rate"`
	IsDisabled        bool     `json:"is_disabled"`
}

// NewVenueInput has the defaults of a new venue.
func (s *Service) NewVenueInput() VenueInput {
	return VenueInput{Sports: []string{}, Tags: []string{}, CheckinRadiusM: s.Config.For(0).Venue.DefaultCheckinRadiusM,
		SlotMinutes: 60, OpenTime: "07:00", CloseTime: "23:00", CourtQty: 1}
}

// InputOf returns a stored venue's editable fields.
func (s *Service) InputOf(ctx context.Context, id int64) (VenueInput, error) {
	a, err := s.AdminVenue(ctx, id)
	if err != nil {
		return VenueInput{}, err
	}
	return VenueInput{MerchantID: a.MerchantID, Name: a.Name, Sports: a.Sports, Center: a.Center, Address: a.Address, District: a.District,
		Tags: a.Tags, CoverURL: a.CoverURL, CheckinRadiusM: a.CheckinRadiusM, Bookable: a.Bookable, PriceAmt: a.PriceAmt,
		SlotMinutes: a.SlotMinutes, OpenTime: a.OpenTime, CloseTime: a.CloseTime, CourtQty: a.CourtQty,
		OwnerDiscountRate: a.OwnerDiscountRate, IsDisabled: a.IsDisabled}, nil
}

func parseClock(s string) (int, bool) {
	t, err := time.Parse("15:04", s)
	if err != nil {
		return 0, false
	}
	return t.Hour()*60 + t.Minute(), true
}

func (in *VenueInput) validate(ctx context.Context, q db.Querier) error {
	bad := func(msg string) error { return httpx.BadRequest("invalid_body", msg) }
	in.Name, in.Address, in.District = strings.TrimSpace(in.Name), strings.TrimSpace(in.Address), strings.TrimSpace(in.District)
	if n := utf8.RuneCountInString(in.Name); n < 1 || n > 50 {
		return bad("场馆名称 1–50 字")
	}
	if len(in.Sports) == 0 {
		return bad("至少选择一个运动分类")
	}
	for _, sp := range in.Sports {
		if !Sports[sp] {
			return bad("运动分类取值错误：" + sp)
		}
	}
	if in.Tags == nil {
		in.Tags = []string{}
	}
	if len(in.Tags) > 10 {
		return bad("标签最多 10 个")
	}
	if !in.Center.valid() {
		return bad("场馆位置不合法")
	}
	if utf8.RuneCountInString(in.Address) > 100 || utf8.RuneCountInString(in.District) > 20 {
		return bad("地址最多 100 字，城区最多 20 字")
	}
	if in.CheckinRadiusM < 10 || in.CheckinRadiusM > 2000 {
		return bad("签到半径应在 10–2000 米之间")
	}
	if in.PriceAmt != nil && *in.PriceAmt <= 0 {
		return bad("价格必须为正（不收费请留空）")
	}
	if in.SlotMinutes < 15 || in.SlotMinutes > 240 || in.SlotMinutes%15 != 0 {
		return bad("时段长度应为 15–240 分钟，且是 15 的倍数")
	}
	open, ok1 := parseClock(in.OpenTime)
	closing, ok2 := parseClock(in.CloseTime)
	if !ok1 || !ok2 || closing <= open {
		return bad("营业时间格式为 HH:MM，结束晚于开始")
	}
	if closing-open < in.SlotMinutes {
		return bad("营业时长不足一个时段")
	}
	if in.CourtQty < 1 || in.CourtQty > 100 {
		return bad("场地数应在 1–100 之间")
	}
	if r := in.OwnerDiscountRate; r != nil && (*r <= 0 || *r > 1) {
		return bad("馆主折扣应在 0–1 之间（0.8 = 八折）")
	}
	if in.Bookable && (in.MerchantID == nil || in.PriceAmt == nil) {
		return bad("开放订场需要绑定商户并填写价格")
	}
	if in.MerchantID != nil {
		var exists bool
		if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_mer_loop_merchant WHERE id=$1)`, *in.MerchantID).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return bad("商户不存在")
		}
	}
	return nil
}

// SaveVenue creates (id 0) or updates a venue.
func (s *Service) SaveVenue(ctx context.Context, tx pgx.Tx, id int64, in VenueInput) (int64, error) {
	if err := in.validate(ctx, tx); err != nil {
		return 0, err
	}
	args := []any{in.MerchantID, in.Name, in.Sports, in.Center.Lng, in.Center.Lat, in.Address, in.District, in.Tags, in.CoverURL, in.CheckinRadiusM,
		in.Bookable, in.PriceAmt, in.SlotMinutes, in.OpenTime, in.CloseTime, in.CourtQty, in.OwnerDiscountRate, in.IsDisabled}
	if id == 0 {
		err := tx.QueryRow(ctx, `INSERT INTO src.src_mer_loop_venue (merchant_id, venue_name, sports, center_geom, address, district, tags, cover_url,
				checkin_radius_m, is_bookable, price_amt, slot_minutes, open_time, close_time, court_qty, owner_discount_rate, is_disabled)
			VALUES ($1,$2,$3, ST_SetSRID(ST_MakePoint($4,$5),4326), $6,$7,$8,$9,$10,$11,$12,$13,$14::time,$15::time,$16,$17,$18) RETURNING id`, args...).Scan(&id)
		return id, err
	}
	_, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_venue SET merchant_id=$1, venue_name=$2, sports=$3, center_geom=ST_SetSRID(ST_MakePoint($4,$5),4326),
			address=$6, district=$7, tags=$8, cover_url=$9, checkin_radius_m=$10, is_bookable=$11, price_amt=$12, slot_minutes=$13,
			open_time=$14::time, close_time=$15::time, court_qty=$16, owner_discount_rate=$17, is_disabled=$18, update_time=now()
		WHERE id=$19`, append(args, id)...)
	return id, err
}

// OwnerWeek is a row of a venue's owner history.
type OwnerWeek struct {
	WeekStart string           `json:"week_start"`
	User      social.UserBrief `json:"user"`
	Points    int              `json:"points"`
}

// Owners is GET /admin/v1/venues/{id}/owners (newest first).
func (s *Service) Owners(ctx context.Context, id int64) ([]OwnerWeek, error) {
	rows, err := s.Pool.Query(ctx, `SELECT week_start_date, user_id, points_qty FROM src.src_mer_loop_venue_owner WHERE venue_id=$1
		ORDER BY week_start_date DESC LIMIT 104`, id)
	if err != nil {
		return nil, err
	}
	type ow struct {
		week time.Time
		user int64
		pts  int
	}
	ows, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (ow, error) {
		var x ow
		return x, r.Scan(&x.week, &x.user, &x.pts)
	})
	if err != nil {
		return nil, err
	}
	ids := make([]int64, len(ows))
	for i, x := range ows {
		ids[i] = x.user
	}
	bs, err := social.Briefs(ctx, s.Pool, ids)
	if err != nil {
		return nil, err
	}
	out := make([]OwnerWeek, len(ows))
	for i, x := range ows {
		out[i] = OwnerWeek{WeekStart: x.week.Format("2006-01-02"), User: bs[x.user], Points: x.pts}
	}
	return out, nil
}
