// V2 第五批 · 商品订单 (docs/api/v2-5「商户商品」· 商品订单). Merchant accounts see their own orders; admin / ops see
// every merchant's; admin can refund the unused coupons of an order (two-step confirm, audited).
import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import dayjs from 'dayjs';
import { Alert, App, Button, DatePicker, Descriptions, Drawer, Empty, Input, Modal, Select, Space, Table, Tag, Tooltip } from 'antd';
import { commerceApi, type ProductOrder, type ProductOrderStatus } from '../../api/commerce';
import type { Coupon, CouponStatus } from '../../api/merchant';
import { useAuth } from '../../auth/AuthContext';
import { PageHeader, Panel } from '../../components/ui';
import { dt, yuan } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { ORDER_STATUS, ORDER_STATUS_ORDER, PRODUCT_TYPE } from './commerceLabels';
import { OrderStatusTag } from './commerceShared';
import { COUPON_STATUS } from './labels';
import { MerchantNav } from './nav';
import { urlParams, useMerchantOptions } from './util';

const PAGE = 20;

/** What an admin refund returns: every unused coupon (次卡: the unused share). */
function refundable(o: ProductOrder): { qty: number; amt: number } {
  const unused = o.coupons.filter((c) => c.status === 'unused');
  const amt = unused.reduce((s, c) => s + (c.uses_total && c.uses_total > 1 ? Math.round((o.unit_price_amt * (c.uses_left ?? c.uses_total)) / c.uses_total) : o.unit_price_amt), 0);
  return { qty: unused.length, amt };
}

function CouponTag({ status }: { status: CouponStatus }) {
  const s = COUPON_STATUS[status];
  return (
    <Tag bordered={false} color={s?.color} style={{ marginInlineEnd: 0 }}>
      {s?.text ?? status}
    </Tag>
  );
}

