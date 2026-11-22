// V2 第五批「商户商品与开放平台」· 商品 / 商品订单 / 官方活动 / 开放平台应用 (docs/api/v2-5-商户商品与开放平台.md
// 「商户商品」「官方活动」「开放平台」). Types and one request function per endpoint; 商户自助改场馆 reuses
// merchantApi.updateVenue (only the whitelisted fields are sent).
import { ADMIN_PREFIX } from '../config';
import { http } from './client';
import type { Coupon } from './merchant';
import type { MerchantRef } from './perks';
import type { Items, Paged } from './types';

const A = ADMIN_PREFIX;
const PAGE = 20;

// ---------- 商户商品 ----------

/** package-套餐券 voucher-代金券（original_amt 为面值） pass-次卡（use_qty 次） */
export type ProductType = 'package' | 'voucher' | 'pass';
/** draft-草稿 reviewing-审核中 on_sale-在售 off_sale-已下架 rejected-未通过 banned-平台强制下架 */
export type ProductStatus = 'draft' | 'reviewing' | 'on_sale' | 'off_sale' | 'rejected' | 'banned';

/** The product's live official-activity price (App shows and orders at it). */
export interface ProductPromotion {
  id: number;
  title: string;
  promo_price_amt: number;
  ends_at: string;
  /** null = 不限 */
  promo_left_qty: number | null;
}

export interface Product {
  id: number;
  merchant: MerchantRef;
  type: ProductType;
  title: string;
  subtitle: string | null;
  description: string | null;
  images: string[];
  sports: string[];
  price_amt: number;
  original_amt: number | null;
  use_qty: number;
  /** One of valid_days (N days after purchase) / valid_until (YYYY-MM-DD, 23:59:59 Asia/Shanghai). */
  valid_days: number | null;
  valid_until: string | null;
  /** null = 不限 */
  stock_qty: number | null;
  sold_qty: number;
  /** 0 = 不限 */
  per_user_limit_qty: number;
  refundable: boolean;
  allow_promotion: boolean;
  promotion: ProductPromotion | null;
  /** [] = every venue of the merchant. */
  venue_ids: number[];
  venues: { id: number; name: string }[];
  rules: string | null;
  status: ProductStatus;
  review_note: string | null;
  has_pending_changes: boolean;
  created_at: string;
  updated_at: string;
}

/** Content fields an on-sale product keeps under review before they replace the live ones. */
export interface ProductContent {
  title: string;
  subtitle: string | null;
  description: string | null;
  images: string[];
  rules: string | null;
}

export interface ProductDetail extends Product {
  pending: Partial<ProductContent> | null;
}

export interface ProductInput {
  type: ProductType;
  title: string;
  subtitle: string | null;
  description: string | null;
  images: string[];
  sports: string[];
  price_amt: number;
  original_amt: number | null;
  use_qty: number;
  valid_days: number | null;
  valid_until: string | null;
  stock_qty: number | null;
  per_user_limit_qty: number;
  refundable: boolean;
  allow_promotion: boolean;
  venue_ids: number[];
  rules: string | null;
}

export interface ProductFilter {
  merchant_id?: number | null;
  status?: ProductStatus | '';
  q?: string;
  allow_promotion?: boolean | null;
  page?: number;
  page_size?: number;
}

// ---------- 商品订单 ----------

/** pending-待支付 paid-已支付（还有未用的券） completed-已完成 refunding-退款中 refunded-已退款 cancelled-已取消 */
export type ProductOrderStatus = 'pending' | 'paid' | 'completed' | 'refunding' | 'refunded' | 'cancelled';

export interface ProductOrder {
  id: number;
  order_no: string;
  product: { id: number; title: string; type: ProductType; image: string | null };
  merchant: MerchantRef;
  qty: number;
  unit_price_amt: number;
  amount_amt: number;
  refund_amt: number;
  promotion: { id: number; title: string } | null;
  status: ProductOrderStatus;
  coupons: Coupon[];
  pay_expires_at: string | null;
  paid_at: string | null;
  created_at: string;
  /** Admin list only. */
  user?: { id: number; nickname: string };
}

export interface ProductOrderFilter {
  merchant_id?: number | null;
  product_id?: number | null;
  status?: ProductOrderStatus | '';
  from?: string;
  to?: string;
  page?: number;
  page_size?: number;
}

// ---------- 官方活动 ----------

/** draft-草稿 scheduled-未开始 active-进行中 ended-已结束 cancelled-已取消 */
export type PromotionStatus = 'draft' | 'scheduled' | 'active' | 'ended' | 'cancelled';

