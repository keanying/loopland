// 查看用户 AI 对话 (admin only; GET /admin/v1/users/{id}/ai-messages, every view is audited).
import { useState } from 'react';
import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { Alert, Drawer, Empty, Image, Pagination, Skeleton, Tag } from 'antd';
import { CompassOutlined, EnvironmentOutlined, RobotOutlined, ThunderboltOutlined } from '@ant-design/icons';
import { api, PAGE_SIZE } from '../../api/admin';
import type { AICard, AIMessage } from '../../api/types';
import { dt, km } from '../../utils/format';

function Card({ c }: { c: AICard }) {
  if (c.type === 'route' && 'route' in c) {
    const r = c.route as { title: string; subtitle?: string; distance_m?: number };
    return (
      <div className="chat-card">
        <CompassOutlined /> <b>路线卡片 · {r.title}</b>
        {r.distance_m ? <span className="muted"> · {km(r.distance_m)}</span> : null}
        {r.subtitle && <div className="muted">{r.subtitle}</div>}
      </div>
    );
  }
  if (c.type === 'territory' && 'territory' in c) {
    const t = c.territory as { name: string; guard?: number };
    return (
      <div className="chat-card">
        <EnvironmentOutlined /> <b>领地卡片 · {t.name}</b>
        {t.guard !== undefined && <span className="muted"> · 守卫值 {t.guard}</span>}
      </div>
    );
  }
  if (c.type === 'boss' && 'boss' in c) {
    const b = c.boss as { name: string; hp?: number; max_hp?: number };
    return (
      <div className="chat-card">
        <ThunderboltOutlined /> <b>怪兽卡片 · {b.name}</b>
        {b.hp !== undefined && b.max_hp ? <span className="muted"> · 血量 {b.hp}/{b.max_hp}</span> : null}
      </div>
    );
  }
  return <div className="chat-card muted">卡片（{c.type}）</div>;
}

function Bubble({ m }: { m: AIMessage }) {
  return (
    <div className={`chat-msg ${m.role}${m.deleted ? ' deleted' : ''}`}>
      {m.role === 'assistant' && (
        <div style={{ fontSize: 11, fontWeight: 700, marginBottom: 2 }}>
          <RobotOutlined /> 圈圈
        </div>
      )}
      {m.content}
      {m.image_url && (
        <div style={{ marginTop: 6 }}>
          <Image src={m.image_url} width={120} height={120} style={{ objectFit: 'cover', borderRadius: 10 }} alt="用户发送的图片" />
        </div>
      )}
      {m.cards.map((c, i) => (
        <Card key={i} c={c} />
      ))}
      <div className="chat-meta">
        {dt(m.created_at, 'MM-DD HH:mm')}
        {m.ai_generated && ' · AI 生成'}
        {m.deleted && ' · 用户已清空'}
      </div>
    </div>
  );
}

export default function AIMessagesDrawer({ user, open, onClose }: { user: { id: number; nickname: string } | null; open: boolean; onClose: () => void }) {
  const [page, setPage] = useState(1);
  const q = useQuery({
    queryKey: ['users', 'ai-messages', user?.id, page],
    queryFn: () => api.userAiMessages(user!.id, page),
    enabled: open && !!user,
    placeholderData: keepPreviousData,
    staleTime: Infinity, // each fetch is an audited view; do not refetch on focus
  });
  // Pages come newest first; read each page top-down in time order.
  const items = [...(q.data?.items ?? [])].sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at) || a.id - b.id);
  return (
    <Drawer
      open={open}
      onClose={onClose}
      afterOpenChange={(v) => !v && setPage(1)}
      width={520}
      title={`${user?.nickname ?? ''} 的 AI 对话`}
      destroyOnHidden
      extra={<Tag color="red" bordered={false}>本次查看已记入审计日志</Tag>}
    >
      <Alert
        type="warning"
        showIcon
        style={{ marginBottom: 14 }}
        message="仅用于投诉核查"
        description="对话保存 180 天；用户清空的对话仍保留到期满。不要截图外传，处理投诉只引用必要内容。"
      />
      {q.isError ? (
        <Empty description={`加载失败：${(q.error as Error).message}`} />
      ) : !q.data ? (
        <Skeleton active paragraph={{ rows: 8 }} />
      ) : items.length === 0 ? (
        <Empty description="这个用户没有和 AI 助手对话过" />
      ) : (
        <>
          <div className="chat-list">
            {items.map((m) => (
              <Bubble key={m.id} m={m} />
            ))}
          </div>
          {q.data.total > PAGE_SIZE && (
            <Pagination
              size="small"
              style={{ marginTop: 16, textAlign: 'center' }}
              current={page}
              pageSize={PAGE_SIZE}
              total={q.data.total}
              showSizeChanger={false}
              showTotal={(n) => `共 ${n} 条 · 第 1 页最新`}
              onChange={setPage}
            />
          )}
        </>
      )}
    </Drawer>
  );
}
