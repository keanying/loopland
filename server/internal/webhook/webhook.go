// Package webhook records merchant events and pushes them to the open
// platform apps that subscribed (docs/api/v2-5-商户商品与开放平台.md
// «Webhook»). Business modules call Emit inside their own transaction; the
// Dispatcher delivers the queued deliveries, signs each request with the
// app secret and retries failures 1m / 5m / 30m / 2h / 6h (6 attempts).
package webhook

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/platform/secure"
)

// Event types.
const (
	ProductReviewed        = "product.reviewed"
	PromotionEntryInvited  = "promotion_entry.invited"
	PromotionEntryApproved = "promotion_entry.approved"
	PromotionEntryRejected = "promotion_entry.rejected"
	PromotionEntryRemoved  = "promotion_entry.removed"
	ProductOrderPaid       = "product_order.paid"
	ProductOrderRefunded   = "product_order.refunded"
	BookingPaid            = "booking.paid"
	BookingCancelled       = "booking.cancelled"
	BookingRefunded        = "booking.refunded"
	RedemptionCreated      = "redemption.created"
	RedemptionVoided       = "redemption.voided"
	StatementCreated       = "statement.created"
	Ping                   = "ping"
)

// Scope is the open platform scope an app needs to receive an event
// (ping needs none).
var Scope = map[string]string{
	ProductReviewed:        "products",
	PromotionEntryInvited:  "promotions",
	PromotionEntryApproved: "promotions",
	PromotionEntryRejected: "promotions",
	PromotionEntryRemoved:  "promotions",
	ProductOrderPaid:       "orders",
	ProductOrderRefunded:   "orders",
	BookingPaid:            "bookings",
	BookingCancelled:       "bookings",
	BookingRefunded:        "bookings",
	RedemptionCreated:      "redemptions",
	RedemptionVoided:       "redemptions",
	StatementCreated:       "statements",
	Ping:                   "",
}

// Attempts is the number of tries before a delivery is marked failed.
const Attempts = 6

// Backoff is the wait after the n-th failed attempt (n = 1..5).
var Backoff = []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute, 2 * time.Hour, 6 * time.Hour}

// Timeout is how long the receiver has to answer.
const Timeout = 10 * time.Second

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// newEventNo is evt_ + a ULID (48-bit milliseconds + 80 random bits,
// Crockford base32): unique and sortable by time.
func newEventNo(t time.Time) string {
	var b [16]byte
	ms := uint64(t.UnixMilli())
	for i := 5; i >= 0; i-- {
		b[i] = byte(ms)
		ms >>= 8
	}
	if _, err := rand.Read(b[6:]); err != nil {
		panic(err)
	}
	// 128 bits → 26 base32 characters (the first carries 3 bits).
	n := new(big.Int).SetBytes(b[:])
	out := make([]byte, 26)
	mask := big.NewInt(31)
	for j := 25; j >= 0; j-- {
		out[j] = crockford[new(big.Int).And(n, mask).Int64()]
		n.Rsh(n, 5)
	}
	return "evt_" + string(out)
}

// Payload is the request body of a delivery.
type Payload struct {
	ID         string    `json:"id"`
	Type       string    `json:"type"`
	CreatedAt  time.Time `json:"created_at"`
	MerchantID int64     `json:"merchant_id"`
	Data       any       `json:"data"`
}

// Emit records an event for the merchant's active apps that subscribed to
// it and have its scope, inside the caller's transaction. Nothing is
// stored when no app wants it.
func Emit(ctx context.Context, q db.Querier, merchantID int64, typ string, data any) error {
	scope, ok := Scope[typ]
	if !ok {
		return fmt.Errorf("unknown webhook event %q", typ)
	}
	rows, err := q.Query(ctx, `SELECT a.id FROM src.src_mer_loop_open_app a JOIN src.src_mer_loop_merchant m ON m.id=a.merchant_id
		WHERE a.merchant_id=$1 AND a.app_status='active' AND m.merchant_status <> 'suspended' AND COALESCE(a.webhook_url, '') <> ''
		  AND $2 = ANY(a.webhook_events) AND ($3 = '' OR $3 = ANY(a.scopes))`, merchantID, typ, scope)
	if err != nil {
		return err
	}
	apps, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil || len(apps) == 0 {
		return err
	}
	_, err = record(ctx, q, merchantID, typ, data, apps)
	return err
}