export interface Promotion {
  id: number;
  title: string;
  subtitle: string | null;
  banner_url: string | null;
  description: string | null;
  starts_at: string;
  ends_at: string;
  apply_open: boolean;
  apply_deadline: string | null;
  status: PromotionStatus;
  product_qty: number;
  created_at: string;
}

export interface PromotionInput {
  title: string;
  subtitle: string | null;
  banner_url: string | null;
  description: string | null;
  starts_at: string;
  ends_at: string;
  apply_open: boolean;
  apply_deadline: string | null;
}

/** pending_merchant-待商户同意 pending_platform-待平台审核 active-已生效 rejected-已拒绝 withdrawn-商户已退出 removed-平台已移除 */
export type EntryStatus = 'pending_merchant' | 'pending_platform' | 'active' | 'rejected' | 'withdrawn' | 'removed';

export interface PromotionEntry {
  id: number;
  promotion_id: number;
  product: Product;
  merchant: MerchantRef;
  promo_price_amt: number;
  platform_subsidy_amt: number;
  /** null = 不限 */
  promo_stock_qty: number | null;
  promo_sold_qty: number;
  sort_no: number;
  /** platform-平台选品 merchant-商户报名 */
  source: 'platform' | 'merchant';
  status: EntryStatus;
  note: string | null;
  created_at: string;
  decided_at: string | null;
  /** Not in the contract's shape: the activity, so the merchant's 「我的报名」 can show it without a second call. Optional. */
  promotion?: Pick<Promotion, 'id' | 'title' | 'starts_at' | 'ends_at' | 'status'>;
}

export interface EntryInput {
  product_id: number;
  promo_price_amt: number;
  platform_subsidy_amt: number;
  promo_stock_qty: number | null;
  sort_no: number;
}

// ---------- 开放平台 ----------

export type OpenScope = 'products' | 'orders' | 'bookings' | 'redemptions' | 'statements' | 'venues' | 'promotions';

export interface OpenApp {
  id: number;
  app_id: string;
  name: string;
  scopes: OpenScope[];
  ip_allowlist: string[];
  webhook_url: string | null;
  webhook_events: string[];
  status: 'active' | 'disabled';
  last_used_at: string | null;
  created_at: string;
  /** Admin list (all merchants) only; not in the contract's shape. */
  merchant?: MerchantRef;
}

/** Returned once, on create and on reset-secret. */
export interface OpenAppWithSecret extends OpenApp {
  app_secret: string;
}

export interface OpenAppInput {
  name: string;
  scopes: OpenScope[];
  ip_allowlist: string[];
  webhook_url: string | null;
  webhook_events: string[];
}

export interface OpenCall {
  id: number;
  method: string;
  path: string;
  status_code: number;
  error_code: string | null;
  latency_ms: number;
  ip: string;
  created_at: string;
}

export interface WebhookDelivery {
  id: number;
  event_id: string;
  event_type: string;
  /** pending-待投递 / 重试中 succeeded-成功 failed-失败（6 次都没成功） */
  status: 'pending' | 'succeeded' | 'failed';
  attempt_qty: number;
  last_status_code: number | null;
  last_error: string | null;
  next_retry_at: string | null;
  created_at: string;
}

// ---------- requests ----------

