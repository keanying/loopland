import { Navigate, useLocation, useNavigate } from 'react-router-dom';
import { Result, Segmented } from 'antd';
import { useMerchantNav } from './navItems';

/** Sub-navigation of the 「商户与活动」 group, for PageHeader `extra`. */
export function MerchantNav() {
  const items = useMerchantNav();
  const loc = useLocation();
  const navigate = useNavigate();
  const current = items.find((i) => loc.pathname === i.to || loc.pathname.startsWith(i.to + '/'))?.to;
  if (items.length < 2) return null;
  return <Segmented className="mer-nav" value={current} onChange={(v) => navigate(String(v))} options={items.map((i) => ({ label: i.label, value: i.to }))} />;
}

/** /merchant → the first page of the group this role may open. */
export function MerchantHome() {
  const items = useMerchantNav();
  if (!items.length) return <Result status="403" title="没有权限" subTitle="当前角色没有权限访问商户与活动" />;
  return <Navigate to={items[0].to} replace />;
}
