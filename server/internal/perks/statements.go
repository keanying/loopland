package perks

import (
	"context"
	"fmt"
	"math"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/adminmsg"
	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/webhook"
)

// AdminRef is a compact back-office account.
type AdminRef struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
}

// StatementLine is one line of a statement.
type StatementLine struct {
	Type      string   `json:"type"`
	RefNo     string   `json:"ref_no"`
	User      *UserRef `json:"user"`
	AmountAmt int64    `json:"amount_amt"`
	// SubsidyAmt is the official promotion subsidy of a product line.
	SubsidyAmt int64     `json:"subsidy_amt"`
	CreatedAt  time.Time `json:"created_at"`
	Voided     bool      `json:"voided"`
}

// Statement is a weekly merchant statement.
type Statement struct {
	ID                   int64           `json:"id"`
	StatementNo          string          `json:"statement_no"`
	Merchant             MerchantRef     `json:"merchant"`
	PeriodStart          string          `json:"period_start"`
	PeriodEnd            string          `json:"period_end"`
	RedemptionQty        int             `json:"redemption_qty"`
	VoidedQty            int             `json:"voided_qty"`
	RedemptionAmt        int64           `json:"redemption_amt"`
	RedemptionDirection  string          `json:"redemption_direction"`
	BookingQty           int             `json:"booking_qty"`
	BookingAmt           int64           `json:"booking_amt"`
	BookingCommissionAmt int64           `json:"booking_commission_amt"`
	ProductQty           int             `json:"product_qty"`
	ProductAmt           int64           `json:"product_amt"`
	ProductCommissionAmt int64           `json:"product_commission_amt"`
	ProductSubsidyAmt    int64           `json:"product_subsidy_amt"`
	NetAmt               int64           `json:"net_amt"`
	Status               string          `json:"status"`
	ConfirmedBy          *AdminRef       `json:"confirmed_by"`
	ConfirmedAt          *time.Time      `json:"confirmed_at"`
	PaidAt               *time.Time      `json:"paid_at"`
	CreatedAt            time.Time       `json:"created_at"`
	Lines                []StatementLine `json:"lines,omitempty"`

	merchantID int64
}

const statementCols = `s.id, s.statement_no, m.id, m.merchant_name, s.period_start_date, s.period_end_date, s.redemption_qty, s.voided_qty, s.redemption_amt,
	s.redemption_direction, s.booking_qty, s.booking_amt, s.booking_commission_amt, s.net_amt, s.statement_status, a.id, a.username, s.confirm_time,
	s.pay_time, s.create_time, s.product_qty, s.product_amt, s.product_commission_amt, s.product_subsidy_amt`

const statementFrom = ` FROM src.src_fin_loop_statement s JOIN src.src_mer_loop_merchant m ON m.id=s.merchant_id
	LEFT JOIN src.src_sys_loop_admin a ON a.id=s.confirm_admin_id `

func scanStatement(r pgx.Row) (Statement, error) {
	var x Statement
	var start, end time.Time
	var aid *int64
	var aname *string
	err := r.Scan(&x.ID, &x.StatementNo, &x.Merchant.ID, &x.Merchant.Name, &start, &end, &x.RedemptionQty, &x.VoidedQty, &x.RedemptionAmt,
		&x.RedemptionDirection, &x.BookingQty, &x.BookingAmt, &x.BookingCommissionAmt, &x.NetAmt, &x.Status, &aid, &aname, &x.ConfirmedAt,
		&x.PaidAt, &x.CreatedAt, &x.ProductQty, &x.ProductAmt, &x.ProductCommissionAmt, &x.ProductSubsidyAmt)
	x.PeriodStart, x.PeriodEnd = start.Format(time.DateOnly), end.Format(time.DateOnly)
	if aid != nil {
		x.ConfirmedBy = &AdminRef{ID: *aid, Username: *aname}
	}
	x.merchantID = x.Merchant.ID
	return x, err
}

