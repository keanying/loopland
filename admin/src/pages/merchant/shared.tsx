import type { ReactNode } from 'react';
import { useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Tag, Tooltip } from 'antd';
import { CoffeeOutlined, HomeOutlined, ShopOutlined } from '@ant-design/icons';
import { api } from '../../api/admin';
import { type MerchantStatus, type MerchantType, type StatementStatus, type BookingStatus } from '../../api/merchant';
import type { LatLng } from '../../api/types';
import SvgMap from '../../components/map/SvgMap';
import { yuan } from '../../utils/format';
import { BOOKING_STATUS, MERCHANT_STATUS, STATEMENT_STATUS } from './labels';

export function MerchantStatusTag({ status }: { status: MerchantStatus }) {
  const s = MERCHANT_STATUS[status];
  return (
    <Tooltip title={s?.hint}>
      <Tag bordered={false} color={s?.color}>
        {s?.text ?? status}
      </Tag>
    </Tooltip>
  );
}

export function BookingStatusTag({ status }: { status: BookingStatus }) {
  const s = BOOKING_STATUS[status];
  return (
    <Tag bordered={false} color={s?.color}>
      {s?.text ?? status}
    </Tag>
  );
}

export function StatementStatusTag({ status }: { status: StatementStatus }) {
  const s = STATEMENT_STATUS[status];
  return (
    <Tag bordered={false} color={s?.color}>
      {s?.text ?? status}
    </Tag>
  );
}

const TYPE_ICON: Record<MerchantType, ReactNode> = { venue: <HomeOutlined />, brand: <CoffeeOutlined />, store: <ShopOutlined /> };
export function MerchantIcon({ type }: { type: MerchantType }) {
  return <span className="mer-icon">{TYPE_ICON[type] ?? <ShopOutlined />}</span>;
}

/** net_amt: > 0 the merchant pays the platform, < 0 the platform pays the merchant. */
export function NetAmount({ amt, block }: { amt: number; block?: boolean }) {
  const text = amt === 0 ? '无需结算' : amt > 0 ? `商户付 ${yuan(amt)}` : `平台付 ${yuan(-amt)}`;
  return (
    <span className={`num ${amt < 0 ? 'net-out' : amt > 0 ? 'net-in' : 'muted'}`} style={block ? { display: 'block' } : undefined}>
      {text}
    </span>
  );
}

const DEFAULT_CENTER = { lat: 31.232, lng: 121.505 };

/** Click-to-pick map (same SVG map as 赛事 / 召唤怪兽: territories around the point as reference). */
export function PointPicker({ point, name, radius, onPick, enabled = true }: { point: LatLng | null; name: string; radius: number; onPick: (p: LatLng) => void; enabled?: boolean }) {
  const key = point ? `${point.lat.toFixed(2)},${point.lng.toFixed(2)}` : '';
  const bbox = useMemo<[number, number, number, number]>(() => {
    const c = point ?? DEFAULT_CENTER;
    return [+(c.lng - 0.02).toFixed(3), +(c.lat - 0.015).toFixed(3), +(c.lng + 0.02).toFixed(3), +(c.lat + 0.015).toFixed(3)];
    // eslint-disable-next-line react-hooks/exhaustive-deps -- refetch when the point moves noticeably
  }, [key]);
  const geo = useQuery({ queryKey: ['territories', 'geo', bbox.join(',')], queryFn: () => api.territoriesGeo(bbox), enabled, placeholderData: (p) => p });
  return (
    <div className="race-place route-preview">
      <SvgMap
        items={geo.data?.items ?? []}
        selectedId={null}
        onSelect={() => undefined}
        focus={null}
        objects={{ bosses: [], chests: [], checkpoints: point ? [{ route_id: 0, index: 0, name: name || '场馆', center: point, radius_m: radius }] : [] }}
        layers={{ territories: true, bosses: false, chests: false, checkpoints: true }}
        preview
        checkpointLabel="场馆 · 签到范围"
        picking
        onPick={(p) => onPick({ lat: +p.lat.toFixed(6), lng: +p.lng.toFixed(6) })}
      />
    </div>
  );
}
