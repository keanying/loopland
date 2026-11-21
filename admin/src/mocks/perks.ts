// Mock of V2 第四批「本地生活与商户」· 投放 / 联名活动 / 能量商城 (docs/api/v2-4-本地生活与商户.md
// 「投放与联名权益」「联名活动」「能量商城」). Validation mirrors the contract. Also answers the
// merchant / venue option lists if no other mock has claimed those routes (perkRoutes goes last).
import { ApiError } from '../api/client';
import type { AdminRole, LatLng } from '../api/types';
import type {
  BrandCampaign,
  BrandCampaignStatus,
  Drop,
  DropStatus,
  DropType,
  MerchantOption,
  Perk,
  SettleDirection,
  ShopItem,
  ShopItemType,
  VenueOption,
} from '../api/perks';

type Ctx = { m: RegExpMatchArray; q: URLSearchParams; body: Record<string, unknown>; adminId: number; role: AdminRole };
type Handler = (ctx: Ctx) => unknown;
type Log = (adminId: number, action: string, target: string, detail?: Record<string, unknown>) => void;

const DAY = 86_400_000;

function fail(status: number, code: string, message: string): never {
  throw new ApiError(status, code, message);
}
function requireRole(role: AdminRole, allowed: AdminRole[]) {
  if (!allowed.includes(role)) fail(403, 'forbidden', '当前角色没有权限执行此操作');
}
const clone = <T,>(x: T): T => JSON.parse(JSON.stringify(x)) as T;
function paginate<T>(items: T[], q: URLSearchParams) {
  const page = Math.max(1, Number(q.get('page') ?? 1));
  const size = Math.min(100, Math.max(1, Number(q.get('page_size') ?? 20)));
  return { items: items.slice((page - 1) * size, page * size), total: items.length };
}
/** Midnight (local) `d` days from today, as RFC 3339. */
function dayAt(d: number, h = 0): string {
  const x = new Date();
  x.setHours(h, 0, 0, 0);
  return new Date(x.getTime() + d * DAY).toISOString();
}

// ---------------------------------------------------------------- merchants & venues (options)

export const perkMerchants: MerchantOption[] = [
  { id: 1, name: '青柠茶铺', type: 'brand', status: 'partner' },
  { id: 2, name: '跑野运动馆', type: 'venue', status: 'partner' },
  { id: 3, name: '街角便利', type: 'store', status: 'partner' },
  { id: 4, name: '山系咖啡', type: 'brand', status: 'partner' },
  { id: 5, name: '城市攀岩馆', type: 'venue', status: 'reviewing' },
  { id: 6, name: '城南全民健身中心', type: 'venue', status: 'partner' },
  { id: 7, name: '麦田烘焙', type: 'store', status: 'suspended' },
  { id: 8, name: '野径户外', type: 'store', status: 'pending_sign' },
];

export const perkVenues: VenueOption[] = [
  { id: 8, name: '跑野运动馆 · 东方路', merchant: { id: 2, name: '跑野运动馆' }, center: { lat: 31.2268, lng: 121.5242 }, address: '浦东新区东方路 1217 号', district: '浦东新区', sports: ['basketball', 'badminton', 'gym'], checkin_radius_m: 150 },
  { id: 9, name: '城南全民健身中心 · 匹克球', merchant: { id: 6, name: '城南全民健身中心' }, center: { lat: 31.1885, lng: 121.4372 }, address: '徐汇区龙华中路 600 号', district: '徐汇区', sports: ['pickleball', 'badminton'], checkin_radius_m: 150 },
  { id: 10, name: '城南全民健身中心 · 游泳馆', merchant: { id: 6, name: '城南全民健身中心' }, center: { lat: 31.1872, lng: 121.4391 }, address: '徐汇区龙华中路 600 号 B 馆', district: '徐汇区', sports: ['swimming'], checkin_radius_m: 120 },
  { id: 11, name: '城市攀岩馆 · 世博店', merchant: { id: 5, name: '城市攀岩馆' }, center: { lat: 31.1903, lng: 121.4968 }, address: '浦东新区世博大道 1368 号', district: '浦东新区', sports: ['climbing'], checkin_radius_m: 100 },
  { id: 12, name: '陆家嘴滨江篮球场', merchant: null, center: { lat: 31.2392, lng: 121.5018 }, address: '浦东新区滨江大道 2967 号', district: '浦东新区', sports: ['basketball'], checkin_radius_m: 150 },
];


// ---------------------------------------------------------------- drops

interface DropRow extends Omit<Drop, 'status'> {
  paused: boolean;
}

const perk = (title: string, value_text: string, description: string, valid_days = 7, rules = '到店出示券码，店员扫码核销；需要当天有一条运动记录'): Perk => ({ title, description, value_text, valid_days, rules });

