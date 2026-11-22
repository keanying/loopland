import { useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { EChartsOption } from 'echarts';
import dayjs from 'dayjs';
import type { Dayjs } from 'dayjs';
import { Alert, App, Button, Col, DatePicker, Descriptions, Drawer, Empty, Modal, Row, Segmented, Select, Space, Table, Tag } from 'antd';
import { CheckOutlined, FileAddOutlined, PayCircleOutlined } from '@ant-design/icons';
import { merchantApi, type SettlementDay, type Statement, type StatementLine, type StatementStatus } from '../../api/merchant';
import { useAuth } from '../../auth/AuthContext';
import Chart from '../../components/Chart';
import { PageHeader, Panel, Tile } from '../../components/ui';
import { useAdminNames } from '../../hooks/useAdminNames';
import { BRAND } from '../../theme';
import { dt, num, pct, yuan } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { SETTLE_DIRECTION, STATEMENT_STATUS } from './labels';
import { MerchantNav } from './nav';
import { NetAmount, StatementStatusTag } from './shared';
import { urlParams, useMerchantOptions } from './util';

const PAGE = 20;
/** Theme info violet: the second series colour used across the console (see AI 用量). */
const SECOND = '#7B6AE0';

type Metric = 'redemptions' | 'voided' | 'bookings';
const METRIC: Record<Metric, { label: string; unit: string; color: string }> = {
  redemptions: { label: '核销', unit: '次', color: BRAND.ink },
  voided: { label: '风控作废', unit: '次', color: BRAND.red },
  bookings: { label: '订场', unit: '笔', color: SECOND },
};

/** One measure per chart: voided (~1%) and bookings (tens) would vanish next to redemptions (hundreds). */
function chartOption(days: SettlementDay[], metric: Metric): EChartsOption {
  const x = days.map((d) => dayjs(d.date).format('MM/DD ddd'));
  const m = METRIC[metric];
  return {
    grid: { left: 48, right: 16, top: 24, bottom: 28 },
    tooltip: {
      trigger: 'axis',
      axisPointer: { type: 'shadow' },
      formatter: (ps) => {
        const p = (Array.isArray(ps) ? ps[0] : ps) as { dataIndex: number; name: string };
        const d = days[p.dataIndex];
        const all = d.redemptions + d.voided;
        return `${p.name}<br/>有效核销 <b>${d.redemptions.toLocaleString('zh-CN')}</b> 次<br/>风控作废 <b>${d.voided}</b> 次${all ? `（${((d.voided / all) * 100).toFixed(1)}%）` : ''}<br/>订场 <b>${d.bookings}</b> 笔`;
      },
    },
    xAxis: { type: 'category', data: x, axisLine: { lineStyle: { color: '#d8d8dc' } }, axisTick: { show: false }, axisLabel: { color: '#6a6a70' } },
    yAxis: { type: 'value', minInterval: 1, splitLine: { lineStyle: { type: 'dashed', color: '#e6e6ea' } }, axisLabel: { color: '#8a8a90' } },
    series: [
      {
        type: 'bar',
        name: m.label,
        barMaxWidth: 28,
        data: days.map((d) => d[metric]),
        itemStyle: { color: m.color, borderRadius: [4, 4, 0, 0] },
        label: { show: true, position: 'top', color: '#3a3a40', fontSize: 11 },
      },
    ],
  };
}

export default function SettlementPage() {
  const { can, admin } = useAuth();
  const staff = admin?.role === 'merchant';
  const writable = can('settlement.write');
  const [params, setParams] = useSearchParams();
  const update = urlParams(params, setParams);
  const status = (params.get('status') ?? '') as StatementStatus | '';
  const merchantId = Number(params.get('merchant_id') ?? 0) || null;
  const page = Number(params.get('page') ?? 1);
  const openId = Number(params.get('id') ?? 0) || null;
  const [asTable, setAsTable] = useState(false);
  const [metric, setMetric] = useState<Metric>('redemptions');
  const [generating, setGenerating] = useState(false);
  const merchants = useMerchantOptions(!staff && can('merchant.read'));

  const overview = useQuery({ queryKey: ['settlement', 'overview'], queryFn: () => merchantApi.settlementOverview(7) });
  const list = useQuery({
    queryKey: ['statements', 'list', status, merchantId, page],
    queryFn: () => merchantApi.statements({ status, merchant_id: merchantId, page }),
    placeholderData: (p) => p,
  });
  const days = overview.data?.days ?? [];
  const sum = (k: keyof Omit<SettlementDay, 'date'>) => days.reduce((s, d) => s + d[k], 0);
  const voidRate = sum('redemptions') + sum('voided') ? sum('voided') / (sum('redemptions') + sum('voided')) : 0;

  return (
    <>
      <PageHeader
        title={staff ? '结算单' : '商户与活动'}
        sub={staff ? '本商户每周的核销和订场结算；有疑问请联系平台运营' : '每周一 03:00 生成上周结算单（核销 + 订场），逐家确认、线下打款后标记已付款；风控作废和已退款的不结算'}
        extra={<MerchantNav />}
      />
      <Row gutter={[20, 20]} className="band">
        <Col xs={24} lg={16}>
          <Panel
            title="近 7 天核销"
            extra={
              <Space>
                <span className="muted" style={{ fontSize: 12 }}>
                  {staff ? '本商户' : '全部商户'}
                </span>
                {!asTable && (
                  <Segmented
                    size="small"
                    value={metric}
                    onChange={(v) => setMetric(v as Metric)}
                    options={(Object.keys(METRIC) as Metric[]).map((k) => ({ label: `${METRIC[k].label}（${METRIC[k].unit}）`, value: k }))}
                  />
                )}
                <Segmented size="small" value={asTable ? 'table' : 'chart'} onChange={(v) => setAsTable(v === 'table')} options={[{ label: '图', value: 'chart' }, { label: '表', value: 'table' }]} />
              </Space>
            }
          >
            {overview.isLoading ? (
              <div style={{ height: 280 }} />
            ) : asTable ? (
              <Table<SettlementDay>
                size="small"
                rowKey="date"
                pagination={false}
                dataSource={days}
                columns={[
                  { title: '日期', dataIndex: 'date', render: (v: string) => <span className="num">{dayjs(v).format('MM/DD ddd')}</span> },
                  { title: '有效核销', dataIndex: 'redemptions', align: 'right', render: (v: number) => <span className="num">{num(v)}</span> },
                  { title: '风控作废', dataIndex: 'voided', align: 'right', render: (v: number) => <span className="num">{num(v)}</span> },
                  { title: '订场', dataIndex: 'bookings', align: 'right', render: (v: number) => <span className="num">{num(v)}</span> },
                ]}
              />
            ) : (
              <div className="band-grow chart-box">
                <Chart option={chartOption(days, metric)} style={{ height: '100%' }} />
              </div>
            )}
          </Panel>
        </Col>
        <Col xs={24} lg={8}>
          <Panel title="近 7 天" grey>
            <Row gutter={[10, 10]}>
              <Col span={12}>
                <Tile v={num(sum('redemptions'))} l="有效核销（次）" />
              </Col>
              <Col span={12}>
                <Tile v={num(sum('voided'))} l={`风控作废 · ${pct(voidRate)}`} warn={voidRate > 0.03} />
              </Col>
              <Col span={12}>
                <Tile v={num(sum('bookings'))} l="订场（笔）" />
              </Col>
              <Col span={12}>
                <Tile v={num(overview.data?.pending_statements)} l="待确认结算单" warn={!!overview.data?.pending_statements} />
              </Col>
            </Row>
            <div className="muted" style={{ fontSize: 12, marginTop: 14, lineHeight: 1.7 }}>
              结算规则：核销需同时满足「当天有一条有效运动记录」和「到店扫码」；当天运动记录事后被风控作废的，那天的核销标记作废、不结算。订场款扣除佣金后结算给商户。
            </div>
            {writable && (
              <Button block icon={<FileAddOutlined />} style={{ marginTop: 14 }} onClick={() => setGenerating(true)}>
                手动生成结算单
              </Button>
            )}
          </Panel>
        </Col>
      </Row>

      <Panel
        title="结算单"
        extra={
          <Space wrap>
            {!staff && (
              <Select
                allowClear
                showSearch
                optionFilterProp="label"
                placeholder="全部商户"
                style={{ width: 180 }}
                value={merchantId ?? undefined}
                onChange={(v) => update({ merchant_id: v ?? null, page: null })}
                options={merchants.options}
              />
            )}
            <Segmented
              value={status}
              onChange={(v) => update({ status: String(v) || null, page: null })}
              options={[{ label: '全部', value: '' }, ...(['draft', 'confirmed', 'paid'] as StatementStatus[]).map((s) => ({ label: STATEMENT_STATUS[s].text, value: s }))]}
            />
          </Space>
        }
      >
        <Table<Statement>
          rowKey="id"
          loading={list.isFetching}
          dataSource={list.data?.items}
          scroll={{ x: 1320 }}
          onRow={(s) => ({ onClick: () => update({ id: s.id }), style: { cursor: 'pointer' } })}
          locale={{ emptyText: <Empty description="没有结算单" /> }}
          pagination={{ current: page, pageSize: PAGE, total: list.data?.total ?? 0, showSizeChanger: false, showTotal: (t) => `共 ${t} 张`, onChange: (p) => update({ page: p === 1 ? null : p }) }}
          columns={[
            { title: '结算单号', dataIndex: 'statement_no', width: 150, render: (v: string) => <span className="num">{v}</span> },
            ...(staff ? [] : [{ title: '商户', key: 'merchant', width: 170, render: (_: unknown, s: Statement) => s.merchant.name }]),
            { title: '状态', dataIndex: 'status', width: 130, render: (v: StatementStatus) => <StatementStatusTag status={v} /> },
            { title: '周期', key: 'period', render: (_, s) => <span className="num">{dayjs(s.period_start).format('MM/DD')}–{dayjs(s.period_end).format('MM/DD')}</span> },
            {
              title: '有效核销',
              key: 'red',
              align: 'right',
              render: (_, s) => (
                <span className="num">
                  {num(s.redemption_qty)}
                  {s.voided_qty > 0 && <div className="muted" style={{ fontSize: 12 }}>剔除 {s.voided_qty}</div>}
                </span>
              ),
            },
            {
              title: '核销结算',
              key: 'red_amt',
              align: 'right',
              render: (_, s) => (
                <span className="num">
                  {s.redemption_amt ? yuan(s.redemption_amt) : '—'}
                  <div className="muted" style={{ fontSize: 12 }}>{!s.redemption_amt ? '不结算' : s.redemption_direction === 'platform_pays' ? '平台补贴' : '服务费'}</div>
                </span>
              ),
            },
            {
              title: '订场',
              key: 'book',
              align: 'right',
              render: (_, s) =>
                s.booking_qty ? (
                  <span className="num">
                    {yuan(s.booking_amt)} · {s.booking_qty} 笔<div className="muted" style={{ fontSize: 12 }}>佣金 {yuan(s.booking_commission_amt)}</div>
                  </span>
                ) : (
                  <span className="muted">—</span>
                ),
            },
            { title: '净额', dataIndex: 'net_amt', align: 'right', render: (v: number) => <b><NetAmount amt={v} /></b> },
            {
              title: '操作',
              key: 'op',
              width: 210,
              align: 'right',
              fixed: 'right',
              render: (_, s) => (
                <Space onClick={(e) => e.stopPropagation()}>
                  <Button size="small" onClick={() => update({ id: s.id })}>
                    查看
                  </Button>
                  {writable && <StatementActions s={s} size="small" />}
                </Space>
              ),
            },
          ]}
        />
      </Panel>
      <StatementDrawer id={openId} onClose={() => update({ id: null })} />
      {writable && <GenerateModal open={generating} onClose={() => setGenerating(false)} />}
    </>
  );
}

// ------------------------------------------------------------ actions

function StatementActions({ s, size }: { s: Statement; size?: 'small' | 'middle' }) {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const done = (text: string) => {
    toastOk(text);
    qc.invalidateQueries({ queryKey: ['statements'] });
    qc.invalidateQueries({ queryKey: ['settlement'] });
    qc.invalidateQueries({ queryKey: ['dashboard'] });
  };
  const confirm = useMutation({ mutationFn: () => merchantApi.confirmStatement(s.id), onSuccess: () => done(`${s.statement_no} 已确认`) });
  const paid = useMutation({ mutationFn: () => merchantApi.markStatementPaid(s.id), onSuccess: () => done(`${s.statement_no} 已标记付款`) });
  const net = s.net_amt === 0 ? '净额为 0，无需打款' : s.net_amt > 0 ? `应由「${s.merchant.name}」付给平台 ${yuan(s.net_amt)}` : `应由平台付给「${s.merchant.name}」${yuan(-s.net_amt)}`;

  if (s.status === 'draft')
    return (
      <Button
        size={size}
        type="primary"
        icon={<CheckOutlined />}
        loading={confirm.isPending}
        onClick={() =>
          modal.confirm({
            title: `确认结算单 ${s.statement_no}？`,
            content: `${s.merchant.name} · ${s.period_start} 至 ${s.period_end}：有效核销 ${s.redemption_qty} 次（风控剔除 ${s.voided_qty}）、订场 ${s.booking_qty} 笔。${net}。确认后金额锁定。`,
            okText: '确认结算单',
            cancelText: '取消',
            onOk: () => confirm.mutateAsync(),
          })
        }
      >
        确认
      </Button>
    );
  if (s.status === 'confirmed')
    return (
      <Button
        size={size}
        icon={<PayCircleOutlined />}
        loading={paid.isPending}
        onClick={() =>
          modal.confirm({
            title: '标记为已付款？',
            content: `${s.statement_no}：${net}。请在线下打款（或收款）完成后再标记，标记后不能撤销。`,
            okText: '已线下打款，标记',
            cancelText: '取消',
            onOk: () => paid.mutateAsync(),
          })
        }
      >
        标记已付款
      </Button>
    );
  return null;
}

function GenerateModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const qc = useQueryClient();
  const lastMonday = dayjs().startOf('day').subtract((dayjs().day() + 6) % 7, 'day').subtract(7, 'day');
  const [week, setWeek] = useState<Dayjs | null>(lastMonday);
  const monday = week ? week.subtract((week.day() + 6) % 7, 'day') : null;
  const gen = useMutation({
    mutationFn: (start: string) => merchantApi.generateStatements(start),
    onSuccess: (_r, start) => {
      toastOk(`已生成 ${start} 起这一周的结算单`);
      qc.invalidateQueries({ queryKey: ['statements'] });
      qc.invalidateQueries({ queryKey: ['settlement'] });
      onClose();
    },
  });
  const future = monday ? monday.add(7, 'day').isAfter(dayjs()) : true;
  return (
    <Modal
      open={open}
      title="手动生成结算单"
      okText="生成"
      cancelText="取消"
      okButtonProps={{ disabled: !monday || future }}
      confirmLoading={gen.isPending}
      onCancel={onClose}
      onOk={() => monday && gen.mutate(monday.format('YYYY-MM-DD'))}
    >
      <Space direction="vertical" style={{ width: '100%' }}>
        <span className="muted">结算单每周一 03:00 自动生成；定时任务漏跑时在这里补生成。某一周已经生成过会提示冲突。</span>
        <DatePicker picker="week" value={week} onChange={setWeek} style={{ width: 220 }} disabledDate={(d) => d.isAfter(dayjs())} />
        {monday && (
          <span className="num">
            结算周期：{monday.format('YYYY-MM-DD')}（周一）至 {monday.add(6, 'day').format('YYYY-MM-DD')}（周日）
          </span>
        )}
        {monday && future && <Alert type="warning" showIcon message="这一周还没结束，不能生成" />}
      </Space>
    </Modal>
  );
}

