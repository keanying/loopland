import { useMemo } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Select, Table, Tag, Typography } from 'antd';
import { api, PAGE_SIZE } from '../api/admin';
import type { AuditItem } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import { PageHeader, Panel } from '../components/ui';
import { dt } from '../utils/format';
import { AUDIT_ACTION } from '../utils/labels';

export default function AuditPage() {
  const { can } = useAuth();
  const [params, setParams] = useSearchParams();
  const adminId = params.get('admin_id') ? Number(params.get('admin_id')) : undefined;
  const page = Number(params.get('page') ?? 1);

  const list = useQuery({
    queryKey: ['audit', adminId, page],
    queryFn: () => api.audit({ admin_id: adminId, page }),
    placeholderData: (prev) => prev,
  });
  // The admins list is admin-only; other roles filter by the operators seen on this page.
  const admins = useQuery({ queryKey: ['admins'], queryFn: api.admins, enabled: can('admins.manage') });

  const options = useMemo(() => {
    const m = new Map<number, string>();
    for (const a of admins.data?.items ?? []) m.set(a.id, a.username);
    for (const a of list.data?.items ?? []) m.set(a.admin.id, a.admin.username);
    return [...m.entries()].map(([value, label]) => ({ value, label }));
  }, [admins.data, list.data]);

  const set = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null) next.delete(k);
      else next.set(k, v);
    }
    setParams(next, { replace: true });
  };

  return (
    <>
      <PageHeader title="审计日志" sub="所有写操作和查看完整手机号都会记录：谁、何时、对什么做了什么" />
      <Panel
        title="操作记录"
        extra={
          <Select
            allowClear
            placeholder="按操作人筛选"
            style={{ width: 200 }}
            value={adminId}
            options={options}
            onChange={(v?: number) => set({ admin_id: v ? String(v) : null, page: null })}
          />
        }
      >
        <Table<AuditItem>
          rowKey="id"
          loading={list.isFetching}
          dataSource={list.data?.items}
          scroll={{ x: 860 }}
          pagination={{
            current: page,
            pageSize: PAGE_SIZE,
            total: list.data?.total ?? 0,
            showSizeChanger: false,
            showTotal: (t) => `共 ${t} 条`,
            onChange: (p) => set({ page: p === 1 ? null : String(p) }),
          }}
          columns={[
            { title: '时间', dataIndex: 'created_at', width: 200, render: (v: string) => <span className="num">{dt(v, 'YYYY-MM-DD HH:mm:ss')}</span> },
            { title: '操作人', key: 'admin', width: 120, render: (_, r) => <b>{r.admin.username}</b> },
            {
              title: '操作',
              dataIndex: 'action',
              render: (v: string) => (
                <span>
                  {AUDIT_ACTION[v] ?? v}{' '}
                  <Tag bordered={false} className="num" style={{ fontSize: 11 }}>
                    {v}
                  </Tag>
                </span>
              ),
            },
            { title: '对象', dataIndex: 'target', render: (v: string) => <span className="num">{v}</span> },
            {
              title: '详情',
              dataIndex: 'detail',
              render: (v: Record<string, unknown>) =>
                v && Object.keys(v).length ? (
                  <Typography.Text code style={{ fontSize: 12 }} ellipsis={{ tooltip: JSON.stringify(v) }}>
                    {JSON.stringify(v)}
                  </Typography.Text>
                ) : (
                  <span className="muted">—</span>
                ),
            },
          ]}
        />
      </Panel>
    </>
  );
}