let dropSeq = 20;
const drops: DropRow[] = [
  {
    id: 1, merchant: { id: 1, name: '青柠茶铺' }, campaign_id: 1, type: 'supply', name: '补给站 · 滨江大道 · 东昌路口',
    center: { lat: 31.2338, lng: 121.5078 }, radius_m: 80, venue_id: null,
    perk: perk('当日跑满 3 km 送中杯热饮', '免费', '限滨江店，每人每天 1 次；热饮任选（不含季节限定）'),
    daily_cap: 200, issued_today: 132, redeemed_today: 96, start_time: dayAt(-11, 0), end_time: dayAt(19, 23), paused: false,
    settle_price_amt: 600, settle_direction: 'platform_pays',
  },
  {
    id: 2, merchant: { id: 1, name: '青柠茶铺' }, campaign_id: 1, type: 'supply', name: '补给站 · 世纪公园 3 号门',
    center: { lat: 31.2182, lng: 121.5518 }, radius_m: 100, venue_id: null,
    perk: perk('跑满 5 km 第二杯半价', '第二杯 5 折', '限世纪公园店，与其他优惠不同享'),
    daily_cap: 150, issued_today: 88, redeemed_today: 41, start_time: dayAt(-11, 0), end_time: dayAt(19, 23), paused: false,
    settle_price_amt: 200, settle_direction: 'merchant_pays',
  },
  {
    id: 3, merchant: { id: 1, name: '青柠茶铺' }, campaign_id: 1, type: 'chest', name: '宝箱 · 陆家嘴环路',
    center: { lat: 31.2405, lng: 121.5031 }, radius_m: 60, venue_id: null,
    perk: perk('全场饮品 9 折', '9 折', '陆家嘴周边 6 家门店通用', 14),
    daily_cap: 100, issued_today: 100, redeemed_today: 37, start_time: dayAt(-6, 0), end_time: dayAt(9, 23), paused: false,
    settle_price_amt: 150, settle_direction: 'merchant_pays',
  },
  {
    id: 4, merchant: { id: 2, name: '跑野运动馆' }, campaign_id: 4, type: 'stronghold', name: '据点 · 跑野运动馆 · 东方路',
    center: { lat: 31.2268, lng: 121.5242 }, radius_m: 150, venue_id: 8,
    perk: perk('签到得周卡 8 折券', '8 折', '购买运动馆周卡时使用，限本人', 30, '前台出示券码核销；需要当天有一条运动记录（场馆签到也算）'),
    daily_cap: 120, issued_today: 64, redeemed_today: 12, start_time: dayAt(-20, 0), end_time: dayAt(9, 23), paused: false,
    settle_price_amt: 0, settle_direction: 'merchant_pays',
  },
  {
    id: 5, merchant: { id: 3, name: '街角便利' }, campaign_id: 3, type: 'chest', name: '宝箱 · 张杨路地铁站',
    center: { lat: 31.2302, lng: 121.5236 }, radius_m: 60, venue_id: null,
    perk: perk('开箱得饮用水一瓶', '免费', '550 ml 饮用水，限张杨路店', 3),
    daily_cap: 300, issued_today: 97, redeemed_today: 66, start_time: dayAt(-6, 0), end_time: dayAt(40, 23), paused: false,
    settle_price_amt: 150, settle_direction: 'platform_pays',
  },
  {
    id: 6, merchant: { id: 3, name: '街角便利' }, campaign_id: 3, type: 'supply', name: '补给站 · 世纪大道 · 福山路',
    center: { lat: 31.2289, lng: 121.5152 }, radius_m: 80, venue_id: null,
    perk: perk('运动饮料第二瓶 1 元', '1 元换购', '限福山路店，每人每天 1 次', 3),
    daily_cap: 200, issued_today: 0, redeemed_today: 4, start_time: dayAt(-6, 0), end_time: dayAt(40, 23), paused: true,
    settle_price_amt: 100, settle_direction: 'platform_pays',
  },
  {
    id: 7, merchant: { id: 4, name: '山系咖啡' }, campaign_id: 2, type: 'supply', name: '补给站 · 东昌路 · 山系咖啡',
    center: { lat: 31.2361, lng: 121.5112 }, radius_m: 80, venue_id: null,
    perk: perk('7 点前晨跑，早餐套餐 7 折', '7 折', '每天 10:00 前使用，限东昌路店', 7),
    daily_cap: 80, issued_today: 0, redeemed_today: 0, start_time: dayAt(10, 0), end_time: dayAt(40, 23), paused: false,
    settle_price_amt: 300, settle_direction: 'platform_pays',
  },
  {
    id: 8, merchant: { id: 1, name: '青柠茶铺' }, campaign_id: 5, type: 'supply', name: '补给站 · 浦东南路 · 秋日夜跑',
    center: { lat: 31.2251, lng: 121.5098 }, radius_m: 80, venue_id: null,
    perk: perk('夜跑后柠檬茶 6 折', '6 折', '19:00 后使用'),
    daily_cap: 120, issued_today: 0, redeemed_today: 0, start_time: dayAt(-51, 0), end_time: dayAt(-21, 23), paused: false,
    settle_price_amt: 200, settle_direction: 'merchant_pays',
  },
  {
    id: 9, merchant: { id: 6, name: '城南全民健身中心' }, campaign_id: 6, type: 'stronghold', name: '据点 · 城南全民健身中心 · 匹克球',
    center: { lat: 31.1885, lng: 121.4372 }, radius_m: 150, venue_id: 9,
    perk: perk('匹克球体验课 1 小时免费', '免费', '周一至周五 18:00 前，需提前电话预约', 14, '前台出示券码核销；需要当天有一条运动记录（场馆签到也算）'),
    daily_cap: 30, issued_today: 0, redeemed_today: 0, start_time: dayAt(14, 0), end_time: dayAt(28, 23), paused: false,
    settle_price_amt: 2000, settle_direction: 'platform_pays',
  },
];

