// Package billing is 会员: plans, orders, payment channels, callbacks,
// membership grants, auto-renew, refunds.
//
// Channels (docs/调研/登录与支付依赖选型.md): WeChat Pay V3 and Alipay through
// go-pay/gopay, Apple In-App Purchase (mandatory for virtual goods on iOS)
// verified as App Store signed JWS, and a mock channel in dev. Stripe/PayPal
// are not needed for a mainland launch.
package billing

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/go-pay/gopay"
	"github.com/go-pay/gopay/alipay"
	wechat "github.com/go-pay/gopay/wechat/v3"
)

// Channels.
const (
	WeChatApp = "wechat_app"
	AlipayApp = "alipay_app"
	AppleIAP  = "apple_iap"
	Mock      = "mock"
)

// ErrUnsupported is returned when a channel can't do something.
var ErrUnsupported = errors.New("not supported by this channel")

// Paid is a verified payment notification.
type Paid struct {
	OrderNo   string
	TradeNo   string
	AmountFen int
	PaidAt    time.Time
}

// Provider is one payment channel.
type Provider interface {
	// Create returns the parameters the app needs to open the payment sheet.
	Create(ctx context.Context, o Order, p Plan, clientIP string) (map[string]any, error)
	// ParseNotify verifies a callback's signature and decodes it. nil Paid
	// with nil error means "acknowledged, nothing to do".
	ParseNotify(r *http.Request) (*Paid, error)
	// Ack writes the success response the channel expects.
	Ack(w http.ResponseWriter)
	// Refund returns the full amount through the original channel.
	Refund(ctx context.Context, o Order, reason string) error
	// Charge takes a renewal payment without the user present (周期扣款).
	Charge(ctx context.Context, o Order) (tradeNo string, err error)
}

// ---------------------------------------------------------------- WeChat Pay V3

// WeChatPay is APP payment through WeChat Pay API v3.
type WeChatPay struct {
	AppID, MchID, APIv3Key, NotifyURL string
	cli                               *wechat.ClientV3
}

// NewWeChatPay builds the client and enables response signature checks with
// the WeChat Pay platform public key.
func NewWeChatPay(appID, mchID, serialNo, apiV3Key, privateKey, pubKey, pubKeyID, notifyURL string) (*WeChatPay, error) {
	cli, err := wechat.NewClientV3(mchID, serialNo, apiV3Key, privateKey)
	if err != nil {
		return nil, err
	}
	if err := cli.AutoVerifySignByPublicKey([]byte(pubKey), pubKeyID); err != nil {
		return nil, err
	}
	return &WeChatPay{AppID: appID, MchID: mchID, APIv3Key: apiV3Key, NotifyURL: notifyURL, cli: cli}, nil
}

// Create implements Provider.
func (w *WeChatPay) Create(ctx context.Context, o Order, p Plan, _ string) (map[string]any, error) {
	bm := make(gopay.BodyMap)
	bm.Set("appid", w.AppID).Set("description", subject(o, p)).Set("out_trade_no", o.OrderNo).
		Set("time_expire", time.Now().Add(2*time.Hour).Format(time.RFC3339)).Set("notify_url", w.NotifyURL).
		SetBodyMap("amount", func(b gopay.BodyMap) { b.Set("total", o.AmountFen).Set("currency", "CNY") })
	rsp, err := w.cli.V3TransactionApp(ctx, bm)
	if err != nil {
		return nil, err
	}
	if rsp.Code != 0 || rsp.Response == nil {
		return nil, fmt.Errorf("wechat prepay: %s", rsp.Error)
	}
	app, err := w.cli.PaySignOfApp(w.AppID, rsp.Response.PrepayId)
	if err != nil {
		return nil, err
	}
	return map[string]any{"appid": app.Appid, "partnerid": app.Partnerid, "prepayid": app.Prepayid, "package": app.Package,
		"noncestr": app.Noncestr, "timestamp": app.Timestamp, "sign": app.Sign}, nil
}

