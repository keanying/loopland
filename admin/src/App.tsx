import { useEffect, type ReactNode } from 'react';
import { Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { App as AntApp, Result, Spin } from 'antd';
import { useAuth } from './auth/AuthContext';
import type { Permission } from './auth/permissions';
import { setNotifier } from './utils/notify';
import AppLayout from './components/AppLayout';
import LoginPage from './pages/LoginPage';
import DashboardPage from './pages/DashboardPage';
import UsersPage from './pages/UsersPage';
import PlansPage from './pages/PlansPage';
import TerritoriesPage from './pages/TerritoriesPage';
import RiskPage from './pages/RiskPage';
import GameplayPage from './pages/GameplayPage';
import OperationsPage from './pages/OperationsPage';
import AuditPage from './pages/AuditPage';
import AdminsPage from './pages/AdminsPage';
import ProvidersPage from './pages/ProvidersPage';
import ReviewPage from './pages/ReviewPage';
import CommunityPage from './pages/CommunityPage';
import AIUsagePage from './pages/AIUsagePage';
// V2 第四批「本地生活与商户」· 商户与活动 group (pages/merchant/navItems.ts)
import { MerchantHome } from './pages/merchant/nav';
import MerchantsPage from './pages/merchant/MerchantsPage';
import VenuesPage from './pages/merchant/VenuesPage';
import BookingsPage from './pages/merchant/BookingsPage';
import SettlementPage from './pages/merchant/SettlementPage';
import RedeemPage from './pages/merchant/RedeemPage';
import RedemptionsPage from './pages/merchant/RedemptionsPage';
import DropsPage from './pages/merchant/DropsPage';
import BrandCampaignsPage from './pages/merchant/BrandCampaignsPage';
import ShopPage from './pages/merchant/ShopPage';

function RequireAuth({ children }: { children: ReactNode }) {
  const { admin, loading } = useAuth();
  const loc = useLocation();
  if (loading) {
    return (
      <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Spin size="large" />
      </div>
    );
  }
  if (!admin) return <Navigate to="/login" replace state={{ from: loc.pathname + loc.search }} />;
  return <>{children}</>;
}

function RequirePerm({ perm, children }: { perm: Permission; children: ReactNode }) {
  const { can } = useAuth();
  if (!can(perm)) return <Result status="403" title="没有权限" subTitle="当前角色没有权限访问这个页面" />;
  return <>{children}</>;
}

/** 总览; merchant staff (no dashboard) land on their 核销台 instead. */
function Home() {
  const { can } = useAuth();
  return can('dashboard.read') ? <DashboardPage /> : <MerchantHome />;
}

function KeepQuery({ to }: { to: string }) {
  const loc = useLocation();
  return <Navigate to={to + loc.search} replace />;
}

/** /orders?status=… (links from 总览 todos) lives on the 订单 tab of 会员套餐与订单. */
function OrdersRedirect() {
  const loc = useLocation();
  const params = new URLSearchParams(loc.search);
  params.set('tab', 'orders');
  return <Navigate to={`/plans?${params.toString()}`} replace />;
}

export default function App() {
  const app = AntApp.useApp();
  useEffect(() => setNotifier(app), [app]);

  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route
        element={
          <RequireAuth>
            <AppLayout />
          </RequireAuth>
        }
      >
        <Route index element={<Home />} />
        <Route path="users" element={<RequirePerm perm="users.read"><UsersPage /></RequirePerm>} />
        <Route path="plans" element={<RequirePerm perm="plans.read"><PlansPage /></RequirePerm>} />
        <Route path="orders" element={<OrdersRedirect />} />
        <Route path="territories" element={<RequirePerm perm="territories.read"><TerritoriesPage /></RequirePerm>} />
        <Route path="map" element={<Navigate to="/territories" replace />} />
        <Route path="risk" element={<RequirePerm perm="risk.read"><RiskPage /></RequirePerm>} />
        <Route path="review" element={<RequirePerm perm="review.read"><ReviewPage /></RequirePerm>} />
        <Route path="community" element={<RequirePerm perm="community.read"><CommunityPage /></RequirePerm>} />
        <Route path="operations" element={<RequirePerm perm="ops.read"><OperationsPage /></RequirePerm>} />
        <Route path="gameplay" element={<RequirePerm perm="gameplay.read"><GameplayPage /></RequirePerm>} />
        <Route
          path="audit"
          element={
            <RequirePerm perm="audit.read">
              <AuditPage />
            </RequirePerm>
          }
        />
        <Route
          path="admins"
          element={
            <RequirePerm perm="admins.manage">
              <AdminsPage />
            </RequirePerm>
          }
        />
        <Route path="settings" element={<Navigate to="/settings/providers" replace />} />
        <Route
          path="settings/providers"
          element={
            <RequirePerm perm="settings.providers">
              <ProvidersPage />
            </RequirePerm>
          }
        />
        <Route path="ai-usage" element={<RequirePerm perm="ai.usage"><AIUsagePage /></RequirePerm>} />
        <Route path="merchant" element={<MerchantHome />} />
        {/* Short links (e.g. 总览 todo links from the API) → the group's pages, keeping the query. */}
        <Route path="merchants" element={<KeepQuery to="/merchant/merchants" />} />
        <Route path="venues" element={<KeepQuery to="/merchant/venues" />} />
        <Route path="bookings" element={<KeepQuery to="/merchant/bookings" />} />
        <Route path="statements" element={<KeepQuery to="/merchant/settlement" />} />
        <Route path="settlement" element={<KeepQuery to="/merchant/settlement" />} />
        <Route path="redemptions" element={<KeepQuery to="/merchant/redemptions" />} />
        <Route path="merchant/merchants" element={<RequirePerm perm="merchant.read"><MerchantsPage /></RequirePerm>} />
        <Route path="merchant/venues" element={<RequirePerm perm="venue.read"><VenuesPage /></RequirePerm>} />
        <Route path="merchant/bookings" element={<RequirePerm perm="booking.read"><BookingsPage /></RequirePerm>} />
        <Route path="merchant/settlement" element={<RequirePerm perm="settlement.read"><SettlementPage /></RequirePerm>} />
        <Route path="merchant/redeem" element={<RequirePerm perm="redeem"><RedeemPage /></RequirePerm>} />
        <Route path="merchant/redemptions" element={<RequirePerm perm="redemption.read"><RedemptionsPage /></RequirePerm>} />
        <Route path="merchant/drops" element={<RequirePerm perm="perks.read"><DropsPage /></RequirePerm>} />
        <Route path="merchant/campaigns" element={<RequirePerm perm="perks.read"><BrandCampaignsPage /></RequirePerm>} />
        <Route path="merchant/shop" element={<RequirePerm perm="perks.read"><ShopPage /></RequirePerm>} />
        <Route path="settings/ai-usage" element={<Navigate to="/ai-usage" replace />} />
        <Route path="*" element={<Result status="404" title="页面不存在" />} />
      </Route>
    </Routes>
  );
}
