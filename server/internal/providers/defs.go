// Package providers manages third-party service configuration (第三方服务配置):
// definitions shown in the admin console, encrypted storage in
// src.src_sys_loop_provider_config, the live client instances (rebuilt without a
// restart when an admin saves), and connection tests.
//
// Precedence per service: a row saved in the admin console wins; without a
// row the bootstrap values from config.yaml / environment are used, so
// existing deployments keep working until someone saves the page.
package providers

// Field is one input on the admin form.
type Field struct {
	Key      string   `json:"key"`
	Label    string   `json:"label"`
	Help     string   `json:"help,omitempty"`
	Kind     string   `json:"kind"` // text | textarea | number | bool | select | url
	Secret   bool     `json:"secret"`
	Required bool     `json:"required"`
	Options  []string `json:"options,omitempty"`
	Default  string   `json:"default,omitempty"`
}

// Def describes one service.
type Def struct {
	Code        string  `json:"code"`
	Name        string  `json:"name"`
	Group       string  `json:"group"`
	Description string  `json:"description"`
	Fields      []Field `json:"fields"`
	// Uses names another service whose credentials this one reuses.
	Uses string `json:"uses,omitempty"`
	// TestInput, when set, is the label of an extra input the test needs
	// (e.g. the phone number to send a test SMS to).
	TestInput string `json:"test_input,omitempty"`
}

// Codes.
const (
	Aliyun      = "aliyun"
	SMS         = "sms"
	Captcha     = "captcha"
	OneClick    = "oneclick"
	Realname    = "realname"
	WeChatLogin = "wechat_login"
	WeChatPay   = "wechat_pay"
	Alipay      = "alipay"
	Apple       = "apple"
	AI          = "ai"
	Email       = "email"
	AMap        = "amap"
)

// AIVendors are OpenAI-compatible endpoints of mainland providers.
var AIVendors = map[string]string{
	"qwen":     "https://dashscope.aliyuncs.com/compatible-mode/v1",
	"deepseek": "https://api.deepseek.com/v1",
	"doubao":   "https://ark.cn-beijing.volces.com/api/v3",
	"zhipu":    "https://open.bigmodel.cn/api/paas/v4",
	"custom":   "",
}

