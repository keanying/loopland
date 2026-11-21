package providers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/auth"
	"github.com/keanying/loopland/server/internal/billing"
	"github.com/keanying/loopland/server/internal/platform/config"
	"github.com/keanying/loopland/server/internal/platform/secure"
	"github.com/keanying/loopland/server/internal/user"
)

// Effective is a service's configuration after precedence.
type Effective struct {
	Code       string
	Enabled    bool
	Values     map[string]string
	Source     string // db | config | none
	Configured bool   // every required field (and the service it uses) is set
}

// Snapshot is the set of live clients built from one configuration.
type Snapshot struct {
	SMS      auth.SMSSender
	Captcha  auth.Captcha
	OneClick auth.OneClick
	WeChat   auth.WeChat
	Apple    auth.Apple
	Realname user.Realname
	Payments map[string]billing.Provider
	AppleIAP *billing.AppleStore
	AI       *AIConfig
	Mailer   *Mailer
	AMapKey  string
	Eff      map[string]Effective
}

// Registry holds the current snapshot.
type Registry struct {
	Pool *pgxpool.Pool
	Box  *secure.Box
	Cfg  config.Config
	Log  *slog.Logger
	HTTP *http.Client

	mu      sync.RWMutex
	snap    Snapshot
	version time.Time
}

// Current returns the live clients.
func (r *Registry) Current() Snapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.snap
}

type row struct {
	enabled bool
	values  map[string]string
}

func (r *Registry) rows(ctx context.Context) (map[string]row, time.Time, error) {
	out := map[string]row{}
	var version time.Time
	if r.Pool == nil {
		return out, version, nil
	}
	rows, err := r.Pool.Query(ctx, `SELECT provider_code, is_enabled, config_json, secret_enc, update_time FROM src.src_sys_provider_config WHERE is_saved`)
	if err != nil {
		return nil, version, err
	}
	defer rows.Close()
	for rows.Next() {
		var code string
		var en bool
		var cfgRaw, enc []byte
		var t time.Time
		if err := rows.Scan(&code, &en, &cfgRaw, &enc, &t); err != nil {
			return nil, version, err
		}
		vals := map[string]string{}
		_ = json.Unmarshal(cfgRaw, &vals)
		if len(enc) > 0 {
			plain, err := r.Box.Open(enc)
			if err != nil {
				return nil, version, fmt.Errorf("decrypt %s: %w (LOOPLAND_DATA_KEY changed?)", code, err)
			}
			sec := map[string]string{}
			_ = json.Unmarshal([]byte(plain), &sec)
			for k, v := range sec {
				vals[k] = v
			}
		}
		out[code] = row{enabled: en, values: vals}
		if t.After(version) {
			version = t
		}
	}
	return out, version, rows.Err()
}

// bootstrap maps config.yaml / environment values onto services.
func bootstrap(c config.Config) map[string]map[string]string {
	b := func(v bool) string { return strconv.FormatBool(v) }
	return map[string]map[string]string{
		Aliyun:      {"access_key_id": c.Aliyun.AccessKeyID, "access_key_secret": c.Aliyun.AccessKeySecret},
		SMS:         {"sign_name": c.Aliyun.SMSSignName, "template_code": c.Aliyun.SMSTemplateCode},
		Captcha:     {"scene_id": c.Aliyun.CaptchaSceneID},
		OneClick:    {},
		Realname:    {},
		WeChatLogin: {"app_id": c.WeChat.AppID, "app_secret": c.WeChat.AppSecret},
		WeChatPay: {"app_id": c.WeChat.AppID, "mch_id": c.WeChat.MchID, "serial_no": c.WeChat.MchSerialNo, "private_key": c.WeChat.MchPrivateKey,
			"apiv3_key": c.WeChat.APIv3Key, "public_key": c.WeChat.PlatformPubKey, "public_key_id": c.WeChat.PlatformPubKeyID},
		Alipay: {"app_id": c.Alipay.AppID, "private_key": c.Alipay.PrivateKey, "public_key": c.Alipay.PublicKey, "sandbox": b(c.Alipay.Sandbox)},
		Apple:  {"bundle_id": c.Apple.BundleID, "iap_issuer_id": c.Apple.IssuerID, "iap_key_id": c.Apple.KeyID, "iap_private_key": c.Apple.PrivateKey},
		AI:     {}, Email: {}, AMap: {},
	}
}

