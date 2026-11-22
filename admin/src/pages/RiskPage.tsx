import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Button, Col, Drawer, Empty, Input, Modal, Pagination, Row, Segmented, Select, Skeleton, Slider, Space, Switch, Tag, Tooltip } from 'antd';
import {
  AimOutlined,
  ApiOutlined,
  DashboardOutlined,
  DisconnectOutlined,
  EnvironmentOutlined,
  MobileOutlined,
  RiseOutlined,
  WarningFilled,
} from '@ant-design/icons';
import type { EChartsOption } from 'echarts';
import { api, PAGE_SIZE } from '../api/admin';
import type { RiskAction, RiskAlert, RiskAlertDetail, RiskResolution, RiskRules, RiskStatus, RiskType } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import Chart from '../components/Chart';
import { Avatar, PageHeader, Panel, Stat } from '../components/ui';
import { ago, area, dayjs, dt, km } from '../utils/format';
import { RISK_ACTION, RISK_TYPE, SPORT_LABEL } from '../utils/labels';
import { toastOk } from '../utils/notify';
import { BRAND } from '../theme';

const TYPE_ICON: Record<RiskType, ReactNode> = {
  speed: <DashboardOutlined />,
  mock_location: <EnvironmentOutlined />,
  teleport: <RiseOutlined />,
  missing_device_data: <DisconnectOutlined />,
  multi_account: <MobileOutlined />,
  device_tamper: <ApiOutlined />,
};

function resolutionText(r: RiskResolution, note?: string | null): string {
  if (!r) return '';
  if (typeof r === 'string') return [RISK_ACTION[r as RiskAction]?.text ?? r, note].filter(Boolean).join(' · ');
  const a = r.action ? RISK_ACTION[r.action as RiskAction]?.text ?? r.action : '已处理';
  const who = typeof r.admin === 'string' ? r.admin : r.admin?.username;
  return [a, r.note, who].filter(Boolean).join(' · ');
}

