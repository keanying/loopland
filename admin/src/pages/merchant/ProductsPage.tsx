// V2 第五批 · 商品 (docs/api/v2-5-商户商品与开放平台.md「商户商品」). Merchant accounts create / edit / submit /
// put on and off sale / delete their own products; admin / ops see every merchant's products read-only and can
// only force them off sale (强制下架 → banned, with a reason).
import { useEffect, useState, type ReactNode } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import dayjs from 'dayjs';
import type { Dayjs } from 'dayjs';
import { Alert, App, Button, Col, DatePicker, Descriptions, Drawer, Empty, Form, Image, Input, InputNumber, Radio, Row, Segmented, Select, Space, Switch, Table, Tag, Tooltip } from 'antd';
import { DeleteOutlined, EditOutlined, PlusOutlined, SearchOutlined, SendOutlined, StopOutlined } from '@ant-design/icons';
import { commerceApi, type Product, type ProductDetail, type ProductInput, type ProductStatus, type ProductType } from '../../api/commerce';
import { useAuth } from '../../auth/AuthContext';
import { PageHeader, Panel } from '../../components/ui';
import { dt, num, yuan } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { ReasonModal } from '../review/shared';
import { PRODUCT_STATUS, PRODUCT_STATUS_ORDER, PRODUCT_TYPE, PRODUCT_TYPES, stockText, validityText } from './commerceLabels';
import { PriceText, ProductStatusTag } from './commerceShared';
import { VENUE_SPORT, VENUE_SPORTS } from './labels';
import { MerchantNav } from './nav';
import { IMAGE_URL, toFen, toYuan, urlParams, useMerchantOptions, useOwnVenues } from './util';

const PAGE = 20;
const SUBMITTABLE: ProductStatus[] = ['draft', 'rejected', 'banned'];
const BAN_REASONS = ['门市价虚标', '描述与实际不符', '用户投诉较多', '含站外引流', '超出经营范围', '涉嫌违规经营'];

export function ProductThumb({ p }: { p: Pick<Product, 'images' | 'title'> }) {
  return p.images[0] ? <img className="prod-thumb" src={p.images[0]} alt={p.title} /> : <span className="prod-thumb" />;
}

