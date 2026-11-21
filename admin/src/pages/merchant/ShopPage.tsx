// 能量商城 (E-05): items by type, create / edit (territory skins get colours + pattern with a live swatch),
// on-sale toggle, limited-until, and redemption stats. Energy is earned by exercise only.
import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, Button, Col, ColorPicker, DatePicker, Form, Image, Input, InputNumber, Modal, Row, Segmented, Select, Space, Switch, Table, Tag, Tooltip } from 'antd';
import { PlusOutlined, ThunderboltFilled } from '@ant-design/icons';
import type { Color } from 'antd/es/color-picker';
import type { Dayjs } from 'dayjs';
import { perksApi, type ShopItem, type ShopItemInput, type ShopItemType } from '../../api/perks';
import { useAuth } from '../../auth/AuthContext';
import { PageHeader, Panel, Tile } from '../../components/ui';
import { dayjs, dt, num } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { MerchantNav } from './nav';
import { SHOP_TYPE, SKIN_PATTERNS } from './perkLabels';
import { SkinSwatch } from './perkShared';

const TYPES = Object.keys(SHOP_TYPE) as ShopItemType[];
const ENERGY_RULE = '能量只能通过运动获得，不能充值、不能转让；商城只能用能量兑换，没有任何付费入口。';

function Energy({ n }: { n: number }) {
  return (
    <span className="num" style={{ whiteSpace: 'nowrap' }}>
      <ThunderboltFilled style={{ color: '#D99A0B' }} /> {num(n)}
    </span>
  );
}

function Thumb({ item, size = 44 }: { item: Pick<ShopItem, 'type' | 'preview' | 'image_url' | 'name'>; size?: number }) {
  if (item.type === 'territory_skin' && item.preview) return <SkinSwatch preview={item.preview} size={size} label={`${item.name} 预览`} />;
  if (item.image_url) return <Image src={item.image_url} width={size} height={size} className="shop-thumb" alt={item.name} preview={false} />;
  return <span className="shop-thumb" style={{ width: size, height: size }} />;
}