export default function RiskPage() {
  const [params, setParams] = useSearchParams();
  const status = (params.get('status') as RiskStatus) || 'open';
  const type = (params.get('type') as RiskType | null) ?? '';
  const page = Number(params.get('page') ?? 1);
  const alertParam = params.get('alert') ? Number(params.get('alert')) : null;

  const update = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null || v === '') next.delete(k);
      else next.set(k, v);
    }
    setParams(next, { replace: true });
  };

  const list = useQuery({
    queryKey: ['risk', 'alerts', status, type, page],
    queryFn: () => api.riskAlerts({ status, type, page }),
    placeholderData: (prev) => prev,
  });
  const openCount = useQuery({ queryKey: ['risk', 'alerts', 'open', '', 1], queryFn: () => api.riskAlerts({ status: 'open', page: 1 }) });
  const resolvedCount = useQuery({ queryKey: ['risk', 'alerts', 'resolved', '', 1], queryFn: () => api.riskAlerts({ status: 'resolved', page: 1 }) });

  const items = useMemo(() => [...(list.data?.items ?? [])].sort((a, b) => b.confidence - a.confidence), [list.data]);
  const selectedId = alertParam ?? items[0]?.id ?? null;
  const high = (openCount.data?.items ?? []).filter((a) => a.confidence >= 0.9).length;
  // 判定规则放在抽屉里：页面本身正好一屏，告警列表贴到屏幕底部
  const [rulesOpen, setRulesOpen] = useState(false);

  return (
    <>
      <PageHeader
        title="风控防作弊"
        sub="疑似作弊的运动不发能量、不圈地，人工确认后再结算或作废"
        extra={<Button onClick={() => setRulesOpen(true)}>判定规则</Button>}
      />
      <Row gutter={[16, 16]}>
        <Col xs={12} xl={6}>
          <Stat value={openCount.data?.total ?? '—'} label="待人工确认" />
        </Col>
        <Col xs={12} xl={6}>
          <Stat value={high} label="高置信（≥ 0.9）待确认" sub="仅统计第一页" />
        </Col>
        <Col xs={12} xl={6}>
          <Stat value={resolvedCount.data?.total ?? '—'} label="已处理告警" />
        </Col>
        <Col xs={12} xl={6}>
          <RulesSummary />
        </Col>
      </Row>

      <Row gutter={[20, 20]} className="split-fill">
        <Col xs={24} lg={9}>
          <Panel
            title="告警"
            extra={
              <Space>
                <Select
                  size="small"
                  style={{ width: 130 }}
                  value={type}
                  onChange={(v) => update({ type: v || null, page: null, alert: null })}
                  options={[{ label: '全部类型', value: '' }, ...Object.entries(RISK_TYPE).map(([value, label]) => ({ value, label }))]}
                />
                <Segmented
                  size="small"
                  value={status}
                  onChange={(v) => update({ status: v === 'open' ? null : String(v), page: null, alert: null })}
                  options={[
                    { label: '待处理', value: 'open' },
                    { label: '已处理', value: 'resolved' },
                  ]}
                />
              </Space>
            }
          >
            <div className="panel-hint" style={{ marginTop: -6, marginBottom: 8 }}>
              按置信度从高到低
            </div>
            <div className="split-scroll">
            {list.isLoading ? (
              <Skeleton active />
            ) : items.length === 0 ? (
              <Empty description={status === 'open' ? '没有待处理的告警' : '暂无记录'} />
            ) : (
              items.map((a) => (
                <div key={a.id} className={`alert-item${a.id === selectedId ? ' active' : ''}`} onClick={() => update({ alert: String(a.id) })} role="button" tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && update({ alert: String(a.id) })}>
                  <div className="alert-icon">{TYPE_ICON[a.type] ?? <WarningFilled />}</div>
                  <div style={{ minWidth: 0, flex: 1 }}>
                    <div>
                      <b>{RISK_TYPE[a.type] ?? a.type}</b>{' '}
                      <span className={a.confidence >= 0.9 ? 'danger-text num' : 'muted num'} style={{ fontSize: 12 }}>
                        置信 {a.confidence.toFixed(2)}
                      </span>
                    </div>
                    <div style={{ fontSize: 12, color: '#3a3a40', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      {a.user.nickname} · {a.detail}
                    </div>
                    <div style={{ fontSize: 12, marginTop: 2 }}>
                      <b>{a.status === 'open' ? '待确认' : resolutionText(a.resolution, a.note) || '已处理'}</b> <span className="muted">· {ago(a.created_at)}</span>
                    </div>
                  </div>
                </div>
              ))
            )}
            </div>
            {(list.data?.total ?? 0) > PAGE_SIZE && (
              <Pagination
                size="small"
                style={{ marginTop: 12, textAlign: 'right' }}
                current={page}
                pageSize={PAGE_SIZE}
                total={list.data?.total}
                showSizeChanger={false}
                onChange={(p) => update({ page: String(p), alert: null })}
              />
            )}
          </Panel>
        </Col>
        <Col xs={24} lg={15}>
          {selectedId ? <AlertDetail id={selectedId} /> : <Panel grey><Empty description="选择左侧的一条告警" style={{ padding: 80 }} /></Panel>}
        </Col>
      </Row>

      <Drawer title="判定规则" width={760} open={rulesOpen} onClose={() => setRulesOpen(false)} destroyOnHidden>
        <RulesEditor />
      </Drawer>
    </>
  );
}

function RulesSummary() {
  const rules = useQuery({ queryKey: ['risk', 'rules'], queryFn: api.riskRules });
  const r = rules.data;
  return <Stat value={r ? `${r.run_max_kmh}` : '—'} unit="km/h" label="跑步最大均速" sub={r ? `骑行 ${r.ride_max_kmh} · 瞬移 ${r.teleport_m} m` : undefined} />;
}

// ------------------------------------------------------------ detail

