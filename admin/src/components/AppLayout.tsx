import { type ReactNode } from 'react';
import { NavLink, Outlet, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Tooltip } from 'antd';
import { api } from '../api/admin';
import { useAuth } from '../auth/AuthContext';
import type { Permission } from '../auth/permissions';
import Logo from './Logo';
import { useMerchantNav } from '../pages/merchant/navItems';
import { Glyph } from './Glyph';

interface MenuItem {
  to: string;
  label: string;
  icon: ReactNode;
  v2?: boolean;
  perm?: Permission;
  /** 商户与活动: shown when the role may open any page of the group. */
  group?: boolean;
}

const MENU: MenuItem[] = [
  { to: '/', label: '总览', icon: <Glyph name="grid" size={20} />, perm: 'dashboard.read' },
  { to: '/users', label: '用户管理', icon: <Glyph name="users" size={20} />, perm: 'users.read' },
  { to: '/plans', label: '会员套餐与订单', icon: <Glyph name="crown" size={20} />, perm: 'plans.read' },
  { to: '/territories', label: '地图与领地', icon: <Glyph name="map" size={20} />, perm: 'territories.read' },
  // V2 社区: 内容审核（审核队列 / 举报处理 / 动态管理 / 敏感词与审核设置）+ 组局与赛事
  { to: '/review', label: '内容审核', icon: <Glyph name="review" size={20} />, perm: 'review.read' },
  { to: '/community', label: '组局与赛事', icon: <Glyph name="flag" size={20} />, perm: 'community.read' },
  { to: '/risk', label: '风控防作弊', icon: <Glyph name="shieldAlert" size={20} />, perm: 'risk.read' },
  // V2 第四批「本地生活与商户」: one entry for the group; its pages share a sub-navigation (pages/merchant/navItems.ts)
  { to: '/merchant', label: '商户与活动', icon: <Glyph name="store" size={20} />, group: true },
  { to: '/operations', label: '玩法运营', icon: <Glyph name="gamepad" size={20} />, perm: 'ops.read' },
  { to: '/gameplay', label: '玩法配置', icon: <Glyph name="tune" size={20} />, perm: 'gameplay.read' },
  { to: '/audit', label: '审计日志', icon: <Glyph name="history" size={20} />, perm: 'audit.read' },
  { to: '/admins', label: '后台账号', icon: <Glyph name="userCheck" size={20} />, perm: 'admins.manage' },
  { to: '/settings/providers', label: '系统配置', icon: <Glyph name="gear" size={20} />, perm: 'settings.providers' },
  // V2 第三批「AI」: admin + ops (系统配置 itself is admin-only, so it gets its own entry)
  { to: '/ai-usage', label: 'AI 用量', icon: <Glyph name="quan" size={20} />, perm: 'ai.usage' },
];

export default function AppLayout() {
  const { logout, can, admin } = useAuth();
  const merchantNav = useMerchantNav();
  const navigate = useNavigate();
  // Pending count on the 内容审核 icon (same query as the queue's stats header).
  const reviewStats = useQuery({ queryKey: ['reviews', 'stats'], queryFn: api.reviewStats, enabled: can('review.read'), refetchInterval: 60_000 });
  const pendingReviews = reviewStats.data?.pending ?? 0;

  return (
    <div className="shell">
      <div className="frame">
        <nav className="side" aria-label="管理端导航">
          <div className="side-logo" role="img" aria-label="圈圈 Loopland 管理端">
            <Logo />
          </div>
          {MENU.filter((m) => (m.group ? merchantNav.length > 0 : !m.perm || can(m.perm))).map((m) =>
            m.v2 ? (
              <Tooltip key={m.to} title={m.label + ' · 下个版本上线'} placement="right">
                <span className="side-link disabled" aria-disabled="true" aria-label={m.label}>
                  {m.icon}
                  <span className="side-badge">V2</span>
                </span>
              </Tooltip>
            ) : (
              <Tooltip key={m.to} title={m.to === '/review' && pendingReviews ? `${m.label} · ${pendingReviews} 条待审核` : m.group && admin?.role === 'merchant' ? '核销、商品与结算' : m.label} placement="right">
                <NavLink to={m.to} end={m.to === '/'} aria-label={m.label} className={({ isActive }) => 'side-link' + (isActive ? ' active' : '')}>
                  {m.icon}
                  {m.to === '/review' && pendingReviews > 0 && <span className="side-count num">{pendingReviews > 99 ? '99+' : pendingReviews}</span>}
                </NavLink>
              </Tooltip>
            ),
          )}
          <div className="side-spacer" />
          <Tooltip title="退出登录" placement="right">
            <button
              type="button"
              className="side-link"
              aria-label="退出登录"
              style={{ border: 0, background: 'transparent', cursor: 'pointer' }}
              onClick={() => {
                logout();
                navigate('/login');
              }}
            >
              <Glyph name="logout" size={20} />
            </button>
          </Tooltip>
        </nav>
        <main className="main">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
