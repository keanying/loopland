// Mock of V2 第五批「商户商品与开放平台」管理端 (docs/api/v2-5-商户商品与开放平台.md): 商品、商品订单、官方活动、
// 开放平台应用（调用记录、Webhook 投递）. Merchant accounts (role merchant, `shop` → 跑野运动馆 #2) only see and
// change their own merchant's data; admin / ops see everything, never edit products (403) and only ban them.
// Product reviews go through the 内容审核 queue of mocks/community.ts (task type `product`).
import { ApiError } from '../api/client';
import type { AdminRole, DashboardTodo, ReviewTask } from '../api/types';
import type { Coupon, CouponStatus } from '../api/merchant';
import type {
  EntryStatus,
  OpenApp,
  OpenCall,
  OpenScope,
  Product,
  ProductContent,
  ProductOrder,
  ProductOrderStatus,
  ProductStatus,
  ProductType,
  Promotion,
  PromotionEntry,
  PromotionStatus,
  WebhookDelivery,
} from '../api/commerce';
import * as db from './data';
import { merchantOf, merchants, venues } from './merchant';
import { onReviewDecided, tasks as reviewTasks } from './community';
import { photo } from './images';
import { notifyMerchant, notifyPlatform } from './messages';

type Ctx = { m: RegExpMatchArray; q: URLSearchParams; body: Record<string, unknown>; adminId: number; role: AdminRole };
type Handler = (ctx: Ctx) => unknown;
type Log = (adminId: number, action: string, target: string, detail?: Record<string, unknown>) => void;

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const NOW = Date.now();
const iso = (ms: number) => new Date(ms).toISOString();
const pad = (n: number, w = 2) => String(n).padStart(w, '0');
const dayKey = (ms: number) => {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
};
const clone = <T,>(x: T): T => JSON.parse(JSON.stringify(x)) as T;

function fail(status: number, code: string, message: string): never {
  throw new ApiError(status, code, message);
}
function requireRole(role: AdminRole, allowed: AdminRole[]) {
  if (!allowed.includes(role)) fail(403, 'forbidden', '当前角色没有权限执行此操作');
}
/** Cheap deterministic hash → [0, 1). */
function h(n: number, salt = 0): number {
  let x = (n * 2654435761 + salt * 40503 + 12345) >>> 0;
  x ^= x >>> 13;
  x = Math.imul(x, 0x5bd1e995) >>> 0;
  x ^= x >>> 15;
  return (x >>> 0) / 4294967296;
}
function paged<T>(items: T[], q: URLSearchParams) {
  const page = Math.max(1, Number(q.get('page') ?? 1));
  const size = Math.min(100, Math.max(1, Number(q.get('page_size') ?? 20)));
  return { items: items.slice((page - 1) * size, page * size), total: items.length };
}
const mref = (id: number) => ({ id, name: merchants.find((x) => x.id === id)?.name ?? `商户 ${id}` });
/** null for platform accounts; the bound merchant for merchant accounts. */
function scopeOf(ctx: Ctx): number | null {
  if (ctx.role !== 'merchant') return null;
  const m = merchantOf(ctx.adminId);
  if (m === null) fail(403, 'no_merchant', '这个商户账号还没有绑定商户');
  return m;
}
const STAFF: AdminRole[] = ['admin', 'ops'];

// ---------------------------------------------------------------- products

interface ProductRow extends Omit<Product, 'merchant' | 'venues' | 'promotion' | 'has_pending_changes'> {
  merchant_id: number;
  archived: boolean;
  pending: Partial<ProductContent> | null;
}

const CONTENT_KEYS: (keyof ProductContent)[] = ['title', 'subtitle', 'description', 'images', 'rules'];
const img = (seed: number, caption: string) => photo(seed, caption, 800, 600);

type Seed = [id: number, merchant: number, type: ProductType, title: string, subtitle: string, sports: string[], price: number, original: number | null, extra: Partial<ProductRow>];
const SEEDS: Seed[] = [
  [31, 2, 'package', '羽毛球 2 小时畅打套餐', '含球拍租借', ['badminton'], 6900, 9000, { stock_qty: 163, sold_qty: 37, per_user_limit_qty: 2, allow_promotion: true, venue_ids: [8, 13] }],
  [32, 2, 'package', '篮球半场 2 小时', '工作日白天场', ['basketball'], 12000, 16000, { stock_qty: 80, sold_qty: 20, venue_ids: [8] }],
  [33, 2, 'voucher', '100 元代金券', '全场通用，可叠加馆主折扣', [], 8500, 10000, { stock_qty: null, sold_qty: 126, per_user_limit_qty: 5, allow_promotion: true }],
  [34, 2, 'pass', '羽毛球 10 次卡', '每次 1 小时，含球', ['badminton'], 39900, 50000, { use_qty: 10, valid_days: null, valid_until: dayKey(NOW + 160 * DAY), stock_qty: 50, sold_qty: 0, status: 'reviewing', venue_ids: [8, 13] }],
  [35, 2, 'package', '网球体验课（60 分钟）', '教练一对一，含拍', ['tennis'], 19900, 26000, { stock_qty: 20, sold_qty: 0, status: 'draft', venue_ids: [13] }],
  [36, 2, 'package', '夜场篮球 2 小时', '20:00 以后可用', ['basketball'], 9900, 14000, { stock_qty: 40, sold_qty: 0, status: 'rejected', review_note: '图片里有微信二维码，属于站外引流；去掉后重新提交', venue_ids: [8] }],
  [37, 2, 'pass', '健身房月卡（30 次）', '器械区 + 淋浴', ['gym'], 29900, 45000, { use_qty: 30, valid_days: 45, stock_qty: 30, sold_qty: 9, status: 'off_sale', venue_ids: [8] }],
  [38, 2, 'voucher', '50 元代金券', '', [], 2000, 5000, { stock_qty: 0, sold_qty: 64, status: 'banned', review_note: '门市价虚标：50 元券按 20 元售卖，与实际优惠不符，平台已下架' }],
  [41, 6, 'package', '匹克球 1 小时体验', '含拍和教学', ['pickleball'], 4900, 8000, { stock_qty: 120, sold_qty: 58, allow_promotion: true, venue_ids: [9] }],
  [42, 6, 'pass', '游泳 20 次卡', '50 米恒温泳池', ['swimming'], 59900, 90000, { use_qty: 20, valid_days: 180, stock_qty: null, sold_qty: 31, allow_promotion: true, venue_ids: [10] }],
  [43, 6, 'package', '游泳单次票', '', ['swimming'], 3500, 4500, { stock_qty: null, sold_qty: 0, status: 'reviewing', venue_ids: [10] }],
  [51, 1, 'package', '柠檬茶双人套餐', '运动后补水，两杯大杯', [], 2600, 3600, { stock_qty: 300, sold_qty: 211, per_user_limit_qty: 4, allow_promotion: true }],
  [52, 1, 'voucher', '30 元代金券', '', [], 2500, 3000, { stock_qty: null, sold_qty: 92 }],
  [55, 4, 'package', '咖啡 + 贝果早餐', '晨跑后 7:00–10:00 可用', [], 2900, 4200, { stock_qty: 100, sold_qty: 40, allow_promotion: true }],
  [58, 5, 'package', '攀岩体验 2 小时', '含装备和保护员', ['climbing'], 12800, 16800, { stock_qty: 30, sold_qty: 0, status: 'reviewing' }],
  [60, 7, 'package', '欧包两件套', '', [], 1800, 2600, { stock_qty: 50, sold_qty: 18 }],
];

const DESCRIPTIONS: Record<string, string> = {
  package: '周一至周五可用，节假日通用。到店前可在 App 预约场地，到店出示券码即可使用。',
  voucher: '全场通用（订场、商品、饮料），单次消费可叠加使用多张，不找零。',
  pass: '每次核销用掉 1 次，有效期内用完即可；不限本人使用，可带朋友一起。',
};

const products: ProductRow[] = SEEDS.map(([id, mid, type, title, subtitle, sports, price, original, extra], i) => {
  const created = NOW - (40 - i * 2) * DAY - id * HOUR;
  return {
    id,
    merchant_id: mid,
    type,
    title,
    subtitle: subtitle || null,
    description: DESCRIPTIONS[type],
    images: [img(id, title.slice(0, 8)), img(id + 3, subtitle.slice(0, 8) || '到店核销'), ...(i % 2 ? [img(id + 7, '场馆环境')] : [])],
    sports,
    price_amt: price,
    original_amt: original,
    use_qty: 1,
    valid_days: 30,
    valid_until: null,
    stock_qty: 100,
    sold_qty: 0,
    per_user_limit_qty: 0,
    refundable: type !== 'pass' || id !== 37,
    allow_promotion: false,
    venue_ids: [],
    rules: '到店出示券码，店员扫码核销；节假日需提前 1 天预约场地',
    status: 'on_sale' as ProductStatus,
    review_note: null,
    created_at: iso(created),
    updated_at: iso(created + 2 * DAY),
    archived: false,
    pending: null,
    ...extra,
  };
});
// An on-sale product with a content change waiting for review.
products.find((p) => p.id === 32)!.pending = { title: '篮球半场 2 小时（含饮料）', subtitle: '工作日白天场，送 2 瓶运动饮料', images: [img(32, '篮球半场'), img(91, '运动饮料')] };

