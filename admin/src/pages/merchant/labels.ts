// Chinese labels for V2 第四批「本地生活与商户」(商户 / 场馆 / 订场 / 核销 / 结算).
import type { BookingStatus, CouponStatus, MerchantStatus, MerchantType, StatementStatus, VenueSport } from '../../api/merchant';

export const MERCHANT_STATUS: Record<MerchantStatus, { text: string; color: string; hint: string }> = {
  partner: { text: '合作中', color: 'success', hint: '场馆可预订，投放正常发券' },
  pending_sign: { text: '待签约', color: 'warning', hint: '资质已过，等待签合同' },
  reviewing: { text: '资质审核', color: 'processing', hint: '运营录入后待审核营业执照等资质' },
  suspended: { text: '暂停', color: 'default', hint: '场馆不可预订、投放不再发券；已发的券仍可核销到有效期' },
};
export const MERCHANT_STATUS_ORDER: MerchantStatus[] = ['partner', 'pending_sign', 'reviewing', 'suspended'];

export const MERCHANT_TYPE: Record<MerchantType, string> = { venue: '场馆', brand: '品牌', store: '门店' };

export const VENUE_SPORT: Record<VenueSport, string> = {
  basketball: '篮球',
  football: '足球',
  badminton: '羽毛球',
  pickleball: '匹克球',
  tennis: '网球',
  swimming: '游泳',
  climbing: '攀岩',
  gym: '健身房',
};
export const VENUE_SPORTS = Object.keys(VENUE_SPORT) as VenueSport[];

export const BOOKING_STATUS: Record<BookingStatus, { text: string; color: string }> = {
  pending_pay: { text: '待支付', color: 'default' },
  paid: { text: '已支付', color: 'success' },
  cancelled: { text: '已取消', color: 'default' },
  refunding: { text: '退款中', color: 'warning' },
  refunded: { text: '已退款', color: 'default' },
  completed: { text: '已完成', color: 'blue' },
  expired: { text: '超时未付', color: 'default' },
};
export const BOOKING_STATUS_ORDER: BookingStatus[] = ['paid', 'pending_pay', 'refunding', 'refunded', 'completed', 'cancelled', 'expired'];

export const COUPON_STATUS: Record<CouponStatus, { text: string; color: string }> = {
  unused: { text: '未使用', color: 'success' },
  used: { text: '已核销', color: 'blue' },
  expired: { text: '已过期', color: 'default' },
  voided: { text: '已作废', color: 'error' },
};

export const DROP_TYPE_LABEL: Record<string, string> = { supply: '补给站', chest: '商户宝箱', stronghold: '据点' };
export const DROP_STATUS_LABEL: Record<string, { text: string; color: string }> = {
  scheduled: { text: '未开始', color: 'default' },
  active: { text: '发券中', color: 'success' },
  paused: { text: '已暂停', color: 'warning' },
  ended: { text: '已结束', color: 'default' },
};

export const STATEMENT_STATUS: Record<StatementStatus, { text: string; color: string }> = {
  draft: { text: '待确认', color: 'warning' },
  confirmed: { text: '已确认 · 待付款', color: 'processing' },
  paid: { text: '已付款', color: 'success' },
};

export const SETTLE_DIRECTION: Record<string, string> = { merchant_pays: '商户付平台（服务费）', platform_pays: '平台付商户（补贴）' };

/** POST /admin/v1/redemptions error codes → what the counter staff reads. */
export const REDEEM_ERROR: Record<string, { title: string; hint: string }> = {
  invalid_coupon: { title: '券码无效', hint: '核对券码后重试；二维码请让顾客在 App 里重新打开' },
  coupon_used: { title: '这张券已经核销过了', hint: '每张券只能核销一次' },
  coupon_expired: { title: '券已过期', hint: '券或二维码已过有效期；二维码 60 秒刷新，请让顾客刷新后重扫' },
  wrong_merchant: { title: '不是本店的券', hint: '请让顾客到发券的商户门店使用' },
  no_activity_today: { title: '今天还没有运动记录', hint: '顾客今天运动后再来核销' },
  daily_cap_reached: { title: '今日核销已达上限', hint: '这个投放今天的核销名额用完了，明天再来' },
  forbidden: { title: '没有核销权限', hint: '当前账号不能核销，请联系运营' },
  no_merchant: { title: '账号未绑定商户', hint: '请联系运营给这个账号绑定商户' },
  network: { title: '网络连接失败', hint: '检查网络后重试' },
};