export default function ProductOrdersPage() {
  const { can, admin } = useAuth();
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const staff = admin?.role === 'merchant';
  const [params, setParams] = useSearchParams();
  const update = urlParams(params, setParams);
  const merchantId = Number(params.get('merchant_id') ?? 0) || null;
  const productId = Number(params.get('product_id') ?? 0) || null;
  const status = (params.get('status') ?? '') as ProductOrderStatus | '';
  const from = params.get('from') ?? '';
  const to = params.get('to') ?? '';
  const page = Number(params.get('page') ?? 1);
  const [detail, setDetail] = useState<ProductOrder | null>(null);
  const [refund, setRefund] = useState<ProductOrder | null>(null);
  const [reason, setReason] = useState('');
  const merchants = useMerchantOptions(!staff && can('merchant.read'));
  const products = useQuery({
    queryKey: ['products', 'options', merchantId],
    queryFn: () => commerceApi.products({ merchant_id: merchantId, page_size: 100 }),
    staleTime: 60_000,
  });

  const list = useQuery({
    queryKey: ['product-orders', 'list', merchantId, productId, status, from, to, page],
    queryFn: () => commerceApi.productOrders({ merchant_id: merchantId, product_id: productId, status, from, to, page }),
    placeholderData: (p) => p,
  });

  const doRefund = useMutation({
    mutationFn: ({ o, r }: { o: ProductOrder; r: string }) => commerceApi.refundProductOrder(o.id, r),
    onSuccess: (o) => {
      toastOk(o.status === 'refunding' ? '已发起退款，款项原路退回（到账后变为「已退款」）' : '未使用的券已退款，已用的不受影响');
      qc.invalidateQueries({ queryKey: ['product-orders'] });
      setDetail((d) => (d && d.id === o.id ? o : d));
    },
  });

  const secondConfirm = (o: ProductOrder, r: string) => {
    setRefund(null);
    const x = refundable(o);
    modal.confirm({
      title: '再次确认退款',
      content: (
        <div>
          将向 <b>{o.user?.nickname ?? '用户'}</b> 原路退回 <b>{yuan(x.amt)}</b>（{x.qty} 张未使用的券作废）。已核销的券不能退。此操作不可撤销。
          <div className="muted" style={{ marginTop: 8 }}>
            原因：{r}
          </div>
        </div>
      ),
      okText: '确认退款',
      okButtonProps: { danger: true },
      cancelText: '取消',
      onOk: () => doRefund.mutateAsync({ o, r }),
    });
  };

  const refundButton = (o: ProductOrder, size: 'small' | 'middle' = 'small') => {
    if (!can('product_order.refund') || !['paid', 'completed'].includes(o.status)) return null;
    const x = refundable(o);
    if (!x.qty) return null;
    return (
      <Button
        size={size}
        danger
        onClick={(e) => {
          e.stopPropagation();
          setReason('');
          setRefund(o);
        }}
      >
        退款
      </Button>
    );
  };

  return (
    <>
      <PageHeader
        title={staff ? '商品订单' : '商户与活动'}
        sub={
          staff
            ? '用户在 App 购买本店商品的订单：支付后每件发 1 张券，到店核销；未使用的券用户可自助退款，过期未用自动退款。退款问题请联系平台运营'
            : '全部商户的商品订单；管理员可为用户退掉未使用的券（已核销的不能退，退款不进结算）'
        }
        extra={<MerchantNav />}
      />
      <Panel
        title="商品订单"
        extra={
          <Space wrap>
            {!staff && (
              <Select
                allowClear
                showSearch
                optionFilterProp="label"
                placeholder="全部商户"
                style={{ width: 160 }}
                value={merchantId ?? undefined}
                onChange={(v) => update({ merchant_id: v ?? null, product_id: null, page: null })}
                options={merchants.options}
              />
            )}
            <Select
              allowClear
              showSearch
              optionFilterProp="label"
              placeholder="全部商品"
              style={{ width: 200 }}
              value={productId ?? undefined}
              onChange={(v) => update({ product_id: v ?? null, page: null })}
              options={(products.data?.items ?? []).map((p) => ({ value: p.id, label: staff ? p.title : `${p.title} · ${p.merchant.name}` }))}
            />
            <DatePicker.RangePicker
              style={{ width: 240 }}
              placeholder={['下单开始', '结束']}
              value={from && to ? [dayjs(from), dayjs(to)] : null}
              onChange={(v) => update({ from: v?.[0]?.format('YYYY-MM-DD') ?? null, to: v?.[1]?.format('YYYY-MM-DD') ?? null, page: null })}
            />
            <Select
              allowClear
              placeholder="全部状态"
              style={{ width: 120 }}
              value={status || undefined}
              onChange={(v) => update({ status: v ?? null, page: null })}
              options={ORDER_STATUS_ORDER.map((s) => ({ value: s, label: ORDER_STATUS[s].text }))}
            />
          </Space>
        }
      >
        <Table<ProductOrder>
          rowKey="id"
          loading={list.isFetching}
          dataSource={list.data?.items}
          scroll={{ x: 1250 }}
          onRow={(o) => ({ onClick: () => setDetail(o), style: { cursor: 'pointer' } })}
          locale={{ emptyText: <Empty description="没有符合条件的订单" /> }}
          pagination={{ current: page, pageSize: PAGE, total: list.data?.total ?? 0, showSizeChanger: false, showTotal: (t) => `共 ${t} 笔`, onChange: (p) => update({ page: p === 1 ? null : p }) }}
          columns={[
            { title: '订单号', dataIndex: 'order_no', width: 190, render: (v: string) => <span className="num">{v}</span> },
            {
              title: '商品',
              key: 'product',
              width: 240,
              render: (_, o) => (
                <div className="prod-cell">
                  {o.product.image ? <img className="prod-thumb" src={o.product.image} alt="" /> : <span className="prod-thumb" />}
                  <div style={{ minWidth: 0 }}>
                    <div className="prod-title">{o.product.title}</div>
                    <div className="prod-sub">{PRODUCT_TYPE[o.product.type]?.text ?? o.product.type}{!staff && ` · ${o.merchant.name}`}</div>
                  </div>
                </div>
              ),
            },
            { title: '用户', key: 'user', width: 120, render: (_, o) => (o.user ? (can('users.read') ? <Link to={`/users?id=${o.user.id}`} onClick={(e) => e.stopPropagation()}>{o.user.nickname}</Link> : o.user.nickname) : '—') },
            {
              title: '数量 × 单价',
              key: 'qty',
              width: 130,
              align: 'right',
              render: (_, o) => (
                <span className="num">
                  {o.qty} × {yuan(o.unit_price_amt)}
                  {o.promotion && (
                    <Tooltip title={`官方活动「${o.promotion.title}」活动价`}>
                      <div>
                        <Tag bordered={false} color="volcano" style={{ marginInlineEnd: 0 }}>
                          活动价
                        </Tag>
                      </div>
                    </Tooltip>
                  )}
                </span>
              ),
            },
            {
              title: '实付 / 已退',
              key: 'amt',
              width: 120,
              align: 'right',
              render: (_, o) => (
                <span className="num">
                  <b>{yuan(o.amount_amt)}</b>
                  {o.refund_amt > 0 && <div className="muted" style={{ fontSize: 12 }}>退 {yuan(o.refund_amt)}</div>}
                </span>
              ),
            },
            {
              title: '券',
              key: 'coupons',
              width: 120,
              render: (_, o) => {
                if (!o.coupons.length) return <span className="muted">—</span>;
                const used = o.coupons.filter((c) => c.status === 'used').length;
                const unused = o.coupons.filter((c) => c.status === 'unused').length;
                return (
                  <span className="num" style={{ fontSize: 12 }}>
                    已用 {used} · 未用 {unused}
                    {o.coupons.length - used - unused > 0 && <span className="muted"> · 其他 {o.coupons.length - used - unused}</span>}
                  </span>
                );
              },
            },
            { title: '状态', dataIndex: 'status', width: 90, render: (v: ProductOrderStatus) => <OrderStatusTag status={v} /> },
            { title: '下单时间', dataIndex: 'created_at', width: 130, render: (v: string) => <span className="num">{dt(v, 'MM-DD HH:mm')}</span> },
            { title: '操作', key: 'op', width: 80, align: 'right', fixed: 'right', render: (_, o) => refundButton(o) || <span className="muted">—</span> },
          ]}
        />
      </Panel>

      <Drawer open={detail !== null} onClose={() => setDetail(null)} width={720} title={detail ? `商品订单 ${detail.order_no}` : ''} extra={detail && refundButton(detail, 'middle')}>
        {detail && <OrderDetail o={detail} staff={staff} />}
      </Drawer>

      <Modal
        open={!!refund}
        title="商品订单退款（第 1 步，共 2 步）"
        okText="下一步"
        cancelText="取消"
        okButtonProps={{ disabled: !reason.trim() }}
        onCancel={() => setRefund(null)}
        onOk={() => refund && secondConfirm(refund, reason.trim())}
      >
        {refund && (
          <Space direction="vertical" style={{ width: '100%' }}>
            <Alert
              type="warning"
              showIcon
              message={`${refund.order_no} · ${refund.product.title}`}
              description={`退掉 ${refundable(refund).qty} 张未使用的券，原路退回 ${yuan(refundable(refund).amt)}；已核销的券不能退。退款不进结算。`}
            />
            <Input.TextArea rows={3} maxLength={200} showCount placeholder="退款原因（必填，会写入审计日志）" value={reason} onChange={(e) => setReason(e.target.value)} />
          </Space>
        )}
      </Modal>
    </>
  );
}

