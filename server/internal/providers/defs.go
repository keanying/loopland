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
	OSS         = "oss"
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
	{Code: Aliyun, Name: "阿里云账号", Group: "账号与安全", Description: "RAM 子账号的 AccessKey，短信、验证码、一键登录、实名核验、对象存储 OSS 共用。授予这几个产品的权限即可（OSS 只需上传图片的 Bucket 的 PutObject）。",
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
	{Code: AI, Name: "AI 大模型", Group: "AI", Description: "国内已备案大模型的 OpenAI 兼容接口，供 AI 助手、路线建议、战报、内容审核使用。App 内需公示模型名称和备案号。开发环境不配置时使用内置的模拟 AI。",
		Fields: []Field{
			{Key: "vendor", Label: "厂商", Kind: "select", Options: []string{"qwen", "deepseek", "doubao", "zhipu", "custom"}, Required: true, Default: "qwen",
				Help: "qwen-通义千问 deepseek-DeepSeek doubao-豆包 zhipu-智谱 custom-其他兼容接口"},
			{Key: "base_url", Label: "接口地址", Kind: "url", Help: "留空用厂商默认地址"},
			{Key: "api_key", Label: "API Key", Kind: "text", Secret: true, Required: true},
			{Key: "model", Label: "对话模型", Kind: "text", Required: true, Help: "如 qwen-plus、deepseek-chat"},
			{Key: "small_model", Label: "小模型（战报、路线解释、审核打分）", Kind: "text", Help: "留空则用对话模型"},
			{Key: "vision_model", Label: "视觉模型（可选）", Kind: "text", Help: "如 qwen-vl-plus；留空则助手不能发图片，审核不识别图片"},
			{Key: "display_name", Label: "公示的模型名称", Kind: "text", Required: true},
			{Key: "registration_no", Label: "生成式 AI 备案号", Kind: "text", Required: true},
			{Key: "weekly_free_quota", Label: "免费用户每周次数", Kind: "number", Default: "3"},
			{Key: "timeout_s", Label: "超时（秒）", Kind: "number", Default: "30"},
			{Key: "price_input_per_mtok_fen", Label: "输入单价（分 / 百万 Token，可选）", Kind: "number", Help: "只用于管理端估算费用"},
			{Key: "price_output_per_mtok_fen", Label: "输出单价（分 / 百万 Token，可选）", Kind: "number", Help: "只用于管理端估算费用"},
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
	{Code: OSS, Name: "对象存储 OSS", Group: "存储", Uses: Aliyun,
		Description: "阿里云对象存储，存用户上传的图片（动态、头像、跑团头像、聊天）。Bucket 设为公共读，或用 CDN 回源访问。没启用时开发环境存本机 server/data/media/，正式环境不能上传图片。连通测试会写入一个 _loopland/check.txt。",
		Fields: []Field{
			{Key: "region", Label: "地域", Kind: "text", Required: true, Default: "cn-hangzhou", Help: "如 cn-hangzhou、cn-shanghai，不带 oss- 前缀"},
			{Key: "endpoint", Label: "Endpoint（可选）", Kind: "text", Help: "留空按地域使用外网 Endpoint；同地域 ECS 可填内网 Endpoint，如 oss-cn-hangzhou-internal.aliyuncs.com"},
			{Key: "bucket", Label: "Bucket 名称", Kind: "text", Required: true},
			{Key: "public_base_url", Label: "访问域名（CDN）", Kind: "url", Help: "图片对外地址前缀，如 https://img.example.com；留空用 Bucket 默认域名"},
		}},
	{Code: AMap, Name: "高德 Web 服务", Group: "地图", Description: "服务端用的高德 Web 服务 Key（地名、逆地理编码、AI 路线建议的步行 / 骑行路径规划）。App 和管理端地图的 Key 在各自的配置文件里。",
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