let productSeq = 70;

// ---------------------------------------------------------------- promotions

interface PromotionRow extends Omit<Promotion, 'status' | 'product_qty'> {
  /** draft / cancelled are stored; published ones become scheduled / active / ended by time. */
  state: 'draft' | 'published' | 'cancelled';
}

const promotions: PromotionRow[] = [
  { id: 1, title: '国庆跑起来', subtitle: '运动场馆国庆特惠', banner_url: img(201, '国庆跑起来'), description: '国庆 7 天，运动场馆和补给店限时特惠。', starts_at: iso(NOW - 53 * DAY), ends_at: iso(NOW - 46 * DAY), apply_open: false, apply_deadline: null, state: 'published', created_at: iso(NOW - 70 * DAY) },
  { id: 2, title: '冬日暖身季', subtitle: '室内运动 6 折起', banner_url: img(202, '冬日暖身季'), description: '天冷了也要动起来：羽毛球、游泳、匹克球、健身房限时活动价，平台再补贴。', starts_at: iso(NOW - 5 * DAY), ends_at: iso(NOW + 9 * DAY), apply_open: true, apply_deadline: iso(NOW + 4 * DAY), state: 'published', created_at: iso(NOW - 20 * DAY) },
  { id: 3, title: '双 12 运动狂欢', subtitle: '羽毛球、游泳、健身 5 折起', banner_url: img(203, '双 12 运动狂欢'), description: '12 月 12 日当天全场活动价，App 首页横幅推荐。', starts_at: iso(NOW + 18 * DAY), ends_at: iso(NOW + 21 * DAY), apply_open: true, apply_deadline: iso(NOW + 12 * DAY), state: 'published', created_at: iso(NOW - 3 * DAY) },
  { id: 4, title: '元旦新年挑战', subtitle: '新年第一跑', banner_url: null, description: '', starts_at: iso(NOW + 38 * DAY), ends_at: iso(NOW + 42 * DAY), apply_open: false, apply_deadline: null, state: 'draft', created_at: iso(NOW - DAY) },
  { id: 5, title: '周末羽毛球节', subtitle: '', banner_url: null, description: '场馆档期冲突，活动取消。', starts_at: iso(NOW - 12 * DAY), ends_at: iso(NOW - 10 * DAY), apply_open: false, apply_deadline: null, state: 'cancelled', created_at: iso(NOW - 30 * DAY) },
];
let promotionSeq = 10;

function promotionStatus(p: PromotionRow, at = Date.now()): PromotionStatus {
  if (p.state !== 'published') return p.state;
  if (at < Date.parse(p.starts_at)) return 'scheduled';
  if (at < Date.parse(p.ends_at)) return 'active';
  return 'ended';
}

interface EntryRow extends Omit<PromotionEntry, 'product' | 'merchant' | 'promotion'> {
  product_id: number;
}

const entries: EntryRow[] = [];
{
  const add = (id: number, pid: number, prid: number, promo: number, subsidy: number, stock: number | null, sold: number, source: 'platform' | 'merchant', status: EntryStatus, sort: number, note = '', agoH = 48) =>
    entries.push({ id, promotion_id: pid, product_id: prid, promo_price_amt: promo, platform_subsidy_amt: subsidy, promo_stock_qty: stock, promo_sold_qty: sold, sort_no: sort, source, status, note: note || null, created_at: iso(NOW - agoH * HOUR), decided_at: status.startsWith('pending') ? null : iso(NOW - (agoH - 6) * HOUR) });
  add(40, 2, 31, 4900, 500, 100, 20, 'platform', 'active', 0, '', 120);
  add(41, 2, 33, 7900, 300, 50, 0, 'platform', 'pending_merchant', 3, '', 20);
  add(42, 2, 41, 3900, 0, 80, 26, 'merchant', 'active', 1, '', 110);
  add(43, 2, 51, 2600, 0, null, 41, 'platform', 'active', 2, '', 100);
  add(44, 2, 55, 1990, 0, 60, 0, 'merchant', 'pending_platform', 0, '', 9);
  add(45, 2, 42, 49900, 0, 30, 0, 'merchant', 'pending_platform', 0, '', 30);
  add(46, 3, 32, 8800, 0, 40, 0, 'merchant', 'pending_platform', 0, '', 26);
  add(47, 3, 41, 2900, 500, 100, 0, 'platform', 'pending_merchant', 0, '', 40);
  add(48, 1, 31, 5900, 0, 50, 50, 'merchant', 'active', 0, '', 60 * 24);
  add(49, 1, 33, 7500, 0, 100, 12, 'platform', 'withdrawn', 1, '', 58 * 24);
  add(50, 1, 52, 1990, 0, 100, 0, 'merchant', 'rejected', 2, '活动价低于成本价的 50%，请调整后再报', 59 * 24);
}
let entrySeq = 60;

const LIVE_ENTRY: EntryStatus[] = ['active', 'pending_merchant', 'pending_platform'];

function productLive(p: ProductRow): boolean {
  const m = merchants.find((x) => x.id === p.merchant_id);
  return !p.archived && p.status !== 'banned' && m?.status !== 'suspended';
}

/** The entry giving a product its current activity price (if any). */
function liveEntry(p: ProductRow): EntryRow | undefined {
  if (!productLive(p)) return undefined;
  return entries.find((e) => {
    const pr = promotions.find((x) => x.id === e.promotion_id)!;
    return e.product_id === p.id && e.status === 'active' && promotionStatus(pr) === 'active' && (e.promo_stock_qty === null || e.promo_sold_qty < e.promo_stock_qty);
  });
}

function productOut(p: ProductRow): Product {
  const e = liveEntry(p);
  const pr = e ? promotions.find((x) => x.id === e.promotion_id)! : null;
  const { merchant_id, archived: _a, pending, ...rest } = p;
  return {
    ...clone(rest),
    merchant: mref(merchant_id),
    venues: p.venue_ids.map((id) => ({ id, name: venues.find((v) => v.id === id)?.name ?? `场馆 ${id}` })),
    promotion: e && pr ? { id: pr.id, title: pr.title, promo_price_amt: e.promo_price_amt, ends_at: pr.ends_at, promo_left_qty: e.promo_stock_qty === null ? null : e.promo_stock_qty - e.promo_sold_qty } : null,
    has_pending_changes: !!pending,
  };
}

function promotionOut(p: PromotionRow): Promotion {
  const { state: _s, ...rest } = p;
  return { ...clone(rest), status: promotionStatus(p), product_qty: entries.filter((e) => e.promotion_id === p.id && e.status === 'active').length };
}

function entryOut(e: EntryRow): PromotionEntry {
  const p = products.find((x) => x.id === e.product_id)!;
  const pr = promotions.find((x) => x.id === e.promotion_id)!;
  const { product_id: _p, ...rest } = e;
  return {
    ...clone(rest),
    product: productOut(p),
    merchant: mref(p.merchant_id),
    promotion: { id: pr.id, title: pr.title, starts_at: pr.starts_at, ends_at: pr.ends_at, status: promotionStatus(pr) },
  };
}

// ---------------------------------------------------------------- review (内容审核 queue, task type product)

const BLOCK_WORDS = ['微信', 'VX', 'vx', '加V', '二维码', 'QQ'];
const REVIEW_WORDS = ['最低价', '全网', '第一', '保证', '100%', '无效退款'];
let reviewSeq = 9000;

function contentText(c: Partial<ProductContent>): string {
  return [c.title, c.subtitle, c.description, c.rules ? `使用规则：${c.rules}` : ''].filter(Boolean).join('\n');
}

function score(text: string, p: ProductRow): { score: number; reasons: string[] } {
  const reasons: string[] = [];
  let s = 12;
  for (const w of BLOCK_WORDS) if (text.includes(w)) {
    reasons.push(`命中拦截词「${w}」（站外引流）`);
    s = Math.max(s, 86);
  }
  for (const w of REVIEW_WORDS) if (text.includes(w)) {
    reasons.push(`命中审核词「${w}」（广告法极限用语）`);
    s = Math.max(s, 55);
  }
  if (p.original_amt && p.price_amt < p.original_amt * 0.4) {
    reasons.push(`售价不到门市价的 40%（${(p.price_amt / 100).toFixed(2)} / ${(p.original_amt / 100).toFixed(2)}），可能门市价虚标`);
    s = Math.max(s, 48);
  }
  return { score: s, reasons };
}

