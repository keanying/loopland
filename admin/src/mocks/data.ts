// Fixture data for VITE_MOCK=1. Shapes follow docs/api/v1.md exactly.
// Everything here is deterministic (seeded) so screenshots are stable.
import type {
  AdminAccount,
  AdminOrder,
  AuditItem,
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
    { key: 'campfire', name: '营火', note: '基础', cost: 80, guard: 50, daily_energy: 10, unlock_level: 1, station_slots: 0 },
    { key: 'tent', name: '营帐', note: '扩充驻扎', cost: 120, guard: 80, daily_energy: 15, unlock_level: 1, station_slots: 1 },
    { key: 'well', name: '水井', note: '恢复体力', cost: 150, guard: 60, daily_energy: 25, unlock_level: 2, station_slots: 0 },
    { key: 'mill', name: '磨坊', note: '能量产出', cost: 200, guard: 40, daily_energy: 40, unlock_level: 2, station_slots: 0 },
    { key: 'house', name: '民居', note: '驻扎 +2 角色', cost: 180, guard: 100, daily_energy: 20, unlock_level: 3, station_slots: 2 },
    { key: 'forge', name: '铁匠铺', note: '角色升级', cost: 260, guard: 150, daily_energy: 30, unlock_level: 4, station_slots: 0 },
    { key: 'tower', name: '箭塔', note: '防守主力', cost: 320, guard: 300, daily_energy: 10, unlock_level: 5, station_slots: 0 },
    { key: 'chapel', name: '礼拜堂', note: '跑团加成', cost: 400, guard: 200, daily_energy: 50, unlock_level: 6, station_slots: 0 },
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
  medals: [{ key: 'distance_100', name: '百公里', distance_km: 100 }],
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