// LoadStatement returns a statement with its lines; scope limits merchant
// staff to their own.
func (s *Service) LoadStatement(ctx context.Context, q db.Querier, scope *int64, id int64, lines bool) (Statement, error) {
	x, err := scanStatement(q.QueryRow(ctx, `SELECT `+statementCols+statementFrom+` WHERE s.id=$1`, id))
	if db.IsNoRows(err) || (err == nil && scope != nil && *scope != x.merchantID) {
		return x, httpx.NotFound("结算单")
	}
	if err != nil || !lines {
		return x, err
	}
	rows, err := q.Query(ctx, `SELECT l.line_type, l.ref_no, u.id, u.nickname, l.amount_amt, l.subsidy_amt, l.occur_time, l.is_voided
		FROM src.src_fin_loop_statement_line l LEFT JOIN src.src_usr_loop_user u ON u.id=l.user_id
		WHERE l.statement_id=$1 ORDER BY l.occur_time, l.id`, id)
	if err != nil {
		return x, err
	}
	x.Lines, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (StatementLine, error) {
		var l StatementLine
		var uid *int64
		var nick *string
		err := r.Scan(&l.Type, &l.RefNo, &uid, &nick, &l.AmountAmt, &l.SubsidyAmt, &l.CreatedAt, &l.Voided)
		if uid != nil {
			l.User = &UserRef{ID: *uid, Nickname: *nick}
		}
		return l, err
	})
	if x.Lines == nil {
		x.Lines = []StatementLine{}
	}
	return x, err
}

// Statements lists statements.
func (s *Service) Statements(ctx context.Context, merchantID int64, status string, p httpx.Page) ([]Statement, int, error) {
	return s.statements(ctx, merchantID, status, -1, p)
}

// StatementsBefore lists statements older than id beforeID (0: from the
// newest; the open API cursor), by id descending.
func (s *Service) StatementsBefore(ctx context.Context, merchantID int64, status string, beforeID int64, limit int) ([]Statement, error) {
	items, _, err := s.statements(ctx, merchantID, status, beforeID, httpx.Page{Page: 1, Size: limit})
	return items, err
}

// statements: beforeID < 0 orders by period (admin pages), else by id.
func (s *Service) statements(ctx context.Context, merchantID int64, status string, beforeID int64, p httpx.Page) ([]Statement, int, error) {
	order := `s.period_start_date DESC, s.id DESC`
	if beforeID >= 0 {
		order = `s.id DESC`
	}
	beforeID = max(beforeID, 0)
	where := `($1 = 0 OR s.merchant_id=$1) AND ($2 = '' OR s.statement_status=$2) AND ($3 = 0 OR s.id < $3)`
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_fin_loop_statement s WHERE `+where, merchantID, status, beforeID).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT `+statementCols+statementFrom+` WHERE `+where+` ORDER BY `+order+` LIMIT $4 OFFSET $5`,
		merchantID, status, beforeID, p.Size, p.Offset())
	if err != nil {
		return nil, 0, err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Statement, error) { return scanStatement(r) })
	if items == nil {
		items = []Statement{}
	}
	return items, total, err
}

// bookingsReady reports whether the booking table (part A, 0009) exists.
func bookingsReady(ctx context.Context, q db.Querier) (bool, error) {
	var ok bool
	err := q.QueryRow(ctx, `SELECT to_regclass('src.src_ord_loop_booking') IS NOT NULL`).Scan(&ok)
	return ok, err
}

// isoNo is ST<ISO year>W<week>-<merchant>.
func statementNo(start time.Time, merchant int64) string {
	y, w := start.ISOWeek()
	return fmt.Sprintf("ST%dW%02d-%03d", y, w, merchant)
}