// ---------------------------------------------------------------- brand campaigns

interface CampaignRow extends Omit<BrandCampaign, 'status' | 'drop_ids' | 'stats'> {
  draft: boolean;
  paused: boolean;
  stats: Omit<BrandCampaign['stats'], 'progress_rate'>;
}

let campaignSeq = 10;
const campaigns: CampaignRow[] = [
  {
    id: 1, merchant: { id: 1, name: '青柠茶铺' }, title: '青柠茶铺 · 冬日暖跑',
    description: '跑步路过补给站领热饮，开陆家嘴宝箱得 9 折券；每家门店每人每天限 1 张。',
    cover_url: null, start_time: dayAt(-11, 0), end_time: dayAt(19, 23), draft: false, paused: false,
    store_count: 86, target_redemptions: 46000, merchant_investment_amt: 4_200_000,
    stats: { issued: 31_840, redeemed: 18_920, new_users: 6_200 },
  },
  {
    id: 2, merchant: { id: 4, name: '山系咖啡' }, title: '山系咖啡 · 晨跑早鸟',
    description: '7 点前完成晨跑，路过补给站领早餐套餐 7 折券，当天到店使用。',
    cover_url: null, start_time: dayAt(10, 0), end_time: dayAt(40, 23), draft: false, paused: false,
    store_count: 6, target_redemptions: 3000, merchant_investment_amt: 800_000,
    stats: { issued: 0, redeemed: 0, new_users: 0 },
  },
  {
    id: 3, merchant: { id: 3, name: '街角便利' }, title: '街角便利 · 城市宝箱',
    description: '地图宝箱刷在门店附近，开箱得饮用水；补给站领运动饮料 1 元换购券。',
    cover_url: null, start_time: dayAt(-6, 0), end_time: dayAt(40, 23), draft: false, paused: false,
    store_count: 40, target_redemptions: 20000, merchant_investment_amt: 2_600_000,
    stats: { issued: 12_480, redeemed: 8_760, new_users: 2_140 },
  },
  {
    id: 4, merchant: { id: 2, name: '跑野运动馆' }, title: '跑野运动馆 · 馆主争夺',
    description: '球类、力量训练签到积分，周榜第一成为馆主享 8 折周卡；签到即得周卡 8 折券。',
    cover_url: null, start_time: dayAt(-20, 0), end_time: dayAt(9, 23), draft: false, paused: true,
    store_count: 12, target_redemptions: 5000, merchant_investment_amt: 1_100_000,
    stats: { issued: 4_960, redeemed: 3_420, new_users: 610 },
  },
  {
    id: 5, merchant: { id: 1, name: '青柠茶铺' }, title: '青柠茶铺 · 秋日夜跑',
    description: '19 点后夜跑经过补给站领柠檬茶 6 折券。',
    cover_url: null, start_time: dayAt(-51, 0), end_time: dayAt(-21, 23), draft: false, paused: false,
    store_count: 32, target_redemptions: 10000, merchant_investment_amt: 1_500_000,
    stats: { issued: 15_300, redeemed: 10_840, new_users: 2_960 },
  },
  {
    id: 6, merchant: { id: 6, name: '城南全民健身中心' }, title: '城南全民健身中心 · 匹克球体验周',
    description: '场馆签到得匹克球体验课 1 小时免费券，新手友好。',
    cover_url: null, start_time: dayAt(14, 0), end_time: dayAt(28, 23), draft: true, paused: false,
    store_count: 1, target_redemptions: 400, merchant_investment_amt: 600_000,
    stats: { issued: 0, redeemed: 0, new_users: 0 },
  },
];

function campaignStatus(c: CampaignRow, now = Date.now()): BrandCampaignStatus {
  if (Date.parse(c.end_time) <= now) return 'ended';
  if (c.draft) return 'draft';
  if (c.paused) return 'paused';
  return Date.parse(c.start_time) > now ? 'scheduled' : 'running';
}

function dropStatus(d: DropRow, now = Date.now()): DropStatus {
  if (Date.parse(d.end_time) <= now) return 'ended';
  const c = d.campaign_id ? campaigns.find((x) => x.id === d.campaign_id) : undefined;
  // 活动的投放跟随活动状态：暂停活动 = 暂停其下所有投放；草稿活动的投放也不发券
  if (d.paused || (c && (c.paused || c.draft) && campaignStatus(c, now) !== 'ended')) return 'paused';
  if (c && Date.parse(c.start_time) > now) return 'scheduled';
  return Date.parse(d.start_time) > now ? 'scheduled' : 'active';
}

function dropOut(d: DropRow): Drop {
  const { paused: _p, ...rest } = d;
  return clone({ ...rest, status: dropStatus(d) });
}

function campaignOut(c: CampaignRow): BrandCampaign {
  const { draft: _d, paused: _p, ...rest } = c;
  const ids = drops.filter((d) => d.campaign_id === c.id).map((d) => d.id);
  return clone({
    ...rest,
    status: campaignStatus(c),
    drop_ids: ids,
    stats: { ...c.stats, progress_rate: c.target_redemptions > 0 ? Math.min(1, +(c.stats.redeemed / c.target_redemptions).toFixed(4)) : 0 },
  });
}

