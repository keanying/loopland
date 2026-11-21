package auth

import (
	"context"
	"fmt"
	"net/url"
	"strings"

	captcha "github.com/alibabacloud-go/captcha-20230305/client"
	dysms "github.com/alibabacloud-go/dysmsapi-20170525/v4/client"
	"github.com/alibabacloud-go/tea/tea"
)

// AliyunAuthFailure reports whether an Aliyun error means the credentials
// or permissions are wrong (as opposed to the expected rejection of a dummy
// request).
func AliyunAuthFailure(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	for _, k := range []string{"InvalidAccessKeyId", "InvalidCredentials", "SignatureDoesNotMatch", "Forbidden", "NoPermission", "InvalidSecurityToken", "isv.ACCOUNT_ABNORMAL"} {
		if strings.Contains(s, k) {
			return true
		}
	}
	return false
}

// Check confirms the AccessKey works and the SMS signature is approved.
func (a *AliyunSMS) Check(context.Context) error {
	resp, err := a.cli.QuerySmsSign(&dysms.QuerySmsSignRequest{SignName: tea.String(a.sign)})
	if err != nil {
		return err
	}
	if resp.Body == nil || tea.StringValue(resp.Body.Code) != "OK" {
		msg := ""
		if resp.Body != nil {
			msg = tea.StringValue(resp.Body.Code) + " " + tea.StringValue(resp.Body.Message)
		}
		return fmt.Errorf("签名查询失败：%s", msg)
	}
	if tea.Int32Value(resp.Body.SignStatus) != 1 {
		return fmt.Errorf("短信签名「%s」尚未审核通过（状态 %d）", a.sign, tea.Int32Value(resp.Body.SignStatus))
	}
	return nil
}

// Check sends a dummy token: a "token invalid" reply proves the AccessKey
// and the 号码认证 product work.
func (a *AliyunOneClick) Check(ctx context.Context) error {
	if a.cli == nil {
		return fmt.Errorf("client not initialised")
	}
	_, err := a.Mobile(ctx, "loopland-doctor-invalid-token")
	if AliyunAuthFailure(err) {
		return err
	}
	return nil
}

// Check verifies a dummy param: a "verify failed" reply proves the
// AccessKey and scene work.
func (a *AliyunCaptcha) Check(ctx context.Context) error {
	resp, err := a.cli.VerifyIntelligentCaptcha(&captcha.VerifyIntelligentCaptchaRequest{
		CaptchaVerifyParam: tea.String("loopland-doctor"), SceneId: tea.String(a.sceneID)})
	if err != nil {
		return err
	}
	if resp.Body != nil && tea.StringValue(resp.Body.Code) != "" && tea.StringValue(resp.Body.Code) != "Success" && !tea.BoolValue(resp.Body.Success) {
		return fmt.Errorf("%s %s", tea.StringValue(resp.Body.Code), tea.StringValue(resp.Body.Message))
	}
	return nil
}

// Check exchanges a dummy code: errcode 40029 (invalid code) proves the
// AppID and AppSecret are accepted.
func (w *WeChatOpen) Check(ctx context.Context) error {
	var tok struct {
		ErrCode int    `json:"errcode"`
		ErrMsg  string `json:"errmsg"`
	}
	q := url.Values{"appid": {w.AppID}, "secret": {w.Secret}, "code": {"loopland-doctor"}, "grant_type": {"authorization_code"}}
	if err := w.get(ctx, "/sns/oauth2/access_token?"+q.Encode(), &tok); err != nil {
		return err
	}
	if tok.ErrCode == 40029 || tok.ErrCode == 40163 {
		return nil
	}
	return fmt.Errorf("微信返回 %d %s（40013=AppID 错误，40125=AppSecret 错误，40164=服务器 IP 不在白名单）", tok.ErrCode, tok.ErrMsg)
}

// Check fetches Apple's signing keys.
func (a *AppleJWKS) Check(ctx context.Context) error {
	if a.BundleID == "" {
		return fmt.Errorf("APPLE_BUNDLE_ID 未设置")
	}
	_, err := a.key(ctx, "loopland-doctor")
	if err != nil && strings.Contains(err.Error(), "unknown apple key") && len(a.keys) > 0 {
		return nil // keys downloaded fine; the dummy kid just isn't among them
	}
	return err
}