type FullDetail = Required<RiskAlertDetail>;

/** The server omits the evidence fields when an alert has no activity. */
function withDefaults(d: RiskAlertDetail): FullDetail {
  return {
    alert: d.alert,
    history: d.history ?? [],
    activity: d.activity ?? null,
    speeds: d.speeds ?? [],
    teleports: d.teleports ?? [],
    device: d.device ?? null,
    sources: d.sources ?? { gps: 0, network: 0, mock: 0 },
    cadence_avg: d.cadence_avg ?? null,
    hr_avg: d.hr_avg ?? null,
    same_device_accounts: d.same_device_accounts ?? 0,
  };
}

function SpeedChart({ d, threshold }: { d: FullDetail; threshold: number }) {
  const t0 = d.speeds[0]?.t ?? 0;
  const option: EChartsOption = {
    grid: { left: 36, right: 16, top: 30, bottom: 26 },
    tooltip: { trigger: 'axis', valueFormatter: (v) => `${v} km/h` },
    xAxis: {
      type: 'category',
      data: d.speeds.map((p) => {
        const sec = Math.round((p.t - t0) / 1000);
        return `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, '0')}`;
      }),
      axisTick: { show: false },
      axisLine: { lineStyle: { color: '#d8d8dc' } },
      axisLabel: { color: '#8a8a90' },
    },
    yAxis: { type: 'value', name: 'km/h', nameTextStyle: { color: '#8a8a90' }, splitLine: { lineStyle: { type: 'dashed', color: '#ececef' } }, axisLabel: { color: '#8a8a90' } },
    series: [
      {
        type: 'line',
        data: d.speeds.map((p) => ({
          value: p.kmh,
          itemStyle: p.over ? { color: BRAND.red, borderColor: '#fff', borderWidth: 2 } : { color: '#fff', borderColor: BRAND.ink, borderWidth: 1.5 },
          symbolSize: p.over ? 10 : 6,
        })),
        symbol: 'circle',
        lineStyle: { color: BRAND.ink, width: 1.8 },
        areaStyle: { color: 'rgba(20,20,20,0.05)' },
        markLine: {
          symbol: 'none',
          lineStyle: { color: BRAND.red, type: 'dashed', width: 1.5 },
          label: { formatter: `阈值 ${threshold} km/h`, color: BRAND.red, position: 'insideEndTop' },
          data: [{ yAxis: threshold }],
        },
      },
    ],
  };
  return <Chart option={option} style={{ height: 220 }} />;
}

function TrackSketch({ d }: { d: FullDetail }) {
  const coords = d.activity?.track?.coordinates ?? [];
  const W = 300;
  const H = 220;
  const pts = [...coords, ...d.teleports.flatMap((t) => [[t.from.lng, t.from.lat], [t.to.lng, t.to.lat]])];
  if (pts.length < 2) return <Empty description="没有轨迹" image={Empty.PRESENTED_IMAGE_SIMPLE} />;
  const xs = pts.map((p) => p[0]);
  const ys = pts.map((p) => p[1]);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const k = Math.cos((((minY + maxY) / 2) * Math.PI) / 180);
  const s = Math.min((W - 30) / Math.max((maxX - minX) * k, 1e-9), (H - 30) / Math.max(maxY - minY, 1e-9));
  const ox = (W - (maxX - minX) * k * s) / 2;
  const oy = (H - (maxY - minY) * s) / 2;
  const P = (lng: number, lat: number) => [ox + (lng - minX) * k * s, oy + (maxY - lat) * s] as const;
  const path = coords.map(([lng, lat], i) => `${i ? 'L' : 'M'}${P(lng, lat).map((n) => n.toFixed(1)).join(' ')}`).join(' ');
  const start = coords[0] ? P(coords[0][0], coords[0][1]) : null;
  const end = coords.length ? P(coords[coords.length - 1][0], coords[coords.length - 1][1]) : null;
  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" height={H} role="img" aria-label="轨迹示意">
      <defs>
        <pattern id="tgrid" width="30" height="30" patternUnits="userSpaceOnUse">
          <path d="M 30 0 L 0 0 0 30" fill="none" stroke="#efeff2" strokeWidth="1" />
        </pattern>
      </defs>
      <rect width={W} height={H} fill="url(#tgrid)" />
      <path d={path} fill="none" stroke={BRAND.ink} strokeWidth={2} strokeLinejoin="round" />
      {d.teleports.map((t, i) => {
        const a = P(t.from.lng, t.from.lat);
        const b = P(t.to.lng, t.to.lat);
        return (
          <g key={i}>
            <line x1={a[0]} y1={a[1]} x2={b[0]} y2={b[1]} stroke={BRAND.red} strokeWidth={3} strokeDasharray="6 4" />
            <text x={(a[0] + b[0]) / 2} y={(a[1] + b[1]) / 2 - 8} fontSize={11} fill={BRAND.red} textAnchor="middle" fontWeight={700}>
              {t.distance_m} m / {t.gap_s} s
            </text>
          </g>
        );
      })}
      {start && <circle cx={start[0]} cy={start[1]} r={5} fill="#fff" stroke={BRAND.ink} strokeWidth={2} />}
      {end && <circle cx={end[0]} cy={end[1]} r={5} fill={BRAND.ink} />}
    </svg>
  );
}