function OrderDetail({ o, staff }: { o: ProductOrder; staff: boolean }) {
  return (
    <Space direction="vertical" size={16} style={{ width: '100%' }}>
      <Descriptions size="small" column={2} bordered>
        <Descriptions.Item label="状态">
          <OrderStatusTag status={o.status} />
        </Descriptions.Item>
        <Descriptions.Item label="商品">
          {o.product.title}
          <span className="muted"> · {PRODUCT_TYPE[o.product.type]?.text ?? o.product.type}</span>
        </Descriptions.Item>
        {!staff && <Descriptions.Item label="商户">{o.merchant.name}</Descriptions.Item>}
        <Descriptions.Item label="用户">{o.user ? `${o.user.nickname}（ID ${o.user.id}）` : '—'}</Descriptions.Item>
        <Descriptions.Item label="数量 × 单价">
          <span className="num">
            {o.qty} × {yuan(o.unit_price_amt)}
          </span>
        </Descriptions.Item>
        <Descriptions.Item label="实付">
          <b className="num">{yuan(o.amount_amt)}</b>
          {o.refund_amt > 0 && <span className="muted num">（已退 {yuan(o.refund_amt)}）</span>}
        </Descriptions.Item>
        <Descriptions.Item label="官方活动">{o.promotion ? `「${o.promotion.title}」活动价` : '—'}</Descriptions.Item>
        <Descriptions.Item label="下单">
          <span className="num">{dt(o.created_at)}</span>
        </Descriptions.Item>
        <Descriptions.Item label="支付">
          <span className="num">{o.paid_at ? dt(o.paid_at) : o.status === 'pending' ? `待支付，${dt(o.pay_expires_at, 'HH:mm')} 前` : '—'}</span>
        </Descriptions.Item>
      </Descriptions>
      {o.status === 'pending' && <Alert type="info" showIcon message="待支付：下单 15 分钟内未支付自动取消，并释放库存" />}
      {o.status === 'refunding' && <Alert type="warning" showIcon message="退款处理中：等待支付渠道回调，到账后变为「已退款」" />}
      <div>
        <div className="mer-h3-row">
          <h3 className="mer-h3">券 · {o.coupons.length}</h3>
          <span className="muted" style={{ fontSize: 12 }}>支付成功后每件发 1 张，用户在卡券包出示，核销台核销</span>
        </div>
        <Table<Coupon>
          size="small"
          rowKey="id"
          pagination={false}
          dataSource={o.coupons}
          locale={{ emptyText: o.status === 'pending' ? '支付后发券' : '没有券' }}
          columns={[
            { title: '券码', dataIndex: 'code', render: (v: string) => <span className="num">{v}</span> },
            { title: '状态', dataIndex: 'status', render: (v: CouponStatus) => <CouponTag status={v} /> },
            { title: '次数', key: 'uses', render: (_, c) => (c.uses_total && c.uses_total > 1 ? <span className="num">剩 {c.uses_left ?? 0} / {c.uses_total}</span> : <span className="muted">—</span>) },
            { title: '有效期至', dataIndex: 'expires_at', render: (v: string) => <span className="num">{dt(v, 'YYYY-MM-DD')}</span> },
            {
              title: '核销',
              key: 'used',
              render: (_, c) =>
                c.used_at ? (
                  <span className="num" style={{ fontSize: 12 }}>
                    {dt(c.used_at, 'MM-DD HH:mm')}
                    {c.used_store && <span className="muted"> · {c.used_store}</span>}
                  </span>
                ) : (
                  <span className="muted">—</span>
                ),
            },
          ]}
        />
      </div>
    </Space>
  );
}
