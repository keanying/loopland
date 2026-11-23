import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, App, Button, DatePicker, Form, Input, Modal, Space, Table, Tag, Tooltip } from 'antd';
import type { Dayjs } from 'dayjs';
import { api } from '../../api/admin';
import type { Season, SeasonInput } from '../../api/types';
import { useAuth } from '../../auth/AuthContext';
import { Panel } from '../../components/ui';
import { dayjs, dt } from '../../utils/format';
import { SEASON_STATUS } from '../../utils/labels';
import { toastOk } from '../../utils/notify';
import { days, fromRange, phaseOf, RANGE_FORMAT, toRange } from './shared';
import { Glyph } from '../../components/Glyph';

type Status = NonNullable<Season['status']>;

/** The contract does not fix a status field; derive it from settled_at and the dates when absent. */
function seasonStatus(s: Season): Status {
  if (s.status) return s.status;
  if (s.settled_at) return 'settled';
  const p = phaseOf(s.starts_at, s.ends_at);
  return p === 'ended' ? 'ended' : p;
}

function overlapWith(list: Season[], selfId: number | null, r: [Dayjs, Dayjs]): Season | undefined {
  const a = r[0].valueOf();
  const b = r[1].valueOf();
  return list.find((s) => s.id !== selfId && Date.parse(s.starts_at) < b && a < Date.parse(s.ends_at));
}

