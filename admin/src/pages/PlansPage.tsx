import { useEffect, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, App, Button, Checkbox, Col, Input, InputNumber, Modal, Row, Segmented, Skeleton, Space, Switch, Table, Tag, Tooltip } from 'antd';
import { LockOutlined, SearchOutlined } from '@ant-design/icons';
import { api, PAGE_SIZE } from '../api/admin';
import type { AdminOrder, OrderStatus, Plan, PlanUpdate } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import { PageHeader, Panel, Stat } from '../components/ui';
import { bigNumber, dt, pct, yuan } from '../utils/format';
import { CHANNEL_LABEL, ORDER_KIND, ORDER_STATUS, PERIOD_LABEL } from '../utils/labels';
import { toastOk } from '../utils/notify';

type Tab = 'plans' | 'entitlements' | 'orders';

export default function PlansPage() {
  const [params, setParams] = useSearchParams();
  const tab = (params.get('tab') as Tab) || 'plans';
  const stats = useQuery({ queryKey: ['orders', 'stats'], queryFn: api.orderStats });
  const s = stats.data;

  return (
    <>
      <PageHeader
        title="会员套餐与订单"
        sub="会员只提供体验类权益，不提升抢地、攻击等对抗能力"
        extra={
          <Segmented
            size="large"
            value={tab}
            onChange={(v) => setParams(v === 'plans' ? {} : { tab: String(v) })}
            options={[
              { label: '套餐', value: 'plans' },
              { label: '权益', value: 'entitlements' },
              { label: '订单', value: 'orders' },
            ]}
          />
        }
      />
      <Row gutter={[16, 16]}>
        {s ? (
          <>
            <Col xs={12} xl={6}>
              <Stat value={`¥${bigNumber(s.month_revenue_fen / 100).value}${bigNumber(s.month_revenue_fen / 100).unit}`} label="本月会员收入" />
            </Col>
            <Col xs={12} xl={6}>
              <Stat value={bigNumber(s.active_members).value} unit={bigNumber(s.active_members).unit} label="在订会员" />
            </Col>
            <Col xs={12} xl={6}>
              <Stat value={pct(s.renew_success_rate, 0)} label="自动续费成功率" sub="失败多因余额不足" />
            </Col>
            <Col xs={12} xl={6}>
              <Stat value={pct(s.refund_rate_today)} label="今日退款率" sub="按今日订单数计" />
            </Col>
          </>
        ) : (
          <Col span={24}>
            <Skeleton active paragraph={{ rows: 2 }} />
          </Col>
        )}
      </Row>
      {tab === 'plans' && <PlansTab />}
      {tab === 'entitlements' && <EntitlementsTab />}
      {tab === 'orders' && <OrdersTab />}
    </>
  );
}

// ---------------------------------------------------------------- plans

function toUpdate(p: Plan): PlanUpdate {
  return {
    name: p.name,
    price_fen: p.price_fen,
    first_price_fen: p.first_price_fen,
    renew_price_fen: p.renew_price_fen,
    on_sale: p.on_sale,
    recommended: p.recommended,
    sort: p.sort,
  };
}

function planDesc(p: Plan, d: PlanUpdate): string {
  if (p.auto_renew) return '每月自动续费，可随时关闭';
  if (p.seats > 1) return `团长购买，${p.seats} 人共享，${PERIOD_LABEL[p.period] ?? p.period}`;
  if (p.period === 'year') return `12 个月，折合 ${yuan(Math.round(d.price_fen / 12))}/月`;
  if (p.period === 'quarter') return '3 个月';
  return '单月购买，不自动续费';
}

const same = (a: PlanUpdate, b: PlanUpdate) => (Object.keys(a) as (keyof PlanUpdate)[]).every((k) => a[k] === b[k]);

