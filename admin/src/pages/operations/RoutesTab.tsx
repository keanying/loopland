import { useMemo, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, App, Button, Col, DatePicker, Drawer, Form, Input, InputNumber, Row, Space, Table, Tag, Tooltip } from 'antd';
import type { Dayjs } from 'dayjs';
import { api } from '../../api/admin';
import type { MapCheckpoint, OrienteeringRoute, RouteCheckpoint, RouteInput } from '../../api/types';
import { useAuth } from '../../auth/AuthContext';
import SvgMap from '../../components/map/SvgMap';
import { routeColor } from '../../components/map/colors';
import { Panel } from '../../components/ui';
import { dayjs, dt, num } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { fromRange, PHASE_TAG, phaseOf, RANGE_FORMAT, toRange } from './shared';
import { Glyph } from '../../components/Glyph';

const MIN_POINTS = 2;
const MAX_POINTS = 12;
const DEFAULT_CENTER = { lat: 31.232, lng: 121.505 };

interface Point {
  uid: number;
  name: string;
  lat: number | null;
  lng: number | null;
  radius_m: number | null;
}

let uidSeq = 1;

/** Admin writes flat lat/lng; the App shape nests them in `center`. Accept both. */
function toPoint(c: RouteCheckpoint): Point {
  return { uid: uidSeq++, name: c.name, lat: c.lat ?? c.center?.lat ?? null, lng: c.lng ?? c.center?.lng ?? null, radius_m: c.radius_m };
}

function pointErrors(points: Point[]): string[] {
  const out: string[] = [];
  if (points.length < MIN_POINTS || points.length > MAX_POINTS) out.push(`打卡点需要 ${MIN_POINTS}–${MAX_POINTS} 个（现在 ${points.length} 个）`);
  points.forEach((p, i) => {
    const miss: string[] = [];
    if (!p.name.trim()) miss.push('名称');
    if (p.lat === null || Math.abs(p.lat) > 90) miss.push('纬度');
    if (p.lng === null || Math.abs(p.lng) > 180) miss.push('经度');
    if (!p.radius_m || p.radius_m <= 0) miss.push('半径');
    if (miss.length) out.push(`第 ${i + 1} 个点缺少${miss.join('、')}`);
  });
  return out;
}