export default function ProductsPage() {
  const { can, admin } = useAuth();
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const staff = admin?.role === 'merchant';
  const writable = can('product.write');
  const [params, setParams] = useSearchParams();
  const update = urlParams(params, setParams);
  const status = (params.get('status') ?? '') as ProductStatus | '';
  const q = params.get('q') ?? '';
  const merchantId = Number(params.get('merchant_id') ?? 0) || null;
  const allowPromotion = params.get('allow_promotion');
  const page = Number(params.get('page') ?? 1);
  const openId = Number(params.get('id') ?? 0) || null;
  const [kw, setKw] = useState(q);
  const [editing, setEditing] = useState<Product | 'new' | null>(null);
  const [banning, setBanning] = useState<Product | null>(null);
  const merchants = useMerchantOptions(!staff && can('merchant.read'));

  const list = useQuery({
    queryKey: ['products', 'list', status, q, merchantId, allowPromotion, page],
    queryFn: () => commerceApi.products({ status, q, merchant_id: merchantId, allow_promotion: allowPromotion === null ? null : allowPromotion === 'true', page }),
    placeholderData: (p) => p,
  });
  const items = list.data?.items ?? [];

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['products'] });
    qc.invalidateQueries({ queryKey: ['reviews'] });
    qc.invalidateQueries({ queryKey: ['dashboard'] });
  };
  const act = useMutation({
    mutationFn: ({ p, op }: { p: Product; op: 'submit' | 'on' | 'off' | 'delete' }) =>
      op === 'submit' ? commerceApi.submitProduct(p.id) : op === 'on' ? commerceApi.onSale(p.id) : op === 'off' ? commerceApi.offSale(p.id) : commerceApi.deleteProduct(p.id).then(() => p),
    onSuccess: (r, v) => {
      refresh();
      if (v.op === 'delete') {
        toastOk(v.p.sold_qty > 0 ? `「${v.p.title}」已归档` : `「${v.p.title}」已删除`);
        if (openId === v.p.id) update({ id: null });
        return;
      }
      const s = (r as Product).status;
      if (v.op === 'submit') toastOk(s === 'on_sale' ? '审核已自动通过，商品已上架' : s === 'rejected' ? '审核未通过，查看原因后修改' : '已提交，等待平台人工审核');
      else toastOk(v.op === 'on' ? '已上架' : '已下架，App 不再展示');
    },
  });
  const ban = useMutation({
    mutationFn: ({ p, reason }: { p: Product; reason: string }) => commerceApi.banProduct(p.id, reason),
    onSuccess: (p) => {
      setBanning(null);
      refresh();
      toastOk(`已强制下架「${p.title}」，商户会收到原因`);
    },
  });

  const confirmDelete = (p: Product) =>
    modal.confirm({
      title: `删除「${p.title}」？`,
      content:
        p.sold_qty > 0 ? (
          <>
            已售出 <b>{num(p.sold_qty)}</b> 件，删除后<b>归档</b>：列表不再显示、App 不再售卖，已售出的券照常可用、可退款。
          </>
        ) : (
          '还没有卖出过，删除后不可恢复。'
        ),
      okText: p.sold_qty > 0 ? '归档' : '删除',
      okButtonProps: { danger: true },
      cancelText: '取消',
      onOk: () => act.mutateAsync({ p, op: 'delete' }),
    });
  const confirmOff = (p: Product) =>
    modal.confirm({
      title: `下架「${p.title}」？`,
      content: '下架后 App 不再展示和售卖，已售出的券照常可用；内容没改过可以随时重新上架。',
      okText: '下架',
      cancelText: '取消',
      onOk: () => act.mutateAsync({ p, op: 'off' }),
    });

  /** The status-dependent actions of one product (merchant side). */
  const actions = (p: Product, size: 'small' | 'middle' = 'small') => {
    if (!writable) return null;
    const busy = act.isPending && act.variables?.p.id === p.id;
    return (
      <Space size={6} onClick={(e) => e.stopPropagation()}>
        <Button size={size} icon={<EditOutlined />} onClick={() => setEditing(p)}>
          编辑
        </Button>
        {SUBMITTABLE.includes(p.status) && (
          <Button size={size} type="primary" icon={<SendOutlined />} loading={busy && act.variables?.op === 'submit'} onClick={() => act.mutate({ p, op: 'submit' })}>
            提交审核
          </Button>
        )}
        {p.status === 'on_sale' && (
          <Button size={size} onClick={() => confirmOff(p)}>
            下架
          </Button>
        )}
        {p.status === 'off_sale' && (
          <Button size={size} type="primary" loading={busy && act.variables?.op === 'on'} onClick={() => act.mutate({ p, op: 'on' })}>
            上架
          </Button>
        )}
        <Tooltip title={p.sold_qty > 0 ? '卖出过的商品删除后归档' : '删除'}>
          <Button size={size} danger icon={<DeleteOutlined />} aria-label="删除" onClick={() => confirmDelete(p)} />
        </Tooltip>
      </Space>
    );
  };
  const banButton = (p: Product, size: 'small' | 'middle' = 'small') =>
    can('product.ban') && p.status !== 'banned' && !staff ? (
      <Button
        size={size}
        danger
        icon={<StopOutlined />}
        onClick={(e) => {
          e.stopPropagation();
          setBanning(p);
        }}
      >
        强制下架
      </Button>
    ) : null;

  return (
    <>
      <PageHeader
        title={staff ? '商品' : '商户与活动'}
        sub={
          staff
            ? '在 App 场馆页、商户页售卖的套餐券、代金券和次卡：新建后提交审核，通过即上架；用户买到的券在核销台核销，按核销结算（扣商品佣金）'
            : '全部商户的商品，只读；平台不新建、不修改商户商品，违规的可强制下架（必须写原因，商户修改后重新提交审核）'
        }
        extra={<MerchantNav />}
      />
      <Panel
        title="商品"
        extra={
          <Space wrap>
            <Input
              allowClear
              prefix={<SearchOutlined />}
              placeholder="商品名称或 ID"
              style={{ width: 180 }}
              value={kw}
              onChange={(e) => {
                setKw(e.target.value);
                if (!e.target.value) update({ q: null, page: null });
              }}
              onPressEnter={() => update({ q: kw.trim(), page: null })}
            />
            {!staff && (
              <Select
                allowClear
                showSearch
                optionFilterProp="label"
                placeholder="全部商户"
                style={{ width: 160 }}
                value={merchantId ?? undefined}
                onChange={(v) => update({ merchant_id: v ?? null, page: null })}
                options={merchants.options}
                loading={merchants.isLoading}
              />
            )}
            {!staff && (
              <Select
                allowClear
                placeholder="官方活动授权"
                style={{ width: 150 }}
                value={allowPromotion ?? undefined}
                onChange={(v) => update({ allow_promotion: v ?? null, page: null })}
                options={[
                  { value: 'true', label: '已授权进活动' },
                  { value: 'false', label: '未授权' },
                ]}
              />
            )}
            <Segmented
              value={status}
              onChange={(v) => update({ status: String(v) || null, page: null })}
              options={[{ label: '全部', value: '' }, ...PRODUCT_STATUS_ORDER.map((s) => ({ label: PRODUCT_STATUS[s].text, value: s }))]}
            />
            {writable && (
              <Button type="primary" icon={<PlusOutlined />} onClick={() => setEditing('new')}>
                新建商品
              </Button>
            )}
          </Space>
        }
      >
        <Table<Product>
          rowKey="id"
          loading={list.isFetching}
          dataSource={items}
          scroll={{ x: 1200 }}
          onRow={(p) => ({ onClick: () => update({ id: p.id }), style: { cursor: 'pointer' } })}
          locale={{ emptyText: <Empty description={q || status || merchantId ? '没有符合条件的商品' : writable ? '还没有商品，点「新建商品」开始' : '还没有商品'} /> }}
          pagination={{ current: page, pageSize: PAGE, total: list.data?.total ?? 0, showSizeChanger: false, showTotal: (t) => `共 ${t} 个`, onChange: (p) => update({ page: p === 1 ? null : p }) }}
          columns={[
            {
              title: '商品',
              key: 'title',
              width: 280,
              render: (_, p) => (
                <div className="prod-cell">
                  <ProductThumb p={p} />
                  <div style={{ minWidth: 0 }}>
                    <div className="prod-title">{p.title}</div>
                    <div className="prod-sub">
                      {PRODUCT_TYPE[p.type]?.text ?? p.type}
                      {p.type === 'pass' && ` · ${p.use_qty} 次`} · #{p.id}
                      {p.subtitle && ` · ${p.subtitle}`}
                    </div>
                  </div>
                </div>
              ),
            },
            ...(!staff
              ? [{ title: '商户', key: 'merchant', width: 130, render: (_: unknown, p: Product) => (can('merchant.read') ? <Link to={`/merchant/merchants?id=${p.merchant.id}`} onClick={(e) => e.stopPropagation()}>{p.merchant.name}</Link> : p.merchant.name) }]
              : []),
            {
              title: '售价',
              key: 'price',
              width: 140,
              render: (_, p) => (
                <div>
                  <PriceText price={p.price_amt} original={p.original_amt} />
                  {p.promotion && (
                    <Tooltip title={`官方活动「${p.promotion.title}」进行中，App 按活动价售卖，至 ${dt(p.promotion.ends_at, 'MM-DD HH:mm')}`}>
                      <div>
                        <Tag bordered={false} color="volcano" style={{ marginTop: 2 }}>
                          活动价 {yuan(p.promotion.promo_price_amt)}
                        </Tag>
                      </div>
                    </Tooltip>
                  )}
                </div>
              ),
            },
            {
              title: '库存 / 已售',
              key: 'stock',
              width: 110,
              align: 'right',
              render: (_, p) => (
                <span className="num">
                  {stockText(p)}
                  <div className="muted" style={{ fontSize: 12 }}>
                    已售 {num(p.sold_qty)}
                  </div>
                </span>
              ),
            },
            { title: '有效期', key: 'valid', width: 130, render: (_, p) => <span className="num">{validityText(p)}</span> },
            {
              title: '状态',
              key: 'status',
              width: 150,
              render: (_, p) => (
                <Space size={4} wrap>
                  <ProductStatusTag status={p.status} />
                  {p.has_pending_changes && (
                    <Tooltip title="改过的标题、图片等正在审核，审核期间旧内容继续在售">
                      <Tag bordered={false} color="processing" style={{ marginInlineEnd: 0 }}>
                        修改待审
                      </Tag>
                    </Tooltip>
                  )}
                  {p.review_note && (
                    <Tooltip title={p.review_note}>
                      <span className="danger-text" style={{ fontSize: 12, cursor: 'help' }}>
                        {p.status === 'banned' ? '下架原因' : '审核意见'}
                      </span>
                    </Tooltip>
                  )}
                </Space>
              ),
            },
            {
              title: <Tooltip title="商户是否授权平台把商品选入官方活动">进活动</Tooltip>,
              key: 'allow',
              width: 80,
              render: (_, p) => (p.allow_promotion ? <Tag bordered={false} color="green">已授权</Tag> : <span className="muted">—</span>),
            },
            { title: '更新时间', dataIndex: 'updated_at', width: 120, render: (v: string) => <span className="num">{dt(v, 'MM-DD HH:mm')}</span> },
            {
              title: '操作',
              key: 'op',
              width: writable ? 300 : 120,
              align: 'right',
              fixed: 'right',
              render: (_, p) => (writable ? actions(p) : banButton(p) ?? <span className="muted">—</span>),
            },
          ]}
        />
      </Panel>

      <ProductDrawer
        id={openId}
        onClose={() => update({ id: null })}
        extra={(p) => (
          <Space>
            {writable && actions(p, 'middle')}
            {banButton(p, 'middle')}
          </Space>
        )}
      />
      {writable && <ProductForm value={editing} onClose={() => setEditing(null)} onSaved={(p) => update({ id: p.id })} />}
      <ReasonModal
        open={banning !== null}
        title={`强制下架「${banning?.title ?? ''}」`}
        presets={BAN_REASONS}
        okText="强制下架"
        loading={ban.isPending}
        effect="商品立即从 App 下架，商户不能自行上架，只能修改后重新提交审核；已售出的券照常可用。原因会发给商户，并写入审计日志。"
        onCancel={() => setBanning(null)}
        onOk={(reason) => banning && ban.mutate({ p: banning, reason })}
      />
    </>
  );
}

