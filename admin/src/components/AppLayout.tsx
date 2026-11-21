import { type ReactNode } from 'react';
import { NavLink, Outlet, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Tooltip } from 'antd';
import {
  AppstoreOutlined,
  AuditOutlined,
  CompassOutlined,
  ControlOutlined,
  CrownOutlined,
  FileDoneOutlined,
  FlagOutlined,
  LogoutOutlined,
  SafetyOutlined,
  SettingOutlined,
  ShopOutlined,
  TeamOutlined,
  ThunderboltOutlined,
  UserSwitchOutlined,
} from '@ant-design/icons';
import { api } from '../api/admin';
import { useAuth } from '../auth/AuthContext';
import type { Permission } from '../auth/permissions';
import Logo from './Logo';

interface MenuItem {
  to: string;
  label: string;
  icon: ReactNode;
  v2?: boolean;
  perm?: Permission;
}

const MENU: MenuItem[] = [
  { to: '/', label: '总览', icon: <AppstoreOutlined /> },
  { to: '/users', label: '用户管理', icon: <TeamOutlined />, perm: 'users.read' },
  { to: '/plans', label: '会员套餐与订单', icon: <CrownOutlined />, perm: 'plans.read' },
  { to: '/territories', label: '地图与领地', icon: <CompassOutlined />, perm: 'territories.read' },
  // V2 社区: 内容审核（审核队列 / 举报处理 / 动态管理 / 敏感词与审核设置）+ 组局与赛事
  { to: '/review', label: '内容审核', icon: <FileDoneOutlined />, perm: 'review.read' },
  { to: '/community', label: '组局与赛事', icon: <FlagOutlined />, perm: 'community.read' },
  { to: '/risk', label: '风控防作弊', icon: <SafetyOutlined />, perm: 'risk.read' },
  { to: '/merchants', label: '商户与活动（V2）', icon: <ShopOutlined />, v2: true },
  { to: '/operations', label: '玩法运营', icon: <ThunderboltOutlined />, perm: 'ops.read' },
  { to: '/gameplay', label: '玩法配置', icon: <ControlOutlined />, perm: 'gameplay.read' },
  { to: '/audit', label: '审计日志', icon: <AuditOutlined />, perm: 'audit.read' },
  { to: '/admins', label: '后台账号', icon: <UserSwitchOutlined />, perm: 'admins.manage' },
  { to: '/settings/providers', label: '系统配置', icon: <SettingOutlined />, perm: 'settings.providers' },
];

export default function AppLayout() {
  const { logout, can } = useAuth();
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
          {MENU.filter((m) => !m.perm || can(m.perm)).map((m) =>
            m.v2 ? (
              <Tooltip key={m.to} title={m.label + ' · 下个版本上线'} placement="right">
                <span className="side-link disabled" aria-disabled="true" aria-label={m.label}>
                  {m.icon}
                  <span className="side-badge">V2</span>
                </span>
              </Tooltip>
            ) : (
              <Tooltip key={m.to} title={m.to === '/review' && pendingReviews ? `${m.label} · ${pendingReviews} 条待审核` : m.label} placement="right">
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
              <LogoutOutlined />
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
