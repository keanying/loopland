package perks

import (
	"context"
	"math"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// CampaignStats are a brand campaign's numbers.
type CampaignStats struct {
	Issued       int     `json:"issued"`
	Redeemed     int     `json:"redeemed"`
	NewUsers     int     `json:"new_users"`
	ProgressRate float64 `json:"progress_rate"`
}

// Campaign is BrandCampaign.
type Campaign struct {
	ID                    int64         `json:"id"`
	Merchant              MerchantRef   `json:"merchant"`
	Title                 string        `json:"title"`
	Description           string        `json:"description"`
	CoverURL              *string       `json:"cover_url"`
	StartTime             time.Time     `json:"start_time"`
	EndTime               time.Time     `json:"end_time"`
	Status                string        `json:"status"`
	StoreCount            int           `json:"store_count"`
	DropIDs               []int64       `json:"drop_ids"`
	TargetRedemptions     int           `json:"target_redemptions"`
	MerchantInvestmentAmt *int64        `json:"merchant_investment_amt,omitempty"`
	Stats                 CampaignStats `json:"stats"`
	// Drops is filled for the app list.
	Drops []PublicDrop `json:"drops,omitempty"`
}

// campaignStatusSQL is the effective status of campaign bc.
const campaignStatusSQL = `(CASE WHEN bc.campaign_status = 'draft' THEN 'draft' WHEN bc.campaign_status = 'paused' THEN 'paused'
	WHEN bc.end_time <= now() THEN 'ended' WHEN bc.start_time > now() THEN 'scheduled' ELSE 'running' END)`

// new_users: registered during the campaign and got one of its coupons
// within 7 days of registering.
const campaignCols = `bc.id, m.id, m.merchant_name, bc.campaign_title, bc.description, bc.cover_url, bc.start_time, bc.end_time, ` + campaignStatusSQL + `,
	bc.store_qty, COALESCE((SELECT array_agg(d.id ORDER BY d.id) FROM src.src_mer_loop_drop d WHERE d.campaign_id=bc.id), '{}'),
	bc.target_redemption_qty, bc.merchant_investment_amt,
	(SELECT count(*) FROM src.src_mkt_loop_coupon c WHERE c.campaign_id=bc.id)::int,
	(SELECT count(*) FROM src.src_mer_loop_redemption r WHERE r.campaign_id=bc.id AND r.redemption_status='valid')::int,
	(SELECT count(DISTINCT c.user_id) FROM src.src_mkt_loop_coupon c JOIN src.src_usr_loop_user u ON u.id=c.user_id
	  WHERE c.campaign_id=bc.id AND u.create_time >= bc.start_time AND u.create_time < bc.end_time AND c.create_time <= u.create_time + interval '7 days')::int`

const campaignFrom = ` FROM src.src_mkt_loop_brand_campaign bc JOIN src.src_mer_loop_merchant m ON m.id=bc.merchant_id `

func scanCampaign(r pgx.Row) (Campaign, error) {
	var c Campaign
	var invest int64
	err := r.Scan(&c.ID, &c.Merchant.ID, &c.Merchant.Name, &c.Title, &c.Description, &c.CoverURL, &c.StartTime, &c.EndTime, &c.Status,
		&c.StoreCount, &c.DropIDs, &c.TargetRedemptions, &invest, &c.Stats.Issued, &c.Stats.Redeemed, &c.Stats.NewUsers)
	c.MerchantInvestmentAmt = &invest
	if c.DropIDs == nil {
		c.DropIDs = []int64{}
	}
	if c.TargetRedemptions > 0 {
		c.Stats.ProgressRate = math.Round(float64(c.Stats.Redeemed)/float64(c.TargetRedemptions)*10000) / 10000
	}
	return c, err
}

// LoadCampaign returns one campaign (admin view).
func LoadCampaign(ctx context.Context, q db.Querier, id int64) (Campaign, error) {
	c, err := scanCampaign(q.QueryRow(ctx, `SELECT `+campaignCols+campaignFrom+` WHERE bc.id=$1`, id))
	if db.IsNoRows(err) {
		return c, httpx.NotFound("联名活动")
	}
	return c, err
}

func collectCampaigns(rows pgx.Rows, err error) ([]Campaign, error) {
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Campaign, error) { return scanCampaign(r) })
	if out == nil {
		out = []Campaign{}
	}
	return out, err
}

