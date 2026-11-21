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
        <Route index element={<DashboardPage />} />
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
        <Route path="settings/ai-usage" element={<Navigate to="/ai-usage" replace />} />
        <Route path="*" element={<Result status="404" title="页面不存在" />} />
      </Route>
    </Routes>
  );
}