function PlansTab() {
  const qc = useQueryClient();
  const { can } = useAuth();
  const editable = can('plan.write');
  const { data } = useQuery({ queryKey: ['plans'], queryFn: api.plans });
  const plans = useMemo(() => data?.items ?? [], [data]);
  const [drafts, setDrafts] = useState<Record<string, PlanUpdate>>({});

  useEffect(() => {
    setDrafts(Object.fromEntries(plans.map((p) => [p.code, toUpdate(p)])));
  }, [plans]);

  const save = useMutation({
    mutationFn: ({ code, body }: { code: string; body: PlanUpdate }) => api.updatePlan(code, body),
    onSuccess: () => {
      toastOk('已保存，新价格只对新订单生效');
      qc.invalidateQueries({ queryKey: ['plans'] });
    },
  });

  const setField = (code: string, patch: Partial<PlanUpdate>) =>
    setDrafts((d) => {
      const next = { ...d, [code]: { ...d[code], ...patch } };
      if (patch.recommended) for (const k of Object.keys(next)) if (k !== code) next[k] = { ...next[k], recommended: false };
      return next;
    });

  if (!data) return <Skeleton active />;

  const ordered = [...plans].sort((a, b) => (drafts[a.code]?.sort ?? a.sort) - (drafts[b.code]?.sort ?? b.sort));

  return (
    <Row gutter={[20, 20]}>
      <Col xs={24} xl={16}>
        <div className="panel-head" style={{ marginBottom: 12 }}>
          <h2 className="panel-title">套餐</h2>
          <span className="panel-hint">改价只对新订单生效，已订阅用户按原价续费</span>
        </div>
        <Row gutter={[16, 16]}>
          {ordered.map((p) => {
            const d = drafts[p.code];
            if (!d) return null;
            const dirty = !same(d, toUpdate(p));
            const invalid = d.first_price_fen !== null && d.first_price_fen > d.price_fen;
            return (
              <Col xs={24} md={12} xxl={8} key={p.code}>
                <div className={`plan-card${d.recommended ? ' rec' : ''}${d.on_sale ? '' : ' off'}`}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <b style={{ fontSize: 17 }}>{p.name}</b>
                    <Space size={4}>
                      {d.recommended && <Tag color="#141414">推荐</Tag>}
                      {!d.on_sale && <Tag bordered={false}>已下架</Tag>}
                    </Space>
                  </div>
                  <div className="muted" style={{ fontSize: 12, margin: '6px 0 12px' }}>
                    {planDesc(p, d)} · <span className="num">{p.code}</span>
                  </div>
                  <Row gutter={8}>
                    <Col span={p.auto_renew ? 8 : 12}>
                      <div className="muted" style={{ fontSize: 11 }}>售价 ¥</div>
                      <InputNumber
                        disabled={!editable}
                        min={0.01}
                        precision={2}
                        style={{ width: '100%' }}
                        value={d.price_fen / 100}
                        onChange={(v) => {
                          const fen = Math.round((v ?? 0) * 100);
                          setField(p.code, p.auto_renew ? { price_fen: fen } : { price_fen: fen, renew_price_fen: fen });
                        }}
                      />
                    </Col>
                    <Col span={p.auto_renew ? 8 : 12}>
                      <div className="muted" style={{ fontSize: 11 }}>首期 ¥</div>
                      <InputNumber
                        disabled={!editable}
                        min={0.01}
                        precision={2}
                        status={invalid ? 'error' : undefined}
                        style={{ width: '100%' }}
                        placeholder="无"
                        value={d.first_price_fen === null ? null : d.first_price_fen / 100}
                        onChange={(v) => setField(p.code, { first_price_fen: v === null || v === undefined ? null : Math.round(v * 100) })}
                      />
                    </Col>
                    {p.auto_renew && (
                      <Col span={8}>
                        <div className="muted" style={{ fontSize: 11 }}>续费 ¥</div>
                        <InputNumber
                          disabled={!editable}
                          min={0.01}
                          precision={2}
                          style={{ width: '100%' }}
                          value={d.renew_price_fen / 100}
                          onChange={(v) => setField(p.code, { renew_price_fen: Math.round((v ?? 0) * 100) })}
                        />
                      </Col>
                    )}
                  </Row>
                  {invalid && (
                    <div className="danger-text" style={{ fontSize: 12, marginTop: 4 }}>
                      首期价不能高于售价
                    </div>
                  )}
                  <div style={{ borderTop: '1px solid #ececef', margin: '14px 0 10px' }} />
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                    <span style={{ fontSize: 13 }}>上架</span>
                    <Switch disabled={!editable} checked={d.on_sale} onChange={(v) => setField(p.code, { on_sale: v })} />
                    <span style={{ fontSize: 13, marginLeft: 6 }}>排序</span>
                    <InputNumber disabled={!editable} size="small" min={0} style={{ width: 56 }} value={d.sort} onChange={(v) => setField(p.code, { sort: v ?? 0 })} />
                    <div style={{ flex: 1 }} />
                    <Button size="small" disabled={!editable || d.recommended} onClick={() => setField(p.code, { recommended: true })}>
                      {d.recommended ? '已设为推荐' : '设为推荐'}
                    </Button>
                  </div>
                  {dirty && (
                    <Space style={{ marginTop: 12 }}>
                      <Button type="primary" size="small" disabled={invalid} loading={save.isPending && save.variables?.code === p.code} onClick={() => save.mutate({ code: p.code, body: { ...d, first_price_fen: d.first_price_fen ?? (p.first_price_fen !== null ? 0 : null) } })}>
                        保存
                      </Button>
                      <Button size="small" onClick={() => setField(p.code, toUpdate(p))}>
                        还原
                      </Button>
                    </Space>
                  )}
                </div>
              </Col>
            );
          })}
        </Row>
        <div className="panel grey" style={{ marginTop: 16, height: 'auto' }}>
          <b>自动续费规则</b>
          <div style={{ fontSize: 13, marginTop: 6, color: '#3a3a40', lineHeight: 1.7 }}>
            开通页显著标明续费价格和周期；每次扣费前 5 天通过短信和 App 提醒；「我的 → 会员」里可以一键关闭，关闭后到期不再扣费。未成年人账号不展示付费入口。
          </div>
        </div>
      </Col>
      <Col xs={24} xl={8}>
        <div className="panel-hint" style={{ marginBottom: 10 }}>
          App 开通页实时预览（含未保存的改动）
        </div>
        <PlanPreview plans={ordered} drafts={drafts} />
      </Col>
    </Row>
  );
}