// feature maps a service to the LOOPLAND_DISABLE switch it had before.
var feature = map[string]string{SMS: "sms", Captcha: "captcha", OneClick: "oneclick", Realname: "realname", WeChatLogin: "wechat_login",
	Apple: "apple_login", WeChatPay: "wechat_pay", Alipay: "alipay"}

func requiredSet(d Def, v map[string]string) bool {
	for _, f := range d.Fields {
		if f.Required && strings.TrimSpace(v[f.Key]) == "" {
			return false
		}
	}
	return true
}

func withDefaults(d Def, v map[string]string) map[string]string {
	out := map[string]string{}
	for _, f := range d.Fields {
		if f.Default != "" {
			out[f.Key] = f.Default
		}
	}
	for k, val := range v {
		if val != "" {
			out[k] = val
		}
	}
	return out
}

func (r *Registry) effective(rows map[string]row) map[string]Effective {
	boot := bootstrap(r.Cfg)
	out := map[string]Effective{}
	for _, d := range Defs {
		e := Effective{Code: d.Code}
		if rw, ok := rows[d.Code]; ok {
			e.Source, e.Enabled, e.Values = "db", rw.enabled, withDefaults(d, rw.values)
		} else {
			e.Values = withDefaults(d, boot[d.Code])
			e.Source = "none"
			hasAny := false
			for _, f := range d.Fields {
				if f.Default == "" && e.Values[f.Key] != "" {
					hasAny = true
				}
			}
			if hasAny {
				e.Source = "config"
			}
			e.Enabled = requiredSet(d, e.Values) && (feature[d.Code] == "" || r.Cfg.Enabled(feature[d.Code]))
		}
		e.Configured = requiredSet(d, e.Values)
		out[d.Code] = e
	}
	// Services that reuse the Aliyun account also need it.
	for code, e := range out {
		if d, _ := DefOf(code); d.Uses != "" {
			e.Configured = e.Configured && out[d.Uses].Configured
			if out[d.Uses].Source == "none" && e.Source == "none" {
				e.Enabled = false
			} else if e.Source != "db" {
				e.Enabled = e.Configured && (feature[code] == "" || r.Cfg.Enabled(feature[code]))
			}
			out[code] = e
		}
	}
	return out
}

// Load reads the configuration and swaps in new clients.
func (r *Registry) Load(ctx context.Context) error {
	rows, version, err := r.rows(ctx)
	if err != nil {
		return err
	}
	snap := r.build(r.effective(rows))
	r.mu.Lock()
	r.snap, r.version = snap, version
	r.mu.Unlock()
	return nil
}

// Watch reloads when another instance saved a change.
func (r *Registry) Watch(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			var v time.Time
			if err := r.Pool.QueryRow(ctx, `SELECT COALESCE(max(update_time), 'epoch') FROM src.src_sys_provider_config`).Scan(&v); err != nil {
				continue
			}
			r.mu.RLock()
			changed := v.After(r.version)
			r.mu.RUnlock()
			if changed {
				if err := r.Load(ctx); err != nil {
					r.Log.Error("reload providers", "err", err)
				}
			}
		}
	}
}

func (r *Registry) on(eff map[string]Effective, code string) (Effective, bool) {
	e := eff[code]
	return e, e.Enabled && e.Configured
}