function Evidence({ label, value, warn, sub }: { label: string; value: ReactNode; warn?: boolean; sub?: ReactNode }) {
  return (
    <div className={`tile${warn ? ' warn' : ''}`} style={{ height: '100%' }}>
      <div className="tile-l" style={{ marginTop: 0, marginBottom: 4 }}>
        {label}
      </div>
      <div style={{ fontWeight: 700, fontSize: 14, color: warn ? BRAND.red : undefined }}>
        {warn && <WarningFilled style={{ marginRight: 4 }} />}
        {value}
      </div>
      {sub && (
        <div className="muted" style={{ fontSize: 11, marginTop: 2 }}>
          {sub}
        </div>
      )}
    </div>
  );
}

function AlertDetail({ id }: { id: number }) {
  const qc = useQueryClient();
  const { can } = useAuth();
  const q = useQuery({ queryKey: ['risk', 'alert', id], queryFn: () => api.riskAlert(id) });
  const rules = useQuery({ queryKey: ['risk', 'rules'], queryFn: api.riskRules });
  const [pending, setPending] = useState<RiskAction | null>(null);
  const [note, setNote] = useState('');

  const resolve = useMutation({
    mutationFn: ({ action, note: n }: { action: RiskAction; note: string }) => api.resolveAlert(id, action, n),
    onSuccess: (a) => {
      qc.setQueryData(['risk', 'alert', id], (old: RiskAlertDetail | undefined) => (old ? { ...old, alert: a } : old));
      qc.invalidateQueries({ queryKey: ['risk', 'alerts'] });
      qc.invalidateQueries({ queryKey: ['dashboard'] });
      setPending(null);
      toastOk(`已处理：${RISK_ACTION[a.resolution && typeof a.resolution === 'object' ? (a.resolution.action as RiskAction) : pending ?? 'warn']?.text ?? '完成'}`);
    },
  });

  if (!q.data) return <Panel grey>{q.isError ? <Empty description="加载失败" /> : <Skeleton active paragraph={{ rows: 12 }} />}</Panel>;
  const d = withDefaults(q.data);
  const a: RiskAlert = d.alert;
  const act = d.activity;
  const sport = act?.sport ?? 'run';
  const r = rules.data;
  const threshold = r ? ((r as unknown as Record<string, number>)[`${sport}_max_kmh`] ?? r.run_max_kmh) : 20;
  const srcTotal = d.sources.gps + d.sources.network + d.sources.mock || 1;
  const mainSrc = d.sources.mock > 0 ? `模拟 ${Math.round((d.sources.mock / srcTotal) * 100)}%` : d.sources.network > d.sources.gps ? '网络定位为主' : 'GPS';
  const open = a.status === 'open';
  const canResolve = can('risk.resolve') && open;

  return (
    <Panel grey style={{ height: 'auto' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 14 }}>
        <Avatar name={a.user.nickname} size="lg" />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 18, fontWeight: 800 }}>
            {RISK_TYPE[a.type] ?? a.type} · <Link to={`/users?id=${a.user.id}`}>{a.user.nickname}</Link>
          </div>
          <div className="muted" style={{ fontSize: 12 }}>
            {act
              ? `${SPORT_LABEL[act.sport] ?? act.sport} · ${dayjs(act.started_at).format('MM/DD HH:mm')} · ${km(act.distance_m)} · 圈地 ${area(act.claimed_area_m2)} · 记录 #${act.id}`
              : `运动 #${a.activity_id}`}{' '}
            · 置信 {a.confidence.toFixed(2)}
          </div>
        </div>
        <Tag bordered={false} color={open ? 'warning' : 'default'} style={{ fontSize: 13, padding: '2px 10px' }}>
          {open ? '待确认' : '已处理'}
        </Tag>
      </div>
      <div style={{ fontSize: 13, marginBottom: 12 }}>{a.detail}</div>

      <Row gutter={[12, 12]}>
        {d.activity ? (
          <>
          <Col xs={24} lg={14}>
            <div className="panel" style={{ padding: 14 }}>
              <b>速度曲线</b>
              <span className="muted" style={{ fontSize: 12, marginLeft: 8 }}>
                红点为超过阈值的采样
              </span>
              {d.speeds.length ? <SpeedChart d={d} threshold={threshold} /> : <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="无速度数据" />}
            </div>
          </Col>
          <Col xs={24} lg={10}>
            <div className="panel" style={{ padding: 14 }}>
              <b>轨迹</b>
              <TrackSketch d={d} />
              <div className="muted" style={{ fontSize: 12 }}>
                {d.teleports.length ? `红色虚线：${d.teleports.length} 段瞬移（相邻点超过 ${r?.teleport_m ?? 500} m）` : '未检测到瞬移段'}
              </div>
            </div>
          </Col>
          </>
        ) : (
          <Col span={24}>
            <div className="tile">这条告警没有关联运动记录（例如多账号同设备），没有速度曲线和轨迹，请结合历史告警判断。</div>
          </Col>
        )}
        <Col span={24}>
          <div className="panel" style={{ padding: 14 }}>
            <b>证据</b>
            <Row gutter={[8, 8]} style={{ marginTop: 10 }}>
              <Col xs={12} md={8} xl={6}>
                <Evidence
                  label="设备"
                  value={d.device ? `${d.device.model} · ${d.device.os}${d.device.rooted ? ' · Root' : ''}${d.device.emulator ? ' · 模拟器' : ''}${d.device.multi_open ? ' · 多开' : ''}` : '无设备信息'}
                  warn={!d.device || d.device.rooted || d.device.emulator || d.device.multi_open}
                />
              </Col>
              <Col xs={12} md={8} xl={6}>
                <Evidence label="定位来源" value={mainSrc} sub={`GPS ${d.sources.gps} · 网络 ${d.sources.network} · 模拟 ${d.sources.mock}`} warn={d.sources.mock > 0} />
              </Col>
              <Col xs={12} md={8} xl={6}>
                <Evidence label="步频" value={d.cadence_avg === null ? '无数据' : `${d.cadence_avg} 步/分`} warn={!d.cadence_avg} />
              </Col>
              <Col xs={12} md={8} xl={6}>
                <Evidence label="心率" value={d.hr_avg === null ? '无心率（无穿戴设备）' : `${d.hr_avg} bpm`} warn={d.hr_avg === null} />
              </Col>
              <Col xs={12} md={8} xl={6}>
                <Evidence label="同设备账号" value={`${d.same_device_accounts} 个`} warn={d.same_device_accounts > 1} />
              </Col>
              <Col xs={12} md={8} xl={6}>
                <Evidence label="历史告警" value={`${d.history.length} 次`} warn={d.history.length > 0} />
              </Col>
              {act && (
                <Col xs={12} md={8} xl={6}>
                  <Evidence label="配速 / 时长" value={`${act.avg_pace_s_per_km ? `${Math.floor(act.avg_pace_s_per_km / 60)}'${String(act.avg_pace_s_per_km % 60).padStart(2, '0')}"` : '—'} · ${Math.round(act.duration_s / 60)} 分钟`} />
                </Col>
              )}
              {d.device && (
                <Col xs={12} md={8} xl={6}>
                  <Evidence label="设备 ID" value={<span className="num" style={{ fontSize: 12 }}>{d.device.id}</span>} />
                </Col>
              )}
            </Row>
            {d.history.length > 0 && (
              <div style={{ marginTop: 12 }}>
                <div className="muted" style={{ fontSize: 12, marginBottom: 4 }}>
                  历史告警
                </div>
                {d.history.map((h) => (
                  <div key={h.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '5px 0', borderBottom: '1px dashed #e6e6ea', gap: 8 }}>
                    <span>
                      <Link to={`/risk?alert=${h.id}&status=${h.status}`}>{RISK_TYPE[h.type] ?? h.type}</Link> <span className="muted">· {h.detail}</span>
                    </span>
                    <span className="muted" style={{ whiteSpace: 'nowrap' }}>
                      {h.status === 'open' ? '待确认' : resolutionText(h.resolution, h.note) || '已处理'} · {dt(h.created_at, 'MM/DD')}
                    </span>
                  </div>
                ))}
              </div>
            )}
          </div>
        </Col>
      </Row>

      {open ? (
        <div style={{ display: 'flex', gap: 10, marginTop: 16, flexWrap: 'wrap' }}>
          <Button type="primary" size="large" disabled={!canResolve} onClick={() => setPending('void')}>
            作废记录并回滚领地
          </Button>
          <Button size="large" disabled={!canResolve} onClick={() => setPending('warn')}>
            警告
          </Button>
          <Button size="large" danger disabled={!canResolve} onClick={() => setPending('ban_30d')}>
            封禁 30 天
          </Button>
          <div style={{ flex: 1 }} />
          <Button size="large" disabled={!canResolve} onClick={() => setPending('false_positive')}>
            误报，放行
          </Button>
          {!can('risk.resolve') && <span className="muted">当前角色不能处理告警</span>}
        </div>
      ) : (
        <div className="tile" style={{ marginTop: 16 }}>
          处理结果：<b>{resolutionText(a.resolution, a.note) || '已处理'}</b>
        </div>
      )}

      <Modal
        open={pending !== null}
        title={pending ? RISK_ACTION[pending].text : ''}
        okText="确认"
        cancelText="取消"
        okButtonProps={{ danger: pending ? RISK_ACTION[pending].danger : false, loading: resolve.isPending }}
        onCancel={() => setPending(null)}
        afterOpenChange={(o) => o && setNote('')}
        onOk={() => pending && resolve.mutate({ action: pending, note })}
      >
        <p>{pending && RISK_ACTION[pending].confirm}</p>
        <Input.TextArea rows={3} maxLength={200} showCount placeholder="备注（可选，写入审计日志）" value={note} onChange={(e) => setNote(e.target.value)} />
      </Modal>
    </Panel>
  );
}