/** Drops of one merchant (for the 商户 detail mock: `"drops":[Drop]`). */
export function dropsOfMerchant(merchantId: number): Drop[] {
  return drops.filter((d) => d.merchant.id === merchantId).map(dropOut);
}

/** Today's redemptions of one merchant across its drops. */
export function todayRedemptionsOf(merchantId: number): number {
  return drops.filter((d) => d.merchant.id === merchantId).reduce((s, d) => s + d.redeemed_today, 0);
}

/** `supplies` for GET /map/objects: active 补给站 in the bbox (minLng,minLat,maxLng,maxLat). */
export function mapSupplies(b: number[]) {
  return drops
    .filter((d) => d.type === 'supply' && dropStatus(d) === 'active')
    .filter((d): d is DropRow & { center: LatLng } => !!d.center && d.center.lng >= b[0] && d.center.lng <= b[2] && d.center.lat >= b[1] && d.center.lat <= b[3])
    .map((d) => ({ id: d.id, name: d.name, center: clone(d.center), radius_m: d.radius_m, perk_title: d.perk.title, claimed_today: false }));
}

// ---------------------------------------------------------------- validation

const str = (v: unknown) => (typeof v === 'string' ? v.trim() : '');
const len = (s: string) => [...s].length;
const int = (v: unknown) => (typeof v === 'number' && Number.isInteger(v) ? v : NaN);

function parseTime(v: unknown, field: string): number {
  const t = typeof v === 'string' ? Date.parse(v) : NaN;
  if (!Number.isFinite(t)) fail(400, 'invalid_body', `${field} 需要是 RFC 3339 时间`);
  return t;
}

function validLatLng(v: unknown): v is LatLng {
  const p = v as LatLng | null;
  return !!p && typeof p.lat === 'number' && typeof p.lng === 'number' && Math.abs(p.lat) <= 90 && Math.abs(p.lng) <= 180;
}

function perkInput(v: unknown): Perk {
  const p = (v ?? {}) as Record<string, unknown>;
  const title = str(p.title);
  if (!title || len(title) > 24) fail(400, 'invalid_body', '权益标题 1–24 字');
  const value_text = str(p.value_text);
  if (!value_text || len(value_text) > 10) fail(400, 'invalid_body', '面值文字 1–10 字，如「5 折」「免费」');
  const description = str(p.description);
  if (len(description) > 60) fail(400, 'invalid_body', '权益说明最多 60 字');
  const valid_days = int(p.valid_days);
  if (!(valid_days >= 1 && valid_days <= 90)) fail(400, 'invalid_body', '券有效天数 1–90 天');
  const rules = str(p.rules);
  if (!rules || len(rules) > 200) fail(400, 'invalid_body', '使用规则必填，最多 200 字（App 内明示）');
  return { title, description, value_text, valid_days, rules };
}

function dropInput(body: Record<string, unknown>, prev: DropRow | null): Omit<DropRow, 'id' | 'issued_today' | 'redeemed_today' | 'paused'> {
  const merged = { ...(prev ? { ...prev, merchant_id: prev.merchant.id } : {}), ...body } as Record<string, unknown>;
  const type = merged.type as DropType;
  if (!['supply', 'chest', 'stronghold'].includes(type)) fail(400, 'invalid_body', 'type 只能是 supply / chest / stronghold');
  if (prev && body.type !== undefined && body.type !== prev.type) fail(400, 'invalid_body', '投放类型创建后不能修改');
  const merchantId = int(merged.merchant_id);
  const mer = perkMerchants.find((x) => x.id === merchantId);
  if (!mer) fail(400, 'invalid_body', '商户不存在');
  if (prev && body.merchant_id !== undefined && merchantId !== prev.merchant.id) fail(400, 'invalid_body', '投放的商户创建后不能修改');
  if (!prev && mer.status !== 'partner') fail(409, 'conflict', `「${mer.name}」不是合作中的商户，不能新建投放`);

  let campaign_id: number | null = merged.campaign_id === null || merged.campaign_id === undefined ? null : int(merged.campaign_id);
  if (campaign_id !== null) {
    const c = campaigns.find((x) => x.id === campaign_id);
    if (!c) fail(400, 'invalid_body', '联名活动不存在');
    if (c.merchant.id !== merchantId) fail(400, 'invalid_body', '联名活动不属于这个商户');
    if (campaignStatus(c) === 'ended') fail(409, 'conflict', '联名活动已结束，不能再挂投放');
  } else campaign_id = null;

  let venue_id: number | null = null;
  let center: LatLng;
  let radius_m = int(merged.radius_m);
  if (type === 'stronghold') {
    venue_id = int(merged.venue_id);
    const v = perkVenues.find((x) => x.id === venue_id);
    if (!v) fail(400, 'invalid_body', '据点需要绑定一个场馆（venue_id）');
    if (v.merchant && v.merchant.id !== merchantId) fail(400, 'invalid_body', '场馆不属于这个商户');
    center = clone(v.center);
    if (!Number.isFinite(radius_m)) radius_m = v.checkin_radius_m ?? 150;
  } else {
    if (!validLatLng(merged.center)) fail(400, 'invalid_body', '请在地图上选择投放位置（center）');
    center = { lat: +merged.center.lat.toFixed(6), lng: +merged.center.lng.toFixed(6) };
  }
  if (!(radius_m >= 20 && radius_m <= 500)) fail(400, 'invalid_body', '半径 20–500 m');

  const name = str(merged.name);
  if (!name || len(name) > 30) fail(400, 'invalid_body', '投放名称 1–30 字');
  if (len(str(merged.store_name)) > 20) fail(400, 'invalid_body', '门店名最多 20 字');
  const daily_cap = int(merged.daily_cap);
  if (!(daily_cap >= 1 && daily_cap <= 100000)) fail(400, 'invalid_body', '每日核销上限 1–100000');
  const start = parseTime(merged.start_time, 'start_time');
  const end = parseTime(merged.end_time, 'end_time');
  if (end <= start) fail(400, 'invalid_body', '结束时间需晚于开始时间');
  if (!prev && end <= Date.now()) fail(400, 'invalid_body', '结束时间已过');
  const settle_price_amt = int(merged.settle_price_amt);
  if (!(settle_price_amt >= 0 && settle_price_amt <= 100000)) fail(400, 'invalid_body', '结算单价 0–1000 元（单位分，整数）');
  const settle_direction = merged.settle_direction as SettleDirection;
  if (!['merchant_pays', 'platform_pays'].includes(settle_direction)) fail(400, 'invalid_body', 'settle_direction 只能是 merchant_pays / platform_pays');

  return {
    merchant: { id: mer.id, name: mer.name },
    campaign_id,
    type,
    name,
    center,
    radius_m,
    venue_id,
    store_name: str(merged.store_name) || null,
    perk: perkInput(merged.perk),
    daily_cap,
    start_time: new Date(start).toISOString(),
    end_time: new Date(end).toISOString(),
    settle_price_amt,
    settle_direction,
  };
}