// build creates clients; failures disable that one service and are logged.
func (r *Registry) build(eff map[string]Effective) Snapshot {
	dev := r.Cfg.Dev()
	s := Snapshot{Eff: eff, Payments: map[string]billing.Provider{}}
	ali := eff[Aliyun].Values
	logErr := func(code string, err error) { r.Log.Error("provider build failed", "provider", code, "err", err) }

	s.SMS = auth.Disabled{Name: "sms"}
	if e, ok := r.on(eff, SMS); ok {
		if c, err := auth.NewAliyunSMS(ali["access_key_id"], ali["access_key_secret"], e.Values["sign_name"], e.Values["template_code"]); err == nil {
			s.SMS = c
		} else {
			logErr(SMS, err)
		}
	} else if dev {
		s.SMS = auth.LogSMS{Log: r.Log}
	}
	s.Captcha = auth.NoCaptcha{}
	if e, ok := r.on(eff, Captcha); ok {
		if c, err := auth.NewAliyunCaptcha(ali["access_key_id"], ali["access_key_secret"], e.Values["scene_id"]); err == nil {
			s.Captcha = c
		} else {
			logErr(Captcha, err)
		}
	}
	s.OneClick = auth.Disabled{Name: "oneclick"}
	if _, ok := r.on(eff, OneClick); ok {
		if c, err := auth.NewAliyunOneClick(ali["access_key_id"], ali["access_key_secret"]); err == nil {
			s.OneClick = c
		} else {
			logErr(OneClick, err)
		}
	} else if dev {
		s.OneClick = auth.DevOneClick{}
	}
	s.WeChat = auth.Disabled{Name: "wechat"}
	if e, ok := r.on(eff, WeChatLogin); ok {
		s.WeChat = &auth.WeChatOpen{AppID: e.Values["app_id"], Secret: e.Values["app_secret"], HTTP: r.HTTP}
	} else if dev {
		s.WeChat = auth.DevWeChat{}
	}
	appleEff, appleOn := r.on(eff, Apple)
	real := &auth.AppleJWKS{BundleID: appleEff.Values["bundle_id"], HTTP: r.HTTP}
	switch {
	case dev:
		s.Apple = devOrReal{dev: auth.DevApple{}, real: real}
	case appleOn:
		s.Apple = real
	default:
		s.Apple = auth.Disabled{Name: "apple"}
	}
	s.Realname = user.UnconfiguredRealname{}
	if _, ok := r.on(eff, Realname); ok {
		if c, err := user.NewAliyunRealname(ali["access_key_id"], ali["access_key_secret"]); err == nil {
			s.Realname = c
		} else {
			logErr(Realname, err)
		}
	} else if dev {
		s.Realname = user.ChecksumRealname{}
	}
	if e, ok := r.on(eff, WeChatPay); ok {
		v := e.Values
		if p, err := billing.NewWeChatPay(v["app_id"], v["mch_id"], v["serial_no"], v["apiv3_key"], v["private_key"], v["public_key"], v["public_key_id"],
			r.Cfg.PublicBaseURL+"/v1/pay/notify/wechat"); err == nil {
			s.Payments[billing.WeChatApp] = p
		} else {
			logErr(WeChatPay, err)
		}
	}
	if e, ok := r.on(eff, Alipay); ok {
		v := e.Values
		if p, err := billing.NewAlipay(v["app_id"], v["private_key"], v["public_key"], r.Cfg.PublicBaseURL+"/v1/pay/notify/alipay", v["sandbox"] == "true"); err == nil {
			s.Payments[billing.AlipayApp] = p
		} else {
			logErr(Alipay, err)
		}
	}
	if appleOn || dev {
		bundle := appleEff.Values["bundle_id"]
		if bundle == "" {
			bundle = r.Cfg.Apple.BundleID
		}
		s.AppleIAP = billing.NewAppleStore(bundle)
		s.Payments[billing.AppleIAP] = s.AppleIAP
	}
	if dev {
		s.Payments[billing.Mock] = billing.MockPay{}
	}
	if e, ok := r.on(eff, AI); ok {
		v := e.Values
		quota, _ := strconv.Atoi(v["weekly_free_quota"])
		timeout, _ := strconv.Atoi(v["timeout_s"])
		s.AI = &AIConfig{Vendor: v["vendor"], BaseURL: v["base_url"], APIKey: v["api_key"], Model: v["model"], SmallModel: v["small_model"],
			DisplayName: v["display_name"], RegistrationNo: v["registration_no"], WeeklyFreeQuota: quota, TimeoutS: timeout}
	}
	if e, ok := r.on(eff, Email); ok {
		port, _ := strconv.Atoi(e.Values["port"])
		s.Mailer = &Mailer{Host: e.Values["host"], Port: port, Username: e.Values["username"], Password: e.Values["password"],
			From: e.Values["from_address"], FromName: e.Values["from_name"]}
	}
	if e, ok := r.on(eff, AMap); ok {
		s.AMapKey = e.Values["web_key"]
	}

	return s
}

// devOrReal accepts dev:<sub> tokens and real Apple tokens in dev.
type devOrReal struct {
	dev  auth.Apple
	real auth.Apple
}

func (d devOrReal) Verify(ctx context.Context, tok string) (string, error) {
	if strings.HasPrefix(tok, "dev:") {
		return d.dev.Verify(ctx, tok)
	}
	return d.real.Verify(ctx, tok)
}

// ---------------------------------------------------------------- live wrappers

