// V2 第四批「本地生活与商户」· 投放 / 联名活动 / 能量商城 (docs/api/v2-4-本地生活与商户.md
// 「投放与联名权益」「联名活动」「能量商城」). Types and one request function per endpoint; kept
// apart from admin.ts / types.ts so the 商户 / 场馆 / 结算 pages can grow those files independently.
import { ADMIN_PREFIX } from '../config';
import { http } from './client';
import type { Items, LatLng, Paged } from './types';

const A = ADMIN_PREFIX;

// ---------- shared ----------

export interface MerchantRef {
  id: number;
  name: string;
}

/** The subset of Merchant (「商户与员工」) the 投放 / 联名活动 forms need. */
export interface MerchantOption extends MerchantRef {
  type?: 'venue' | 'brand' | 'store' | string;
  status: 'partner' | 'pending_sign' | 'reviewing' | 'suspended' | string;
}

/** The subset of Venue (「场馆」) the 据点 picker needs. */
export interface VenueOption {
  id: number;
  name: string;
  merchant: MerchantRef | null;
  center: LatLng;
  address?: string;
  district?: string;
  sports?: string[];
  checkin_radius_m?: number;
}

// ---------- 投放 (M-25) ----------

export interface Perk {
  title: string;
  description: string;
  value_text: string;
  valid_days: number;
  rules: string;
}

export type DropType = 'supply' | 'chest' | 'stronghold';
export type DropStatus = 'scheduled' | 'active' | 'paused' | 'ended';
export type SettleDirection = 'merchant_pays' | 'platform_pays';

export interface Drop {
  id: number;
  merchant: MerchantRef;
  campaign_id: number | null;
  type: DropType;
  name: string;
  center: LatLng;
  radius_m: number;
  venue_id: number | null;
  perk: Perk;
  daily_cap: number;
  issued_today: number;
  redeemed_today: number;
  start_time: string;
  end_time: string;
  status: DropStatus;
  settle_price_amt: number;
  settle_direction: SettleDirection;
}

export interface DropInput {
  merchant_id: number;
  campaign_id: number | null;
  type: DropType;
  name: string;
  /** null for 据点: the venue's centre is used. */
  center: LatLng | null;
  radius_m: number;
  venue_id: number | null;
  perk: Perk;
  daily_cap: number;
  start_time: string;
  end_time: string;
  settle_price_amt: number;
  settle_direction: SettleDirection;
}

export interface DropFilter {
  merchant_id?: number | null;
  type?: DropType | '';
  status?: DropStatus | '';
  page?: number;
  page_size?: number;
}

// ---------- 联名活动 (M-26) ----------

export type BrandCampaignStatus = 'draft' | 'scheduled' | 'running' | 'paused' | 'ended';

export interface BrandCampaignStats {
  issued: number;
  redeemed: number;
  new_users: number;
  progress_rate: number;
}

export interface BrandCampaign {
  id: number;
  merchant: MerchantRef;
  title: string;
  description: string;
  cover_url: string | null;
  start_time: string;
  end_time: string;
  status: BrandCampaignStatus;
  store_count: number;
  drop_ids: number[];
  target_redemptions: number;
  /** 分 */
  merchant_investment_amt: number;
  stats: BrandCampaignStats;
}

export interface BrandCampaignInput {
  merchant_id: number;
  title: string;
  description: string;
  cover_url: string | null;
  start_time: string;
  end_time: string;
  store_count: number;
  drop_ids: number[];
  target_redemptions: number;
  merchant_investment_amt: number;
}

// ---------- 能量商城 (E-05) ----------

export type ShopItemType = 'territory_skin' | 'avatar_frame' | 'map_marker';
export type SkinPattern = 'solid' | 'grid' | 'stripe' | 'dots' | 'wave';

export interface ShopPreview {
  fill: string;
  stroke: string;
  pattern: SkinPattern | string;
}

export interface ShopItem {
  key: string;
  name: string;
  type: ShopItemType;
  price_energy: number;
  image_url: string | null;
  preview: ShopPreview | null;
  description: string;
  limited_until: string | null;
  on_sale: boolean;
}

export type ShopItemInput = Omit<ShopItem, 'key'> & { key?: string };

export interface ShopItemStat {
  key: string;
  redemptions: number;
  energy_spent: number;
}

export interface ShopStats {
  items: ShopItemStat[];
}

// ---------- requests ----------

const PAGE = 20;

export const perksApi = {
  // options for the forms (owned by the 商户 / 场馆 pages)
  merchantOptions: () => http.get<Paged<MerchantOption>>(`${A}/merchants`, { page_size: 100 }),
  venueOptions: (merchantId?: number | null) => http.get<Paged<VenueOption>>(`${A}/venues`, { merchant_id: merchantId ?? undefined, page_size: 100 }),

  drops: (p: DropFilter) => http.get<Paged<Drop>>(`${A}/drops`, { page_size: PAGE, ...p }),
  createDrop: (body: DropInput) => http.post<Drop>(`${A}/drops`, body),
  updateDrop: (id: number, body: Partial<DropInput>) => http.patch<Drop>(`${A}/drops/${id}`, body),
  pauseDrop: (id: number) => http.post<Drop>(`${A}/drops/${id}/pause`),
  resumeDrop: (id: number) => http.post<Drop>(`${A}/drops/${id}/resume`),

  campaigns: (p: { status?: BrandCampaignStatus | ''; page?: number; page_size?: number }) =>
    http.get<Paged<BrandCampaign>>(`${A}/brand-campaigns`, { page_size: PAGE, ...p }),
  createCampaign: (body: BrandCampaignInput) => http.post<BrandCampaign>(`${A}/brand-campaigns`, body),
  updateCampaign: (id: number, body: Partial<BrandCampaignInput>) => http.patch<BrandCampaign>(`${A}/brand-campaigns/${id}`, body),
  campaignAction: (id: number, action: 'pause' | 'resume' | 'launch') => http.post<BrandCampaign>(`${A}/brand-campaigns/${id}/${action}`),

  shopItems: (type?: ShopItemType | '') => http.get<Items<ShopItem>>(`${A}/shop/items`, { type }),
  createShopItem: (body: ShopItemInput) => http.post<ShopItem>(`${A}/shop/items`, body),
  updateShopItem: (key: string, body: Partial<ShopItemInput>) => http.patch<ShopItem>(`${A}/shop/items/${encodeURIComponent(key)}`, body),
  shopStats: () => http.get<ShopStats>(`${A}/shop/stats`),
};
