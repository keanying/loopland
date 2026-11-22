import type { CSSProperties, ReactNode } from 'react';
import { Dropdown, Tag, Tooltip } from 'antd';
import { ArrowDownOutlined, ArrowUpOutlined, ExclamationCircleOutlined, LogoutOutlined } from '@ant-design/icons';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext';
import { ROLE_LABEL } from '../utils/labels';
import { MOCK } from '../config';

export function MeChip() {
  const { admin, logout } = useAuth();
  const navigate = useNavigate();
  if (!admin) return null;
  return (
    <Dropdown
      menu={{
        items: [{ key: 'logout', icon: <LogoutOutlined />, label: '退出登录' }],
        onClick: () => {
          logout();
          navigate('/login');
        },
      }}
    >
      <div className="me-chip">
        <div className="me-avatar">{admin.username.slice(0, 1).toUpperCase()}</div>
        <div>
          <div className="me-name">{admin.username}</div>
          <div className="me-role">
            {ROLE_LABEL[admin.role] ?? admin.role}
            {MOCK && (
              <Tag color="purple" style={{ marginLeft: 6, fontSize: 10, lineHeight: '16px' }}>
                MOCK
              </Tag>
            )}
          </div>
        </div>
      </div>
    </Dropdown>
  );
}

/** 说明文字收进一个「!」图标，鼠标悬停 / 点击时显示，页面上不占位置。 */
export function InfoTip({ children, label = '说明' }: { children: ReactNode; label?: string }) {
  return (
    <Tooltip title={children} placement="bottomLeft" styles={{ root: { maxWidth: 420 } }} trigger={['hover', 'click']}>
      <ExclamationCircleOutlined className="info-tip" role="button" tabIndex={0} aria-label={label} />
    </Tooltip>
  );
}

/**
 * 页头。sub：页面说明，收进标题旁的「!」图标；subline：需要一直看得到的短信息（日期、门店名），
 * 显示在标题下面。
 */
export function PageHeader({ title, sub, subline, extra }: { title: string; sub?: ReactNode; subline?: ReactNode; extra?: ReactNode }) {
  return (
    <header className="page-header">
      <div>
        <h1 className="page-title">
          {title}
          {sub && <InfoTip label={`${title}说明`}>{sub}</InfoTip>}
        </h1>
        {subline && <div className="page-sub">{subline}</div>}
      </div>
      <div className="page-extra">
        {extra}
        <MeChip />
      </div>
    </header>
  );
}

export function Delta({ ratio, invert = false, suffix = '较上周同期' }: { ratio: number | null; invert?: boolean; suffix?: string }) {
  if (ratio === null) return <span className="muted">上周同期无数据</span>;
  const up = ratio >= 0;
  const good = invert ? !up : up;
  return (
    <span className={good ? 'delta-up' : 'delta-down'}>
      {up ? <ArrowUpOutlined /> : <ArrowDownOutlined />} {up ? '+' : ''}
      {(ratio * 100).toFixed(1)}% <span className="muted">{suffix}</span>
    </span>
  );
}

export function Stat({ value, unit, label, sub }: { value: ReactNode; unit?: string; label: ReactNode; sub?: ReactNode }) {
  return (
    <div className="stat">
      <div className="stat-value num">
        {value}
        {unit && <span className="stat-unit">{unit}</span>}
      </div>
      <div className="stat-label">{label}</div>
      {sub && <div className="stat-sub">{sub}</div>}
    </div>
  );
}

export function Panel({ title, extra, children, grey, className, style }: { title?: ReactNode; extra?: ReactNode; children: ReactNode; grey?: boolean; className?: string; style?: CSSProperties }) {
  return (
    <section className={`panel${grey ? ' grey' : ''}${className ? ' ' + className : ''}`} style={style}>
      {(title || extra) && (
        <div className="panel-head">
          {typeof title === 'string' ? <h2 className="panel-title">{title}</h2> : title}
          {extra}
        </div>
      )}
      {children}
    </section>
  );
}

export function Avatar({ name, size }: { name: string; size?: 'lg' }) {
  return <span className={`u-avatar${size ? ' ' + size : ''}`}>{name.slice(0, 1)}</span>;
}

export function Tile({ v, l, warn }: { v: ReactNode; l: ReactNode; warn?: boolean }) {
  return (
    <div className={`tile${warn ? ' warn' : ''}`}>
      <div className="tile-v num">{v}</div>
      <div className="tile-l">{l}</div>
    </div>
  );
}