// ParseNotify implements Provider.
func (w *WeChatPay) ParseNotify(r *http.Request) (*Paid, error) {
	n, err := wechat.V3ParseNotify(r)
	if err != nil {
		return nil, err
	}
	if err := n.VerifySignByPK(w.cli.WxPublicKey()); err != nil {
		return nil, fmt.Errorf("wechat notify signature: %w", err)
	}
	res, err := n.DecryptPayCipherText(w.APIv3Key)
	if err != nil {
		return nil, err
	}
	if res.TradeState != "SUCCESS" || res.Amount == nil {
		return nil, nil
	}
	t, _ := time.Parse(time.RFC3339, res.SuccessTime)
	return &Paid{OrderNo: res.OutTradeNo, TradeNo: res.TransactionId, AmountFen: res.Amount.Total, PaidAt: t}, nil
}

// Ack implements Provider.
func (w *WeChatPay) Ack(rw http.ResponseWriter) {
	rw.Header().Set("Content-Type", "application/json")
	_, _ = rw.Write([]byte(`{"code":"SUCCESS","message":"成功"}`))
}

// Refund implements Provider.
func (w *WeChatPay) Refund(ctx context.Context, o Order, reason string) error {
	bm := make(gopay.BodyMap)
	bm.Set("out_trade_no", o.OrderNo).Set("out_refund_no", "R"+o.OrderNo).Set("reason", reason).
		SetBodyMap("amount", func(b gopay.BodyMap) {
			b.Set("refund", o.AmountFen).Set("total", o.AmountFen).Set("currency", "CNY")
		})
	rsp, err := w.cli.V3Refund(ctx, bm)
	if err != nil {
		return err
	}
	if rsp.Code != 0 {
		return fmt.Errorf("wechat refund: %s", rsp.Error)
	}
	return nil
}

// Charge implements Provider. WeChat 委托代扣 needs the papay contract to be
// signed during the first purchase; that product is not activated yet.
func (w *WeChatPay) Charge(context.Context, Order) (string, error) { return "", ErrUnsupported }

// ---------------------------------------------------------------- Alipay

// Alipay is APP payment through Alipay.
type Alipay struct {
	PublicKey, NotifyURL string
	cli                  *alipay.Client
}

// NewAlipay builds the client.
func NewAlipay(appID, privateKey, publicKey, notifyURL string, sandbox bool) (*Alipay, error) {
	cli, err := alipay.NewClient(appID, privateKey, !sandbox)
	if err != nil {
		return nil, err
	}
	cli.SetCharset(alipay.UTF8).SetSignType(alipay.RSA2).SetNotifyUrl(notifyURL)
	return &Alipay{PublicKey: publicKey, NotifyURL: notifyURL, cli: cli}, nil
}

// subject is the goods description shown on the payment sheet.
func subject(o Order, p Plan) string {
	if o.BizType != "" && o.BizType != BizMembership {
		return "圈圈-" + o.PlanName
	}
	return "圈圈会员-" + p.Name
}

func yuan(fen int) string { return strconv.FormatFloat(float64(fen)/100, 'f', 2, 64) }

// Create implements Provider.
func (a *Alipay) Create(ctx context.Context, o Order, p Plan, _ string) (map[string]any, error) {
	bm := make(gopay.BodyMap)
	bm.Set("subject", subject(o, p)).Set("out_trade_no", o.OrderNo).Set("total_amount", yuan(o.AmountFen)).
		Set("timeout_express", "2h")
	s, err := a.cli.TradeAppPay(ctx, bm)
	if err != nil {
		return nil, err
	}
	return map[string]any{"order_string": s}, nil
}