function pushTask(p: ProductRow, content: Partial<ProductContent>, risk: { score: number; reasons: string[] }, isChange: boolean, agoMs = 0) {
  const m = mref(p.merchant_id);
  reviewTasks.push({
    id: ++reviewSeq,
    target_type: 'product',
    target_id: p.id,
    user: { id: m.id, nickname: m.name },
    text: contentText(content),
    images: content.images ?? p.images,
    risk_score: risk.score,
    risk_reasons: risk.reasons,
    report_count: 0,
    status: 'pending',
    reject_reason: null,
    reviewer: null,
    reviewed_at: null,
    created_at: iso(Date.now() - agoMs),
    ai: {
      risk_score: Math.min(95, risk.score + 4),
      labels: risk.score >= 70 ? ['contact'] : risk.score >= 40 ? ['ad'] : [],
      reason: risk.score >= 70 ? '图片或文字含站外联系方式' : risk.score >= 40 ? '价格或用语可能夸大，建议核实门市价' : '商品描述正常',
      confidence: 0.78,
      suggestion: risk.score >= 70 ? 'reject' : risk.score >= 40 ? 'review' : 'approve',
      model_name: 'mock-moderation',
    },
    merchant: m,
    product: { id: p.id, type: p.type, price_amt: p.price_amt, original_amt: p.original_amt, is_change: isChange },
  });
}

function contentOf(p: ProductRow): ProductContent {
  return { title: p.title, subtitle: p.subtitle, description: p.description, images: p.images, rules: p.rules };
}

// Seed tasks: products already waiting for manual review.
for (const p of products) {
  if (p.status === 'reviewing') pushTask(p, contentOf(p), score(contentText(contentOf(p)), p).score > 40 ? score(contentText(contentOf(p)), p) : { score: 46, reasons: ['新商户首个商品，抽检人工复核'] }, false, (p.id % 7) * HOUR + 20 * MIN);
  if (p.pending) pushTask(p, { ...contentOf(p), ...p.pending }, { score: 52, reasons: ['在售商品修改了标题和图片'] }, true, 3 * HOUR);
}

onReviewDecided((t: ReviewTask, approve: boolean, reason: string) => {
  if (t.target_type !== 'product') return;
  const p = products.find((x) => x.id === t.target_id);
  if (!p) return;
  const link = `/merchant/products?id=${p.id}`;
  if (t.product?.is_change) {
    if (approve && p.pending) Object.assign(p, p.pending);
    p.pending = null;
    p.review_note = approve ? null : `修改未通过：${reason}`;
    notifyMerchant(p.merchant_id, approve ? { category: 'product', level: 'success', title: `商品「${p.title}」的修改已生效`, link } : { category: 'product', level: 'warning', title: `商品「${p.title}」的修改未通过：${reason}`, body: '旧内容继续在售。', link });
  } else if (p.status === 'reviewing') {
    p.status = approve ? 'on_sale' : 'rejected';
    p.review_note = approve ? null : reason;
    notifyMerchant(p.merchant_id, approve ? { category: 'product', level: 'success', title: `商品「${p.title}」审核通过，已上架`, body: '可在「商品」里查看。', link } : { category: 'product', level: 'warning', title: `商品「${p.title}」未通过审核：${reason}`, body: '修改后可以重新提交。', link });
  }
  p.updated_at = new Date().toISOString();
});

/** Moderation on submit / content change: block → rejected, review → manual queue, else auto-approved. */
function moderate(p: ProductRow, content: Partial<ProductContent>, isChange: boolean): 'approved' | 'rejected' | 'reviewing' {
  const r = score(contentText(content), p);
  const link = `/merchant/products?id=${p.id}`;
  const name = String(content.title ?? p.title);
  if (r.score >= 70) {
    if (isChange) {
      p.pending = null;
      p.review_note = `修改未通过：${r.reasons[0]}`;
    } else {
      p.status = 'rejected';
      p.review_note = r.reasons.join('；');
    }
    notifyMerchant(p.merchant_id, { category: 'product', level: 'warning', title: isChange ? `商品「${p.title}」的修改未通过：${r.reasons[0]}` : `商品「${name}」未通过审核：${r.reasons[0]}`, body: '修改后可以重新提交。', link });
    return 'rejected';
  }
  if (r.score >= 40) {
    if (!isChange) p.status = 'reviewing';
    p.review_note = null;
    pushTask(p, content, r, isChange);
    notifyPlatform({ category: 'review', level: 'info', title: `商户「${mref(p.merchant_id).name}」提交了商品「${name}」，待审核`, link: '/review?type=product' });
    return 'reviewing';
  }
  if (isChange) {
    Object.assign(p, p.pending);
    p.pending = null;
  } else p.status = 'on_sale';
  p.review_note = null;
  notifyMerchant(p.merchant_id, { category: 'product', level: 'success', title: isChange ? `商品「${p.title}」的修改已生效` : `商品「${p.title}」审核通过，已上架`, body: '可在「商品」里查看。', link });
  return 'approved';
}

// ---------------------------------------------------------------- input validation

const TYPES: ProductType[] = ['package', 'voucher', 'pass'];
const IMG_RE = /^(https?:\/\/|\/|data:image\/)/;

function productInput(b: Record<string, unknown>, merchantId: number, base?: ProductRow): Omit<ProductRow, 'id' | 'merchant_id' | 'status' | 'review_note' | 'sold_qty' | 'created_at' | 'updated_at' | 'archived' | 'pending'> {
  const get = <K extends keyof ProductRow>(k: K): unknown => (k in b ? b[k as string] : base ? base[k] : undefined);
  const type = get('type') as ProductType;
  if (!TYPES.includes(type)) fail(400, 'invalid_request', '商品类型只能是 package / voucher / pass');
  if (base && type !== base.type && base.sold_qty > 0) fail(400, 'invalid_request', '已售出的商品不能改类型');
  const title = String(get('title') ?? '').trim();
  if (title.length < 2 || title.length > 40) fail(400, 'invalid_request', '标题 2–40 字');
  const opt = (k: 'subtitle' | 'description' | 'rules', max: number) => {
    const v = get(k);
    const s = v === null || v === undefined ? '' : String(v).trim();
    if (s.length > max) fail(400, 'invalid_request', `${k} 最多 ${max} 字`);
    return s || null;
  };
  const images = get('images');
  if (!Array.isArray(images) || images.length < 1 || images.length > 9 || images.some((u) => typeof u !== 'string' || !IMG_RE.test(u))) fail(400, 'invalid_request', '图片 1–9 张，需要是上传后得到的地址');
  const price = Number(get('price_amt'));
  if (!Number.isInteger(price) || price < 1 || price > 1_000_000) fail(400, 'invalid_request', '售价 0.01–10000 元');
  const o = get('original_amt');
  const original = o === null || o === undefined || o === '' ? null : Number(o);
  if (original !== null && (!Number.isInteger(original) || original < price)) fail(400, 'invalid_request', '门市价须不低于售价');
  const useQty = type === 'pass' ? Number(get('use_qty')) : 1;
  if (type === 'pass' && (!Number.isInteger(useQty) || useQty < 2 || useQty > 100)) fail(400, 'invalid_request', '次卡次数 2–100');
  const vd = get('valid_days');
  const vu = get('valid_until');
  const validDays = vd === null || vd === undefined || vd === '' ? null : Number(vd);
  const validUntil = vu === null || vu === undefined || vu === '' ? null : String(vu);
  if ((validDays === null) === (validUntil === null)) fail(400, 'invalid_request', '有效期二选一：购买后天数或固定截止日');
  if (validDays !== null && (!Number.isInteger(validDays) || validDays < 1 || validDays > 365)) fail(400, 'invalid_request', '有效天数 1–365');
  if (validUntil !== null && (!/^\d{4}-\d{2}-\d{2}$/.test(validUntil) || validUntil < dayKey(Date.now()))) fail(400, 'invalid_request', '截止日期格式 YYYY-MM-DD，且不能早于今天');
  const st = get('stock_qty');
  const stock = st === null || st === undefined || st === '' ? null : Number(st);
  if (stock !== null && (!Number.isInteger(stock) || stock < 0)) fail(400, 'invalid_request', '库存须为非负整数，不限填 null');
  const limit = Number(get('per_user_limit_qty') ?? 0);
  if (!Number.isInteger(limit) || limit < 0 || limit > 99) fail(400, 'invalid_request', '每人限购 0–99（0 = 不限）');
  const vids = get('venue_ids') ?? [];
  if (!Array.isArray(vids) || vids.some((id) => !venues.some((v) => v.id === Number(id) && v.merchant_id === merchantId))) fail(400, 'invalid_request', '适用门店只能选本商户的场馆');
  const sports = get('sports') ?? [];
  return {
    type,
    title,
    subtitle: opt('subtitle', 40),
    description: opt('description', 1000),
    images: images as string[],
    sports: Array.isArray(sports) ? (sports as string[]) : [],
    price_amt: price,
    original_amt: original,
    use_qty: useQty,
    valid_days: validDays,
    valid_until: validUntil,
    stock_qty: stock,
    per_user_limit_qty: limit,
    refundable: get('refundable') !== false,
    allow_promotion: get('allow_promotion') === true,
    venue_ids: (vids as unknown[]).map(Number),
    rules: opt('rules', 500),
  };
}

// ---------------------------------------------------------------- product orders

interface CouponRow {
  id: number;
  code: string;
  status: CouponStatus;
  uses_left: number;
  used_at: number | null;
  used_store: string | null;
}
interface OrderRow extends Omit<ProductOrder, 'product' | 'merchant' | 'coupons' | 'user'> {
  product_id: number;
  merchant_id: number;
  user_index: number;
  coupon_rows: CouponRow[];
  created_ms: number;
}

