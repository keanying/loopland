// 地图与领地 · V2 玩法对象操作：召唤怪兽、投放宝箱、批量撒宝箱，以及地图上选中对象的卡片。
import { useEffect } from 'react';
import { Link } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useGameplayDefaults } from '../hooks/useGameplayDefaults';
import { Alert, App, Button, Col, Form, Input, InputNumber, Modal, Row, Select, Space } from 'antd';
import { api } from '../api/admin';
import type { BossCreate, ChestCreate, LatLng, MapBoss, MapChest } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import { toastOk } from '../utils/notify';
import { BOSS_KIND } from '../utils/labels';
import { dt } from '../utils/format';
import { BossBadge, HpBar } from './gameplay';
import { bossKindName, timeLeft } from '../utils/gameplay';
import { Panel, Tile } from './ui';
import { Glyph } from './Glyph';

type BBox = [number, number, number, number];


function invalidateObjects(qc: ReturnType<typeof useQueryClient>) {
  qc.invalidateQueries({ queryKey: ['map-objects'] });
  qc.invalidateQueries({ queryKey: ['bosses'] });
  qc.invalidateQueries({ queryKey: ['chests'] });
}

/** Banner over the map while the user picks a coordinate. */
export function PickBanner({ text, onCancel }: { text: string; onCancel: () => void }) {
  return (
    <div className="pick-banner" role="status">
      <Glyph name="locate" size="1em" /> {text}
      <Button size="small" shape="round" icon={<Glyph name="close" size={14} />} onClick={onCancel}>
        取消
      </Button>
    </div>
  );
}

function CoordFields({ onPickOnMap }: { onPickOnMap: () => void }) {
  return (
    <Row gutter={12} align="bottom">
      <Col span={9}>
        <Form.Item name="lat" label="纬度 lat" rules={[{ required: true, message: '请填写纬度' }]}>
          <InputNumber className="num" style={{ width: '100%' }} min={-90} max={90} step={0.0001} precision={6} placeholder="31.232000" />
        </Form.Item>
      </Col>
      <Col span={9}>
        <Form.Item name="lng" label="经度 lng" rules={[{ required: true, message: '请填写经度' }]}>
          <InputNumber className="num" style={{ width: '100%' }} min={-180} max={180} step={0.0001} precision={6} placeholder="121.505000" />
        </Form.Item>
      </Col>
      <Col span={6}>
        <Form.Item>
          <Button block icon={<Glyph name="locate" />} onClick={onPickOnMap}>
            地图选点
          </Button>
        </Form.Item>
      </Col>
    </Row>
  );
}

export interface PickableModalProps {
  open: boolean;
  onClose: () => void;
  /** Hide the modal and let the user click the map; `picked` comes back here. */
  onPickOnMap: () => void;
  picked: LatLng | null;
  onPointChange?: (p: LatLng | null) => void;
}

type BossForm = BossCreate;

