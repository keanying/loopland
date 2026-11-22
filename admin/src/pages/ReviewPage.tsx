import type { ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Segmented } from 'antd';
import { useAuth } from '../auth/AuthContext';
import type { Permission } from '../auth/permissions';
import { PageHeader } from '../components/ui';
import QueueTab from './review/QueueTab';
import ReportsTab from './review/ReportsTab';
import PostsTab from './review/PostsTab';
import SettingsTab from './review/SettingsTab';

type Tab = 'queue' | 'reports' | 'posts' | 'settings';

const TABS: { value: Tab; label: string; sub: string; perm: Permission }[] = [
  { value: 'queue', label: '审核队列', sub: '动态、评论、昵称、头像、跑团名称和头像、简介、组局、商户商品，按风险分（规则与 AI 取高）排序；资料类改动先生效后审核', perm: 'review.read' },
  { value: 'reports', label: '举报处理', sub: '用户举报的动态、评论、用户、跑团和消息；下架可同时禁言作者', perm: 'review.read' },
  { value: 'posts', label: '动态管理', sub: '按关键词、作者、审核状态查找动态，查看图片和附带的运动，违规的下架', perm: 'review.read' },
  { value: 'settings', label: '敏感词与审核设置', sub: '拦截词、审核词、自动放行线 / 自动拦截线、AI 审核开关和举报自动隐藏人数，仅管理员可改', perm: 'moderation.settings' },
];

export default function ReviewPage() {
  const { can } = useAuth();
  const [params, setParams] = useSearchParams();
  const tabs = TABS.filter((t) => can(t.perm));
  const tab = (tabs.find((t) => t.value === params.get('tab'))?.value ?? 'queue') as Tab;
  const body: Record<Tab, ReactNode> = {
    queue: <QueueTab />,
    reports: <ReportsTab />,
    posts: <PostsTab />,
    settings: <SettingsTab />,
  };
  return (
    <>
      <PageHeader
        title="内容审核"
        sub={TABS.find((t) => t.value === tab)?.sub}
        extra={
          <Segmented
            size="large"
            value={tab}
            onChange={(v) => setParams(v === 'queue' ? {} : { tab: String(v) })}
            options={tabs.map((t) => ({ label: t.label, value: t.value }))}
          />
        }
      />
      {body[tab]}
    </>
  );
}
