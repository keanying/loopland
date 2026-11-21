// Fixture data for mock mode (app.mock: true in config.yaml). Shapes follow docs/api/v1.md exactly.
// Everything here is deterministic (seeded) so screenshots are stable.
import type {
  AdminAccount,
  AdminOrder,
  AuditItem,
  BossDetail,
  Campaign,
  ChestListItem,
  OrienteeringRoute,
  Season,
  Config,
  Entitlement,
  GameplayState,
  OrderStatus,
  Plan,
  RiskAlert,
  RiskRules,
  RiskType,
  Territory,
  TerritoryEvent,
  UserDetail,
  UserStatus,
} from '../api/types';

function mulberry32(seed: number) {
  let a = seed;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export const rand = mulberry32(20261120);
const pick = <T,>(arr: T[]): T => arr[Math.floor(rand() * arr.length)];
const int = (lo: number, hi: number) => Math.floor(lo + rand() * (hi - lo + 1));

const NOW = Date.now();
const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
export const iso = (ms: number) => new Date(ms).toISOString();
export const ago = (ms: number) => iso(NOW - ms);

// ---------------- admins ----------------

export const admins: AdminAccount[] = [
  { id: 1, username: 'admin', role: 'admin', disabled: false, created_at: ago(120 * DAY) },
  { id: 2, username: 'xiaolin', role: 'ops', disabled: false, created_at: ago(90 * DAY) },
  { id: 3, username: 'amei', role: 'reviewer', disabled: false, created_at: ago(60 * DAY) },
  { id: 4, username: 'shop', role: 'merchant', disabled: false, created_at: ago(30 * DAY) },
  { id: 5, username: 'old_ops', role: 'ops', disabled: true, created_at: ago(200 * DAY) },
];

// ---------------- users ----------------

const NAMES = [
  '小鹿', '江湾骑士团长', '阿强', '约跑小马', '跑跑7721', '晨跑王', '小葵', '退坑的老周', '夜跑兔', '咸鱼跑者',
  '晨风-阿凯', '闪电侠', '城东跑团长', '慢慢跑', '风一样的男子', '小橘子', '跑步机杀手', '外滩追风', '世纪公园常客', '张江码农',
  '徐汇跑鞋', '苏河夜行', '滨江漫步', '马拉松阿姨', '十公里先生', '奔跑的蜗牛', '前滩飞鱼', '陆家嘴打工人', '静安小白', '五角场学长',
  '虹口老炮', '杨浦团子', '普陀铁腿', '闵行小飞', '松江骑手', '嘉定猫猫', '宝山阿姨', '浦江夜猫', '青浦慢跑', '奉贤晨光',
];
const SOURCES = ['sms', 'sms', 'sms', 'oneclick', 'oneclick', 'wechat', 'wechat', 'apple'];

export const crews = [
  { id: 3, name: '城西跑团' },
  { id: 5, name: '晨风跑团' },
  { id: 8, name: '江湾骑士' },
  { id: 9, name: '夜跑兔' },
];

export const plans: Plan[] = [
  {
    code: 'auto_month', name: '连续包月', period: 'month', auto_renew: true, price_fen: 1800, first_price_fen: 1500, renew_price_fen: 1800,
    seats: 1, recommended: false, apple_product_id: 'com.loopland.member.auto_month', on_sale: true, sort: 1,
    entitlements: ['map_styles', 'advanced_stats', 'ai_coach_unlimited', 'exclusive_skins', 'hd_replay_export'],
  },
  {
    code: 'month', name: '月卡', period: 'month', auto_renew: false, price_fen: 1800, first_price_fen: null, renew_price_fen: 1800,
    seats: 1, recommended: false, apple_product_id: 'com.loopland.member.month', on_sale: true, sort: 2,
    entitlements: ['map_styles', 'advanced_stats', 'ai_coach_unlimited'],
  },
  {
    code: 'quarter', name: '季卡', period: 'quarter', auto_renew: false, price_fen: 4500, first_price_fen: null, renew_price_fen: 4500,
    seats: 1, recommended: false, apple_product_id: 'com.loopland.member.quarter', on_sale: true, sort: 3,
    entitlements: ['map_styles', 'advanced_stats', 'ai_coach_unlimited', 'exclusive_skins'],
  },
  {
    code: 'year', name: '年卡', period: 'year', auto_renew: false, price_fen: 16800, first_price_fen: null, renew_price_fen: 16800,
    seats: 1, recommended: true, apple_product_id: 'com.loopland.member.year', on_sale: true, sort: 4,
    entitlements: ['map_styles', 'advanced_stats', 'ai_coach_unlimited', 'exclusive_skins', 'hd_replay_export'],
  },
  {
    code: 'crew_year', name: '跑团版', period: 'year', auto_renew: false, price_fen: 29800, first_price_fen: null, renew_price_fen: 29800,
    seats: 5, recommended: false, apple_product_id: 'com.loopland.member.crew_year', on_sale: false, sort: 5,
    entitlements: ['map_styles', 'advanced_stats', 'ai_coach_unlimited', 'exclusive_skins', 'hd_replay_export', 'crew_tools'],
  },
];

export const entitlements: Entitlement[] = [
  { key: 'map_styles', name: '手绘 / 3D 地图', locked: false },
  { key: 'advanced_stats', name: '高级数据', locked: false },
  { key: 'ai_coach_unlimited', name: 'AI 教练不限次', locked: false },
  { key: 'exclusive_skins', name: '专属领地皮肤', locked: false },
  { key: 'hd_replay_export', name: '高清回放导出', locked: false },
  { key: 'crew_tools', name: '跑团管理工具', locked: false },
  { key: 'guard_bonus', name: '抢地守卫加成', locked: true },
  { key: 'extra_energy', name: '额外能量', locked: true },
];

function phoneFor(id: number): string {
  const prefixes = ['138', '139', '150', '186', '177', '136', '135', '133', '158', '189'];
  const p = prefixes[id % prefixes.length];
  const tail = String((id * 7919) % 10000).padStart(4, '0');
  const mid = String((id * 104729) % 10000).padStart(4, '0');
  return `${p}${mid}${tail}`;
}
export const maskPhone = (p: string) => `${p.slice(0, 3)}****${p.slice(7)}`;

export const phones = new Map<number, string>();

const STATUSES: UserStatus[] = ['active', 'active', 'active', 'active', 'active', 'active', 'muted', 'active', 'active', 'active'];

export const users: UserDetail[] = NAMES.map((nickname, i) => {
  const id = [10293, 20871, 55120, 70455, 77210, 33018, 88302, 41556][i] ?? 90000 + i * 37;
  const phone = phoneFor(id);
  phones.set(id, phone);
  let status: UserStatus = i < 8 ? (['active', 'active', 'muted', 'active', 'banned', 'active', 'active', 'deleting'] as UserStatus[])[i] : pick(STATUSES);
  if (i === 25) status = 'banned';
  const createdAgo = i === 6 || i === 3 || i % 9 === 0 ? int(1, 10) * HOUR : int(2, 400) * DAY;
  const memberPlan = i % 3 === 0 ? plans[3] : i % 4 === 1 ? plans[0] : i % 7 === 2 ? plans[2] : null;
  const crew = i % 2 === 0 ? crews[i % crews.length] : null;
  const dist = int(5, 1600) * 1000 + int(0, 999);
  const isAdult = i === 13 ? false : i % 5 === 4 ? null : true;
  return {
    id,
    nickname,
    avatar_url: null,
    level: int(1, 6),
    energy: int(0, 900),
    energy_today: int(0, 300),
    daily_energy_cap: 600,
    phone_masked: maskPhone(phone),
    realname_verified: isAdult !== null,
    is_adult: isAdult,
    status,
    muted_until: status === 'muted' ? iso(NOW + 5 * DAY) : null,
    delete_after: status === 'deleting' ? iso(NOW + 4 * DAY) : null,
    consents: { privacy_version: '2026-11', location: true, health: i % 2 === 0 },
    crew,
    membership: memberPlan
      ? {
          active: true,
          plan_code: memberPlan.code,
          plan_name: memberPlan.name,
          expires_at: iso(NOW + int(3, 300) * DAY),
          auto_renew: memberPlan.auto_renew,
          next_charge_at: memberPlan.auto_renew ? iso(NOW + int(3, 28) * DAY) : null,
          channel: pick(['wechat_app', 'alipay_app', 'apple_iap']),
        }
      : null,
    stats: {
      total_distance_m: dist,
      activity_count: int(1, 400),
      territory_count: int(0, 30),
      territory_area_m2: int(0, 900000),
      week: { count: int(0, 7), distance_m: int(0, 60000), duration_s: int(0, 20000), energy: int(0, 600) },
    },
    created_at: ago(createdAgo),
    source: SOURCES[i % SOURCES.length],
    last_login_at: ago(int(1, 5000) * MIN),
    codex_count: int(0, 60),
    risk_alerts: [],
  };
});

// ---------------- orders ----------------

const ORDER_STATUSES: OrderStatus[] = ['paid', 'paid', 'paid', 'paid', 'paid', 'refund_requested', 'renew_failed', 'refunded', 'closed', 'created'];

export const orders: AdminOrder[] = Array.from({ length: 64 }, (_, i) => {
  const plan = plans[i % plans.length];
  const user = users[(i * 7) % users.length];
  const status = i < 3 ? (['refund_requested', 'renew_failed', 'refund_requested'] as OrderStatus[])[i] : pick(ORDER_STATUSES);
  const created = NOW - (i * 9 + int(0, 8)) * HOUR;
  const first = plan.first_price_fen !== null && i % 2 === 0;
  const d = new Date(created);
  const ymd = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
  return {
    order_no: `LP${ymd}${String(100000 + i * 137).slice(-6)}`,
    plan_code: plan.code,
    plan_name: plan.name,
    amount_fen: first ? plan.first_price_fen ?? plan.price_fen : plan.price_fen,
    kind: plan.auto_renew && !first ? 'renewal' : 'purchase',
    channel: pick(['wechat_app', 'alipay_app', 'apple_iap']),
    status,
    created_at: iso(created),
    paid_at: status === 'created' || status === 'closed' || status === 'renew_failed' ? null : iso(created + 40_000),
    user: { id: user.id, nickname: user.nickname },
  };
});

// ---------------- territories ----------------

const CENTER = { lng: 121.505, lat: 31.232 };
const PLACE_NAMES = [
  '滨江公园', '世纪广场', '老城厢', '体育中心', '南湖绿道', '大学城', '东站', '港口', '陆家嘴环路', '东方明珠下',
  '船厂1862', '民生码头', '老白渡', '前滩公园', '后滩湿地', '世博文化公园', '张家浜', '源深体育场', '塘桥', '浦东南路口',
  '花木路', '东昌路', '其昌栈', '洋泾港',
];

function polygonAround(cx: number, cy: number, r: number): number[][] {
  const n = int(5, 7);
  const ring: number[][] = [];
  const start = rand() * Math.PI;
  for (let k = 0; k < n; k++) {
    const a = start + (k / n) * Math.PI * 2;
    const rr = r * (0.7 + rand() * 0.45);
    ring.push([+(cx + rr * Math.cos(a) * 1.15).toFixed(6), +(cy + rr * Math.sin(a)).toFixed(6)]);
  }
  ring.push(ring[0]);
  return ring;
}

function ringArea(ring: number[][]): number {
  const mPerLat = 110_574;
  const mPerLng = 111_320 * Math.cos((CENTER.lat * Math.PI) / 180);
  let s = 0;
  for (let k = 0; k < ring.length - 1; k++) {
    const [x1, y1] = ring[k];
    const [x2, y2] = ring[k + 1];
    s += x1 * mPerLng * (y2 * mPerLat) - x2 * mPerLng * (y1 * mPerLat);
  }
  return Math.abs(s / 2);
}

const BUILDING_NAMES: Record<string, string> = {
  campfire: '营火', tent: '营帐', well: '水井', mill: '磨坊', house: '民居', forge: '铁匠铺', tower: '箭塔', chapel: '礼拜堂',
};

export const territories: Territory[] = PLACE_NAMES.map((name, i) => {
  const col = i % 6;
  const row = Math.floor(i / 6);
  const cx = CENTER.lng - 0.03 + col * 0.012 + (rand() - 0.5) * 0.003;
  const cy = CENTER.lat + 0.018 - row * 0.012 + (rand() - 0.5) * 0.003;
  const ring = polygonAround(cx, cy, 0.0045 + rand() * 0.0012);
  const unowned = i === 5 || i === 17;
  const owner = unowned ? null : users[[8, 10, 1, 8, 10, 0, 8, 1, 12, 3][i % 10]];
  const crew = owner?.crew ?? null;
  const frozen = i === 6 || i === 15;
  const nb = unowned ? 0 : int(0, 6);
  const slotKeys = Object.keys(BUILDING_NAMES);
  const slots = Array.from({ length: 6 }, (_, s) => {
    const b = s < nb ? slotKeys[(s + i) % slotKeys.length] : null;
    return { slot: s, building: b, name: b ? BUILDING_NAMES[b] : null };
  });
  const guard = unowned ? 0 : Math.round((200 + rand() * 1400) / 50) * 50;
  const changes = i === 1 || i === 4 || i === 11 ? int(1, 4) : 0;
  const events: TerritoryEvent[] = [];
  if (!unowned) {
    events.push({ kind: 'claim', actor: owner, prev_owner: null, new_owner: owner, prev_guard: 0, new_guard: 50, admin: null, created_at: ago(int(5, 40) * DAY) });
    if (nb) events.push({ kind: 'build', actor: owner, prev_owner: null, new_owner: null, prev_guard: 50, new_guard: guard, admin: null, created_at: ago(int(1, 4) * DAY) });
    if (changes) {
      const attacker = users[(i + 3) % users.length];
      events.push({ kind: 'attack', actor: attacker, prev_owner: owner, new_owner: owner, prev_guard: guard + 300, new_guard: guard, admin: null, created_at: ago(int(1, 6) * HOUR) });
    }
    if (frozen) events.push({ kind: 'freeze', actor: null, prev_owner: null, new_owner: null, prev_guard: null, new_guard: null, admin: 2, created_at: ago(3 * HOUR) });
  }
  events.sort((a, b) => b.created_at.localeCompare(a.created_at));
  return {
    id: 101 + i,
    name,
    relation: unowned ? 'unowned' : 'enemy',
    owner: owner ? { id: owner.id, nickname: owner.nickname, avatar_url: null } : null,
    crew,
    geometry: { type: 'MultiPolygon', coordinates: [[ring]] },
    center: { lat: +cy.toFixed(6), lng: +cx.toFixed(6) },
    area_m2: +ringArea(ring).toFixed(1),
    guard,
    frozen,
    daily_energy: nb * 12,
    slots,
    station_slots: 1 + (nb > 4 ? 2 : 0),
    stationed: nb > 2 ? [{ role: 'archer', name: '弓箭手', buff_text: '领地守卫 +5%' }] : [],
    captured_at: unowned ? null : events[events.length - 1]?.created_at ?? null,
    events,
  };
});

export const territoryMeta = new Map<number, { changes_today: number; updated_at: string }>(
  territories.map((t, i) => [t.id, { changes_today: i === 1 || i === 4 || i === 11 ? 1 + (i % 3) : 0, updated_at: t.events[0]?.created_at ?? ago(30 * DAY) }]),
);

// ---------------- risk ----------------

export const riskRules: RiskRules = {
  run_max_kmh: 20,
  ride_max_kmh: 45,
  hike_max_kmh: 12,
  walk_max_kmh: 10,
  teleport_m: 500,
  gap_s: 30,
  require_wearable_for_events: true,
};

const RISK_SEED: { type: RiskType; conf: number; user: number; detail: string }[] = [
  { type: 'mock_location', conf: 0.99, user: 9, detail: '检测到虚拟定位工具（定位来源 mock 占 62%）' },
  { type: 'speed', conf: 0.94, user: 4, detail: '跑步中 8 分钟均速 31 km/h，超过跑步上限 20 km/h' },
  { type: 'multi_account', conf: 0.88, user: 12, detail: '5 个账号 · 1 台设备轮流登录互刷领地' },
  { type: 'teleport', conf: 0.71, user: 10, detail: '2 秒内位移 1.4 km' },
  { type: 'missing_device_data', conf: 0.62, user: 11, detail: '配速 3:10 但无心率与步频' },
  { type: 'device_tamper', conf: 0.58, user: 16, detail: '设备已 root，检测到多开环境' },
  { type: 'speed', conf: 0.53, user: 21, detail: '骑行 31 km/h 被记录为跑步' },
  { type: 'teleport', conf: 0.47, user: 27, detail: '隧道出口位移 620 m（间隔 25 秒）' },
  { type: 'speed', conf: 0.41, user: 33, detail: '最后 1 km 均速 21.5 km/h' },
];

export const riskAlerts: RiskAlert[] = RISK_SEED.map((s, i) => ({
  id: 7 + i,
  activity_id: 5000 + i * 13,
  user: { id: users[s.user].id, nickname: users[s.user].nickname },
  type: s.type,
  confidence: s.conf,
  detail: s.detail,
  status: 'open',
  resolution: null,
  created_at: ago((i * 17 + 8) * MIN),
}));

// a few resolved ones for history
riskAlerts.push(
  { id: 3, activity_id: 4100, user: { id: users[4].id, nickname: users[4].nickname }, type: 'speed', confidence: 0.81, detail: '骑行被记录为跑步', status: 'resolved', resolution: 'warn', note: '首次，警告', created_at: ago(9 * DAY) },
  { id: 4, activity_id: 4211, user: { id: users[4].id, nickname: users[4].nickname }, type: 'teleport', confidence: 0.66, detail: '3 秒内位移 900 m', status: 'resolved', resolution: 'void', note: null, created_at: ago(4 * DAY) },
  { id: 5, activity_id: 4302, user: { id: users[19].id, nickname: users[19].nickname }, type: 'missing_device_data', confidence: 0.4, detail: '无步频', status: 'resolved', resolution: 'false_positive', note: '手机放包里', created_at: ago(2 * DAY) },
);

for (const a of riskAlerts) {
  const u = users.find((x) => x.id === a.user.id);
  if (u) u.risk_alerts.push(a);
}

// ---------------- gameplay ----------------

export const gameplayConfig: Config = {
  version: 'v3.12',
  slots_per_territory: 6,
  base_station_slots: 1,
  daily_energy_cap: 600,
  min_claim_area_m2: 500,
  boss_strike_cost: 100,
  level_thresholds: [0, 200, 600, 1200, 2000, 3200],
  energy: [
    { sport: 'run', name: '跑步', unit: 'km', per: 1, energy: 10 },
    { sport: 'ride', name: '骑行', unit: 'km', per: 1, energy: 4 },
    { sport: 'hike', name: '徒步', unit: 'km', per: 1, energy: 6 },
    { sport: 'walk', name: '健走', unit: 'km', per: 1, energy: 6, pending: true },
    { sport: 'strength', name: '力量', unit: 'min', per: 10, energy: 5 },
    { sport: 'yoga', name: '瑜伽', unit: 'min', per: 10, energy: 4 },
    { sport: 'rope', name: '跳绳', unit: 'count', per: 100, energy: 2 },
    { sport: 'hiit', name: 'HIIT', unit: 'min', per: 10, energy: 5, pending: true },
  ],
  buildings: [
    { key: 'campfire', name: '营火', note: '基础', cost: 80, guard: 50, daily_energy: 10, unlock_level: 1, station_slots: 0, blueprint_bypass_level: false },
    { key: 'tent', name: '营帐', note: '扩充驻扎', cost: 120, guard: 80, daily_energy: 15, unlock_level: 1, station_slots: 1, blueprint_bypass_level: true },
    { key: 'well', name: '水井', note: '恢复体力', cost: 150, guard: 60, daily_energy: 25, unlock_level: 2, station_slots: 0, blueprint_bypass_level: true },
    { key: 'mill', name: '磨坊', note: '能量产出', cost: 200, guard: 40, daily_energy: 40, unlock_level: 2, station_slots: 0, blueprint_bypass_level: true },
    { key: 'house', name: '民居', note: '驻扎 +2 角色', cost: 180, guard: 100, daily_energy: 20, unlock_level: 3, station_slots: 2, blueprint_bypass_level: true },
    { key: 'forge', name: '铁匠铺', note: '角色升级', cost: 260, guard: 150, daily_energy: 30, unlock_level: 4, station_slots: 0, blueprint_bypass_level: false },
    { key: 'tower', name: '箭塔', note: '防守主力', cost: 320, guard: 300, daily_energy: 10, unlock_level: 5, station_slots: 0, blueprint_bypass_level: true },
    { key: 'chapel', name: '礼拜堂', note: '跑团加成', cost: 400, guard: 200, daily_energy: 50, unlock_level: 6, station_slots: 0, blueprint_bypass_level: false },
  ],
  roles: [
    { key: 'archer', name: '弓箭手', sport: 'run', threshold: 30, unit: 'km', buff: 'guard_pct', buff_value: 5, buff_text: '领地守卫 +5%' },
    { key: 'knight', name: '骑士', sport: 'ride', threshold: 80, unit: 'km', buff: 'capture_speed', buff_value: 8, buff_text: '攻占速度 +8%' },
    { key: 'smith', name: '铁匠', sport: 'strength', threshold: 300, unit: 'min', buff: 'build_cost_pct', buff_value: 6, buff_text: '建造费用 -6%' },
    { key: 'monk', name: '修士', sport: 'yoga', threshold: 300, unit: 'min', buff: 'daily_energy', buff_value: 10, buff_text: '每日恢复 +10 能量' },
    { key: 'scout', name: '斥候', sport: 'hike', threshold: 20, unit: 'km', buff: 'vision', buff_value: 1, buff_text: '地图视野 +1 格' },
    { key: 'banner', name: '旗手', sport: 'rally', threshold: 5, unit: 'count', buff: 'crew_boss_dmg_pct', buff_value: 10, buff_text: '跑团合击伤害 +10%' },
    { key: 'alchemist', name: '药剂师', sport: 'rope', threshold: 3000, unit: 'count', buff: 'chest_drop_pct', buff_value: 5, buff_text: '宝箱额外掉落 +5%' },
    { key: 'farmer', name: '农夫', sport: 'walk', threshold: 15, unit: 'km', buff: 'mill_yield_pct', buff_value: 12, buff_text: '磨坊产出 +12%' },
  ],
  companions: [{ key: 'gecko', name: '闪电壁虎', hatch_km: 10 }],
  medals: [
    { key: 'distance_100', name: '百公里', type: 'distance_km', target: 100, distance_km: 100 },
    { key: 'guardian', name: '守护者', type: 'defends', target: 5 },
    { key: 'ten_loops', name: '一夜十圈', type: 'loops_single', target: 10 },
    { key: 'monster_hunter', name: '怪兽猎人', type: 'boss_defeats', target: 5 },
    { key: 'treasure', name: '寻宝人', type: 'chests', target: 20 },
    { key: 'orienteer', name: '城市定向家', type: 'routes', target: 3 },
  ],
  boss: {
    strike_cost: 100, strike_damage: 40, strike_cooldown_s: 30,
    combo_window_s: 300, combo_pct: 10, combo_max_pct: 50,
    damage: [
      { sport: 'run', per: 1, unit: 'km', damage: 100 },
      { sport: 'ride', per: 1, unit: 'km', damage: 100 },
      { sport: 'hike', per: 1, unit: 'km', damage: 100 },
      { sport: 'walk', per: 1, unit: 'km', damage: 100 },
      { sport: 'rope', per: 100, unit: 'count', damage: 30 },
      { sport: 'strength', per: 10, unit: 'min', damage: 30 },
      { sport: 'yoga', per: 10, unit: 'min', damage: 30 },
      { sport: 'hiit', per: 10, unit: 'min', damage: 30 },
    ],
    default_hp: 10000, radius_m: 1000, duration_h: 48, auto_spawn_max: 3,
    engage_h: 6, expire_refund_pct: 20, top_extra_rolls: 3, drop_energy: 200,
    yield_penalty_pct: 50,
  },
  chest: { energy_min: 20, energy_max: 60, radius_m: 50, daily_spawn: 20, duration_h: 24 },
  defense: { window_h: 24, max_guard: 2000 },
  season: {
    tiers: [
      { name: '青铜', min_km2: 0 }, { name: '白银', min_km2: 0.5 }, { name: '黄金', min_km2: 3.6 },
      { name: '铂金', min_km2: 8 }, { name: '钻石', min_km2: 15 },
    ],
  },
  season_tasks: [
    { key: 'weekly_runs', name: '本周运动 3 次', type: 'weekly_count', target: 3, reward_energy: 60 },
    { key: 'weekly_area', name: '本周圈地 2 万 m²', type: 'weekly_area_m2', target: 20000, reward_energy: 80 },
    { key: 'weekly_distance', name: '本周跑够 15 km', type: 'weekly_distance_km', target: 15, reward_energy: 80 },
    { key: 'new_sport', name: '尝试一项本赛季没做过的运动', type: 'new_sport', target: 1, reward_energy: 50 },
  ],
  companion: { feed_cost: 50, feed_exp: 10, exp_per_100m: 1, exp_per_level: 100 },
  relay: { default_legs: 6, leg_km: 3, duration_h: 168, reward_energy: 100 },
  bosses: [
    { key: 'sofa', name: '沙发怪', drops: [ { item: 'banner', kind: 'role', percent: 35 }, { item: 'knight', kind: 'role', percent: 20 }, { item: 'tent', kind: 'blueprint', percent: 10 }, { item: 'firetail', kind: 'egg', percent: 5 }, { item: 'energy', kind: 'energy', percent: 30 } ] },
    { key: 'bat', name: '熬夜蝠', drops: [ { item: 'scout', kind: 'role', percent: 30 }, { item: 'archer', kind: 'role', percent: 25 }, { item: 'tower', kind: 'blueprint', percent: 8 }, { item: 'nightnewt', kind: 'egg', percent: 4 }, { item: 'energy', kind: 'energy', percent: 33 } ] },
    { key: 'smog', name: '雾霾怪', drops: [ { item: 'monk', kind: 'role', percent: 25 }, { item: 'well', kind: 'blueprint', percent: 15 }, { item: 'chapel', kind: 'blueprint', percent: 6 }, { item: 'axolotl', kind: 'egg', percent: 4 }, { item: 'energy', kind: 'energy', percent: 50 } ] },
    { key: 'sugar', name: '糖分怪', drops: [ { item: 'farmer', kind: 'role', percent: 30 }, { item: 'mill', kind: 'blueprint', percent: 15 }, { item: 'house', kind: 'blueprint', percent: 10 }, { item: 'frog', kind: 'egg', percent: 5 }, { item: 'energy', kind: 'energy', percent: 40 } ] },
  ],
};

const prevConfig: Config = JSON.parse(JSON.stringify(gameplayConfig));
prevConfig.version = 'v3.11';
prevConfig.bosses[0].drops[0].percent = 30;
prevConfig.bosses[0].drops[4].percent = 35;

export const gameplay: GameplayState = {
  current: { version: 'v3.12', rollout_pct: 100, body: gameplayConfig, note: '冬季赛季掉落调整', published_by: 2, published_at: ago(2 * DAY) },
  previous: { version: 'v3.11', rollout_pct: 100, body: prevConfig, note: '新增联名旗手卡', published_by: 1, published_at: ago(10 * DAY) },
  history: [
    { version: 'v3.12', note: '冬季赛季掉落调整', rollout_pct: 100, published_by: 2, published_at: ago(2 * DAY) },
    { version: 'v3.11', note: '新增联名旗手卡', rollout_pct: 100, published_by: 1, published_at: ago(10 * DAY) },
    { version: 'v3.10', note: 'S3 开赛数值', rollout_pct: 100, published_by: null, published_at: ago(19 * DAY) },
  ],
};

// ---------------- audit ----------------

export const audit: AuditItem[] = [
  { id: 1, admin: { id: 2, username: 'xiaolin' }, action: 'user.mute_7d', target: `user:${users[2].id}`, detail: {}, created_at: ago(2 * DAY) },
  { id: 2, admin: { id: 1, username: 'admin' }, action: 'gameplay.publish', target: 'gameplay:v3.12', detail: { rollout_pct: 10 }, created_at: ago(2 * DAY + 3 * HOUR) },
  { id: 3, admin: { id: 1, username: 'admin' }, action: 'gameplay.rollout', target: 'gameplay:v3.12', detail: { rollout_pct: 100 }, created_at: ago(2 * DAY) },
  { id: 4, admin: { id: 3, username: 'amei' }, action: 'risk.void', target: 'alert:4', detail: { note: '' }, created_at: ago(4 * DAY) },
  { id: 5, admin: { id: 2, username: 'xiaolin' }, action: 'user.reveal_phone', target: `user:${users[0].id}`, detail: {}, created_at: ago(5 * HOUR) },
  { id: 6, admin: { id: 2, username: 'xiaolin' }, action: 'territory.freeze', target: 'territory:107', detail: { frozen: true }, created_at: ago(3 * HOUR) },
  { id: 7, admin: { id: 1, username: 'admin' }, action: 'user.ban', target: `user:${users[4].id}`, detail: {}, created_at: ago(26 * HOUR) },
].sort((a, b) => b.created_at.localeCompare(a.created_at));

// ---------------- dashboard trend ----------------

export const trend = (() => {
  const days: string[] = [];
  const active: number[] = [];
  const dist: number[] = [];
  const newT: number[] = [];
  for (let k = 29; k >= 0; k--) {
    const d = new Date(NOW - k * DAY);
    days.push(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`);
    const weekday = d.getDay();
    const weekend = weekday === 0 || weekday === 6 ? 1.25 : 1;
    const growth = 1 + (29 - k) * 0.012;
    active.push(Math.round(38000 * growth * weekend * (0.92 + rand() * 0.16)));
    dist.push(+(152000 * growth * weekend * (0.9 + rand() * 0.2)).toFixed(1));
    newT.push(Math.round(5200 * growth * weekend * (0.85 + rand() * 0.3)));
  }
  return { days, active_users: active, distance_km: dist, new_territories: newT };
})();

// ---------------- V2 玩法运营 ----------------

const BOSS_SEED: { kind: string; name: string; level: number; loc: string; dlng: number; dlat: number; hp: number; max: number; status: BossDetail['status']; spawnedAgo: number; by: number | null; people: number }[] = [
  { kind: 'sofa', name: '沙发怪', level: 12, loc: '滨江公园一带', dlng: -0.018, dlat: 0.012, hp: 3800, max: 10000, status: 'active', spawnedAgo: 20 * HOUR, by: null, people: 23 },
  { kind: 'bat', name: '熬夜蝠', level: 8, loc: '陆家嘴环路', dlng: 0.012, dlat: -0.004, hp: 7600, max: 8000, status: 'active', spawnedAgo: 3 * HOUR, by: 2, people: 6 },
  { kind: 'sugar', name: '糖分怪', level: 15, loc: '世博文化公园', dlng: -0.004, dlat: -0.022, hp: 1200, max: 12000, status: 'active', spawnedAgo: 40 * HOUR, by: null, people: 41 },
  { kind: 'smog', name: '雾霾怪', level: 10, loc: '前滩公园', dlng: 0.02, dlat: -0.03, hp: 0, max: 10000, status: 'defeated', spawnedAgo: 3 * DAY, by: 1, people: 35 },
  { kind: 'sofa', name: '沙发怪', level: 6, loc: '源深体育场', dlng: 0.03, dlat: 0.01, hp: 0, max: 6000, status: 'defeated', spawnedAgo: 6 * DAY, by: null, people: 18 },
  { kind: 'bat', name: '熬夜蝠', level: 9, loc: '老白渡', dlng: -0.026, dlat: -0.012, hp: 2900, max: 9000, status: 'expired', spawnedAgo: 5 * DAY, by: null, people: 12 },
];

const DROP_NAMES: Record<string, string> = {
  banner: '旗手卡', knight: '骑士卡', tent: '营帐图纸', firetail: '火尾蜥蛋', energy: '能量', scout: '斥候卡', archer: '弓箭手卡',
  tower: '箭塔图纸', nightnewt: '夜行蝾螈蛋', monk: '修士卡', well: '水井图纸', chapel: '礼拜堂图纸', axolotl: '六角龙蛋',
  farmer: '农夫卡', mill: '磨坊图纸', house: '民居图纸', frog: '雨蛙蛋',
};

export const bosses: BossDetail[] = BOSS_SEED.map((b, i) => {
  const conf = gameplayConfig.bosses.find((x) => x.key === b.kind)!;
  const spawned = NOW - b.spawnedAgo;
  const expires = spawned + 48 * HOUR;
  const dealt = b.max - b.hp;
  // Split the damage dealt across participants with a long tail.
  const weights = Array.from({ length: b.people }, (_, k) => 1 / (k + 1.6) + rand() * 0.05);
  const wsum = weights.reduce((x, y) => x + y, 0);
  let left = dealt;
  const rank = weights.map((w, k) => {
    const u = users[(i * 7 + k * 3) % users.length];
    const dmg = k === b.people - 1 ? left : Math.max(1, Math.round((dealt * w) / wsum));
    left -= dmg;
    return { rank: k + 1, user: { id: u.id, nickname: u.nickname, avatar_url: null }, damage: Math.max(dmg, 1) };
  }).sort((a, c) => c.damage - a.damage).map((r, k) => ({ ...r, rank: k + 1 }));
  const rewards =
    b.status === 'defeated'
      ? rank.map((r) => {
          const rolls = r.rank <= 3 ? 2 : 1;
          const items = Array.from({ length: rolls }, (_, k) => {
            const d = conf.drops[(r.user.id + i + k * 3) % conf.drops.length];
            return { item: d.item, kind: d.kind, name: DROP_NAMES[d.item] ?? d.item, converted_energy: d.kind === 'energy' ? 200 : (r.user.id + k) % 4 === 0 ? 50 : null };
          });
          return { user: r.user, rank: r.rank, damage: r.damage, items };
        })
      : b.status === 'expired'
        ? rank.map((r) => ({ user: r.user, rank: r.rank, damage: r.damage, items: [], energy: Math.round(((r.user.id % 5) + 1) * 100 * 0.2) }))
        : [];
  return {
    id: 3 + i,
    kind: b.kind,
    name: b.name,
    level: b.level,
    description: '它代表「懒得动」，越久没人来跑，它越壮。',
    location_name: b.loc,
    center: { lat: +(CENTER.lat + b.dlat).toFixed(6), lng: +(CENTER.lng + b.dlng).toFixed(6) },
    radius_m: i === 1 ? 600 : 1000,
    hp: b.hp,
    hp_max: b.max,
    status: b.status,
    spawned_at: iso(spawned),
    expires_at: iso(expires),
    defeated_at: b.status === 'defeated' ? iso(spawned + 30 * HOUR) : null,
    spawned_by: b.by,
    occupied_territories: 2 + (i % 4),
    effect_text: '范围内领地每日能量产出减半',
    damage_rules: gameplayConfig.boss!.damage.map((d) => ({ ...d, label: { run: '跑步', ride: '骑行', hike: '徒步', walk: '健走', rope: '跳绳', strength: '力量', yoga: '瑜伽', hiit: 'HIIT' }[d.sport] ?? d.sport })),
    strike: { cost: 100, damage: 40, cooldown_s: 30 },
    participants: b.people,
    rank,
    drops: conf.drops.map((d) => ({ ...d, name: DROP_NAMES[d.item] ?? d.item })),
    rewards,
  };
});

export const chests: ChestListItem[] = Array.from({ length: 26 }, (_, i) => {
  const status = i < 18 ? 'active' : i < 23 ? 'expired' : 'removed';
  const created = NOW - (i < 18 ? int(1, 18) : int(24, 70)) * HOUR;
  const source = i % 5 === 0 ? 'admin' : i % 3 === 0 ? 'scatter' : 'system';
  return {
    id: 900 + i,
    center: { lat: +(CENTER.lat + 0.02 - rand() * 0.055).toFixed(6), lng: +(CENTER.lng - 0.034 + rand() * 0.07).toFixed(6) },
    radius_m: 50,
    energy_min: source === 'admin' ? 50 : 20,
    energy_max: source === 'admin' ? 100 : 60,
    opens: status === 'active' ? int(0, 12) : int(5, 40),
    source,
    status,
    created_at: iso(created),
    expires_at: iso(created + 24 * HOUR),
  };
});

const dayStart = (ms: number) => {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
};

export const seasons: Season[] = [
  { id: 1, name: 'S1 春季赛', starts_at: iso(dayStart(NOW - 200 * DAY)), ends_at: iso(dayStart(NOW - 139 * DAY)), status: 'settled', settled_at: iso(dayStart(NOW - 139 * DAY) + 5 * MIN) },
  { id: 2, name: 'S2 夏季赛', starts_at: iso(dayStart(NOW - 139 * DAY)), ends_at: iso(dayStart(NOW - 78 * DAY)), status: 'settled', settled_at: iso(dayStart(NOW - 78 * DAY) + 5 * MIN) },
  { id: 3, name: 'S3 冬季赛', starts_at: iso(dayStart(NOW - 18 * DAY)), ends_at: iso(dayStart(NOW + 42 * DAY)), status: 'active', settled_at: null },
  { id: 4, name: 'S4 新春赛', starts_at: iso(dayStart(NOW + 42 * DAY)), ends_at: iso(dayStart(NOW + 103 * DAY)), status: 'upcoming', settled_at: null },
];

export const campaigns: Campaign[] = [
  { id: 5, title: '夜跑专场', type: 'night_run', description: '晚上 7 点到 11 点出发，跑满 5 km', rules: { start_hour_from: 19, start_hour_to: 23, min_distance_km: 5 }, starts_at: iso(dayStart(NOW - 3 * DAY)), ends_at: iso(dayStart(NOW + 4 * DAY)), reward_energy: 100, reward_medal: { key: 'campaign_5', name: '夜行者' }, participants: 1240, completed_count: 318 },
  { id: 6, title: '破 6 挑战', type: 'pace', description: '5 km 配速快于 6:00', rules: { min_distance_km: 5, max_pace_s_per_km: 360 }, starts_at: iso(dayStart(NOW - 1 * DAY)), ends_at: iso(dayStart(NOW + 6 * DAY)), reward_energy: 80, reward_medal: null, participants: 860, completed_count: 92 },
  { id: 7, title: '周末半马', type: 'distance', description: '单次跑满 21 km', rules: { min_distance_km: 21 }, starts_at: iso(dayStart(NOW + 2 * DAY)), ends_at: iso(dayStart(NOW + 4 * DAY)), reward_energy: 200, reward_medal: { key: 'campaign_7', name: '半马勋章' }, participants: 0, completed_count: 0 },
  { id: 4, title: '国庆十公里', type: 'distance', description: '假期跑满 10 km', rules: { min_distance_km: 10 }, starts_at: iso(dayStart(NOW - 50 * DAY)), ends_at: iso(dayStart(NOW - 43 * DAY)), reward_energy: 120, reward_medal: null, participants: 5320, completed_count: 2110 },
];

const cp = (name: string, dlng: number, dlat: number, r = 60) => ({ name, lat: +(CENTER.lat + dlat).toFixed(6), lng: +(CENTER.lng + dlng).toFixed(6), radius_m: r });

export const routes: OrienteeringRoute[] = [
  {
    id: 2, name: '城南线', description: '从老城厢一路到前滩，沿江 6 个打卡点', reward_energy: 150,
    starts_at: iso(dayStart(NOW - 10 * DAY)), ends_at: iso(dayStart(NOW + 20 * DAY)), finishers: 88,
    checkpoints: [cp('拱桥', -0.028, 0.004), cp('老街口', -0.02, -0.006), cp('滨江码头', -0.012, -0.014, 80), cp('船厂1862', -0.002, -0.018), cp('世博文化公园', 0.008, -0.024, 100), cp('前滩公园', 0.02, -0.03)].map((c, index) => ({ index, ...c })),
  },
  {
    id: 3, name: '陆家嘴环线', description: '金融城一圈，4 个打卡点', reward_energy: 100,
    starts_at: iso(dayStart(NOW + 5 * DAY)), ends_at: iso(dayStart(NOW + 35 * DAY)), finishers: 0,
    checkpoints: [cp('东方明珠下', 0.004, 0.014), cp('陆家嘴环路', 0.014, 0.01), cp('源深体育场', 0.026, 0.004), cp('张家浜', 0.016, -0.004)].map((c, index) => ({ index, ...c })),
  },
];

/** Districts that have crews (`GET /admin/v1/districts`), most crews first. */
export const DISTRICTS = [
  { name: '浦东新区', crews: 14 },
  { name: '徐汇区', crews: 12 },
  { name: '黄浦区', crews: 9 },
  { name: '静安区', crews: 7 },
  { name: '杨浦区', crews: 6 },
];

/** Deterministic standings per district + week. */
export function leagueFor(district: string, weekStart: string) {
  let seed = 0;
  for (const ch of district + weekStart) seed = (seed * 31 + ch.charCodeAt(0)) | 0;
  const r = mulberry32(seed);
  const names = ['城西跑团', '晨风跑团', '江湾骑士', '夜跑兔', '滨江慢跑', '世纪公园跑团', '张江码农跑', '前滩飞鱼', '苏河夜行', '徐汇跑鞋'];
  const n = 6 + Math.floor(r() * 4);
  return names
    .slice(0, n)
    .map((name, k) => ({ crew: { id: [3, 5, 8, 9, 11, 12, 14, 15, 17, 18][k], name }, score_m2: Math.round((200_000 + r() * 900_000) / 100) * 100, active_members: 3 + Math.floor(r() * 14) }))
    .sort((a, b) => b.score_m2 - a.score_m2)
    .map((x, k) => ({ rank: k + 1, ...x }));
}