// ------------------------------------------------------------ rules

const RULES: { key: keyof Omit<RiskRules, 'require_wearable_for_events'>; label: string; unit: string; min: number; max: number; step: number; hint: string }[] = [
  { key: 'run_max_kmh', label: '跑步最大均速', unit: 'km/h', min: 10, max: 40, step: 1, hint: '超过即标记为疑似乘车' },
  { key: 'ride_max_kmh', label: '骑行最大均速', unit: 'km/h', min: 20, max: 80, step: 1, hint: '公路车冲刺可达 50+' },
  { key: 'hike_max_kmh', label: '徒步最大均速', unit: 'km/h', min: 4, max: 20, step: 1, hint: '' },
  { key: 'walk_max_kmh', label: '健走最大均速', unit: 'km/h', min: 4, max: 20, step: 1, hint: '' },
  { key: 'teleport_m', label: '瞬移距离', unit: 'm', min: 100, max: 2000, step: 50, hint: '相邻两点间超过即告警' },
  { key: 'gap_s', label: '信号丢失容忍', unit: '秒', min: 5, max: 120, step: 5, hint: '隧道、高架下自动放宽' },
];

function RulesEditor() {
  const qc = useQueryClient();
  const { can } = useAuth();
  const editable = can('risk.rules');
  const q = useQuery({ queryKey: ['risk', 'rules'], queryFn: api.riskRules });
  const [draft, setDraft] = useState<RiskRules | null>(null);
  useEffect(() => {
    if (q.data) setDraft(q.data);
  }, [q.data]);
  const save = useMutation({
    mutationFn: (r: RiskRules) => api.updateRiskRules(r),
    onSuccess: (r) => {
      qc.setQueryData(['risk', 'rules'], r);
      toastOk('规则已保存，只对新上传的记录生效');
    },
  });

  if (!draft || !q.data) return <Panel><Skeleton active /></Panel>;
  const dirty = JSON.stringify(draft) !== JSON.stringify(q.data);

  return (
    <Panel
      title="判定规则"
      extra={
        <Space>
          <span className="panel-hint">改动后对新上传的记录生效，历史记录不重算</span>
          {dirty && (
            <>
              <Button size="small" onClick={() => setDraft(q.data)}>
                撤销
              </Button>
              <Button size="small" type="primary" loading={save.isPending} onClick={() => save.mutate(draft)}>
                保存规则
              </Button>
            </>
          )}
        </Space>
      }
    >
      <Row gutter={[12, 12]}>
        {RULES.map((r) => (
          <Col xs={24} sm={12} lg={8} xxl={6} key={r.key}>
            <div className="rule-card" style={draft[r.key] !== q.data[r.key] ? { background: '#f4fbd2' } : undefined}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span style={{ fontSize: 13 }}>{r.label}</span>
                <b className="num">
                  {draft[r.key]} {r.unit}
                </b>
              </div>
              <Slider disabled={!editable} min={r.min} max={r.max} step={r.step} value={draft[r.key]} onChange={(v) => setDraft({ ...draft, [r.key]: v })} tooltip={{ formatter: (v) => `${v} ${r.unit}` }} />
              <div className="muted" style={{ fontSize: 12, minHeight: 18 }}>
                {r.hint}
              </div>
            </div>
          </Col>
        ))}
        <Col xs={24} sm={12} lg={8} xxl={6}>
          <div className="rule-card" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, ...(draft.require_wearable_for_events !== q.data.require_wearable_for_events ? { background: '#f4fbd2' } : {}) }}>
            <div>
              <div style={{ fontSize: 13 }}>赛事与联赛要求穿戴设备数据</div>
              <div className="muted" style={{ fontSize: 12 }}>
                无心率/步频的记录不计入排名
              </div>
            </div>
            <Tooltip title={editable ? undefined : '当前角色不能修改规则'}>
              <Switch disabled={!editable} checked={draft.require_wearable_for_events} onChange={(v) => setDraft({ ...draft, require_wearable_for_events: v })} />
            </Tooltip>
          </div>
        </Col>
      </Row>
      <div className="muted" style={{ fontSize: 12, marginTop: 10 }}>
        <AimOutlined /> 规则影响新上传运动的自动判定：确定性作弊直接作废，疑似的进入上方人工复核队列。
      </div>
    </Panel>
  );
}