// ParseNotify implements Provider.
func (a *Alipay) ParseNotify(r *http.Request) (*Paid, error) {
	bm, err := alipay.ParseNotifyToBodyMap(r)
	if err != nil {
		return nil, err
	}
	ok, err := alipay.VerifySign(a.PublicKey, bm)
	if err != nil || !ok {
		return nil, fmt.Errorf("alipay notify signature: %v", err)
	}
	st := bm.GetString("trade_status")
	if st != "TRADE_SUCCESS" && st != "TRADE_FINISHED" {
		return nil, nil
	}
	amt, err := strconv.ParseFloat(bm.GetString("total_amount"), 64)
	if err != nil {
		return nil, err
	}
	t, _ := time.ParseInLocation("2006-01-02 15:04:05", bm.GetString("gmt_payment"), time.Local)
	return &Paid{OrderNo: bm.GetString("out_trade_no"), TradeNo: bm.GetString("trade_no"), AmountFen: int(amt*100 + 0.5), PaidAt: t}, nil
}

// Ack implements Provider.
func (a *Alipay) Ack(rw http.ResponseWriter) { _, _ = rw.Write([]byte("success")) }

// Refund implements Provider.
func (a *Alipay) Refund(ctx context.Context, o Order, reason string) error {
	bm := make(gopay.BodyMap)
	bm.Set("out_trade_no", o.OrderNo).Set("refund_amount", yuan(o.AmountFen)).Set("refund_reason", reason).Set("out_request_no", "R"+o.OrderNo)
	rsp, err := a.cli.TradeRefund(ctx, bm)
	if err != nil {
		return err
	}
	if rsp.Response == nil || rsp.Response.Code != "10000" {
		return fmt.Errorf("alipay refund failed")
	}
	return nil
}

// Charge implements Provider. Alipay 周期扣款 needs an agreement signed with
// the first payment; not activated yet.
func (a *Alipay) Charge(context.Context, Order) (string, error) { return "", ErrUnsupported }

// ---------------------------------------------------------------- Apple

// AppleStore verifies App Store signed transactions. Payment happens on the
// device; Create only returns the product and appAccountToken.
type AppleStore struct {
	BundleID string
	Verifier *AppleVerifier
}

// NewAppleStore pins Apple's root (see AppleVerifier).
func NewAppleStore(bundleID string) *AppleStore {
	return &AppleStore{BundleID: bundleID, Verifier: NewAppleVerifier()}
}

// Create implements Provider.
func (a *AppleStore) Create(_ context.Context, o Order, p Plan, _ string) (map[string]any, error) {
	if p.AppleProductID == nil || o.AppAccountToken == nil {
		return nil, fmt.Errorf("plan %s has no App Store product", p.Code)
	}
	return map[string]any{"product_id": *p.AppleProductID, "app_account_token": o.AppAccountToken.String()}, nil
}

// ParseNotify implements Provider; App Store notifications are handled by
// Service.AppleNotification instead.
func (a *AppleStore) ParseNotify(*http.Request) (*Paid, error) { return nil, ErrUnsupported }

// Ack implements Provider.
func (a *AppleStore) Ack(rw http.ResponseWriter) { rw.WriteHeader(http.StatusOK) }

// Refund implements Provider: Apple refunds are requested by the user from
// Apple; we learn about them through the REFUND notification.
func (a *AppleStore) Refund(context.Context, Order, string) error { return ErrUnsupported }

// Charge implements Provider: Apple renews subscriptions itself.
func (a *AppleStore) Charge(context.Context, Order) (string, error) { return "", ErrUnsupported }

// ---------------------------------------------------------------- Mock

// MockPay succeeds at everything (dev only).
type MockPay struct{}

// Create implements Provider.
func (MockPay) Create(context.Context, Order, Plan, string) (map[string]any, error) {
	return map[string]any{}, nil
}

// ParseNotify implements Provider.
func (MockPay) ParseNotify(*http.Request) (*Paid, error) { return nil, ErrUnsupported }

// Ack implements Provider.
func (MockPay) Ack(rw http.ResponseWriter) { rw.WriteHeader(http.StatusOK) }

// Refund implements Provider.
func (MockPay) Refund(context.Context, Order, string) error { return nil }

// Charge implements Provider.
func (MockPay) Charge(_ context.Context, o Order) (string, error) { return "MOCK-" + o.OrderNo, nil }