// record stores the event and one pending delivery per app; it returns
// the delivery ids.
func record(ctx context.Context, q db.Querier, merchantID int64, typ string, data any, apps []int64) ([]int64, error) {
	now := time.Now()
	p := Payload{ID: newEventNo(now), Type: typ, CreatedAt: now.In(clock.Shanghai).Truncate(time.Second), MerchantID: merchantID, Data: data}
	raw, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	var eventID int64
	if err := q.QueryRow(ctx, `INSERT INTO src.src_mer_loop_webhook_event (event_no, merchant_id, event_type, payload_json, create_time)
		VALUES ($1,$2,$3,$4,$5) RETURNING id`, p.ID, merchantID, typ, raw, now).Scan(&eventID); err != nil {
		return nil, err
	}
	rows, err := q.Query(ctx, `INSERT INTO src.src_mer_loop_webhook_delivery (event_id, open_app_id, next_retry_time)
		SELECT $1, unnest($2::bigint[]), now() RETURNING id`, eventID, apps)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[int64])
}

// Sign is hex(HMAC-SHA256(secret, timestamp + "." + body)).
func Sign(secret string, ts int64, body []byte) string {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(strconv.FormatInt(ts, 10)))
	m.Write([]byte("."))
	m.Write(body)
	return hex.EncodeToString(m.Sum(nil))
}

// Delivery is a delivery record (管理端 投递记录).
type Delivery struct {
	ID             int64      `json:"id"`
	EventID        string     `json:"event_id"`
	EventType      string     `json:"event_type"`
	Status         string     `json:"status"`
	AttemptQty     int        `json:"attempt_qty"`
	LastStatusCode *int       `json:"last_status_code"`
	LastError      *string    `json:"last_error"`
	NextRetryAt    *time.Time `json:"next_retry_at"`
	CreatedAt      time.Time  `json:"created_at"`
}

const deliveryCols = `d.id, e.event_no, e.event_type, d.delivery_status, d.attempt_qty, d.last_status_code, d.last_error, d.next_retry_time, d.create_time`

const deliveryFrom = ` FROM src.src_mer_loop_webhook_delivery d JOIN src.src_mer_loop_webhook_event e ON e.id=d.event_id `

func scanDelivery(r pgx.Row) (Delivery, error) {
	var d Delivery
	err := r.Scan(&d.ID, &d.EventID, &d.EventType, &d.Status, &d.AttemptQty, &d.LastStatusCode, &d.LastError, &d.NextRetryAt, &d.CreatedAt)
	return d, err
}

// Deliveries lists an app's deliveries, newest first.
func Deliveries(ctx context.Context, q db.Querier, appID int64, p httpx.Page) ([]Delivery, int, error) {
	var total int
	if err := q.QueryRow(ctx, `SELECT count(*) FROM src.src_mer_loop_webhook_delivery WHERE open_app_id=$1`, appID).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := q.Query(ctx, `SELECT `+deliveryCols+deliveryFrom+` WHERE d.open_app_id=$1 ORDER BY d.id DESC LIMIT $2 OFFSET $3`, appID, p.Size, p.Offset())
	if err != nil {
		return nil, 0, err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Delivery, error) { return scanDelivery(r) })
	if items == nil {
		items = []Delivery{}
	}
	return items, total, err
}

// LoadDelivery loads one delivery of an app.
func LoadDelivery(ctx context.Context, q db.Querier, appID, id int64) (Delivery, error) {
	d, err := scanDelivery(q.QueryRow(ctx, `SELECT `+deliveryCols+deliveryFrom+` WHERE d.id=$1 AND d.open_app_id=$2`, id, appID))
	if db.IsNoRows(err) {
		return d, httpx.NotFound("投递记录")
	}
	return d, err
}