// The services hold these wrappers, so a saved change applies to the next
// request without rebuilding the services.
type (
	dynSMS      struct{ r *Registry }
	dynCaptcha  struct{ r *Registry }
	dynOneClick struct{ r *Registry }
	dynWeChat   struct{ r *Registry }
	dynApple    struct{ r *Registry }
	dynRealname struct{ r *Registry }
)

func (d dynSMS) Send(ctx context.Context, phone, code string) error {
	return d.r.Current().SMS.Send(ctx, phone, code)
}
func (d dynCaptcha) Verify(ctx context.Context, tok, ip string) error {
	return d.r.Current().Captcha.Verify(ctx, tok, ip)
}
func (d dynOneClick) Mobile(ctx context.Context, tok string) (string, error) {
	return d.r.Current().OneClick.Mobile(ctx, tok)
}
func (d dynWeChat) Exchange(ctx context.Context, code string) (auth.WeChatIdentity, error) {
	return d.r.Current().WeChat.Exchange(ctx, code)
}
func (d dynApple) Verify(ctx context.Context, tok string) (string, error) {
	return d.r.Current().Apple.Verify(ctx, tok)
}
func (d dynRealname) Verify(ctx context.Context, name, id string) (time.Time, error) {
	return d.r.Current().Realname.Verify(ctx, name, id)
}

// Live returns wrappers that always use the current configuration.
func (r *Registry) Live() (auth.SMSSender, auth.Captcha, auth.OneClick, auth.WeChat, auth.Apple, user.Realname) {
	return dynSMS{r}, dynCaptcha{r}, dynOneClick{r}, dynWeChat{r}, dynApple{r}, dynRealname{r}
}

// IsLive reports whether v is one of the wrappers returned by Live.
func IsLive(v any) bool {
	switch v.(type) {
	case dynSMS, dynCaptcha, dynOneClick, dynWeChat, dynApple, dynRealname:
		return true
	}
	return false
}

// Payment looks up a live payment channel.
func (r *Registry) Payment(channel string) (billing.Provider, bool) {
	p, ok := r.Current().Payments[channel]
	return p, ok
}

// AppleStore returns the live App Store verifier (nil if disabled).
func (r *Registry) AppleStore() *billing.AppleStore { return r.Current().AppleIAP }

// ---------------------------------------------------------------- admin view and writes

// View is one service in the admin console.
type View struct {
	Def
	Enabled    bool           `json:"enabled"`
	Configured bool           `json:"configured"`
	Source     string         `json:"source"`
	Values     map[string]any `json:"values"`
	Check      *CheckResult   `json:"last_check"`
	UpdatedBy  *int64         `json:"updated_by"`
	UpdateTime *time.Time     `json:"update_time"`
}

// CheckResult is the last connection test.
type CheckResult struct {
	Status  string    `json:"status"`
	Message string    `json:"message"`
	Time    time.Time `json:"time"`
}

// Masked shows a secret's presence without its value.
type Masked struct {
	Set  bool   `json:"set"`
	Hint string `json:"hint,omitempty"`
}

func mask(v string) Masked {
	if v == "" {
		return Masked{}
	}
	if len(v) <= 8 {
		return Masked{Set: true, Hint: "****"}
	}
	return Masked{Set: true, Hint: v[:2] + "****" + v[len(v)-2:]}
}

