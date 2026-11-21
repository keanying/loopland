// Mock of 系统配置 · 第三方服务 (docs/api/系统配置.md). The catalogue is copied from
// server/internal/providers/defs.go; precedence, masking and validation mirror registry.go.
// Plain values (including the fake secrets) live only in this module's memory.
import { ApiError } from '../api/client';
import type { Provider, ProviderCheck, ProviderField, ProviderSecret } from '../api/types';

interface Def {
  code: string;
  name: string;
  group: string;
  description: string;
  uses?: string;
  test_input?: string;
  fields: ProviderField[] | null;
}

type F = Omit<ProviderField, 'secret' | 'required'> & { secret?: boolean; required?: boolean };
const f = (x: F): ProviderField => ({ secret: false, required: false, ...x });

export const DEFS: Def[] = [
  {
    code: 'aliyun', name: '阿里云账号', group: '账号与安全',
    description: 'RAM 子账号的 AccessKey，短信、验证码、一键登录、实名核验共用。授予这四个产品的权限即可。',
    fields: [
      f({ key: 'access_key_id', label: 'AccessKey ID', kind: 'text', required: true }),
      f({ key: 'access_key_secret', label: 'AccessKey Secret', kind: 'text', secret: true, required: true }),
    ],
  },
  {
    code: 'sms', name: '短信验证码', group: '账号与安全', uses: 'aliyun',
    description: '阿里云短信服务。签名和模板需先在控制台审核通过，模板变量名必须是 ${code}。',
    test_input: '测试手机号（会真实发送一条短信）',
    fields: [
      f({ key: 'sign_name', label: '短信签名', kind: 'text', required: true, default: '圈圈' }),
      f({ key: 'template_code', label: '验证码模板 CODE', kind: 'text', required: true, help: '如 SMS_123456789' }),
    ],
  },
  {
    code: 'captcha', name: '人机验证', group: '账号与安全', uses: 'aliyun',
    description: '阿里云验证码 2.0，发短信前校验。App 端用同一个场景（场景 ID 和身份标在 App 配置里）。',
    fields: [f({ key: 'scene_id', label: '场景 ID', kind: 'text', required: true })],
  },
  {
    code: 'oneclick', name: '一键登录', group: '账号与安全', uses: 'aliyun',
    description: '阿里云号码认证。App 端的方案秘钥在 App 配置里，后端复用阿里云 AccessKey。',
    fields: null,
  },
  {
    code: 'realname', name: '实名核验', group: '账号与安全', uses: 'aliyun',
    description: '阿里云身份证二要素核验（按次收费）。购买会员前必须实名。',
    test_input: '测试用「姓名,身份证号」（会产生一次收费调用）',
    fields: null,
  },
  {
    code: 'wechat_login', name: '微信登录', group: '账号与安全',
    description: '微信开放平台「移动应用」。需把服务器出口 IP 加入开放平台白名单。',
    fields: [
      f({ key: 'app_id', label: 'AppID', kind: 'text', required: true, help: 'wx 开头' }),
      f({ key: 'app_secret', label: 'AppSecret', kind: 'text', secret: true, required: true }),
    ],
  },
  {
    code: 'wechat_pay', name: '微信支付', group: '支付',
    description: '微信支付 APIv3（公钥模式）。回调地址自动使用「后端公网地址/v1/pay/notify/wechat」。',
    fields: [
      f({ key: 'app_id', label: 'AppID', kind: 'text', required: true, help: '与微信登录的移动应用相同' }),
      f({ key: 'mch_id', label: '商户号', kind: 'text', required: true }),
      f({ key: 'serial_no', label: '商户 API 证书序列号', kind: 'text', required: true }),
      f({ key: 'private_key', label: '商户 API 私钥（apiclient_key.pem 内容）', kind: 'textarea', secret: true, required: true }),
      f({ key: 'apiv3_key', label: 'APIv3 密钥', kind: 'text', secret: true, required: true }),
      f({ key: 'public_key', label: '微信支付公钥（pub_key.pem 内容）', kind: 'textarea', required: true }),
      f({ key: 'public_key_id', label: '微信支付公钥 ID', kind: 'text', required: true, help: 'PUB_KEY_ID_ 开头' }),
    ],
  },
  {
    code: 'alipay', name: '支付宝', group: '支付',
    description: '支付宝 APP 支付（RSA2）。回调地址自动使用「后端公网地址/v1/pay/notify/alipay」。',
    fields: [
      f({ key: 'app_id', label: 'AppID', kind: 'text', required: true }),
      f({ key: 'private_key', label: '应用私钥', kind: 'textarea', secret: true, required: true }),
      f({ key: 'public_key', label: '支付宝公钥（不是应用公钥）', kind: 'textarea', required: true }),
      f({ key: 'sandbox', label: '沙箱环境', kind: 'bool', default: 'false' }),
    ],
  },
  {
    code: 'apple', name: 'Apple 登录与内购', group: '支付',
    description: 'Sign in with Apple 和 App Store 内购。服务器通知 V2 地址填「后端公网地址/v1/pay/notify/apple」。',
    fields: [
      f({ key: 'bundle_id', label: 'Bundle ID', kind: 'text', required: true, default: 'com.loopland.app' }),
      f({ key: 'iap_issuer_id', label: 'App Store Server API Issuer ID（可选）', kind: 'text' }),
      f({ key: 'iap_key_id', label: 'App Store Server API Key ID（可选）', kind: 'text' }),
      f({ key: 'iap_private_key', label: 'App Store Server API 私钥 .p8（可选）', kind: 'textarea', secret: true }),
    ],
  },
  {
    code: 'ai', name: 'AI 大模型', group: 'AI',
    description: '国内已备案大模型的 OpenAI 兼容接口，供 AI 助手、战报、跟练使用。App 内需公示模型名称和备案号。',
    fields: [
      f({
        key: 'vendor', label: '厂商', kind: 'select', options: ['qwen', 'deepseek', 'doubao', 'zhipu', 'custom'], required: true, default: 'qwen',
        help: 'qwen-通义千问 deepseek-DeepSeek doubao-豆包 zhipu-智谱 custom-其他兼容接口',
      }),
      f({ key: 'base_url', label: '接口地址', kind: 'url', help: '留空用厂商默认地址' }),
      f({ key: 'api_key', label: 'API Key', kind: 'text', secret: true, required: true }),
      f({ key: 'model', label: '对话模型', kind: 'text', required: true, help: '如 qwen-plus、deepseek-chat' }),
      f({ key: 'small_model', label: '小模型（战报、跟练）', kind: 'text', help: '留空则用对话模型' }),
      f({ key: 'display_name', label: '公示的模型名称', kind: 'text', required: true }),
      f({ key: 'registration_no', label: '生成式 AI 备案号', kind: 'text', required: true }),
      f({ key: 'weekly_free_quota', label: '免费用户每周次数', kind: 'number', default: '3' }),
      f({ key: 'timeout_s', label: '超时（秒）', kind: 'number', default: '30' }),
    ],
  },
  {
    code: 'email', name: '邮件', group: '通知',
    description: 'SMTP 发信（运营报表、告警、对账通知）。端口 465 用 SSL，587 用 STARTTLS。',
    test_input: '测试收件邮箱',
    fields: [
      f({ key: 'host', label: 'SMTP 服务器', kind: 'text', required: true, help: '如 smtpdm.aliyun.com' }),
      f({ key: 'port', label: '端口', kind: 'number', required: true, default: '465' }),
      f({ key: 'username', label: '用户名', kind: 'text', required: true }),
      f({ key: 'password', label: '密码', kind: 'text', secret: true, required: true }),
      f({ key: 'from_address', label: '发件地址', kind: 'text', required: true }),
      f({ key: 'from_name', label: '发件人名称', kind: 'text', default: '圈圈 Loopland' }),
    ],
  },
  {
    code: 'amap', name: '高德 Web 服务', group: '地图',
    description: '服务端用的高德 Web 服务 Key（地名、逆地理编码）。App 和管理端地图的 Key 在各自的配置文件里。',
    fields: [f({ key: 'web_key', label: 'Web 服务 Key', kind: 'text', secret: true, required: true })],
  },
];

