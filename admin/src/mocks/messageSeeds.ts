// Seed messages for the 站内信 mock (mocks/messages.ts), built on first use from the commerce / merchant mocks so
// every link opens something that exists: `shop` (跑野运动馆 #2) gets product, promotion, settlement, order and
// open-platform messages; admin / ops get review and promotion-application messages (review ones go to reviewer too).
import type { MessageDraft } from './messages';
import { addMessages, enabled, setInboxSeeder, staffOf, yuanText } from './messages';
import { merchants, statementMessagesOf } from './merchant';
import { commerceRows } from './commerce';

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const merchantName = (id: number) => merchants.find((m) => m.id === id)?.name ?? `商户 ${id}`;

setInboxSeeder(() => {
  const now = Date.now();
  const ago = (ms: number) => now - ms;
  const products = commerceRows.products();
  const title = (id: number) => products.find((p) => p.id === id)?.title ?? `商品 #${id}`;
  const promo = (id: number) => commerceRows.promotions().find((p) => p.id === id)?.title ?? `活动 #${id}`;
  const shop = 2;
  const staff = staffOf(shop);
  const platform = enabled(['admin', 'ops']);
  const reviewers = enabled(['admin', 'ops', 'reviewer']);

  // ---------- merchant 跑野运动馆 (`shop`)
  const m = (d: MessageDraft, at: number, read = false) => addMessages(staff, d, at, read);
  m({ category: 'system', level: 'info', title: '欢迎使用圈圈商户后台', body: '商品、官方活动、结算单和开放平台的通知都会出现在这里，右上角铃铛显示未读数。' }, ago(30 * DAY), true);
  m({ category: 'openapi', level: 'info', title: '应用「收银系统」已被平台启用', body: '可以继续用它调用开放接口。', link: '/merchant/open-apps?id=3' }, ago(20 * DAY), true);
  m({ category: 'promotion', level: 'info', title: `商品「${title(31)}」已加入「${promo(1)}」`, body: '平台按原价直接加入，活动期间 App 专题页展示。', link: '/merchant/promotions?tab=mine' }, ago(52 * DAY), true);
  m({ category: 'product', level: 'success', title: `商品「${title(35)}」的修改已生效`, body: '新的标题和图片已替换线上内容。', link: '/merchant/products?id=35' }, ago(9 * DAY), true);
  const p38 = products.find((p) => p.id === 38);
  m({ category: 'product', level: 'error', title: `商品「${title(38)}」已被平台下架：${p38?.review_note ?? '门市价虚标'}`, body: '修改后可以重新提交审核。', link: '/merchant/products?id=38' }, ago(6 * DAY), true);
  m({ category: 'promotion', level: 'success', title: `商品「${title(31)}」报名「${promo(2)}」已通过`, body: '活动期间 App 按活动价售卖。', link: '/merchant/promotions?tab=mine' }, ago(5 * DAY), true);
  const refunded = commerceRows.orders().find((o) => o.merchant_id === shop && o.status === 'refunded');
  if (refunded)
    m({ category: 'product', level: 'info', title: `订单 ${refunded.order_no} 已由平台退款 ${yuanText(refunded.refund_amt || refunded.amount_amt)}：用户到店时场地已满`, body: '平台退款的订单不进结算单。', link: `/merchant/product-orders?id=${refunded.id}` }, ago(3 * DAY), true);
  // Statements: newest (draft, unread) and the two before it (read).
  statementMessagesOf(shop)
    .slice(0, 3)
    .forEach((s, i) => m(s.draft, Math.min(Date.parse(s.at), ago((i + 1) * 20 * HOUR)), i > 0));
  m({ category: 'product', level: 'warning', title: `商品「${title(36)}」未通过审核：图片里有微信二维码`, body: products.find((p) => p.id === 36)?.review_note ?? null, link: '/merchant/products?id=36' }, ago(2 * DAY));
  const invite = commerceRows.entries().find((e) => e.status === 'pending_merchant' && products.find((p) => p.id === e.product_id)?.merchant_id === shop);
  if (invite)
    m({ category: 'promotion', level: 'info', title: `「${promo(invite.promotion_id)}」邀请你的商品「${title(invite.product_id)}」参加，活动价 ${yuanText(invite.promo_price_amt)}`, body: invite.platform_subsidy_amt ? `平台每核销一件补贴 ${yuanText(invite.platform_subsidy_amt)}，同意后生效。` : '同意后生效。', link: '/merchant/promotions?tab=invites' }, ago(20 * HOUR));
  m({ category: 'openapi', level: 'error', title: '应用「收银系统」有 1 条回调推送失败', body: 'product_order.paid 回调 6 次都没有收到 2xx 响应，请检查 Webhook 地址。', link: '/merchant/open-apps?id=3' }, ago(5 * HOUR));
  m({ category: 'product', level: 'success', title: `商品「${title(31)}」审核通过，已上架`, body: '可在「商品」里查看。', link: '/merchant/products?id=31' }, ago(35 * MIN));

  // ---------- platform (admin / ops; review ones also reviewer)
  const p = (d: MessageDraft, at: number, read = false) => addMessages(d.category === 'review' ? reviewers : platform, d, at, read);
  p({ category: 'system', level: 'info', title: '管理端站内信上线', body: '审核、官方活动报名等待处理的事项会通知到这里。' }, ago(14 * DAY), true);
  const entries = commerceRows.entries();
  for (const e of entries) {
    const prod = products.find((x) => x.id === e.product_id);
    if (!prod) continue;
    const at = Date.parse(e.created_at);
    const link = `/merchant/promotions?id=${e.promotion_id}`;
    if (e.status === 'pending_platform')
      p({ category: 'promotion', level: 'info', title: `商户「${merchantName(prod.merchant_id)}」报名「${promo(e.promotion_id)}」：商品「${prod.title}」`, body: `活动价 ${yuanText(e.promo_price_amt)}，待审核。`, link }, at, at < ago(28 * HOUR));
    if (e.status === 'withdrawn') p({ category: 'promotion', level: 'info', title: `商户「${merchantName(prod.merchant_id)}」退出了「${promo(e.promotion_id)}」`, body: `商品「${prod.title}」`, link }, at + DAY, true);
  }
  for (const prod of products.filter((x) => x.status === 'reviewing'))
    p({ category: 'review', level: 'info', title: `商户「${merchantName(prod.merchant_id)}」提交了商品「${prod.title}」，待审核`, link: '/review?type=product' }, ago(((prod.id % 7) + 1) * HOUR), false);
});