// FailedApps counts apps with a failed delivery in the last 24 hours
// (总览待办 webhook_failed).
func FailedApps(ctx context.Context, q db.Querier) (int, error) {
	var n int
	err := q.QueryRow(ctx, `SELECT count(DISTINCT open_app_id) FROM src.src_mer_loop_webhook_delivery
		WHERE delivery_status='failed' AND update_time > now() - interval '24 hours'`).Scan(&n)
	return n, err
}

// ---------------------------------------------------------------- delivery

// Dispatcher sends queued deliveries.
type Dispatcher struct {
	Pool *pgxpool.Pool
	Box  *secure.Box
	Log  *slog.Logger
	// HTTP overrides the client (tests); default has Timeout and does not
	// follow redirects.
	HTTP *http.Client
}

func (d *Dispatcher) client() *http.Client {
	if d.HTTP != nil {
		return d.HTTP
	}
	return &http.Client{Timeout: Timeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

// Run polls for due deliveries every few seconds until ctx ends (the job
// runner also calls DeliverDue every tick).
func (d *Dispatcher) Run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := d.DeliverDue(ctx); err != nil && ctx.Err() == nil {
				d.Log.Error("webhook deliver", "err", err)
			}
		}
	}
}

// DeliverDue sends every pending delivery whose time has come. Each one is
// leased for 2 minutes first, so concurrent runners do not send it twice.
func (d *Dispatcher) DeliverDue(ctx context.Context) error {
	rows, err := d.Pool.Query(ctx, `UPDATE src.src_mer_loop_webhook_delivery SET next_retry_time = now() + interval '2 minutes'
		WHERE id IN (SELECT id FROM src.src_mer_loop_webhook_delivery WHERE delivery_status='pending' AND next_retry_time <= now()
			ORDER BY next_retry_time LIMIT 50 FOR UPDATE SKIP LOCKED) RETURNING id`)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	for _, id := range ids {
		if _, err := d.attempt(ctx, id, false); err != nil {
			d.Log.Error("webhook attempt", "delivery", id, "err", err)
		}
	}
	return nil
}

// Redeliver sends one delivery of the app now (管理端「重发」).
func (d *Dispatcher) Redeliver(ctx context.Context, appID, id int64) (Delivery, error) {
	if _, err := LoadDelivery(ctx, d.Pool, appID, id); err != nil {
		return Delivery{}, err
	}
	if _, err := d.attempt(ctx, id, true); err != nil {
		return Delivery{}, err
	}
	return LoadDelivery(ctx, d.Pool, appID, id)
}

// Ping records a ping event for one app and sends it at once (管理端「发送
// 测试事件」); the app does not need to subscribe to it.
func (d *Dispatcher) Ping(ctx context.Context, appID int64) (Delivery, error) {
	var merchant int64
	var url *string
	if err := d.Pool.QueryRow(ctx, `SELECT merchant_id, webhook_url FROM src.src_mer_loop_open_app WHERE id=$1`, appID).Scan(&merchant, &url); err != nil {
		if db.IsNoRows(err) {
			return Delivery{}, httpx.NotFound("应用")
		}
		return Delivery{}, err
	}
	if url == nil || *url == "" {
		return Delivery{}, httpx.BadRequest("no_webhook_url", "请先填写 Webhook 地址")
	}
	ids, err := record(ctx, d.Pool, merchant, Ping, map[string]any{"message": "pong", "app_id": appID}, []int64{appID})
	if err != nil {
		return Delivery{}, err
	}
	if _, err := d.attempt(ctx, ids[0], true); err != nil {
		return Delivery{}, err
	}
	return LoadDelivery(ctx, d.Pool, appID, ids[0])
}

var errStopped = errors.New("应用已停用或商户已暂停合作，停止推送")

