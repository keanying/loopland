import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { App, Button, Empty, Segmented, Space, Table, Tag } from 'antd';
import { EnvironmentOutlined } from '@ant-design/icons';
import { api, PAGE_SIZE } from '../../api/admin';
import type { ChestListItem, ChestStatus } from '../../api/types';
import { useAuth } from '../../auth/AuthContext';
import { useAdminNames } from '../../hooks/useAdminNames';
import { timeLeft } from '../../utils/gameplay';
import { Panel } from '../../components/ui';
import { dt, num } from '../../utils/format';
import { CHEST_SOURCE, CHEST_STATUS } from '../../utils/labels';
import { toastOk } from '../../utils/notify';

export default function ChestsTab() {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const [params, setParams] = useSearchParams();
  const status = (params.get('status') as ChestStatus) || 'active';
  const page = Number(params.get('page') ?? 1);
  const { can } = useAuth();
  const editable = can('ops.write');
  const adminName = useAdminNames();

  const set = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null) next.delete(k);
      else next.set(k, v);
    }
    setParams(next, { replace: true });
  };

  const list = useQuery({ queryKey: ['chests', status, page], queryFn: () => api.chests({ status, page }), placeholderData: (p) => p });
  const remove = useMutation({
    mutationFn: (id: number) => api.deleteChest(id),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['chests'] });
      qc.invalidateQueries({ queryKey: ['map-objects'] });
      toastOk('宝箱已下架');
    },
  });

  const source = (v: ChestListItem['source']) => {
    if (v === null || v === undefined) return <span className="muted">—</span>;
    if (typeof v === 'number') return <span>运营 {adminName(v)}</span>;
    return <Tag bordered={false} color={v === 'system' || v === 'daily' ? undefined : 'purple'}>{CHEST_SOURCE[v] ?? v}</Tag>;
  };

  return (
    <Panel
      title="宝箱"
      extra={
        <Space wrap>
          <Segmented
            value={status}
            onChange={(v) => set({ status: v === 'active' ? null : String(v), page: null })}
            options={[
              { label: '可开启', value: 'active' },
              { label: '已开完', value: 'opened_out' },
              { label: '已过期', value: 'expired' },
            ]}
          />
          <Link to="/territories">
            <Button icon={<EnvironmentOutlined />}>去地图投放</Button>
          </Link>
        </Space>
      }
    >
      <Table<ChestListItem>
        rowKey="id"
        loading={list.isFetching}
        dataSource={list.data?.items}
        scroll={{ x: 900 }}
        locale={{ emptyText: <Empty description="暂无宝箱" /> }}
        pagination={{
          current: page,
          pageSize: PAGE_SIZE,
          total: list.data?.total ?? 0,
          showSizeChanger: false,
          showTotal: (t) => `共 ${t} 个`,
          onChange: (p) => set({ page: p === 1 ? null : String(p) }),
        }}
        columns={[
          { title: '宝箱', dataIndex: 'id', render: (v: number) => <b className="num">#{v}</b> },
          {
            title: '位置',
            key: 'pos',
            render: (_, c) => (
              <span className="num muted">
                {c.center.lat.toFixed(5)}, {c.center.lng.toFixed(5)}
                {c.radius_m ? ` · ${c.radius_m} m` : ''}
              </span>
            ),
          },
          { title: '能量', key: 'energy', render: (_, c) => <span className="num">{c.energy_min}–{c.energy_max}</span> },
          { title: '开启人数', key: 'opens', align: 'right', render: (_, c) => <span className="num">{num(c.opens ?? c.opened_count)}</span> },
          { title: '来源', dataIndex: 'source', render: source },
          { title: '投放', dataIndex: 'created_at', render: (v?: string) => <span className="muted num">{dt(v, 'MM-DD HH:mm')}</span> },
          {
            title: '到期',
            dataIndex: 'expires_at',
            render: (v?: string) => (status === 'active' ? <span className="num">{timeLeft(v).replace('还剩 ', '')}</span> : <span className="muted num">{dt(v, 'MM-DD HH:mm')}</span>),
          },
          { title: '状态', dataIndex: 'status', render: (v?: string) => (v ? <Tag bordered={false} color={CHEST_STATUS[v]?.color}>{CHEST_STATUS[v]?.text ?? v}</Tag> : null) },
          {
            title: '操作',
            key: 'op',
            align: 'right',
            render: (_, c) =>
              (c.status ?? status) === 'active' ? (
                <Button
                  size="small"
                  danger
                  disabled={!editable}
                  onClick={() =>
                    modal.confirm({
                      title: `下架宝箱 #${c.id}？`,
                      content: '下架后 App 地图上不再显示，已经开过的人不受影响。',
                      okText: '下架',
                      okButtonProps: { danger: true },
                      cancelText: '取消',
                      onOk: () => remove.mutateAsync(c.id),
                    })
                  }
                >
                  下架
                </Button>
              ) : null,
          },
        ]}
      />
    </Panel>
  );
}