// Generate builds the statements of the week starting at start (a Monday,
// Asia/Shanghai) for every merchant with redemptions or bookings in it. It
// fails with 409 when the period was generated before.
func (s *Service) Generate(ctx context.Context, start time.Time, failIfExists bool) ([]int64, error) {
	start = clock.Day(start)
	if start.Weekday() != time.Monday {
		return nil, httpx.BadRequest("invalid_period", "period_start 必须是周一")
	}
	end := start.AddDate(0, 0, 6)
	if !clock.Now().After(end.AddDate(0, 0, 1)) {
		return nil, httpx.BadRequest("invalid_period", "这一周还没结束")
	}
	var ids []int64
	var created []Statement
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_fin_loop_statement WHERE period_start_date=$1)`, start).Scan(&exists); err != nil {
			return err
		}
		if exists && failIfExists {
			return httpx.Conflict("statement_exists", "这一周的结算单已经生成过了")
		}
		withBookings, err := bookingsReady(ctx, tx)
		if err != nil {
			return err
		}
		q := `SELECT DISTINCT merchant_id FROM src.src_mer_loop_redemption WHERE redeem_date BETWEEN $1 AND $2 AND statement_id IS NULL`
		if withBookings {
			q += ` UNION SELECT DISTINCT merchant_id FROM src.src_ord_loop_booking WHERE booking_status IN ('paid','completed')
				AND start_time >= $1::date::timestamp AT TIME ZONE 'Asia/Shanghai' AND start_time < ($2::date + 1)::timestamp AT TIME ZONE 'Asia/Shanghai'
				AND merchant_id IS NOT NULL`
		}
		rows, err := tx.Query(ctx, q, start, end)
		if err != nil {
			return err
		}
		merchants, err := pgx.CollectRows(rows, pgx.RowTo[int64])
		if err != nil {
			return err
		}
		for _, m := range merchants {
			var id int64
			err := tx.QueryRow(ctx, `INSERT INTO src.src_fin_loop_statement (statement_no, merchant_id, period_start_date, period_end_date, booking_commission_rate,
					product_commission_rate)
				SELECT $1, id, $3, $4, booking_commission_rate, product_commission_rate FROM src.src_mer_loop_merchant WHERE id=$2
				ON CONFLICT (merchant_id, period_start_date) DO NOTHING RETURNING id`, statementNo(start, m), m, start, end).Scan(&id)
			if db.IsNoRows(err) {
				continue
			}
			if err != nil {
				return err
			}
			if err := fill(ctx, tx, id, m, start, end, withBookings); err != nil {
				return err
			}
			x, err := s.LoadStatement(ctx, tx, nil, id, true)
			if err != nil {
				return err
			}
			if err := webhook.Emit(ctx, tx, m, webhook.StatementCreated, x); err != nil {
				return err
			}
			ids = append(ids, id)
			created = append(created, x)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	for _, x := range created {
		s.Msg.ToMerchant(ctx, x.merchantID, adminmsg.Msg{Category: adminmsg.CatSettlement, Level: adminmsg.Info,
			Title: weekTitle(start) + "已生成，待平台确认", Body: statementBody(x), Link: statementLink(x.ID), RefType: "statement", RefID: x.ID})
	}
	return ids, nil
}

func weekTitle(start time.Time) string {
	_, w := start.ISOWeek()
	return fmt.Sprintf("第 %d 周结算单", w)
}

func statementLink(id int64) string { return fmt.Sprintf("/merchant/settlement?id=%d", id) }

// statementBody is the period and the net amount (net_amt > 0: the merchant pays).
func statementBody(x Statement) string {
	net := "商户应付平台 " + adminmsg.Yuan(x.NetAmt)
	if x.NetAmt <= 0 {
		net = "平台应付商户 " + adminmsg.Yuan(-x.NetAmt)
	}
	return fmt.Sprintf("%s 至 %s（%s），%s。", x.PeriodStart, x.PeriodEnd, x.StatementNo, net)
}

// fill writes a new statement's lines and totals. Redemptions are lines
// (voided ones listed but not counted); paid / completed bookings whose
// start falls in the period are lines (refunded ones are not).
func fill(ctx context.Context, tx pgx.Tx, id, merchant int64, start, end time.Time, withBookings bool) error {
	if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_redemption SET statement_id=$1, update_time=now()
		WHERE merchant_id=$2 AND redeem_date BETWEEN $3 AND $4 AND statement_id IS NULL`, id, merchant, start, end); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO src.src_fin_loop_statement_line (statement_id, line_type, ref_id, ref_no, user_id, amount_amt, is_voided, occur_time)
		SELECT $1, 'redemption', r.id, r.redemption_no, r.user_id, r.settle_price_amt, r.redemption_status='voided', r.create_time
		FROM src.src_mer_loop_redemption r WHERE r.statement_id=$1 AND r.redemption_type='drop' ON CONFLICT (line_type, ref_id) DO NOTHING`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO src.src_fin_loop_statement_line (statement_id, line_type, ref_id, ref_no, user_id, amount_amt, subsidy_amt, is_voided, occur_time)
		SELECT $1, 'product', r.id, r.redemption_no, r.user_id, r.product_amt, r.product_subsidy_amt, r.redemption_status='voided', r.create_time
		FROM src.src_mer_loop_redemption r WHERE r.statement_id=$1 AND r.redemption_type='product' ON CONFLICT (line_type, ref_id) DO NOTHING`, id); err != nil {
		return err
	}
	if withBookings {
		if _, err := tx.Exec(ctx, `INSERT INTO src.src_fin_loop_statement_line (statement_id, line_type, ref_id, ref_no, user_id, amount_amt, is_voided, occur_time)
			SELECT $1, 'booking', b.id, b.booking_no, b.user_id, b.amount_amt, false, b.start_time FROM src.src_ord_loop_booking b
			WHERE b.merchant_id=$2 AND b.booking_status IN ('paid','completed')
			  AND b.start_time >= $3::date::timestamp AT TIME ZONE 'Asia/Shanghai' AND b.start_time < ($4::date + 1)::timestamp AT TIME ZONE 'Asia/Shanghai'
			ON CONFLICT (line_type, ref_id) DO NOTHING`, id, merchant, start, end); err != nil {
			return err
		}
	}
	return recompute(ctx, tx, id)
}

