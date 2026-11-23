// V2 第五批 · 官方活动（平台：admin / ops，promotion.manage）(docs/api/v2-5「官方活动」). Create / edit / publish /
// cancel activities; pick products merchants authorised (allow_promotion, on sale); review merchant applications;
// edit per-item platform subsidy and sort order; remove items.
import { useEffect, useState, type ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useMutation, useQueries, useQuery, useQueryClient } from '@tanstack/react-query';
import dayjs from 'dayjs';
import type { Dayjs } from 'dayjs';
import { Alert, App, Badge, Button, Col, DatePicker, Descriptions, Drawer, Empty, Form, Image, Input, InputNumber, Modal, Row, Segmented, Select, Space, Switch, Table, Tag, Tooltip } from 'antd';
import { commerceApi, type EntryStatus, type Promotion, type PromotionEntry, type PromotionInput, type PromotionStatus } from '../../api/commerce';
import { SingleImageUpload } from '../../components/ImageUpload';
import { PageHeader, Panel } from '../../components/ui';
import { dt, num, yuan } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { ReasonModal } from '../review/shared';
import { discountLine, ENTRY_SOURCE, PROMOTION_STATUS, PROMOTION_STATUS_ORDER } from './commerceLabels';
import { EntryStatusTag, PriceText, PromotionStatusTag } from './commerceShared';
import { MerchantNav } from './nav';
import { ProductThumb } from './ProductsPage';
import { toFen, toYuan, urlParams } from './util';
import { Glyph } from '../../components/Glyph';

const PAGE = 20;
const LIVE: EntryStatus[] = ['active', 'pending_merchant', 'pending_platform'];

function periodText(p: Pick<Promotion, 'starts_at' | 'ends_at'>): string {
  const s = dayjs(p.starts_at);
  const e = dayjs(p.ends_at);
  return `${s.format('MM/DD HH:mm')} – ${e.format(s.isSame(e, 'year') ? 'MM/DD HH:mm' : 'YYYY/MM/DD HH:mm')}`;
}

