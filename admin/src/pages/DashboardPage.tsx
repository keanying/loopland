import { useMemo, useState, type ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Button, Col, Empty, Row, Segmented, Skeleton, Table, Tag } from 'antd';
import { ArrowRightOutlined, CrownOutlined, ExclamationCircleOutlined, SafetyOutlined } from '@ant-design/icons';
import type { EChartsOption } from 'echarts';
import { api } from '../api/admin';
import type { DashboardTodo } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import Chart from '../components/Chart';
import { Delta, PageHeader, Panel } from '../components/ui';
import { bigNumber, change, dayjs } from '../utils/format';
import { TODO_TYPE } from '../utils/labels';
import { BRAND } from '../theme';

type Metric = 'active_users' | 'distance_km' | 'new_territories';
const METRIC: Record<Metric, { label: string; unit: string; title: string }> = {
  active_users: { label: '活跃', unit: '人', title: '活跃用户' },
  distance_km: { label: '跑量', unit: 'km', title: '跑量' },
  new_territories: { label: '新增领地', unit: '块', title: '新增领地' },
};

/** Map a todo `link` from the API onto a route of this console. */
function todoRoute(t: DashboardTodo): string {
  const link = t.link || '';
  if (link.startsWith('/')) return link;
  if (t.type === 'risk') return '/risk';
  if (t.type === 'refund') return '/plans?tab=orders&status=refund_requested';
  return '/plans?tab=orders&status=renew_failed';
}

function greeting(): string {
  const h = new Date().getHours();
  if (h < 6) return '夜深了';
  if (h < 11) return '早上好';
  if (h < 13) return '中午好';
  if (h < 18) return '下午好';
  return '晚上好';
}

const TODO_ICON: Record<string, ReactNode> = {
  risk: <SafetyOutlined />,
  refund: <CrownOutlined />,
  renew_failed: <CrownOutlined />,
};

function MetricCard({ value, unit, label, now, before, invert }: { value: number; unit?: string; label: string; now: number; before: number; invert?: boolean }) {
  const b = bigNumber(value);
  return (
    <div className="stat">
      <div className="stat-value num">
        {b.value}
        <span className="stat-unit">
          {b.unit}
          {unit}
        </span>
      </div>
      <div className="stat-label">{label}</div>
      <div className="stat-sub">
        <Delta ratio={change(now, before)} invert={invert} />
      </div>
    </div>
  );
}

