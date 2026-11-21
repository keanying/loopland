import type { ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Segmented } from 'antd';
import { PageHeader } from '../components/ui';
import BossesTab from './operations/BossesTab';
import ChestsTab from './operations/ChestsTab';
import SeasonsTab from './operations/SeasonsTab';
import CampaignsTab from './operations/CampaignsTab';
import RoutesTab from './operations/RoutesTab';
import LeagueTab from './operations/LeagueTab';

type Tab = 'bosses' | 'chests' | 'seasons' | 'campaigns' | 'routes' | 'league';

const TABS: { value: Tab; label: string; sub: string }[] = [
  { value: 'bosses', label: '城市怪兽', sub: '系统每小时自动投放，运营也可以在「地图与领地」手动召唤；击败按伤害排名掉落' },
  { value: 'chests', label: '宝箱', sub: '每天 06:00 系统刷新，深夜（23:00–05:00）不刷新；运营可单个投放或批量撒' },
  { value: 'seasons', label: '赛季', sub: '2 个月一季，按赛季内新圈面积定段位；到期自动结算，也可手动结算' },
  { value: 'campaigns', label: '限时活动', sub: '配速挑战、夜跑专场、距离挑战；运动结算时自动判定完成' },
  { value: 'routes', label: '城市定向', sub: '一条有序打卡点路线，可以分多次跑，按顺序经过每个点即完成' },
  { value: 'league', label: '城区联赛', sub: '同城区跑团按本周成员新圈面积排名，每周一 00:00 结算' },
];

export default function OperationsPage() {
  const [params, setParams] = useSearchParams();
  const tab = (TABS.find((t) => t.value === params.get('tab'))?.value ?? 'bosses') as Tab;
  const body: Record<Tab, ReactNode> = {
    bosses: <BossesTab />,
    chests: <ChestsTab />,
    seasons: <SeasonsTab />,
    campaigns: <CampaignsTab />,
    routes: <RoutesTab />,
    league: <LeagueTab />,
  };
  return (
    <>
      <PageHeader
        title="玩法运营"
        sub={TABS.find((t) => t.value === tab)?.sub}
        extra={
          <Segmented
            size="large"
            value={tab}
            onChange={(v) => setParams(v === 'bosses' ? {} : { tab: String(v) })}
            options={TABS.map((t) => ({ label: t.label, value: t.value }))}
          />
        }
      />
      {body[tab]}
    </>
  );
}