export default function PromotionsPage() {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const [params, setParams] = useSearchParams();
  const update = urlParams(params, setParams);
  const status = (params.get('status') ?? '') as PromotionStatus | '';
  const page = Number(params.get('page') ?? 1);
  const openId = Number(params.get('id') ?? 0) || null;
  const entryStatus = (params.get('entry_status') ?? '') as EntryStatus | '';
  const [editing, setEditing] = useState<Promotion | 'new' | null>(null);

  const list = useQuery({ queryKey: ['promotions', 'list', status, page], queryFn: () => commerceApi.promotions({ status, page }), placeholderData: (p) => p });
  const items = list.data?.items ?? [];
  // Pending applications per activity (there is no cross-activity entries list for the platform).
  const pendingQs = useQueries({
    queries: items.map((p) => ({ queryKey: ['promotions', 'entries', p.id, 'pending_platform'], queryFn: () => commerceApi.promotionEntries(p.id, 'pending_platform'), enabled: ['scheduled', 'active', 'draft'].includes(p.status), staleTime: 15_000 })),
  });
  const pendingOf = (id: number) => pendingQs[items.findIndex((p) => p.id === id)]?.data?.items.length ?? 0;

  // 总览 todo link (?entry_status=pending_platform): open the first activity with applications waiting.
  useEffect(() => {
    if (openId || entryStatus !== 'pending_platform' || !items.length || pendingQs.some((q) => q.isLoading)) return;
    const first = items.find((p) => pendingOf(p.id) > 0);
    if (first) update({ id: first.id });
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only once the counts are in
  }, [openId, entryStatus, items.length, pendingQs.map((q) => q.data?.items.length).join(',')]);

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['promotions'] });
    qc.invalidateQueries({ queryKey: ['products'] });
    qc.invalidateQueries({ queryKey: ['dashboard'] });
  };
  const setState = useMutation({
    mutationFn: ({ p, op }: { p: Promotion; op: 'publish' | 'cancel' }) => (op === 'publish' ? commerceApi.publishPromotion(p.id) : commerceApi.cancelPromotion(p.id)),
    onSuccess: (p, v) => {
      refresh();
      toastOk(v.op === 'publish' ? `已发布，${p.status === 'active' ? '活动进行中' : `${dt(p.starts_at, 'MM-DD HH:mm')} 开始`}` : '活动已取消，活动价立即失效');
    },
  });
  const confirmState = (p: Promotion, op: 'publish' | 'cancel') =>
    modal.confirm({
      title: op === 'publish' ? `发布「${p.title}」？` : `取消「${p.title}」？`,
      content:
        op === 'publish'
          ? `发布后 App 展示活动${p.apply_open ? '，商户可以报名' : ''}；${dayjs(p.starts_at).isAfter(dayjs()) ? `${dt(p.starts_at)} 开始后活动价生效` : '活动价立即生效'}。`
          : '取消后活动价立即失效，App 不再展示；已售出的订单不受影响。参与的商户会收到通知。',
      okText: op === 'publish' ? '发布' : '取消活动',
      okButtonProps: { danger: op === 'cancel' },
      cancelText: '再想想',
      onOk: () => setState.mutateAsync({ p, op }),
    });

  const stateButtons = (p: Promotion, size: 'small' | 'middle' = 'small') => (
    <Space size={6} onClick={(e) => e.stopPropagation()}>
      {!['ended', 'cancelled'].includes(p.status) && (
        <Button size={size} icon={<Glyph name="pencil" size={size === 'small' ? 14 : 16} />} onClick={() => setEditing(p)}>
          编辑
        </Button>
      )}
      {p.status === 'draft' && (
        <Button size={size} type="primary" icon={<Glyph name="megaphone" size={size === 'small' ? 14 : 16} />} onClick={() => confirmState(p, 'publish')}>
          发布
        </Button>
      )}
      {['draft', 'scheduled', 'active'].includes(p.status) && (
        <Button size={size} danger icon={<Glyph name="block" size={size === 'small' ? 14 : 16} />} onClick={() => confirmState(p, 'cancel')}>
          取消
        </Button>
      )}
    </Space>
  );

  return (
    <>
      <PageHeader
        title="商户与活动"
        sub="平台官方活动（专题、限时活动价）：只能选商户授权「允许进入官方活动」的在售商品，活动价低于售价要商户同意；商户也可以报名开放报名的活动，运营审核。活动价由商户让利，平台可加每件补贴（按核销结算给商户）"
        extra={<MerchantNav />}
      />
      <Panel
        title="官方活动"
        extra={
          <Space wrap>
            <Segmented
              value={status}
              onChange={(v) => update({ status: String(v) || null, page: null })}
              options={[{ label: '全部', value: '' }, ...PROMOTION_STATUS_ORDER.map((s) => ({ label: PROMOTION_STATUS[s].text, value: s }))]}
            />
            <Button type="primary" icon={<Glyph name="plus" />} onClick={() => setEditing('new')}>
              新建活动
            </Button>
          </Space>
        }
      >
        <Table<Promotion>
          rowKey="id"
          loading={list.isFetching}
          dataSource={items}
          scroll={{ x: 1100 }}
          onRow={(p) => ({ onClick: () => update({ id: p.id }), style: { cursor: 'pointer' } })}
          locale={{ emptyText: <Empty description={status ? '没有这个状态的活动' : '还没有官方活动，点「新建活动」'} /> }}
          pagination={{ current: page, pageSize: PAGE, total: list.data?.total ?? 0, showSizeChanger: false, showTotal: (t) => `共 ${t} 个`, onChange: (p) => update({ page: p === 1 ? null : p }) }}
          columns={[
            {
              title: '活动',
              key: 'title',
              width: 280,
              render: (_, p) => (
                <div className="prod-cell">
                  {p.banner_url ? <img className="prod-thumb" src={p.banner_url} alt="" /> : <span className="prod-thumb" />}
                  <div style={{ minWidth: 0 }}>
                    <div className="prod-title">{p.title}</div>
                    <div className="prod-sub">{p.subtitle || '—'}</div>
                  </div>
                </div>
              ),
            },
            { title: '活动时间', key: 'period', width: 220, render: (_, p) => <span className="num">{periodText(p)}</span> },
            {
              title: '商户报名',
              key: 'apply',
              width: 150,
              render: (_, p) =>
                p.apply_open ? (
                  <span className="num">
                    开放
                    <div className="muted" style={{ fontSize: 12 }}>
                      截止 {p.apply_deadline ? dt(p.apply_deadline, 'MM-DD HH:mm') : '活动结束'}
                    </div>
                  </span>
                ) : (
                  <span className="muted">只由平台选品</span>
                ),
            },
            { title: '生效商品', dataIndex: 'product_qty', width: 90, align: 'right', render: (v: number) => <b className="num">{num(v)}</b> },
            {
              title: '待审报名',
              key: 'pending',
              width: 90,
              align: 'right',
              render: (_, p) => (pendingOf(p.id) ? <Badge count={pendingOf(p.id)} color="#d99a0b" /> : <span className="muted">—</span>),
            },
            { title: '状态', dataIndex: 'status', width: 90, render: (v: PromotionStatus) => <PromotionStatusTag status={v} /> },
            { title: '操作', key: 'op', width: 230, align: 'right', fixed: 'right', render: (_, p) => stateButtons(p) },
          ]}
        />
      </Panel>
      <PromotionDrawer id={openId} initialEntryStatus={entryStatus} onClose={() => update({ id: null, entry_status: null })} extra={(p) => stateButtons(p, 'middle')} />
      <PromotionForm value={editing} onClose={() => setEditing(null)} onSaved={(p) => update({ id: p.id })} />
    </>
  );
}