function campaignInput(body: Record<string, unknown>, prev: CampaignRow | null) {
  const merged = { ...(prev ? { ...prev, merchant_id: prev.merchant.id } : {}), ...body } as Record<string, unknown>;
  const merchantId = int(merged.merchant_id);
  const mer = perkMerchants.find((x) => x.id === merchantId);
  if (!mer) fail(400, 'invalid_body', '商户不存在');
  if (prev && body.merchant_id !== undefined && merchantId !== prev.merchant.id) fail(400, 'invalid_body', '活动的商户创建后不能修改');
  if (!prev && (mer.status === 'suspended' || mer.status === 'reviewing')) fail(409, 'conflict', `「${mer.name}」${mer.status === 'suspended' ? '已暂停合作' : '资质审核中'}，不能新建联名活动`);
  const title = str(merged.title);
  if (!title || len(title) > 30) fail(400, 'invalid_body', '活动标题 1–30 字');
  const description = str(merged.description);
  if (len(description) > 200) fail(400, 'invalid_body', '活动说明最多 200 字');
  const cover = str(merged.cover_url);
  if (cover && !/^https?:\/\//.test(cover)) fail(400, 'invalid_body', '封面需要是 http(s) 地址');
  const start = parseTime(merged.start_time, 'start_time');
  const end = parseTime(merged.end_time, 'end_time');
  if (end <= start) fail(400, 'invalid_body', '结束时间需晚于开始时间');
  const store_count = int(merged.store_count);
  if (!(store_count >= 0 && store_count <= 10000)) fail(400, 'invalid_body', '门店数 0–10000');
  const target = int(merged.target_redemptions);
  if (!(target >= 1)) fail(400, 'invalid_body', '核销目标至少 1');
  const invest = int(merged.merchant_investment_amt);
  if (!(invest >= 0)) fail(400, 'invalid_body', '商户投入单位分，非负整数');
  let dropIds: number[] | undefined;
  if (body.drop_ids !== undefined) {
    if (!Array.isArray(body.drop_ids)) fail(400, 'invalid_body', 'drop_ids 需要是数组');
    dropIds = body.drop_ids.map((x) => int(x));
    for (const id of dropIds) {
      const d = drops.find((x) => x.id === id);
      if (!d) fail(400, 'invalid_body', `投放 #${id} 不存在`);
      if (d.merchant.id !== merchantId) fail(400, 'invalid_body', `投放 #${id} 不属于这个商户`);
      if (d.campaign_id && d.campaign_id !== prev?.id) fail(409, 'conflict', `投放「${d.name}」已属于其他联名活动`);
    }
  }
  let draft: boolean | undefined;
  if (body.status !== undefined) {
    if (body.status !== 'draft' && body.status !== 'scheduled') fail(400, 'invalid_body', 'status 只能是 draft / scheduled');
    if (prev && !prev.draft && (campaignStatus(prev) === 'running' || campaignStatus(prev) === 'paused')) fail(409, 'invalid_status', '活动已上线，不能改回草稿；暂停和恢复请用对应按钮');
    draft = body.status === 'draft';
  }
  return {
    draft,
    fields: {
      merchant: { id: mer.id, name: mer.name },
      title,
      description,
      cover_url: cover || null,
      start_time: new Date(start).toISOString(),
      end_time: new Date(end).toISOString(),
      store_count,
      target_redemptions: target,
      merchant_investment_amt: invest,
    },
    dropIds,
  };
}

function attachDrops(campaignId: number, ids: number[] | undefined) {
  if (!ids) return;
  for (const d of drops) {
    if (d.campaign_id === campaignId && !ids.includes(d.id)) d.campaign_id = null;
    if (ids.includes(d.id)) d.campaign_id = campaignId;
  }
}

// ---------------------------------------------------------------- energy shop

const svgUri = (svg: string) => `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
function itemImage(type: ShopItemType, a: string, b: string): string {
  const body =
    type === 'avatar_frame'
      ? `<circle cx="64" cy="64" r="46" fill="none" stroke="${a}" stroke-width="12"/><circle cx="64" cy="64" r="46" fill="none" stroke="${b}" stroke-width="3" stroke-dasharray="6 6"/><circle cx="64" cy="56" r="14" fill="#c9c9cf"/><path d="M38 96c6-16 46-16 52 0" fill="#c9c9cf"/>`
      : type === 'map_marker'
        ? `<path d="M64 16c-20 0-34 15-34 33 0 24 34 63 34 63s34-39 34-63c0-18-14-33-34-33z" fill="${a}" stroke="${b}" stroke-width="5"/><circle cx="64" cy="49" r="12" fill="#fff"/>`
        : `<rect x="18" y="18" width="92" height="92" rx="18" fill="${a}" stroke="${b}" stroke-width="6"/>`;
  return svgUri(`<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128"><rect width="128" height="128" rx="24" fill="#F2F2F4"/>${body}</svg>`);
}

