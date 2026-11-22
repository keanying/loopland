// Chinese labels and text helpers for V2 第五批「商户商品与开放平台」(商品 / 商品订单 / 官方活动 / 开放平台).
import type { EntryStatus, OpenScope, Product, ProductOrderStatus, ProductStatus, ProductType, PromotionStatus } from '../../api/commerce';
import { yuan } from '../../utils/format';

export const PRODUCT_TYPE: Record<ProductType, { text: string; hint: string }> = {
  package: { text: '套餐券', hint: '一次核销，含固定内容（如 2 小时场地 + 球拍）' },
  voucher: { text: '代金券', hint: '到店抵扣现金，门市价即面值' },
  pass: { text: '次卡', hint: '可核销多次，每次用掉 1 次' },
};
export const PRODUCT_TYPES = Object.keys(PRODUCT_TYPE) as ProductType[];

export const PRODUCT_STATUS: Record<ProductStatus, { text: string; color: string; hint: string }> = {
  draft: { text: '草稿', color: 'default', hint: '还没提交审核，App 不可见' },
  reviewing: { text: '审核中', color: 'processing', hint: '等待平台人工审核' },
  on_sale: { text: '在售', color: 'success', hint: 'App 场馆页、商户页可见可买' },
  off_sale: { text: '已下架', color: 'default', hint: '商户自己下架；内容没改过可直接重新上架' },
  rejected: { text: '未通过', color: 'error', hint: '审核没通过，按原因修改后重新提交' },
  banned: { text: '平台下架', color: 'error', hint: '平台强制下架，商户不能自行上架，修改后重新提交审核' },
};
export const PRODUCT_STATUS_ORDER: ProductStatus[] = ['on_sale', 'reviewing', 'draft', 'off_sale', 'rejected', 'banned'];

export const ORDER_STATUS: Record<ProductOrderStatus, { text: string; color: string }> = {
  pending: { text: '待支付', color: 'default' },
  paid: { text: '已支付', color: 'success' },
  completed: { text: '已完成', color: 'blue' },
  refunding: { text: '退款中', color: 'warning' },
  refunded: { text: '已退款', color: 'default' },
  cancelled: { text: '已取消', color: 'default' },
};
export const ORDER_STATUS_ORDER: ProductOrderStatus[] = ['paid', 'completed', 'pending', 'refunding', 'refunded', 'cancelled'];

export const PROMOTION_STATUS: Record<PromotionStatus, { text: string; color: string }> = {
  draft: { text: '草稿', color: 'default' },
  scheduled: { text: '未开始', color: 'processing' },
  active: { text: '进行中', color: 'success' },
  ended: { text: '已结束', color: 'default' },
  cancelled: { text: '已取消', color: 'default' },
};
export const PROMOTION_STATUS_ORDER: PromotionStatus[] = ['active', 'scheduled', 'draft', 'ended', 'cancelled'];

export const ENTRY_STATUS: Record<EntryStatus, { text: string; color: string; staff?: string }> = {
  pending_merchant: { text: '待商户同意', color: 'warning', staff: '待我确认' },
  pending_platform: { text: '待审核', color: 'processing', staff: '待平台审核' },
  active: { text: '已生效', color: 'success' },
  rejected: { text: '已拒绝', color: 'error' },
  withdrawn: { text: '商户已退出', color: 'default', staff: '已退出' },
  removed: { text: '平台已移除', color: 'default' },
};
export const ENTRY_STATUS_ORDER: EntryStatus[] = ['pending_platform', 'pending_merchant', 'active', 'rejected', 'withdrawn', 'removed'];
export const ENTRY_SOURCE: Record<string, string> = { platform: '平台选品', merchant: '商户报名' };

export const OPEN_SCOPE: Record<OpenScope, { text: string; hint: string }> = {
  products: { text: '商品', hint: '查询、新建、修改、上下架商品，改库存' },
  orders: { text: '商品订单', hint: '查询商品订单' },
  redemptions: { text: '核销', hint: '收银台查券、核销，查核销记录' },
  bookings: { text: '订场', hint: '查询场馆预订' },
  venues: { text: '场馆与占场', hint: '改场馆价格 / 营业时间等，查时段，同步线下订场占场' },
  promotions: { text: '官方活动', hint: '查可报名活动、报名、接受 / 拒绝邀请、退出' },
  statements: { text: '结算单', hint: '查询结算单和明细' },
};
export const OPEN_SCOPES = Object.keys(OPEN_SCOPE) as OpenScope[];

/** Webhook events and the scope each needs (only pushed when the app has it). */
export const WEBHOOK_EVENT: Record<string, { text: string; scope: OpenScope | null }> = {
  'product.reviewed': { text: '商品审核结果', scope: 'products' },
  'promotion_entry.invited': { text: '平台邀请商品参加活动', scope: 'promotions' },
  'promotion_entry.approved': { text: '活动报名通过', scope: 'promotions' },
  'promotion_entry.rejected': { text: '活动报名被驳回', scope: 'promotions' },
  'promotion_entry.removed': { text: '活动商品被移除', scope: 'promotions' },
  'product_order.paid': { text: '商品订单已支付', scope: 'orders' },
  'product_order.refunded': { text: '商品订单已退款', scope: 'orders' },
  'booking.paid': { text: '订场已支付', scope: 'bookings' },
  'booking.cancelled': { text: '订场已取消', scope: 'bookings' },
  'booking.refunded': { text: '订场已退款', scope: 'bookings' },
  'redemption.created': { text: '券已核销', scope: 'redemptions' },
  'redemption.voided': { text: '核销被风控作废', scope: 'redemptions' },
  'statement.created': { text: '结算单已生成', scope: 'statements' },
  ping: { text: '测试 ping', scope: null },
};
export const WEBHOOK_EVENTS = Object.keys(WEBHOOK_EVENT).filter((e) => e !== 'ping');

export const DELIVERY_STATUS: Record<string, { text: string; color: string }> = {
  pending: { text: '重试中', color: 'warning' },
  succeeded: { text: '成功', color: 'success' },
  failed: { text: '失败', color: 'error' },
};

/** Open-platform error codes → what the merchant reads in the call log. */
export const OPEN_ERROR: Record<string, string> = {
  invalid_signature: '签名不对或缺少签名头',
  timestamp_expired: '时间戳与服务器相差超过 300 秒',
  nonce_reused: 'nonce 10 分钟内重复',
  invalid_app: 'app_id 不存在',
  ip_not_allowed: 'IP 不在白名单',
  scope_denied: '应用没有这个接口的权限',
  rate_limited: '超过每分钟 120 次',
  app_disabled: '应用已停用',
  not_found: '对象不存在或不属于本商户',
  invalid_request: '参数不对',
  sold_out: '库存不足',
  slot_full: '场地已满',
};

/** 购买后 30 天 / 至 2026-12-31 */
export function validityText(p: Pick<Product, 'valid_days' | 'valid_until'>): string {
  if (p.valid_until) return `至 ${p.valid_until}`;
  if (p.valid_days) return `购买后 ${p.valid_days} 天`;
  return '—';
}

/** stock_qty is the remaining stock (null = 不限). */
export function stockText(p: Pick<Product, 'stock_qty'>): string {
  return p.stock_qty === null ? '不限' : p.stock_qty === 0 ? '已售罄' : `剩 ${p.stock_qty}`;
}

/** "-¥20（7.1 折）" style difference between the promo and the regular price. */
export function discountLine(promo: number, price: number): string {
  if (promo >= price) return '与原价相同';
  const z = +((promo / price) * 10).toFixed(1);
  return `比原价低 ${yuan(price - promo)}（${z} 折）`;
}