// ------------------------------------------------------------ detail

function ProductDrawer({ id, onClose, extra }: { id: number | null; onClose: () => void; extra: (p: Product) => ReactNode }) {
  const detail = useQuery({ queryKey: ['products', 'detail', id], queryFn: () => commerceApi.product(id!), enabled: id !== null });
  const p = detail.data;
  return (
    <Drawer open={id !== null} onClose={onClose} width={760} title={p ? p.title : '商品详情'} extra={p && extra(p)} loading={detail.isLoading}>
      {p && <ProductDetailBody p={p} />}
    </Drawer>
  );
}

function ProductDetailBody({ p }: { p: ProductDetail }) {
  const { admin } = useAuth();
  const staff = admin?.role === 'merchant';
  const pending = p.pending;
  return (
    <Space direction="vertical" size={16} style={{ width: '100%' }}>
      {p.status === 'banned' && <Alert type="error" showIcon message="平台已强制下架" description={<>原因：{p.review_note ?? '—'}{staff && '。修改后可重新提交审核，审核通过后上架。'}</>} />}
      {p.status === 'rejected' && <Alert type="error" showIcon message="审核未通过" description={<>原因：{p.review_note ?? '—'}{staff && '。按原因修改后重新提交。'}</>} />}
      {p.status === 'reviewing' && <Alert type="info" showIcon message="审核中" description="平台人工审核，一般 1 个工作日内处理；结果会发站内信。" />}
      {p.status !== 'banned' && p.status !== 'rejected' && p.review_note && <Alert type="warning" showIcon message="最近一次修改没有通过" description={p.review_note} />}
      {p.has_pending_changes && pending && (
        <div className="prod-box" style={{ paddingBottom: 14 }}>
          <div className="prod-box-title">
            修改待审 <span className="muted" style={{ fontWeight: 400, fontSize: 12 }}>审核通过后替换；期间 App 仍显示左侧的在售内容</span>
          </div>
          <div className="prod-diff">
            <span className="hd" />
            <span className="hd">在售</span>
            <span className="hd">待审</span>
            {(['title', 'subtitle', 'description', 'rules'] as const)
              .filter((k) => k in pending && pending[k] !== p[k])
              .map((k) => (
                <FragmentRow key={k} label={{ title: '标题', subtitle: '副标题', description: '描述', rules: '使用规则' }[k]} before={p[k] ?? '—'} after={pending[k] ?? '—'} />
              ))}
            {pending.images && JSON.stringify(pending.images) !== JSON.stringify(p.images) && (
              <>
                <span className="muted">图片</span>
                <span>{p.images.length} 张</span>
                <Image.PreviewGroup>
                  <Space size={4} wrap>
                    {pending.images.map((u, i) => (
                      <Image key={i} src={u} width={54} height={40} style={{ objectFit: 'cover', borderRadius: 6 }} alt="" />
                    ))}
                  </Space>
                </Image.PreviewGroup>
              </>
            )}
          </div>
        </div>
      )}
      {p.images.length > 0 && (
        <Image.PreviewGroup>
          <Space wrap className="thumbs">
            {p.images.map((u, i) => (
              <Image key={i} src={u} width={150} height={104} style={{ objectFit: 'cover' }} alt={`${p.title} ${i + 1}`} />
            ))}
          </Space>
        </Image.PreviewGroup>
      )}
      <Descriptions size="small" column={2} bordered>
        <Descriptions.Item label="状态">
          <ProductStatusTag status={p.status} />
        </Descriptions.Item>
        <Descriptions.Item label="类型">
          {PRODUCT_TYPE[p.type]?.text ?? p.type}
          {p.type === 'pass' && ` · ${p.use_qty} 次`}
        </Descriptions.Item>
        {!staff && <Descriptions.Item label="商户" span={2}>{p.merchant.name}</Descriptions.Item>}
        <Descriptions.Item label="售价">
          <PriceText price={p.price_amt} original={p.original_amt} />
          {p.type === 'voucher' && p.original_amt && <span className="muted">（面值 {yuan(p.original_amt)}）</span>}
        </Descriptions.Item>
        <Descriptions.Item label="有效期">{validityText(p)}</Descriptions.Item>
        <Descriptions.Item label="库存">{stockText(p)}</Descriptions.Item>
        <Descriptions.Item label="已售">
          <span className="num">{num(p.sold_qty)}</span>
        </Descriptions.Item>
        <Descriptions.Item label="每人限购">{p.per_user_limit_qty ? `${p.per_user_limit_qty} 件` : '不限'}</Descriptions.Item>
        <Descriptions.Item label="退款">{p.refundable ? '未使用可退，过期自动退' : '不可退款'}</Descriptions.Item>
        <Descriptions.Item label="适用门店" span={2}>
          {p.venues.length ? p.venues.map((v) => v.name).join('、') : '本商户所有场馆'}
        </Descriptions.Item>
        <Descriptions.Item label="运动" span={2}>
          {p.sports.length ? p.sports.map((s) => VENUE_SPORT[s as keyof typeof VENUE_SPORT] ?? s).join('、') : '—'}
        </Descriptions.Item>
        <Descriptions.Item label="官方活动" span={2}>
          {p.allow_promotion ? <Tag bordered={false} color="green">已授权平台选入官方活动</Tag> : <span className="muted">未授权（仍可自己报名开放报名的活动）</span>}
          {p.promotion && (
            <div style={{ marginTop: 4 }}>
              正在「<b>{p.promotion.title}</b>」：活动价 <b className="num">{yuan(p.promotion.promo_price_amt)}</b>
              {p.promotion.promo_left_qty !== null && <span className="muted num">，活动库存剩 {p.promotion.promo_left_qty}</span>}
              <span className="muted num">，至 {dt(p.promotion.ends_at)}</span>
            </div>
          )}
        </Descriptions.Item>
        <Descriptions.Item label="副标题" span={2}>{p.subtitle || '—'}</Descriptions.Item>
        <Descriptions.Item label="描述" span={2}>
          <div style={{ whiteSpace: 'pre-wrap' }}>{p.description || '—'}</div>
        </Descriptions.Item>
        <Descriptions.Item label="使用规则" span={2}>
          <div style={{ whiteSpace: 'pre-wrap' }}>{p.rules || '—'}</div>
        </Descriptions.Item>
        <Descriptions.Item label="创建">{dt(p.created_at)}</Descriptions.Item>
        <Descriptions.Item label="更新">{dt(p.updated_at)}</Descriptions.Item>
      </Descriptions>
    </Space>
  );
}

