// Mock of V2 第三批「AI」管理端 (docs/api/v2-3-AI.md 「管理端 · AI 用量」): daily usage,
// per-feature stats, the call log (metadata only) and a user's assistant conversation.
import { ApiError } from '../api/client';
import type { AdminRole, AICall, AIMessage, AIUsage, AIUsageDay, AIUsageFeature } from '../api/types';
import * as db from './data';
import { aiModels, aiPrices } from './providers';

type Ctx = { m: RegExpMatchArray; q: URLSearchParams; body: Record<string, unknown>; adminId: number; role: AdminRole };
type Handler = (ctx: Ctx) => unknown;
type Log = (adminId: number, action: string, target: string, detail?: Record<string, unknown>) => void;

const MIN = 60_000;
const DAY = 86_400_000;

function fail(status: number, code: string, message: string): never {
  throw new ApiError(status, code, message);
}
function requireRole(role: AdminRole, allowed: AdminRole[]) {
  if (!allowed.includes(role)) fail(403, 'forbidden', '当前角色没有权限执行此操作');
}

/** Cheap deterministic hash → [0, 1). */
function h(n: number, salt = 0): number {
  let x = (n * 2654435761 + salt * 40503) >>> 0;
  x ^= x >>> 13;
  x = Math.imul(x, 0x5bd1e995) >>> 0;
  x ^= x >>> 15;
  return (x >>> 0) / 4294967296;
}

interface FeatureProfile {
  /** Calls on an average weekday. */
  base: number;
  weekend: number;
  prompt: number;
  completion: number;
  latency: number;
  failRate: number;
  small: boolean;
}

const PROFILE: Record<string, FeatureProfile> = {
  chat: { base: 860, weekend: 1.35, prompt: 1850, completion: 340, latency: 2350, failRate: 0.0042, small: false },
  route: { base: 1480, weekend: 1.5, prompt: 620, completion: 58, latency: 880, failRate: 0.0021, small: true },
  report: { base: 1120, weekend: 1.45, prompt: 710, completion: 118, latency: 1460, failRate: 0.0018, small: true },
  moderation: { base: 2380, weekend: 1.2, prompt: 430, completion: 64, latency: 640, failRate: 0.0056, small: true },
  workout: { base: 150, weekend: 1.6, prompt: 300, completion: 82, latency: 720, failRate: 0.0013, small: true },
};
const FEATURES = Object.keys(PROFILE);