const shopItems: ShopItem[] = [
  { key: 'skin_neon', name: '霓虹领地皮肤', type: 'territory_skin', price_energy: 800, image_url: null, preview: { fill: '#D9F26B', stroke: '#A0D911', pattern: 'grid' }, description: '荧光绿网格，夜跑党最爱', limited_until: null, on_sale: true },
  { key: 'skin_lavender', name: '薰衣草领地皮肤', type: 'territory_skin', price_energy: 600, image_url: null, preview: { fill: '#C9BEF7', stroke: '#7B6AE0', pattern: 'dots' }, description: '淡紫圆点，温柔但不好惹', limited_until: null, on_sale: true },
  { key: 'skin_sunset', name: '落日条纹皮肤', type: 'territory_skin', price_energy: 1200, image_url: null, preview: { fill: '#FFC59A', stroke: '#E8590C', pattern: 'stripe' }, description: '冬日限定，斜纹落日色', limited_until: dayAt(10, 23), on_sale: true },
  { key: 'skin_ocean', name: '海浪领地皮肤', type: 'territory_skin', price_energy: 900, image_url: null, preview: { fill: '#9ED8F5', stroke: '#2F6FD0', pattern: 'wave' }, description: '夏季款，已下架', limited_until: null, on_sale: false },
  { key: 'frame_gold', name: '金色头像框', type: 'avatar_frame', price_energy: 1500, image_url: itemImage('avatar_frame', '#F2C94C', '#B7791F'), preview: null, description: '圈地达人专属金边', limited_until: null, on_sale: true },
  { key: 'frame_night', name: '夜跑者头像框', type: 'avatar_frame', price_energy: 500, image_url: itemImage('avatar_frame', '#3A3F6B', '#B4A3F5'), preview: null, description: '深蓝星点，晚上 8 点后跑步的人懂', limited_until: null, on_sale: true },
  { key: 'marker_flag', name: '小旗标记', type: 'map_marker', price_energy: 300, image_url: itemImage('map_marker', '#DCF26A', '#141414'), preview: null, description: '地图上的你变成一面小旗', limited_until: null, on_sale: true },
  { key: 'marker_rocket', name: '火箭标记', type: 'map_marker', price_energy: 1000, image_url: itemImage('map_marker', '#F27CA8', '#D93A2B'), preview: null, description: '双十二限定，配速越快尾焰越长', limited_until: dayAt(22, 23), on_sale: true },
];

const shopRedemptions: Record<string, number> = {
  skin_neon: 3_284, skin_lavender: 2_105, skin_sunset: 642, skin_ocean: 1_930,
  frame_gold: 418, frame_night: 2_766, marker_flag: 5_012, marker_rocket: 203,
};

const HEX = /^#[0-9A-Fa-f]{6}$/;
const PATTERNS = ['solid', 'grid', 'stripe', 'dots', 'wave'];