const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const codeFor = (n: number) => Array.from({ length: 8 }, (_, k) => CODE_CHARS[Math.floor(h(n, k + 900) * CODE_CHARS.length)]).join('');

const orders: OrderRow[] = [];
{
  let id = 120;
  let couponId = 400000;
  const sellable = products.filter((p) => p.sold_qty > 0);
  for (let k = 0; k < 96; k++) {
    const p = sellable[Math.floor(h(k, 1) * sellable.length)];
    id++;
    const created = NOW - Math.floor(h(k, 2) * 26 * DAY) - 20 * MIN;
    const qty = h(k, 3) < 0.72 ? 1 : h(k, 4) < 0.7 ? 2 : 3;
    const e = entries.find((x) => x.product_id === p.id && x.status === 'active' && promotionStatus(promotions.find((pr) => pr.id === x.promotion_id)!, created) === 'active');
    const unit = e ? e.promo_price_amt : p.price_amt;
    const r = h(k, 5);
    let status: ProductOrderStatus = r < 0.5 ? 'paid' : r < 0.78 ? 'completed' : r < 0.86 ? 'refunded' : r < 0.94 ? 'cancelled' : 'paid';
    if (k < 3) status = 'pending';
    if (k === 5) status = 'refunding';
    const stamp = new Date(status === 'pending' ? NOW - (k + 1) * 3 * MIN : created);
    const rows: CouponRow[] = [];
    const store = venues.find((v) => v.id === (p.venue_ids[0] ?? venues.find((x) => x.merchant_id === p.merchant_id)?.id))?.name ?? mref(p.merchant_id).name;
    if (status !== 'pending' && status !== 'cancelled') {
      for (let c = 0; c < qty; c++) {
        couponId++;
        const used = status === 'completed' || (status === 'paid' && c > 0 && h(k * 10 + c, 6) < 0.5);
        const st: CouponStatus = status === 'refunded' ? 'refunded' : used ? 'used' : 'unused';
        const usesLeft = p.type === 'pass' ? (st === 'used' ? 0 : st === 'unused' ? Math.max(1, p.use_qty - Math.floor(h(k, c + 7) * p.use_qty)) : p.use_qty) : st === 'unused' ? 1 : 0;
        rows.push({ id: couponId, code: codeFor(couponId), status: st, uses_left: usesLeft, used_at: st === 'used' ? created + (1 + Math.floor(h(k, c) * 4)) * DAY : null, used_store: st === 'used' ? store : null });
      }
    }
    orders.push({
      id,
      order_no: `PO${stamp.getFullYear()}${pad(stamp.getMonth() + 1)}${pad(stamp.getDate())}${pad(stamp.getHours())}${pad(stamp.getMinutes())}${pad(stamp.getSeconds())}${pad(id % 1000, 3)}`,
      product_id: p.id,
      merchant_id: p.merchant_id,
      user_index: Math.floor(h(k, 8) * db.users.length),
      qty,
      unit_price_amt: unit,
      amount_amt: unit * qty,
      refund_amt: status === 'refunded' ? unit * qty : 0,
      promotion: e ? { id: e.promotion_id, title: promotions.find((pr) => pr.id === e.promotion_id)!.title } : null,
      status,
      pay_expires_at: status === 'pending' ? iso(NOW + (15 - k * 4) * MIN) : null,
      paid_at: status === 'pending' || status === 'cancelled' ? null : iso(created + 40_000),
      created_at: iso(status === 'pending' ? NOW - (k + 1) * 3 * MIN : created),
      created_ms: status === 'pending' ? NOW - (k + 1) * 3 * MIN : created,
      coupon_rows: rows,
    });
  }
  orders.sort((a, b) => b.created_ms - a.created_ms);
}

function couponOut(o: OrderRow, p: ProductRow, c: CouponRow): Coupon {
  const obtained = Date.parse(o.paid_at ?? o.created_at);
  const expires = p.valid_until ? Date.parse(`${p.valid_until}T23:59:59+08:00`) : obtained + (p.valid_days ?? 30) * DAY;
  return {
    id: c.id,
    code: c.code,
    perk: { title: p.title, description: p.subtitle ?? '', value_text: `¥${(o.unit_price_amt / 100).toFixed(o.unit_price_amt % 100 ? 2 : 0)}`, valid_days: p.valid_days ?? 0, rules: p.rules ?? '' },
    merchant: mref(p.merchant_id),
    source: { type: 'product', product_id: p.id, order_id: o.id, name: p.title },
    status: c.status === 'unused' && expires < Date.now() ? 'expired' : c.status,
    obtained_at: iso(obtained),
    expires_at: iso(expires),
    used_at: c.used_at ? iso(c.used_at) : null,
    used_store: c.used_store,
    uses_total: p.use_qty,
    uses_left: c.uses_left,
  };
}

function orderOut(o: OrderRow): ProductOrder {
  const p = products.find((x) => x.id === o.product_id)!;
  const u = db.users[o.user_index % db.users.length];
  const { product_id: _p, merchant_id, user_index: _u, coupon_rows, created_ms: _c, ...rest } = o;
  return {
    ...clone(rest),
    product: { id: p.id, title: p.title, type: p.type, image: p.images[0] ?? null },
    merchant: mref(merchant_id),
    coupons: coupon_rows.map((c) => couponOut(o, p, c)),
    user: { id: u.id, nickname: u.nickname },
  };
}

// ---------------------------------------------------------------- open apps

interface AppRow extends Omit<OpenApp, 'merchant'> {
  merchant_id: number;
  secret: string;
}

const hex = (n: number) => Array.from({ length: n }, () => '0123456789abcdef'[Math.floor(Math.random() * 16)]).join('');
const appIdChars = 'abcdefghjkmnpqrstuvwxyz23456789';
const newAppId = () => 'lpa_' + Array.from({ length: 8 }, () => appIdChars[Math.floor(Math.random() * appIdChars.length)]).join('');

const apps: AppRow[] = [
  { id: 3, merchant_id: 2, app_id: 'lpa_7f3k2m9x', name: '收银系统', scopes: ['products', 'orders', 'redemptions'], ip_allowlist: ['203.0.113.10', '203.0.113.11'], webhook_url: 'https://pos.example.com/loopland/webhook', webhook_events: ['product_order.paid', 'product_order.refunded', 'redemption.created'], status: 'active', last_used_at: iso(NOW - 3 * MIN), created_at: iso(NOW - 26 * DAY), secret: hex(32) },
  { id: 4, merchant_id: 2, app_id: 'lpa_q8w2e7r1', name: '自有订场系统', scopes: ['bookings', 'venues'], ip_allowlist: [], webhook_url: 'https://booking.paoye.example/hooks/loopland', webhook_events: ['booking.paid', 'booking.cancelled', 'booking.refunded'], status: 'active', last_used_at: iso(NOW - 41 * MIN), created_at: iso(NOW - 12 * DAY), secret: hex(32) },
  { id: 5, merchant_id: 2, app_id: 'lpa_c4n9v6b2', name: 'ERP 对账', scopes: ['statements', 'orders'], ip_allowlist: ['198.51.100.0/24'], webhook_url: null, webhook_events: [], status: 'disabled', last_used_at: iso(NOW - 9 * DAY), created_at: iso(NOW - 40 * DAY), secret: hex(32) },
  { id: 1, merchant_id: 6, app_id: 'lpa_m2x8k4p7', name: '健身中心会员系统', scopes: ['products', 'orders', 'redemptions', 'venues', 'statements'], ip_allowlist: ['192.0.2.20'], webhook_url: 'https://crm.example.org/api/loopland', webhook_events: ['product_order.paid', 'redemption.created', 'statement.created'], status: 'active', last_used_at: iso(NOW - 2 * HOUR), created_at: iso(NOW - 33 * DAY), secret: hex(32) },
];
let appSeq = 10;
const MAX_APPS = 5;
const SCOPES: OpenScope[] = ['products', 'orders', 'bookings', 'redemptions', 'statements', 'venues', 'promotions'];
const EVENTS = ['product.reviewed', 'promotion_entry.invited', 'promotion_entry.approved', 'promotion_entry.rejected', 'promotion_entry.removed', 'product_order.paid', 'product_order.refunded', 'booking.paid', 'booking.cancelled', 'booking.refunded', 'redemption.created', 'redemption.voided', 'statement.created'];
const IP_RE = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}(\/([12]?\d|3[0-2]))?$/;

function appOut(a: AppRow): OpenApp {
  const { merchant_id, secret: _s, ...rest } = a;
  return { ...clone(rest), merchant: mref(merchant_id) };
}

