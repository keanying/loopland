// V2 第五批 · 官方活动（商户账号，promotion.join）(docs/api/v2-5「官方活动」· 商户): three views — activities open
// for applications (apply with a product, activity price and stock), platform invitations (accept / decline, the
// price difference spelled out), and my entries (withdraw).
import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import dayjs from 'dayjs';
import { Alert, App, Button, Col, Empty, Form, Image, InputNumber, Modal, Row, Segmented, Select, Space, Table, Tag, Tooltip } from 'antd';
import { commerceApi, type EntryStatus, type Promotion, type PromotionEntry } from '../../api/commerce';
import { PageHeader, Panel } from '../../components/ui';
import { dt, num, yuan } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { ReasonModal } from '../review/shared';
import { discountLine, ENTRY_SOURCE, ENTRY_STATUS, ENTRY_STATUS_ORDER } from './commerceLabels';
import { EntryStatusTag, PriceText, PromotionStatusTag } from './commerceShared';
import { MerchantNav } from './nav';
import { ProductThumb } from './ProductsPage';
import { toFen, urlParams } from './util';
import { Glyph } from '../../components/Glyph';

type View = 'open' | 'invites' | 'mine';
const LIVE: EntryStatus[] = ['active', 'pending_merchant', 'pending_platform'];

function periodText(p: Pick<Promotion, 'starts_at' | 'ends_at'>): string {
  return `${dayjs(p.starts_at).format('MM/DD HH:mm')} – ${dayjs(p.ends_at).format('MM/DD HH:mm')}`;
}

/** 「每件少收 ¥20」 — what accepting an invitation costs the merchant per item, net of the platform subsidy. */
function PriceDiff({ e }: { e: PromotionEntry }) {
  const diff = e.product.price_amt - e.promo_price_amt;
  const net = diff - e.platform_subsidy_amt;
  return (
    <div className="num" style={{ lineHeight: 1.4 }}>
      {diff > 0 ? (
        <>
          <b className="danger-text">每件少收 {yuan(diff)}</b>
          <div className="muted" style={{ fontSize: 12 }}>
            {discountLine(e.promo_price_amt, e.product.price_amt)}
          </div>
          {e.platform_subsidy_amt > 0 && (
            <div style={{ fontSize: 12 }}>
              平台补 {yuan(e.platform_subsidy_amt)} → 实际让利 <b>{yuan(Math.max(0, net))}</b>
            </div>
          )}
        </>
      ) : (
        <span>与售价相同</span>
      )}
    </div>
  );
}

