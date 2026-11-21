// In-memory fake of the admin API, used when app.mock is true (npm run dev:mock → config.mock.yaml).
// Route patterns are relative to api.admin_prefix. Delete this folder (and the import in src/api/client.ts) once the backend is live.
import { ApiError } from '../api/client';
import { ADMIN_PREFIX } from '../config';
import type {
  AdminRole,
  BossDetail,
  Campaign,
  CampaignRules,
  CampaignType,
  ChestListItem,
  Config,
  OrienteeringRoute,
  Season,
  Dashboard,
  GameplayState,
  OrderStats,
  RiskAction,
  RiskAlertDetail,
  RiskRules,
  Territory,
  UserAction,
  UserDetail,
} from '../api/types';
import * as db from './data';

const DAY = 86_400_000;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const today = () => new Date().toISOString().slice(0, 10);

function fail(status: number, code: string, message: string): never {
  throw new ApiError(status, code, message);
}

function clone<T>(x: T): T {
  return JSON.parse(JSON.stringify(x)) as T;
}

function paginate<T>(items: T[], q: URLSearchParams) {
  const page = Math.max(1, Number(q.get('page') ?? 1));
  const size = Math.min(100, Math.max(1, Number(q.get('page_size') ?? 20)));
  return { items: items.slice((page - 1) * size, page * size), total: items.length };
}

let auditSeq = 100;
function log(adminId: number, action: string, target: string, detail: Record<string, unknown> = {}) {
  const a = db.admins.find((x) => x.id === adminId)!;
  db.audit.unshift({ id: ++auditSeq, admin: { id: a.id, username: a.username }, action, target, detail, created_at: new Date().toISOString() });
}

function requireRole(role: AdminRole, allowed: AdminRole[]) {
  if (!allowed.includes(role)) fail(403, 'forbidden', '当前角色没有权限执行此操作');
}

function territorySummaryOf(t: Territory) {
  const { id, name, relation, owner, crew, geometry, center, area_m2, guard, frozen } = t;
  return { id, name, relation, owner, crew, geometry, center, area_m2, guard, frozen };
}

function riskDetail(id: number): RiskAlertDetail {
  const alert = db.riskAlerts.find((a) => a.id === id);
  if (!alert) fail(404, 'not_found', '告警不存在');
  const t = db.territories[id % db.territories.length];
  const start = Date.now() - 6 * 3600_000 - id * 3600_000;
  const n = 25;
  const threshold = db.riskRules.run_max_kmh;
  const speeds = Array.from({ length: n }, (_, k) => {
    let kmh = 10.5 + Math.sin(k / 2) * 0.8 + (k % 3) * 0.3;
    if (alert.type === 'speed' && k >= 9 && k <= 14) kmh = 27 + (k % 3) * 2.1;
    if (alert.type === 'teleport' && k === 12) kmh = 48;
    return { t: start + k * 30_000, kmh: +kmh.toFixed(1), over: kmh > threshold };
  });
  const coords: number[][] = [];
  let lng = t.center.lng - 0.006;
  let lat = t.center.lat - 0.003;
  for (let k = 0; k < 60; k++) {
    const jump = alert.type === 'teleport' && k === 30 ? 0.012 : 0;
    const fast = alert.type === 'speed' && k > 22 && k < 36 ? 2.6 : 1;
    lng += (0.00022 + jump) * fast;
    lat += Math.sin(k / 8) * 0.00018 * fast;
    coords.push([+lng.toFixed(6), +lat.toFixed(6)]);
  }
  const teleports =
    alert.type === 'teleport'
      ? [{ from: { lng: coords[29][0], lat: coords[29][1] }, to: { lng: coords[30][0], lat: coords[30][1] }, distance_m: 1400, gap_s: 2 }]
      : alert.type === 'speed'
        ? [{ from: { lng: coords[22][0], lat: coords[22][1] }, to: { lng: coords[36][0], lat: coords[36][1] }, distance_m: 820, gap_s: 95 }]
        : [];
  const mock = alert.type === 'mock_location';
  const noDevice = alert.type === 'missing_device_data';
  return {
    alert: clone(alert),
    activity: {
      id: alert.activity_id ?? 0,
      sport: 'run',
      status: alert.status === 'open' ? 'review' : 'settled',
      started_at: new Date(start).toISOString(),
      ended_at: new Date(start + 12 * 60_000).toISOString(),
      distance_m: 12600,
      duration_s: 720 * 3,
      avg_pace_s_per_km: 171,
      amount: 12.6,
      energy_granted: 0,
      claimed_area_m2: 3_100_000 / 1000,
      track: { type: 'LineString', coordinates: coords },
      claims: [{ territory_id: t.id, kind: 'claim', area_m2: 3100 }],
    },
    speeds,
    teleports,
    device: {
      id: `dev-${alert.user.id}`,
      model: alert.type === 'device_tamper' ? 'Redmi K60' : 'iPhone15,2',
      os: alert.type === 'device_tamper' ? 'Android 14' : 'iOS 18.1',
      rooted: alert.type === 'device_tamper',
      emulator: false,
      multi_open: alert.type === 'device_tamper' || alert.type === 'multi_account',
    },
    sources: mock ? { gps: 380, network: 0, mock: 620 } : { gps: 980, network: 20, mock: 0 },
    cadence_avg: alert.type === 'speed' || noDevice ? 0 : 168,
    hr_avg: noDevice || alert.type === 'speed' ? null : 151,
    same_device_accounts: alert.type === 'multi_account' ? 5 : 1,
    history: db.riskAlerts.filter((a) => a.user.id === alert.user.id && a.id !== alert.id).map(clone),
  };
}