// Views lists every service for the admin console.
func (r *Registry) Views(ctx context.Context) ([]View, error) {
	eff := r.Current().Eff
	meta := map[string]View{}
	rows, err := r.Pool.Query(ctx, `SELECT provider_code, is_saved, check_status, check_message, check_time, updated_by, update_time FROM src.src_sys_provider_config`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var code string
		var st, msg *string
		var ct *time.Time
		var v View
		var ut time.Time
		var saved bool
		if err := rows.Scan(&code, &saved, &st, &msg, &ct, &v.UpdatedBy, &ut); err != nil {
			rows.Close()
			return nil, err
		}
		if saved {
			v.UpdateTime = &ut
		} else {
			v.UpdatedBy = nil
		}
		if st != nil && ct != nil {
			v.Check = &CheckResult{Status: *st, Message: deref(msg), Time: *ct}
		}
		meta[code] = v
	}
	rows.Close()
	out := make([]View, 0, len(Defs))
	for _, d := range Defs {
		e := eff[d.Code]
		v := meta[d.Code]
		v.Def, v.Enabled, v.Configured, v.Source = d, e.Enabled, e.Configured, e.Source
		if v.Fields == nil {
			v.Fields = []Field{}
		}
		v.Values = map[string]any{}
		for _, f := range d.Fields {
			if f.Secret {
				v.Values[f.Key] = mask(e.Values[f.Key])
			} else {
				v.Values[f.Key] = e.Values[f.Key]
			}
		}
		out = append(out, v)
	}
	return out, nil
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// ErrInvalid is a validation error shown to the admin.
type ErrInvalid struct{ Msg string }

func (e ErrInvalid) Error() string { return e.Msg }

// Save stores a service's configuration. Secret fields left empty keep
// their stored value; keys listed in clear are removed.
func (r *Registry) Save(ctx context.Context, code string, enabled bool, values map[string]string, clear []string, adminID int64) ([]string, error) {
	d, ok := DefOf(code)
	if !ok {
		return nil, ErrInvalid{"没有这个服务"}
	}
	known := map[string]Field{}
	for _, f := range d.Fields {
		known[f.Key] = f
	}
	cur := r.Current().Eff[code].Values
	merged := map[string]string{}
	for k, v := range cur {
		merged[k] = v
	}
	var changed []string
	for k, v := range values {
		f, ok := known[k]
		if !ok {
			return nil, ErrInvalid{"未知字段 " + k}
		}
		v = strings.TrimSpace(v)
		if f.Secret && v == "" {
			continue // keep
		}
		if err := validate(f, v); err != nil {
			return nil, err
		}
		if merged[k] != v {
			changed = append(changed, k)
		}
		merged[k] = v
	}
	for _, k := range clear {
		if _, ok := known[k]; ok && merged[k] != "" {
			merged[k] = ""
			changed = append(changed, k)
		}
	}
	if enabled && !requiredSet(d, merged) {
		var miss []string
		for _, f := range d.Fields {
			if f.Required && strings.TrimSpace(merged[f.Key]) == "" {
				miss = append(miss, f.Label)
			}
		}
		return nil, ErrInvalid{"启用前请填写：" + strings.Join(miss, "、")}
	}
	if enabled && d.Uses != "" && !r.Current().Eff[d.Uses].Configured {
		ud, _ := DefOf(d.Uses)
		return nil, ErrInvalid{"请先配置「" + ud.Name + "」"}
	}
	plain, secret := map[string]string{}, map[string]string{}
	for k, v := range merged {
		if f, ok := known[k]; ok {
			if f.Secret {
				secret[k] = v
			} else {
				plain[k] = v
			}
		}
	}
	pj, _ := json.Marshal(plain)
	sj, _ := json.Marshal(secret)
	_, err := r.Pool.Exec(ctx, `INSERT INTO src.src_sys_provider_config (provider_code, is_enabled, is_saved, config_json, secret_enc, updated_by, update_time)
		VALUES ($1,$2,true,$3,$4,$5,now())
		ON CONFLICT (provider_code) DO UPDATE SET is_enabled=EXCLUDED.is_enabled, is_saved=true, config_json=EXCLUDED.config_json,
			secret_enc=EXCLUDED.secret_enc, updated_by=EXCLUDED.updated_by, update_time=now()`, code, enabled, pj, r.Box.Seal(string(sj)), adminID)
	if err != nil {
		return nil, err
	}
	return changed, r.Load(ctx)
}

func validate(f Field, v string) error {
	if v == "" {
		return nil
	}
	switch f.Kind {
	case "number":
		if _, err := strconv.Atoi(v); err != nil {
			return ErrInvalid{f.Label + " 必须是整数"}
		}
	case "bool":
		if v != "true" && v != "false" {
			return ErrInvalid{f.Label + " 只能是 true 或 false"}
		}
	case "select":
		ok := false
		for _, o := range f.Options {
			ok = ok || o == v
		}
		if !ok {
			return ErrInvalid{f.Label + " 取值不在可选范围内"}
		}
	case "url":
		if !strings.HasPrefix(v, "https://") && !strings.HasPrefix(v, "http://") {
			return ErrInvalid{f.Label + " 必须是 http(s) 地址"}
		}
	}
	return nil
}

// Test runs a connection check against the effective configuration and
// records the result. It does not change which configuration is used.
func (r *Registry) Test(ctx context.Context, code, input string) (CheckResult, error) {
	if _, ok := DefOf(code); !ok {
		return CheckResult{}, ErrInvalid{"没有这个服务"}
	}
	err := r.Check(ctx, code, input)
	res := CheckResult{Status: "ok", Message: "连接正常", Time: time.Now()}
	if err != nil {
		res.Status, res.Message = "fail", err.Error()
		if len(res.Message) > 500 {
			res.Message = res.Message[:500]
		}
	}
	_, dbErr := r.Pool.Exec(ctx, `INSERT INTO src.src_sys_provider_config (provider_code, check_status, check_message, check_time)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (provider_code) DO UPDATE SET check_status=EXCLUDED.check_status, check_message=EXCLUDED.check_message, check_time=EXCLUDED.check_time`,
		code, res.Status, res.Message, res.Time)
	return res, dbErr
}

// Check runs the connection check for code against the effective
// configuration without recording it.
func (r *Registry) Check(ctx context.Context, code, input string) error {
	eff := r.Current().Eff
	e, ok := eff[code]
	if !ok {
		return ErrInvalid{"没有这个服务"}
	}
	if !e.Configured {
		return fmt.Errorf("必填项没有填全")
	}
	return r.check(ctx, code, e.Values, eff[Aliyun].Values, input)
}

// check performs a harmless real call per service.
func (r *Registry) check(ctx context.Context, code string, v, ali map[string]string, input string) error {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	hc := r.HTTP
	if hc == nil {
		hc = &http.Client{Timeout: 15 * time.Second}
	}
	switch code {
	case Aliyun:
		c, err := auth.NewAliyunOneClick(v["access_key_id"], v["access_key_secret"])
		if err != nil {
			return err
		}
		return c.Check(ctx)
	case SMS:
		c, err := auth.NewAliyunSMS(ali["access_key_id"], ali["access_key_secret"], v["sign_name"], v["template_code"])
		if err != nil {
			return err
		}
		if err := c.Check(ctx); err != nil {
			return err
		}
		if input != "" {
			return c.Send(ctx, strings.TrimSpace(input), "123456")
		}
		return nil
	case Captcha:
		c, err := auth.NewAliyunCaptcha(ali["access_key_id"], ali["access_key_secret"], v["scene_id"])
		if err != nil {
			return err
		}
		return c.Check(ctx)
	case OneClick:
		c, err := auth.NewAliyunOneClick(ali["access_key_id"], ali["access_key_secret"])
		if err != nil {
			return err
		}
		return c.Check(ctx)
	case Realname:
		if input == "" {
			return fmt.Errorf("实名核验按次收费，请在测试输入里填「姓名,身份证号」")
		}
		c, err := user.NewAliyunRealname(ali["access_key_id"], ali["access_key_secret"])
		if err != nil {
			return err
		}
		name, id, _ := strings.Cut(input, ",")
		_, err = c.Verify(ctx, strings.TrimSpace(name), strings.TrimSpace(id))
		return err
	case WeChatLogin:
		return (&auth.WeChatOpen{AppID: v["app_id"], Secret: v["app_secret"], HTTP: hc}).Check(ctx)
	case WeChatPay:
		p, err := billing.NewWeChatPay(v["app_id"], v["mch_id"], v["serial_no"], v["apiv3_key"], v["private_key"], v["public_key"], v["public_key_id"], r.Cfg.PublicBaseURL)
		if err != nil {
			return err
		}
		return p.Check(ctx)
	case Alipay:
		p, err := billing.NewAlipay(v["app_id"], v["private_key"], v["public_key"], r.Cfg.PublicBaseURL, v["sandbox"] == "true")
		if err != nil {
			return err
		}
		return p.Check(ctx)
	case Apple:
		return (&auth.AppleJWKS{BundleID: v["bundle_id"], HTTP: hc}).Check(ctx)
	case AI:
		return AIConfig{Vendor: v["vendor"], BaseURL: v["base_url"], APIKey: v["api_key"], Model: v["model"]}.Check(ctx, hc)
	case Email:
		port, _ := strconv.Atoi(v["port"])
		if input == "" {
			return fmt.Errorf("请填写测试收件邮箱")
		}
		m := &Mailer{Host: v["host"], Port: port, Username: v["username"], Password: v["password"], From: v["from_address"], FromName: v["from_name"]}
		return m.Send(ctx, strings.TrimSpace(input), "圈圈 Loopland 邮件测试", "这是一封测试邮件，收到说明邮件配置正确。")
	case AMap:
		return AMapCheck(ctx, hc, v["web_key"])
	}
	return fmt.Errorf("这个服务没有连通测试")
}