function FragmentRow({ label, before, after }: { label: string; before: string; after: string }) {
  return (
    <>
      <span className="muted">{label}</span>
      <span style={{ whiteSpace: 'pre-wrap' }}>{before}</span>
      <b style={{ whiteSpace: 'pre-wrap' }}>{after}</b>
    </>
  );
}

// ------------------------------------------------------------ create / edit (merchant accounts)

interface FormValues {
  type: ProductType;
  title: string;
  subtitle?: string;
  description?: string;
  images: { url: string }[];
  sports: string[];
  price_yuan: number;
  original_yuan?: number | null;
  use_qty?: number;
  validity: 'days' | 'until';
  valid_days?: number;
  valid_until?: Dayjs | null;
  stock_unlimited: boolean;
  stock_qty?: number | null;
  per_user_limit_qty: number;
  refundable: boolean;
  allow_promotion: boolean;
  venue_ids: number[];
  rules?: string;
}

function ProductForm({ value, onClose, onSaved }: { value: Product | 'new' | null; onClose: () => void; onSaved: (p: Product) => void }) {
  const qc = useQueryClient();
  const [form] = Form.useForm<FormValues>();
  const editing = value && value !== 'new' ? value : null;
  const own = useOwnVenues(value !== null);
  // The detail carries the pending content of a live product: the form edits that version.
  const detail = useQuery({ queryKey: ['products', 'detail', editing?.id], queryFn: () => commerceApi.product(editing!.id), enabled: !!editing });
  const d = editing ? detail.data : undefined;
  const type = Form.useWatch('type', form);
  const validity = Form.useWatch('validity', form);
  const unlimited = Form.useWatch('stock_unlimited', form);
  const images = Form.useWatch('images', form) ?? [];
  const price = Form.useWatch('price_yuan', form);
  const original = Form.useWatch('original_yuan', form);
  const allow = Form.useWatch('allow_promotion', form);
  const [submitAfter, setSubmitAfter] = useState(false);
  const live = !!editing && (editing.status === 'on_sale' || editing.status === 'off_sale');

  useEffect(() => {
    if (!value) return;
    form.resetFields();
    if (value === 'new') {
      form.setFieldsValue({ type: 'package', images: [{ url: '' }], sports: [], validity: 'days', valid_days: 30, stock_unlimited: false, stock_qty: 100, per_user_limit_qty: 0, refundable: true, allow_promotion: false, venue_ids: [], use_qty: 10 });
      return;
    }
    if (!d) return;
    const c = { ...d, ...(d.pending ?? {}) };
    form.setFieldsValue({
      type: d.type,
      title: c.title,
      subtitle: c.subtitle ?? '',
      description: c.description ?? '',
      images: (c.images ?? []).map((url) => ({ url })),
      sports: d.sports,
      price_yuan: toYuan(d.price_amt) ?? 0,
      original_yuan: toYuan(d.original_amt),
      use_qty: d.type === 'pass' ? d.use_qty : 10,
      validity: d.valid_until ? 'until' : 'days',
      valid_days: d.valid_days ?? 30,
      valid_until: d.valid_until ? dayjs(d.valid_until) : null,
      stock_unlimited: d.stock_qty === null,
      stock_qty: d.stock_qty ?? 100,
      per_user_limit_qty: d.per_user_limit_qty,
      refundable: d.refundable,
      allow_promotion: d.allow_promotion,
      venue_ids: d.venue_ids,
      rules: c.rules ?? '',
    });
  }, [value, d, form]);

  const save = useMutation({
    mutationFn: async ({ body, submit }: { body: ProductInput; submit: boolean }) => {
      const p = editing ? await commerceApi.updateProduct(editing.id, body) : await commerceApi.createProduct(body);
      return submit && SUBMITTABLE.includes(p.status) ? commerceApi.submitProduct(p.id) : p;
    },
    onSuccess: (p, v) => {
      qc.invalidateQueries({ queryKey: ['products'] });
      qc.invalidateQueries({ queryKey: ['reviews'] });
      qc.invalidateQueries({ queryKey: ['dashboard'] });
      if (v.submit) toastOk(p.status === 'on_sale' ? '已保存，审核自动通过并上架' : p.status === 'rejected' ? '已保存，审核未通过，查看原因后修改' : '已保存并提交审核');
      else if (p.has_pending_changes) toastOk('已保存；改动的内容正在审核，旧内容继续在售');
      else toastOk(editing ? '已保存' : '已保存为草稿，提交审核后才会上架');
      onClose();
      onSaved(p);
    },
  });

  const submit = (v: FormValues) => {
    const body: ProductInput = {
      type: v.type,
      title: v.title.trim(),
      subtitle: v.subtitle?.trim() || null,
      description: v.description?.trim() || null,
      images: (v.images ?? []).map((x) => x.url?.trim()).filter(Boolean),
      sports: v.sports ?? [],
      price_amt: toFen(v.price_yuan) ?? 0,
      original_amt: toFen(v.original_yuan ?? null),
      use_qty: v.type === 'pass' ? v.use_qty ?? 2 : 1,
      valid_days: v.validity === 'days' ? v.valid_days ?? 30 : null,
      valid_until: v.validity === 'until' && v.valid_until ? v.valid_until.format('YYYY-MM-DD') : null,
      stock_qty: v.stock_unlimited ? null : v.stock_qty ?? 0,
      per_user_limit_qty: v.per_user_limit_qty ?? 0,
      refundable: !!v.refundable,
      allow_promotion: !!v.allow_promotion,
      venue_ids: v.venue_ids ?? [],
      rules: v.rules?.trim() || null,
    };
    save.mutate({ body, submit: submitAfter });
  };
  const canSubmit = !editing || SUBMITTABLE.includes(editing.status);
  const discount = price && original && original > price ? +((price / original) * 10).toFixed(1) : null;

  return (
    <Drawer
      open={value !== null}
      onClose={onClose}
      width={860}
      title={editing ? `编辑商品 · ${editing.title}` : '新建商品'}
      loading={!!editing && detail.isLoading}
      extra={
        <Space>
          <Button onClick={onClose}>取消</Button>
          <Button
            loading={save.isPending && !submitAfter}
            onClick={() => {
              setSubmitAfter(false);
              form.submit();
            }}
          >
            {editing ? '保存' : '保存草稿'}
          </Button>
          {canSubmit && (
            <Button
              type="primary"
              icon={<SendOutlined />}
              loading={save.isPending && submitAfter}
              onClick={() => {
                setSubmitAfter(true);
                form.submit();
              }}
            >
              保存并提交审核
            </Button>
          )}
        </Space>
      }
    >
      {live && (
        <Alert
          type="info"
          showIcon
          style={{ marginBottom: 16 }}
          message="在售商品：改标题、副标题、描述、图片、使用规则需要重新审核"
          description="审核期间旧内容继续在售，通过后替换，驳回则丢弃改动。价格、库存、限购、有效期、门店、退款立即生效（只影响之后的购买）。"
        />
      )}
      {editing?.review_note && editing.status !== 'on_sale' && <Alert type="error" showIcon style={{ marginBottom: 16 }} message={editing.status === 'banned' ? '平台下架原因' : '审核意见'} description={editing.review_note} />}
      <Form form={form} layout="vertical" onFinish={submit} requiredMark="optional" onFinishFailed={({ errorFields }) => errorFields[0] && form.scrollToField(errorFields[0].name)}>
        <Row gutter={24}>
          <Col xs={24} lg={13}>
            <Form.Item name="type" label="类型" rules={[{ required: true }]} extra={type ? PRODUCT_TYPE[type as ProductType]?.hint : undefined}>
              <Radio.Group optionType="button" options={PRODUCT_TYPES.map((t) => ({ value: t, label: PRODUCT_TYPE[t].text, disabled: !!editing && editing.sold_qty > 0 && t !== editing.type }))} />
            </Form.Item>
            <Form.Item name="title" label="标题" rules={[{ required: true, whitespace: true, message: '请填写标题' }, { min: 2, max: 40, message: '2–40 字' }]}>
              <Input placeholder="羽毛球 2 小时畅打套餐" showCount maxLength={40} />
            </Form.Item>
            <Form.Item name="subtitle" label="副标题" rules={[{ max: 40, message: '最多 40 字' }]}>
              <Input placeholder="含球拍租借" showCount maxLength={40} />
            </Form.Item>
            <div className="ant-form-item-label" style={{ paddingBottom: 8 }}>
              <label>图片（1–9 张，第一张为封面）</label>
            </div>
            <Form.List
              name="images"
              rules={[{ validator: async (_, v?: { url: string }[]) => ((v ?? []).some((x) => x?.url?.trim()) ? undefined : Promise.reject(new Error('至少 1 张图片'))) }]}
            >
              {(fields, { add, remove }, { errors }) => (
                <Space direction="vertical" style={{ width: '100%', marginBottom: 18 }}>
                  {fields.map((f, i) => {
                    const url = images[i]?.url?.trim();
                    return (
                      <div key={f.key} className="mer-img-row">
                        <div className="mer-img-thumb">{url && IMAGE_URL.test(url) ? <Image src={url} width={64} height={46} alt="" /> : <span className="muted">预览</span>}</div>
                        <Form.Item name={[f.name, 'url']} style={{ flex: 1, marginBottom: 0 }} rules={[{ pattern: IMAGE_URL, message: '需要是 http(s) 图片地址' }]}>
                          <Input placeholder="https://… 图片地址（媒体上传后得到）" allowClear />
                        </Form.Item>
                        <Button aria-label="删除这张" icon={<DeleteOutlined />} disabled={fields.length <= 1} onClick={() => remove(f.name)} />
                      </div>
                    );
                  })}
                  <Button icon={<PlusOutlined />} disabled={fields.length >= 9} onClick={() => add({ url: '' })}>
                    添加一张
                  </Button>
                  <Form.ErrorList errors={errors} />
                </Space>
              )}
            </Form.List>
            <Form.Item name="description" label="描述" rules={[{ max: 1000, message: '最多 1000 字' }]}>
              <Input.TextArea rows={4} showCount maxLength={1000} placeholder="包含什么、什么时间可用、注意事项" />
            </Form.Item>
            <Form.Item name="rules" label="使用规则" rules={[{ max: 500, message: '最多 500 字' }]}>
              <Input.TextArea rows={3} showCount maxLength={500} placeholder="到店出示券码，店员扫码核销；节假日需提前预约" />
            </Form.Item>
          </Col>
          <Col xs={24} lg={11}>
            <div className="prod-box">
              <div className="prod-box-title">价格与库存</div>
              <Row gutter={12}>
                <Col span={12}>
                  <Form.Item name="price_yuan" label="售价（元）" rules={[{ required: true, message: '请填写售价' }]}>
                    <InputNumber className="num" min={0.01} max={10000} precision={2} prefix="¥" style={{ width: '100%' }} placeholder="69" />
                  </Form.Item>
                </Col>
                <Col span={12}>
                  <Form.Item
                    name="original_yuan"
                    label={type === 'voucher' ? '面值（元）' : '门市价（元）'}
                    dependencies={['price_yuan']}
                    extra={discount ? `${discount} 折` : type === 'voucher' ? '代金券的抵扣金额' : '可不填；填了 App 划线显示'}
                    rules={[
                      { required: type === 'voucher', message: '代金券要填面值' },
                      ({ getFieldValue }) => ({ validator: (_, v?: number | null) => (v === null || v === undefined || v >= (getFieldValue('price_yuan') ?? 0) ? Promise.resolve() : Promise.reject(new Error('不能低于售价'))) }),
                    ]}
                  >
                    <InputNumber className="num" min={0.01} max={10000} precision={2} prefix="¥" style={{ width: '100%' }} placeholder="90" />
                  </Form.Item>
                </Col>
                {type === 'pass' && (
                  <Col span={12}>
                    <Form.Item name="use_qty" label="次数" rules={[{ required: true, message: '请填写次数' }]} extra="每次核销用掉 1 次">
                      <InputNumber className="num" min={2} max={100} precision={0} suffix="次" style={{ width: '100%' }} />
                    </Form.Item>
                  </Col>
                )}
                <Col span={12}>
                  <Form.Item name="per_user_limit_qty" label="每人限购" extra="0 = 不限">
                    <InputNumber className="num" min={0} max={99} precision={0} suffix="件" style={{ width: '100%' }} />
                  </Form.Item>
                </Col>
                <Col span={type === 'pass' ? 24 : 12}>
                  <Form.Item label="库存（剩余可售）" required extra={unlimited ? '不限量售卖' : '下单即占库存，15 分钟未支付释放'}>
                    <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                      <Form.Item name="stock_qty" noStyle rules={[{ required: !unlimited, message: '请填写库存' }]}>
                        <InputNumber className="num" min={0} max={999999} precision={0} disabled={!!unlimited} style={{ flex: 1 }} placeholder={unlimited ? '不限' : '100'} />
                      </Form.Item>
                      <Form.Item name="stock_unlimited" valuePropName="checked" noStyle>
                        <Switch checkedChildren="不限" unCheckedChildren="限量" />
                      </Form.Item>
                    </div>
                  </Form.Item>
                </Col>
              </Row>
            </div>
            <div className="prod-box">
              <div className="prod-box-title">有效期与使用</div>
              <Form.Item name="validity" style={{ marginBottom: 10 }}>
                <Radio.Group
                  options={[
                    { value: 'days', label: '购买后 N 天' },
                    { value: 'until', label: '固定截止日' },
                  ]}
                />
              </Form.Item>
              {validity === 'until' ? (
                <Form.Item name="valid_until" rules={[{ required: true, message: '请选择截止日' }]} extra="当天 23:59:59（北京时间）前可用">
                  <DatePicker style={{ width: '100%' }} disabledDate={(d) => d.isBefore(dayjs().startOf('day'))} />
                </Form.Item>
              ) : (
                <Form.Item name="valid_days" rules={[{ required: true, message: '请填写天数' }]}>
                  <InputNumber className="num" min={1} max={365} precision={0} addonBefore="购买后" addonAfter="天内可用" style={{ width: '100%' }} />
                </Form.Item>
              )}
              <Form.Item name="venue_ids" label="适用门店" extra="不选 = 本商户所有场馆都可用；核销时校验门店">
                <Select mode="multiple" allowClear placeholder="全部门店" options={own.options} loading={own.isLoading} />
              </Form.Item>
              <Form.Item name="sports" label="运动（可选）">
                <Select mode="multiple" allowClear placeholder="用于 App 按运动筛选" options={VENUE_SPORTS.map((s) => ({ value: s, label: VENUE_SPORT[s] }))} />
              </Form.Item>
              <Form.Item name="refundable" label="退款" valuePropName="checked" extra="可退：未使用的券用户随时可退，过期未用自动退款；不可退：过期作废">
                <Switch checkedChildren="未使用可退" unCheckedChildren="不可退" />
              </Form.Item>
            </div>
            <div className="prod-box">
              <Form.Item
                name="allow_promotion"
                label="允许进入官方活动"
                valuePropName="checked"
                extra={
                  allow
                    ? '平台运营可以把这个商品选进官方活动（专题、横幅推荐）。活动价低于售价时需要你同意；平台可加每件补贴。关掉后不能再被选入，进行中的活动不受影响，可单独退出。'
                    : '打开后平台可以把它选进官方活动获得曝光；不打开也可以自己报名开放报名的活动。'
                }
              >
                <Switch checkedChildren="允许" unCheckedChildren="不允许" />
              </Form.Item>
            </div>
            {editing && editing.sold_qty > 0 && (
              <div className="muted" style={{ fontSize: 12 }}>
                已售 {num(editing.sold_qty)} 件：改价格、有效期等只影响之后的购买，已售出的券不变
              </div>
            )}
          </Col>
        </Row>
      </Form>
    </Drawer>
  );
}