function userAction(u: UserDetail, action: UserAction, message?: string) {
  const now = Date.now();
  switch (action) {
    case 'gift_member_7d': {
      const base = u.membership?.active && u.membership.expires_at ? Math.max(Date.parse(u.membership.expires_at), now) : now;
      u.membership = {
        ...(u.membership ?? { plan_code: 'gift', plan_name: '体验 7 天', auto_renew: false, channel: 'gift', next_charge_at: null }),
        active: true,
        expires_at: new Date(base + 7 * DAY).toISOString(),
      };
      break;
    }
    case 'notify':
      if (!message?.trim()) fail(400, 'invalid_body', '通知内容不能为空');
      break;
    case 'mute_7d':
      if (u.status === 'banned') fail(409, 'conflict', '用户已封禁');
      u.status = 'muted';
      u.muted_until = new Date(now + 7 * DAY).toISOString();
      break;
    case 'unmute':
      if (u.status === 'muted') u.status = 'active';
      u.muted_until = null;
      break;
    case 'ban':
      u.status = 'banned';
      for (const t of db.territories) if (t.owner?.id === u.id) t.frozen = true;
      break;
    case 'unban':
      if (u.status === 'banned') u.status = 'active';
      for (const t of db.territories) if (t.owner?.id === u.id) t.frozen = false;
      break;
    default:
      fail(400, 'invalid_body', `未知操作 ${String(action)}`);
  }
}

function validateConfig(c: Config) {
  for (const b of c.bosses ?? []) {
    const sum = b.drops.reduce((s, d) => s + Number(d.percent), 0);
    if (Math.abs(sum - 100) > 1e-6) fail(400, 'invalid_config', `${b.name} 掉落合计 ${sum}%，必须等于 100%`);
  }
  for (const b of c.buildings) if (b.cost <= 0) fail(400, 'invalid_config', `${b.name} 建造能量必须大于 0`);
  const tiers = c.season?.tiers ?? [];
  for (let i = 1; i < tiers.length; i++) if (!(tiers[i].min_km2 > tiers[i - 1].min_km2)) fail(400, 'invalid_config', `段位 ${tiers[i].name} 的最低面积必须大于 ${tiers[i - 1].name}`);
  if (c.boss && c.boss.strike_cost <= 0) fail(400, 'invalid_config', '合击消耗能量必须大于 0');
  if (c.chest && c.chest.energy_min > c.chest.energy_max) fail(400, 'invalid_config', '宝箱能量下限不能大于上限');
}

// ---------- V2 helpers ----------

const HOUR = 3_600_000;
const inBbox = (b: number[], p: { lat: number; lng: number }) => p.lng >= b[0] && p.lng <= b[2] && p.lat >= b[1] && p.lat <= b[3];

function parseBbox(raw: unknown): [number, number, number, number] {
  const arr = Array.isArray(raw) ? raw.map(Number) : String(raw ?? '').split(',').map(Number);
  if (arr.length !== 4 || !arr.every(Number.isFinite)) fail(400, 'invalid_bbox', 'bbox 格式应为 minLng,minLat,maxLng,maxLat');
  const [a, b, c, d] = arr;
  if (a >= c || b >= d || c - a > 2 || d - b > 2) fail(400, 'invalid_bbox', 'bbox 范围无效或过大（最多 2 度）');
  return [a, b, c, d];
}

function bossListItem(b: BossDetail) {
  const { id, kind, name, level, location_name, hp, hp_max, participants, spawned_by, spawned_at, expires_at, status, center, radius_m, defeated_at } = b;
  return { id, kind, name, level, location_name, hp, hp_max, participants, spawned_by: spawned_by ?? null, spawned_at, expires_at, status, center, radius_m, defeated_at };
}

function seasonStatus(x: Season): Season {
  if (x.settled_at) return { ...x, status: 'settled' };
  const now = Date.now();
  if (Date.parse(x.starts_at) > now) return { ...x, status: 'upcoming' };
  if (Date.parse(x.ends_at) > now) return { ...x, status: 'active' };
  return { ...x, status: 'ended' };
}

function seasonInput(body: Record<string, unknown>, selfId: number | null) {
  const name = String(body.name ?? '').trim();
  const starts = Date.parse(String(body.starts_at ?? ''));
  const ends = Date.parse(String(body.ends_at ?? ''));
  if (!name) fail(400, 'invalid_body', '赛季名称必填');
  if (!Number.isFinite(starts) || !Number.isFinite(ends) || ends <= starts) fail(400, 'invalid_body', '结束时间必须晚于开始时间');
  const clash = db.seasons.find((x) => x.id !== selfId && Date.parse(x.starts_at) < ends && starts < Date.parse(x.ends_at));
  if (clash) fail(409, 'season_overlap', `时间和「${clash.name}」重叠`);
  return { name, starts_at: new Date(starts).toISOString(), ends_at: new Date(ends).toISOString() };
}

function campaignInput(body: Record<string, unknown>) {
  const title = String(body.title ?? '').trim();
  const type = body.type as CampaignType;
  if (!title) fail(400, 'invalid_body', '活动标题必填');
  if (!['pace', 'night_run', 'distance'].includes(type)) fail(400, 'invalid_body', '活动类型无效');
  const r = (body.rules ?? {}) as CampaignRules;
  if (!(Number(r.min_distance_km) > 0)) fail(400, 'invalid_rules', '最短距离必须大于 0');
  if (type === 'pace' && !(Number(r.max_pace_s_per_km) > 0)) fail(400, 'invalid_rules', '配速挑战需要设置配速上限');
  if (type === 'night_run' && (r.start_hour_from === undefined || r.start_hour_to === undefined)) fail(400, 'invalid_rules', '夜跑专场需要设置出发时段');
  const rules: CampaignRules =
    type === 'pace'
      ? { min_distance_km: r.min_distance_km, max_pace_s_per_km: r.max_pace_s_per_km }
      : type === 'night_run'
        ? { min_distance_km: r.min_distance_km, start_hour_from: r.start_hour_from, start_hour_to: r.start_hour_to }
        : { min_distance_km: r.min_distance_km };
  const starts = Date.parse(String(body.starts_at ?? ''));
  const ends = Date.parse(String(body.ends_at ?? ''));
  if (!Number.isFinite(starts) || !Number.isFinite(ends) || ends <= starts) fail(400, 'invalid_body', '结束时间必须晚于开始时间');
  const medal = String(body.reward_medal_name ?? '').trim();
  return {
    title, type, description: String(body.description ?? ''), rules,
    starts_at: new Date(starts).toISOString(), ends_at: new Date(ends).toISOString(),
    reward_energy: Number(body.reward_energy ?? 0), medalName: medal,
  };
}

