// AI 用量 (docs/api/v2-3-AI.md 「管理端 · AI 用量」; admin + ops): daily calls / failures / tokens /
// cost, per-feature table, users at the weekly free limit, call log (metadata only, no content).
import { useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { Alert, Button, Col, Empty, Row, Segmented, Select, Skeleton, Table, Tag, Tooltip } from 'antd';
import type { EChartsOption } from 'echarts';
import { api, PAGE_SIZE } from '../api/admin';
import type { AICall, AIUsageDay, AIUsageFeature } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import Chart from '../components/Chart';
import { PageHeader, Panel, Stat } from '../components/ui';
import { BRAND } from '../theme';
import { bigNumber, dayjs, dt, num, yuan } from '../utils/format';
import { AI_FEATURE, AI_FEATURE_ORDER } from '../utils/labels';

type Metric = 'calls' | 'failed' | 'tokens' | 'cost';
const METRIC: Record<Metric, { label: string; unit: string }> = {
  calls: { label: '调用量', unit: '次' },
  failed: { label: '失败', unit: '次' },
  tokens: { label: 'Token', unit: 'Token' },
  cost: { label: '估算费用', unit: '元' },
};
/** Second series colour: the theme's info violet (readable on white, unlike the lavender accent). */
const SECOND = '#7B6AE0';

const featureName = (f: string) => AI_FEATURE[f]?.text ?? f;
const tokens = (n: number) => {
  const b = bigNumber(n);
  return `${b.value}${b.unit}`;
};
const ms = (v: number) => (v >= 1000 ? `${(v / 1000).toFixed(1)} s` : `${Math.round(v)} ms`);
const sumCost = (xs: { cost_fen: number | null }[]) => (xs.some((x) => x.cost_fen !== null) ? xs.reduce((s, x) => s + (x.cost_fen ?? 0), 0) : null);

function chartOption(days: AIUsageDay[], metric: Metric): EChartsOption {
  const x = days.map((d) => dayjs(d.date).format(days.length <= 7 ? 'MM/DD ddd' : 'MM/DD'));
  const axis = {
    xAxis: { type: 'category' as const, data: x, axisLine: { lineStyle: { color: '#d8d8dc' } }, axisTick: { show: false }, axisLabel: { color: '#6a6a70' } },
    yAxis: {
      type: 'value' as const,
      splitLine: { lineStyle: { type: 'dashed' as const, color: '#e6e6ea' } },
      axisLabel: { color: '#8a8a90', formatter: (v: number) => (metric === 'cost' ? `¥${v}` : v >= 10000 ? `${v / 10000}万` : String(v)) },
    },
  };
  const bar = { type: 'bar' as const, stack: 'a', barMaxWidth: 28 };
  if (metric === 'calls' || metric === 'failed') {
    // One measure per chart: failures are well under 1% of calls and would vanish in a stacked bar.
    const failed = metric === 'failed';
    return {
      grid: { left: 56, right: 24, top: 24, bottom: 28 },
      tooltip: {
        trigger: 'axis',
        axisPointer: { type: 'shadow' },
        formatter: (ps) => {
          const p = (Array.isArray(ps) ? ps[0] : ps) as { dataIndex: number; name: string };
          const d = days[p.dataIndex];
          const rate = d.calls ? ((d.failed / d.calls) * 100).toFixed(2) : '0';
          return `${p.name}<br/>调用 <b>${d.calls.toLocaleString('zh-CN')}</b> 次<br/>失败 <b>${d.failed.toLocaleString('zh-CN')}</b> 次（${rate}%）`;
        },
      },
      ...axis,
      series: [
        {
          ...bar,
          name: failed ? '失败' : '调用',
          data: days.map((d) => (failed ? d.failed : d.calls)),
          itemStyle: { color: failed ? BRAND.red : BRAND.ink, borderRadius: [4, 4, 0, 0] },
          label: failed ? { show: true, position: 'top', color: '#3a3a40', fontSize: 11, formatter: (x: { value?: unknown }) => (Number(x.value) ? String(x.value) : '') } : undefined,
        },
      ],
    };
  }
  if (metric === 'cost') {
    return {
      grid: { left: 56, right: 24, top: 24, bottom: 28 },
      tooltip: { trigger: 'axis', valueFormatter: (v) => (v === null || v === undefined || v === '-' ? '未填单价' : `¥${Number(v).toFixed(2)}`) },
      ...axis,
      series: [
        {
          type: 'line',
          name: '估算费用',
          smooth: true,
          symbol: 'circle',
          symbolSize: 8,
          data: days.map((d) => (d.cost_fen === null ? '-' : +(d.cost_fen / 100).toFixed(2))),
          itemStyle: { color: '#fff', borderColor: BRAND.ink, borderWidth: 2 },
          lineStyle: { color: BRAND.ink, width: 2 },
          areaStyle: { color: 'rgba(20,20,20,0.06)' },
        },
      ],
    };
  }
  const [a, b] = [
    { name: '输入 Token', data: days.map((d) => d.prompt_tokens), color: BRAND.ink },
    { name: '输出 Token', data: days.map((d) => d.completion_tokens), color: SECOND },
  ];
  return {
    grid: { left: 56, right: 24, top: 40, bottom: 28 },
    legend: { top: 0, right: 0, icon: 'roundRect', itemWidth: 12, itemHeight: 12, textStyle: { color: '#3a3a40' } },
    tooltip: { trigger: 'axis', axisPointer: { type: 'shadow' }, valueFormatter: (v) => `${Number(v).toLocaleString('zh-CN')} ${METRIC[metric].unit}` },
    ...axis,
    series: [
      { ...bar, name: a.name, data: a.data, itemStyle: { color: a.color, borderColor: '#fff', borderWidth: 1 } },
      { ...bar, name: b.name, data: b.data, itemStyle: { color: b.color, borderRadius: [4, 4, 0, 0], borderColor: '#fff', borderWidth: 1 } },
    ],
  };
}

export default function AIUsagePage() {
  const { can } = useAuth();
  const [params, setParams] = useSearchParams();
  const days = [7, 14, 30].includes(Number(params.get('days'))) ? Number(params.get('days')) : 7;
  const feature = params.get('feature') ?? '';
  const status = params.get('status') ?? '';
  const page = Number(params.get('page') ?? 1);
  const [metric, setMetric] = useState<Metric>('calls');
  const [asTable, setAsTable] = useState(false);

  const set = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null || v === '') next.delete(k);
      else next.set(k, v);
    }
    setParams(next, { replace: true });
  };

  const usage = useQuery({ queryKey: ['ai', 'usage', days], queryFn: () => api.aiUsage(days), placeholderData: keepPreviousData });
  const calls = useQuery({
    queryKey: ['ai', 'calls', feature, status, page],
    queryFn: () => api.aiCalls({ feature, status, page }),
    placeholderData: keepPreviousData,
  });

  const u = usage.data;
  const daily = useMemo(() => u?.days ?? [], [u]);
  const option = useMemo(() => chartOption(daily, metric), [daily, metric]);
  const features = useMemo(() => {
    const order = (f: string) => {
      const i = (AI_FEATURE_ORDER as readonly string[]).indexOf(f);
      return i < 0 ? 99 : i;
    };
    return [...(u?.by_feature ?? [])].sort((a, b) => order(a.feature) - order(b.feature));
  }, [u]);

  const total = daily.reduce((s, d) => s + d.calls, 0);
  const failed = daily.reduce((s, d) => s + d.failed, 0);
  const tok = daily.reduce((s, d) => s + d.prompt_tokens + d.completion_tokens, 0);
  const cost = sumCost(daily);
  const maxCalls = Math.max(1, ...features.map((f) => f.calls));

  return (
    <>
      <PageHeader
        title="AI 用量"
        sub="各 AI 功能的调用量、Token、失败率、耗时和估算费用；调用记录只有元数据，不含对话内容"
        extra={
          <Segmented
            size="large"
            value={days}
            onChange={(v) => set({ days: v === 7 ? null : String(v), page: null })}
            options={[
              { label: '近 7 天', value: 7 },
              { label: '近 14 天', value: 14 },
              { label: '近 30 天', value: 30 },
            ]}
          />
        }
      />

      {usage.isError && <Alert type="error" showIcon message={`加载失败：${(usage.error as Error).message}`} style={{ marginBottom: 16 }} />}
      {!u ? (
        <Skeleton active paragraph={{ rows: 12 }} />
      ) : (
        <>
          <Row gutter={[16, 16]}>
            <Col xs={12} xl={5}>
              <Stat value={bigNumber(total).value} unit={`${bigNumber(total).unit}次`} label="调用次数" sub={`近 ${days} 天，日均 ${num(total / Math.max(1, daily.length), 0)} 次`} />
            </Col>
            <Col xs={12} xl={5}>
              <Stat value={total ? ((failed / total) * 100).toFixed(2) : '0'} unit="%" label="失败率" sub={`失败 ${num(failed)} 次（含超时），不扣用户次数`} />
            </Col>
            <Col xs={12} xl={5}>
              <Stat value={bigNumber(tok).value} unit={`${bigNumber(tok).unit} Token`} label="Token 用量" sub={`输入 ${tokens(daily.reduce((s, d) => s + d.prompt_tokens, 0))} · 输出 ${tokens(daily.reduce((s, d) => s + d.completion_tokens, 0))}`} />
            </Col>
            <Col xs={12} xl={5}>
              <Stat
                value={cost === null ? '—' : yuan(cost)}
                label="估算费用"
                sub={
                  cost === null ? (
                    can('settings.providers') ? <Link to="/settings/providers">未填单价，去「系统配置 → AI 大模型」填写</Link> : '未填单价，请管理员在系统配置里填写'
                  ) : (
                    '按「AI 大模型」里填的单价估算，以账单为准'
                  )
                }
              />
            </Col>
            <Col xs={24} xl={4}>
              <Stat value={num(u.quota.users_hit_limit_this_week)} unit="人" label="本周用完免费次数" sub="免费用户每周助手对话上限，周一 00:00 重置" />
            </Col>
          </Row>

          <Row gutter={[20, 20]}>
            <Col span={24}>
              <Panel
                title="每日用量"
                extra={
                  <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                    <Segmented size="small" value={metric} onChange={(v) => setMetric(v as Metric)} options={(Object.keys(METRIC) as Metric[]).map((k) => ({ label: METRIC[k].label, value: k }))} />
                    <Button size="small" onClick={() => setAsTable((x) => !x)}>
                      {asTable ? '看图表' : '看表格'}
                    </Button>
                  </div>
                }
              >
                {daily.length === 0 ? (
                  <Empty description="这段时间没有 AI 调用" />
                ) : asTable ? (
                  <Table<AIUsageDay>
                    size="small"
                    rowKey="date"
                    pagination={false}
                    scroll={{ y: 300 }}
                    dataSource={[...daily].reverse()}
                    columns={[
                      { title: '日期', dataIndex: 'date', render: (d: string) => dayjs(d).format('YYYY-MM-DD ddd') },
                      { title: '调用', dataIndex: 'calls', align: 'right', render: (v: number) => <span className="num">{num(v)}</span> },
                      { title: '失败', dataIndex: 'failed', align: 'right', render: (v: number, d) => <span className={`num${v ? ' danger-text' : ''}`}>{num(v)}{d.calls ? <span className="muted">（{((v / d.calls) * 100).toFixed(2)}%）</span> : null}</span> },
                      { title: '输入 Token', dataIndex: 'prompt_tokens', align: 'right', render: (v: number) => <span className="num">{num(v)}</span> },
                      { title: '输出 Token', dataIndex: 'completion_tokens', align: 'right', render: (v: number) => <span className="num">{num(v)}</span> },
                      { title: '估算费用', dataIndex: 'cost_fen', align: 'right', render: (v: number | null) => <span className="num">{v === null ? <span className="muted">未填单价</span> : yuan(v)}</span> },
                    ]}
                  />
                ) : metric === 'cost' && daily.every((d) => d.cost_fen === null) ? (
                  <Empty description="没有填写单价，无法估算费用" style={{ padding: 60 }} />
                ) : (
                  <Chart option={option} style={{ height: 300 }} />
                )}
              </Panel>
            </Col>

            <Col span={24}>
              <Panel title="各功能用量" extra={<span className="panel-hint">近 {days} 天 · 点功能名查看调用记录</span>}>
                <Table<AIUsageFeature>
                  rowKey="feature"
                  size="small"
                  pagination={false}
                  scroll={{ x: 900 }}
                  dataSource={features}
                  locale={{ emptyText: <Empty description="没有调用" /> }}
                  summary={(rows) =>
                    rows.length > 1 ? (
                      <Table.Summary.Row>
                        <Table.Summary.Cell index={0}>
                          <b>合计</b>
                        </Table.Summary.Cell>
                        <Table.Summary.Cell index={1} align="right">
                          <b className="num">{num(rows.reduce((s, r) => s + r.calls, 0))}</b>
                        </Table.Summary.Cell>
                        <Table.Summary.Cell index={2} />
                        <Table.Summary.Cell index={3} align="right">
                          <b className="num">{num(rows.reduce((s, r) => s + r.failed, 0))}</b>
                        </Table.Summary.Cell>
                        <Table.Summary.Cell index={4} />
                        <Table.Summary.Cell index={5} align="right">
                          <b className="num">{tokens(rows.reduce((s, r) => s + r.prompt_tokens, 0))}</b>
                        </Table.Summary.Cell>
                        <Table.Summary.Cell index={6} align="right">
                          <b className="num">{tokens(rows.reduce((s, r) => s + r.completion_tokens, 0))}</b>
                        </Table.Summary.Cell>
                        <Table.Summary.Cell index={7} align="right">
                          <b className="num">{(() => {
                            const c = sumCost([...rows]);
                            return c === null ? '—' : yuan(c);
                          })()}</b>
                        </Table.Summary.Cell>
                      </Table.Summary.Row>
                    ) : null
                  }
                  columns={[
                    {
                      title: '功能',
                      dataIndex: 'feature',
                      render: (f: string) => (
                        <div>
                          <a onClick={() => set({ feature: f, page: null })}>
                            <b>{featureName(f)}</b>
                          </a>
                          <div className="muted" style={{ fontSize: 12 }}>
                            {AI_FEATURE[f]?.hint ?? f}
                          </div>
                        </div>
                      ),
                    },
                    { title: '调用', dataIndex: 'calls', align: 'right', render: (v: number) => <span className="num">{num(v)}</span> },
                    {
                      title: '占比',
                      key: 'share',
                      width: 140,
                      render: (_, r) => (
                        <div className="bar-track" title={`${total ? ((r.calls / total) * 100).toFixed(1) : 0}%`}>
                          <div className="bar-fill" style={{ width: `${(r.calls / maxCalls) * 100}%` }} />
                        </div>
                      ),
                    },
                    {
                      title: '失败',
                      dataIndex: 'failed',
                      align: 'right',
                      render: (v: number, r) => (
                        <span className={`num${r.calls && v / r.calls >= 0.02 ? ' danger-text' : ''}`}>
                          {num(v)}
                          <span className="muted">（{r.calls ? ((v / r.calls) * 100).toFixed(2) : '0'}%）</span>
                        </span>
                      ),
                    },
                    { title: '平均耗时', dataIndex: 'avg_latency_ms', align: 'right', render: (v: number) => <span className="num">{ms(v)}</span> },
                    { title: '输入 Token', dataIndex: 'prompt_tokens', align: 'right', render: (v: number) => <span className="num">{tokens(v)}</span> },
                    { title: '输出 Token', dataIndex: 'completion_tokens', align: 'right', render: (v: number) => <span className="num">{tokens(v)}</span> },
                    { title: '估算费用', dataIndex: 'cost_fen', align: 'right', render: (v: number | null) => <span className="num">{v === null ? <span className="muted">未填单价</span> : yuan(v)}</span> },
                  ]}
                />
              </Panel>
            </Col>
          </Row>
        </>
      )}

      <Panel
        title="调用记录"
        style={{ marginTop: 20, height: 'auto' }}
        extra={
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
            <Select
              size="small"
              value={feature}
              style={{ width: 140 }}
              aria-label="按功能筛选"
              onChange={(v) => set({ feature: v || null, page: null })}
              options={[{ value: '', label: '全部功能' }, ...AI_FEATURE_ORDER.map((f) => ({ value: f, label: AI_FEATURE[f].text }))]}
            />
            <Segmented
              size="small"
              value={status}
              onChange={(v) => set({ status: String(v) || null, page: null })}
              options={[
                { label: '全部', value: '' },
                { label: '成功', value: 'ok' },
                { label: '失败', value: 'failed' },
              ]}
            />
          </div>
        }
      >
        <div className="panel-hint" style={{ marginBottom: 8 }}>
          只记录功能、用户、模型、Token、耗时和错误，不含提问和回答内容；投诉核查请到用户详情里「查看 AI 对话」（仅管理员，记审计）。
        </div>
        <Table<AICall>
          rowKey="id"
          size="small"
          loading={calls.isFetching && !calls.data}
          dataSource={calls.data?.items ?? []}
          scroll={{ x: 960 }}
          locale={{ emptyText: <Empty description="没有符合条件的调用" /> }}
          pagination={{
            current: page,
            pageSize: PAGE_SIZE,
            total: calls.data?.total ?? 0,
            showSizeChanger: false,
            showTotal: (n) => `共 ${num(n)} 条`,
            onChange: (p) => set({ page: p === 1 ? null : String(p) }),
          }}
          columns={[
            { title: '时间', dataIndex: 'created_at', width: 150, render: (v: string) => <span className="num">{dt(v, 'MM-DD HH:mm:ss')}</span> },
            { title: '功能', dataIndex: 'feature', render: (f: string) => <Tag bordered={false}>{featureName(f)}</Tag> },
            {
              title: '用户',
              dataIndex: 'user',
              render: (x: AICall['user']) =>
                x ? (
                  <Link to={`/users?id=${x.id}`}>
                    {x.nickname} <span className="muted num">#{x.id}</span>
                  </Link>
                ) : (
                  <span className="muted">系统</span>
                ),
            },
            { title: '模型', dataIndex: 'model', render: (v: string) => <span style={{ fontFamily: 'ui-monospace, Menlo, monospace', fontSize: 12 }}>{v}</span> },
            {
              title: '状态',
              dataIndex: 'status',
              render: (v: string, r) =>
                v === 'ok' ? (
                  <Tag bordered={false} color="success">
                    成功
                  </Tag>
                ) : (
                  <Tooltip title={r.error}>
                    <Tag bordered={false} color="error">
                      失败
                    </Tag>
                    <span className="danger-text" style={{ fontSize: 12 }}>
                      {(r.error ?? '').slice(0, 24)}
                      {(r.error ?? '').length > 24 ? '…' : ''}
                    </span>
                  </Tooltip>
                ),
            },
            { title: '输入 / 输出 Token', key: 'tok', align: 'right', render: (_, r) => <span className="num">{num(r.prompt_tokens)} / {num(r.completion_tokens)}</span> },
            { title: '耗时', dataIndex: 'latency_ms', align: 'right', render: (v: number) => <span className={`num${v >= 10000 ? ' danger-text' : ''}`}>{ms(v)}</span> },
          ]}
        />
      </Panel>
    </>
  );
}
