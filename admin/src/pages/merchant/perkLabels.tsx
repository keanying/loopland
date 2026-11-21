// Labels and helpers of the 投放 / 联名活动 / 能量商城 pages (no components: see perkShared.tsx).
import { CoffeeOutlined, GiftOutlined, HomeOutlined } from '@ant-design/icons';
import type { ReactNode } from 'react';
import type { BrandCampaignStatus, DropStatus, DropType, ShopItemType } from '../../api/perks';

export const DROP_TYPES: DropType[] = ['supply', 'chest', 'stronghold'];

export const DROP_TYPE: Record<DropType, { label: string; icon: ReactNode; short: string; how: string; claim: string }> = {
  supply: {
    label: '补给站',
    icon: <CoffeeOutlined />,
    short: '跑步路线经过即可领取，店员扫码核销',
    how: '在地图上画一个圆：运动轨迹经过范围内（运动结算时判定），或人在范围内点「领取」，就得一张券。每人每个补给站每天 1 张。',
    claim: '跑步经过补给站自动领取',
  },
  chest: {
    label: '宝箱',
    icon: <GiftOutlined />,
    short: '在地图上刷出商户宝箱，开启得券',
    how: '按投放位置刷出商户宝箱（沿用宝箱机制，深夜 23:00–05:00 不刷），走到宝箱附近开启得券——奖励是券，不是能量。',
    claim: '在地图上找到宝箱并开启',
  },
  stronghold: {
    label: '据点',
    icon: <HomeOutlined />,
    short: '绑定场馆，场馆签到得券',
    how: '绑定一个场馆：用户在场馆范围内定位签到或扫场馆二维码签到就得券，签到同时累积馆主积分（周榜第一成为馆主）。',
    claim: '到场馆签到领取',
  },
};

export const DROP_STATUS: Record<DropStatus, { text: string; color: string }> = {
  scheduled: { text: '未开始', color: 'blue' },
  active: { text: '发券中', color: 'success' },
  paused: { text: '已暂停', color: 'warning' },
  ended: { text: '已结束', color: 'default' },
};

export const SETTLE_DIRECTION_TEXT: Record<string, { text: string; short: string; hint: string }> = {
  merchant_pays: { text: '商户付平台（服务费）', short: '商户付', hint: '每张有效核销，商户付给平台的服务费' },
  platform_pays: { text: '平台付商户（补贴）', short: '平台补贴', hint: '每张有效核销，平台补贴给商户（权益成本由平台承担一部分）' },
};

export const CAMPAIGN_STATUS: Record<BrandCampaignStatus, { text: string; color: string }> = {
  draft: { text: '草稿', color: 'default' },
  scheduled: { text: '待上线', color: 'blue' },
  running: { text: '进行中', color: 'success' },
  paused: { text: '已暂停', color: 'warning' },
  ended: { text: '已结束', color: 'default' },
};

export const SHOP_TYPE: Record<ShopItemType, string> = { territory_skin: '领地皮肤', avatar_frame: '头像框', map_marker: '地图标记' };

export const SKIN_PATTERNS: { value: string; label: string }[] = [
  { value: 'solid', label: '纯色' },
  { value: 'grid', label: '网格' },
  { value: 'stripe', label: '斜纹' },
  { value: 'dots', label: '圆点' },
  { value: 'wave', label: '波浪' },
];

export const NO_PAID_DRAW = '不设付费抽取：券只能通过运动、签到免费获得，App 里没有任何付费抽券的入口。';

/** 元 (form) ↔ 分 (API). */
export const toFen = (yuan: number | null | undefined) => Math.round((yuan ?? 0) * 100);
export const toYuan = (fen: number | null | undefined) => (fen ?? 0) / 100;

/** "¥ 4.2 万" style money for big merchant investments (分 in). */
export function yuanShort(fen: number | null | undefined): string {
  const y = (fen ?? 0) / 100;
  if (Math.abs(y) >= 10000) return `¥ ${(y / 10000).toLocaleString('zh-CN', { maximumFractionDigits: 2 })} 万`;
  return `¥ ${y.toLocaleString('zh-CN', { maximumFractionDigits: 2 })}`;
}