export default function SeasonsTab() {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const { can } = useAuth();
  const editable = can('ops.write');
  const q = useQuery({ queryKey: ['seasons'], queryFn: api.seasons });
  const list = q.data?.items ?? [];
  const [editing, setEditing] = useState<Season | 'new' | null>(null);

  const settle = useMutation({
    mutationFn: (id: number) => api.settleSeason(id),
    onSuccess: (s) => {
      qc.invalidateQueries({ queryKey: ['seasons'] });
      toastOk(`「${s?.name ?? '赛季'}」已结算，段位奖牌已发放`);
    },
  });

  const confirmSettle = (s: Season) => {
    const early = Date.parse(s.ends_at) > Date.now();
    modal.confirm({
      title: `结算「${s.name}」？`,
      content: early
        ? `赛季还没到期（${dt(s.ends_at)} 结束）。提前结算会立即锁定排名、按最终段位发放赛季奖牌，之后赛季不能再修改。`
        : '按最终段位发放赛季奖牌，锁定排名。结算后赛季不能再修改。建筑和图鉴不清空。',
      okText: '下一步',
      cancelText: '取消',
      onOk: () =>
        new Promise<void>((resolve) => {
          resolve();
          modal.confirm({
            title: '再次确认结算',
            content: (
              <div>
                即将结算 <b>{s.name}</b>，此操作<b>不可撤销</b>。
              </div>
            ),
            okText: '确认结算',
            okButtonProps: { danger: true },
            cancelText: '取消',
            onOk: () => settle.mutateAsync(s.id),
          });
        }),
    });
  };

  return (
    <Panel
      title="赛季"
      extra={
        <Button type="primary" icon={<Glyph name="plus" />} disabled={!editable} onClick={() => setEditing('new')}>
          新建赛季
        </Button>
      }
    >
      <Table<Season>
        rowKey="id"
        loading={q.isFetching}
        dataSource={list}
        pagination={false}
        scroll={{ x: 820 }}
        columns={[
          { title: '赛季', dataIndex: 'name', render: (v: string, s) => <div><b>{v}</b><div className="muted num" style={{ fontSize: 12 }}>#{s.id}</div></div> },
          { title: '开始', dataIndex: 'starts_at', render: (v: string) => <span className="num">{dt(v)}</span> },
          { title: '结束', dataIndex: 'ends_at', render: (v: string) => <span className="num">{dt(v)}</span> },
          { title: '天数', key: 'days', align: 'right', render: (_, s) => <span className="num">{days(s.starts_at, s.ends_at)}</span> },
          {
            title: '状态',
            key: 'status',
            render: (_, s) => {
              const st = seasonStatus(s);
              return (
                <Space size={4}>
                  <Tag bordered={false} color={SEASON_STATUS[st]?.color}>
                    {SEASON_STATUS[st]?.text ?? st}
                  </Tag>
                  {st === 'active' && <span className="muted" style={{ fontSize: 12 }}>还剩 {Math.max(0, dayjs(s.ends_at).diff(dayjs(), 'day'))} 天</span>}
                  {st === 'settled' && s.settled_at && <span className="muted num" style={{ fontSize: 12 }}>{dt(s.settled_at, 'MM-DD HH:mm')}</span>}
                </Space>
              );
            },
          },
          {
            title: '操作',
            key: 'op',
            align: 'right',
            render: (_, s) => {
              const st = seasonStatus(s);
              return (
                <Space>
                  <Tooltip title={st === 'settled' ? '已结算的赛季不能修改' : undefined}>
                    <Button size="small" disabled={!editable || st === 'settled'} onClick={() => setEditing(s)}>
                      编辑
                    </Button>
                  </Tooltip>
                  <Tooltip title={st === 'settled' ? '已结算' : st === 'upcoming' ? '还没开始' : undefined}>
                    <Button size="small" danger disabled={!editable || st === 'settled' || st === 'upcoming'} onClick={() => confirmSettle(s)}>
                      手动结算
                    </Button>
                  </Tooltip>
                </Space>
              );
            },
          },
        ]}
      />
      <div className="muted" style={{ fontSize: 12, marginTop: 10 }}>
        赛季到期由后台任务自动结算；手动结算用于提前收尾或自动结算失败时补做。时间不能和其他赛季重叠。
      </div>
      <SeasonModal value={editing} list={list} onClose={() => setEditing(null)} />
    </Panel>
  );
}

function SeasonModal({ value, list, onClose }: { value: Season | 'new' | null; list: Season[]; onClose: () => void }) {
  const [form] = Form.useForm<{ name: string; range: [Dayjs, Dayjs] }>();
  const qc = useQueryClient();
  const editing = value && value !== 'new' ? value : null;
  const range = Form.useWatch('range', form);
  const save = useMutation({
    mutationFn: (body: SeasonInput) => (editing ? api.updateSeason(editing.id, body) : api.createSeason(body)),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['seasons'] });
      toastOk(editing ? '赛季已更新' : '赛季已创建');
      onClose();
    },
  });
  const span = range?.[0] && range?.[1] ? Math.round(range[1].diff(range[0], 'day', true)) : null;
  const started = editing ? Date.parse(editing.starts_at) <= Date.now() : false;

  return (
    <Modal
      open={value !== null}
      title={editing ? `编辑「${editing.name}」` : '新建赛季'}
      forceRender
      okText="保存"
      cancelText="取消"
      confirmLoading={save.isPending}
      onCancel={onClose}
      onOk={() => form.submit()}
      afterOpenChange={(o) => {
        if (!o) return;
        if (editing) form.setFieldsValue({ name: editing.name, range: toRange(editing.starts_at, editing.ends_at) });
        else {
          const last = [...list].sort((a, b) => b.ends_at.localeCompare(a.ends_at))[0];
          const start = last ? dayjs(last.ends_at) : dayjs().startOf('day');
          form.setFieldsValue({ name: '', range: [start, start.add(2, 'month')] });
        }
      }}
    >
      <Form form={form} layout="vertical" requiredMark={false} onFinish={(v) => save.mutate({ name: v.name.trim(), ...fromRange(v.range) })}>
        <Form.Item name="name" label="名称" rules={[{ required: true, whitespace: true, message: '例如：S4 新春赛' }]}>
          <Input maxLength={20} placeholder="S4 新春赛" />
        </Form.Item>
        <Form.Item
          name="range"
          label="时间"
          extra={span !== null ? `共 ${span} 天${span < 50 || span > 70 ? '（建议 2 个月一季）' : ''}` : undefined}
          rules={[
            { required: true, message: '请选择开始和结束时间' },
            {
              validator: (_, r: [Dayjs, Dayjs] | undefined) => {
                if (!r?.[0] || !r?.[1]) return Promise.resolve();
                if (!r[1].isAfter(r[0])) return Promise.reject(new Error('结束时间必须晚于开始时间'));
                const clash = overlapWith(list, editing?.id ?? null, r);
                return clash ? Promise.reject(new Error(`和「${clash.name}」（${dt(clash.starts_at, 'MM-DD')} – ${dt(clash.ends_at, 'MM-DD')}）时间重叠`)) : Promise.resolve();
              },
            },
          ]}
        >
          <DatePicker.RangePicker showTime={{ format: 'HH:mm' }} format={RANGE_FORMAT} style={{ width: '100%' }} disabled={[started, false]} />
        </Form.Item>
        {started && <Alert type="info" showIcon message="赛季已经开始，只能调整结束时间" />}
      </Form>
    </Modal>
  );
}
