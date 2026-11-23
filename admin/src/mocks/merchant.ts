// Mock of V2 第四批「本地生活与商户」管理端 · 商户 / 场馆 / 订场 / 核销 / 结算
// (docs/api/v2-4-本地生活与商户.md). Four weeks of redemptions and bookings are generated
// deterministically so the 7-day chart, the redemption log and the weekly statements agree.
// Merchant staff (role merchant) only see their own merchant (admin `shop` → 跑野运动馆).
// Drops come from mocks/perks.ts (the 投放 page's mock); merchant / venue ids match its option lists.
import { ApiError } from '../api/client';
import type { AdminRole, DashboardTodo, UserBrief } from '../api/types';
import type { Drop, MerchantRef } from '../api/perks';
import type {
  Booking,
  BookingStatus,
  Coupon,
  CouponStatus,
  Merchant,
  MerchantStatus,
  MerchantType,
  Redemption,
  Statement,
  StatementLine,
  StatementStatus,
  Venue,
  VenueSport,
} from '../api/merchant';
import * as db from './data';
import { dropsOfMerchant } from './perks';
import { notifyMerchant, yuanText, type MessageDraft } from './messages';

type Ctx = { m: RegExpMatchArray; q: URLSearchParams; body: Record<string, unknown>; adminId: number; role: AdminRole };
type Handler = (ctx: Ctx) => unknown;
type Log = (adminId: number, action: string, target: string, detail?: Record<string, unknown>) => void;

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const HISTORY_DAYS = 28;

function fail(status: number, code: string, message: string): never {
  throw new ApiError(status, code, message);
}
function requireRole(role: AdminRole, allowed: AdminRole[]) {
  if (!allowed.includes(role)) fail(403, 'forbidden', '当前角色没有权限执行此操作');
}
const clone = <T,>(x: T): T => JSON.parse(JSON.stringify(x)) as T;

/** Cheap deterministic hash → [0, 1). */
function h(n: number, salt = 0): number {
  let x = (n * 2654435761 + salt * 40503 + 12345) >>> 0;
  x ^= x >>> 13;
  x = Math.imul(x, 0x5bd1e995) >>> 0;
  x ^= x >>> 15;
  return (x >>> 0) / 4294967296;
}

const pad = (n: number, w = 2) => String(n).padStart(w, '0');
function dayKey(d: Date | number): string {
  const x = typeof d === 'number' ? new Date(d) : d;
  return `${x.getFullYear()}-${pad(x.getMonth() + 1)}-${pad(x.getDate())}`;
}
function startOfDay(ms: number): number {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}
function mondayOf(ms: number): number {
  const d = new Date(startOfDay(ms));
  const wd = (d.getDay() + 6) % 7;
  return d.getTime() - wd * DAY;
}
/** ISO week number of a Monday. */
function isoWeek(mondayMs: number): { year: number; week: number } {
  const thu = new Date(mondayMs + 3 * DAY);
  const year = thu.getFullYear();
  const jan4 = new Date(year, 0, 4);
  const week1 = mondayOf(jan4.getTime());
  return { year, week: Math.round((mondayOf(thu.getTime()) - week1) / (7 * DAY)) + 1 };
}
const iso = (ms: number) => new Date(ms).toISOString();

const NOW = Date.now();
const TODAY = startOfDay(NOW);
const THIS_MONDAY = mondayOf(NOW);

const userBrief = (i: number): UserBrief => {
  const u = db.users[i % db.users.length];
  return { id: u.id, nickname: u.nickname, avatar_url: null };
};
const userRef = (i: number) => {
  const u = db.users[i % db.users.length];
  return { id: u.id, nickname: u.nickname };
};