function routeInput(body: Record<string, unknown>) {
  const name = String(body.name ?? '').trim();
  if (!name) fail(400, 'invalid_body', '路线名称必填');
  const cps = (body.checkpoints ?? []) as { name: string; lat: number; lng: number; radius_m: number }[];
  if (!Array.isArray(cps) || cps.length < 2 || cps.length > 12) fail(400, 'invalid_checkpoints', '打卡点需要 2–12 个');
  for (const c of cps) if (!c.name || !Number.isFinite(c.lat) || !Number.isFinite(c.lng) || !(c.radius_m > 0)) fail(400, 'invalid_checkpoints', '每个打卡点都要有名称、坐标和半径');
  const starts = Date.parse(String(body.starts_at ?? ''));
  const ends = Date.parse(String(body.ends_at ?? ''));
  if (!Number.isFinite(starts) || !Number.isFinite(ends) || ends <= starts) fail(400, 'invalid_body', '结束时间必须晚于开始时间');
  return {
    name, description: String(body.description ?? ''), reward_energy: Number(body.reward_energy ?? 0),
    starts_at: new Date(starts).toISOString(), ends_at: new Date(ends).toISOString(),
    checkpoints: cps.map((c, index) => ({ index, name: c.name, lat: c.lat, lng: c.lng, radius_m: c.radius_m })),
  };
}