const PEM_PRIVATE = '-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7mock0000000000\n-----END PRIVATE KEY-----';
const PEM_PUBLIC = '-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAu1SU1LfVLPHCozMxH2Mo\n4lgOEePzNm0tRgeLezV6ffAt0gunVTLw7onLRnrq0/IzW7yWR7QkrmBL7jTKEn5u\n-----END PUBLIC KEY-----';

/** config.yaml / environment values (what the server would bootstrap from). */
const BOOT: Record<string, Record<string, string>> = {
  aliyun: { access_key_id: 'LTAI5tMockKey8x2Qp', access_key_secret: 'mZ7mockAccessKeySecret0x3kT' },
  sms: { sign_name: '圈圈', template_code: 'SMS_476120335' },
  captcha: { scene_id: '1t3ok2ve' },
  wechat_login: { app_id: 'wx8f3c2a91d0b5e471', app_secret: 'c4e1mockWeChatAppSecret95' },
  apple: { bundle_id: 'com.loopland.app' },
};

interface Row {
  saved: boolean;
  enabled: boolean;
  values: Record<string, string>;
  check: ProviderCheck | null;
  updated_by: number | null;
  update_time: string | null;
}

const H = 3_600_000;
const at = (msAgo: number) => new Date(Date.now() - msAgo).toISOString();
const ok = (msAgo: number): ProviderCheck => ({ status: 'ok', message: '连接正常', time: at(msAgo) });

