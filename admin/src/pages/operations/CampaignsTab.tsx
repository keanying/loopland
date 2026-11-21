import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, App, Button, Col, DatePicker, Form, Input, InputNumber, Modal, Row, Select, Space, Table, Tag, Tooltip } from 'antd';
import { PlusOutlined } from '@ant-design/icons';
import type { Dayjs } from 'dayjs';
import { api } from '../../api/admin';
import type { Campaign, CampaignInput, CampaignRules, CampaignType } from '../../api/types';
import { useAuth } from '../../auth/AuthContext';
import { mmss, parseMmss } from '../../utils/gameplay';
import { Panel } from '../../components/ui';
import { dayjs, dt, num } from '../../utils/format';
import { CAMPAIGN_TYPE } from '../../utils/labels';
import { toastOk } from '../../utils/notify';
import { fromRange, PHASE_TAG, phaseOf, RANGE_FORMAT, toRange } from './shared';

function rulesText(type: CampaignType, r: CampaignRules): string {
  const parts: string[] = [];
  if (type === 'night_run' && r.start_hour_from !== undefined && r.start_hour_to !== undefined) parts.push(`${r.start_hour_from}:00–${r.start_hour_to}:00 出发`);
  if (r.min_distance_km !== undefined) parts.push(`≥ ${r.min_distance_km} km`);
  if (type === 'pace' && r.max_pace_s_per_km) parts.push(`配速快于 ${mmss(r.max_pace_s_per_km)} /km`);
  return parts.join(' · ') || '—';
}

interface FormValues {
  title: string;
  type: CampaignType;
  description: string;
  range: [Dayjs, Dayjs];
  min_distance_km: number;
  pace: string;
  start_hour_from: number;
  start_hour_to: number;
  reward_energy: number;
  reward_medal_name?: string;
}

export default function CampaignsTab() {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const { can } = useAuth();
  const editable = can('ops.write');
  const q = useQuery({ queryKey: ['campaigns'], queryFn: api.campaigns });
  const [editing, setEditing] = useState<Campaign | 'new' | null>(null);
  const remove = useMutation({
    mutationFn: (id: number) => api.deleteCampaign(id),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['campaigns'] });
      toastOk('活动已删除');
    },
  });

  return (
    <Panel
      title="限时活动"
      extra={
        <Button type="primary" icon={<PlusOutlined />} disabled={!editable} onClick={() => setEditing('new')}>
          新建活动
        </Button>
      }
    >
      <Table<Campaign>
        rowKey="id"
        loading={q.isFetching}
        dataSource={q.data?.items}
        pagination={false}
        scroll={{ x: 1080 }}
        columns={[
          {
            title: '活动',
            dataIndex: 'title',
            render: (v: string, c) => (
              <div style={{ maxWidth: 240 }}>
                <b>{v}</b>
                <div className="muted" style={{ fontSize: 12 }}>
                  {c.description || '—'}
                </div>
              </div>
            ),
          },
          { title: '类型', dataIndex: 'type', render: (v: string) => <Tag bordered={false} color={CAMPAIGN_TYPE[v]?.color}>{CAMPAIGN_TYPE[v]?.text ?? v}</Tag> },
          { title: '规则', key: 'rules', render: (_, c) => <span className="num" style={{ fontSize: 13 }}>{rulesText(c.type, c.rules ?? {})}</span> },
          {
            title: '时间',
            key: 'time',
            render: (_, c) => (
              <span className="num" style={{ fontSize: 12, whiteSpace: 'nowrap' }}>
                {dt(c.starts_at, 'MM-DD HH:mm')} – {dt(c.ends_at, 'MM-DD HH:mm')}
              </span>
            ),
          },
          {
            title: '奖励',
            key: 'reward',
            render: (_, c) => (
              <span>
                <span className="num">{c.reward_energy} 能量</span>
                {(c.reward_medal?.name ?? c.reward_medal_name) && (
                  <Tag bordered={false} color="gold" style={{ marginLeft: 6 }}>
                    {c.reward_medal?.name ?? c.reward_medal_name}
                  </Tag>
                )}
              </span>
            ),
          },
          {
            title: '参与 / 完成',
            key: 'people',
            align: 'right',
            render: (_, c) => (
              <span className="num">
                {num(c.participants)}
                {c.completed_count !== undefined && <span className="muted"> / {num(c.completed_count)}</span>}
              </span>
            ),
          },
          {
            title: '状态',
            key: 'phase',
            render: (_, c) => {
              const p = phaseOf(c.starts_at, c.ends_at);
              return <Tag bordered={false} color={PHASE_TAG[p].color}>{PHASE_TAG[p].text}</Tag>;
            },
          },
          {
            title: '操作',
            key: 'op',
            align: 'right',
            render: (_, c) => {
              const started = phaseOf(c.starts_at, c.ends_at) !== 'upcoming';
              return (
                <Space>
                  <Button size="small" disabled={!editable} onClick={() => setEditing(c)}>
                    编辑
                  </Button>
                  <Tooltip title={started ? '已开始的活动不能删除' : undefined}>
                    <Button
                      size="small"
                      danger
                      disabled={!editable || started}
                      onClick={() =>
                        modal.confirm({
                          title: `删除「${c.title}」？`,
                          content: '活动还没开始，删除后 App 不再展示。',
                          okText: '删除',
                          okButtonProps: { danger: true },
                          cancelText: '取消',
                          onOk: () => remove.mutateAsync(c.id),
                        })
                      }
                    >
                      删除
                    </Button>
                  </Tooltip>
                </Space>
              );
            },
          },
        ]}
      />
      <CampaignModal value={editing} onClose={() => setEditing(null)} />
    </Panel>
  );
}