function shopInput(body: Record<string, unknown>, prev: ShopItem | null): ShopItem {
  const merged = { ...(prev ?? {}), ...body } as Record<string, unknown>;
  const key = prev ? prev.key : str(merged.key);
  if (!prev) {
    if (!/^[a-z][a-z0-9_]{2,39}$/.test(key)) fail(400, 'invalid_body', 'key 用小写字母开头，小写字母、数字、下划线，3–40 位');
    if (shopItems.some((x) => x.key === key)) fail(409, 'conflict', `key「${key}」已存在`);
  } else if (body.key !== undefined && body.key !== prev.key) fail(400, 'invalid_body', 'key 创建后不能修改');
  const type = merged.type as ShopItemType;
  if (!['territory_skin', 'avatar_frame', 'map_marker'].includes(type)) fail(400, 'invalid_body', 'type 只能是 territory_skin / avatar_frame / map_marker');
  if (prev && body.type !== undefined && body.type !== prev.type) fail(400, 'invalid_body', '商品类型创建后不能修改');
  const name = str(merged.name);
  if (!name || len(name) > 20) fail(400, 'invalid_body', '名称 1–20 字');
  const price = int(merged.price_energy);
  if (!(price >= 1 && price <= 100000)) fail(400, 'invalid_body', '价格 1–100000 能量（只能用能量兑换）');
  const image = str(merged.image_url);
  if (image && !/^(https?:\/\/|data:image\/)/.test(image)) fail(400, 'invalid_body', '图片需要是 http(s) 地址');
  let preview: ShopItem['preview'] = null;
  if (type === 'territory_skin') {
    const p = (merged.preview ?? {}) as Record<string, unknown>;
    if (!HEX.test(String(p.fill)) || !HEX.test(String(p.stroke))) fail(400, 'invalid_body', '领地皮肤需要填充色和描边色（#RRGGBB）');
    if (!PATTERNS.includes(String(p.pattern))) fail(400, 'invalid_body', `花纹只能是 ${PATTERNS.join(' / ')}`);
    preview = { fill: String(p.fill).toUpperCase(), stroke: String(p.stroke).toUpperCase(), pattern: String(p.pattern) };
  } else if (!image) fail(400, 'invalid_body', '头像框和地图标记需要图片');
  const description = str(merged.description);
  if (len(description) > 60) fail(400, 'invalid_body', '说明最多 60 字');
  let limited_until: string | null = null;
  if (merged.limited_until) {
    const t = parseTime(merged.limited_until, 'limited_until');
    if (!prev && t <= Date.now()) fail(400, 'invalid_body', '限时截止时间已过');
    limited_until = new Date(t).toISOString();
  }
  return { key, name, type, price_energy: price, image_url: image || null, preview, description, limited_until, on_sale: merged.on_sale !== false };
}

// ---------------------------------------------------------------- routes

const OPS: AdminRole[] = ['admin', 'ops'];

