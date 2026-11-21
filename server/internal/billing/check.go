package billing

import (
	"context"
	"fmt"
	"strings"

	"github.com/go-pay/gopay"
	wechat "github.com/go-pay/gopay/wechat/v3"
)

const doctorOrder = "LPDOCTOR0000000000"

// Check queries an order that cannot exist: ORDER_NOT_EXIST proves the
// merchant id, certificate serial, private key and platform public key
// (response signature) all work.
func (w *WeChatPay) Check(ctx context.Context) error {
	rsp, err := w.cli.V3TransactionQueryOrder(ctx, wechat.OutTradeNo, doctorOrder)
	if err != nil {
		return err
	}
	if rsp.Code == 404 || rsp.ErrResponse.Code == "ORDER_NOT_EXIST" {
		return nil
	}
	if rsp.Code == 0 {
		return nil
	}
	return fmt.Errorf("微信支付返回 %d %s %s", rsp.Code, rsp.ErrResponse.Code, rsp.ErrResponse.Message)
}

// Check queries an order that cannot exist: ACQ.TRADE_NOT_EXIST proves the
// app id, private key and Alipay public key work.
func (a *Alipay) Check(ctx context.Context) error {
	bm := make(gopay.BodyMap)
	bm.Set("out_trade_no", doctorOrder)
	_, err := a.cli.TradeQuery(ctx, bm)
	if err == nil || strings.Contains(err.Error(), "ACQ.TRADE_NOT_EXIST") {
		return nil
	}
	return err
}
