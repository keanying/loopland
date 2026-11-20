// Package auth is 统一登录: SMS code, operator one-click login, WeChat and
// Sign in with Apple, all mapped to one account keyed by phone number, plus
// JWT access tokens with rotating refresh tokens.
//
// Approach (docs/调研/登录与支付依赖选型.md, 方案 B): the app sends codes and
// tokens straight to the backend, so the WeChat and Apple exchanges are plain
// HTTPS calls rather than goth's browser redirect flows; SMS and 一键登录 use
// the Aliyun SDKs. Each external service sits behind an interface so it can
// be swapped (技术选型: 能替换).
package auth

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	openapi "github.com/alibabacloud-go/darabonba-openapi/v2/client"
	dypns "github.com/alibabacloud-go/dypnsapi-20170525/v2/client"
	dysms "github.com/alibabacloud-go/dysmsapi-20170525/v4/client"
	"github.com/alibabacloud-go/tea/tea"
	"github.com/golang-jwt/jwt/v5"
)

// ErrProvider wraps failures of an external identity service.
var ErrProvider = errors.New("provider error")

// SMSSender delivers verification codes.
type SMSSender interface {
	Send(ctx context.Context, phone, code string) error
}

// OneClick exchanges an operator token (运营商一键登录) for a phone number.
type OneClick interface {
	Mobile(ctx context.Context, token string) (string, error)
}

// WeChatIdentity is what WeChat returns for an app login code.
type WeChatIdentity struct {
	OpenID, UnionID, Nickname, Avatar string
}

// WeChat exchanges an app authorisation code.
type WeChat interface {
	Exchange(ctx context.Context, code string) (WeChatIdentity, error)
}

// Apple verifies a Sign in with Apple identity token and returns its subject.
type Apple interface {
	Verify(ctx context.Context, identityToken string) (string, error)
}

// Captcha verifies the 人机验证 token sent with SMS requests.
type Captcha interface {
	Verify(ctx context.Context, token, ip string) error
}

// ---------------------------------------------------------------- Aliyun

func aliyunConfig(ak, sk, endpoint string) *openapi.Config {
	return &openapi.Config{AccessKeyId: tea.String(ak), AccessKeySecret: tea.String(sk), Endpoint: tea.String(endpoint)}
}

// AliyunSMS sends through 阿里云短信服务.
type AliyunSMS struct {
	cli        *dysms.Client
	sign, tmpl string
}

// NewAliyunSMS builds the sender.
func NewAliyunSMS(ak, sk, sign, tmpl string) (*AliyunSMS, error) {
	cli, err := dysms.NewClient(aliyunConfig(ak, sk, "dysmsapi.aliyuncs.com"))
	if err != nil {
		return nil, err
	}
	return &AliyunSMS{cli: cli, sign: sign, tmpl: tmpl}, nil
}

// Send implements SMSSender.
func (a *AliyunSMS) Send(_ context.Context, phone, code string) error {
	param, _ := json.Marshal(map[string]string{"code": code})
	resp, err := a.cli.SendSms(&dysms.SendSmsRequest{
		PhoneNumbers: tea.String(phone), SignName: tea.String(a.sign),
		TemplateCode: tea.String(a.tmpl), TemplateParam: tea.String(string(param)),
	})
	if err != nil {
		return fmt.Errorf("%w: sms: %v", ErrProvider, err)
	}
	if resp.Body == nil || tea.StringValue(resp.Body.Code) != "OK" {
		msg := ""
		if resp.Body != nil {
			msg = tea.StringValue(resp.Body.Message)
		}
		return fmt.Errorf("%w: sms: %s", ErrProvider, msg)
	}
	return nil
}

// AliyunOneClick uses 阿里云号码认证 GetMobile.
type AliyunOneClick struct{ cli *dypns.Client }

// NewAliyunOneClick builds the client.
func NewAliyunOneClick(ak, sk string) (*AliyunOneClick, error) {
	cli, err := dypns.NewClient(aliyunConfig(ak, sk, "dypnsapi.aliyuncs.com"))
	if err != nil {
		return nil, err
	}
	return &AliyunOneClick{cli: cli}, nil
}