// ------------------------------------------------------------ detail

function StatementDrawer({ id, onClose }: { id: number | null; onClose: () => void }) {
  const { can } = useAuth();
  const who = useAdminNames();
  const [type, setType] = useState<'all' | 'redemption' | 'booking' | 'product' | 'voided'>('all');
  const q = useQuery({ queryKey: ['statements', 'detail', id], queryFn: () => merchantApi.statement(id!), enabled: id !== null });
  const s = q.data;
  const lines = (s?.lines ?? []).filter((l) => (type === 'all' ? true : type === 'voided' ? l.voided : l.type === type));
  const count = (t: typeof type) => (s?.lines ?? []).filter((l) => (t === 'voided' ? l.voided : l.type === t)).length;

  return (
    <Drawer
      open={id !== null}
      onClose={onClose}
      afterOpenChange={(o) => o && setType('all')}
      width={900}
      loading={q.isLoading}
      title={s ? `结算单 ${s.statement_no}` : '结算单'}
      extra={s && can('settlement.write') && <StatementActions s={s} />}
    >
      {s && (
        <Space direction="vertical" size={16} style={{ width: '100%' }}>
          <Row gutter={[10, 10]}>
            <Col xs={12} md={6}>
              <Tile v={num(s.redemption_qty)} l={`有效核销 · 剔除 ${s.voided_qty}`} />
            </Col>
            <Col xs={12} md={6}>
              <Tile v={yuan(s.redemption_amt)} l={s.redemption_direction === 'platform_pays' ? '核销补贴（平台付）' : '核销服务费（商户付）'} />
            </Col>
            <Col xs={12} md={6}>
              <Tile v={yuan(s.booking_amt - s.booking_commission_amt)} l={`订场 ${s.booking_qty} 笔 · 扣佣金后`} />
            </Col>
            <Col xs={12} md={6}>
              <div className="tile">
                <div className="tile-v">
                  <NetAmount amt={s.net_amt} />
                </div>
                <div className="tile-l">净额</div>
              </div>
            </Col>
          </Row>
          <Descriptions size="small" column={2} bordered>
            <Descriptions.Item label="商户">{s.merchant.name}</Descriptions.Item>
            <Descriptions.Item label="周期">
              <span className="num">
                {s.period_start} 至 {s.period_end}
              </span>
            </Descriptions.Item>
            <Descriptions.Item label="状态">
              <StatementStatusTag status={s.status} />
            </Descriptions.Item>
            <Descriptions.Item label="核销结算方向">{SETTLE_DIRECTION[s.redemption_direction] ?? s.redemption_direction}</Descriptions.Item>
            <Descriptions.Item label="订场">
              {s.booking_qty ? (
                <span className="num">
                  {yuan(s.booking_amt)} − 佣金 {yuan(s.booking_commission_amt)} = {yuan(s.booking_amt - s.booking_commission_amt)}（平台付商户）
                </span>
              ) : (
                '本期没有订场'
              )}
            </Descriptions.Item>
            {s.product_qty !== undefined && (
              <Descriptions.Item label="商品券（V2 第五批）" span={2}>
                {s.product_qty ? (
                  <span className="num">
                    核销 {s.product_qty} 次 · {yuan(s.product_amt ?? 0)} − 佣金 {yuan(s.product_commission_amt ?? 0)}
                    {s.product_subsidy_amt ? ` + 官方活动补贴 ${yuan(s.product_subsidy_amt)}` : ''} = {yuan((s.product_amt ?? 0) - (s.product_commission_amt ?? 0) + (s.product_subsidy_amt ?? 0))}（平台付商户）
                  </span>
                ) : (
                  '本期没有商品券核销'
                )}
              </Descriptions.Item>
            )}
            <Descriptions.Item label="确认">
              {s.confirmed_at ? (
                <span className="num">
                  {typeof s.confirmed_by === 'number' || s.confirmed_by ? who(s.confirmed_by) : '—'} · {dt(s.confirmed_at)}
                </span>
              ) : (
                '—'
              )}
            </Descriptions.Item>
            <Descriptions.Item label="付款" span="filled">{s.paid_at ? <span className="num">{dt(s.paid_at)}</span> : '—'}</Descriptions.Item>
          </Descriptions>
          <div>
            <div className="mer-h3-row">
              <h3 className="mer-h3">明细 · {s.lines.length} 条</h3>
              <Segmented
                size="small"
                value={type}
                onChange={(v) => setType(v as typeof type)}
                options={[
                  { label: `全部 ${s.lines.length}`, value: 'all' },
                  { label: `核销 ${count('redemption')}`, value: 'redemption' },
                  { label: `订场 ${count('booking')}`, value: 'booking' },
                  ...(count('product') ? [{ label: `商品券 ${count('product')}`, value: 'product' }] : []),
                  { label: `风控作废 ${count('voided')}`, value: 'voided' },
                ]}
              />
            </div>
            <Table<StatementLine>
              size="small"
              rowKey={(l) => `${l.type}-${l.ref_no}`}
              dataSource={lines}
              rowClassName={(l) => (l.voided ? 'row-disabled' : '')}
              pagination={{ pageSize: 15, showSizeChanger: false, showTotal: (t) => `共 ${t} 条` }}
              columns={[
                { title: '类型', dataIndex: 'type', render: (v: string, l) => <>{v === 'booking' ? <Tag bordered={false} color="purple">订场</Tag> : v === 'product' ? <Tag bordered={false} color="orange">商品券</Tag> : <Tag bordered={false}>核销</Tag>}{l.voided && <Tag bordered={false} color="error">风控作废 · 不结算</Tag>}</> },
                { title: '单号', dataIndex: 'ref_no', render: (v: string) => <span className="num">{v}</span> },
                { title: '用户', key: 'user', render: (_, l) => l.user?.nickname ?? '—' },
                { title: '金额', dataIndex: 'amount_amt', align: 'right', render: (v: number, l) => <span className="num">{l.voided ? <s>{yuan(v)}</s> : yuan(v)}</span> },
                { title: '时间', dataIndex: 'created_at', render: (v: string) => <span className="num">{dt(v)}</span> },
              ]}
            />
          </div>
        </Space>
      )}
    </Drawer>
  );
}