function mondayOf(d: Date): string {
  const x = new Date(d);
  x.setHours(0, 0, 0, 0);
  x.setDate(x.getDate() - ((x.getDay() + 6) % 7));
  return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`;
}

function bumpVersion(v: string): string {
  const m = /^v(\d+)\.(\d+)$/.exec(v);
  return m ? `v${m[1]}.${Number(m[2]) + 1}` : `${v}.1`;
}

type Handler = (ctx: { m: RegExpMatchArray; q: URLSearchParams; body: Record<string, unknown>; adminId: number; role: AdminRole }) => unknown;

const routes: [string, RegExp, Handler][] = [
  ['GET', /^\/me$/, ({ adminId }) => {
    const a = db.admins.find((x) => x.id === adminId)!;
    return { id: a.id, username: a.username, role: a.role };
  }],

  ['GET', /^\/dashboard$/, (): Dashboard => {
    const open = db.riskAlerts.filter((a) => a.status === 'open').length;
    const refunds = db.orders.filter((o) => o.status === 'refund_requested').length;
    const renew = db.orders.filter((o) => o.status === 'renew_failed').length;
    const last = db.trend.active_users.length - 1;
    const todos: Dashboard['todos'] = [];
    if (open) todos.push({ type: 'risk', title: `${open} 条风控告警待处理`, count: open, priority: 1, link: '/risk' });
    if (refunds) todos.push({ type: 'refund', title: `${refunds} 笔会员退款申请`, count: refunds, priority: 2, link: '/orders?status=refund_requested' });
    if (renew) todos.push({ type: 'renew_failed', title: `${renew} 笔自动续费失败`, count: renew, priority: 3, link: '/orders?status=renew_failed' });
    return {
      today: { active_users: db.trend.active_users[last], activities: 31620, new_territories: db.trend.new_territories[last], pending_risk: open },
      last_week: { active_users: db.trend.active_users[last - 7], activities: 30380, new_territories: db.trend.new_territories[last - 7], pending_risk: open + 2 },
      trend: db.trend,
      todos,
    };
  }],

  // users
  ['GET', /^\/users\/stats$/, () => ({
    total: 312480,
    today_new: 1286,
    retention_7d: 0.42,
    members: 18600,
    sources: [
      { provider: 'oneclick', count: 14820 },
      { provider: 'wechat', count: 10530 },
      { provider: 'sms', count: 6630 },
      { provider: 'apple', count: 4290 },
    ],
  })],
  ['GET', /^\/users$/, ({ q }) => {
    const kw = (q.get('q') ?? '').trim();
    const filter = q.get('filter') ?? 'all';
    let list = db.users;
    if (kw) list = list.filter((u) => u.nickname.includes(kw) || String(u.id) === kw || (kw.length === 4 && (u.phone_masked ?? '').endsWith(kw)));
    if (filter === 'member') list = list.filter((u) => u.membership?.active);
    if (filter === 'today') list = list.filter((u) => u.created_at.slice(0, 10) === today() || Date.now() - Date.parse(u.created_at) < DAY);
    if (filter === 'abnormal') list = list.filter((u) => u.status === 'muted' || u.status === 'banned' || u.risk_alerts.some((a) => a.status === 'open'));
    return paginate(
      list.map((u) => ({ id: u.id, nickname: u.nickname, phone_masked: u.phone_masked, source: u.source, created_at: u.created_at, member: !!u.membership?.active, status: u.status, delete_after: u.delete_after })),
      q,
    );
  }],
  ['GET', /^\/users\/(\d+)$/, ({ m }) => {
    const u = db.users.find((x) => x.id === Number(m[1]));
    if (!u) fail(404, 'not_found', '用户不存在');
    return clone(u);
  }],
  ['POST', /^\/users\/(\d+)\/reveal-phone$/, ({ m, role, adminId }) => {
    requireRole(role, ['admin', 'ops', 'reviewer']);
    const id = Number(m[1]);
    const phone = db.phones.get(id);
    if (!phone) fail(404, 'not_found', '用户不存在');
    log(adminId, 'user.reveal_phone', `user:${id}`);
    return { phone };
  }],
  ['POST', /^\/users\/(\d+)\/actions$/, ({ m, body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const u = db.users.find((x) => x.id === Number(m[1]));
    if (!u) fail(404, 'not_found', '用户不存在');
    userAction(u, body.action as UserAction, body.message as string | undefined);
    log(adminId, `user.${String(body.action)}`, `user:${u.id}`, body.message ? { message: body.message } : {});
    return clone(u);
  }],

  // plans & orders
  ['GET', /^\/entitlements$/, () => ({ items: clone(db.entitlements) })],
  ['GET', /^\/plans$/, () => ({ items: clone([...db.plans].sort((a, b) => a.sort - b.sort)) })],
  ['PUT', /^\/plans\/([\w-]+)$/, ({ m, body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const p = db.plans.find((x) => x.code === m[1]);
    if (!p) fail(404, 'not_found', '套餐不存在');
    const price = Number(body.price_fen);
    // Like the server: null keeps the intro price, 0 clears it.
    const first = body.first_price_fen === null || body.first_price_fen === undefined ? p.first_price_fen : Number(body.first_price_fen) || null;
    if (!(price > 0)) fail(400, 'invalid_price', '价格必须在 ¥0.01–¥10000 之间');
    if (body.recommended) for (const x of db.plans) x.recommended = false;
    Object.assign(p, {
      name: String(body.name), price_fen: price, first_price_fen: first, renew_price_fen: Number(body.renew_price_fen),
      on_sale: !!body.on_sale, recommended: !!body.recommended, sort: Number(body.sort),
    });
    log(adminId, 'plan.update', `plan:${p.code}`, { price_fen: price, first_price_fen: first, on_sale: p.on_sale });
    return clone(p);
  }],
  ['PUT', /^\/plans\/([\w-]+)\/entitlements$/, ({ m, body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const p = db.plans.find((x) => x.code === m[1]);
    if (!p) fail(404, 'not_found', '套餐不存在');
    const list = (body.entitlements as string[]) ?? [];
    const locked = list.find((k) => db.entitlements.find((e) => e.key === k)?.locked);
    if (locked) fail(400, 'entitlement_locked', '「抢地守卫加成」「额外能量」不能放进任何套餐');
    p.entitlements = list;
    log(adminId, 'plan.entitlements', `plan:${p.code}`, { entitlements: list });
    return clone(p);
  }],
  ['GET', /^\/orders\/stats$/, (): OrderStats => ({ month_revenue_fen: 28_600_000, active_members: 18600, renew_success_rate: 0.81, refund_rate_today: 0.0143 })],
  ['GET', /^\/orders$/, ({ q }) => {
    const status = q.get('status');
    const kw = (q.get('q') ?? '').trim();
    let list = db.orders;
    if (status) list = list.filter((o) => o.status === status);
    if (kw) list = list.filter((o) => o.order_no.includes(kw) || o.user.nickname.includes(kw) || String(o.user.id) === kw);
    return paginate(list.map(clone), q);
  }],
  ['POST', /^\/orders\/(\w+)\/refund$/, ({ m, body, role, adminId }) => {
    requireRole(role, ['admin']);
    const o = db.orders.find((x) => x.order_no === m[1]);
    if (!o) fail(404, 'not_found', '订单不存在');
    if (body.confirm !== true) fail(400, 'invalid_body', '需要 confirm=true');
    if (o.status !== 'paid' && o.status !== 'refund_requested') fail(409, 'conflict', '该订单状态不能退款');
    o.status = 'refunded';
    log(adminId, 'order.refund', `order:${o.order_no}`, { reason: body.reason });
    const { user: _user, ...order } = o;
    return clone(order);
  }],
  ['POST', /^\/orders\/(\w+)\/remind$/, ({ m, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const o = db.orders.find((x) => x.order_no === m[1]);
    if (!o) fail(404, 'not_found', '订单不存在');
    if (o.status !== 'renew_failed') fail(409, 'conflict', '只有续费失败的订单可以提醒');
    log(adminId, 'order.remind', `order:${o.order_no}`);
    return {};
  }],

  // territories
  ['GET', /^\/territories\/geo$/, ({ q }) => {
    const bbox = (q.get('bbox') ?? '').split(',').map(Number);
    if (bbox.length !== 4 || !bbox.every(Number.isFinite)) fail(400, 'invalid_bbox', 'bbox 格式应为 minLng,minLat,maxLng,maxLat');
    const [a, b, c, d] = bbox;
    if (a >= c || b >= d || c - a > 2 || d - b > 2) fail(400, 'invalid_bbox', 'bbox 范围无效或过大（最多 2 度）');
    const list = db.territories.filter((t) => t.center.lng >= a && t.center.lng <= c && t.center.lat >= b && t.center.lat <= d);
    return { items: list.map((t) => clone(territorySummaryOf(t))) };
  }],
  ['GET', /^\/territories$/, ({ q }) => {
    const status = q.get('status') ?? 'all';
    const kw = (q.get('q') ?? '').trim();
    let list = db.territories;
    if (status === 'contested') list = list.filter((t) => (db.territoryMeta.get(t.id)?.changes_today ?? 0) > 0);
    if (status === 'frozen') list = list.filter((t) => t.frozen);
    if (kw) list = list.filter((t) => t.name.includes(kw) || String(t.id) === kw || (t.owner?.nickname ?? '').includes(kw));
    return paginate(
      list.map((t) => ({
        id: t.id, name: t.name, owner: t.owner, crew: t.crew, area_m2: t.area_m2, guard: t.guard, frozen: t.frozen,
        changes_today: db.territoryMeta.get(t.id)?.changes_today ?? 0,
        building_count: t.slots.filter((s) => s.building).length,
        center: t.center,
        updated_at: db.territoryMeta.get(t.id)?.updated_at ?? t.captured_at,
      })),
      q,
    );
  }],
  ['GET', /^\/territories\/(\d+)$/, ({ m }) => {
    const t = db.territories.find((x) => x.id === Number(m[1]));
    if (!t) fail(404, 'not_found', '领地不存在');
    return clone(t);
  }],
  ['POST', /^\/territories\/(\d+)\/(guard|freeze|reset)$/, ({ m, body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const t = db.territories.find((x) => x.id === Number(m[1]));
    if (!t) fail(404, 'not_found', '领地不存在');
    const a = db.admins.find((x) => x.id === adminId)!;
    const now = new Date().toISOString();
    if (m[2] === 'guard') {
      const g = Number(body.guard);
      if (!Number.isInteger(g) || g < 0 || g > 2000 || g % 50 !== 0) fail(400, 'invalid_body', '守卫值须在 0–2000 之间，步长 50');
      t.events.unshift({ kind: 'admin_guard', actor: null, prev_guard: t.guard, new_guard: g, admin: a.id, created_at: now });
      t.guard = g;
      log(adminId, 'territory.guard', `territory:${t.id}`, { guard: g });
    } else if (m[2] === 'freeze') {
      t.frozen = !!body.frozen;
      t.events.unshift({ kind: t.frozen ? 'freeze' : 'unfreeze', actor: null, admin: a.id, created_at: now });
      log(adminId, 'territory.freeze', `territory:${t.id}`, { frozen: t.frozen });
    } else {
      t.events.unshift({ kind: 'reset', actor: null, prev_owner: t.owner, new_owner: null, prev_guard: t.guard, new_guard: 0, admin: a.id, created_at: now });
      t.owner = null;
      t.crew = null;
      t.relation = 'unowned';
      t.guard = 0;
      t.frozen = false;
      t.slots = t.slots.map((s) => ({ ...s, building: null, name: null }));
      t.stationed = [];
      t.daily_energy = 0;
      log(adminId, 'territory.reset', `territory:${t.id}`);
    }
    db.territoryMeta.set(t.id, { changes_today: db.territoryMeta.get(t.id)?.changes_today ?? 0, updated_at: now });
    return clone(t);
  }],

  // risk
  ['GET', /^\/risk\/alerts$/, ({ q }) => {
    const status = q.get('status') || 'open'; // server default
    const type = q.get('type');
    let list = [...db.riskAlerts];
    if (status) list = list.filter((a) => a.status === status);
    if (type) list = list.filter((a) => a.type === type);
    list.sort((a, b) => b.confidence - a.confidence);
    return paginate(list.map(clone), q);
  }],
  ['GET', /^\/risk\/alerts\/(\d+)$/, ({ m }) => riskDetail(Number(m[1]))],
  ['POST', /^\/risk\/alerts\/(\d+)\/resolve$/, ({ m, body, role, adminId }) => {
    requireRole(role, ['admin', 'ops', 'reviewer']);
    const a = db.riskAlerts.find((x) => x.id === Number(m[1]));
    if (!a) fail(404, 'not_found', '告警不存在');
    if (a.status === 'resolved') fail(409, 'conflict', '该告警已处理');
    const action = body.action as RiskAction;
    a.status = 'resolved';
    a.resolution = action;
    a.note = String(body.note ?? '') || null;
    if (action === 'ban_30d') {
      const u = db.users.find((x) => x.id === a.user.id);
      if (u) u.status = 'banned';
    }
    log(adminId, `risk.${action}`, `alert:${a.id}`, { note: body.note ?? '' });
    return clone(a);
  }],
  ['GET', /^\/risk\/rules$/, () => clone(db.riskRules)],
  ['PUT', /^\/risk\/rules$/, ({ body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    Object.assign(db.riskRules, body as unknown as RiskRules);
    log(adminId, 'risk.rules', 'risk_rules', body);
    return clone(db.riskRules);
  }],

  // gameplay
  ['GET', /^\/gameplay$/, () => clone(db.gameplay)],
  ['POST', /^\/gameplay\/publish$/, ({ body, role, adminId }): GameplayState => {
    requireRole(role, ['admin']);
    const cfg = body.body as Config;
    validateConfig(cfg);
    const pctv = Number(body.rollout_pct);
    if (pctv !== 10 && pctv !== 100) fail(400, 'invalid_body', 'rollout_pct 只能是 10 或 100');
    const version = bumpVersion(db.gameplay.current.version);
    const a = db.admins.find((x) => x.id === adminId)!;
    const now = new Date().toISOString();
    db.gameplay.previous = db.gameplay.current;
    db.gameplay.current = { version, rollout_pct: pctv, body: { ...clone(cfg), version }, note: String(body.note ?? ''), published_by: a.id, published_at: now };
    db.gameplay.history.unshift({ version, note: String(body.note ?? ''), rollout_pct: pctv, published_by: a.id, published_at: now });
    log(adminId, 'gameplay.publish', `gameplay:${version}`, { rollout_pct: pctv });
    return clone(db.gameplay);
  }],
  ['POST', /^\/gameplay\/rollout$/, ({ body, role, adminId }) => {
    requireRole(role, ['admin']);
    db.gameplay.current.rollout_pct = Number(body.rollout_pct ?? 100);
    const h = db.gameplay.history.find((x) => x.version === db.gameplay.current.version);
    if (h) h.rollout_pct = db.gameplay.current.rollout_pct;
    log(adminId, 'gameplay.rollout', `gameplay:${db.gameplay.current.version}`, { rollout_pct: db.gameplay.current.rollout_pct });
    return clone(db.gameplay);
  }],
  ['POST', /^\/gameplay\/rollback$/, ({ role, adminId }) => {
    requireRole(role, ['admin']);
    if (!db.gameplay.previous) fail(409, 'conflict', '没有可以回滚的上一个版本');
    const gone = db.gameplay.current.version;
    db.gameplay.current = db.gameplay.previous;
    db.gameplay.previous = null;
    db.gameplay.history = db.gameplay.history.filter((h) => h.version !== gone);
    log(adminId, 'gameplay.rollback', `gameplay:${gone}`);
    return clone(db.gameplay);
  }],

  // V2 玩法运营
  ['GET', /^\/map\/objects$/, ({ q }) => {
    const b = parseBbox(q.get('bbox'));
    const now = Date.now();
    return {
      bosses: db.bosses
        .filter((x) => x.status === 'active' && inBbox(b, x.center))
        .map(({ id, kind, name, level, center, radius_m, hp, hp_max, expires_at, location_name }) => ({ id, kind, name, level, center, radius_m, hp, hp_max, expires_at, location_name })),
      chests: db.chests.filter((x) => x.status === 'active' && inBbox(b, x.center)).map((x) => ({ id: x.id, center: x.center, radius_m: x.radius_m ?? 50, expires_at: x.expires_at })),
      checkpoints: db.routes
        .filter((r) => Date.parse(r.starts_at) <= now && Date.parse(r.ends_at) > now)
        .flatMap((r) => r.checkpoints.map((c, index) => ({ route_id: r.id, index, name: c.name, center: { lat: c.lat!, lng: c.lng! }, radius_m: c.radius_m })))
        .filter((c) => inBbox(b, c.center)),
    };
  }],
  ['GET', /^\/bosses$/, ({ q }) => {
    const status = q.get('status');
    const list = db.bosses.filter((b) => !status || b.status === status).sort((a, b) => b.spawned_at.localeCompare(a.spawned_at));
    return paginate(list.map((b) => clone(bossListItem(b))), q);
  }],
  ['GET', /^\/bosses\/(\d+)$/, ({ m }) => {
    const b = db.bosses.find((x) => x.id === Number(m[1]));
    if (!b) fail(404, 'not_found', '怪兽不存在');
    return clone(b);
  }],
  ['POST', /^\/bosses$/, ({ body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const kind = String(body.kind ?? '');
    const conf = db.gameplay.current.body.bosses.find((x) => x.key === kind);
    if (!conf) fail(400, 'invalid_body', '怪兽种类无效');
    const lat = Number(body.lat);
    const lng = Number(body.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) fail(400, 'invalid_body', '坐标无效');
    const location_name = String(body.location_name ?? '').trim();
    if (!location_name) fail(400, 'invalid_body', '地点名称必填');
    const rules = db.gameplay.current.body.boss;
    const hp = Number(body.hp ?? rules?.default_hp ?? 10000);
    const radius = Number(body.radius_m ?? rules?.radius_m ?? 1000);
    const hours = Number(body.duration_h ?? rules?.duration_h ?? 48);
    if (!(hp > 0) || !(radius > 0) || !(hours > 0)) fail(400, 'invalid_body', '血量、半径、持续时间必须大于 0');
    const now = Date.now();
    const tpl = db.bosses[0];
    const b: BossDetail = {
      ...clone(tpl),
      id: Math.max(...db.bosses.map((x) => x.id)) + 1,
      kind, name: conf.name, level: Number(body.level ?? 10), location_name,
      center: { lat, lng }, radius_m: radius, hp, hp_max: hp, status: 'active',
      spawned_at: new Date(now).toISOString(), expires_at: new Date(now + hours * HOUR).toISOString(), defeated_at: null,
      spawned_by: adminId, occupied_territories: db.territories.filter((t) => Math.hypot((t.center.lat - lat) * 110574, (t.center.lng - lng) * 95300) < radius).length,
      participants: 0, rank: [], rewards: [],
      drops: conf.drops.map((d) => ({ ...d, name: tpl.drops.find((x) => x.item === d.item)?.name ?? d.item })),
    };
    db.bosses.unshift(b);
    log(adminId, 'boss.spawn', `boss:${b.id}`, { kind, lat, lng, hp, radius_m: radius, duration_h: hours });
    return clone(b);
  }],
  ['POST', /^\/bosses\/(\d+)\/end$/, ({ m, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const b = db.bosses.find((x) => x.id === Number(m[1]));
    if (!b) fail(404, 'not_found', '怪兽不存在');
    if (b.status !== 'active') fail(409, 'boss_not_active', '怪兽已经结束');
    b.status = 'expired';
    b.expires_at = new Date().toISOString();
    b.rewards = b.rank.map((r) => ({ user: r.user, rank: r.rank, damage: r.damage, items: [], energy: 20 }));
    log(adminId, 'boss.end', `boss:${b.id}`);
    return clone(b);
  }],

  ['GET', /^\/chests$/, ({ q }) => {
    const status = q.get('status') ?? '';
    if (!['', 'active', 'expired', 'removed'].includes(status)) fail(400, 'invalid_status', 'status 取值 active / expired / removed');
    const list = db.chests.filter((c) => !status || c.status === status).sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
    return paginate(list.map(clone), q);
  }],
  ['POST', /^\/chests$/, ({ body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const lat = Number(body.lat);
    const lng = Number(body.lng);
    const min = Number(body.energy_min);
    const max = Number(body.energy_max);
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) fail(400, 'invalid_body', '坐标无效');
    if (!(min > 0) || !(max >= min)) fail(400, 'invalid_body', '能量范围无效');
    const now = Date.now();
    const c: ChestListItem = {
      id: Math.max(...db.chests.map((x) => x.id)) + 1, center: { lat, lng }, radius_m: Number(body.radius_m ?? 50),
      energy_min: min, energy_max: max, opens: 0, source: 'admin', status: 'active',
      created_at: new Date(now).toISOString(), expires_at: new Date(now + Number(body.duration_h ?? 24) * HOUR).toISOString(),
    };
    db.chests.unshift(c);
    log(adminId, 'chest.place', `chest:${c.id}`, { lat, lng, energy_min: min, energy_max: max });
    return clone(c);
  }],
  ['POST', /^\/chests\/scatter$/, ({ body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const [a, b, c, d] = parseBbox(body.bbox);
    const count = Number(body.count);
    if (!Number.isInteger(count) || count < 1 || count > 200) fail(400, 'invalid_body', '数量须在 1–200 之间');
    const rules = db.gameplay.current.body.chest;
    const now = Date.now();
    let id = Math.max(...db.chests.map((x) => x.id));
    const made: ChestListItem[] = Array.from({ length: count }, () => ({
      id: ++id,
      center: { lat: +(b + Math.random() * (d - b)).toFixed(6), lng: +(a + Math.random() * (c - a)).toFixed(6) },
      radius_m: rules?.radius_m ?? 50, energy_min: rules?.energy_min ?? 20, energy_max: rules?.energy_max ?? 60,
      opens: 0, source: 'admin', status: 'active',
      created_at: new Date(now).toISOString(), expires_at: new Date(now + Number(body.duration_h ?? 24) * HOUR).toISOString(),
    }));
    db.chests.unshift(...made);
    log(adminId, 'chest.scatter', 'chests', { bbox: [a, b, c, d], count, duration_h: body.duration_h });
    return { placed: made.length };
  }],
  ['DELETE', /^\/chests\/(\d+)$/, ({ m, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const c = db.chests.find((x) => x.id === Number(m[1]));
    if (!c || c.status === 'removed') fail(404, 'not_found', '宝箱不存在');
    c.status = 'removed';
    log(adminId, 'chest.remove', `chest:${c.id}`);
    return {};
  }],

  ['GET', /^\/seasons$/, () => {
    const items = [...db.seasons].sort((a, b) => b.starts_at.localeCompare(a.starts_at)).map(seasonStatus);
    return { items: clone(items), total: items.length };
  }],
  ['POST', /^\/seasons$/, ({ body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const v = seasonInput(body, null);
    const x: Season = { id: Math.max(...db.seasons.map((s) => s.id)) + 1, ...v, settled_at: null };
    db.seasons.push(x);
    log(adminId, 'season.create', `season:${x.id}`, v);
    return clone(seasonStatus(x));
  }],
  ['PATCH', /^\/seasons\/(\d+)$/, ({ m, body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const x = db.seasons.find((s) => s.id === Number(m[1]));
    if (!x) fail(404, 'not_found', '赛季不存在');
    if (x.settled_at) fail(409, 'season_settled', '赛季已结算，不能修改');
    Object.assign(x, seasonInput({ ...x, ...body }, x.id));
    log(adminId, 'season.update', `season:${x.id}`, body);
    return clone(seasonStatus(x));
  }],
  ['POST', /^\/seasons\/(\d+)\/settle$/, ({ m, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const x = db.seasons.find((s) => s.id === Number(m[1]));
    if (!x) fail(404, 'not_found', '赛季不存在');
    if (x.settled_at) fail(409, 'season_settled', '赛季已结算');
    x.settled_at = new Date().toISOString();
    if (Date.parse(x.ends_at) > Date.now()) x.ends_at = x.settled_at;
    log(adminId, 'season.settle', `season:${x.id}`);
    return clone(seasonStatus(x));
  }],

  ['GET', /^\/campaigns$/, () => {
    const items = [...db.campaigns].sort((a, b) => b.starts_at.localeCompare(a.starts_at));
    return { items: clone(items), total: items.length };
  }],
  ['POST', /^\/campaigns$/, ({ body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const { medalName, ...v } = campaignInput(body);
    const id = Math.max(...db.campaigns.map((c) => c.id)) + 1;
    const c: Campaign = { id, ...v, reward_medal: medalName ? { key: `campaign_${id}`, name: medalName } : null, participants: 0, completed_count: 0 };
    db.campaigns.push(c);
    log(adminId, 'campaign.create', `campaign:${c.id}`, { title: c.title, type: c.type });
    return clone(c);
  }],
  ['PATCH', /^\/campaigns\/(\d+)$/, ({ m, body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const c = db.campaigns.find((x) => x.id === Number(m[1]));
    if (!c) fail(404, 'not_found', '活动不存在');
    const { medalName, ...v } = campaignInput({ ...c, reward_medal_name: c.reward_medal?.name ?? null, ...body });
    Object.assign(c, v, { reward_medal: medalName ? { key: c.reward_medal?.key ?? `campaign_${c.id}`, name: medalName } : null });
    log(adminId, 'campaign.update', `campaign:${c.id}`, body);
    return clone(c);
  }],
  ['DELETE', /^\/campaigns\/(\d+)$/, ({ m, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const i = db.campaigns.findIndex((x) => x.id === Number(m[1]));
    if (i < 0) fail(404, 'not_found', '活动不存在');
    if (Date.parse(db.campaigns[i].starts_at) <= Date.now()) fail(409, 'campaign_started', '活动已开始，不能删除');
    log(adminId, 'campaign.delete', `campaign:${db.campaigns[i].id}`);
    db.campaigns.splice(i, 1);
    return {};
  }],

  ['GET', /^\/routes$/, () => {
    const items = [...db.routes].sort((a, b) => b.starts_at.localeCompare(a.starts_at));
    return { items: clone(items), total: items.length };
  }],
  ['POST', /^\/routes$/, ({ body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const v = routeInput(body);
    const r: OrienteeringRoute = { id: Math.max(...db.routes.map((x) => x.id)) + 1, ...v, finishers: 0 };
    db.routes.push(r);
    log(adminId, 'route.create', `route:${r.id}`, { name: r.name, checkpoints: r.checkpoints.length });
    return clone(r);
  }],
  ['PATCH', /^\/routes\/(\d+)$/, ({ m, body, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const r = db.routes.find((x) => x.id === Number(m[1]));
    if (!r) fail(404, 'not_found', '路线不存在');
    Object.assign(r, routeInput({ ...r, ...body }));
    log(adminId, 'route.update', `route:${r.id}`, { name: r.name });
    return clone(r);
  }],
  ['DELETE', /^\/routes\/(\d+)$/, ({ m, role, adminId }) => {
    requireRole(role, ['admin', 'ops']);
    const i = db.routes.findIndex((x) => x.id === Number(m[1]));
    if (i < 0) fail(404, 'not_found', '路线不存在');
    log(adminId, 'route.delete', `route:${db.routes[i].id}`);
    db.routes.splice(i, 1);
    return {};
  }],

  ['GET', /^\/districts$/, ({ role }) => {
    requireRole(role, ['admin', 'ops']);
    return { items: clone(db.DISTRICTS) };
  }],
  ['GET', /^\/league$/, ({ q, role }) => {
    requireRole(role, ['admin', 'ops']);
    const district = q.get('district') || db.DISTRICTS[0].name;
    const week = q.get('week_start') || mondayOf(new Date());
    if (!/^\d{4}-\d{2}-\d{2}$/.test(week)) fail(400, 'invalid_body', 'week_start 格式应为 YYYY-MM-DD');
    return { week_start: week, district, standings: week > mondayOf(new Date()) ? [] : db.leagueFor(district, week) };
  }],

  // audit & admins
  ['GET', /^\/audit$/, ({ q }) => {
    const id = q.get('admin_id');
    const list = id ? db.audit.filter((a) => a.admin.id === Number(id)) : db.audit;
    return paginate(list.map(clone), q);
  }],
  ['GET', /^\/admins$/, ({ role }) => {
    requireRole(role, ['admin']);
    return { items: clone(db.admins) };
  }],
  ['POST', /^\/admins$/, ({ body, role, adminId }) => {
    requireRole(role, ['admin']);
    const username = String(body.username ?? '').trim();
    if (!username || String(body.password ?? '').length < 8) fail(400, 'invalid_body', '用户名必填，密码至少 8 位');
    if (db.admins.some((a) => a.username === username)) fail(409, 'conflict', '用户名已存在');
    const a = { id: Math.max(...db.admins.map((x) => x.id)) + 1, username, role: body.role as AdminRole, disabled: false, created_at: new Date().toISOString() };
    db.admins.push(a);
    log(adminId, 'admin.create', `admin:${a.id}`, { role: a.role });
    return clone(a);
  }],
  ['PATCH', /^\/admins\/(\d+)$/, ({ m, body, role, adminId }) => {
    requireRole(role, ['admin']);
    const a = db.admins.find((x) => x.id === Number(m[1]));
    if (!a) fail(404, 'not_found', '账号不存在');
    if (a.id === adminId && (body.disabled === true || (body.role && body.role !== 'admin'))) fail(409, 'conflict', '不能停用自己或降低自己的权限');
    if (body.role) a.role = body.role as AdminRole;
    if (typeof body.disabled === 'boolean') a.disabled = body.disabled;
    log(adminId, 'admin.update', `admin:${a.id}`, { role: body.role, disabled: body.disabled, password: body.password ? '***' : undefined });
    return clone(a);
  }],
];

export async function mockFetch(method: string, url: string, body: unknown, token: string | null): Promise<unknown> {
  await sleep(120 + Math.random() * 120);
  const [fullPath, qs] = url.split('?');
  if (!fullPath.startsWith(ADMIN_PREFIX + '/')) fail(404, 'not_found', `mock: ${method} ${fullPath} 不在 ${ADMIN_PREFIX} 下`);
  const path = fullPath.slice(ADMIN_PREFIX.length);
  const q = new URLSearchParams(qs ?? '');
  const b = (body ?? {}) as Record<string, unknown>;

  if (method === 'POST' && path === '/login') {
    const a = db.admins.find((x) => x.username === String(b.username ?? '').trim());
    if (!a || !b.password || b.password === 'wrong') fail(401, 'invalid_credentials', '用户名或密码错误');
    if (a.disabled) fail(403, 'forbidden', '账号已停用');
    log(a.id, 'admin.login', `admin:${a.id}`);
    return { token: `mock-${a.id}`, admin: { id: a.id, username: a.username, role: a.role } };
  }

  const adminId = Number(/^mock-(\d+)$/.exec(token ?? '')?.[1]);
  const admin = db.admins.find((x) => x.id === adminId);
  if (!admin || admin.disabled) fail(401, 'unauthorized', '登录已过期，请重新登录');

  for (const [mth, re, h] of routes) {
    if (mth !== method) continue;
    const m = path.match(re);
    if (m) return h({ m, q, body: b, adminId: admin.id, role: admin.role });
  }
  fail(404, 'not_found', `mock: ${method} ${path} 未实现`);
}