function CampaignModal({ value, onClose }: { value: Campaign | 'new' | null; onClose: () => void }) {
  const [form] = Form.useForm<FormValues>();
  const qc = useQueryClient();
  const editing = value && value !== 'new' ? value : null;
  const type = Form.useWatch('type', form) ?? 'night_run';
  const save = useMutation({
    mutationFn: (body: CampaignInput) => (editing ? api.updateCampaign(editing.id, body) : api.createCampaign(body)),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['campaigns'] });
      toastOk(editing ? '活动已更新' : '活动已创建');
      onClose();
    },
  });

  const submit = (v: FormValues) => {
    const rules: CampaignRules =
      v.type === 'pace'
        ? { min_distance_km: v.min_distance_km, max_pace_s_per_km: parseMmss(v.pace) ?? undefined }
        : v.type === 'night_run'
          ? { min_distance_km: v.min_distance_km, start_hour_from: v.start_hour_from, start_hour_to: v.start_hour_to }
          : { min_distance_km: v.min_distance_km };
    save.mutate({
      title: v.title.trim(),
      type: v.type,
      description: (v.description ?? '').trim(),
      rules,
      ...fromRange(v.range),
      reward_energy: v.reward_energy,
      reward_medal_name: v.reward_medal_name?.trim() || null,
    });
  };

  const started = editing ? Date.parse(editing.starts_at) <= Date.now() : false;

  return (
    <Modal
      open={value !== null}
      title={editing ? `编辑「${editing.title}」` : '新建限时活动'}
      width={640}
      forceRender
      okText="保存"
      cancelText="取消"
      confirmLoading={save.isPending}
      onCancel={onClose}
      onOk={() => form.submit()}
      afterOpenChange={(o) => {
        if (!o) return;
        if (editing) {
          const r = editing.rules ?? {};
          form.setFieldsValue({
            title: editing.title,
            type: editing.type,
            description: editing.description,
            range: toRange(editing.starts_at, editing.ends_at),
            min_distance_km: r.min_distance_km ?? 5,
            pace: r.max_pace_s_per_km ? mmss(r.max_pace_s_per_km) : '6:00',
            start_hour_from: r.start_hour_from ?? 19,
            start_hour_to: r.start_hour_to ?? 23,
            reward_energy: editing.reward_energy,
            reward_medal_name: editing.reward_medal?.name ?? editing.reward_medal_name ?? '',
          });
        } else {
          const start = dayjs().add(1, 'day').startOf('day');
          form.resetFields();
          form.setFieldsValue({ type: 'night_run', range: [start, start.add(7, 'day')], min_distance_km: 5, pace: '6:00', start_hour_from: 19, start_hour_to: 23, reward_energy: 100 });
        }
      }}
    >
      {started && <Alert type="warning" showIcon style={{ marginBottom: 12 }} message="活动已经开始，修改规则只影响之后的运动结算" />}
      <Form<FormValues> form={form} layout="vertical" requiredMark={false} onFinish={submit}>
        <Row gutter={12}>
          <Col span={14}>
            <Form.Item name="title" label="标题" rules={[{ required: true, whitespace: true }]}>
              <Input maxLength={20} placeholder="夜跑专场" />
            </Form.Item>
          </Col>
          <Col span={10}>
            <Form.Item name="type" label="类型" rules={[{ required: true }]}>
              <Select options={Object.entries(CAMPAIGN_TYPE).map(([k, v]) => ({ value: k, label: v.text }))} />
            </Form.Item>
          </Col>
        </Row>
        <Form.Item name="description" label="说明（App 展示）">
          <Input.TextArea rows={2} maxLength={120} showCount placeholder="晚上 7 点到 11 点出发，跑满 5 km" />
        </Form.Item>

        <div className="tile" style={{ marginBottom: 16 }}>
          <b>完成条件</b>
          <Row gutter={12} style={{ marginTop: 10 }}>
            <Col span={8}>
              <Form.Item name="min_distance_km" label="单次最短距离 km" rules={[{ required: true }, { type: 'number', min: 0.1, message: '必须大于 0' }]} style={{ marginBottom: 0 }}>
                <InputNumber className="num" min={0.1} step={1} precision={1} style={{ width: '100%' }} />
              </Form.Item>
            </Col>
            {type === 'pace' && (
              <Col span={8}>
                <Form.Item
                  name="pace"
                  label="配速快于（分:秒 /km）"
                  rules={[
                    { required: true, message: '例如 6:00' },
                    { validator: (_, v: string) => (!v || (parseMmss(v) ?? 0) > 0 ? Promise.resolve() : Promise.reject(new Error('格式为 分:秒，例如 5:30'))) },
                  ]}
                  style={{ marginBottom: 0 }}
                >
                  <Input className="num" placeholder="6:00" suffix="/km" />
                </Form.Item>
              </Col>
            )}
            {type === 'night_run' && (
              <>
                <Col span={8}>
                  <Form.Item name="start_hour_from" label="出发时段 从（点）" rules={[{ required: true }]} style={{ marginBottom: 0 }}>
                    <InputNumber className="num" min={0} max={23} style={{ width: '100%' }} suffix=":00" />
                  </Form.Item>
                </Col>
                <Col span={8}>
                  <Form.Item
                    name="start_hour_to"
                    label="到（点）"
                    dependencies={['start_hour_from']}
                    rules={[
                      { required: true },
                      ({ getFieldValue }) => ({
                        validator: (_, v: number) => (v > getFieldValue('start_hour_from') ? Promise.resolve() : Promise.reject(new Error('要晚于开始时段'))),
                      }),
                    ]}
                    style={{ marginBottom: 0 }}
                  >
                    <InputNumber className="num" min={1} max={23} style={{ width: '100%' }} suffix=":00" />
                  </Form.Item>
                </Col>
              </>
            )}
          </Row>
          <div className="muted" style={{ fontSize: 12, marginTop: 8 }}>
            {type === 'pace' && '单次运动距离达标且平均配速快于设定值即完成。'}
            {type === 'night_run' && '在这个时段内出发、距离达标即完成；时段不能跨过午夜。'}
            {type === 'distance' && '单次运动距离达标即完成。'}
          </div>
        </div>

        <Form.Item
          name="range"
          label="活动时间"
          rules={[
            { required: true },
            { validator: (_, r?: [Dayjs, Dayjs]) => (!r?.[0] || !r?.[1] || r[1].isAfter(r[0]) ? Promise.resolve() : Promise.reject(new Error('结束时间必须晚于开始时间'))) },
          ]}
        >
          <DatePicker.RangePicker showTime={{ format: 'HH:mm' }} format={RANGE_FORMAT} style={{ width: '100%' }} />
        </Form.Item>
        <Row gutter={12}>
          <Col span={10}>
            <Form.Item name="reward_energy" label="奖励能量" rules={[{ required: true }]}>
              <InputNumber className="num" min={0} step={10} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
          <Col span={14}>
            <Form.Item name="reward_medal_name" label="奖牌名称（可选）" extra="留空则不发奖牌">
              <Input maxLength={12} placeholder="夜行者" />
            </Form.Item>
          </Col>
        </Row>
      </Form>
    </Modal>
  );
}