// Mobile implements OneClick.
func (a *AliyunOneClick) Mobile(_ context.Context, token string) (string, error) {
	resp, err := a.cli.GetMobile(&dypns.GetMobileRequest{AccessToken: tea.String(token)})
	if err != nil {
		return "", fmt.Errorf("%w: getmobile: %v", ErrProvider, err)
	}
	if resp.Body == nil || tea.StringValue(resp.Body.Code) != "OK" || resp.Body.GetMobileResultDTO == nil {
		msg := ""
		if resp.Body != nil {
			msg = tea.StringValue(resp.Body.Message)
		}
		return "", fmt.Errorf("%w: getmobile: %s", ErrProvider, msg)
	}
	return tea.StringValue(resp.Body.GetMobileResultDTO.Mobile), nil
}

// ---------------------------------------------------------------- WeChat

// WeChatOpen is the 微信开放平台 mobile-app login.
type WeChatOpen struct {
	AppID, Secret string
	HTTP          *http.Client
	Base          string // https://api.weixin.qq.com
}

// Exchange implements WeChat.
func (w *WeChatOpen) Exchange(ctx context.Context, code string) (WeChatIdentity, error) {
	var tok struct {
		AccessToken string `json:"access_token"`
		OpenID      string `json:"openid"`
		UnionID     string `json:"unionid"`
		ErrCode     int    `json:"errcode"`
		ErrMsg      string `json:"errmsg"`
	}
	q := url.Values{"appid": {w.AppID}, "secret": {w.Secret}, "code": {code}, "grant_type": {"authorization_code"}}
	if err := w.get(ctx, "/sns/oauth2/access_token?"+q.Encode(), &tok); err != nil {
		return WeChatIdentity{}, err
	}
	if tok.ErrCode != 0 || tok.OpenID == "" {
		return WeChatIdentity{}, fmt.Errorf("%w: wechat %d %s", ErrProvider, tok.ErrCode, tok.ErrMsg)
	}
	id := WeChatIdentity{OpenID: tok.OpenID, UnionID: tok.UnionID}
	var info struct {
		Nickname   string `json:"nickname"`
		HeadImgURL string `json:"headimgurl"`
		UnionID    string `json:"unionid"`
	}
	q = url.Values{"access_token": {tok.AccessToken}, "openid": {tok.OpenID}}
	if err := w.get(ctx, "/sns/userinfo?"+q.Encode(), &info); err == nil {
		id.Nickname, id.Avatar = info.Nickname, info.HeadImgURL
		if id.UnionID == "" {
			id.UnionID = info.UnionID
		}
	}
	return id, nil
}