// ------------------------------------------------------------ detail + entries

type EntryDialog = { kind: 'approve' | 'edit'; e: PromotionEntry } | { kind: 'reject' | 'remove'; e: PromotionEntry } | null;

function PromotionDrawer({ id, initialEntryStatus, onClose, extra }: { id: number | null; initialEntryStatus: EntryStatus | ''; onClose: () => void; extra: (p: Promotion) => ReactNode }) {
  const qc = useQueryClient();
  const [filter, setFilter] = useState<'' | 'pending' | EntryStatus>('');
  const [adding, setAdding] = useState(false);
  const [dialog, setDialog] = useState<EntryDialog>(null);
  useEffect(() => {
    if (id) setFilter(initialEntryStatus === 'pending_platform' ? 'pending_platform' : '');
  }, [id, initialEntryStatus]);
  const promo = useQuery({ queryKey: ['promotions', 'detail', id], queryFn: () => commerceApi.promotion(id!), enabled: id !== null });
  const entries = useQuery({ queryKey: ['promotions', 'entries', id, 'all'], queryFn: () => commerceApi.promotionEntries(id!), enabled: id !== null });
  const p = promo.data;
  const all = entries.data?.items ?? [];
  const shown = filter === '' ? all : filter === 'pending' ? all.filter((e) => e.status === 'pending_merchant' || e.status === 'pending_platform') : all.filter((e) => e.status === filter);
  const count = (s: EntryStatus) => all.filter((e) => e.status === s).length;
  const editable = p && !['ended', 'cancelled'].includes(p.status);

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['promotions'] });
    qc.invalidateQueries({ queryKey: ['products'] });
    qc.invalidateQueries({ queryKey: ['dashboard'] });
  };
  const decide = useMutation({
    mutationFn: ({ e, kind, note, subsidy, sort }: { e: PromotionEntry; kind: 'approve' | 'reject' | 'remove' | 'edit'; note?: string; subsidy?: number; sort?: number }) =>
      kind === 'approve'
        ? commerceApi.approveEntry(e.id, subsidy ?? 0)
        : kind === 'reject'
          ? commerceApi.rejectEntry(e.id, note ?? '')
          : kind === 'remove'
            ? commerceApi.removeEntry(e.id, note ?? '')
            : commerceApi.patchEntry(e.id, { platform_subsidy_amt: subsidy, sort_no: sort }),
    onSuccess: (_r, v) => {
      setDialog(null);
      refresh();
      toastOk({ approve: '报名已通过，活动价在活动期间生效', reject: '已驳回，商户会收到原因', remove: '已从活动移除，商户会收到原因', edit: '已保存' }[v.kind]);
    },
  });

  return (
    <Drawer
      open={id !== null}
      onClose={onClose}
      width={1080}
      loading={promo.isLoading}
      title={
        p ? (
          <Space>
            {p.title}
            <PromotionStatusTag status={p.status} />
          </Space>
        ) : (
          '官方活动'
        )
      }
      extra={p && extra(p)}
    >
      {p && (
        <Space direction="vertical" size={16} style={{ width: '100%' }}>
          <Row gutter={16}>
            {p.banner_url && (
              <Col xs={24} md={8}>
                <Image src={p.banner_url} className="promo-banner" alt={p.title} />
              </Col>
            )}
            <Col xs={24} md={p.banner_url ? 16 : 24}>
              <Descriptions size="small" column={2} bordered>
                <Descriptions.Item label="副标题" span={2}>{p.subtitle || '—'}</Descriptions.Item>
                <Descriptions.Item label="活动时间" span={2}>
                  <span className="num">{periodText(p)}</span>
                </Descriptions.Item>
                <Descriptions.Item label="商户报名">{p.apply_open ? `开放，截止 ${p.apply_deadline ? dt(p.apply_deadline, 'MM-DD HH:mm') : '活动结束'}` : '不开放'}</Descriptions.Item>
                <Descriptions.Item label="生效商品">
                  <b className="num">{num(p.product_qty)}</b>
                </Descriptions.Item>
                <Descriptions.Item label="说明" span={2}>
                  <div style={{ whiteSpace: 'pre-wrap' }}>{p.description || '—'}</div>
                </Descriptions.Item>
              </Descriptions>
            </Col>
          </Row>
          {p.status === 'draft' && <Alert type="info" showIcon message="草稿：可以先选好商品，发布后 App 才展示、活动价才会在活动时间内生效" />}

          <div>
            <div className="mer-h3-row">
              <h3 className="mer-h3">活动商品 · {all.length}</h3>
              <Space wrap>
                <Segmented
                  size="small"
                  value={filter}
                  onChange={(v) => setFilter(v as typeof filter)}
                  options={[
                    { label: `全部 ${all.length}`, value: '' },
                    { label: `待审核 ${count('pending_platform')}`, value: 'pending_platform' },
                    { label: `待商户同意 ${count('pending_merchant')}`, value: 'pending_merchant' },
                    { label: `已生效 ${count('active')}`, value: 'active' },
                    { label: '已退出 / 移除 / 拒绝', value: 'rejected' },
                  ]}
                />
                {editable && (
                  <Button type="primary" size="small" icon={<Glyph name="plus" size={14} />} onClick={() => setAdding(true)}>
                    添加商品
                  </Button>
                )}
              </Space>
            </div>
            <Table<PromotionEntry>
              size="small"
              rowKey="id"
              loading={entries.isFetching}
              dataSource={filter === 'rejected' ? all.filter((e) => !LIVE.includes(e.status)) : shown}
              pagination={false}
              scroll={{ x: 1000 }}
              locale={{ emptyText: <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description={filter ? '没有这个状态的商品' : '还没有商品：点「添加商品」从商户授权的商品里选，或等商户报名'} /> }}
              columns={[
                {
                  title: '商品',
                  key: 'product',
                  width: 240,
                  render: (_, e) => (
                    <div className="prod-cell">
                      <ProductThumb p={e.product} />
                      <div style={{ minWidth: 0 }}>
                        <div className="prod-title">{e.product.title}</div>
                        <div className="prod-sub">{e.merchant.name}</div>
                      </div>
                    </div>
                  ),
                },
                { title: '来源', dataIndex: 'source', width: 80, render: (v: string) => <Tag bordered={false}>{ENTRY_SOURCE[v] ?? v}</Tag> },
                {
                  title: '活动价 / 售价',
                  key: 'price',
                  width: 170,
                  render: (_, e) => (
                    <div>
                      <PriceText price={e.promo_price_amt} original={e.product.price_amt !== e.promo_price_amt ? e.product.price_amt : null} />
                      <div className="muted" style={{ fontSize: 12 }}>
                        {discountLine(e.promo_price_amt, e.product.price_amt)}
                      </div>
                    </div>
                  ),
                },
                { title: '平台补贴/件', dataIndex: 'platform_subsidy_amt', width: 100, align: 'right', render: (v: number) => (v ? <b className="num">{yuan(v)}</b> : <span className="muted">—</span>) },
                {
                  title: '活动库存',
                  key: 'stock',
                  width: 100,
                  align: 'right',
                  render: (_, e) => (
                    <span className="num">
                      {e.promo_stock_qty === null ? '不限' : num(e.promo_stock_qty)}
                      <div className="muted" style={{ fontSize: 12 }}>
                        已售 {num(e.promo_sold_qty)}
                      </div>
                    </span>
                  ),
                },
                { title: '排序', dataIndex: 'sort_no', width: 60, align: 'right', render: (v: number) => <span className="num">{v}</span> },
                {
                  title: '状态',
                  key: 'status',
                  width: 130,
                  render: (_, e) => (
                    <div>
                      <EntryStatusTag status={e.status} />
                      {e.note && (
                        <Tooltip title={e.note}>
                          <div className="muted" style={{ fontSize: 12, maxWidth: 120, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                            {e.note}
                          </div>
                        </Tooltip>
                      )}
                    </div>
                  ),
                },
                {
                  title: '操作',
                  key: 'op',
                  width: 220,
                  align: 'right',
                  fixed: 'right',
                  render: (_, e) =>
                    editable ? (
                      <Space size={4}>
                        {e.status === 'pending_platform' && (
                          <>
                            <Button size="small" type="primary" icon={<Glyph name="check" size={14} />} onClick={() => setDialog({ kind: 'approve', e })}>
                              通过
                            </Button>
                            <Button size="small" danger icon={<Glyph name="close" size={14} />} onClick={() => setDialog({ kind: 'reject', e })}>
                              驳回
                            </Button>
                          </>
                        )}
                        {(e.status === 'active' || e.status === 'pending_merchant') && (
                          <>
                            <Button size="small" icon={<Glyph name="pencil" size={14} />} onClick={() => setDialog({ kind: 'edit', e })}>
                              补贴 / 排序
                            </Button>
                            <Button size="small" danger onClick={() => setDialog({ kind: 'remove', e })}>
                              移除
                            </Button>
                          </>
                        )}
                        {!LIVE.includes(e.status) && <span className="muted">—</span>}
                      </Space>
                    ) : (
                      <span className="muted">—</span>
                    ),
                },
              ]}
            />
          </div>
          <AddEntryModal promotion={adding ? p : null} onClose={() => setAdding(false)} onDone={refresh} />
          <SubsidyModal dialog={dialog?.kind === 'approve' || dialog?.kind === 'edit' ? dialog : null} loading={decide.isPending} onCancel={() => setDialog(null)} onOk={(subsidy, sort) => dialog && decide.mutate({ e: dialog.e, kind: dialog.kind, subsidy, sort })} />
          <ReasonModal
            open={dialog?.kind === 'reject' || dialog?.kind === 'remove'}
            title={dialog ? `${dialog.kind === 'reject' ? '驳回报名' : '从活动移除'}「${dialog.e.product.title}」· ${dialog.e.merchant.name}` : ''}
            presets={dialog?.kind === 'reject' ? ['活动价让利不够', '商品与活动主题不符', '库存太少', '名额已满'] : ['商户违规', '商品与活动主题不符', '价格异常', '用户投诉']}
            okText={dialog?.kind === 'reject' ? '驳回' : '移除'}
            loading={decide.isPending}
            effect={dialog?.kind === 'remove' ? '移除后活动价立即失效，已售出的订单不受影响；原因会发给商户。' : '原因会发给商户，商户可调整后重新报名。'}
            onCancel={() => setDialog(null)}
            onOk={(note) => dialog && decide.mutate({ e: dialog.e, kind: dialog.kind, note })}
          />
        </Space>
      )}
    </Drawer>
  );
}

function SubsidyModal({ dialog, loading, onCancel, onOk }: { dialog: { kind: 'approve' | 'edit'; e: PromotionEntry } | null; loading: boolean; onCancel: () => void; onOk: (subsidy: number, sort?: number) => void }) {
  const [subsidy, setSubsidy] = useState<number | null>(0);
  const [sort, setSort] = useState<number | null>(0);
  useEffect(() => {
    if (dialog) {
      setSubsidy(toYuan(dialog.e.platform_subsidy_amt));
      setSort(dialog.e.sort_no);
    }
  }, [dialog]);
  const e = dialog?.e;
  return (
    <Modal
      open={!!dialog}
      title={dialog?.kind === 'approve' ? `通过报名「${e?.product.title ?? ''}」` : `补贴与排序「${e?.product.title ?? ''}」`}
      okText={dialog?.kind === 'approve' ? '通过' : '保存'}
      cancelText="取消"
      confirmLoading={loading}
      onCancel={onCancel}
      onOk={() => onOk(toFen(subsidy) ?? 0, dialog?.kind === 'edit' ? sort ?? 0 : undefined)}
      destroyOnHidden
    >
      {e && (
        <Space direction="vertical" style={{ width: '100%' }} size={14}>
          <Alert
            type="info"
            showIcon
            message={
              <>
                {e.merchant.name} · 活动价 <b className="num">{yuan(e.promo_price_amt)}</b>（售价 {yuan(e.product.price_amt)}，{discountLine(e.promo_price_amt, e.product.price_amt)}）
              </>
            }
            description={`活动库存 ${e.promo_stock_qty === null ? '不限' : e.promo_stock_qty}。平台补贴按每核销一件结算给商户，计入结算单「官方活动补贴」。`}
          />
          <div>
            <div style={{ marginBottom: 6 }}>平台补贴（元/件）</div>
            <InputNumber className="num" min={0} max={1000} precision={2} prefix="¥" value={subsidy} onChange={setSubsidy} style={{ width: 200 }} />
            <span className="muted" style={{ marginLeft: 8, fontSize: 12 }}>
              0 = 不补贴
            </span>
          </div>
          {dialog?.kind === 'edit' && (
            <div>
              <div style={{ marginBottom: 6 }}>排序（越小越靠前）</div>
              <InputNumber className="num" min={0} max={999} precision={0} value={sort} onChange={setSort} style={{ width: 200 }} />
            </div>
          )}
        </Space>
      )}
    </Modal>
  );
}

/** 平台选品: only products whose merchant allowed official activities and that are on sale. */
function AddEntryModal({ promotion, onClose, onDone }: { promotion: Promotion | null; onClose: () => void; onDone: () => void }) {
  const [form] = Form.useForm<{ product_id: number; promo_yuan?: number | null; subsidy_yuan?: number | null; stock?: number | null; sort_no: number }>();
  const [kw, setKw] = useState('');
  const options = useQuery({
    queryKey: ['products', 'promotable', kw],
    queryFn: () => commerceApi.products({ allow_promotion: true, status: 'on_sale', q: kw, page_size: 50 }),
    enabled: !!promotion,
    placeholderData: (p) => p,
  });
  const productId = Form.useWatch('product_id', form);
  const promoYuan = Form.useWatch('promo_yuan', form);
  const picked = options.data?.items.find((x) => x.id === productId);
  const promoFen = toFen(promoYuan ?? null);
  const needsMerchant = picked && promoFen !== null && promoFen < picked.price_amt;
  useEffect(() => {
    if (promotion) {
      form.resetFields();
      form.setFieldsValue({ sort_no: 0, subsidy_yuan: 0 });
      setKw('');
    }
  }, [promotion, form]);
  const add = useMutation({
    mutationFn: (v: { product_id: number; promo_yuan?: number | null; subsidy_yuan?: number | null; stock?: number | null; sort_no: number }) =>
      commerceApi.addEntry(promotion!.id, { product_id: v.product_id, promo_price_amt: toFen(v.promo_yuan ?? null) ?? picked?.price_amt ?? 0, platform_subsidy_amt: toFen(v.subsidy_yuan ?? 0) ?? 0, promo_stock_qty: v.stock ?? null, sort_no: v.sort_no ?? 0 }),
    onSuccess: (e) => {
      toastOk(e.status === 'pending_merchant' ? '已邀请，商户同意后生效' : '已加入活动');
      onDone();
      onClose();
    },
  });
  return (
    <Modal open={!!promotion} title={`添加商品 · ${promotion?.title ?? ''}`} okText="添加" cancelText="取消" confirmLoading={add.isPending} onCancel={onClose} onOk={() => form.submit()} width={620} destroyOnHidden>
      <Alert type="info" showIcon style={{ marginBottom: 14 }} message="只列出商户授权「允许进入官方活动」的在售商品" description="活动价不填或等于售价：直接生效；低于售价：发邀请，商户同意后生效（差价由商户让利）。" />
      <Form form={form} layout="vertical" onFinish={(v) => add.mutate(v)} requiredMark="optional">
        <Form.Item name="product_id" label="商品" rules={[{ required: true, message: '请选择商品' }]}>
          <Select
            showSearch
            filterOption={false}
            onSearch={setKw}
            loading={options.isFetching}
            placeholder="搜索商品名称"
            notFoundContent={options.isFetching ? '加载中…' : '没有可选的商品'}
            options={(options.data?.items ?? []).map((x) => ({
              value: x.id,
              disabled: !!x.promotion,
              label: (
                <span>
                  {x.title} <span className="muted">· {x.merchant.name} · {yuan(x.price_amt)}{x.promotion ? ` · 已在「${x.promotion.title}」` : ''}</span>
                </span>
              ),
            }))}
          />
        </Form.Item>
        <Row gutter={12}>
          <Col span={12}>
            <Form.Item
              name="promo_yuan"
              label="活动价（元）"
              extra={picked ? (needsMerchant ? `${discountLine(promoFen!, picked.price_amt)}，需商户同意` : `售价 ${yuan(picked.price_amt)}，不填 = 原价直接生效`) : '不填 = 按售价'}
              rules={[{ validator: (_, v?: number | null) => (v === null || v === undefined || !picked || toFen(v)! <= picked.price_amt ? Promise.resolve() : Promise.reject(new Error('不能高于售价'))) }]}
            >
              <InputNumber className="num" min={0.01} max={10000} precision={2} prefix="¥" style={{ width: '100%' }} placeholder={picked ? String(picked.price_amt / 100) : ''} />
            </Form.Item>
          </Col>
          <Col span={12}>
            <Form.Item name="subsidy_yuan" label="平台补贴（元/件）" extra="按核销结算给商户">
              <InputNumber className="num" min={0} max={1000} precision={2} prefix="¥" style={{ width: '100%' }} />
            </Form.Item>
          </Col>
          <Col span={12}>
            <Form.Item name="stock" label="活动库存" extra="不填 = 不限（受商品库存约束）">
              <InputNumber className="num" min={1} max={99999} precision={0} style={{ width: '100%' }} placeholder="不限" />
            </Form.Item>
          </Col>
          <Col span={12}>
            <Form.Item name="sort_no" label="排序" extra="越小越靠前">
              <InputNumber className="num" min={0} max={999} precision={0} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
        </Row>
      </Form>
    </Modal>
  );
}

// ------------------------------------------------------------ create / edit

interface FormValues {
  title: string;
  subtitle?: string;
  banner_url?: string;
  description?: string;
  period: [Dayjs, Dayjs];
  apply_open: boolean;
  apply_deadline?: Dayjs | null;
}

function PromotionForm({ value, onClose, onSaved }: { value: Promotion | 'new' | null; onClose: () => void; onSaved: (p: Promotion) => void }) {
  const qc = useQueryClient();
  const [form] = Form.useForm<FormValues>();
  const editing = value && value !== 'new' ? value : null;
  const applyOpen = Form.useWatch('apply_open', form);
  useEffect(() => {
    if (!value) return;
    form.resetFields();
    form.setFieldsValue(
      editing
        ? {
            title: editing.title,
            subtitle: editing.subtitle ?? '',
            banner_url: editing.banner_url ?? '',
            description: editing.description ?? '',
            period: [dayjs(editing.starts_at), dayjs(editing.ends_at)],
            apply_open: editing.apply_open,
            apply_deadline: editing.apply_deadline ? dayjs(editing.apply_deadline) : null,
          }
        : { apply_open: true, period: [dayjs().add(7, 'day').startOf('day'), dayjs().add(14, 'day').endOf('day')], apply_deadline: dayjs().add(5, 'day').endOf('day') },
    );
  }, [value, editing, form]);
  const save = useMutation({
    mutationFn: (body: PromotionInput) => (editing ? commerceApi.updatePromotion(editing.id, body) : commerceApi.createPromotion(body)),
    onSuccess: (p) => {
      toastOk(editing ? '活动已保存' : '活动已创建（草稿），选好商品后发布');
      qc.invalidateQueries({ queryKey: ['promotions'] });
      onClose();
      onSaved(p);
    },
  });
  const submit = (v: FormValues) =>
    save.mutate({
      title: v.title.trim(),
      subtitle: v.subtitle?.trim() || null,
      banner_url: v.banner_url?.trim() || null,
      description: v.description?.trim() || null,
      starts_at: v.period[0].toISOString(),
      ends_at: v.period[1].toISOString(),
      apply_open: !!v.apply_open,
      apply_deadline: v.apply_open && v.apply_deadline ? v.apply_deadline.toISOString() : null,
    });
  return (
    <Drawer
      open={value !== null}
      onClose={onClose}
      width={640}
      title={editing ? `编辑活动 · ${editing.title}` : '新建官方活动'}
      extra={
        <Space>
          <Button onClick={onClose}>取消</Button>
          <Button type="primary" loading={save.isPending} onClick={() => form.submit()}>
            保存
          </Button>
        </Space>
      }
    >
      {editing?.status === 'active' && <Alert type="warning" showIcon style={{ marginBottom: 14 }} message="活动进行中：改时间会影响活动价的生效范围，参与商户会收到通知" />}
      <Form form={form} layout="vertical" onFinish={submit} requiredMark="optional">
        <Form.Item name="title" label="活动名称" rules={[{ required: true, whitespace: true, message: '请填写活动名称' }, { min: 2, max: 30, message: '2–30 字' }]}>
          <Input placeholder="双 12 运动狂欢" showCount maxLength={30} />
        </Form.Item>
        <Form.Item name="subtitle" label="副标题" rules={[{ max: 40, message: '最多 40 字' }]}>
          <Input placeholder="羽毛球、游泳、健身 5 折起" />
        </Form.Item>
        <Form.Item name="period" label="活动时间" rules={[{ required: true, message: '请选择活动时间' }]} extra="活动价只在这段时间内生效">
          <DatePicker.RangePicker showTime={{ format: 'HH:mm' }} format="YYYY-MM-DD HH:mm" style={{ width: '100%' }} />
        </Form.Item>
        <Row gutter={12}>
          <Col span={10}>
            <Form.Item name="apply_open" label="商户报名" valuePropName="checked" extra="打开后商户可以把自己的商品报名进来，运营审核">
              <Switch checkedChildren="开放" unCheckedChildren="不开放" />
            </Form.Item>
          </Col>
          <Col span={14}>
            <Form.Item name="apply_deadline" label="报名截止" rules={[{ required: !!applyOpen, message: '请选择报名截止时间' }]}>
              <DatePicker showTime={{ format: 'HH:mm' }} format="YYYY-MM-DD HH:mm" disabled={!applyOpen} style={{ width: '100%' }} />
            </Form.Item>
          </Col>
        </Row>
        <Form.Item name="banner_url" label="横幅图" extra="App 首页「玩法」/ 本地生活入口展示">
          <SingleImageUpload purpose="promotion_banner" shape="banner" label="活动横幅" hint="建议 3:1" />
        </Form.Item>
        <Form.Item name="description" label="活动说明" rules={[{ max: 1000, message: '最多 1000 字' }]}>
          <Input.TextArea rows={4} showCount maxLength={1000} />
        </Form.Item>
      </Form>
    </Drawer>
  );
}