function appInput(b: Record<string, unknown>, base?: AppRow): Pick<AppRow, 'name' | 'scopes' | 'ip_allowlist' | 'webhook_url' | 'webhook_events'> {
  const get = (k: keyof AppRow) => (k in b ? b[k] : base?.[k]);
  const name = String(get('name') ?? '').trim();
  if (!name || name.length > 30) fail(400, 'invalid_request', '应用名称 1–30 字');
  const scopes = get('scopes');
  if (!Array.isArray(scopes) || !scopes.length || scopes.some((s) => !SCOPES.includes(s as OpenScope))) fail(400, 'invalid_request', '至少选一个接口权限');
  const ips = get('ip_allowlist') ?? [];
  if (!Array.isArray(ips) || ips.length > 20 || ips.some((x) => typeof x !== 'string' || !IP_RE.test(x))) fail(400, 'invalid_request', 'IP 白名单最多 20 条，每条为 IPv4 或 CIDR');
  const url = get('webhook_url');
  const webhook = url ? String(url).trim() : null;
  if (webhook && !/^https:\/\/[^\s/]+\.[^\s]+$/.test(webhook)) fail(400, 'invalid_request', 'Webhook 地址须为 https');
  const events = get('webhook_events') ?? [];
  if (!Array.isArray(events) || events.some((e) => !EVENTS.includes(String(e)))) fail(400, 'invalid_request', 'Webhook 事件取值见文档');
  if (events.length && !webhook) fail(400, 'invalid_request', '订阅事件需要先填 Webhook 地址');
  return { name, scopes: scopes as OpenScope[], ip_allowlist: ips as string[], webhook_url: webhook, webhook_events: events as string[] };
}

const PATHS: Record<OpenScope, [string, string][]> = {
  products: [['GET', '/open/v1/products'], ['PUT', '/open/v1/products/31/stock'], ['PATCH', '/open/v1/products/33']],
  orders: [['GET', '/open/v1/product-orders'], ['GET', '/open/v1/product-orders/141']],
  redemptions: [['POST', '/open/v1/coupons/lookup'], ['POST', '/open/v1/redemptions'], ['GET', '/open/v1/redemptions']],
  bookings: [['GET', '/open/v1/bookings'], ['GET', '/open/v1/bookings/318']],
  venues: [['GET', '/open/v1/venues/8/slots'], ['POST', '/open/v1/venues/8/blocks'], ['DELETE', '/open/v1/venues/8/blocks/52']],
  statements: [['GET', '/open/v1/statements'], ['GET', '/open/v1/statements/7']],
  promotions: [['GET', '/open/v1/promotions'], ['POST', '/open/v1/promotions/2/apply']],
};

const calls = new Map<number, OpenCall[]>();
const deliveries = new Map<number, WebhookDelivery[]>();
let callSeq = 1;
let deliverySeq = 1;
{
  for (const a of apps) {
    const list: OpenCall[] = [];
    const n = a.status === 'disabled' ? 6 : a.id === 4 ? 46 : 78;
    const last = a.last_used_at ? Date.parse(a.last_used_at) : NOW;
    for (let k = 0; k < n; k++) {
      const scope = a.scopes[Math.floor(h(a.id * 100 + k, 1) * a.scopes.length)];
      const [method, path] = PATHS[scope][Math.floor(h(a.id * 100 + k, 2) * PATHS[scope].length)];
      const r = h(a.id * 100 + k, 3);
      const err: [number, string | null] = a.status === 'disabled' && k < 2 ? [403, 'app_disabled'] : r < 0.9 ? [200, null] : r < 0.94 ? [401, 'invalid_signature'] : r < 0.96 ? [401, 'timestamp_expired'] : r < 0.98 ? [404, 'not_found'] : [429, 'rate_limited'];
      list.push({
        id: callSeq++,
        method,
        path,
        status_code: method === 'POST' && err[0] === 200 ? 201 : method === 'DELETE' && err[0] === 200 ? 204 : err[0],
        error_code: err[1],
        latency_ms: 18 + Math.floor(h(a.id * 100 + k, 4) * 160),
        ip: a.ip_allowlist[0]?.replace(/\/\d+$/, '').replace(/\.0$/, '.17') ?? '198.51.100.42',
        created_at: iso(last - k * (a.status === 'disabled' ? 4 * HOUR : 1.9 * HOUR) - Math.floor(h(k, 5) * 30 * MIN)),
      });
    }
    calls.set(a.id, list);

    const dl: WebhookDelivery[] = [];
    if (a.webhook_url) {
      for (let k = 0; k < 26; k++) {
        const ev = a.webhook_events[Math.floor(h(a.id * 50 + k, 6) * a.webhook_events.length)];
        const at = NOW - k * 2.7 * HOUR - 6 * MIN;
        const failing = a.id === 4 && k < 4;
        const retrying = a.id === 4 && k === 0;
        dl.push({
          id: deliverySeq++,
          event_id: `evt_01JD${Math.floor(h(a.id * 50 + k, 7) * 1e10).toString(36).toUpperCase().padStart(7, '0')}`,
          event_type: ev,
          status: retrying ? 'pending' : failing ? 'failed' : 'succeeded',
          attempt_qty: retrying ? 3 : failing ? 6 : h(k, 8) < 0.1 ? 2 : 1,
          last_status_code: failing ? 502 : 200,
          last_error: failing ? '对方返回 502 Bad Gateway' : null,
          next_retry_at: retrying ? iso(NOW + 24 * MIN) : null,
          created_at: iso(at),
        });
      }
    }
    deliveries.set(a.id, dl);
  }
}

function findApp(ctx: Ctx, id: number): AppRow {
  const scope = scopeOf(ctx);
  const a = apps.find((x) => x.id === id);
  if (!a || (scope !== null && a.merchant_id !== scope)) fail(404, 'not_found', '应用不存在');
  return a;
}

// ---------------------------------------------------------------- 总览 todos

export function commerceTodos(role: AdminRole): DashboardTodo[] {
  const todos: DashboardTodo[] = [];
  const reviewing = reviewTasks.filter((t) => t.target_type === 'product' && t.status === 'pending').length;
  if (reviewing) todos.push({ type: 'product_review', title: `${reviewing} 个商品待人工审核`, count: reviewing, priority: 2, link: '/review?type=product' });
  const applies = entries.filter((e) => e.status === 'pending_platform').length;
  if (applies) todos.push({ type: 'promotion_apply', title: `${applies} 条官方活动报名待审核`, count: applies, priority: 2, link: '/merchant/promotions?entry_status=pending_platform' });
  if (role === 'admin') {
    const failedApps = apps.filter((a) => (deliveries.get(a.id) ?? []).some((d) => d.status === 'failed' && Date.parse(d.created_at) > Date.now() - DAY));
    if (failedApps.length) {
      const only = failedApps.length === 1 ? failedApps[0].merchant_id : null;
      todos.push({ type: 'webhook_failed', title: `${failedApps.length} 个开放平台应用 Webhook 投递失败`, count: failedApps.length, priority: 3, link: only ? `/merchant/merchants?id=${only}` : '/merchant/merchants' });
    }
  }
  return todos;
}

// ---------------------------------------------------------------- routes