// AdminCampaigns lists campaigns.
func (s *Service) AdminCampaigns(ctx context.Context, status string, merchantID int64, p httpx.Page) ([]Campaign, int, error) {
	where := `($1 = '' OR ` + campaignStatusSQL + ` = $1) AND ($2 = 0 OR bc.merchant_id=$2)`
	var total int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*)`+campaignFrom+` WHERE `+where, status, merchantID).Scan(&total); err != nil {
		return nil, 0, err
	}
	items, err := collectCampaigns(s.Pool.Query(ctx, `SELECT `+campaignCols+campaignFrom+` WHERE `+where+` ORDER BY bc.start_time DESC, bc.id DESC LIMIT $3 OFFSET $4`,
		status, merchantID, p.Size, p.Offset()))
	return items, total, err
}

// AppCampaigns lists the running campaigns with their drops, without the
// merchant's investment.
func (s *Service) AppCampaigns(ctx context.Context) ([]Campaign, error) {
	items, err := collectCampaigns(s.Pool.Query(ctx, `SELECT `+campaignCols+campaignFrom+` WHERE `+campaignStatusSQL+` = 'running'
		AND m.merchant_status <> 'suspended' ORDER BY bc.start_time DESC LIMIT 100`))
	if err != nil {
		return nil, err
	}
	for i := range items {
		items[i].MerchantInvestmentAmt = nil
		drops, err := collectDrops(s.Pool.Query(ctx, `SELECT `+dropCols+dropFrom+` WHERE d.campaign_id=$1 AND `+dropStatusSQL+` <> 'ended' ORDER BY d.id`, items[i].ID))
		if err != nil {
			return nil, err
		}
		items[i].Drops = make([]PublicDrop, 0, len(drops))
		for _, d := range drops {
			items[i].Drops = append(items[i].Drops, d.Public())
		}
	}
	return items, nil
}

// CampaignInput is the admin create / update body.
type CampaignInput struct {
	MerchantID            int64     `json:"merchant_id"`
	Title                 string    `json:"title"`
	Description           string    `json:"description"`
	CoverURL              *string   `json:"cover_url"`
	StartTime             time.Time `json:"start_time"`
	EndTime               time.Time `json:"end_time"`
	StoreCount            int       `json:"store_count"`
	TargetRedemptions     int       `json:"target_redemptions"`
	MerchantInvestmentAmt int64     `json:"merchant_investment_amt"`
	// Status on create: draft or scheduled (default; published by time).
	Status string `json:"status,omitempty"`
	// DropIDs, when given, attaches exactly these drops of the merchant.
	DropIDs *[]int64 `json:"drop_ids,omitempty"`
}

func (in *CampaignInput) validate(ctx context.Context, q db.Querier) error {
	in.Title = strings.TrimSpace(in.Title)
	switch {
	case in.Title == "":
		return bad("标题不能为空")
	case !in.EndTime.After(in.StartTime):
		return bad("结束时间必须晚于开始时间")
	case in.StoreCount < 0 || in.TargetRedemptions < 0 || in.MerchantInvestmentAmt < 0:
		return bad("门店数、目标核销和商户投入不能为负")
	}
	var ok bool
	if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_mer_loop_merchant WHERE id=$1)`, in.MerchantID).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return bad("商户不存在")
	}
	if in.DropIDs != nil && len(*in.DropIDs) > 0 {
		var n int
		if err := q.QueryRow(ctx, `SELECT count(*) FROM src.src_mer_loop_drop WHERE id = ANY($1) AND merchant_id=$2`, *in.DropIDs, in.MerchantID).Scan(&n); err != nil {
			return err
		}
		if n != len(*in.DropIDs) {
			return bad("drop_ids 里有不属于这个商户的投放")
		}
	}
	return nil
}

