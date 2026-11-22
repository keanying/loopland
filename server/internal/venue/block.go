package venue

import (
	"context"
	"encoding/json"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Block is 外部占场: courts a merchant sold in its own system, synced
// through the open API so the app cannot book them
// (docs/api/v2-5-商户商品与开放平台.md «占场（Block）»).
type Block struct {
	ID          int64     `json:"id"`
	VenueID     int64     `json:"venue_id"`
	Date        string    `json:"date"`
	Start       string    `json:"start"`
	End         string    `json:"end"`
	CourtQty    int       `json:"court_qty"`
	ExternalRef *string   `json:"external_ref"`
	Note        string    `json:"note"`
	CreatedAt   time.Time `json:"created_at"`
}

// BlockInput is POST /open/v1/venues/{id}/blocks.
type BlockInput struct {
	Date        string `json:"date"`
	Start       string `json:"start"`
	End         string `json:"end"`
	CourtQty    int    `json:"court_qty"`
	ExternalRef string `json:"external_ref"`
	Note        string `json:"note"`
}

const blockCols = `id, venue_id, block_date, start_time, end_time, court_qty, external_ref, note, create_time`

func scanBlock(r pgx.Row) (Block, error) {
	var b Block
	var day, st, en time.Time
	err := r.Scan(&b.ID, &b.VenueID, &day, &st, &en, &b.CourtQty, &b.ExternalRef, &b.Note, &b.CreatedAt)
	b.Date = day.Format(time.DateOnly)
	b.Start, b.End = st.In(clock.Shanghai).Format("15:04"), en.In(clock.Shanghai).Format("15:04")
	return b, err
}

// ownVenue loads a venue of the merchant (another merchant's is 404).
func (s *Service) ownVenue(ctx context.Context, q db.Querier, merchantID, id int64) (Venue, error) {
	v, err := s.Get(ctx, q, 0, id, true)
	if err != nil {
		return v, err
	}
	if v.row.merchantID == nil || *v.row.merchantID != merchantID {
		return Venue{}, httpx.NotFound("场馆")
	}
	return v, nil
}

// CreateBlock holds courts of an aligned period inside the opening hours;
// more than the courts left is 409 slot_full. Resubmitting an external_ref
// returns the existing block (created=false).
func (s *Service) CreateBlock(ctx context.Context, merchantID, venueID, appID int64, in BlockInput) (Block, bool, error) {
	in.ExternalRef, in.Note = strings.TrimSpace(in.ExternalRef), strings.TrimSpace(in.Note)
	if utf8.RuneCountInString(in.ExternalRef) > 64 || utf8.RuneCountInString(in.Note) > 200 {
		return Block{}, false, httpx.BadRequest("invalid_body", "external_ref 最多 64 字，note 最多 200 字")
	}
	if in.CourtQty == 0 {
		in.CourtQty = 1
	}
	day, err := time.ParseInLocation(time.DateOnly, in.Date, clock.Shanghai)
	if err != nil {
		return Block{}, false, httpx.BadRequest("invalid_date", "date 格式为 YYYY-MM-DD")
	}
	var out Block
	created := false
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT 1 FROM src.src_mer_loop_venue WHERE id=$1 FOR UPDATE`, venueID); err != nil {
			return err
		}
		v, err := s.ownVenue(ctx, tx, merchantID, venueID)
		if err != nil {
			return err
		}
		if in.ExternalRef != "" {
			b, err := scanBlock(tx.QueryRow(ctx, `SELECT `+blockCols+` FROM src.src_mer_loop_venue_block WHERE venue_id=$1 AND external_ref=$2`, venueID, in.ExternalRef))
			if err == nil {
				out = b
				return nil
			}
			if !db.IsNoRows(err) {
				return err
			}
		}
		if in.CourtQty < 1 || in.CourtQty > v.row.courtQty {
			return httpx.BadRequest("invalid_body", "court_qty 应在 1 到场馆场地数之间")
		}
		open, _ := parseClock(v.row.openTime)
		closing, _ := parseClock(v.row.closeTime)
		st, ok1 := parseClock(in.Start)
		en, ok2 := parseClock(in.End)
		step := v.row.slotMinutes
		if !ok1 || !ok2 || st < open || en > closing || en <= st || (st-open)%step != 0 || (en-open)%step != 0 {
			return httpx.BadRequest("invalid_slot", "时段须在营业时间内并对齐场馆的时段长度")
		}
		start, end := day.Add(time.Duration(st)*time.Minute), day.Add(time.Duration(en)*time.Minute)
		if !end.After(time.Now()) {
			return httpx.BadRequest("invalid_slot", "这个时段已经结束")
		}
		hs, err := occupancy(ctx, tx, venueID, start, end)
		if err != nil {
			return err
		}
		for t := start; t.Before(end); t = t.Add(time.Duration(step) * time.Minute) {
			if used(hs, t, t.Add(time.Duration(step)*time.Minute))+in.CourtQty > v.row.courtQty {
				return httpx.Conflict("slot_full", "所选时段剩余场地不足")
			}
		}
		var ref, app any
		if in.ExternalRef != "" {
			ref = in.ExternalRef
		}
		if appID != 0 {
			app = appID
		}
		out, err = scanBlock(tx.QueryRow(ctx, `INSERT INTO src.src_mer_loop_venue_block (venue_id, merchant_id, open_app_id, block_date, start_time, end_time,
				court_qty, external_ref, note) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING `+blockCols,
			venueID, merchantID, app, day, start, end, in.CourtQty, ref, in.Note))
		created = err == nil
		return err
	})
	return out, created, err
}

// Blocks lists a venue's blocks (optionally of one date).
func (s *Service) Blocks(ctx context.Context, merchantID *int64, venueID int64, date string) ([]Block, error) {
	var day *time.Time
	if date != "" {
		d, err := time.ParseInLocation(time.DateOnly, date, clock.Shanghai)
		if err != nil {
			return nil, httpx.BadRequest("invalid_date", "date 格式为 YYYY-MM-DD")
		}
		day = &d
	}
	if merchantID != nil {
		if _, err := s.ownVenue(ctx, s.Pool, *merchantID, venueID); err != nil {
			return nil, err
		}
	}
	rows, err := s.Pool.Query(ctx, `SELECT `+blockCols+` FROM src.src_mer_loop_venue_block WHERE venue_id=$1 AND ($2::date IS NULL OR block_date=$2)
		ORDER BY start_time, id LIMIT 500`, venueID, day)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Block, error) { return scanBlock(r) })
	if out == nil {
		out = []Block{}
	}
	return out, err
}

// DeleteBlock releases a block of the merchant's venue.
func (s *Service) DeleteBlock(ctx context.Context, merchantID, venueID, id int64) error {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM src.src_mer_loop_venue_block WHERE id=$1 AND venue_id=$2 AND merchant_id=$3`, id, venueID, merchantID)
	if err == nil && tag.RowsAffected() == 0 {
		return httpx.NotFound("占场")
	}
	return err
}