func (w *WeChatOpen) get(ctx context.Context, path string, v any) error {
	base := w.Base
	if base == "" {
		base = "https://api.weixin.qq.com"
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, base+path, nil)
	c := w.HTTP
	if c == nil {
		c = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := c.Do(req)
	if err != nil {
		return fmt.Errorf("%w: wechat: %v", ErrProvider, err)
	}
	defer resp.Body.Close()
	return json.NewDecoder(resp.Body).Decode(v)
}

// ---------------------------------------------------------------- Apple

// AppleJWKS verifies identity tokens against Apple's published keys.
type AppleJWKS struct {
	BundleID string
	KeysURL  string // https://appleid.apple.com/auth/keys
	HTTP     *http.Client

	mu      sync.Mutex
	keys    map[string]*rsa.PublicKey
	fetched time.Time
}

const appleIssuer = "https://appleid.apple.com"

// Verify implements Apple.
func (a *AppleJWKS) Verify(ctx context.Context, token string) (string, error) {
	claims := jwt.RegisteredClaims{}
	_, err := jwt.ParseWithClaims(token, &claims, func(t *jwt.Token) (any, error) {
		kid, _ := t.Header["kid"].(string)
		return a.key(ctx, kid)
	}, jwt.WithValidMethods([]string{"RS256"}), jwt.WithIssuer(appleIssuer), jwt.WithAudience(a.BundleID), jwt.WithExpirationRequired())
	if err != nil {
		return "", fmt.Errorf("%w: apple: %v", ErrProvider, err)
	}
	if claims.Subject == "" {
		return "", fmt.Errorf("%w: apple: empty subject", ErrProvider)
	}
	return claims.Subject, nil
}

func (a *AppleJWKS) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if k, ok := a.keys[kid]; ok && time.Since(a.fetched) < 24*time.Hour {
		return k, nil
	}
	if time.Since(a.fetched) < time.Minute && a.keys != nil {
		return nil, fmt.Errorf("unknown apple key %q", kid)
	}
	u := a.KeysURL
	if u == "" {
		u = appleIssuer + "/auth/keys"
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	c := a.HTTP
	if c == nil {
		c = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var set struct {
		Keys []struct {
			Kid, N, E string
		} `json:"keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&set); err != nil {
		return nil, err
	}
	a.keys = map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		n, err1 := base64.RawURLEncoding.DecodeString(k.N)
		e, err2 := base64.RawURLEncoding.DecodeString(k.E)
		if err1 != nil || err2 != nil {
			continue
		}
		a.keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
	}
	a.fetched = time.Now()
	if k, ok := a.keys[kid]; ok {
		return k, nil
	}
	return nil, fmt.Errorf("unknown apple key %q", kid)
}

// ---------------------------------------------------------------- dev fakes

// LogSMS logs codes instead of sending them (dev).
type LogSMS struct{ Log *slog.Logger }

// Send implements SMSSender.
func (l LogSMS) Send(_ context.Context, phone, code string) error {
	l.Log.Info("dev sms code", "phone", phone, "code", code)
	return nil
}

// DevOneClick accepts tokens of the form "dev:13800138000".
type DevOneClick struct{}

// Mobile implements OneClick.
func (DevOneClick) Mobile(_ context.Context, token string) (string, error) {
	if p, ok := strings.CutPrefix(token, "dev:"); ok {
		return p, nil
	}
	return "", fmt.Errorf("%w: dev one-click token must look like dev:<phone>", ErrProvider)
}

// DevWeChat accepts codes of the form "dev:<openid>".
type DevWeChat struct{}

// Exchange implements WeChat.
func (DevWeChat) Exchange(_ context.Context, code string) (WeChatIdentity, error) {
	if id, ok := strings.CutPrefix(code, "dev:"); ok && id != "" {
		return WeChatIdentity{OpenID: id, UnionID: "u-" + id, Nickname: "微信用户"}, nil
	}
	return WeChatIdentity{}, fmt.Errorf("%w: dev wechat code must look like dev:<openid>", ErrProvider)
}

// DevApple accepts tokens of the form "dev:<sub>".
type DevApple struct{}

// Verify implements Apple.
func (DevApple) Verify(_ context.Context, token string) (string, error) {
	if sub, ok := strings.CutPrefix(token, "dev:"); ok && sub != "" {
		return sub, nil
	}
	return "", fmt.Errorf("%w: dev apple token must look like dev:<sub>", ErrProvider)
}

// NoCaptcha accepts everything. Production must plug in 阿里云验证码 (or
// similar) here before launch; rate limits below still apply.
type NoCaptcha struct{}

// Verify implements Captcha.
func (NoCaptcha) Verify(context.Context, string, string) error { return nil }

// Disabled is used for providers without configuration.
type Disabled struct{ Name string }

func (d Disabled) err() error {
	return fmt.Errorf("%w: %s login is not configured", ErrProvider, d.Name)
}

// Send implements SMSSender.
func (d Disabled) Send(context.Context, string, string) error { return d.err() }

// Mobile implements OneClick.
func (d Disabled) Mobile(context.Context, string) (string, error) { return "", d.err() }

// Exchange implements WeChat.
func (d Disabled) Exchange(context.Context, string) (WeChatIdentity, error) {
	return WeChatIdentity{}, d.err()
}

// Verify implements Apple.
func (d Disabled) Verify(context.Context, string) (string, error) { return "", d.err() }