export function SummonBossModal({ open, onClose, onPickOnMap, picked, onPointChange, onCreated }: PickableModalProps & { onCreated: (id: number, center: LatLng) => void }) {
  const [form] = Form.useForm<BossForm>();
  const qc = useQueryClient();
  const d = useGameplayDefaults();
  const lat = Form.useWatch('lat', form);
  const lng = Form.useWatch('lng', form);

  useEffect(() => {
    onPointChange?.(open && typeof lat === 'number' && typeof lng === 'number' ? { lat, lng } : null);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- report coordinate changes only
  }, [lat, lng, open]);

  useEffect(() => {
    if (picked) form.setFieldsValue(picked);
  }, [picked, form]);

  const create = useMutation({
    mutationFn: (v: BossForm) => api.createBoss(v),
    onSuccess: (b) => {
      invalidateObjects(qc);
      toastOk(`已召唤 ${b.name ?? bossKindName(b.kind)}，${b.radius_m ?? ''} m 范围内的领地产能减半`);
      onCreated(b.id, b.center);
      form.resetFields();
      onClose();
    },
  });

  return (
    <Modal
      open={open}
      title="召唤怪兽"
      forceRender
      okText="召唤"
      cancelText="取消"
      confirmLoading={create.isPending}
      onCancel={onClose}
      onOk={() => form.submit()}
      afterOpenChange={(o) => {
        if (o && form.getFieldValue('hp') === undefined) {
          form.setFieldsValue({ kind: (d.kinds[0]?.value ?? 'sofa') as BossCreate['kind'], level: 10, hp: d.boss.default_hp, radius_m: d.boss.radius_m, duration_h: d.boss.duration_h });
        }
      }}
    >
      <Form<BossForm> form={form} layout="vertical" requiredMark={false} onFinish={(v) => create.mutate({ ...v, location_name: v.location_name.trim() })}>
        <Row gutter={12}>
          <Col span={12}>
            <Form.Item name="kind" label="种类" rules={[{ required: true }]}>
              <Select options={d.kinds.map((k) => ({ value: k.value, label: `${k.label} · ${BOSS_KIND[k.value]?.hint ?? ''}` }))} />
            </Form.Item>
          </Col>
          <Col span={12}>
            <Form.Item name="location_name" label="地点名称（App 展示）" rules={[{ required: true, whitespace: true, message: '例如：滨江公园一带' }]}>
              <Input maxLength={20} placeholder="滨江公园一带" />
            </Form.Item>
          </Col>
        </Row>
        <CoordFields onPickOnMap={onPickOnMap} />
        <Row gutter={12}>
          <Col span={6}>
            <Form.Item name="level" label="等级" rules={[{ required: true }]}>
              <InputNumber className="num" min={1} max={99} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
          <Col span={6}>
            <Form.Item name="hp" label="血量" rules={[{ required: true }]}>
              <InputNumber className="num" min={1} step={1000} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
          <Col span={6}>
            <Form.Item name="radius_m" label="半径 m" rules={[{ required: true }]}>
              <InputNumber className="num" min={50} max={5000} step={100} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
          <Col span={6}>
            <Form.Item name="duration_h" label="持续 小时" rules={[{ required: true }]}>
              <InputNumber className="num" min={1} max={336} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
        </Row>
        <div className="muted" style={{ fontSize: 12 }}>
          默认值来自玩法配置「怪兽」（血量 {d.boss.default_hp}、半径 {d.boss.radius_m} m、持续 {d.boss.duration_h} 小时）。深夜时段也可以手动投放；怪兽在场期间范围内领地每日产能减半。
        </div>
      </Form>
    </Modal>
  );
}

export function ChestModal({ open, onClose, onPickOnMap, picked, onPointChange }: PickableModalProps) {
  const [form] = Form.useForm<ChestCreate>();
  const qc = useQueryClient();
  const d = useGameplayDefaults();
  const lat = Form.useWatch('lat', form);
  const lng = Form.useWatch('lng', form);

  useEffect(() => {
    onPointChange?.(open && typeof lat === 'number' && typeof lng === 'number' ? { lat, lng } : null);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- report coordinate changes only
  }, [lat, lng, open]);
  useEffect(() => {
    if (picked) form.setFieldsValue(picked);
  }, [picked, form]);

  const create = useMutation({
    mutationFn: (v: ChestCreate) => api.createChest(v),
    onSuccess: () => {
      invalidateObjects(qc);
      toastOk('宝箱已投放');
      form.resetFields();
      onClose();
    },
  });

  return (
    <Modal
      open={open}
      title="投放宝箱"
      forceRender
      okText="投放"
      cancelText="取消"
      confirmLoading={create.isPending}
      onCancel={onClose}
      onOk={() => form.submit()}
      afterOpenChange={(o) => {
        if (o && form.getFieldValue('energy_min') === undefined) {
          form.setFieldsValue({ energy_min: d.chest.energy_min, energy_max: d.chest.energy_max, duration_h: d.chest.duration_h, radius_m: d.chest.radius_m });
        }
      }}
    >
      <Form<ChestCreate> form={form} layout="vertical" requiredMark={false} onFinish={(v) => create.mutate(v)}>
        <CoordFields onPickOnMap={onPickOnMap} />
        <Row gutter={12}>
          <Col span={6}>
            <Form.Item name="energy_min" label="能量下限" rules={[{ required: true }]}>
              <InputNumber className="num" min={1} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
          <Col span={6}>
            <Form.Item
              name="energy_max"
              label="能量上限"
              dependencies={['energy_min']}
              rules={[
                { required: true },
                ({ getFieldValue }) => ({
                  validator: (_, v: number) => (v >= getFieldValue('energy_min') ? Promise.resolve() : Promise.reject(new Error('不能小于下限'))),
                }),
              ]}
            >
              <InputNumber className="num" min={1} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
          <Col span={6}>
            <Form.Item name="radius_m" label="半径 m" rules={[{ required: true }]}>
              <InputNumber className="num" min={10} max={500} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
          <Col span={6}>
            <Form.Item name="duration_h" label="持续 小时" rules={[{ required: true }]}>
              <InputNumber className="num" min={1} max={168} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
        </Row>
        <div className="muted" style={{ fontSize: 12 }}>
          跑步轨迹经过宝箱范围自动开启，每人每个宝箱只能开一次。宝箱能量不计入每日上限。
        </div>
      </Form>
    </Modal>
  );
}