export default function DashboardPage() {
  const navigate = useNavigate();
  const { admin } = useAuth();
  const { data, isLoading } = useQuery({ queryKey: ['dashboard'], queryFn: api.dashboard });
  const [metric, setMetric] = useState<Metric>('active_users');
  const [range, setRange] = useState<7 | 30>(7);
  const [asTable, setAsTable] = useState(false);
  const [todoFilter, setTodoFilter] = useState<string>('all');

  const series = useMemo(() => {
    if (!data) return [];
    const { days } = data.trend;
    const vals = data.trend[metric];
    return days.map((d, i) => ({ day: d, value: vals[i] ?? 0 })).slice(-range);
  }, [data, metric, range]);

  const option = useMemo<EChartsOption>(() => {
    const max = series.reduce((m, p) => Math.max(m, p.value), 0);
    const maxIdx = series.findIndex((p) => p.value === max);
    return {
      grid: { left: 48, right: 24, top: 36, bottom: 28 },
      tooltip: { trigger: 'axis', valueFormatter: (v) => `${Number(v).toLocaleString('zh-CN')} ${METRIC[metric].unit}` },
      xAxis: {
        type: 'category',
        data: series.map((p) => dayjs(p.day).format(range === 7 ? 'MM/DD ddd' : 'MM/DD')),
        axisLine: { lineStyle: { color: '#d8d8dc' } },
        axisTick: { show: false },
        axisLabel: { color: '#6a6a70' },
      },
      yAxis: {
        type: 'value',
        splitLine: { lineStyle: { type: 'dashed', color: '#e6e6ea' } },
        axisLabel: { color: '#8a8a90', formatter: (v: number) => (v >= 10000 ? `${v / 10000}万` : String(v)) },
      },
      series: [
        {
          type: 'line',
          smooth: true,
          data: series.map((p) => p.value),
          symbol: 'circle',
          symbolSize: range === 7 ? 9 : 5,
          itemStyle: { color: '#fff', borderColor: BRAND.ink, borderWidth: 2 },
          lineStyle: { color: BRAND.ink, width: 2 },
          areaStyle: { color: 'rgba(20,20,20,0.06)' },
          markPoint:
            maxIdx >= 0
              ? {
                  symbol: 'roundRect',
                  symbolSize: [82, 26],
                  symbolOffset: [0, -24],
                  itemStyle: { color: BRAND.ink },
                  label: { color: '#fff', fontWeight: 'bold', formatter: () => `${bigNumber(max).value}${bigNumber(max).unit}${METRIC[metric].unit}` },
                  data: [{ name: 'max', coord: [maxIdx, max] }],
                }
              : undefined,
        },
      ],
    };
  }, [series, metric, range]);

  if (isLoading || !data) {
    return (
      <>
        <PageHeader title="总览" sub={dayjs().format('YYYY 年 M 月 D 日 · dddd')} />
        <Skeleton active paragraph={{ rows: 12 }} />
      </>
    );
  }

  const { today, last_week: lw } = data;
  const todos = [...data.todos].sort((a, b) => a.priority - b.priority);
  const todoTypes = Array.from(new Set(todos.map((t) => t.type)));
  const shownTodos = todoFilter === 'all' ? todos : todos.filter((t) => t.type === todoFilter);
  const first = todos[0];
  const totalTodo = todos.reduce((s, t) => s + t.count, 0);

  return (
    <>
      <PageHeader title="总览" sub={dayjs().format('YYYY 年 M 月 D 日 · dddd')} />

      <Row gutter={[20, 20]}>
        <Col xs={24} xl={13}>
          <div className="greet">
            <h2>
              {greeting()}，{admin?.username}
            </h2>
            <div style={{ fontSize: 14, color: '#3a3a40', lineHeight: 1.8, maxWidth: 520 }}>
              今天有 <b>{today.pending_risk}</b> 起风控告警待处理
              {todos.length > 0 && (
                <>
                  ，共 <b>{totalTodo}</b> 项待办
                </>
              )}
              。今日新增领地 <b>{today.new_territories.toLocaleString('zh-CN')}</b> 块，较上周同期{' '}
              {lw.new_territories ? `${today.new_territories >= lw.new_territories ? '多' : '少'} ${Math.abs(Math.round((change(today.new_territories, lw.new_territories) ?? 0) * 100))}%` : '—'}。
            </div>
            <Button type="primary" size="large" style={{ marginTop: 20 }} disabled={!first} onClick={() => first && navigate(todoRoute(first))}>
              开始处理 <ArrowRightOutlined />
            </Button>
            <svg width="180" height="120" viewBox="0 0 180 120" style={{ position: 'absolute', right: 28, bottom: 18, opacity: 0.9 }} aria-hidden="true">
              <path d="M10 104 C 50 98, 120 110, 172 100" stroke={BRAND.ink} strokeWidth="2" fill="none" />
              <path d="M30 90 C 40 40, 90 30, 110 60 S 150 90, 160 40" stroke={BRAND.ink} strokeWidth="2" strokeDasharray="5 5" fill="none" />
              <circle cx="30" cy="90" r="6" fill={BRAND.lime} stroke={BRAND.ink} strokeWidth="2" />
              <path d="M150 20 l10 0 l0 22 l-10 -4 z" fill={BRAND.lavender} stroke={BRAND.ink} strokeWidth="2" />
              <line x1="150" y1="20" x2="150" y2="46" stroke={BRAND.ink} strokeWidth="2" />
            </svg>
          </div>
        </Col>
        <Col xs={24} xl={11}>
          <Row gutter={[16, 16]}>
            <Col xs={12}>
              <MetricCard value={today.active_users} label="今日活跃用户" now={today.active_users} before={lw.active_users} />
            </Col>
            <Col xs={12}>
              <MetricCard value={today.activities} unit="次" label="今日运动记录" now={today.activities} before={lw.activities} />
            </Col>
            <Col xs={12}>
              <MetricCard value={today.new_territories} unit="块" label="新增领地" now={today.new_territories} before={lw.new_territories} />
            </Col>
            <Col xs={12}>
              <MetricCard value={today.pending_risk} unit="条" label="待处理风控告警" now={today.pending_risk} before={lw.pending_risk} invert />
            </Col>
          </Row>
        </Col>

        <Col xs={24} xl={10}>
          <Panel
            title="待处理事项"
            extra={
              <Segmented
                size="small"
                value={todoFilter}
                onChange={(v) => setTodoFilter(String(v))}
                options={[
                  { label: `全部 ${todos.reduce((s, t) => s + t.count, 0)}`, value: 'all' },
                  ...todoTypes.map((t) => ({ label: `${TODO_TYPE[t] ?? t} ${todos.filter((x) => x.type === t).reduce((s, x) => s + x.count, 0)}`, value: t })),
                ]}
              />
            }
          >
            {shownTodos.length === 0 ? (
              <Empty description="没有待处理事项" />
            ) : (
              shownTodos.map((t, i) => (
                <div className="todo-row" key={`${t.type}-${i}`} style={i === 0 ? { borderTop: 0 } : undefined}>
                  <div className="todo-icon">{TODO_ICON[t.type] ?? <ExclamationCircleOutlined />}</div>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontWeight: 700, fontSize: 14 }}>{t.title}</div>
                    <div className="muted" style={{ fontSize: 12 }}>
                      {TODO_TYPE[t.type] ?? t.type} · {t.count} 项
                    </div>
                  </div>
                  <Tag color={t.priority <= 1 ? 'red' : t.priority === 2 ? 'gold' : 'default'} bordered={false}>
                    {t.priority <= 1 ? '高优先' : t.priority === 2 ? '中优先' : '低优先'}
                  </Tag>
                  <Button type="primary" onClick={() => navigate(todoRoute(t))}>
                    去处理
                  </Button>
                </div>
              ))
            )}
          </Panel>
        </Col>

        <Col xs={24} xl={14}>
          <Panel
            title={
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
                <h2 className="panel-title">趋势 · {METRIC[metric].title}</h2>
                <span className="panel-hint">单位：{METRIC[metric].unit}</span>
              </div>
            }
            extra={
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                <Segmented
                  size="small"
                  value={metric}
                  onChange={(v) => setMetric(v as Metric)}
                  options={(Object.keys(METRIC) as Metric[]).map((k) => ({ label: METRIC[k].label, value: k }))}
                />
                <Segmented
                  size="small"
                  value={range}
                  onChange={(v) => setRange(v as 7 | 30)}
                  options={[
                    { label: '近 7 天', value: 7 },
                    { label: '近 30 天', value: 30 },
                  ]}
                />
                <Button size="small" onClick={() => setAsTable((x) => !x)}>
                  {asTable ? '看图表' : '看表格'}
                </Button>
              </div>
            }
          >
            {asTable ? (
              <Table
                size="small"
                rowKey="day"
                pagination={false}
                scroll={{ y: 260 }}
                dataSource={[...series].reverse()}
                columns={[
                  { title: '日期', dataIndex: 'day', render: (d: string) => dayjs(d).format('YYYY-MM-DD ddd') },
                  { title: `${METRIC[metric].title}（${METRIC[metric].unit}）`, dataIndex: 'value', align: 'right', render: (v: number) => <span className="num">{v.toLocaleString('zh-CN')}</span> },
                ]}
              />
            ) : (
              <Chart option={option} style={{ height: 300 }} />
            )}
          </Panel>
        </Col>
      </Row>
    </>
  );
}