export default function ShopPage() {
  const [params, setParams] = useSearchParams();
  const type = (params.get('type') ?? '') as ShopItemType | '';
  const { can } = useAuth();
  const writable = can('perks.write');
  const qc = useQueryClient();
  const [editing, setEditing] = useState<ShopItem | 'new' | null>(null);

  const items = useQuery({ queryKey: ['shop', 'items', type], queryFn: () => perksApi.shopItems(type), placeholderData: (p) => p });
  const stats = useQuery({ queryKey: ['shop', 'stats'], queryFn: perksApi.shopStats });
  const statOf = (key: string) => stats.data?.items.find((s) => s.key === key);
  const all = stats.data?.items ?? [];
  const totalRedemptions = all.reduce((s, x) => s + (x.redemptions ?? 0), 0);
  const totalEnergy = all.reduce((s, x) => s + (x.energy_spent ?? 0), 0);
  const hottest = [...all].sort((a, b) => b.redemptions - a.redemptions)[0];

  const toggle = useMutation({
    mutationFn: (i: ShopItem) => perksApi.updateShopItem(i.key, { on_sale: !i.on_sale }),
    onSuccess: (i) => {
      qc.invalidateQueries({ queryKey: ['shop'] });
      toastOk(i.on_sale ? `「${i.name}」已上架` : `「${i.name}」已下架，已购买的用户仍可装备`);
    },
  });

  const list = items.data?.items ?? [];
  const now = Date.now();

  return (
    <>
      <PageHeader title="商户与活动" sub="能量商城 · 用运动攒下的能量换领地皮肤、头像框、地图标记" extra={<MerchantNav />} />
      <div className="energy-note" role="note">
        <ThunderboltFilled style={{ color: '#7A8F12', fontSize: 18 }} />
        <span>
          <b>能量不能购买、不能转让。</b>
          {ENERGY_RULE}
        </span>
      </div>
      <Row gutter={[12, 12]} style={{ marginBottom: 16 }}>
        <Col xs={12} md={6}>
          <Tile v={num(list.filter((i) => i.on_sale).length)} l={type ? `${SHOP_TYPE[type]} · 在售` : '在售商品'} />
        </Col>
        <Col xs={12} md={6}>
          <Tile v={num(totalRedemptions)} l="累计兑换次数" />
        </Col>
        <Col xs={12} md={6}>
          <Tile v={<Energy n={totalEnergy} />} l="累计消耗能量" />
        </Col>
        <Col xs={12} md={6}>
          <Tile v={<span style={{ fontSize: 16 }}>{hottest ? list.find((i) => i.key === hottest.key)?.name ?? hottest.key : '—'}</span>} l={hottest ? `最热 · 兑换 ${num(hottest.redemptions)} 次` : '最热商品'} />
        </Col>
      </Row>
      <Panel
        title="商品"
        extra={
          <Button type="primary" icon={<PlusOutlined />} disabled={!writable} onClick={() => setEditing('new')}>
            新建商品
          </Button>
        }
      >
        <Segmented
          style={{ marginBottom: 14 }}
          value={type}
          onChange={(v) => setParams(v ? { type: String(v) } : {}, { replace: true })}
          options={[{ label: '全部', value: '' }, ...TYPES.map((t) => ({ label: SHOP_TYPE[t], value: t }))]}
        />
        <Table<ShopItem>
          rowKey="key"
          loading={items.isFetching}
          dataSource={list}
          pagination={false}
          scroll={{ x: 1000 }}
          columns={[
            {
              title: '商品',
              key: 'name',
              render: (_, i) => (
                <Space>
                  <Thumb item={i} />
                  <div>
                    <b>{i.name}</b>
                    <div className="muted num" style={{ fontSize: 12 }}>
                      {i.key}
                    </div>
                  </div>
                </Space>
              ),
            },
            { title: '类型', dataIndex: 'type', render: (t: ShopItemType) => <Tag bordered={false}>{SHOP_TYPE[t] ?? t}</Tag> },
            { title: '价格', dataIndex: 'price_energy', align: 'right', render: (n: number) => <Energy n={n} /> },
            { title: '兑换', key: 'r', align: 'right', render: (_, i) => <span className="num">{num(statOf(i.key)?.redemptions)}</span> },
            { title: '消耗能量', key: 'e', align: 'right', render: (_, i) => <span className="num">{num(statOf(i.key)?.energy_spent)}</span> },
            {
              title: '限时',
              dataIndex: 'limited_until',
              render: (v: string | null) =>
                v ? (
                  Date.parse(v) > now ? (
                    <Tag bordered={false} color="orange">
                      至 {dt(v, 'MM-DD HH:mm')}
                    </Tag>
                  ) : (
                    <Tag bordered={false}>已过期 {dt(v, 'MM-DD')}</Tag>
                  )
                ) : (
                  <span className="muted">长期</span>
                ),
            },
            { title: '说明', dataIndex: 'description', render: (v: string) => <span className="muted" style={{ fontSize: 12 }}>{v || '—'}</span> },
            {
              title: '上架',
              key: 'sale',
              render: (_, i) => (
                <Tooltip title={i.on_sale ? '下架后 App 不再展示，已购买的用户仍可装备' : '上架到 App 商城'}>
                  <Switch size="small" checked={i.on_sale} disabled={!writable} loading={toggle.isPending && toggle.variables?.key === i.key} onChange={() => toggle.mutate(i)} aria-label={`${i.name} 上架`} />
                </Tooltip>
              ),
            },
            {
              title: '操作',
              key: 'op',
              align: 'right',
              render: (_, i) => (
                <Button size="small" disabled={!writable} onClick={() => setEditing(i)}>
                  编辑
                </Button>
              ),
            },
          ]}
        />
      </Panel>
      <ShopItemModal value={editing} onClose={() => setEditing(null)} />
    </>
  );
}

// ------------------------------------------------------------ create / edit

interface FormValues {
  key: string;
  name: string;
  type: ShopItemType;
  price_energy: number;
  image_url: string;
  fill: string;
  stroke: string;
  pattern: string;
  description: string;
  limited_until: Dayjs | null;
  on_sale: boolean;
}

const hex = (c: Color | string) => (typeof c === 'string' ? c : c.toHexString()).toUpperCase().slice(0, 7);