/** AMap viewports can exceed the server's 2° bbox limit; keep the centre. */
function clamp2(b: BBox): BBox {
  const cx = (b[0] + b[2]) / 2;
  const cy = (b[1] + b[3]) / 2;
  const hx = Math.min((b[2] - b[0]) / 2, 0.99);
  const hy = Math.min((b[3] - b[1]) / 2, 0.99);
  return [cx - hx, cy - hy, cx + hx, cy + hy].map((n) => +n.toFixed(6)) as BBox;
}

export function ScatterModal({ open, onClose, viewport }: { open: boolean; onClose: () => void; viewport: BBox | null }) {
  const [form] = Form.useForm<{ count: number; duration_h: number }>();
  const qc = useQueryClient();
  const d = useGameplayDefaults();
  const box = viewport ? clamp2(viewport) : null;
  const kmW = box ? ((box[2] - box[0]) * 111.32 * Math.cos((((box[1] + box[3]) / 2) * Math.PI) / 180)).toFixed(1) : '—';
  const kmH = box ? ((box[3] - box[1]) * 110.57).toFixed(1) : '—';

  const scatter = useMutation({
    mutationFn: (v: { count: number; duration_h: number }) => api.scatterChests({ bbox: box!.join(','), count: v.count, duration_h: v.duration_h }),
    onSuccess: (r, v) => {
      invalidateObjects(qc);
      toastOk(`已在当前视野撒下 ${r.placed ?? r.created ?? r.items?.length ?? v.count} 个宝箱`);
      onClose();
    },
  });

  return (
    <Modal
      open={open}
      title="批量撒宝箱"
      forceRender
      okText="撒宝箱"
      cancelText="取消"
      okButtonProps={{ disabled: !box }}
      confirmLoading={scatter.isPending}
      onCancel={onClose}
      onOk={() => form.submit()}
      afterOpenChange={(o) => {
        if (o) form.setFieldsValue({ count: d.chest.daily_spawn, duration_h: d.chest.duration_h });
      }}
    >
      <Alert
        type="info"
        showIcon
        style={{ marginBottom: 16 }}
        message={`范围：地图当前视野（约 ${kmW} × ${kmH} km）`}
        description={
          <span className="num" style={{ fontSize: 12 }}>
            {box ? `bbox ${box.join(', ')}` : '地图还没加载完'} · 在近 30 天跑者常经过的轨迹点上随机撒，先把地图移到想撒的区域
          </span>
        }
      />
      <Form form={form} layout="vertical" requiredMark={false} onFinish={(v) => scatter.mutate(v)}>
        <Row gutter={12}>
          <Col span={12}>
            <Form.Item name="count" label="数量" rules={[{ required: true }]}>
              <InputNumber className="num" min={1} max={200} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
          <Col span={12}>
            <Form.Item name="duration_h" label="持续 小时" rules={[{ required: true }]}>
              <InputNumber className="num" min={1} max={168} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
        </Row>
        <div className="muted" style={{ fontSize: 12 }}>
          能量范围和半径用玩法配置「宝箱」的默认值（{d.chest.energy_min}–{d.chest.energy_max} 能量，半径 {d.chest.radius_m} m）。
        </div>
      </Form>
    </Modal>
  );
}