// recompute sets a statement's totals from its lines:
//
//	redemption signed  = Σ price (merchant_pays) − Σ price (platform_pays), valid only
//	commission         = round(booking_amt × booking_commission_rate)
//	product commission = round(product_amt × product_commission_rate)
//	net_amt            = redemption signed − (booking_amt − commission)
//	                     − (product_amt − product commission) − product_subsidy_amt
//
// so net_amt > 0 means the merchant pays the platform.
func recompute(ctx context.Context, tx pgx.Tx, id int64) error {
	var redeemed, voided, bookings, products int
	var signed, bookingAmt, productAmt, subsidy int64
	var rate, productRate float64
	if err := tx.QueryRow(ctx, `SELECT
			count(*) FILTER (WHERE l.line_type='redemption' AND NOT l.is_voided)::int,
			count(*) FILTER (WHERE l.line_type='redemption' AND l.is_voided)::int,
			COALESCE(sum(CASE WHEN r.settle_direction='platform_pays' THEN -l.amount_amt ELSE l.amount_amt END)
				FILTER (WHERE l.line_type='redemption' AND NOT l.is_voided), 0)::bigint,
			count(*) FILTER (WHERE l.line_type='booking')::int,
			COALESCE(sum(l.amount_amt) FILTER (WHERE l.line_type='booking'), 0)::bigint,
			(SELECT booking_commission_rate::float8 FROM src.src_fin_loop_statement WHERE id=$1),
			count(*) FILTER (WHERE l.line_type='product' AND NOT l.is_voided)::int,
			COALESCE(sum(l.amount_amt) FILTER (WHERE l.line_type='product' AND NOT l.is_voided), 0)::bigint,
			COALESCE(sum(l.subsidy_amt) FILTER (WHERE l.line_type='product' AND NOT l.is_voided), 0)::bigint,
			(SELECT product_commission_rate::float8 FROM src.src_fin_loop_statement WHERE id=$1)
		FROM src.src_fin_loop_statement_line l LEFT JOIN src.src_mer_loop_redemption r ON l.line_type='redemption' AND r.id=l.ref_id
		WHERE l.statement_id=$1`, id).Scan(&redeemed, &voided, &signed, &bookings, &bookingAmt, &rate, &products, &productAmt, &subsidy, &productRate); err != nil {
		return err
	}
	commission := int64(math.Round(float64(bookingAmt) * rate))
	productCommission := int64(math.Round(float64(productAmt) * productRate))
	direction, amt := "merchant_pays", signed
	if signed < 0 {
		direction, amt = "platform_pays", -signed
	}
	net := signed - (bookingAmt - commission) - (productAmt - productCommission) - subsidy
	_, err := tx.Exec(ctx, `UPDATE src.src_fin_loop_statement SET redemption_qty=$2, voided_qty=$3, redemption_amt=$4, redemption_direction=$5,
			booking_qty=$6, booking_amt=$7, booking_commission_amt=$8, net_amt=$9, product_qty=$10, product_amt=$11, product_commission_amt=$12,
			product_subsidy_amt=$13, update_time=now() WHERE id=$1`,
		id, redeemed, voided, amt, direction, bookings, bookingAmt, commission, net, products, productAmt, productCommission, subsidy)
	return err
}

// WeeklyStatements generates last week's statements once, from Monday 03:00
// (Asia/Shanghai).
func (s *Service) WeeklyStatements(ctx context.Context, now time.Time) error {
	today := clock.Day(now)
	monday := today.AddDate(0, 0, -((int(today.Weekday()) + 6) % 7))
	if now.Before(monday.Add(3 * time.Hour)) {
		return nil
	}
	period := monday.AddDate(0, 0, -7)
	tag, err := s.Pool.Exec(ctx, `INSERT INTO src.src_sys_loop_setting (setting_key, setting_value) VALUES ('statements_period', to_jsonb($1::text))
		ON CONFLICT (setting_key) DO UPDATE SET setting_value=EXCLUDED.setting_value, update_time=now() WHERE src_sys_loop_setting.setting_value <> to_jsonb($1::text)`,
		period.Format(time.DateOnly))
	if err != nil || tag.RowsAffected() == 0 {
		return err
	}
	_, err = s.Generate(ctx, period, false)
	return err
}

