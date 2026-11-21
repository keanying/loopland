// 「商户与活动」menu group: one sidebar entry (/merchant) and a sub-navigation (nav.tsx) across its pages.
// Add new pages of the group here (and their routes in App.tsx); entries the current role cannot see are hidden.
import { useAuth } from '../../auth/AuthContext';
import type { Permission } from '../../auth/permissions';

export interface MerchantNavItem {
  to: string;
  label: string;
  perm: Permission;
  /** Label for merchant staff (role merchant) when it differs. */
  staffLabel?: string;
}

export const MERCHANT_NAV: MerchantNavItem[] = [
  { to: '/merchant/merchants', label: '商户', perm: 'merchant.read' },
  { to: '/merchant/venues', label: '场馆', perm: 'venue.read' },
  { to: '/merchant/drops', label: '投放', perm: 'perks.read' },
  { to: '/merchant/campaigns', label: '联名活动', perm: 'perks.read' },
  { to: '/merchant/bookings', label: '订场', perm: 'booking.read', staffLabel: '场馆预订' },
  { to: '/merchant/settlement', label: '核销结算', perm: 'settlement.read', staffLabel: '结算单' },
  { to: '/merchant/redeem', label: '核销台', perm: 'redeem' },
  { to: '/merchant/redemptions', label: '核销记录', perm: 'redemption.read' },
  { to: '/merchant/shop', label: '能量商城', perm: 'perks.read' },
];

/** The group's pages this role may open (merchant staff: 核销台 first). */
export function useMerchantNav(): MerchantNavItem[] {
  const { can, admin } = useAuth();
  const staff = admin?.role === 'merchant';
  const items = MERCHANT_NAV.filter((i) => can(i.perm)).map((i) => (staff && i.staffLabel ? { ...i, label: i.staffLabel } : i));
  return staff ? [...items.filter((i) => i.to === '/merchant/redeem'), ...items.filter((i) => i.to !== '/merchant/redeem')] : items;
}