/** Right-hand card for a boss or chest picked on the map. */
export function MapObjectCard({ boss, chest, onClose }: { boss?: MapBoss; chest?: MapChest; onClose: () => void }) {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const { can } = useAuth();
  const editable = can('ops.write');
  const end = useMutation({
    mutationFn: (id: number) => api.endBoss(id),
    onSuccess: () => {
      invalidateObjects(qc);
      toastOk('已提前结束，参与者按到期规则返还能量');
      onClose();
    },
  });
  const remove = useMutation({
    mutationFn: (id: number) => api.deleteChest(id),
    onSuccess: () => {
      invalidateObjects(qc);
      toastOk('宝箱已下架');
      onClose();
    },
  });

  if (boss) {
    return (
      <Panel title="怪兽" extra={<Button size="small" type="text" icon={<Glyph name="close" size={14} />} onClick={onClose} aria-label="关闭" />}>
        <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
          <BossBadge kind={boss.kind} size={52} />
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 20, fontWeight: 800 }}>
              {boss.name || bossKindName(boss.kind)} <span className="muted num">Lv.{boss.level}</span>
            </div>
            <div className="muted" style={{ fontSize: 12 }}>
              {boss.location_name} · #{boss.id}
            </div>
          </div>
        </div>
        <div style={{ marginTop: 16 }}>
          <HpBar hp={boss.hp} max={boss.hp_max} />
        </div>
        <Row gutter={8} style={{ marginTop: 14 }}>
          <Col span={12}>
            <Tile v={`${boss.radius_m} m`} l="范围半径" />
          </Col>
          <Col span={12}>
            <Tile v={timeLeft(boss.expires_at).replace('还剩 ', '')} l={`到期 ${dt(boss.expires_at, 'MM-DD HH:mm')}`} />
          </Col>
        </Row>
        <Space style={{ marginTop: 16 }} wrap>
          <Link to={`/operations?tab=bosses&boss=${boss.id}`}>
            <Button type="primary">伤害排名与掉落</Button>
          </Link>
          <Button
            danger
            disabled={!editable}
            loading={end.isPending}
            onClick={() =>
              modal.confirm({
                title: `提前结束「${boss.name}」？`,
                content: '按到期未击败处理：怪兽消失，参与者返还部分合击能量，不发掉落。',
                okText: '提前结束',
                okButtonProps: { danger: true },
                cancelText: '取消',
                onOk: () => end.mutateAsync(boss.id),
              })
            }
          >
            提前结束
          </Button>
        </Space>
      </Panel>
    );
  }
  if (chest) {
    return (
      <Panel title="宝箱" extra={<Button size="small" type="text" icon={<Glyph name="close" size={14} />} onClick={onClose} aria-label="关闭" />}>
        <div style={{ fontSize: 20, fontWeight: 800 }}>宝箱 #{chest.id}</div>
        <div className="muted num" style={{ fontSize: 12 }}>
          {chest.center.lat.toFixed(5)}, {chest.center.lng.toFixed(5)}
        </div>
        <Row gutter={8} style={{ marginTop: 14 }}>
          <Col span={12}>
            <Tile v={`${chest.radius_m} m`} l="开启半径" />
          </Col>
          <Col span={12}>
            <Tile v={timeLeft(chest.expires_at).replace('还剩 ', '')} l={`到期 ${dt(chest.expires_at, 'MM-DD HH:mm')}`} />
          </Col>
        </Row>
        <Space style={{ marginTop: 16 }} wrap>
          <Link to="/operations?tab=chests">
            <Button>宝箱列表</Button>
          </Link>
          <Button
            danger
            disabled={!editable}
            loading={remove.isPending}
            onClick={() =>
              modal.confirm({ title: `下架宝箱 #${chest.id}？`, content: '下架后 App 地图上不再显示，已经开过的不受影响。', okText: '下架', okButtonProps: { danger: true }, cancelText: '取消', onOk: () => remove.mutateAsync(chest.id) })
            }
          >
            下架
          </Button>
        </Space>
      </Panel>
    );
  }
  return null;
}