// attempt sends a delivery once and records the outcome. manual attempts
// (redeliver, ping) do not move a failed delivery back to the retry queue.
func (d *Dispatcher) attempt(ctx context.Context, id int64, manual bool) (bool, error) {
	var url *string
	var secretEnc, body []byte
	var appStatus, merchantStatus, status, typ string
	var attempts int
	err := d.Pool.QueryRow(ctx, `SELECT a.webhook_url, a.app_secret_enc, a.app_status, m.merchant_status, e.payload_json::text, e.event_type,
			dl.delivery_status, dl.attempt_qty
		FROM src.src_mer_loop_webhook_delivery dl JOIN src.src_mer_loop_webhook_event e ON e.id=dl.event_id
		JOIN src.src_mer_loop_open_app a ON a.id=dl.open_app_id JOIN src.src_mer_loop_merchant m ON m.id=a.merchant_id
		WHERE dl.id=$1`, id).Scan(&url, &secretEnc, &appStatus, &merchantStatus, &body, &typ, &status, &attempts)
	if err != nil {
		return false, err
	}
	if appStatus != "active" || merchantStatus == "suspended" || url == nil || *url == "" {
		_, err := d.Pool.Exec(ctx, `UPDATE src.src_mer_loop_webhook_delivery SET delivery_status='failed', last_error=$2, next_retry_time=NULL,
			update_time=now() WHERE id=$1`, id, errStopped.Error())
		return false, err
	}
	secret, err := d.Box.Open(secretEnc)
	if err != nil {
		return false, err
	}
	code, sendErr := d.send(ctx, *url, secret, typ, id, body)
	ok := sendErr == nil && code >= 200 && code < 300
	var lastErr *string
	var lastCode *int
	if code != 0 {
		lastCode = &code
	}
	if !ok {
		msg := fmt.Sprintf("HTTP %d", code)
		if sendErr != nil {
			msg = sendErr.Error()
		}
		if len(msg) > 300 {
			msg = msg[:300]
		}
		lastErr = &msg
	}
	attempts++
	newStatus, next := "succeeded", (*time.Time)(nil)
	if !ok {
		switch {
		case manual && status != "pending":
			newStatus = "failed"
		case attempts >= Attempts:
			newStatus = "failed"
		default:
			newStatus = "pending"
			t := time.Now().Add(Backoff[min(attempts, len(Backoff))-1])
			next = &t
		}
	}
	_, err = d.Pool.Exec(ctx, `UPDATE src.src_mer_loop_webhook_delivery SET delivery_status=$2, attempt_qty=$3, last_status_code=$4, last_error=$5,
			next_retry_time=$6, last_attempt_time=now(), update_time=now() WHERE id=$1`, id, newStatus, attempts, lastCode, lastErr, next)
	return ok, err
}

func (d *Dispatcher) send(ctx context.Context, url, secret, typ string, deliveryID int64, body []byte) (int, error) {
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	ts := time.Now().Unix()
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "Loopland-Webhook/1")
	req.Header.Set("X-Loop-Event", typ)
	req.Header.Set("X-Loop-Delivery", strconv.FormatInt(deliveryID, 10))
	req.Header.Set("X-Loop-Timestamp", strconv.FormatInt(ts, 10))
	req.Header.Set("X-Loop-Signature", Sign(secret, ts, body))
	resp, err := d.client().Do(req)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || strings.Contains(err.Error(), "Client.Timeout") {
			return 0, errors.New("对方 10 秒内没有响应")
		}
		return 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	return resp.StatusCode, nil
}

// Jobs are the periodic jobs: due deliveries and the 7-day call-log cleanup.
func (d *Dispatcher) Jobs() map[string]func(context.Context) error {
	return map[string]func(context.Context) error{
		"webhook_deliver": d.DeliverDue,
		"open_call_log_cleanup": func(ctx context.Context) error {
			_, err := d.Pool.Exec(ctx, `DELETE FROM src.src_mer_loop_open_call_log WHERE create_time < now() - interval '7 days'`)
			return err
		},
	}
}