export function commerceRoutes(log: Log): [string, RegExp, Handler][] {
  const findProduct = (ctx: Ctx, id: number): ProductRow => {
    const scope = scopeOf(ctx);
    const p = products.find((x) => x.id === id && !x.archived);
    if (!p || (scope !== null && p.merchant_id !== scope)) fail(404, 'not_found', '商品不存在');
    return p;
  };
  const touch = (p: ProductRow) => {
    p.updated_at = new Date().toISOString();
  };

  return [
    // ---- 商品
    ['GET', /^\/products$/, (ctx) => {
      requireRole(ctx.role, [...STAFF, 'merchant']);
      const scope = scopeOf(ctx);
      const { q } = ctx;
      const mid = scope ?? (q.get('merchant_id') ? Number(q.get('merchant_id')) : null);
      const status = q.get('status') || '';
      const kw = (q.get('q') || '').trim();
      const ap = q.get('allow_promotion');
      const order: ProductStatus[] = ['reviewing', 'on_sale', 'draft', 'rejected', 'off_sale', 'banned'];
      const list = products
        .filter((p) => !p.archived && (mid === null || p.merchant_id === mid) && (!status || p.status === status) && (!kw || p.title.includes(kw) || String(p.id) === kw) && (ap === null || ap === '' || p.allow_promotion === (ap === 'true')))
        .sort((a, b) => (scope === null ? 0 : order.indexOf(a.status) - order.indexOf(b.status)) || Date.parse(b.updated_at) - Date.parse(a.updated_at))
        .map(productOut);
      return paged(list, q);
    }],
    ['GET', /^\/products\/(\d+)$/, (ctx) => {
      requireRole(ctx.role, [...STAFF, 'merchant']);
      const p = findProduct(ctx, Number(ctx.m[1]));
      return { ...productOut(p), pending: p.pending ? clone(p.pending) : null };
    }],
    ['POST', /^\/products$/, (ctx) => {
      requireRole(ctx.role, ['merchant']);
      const mid = scopeOf(ctx)!;
      const v = productInput(ctx.body, mid);
      const now = new Date().toISOString();
      const p: ProductRow = { id: ++productSeq, merchant_id: mid, ...v, status: 'draft', review_note: null, sold_qty: 0, created_at: now, updated_at: now, archived: false, pending: null };
      products.unshift(p);
      log(ctx.adminId, 'product.create', `product:${p.id}`, { title: p.title });
      return productOut(p);
    }],
    ['PATCH', /^\/products\/(\d+)$/, (ctx) => {
      requireRole(ctx.role, ['merchant']);
      const p = findProduct(ctx, Number(ctx.m[1]));
      const live = p.status === 'on_sale' || p.status === 'off_sale';
      // Live products keep their content on sale; content changes wait in `pending`.
      const base: ProductRow = live && p.pending ? { ...p, ...p.pending } : p;
      const v = productInput(ctx.body, p.merchant_id, base);
      const content: Partial<ProductContent> = {};
      const others: Partial<ProductRow> = {};
      for (const [k, val] of Object.entries(v)) {
        if (CONTENT_KEYS.includes(k as keyof ProductContent)) (content as Record<string, unknown>)[k] = val;
        else (others as Record<string, unknown>)[k] = val;
      }
      Object.assign(p, others);
      let reviewed: string | undefined;
      if (live) {
        const changed = CONTENT_KEYS.some((k) => JSON.stringify(content[k]) !== JSON.stringify(p[k]));
        if (changed) {
          p.pending = content;
          reviewed = moderate(p, { ...contentOf(p), ...content }, true);
        } else p.pending = null;
      } else Object.assign(p, content);
      touch(p);
      log(ctx.adminId, 'product.update', `product:${p.id}`, { fields: Object.keys(ctx.body), review: reviewed });
      return productOut(p);
    }],
    ['DELETE', /^\/products\/(\d+)$/, (ctx) => {
      requireRole(ctx.role, ['merchant']);
      const p = findProduct(ctx, Number(ctx.m[1]));
      if (p.sold_qty > 0) {
        p.archived = true;
        for (const e of entries) if (e.product_id === p.id && LIVE_ENTRY.includes(e.status)) e.status = 'withdrawn';
      } else products.splice(products.indexOf(p), 1);
      log(ctx.adminId, 'product.delete', `product:${p.id}`, { archived: p.sold_qty > 0 });
      return null;
    }],
    ['POST', /^\/products\/(\d+)\/submit$/, (ctx) => {
      requireRole(ctx.role, ['merchant']);
      const p = findProduct(ctx, Number(ctx.m[1]));
      if (!['draft', 'rejected', 'banned'].includes(p.status)) fail(409, 'invalid_status', '只有草稿、未通过或平台下架的商品可以提交审核');
      const r = moderate(p, contentOf(p), false);
      touch(p);
      log(ctx.adminId, 'product.submit', `product:${p.id}`, { result: r });
      return productOut(p);
    }],
    ['POST', /^\/products\/(\d+)\/(on-sale|off-sale)$/, (ctx) => {
      requireRole(ctx.role, ['merchant']);
      const p = findProduct(ctx, Number(ctx.m[1]));
      const on = ctx.m[2] === 'on-sale';
      if (on && p.status !== 'off_sale') fail(409, 'invalid_status', p.status === 'banned' ? '平台下架的商品不能自行上架，修改后重新提交审核' : '只有已下架的商品可以上架');
      if (!on && p.status !== 'on_sale') fail(409, 'invalid_status', '只有在售的商品可以下架');
      p.status = on ? 'on_sale' : 'off_sale';
      touch(p);
      log(ctx.adminId, on ? 'product.on_sale' : 'product.off_sale', `product:${p.id}`);
      return productOut(p);
    }],
    ['POST', /^\/products\/(\d+)\/ban$/, (ctx) => {
      requireRole(ctx.role, STAFF);
      const p = findProduct(ctx, Number(ctx.m[1]));
      const reason = String(ctx.body.reason ?? '').trim();
      if (!reason) fail(400, 'invalid_request', '请填写下架原因');
      if (p.status === 'banned') fail(409, 'invalid_status', '已经是平台下架状态');
      p.status = 'banned';
      p.review_note = reason;
      p.pending = null;
      for (const t of reviewTasks) if (t.target_type === 'product' && t.target_id === p.id && t.status === 'pending') {
        t.status = 'rejected';
        t.reject_reason = `平台下架：${reason}`;
        t.reviewed_at = new Date().toISOString();
      }
      touch(p);
      notifyMerchant(p.merchant_id, { category: 'product', level: 'error', title: `商品「${p.title}」已被平台下架：${reason}`, body: '修改后可以重新提交审核。', link: `/merchant/products?id=${p.id}` });
      log(ctx.adminId, 'product.ban', `product:${p.id}`, { reason });
      return productOut(p);
    }],

    // ---- 商品订单
    ['GET', /^\/product-orders$/, (ctx) => {
      requireRole(ctx.role, [...STAFF, 'merchant']);
      const scope = scopeOf(ctx);
      const { q } = ctx;
      const mid = scope ?? (q.get('merchant_id') ? Number(q.get('merchant_id')) : null);
      const pid = q.get('product_id') ? Number(q.get('product_id')) : null;
      const status = q.get('status') || '';
      const from = q.get('from');
      const to = q.get('to');
      for (const x of [from, to]) if (x && !/^\d{4}-\d{2}-\d{2}$/.test(x)) fail(400, 'invalid_request', 'from / to 格式应为 YYYY-MM-DD');
      const list = orders.filter((o) => (mid === null || o.merchant_id === mid) && (pid === null || o.product_id === pid) && (!status || o.status === status) && (!from || dayKey(o.created_ms) >= from) && (!to || dayKey(o.created_ms) <= to));
      const page = paged(list, q);
      return { items: page.items.map(orderOut), total: page.total };
    }],
    ['POST', /^\/product-orders\/(\d+)\/refund$/, ({ m, body, role, adminId }) => {
      requireRole(role, ['admin']);
      const o = orders.find((x) => x.id === Number(m[1]));
      if (!o) fail(404, 'not_found', '订单不存在');
      const reason = String(body.reason ?? '').trim();
      if (!reason) fail(400, 'invalid_request', '请填写退款原因');
      const unused = o.coupon_rows.filter((c) => c.status === 'unused');
      if (!['paid', 'completed'].includes(o.status) || !unused.length) fail(409, 'nothing_to_refund', '没有可退的券（已核销的券不能退）');
      const p = products.find((x) => x.id === o.product_id)!;
      // 次卡: refund the unused share of a coupon.
      const amt = unused.reduce((s, c) => s + Math.round((o.unit_price_amt * c.uses_left) / Math.max(1, p.use_qty)), 0);
      for (const c of unused) c.status = 'refunded';
      o.refund_amt += amt;
      const allRefunded = o.coupon_rows.every((c) => c.status === 'refunded');
      o.status = allRefunded ? 'refunding' : o.coupon_rows.some((c) => c.status === 'unused') ? 'paid' : 'completed';
      if (allRefunded) setTimeout(() => {
        if (o.status === 'refunding') o.status = 'refunded';
      }, 4000);
      log(adminId, 'product_order.refund', `product_order:${o.id}`, { order_no: o.order_no, refund_amt: amt, reason });
      return orderOut(o);
    }],

    // ---- 官方活动 · 平台 + 商户（apply_open=true）
    ['GET', /^\/promotions$/, (ctx) => {
      const { q, role } = ctx;
      requireRole(role, [...STAFF, 'merchant']);
      const applyOpen = q.get('apply_open') === 'true';
      if (role === 'merchant' && !applyOpen) fail(403, 'forbidden', '商户账号只能查看可报名的活动');
      const status = q.get('status') || '';
      const order: PromotionStatus[] = ['active', 'scheduled', 'draft', 'ended', 'cancelled'];
      const list = promotions
        .filter((p) => (!status || promotionStatus(p) === status) && (!applyOpen || (p.apply_open && ['scheduled', 'active'].includes(promotionStatus(p)) && (!p.apply_deadline || Date.parse(p.apply_deadline) > Date.now()))))
        .sort((a, b) => order.indexOf(promotionStatus(a)) - order.indexOf(promotionStatus(b)) || Date.parse(a.starts_at) - Date.parse(b.starts_at))
        .map(promotionOut);
      return paged(list, q);
    }],
    ['GET', /^\/promotions\/(\d+)$/, ({ m, role }) => {
      requireRole(role, [...STAFF, 'merchant']);
      const p = promotions.find((x) => x.id === Number(m[1]));
      if (!p || (role === 'merchant' && p.state === 'draft')) fail(404, 'not_found', '活动不存在');
      return promotionOut(p);
    }],
    ['POST', /^\/promotions$/, ({ body, role, adminId }) => {
      requireRole(role, STAFF);
      const p: PromotionRow = { id: ++promotionSeq, state: 'draft', created_at: new Date().toISOString(), ...promotionInput(body) };
      promotions.unshift(p);
      log(adminId, 'promotion.create', `promotion:${p.id}`, { title: p.title });
      return promotionOut(p);
    }],
    ['PATCH', /^\/promotions\/(\d+)$/, ({ m, body, role, adminId }) => {
      requireRole(role, STAFF);
      const p = promotions.find((x) => x.id === Number(m[1]));
      if (!p) fail(404, 'not_found', '活动不存在');
      if (['ended', 'cancelled'].includes(promotionStatus(p))) fail(409, 'invalid_status', '已结束或已取消的活动不能修改');
      Object.assign(p, promotionInput(body, p));
      log(adminId, 'promotion.update', `promotion:${p.id}`, { fields: Object.keys(body) });
      return promotionOut(p);
    }],
    ['POST', /^\/promotions\/(\d+)\/(publish|cancel)$/, ({ m, role, adminId }) => {
      requireRole(role, STAFF);
      const p = promotions.find((x) => x.id === Number(m[1]));
      if (!p) fail(404, 'not_found', '活动不存在');
      if (m[2] === 'publish') {
        if (p.state !== 'draft') fail(409, 'invalid_status', '只有草稿可以发布');
        if (Date.parse(p.ends_at) <= Date.now()) fail(409, 'invalid_status', '活动结束时间已过，先改时间再发布');
        p.state = 'published';
      } else {
        if (!['draft', 'scheduled', 'active'].includes(promotionStatus(p))) fail(409, 'invalid_status', '活动已结束或已取消');
        p.state = 'cancelled';
      }
      log(adminId, `promotion.${m[2]}`, `promotion:${p.id}`);
      return promotionOut(p);
    }],
    ['GET', /^\/promotions\/(\d+)\/entries$/, ({ m, q, role }) => {
      requireRole(role, STAFF);
      const status = q.get('status') || '';
      const list = entries
        .filter((e) => e.promotion_id === Number(m[1]) && (!status || e.status === status))
        .sort((a, b) => ENTRY_ORDER.indexOf(a.status) - ENTRY_ORDER.indexOf(b.status) || a.sort_no - b.sort_no || a.id - b.id);
      return { items: list.map(entryOut) };
    }],
    ['POST', /^\/promotions\/(\d+)\/entries$/, ({ m, body, role, adminId }) => {
      requireRole(role, STAFF);
      const pr = promotions.find((x) => x.id === Number(m[1]));
      if (!pr) fail(404, 'not_found', '活动不存在');
      if (['ended', 'cancelled'].includes(promotionStatus(pr))) fail(409, 'invalid_status', '活动已结束或已取消');
      const p = products.find((x) => x.id === Number(body.product_id) && !x.archived);
      if (!p) fail(404, 'not_found', '商品不存在');
      if (!p.allow_promotion) fail(409, 'not_authorized', '商户没有授权这个商品进入官方活动');
      if (p.status !== 'on_sale') fail(409, 'not_on_sale', '只能选在售的商品');
      const promo = body.promo_price_amt === null || body.promo_price_amt === undefined || body.promo_price_amt === '' ? p.price_amt : Number(body.promo_price_amt);
      if (!Number.isInteger(promo) || promo < 1 || promo > p.price_amt) fail(400, 'invalid_request', '活动价须在 0.01 元到商品售价之间');
      conflict(p.id, pr, null);
      const e: EntryRow = {
        id: ++entrySeq,
        promotion_id: pr.id,
        product_id: p.id,
        promo_price_amt: promo,
        platform_subsidy_amt: Math.max(0, Number(body.platform_subsidy_amt ?? 0)),
        promo_stock_qty: body.promo_stock_qty === null || body.promo_stock_qty === undefined || body.promo_stock_qty === '' ? null : Number(body.promo_stock_qty),
        promo_sold_qty: 0,
        sort_no: Number(body.sort_no ?? 0),
        source: 'platform',
        status: promo < p.price_amt ? 'pending_merchant' : 'active',
        note: null,
        created_at: new Date().toISOString(),
        decided_at: promo < p.price_amt ? null : new Date().toISOString(),
      };
      entries.push(e);
      log(adminId, 'promotion_entry.create', `promotion_entry:${e.id}`, { promotion_id: pr.id, product_id: p.id, status: e.status });
      return entryOut(e);
    }],
    ['POST', /^\/promotion-entries\/(\d+)\/(approve|reject|remove)$/, ({ m, body, role, adminId }) => {
      requireRole(role, STAFF);
      const e = entries.find((x) => x.id === Number(m[1]));
      if (!e) fail(404, 'not_found', '条目不存在');
      const note = String(body.note ?? '').trim();
      if (m[2] === 'approve') {
        if (e.status !== 'pending_platform') fail(409, 'invalid_status', '只有待审核的报名可以通过');
        conflict(e.product_id, promotions.find((x) => x.id === e.promotion_id)!, e.id);
        e.status = 'active';
        e.platform_subsidy_amt = Math.max(0, Number(body.platform_subsidy_amt ?? e.platform_subsidy_amt));
      } else if (m[2] === 'reject') {
        if (e.status !== 'pending_platform') fail(409, 'invalid_status', '只有待审核的报名可以驳回');
        if (!note) fail(400, 'invalid_request', '请填写驳回原因');
        e.status = 'rejected';
        e.note = note;
      } else {
        if (!LIVE_ENTRY.includes(e.status)) fail(409, 'invalid_status', '这个条目已经不在活动里了');
        if (!note) fail(400, 'invalid_request', '请填写移除原因');
        e.status = 'removed';
        e.note = note;
      }
      e.decided_at = new Date().toISOString();
      log(adminId, `promotion_entry.${m[2]}`, `promotion_entry:${e.id}`, { note: note || undefined, platform_subsidy_amt: m[2] === 'approve' ? e.platform_subsidy_amt : undefined });
      return entryOut(e);
    }],
    ['PATCH', /^\/promotion-entries\/(\d+)$/, ({ m, body, role, adminId }) => {
      requireRole(role, STAFF);
      const e = entries.find((x) => x.id === Number(m[1]));
      if (!e) fail(404, 'not_found', '条目不存在');
      if ('sort_no' in body) {
        const s = Number(body.sort_no);
        if (!Number.isInteger(s) || s < 0 || s > 999) fail(400, 'invalid_request', '排序 0–999');
        e.sort_no = s;
      }
      if ('platform_subsidy_amt' in body) {
        const s = Number(body.platform_subsidy_amt);
        if (!Number.isInteger(s) || s < 0 || s > 100_000) fail(400, 'invalid_request', '补贴 0–1000 元');
        e.platform_subsidy_amt = s;
      }
      log(adminId, 'promotion_entry.update', `promotion_entry:${e.id}`, { fields: Object.keys(body) });
      return entryOut(e);
    }],

    // ---- 官方活动 · 商户
    ['GET', /^\/promotion-entries$/, (ctx) => {
      requireRole(ctx.role, ['merchant']);
      const mid = scopeOf(ctx)!;
      const status = ctx.q.get('status') || '';
      const list = entries
        .filter((e) => products.find((p) => p.id === e.product_id)?.merchant_id === mid && (!status || e.status === status))
        .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));
      return { items: list.map(entryOut) };
    }],
    ['POST', /^\/promotions\/(\d+)\/apply$/, (ctx) => {
      requireRole(ctx.role, ['merchant']);
      const mid = scopeOf(ctx)!;
      const { body } = ctx;
      const pr = promotions.find((x) => x.id === Number(ctx.m[1]));
      if (!pr || pr.state === 'draft') fail(404, 'not_found', '活动不存在');
      if (!pr.apply_open || !['scheduled', 'active'].includes(promotionStatus(pr)) || (pr.apply_deadline && Date.parse(pr.apply_deadline) <= Date.now())) fail(409, 'apply_closed', '这个活动已停止报名');
      const p = products.find((x) => x.id === Number(body.product_id) && !x.archived && x.merchant_id === mid);
      if (!p) fail(404, 'not_found', '商品不存在');
      if (p.status !== 'on_sale') fail(409, 'not_on_sale', '只能报名在售的商品');
      const promo = Number(body.promo_price_amt);
      if (!Number.isInteger(promo) || promo < 1 || promo > p.price_amt) fail(400, 'invalid_request', '活动价须在 0.01 元到商品售价之间');
      const stock = body.promo_stock_qty === null || body.promo_stock_qty === undefined || body.promo_stock_qty === '' ? null : Number(body.promo_stock_qty);
      if (stock !== null && (!Number.isInteger(stock) || stock < 1)) fail(400, 'invalid_request', '活动库存须为正整数，不限留空');
      conflict(p.id, pr, null);
      const e: EntryRow = { id: ++entrySeq, promotion_id: pr.id, product_id: p.id, promo_price_amt: promo, platform_subsidy_amt: 0, promo_stock_qty: stock, promo_sold_qty: 0, sort_no: 0, source: 'merchant', status: 'pending_platform', note: null, created_at: new Date().toISOString(), decided_at: null };
      entries.push(e);
      log(ctx.adminId, 'promotion_entry.apply', `promotion_entry:${e.id}`, { promotion_id: pr.id, product_id: p.id, promo_price_amt: promo });
      return entryOut(e);
    }],
    ['POST', /^\/promotion-entries\/(\d+)\/(accept|decline|withdraw)$/, (ctx) => {
      requireRole(ctx.role, ['merchant']);
      const mid = scopeOf(ctx)!;
      const e = entries.find((x) => x.id === Number(ctx.m[1]));
      if (!e || products.find((p) => p.id === e.product_id)?.merchant_id !== mid) fail(404, 'not_found', '条目不存在');
      const act = ctx.m[2];
      if (act === 'accept' || act === 'decline') {
        if (e.status !== 'pending_merchant') fail(409, 'invalid_status', '这条邀请已经处理过了');
        if (act === 'accept') conflict(e.product_id, promotions.find((x) => x.id === e.promotion_id)!, e.id);
        e.status = act === 'accept' ? 'active' : 'rejected';
        e.note = act === 'decline' ? String(ctx.body.note ?? '').trim() || '商户不参加' : e.note;
      } else {
        if (!LIVE_ENTRY.includes(e.status)) fail(409, 'invalid_status', '这个商品已经不在活动里了');
        e.status = 'withdrawn';
      }
      e.decided_at = new Date().toISOString();
      log(ctx.adminId, `promotion_entry.${act}`, `promotion_entry:${e.id}`);
      return entryOut(e);
    }],

    // ---- 开放平台
    ['GET', /^\/open-apps$/, (ctx) => {
      requireRole(ctx.role, ['admin', 'merchant']);
      const scope = scopeOf(ctx);
      const mid = scope ?? (ctx.q.get('merchant_id') ? Number(ctx.q.get('merchant_id')) : null);
      return { items: apps.filter((a) => mid === null || a.merchant_id === mid).sort((a, b) => a.id - b.id).map(appOut) };
    }],
    ['POST', /^\/open-apps$/, (ctx) => {
      requireRole(ctx.role, ['merchant']);
      const mid = scopeOf(ctx)!;
      if (apps.filter((a) => a.merchant_id === mid).length >= MAX_APPS) fail(409, 'app_limit', `每个商户最多建 ${MAX_APPS} 个应用`);
      const a: AppRow = { id: ++appSeq, merchant_id: mid, app_id: newAppId(), ...appInput(ctx.body), status: 'active', last_used_at: null, created_at: new Date().toISOString(), secret: hex(32) };
      apps.push(a);
      calls.set(a.id, []);
      deliveries.set(a.id, []);
      log(ctx.adminId, 'open_app.create', `open_app:${a.id}`, { app_id: a.app_id, scopes: a.scopes });
      return { ...appOut(a), app_secret: a.secret };
    }],
    ['PATCH', /^\/open-apps\/(\d+)$/, (ctx) => {
      requireRole(ctx.role, ['merchant']);
      const a = findApp(ctx, Number(ctx.m[1]));
      Object.assign(a, appInput(ctx.body, a));
      log(ctx.adminId, 'open_app.update', `open_app:${a.id}`, { fields: Object.keys(ctx.body) });
      return appOut(a);
    }],
    ['DELETE', /^\/open-apps\/(\d+)$/, (ctx) => {
      requireRole(ctx.role, ['merchant']);
      const a = findApp(ctx, Number(ctx.m[1]));
      apps.splice(apps.indexOf(a), 1);
      log(ctx.adminId, 'open_app.delete', `open_app:${a.id}`, { app_id: a.app_id });
      return null;
    }],
    ['POST', /^\/open-apps\/(\d+)\/reset-secret$/, (ctx) => {
      requireRole(ctx.role, ['merchant']);
      const a = findApp(ctx, Number(ctx.m[1]));
      a.secret = hex(32);
      log(ctx.adminId, 'open_app.reset_secret', `open_app:${a.id}`, { app_id: a.app_id });
      return { ...appOut(a), app_secret: a.secret };
    }],
    ['POST', /^\/open-apps\/(\d+)\/(enable|disable)$/, (ctx) => {
      requireRole(ctx.role, ['admin', 'merchant']);
      const a = findApp(ctx, Number(ctx.m[1]));
      a.status = ctx.m[2] === 'enable' ? 'active' : 'disabled';
      log(ctx.adminId, `open_app.${ctx.m[2]}`, `open_app:${a.id}`, { app_id: a.app_id });
      return appOut(a);
    }],
    ['GET', /^\/open-apps\/(\d+)\/calls$/, (ctx) => {
      requireRole(ctx.role, ['admin', 'merchant']);
      const a = findApp(ctx, Number(ctx.m[1]));
      const since = Date.now() - 7 * DAY;
      return paged((calls.get(a.id) ?? []).filter((c) => Date.parse(c.created_at) >= since), ctx.q);
    }],
    ['GET', /^\/open-apps\/(\d+)\/deliveries$/, (ctx) => {
      requireRole(ctx.role, ['admin', 'merchant']);
      const a = findApp(ctx, Number(ctx.m[1]));
      return paged(deliveries.get(a.id) ?? [], ctx.q);
    }],
    ['POST', /^\/open-apps\/(\d+)\/deliveries\/(\d+)\/redeliver$/, (ctx) => {
      requireRole(ctx.role, ['admin', 'merchant']);
      const a = findApp(ctx, Number(ctx.m[1]));
      const d = (deliveries.get(a.id) ?? []).find((x) => x.id === Number(ctx.m[2]));
      if (!d) fail(404, 'not_found', '投递记录不存在');
      if (!a.webhook_url) fail(409, 'no_webhook', '应用没有设置 Webhook 地址');
      if (a.status === 'disabled') fail(403, 'app_disabled', '应用已停用，Webhook 停发');
      d.attempt_qty++;
      d.status = 'succeeded';
      d.last_status_code = 200;
      d.last_error = null;
      d.next_retry_at = null;
      log(ctx.adminId, 'open_app.redeliver', `open_app:${a.id}`, { delivery_id: d.id, event_id: d.event_id });
      return clone(d);
    }],
    ['POST', /^\/open-apps\/(\d+)\/test-webhook$/, (ctx) => {
      requireRole(ctx.role, ['admin', 'merchant']);
      const a = findApp(ctx, Number(ctx.m[1]));
      if (!a.webhook_url) fail(409, 'no_webhook', '应用没有设置 Webhook 地址');
      if (a.status === 'disabled') fail(403, 'app_disabled', '应用已停用，Webhook 停发');
      const ok = !a.webhook_url.includes('booking.');
      const d: WebhookDelivery = {
        id: deliverySeq++,
        event_id: `evt_01JD${hex(8).toUpperCase()}`,
        event_type: 'ping',
        status: ok ? 'succeeded' : 'pending',
        attempt_qty: 1,
        last_status_code: ok ? 200 : 502,
        last_error: ok ? null : '对方返回 502 Bad Gateway',
        next_retry_at: ok ? null : new Date(Date.now() + MIN).toISOString(),
        created_at: new Date().toISOString(),
      };
      deliveries.get(a.id)?.unshift(d);
      log(ctx.adminId, 'open_app.test_webhook', `open_app:${a.id}`, { delivery_id: d.id });
      return clone(d);
    }],
  ];
}