const rows: Record<string, Row> = {
  aliyun: { saved: true, enabled: true, values: { ...BOOT.aliyun }, check: ok(2 * H), updated_by: 1, update_time: at(26 * H) },
  sms: { saved: true, enabled: true, values: { sign_name: '圈圈', template_code: 'SMS_476120335' }, check: ok(2 * H), updated_by: 1, update_time: at(26 * H) },
  captcha: {
    saved: false, enabled: false, values: {},
    check: { status: 'fail', message: 'InvalidSceneId.NotFound：场景 ID 不存在或不属于当前账号', time: at(5 * H) },
    updated_by: null, update_time: null,
  },
  oneclick: { saved: true, enabled: true, values: {}, check: ok(2 * H), updated_by: 1, update_time: at(26 * H) },
  realname: { saved: true, enabled: true, values: {}, check: null, updated_by: 1, update_time: at(50 * H) },
  wechat_login: { saved: false, enabled: false, values: {}, check: ok(30 * H), updated_by: null, update_time: null },
  wechat_pay: {
    saved: true, enabled: true,
    values: {
      app_id: 'wx8f3c2a91d0b5e471', mch_id: '1712345678', serial_no: '3775B6A45ACD588826D15E583A95F5DD********',
      private_key: PEM_PRIVATE, apiv3_key: 'Qm9ja0FQSXYzS2V5MzJieXRlc0xvbmc', public_key: PEM_PUBLIC, public_key_id: 'PUB_KEY_ID_0117123456782025110800381900',
    },
    check: ok(20 * H), updated_by: 1, update_time: at(3 * 24 * H),
  },
  alipay: {
    saved: true, enabled: false, values: { app_id: '2021004133691234', private_key: PEM_PRIVATE, public_key: PEM_PUBLIC, sandbox: 'true' },
    check: { status: 'fail', message: 'isv.invalid-app-id：无效的 AppID 参数（沙箱 AppID 不能用于正式环境）', time: at(4 * 24 * H) },
    updated_by: 1, update_time: at(4 * 24 * H),
  },
  apple: { saved: false, enabled: false, values: {}, check: ok(6 * 24 * H), updated_by: null, update_time: null },
  ai: {
    saved: true, enabled: true,
    values: {
      vendor: 'qwen', base_url: '', api_key: 'sk-mock7f2e91c0a4d3b856', model: 'qwen-plus', small_model: 'qwen-turbo',
      display_name: '通义千问', registration_no: 'Beijing-QianWen-20230830S0002', weekly_free_quota: '3', timeout_s: '30',
    },
    check: ok(1.5 * H), updated_by: 1, update_time: at(1.6 * H),
  },
  email: { saved: false, enabled: false, values: {}, check: null, updated_by: null, update_time: null },
  amap: { saved: false, enabled: false, values: {}, check: null, updated_by: null, update_time: null },
};