export default function MyPromotionsPage() {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const [params, setParams] = useSearchParams();
  const update = urlParams(params, setParams);
  // `?tab=` comes from 站内信 links (/merchant/promotions?tab=invites | mine); `?view=` from the page itself.
  const rawView = params.get('view') ?? params.get('tab') ?? '';
  const view = (['open', 'invites', 'mine'].includes(rawView) ? rawView : null) as View | null;
  const mineStatus = (params.get('status') ?? '') as EntryStatus | '';
  const [applying, setApplying] = useState<Promotion | null>(null);
  const [declining, setDeclining] = useState<PromotionEntry | null>(null);

  const open = useQuery({ queryKey: ['promotions', 'open'], queryFn: commerceApi.openPromotions });
  const mine = useQuery({ queryKey: ['promotion-entries', 'mine'], queryFn: () => commerceApi.myEntries() });
  const all = mine.data?.items ?? [];
  const invites = all.filter((e) => e.status === 'pending_merchant');
  // Default view: invitations first when there are some.
  const current: View = view ?? (invites.length ? 'invites' : 'open');
  const promoTitle = (e: PromotionEntry) => e.promotion?.title ?? open.data?.items.find((p) => p.id === e.promotion_id)?.title ?? `活动 #${e.promotion_id}`;
  const promoPeriod = (e: PromotionEntry) => {
    const p = e.promotion ?? open.data?.items.find((x) => x.id === e.promotion_id);
    return p ? periodText(p) : '';
  };

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['promotion-entries'] });
    qc.invalidateQueries({ queryKey: ['promotions'] });
    qc.invalidateQueries({ queryKey: ['products'] });
  };
  const act = useMutation({
    mutationFn: ({ e, op, note }: { e: PromotionEntry; op: 'accept' | 'decline' | 'withdraw'; note?: string }) =>
      op === 'accept' ? commerceApi.acceptEntry(e.id) : op === 'decline' ? commerceApi.declineEntry(e.id, note ?? '') : commerceApi.withdrawEntry(e.id),
    onSuccess: (_r, v) => {
      setDeclining(null);
      refresh();
      toastOk({ accept: '已接受，活动期间 App 按活动价售卖', decline: '已拒绝邀请', withdraw: '已退出活动，活动价立即失效' }[v.op]);
    },
  });
  const confirmAccept = (e: PromotionEntry) =>
    modal.confirm({
      title: `接受「${promoTitle(e)}」的邀请？`,
      content: (
        <div>
          「{e.product.title}」活动期间按 <b className="num">{yuan(e.promo_price_amt)}</b> 售卖（售价 {yuan(e.product.price_amt)}），每件少收 <b className="num">{yuan(e.product.price_amt - e.promo_price_amt)}</b>
          {e.platform_subsidy_amt > 0 && <>，平台每核销一件补贴 <b className="num">{yuan(e.platform_subsidy_amt)}</b></>}。
          {e.promo_stock_qty !== null && `活动库存 ${e.promo_stock_qty} 件，卖完恢复原价。`}
          随时可以退出，已售出的不受影响。
        </div>
      ),
      okText: '接受',
      cancelText: '再想想',
      onOk: () => act.mutateAsync({ e, op: 'accept' }),
    });
  const confirmWithdraw = (e: PromotionEntry) =>
    modal.confirm({
      title: `退出「${promoTitle(e)}」？`,
      content: `「${e.product.title}」${e.status === 'active' ? '的活动价立即失效，恢复原价' : '的报名撤回'}；已售出的订单不受影响。`,
      okText: '退出',
      okButtonProps: { danger: true },
      cancelText: '取消',
      onOk: () => act.mutateAsync({ e, op: 'withdraw' }),
    });

  const productCell = (e: PromotionEntry) => (
    <div className="prod-cell">
      <ProductThumb p={e.product} />
      <div style={{ minWidth: 0 }}>
        <div className="prod-title">{e.product.title}</div>
        <div className="prod-sub">售价 {yuan(e.product.price_amt)}</div>
      </div>
    </div>
  );
  const promoCell = (e: PromotionEntry) => (
    <div>
      <b>{promoTitle(e)}</b>
      <div className="muted num" style={{ fontSize: 12 }}>
        {promoPeriod(e)}
      </div>
    </div>
  );

  const appliedIds = new Set(all.filter((e) => LIVE.includes(e.status)).map((e) => e.promotion_id));

  return (
    <>
      <PageHeader
        title="官方活动"
        sub="平台的专题和限时活动：可以把在售商品报名到开放报名的活动（平台审核），也会收到平台的选品邀请。活动价由你让利，平台可能加每件补贴（按核销进结算单）；随时可以退出，已售出的不受影响"
        extra={<MerchantNav />}
      />
      <Panel
        title={
          <Segmented
            value={current}
            onChange={(v) => update({ view: String(v), tab: null, status: null })}
            options={[
              { label: `可报名的活动 ${open.data?.items.length ?? ''}`, value: 'open' },
              { label: `平台邀请${invites.length ? ` ${invites.length}` : ''}`, value: 'invites' },
              { label: `我的报名 ${all.length || ''}`, value: 'mine' },
            ]}
          />
        }
        extra={
          current === 'mine' && (
            <Select
              allowClear
              placeholder="全部状态"
              style={{ width: 140 }}
              value={mineStatus || undefined}
              onChange={(v) => update({ status: v ?? null })}
              options={ENTRY_STATUS_ORDER.map((s) => ({ value: s, label: ENTRY_STATUS[s].staff ?? ENTRY_STATUS[s].text }))}
            />
          )
        }
      >
        {current === 'open' && (
          <Table<Promotion>
            rowKey="id"
            loading={open.isFetching}
            dataSource={open.data?.items}
            pagination={false}
            scroll={{ x: 960 }}
            locale={{ emptyText: <Empty description="现在没有开放报名的活动" /> }}
            columns={[
              {
                title: '活动',
                key: 'title',
                width: 320,
                render: (_, p) => (
                  <div className="prod-cell">
                    {p.banner_url ? <Image src={p.banner_url} width={96} height={54} style={{ objectFit: 'cover', borderRadius: 10 }} alt="" /> : <span className="prod-thumb" />}
                    <div style={{ minWidth: 0 }}>
                      <div className="prod-title">{p.title}</div>
                      <div className="prod-sub">{p.subtitle || '—'}</div>
                    </div>
                  </div>
                ),
              },
              { title: '活动时间', key: 'period', width: 200, render: (_, p) => <span className="num">{periodText(p)}</span> },
              { title: '报名截止', dataIndex: 'apply_deadline', width: 140, render: (v: string | null) => <span className="num">{v ? dt(v, 'MM-DD HH:mm') : '活动结束前'}</span> },
              { title: '已有商品', dataIndex: 'product_qty', width: 90, align: 'right', render: (v: number) => <span className="num">{num(v)}</span> },
              { title: '状态', dataIndex: 'status', width: 90, render: (v: Promotion['status']) => <PromotionStatusTag status={v} /> },
              {
                title: '操作',
                key: 'op',
                width: 150,
                align: 'right',
                fixed: 'right',
                render: (_, p) => (
                  <Space size={6}>
                    {appliedIds.has(p.id) && <Tag bordered={false} color="blue">已报名</Tag>}
                    <Button size="small" type="primary" icon={<Glyph name="send" size={14} />} onClick={() => setApplying(p)}>
                      报名
                    </Button>
                  </Space>
                ),
              },
            ]}
          />
        )}

        {current === 'invites' && (
          <Table<PromotionEntry>
            rowKey="id"
            loading={mine.isFetching}
            dataSource={invites}
            pagination={false}
            scroll={{ x: 1100 }}
            locale={{ emptyText: <Empty description="没有待确认的平台邀请" /> }}
            columns={[
              { title: '活动', key: 'promo', width: 200, render: (_, e) => promoCell(e) },
              { title: '商品', key: 'product', width: 230, render: (_, e) => productCell(e) },
              { title: '邀请活动价', dataIndex: 'promo_price_amt', width: 110, align: 'right', render: (v: number) => <b className="num" style={{ fontSize: 16 }}>{yuan(v)}</b> },
              { title: '差价', key: 'diff', width: 210, render: (_, e) => <PriceDiff e={e} /> },
              { title: '活动库存', dataIndex: 'promo_stock_qty', width: 90, align: 'right', render: (v: number | null) => <span className="num">{v === null ? '不限' : num(v)}</span> },
              { title: '邀请时间', dataIndex: 'created_at', width: 110, render: (v: string) => <span className="num">{dt(v, 'MM-DD HH:mm')}</span> },
              {
                title: '操作',
                key: 'op',
                width: 170,
                align: 'right',
                fixed: 'right',
                render: (_, e) => (
                  <Space size={6}>
                    <Button size="small" type="primary" icon={<Glyph name="check" size={14} />} onClick={() => confirmAccept(e)}>
                      接受
                    </Button>
                    <Button size="small" icon={<Glyph name="close" size={14} />} onClick={() => setDeclining(e)}>
                      拒绝
                    </Button>
                  </Space>
                ),
              },
            ]}
          />
        )}

        {current === 'mine' && (
          <Table<PromotionEntry>
            rowKey="id"
            loading={mine.isFetching}
            dataSource={mineStatus ? all.filter((e) => e.status === mineStatus) : all}
            pagination={false}
            scroll={{ x: 1150 }}
            locale={{ emptyText: <Empty description="还没有参加过官方活动" /> }}
            columns={[
              { title: '活动', key: 'promo', width: 200, render: (_, e) => promoCell(e) },
              { title: '商品', key: 'product', width: 230, render: (_, e) => productCell(e) },
              { title: '来源', dataIndex: 'source', width: 90, render: (v: string) => <Tag bordered={false}>{v === 'platform' ? '平台邀请' : ENTRY_SOURCE[v] ?? v}</Tag> },
              { title: '活动价', key: 'price', width: 140, render: (_, e) => <PriceText price={e.promo_price_amt} original={e.promo_price_amt < e.product.price_amt ? e.product.price_amt : null} /> },
              { title: '平台补贴/件', dataIndex: 'platform_subsidy_amt', width: 100, align: 'right', render: (v: number) => (v ? <b className="num">{yuan(v)}</b> : <span className="muted">—</span>) },
              {
                title: '活动库存 / 已售',
                key: 'stock',
                width: 120,
                align: 'right',
                render: (_, e) => (
                  <span className="num">
                    {e.promo_stock_qty === null ? '不限' : num(e.promo_stock_qty)} / {num(e.promo_sold_qty)}
                  </span>
                ),
              },
              {
                title: '状态',
                key: 'status',
                width: 140,
                render: (_, e) => (
                  <div>
                    <EntryStatusTag status={e.status} staff />
                    {e.note && (
                      <Tooltip title={e.note}>
                        <div className="danger-text" style={{ fontSize: 12, maxWidth: 130, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
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
                width: 150,
                align: 'right',
                fixed: 'right',
                render: (_, e) =>
                  e.status === 'pending_merchant' ? (
                    <Space size={6}>
                      <Button size="small" type="primary" onClick={() => confirmAccept(e)}>
                        接受
                      </Button>
                      <Button size="small" onClick={() => setDeclining(e)}>
                        拒绝
                      </Button>
                    </Space>
                  ) : LIVE.includes(e.status) && !['ended', 'cancelled'].includes(e.promotion?.status ?? '') ? (
                    <Button size="small" danger icon={<Glyph name="logout" size={14} />} onClick={() => confirmWithdraw(e)}>
                      {e.status === 'pending_platform' ? '撤回' : '退出'}
                    </Button>
                  ) : (
                    <span className="muted">—</span>
                  ),
              },
            ]}
          />
        )}
      </Panel>

      <ApplyModal promotion={applying} taken={new Set(all.filter((e) => applying && e.promotion_id === applying.id && LIVE.includes(e.status)).map((e) => e.product.id))} onClose={() => setApplying(null)} onDone={refresh} />
      <ReasonModal
        open={declining !== null}
        title={`拒绝邀请「${declining?.product.title ?? ''}」`}
        presets={['让利太多', '库存不够', '档期冲突', '暂不参加活动']}
        okText="拒绝"
        required={false}
        loading={act.isPending}
        effect="拒绝后这个商品不参加本活动，平台会收到你的说明。"
        onCancel={() => setDeclining(null)}
        onOk={(note) => declining && act.mutate({ e: declining, op: 'decline', note })}
      />
    </>
  );
}

/** `taken`: my products already in this activity (applied, invited or active). */
function ApplyModal({ promotion, taken, onClose, onDone }: { promotion: Promotion | null; taken: Set<number>; onClose: () => void; onDone: () => void }) {
  const [form] = Form.useForm<{ product_id: number; promo_yuan: number; stock?: number | null }>();
  const products = useQuery({ queryKey: ['products', 'on_sale', 'mine'], queryFn: () => commerceApi.products({ status: 'on_sale', page_size: 100 }), enabled: !!promotion });
  const productId = Form.useWatch('product_id', form);
  const promoYuan = Form.useWatch('promo_yuan', form);
  const picked = products.data?.items.find((x) => x.id === productId);
  const promoFen = toFen(promoYuan ?? null);
  useEffect(() => {
    if (promotion) form.resetFields();
  }, [promotion, form]);
  const apply = useMutation({
    mutationFn: (v: { product_id: number; promo_yuan: number; stock?: number | null }) => commerceApi.applyPromotion(promotion!.id, { product_id: v.product_id, promo_price_amt: toFen(v.promo_yuan) ?? 0, promo_stock_qty: v.stock ?? null }),
    onSuccess: () => {
      toastOk('已报名，等待平台审核');
      onDone();
      onClose();
    },
  });
  return (
    <Modal open={!!promotion} title={`报名「${promotion?.title ?? ''}」`} okText="提交报名" cancelText="取消" confirmLoading={apply.isPending} onCancel={onClose} onOk={() => form.submit()} width={600} destroyOnHidden>
      {promotion && (
        <Alert
          type="info"
          showIcon
          style={{ marginBottom: 14 }}
          message={`活动时间 ${periodText(promotion)}${promotion.apply_deadline ? `，报名截止 ${dt(promotion.apply_deadline, 'MM-DD HH:mm')}` : ''}`}
          description="活动价由你让利（不能高于售价），平台审核通过后在活动期间生效，可能加每件补贴。同一商品同一时间只能在一个活动里。"
        />
      )}
      <Form form={form} layout="vertical" onFinish={(v) => apply.mutate(v)} requiredMark="optional">
        <Form.Item name="product_id" label="商品" rules={[{ required: true, message: '请选择要报名的商品' }]} extra="只能报名在售的商品">
          <Select
            showSearch
            optionFilterProp="title"
            loading={products.isLoading}
            placeholder="选择在售商品"
            notFoundContent="没有在售的商品"
            options={(products.data?.items ?? []).map((x) => ({
              value: x.id,
              title: x.title,
              disabled: !!x.promotion || taken.has(x.id),
              label: (
                <span>
                  {x.title} <span className="muted">· {yuan(x.price_amt)}{taken.has(x.id) ? ' · 已在本活动' : x.promotion ? ` · 已在「${x.promotion.title}」` : ''}</span>
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
              extra={picked ? (promoFen ? discountLine(promoFen, picked.price_amt) : `售价 ${yuan(picked.price_amt)}`) : undefined}
              rules={[
                { required: true, message: '请填写活动价' },
                { validator: (_, v?: number) => (v === undefined || v === null || !picked || toFen(v)! <= picked.price_amt ? Promise.resolve() : Promise.reject(new Error('不能高于售价'))) },
              ]}
            >
              <InputNumber className="num" min={0.01} max={10000} precision={2} prefix="¥" style={{ width: '100%' }} placeholder={picked ? String(picked.price_amt / 100) : ''} />
            </Form.Item>
          </Col>
          <Col span={12}>
            <Form.Item name="stock" label="活动库存" extra="不填 = 不限；卖完恢复原价">
              <InputNumber className="num" min={1} max={99999} precision={0} style={{ width: '100%' }} placeholder="不限" />
            </Form.Item>
          </Col>
        </Row>
      </Form>
    </Modal>
  );
}