function dayKey(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** One feature on one day (offset = days before today, 0 = today so far). */
function featureDay(f: string, offset: number) {
  const p = PROFILE[f];
  const d = new Date(Date.now() - offset * DAY);
  const wd = d.getDay();
  const weekend = wd === 0 || wd === 6 ? p.weekend : 1;
  const growth = 1 + (30 - offset) * 0.004; // slow growth over the month
  let calls = Math.round(p.base * weekend * growth * (0.9 + h(offset, f.length) * 0.2));
  if (offset === 0) {
    const now = new Date();
    calls = Math.round(calls * ((now.getHours() * 60 + now.getMinutes()) / 1440));
  }
  // one bad afternoon: the vendor rate-limited moderation 3 days ago
  const failRate = p.failRate * (f === 'moderation' && offset === 3 ? 6 : 1);
  const failed = Math.round(calls * failRate * (0.6 + h(offset, f.length + 7) * 0.8));
  return {
    calls,
    failed,
    prompt_tokens: Math.round(calls * p.prompt * (0.92 + h(offset, 3) * 0.16)),
    completion_tokens: Math.round(calls * p.completion * (0.9 + h(offset, 5) * 0.2)),
    latency: Math.round(p.latency * (0.9 + h(offset, f.length + 11) * 0.25)),
  };
}

function cost(prompt: number, completion: number): number | null {
  const pr = aiPrices();
  return pr ? Math.round((prompt * pr.input + completion * pr.output) / 1e6) : null;
}

function usage(days: number): AIUsage {
  const out: AIUsageDay[] = [];
  const acc: Record<string, AIUsageFeature & { lat: number }> = {};
  for (let off = days - 1; off >= 0; off--) {
    const row = { calls: 0, failed: 0, prompt_tokens: 0, completion_tokens: 0 };
    for (const f of FEATURES) {
      const x = featureDay(f, off);
      row.calls += x.calls;
      row.failed += x.failed;
      row.prompt_tokens += x.prompt_tokens;
      row.completion_tokens += x.completion_tokens;
      const a = (acc[f] ??= { feature: f, calls: 0, failed: 0, avg_latency_ms: 0, prompt_tokens: 0, completion_tokens: 0, cost_fen: null, lat: 0 });
      a.calls += x.calls;
      a.failed += x.failed;
      a.prompt_tokens += x.prompt_tokens;
      a.completion_tokens += x.completion_tokens;
      a.lat += x.latency * x.calls;
    }
    out.push({ date: dayKey(new Date(Date.now() - off * DAY)), ...row, cost_fen: cost(row.prompt_tokens, row.completion_tokens) });
  }
  const by_feature = FEATURES.map((f) => {
    const { lat, ...a } = acc[f];
    return { ...a, avg_latency_ms: a.calls ? Math.round(lat / a.calls) : 0, cost_fen: cost(a.prompt_tokens, a.completion_tokens) };
  });
  return { days: out, by_feature, quota: { users_hit_limit_this_week: 128 + new Date().getDay() * 17 } };
}

// ---- call log: virtual list over the last 3 days, newest first ----

const ERRORS = [
  'timeout after 3s（审核超时，已按规则分处理）',
  'HTTP 429 Requests rate limit exceeded, please try again later.',
  'HTTP 500 InternalError.Algo: An internal error has occured',
  'HTTP 400 DataInspectionFailed: Input data may contain inappropriate content.',
  'timeout after 30s',
];
const LOG_SIZE = 3 * FEATURES.reduce((s, f) => s + PROFILE[f].base, 0);
const SHARE = FEATURES.map((f) => PROFILE[f].base);
const SHARE_SUM = SHARE.reduce((a, b) => a + b, 0);
const LOG_START = Date.now();

function callAt(i: number): AICall {
  const r = h(i, 1) * SHARE_SUM;
  let k = 0;
  let acc = SHARE[0];
  while (acc < r && k < FEATURES.length - 1) acc += SHARE[++k];
  const f = FEATURES[k];
  const p = PROFILE[f];
  const m = aiModels();
  const failed = h(i, 2) < p.failRate * 2.2;
  const err = failed ? ERRORS[Math.floor(h(i, 3) * ERRORS.length)] : null;
  const u = db.users[Math.floor(h(i, 4) * db.users.length)];
  const vision = f === 'moderation' && m.vision && h(i, 5) < 0.18;
  const prompt = failed && err?.startsWith('timeout') ? Math.round(p.prompt * (0.7 + h(i, 6) * 0.6)) : Math.round(p.prompt * (0.55 + h(i, 6) * 0.9));
  return {
    id: 900000 - i,
    feature: f,
    user: f === 'moderation' && h(i, 7) < 0.08 ? null : { id: u.id, nickname: u.nickname },
    model: vision ? m.vision : p.small ? m.small : m.model,
    status: failed ? 'failed' : 'ok',
    error: err,
    prompt_tokens: failed && !err?.startsWith('timeout') ? 0 : prompt,
    completion_tokens: failed ? 0 : Math.round(p.completion * (0.5 + h(i, 8))),
    latency_ms: failed && err?.startsWith('timeout') ? (err.includes('30s') ? 30000 : 3000) : Math.round(p.latency * (0.45 + h(i, 9) * 1.2)),
    created_at: new Date(LOG_START - i * ((3 * DAY) / LOG_SIZE) - h(i, 10) * 3000).toISOString(),
  };
}

function calls(q: URLSearchParams) {
  const feature = q.get('feature') ?? '';
  const status = q.get('status') ?? '';
  if (feature && !FEATURES.includes(feature)) fail(400, 'invalid_feature', 'feature 取值 chat / route / report / moderation / workout');
  if (status && status !== 'ok' && status !== 'failed') fail(400, 'invalid_status', 'status 取值 ok / failed');
  const page = Math.max(1, Number(q.get('page') ?? 1));
  const size = Math.min(100, Math.max(1, Number(q.get('page_size') ?? 20)));
  const from = (page - 1) * size;
  const items: AICall[] = [];
  let total = 0;
  for (let i = 0; i < LOG_SIZE; i++) {
    const c = callAt(i);
    if ((feature && c.feature !== feature) || (status && c.status !== status)) continue;
    if (total >= from && items.length < size) items.push(c);
    total++;
  }
  return { items, total };
}

// ---- a user's assistant conversation ----

type Turn = [string, string, AIMessage['cards']?];
const CONVO: Turn[] = [
  ['今晚去哪抢地？', '你附近有两块守卫值很低的地：「西岸草坪」守卫值 42，「龙腾大道 3 号段」守卫值 65，都在 1.5 km 内。往东绕滨江公园一圈正好经过，约 5.2 km、32 分钟。', [
    { type: 'route', route: { id: 'r_8f2c1a', type: 'capture', title: '夺回「西岸草坪」', subtitle: '绕滨江公园一圈，途经两块低守卫值的地', distance_m: 5200 } },
    { type: 'territory', territory: { id: 12, name: '西岸草坪', guard: 42 } },
  ]],
  ['沙发怪怎么打比较快？', '沙发怪还剩 1200 / 5000 血，今晚 23:00 消失。在它 1 km 范围内跑步每公里造成 100 点伤害；跑团成员 5 分钟内一起合击还有连击加成，叫上城西跑团 3 个人各跑 4 km 基本就能打掉。', [
    { type: 'boss', boss: { id: 5, name: '沙发怪', hp: 1200, max_hp: 5000 } },
  ]],
  ['我膝盖有点疼，今天还跑吗', '膝盖疼的话今天建议休息，或者换成上肢力量 / 普拉提这类不冲击膝盖的训练。如果疼痛持续或者肿胀，请及时就医。等不疼了从 3 km 轻松跑开始恢复。'],
  ['帮我排一下这周的计划', '按你最近 4 周平均每周 18 km：周二 5 km 轻松跑、周四 6 km 节奏跑、周六 8 km 长距离（顺路守一下滨江那两块地），周一和周五可以做 15 分钟跳绳入门。总量约 19 km，比上周多一点点。'],
  ['你能帮我刷点能量吗', '这个问题圈圈暂时回答不了。能量只能通过真实运动获得，跑一圈就有啦。'],
  ['图鉴里雾霾怪的蛋怎么拿', '雾霾怪的掉落表里「夜行蝾螈蛋」掉率 8%，击败后前 3 名会多掷一次。它周末常在静安、普陀一带出没，出现时 App 首页会提醒你。'],
  ['今天跑了 10 公里，帮我写个战报', '今晚 10.2 公里，配速 5\'48"，一口气圈下世纪公园东侧两块地，还给沙发怪补了 1000 点伤害，城西跑团本周排名升到第 3！'],
];

function messages(userId: number): AIMessage[] {
  const idx = db.users.findIndex((u) => u.id === userId);
  if (idx < 0) fail(404, 'not_found', '用户不存在');
  if (idx % 4 === 3) return [];
  const n = 4 + (idx % 4);
  const out: AIMessage[] = [];
  let id = userId * 100;
  const base = Date.now() - (n + 1) * 7 * 3600_000;
  for (let k = 0; k < n; k++) {
    const [qText, aText, cards] = CONVO[(k + idx) % CONVO.length];
    const t = base + k * 7 * 3600_000 + Math.floor(h(idx, k) * 60) * MIN;
    const deleted = k < 2 && idx % 3 === 1; // the user cleared older turns
    out.push({ id: ++id, role: 'user', content: qText, image_url: null, cards: [], ai_generated: false, created_at: new Date(t).toISOString(), deleted });
    out.push({ id: ++id, role: 'assistant', content: aText, image_url: null, cards: cards ?? [], ai_generated: true, created_at: new Date(t + 4000).toISOString(), deleted });
  }
  return out.reverse(); // newest first
}

export function aiRoutes(log: Log): [string, RegExp, Handler][] {
  return [
    ['GET', /^\/ai\/usage$/, ({ q, role }) => {
      requireRole(role, ['admin', 'ops']);
      const days = Number(q.get('days') ?? 7);
      if (!Number.isInteger(days) || days < 1 || days > 90) fail(400, 'invalid_days', 'days 取值 1–90');
      return usage(days);
    }],
    ['GET', /^\/ai\/calls$/, ({ q, role }) => {
      requireRole(role, ['admin', 'ops']);
      return calls(q);
    }],
    ['GET', /^\/users\/(\d+)\/ai-messages$/, ({ m, q, role, adminId }) => {
      requireRole(role, ['admin']);
      const id = Number(m[1]);
      const all = messages(id);
      const page = Math.max(1, Number(q.get('page') ?? 1));
      const size = Math.min(100, Math.max(1, Number(q.get('page_size') ?? 20)));
      log(adminId, 'ai.messages.view', `user:${id}`, { page });
      return { items: all.slice((page - 1) * size, page * size), total: all.length };
    }],
  ];
}