function fail(status: number, code: string, message: string): never {
  throw new ApiError(status, code, message);
}

function defOf(code: string): Def {
  const d = DEFS.find((x) => x.code === code);
  if (!d) fail(404, 'not_found', '服务不存在');
  return d;
}

const fieldsOf = (d: Def) => d.fields ?? [];

function withDefaults(d: Def, v: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const x of fieldsOf(d)) if (x.default) out[x.key] = x.default;
  for (const [k, val] of Object.entries(v)) if (val !== '') out[k] = val;
  return out;
}

const requiredSet = (d: Def, v: Record<string, string>) => fieldsOf(d).every((x) => !x.required || (v[x.key] ?? '').trim() !== '');

interface Effective {
  enabled: boolean;
  configured: boolean;
  source: 'db' | 'config' | 'none';
  values: Record<string, string>;
}

function effective(): Record<string, Effective> {
  const out: Record<string, Effective> = {};
  for (const d of DEFS) {
    const r = rows[d.code];
    if (r.saved) {
      const values = withDefaults(d, r.values);
      out[d.code] = { enabled: r.enabled, configured: requiredSet(d, values), source: 'db', values };
    } else {
      const values = withDefaults(d, BOOT[d.code] ?? {});
      const hasAny = fieldsOf(d).some((x) => !x.default && values[x.key]);
      const configured = requiredSet(d, values);
      out[d.code] = { enabled: configured, configured, source: hasAny ? 'config' : 'none', values };
    }
  }
  for (const d of DEFS) {
    if (!d.uses) continue;
    const e = out[d.code];
    e.configured = e.configured && out[d.uses].configured;
    if (out[d.uses].source === 'none' && e.source === 'none') e.enabled = false;
    else if (e.source !== 'db') e.enabled = e.configured;
  }
  return out;
}

function mask(v: string | undefined): ProviderSecret {
  if (!v) return { set: false };
  if (v.length <= 8) return { set: true, hint: '****' };
  return { set: true, hint: `${v.slice(0, 2)}****${v.slice(-2)}` };
}

function view(d: Def, eff: Record<string, Effective>): Provider {
  const e = eff[d.code];
  const r = rows[d.code];
  const values: Provider['values'] = {};
  for (const x of fieldsOf(d)) values[x.key] = x.secret ? mask(e.values[x.key]) : (e.values[x.key] ?? '');
  return {
    ...JSON.parse(JSON.stringify(d)),
    enabled: e.enabled,
    configured: e.configured,
    source: e.source,
    values,
    last_check: r.check ? { ...r.check } : null,
    updated_by: r.saved ? r.updated_by : null,
    update_time: r.saved ? r.update_time : null,
  };
}

export function listProviders(): { items: Provider[] } {
  const eff = effective();
  return { items: DEFS.map((d) => view(d, eff)) };
}

function validate(x: ProviderField, v: string) {
  if (v === '') return;
  switch (x.kind) {
    case 'number':
      if (!/^[-+]?\d+$/.test(v)) fail(400, 'invalid_config', `${x.label} 必须是整数`);
      break;
    case 'bool':
      if (v !== 'true' && v !== 'false') fail(400, 'invalid_config', `${x.label} 只能是 true 或 false`);
      break;
    case 'select':
      if (!x.options?.includes(v)) fail(400, 'invalid_config', `${x.label} 取值不在可选范围内`);
      break;
    case 'url':
      if (!v.startsWith('https://') && !v.startsWith('http://')) fail(400, 'invalid_config', `${x.label} 必须是 http(s) 地址`);
      break;
  }
}

