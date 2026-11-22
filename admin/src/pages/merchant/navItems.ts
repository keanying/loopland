// 「商户与活动」menu group: one sidebar entry (/merchant) and a sub-navigation (nav.tsx) across its pages.
// Add new pages of the group here (and their routes in App.tsx); entries the current role cannot see are hidden.
import { useAuth } from '../../auth/AuthContext';
import type { Permission } from '../../auth/permissions';

export interface MerchantNavItem {
  to: string;
  label: string;
  /** Shown when the role has any of these. */
  perm: Permission | Permission[];
  /** Label for merchant staff (role merchant) when it differs. */
  staffLabel?: string;
  /** Only for merchant staff (开放平台: admins see a merchant's apps in its detail instead). */
  staffOnly?: boolean;
}

export const MERCHANT_NAV: MerchantNavItem[] = [
  { to: '/merchant/merchants', label: '商户', perm: 'merchant.read' },
  { to: '/merchant/venues', label: '场馆', perm: ['venue.read', 'venue.self'] },
  // V2 第五批「商户商品与开放平台」
  { to: '/merchant/products', label: '商品', perm: 'product.read' },
  { to: '/merchant/product-orders', label: '商品订单', perm: 'product.read' },
  { to: '/merchant/promotions', label: '官方活动', perm: ['promotion.manage', 'promotion.join'] },
  { to: '/merchant/drops', label: '投放', perm: 'perks.read' },
  { to: '/merchant/campaigns', label: '联名活动', perm: 'perks.read' },
  { to: '/merchant/bookings', label: '订场', perm: 'booking.read', staffLabel: '场馆预订' },
  { to: '/merchant/settlement', label: '核销结算', perm: 'settlement.read', staffLabel: '结算单' },
  { to: '/merchant/redeem', label: '核销台', perm: 'redeem' },
  { to: '/merchant/redemptions', label: '核销记录', perm: 'redemption.read' },
  { to: '/merchant/shop', label: '能量商城', perm: 'perks.read' },
  { to: '/merchant/open-apps', label: '开放平台', perm: 'openapi.manage', staffOnly: true },
];

/** Merchant staff order (docs/api/v2-5 「管理端页面」): 核销台 first. */
const STAFF_ORDER = [
  '/merchant/redeem',
  '/merchant/products',
  '/merchant/product-orders',
  '/merchant/promotions',
  '/merchant/bookings',
  '/merchant/venues',
  '/merchant/settlement',
  '/merchant/redemptions',
  '/merchant/open-apps',
];

export function canAny(can: (p: Permission) => boolean, perm: Permission | Permission[]): boolean {
  return (Array.isArray(perm) ? perm : [perm]).some((p) => can(p));
}

/** The group's pages this role may open (merchant staff: 核销台 first). */
export function useMerchantNav(): MerchantNavItem[] {
  const { can, admin } = useAuth();
  const staff = admin?.role === 'merchant';
  const items = MERCHANT_NAV.filter((i) => canAny(can, i.perm) && (!i.staffOnly || staff)).map((i) => (staff && i.staffLabel ? { ...i, label: i.staffLabel } : i));
  if (!staff) return items;
  const rank = (to: string) => (STAFF_ORDER.includes(to) ? STAFF_ORDER.indexOf(to) : STAFF_ORDER.length);
  return [...items].sort((a, b) => rank(a.to) - rank(b.to));
}
