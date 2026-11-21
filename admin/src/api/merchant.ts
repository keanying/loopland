// V2 第四批「本地生活与商户」· 商户 / 场馆 / 订场 / 核销 / 结算 (docs/api/v2-4-本地生活与商户.md
// 「商户与员工」「场馆」「订场」「核销」「结算」). Types and one request function per endpoint; the
// 投放 / 联名活动 / 能量商城 side lives in perks.ts (Drop, Perk, MerchantRef come from there).
import { ADMIN_PREFIX } from '../config';
import { http } from './client';
import type { Drop, MerchantRef, Perk } from './perks';
import type { Items, LatLng, Paged, UserBrief } from './types';

const A = ADMIN_PREFIX;
const PAGE = 20;

// ---------- 商户 (M-24) ----------

export type MerchantType = 'venue' | 'brand' | 'store';
export type MerchantStatus = 'partner' | 'pending_sign' | 'reviewing' | 'suspended';

export interface Merchant {
  id: number;
  name: string;
  type: MerchantType;
  status: MerchantStatus;
  contact_name: string | null;
  /** Masked (138****1234); the full number only through revealPhone (admin, audited). */
  contact_phone: string | null;
  license_images: string[];
  /** 0–1 (0.1 = the platform keeps 10% of booking revenue). */
  booking_commission_rate: number;
  venue_count: number;
  drop_count: number;
  today_redemptions: number;
  created_at: string;
}

export interface MerchantStaff {
  id: number;
  username: string;
  is_disabled: boolean;
}

export interface MerchantDetail extends Merchant {
  venues: Venue[];
  drops: Drop[];
  staff: MerchantStaff[];
}

export interface MerchantInput {
  name: string;
  type: MerchantType;
  status: MerchantStatus;
  contact_name: string | null;
  /** Full number. Left out on edit = keep the stored one. */
  contact_phone?: string | null;
  license_images: string[];
  booking_commission_rate: number;
}

// ---------- 场馆 (C-07 / C-08 / E-03) ----------

export type VenueSport = 'basketball' | 'football' | 'badminton' | 'pickleball' | 'tennis' | 'swimming' | 'climbing' | 'gym';

export interface VenueOwner {
  user: UserBrief;
  points: number;
  since: string;
}

export interface Venue {
  id: number;
  merchant: MerchantRef | null;
  name: string;
  sports: VenueSport[];
  center: LatLng;
  address: string;
  district: string;
  tags: string[];
  cover_url: string | null;
  checkin_radius_m: number;
  bookable: boolean;
  /** 分 per price_unit. */
  price_amt: number | null;
  price_unit: 'hour' | string;
  owner: VenueOwner | null;
  /** 0.8 = 八折; null = no discount. */
  owner_discount_rate: number | null;
  // Editable fields of the admin form; the contract's Venue shape leaves them out, so they are optional.
  slot_minutes?: number;
  open_time?: string;
  close_time?: string;
  court_qty?: number;
  is_disabled?: boolean;
}

export interface VenueInput {
  merchant_id: number | null;
  name: string;
  sports: VenueSport[];
  center: LatLng;
  address: string;
  district: string;
  tags: string[];
  cover_url: string | null;
  checkin_radius_m: number;
  bookable: boolean;
  price_amt: number | null;
  slot_minutes: number;
  open_time: string;
  close_time: string;
  court_qty: number;
  owner_discount_rate: number | null;
  is_disabled: boolean;
}

export interface VenueFilter {
  merchant_id?: number | null;
  sport?: VenueSport | '';
  q?: string;
  page?: number;
  page_size?: number;
}

export interface VenueQr {
  /** LPV.<venue_id>.<签名>: what the QR encodes. */
  payload: string;
  /** Universal link https://<domain>/v/<payload> (system camera). */
  url: string;
}

export interface VenueOwnerWeek {
  week_start: string;
  user: UserBrief;
  points: number;
}

// ---------- 订场 (E-03 / D-11) ----------

export type BookingStatus = 'pending_pay' | 'paid' | 'cancelled' | 'refunding' | 'refunded' | 'completed' | 'expired';

export interface Booking {
  id: number;
  booking_no: string;
  venue: { id: number; name: string };
  start_time: string;
  end_time: string;
  court_qty: number;
  amount_amt: number;
  original_amt: number;
  discount_type: 'owner' | 'none';
  status: BookingStatus;
  meetup_id: number | null;
  pay: { order_no: string; channel: string } | null;
  cancel_deadline: string;
  created_at: string;
  /** Admin list only. */
  user?: { id: number; nickname: string };
}

export interface BookingFilter {
  venue_id?: number | null;
  status?: BookingStatus | '';
  date?: string;
  page?: number;
  page_size?: number;
}

// ---------- 核销 (A-16 / E-04) ----------

export type CouponStatus = 'unused' | 'used' | 'expired' | 'voided';