// Defs is the catalogue, in display order.
var Defs = []Def{
	{Code: Aliyun, Name: "阿里云账号", Group: "账号与安全", Description: "RAM 子账号的 AccessKey，短信、验证码、一键登录、实名核验共用。授予这四个产品的权限即可。",
		Fields: []Field{
			{Key: "access_key_id", Label: "AccessKey ID", Kind: "text", Required: true},
			{Key: "access_key_secret", Label: "AccessKey Secret", Kind: "text", Secret: true, Required: true},
		}},
	{Code: SMS, Name: "短信验证码", Group: "账号与安全", Uses: Aliyun, Description: "阿里云短信服务。签名和模板需先在控制台审核通过，模板变量名必须是 ${code}。",
		TestInput: "测试手机号（会真实发送一条短信）",
		Fields: []Field{
			{Key: "sign_name", Label: "短信签名", Kind: "text", Required: true, Default: "圈圈"},
			{Key: "template_code", Label: "验证码模板 CODE", Kind: "text", Required: true, Help: "如 SMS_123456789"},
		}},
	{Code: Captcha, Name: "人机验证", Group: "账号与安全", Uses: Aliyun, Description: "阿里云验证码 2.0，发短信前校验。App 端用同一个场景（场景 ID 和身份标在 App 配置里）。",
		Fields: []Field{{Key: "scene_id", Label: "场景 ID", Kind: "text", Required: true}}},
	{Code: OneClick, Name: "一键登录", Group: "账号与安全", Uses: Aliyun, Description: "阿里云号码认证。App 端的方案秘钥在 App 配置里，后端复用阿里云 AccessKey。"},
	{Code: Realname, Name: "实名核验", Group: "账号与安全", Uses: Aliyun, Description: "阿里云身份证二要素核验（按次收费）。购买会员前必须实名。",
		TestInput: "测试用「姓名,身份证号」（会产生一次收费调用）"},
	{Code: WeChatLogin, Name: "微信登录", Group: "账号与安全", Description: "微信开放平台「移动应用」。需把服务器出口 IP 加入开放平台白名单。",
		Fields: []Field{
			{Key: "app_id", Label: "AppID", Kind: "text", Required: true, Help: "wx 开头"},
			{Key: "app_secret", Label: "AppSecret", Kind: "text", Secret: true, Required: true},
		}},
	{Code: WeChatPay, Name: "微信支付", Group: "支付", Description: "微信支付 APIv3（公钥模式）。回调地址自动使用「后端公网地址/v1/pay/notify/wechat」。",
		Fields: []Field{
			{Key: "app_id", Label: "AppID", Kind: "text", Required: true, Help: "与微信登录的移动应用相同"},
			{Key: "mch_id", Label: "商户号", Kind: "text", Required: true},
			{Key: "serial_no", Label: "商户 API 证书序列号", Kind: "text", Required: true},
			{Key: "private_key", Label: "商户 API 私钥（apiclient_key.pem 内容）", Kind: "textarea", Secret: true, Required: true},
			{Key: "apiv3_key", Label: "APIv3 密钥", Kind: "text", Secret: true, Required: true},
			{Key: "public_key", Label: "微信支付公钥（pub_key.pem 内容）", Kind: "textarea", Required: true},
			{Key: "public_key_id", Label: "微信支付公钥 ID", Kind: "text", Required: true, Help: "PUB_KEY_ID_ 开头"},
		}},
	{Code: Alipay, Name: "支付宝", Group: "支付", Description: "支付宝 APP 支付（RSA2）。回调地址自动使用「后端公网地址/v1/pay/notify/alipay」。",
		Fields: []Field{
			{Key: "app_id", Label: "AppID", Kind: "text", Required: true},
			{Key: "private_key", Label: "应用私钥", Kind: "textarea", Secret: true, Required: true},
			{Key: "public_key", Label: "支付宝公钥（不是应用公钥）", Kind: "textarea", Required: true},
			{Key: "sandbox", Label: "沙箱环境", Kind: "bool", Default: "false"},
		}},
	{Code: Apple, Name: "Apple 登录与内购", Group: "支付", Description: "Sign in with Apple 和 App Store 内购。服务器通知 V2 地址填「后端公网地址/v1/pay/notify/apple」。",
		Fields: []Field{
			{Key: "bundle_id", Label: "Bundle ID", Kind: "text", Required: true, Default: "com.loopland.app"},
			{Key: "iap_issuer_id", Label: "App Store Server API Issuer ID（可选）", Kind: "text"},
			{Key: "iap_key_id", Label: "App Store Server API Key ID（可选）", Kind: "text"},
			{Key: "iap_private_key", Label: "App Store Server API 私钥 .p8（可选）", Kind: "textarea", Secret: true},
		}},
	{Code: AI, Name: "AI 大模型", Group: "AI", Description: "国内已备案大模型的 OpenAI 兼容接口，供 AI 助手、战报、跟练使用。App 内需公示模型名称和备案号。",
		Fields: []Field{
			{Key: "vendor", Label: "厂商", Kind: "select", Options: []string{"qwen", "deepseek", "doubao", "zhipu", "custom"}, Required: true, Default: "qwen",
				Help: "qwen-通义千问 deepseek-DeepSeek doubao-豆包 zhipu-智谱 custom-其他兼容接口"},
			{Key: "base_url", Label: "接口地址", Kind: "url", Help: "留空用厂商默认地址"},
			{Key: "api_key", Label: "API Key", Kind: "text", Secret: true, Required: true},
			{Key: "model", Label: "对话模型", Kind: "text", Required: true, Help: "如 qwen-plus、deepseek-chat"},
			{Key: "small_model", Label: "小模型（战报、跟练）", Kind: "text", Help: "留空则用对话模型"},
			{Key: "display_name", Label: "公示的模型名称", Kind: "text", Required: true},
			{Key: "registration_no", Label: "生成式 AI 备案号", Kind: "text", Required: true},
			{Key: "weekly_free_quota", Label: "免费用户每周次数", Kind: "number", Default: "3"},
			{Key: "timeout_s", Label: "超时（秒）", Kind: "number", Default: "30"},
		}},
	{Code: Email, Name: "邮件", Group: "通知", Description: "SMTP 发信（运营报表、告警、对账通知）。端口 465 用 SSL，587 用 STARTTLS。",
		TestInput: "测试收件邮箱",
		Fields: []Field{
			{Key: "host", Label: "SMTP 服务器", Kind: "text", Required: true, Help: "如 smtpdm.aliyun.com"},
			{Key: "port", Label: "端口", Kind: "number", Required: true, Default: "465"},
			{Key: "username", Label: "用户名", Kind: "text", Required: true},
			{Key: "password", Label: "密码", Kind: "text", Secret: true, Required: true},
			{Key: "from_address", Label: "发件地址", Kind: "text", Required: true},
			{Key: "from_name", Label: "发件人名称", Kind: "text", Default: "圈圈 Loopland"},
		}},
	{Code: AMap, Name: "高德 Web 服务", Group: "地图", Description: "服务端用的高德 Web 服务 Key（地名、逆地理编码）。App 和管理端地图的 Key 在各自的配置文件里。",
		Fields: []Field{{Key: "web_key", Label: "Web 服务 Key", Kind: "text", Secret: true, Required: true}}},
}

// DefOf returns the definition of a code.
func DefOf(code string) (Def, bool) {
	for _, d := range Defs {
		if d.Code == code {
			return d, true
		}
	}
	return Def{}, false
}