function ShopItemModal({ value, onClose }: { value: ShopItem | 'new' | null; onClose: () => void }) {
  const [form] = Form.useForm<FormValues>();
  const qc = useQueryClient();
  const editing = value && value !== 'new' ? value : null;
  const type = (Form.useWatch('type', form) ?? 'territory_skin') as ShopItemType;
  const fill = Form.useWatch('fill', form) as string | undefined;
  const stroke = Form.useWatch('stroke', form) as string | undefined;
  const pattern = Form.useWatch('pattern', form) as string | undefined;
  const image = Form.useWatch('image_url', form) as string | undefined;
  const name = Form.useWatch('name', form) as string | undefined;
  const price = Form.useWatch('price_energy', form) as number | undefined;
  const skin = type === 'territory_skin';

  const save = useMutation({
    mutationFn: (body: ShopItemInput) => {
      if (!editing) return perksApi.createShopItem(body);
      const { key: _k, type: _t, ...patch } = body;
      return perksApi.updateShopItem(editing.key, patch);
    },
    onSuccess: (i) => {
      qc.invalidateQueries({ queryKey: ['shop'] });
      toastOk(editing ? `已保存「${i.name}」` : `已新建「${i.name}」${i.on_sale ? '并上架' : '（未上架）'}`);
      onClose();
    },
  });

  const submit = (v: FormValues) =>
    save.mutate({
      key: v.key?.trim(),
      name: v.name.trim(),
      type: v.type,
      price_energy: v.price_energy,
      image_url: v.image_url?.trim() || null,
      preview: v.type === 'territory_skin' ? { fill: hex(v.fill), stroke: hex(v.stroke), pattern: v.pattern } : null,
      description: (v.description ?? '').trim(),
      limited_until: v.limited_until ? v.limited_until.second(0).millisecond(0).format() : null,
      on_sale: v.on_sale,
    });

  // Fill the form as soon as it opens (not after the animation, so early clicks are kept).
  useEffect(() => {
    if (value === null) return;
    form.resetFields();
    if (editing) {
      form.setFieldsValue({
        key: editing.key,
        name: editing.name,
        type: editing.type,
        price_energy: editing.price_energy,
        image_url: editing.image_url ?? '',
        fill: editing.preview?.fill ?? '#DCF26A',
        stroke: editing.preview?.stroke ?? '#141414',
        pattern: editing.preview?.pattern ?? 'solid',
        description: editing.description,
        limited_until: editing.limited_until ? dayjs(editing.limited_until) : null,
        on_sale: editing.on_sale,
      });
    } else {
      form.setFieldsValue({ type: 'territory_skin', price_energy: 800, fill: '#DCF26A', stroke: '#141414', pattern: 'grid', limited_until: null, on_sale: true });
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps -- once per open
  }, [value]);

  return (
    <Modal
      open={value !== null}
      title={editing ? `编辑「${editing.name}」` : '新建商品'}
      width={760}
      forceRender
      okText="保存"
      cancelText="取消"
      confirmLoading={save.isPending}
      onCancel={onClose}
      onOk={() => form.submit()}
    >
      <Alert type="info" showIcon style={{ marginBottom: 14 }} message={ENERGY_RULE} />
      <Row gutter={20}>
        <Col xs={24} md={15}>
          <Form<FormValues> form={form} layout="vertical" requiredMark={false} onFinish={submit}>
            <Row gutter={12}>
              <Col span={12}>
                <Form.Item name="type" label="类型" rules={[{ required: true }]} extra={editing ? '创建后不能修改' : undefined}>
                  <Select disabled={!!editing} options={TYPES.map((t) => ({ value: t, label: SHOP_TYPE[t] }))} />
                </Form.Item>
              </Col>
              <Col span={12}>
                <Form.Item
                  name="key"
                  label="key"
                  rules={editing ? [] : [{ required: true, message: '请填写 key' }, { pattern: /^[a-z][a-z0-9_]{2,39}$/, message: '小写字母开头，小写字母、数字、下划线，3–40 位' }]}
                  extra={editing ? 'App 按 key 识别，创建后不能修改' : 'App 按 key 识别装扮，如 skin_neon、frame_gold'}
                >
                  <Input className="num" disabled={!!editing} placeholder={type === 'territory_skin' ? 'skin_neon' : type === 'avatar_frame' ? 'frame_gold' : 'marker_flag'} />
                </Form.Item>
              </Col>
            </Row>
            <Row gutter={12}>
              <Col span={14}>
                <Form.Item name="name" label="名称" rules={[{ required: true, whitespace: true, message: '请填写名称' }, { max: 20, message: '最多 20 字' }]}>
                  <Input maxLength={20} placeholder="霓虹领地皮肤" />
                </Form.Item>
              </Col>
              <Col span={10}>
                <Form.Item name="price_energy" label="价格（能量）" rules={[{ required: true, message: '请填写价格' }]}>
                  <InputNumber className="num" min={1} max={100000} step={50} prefix={<ThunderboltFilled style={{ color: '#D99A0B' }} />} style={{ width: '100%' }} />
                </Form.Item>
              </Col>
            </Row>
            <Form.Item
              name="image_url"
              label={skin ? '图片地址（可选）' : '图片地址'}
              rules={[{ required: !skin, message: '头像框和地图标记需要图片' }, { pattern: /^(https?:\/\/|data:image\/)/, message: '需要是 http(s) 地址' }]}
            >
              <Input placeholder="https://cdn.../item.png" allowClear />
            </Form.Item>
            {skin && (
              <Row gutter={12}>
                <Col span={8}>
                  <Form.Item name="fill" label="填充色" rules={[{ required: true }]} getValueFromEvent={(c: Color) => hex(c)}>
                    <ColorPicker showText disabledAlpha format="hex" />
                  </Form.Item>
                </Col>
                <Col span={8}>
                  <Form.Item name="stroke" label="描边色" rules={[{ required: true }]} getValueFromEvent={(c: Color) => hex(c)}>
                    <ColorPicker showText disabledAlpha format="hex" />
                  </Form.Item>
                </Col>
                <Col span={8}>
                  <Form.Item name="pattern" label="花纹" rules={[{ required: true }]}>
                    <Select options={SKIN_PATTERNS} />
                  </Form.Item>
                </Col>
              </Row>
            )}
            <Form.Item name="description" label="说明" rules={[{ max: 60, message: '最多 60 字' }]}>
              <Input maxLength={60} showCount placeholder="荧光绿网格，夜跑党最爱" />
            </Form.Item>
            <Row gutter={12}>
              <Col span={14}>
                <Form.Item name="limited_until" label="限时截止（可选）" extra="到点后 App 不再展示；留空为长期">
                  <DatePicker showTime={{ format: 'HH:mm' }} format="YYYY-MM-DD HH:mm" style={{ width: '100%' }} />
                </Form.Item>
              </Col>
              <Col span={10}>
                <Form.Item name="on_sale" label="上架" valuePropName="checked">
                  <Switch checkedChildren="在售" unCheckedChildren="下架" />
                </Form.Item>
              </Col>
            </Row>
          </Form>
        </Col>
        <Col xs={24} md={9}>
          <div className="field-cell" style={{ textAlign: 'center' }}>
            <div className="muted" style={{ fontSize: 12, marginBottom: 10 }}>
              App 预览
            </div>
            <div style={{ display: 'flex', justifyContent: 'center' }}>
              {skin ? (
                <SkinSwatch preview={{ fill, stroke, pattern }} size={160} label="领地皮肤实时预览" />
              ) : image && /^(https?:\/\/|data:image\/)/.test(image) ? (
                <Image src={image} width={120} height={120} className="shop-thumb" alt="图片预览" />
              ) : (
                <span className="shop-thumb" style={{ width: 120, height: 120 }} />
              )}
            </div>
            <div style={{ marginTop: 10, fontWeight: 800 }}>{name?.trim() || '商品名称'}</div>
            <div style={{ marginTop: 4 }}>{price ? <Energy n={price} /> : '—'}</div>
            {skin && (
              <div className="muted num" style={{ fontSize: 12, marginTop: 6 }}>
                {fill ?? '—'} · {stroke ?? '—'} · {SKIN_PATTERNS.find((p) => p.value === pattern)?.label ?? pattern}
              </div>
            )}
          </div>
        </Col>
      </Row>
    </Modal>
  );
}