const ENTRY_ORDER: EntryStatus[] = ['pending_platform', 'pending_merchant', 'active', 'rejected', 'withdrawn', 'removed'];

/** One product, one live entry in overlapping activities (409 promotion_conflict). */
function conflict(productId: number, pr: PromotionRow, selfId: number | null) {
  const s = Date.parse(pr.starts_at);
  const e = Date.parse(pr.ends_at);
  const other = entries.find((x) => {
    if (x.id === selfId || x.product_id !== productId || !LIVE_ENTRY.includes(x.status)) return false;
    const o = promotions.find((p) => p.id === x.promotion_id)!;
    if (!['draft', 'scheduled', 'active'].includes(promotionStatus(o))) return false;
    return x.promotion_id === pr.id || (Date.parse(o.starts_at) < e && Date.parse(o.ends_at) > s);
  });
  if (other) {
    const o = promotions.find((p) => p.id === other.promotion_id)!;
    fail(409, 'promotion_conflict', other.promotion_id === pr.id ? '这个商品已经在本活动里了' : `这个商品已在时间重叠的活动「${o.title}」里`);
  }
}

function promotionInput(b: Record<string, unknown>, base?: PromotionRow): Omit<PromotionRow, 'id' | 'state' | 'created_at'> {
  const get = (k: keyof PromotionRow) => (k in b ? b[k] : base?.[k]);
  const title = String(get('title') ?? '').trim();
  if (title.length < 2 || title.length > 30) fail(400, 'invalid_request', '活动名称 2–30 字');
  const starts = String(get('starts_at') ?? '');
  const ends = String(get('ends_at') ?? '');
  if (!Date.parse(starts) || !Date.parse(ends) || Date.parse(starts) >= Date.parse(ends)) fail(400, 'invalid_request', '活动时间无效：开始须早于结束');
  const applyOpen = get('apply_open') === true;
  const dl = get('apply_deadline');
  const deadline = applyOpen && dl ? String(dl) : null;
  if (deadline && (!Date.parse(deadline) || Date.parse(deadline) > Date.parse(ends))) fail(400, 'invalid_request', '报名截止须早于活动结束');
  const banner = get('banner_url');
  if (banner && !IMG_RE.test(String(banner))) fail(400, 'invalid_request', '横幅图地址无效');
  const str = (k: keyof PromotionRow) => {
    const v = get(k);
    return v ? String(v).trim() || null : null;
  };
  return { title, subtitle: str('subtitle'), banner_url: banner ? String(banner) : null, description: str('description'), starts_at: new Date(starts).toISOString(), ends_at: new Date(ends).toISOString(), apply_open: applyOpen, apply_deadline: deadline ? new Date(deadline).toISOString() : null };
}

/** Read-only views for the 站内信 seeds (mocks/messages.ts); read lazily, never at import time. */
export const commerceRows = {
  products: () => products,
  orders: () => orders,
  promotions: () => promotions,
  entries: () => entries,
};
