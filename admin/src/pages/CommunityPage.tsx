import type { ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Segmented } from 'antd';
import { PageHeader } from '../components/ui';
import MeetupsTab from './community/MeetupsTab';
import RacesTab from './community/RacesTab';

type Tab = 'meetups' | 'races';

const TABS: { value: Tab; label: string; sub: string }[] = [
  { value: 'meetups', label: '组局管理', sub: '用户发起的约跑、约球、约骑；违规或无法成行的可以取消，报名者会收到通知' },
  { value: 'races', label: '赛事管理', sub: '线上赛在运动结算时自动判定完赛；线下赛由运营在报名名单里标记完赛，完赛发奖牌' },
];

export default function CommunityPage() {
  const [params, setParams] = useSearchParams();
  const tab = (TABS.find((t) => t.value === params.get('tab'))?.value ?? 'meetups') as Tab;
  const body: Record<Tab, ReactNode> = { meetups: <MeetupsTab />, races: <RacesTab /> };
  return (
    <>
      <PageHeader
        title="组局与赛事"
        sub={TABS.find((t) => t.value === tab)?.sub}
        extra={
          <Segmented
            size="large"
            value={tab}
            onChange={(v) => setParams(v === 'meetups' ? {} : { tab: String(v) })}
            options={TABS.map((t) => ({ label: t.label, value: t.value }))}
          />
        }
      />
      {body[tab]}
    </>
  );
}
