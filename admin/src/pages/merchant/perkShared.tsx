// Shared components of the 投放 / 联名活动 / 能量商城 pages: the type badge, the in-App coupon
// preview and the territory-skin swatch (labels live in perkLabels.tsx).
import type { DropType, Perk, ShopPreview } from '../../api/perks';
import { DROP_TYPE } from './perkLabels';
import './perks.css';

export function DropTypeBadge({ type, size = 34 }: { type: DropType; size?: number }) {
  return (
    <span className={`drop-ic ${type}`} style={{ width: size, height: size, fontSize: size * 0.48 }} aria-hidden>
      {DROP_TYPE[type].icon}
    </span>
  );
}

/** How the coupon looks in the App's 卡券包 (dark theme), with how it is obtained. */
export function CouponPreview({
  perk,
  merchant,
  type,
  place,
  dailyCap,
  until,
}: {
  perk: Partial<Perk>;
  merchant?: string;
  type: DropType;
  place?: string;
  dailyCap?: number | null;
  until?: string;
}) {
  const title = perk.title?.trim() || '权益标题';
  const value = perk.value_text?.trim() || '面值';
  return (
    <div className="phone coupon-phone" aria-label="App 内券样式预览">
      <div className="phone-screen">
        <div className="cp-head">
          <b>卡券包</b>
          <span className="cp-chip">联名权益</span>
        </div>
        <div className="coupon">
          <div className="coupon-stub">
            <div className={`coupon-value${[...value].length > 4 ? ' long' : ''}`}>{value}</div>
            <div className="coupon-merchant">{merchant || '商户'}</div>
          </div>
          <div className="coupon-main">
            <div className="coupon-title">{title}</div>
            {perk.description?.trim() && <div className="coupon-desc">{perk.description.trim()}</div>}
            <div className="coupon-src">
              {DROP_TYPE[type].icon} {DROP_TYPE[type].label}
              {place ? ` · ${place}` : ''}
            </div>
          </div>
        </div>
        <div className="coupon-btn">出示券码</div>
        <div className="cp-rules">
          <div className="cp-rules-t">使用规则</div>
          <div>{perk.rules?.trim() || '—'}</div>
          <div className="cp-line">领取：{DROP_TYPE[type].claim}，免费</div>
          <div className="cp-line">有效期：领取后 {perk.valid_days || '—'} 天内使用</div>
          {dailyCap ? <div className="cp-line">每天限量 {dailyCap} 张，发完显示「今日已领完」</div> : null}
          {until && <div className="cp-line">活动截止：{until}</div>}
          <div className="cp-note">不设付费抽取 · 只能运动免费领取</div>
        </div>
      </div>
    </div>
  );
}

/** A territory polygon painted with a skin (fill, stroke, pattern), like the App map. */
export function SkinSwatch({ preview, size = 120, label }: { preview: Partial<ShopPreview> | null | undefined; size?: number; label?: string }) {
  const fill = preview?.fill || '#D6D6DA';
  const stroke = preview?.stroke || '#3A3A40';
  const pattern = preview?.pattern || 'solid';
  const id = `sk-${pattern}-${fill.slice(1)}-${stroke.slice(1)}-${size}`;
  const motif =
    pattern === 'grid' ? (
      <path d="M 12 0 L 0 0 0 12" fill="none" stroke={stroke} strokeWidth={1.2} opacity={0.55} />
    ) : pattern === 'stripe' ? (
      <path d="M -3 3 L 3 -3 M 0 12 L 12 0 M 9 15 L 15 9" stroke={stroke} strokeWidth={2.2} opacity={0.5} />
    ) : pattern === 'dots' ? (
      <circle cx={6} cy={6} r={2} fill={stroke} opacity={0.55} />
    ) : pattern === 'wave' ? (
      <path d="M 0 6 Q 3 2 6 6 T 12 6" fill="none" stroke={stroke} strokeWidth={1.6} opacity={0.55} />
    ) : null;
  return (
    <svg width={size} height={size} viewBox="0 0 100 100" role="img" aria-label={label ?? '领地皮肤预览'} className="skin-swatch">
      <defs>
        <pattern id={id} width={12} height={12} patternUnits="userSpaceOnUse">
          <rect width={12} height={12} fill={fill} />
          {motif}
        </pattern>
      </defs>
      <rect width={100} height={100} rx={18} fill="#1A1A1E" />
      <path d="M 18 30 L 48 14 L 84 26 L 88 62 L 62 86 L 24 78 L 12 52 Z" fill={`url(#${id})`} fillOpacity={0.92} stroke={stroke} strokeWidth={3} strokeLinejoin="round" />
    </svg>
  );
}