/** PUT /providers/{code}; returns the saved item and the changed field names (for the audit log). */
export function saveProvider(code: string, body: Record<string, unknown>, adminId: number): { item: Provider; changed: string[]; enabledBefore: boolean } {
  const d = defOf(code);
  const known = new Map(fieldsOf(d).map((x) => [x.key, x]));
  const eff = effective();
  const merged: Record<string, string> = { ...eff[code].values };
  const changed: string[] = [];
  const values = (body.values ?? {}) as Record<string, unknown>;
  if (typeof values !== 'object' || Array.isArray(values)) fail(400, 'invalid_body', '请求格式不正确');
  for (const [k, raw] of Object.entries(values)) {
    const x = known.get(k);
    if (!x) fail(400, 'invalid_config', `未知字段 ${k}`);
    if (typeof raw !== 'string') fail(400, 'invalid_body', '请求格式不正确');
    const v = raw.trim();
    if (x.secret && v === '') continue;
    validate(x, v);
    if ((merged[k] ?? '') !== v) changed.push(k);
    merged[k] = v;
  }
  for (const k of (body.clear ?? []) as string[]) {
    if (known.has(k) && merged[k]) {
      merged[k] = '';
      changed.push(k);
    }
  }
  const enabled = body.enabled === true;
  if (enabled && !requiredSet(d, merged)) {
    const miss = fieldsOf(d).filter((x) => x.required && !(merged[x.key] ?? '').trim()).map((x) => x.label);
    fail(400, 'invalid_config', `启用前请填写：${miss.join('、')}`);
  }
  if (enabled && d.uses && !eff[d.uses].configured) fail(400, 'invalid_config', `请先配置「${defOf(d.uses).name}」`);
  const r = rows[code];
  const enabledBefore = eff[code].enabled;
  Object.assign(r, { saved: true, enabled, values: merged, updated_by: adminId, update_time: new Date().toISOString() });
  return { item: view(d, effective()), changed, enabledBefore };
}

const sleep = (ms: number) => new Promise((res) => setTimeout(res, ms));

/** POST /providers/{code}/test against the effective configuration; failures are 200 with status "fail". */
export async function testProvider(code: string, input: string): Promise<ProviderCheck> {
  defOf(code);
  await sleep(500);
  const eff = effective();
  const e = eff[code];
  const v = e.values;
  let err = '';
  if (!e.configured) err = '必填项没有填全';
  else
    switch (code) {
      case 'aliyun':
      case 'oneclick':
        if (!eff.aliyun.values.access_key_id.startsWith('LTAI')) err = 'InvalidAccessKeyId.NotFound：AccessKey ID 不存在';
        break;
      case 'sms':
        if (input && !/^1\d{10}$/.test(input.trim())) err = 'isv.MOBILE_NUMBER_ILLEGAL：手机号码格式错误';
        break;
      case 'captcha':
        if (v.scene_id === '1t3ok2ve') err = 'InvalidSceneId.NotFound：场景 ID 不存在或不属于当前账号';
        break;
      case 'realname': {
        if (!input) {
          err = '实名核验按次收费，请在测试输入里填「姓名,身份证号」';
          break;
        }
        const [, id = ''] = input.split(/[,，]/);
        if (!/^\d{17}[\dXx]$/.test(id.trim())) err = '身份证号格式不正确';
        break;
      }
      case 'wechat_login':
        if (!v.app_id.startsWith('wx')) err = 'errcode=40013 invalid appid';
        break;
      case 'alipay':
        if (v.sandbox === 'true') err = 'isv.invalid-app-id：无效的 AppID 参数（沙箱 AppID 不能用于正式环境）';
        break;
      case 'ai':
        if (!v.api_key.startsWith('sk-')) err = 'HTTP 401 invalid api key';
        break;
      case 'email':
        if (!input) err = '请填写测试收件邮箱';
        else if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(input.trim())) err = '554 收件地址格式不正确';
        break;
      case 'amap':
        if (v.web_key.length < 16) err = 'INVALID_USER_KEY：Key 不正确或过期';
        break;
    }
  const res: ProviderCheck = { status: err ? 'fail' : 'ok', message: err || '连接正常', time: new Date().toISOString() };
  rows[code].check = res;
  return { ...res };
}