export interface Coupon {
  id: number;
  code: string;
  perk: Perk;
  merchant: MerchantRef;
  source: { type: 'supply' | 'chest' | 'stronghold'; drop_id: number; name: string };
  status: CouponStatus;
  obtained_at: string;
  expires_at: string;
  used_at: string | null;
  used_store: string | null;
}

export interface Redemption {
  id: number;
  coupon: Coupon;
  user: { id: number; nickname: string };
  store: string | null;
  created_at: string;
  /** 风控作废了当天的运动记录 → 不结算 (list only; not in the contract's redemption shape). */
  voided?: boolean;
}

export type RedeemBody = { payload: string } | { code: string };

export interface RedemptionFilter {
  merchant_id?: number | null;
  from?: string;
  to?: string;
  page?: number;
  page_size?: number;
}

// ---------- 结算 (M-27) ----------

export type StatementStatus = 'draft' | 'confirmed' | 'paid';

export interface Statement {
  id: number;
  statement_no: string;
  merchant: MerchantRef;
  period_start: string;
  period_end: string;
  redemption_qty: number;
  voided_qty: number;
  redemption_amt: number;
  redemption_direction: 'merchant_pays' | 'platform_pays';
  booking_qty: number;
  booking_amt: number;
  booking_commission_amt: number;
  /** > 0: the merchant pays the platform; < 0: the platform pays the merchant. */
  net_amt: number;
  status: StatementStatus;
  confirmed_by: number | { id: number; username: string } | null;
  confirmed_at: string | null;
  paid_at: string | null;
}

export interface StatementLine {
  type: 'redemption' | 'booking';
  ref_no: string;
  user: { id: number; nickname: string };
  amount_amt: number;
  created_at: string;
  voided: boolean;
}

export interface StatementDetail extends Statement {
  lines: StatementLine[];
}

export interface SettlementDay {
  date: string;
  redemptions: number;
  voided: number;
  bookings: number;
}

export interface SettlementOverview {
  days: SettlementDay[];
  pending_statements: number;
}

// ---------- requests ----------

export const merchantApi = {
  merchants: (p: { status?: MerchantStatus | ''; q?: string; page?: number; page_size?: number }) =>
    http.get<Paged<Merchant>>(`${A}/merchants`, { page_size: PAGE, ...p }),
  merchant: (id: number) => http.get<MerchantDetail>(`${A}/merchants/${id}`),
  createMerchant: (body: MerchantInput) => http.post<Merchant>(`${A}/merchants`, body),
  updateMerchant: (id: number, body: Partial<MerchantInput>) => http.patch<Merchant>(`${A}/merchants/${id}`, body),
  /** Not spelled out in the contract (「管理员查看完整号码记审计」); mirrors POST /users/{id}/reveal-phone. */
  revealMerchantPhone: (id: number) => http.post<{ phone: string }>(`${A}/merchants/${id}/reveal-phone`),
  createStaff: (id: number, body: { username: string; password: string }) => http.post<Record<string, never>>(`${A}/merchants/${id}/staff`, body),

  venues: (p: VenueFilter) => http.get<Paged<Venue>>(`${A}/venues`, { page_size: PAGE, ...p }),
  createVenue: (body: VenueInput) => http.post<Venue>(`${A}/venues`, body),
  updateVenue: (id: number, body: Partial<VenueInput>) => http.patch<Venue>(`${A}/venues/${id}`, body),
  venueQr: (id: number) => http.get<VenueQr>(`${A}/venues/${id}/qr`),
  rotateVenueQr: (id: number) => http.post<VenueQr>(`${A}/venues/${id}/qr/rotate`),
  venueOwners: (id: number) => http.get<Items<VenueOwnerWeek>>(`${A}/venues/${id}/owners`),

  bookings: (p: BookingFilter) => http.get<Paged<Booking>>(`${A}/bookings`, { page_size: PAGE, ...p }),
  refundBooking: (id: number, reason: string) => http.post<Booking>(`${A}/bookings/${id}/refund`, { reason }),

  redeem: (body: RedeemBody) => http.post<{ redemption: Redemption }>(`${A}/redemptions`, body),
  redemptions: (p: RedemptionFilter) => http.get<Paged<Redemption>>(`${A}/redemptions`, { page_size: PAGE, ...p }),

  settlementOverview: (days = 7) => http.get<SettlementOverview>(`${A}/settlement/overview`, { days }),
  statements: (p: { merchant_id?: number | null; status?: StatementStatus | ''; page?: number; page_size?: number }) =>
    http.get<Paged<Statement>>(`${A}/statements`, { page_size: PAGE, ...p }),
  statement: (id: number) => http.get<StatementDetail>(`${A}/statements/${id}`),
  confirmStatement: (id: number) => http.post<Statement>(`${A}/statements/${id}/confirm`),
  markStatementPaid: (id: number) => http.post<Statement>(`${A}/statements/${id}/paid`),
  generateStatements: (periodStart: string) => http.post<unknown>(`${A}/statements/generate`, { period_start: periodStart }),
};