export const commerceApi = {
  // 商品（商户账号：本商户；admin / ops：全部，只读 + 强制下架）
  products: (p: ProductFilter) => http.get<Paged<Product>>(`${A}/products`, { page_size: PAGE, ...p }),
  product: (id: number) => http.get<ProductDetail>(`${A}/products/${id}`),
  createProduct: (body: ProductInput) => http.post<Product>(`${A}/products`, body),
  updateProduct: (id: number, body: Partial<ProductInput>) => http.patch<Product>(`${A}/products/${id}`, body),
  deleteProduct: (id: number) => http.del<unknown>(`${A}/products/${id}`),
  submitProduct: (id: number) => http.post<Product>(`${A}/products/${id}/submit`),
  onSale: (id: number) => http.post<Product>(`${A}/products/${id}/on-sale`),
  offSale: (id: number) => http.post<Product>(`${A}/products/${id}/off-sale`),
  banProduct: (id: number, reason: string) => http.post<Product>(`${A}/products/${id}/ban`, { reason }),

  // 商品订单
  productOrders: (p: ProductOrderFilter) => http.get<Paged<ProductOrder>>(`${A}/product-orders`, { page_size: PAGE, ...p }),
  refundProductOrder: (id: number, reason: string) => http.post<ProductOrder>(`${A}/product-orders/${id}/refund`, { reason }),

  // 官方活动 · 平台（promotion.manage）
  promotions: (p: { status?: PromotionStatus | ''; apply_open?: boolean; page?: number; page_size?: number }) =>
    http.get<Paged<Promotion>>(`${A}/promotions`, { page_size: PAGE, ...p }),
  promotion: (id: number) => http.get<Promotion>(`${A}/promotions/${id}`),
  createPromotion: (body: PromotionInput) => http.post<Promotion>(`${A}/promotions`, body),
  updatePromotion: (id: number, body: Partial<PromotionInput>) => http.patch<Promotion>(`${A}/promotions/${id}`, body),
  publishPromotion: (id: number) => http.post<Promotion>(`${A}/promotions/${id}/publish`),
  cancelPromotion: (id: number) => http.post<Promotion>(`${A}/promotions/${id}/cancel`),
  promotionEntries: (id: number, status?: EntryStatus | '') => http.get<Items<PromotionEntry>>(`${A}/promotions/${id}/entries`, { status }),
  addEntry: (id: number, body: EntryInput) => http.post<PromotionEntry>(`${A}/promotions/${id}/entries`, body),
  approveEntry: (id: number, platform_subsidy_amt: number) => http.post<PromotionEntry>(`${A}/promotion-entries/${id}/approve`, { platform_subsidy_amt }),
  rejectEntry: (id: number, note: string) => http.post<PromotionEntry>(`${A}/promotion-entries/${id}/reject`, { note }),
  removeEntry: (id: number, note: string) => http.post<PromotionEntry>(`${A}/promotion-entries/${id}/remove`, { note }),
  patchEntry: (id: number, body: { sort_no?: number; platform_subsidy_amt?: number }) => http.patch<PromotionEntry>(`${A}/promotion-entries/${id}`, body),

  // 官方活动 · 商户（promotion.join）
  openPromotions: () => http.get<Paged<Promotion>>(`${A}/promotions`, { apply_open: true, page_size: 50 }),
  myEntries: (status?: EntryStatus | '') => http.get<Items<PromotionEntry>>(`${A}/promotion-entries`, { status }),
  applyPromotion: (id: number, body: { product_id: number; promo_price_amt: number; promo_stock_qty: number | null }) =>
    http.post<PromotionEntry>(`${A}/promotions/${id}/apply`, body),
  acceptEntry: (id: number) => http.post<PromotionEntry>(`${A}/promotion-entries/${id}/accept`),
  declineEntry: (id: number, note: string) => http.post<PromotionEntry>(`${A}/promotion-entries/${id}/decline`, { note }),
  withdrawEntry: (id: number) => http.post<PromotionEntry>(`${A}/promotion-entries/${id}/withdraw`),

  // 开放平台（openapi.manage：商户账号管本商户；admin 看全部、可停用）
  openApps: (merchant_id?: number | null) => http.get<Items<OpenApp>>(`${A}/open-apps`, { merchant_id }),
  createOpenApp: (body: OpenAppInput) => http.post<OpenAppWithSecret>(`${A}/open-apps`, body),
  updateOpenApp: (id: number, body: Partial<OpenAppInput>) => http.patch<OpenApp>(`${A}/open-apps/${id}`, body),
  deleteOpenApp: (id: number) => http.del<unknown>(`${A}/open-apps/${id}`),
  resetSecret: (id: number) => http.post<OpenAppWithSecret>(`${A}/open-apps/${id}/reset-secret`),
  disableApp: (id: number) => http.post<OpenApp>(`${A}/open-apps/${id}/disable`),
  enableApp: (id: number) => http.post<OpenApp>(`${A}/open-apps/${id}/enable`),
  appCalls: (id: number, page: number) => http.get<Paged<OpenCall>>(`${A}/open-apps/${id}/calls`, { page, page_size: PAGE }),
  appDeliveries: (id: number, page: number) => http.get<Paged<WebhookDelivery>>(`${A}/open-apps/${id}/deliveries`, { page, page_size: PAGE }),
  redeliver: (id: number, did: number) => http.post<WebhookDelivery>(`${A}/open-apps/${id}/deliveries/${did}/redeliver`),
  testWebhook: (id: number) => http.post<WebhookDelivery>(`${A}/open-apps/${id}/test-webhook`),
};