// StatementAction confirms (draft → confirmed) or marks paid
// (confirmed → paid).
func (s *Service) StatementAction(ctx context.Context, tx pgx.Tx, id, adminID int64, action string) error {
	var status string
	err := tx.QueryRow(ctx, `SELECT statement_status FROM src.src_fin_loop_statement WHERE id=$1 FOR UPDATE`, id).Scan(&status)
	if db.IsNoRows(err) {
		return httpx.NotFound("结算单")
	}
	if err != nil {
		return err
	}
	switch {
	case action == "confirm" && status == "draft":
		_, err = tx.Exec(ctx, `UPDATE src.src_fin_loop_statement SET statement_status='confirmed', confirm_admin_id=$2, confirm_time=now(), update_time=now() WHERE id=$1`,
			id, adminID)
	case action == "paid" && status == "confirmed":
		_, err = tx.Exec(ctx, `UPDATE src.src_fin_loop_statement SET statement_status='paid', pay_time=now(), update_time=now() WHERE id=$1`, id)
	case action == "confirm":
		return httpx.Conflict("invalid_status", "只有待确认的结算单可以确认")
	default:
		return httpx.Conflict("invalid_status", "确认后才能标记已付款")
	}
	if err != nil {
		return err
	}
	x, err := s.LoadStatement(ctx, tx, nil, id, false)
	if err != nil {
		return err
	}
	start, _ := time.ParseInLocation(time.DateOnly, x.PeriodStart, clock.Shanghai)
	m := adminmsg.Msg{Category: adminmsg.CatSettlement, Level: adminmsg.Success, Title: weekTitle(start) + "已确认", Body: statementBody(x),
		Link: statementLink(id), RefType: "statement", RefID: id}
	if action == "paid" {
		m.Title = weekTitle(start) + "平台已付款 " + adminmsg.Yuan(max(-x.NetAmt, 0))
		if x.NetAmt > 0 {
			m.Title = weekTitle(start) + "已结清 " + adminmsg.Yuan(x.NetAmt)
		}
	}
	s.Msg.ToMerchant(ctx, x.merchantID, m)
	return nil
}

// OverviewDay is one bar of the settlement chart.
type OverviewDay struct {
	Date        string `json:"date"`
	Redemptions int    `json:"redemptions"`
	Voided      int    `json:"voided"`
	Bookings    int    `json:"bookings"`
}

// Overview is GET /admin/v1/settlement/overview.
func (s *Service) Overview(ctx context.Context, merchantID int64, days int) ([]OverviewDay, int, error) {
	today := clock.Today()
	start := today.AddDate(0, 0, -(days - 1))
	withBookings, err := bookingsReady(ctx, s.Pool)
	if err != nil {
		return nil, 0, err
	}
	bookingSQL := `0`
	if withBookings {
		bookingSQL = `(SELECT count(*) FROM src.src_ord_loop_booking b WHERE ($1 = 0 OR b.merchant_id=$1) AND b.booking_status IN ('paid','completed')
			AND b.start_time >= d::timestamp AT TIME ZONE 'Asia/Shanghai' AND b.start_time < (d + 1)::timestamp AT TIME ZONE 'Asia/Shanghai')`
	}
	rows, err := s.Pool.Query(ctx, `SELECT d::date,
			(SELECT count(*) FROM src.src_mer_loop_redemption r WHERE ($1 = 0 OR r.merchant_id=$1) AND r.redeem_date=d AND r.redemption_status='valid')::int,
			(SELECT count(*) FROM src.src_mer_loop_redemption r WHERE ($1 = 0 OR r.merchant_id=$1) AND r.redeem_date=d AND r.redemption_status='voided')::int,
			`+bookingSQL+`::int
		FROM generate_series($2::date, $3::date, interval '1 day') g(d0), LATERAL (SELECT g.d0::date AS d) x ORDER BY 1`, merchantID, start, today)
	if err != nil {
		return nil, 0, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (OverviewDay, error) {
		var o OverviewDay
		var d time.Time
		err := r.Scan(&d, &o.Redemptions, &o.Voided, &o.Bookings)
		o.Date = d.Format(time.DateOnly)
		return o, err
	})
	if err != nil {
		return nil, 0, err
	}
	var pending int
	err = s.Pool.QueryRow(ctx, `SELECT count(*) FROM src.src_fin_loop_statement WHERE statement_status='draft' AND ($1 = 0 OR merchant_id=$1)`, merchantID).Scan(&pending)
	return out, pending, err
}

// PendingStatements counts draft statements (总览待办).
func PendingStatements(ctx context.Context, q db.Querier) (int, error) {
	var n int
	err := q.QueryRow(ctx, `SELECT count(*) FROM src.src_fin_loop_statement WHERE statement_status='draft'`).Scan(&n)
	return n, err
}