/** Inline SVG 营业执照 placeholder (no network in mock mode). */
function licenseImage(name: string, seed: number): string {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="600" height="420" viewBox="0 0 600 420">
<rect width="600" height="420" fill="#FBF7EC"/><rect x="18" y="18" width="564" height="384" fill="none" stroke="#B8862B" stroke-width="6"/>
<text x="300" y="86" text-anchor="middle" font-size="40" font-family="serif" font-weight="700" fill="#9A2A1F">${seed % 2 ? '营 业 执 照' : '食品经营许可证'}</text>
<text x="60" y="160" font-size="22" font-family="sans-serif" fill="#333">名称：${name}</text>
<text x="60" y="204" font-size="22" font-family="sans-serif" fill="#333">统一社会信用代码：91310115MA1H${(700000 + seed * 7919).toString().slice(0, 6)}X</text>
<text x="60" y="248" font-size="22" font-family="sans-serif" fill="#333">类型：有限责任公司</text>
<text x="60" y="292" font-size="22" font-family="sans-serif" fill="#333">住所：上海市浦东新区</text>
<circle cx="470" cy="320" r="56" fill="none" stroke="#C8341F" stroke-width="5" opacity=".8"/><text x="470" y="328" text-anchor="middle" font-size="18" fill="#C8341F" opacity=".8">登记机关</text>
</svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

// ---------------------------------------------------------------- merchants

interface MerchantRow {
  id: number;
  name: string;
  type: MerchantType;
  status: MerchantStatus;
  contact_name: string | null;
  phone: string | null;
  license_images: string[];
  booking_commission_rate: number;
  /** V2 第五批 (default 0.08). */
  product_commission_rate: number;
  created_at: string;
}

const maskPhone = (p: string | null) => (p ? `${p.slice(0, 3)}****${p.slice(7)}` : null);

// Same ids / names / statuses as perkMerchants in mocks/perks.ts (the 投放 / 联名活动 mocks), plus 江湾网球中心.
export const merchants: MerchantRow[] = (
  [
    [1, '青柠茶铺', 'brand', 'partner', '林店长', '13816620931', 0, 2, 96],
    [2, '跑野运动馆', 'venue', 'partner', '赵教练', '13917783302', 0.1, 2, 88],
    [3, '街角便利', 'store', 'partner', '陈老板', '15900456678', 0, 1, 74],
    [4, '山系咖啡', 'brand', 'partner', '许小姐', '13661880045', 0, 2, 40],
    [5, '城市攀岩馆', 'venue', 'reviewing', '马克', '17717362210', 0.12, 1, 3],
    [6, '城南全民健身中心', 'venue', 'partner', '王经理', '13801231234', 0.1, 2, 61],
    [7, '麦田烘焙', 'store', 'suspended', '刘店长', '13371659204', 0, 1, 150],
    [8, '野径户外', 'store', 'pending_sign', '孙经理', '13524470981', 0, 1, 9],
    [9, '江湾网球中心', 'venue', 'reviewing', '周经理', '18621345567', 0.1, 0, 1],
  ] as [number, string, MerchantType, MerchantStatus, string, string, number, number, number][]
).map(([id, name, type, status, contact, phone, rate, licenses, days]) => ({
  id,
  name,
  type,
  status,
  contact_name: contact,
  phone,
  license_images: Array.from({ length: licenses }, (_, k) => licenseImage(name, id * 10 + k)),
  booking_commission_rate: rate,
  product_commission_rate: id === 1 ? 0.05 : 0.08,
  created_at: iso(NOW - days * DAY - id * 3 * HOUR),
}));

/** Admin accounts bound to a merchant (role merchant). */
const staffMerchant = new Map<number, number>([[4, 2]]); // shop → 跑野运动馆
export function merchantOf(adminId: number): number | null {
  return staffMerchant.get(adminId) ?? null;
}
function scopeOf(ctx: Ctx): number | null {
  if (ctx.role !== 'merchant') return null;
  const m = merchantOf(ctx.adminId);
  if (m === null) fail(403, 'no_merchant', '这个商户账号还没有绑定商户');
  return m;
}
const mref = (id: number): MerchantRef => ({ id, name: merchants.find((x) => x.id === id)?.name ?? `商户 ${id}` });

// ---------------------------------------------------------------- venues

interface VenueRow extends Required<Pick<Venue, 'slot_minutes' | 'open_time' | 'close_time' | 'court_qty' | 'is_disabled'>> {
  id: number;
  merchant_id: number | null;
  name: string;
  sports: VenueSport[];
  center: { lat: number; lng: number };
  address: string;
  district: string;
  tags: string[];
  cover_url: string | null;
  checkin_radius_m: number;
  bookable: boolean;
  price_amt: number | null;
  owner_discount_rate: number | null;
  qr_version: number;
}

const C = { lng: 121.505, lat: 31.232 };
// Ids 8–12 are perkVenues in mocks/perks.ts (据点 drops point at 8 and 9).
type VenueSeed = Pick<VenueRow, 'id' | 'merchant_id' | 'name' | 'sports' | 'center' | 'address' | 'district' | 'tags' | 'price_amt' | 'court_qty' | 'owner_discount_rate'> & Partial<VenueRow>;
const VENUE_SEED: VenueSeed[] = [
  { id: 8, merchant_id: 2, name: '跑野运动馆 · 东方路', sports: ['basketball', 'badminton', 'gym'], center: { lat: 31.2268, lng: 121.5242 }, address: '浦东新区东方路 1217 号', district: '浦东新区', tags: ['室内', '木地板', '可开发票'], price_amt: 8000, court_qty: 4, owner_discount_rate: 0.8 },
  { id: 9, merchant_id: 6, name: '城南全民健身中心 · 匹克球', sports: ['pickleball', 'badminton'], center: { lat: 31.1885, lng: 121.4372 }, address: '徐汇区龙华中路 600 号', district: '徐汇区', tags: ['室内', '可租拍', '新手友好'], price_amt: 6000, court_qty: 4, owner_discount_rate: 0.8 },
  { id: 10, merchant_id: 6, name: '城南全民健身中心 · 游泳馆', sports: ['swimming'], center: { lat: 31.1872, lng: 121.4391 }, address: '徐汇区龙华中路 600 号 B 馆', district: '徐汇区', tags: ['恒温', '50 米泳道'], price_amt: 4500, court_qty: 8, owner_discount_rate: null, checkin_radius_m: 120 },
  { id: 11, merchant_id: 5, name: '城市攀岩馆 · 世博店', sports: ['climbing'], center: { lat: 31.1903, lng: 121.4968 }, address: '浦东新区世博大道 1368 号', district: '浦东新区', tags: ['室内', '抱石', '有教练'], bookable: false, price_amt: null, court_qty: 1, owner_discount_rate: null, checkin_radius_m: 100 },
  { id: 12, merchant_id: null, name: '陆家嘴滨江篮球场', sports: ['basketball'], center: { lat: 31.2392, lng: 121.5018 }, address: '浦东新区滨江大道 2967 号', district: '浦东新区', tags: ['室外', '免费', '夜场灯光'], bookable: false, price_amt: null, court_qty: 2, owner_discount_rate: null },
  { id: 13, merchant_id: 2, name: '跑野运动馆 · 张江', sports: ['badminton', 'tennis'], center: { lat: 31.2049, lng: 121.5905 }, address: '浦东新区祖冲之路 887 号', district: '浦东新区', tags: ['室内', '可租拍', '空调'], price_amt: 7000, court_qty: 6, owner_discount_rate: 0.85, slot_minutes: 90 },
  { id: 14, merchant_id: 9, name: '江湾网球中心', sports: ['tennis'], center: { lat: 31.3065, lng: 121.5108 }, address: '杨浦区国和路 346 号', district: '杨浦区', tags: ['室外', '硬地', '夜场灯光'], bookable: false, price_amt: 15000, court_qty: 6, owner_discount_rate: null, slot_minutes: 90 },
  { id: 15, merchant_id: null, name: '滨江足球公园', sports: ['football'], center: { lat: C.lat + 0.014, lng: C.lng - 0.026 }, address: '浦东新区滨江大道 2727 号', district: '浦东新区', tags: ['室外', '免费', '7 人制'], bookable: false, price_amt: null, court_qty: 2, owner_discount_rate: null, checkin_radius_m: 250 },
  { id: 16, merchant_id: null, name: '徐汇滨江篮球场', sports: ['basketball'], center: { lat: 31.1802, lng: 121.4617 }, address: '徐汇区龙腾大道 2350 号', district: '徐汇区', tags: ['室外', '免费', '夜场灯光'], bookable: false, price_amt: null, court_qty: 4, owner_discount_rate: null, checkin_radius_m: 200 },
  { id: 17, merchant_id: null, name: '陆家嘴中心绿地篮球场', sports: ['basketball'], center: { lat: C.lat + 0.0095, lng: C.lng - 0.006 }, address: '浦东新区陆家嘴环路 1188 号', district: '浦东新区', tags: ['室外', '维修中'], bookable: false, price_amt: null, court_qty: 1, owner_discount_rate: null, is_disabled: true },
];
export const venues: VenueRow[] = VENUE_SEED.map((v) => ({
  cover_url: null,
  checkin_radius_m: 150,
  bookable: true,
  slot_minutes: 60,
  open_time: v.sports.includes('swimming') ? '06:30' : '08:00',
  close_time: '22:00',
  is_disabled: false,
  qr_version: 1,
  ...v,
}));

/** This week's 馆主 (and history): deterministic per venue + week. */
function ownerFor(venueId: number, weeksAgo: number): { user: UserBrief; points: number } | null {
  if (weeksAgo === 0 && (venueId === 6 || venueId === 10)) return null;
  if (h(venueId, weeksAgo + 70) < 0.12) return null;
  const ui = [8, 3, 12, 0, 21, 14, 27, 1, 9, 18][(venueId + (h(venueId, weeksAgo) < 0.6 ? 0 : weeksAgo)) % 10];
  return { user: userBrief(ui), points: 60 + Math.floor(h(venueId, weeksAgo + 7) * 18) * 10 };
}

function venueOut(v: VenueRow): Venue {
  const o = ownerFor(v.id, 0);
  return {
    id: v.id,
    merchant: v.merchant_id ? mref(v.merchant_id) : null,
    name: v.name,
    sports: [...v.sports],
    center: { ...v.center },
    address: v.address,
    district: v.district,
    tags: [...v.tags],
    cover_url: v.cover_url,
    checkin_radius_m: v.checkin_radius_m,
    bookable: v.bookable,
    price_amt: v.price_amt,
    price_unit: 'hour',
    owner: o ? { ...o, since: dayKey(THIS_MONDAY) } : null,
    owner_discount_rate: v.owner_discount_rate,
    slot_minutes: v.slot_minutes,
    open_time: v.open_time,
    close_time: v.close_time,
    court_qty: v.court_qty,
    is_disabled: v.is_disabled,
  };
}

function qrOf(v: VenueRow) {
  const sig = Array.from({ length: 10 }, (_, k) => 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'[Math.floor(h(v.id * 31 + v.qr_version, k) * 56)]).join('');
  const payload = `LPV.${v.id}.${sig}`;
  return { payload, url: `https://l.loopland.cn/v/${payload}` };
}

/** 商户自助改场馆 (docs/api/v2-5 「商户自助改场馆」): the only fields a merchant account may send. */
const VENUE_SELF_FIELDS = ['cover_url', 'tags', 'price_amt', 'slot_minutes', 'open_time', 'close_time', 'court_qty', 'owner_discount_rate', 'bookable'];

const SPORTS: VenueSport[] = ['basketball', 'football', 'badminton', 'pickleball', 'tennis', 'swimming', 'climbing', 'gym'];
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const IMG_RE = /^(https?:\/\/|\/|data:image\/)/;

function venueInput(b: Record<string, unknown>, base?: VenueRow): Omit<VenueRow, 'id' | 'qr_version'> {
  const get = <K extends keyof VenueRow>(k: K): unknown => (k in b ? b[k as string] : base?.[k]);
  const name = String(get('name') ?? '').trim();
  if (!name || name.length > 40) fail(400, 'invalid_body', '场馆名称必填，最多 40 字');
  const merchantId = get('merchant_id') ?? (b.merchant && typeof b.merchant === 'object' ? (b.merchant as { id: number }).id : null);
  const mid = merchantId === null || merchantId === undefined || merchantId === '' ? null : Number(merchantId);
  if (mid !== null && !merchants.some((x) => x.id === mid)) fail(400, 'invalid_body', '商户不存在');
  const sports = get('sports');
  if (!Array.isArray(sports) || !sports.length || sports.some((s) => !SPORTS.includes(s as VenueSport))) fail(400, 'invalid_body', '至少选一个运动，取值见约定');
  const center = get('center') as { lat?: unknown; lng?: unknown } | undefined;
  const lat = Number(center?.lat);
  const lng = Number(center?.lng);
  if (!center || !Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) fail(400, 'invalid_body', '场馆坐标无效');
  const radius = Number(get('checkin_radius_m') ?? 150);
  if (!Number.isInteger(radius) || radius < 30 || radius > 1000) fail(400, 'invalid_body', '签到半径 30–1000 米');
  const bookable = get('bookable') === true;
  const price = get('price_amt');
  const priceAmt = price === null || price === undefined || price === '' ? null : Number(price);
  if (priceAmt !== null && (!Number.isInteger(priceAmt) || priceAmt < 0)) fail(400, 'invalid_body', '价格必须是非负整数（分）');
  if (bookable && mid === null) fail(400, 'invalid_body', '非合作场馆（没有商户）只能签到，不能开放预订');
  if (bookable && !priceAmt) fail(400, 'invalid_body', '开放预订需要填写价格');
  const slot = Number(get('slot_minutes') ?? 60);
  if (![30, 60, 90, 120].includes(slot)) fail(400, 'invalid_body', '时段长度只能是 30 / 60 / 90 / 120 分钟');
  const open = String(get('open_time') ?? '08:00');
  const close = String(get('close_time') ?? '22:00');
  if (!TIME_RE.test(open) || !TIME_RE.test(close) || open >= close) fail(400, 'invalid_body', '营业时间格式为 HH:mm，且开门早于关门');
  const courts = Number(get('court_qty') ?? 1);
  if (!Number.isInteger(courts) || courts < 1 || courts > 50) fail(400, 'invalid_body', '场地数 1–50');
  const disc = get('owner_discount_rate');
  const discount = disc === null || disc === undefined || disc === '' ? null : Number(disc);
  if (discount !== null && !(discount > 0 && discount < 1)) fail(400, 'invalid_body', '馆主折扣应在 0–1 之间（0.8 = 八折），不打折留空');
  const tags = get('tags') ?? [];
  if (!Array.isArray(tags) || tags.length > 8 || tags.some((t) => typeof t !== 'string' || !t.trim() || t.length > 10)) fail(400, 'invalid_body', '标签最多 8 个，每个不超过 10 字');
  const cover = get('cover_url');
  const coverUrl = cover ? String(cover) : null;
  if (coverUrl && !IMG_RE.test(coverUrl)) fail(400, 'invalid_body', '封面图地址无效');
  return {
    merchant_id: mid,
    name,
    sports: sports as VenueSport[],
    center: { lat, lng },
    address: String(get('address') ?? '').trim(),
    district: String(get('district') ?? '').trim(),
    tags: (tags as string[]).map((t) => t.trim()),
    cover_url: coverUrl,
    checkin_radius_m: radius,
    bookable,
    price_amt: priceAmt,
    slot_minutes: slot,
    open_time: open,
    close_time: close,
    court_qty: courts,
    owner_discount_rate: discount,
    is_disabled: get('is_disabled') === true,
  };
}

// ---------------------------------------------------------------- drops (owned by mocks/perks.ts)

/** Every drop, fresh from the 投放 mock (it changes when the 投放 page edits them). */
function allDrops(): Drop[] {
  return merchants.flatMap((m) => dropsOfMerchant(m.id));
}
function dropById(id: number): Drop | undefined {
  return allDrops().find((d) => d.id === id);
}

function storeOf(d: Pick<Drop, 'name'>): string {
  const n = d.name.split(' · ').slice(1).join(' · ');
  return n || d.name;
}

// ---------------------------------------------------------------- redemptions (history + live)

interface RedemptionRow {
  id: number;
  coupon_id: number;
  code: string;
  drop_id: number;
  merchant_id: number;
  user_index: number;
  at: number;
  obtained_at: number;
  voided: boolean;
}

const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const codeFor = (n: number) => Array.from({ length: 8 }, (_, k) => CODE_CHARS[Math.floor(h(n, k + 300) * CODE_CHARS.length)]).join('');

/** A snapshot of the seeded drops: redemption history and statements are computed from it. */
const SEED_DROPS = new Map<number, Drop>(allDrops().map((d) => [d.id, d]));

const redemptions: RedemptionRow[] = [];
{
  let id = 5000;
  for (let off = HISTORY_DAYS - 1; off >= 0; off--) {
    const day = TODAY - off * DAY;
    const wd = new Date(day).getDay();
    const weekend = wd === 0 || wd === 6 ? 1.4 : 1;
    const span = off === 0 ? Math.max(HOUR, NOW - day - 7 * HOUR) : 15 * HOUR;
    for (const d of SEED_DROPS.values()) {
      if (Date.parse(d.start_time) > day + DAY || Date.parse(d.end_time) < day) continue;
      // Today: exactly what the 投放 mock reports; earlier days: around a full day of that.
      const full = d.redeemed_today ? d.redeemed_today * 1.25 : d.status === 'ended' ? 24 : 0;
      let n = off === 0 ? d.redeemed_today : Math.round(full * weekend * (0.7 + h(d.id * 100 + off, 1) * 0.5));
      n = Math.min(n, d.daily_cap);
      for (let k = 0; k < n; k++) {
        id++;
        const at = day + 7 * HOUR + Math.floor(h(id, 2) * span);
        redemptions.push({
          id,
          coupon_id: 200000 + id,
          code: codeFor(id),
          drop_id: d.id,
          merchant_id: d.merchant.id,
          user_index: Math.floor(h(id, 3) * db.users.length),
          at,
          obtained_at: at - Math.floor((0.2 + h(id, 4) * 3) * DAY),
          voided: off > 0 && h(id, 5) < 0.014,
        });
      }
    }
  }
  redemptions.sort((a, b) => b.at - a.at);
}
let redemptionSeq = 90000;

/** Settlement price of one redemption, signed: + merchant pays the platform, − the platform pays. */
function signedPrice(dropId: number): number {
  const d = SEED_DROPS.get(dropId) ?? dropById(dropId);
  if (!d) return 0;
  return d.settle_direction === 'merchant_pays' ? d.settle_price_amt : -d.settle_price_amt;
}

function couponFrom(id: number, code: string, d: Drop, status: CouponStatus, obtained: number, expires: number, used: number | null): Coupon {
  return {
    id,
    code,
    perk: { ...d.perk },
    merchant: mref(d.merchant.id),
    source: { type: d.type, drop_id: d.id, name: d.name },
    status,
    obtained_at: iso(obtained),
    expires_at: iso(expires),
    used_at: used ? iso(used) : null,
    used_store: used ? storeOf(d) : null,
  };
}

function redemptionOut(r: RedemptionRow): Redemption {
  const d = SEED_DROPS.get(r.drop_id) ?? dropById(r.drop_id)!;
  const expires = startOfDay(r.obtained_at) + (d.perk.valid_days + 1) * DAY - 1000;
  return {
    id: r.id,
    coupon: couponFrom(r.coupon_id, r.code, d, 'used', r.obtained_at, expires, r.at),
    user: userRef(r.user_index),
    store: storeOf(d),
    created_at: iso(r.at),
    voided: r.voided,
  };
}

// ---------------------------------------------------------------- live coupons (核销台 test codes)

interface CouponRow {
  id: number;
  code: string;
  drop_id: number;
  user_index: number;
  status: CouponStatus;
  obtained_at: number;
  expires_at: number;
  used_at: number | null;
}

/** Users without a settled activity today (→ no_activity_today). */
const NO_ACTIVITY_TODAY = new Set<number>([16]);

// Drop 4 = 据点 · 跑野运动馆 · 东方路 (merchant 2, the `shop` account); drop 1 = 青柠茶铺 补给站.
const coupons: CouponRow[] = [
  { id: 77, code: '8K2D9QXW', drop_id: 4, user_index: 8, status: 'unused', obtained_at: NOW - 2 * HOUR, expires_at: TODAY + 30 * DAY, used_at: null },
  { id: 83, code: 'P2X7MNQR', drop_id: 4, user_index: 3, status: 'unused', obtained_at: NOW - 26 * HOUR, expires_at: TODAY + 29 * DAY, used_at: null },
  { id: 78, code: '7HM3QPLA', drop_id: 4, user_index: 12, status: 'used', obtained_at: NOW - 3 * DAY, expires_at: TODAY + 27 * DAY, used_at: NOW - DAY - 3 * HOUR },
  { id: 79, code: '5RT8WXYZ', drop_id: 4, user_index: 21, status: 'expired', obtained_at: NOW - 32 * DAY, expires_at: TODAY - DAY, used_at: null },
  { id: 80, code: '3NB6KDFE', drop_id: 4, user_index: 16, status: 'unused', obtained_at: NOW - 5 * HOUR, expires_at: TODAY + 30 * DAY, used_at: null },
  { id: 82, code: '6LK4JHGF', drop_id: 1, user_index: 27, status: 'unused', obtained_at: NOW - 3 * HOUR, expires_at: TODAY + 7 * DAY, used_at: null },
  { id: 84, code: 'J4H8TTKC', drop_id: 1, user_index: 1, status: 'unused', obtained_at: NOW - 6 * HOUR, expires_at: TODAY + 7 * DAY, used_at: null },
];

function couponOut(c: CouponRow): Coupon {
  const d = dropById(c.drop_id)!;
  return couponFrom(c.id, c.code, d, c.status === 'unused' && c.expires_at < Date.now() ? 'expired' : c.status, c.obtained_at, c.expires_at, c.used_at);
}

// ---------------------------------------------------------------- bookings

interface BookingRow extends Omit<Booking, 'user' | 'venue'> {
  venue_id: number;
  merchant_id: number;
  user_index: number;
  start_ms: number;
}

const bookings: BookingRow[] = [];
{
  let id = 300;
  for (let off = HISTORY_DAYS - 1; off >= -6; off--) {
    const day = TODAY - off * DAY;
    for (const v of venues) {
      if (!v.merchant_id || !v.price_amt || !v.bookable) continue;
      const n = Math.floor(h(v.id * 1000 + off, 11) * (v.court_qty > 4 ? 7 : 5));
      for (let k = 0; k < n; k++) {
        id++;
        const openH = Number(v.open_time.slice(0, 2));
        const closeH = Math.min(22, Number(v.close_time.slice(0, 2)));
        const slots = h(id, 12) < 0.35 ? 2 : 1;
        const startH = openH + 1 + Math.floor(h(id, 13) * Math.max(1, closeH - openH - 1 - slots));
        const start = day + startH * HOUR;
        const end = start + slots * v.slot_minutes * MIN;
        const owner = v.owner_discount_rate !== null && h(id, 14) < 0.18;
        const original = v.price_amt * slots;
        const amount = owner ? Math.round(original * (v.owner_discount_rate ?? 1)) : original;
        let created = start - (2 + Math.floor(h(id, 15) * 70)) * HOUR;
        if (created > NOW - 5 * MIN) created = NOW - (20 + Math.floor(h(id, 20) * 3 * 24 * 60)) * MIN;
        const r = h(id, 16);
        let status: BookingStatus;
        if (start < NOW) status = r < 0.86 ? 'completed' : r < 0.92 ? 'refunded' : r < 0.97 ? 'cancelled' : 'expired';
        else status = r < 0.72 ? 'paid' : r < 0.8 ? 'pending_pay' : r < 0.86 ? 'refunding' : r < 0.94 ? 'cancelled' : 'refunded';
        const ch = h(id, 17) < 0.68 ? 'wechat_app' : 'alipay_app';
        const stamp = new Date(created);
        bookings.push({
          id,
          booking_no: `BK${stamp.getFullYear()}${pad(stamp.getMonth() + 1)}${pad(stamp.getDate())}${pad(stamp.getHours())}${pad(stamp.getMinutes())}${pad(id % 100000, 5)}`,
          venue_id: v.id,
          merchant_id: v.merchant_id,
          user_index: Math.floor(h(id, 18) * db.users.length),
          start_ms: start,
          start_time: iso(start),
          end_time: iso(end),
          court_qty: 1,
          amount_amt: amount,
          original_amt: original,
          discount_type: owner ? 'owner' : 'none',
          status: status === 'pending_pay' && NOW - created > 15 * MIN ? 'expired' : status,
          meetup_id: h(id, 19) < 0.12 ? 400 + (id % 60) : null,
          pay: status === 'expired' ? null : { order_no: `LP${stamp.getTime().toString(36).toUpperCase()}${id}`, channel: ch },
          cancel_deadline: iso(start - 2 * HOUR),
          created_at: iso(created),
        });
      }
    }
  }
  // A couple of fresh unpaid ones (expire 15 min after creation).
  for (const b of bookings.filter((x) => x.start_ms > NOW + DAY).slice(0, 2)) {
    b.status = 'pending_pay';
    b.created_at = iso(NOW - 4 * MIN);
  }
  bookings.sort((a, b) => b.start_ms - a.start_ms);
}

function bookingOut(b: BookingRow): Booking {
  const v = venues.find((x) => x.id === b.venue_id)!;
  const { venue_id: _v, merchant_id: _m, user_index, start_ms: _s, ...rest } = b;
  return { ...clone(rest), venue: { id: v.id, name: v.name }, user: userRef(user_index) };
}

// ---------------------------------------------------------------- statements

interface StatementRow {
  id: number;
  merchant_id: number;
  period_start: number;
  status: StatementStatus;
  confirmed_by: number | null;
  confirmed_at: string | null;
  paid_at: string | null;
}

const BILLED: BookingStatus[] = ['completed', 'paid'];

function periodRows(merchantId: number, from: number) {
  const to = from + 7 * DAY;
  return {
    reds: redemptions.filter((r) => r.merchant_id === merchantId && r.at >= from && r.at < to),
    books: bookings.filter((b) => b.merchant_id === merchantId && b.start_ms >= from && b.start_ms < to && BILLED.includes(b.status)),
  };
}

function statementOut(s: StatementRow): Statement {
  const m = merchants.find((x) => x.id === s.merchant_id)!;
  const { reds, books } = periodRows(s.merchant_id, s.period_start);
  const ok = reds.filter((r) => !r.voided);
  // Drops of one merchant can settle in different directions: the statement carries the net.
  const signed = ok.reduce((sum, r) => sum + signedPrice(r.drop_id), 0);
  const redemptionAmt = Math.abs(signed);
  const dir: Statement['redemption_direction'] = signed < 0 ? 'platform_pays' : 'merchant_pays';
  const bookingAmt = books.reduce((sum, b) => sum + b.amount_amt, 0);
  const commission = Math.round(bookingAmt * m.booking_commission_rate);
  const { year, week } = isoWeek(s.period_start);
  return {
    id: s.id,
    statement_no: `ST${year}W${pad(week)}-${pad(s.merchant_id, 3)}`,
    merchant: mref(s.merchant_id),
    period_start: dayKey(s.period_start),
    period_end: dayKey(s.period_start + 6 * DAY),
    redemption_qty: ok.length,
    voided_qty: reds.length - ok.length,
    redemption_amt: redemptionAmt,
    redemption_direction: dir,
    booking_qty: books.length,
    booking_amt: bookingAmt,
    booking_commission_amt: commission,
    net_amt: signed - (bookingAmt - commission),
    status: s.status,
    confirmed_by: s.confirmed_by,
    confirmed_at: s.confirmed_at,
    paid_at: s.paid_at,
  };
}

function statementLines(s: StatementRow): StatementLine[] {
  const { reds, books } = periodRows(s.merchant_id, s.period_start);
  const lines: (StatementLine & { t: number })[] = [
    ...reds.map((r) => ({
      type: 'redemption' as const,
      ref_no: `RD${r.id}`,
      user: userRef(r.user_index),
      amount_amt: Math.abs(signedPrice(r.drop_id)),
      created_at: iso(r.at),
      voided: r.voided,
      t: r.at,
    })),
    ...books.map((b) => ({ type: 'booking' as const, ref_no: b.booking_no, user: userRef(b.user_index), amount_amt: b.amount_amt, created_at: b.start_time, voided: false, t: b.start_ms })),
  ];
  return lines.sort((a, b) => a.t - b.t).map(({ t: _t, ...l }) => l);
}

/** Merchants that had anything to settle in a week. */
function billableMerchants(from: number): number[] {
  return merchants
    .filter((m) => {
      const { reds, books } = periodRows(m.id, from);
      return reds.length > 0 || books.length > 0;
    })
    .map((m) => m.id);
}

const statements: StatementRow[] = [];
let statementSeq = 0;
for (const w of [3, 2, 1]) {
  const from = THIS_MONDAY - w * 7 * DAY;
  for (const mid of billableMerchants(from)) {
    const status: StatementStatus = w === 3 ? 'paid' : w === 2 ? (mid % 2 ? 'paid' : 'confirmed') : mid === 3 ? 'confirmed' : 'draft';
    const confirmedAt = status === 'draft' ? null : iso(from + (7 + 1) * DAY + 3 * HOUR + mid * 7 * MIN);
    statements.push({
      id: ++statementSeq,
      merchant_id: mid,
      period_start: from,
      status,
      confirmed_by: status === 'draft' ? null : 1,
      confirmed_at: confirmedAt,
      paid_at: status === 'paid' ? iso(from + (7 + 3) * DAY + 5 * HOUR + mid * 11 * MIN) : null,
    });
  }
}

// ---------------------------------------------------------------- shared helpers

function paged<T>(items: T[], q: URLSearchParams) {
  const page = Math.max(1, Number(q.get('page') ?? 1));
  const size = Math.min(100, Math.max(1, Number(q.get('page_size') ?? 20)));
  return { items: items.slice((page - 1) * size, page * size), total: items.length };
}

function merchantOut(m: MerchantRow): Merchant {
  return {
    id: m.id,
    name: m.name,
    type: m.type,
    status: m.status,
    contact_name: m.contact_name,
    contact_phone: maskPhone(m.phone),
    license_images: [...m.license_images],
    booking_commission_rate: m.booking_commission_rate,
    product_commission_rate: m.product_commission_rate,
    venue_count: venues.filter((v) => v.merchant_id === m.id).length,
    drop_count: dropsOfMerchant(m.id).filter((d) => d.status !== 'ended').length,
    today_redemptions: redemptions.filter((r) => r.merchant_id === m.id && r.at >= TODAY && !r.voided).length,
    created_at: m.created_at,
  };
}

const MERCHANT_TYPES: MerchantType[] = ['venue', 'brand', 'store'];
const MERCHANT_STATUSES: MerchantStatus[] = ['partner', 'pending_sign', 'reviewing', 'suspended'];

function merchantInput(b: Record<string, unknown>, base?: MerchantRow): Omit<MerchantRow, 'id' | 'created_at'> {
  const get = (k: string, fallback: unknown) => (k in b ? b[k] : fallback);
  const name = String(get('name', base?.name) ?? '').trim();
  if (!name || name.length > 40) fail(400, 'invalid_body', '商户名称必填，最多 40 字');
  if (merchants.some((x) => x.name === name && x.id !== base?.id)) fail(409, 'conflict', '已有同名商户');
  const type = get('type', base?.type) as MerchantType;
  if (!MERCHANT_TYPES.includes(type)) fail(400, 'invalid_body', '商户类型只能是 venue / brand / store');
  const status = get('status', base?.status ?? 'reviewing') as MerchantStatus;
  if (!MERCHANT_STATUSES.includes(status)) fail(400, 'invalid_body', '合作状态无效');
  const rawPhone = 'contact_phone' in b ? b.contact_phone : undefined;
  let phone = base?.phone ?? null;
  if (rawPhone !== undefined) {
    phone = rawPhone === null || rawPhone === '' ? null : String(rawPhone).trim();
    if (phone !== null && !/^1[3-9]\d{9}$/.test(phone)) fail(400, 'invalid_phone', '联系电话应为 11 位手机号');
  }
  const images = get('license_images', base?.license_images ?? []);
  if (!Array.isArray(images) || images.length > 9 || images.some((u) => typeof u !== 'string' || !IMG_RE.test(u))) fail(400, 'invalid_body', '资质图片最多 9 张，需要是 http(s) 地址');
  const rate = Number(get('booking_commission_rate', base?.booking_commission_rate ?? 0));
  if (!Number.isFinite(rate) || rate < 0 || rate > 1) fail(400, 'invalid_body', '订场佣金比例应在 0–1 之间');
  const prate = Number(get('product_commission_rate', base?.product_commission_rate ?? 0.08));
  if (!Number.isFinite(prate) || prate < 0 || prate > 1) fail(400, 'invalid_body', '商品佣金比例应在 0–1 之间');
  const contact = get('contact_name', base?.contact_name ?? null);
  return {
    name,
    type,
    status,
    contact_name: contact ? String(contact).trim() || null : null,
    phone,
    license_images: images as string[],
    booking_commission_rate: +rate.toFixed(4),
    product_commission_rate: +prate.toFixed(4),
  };
}

function inRange(at: number, from: string | null, to: string | null): boolean {
  if (from && at < new Date(`${from}T00:00:00`).getTime()) return false;
  if (to && at >= new Date(`${to}T00:00:00`).getTime() + DAY) return false;
  return true;
}

/** 总览 todos (M-04). */
export function merchantTodos(): DashboardTodo[] {
  const todos: DashboardTodo[] = [];
  const reviewing = merchants.filter((m) => m.status === 'reviewing').length;
  if (reviewing) todos.push({ type: 'merchant_review', title: `${reviewing} 家商户资质待审核`, count: reviewing, priority: 2, link: '/merchant/merchants?status=reviewing' });
  const refunding = bookings.filter((b) => b.status === 'refunding').length;
  if (refunding) todos.push({ type: 'booking_refund', title: `${refunding} 笔订场退款处理中`, count: refunding, priority: 2, link: '/merchant/bookings?status=refunding' });
  const drafts = statements.filter((s) => s.status === 'draft').length;
  if (drafts) todos.push({ type: 'statement_confirm', title: `${drafts} 张结算单待确认`, count: drafts, priority: 3, link: '/merchant/settlement?status=draft' });
  return todos;
}

// ---------------------------------------------------------------- routes

const STAFF: AdminRole[] = ['admin', 'ops'];

export function merchantRoutes(log: Log): [string, RegExp, Handler][] {
  return [
    // ---- 商户
    ['GET', /^\/merchants$/, (ctx) => {
      requireRole(ctx.role, [...STAFF, 'merchant']);
      const scope = scopeOf(ctx);
      const status = ctx.q.get('status') || '';
      if (status && !MERCHANT_STATUSES.includes(status as MerchantStatus)) fail(400, 'invalid_status', '状态无效');
      const kw = (ctx.q.get('q') || '').trim().toLowerCase();
      const list = merchants
        .filter((m) => (scope === null || m.id === scope) && (!status || m.status === status) && (!kw || m.name.toLowerCase().includes(kw) || (m.contact_name ?? '').includes(kw) || String(m.id) === kw))
        .sort((a, b) => MERCHANT_STATUSES.indexOf(a.status) - MERCHANT_STATUSES.indexOf(b.status) || b.id - a.id)
        .map(merchantOut);
      return paged(list, ctx.q);
    }],
    ['GET', /^\/merchants\/(\d+)$/, (ctx) => {
      requireRole(ctx.role, [...STAFF, 'merchant']);
      const scope = scopeOf(ctx);
      const m = merchants.find((x) => x.id === Number(ctx.m[1]));
      if (!m || (scope !== null && scope !== m.id)) fail(404, 'not_found', '商户不存在');
      return {
        ...merchantOut(m),
        venues: venues.filter((v) => v.merchant_id === m.id).map(venueOut),
        drops: dropsOfMerchant(m.id),
        staff: db.admins.filter((a) => a.role === 'merchant' && staffMerchant.get(a.id) === m.id).map((a) => ({ id: a.id, username: a.username, is_disabled: a.disabled })),
      };
    }],
    ['POST', /^\/merchants$/, ({ body, role, adminId }) => {
      requireRole(role, STAFF);
      if ('product_commission_rate' in body && role !== 'admin') fail(403, 'forbidden', '只有管理员可以改商品佣金');
      const v = merchantInput(body);
      const m: MerchantRow = { id: Math.max(...merchants.map((x) => x.id)) + 1, created_at: new Date().toISOString(), ...v };
      merchants.push(m);
      log(adminId, 'merchant.create', `merchant:${m.id}`, { name: m.name, status: m.status });
      return merchantOut(m);
    }],
    ['PATCH', /^\/merchants\/(\d+)$/, ({ m: mm, body, role, adminId }) => {
      requireRole(role, STAFF);
      if ('product_commission_rate' in body && role !== 'admin') fail(403, 'forbidden', '只有管理员可以改商品佣金');
      const m = merchants.find((x) => x.id === Number(mm[1]));
      if (!m) fail(404, 'not_found', '商户不存在');
      const before = m.status;
      Object.assign(m, merchantInput(body, m));
      log(adminId, 'merchant.update', `merchant:${m.id}`, { fields: Object.keys(body).map((k) => (k === 'contact_phone' ? 'contact_phone(***)' : k)), status_before: before, status: m.status });
      return merchantOut(m);
    }],
    ['POST', /^\/merchants\/(\d+)\/reveal-phone$/, ({ m: mm, role, adminId }) => {
      requireRole(role, ['admin']);
      const m = merchants.find((x) => x.id === Number(mm[1]));
      if (!m) fail(404, 'not_found', '商户不存在');
      if (!m.phone) fail(404, 'not_found', '没有登记联系电话');
      log(adminId, 'merchant.reveal_phone', `merchant:${m.id}`);
      return { phone: m.phone };
    }],
    ['POST', /^\/merchants\/(\d+)\/staff$/, ({ m: mm, body, role, adminId }) => {
      requireRole(role, ['admin']);
      const m = merchants.find((x) => x.id === Number(mm[1]));
      if (!m) fail(404, 'not_found', '商户不存在');
      const username = String(body.username ?? '').trim();
      if (!/^[a-zA-Z0-9_.-]{3,32}$/.test(username)) fail(400, 'invalid_body', '用户名 3–32 位字母、数字、下划线');
      if (String(body.password ?? '').length < 10) fail(400, 'invalid_body', '密码至少 10 位');
      if (db.admins.some((a) => a.username === username)) fail(409, 'conflict', '用户名已存在');
      const a = { id: Math.max(...db.admins.map((x) => x.id)) + 1, username, role: 'merchant' as AdminRole, disabled: false, created_at: new Date().toISOString() };
      db.admins.push(a);
      staffMerchant.set(a.id, m.id);
      log(adminId, 'merchant.staff.create', `admin:${a.id}`, { merchant_id: m.id });
      return {};
    }],

    // ---- 场馆
    ['GET', /^\/venues$/, (ctx) => {
      const { q, role } = ctx;
      requireRole(role, [...STAFF, 'merchant']);
      // V2 第五批 商户自助改场馆: merchant accounts only see their own venues.
      const mid = role === 'merchant' ? String(scopeOf(ctx)) : q.get('merchant_id');
      const sport = q.get('sport') || '';
      const kw = (q.get('q') || '').trim();
      const list = venues
        .filter((v) => (!mid || v.merchant_id === Number(mid)) && (!sport || v.sports.includes(sport as VenueSport)) && (!kw || v.name.includes(kw) || v.address.includes(kw) || v.district.includes(kw)))
        .sort((a, b) => Number(a.is_disabled) - Number(b.is_disabled) || a.id - b.id)
        .map(venueOut);
      return paged(list, q);
    }],
    ['POST', /^\/venues$/, ({ body, role, adminId }) => {
      requireRole(role, STAFF);
      const v: VenueRow = { id: Math.max(...venues.map((x) => x.id)) + 1, qr_version: 1, ...venueInput(body) };
      venues.push(v);
      log(adminId, 'venue.create', `venue:${v.id}`, { name: v.name, merchant_id: v.merchant_id });
      return venueOut(v);
    }],
    ['PATCH', /^\/venues\/(\d+)$/, (ctx) => {
      const { m, body, role, adminId } = ctx;
      requireRole(role, [...STAFF, 'merchant']);
      const scope = scopeOf(ctx);
      const v = venues.find((x) => x.id === Number(m[1]));
      if (!v || (scope !== null && v.merchant_id !== scope)) fail(404, 'not_found', '场馆不存在');
      if (scope !== null) {
        const bad = Object.keys(body).filter((k) => !VENUE_SELF_FIELDS.includes(k));
        if (bad.length) fail(403, 'field_not_allowed', `商户不能修改：${bad.join(', ')}（位置、名称等请联系平台运营）`);
      }
      Object.assign(v, venueInput(body, v));
      log(adminId, 'venue.update', `venue:${v.id}`, { fields: Object.keys(body) });
      return venueOut(v);
    }],
    ['GET', /^\/venues\/(\d+)\/qr$/, ({ m, role }) => {
      requireRole(role, STAFF);
      const v = venues.find((x) => x.id === Number(m[1]));
      if (!v) fail(404, 'not_found', '场馆不存在');
      return qrOf(v);
    }],
    ['POST', /^\/venues\/(\d+)\/qr\/rotate$/, ({ m, role, adminId }) => {
      requireRole(role, STAFF);
      const v = venues.find((x) => x.id === Number(m[1]));
      if (!v) fail(404, 'not_found', '场馆不存在');
      v.qr_version++;
      log(adminId, 'venue.qr_rotate', `venue:${v.id}`);
      return qrOf(v);
    }],
    ['GET', /^\/venues\/(\d+)\/owners$/, ({ m, role }) => {
      requireRole(role, STAFF);
      const v = venues.find((x) => x.id === Number(m[1]));
      if (!v) fail(404, 'not_found', '场馆不存在');
      const items = [];
      for (let w = 0; w < 10; w++) {
        const o = ownerFor(v.id, w);
        if (o) items.push({ week_start: dayKey(THIS_MONDAY - w * 7 * DAY), user: o.user, points: o.points });
      }
      return { items };
    }],

    // ---- 外部占场（开放平台同步过来的已售场地；按日期生成几条演示数据）
    ['GET', /^\/venues\/(\d+)\/blocks$/, (ctx) => {
      requireRole(ctx.role, [...STAFF, 'merchant']);
      const scope = scopeOf(ctx);
      const v = venues.find((x) => x.id === Number(ctx.m[1]));
      if (!v || (scope !== null && v.merchant_id !== scope)) fail(404, 'not_found', '场馆不存在');
      const date = ctx.q.get('date') || '';
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) fail(400, 'invalid_body', 'date 格式应为 YYYY-MM-DD');
      if (!v.bookable) return { items: [] };
      const d = Number(date.slice(8, 10));
      const items = [
        { id: v.id * 100 + d, venue_id: v.id, date, start: '18:00', end: '20:00', court_qty: 1, external_ref: `POS-${8800 + d}`, note: '前台散客', created_at: `${date}T09:12:00+08:00` },
        ...(d % 2 === 0
          ? [{ id: v.id * 100 + d + 50, venue_id: v.id, date, start: '07:00', end: '09:00', court_qty: 2, external_ref: `CLUB-${300 + d}`, note: '俱乐部包场', created_at: `${date}T06:40:00+08:00` }]
          : []),
      ].sort((a, b) => a.start.localeCompare(b.start));
      return { items };
    }],

    // ---- 订场
    ['GET', /^\/bookings$/, (ctx) => {
      requireRole(ctx.role, [...STAFF, 'merchant']);
      const scope = scopeOf(ctx);
      const { q } = ctx;
      const vid = q.get('venue_id');
      const status = q.get('status') || '';
      const date = q.get('date') || '';
      if (date && !/^\d{4}-\d{2}-\d{2}$/.test(date)) fail(400, 'invalid_body', 'date 格式应为 YYYY-MM-DD');
      const list = bookings.filter(
        (b) => (scope === null || b.merchant_id === scope) && (!vid || b.venue_id === Number(vid)) && (!status || b.status === status) && (!date || dayKey(b.start_ms) === date),
      );
      return paged(list.map(bookingOut), q);
    }],
    ['POST', /^\/bookings\/(\d+)\/refund$/, ({ m, body, role, adminId }) => {
      requireRole(role, ['admin']);
      const b = bookings.find((x) => x.id === Number(m[1]));
      if (!b) fail(404, 'not_found', '预订不存在');
      if (b.status !== 'paid' && b.status !== 'completed') fail(409, 'invalid_status', '只有已支付或已完成的预订可以退款');
      const reason = String(body.reason ?? '').trim();
      if (!reason) fail(400, 'invalid_body', '请填写退款原因');
      b.status = 'refunding';
      log(adminId, 'booking.refund', `booking:${b.id}`, { booking_no: b.booking_no, amount_amt: b.amount_amt, reason });
      // The payment channel calls back a moment later.
      setTimeout(() => {
        if (b.status === 'refunding') b.status = 'refunded';
      }, 4000);
      return bookingOut(b);
    }],

    // ---- 核销
    ['POST', /^\/redemptions$/, (ctx) => {
      requireRole(ctx.role, [...STAFF, 'merchant']);
      const scope = scopeOf(ctx);
      const { body } = ctx;
      let coupon: CouponRow | undefined;
      if (typeof body.payload === 'string' && body.payload.trim()) {
        const p = /^LPC\.(\d+)\.(\d{9,11})\.([A-Za-z0-9_-]{4,})$/.exec(body.payload.trim());
        if (!p) fail(400, 'invalid_coupon', '二维码不是圈圈的券码');
        coupon = coupons.find((c) => c.id === Number(p[1]));
        if (!coupon) fail(400, 'invalid_coupon', '券不存在');
        if (Date.now() / 1000 - Number(p[2]) > 60) fail(409, 'coupon_expired', '二维码已过期（60 秒有效），请让顾客刷新后重扫');
      } else if (typeof body.code === 'string' && body.code.trim()) {
        const code = body.code.trim().toUpperCase().replace(/[\s-]/g, '');
        coupon = coupons.find((c) => c.code === code);
        if (!coupon) {
          if (redemptions.some((r) => r.code === code)) fail(409, 'coupon_used', '这张券已经核销过了');
          fail(400, 'invalid_coupon', '券码不存在');
        }
      } else fail(400, 'invalid_body', 'payload 和 code 至少填一个');
      const c = coupon!;
      const d = dropById(c.drop_id);
      if (!d) fail(400, 'invalid_coupon', '券对应的投放不存在');
      if (scope !== null && d.merchant.id !== scope) fail(403, 'wrong_merchant', `这张券属于「${mref(d.merchant.id).name}」，不能在本店核销`);
      if (c.status === 'used') fail(409, 'coupon_used', `这张券已于 ${new Date(c.used_at!).toLocaleString('zh-CN', { hour12: false })} 核销`);
      if (c.status === 'voided') fail(400, 'invalid_coupon', '券已作废');
      if (c.status === 'expired' || c.expires_at < Date.now()) fail(409, 'coupon_expired', '券已过期');
      if (NO_ACTIVITY_TODAY.has(c.user_index)) fail(409, 'no_activity_today', '今天还没有运动记录，运动后再来核销');
      const todayCount = redemptions.filter((r) => r.drop_id === d.id && r.at >= startOfDay(Date.now()) && !r.voided).length;
      if (todayCount >= d.daily_cap) fail(409, 'daily_cap_reached', `「${d.name}」今天的核销已达上限 ${d.daily_cap} 张`);
      const now = Date.now();
      c.status = 'used';
      c.used_at = now;
      const row: RedemptionRow = { id: ++redemptionSeq, coupon_id: c.id, code: c.code, drop_id: d.id, merchant_id: d.merchant.id, user_index: c.user_index, at: now, obtained_at: c.obtained_at, voided: false };
      redemptions.unshift(row);
      log(ctx.adminId, 'redemption.create', `coupon:${c.id}`, { merchant_id: d.merchant.id, by: 'payload' in body ? 'qr' : 'code' });
      return { redemption: { id: row.id, coupon: couponOut(c), user: userRef(c.user_index), store: storeOf(d), created_at: iso(now) } };
    }],
    ['GET', /^\/redemptions$/, (ctx) => {
      requireRole(ctx.role, [...STAFF, 'merchant']);
      const scope = scopeOf(ctx);
      const { q } = ctx;
      const mid = scope ?? (q.get('merchant_id') ? Number(q.get('merchant_id')) : null);
      const from = q.get('from');
      const to = q.get('to');
      for (const x of [from, to]) if (x && !/^\d{4}-\d{2}-\d{2}$/.test(x)) fail(400, 'invalid_body', 'from / to 格式应为 YYYY-MM-DD');
      const list = redemptions.filter((r) => (mid === null || r.merchant_id === mid) && inRange(r.at, from, to));
      const page = paged(list, q);
      return { items: page.items.map(redemptionOut), total: page.total };
    }],

    // ---- 结算
    ['GET', /^\/settlement\/overview$/, (ctx) => {
      requireRole(ctx.role, ['admin', 'merchant']);
      const scope = scopeOf(ctx);
      const n = Math.min(30, Math.max(1, Number(ctx.q.get('days') ?? 7)));
      const days = Array.from({ length: n }, (_, i) => {
        const day = TODAY - (n - 1 - i) * DAY;
        const reds = redemptions.filter((r) => r.at >= day && r.at < day + DAY && (scope === null || r.merchant_id === scope));
        const voided = reds.filter((r) => r.voided).length;
        return {
          date: dayKey(day),
          redemptions: reds.length - voided,
          voided,
          bookings: bookings.filter((b) => b.start_ms >= day && b.start_ms < day + DAY && BILLED.includes(b.status) && (scope === null || b.merchant_id === scope)).length,
        };
      });
      return { days, pending_statements: statements.filter((s) => s.status === 'draft' && (scope === null || s.merchant_id === scope)).length };
    }],
    ['GET', /^\/statements$/, (ctx) => {
      requireRole(ctx.role, ['admin', 'merchant']);
      const scope = scopeOf(ctx);
      const status = ctx.q.get('status') || '';
      if (status && !['draft', 'confirmed', 'paid'].includes(status)) fail(400, 'invalid_status', '状态无效');
      const mid = scope ?? (ctx.q.get('merchant_id') ? Number(ctx.q.get('merchant_id')) : null);
      const list = statements
        .filter((s) => (mid === null || s.merchant_id === mid) && (!status || s.status === status))
        .sort((a, b) => b.period_start - a.period_start || a.merchant_id - b.merchant_id)
        .map(statementOut);
      return paged(list, ctx.q);
    }],
    ['GET', /^\/statements\/(\d+)$/, (ctx) => {
      requireRole(ctx.role, ['admin', 'merchant']);
      const scope = scopeOf(ctx);
      const s = statements.find((x) => x.id === Number(ctx.m[1]));
      if (!s || (scope !== null && s.merchant_id !== scope)) fail(404, 'not_found', '结算单不存在');
      return { ...statementOut(s), lines: statementLines(s) };
    }],
    ['POST', /^\/statements\/(\d+)\/confirm$/, ({ m, role, adminId }) => {
      requireRole(role, ['admin']);
      const s = statements.find((x) => x.id === Number(m[1]));
      if (!s) fail(404, 'not_found', '结算单不存在');
      if (s.status !== 'draft') fail(409, 'invalid_status', '只有待确认的结算单可以确认');
      s.status = 'confirmed';
      s.confirmed_by = adminId;
      s.confirmed_at = new Date().toISOString();
      notifyMerchant(s.merchant_id, statementMessage(s));
      const out = statementOut(s);
      log(adminId, 'statement.confirm', `statement:${s.id}`, { statement_no: out.statement_no, net_amt: out.net_amt });
      return out;
    }],
    ['POST', /^\/statements\/(\d+)\/paid$/, ({ m, role, adminId }) => {
      requireRole(role, ['admin']);
      const s = statements.find((x) => x.id === Number(m[1]));
      if (!s) fail(404, 'not_found', '结算单不存在');
      if (s.status !== 'confirmed') fail(409, 'invalid_status', '结算单确认后才能标记已付款');
      s.status = 'paid';
      s.paid_at = new Date().toISOString();
      notifyMerchant(s.merchant_id, statementMessage(s));
      const out = statementOut(s);
      log(adminId, 'statement.paid', `statement:${s.id}`, { statement_no: out.statement_no, net_amt: out.net_amt });
      return out;
    }],
    ['POST', /^\/statements\/generate$/, ({ body, role, adminId }) => {
      requireRole(role, ['admin']);
      const raw = String(body.period_start ?? '');
      if (!/^\d{4}-\d{2}-\d{2}$/.test(raw)) fail(400, 'invalid_body', 'period_start 格式应为 YYYY-MM-DD');
      const from = new Date(`${raw}T00:00:00`).getTime();
      if (new Date(from).getDay() !== 1) fail(400, 'invalid_period', '结算周期从周一开始');
      if (from + 7 * DAY > NOW) fail(400, 'invalid_period', '这一周还没结束，不能生成结算单');
      if (statements.some((s) => s.period_start === from)) fail(409, 'conflict', '这一周的结算单已经生成过了');
      const ids = billableMerchants(from);
      for (const mid of ids) {
        const s: StatementRow = { id: ++statementSeq, merchant_id: mid, period_start: from, status: 'draft', confirmed_by: null, confirmed_at: null, paid_at: null };
        statements.push(s);
        notifyMerchant(mid, statementMessage(s));
      }
      log(adminId, 'statement.generate', `period:${raw}`, { merchants: ids.length });
      return { generated: ids.length };
    }],
  ];
}

/** 站内信 for a statement in its current status (docs/api/v2-6 「谁收到什么」). */
function statementMessage(s: StatementRow): MessageDraft {
  const out = statementOut(s);
  const week = `第 ${isoWeek(s.period_start).week} 周结算单`;
  const link = `/merchant/settlement?id=${s.id}`;
  if (s.status === 'draft') return { category: 'settlement', level: 'info', title: `${week}已生成，待平台确认`, body: `${out.period_start} 至 ${out.period_end}，核销 ${out.redemption_qty} 张、订场 ${out.booking_qty} 单。`, link };
  if (s.status === 'confirmed') return { category: 'settlement', level: 'success', title: `${week}已确认`, body: '平台已确认金额，线下打款后会再通知你。', link };
  return { category: 'settlement', level: 'success', title: `${week}平台已付款 ${yuanText(Math.abs(out.net_amt))}`, body: '请留意对公账户到账情况。', link };
}

/** A merchant's statements (newest first) as 站内信, for the seeds in mocks/messages.ts. */
export function statementMessagesOf(merchantId: number): { draft: MessageDraft; at: string }[] {
  return statements
    .filter((s) => s.merchant_id === merchantId)
    .sort((a, b) => b.period_start - a.period_start)
    .map((s) => ({ draft: statementMessage(s), at: s.paid_at ?? s.confirmed_at ?? iso(s.period_start + 7 * DAY + 3 * HOUR) }));
}