export default function RoutesTab() {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const { can } = useAuth();
  const editable = can('ops.write');
  const q = useQuery({ queryKey: ['routes'], queryFn: api.routes });
  const [editing, setEditing] = useState<OrienteeringRoute | 'new' | null>(null);
  const remove = useMutation({
    mutationFn: (id: number) => api.deleteRoute(id),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['routes'] });
      qc.invalidateQueries({ queryKey: ['map-objects'] });
      toastOk('路线已删除');
    },
  });

  return (
    <Panel
      title="城市定向"
      extra={
        <Button type="primary" icon={<Glyph name="plus" />} disabled={!editable} onClick={() => setEditing('new')}>
          新建路线
        </Button>
      }
    >
      <Table<OrienteeringRoute>
        rowKey="id"
        loading={q.isFetching}
        dataSource={q.data?.items}
        pagination={false}
        scroll={{ x: 980 }}
        columns={[
          {
            title: '路线',
            dataIndex: 'name',
            render: (v: string, r) => (
              <div style={{ maxWidth: 260 }}>
                <span className="swatch" style={{ background: routeColor(r.id), borderRadius: '50%' }} />
                <b>{v}</b>
                <div className="muted" style={{ fontSize: 12 }}>
                  {r.description || '—'}
                </div>
              </div>
            ),
          },
          {
            title: '打卡点',
            key: 'cps',
            render: (_, r) => (
              <div style={{ maxWidth: 280 }}>
                <b className="num">{r.checkpoints.length}</b> 个
                <div className="muted" style={{ fontSize: 12 }}>
                  {r.checkpoints.map((c) => c.name).join(' → ')}
                </div>
              </div>
            ),
          },
          { title: '奖励', dataIndex: 'reward_energy', render: (v: number) => <span className="num">{v} 能量</span> },
          {
            title: '时间',
            key: 'time',
            render: (_, r) => (
              <span className="num" style={{ fontSize: 12, whiteSpace: 'nowrap' }}>
                {dt(r.starts_at, 'MM-DD')} – {dt(r.ends_at, 'MM-DD')}
              </span>
            ),
          },
          { title: '完成人数', key: 'finishers', align: 'right', render: (_, r) => <span className="num">{num(r.finishers ?? r.completed_count)}</span> },
          {
            title: '状态',
            key: 'phase',
            render: (_, r) => {
              const p = phaseOf(r.starts_at, r.ends_at);
              return <Tag bordered={false} color={PHASE_TAG[p].color}>{PHASE_TAG[p].text}</Tag>;
            },
          },
          {
            title: '操作',
            key: 'op',
            align: 'right',
            render: (_, r) => (
              <Space>
                <Button size="small" disabled={!editable} onClick={() => setEditing(r)}>
                  编辑
                </Button>
                <Button
                  size="small"
                  danger
                  disabled={!editable}
                  onClick={() =>
                    modal.confirm({
                      title: `删除「${r.name}」？`,
                      content: phaseOf(r.starts_at, r.ends_at) === 'active' ? '路线进行中，删除后跑者已打卡的进度作废。' : '删除后 App 不再展示这条路线。',
                      okText: '删除',
                      okButtonProps: { danger: true },
                      cancelText: '取消',
                      onOk: () => remove.mutateAsync(r.id),
                    })
                  }
                >
                  删除
                </Button>
              </Space>
            ),
          },
        ]}
      />
      <RouteDrawer value={editing} onClose={() => setEditing(null)} />
    </Panel>
  );
}

interface FormValues {
  name: string;
  description: string;
  reward_energy: number;
  range: [Dayjs, Dayjs];
}