// SelfFields are the venue fields a merchant may change itself (商户自助改场馆).
var SelfFields = map[string]bool{"cover_url": true, "tags": true, "price_amt": true, "slot_minutes": true, "open_time": true, "close_time": true,
	"court_qty": true, "owner_discount_rate": true, "bookable": true}

// SelfUpdate is the merchant's PATCH of its own venue: only SelfFields
// (anything else is 403 field_not_allowed); another merchant's venue is 404.
func (s *Service) SelfUpdate(ctx context.Context, tx pgx.Tx, merchantID, id int64, body []byte) (VenueInput, error) {
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(body, &keys); err != nil {
		return VenueInput{}, httpx.BadRequest("invalid_body", "请求格式错误")
	}
	for k := range keys {
		if !SelfFields[k] {
			return VenueInput{}, httpx.Forbidden("field_not_allowed", "商户不能修改场馆的 "+k+"（位置、名称等请联系平台修改）")
		}
	}
	if _, err := s.ownVenue(ctx, tx, merchantID, id); err != nil {
		return VenueInput{}, err
	}
	in, err := s.InputOf(ctx, id)
	if err != nil {
		return in, err
	}
	if err := json.Unmarshal(body, &in); err != nil {
		return in, httpx.BadRequest("invalid_body", "请求格式错误："+err.Error())
	}
	_, err = s.SaveVenue(ctx, tx, id, in)
	return in, err
}

// MerchantVenues lists a merchant's venues (open API).
func (s *Service) MerchantVenues(ctx context.Context, merchantID int64) ([]AdminVenue, error) {
	return s.adminVenues(ctx, `v.merchant_id=$4 ORDER BY v.id`, merchantID)
}

// OwnAdminVenue loads a venue of the merchant for the back office / open API.
func (s *Service) OwnAdminVenue(ctx context.Context, merchantID, id int64) (AdminVenue, error) {
	v, err := s.ownVenue(ctx, s.Pool, merchantID, id)
	if err != nil {
		return AdminVenue{}, err
	}
	return adminView(v), nil
}
