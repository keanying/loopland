// Package adminmsg is the back-office inbox (管理端站内信,
// docs/api/v2-6-管理端图片上传与站内信.md): merchant staff and platform
// accounts get notices about what concerns them (review results,
// promotion invitations and applications, statements, open platform
// problems).
//
// Business code calls Notifier.ToMerchant / ToPlatform. Messages are
// written after the business transaction commits: when the context
// carries an outbox (every HTTP request and every job does, see
// WithOutbox), they wait in it until Settle; otherwise they are written at
// once, so call them outside transactions there. Writing a message never
// fails the business operation: errors are only logged.
package adminmsg

import (
	"context"
	"log/slog"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Categories.
const (
	CatProduct    = "product"
	CatPromotion  = "promotion"
	CatSettlement = "settlement"
	CatOpenAPI    = "openapi"
	CatReview     = "review"
	CatSystem     = "system"
)

// Categories lists the valid categories.
var Categories = map[string]bool{CatProduct: true, CatPromotion: true, CatSettlement: true, CatOpenAPI: true, CatReview: true, CatSystem: true}

// Levels.
const (
	Info    = "info"
	Success = "success"
	Warning = "warning"
	Error   = "error"
)

// Limits of the stored text (runes).
const (
	MaxTitle = 80
	MaxBody  = 300
	// Retention is how long messages are kept.
	Retention = 180 * 24 * time.Hour
)

// Msg is one notice, sent to every recipient of a group.
type Msg struct {
	Category string
	Level    string
	Title    string
	Body     string
	Link     string
	// RefType / RefID name the object the message is about (optional).
	RefType string
	RefID   int64
	// Dedupe skips the message when one with the same RefType and RefID was
	// sent within this window (Webhook failures: once per app per 24h).
	Dedupe time.Duration
}

// Notifier writes messages.
type Notifier struct {
	Pool *pgxpool.Pool
	Log  *slog.Logger
}

// ToMerchant sends m to every enabled staff account of the merchant.
func (n *Notifier) ToMerchant(ctx context.Context, merchantID int64, m Msg) {
	if n == nil || merchantID == 0 {
		return
	}
	n.post(ctx, m, `role='merchant' AND merchant_id=$1`, merchantID)
}

// ToPlatform sends m to every enabled admin and ops account, and to the
// reviewers when includeReviewer.
func (n *Notifier) ToPlatform(ctx context.Context, m Msg, includeReviewer bool) {
	if n == nil {
		return
	}
	roles := []string{"admin", "ops"}
	if includeReviewer {
		roles = append(roles, "reviewer")
	}
	n.post(ctx, m, `role = ANY($1)`, roles)
}

func (n *Notifier) post(ctx context.Context, m Msg, where string, arg any) {
	send := func(ctx context.Context) {
		if err := n.write(ctx, m, where, arg); err != nil && n.Log != nil {
			n.Log.Error("admin message", "title", m.Title, "err", err)
		}
	}
	if ob, ok := ctx.Value(outboxKey{}).(*outbox); ok {
		ob.add(send)
		return
	}
	send(ctx)
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}

func (n *Notifier) write(ctx context.Context, m Msg, where string, arg any) error {
	if !Categories[m.Category] {
		m.Category = CatSystem
	}
	switch m.Level {
	case Info, Success, Warning, Error:
	default:
		m.Level = Info
	}
	var link, refType, refID any
	if m.Link != "" {
		link = m.Link
	}
	if m.RefType != "" {
		refType, refID = m.RefType, m.RefID
	}
	return pgx.BeginFunc(ctx, n.Pool, func(tx pgx.Tx) error {
		if m.Dedupe > 0 && m.RefType != "" {
			if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(7310003, hashtext($1 || ':' || $2::bigint::text))`, m.RefType, m.RefID); err != nil {
				return err
			}
			var sent bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM src.src_msg_loop_admin_message WHERE ref_type=$1 AND ref_id=$2 AND create_time > $3)`,
				m.RefType, m.RefID, time.Now().Add(-m.Dedupe)).Scan(&sent); err != nil || sent {
				return err
			}
		}
		_, err := tx.Exec(ctx, `INSERT INTO src.src_msg_loop_admin_message (admin_id, category_type, level_type, title, body_text, link_url, ref_type, ref_id)
			SELECT id, $2, $3, $4, $5, $6, $7, $8 FROM src.src_sys_loop_admin WHERE NOT is_disabled AND `+where,
			arg, m.Category, m.Level, clip(m.Title, MaxTitle), clip(m.Body, MaxBody), link, refType, refID)
		return err
	})
}

// ---------------------------------------------------------------- outbox

type outboxKey struct{}

type outbox struct {
	mu  sync.Mutex
	fns []func(context.Context)
}

func (o *outbox) add(f func(context.Context)) {
	o.mu.Lock()
	o.fns = append(o.fns, f)
	o.mu.Unlock()
}

func (o *outbox) take() []func(context.Context) {
	o.mu.Lock()
	defer o.mu.Unlock()
	fns := o.fns
	o.fns = nil
	return fns
}

// WithOutbox returns a context whose messages wait until Settle.
func WithOutbox(ctx context.Context) context.Context {
	return context.WithValue(ctx, outboxKey{}, &outbox{})
}

// Settle writes the waiting messages when ok (the work committed) and
// drops them otherwise. It can be called several times (after each
// transaction of a job).
func Settle(ctx context.Context, ok bool) {
	ob, _ := ctx.Value(outboxKey{}).(*outbox)
	if ob == nil {
		return
	}
	fns := ob.take()
	if !ok || len(fns) == 0 {
		return
	}
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	for _, f := range fns {
		f(wctx)
	}
}

// WrapJobs gives each job its own outbox, settled when the job returns.
func WrapJobs(jobs map[string]func(context.Context) error) map[string]func(context.Context) error {
	out := make(map[string]func(context.Context) error, len(jobs))
	for k, f := range jobs {
		out[k] = func(ctx context.Context) error {
			ctx = WithOutbox(ctx)
			err := f(ctx)
			Settle(ctx, err == nil)
			return err
		}
	}
	return out
}