function RouteDrawer({ value, onClose }: { value: OrienteeringRoute | 'new' | null; onClose: () => void }) {
  const [form] = Form.useForm<FormValues>();
  const qc = useQueryClient();
  const editing = value && value !== 'new' ? value : null;
  const [points, setPoints] = useState<Point[]>([]);
  const [tried, setTried] = useState(false);
  const errors = pointErrors(points);

  const save = useMutation({
    mutationFn: (body: RouteInput) => (editing ? api.updateRoute(editing.id, body) : api.createRoute(body)),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['routes'] });
      qc.invalidateQueries({ queryKey: ['map-objects'] });
      toastOk(editing ? '路线已更新' : '路线已创建');
      onClose();
    },
  });

  const submit = (v: FormValues) => {
    setTried(true);
    if (errors.length) return;
    save.mutate({
      name: v.name.trim(),
      description: (v.description ?? '').trim(),
      reward_energy: v.reward_energy,
      ...fromRange(v.range),
      checkpoints: points.map((p) => ({ name: p.name.trim(), lat: p.lat!, lng: p.lng!, radius_m: p.radius_m! })),
    });
  };

  const patch = (uid: number, d: Partial<Point>) => setPoints((ps) => ps.map((p) => (p.uid === uid ? { ...p, ...d } : p)));
  const move = (i: number, dir: -1 | 1) =>
    setPoints((ps) => {
      const n = [...ps];
      [n[i], n[i + dir]] = [n[i + dir], n[i]];
      return n;
    });
  const add = (at?: { lat: number; lng: number }) =>
    setPoints((ps) => {
      if (ps.length >= MAX_POINTS) return ps;
      const last = [...ps].reverse().find((p) => p.lat !== null && p.lng !== null);
      const pos = at ?? (last ? { lat: +(last.lat! - 0.003).toFixed(6), lng: +(last.lng! + 0.004).toFixed(6) } : DEFAULT_CENTER);
      return [...ps, { uid: uidSeq++, name: '', ...pos, radius_m: 60 }];
    });

  // Preview: checkpoints as map objects over the territories around them.
  const valid = points.filter((p) => p.lat !== null && p.lng !== null);
  const cps: MapCheckpoint[] = points.flatMap((p, index) => (p.lat !== null && p.lng !== null ? [{ route_id: editing?.id ?? 0, index, name: p.name || `点 ${index + 1}`, center: { lat: p.lat, lng: p.lng }, radius_m: p.radius_m ?? 60 }] : []));
  const bbox = useMemo<[number, number, number, number]>(() => {
    if (!valid.length) return [DEFAULT_CENTER.lng - 0.03, DEFAULT_CENTER.lat - 0.03, DEFAULT_CENTER.lng + 0.03, DEFAULT_CENTER.lat + 0.03];
    const lngs = valid.map((p) => p.lng!);
    const lats = valid.map((p) => p.lat!);
    const pad = 0.006;
    return [Math.min(...lngs) - pad, Math.min(...lats) - pad, Math.max(...lngs) + pad, Math.max(...lats) + pad].map((n) => +n.toFixed(3)) as [number, number, number, number];
    // eslint-disable-next-line react-hooks/exhaustive-deps -- recompute on coordinate changes only
  }, [valid.map((p) => `${p.lat},${p.lng}`).join(';')]);
  const geo = useQuery({
    queryKey: ['territories', 'geo', bbox.join(',')],
    queryFn: () => api.territoriesGeo(bbox),
    enabled: value !== null && bbox[2] - bbox[0] <= 2 && bbox[3] - bbox[1] <= 2,
    placeholderData: (p) => p,
  });

  return (
    <Drawer
      open={value !== null}
      onClose={onClose}
      width={1080}
      title={editing ? `编辑「${editing.name}」` : '新建定向路线'}
      forceRender
      afterOpenChange={(o) => {
        if (!o) return;
        setTried(false);
        if (editing) {
          form.setFieldsValue({ name: editing.name, description: editing.description, reward_energy: editing.reward_energy, range: toRange(editing.starts_at, editing.ends_at) });
          setPoints([...editing.checkpoints].sort((a, b) => (a.index ?? 0) - (b.index ?? 0)).map(toPoint));
        } else {
          const start = dayjs().add(1, 'day').startOf('day');
          form.resetFields();
          form.setFieldsValue({ reward_energy: 150, range: [start, start.add(30, 'day')] });
          setPoints([]);
        }
      }}
      extra={
        <Space>
          <Button onClick={onClose}>取消</Button>
          <Button type="primary" loading={save.isPending} onClick={() => form.submit()}>
            保存
          </Button>
        </Space>
      }
    >
      <Row gutter={24}>
        <Col xs={24} lg={13}>
          <Form<FormValues> form={form} layout="vertical" requiredMark={false} onFinish={submit} onFinishFailed={() => setTried(true)}>
            <Row gutter={12}>
              <Col span={14}>
                <Form.Item name="name" label="路线名称" rules={[{ required: true, whitespace: true }]}>
                  <Input maxLength={20} placeholder="城南线" />
                </Form.Item>
              </Col>
              <Col span={10}>
                <Form.Item name="reward_energy" label="完成奖励能量" rules={[{ required: true }]}>
                  <InputNumber className="num" min={0} step={10} style={{ width: '100%' }} />
                </Form.Item>
              </Col>
            </Row>
            <Form.Item name="description" label="说明">
              <Input.TextArea rows={2} maxLength={120} placeholder="从老城厢一路到前滩，沿江 6 个打卡点" />
            </Form.Item>
            <Form.Item
              name="range"
              label="开放时间"
              rules={[
                { required: true },
                { validator: (_, r?: [Dayjs, Dayjs]) => (!r?.[0] || !r?.[1] || r[1].isAfter(r[0]) ? Promise.resolve() : Promise.reject(new Error('结束时间必须晚于开始时间'))) },
              ]}
            >
              <DatePicker.RangePicker showTime={{ format: 'HH:mm' }} format={RANGE_FORMAT} style={{ width: '100%' }} />
            </Form.Item>
          </Form>

          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', margin: '4px 0 6px' }}>
            <b>
              打卡点 <span className="muted num">{points.length}/{MAX_POINTS}</span>
            </b>
            <Button size="small" icon={<Glyph name="plus" size={14} />} disabled={points.length >= MAX_POINTS} onClick={() => add()}>
              添加打卡点
            </Button>
          </div>
          <div className="cp-row muted" style={{ fontSize: 12 }}>
            <span>#</span>
            <span>名称</span>
            <span>纬度 lat</span>
            <span>经度 lng</span>
            <span>半径 m</span>
            <span />
          </div>
          {points.map((p, i) => (
            <div className="cp-row" key={p.uid}>
              <span className="num" style={{ width: 24, height: 24, borderRadius: 12, border: `2px solid ${routeColor(editing?.id ?? 0)}`, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 800 }}>
                {i + 1}
              </span>
              <Input size="small" value={p.name} maxLength={16} placeholder="拱桥" status={tried && !p.name.trim() ? 'error' : undefined} onChange={(e) => patch(p.uid, { name: e.target.value })} />
              <InputNumber size="small" className="num" value={p.lat} min={-90} max={90} step={0.0005} precision={6} style={{ width: '100%' }} status={tried && p.lat === null ? 'error' : undefined} onChange={(v) => patch(p.uid, { lat: v })} />
              <InputNumber size="small" className="num" value={p.lng} min={-180} max={180} step={0.0005} precision={6} style={{ width: '100%' }} status={tried && p.lng === null ? 'error' : undefined} onChange={(v) => patch(p.uid, { lng: v })} />
              <InputNumber size="small" className="num" value={p.radius_m} min={10} max={500} step={10} style={{ width: '100%' }} onChange={(v) => patch(p.uid, { radius_m: v })} />
              <Space size={2}>
                <Tooltip title="上移">
                  <Button size="small" type="text" icon={<Glyph name="arrowUp" size={14} />} disabled={i === 0} onClick={() => move(i, -1)} aria-label="上移" />
                </Tooltip>
                <Tooltip title="下移">
                  <Button size="small" type="text" icon={<Glyph name="arrowDown" size={14} />} disabled={i === points.length - 1} onClick={() => move(i, 1)} aria-label="下移" />
                </Tooltip>
                <Tooltip title="删除">
                  <Button size="small" type="text" danger icon={<Glyph name="trash" size={14} />} onClick={() => setPoints((ps) => ps.filter((x) => x.uid !== p.uid))} aria-label="删除" />
                </Tooltip>
              </Space>
            </div>
          ))}
          {points.length === 0 && <div className="muted" style={{ padding: '16px 0' }}>还没有打卡点：点「添加打卡点」，或直接在右侧地图上点击。</div>}
          {(tried || points.length > MAX_POINTS) && errors.length > 0 && <Alert type="error" showIcon style={{ marginTop: 10 }} message={errors.join('；')} />}
        </Col>
        <Col xs={24} lg={11}>
          <b>预览</b>
          <div className="muted" style={{ fontSize: 12, margin: '2px 0 8px' }}>
            按顺序连线，圆圈是打卡半径。点击地图在末尾添加一个打卡点，拖动平移、滚轮缩放。
          </div>
          <div className="route-preview">
            <SvgMap
              items={geo.data?.items ?? []}
              selectedId={null}
              onSelect={() => undefined}
              focus={null}
              objects={{ bosses: [], chests: [], checkpoints: cps }}
              preview
              picking={points.length < MAX_POINTS}
              onPick={(pt) => add(pt)}
            />
          </div>
        </Col>
      </Row>
    </Drawer>
  );
}