function PlanPreview({ plans, drafts }: { plans: Plan[]; drafts: Record<string, PlanUpdate> }) {
  const shown = plans.filter((p) => drafts[p.code]?.on_sale);
  const auto = shown.find((p) => p.auto_renew);
  return (
    <div className="phone">
      <div className="phone-screen">
        <div style={{ fontSize: 20, fontWeight: 900 }}>圈地会员</div>
        <div style={{ fontSize: 12, color: '#b9b9c0', marginTop: 6 }}>手绘 / 3D 地图 · 高级数据 · AI 教练不限次</div>
        {shown.length === 0 && <div style={{ color: '#888', marginTop: 24, textAlign: 'center' }}>没有上架的套餐</div>}
        {shown.map((p) => {
          const d = drafts[p.code];
          const first = d.first_price_fen;
          const discounted = first !== null && first < d.price_fen;
          return (
            <div key={p.code} className={`pv-plan${d.recommended ? ' rec' : ''}`}>
              <div>
                <div style={{ fontWeight: 700, fontSize: 14 }}>
                  {d.name}
                  {d.recommended ? ' · 推荐' : ''}
                </div>
                <div style={{ fontSize: 11, color: '#b9b9c0', marginTop: 2 }}>
                  {p.auto_renew
                    ? `${first !== null ? `首期 ${yuan(first)}，之后 ` : '每月 '}${yuan(d.renew_price_fen)}/月`
                    : discounted
                      ? `首期 ${yuan(first)}，之后 ${yuan(d.price_fen)}`
                      : planDesc(p, d)}
                </div>
              </div>
              <div style={{ textAlign: 'right' }}>
                <div className="num" style={{ fontSize: 18, fontWeight: 800 }}>
                  {yuan(discounted ? first : d.price_fen)}
                </div>
                {discounted && (
                  <div className="num" style={{ fontSize: 11, color: '#8a8a90', textDecoration: 'line-through' }}>
                    {yuan(d.price_fen)}
                  </div>
                )}
              </div>
            </div>
          );
        })}
        <div className="pv-cta">立即开通</div>
        {auto && (
          <div style={{ fontSize: 10, color: '#9a9aa0', marginTop: 10, textAlign: 'center', lineHeight: 1.6 }}>
            {drafts[auto.code].name}首月 {yuan(drafts[auto.code].first_price_fen ?? drafts[auto.code].renew_price_fen)}，次月起 {yuan(drafts[auto.code].renew_price_fen)}/月自动续费，扣费前 5 天提醒，可随时在「我的」中关闭
          </div>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- entitlements

function EntitlementsTab() {
  const qc = useQueryClient();
  const { can } = useAuth();
  const editable = can('plan.write');
  const ents = useQuery({ queryKey: ['entitlements'], queryFn: api.entitlements });
  const plans = useQuery({ queryKey: ['plans'], queryFn: api.plans });

  const toggle = useMutation({
    mutationFn: ({ plan, list }: { plan: string; list: string[] }) => api.updatePlanEntitlements(plan, list),
    onSuccess: (p) => {
      qc.setQueryData(['plans'], (old: { items: Plan[] } | undefined) => (old ? { items: old.items.map((x) => (x.code === p.code ? { ...x, ...p } : x)) } : old));
      toastOk(`已更新「${p.name}」的权益`);
    },
  });

  if (!ents.data || !plans.data) return <Skeleton active />;
  const ps = [...plans.data.items].sort((a, b) => a.sort - b.sort);

  return (
    <Panel title="权益矩阵" extra={<span className="panel-hint">行是权益、列是套餐，点格子开关。锁定的权益任何套餐都不能开</span>}>
      <Table
        rowKey="key"
        pagination={false}
        dataSource={ents.data.items}
        scroll={{ x: 720 }}
        columns={[
          {
            title: '权益',
            dataIndex: 'name',
            fixed: 'left',
            render: (v: string, e) => (
              <Space>
                <b>{v}</b>
                {e.locked && (
                  <Tooltip title="涉及对抗公平，锁死不可售卖">
                    <Tag icon={<LockOutlined />} bordered={false}>
                      锁定
                    </Tag>
                  </Tooltip>
                )}
              </Space>
            ),
          },
          ...ps.map((p) => ({
            title: (
              <span>
                {p.name}
                {!p.on_sale && <span className="muted">（下架）</span>}
              </span>
            ),
            key: p.code,
            align: 'center' as const,
            render: (_: unknown, e: { key: string; locked: boolean }) => {
              const on = p.entitlements.includes(e.key);
              return (
                <Checkbox
                  aria-label={`${p.name} · ${e.key}`}
                  checked={on && !e.locked}
                  disabled={e.locked || !editable || toggle.isPending}
                  onChange={(ev) =>
                    toggle.mutate({ plan: p.code, list: ev.target.checked ? [...p.entitlements, e.key] : p.entitlements.filter((k) => k !== e.key) })
                  }
                />
              );
            },
          })),
        ]}
      />
    </Panel>
  );
}

// ---------------------------------------------------------------- orders

const ORDER_FILTERS: { label: string; value: OrderStatus | '' }[] = [
  { label: '全部', value: '' },
  { label: '已支付', value: 'paid' },
  { label: '退款申请', value: 'refund_requested' },
  { label: '续费失败', value: 'renew_failed' },
  { label: '已退款', value: 'refunded' },
  { label: '待支付', value: 'created' },
  { label: '已关闭', value: 'closed' },
];

function OrdersTab() {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const { can } = useAuth();
  const [params, setParams] = useSearchParams();
  const status = (params.get('status') as OrderStatus | null) ?? '';
  const q = params.get('q') ?? '';
  const page = Number(params.get('page') ?? 1);
  const [kw, setKw] = useState(q);
  const [refund, setRefund] = useState<AdminOrder | null>(null);
  const [reason, setReason] = useState('');

  const update = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null || v === '') next.delete(k);
      else next.set(k, v);
    }
    setParams(next, { replace: true });
  };

  const list = useQuery({
    queryKey: ['orders', 'list', status, q, page],
    queryFn: () => api.orders({ status, q, page }),
    placeholderData: (prev) => prev,
  });

  const doRefund = useMutation({
    mutationFn: ({ order, reason: r }: { order: AdminOrder; reason: string }) => api.refund(order.order_no, r),
    onSuccess: () => {
      toastOk('已退款，款项原路退回，会员权益已收回');
      qc.invalidateQueries({ queryKey: ['orders'] });
    },
  });
  const remind = useMutation({
    mutationFn: (o: AdminOrder) => api.remind(o.order_no),
    onSuccess: () => toastOk('已提醒用户续费，3 天内保留会员权益'),
  });

  // Second confirmation, after the reason was filled in on the first.
  const secondConfirm = (order: AdminOrder, r: string) => {
    setRefund(null);
    modal.confirm({
      title: '再次确认退款',
      content: (
        <div>
          将向 <b>{order.user.nickname}</b> 退回 <b>{yuan(order.amount_fen)}</b>（{CHANNEL_LABEL[order.channel] ?? order.channel}原路退回），并立即收回会员权益。此操作不可撤销。
          <div className="muted" style={{ marginTop: 8 }}>
            原因：{r}
          </div>
        </div>
      ),
      okText: '确认退款',
      okButtonProps: { danger: true },
      cancelText: '取消',
      onOk: () => doRefund.mutateAsync({ order, reason: r }),
    });
  };

  return (
    <Panel
      title="订单"
      extra={
        <Space wrap>
          <Input
            allowClear
            prefix={<SearchOutlined />}
            placeholder="订单号、用户昵称或 ID"
            style={{ width: 240 }}
            value={kw}
            onChange={(e) => {
              setKw(e.target.value);
              if (!e.target.value) update({ q: null, page: null });
            }}
            onPressEnter={() => update({ q: kw.trim(), page: null })}
          />
          <Segmented value={status} onChange={(v) => update({ status: String(v) || null, page: null })} options={ORDER_FILTERS} />
        </Space>
      }
    >
      <Table<AdminOrder>
        rowKey="order_no"
        loading={list.isFetching}
        dataSource={list.data?.items}
        scroll={{ x: 1200 }}
        pagination={{
          current: page,
          pageSize: PAGE_SIZE,
          total: list.data?.total ?? 0,
          showSizeChanger: false,
          showTotal: (t) => `共 ${t} 笔`,
          onChange: (p) => update({ page: p === 1 ? null : String(p) }),
        }}
        columns={[
          { title: '订单号', dataIndex: 'order_no', render: (v: string) => <span className="num">{v}</span> },
          { title: '用户', key: 'user', render: (_, o) => <Link to={`/users?id=${o.user.id}`}>{o.user.nickname}</Link> },
          { title: '套餐', dataIndex: 'plan_name' },
          { title: '金额', dataIndex: 'amount_fen', align: 'right', render: (v: number) => <b className="num">{yuan(v)}</b> },
          { title: '类型', dataIndex: 'kind', render: (v?: string) => (v ? ORDER_KIND[v] ?? v : '—') },
          { title: '渠道', dataIndex: 'channel', render: (v: string) => CHANNEL_LABEL[v] ?? v },
          {
            title: '状态',
            dataIndex: 'status',
            render: (v: OrderStatus) => (
              <Tag bordered={false} color={ORDER_STATUS[v]?.color}>
                {ORDER_STATUS[v]?.text ?? v}
              </Tag>
            ),
          },
          { title: '下单时间', dataIndex: 'created_at', render: (v: string) => <span className="num">{dt(v)}</span> },
          { title: '支付时间', dataIndex: 'paid_at', render: (v: string | null, o) => <span className="num">{dt(v)}{o.refunded_at ? <div className="muted">退款 {dt(o.refunded_at)}</div> : null}</span> },
          {
            title: '操作',
            key: 'op',
            align: 'right',
            fixed: 'right',
            render: (_, o) => (
              <Space>
                {(o.status === 'paid' || o.status === 'refund_requested') &&
                  (can('order.refund') ? (
                    <Button
                      size="small"
                      danger={o.status === 'refund_requested'}
                      onClick={() => {
                        setReason(o.status === 'refund_requested' ? '用户申请退款' : '');
                        setRefund(o);
                      }}
                    >
                      退款
                    </Button>
                  ) : (
                    <Tooltip title="只有管理员可以退款">
                      <Button size="small" disabled>
                        退款
                      </Button>
                    </Tooltip>
                  ))}
                {o.status === 'renew_failed' && (
                  <Button size="small" type="primary" disabled={!can('order.remind')} loading={remind.isPending && remind.variables?.order_no === o.order_no} onClick={() => remind.mutate(o)}>
                    提醒用户
                  </Button>
                )}
              </Space>
            ),
          },
        ]}
      />
      <Modal
        open={!!refund}
        title="退款（第 1 步，共 2 步）"
        okText="下一步"
        cancelText="取消"
        okButtonProps={{ disabled: !reason.trim() }}
        onCancel={() => setRefund(null)}
        onOk={() => refund && secondConfirm(refund, reason.trim())}
      >
        {refund && (
          <Space direction="vertical" style={{ width: '100%' }}>
            <Alert type="warning" showIcon message={`订单 ${refund.order_no} · ${refund.plan_name} · ${yuan(refund.amount_fen)}`} description="退款原路退回，并收回该订单对应的会员权益。" />
            <Input.TextArea rows={3} maxLength={200} showCount placeholder="退款原因（必填，会写入审计日志）" value={reason} onChange={(e) => setReason(e.target.value)} />
          </Space>
        )}
      </Modal>
    </Panel>
  );
}