func attachDrops(ctx context.Context, tx pgx.Tx, id int64, ids *[]int64) error {
	if ids == nil {
		return nil
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_drop SET campaign_id=NULL, update_time=now() WHERE campaign_id=$1 AND NOT (id = ANY($2))`, id, *ids); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `UPDATE src.src_mer_loop_drop SET campaign_id=$1, update_time=now() WHERE id = ANY($2)`, id, *ids)
	return err
}

// CreateCampaign stores a campaign.
func (s *Service) CreateCampaign(ctx context.Context, tx pgx.Tx, by int64, in CampaignInput) (int64, error) {
	if err := in.validate(ctx, tx); err != nil {
		return 0, err
	}
	status := "published"
	switch in.Status {
	case "draft":
		status = "draft"
	case "", "scheduled", "running":
	default:
		return 0, bad("status 只能是 draft / scheduled")
	}
	var id int64
	if err := tx.QueryRow(ctx, `INSERT INTO src.src_mkt_loop_brand_campaign (merchant_id, campaign_title, description, cover_url, start_time, end_time,
			campaign_status, store_qty, target_redemption_qty, merchant_investment_amt, create_admin_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING id`,
		in.MerchantID, in.Title, in.Description, in.CoverURL, in.StartTime, in.EndTime, status, in.StoreCount, in.TargetRedemptions,
		in.MerchantInvestmentAmt, by).Scan(&id); err != nil {
		return 0, err
	}
	return id, attachDrops(ctx, tx, id, in.DropIDs)
}

// CampaignInputOf returns the editable fields.
func (s *Service) CampaignInputOf(ctx context.Context, id int64) (CampaignInput, error) {
	c, err := LoadCampaign(ctx, s.Pool, id)
	if err != nil {
		return CampaignInput{}, err
	}
	return CampaignInput{MerchantID: c.Merchant.ID, Title: c.Title, Description: c.Description, CoverURL: c.CoverURL, StartTime: c.StartTime,
		EndTime: c.EndTime, StoreCount: c.StoreCount, TargetRedemptions: c.TargetRedemptions, MerchantInvestmentAmt: *c.MerchantInvestmentAmt}, nil
}

// UpdateCampaign saves edited fields; status "draft" ↔ "scheduled" may be
// switched here (pause / resume / launch have their own endpoints).
func (s *Service) UpdateCampaign(ctx context.Context, tx pgx.Tx, id int64, in CampaignInput) error {
	if err := in.validate(ctx, tx); err != nil {
		return err
	}
	var cur string
	if err := tx.QueryRow(ctx, `SELECT campaign_status FROM src.src_mkt_loop_brand_campaign WHERE id=$1 FOR UPDATE`, id).Scan(&cur); err != nil {
		return err
	}
	status := cur
	switch in.Status {
	case "":
	case "draft":
		status = "draft"
	case "scheduled":
		if cur == "draft" {
			status = "published"
		}
	default:
		return bad("status 只能改为 draft / scheduled，暂停和恢复请用对应按钮")
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_mkt_loop_brand_campaign SET merchant_id=$2, campaign_title=$3, description=$4, cover_url=$5, start_time=$6,
			end_time=$7, campaign_status=$8, store_qty=$9, target_redemption_qty=$10, merchant_investment_amt=$11, update_time=now() WHERE id=$1`,
		id, in.MerchantID, in.Title, in.Description, in.CoverURL, in.StartTime, in.EndTime, status, in.StoreCount, in.TargetRedemptions,
		in.MerchantInvestmentAmt); err != nil {
		return err
	}
	return attachDrops(ctx, tx, id, in.DropIDs)
}

var errCampaignState = func(msg string) error { return httpx.Conflict("invalid_status", msg) }

// CampaignAction pauses, resumes or launches (提前上线) a campaign. Its
// drops follow: a paused campaign pauses all its drops; launching moves the
// start of the campaign and of its not-yet-started drops to now.
func (s *Service) CampaignAction(ctx context.Context, tx pgx.Tx, id int64, action string) error {
	var status string
	err := tx.QueryRow(ctx, `SELECT `+campaignStatusSQL+` FROM src.src_mkt_loop_brand_campaign bc WHERE bc.id=$1 FOR UPDATE`, id).Scan(&status)
	if db.IsNoRows(err) {
		return httpx.NotFound("联名活动")
	}
	if err != nil {
		return err
	}
	switch action {
	case "pause":
		if status != "running" && status != "scheduled" {
			return errCampaignState("只有未开始或进行中的活动可以暂停")
		}
		_, err = tx.Exec(ctx, `UPDATE src.src_mkt_loop_brand_campaign SET campaign_status='paused', update_time=now() WHERE id=$1`, id)
		if err == nil {
			_, err = tx.Exec(ctx, `UPDATE src.src_ply_loop_chest c SET remove_time=now() FROM src.src_mer_loop_drop d
				WHERE c.drop_id=d.id AND d.campaign_id=$1 AND c.remove_time IS NULL`, id)
		}
	case "resume":
		if status != "paused" {
			return errCampaignState("活动没有暂停")
		}
		_, err = tx.Exec(ctx, `UPDATE src.src_mkt_loop_brand_campaign SET campaign_status='published', update_time=now() WHERE id=$1`, id)
	case "launch":
		if status != "draft" && status != "scheduled" {
			return errCampaignState("只有草稿或未开始的活动可以提前上线")
		}
		_, err = tx.Exec(ctx, `UPDATE src.src_mkt_loop_brand_campaign SET campaign_status='published', start_time=now(), update_time=now() WHERE id=$1`, id)
		if err == nil {
			_, err = tx.Exec(ctx, `UPDATE src.src_mer_loop_drop SET start_time=now(), update_time=now() WHERE campaign_id=$1 AND start_time > now() AND end_time > now()`, id)
		}
	default:
		return httpx.NotFound("操作")
	}
	return err
}
