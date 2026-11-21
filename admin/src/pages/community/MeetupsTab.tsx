// 组局与赛事 · 组局管理: GET /admin/v1/meetups (status / type), POST /meetups/{id}/cancel.
import { useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Button, Empty, Progress, Segmented, Select, Space, Table, Tag, Tooltip } from 'antd';
import { EnvironmentOutlined } from '@ant-design/icons';
import { api, PAGE_SIZE } from '../../api/admin';
import type { Meetup, MeetupStatus, MeetupType } from '../../api/types';
import { useAuth } from '../../auth/AuthContext';
import { Panel } from '../../components/ui';
import { ago, dayjs } from '../../utils/format';
import { MEETUP_STATUS, MEETUP_TYPE, REVIEW_STATUS } from '../../utils/labels';
import { toastOk } from '../../utils/notify';
import { ReasonModal } from '../review/shared';

const CANCEL_REASONS = ['天气或场地原因', '内容违规', '发起人申请取消', '涉嫌营销或诈骗', '时间地点信息不实'];

function timeRange(m: Meetup): string {
  const s = dayjs(m.start_time);
  const e = dayjs(m.end_time);
  return `${s.format('MM-DD ddd HH:mm')}–${e.isSame(s, 'day') ? e.format('HH:mm') : e.format('MM-DD HH:mm')}`;
}

export default function MeetupsTab() {
  const qc = useQueryClient();
  const { can } = useAuth();
  const writable = can('community.write');
  const [params, setParams] = useSearchParams();
  const status = (params.get('status') ?? '') as MeetupStatus | '';
  const type = (params.get('type') ?? '') as MeetupType | '';
  const page = Number(params.get('page') ?? 1);
  const set = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null || v === '') next.delete(k);
      else next.set(k, v);
    }
    setParams(next, { replace: true });
  };

  const list = useQuery({ queryKey: ['meetups', status, type, page], queryFn: () => api.meetups({ status, type, page }), placeholderData: (p) => p });
  const [cancelling, setCancelling] = useState<Meetup | null>(null);
  const cancel = useMutation({
    mutationFn: ({ id, reason }: { id: number; reason: string }) => api.cancelMeetup(id, reason),
    onSuccess: (m) => {
      setCancelling(null);
      qc.invalidateQueries({ queryKey: ['meetups'] });
      toastOk(`已取消「${m?.title ?? ''}」，已通知报名者`);
    },
  });

  return (
    <Panel
      title="组局"
      extra={
        <Space wrap>
          <Select
            style={{ width: 120 }}
            value={type}
            onChange={(v) => set({ type: v || null, page: null })}
            options={[{ label: '全部类型', value: '' }, ...Object.entries(MEETUP_TYPE).map(([value, t]) => ({ value, label: t.text }))]}
          />
          <Segmented
            value={status}
            onChange={(v) => set({ status: String(v) || null, page: null })}
            options={[{ label: '全部', value: '' }, ...Object.entries(MEETUP_STATUS).map(([value, t]) => ({ value, label: t.text }))]}
          />
        </Space>
      }
    >
      <Table<Meetup>
        rowKey="id"
        loading={list.isFetching}
        dataSource={list.data?.items}
        scroll={{ x: 1200 }}
        locale={{ emptyText: <Empty description="没有符合条件的组局" /> }}
        pagination={{
          current: page,
          pageSize: PAGE_SIZE,
          total: list.data?.total ?? 0,
          showSizeChanger: false,
          showTotal: (t) => `共 ${t} 个`,
          onChange: (p) => set({ page: p === 1 ? null : String(p) }),
        }}
        columns={[
          {
            title: '组局',
            key: 'title',
            render: (_, m) => (
              <div style={{ maxWidth: 260 }}>
                <b>{m.title}</b> <span className="muted num" style={{ fontSize: 12 }}>#{m.id}</span>
                <div className="muted" style={{ fontSize: 12 }}>
                  {m.description || '—'}
                </div>
                {m.requirement && (
                  <div style={{ fontSize: 12 }}>
                    要求：<span className="num">{m.requirement}</span>
                  </div>
                )}
              </div>
            ),
          },
          { title: '类型', dataIndex: 'type', render: (v: string) => <Tag bordered={false} color={MEETUP_TYPE[v]?.color}>{MEETUP_TYPE[v]?.text ?? v}</Tag> },
          {
            title: '时间',
            key: 'time',
            render: (_, m) => (
              <div className="num" style={{ fontSize: 12, whiteSpace: 'nowrap' }}>
                {timeRange(m)}
                <div className="muted">{Date.parse(m.start_time) > Date.now() ? dayjs(m.start_time).fromNow() + '开始' : ago(m.start_time) + '开始'}</div>
              </div>
            ),
          },
          {
            title: '地点',
            key: 'place',
            render: (_, m) => (
              <Tooltip title={`${m.place.lat.toFixed(5)}, ${m.place.lng.toFixed(5)}`}>
                <div style={{ fontSize: 13, maxWidth: 180 }}>
                  <EnvironmentOutlined /> {m.place.name}
                  {m.district && <div className="muted" style={{ fontSize: 12 }}>{m.district}</div>}
                </div>
              </Tooltip>
            ),
          },
          {
            title: '人数',
            key: 'people',
            width: 130,
            render: (_, m) => (
              <div>
                <span className="num">
                  {m.joined_count} / {m.capacity}
                </span>
                <Progress percent={Math.round((m.joined_count / Math.max(1, m.capacity)) * 100)} showInfo={false} size="small" strokeColor="#141414" />
              </div>
            ),
          },
          {
            title: '发起人',
            key: 'creator',
            render: (_, m) => (
              <div style={{ whiteSpace: 'nowrap' }}>
                {m.creator.nickname}
                <div className="muted num" style={{ fontSize: 12 }}>
                  #{m.creator.id}
                </div>
              </div>
            ),
          },
          { title: '审核', dataIndex: 'review_status', render: (v: string) => <Tag bordered={false} color={REVIEW_STATUS[v]?.color}>{v === 'rejected' ? '未通过' : REVIEW_STATUS[v]?.text ?? v}</Tag> },
          { title: '状态', dataIndex: 'status', render: (v: string) => <Tag bordered={false} color={MEETUP_STATUS[v]?.color}>{MEETUP_STATUS[v]?.text ?? v}</Tag> },
          {
            title: '操作',
            key: 'op',
            align: 'right',
            render: (_, m) => {
              const active = m.status === 'open' || m.status === 'full';
              return (
                <Tooltip title={active ? undefined : '已取消或已结束'}>
                  <Button size="small" danger disabled={!writable || !active} onClick={() => setCancelling(m)}>
                    取消组局
                  </Button>
                </Tooltip>
              );
            },
          },
        ]}
      />
      <ReasonModal
        open={cancelling !== null}
        title={cancelling ? `取消「${cancelling.title}」` : ''}
        presets={CANCEL_REASONS}
        okText="确认取消"
        cancelText="返回"
        loading={cancel.isPending}
        effect={cancelling ? `${cancelling.joined_count} 位报名者会收到「组局已取消」的通知和原因；群聊保留，组局不再出现在附近列表。` : undefined}
        onCancel={() => setCancelling(null)}
        onOk={(reason) => cancelling && cancel.mutate({ id: cancelling.id, reason })}
      />
    </Panel>
  );
}