export function perkRoutes(log: Log): [string, RegExp, Handler][] {
  return [
    // option lists (fallbacks: the 商户 / 场馆 mocks answer these when they are registered first)
    ['GET', /^\/merchants$/, ({ q, role }) => {
      requireRole(role, OPS);
      const status = q.get('status');
      const kw = (q.get('q') ?? '').trim();
      return paginate(perkMerchants.filter((m) => (!status || m.status === status) && (!kw || m.name.includes(kw))).map(clone), q);
    }],
    ['GET', /^\/venues$/, ({ q, role }) => {
      requireRole(role, OPS);
      const mid = Number(q.get('merchant_id') ?? 0);
      return paginate(perkVenues.filter((v) => !mid || v.merchant?.id === mid).map(clone), q);
    }],

    // 投放
    ['GET', /^\/drops$/, ({ q, role }) => {
      requireRole(role, OPS);
      const mid = Number(q.get('merchant_id') ?? 0);
      const type = q.get('type');
      const status = q.get('status');
      const rank: Record<DropStatus, number> = { active: 0, paused: 1, scheduled: 2, ended: 3 };
      const list = drops
        .map(dropOut)
        .filter((d) => (!mid || d.merchant.id === mid) && (!type || d.type === type) && (!status || d.status === status))
        .sort((a, b) => rank[a.status] - rank[b.status] || b.id - a.id);
      return paginate(list, q);
    }],
    ['POST', /^\/drops$/, ({ body, role, adminId }) => {
      requireRole(role, OPS);
      const v = dropInput(body, null);
      const row: DropRow = { id: ++dropSeq, ...v, issued_today: 0, redeemed_today: 0, paused: false };
      drops.unshift(row);
      log(adminId, 'drop.create', `drop:${row.id}`, { type: row.type, merchant_id: row.merchant.id, daily_cap: row.daily_cap });
      return dropOut(row);
    }],
    ['PATCH', /^\/drops\/(\d+)$/, ({ m, body, role, adminId }) => {
      requireRole(role, OPS);
      const d = drops.find((x) => x.id === Number(m[1]));
      if (!d) fail(404, 'not_found', '投放不存在');
      if (dropStatus(d) === 'ended') fail(409, 'conflict', '投放已结束，不能修改');
      const v = dropInput(body, d);
      Object.assign(d, v);
      log(adminId, 'drop.update', `drop:${d.id}`, { fields: Object.keys(body) });
      return dropOut(d);
    }],
    ['POST', /^\/drops\/(\d+)\/(pause|resume)$/, ({ m, role, adminId }) => {
      requireRole(role, OPS);
      const d = drops.find((x) => x.id === Number(m[1]));
      if (!d) fail(404, 'not_found', '投放不存在');
      const st = dropStatus(d);
      if (st === 'ended') fail(409, 'conflict', '投放已结束');
      if (m[2] === 'pause') {
        if (d.paused) fail(409, 'conflict', '投放已经是暂停状态');
        d.paused = true;
      } else {
        if (!d.paused) fail(409, 'conflict', st === 'paused' ? '所属联名活动已暂停，请先恢复活动' : '投放没有暂停');
        const c = d.campaign_id ? campaigns.find((x) => x.id === d.campaign_id) : undefined;
        if (c && (c.paused || c.draft)) fail(409, 'conflict', `所属联名活动「${c.title}」${c.draft ? '还是草稿' : '已暂停'}，请先恢复活动`);
        d.paused = false;
      }
      log(adminId, `drop.${m[2]}`, `drop:${d.id}`);
      return dropOut(d);
    }],

    // 联名活动
    ['GET', /^\/brand-campaigns$/, ({ q, role }) => {
      requireRole(role, OPS);
      const status = q.get('status');
      const rank: Record<BrandCampaignStatus, number> = { running: 0, paused: 1, scheduled: 2, draft: 3, ended: 4 };
      const list = campaigns
        .map(campaignOut)
        .filter((c) => !status || c.status === status)
        .sort((a, b) => rank[a.status] - rank[b.status] || Date.parse(b.start_time) - Date.parse(a.start_time));
      return paginate(list, q);
    }],
    ['POST', /^\/brand-campaigns$/, ({ body, role, adminId }) => {
      requireRole(role, OPS);
      const { fields, dropIds, draft } = campaignInput(body, null);
      const row: CampaignRow = { id: ++campaignSeq, ...fields, draft: draft ?? false, paused: false, stats: { issued: 0, redeemed: 0, new_users: 0 } };
      campaigns.unshift(row);
      attachDrops(row.id, dropIds);
      log(adminId, 'brand_campaign.create', `brand_campaign:${row.id}`, { merchant_id: row.merchant.id, target: row.target_redemptions, investment_amt: row.merchant_investment_amt });
      return campaignOut(row);
    }],
    ['PATCH', /^\/brand-campaigns\/(\d+)$/, ({ m, body, role, adminId }) => {
      requireRole(role, OPS);
      const c = campaigns.find((x) => x.id === Number(m[1]));
      if (!c) fail(404, 'not_found', '联名活动不存在');
      if (campaignStatus(c) === 'ended') fail(409, 'conflict', '活动已结束，不能修改');
      const { fields, dropIds, draft } = campaignInput(body, c);
      Object.assign(c, fields);
      if (draft !== undefined) c.draft = draft;
      attachDrops(c.id, dropIds);
      log(adminId, 'brand_campaign.update', `brand_campaign:${c.id}`, { fields: Object.keys(body) });
      return campaignOut(c);
    }],
    ['POST', /^\/brand-campaigns\/(\d+)\/(pause|resume|launch)$/, ({ m, role, adminId }) => {
      requireRole(role, OPS);
      const c = campaigns.find((x) => x.id === Number(m[1]));
      if (!c) fail(404, 'not_found', '联名活动不存在');
      const st = campaignStatus(c);
      if (st === 'ended') fail(409, 'conflict', '活动已结束');
      if (m[2] === 'pause') {
        if (st !== 'running' && st !== 'scheduled') fail(409, 'conflict', '只有进行中或待开始的活动可以暂停');
        c.paused = true;
      } else if (m[2] === 'resume') {
        if (st !== 'paused') fail(409, 'conflict', '活动没有暂停');
        c.paused = false;
      } else {
        if (st !== 'scheduled' && st !== 'draft') fail(409, 'conflict', '只有待开始或草稿的活动可以提前上线');
        c.draft = false;
        c.paused = false;
        c.start_time = new Date().toISOString();
        // the drops go live with the campaign
        for (const d of drops) if (d.campaign_id === c.id && Date.parse(d.start_time) > Date.now()) d.start_time = c.start_time;
      }
      log(adminId, `brand_campaign.${m[2]}`, `brand_campaign:${c.id}`);
      return campaignOut(c);
    }],

    // 能量商城
    ['GET', /^\/shop\/items$/, ({ q, role }) => {
      requireRole(role, OPS);
      const type = q.get('type');
      return { items: shopItems.filter((x) => !type || x.type === type).map(clone) };
    }],
    ['POST', /^\/shop\/items$/, ({ body, role, adminId }) => {
      requireRole(role, OPS);
      const item = shopInput(body, null);
      shopItems.push(item);
      shopRedemptions[item.key] = 0;
      log(adminId, 'shop_item.create', `shop_item:${item.key}`, { price_energy: item.price_energy, on_sale: item.on_sale });
      return clone(item);
    }],
    ['PATCH', /^\/shop\/items\/([\w-]+)$/, ({ m, body, role, adminId }) => {
      requireRole(role, OPS);
      const i = shopItems.findIndex((x) => x.key === m[1]);
      if (i < 0) fail(404, 'not_found', '商品不存在');
      const item = shopInput(body, shopItems[i]);
      shopItems[i] = item;
      log(adminId, 'shop_item.update', `shop_item:${item.key}`, { fields: Object.keys(body) });
      return clone(item);
    }],
    ['GET', /^\/shop\/stats$/, ({ role }) => {
      requireRole(role, OPS);
      return {
        items: shopItems.map((x) => {
          const n = shopRedemptions[x.key] ?? 0;
          return { key: x.key, redemptions: n, energy_spent: n * x.price_energy };
        }),
      };
    }],
  ];
}
