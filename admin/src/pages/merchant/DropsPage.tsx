// 投放 (M-25): 补给站 / 宝箱 / 据点 by merchant, today's issued / redeemed vs the daily cap; 新建投放 wizard,
// edit, pause / resume. Supports ?merchant_id= (links from the 商户 page).
import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { App, Button, Col, Row, Segmented, Select, Space, Table, Tag, Tooltip } from 'antd';
import { perksApi, type Drop, type DropStatus, type DropType } from '../../api/perks';
import { useAuth } from '../../auth/AuthContext';
import { PageHeader, Panel, Tile } from '../../components/ui';
import { dt, num, yuan } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { MerchantNav } from './nav';
import { DROP_STATUS, DROP_TYPE, DROP_TYPES, SETTLE_DIRECTION_TEXT } from './perkLabels';
import { DropTypeBadge } from './perkShared';
import DropWizard from './DropWizard';
import { Glyph } from '../../components/Glyph';

function CapCell({ d }: { d: Drop }) {
  // daily_cap 0 = 不限 (backend)
  const cap = d.daily_cap > 0 ? d.daily_cap : Math.max(1, d.issued_today);
  const full = d.daily_cap > 0 && d.issued_today >= d.daily_cap;
  return (
    <div className="cap-cell">
      <span className="num" style={{ fontSize: 13 }}>
        发 <b>{num(d.issued_today)}</b> · 核销 <b>{num(d.redeemed_today)}</b>
        <span className="muted"> / 上限 {d.daily_cap > 0 ? num(d.daily_cap) : '不限'}</span>
      </span>
      <div className={`cap-track${full ? ' full' : ''}`} role="img" aria-label={`今日发出 ${d.issued_today}，核销 ${d.redeemed_today}，上限 ${d.daily_cap}`}>
        <i className="issued" style={{ width: `${Math.min(100, (d.issued_today / cap) * 100)}%` }} />
        <i className="redeemed" style={{ width: `${Math.min(100, (d.redeemed_today / cap) * 100)}%` }} />
      </div>
      {full && d.status === 'active' && <div style={{ fontSize: 11.5, color: '#C2410C', marginTop: 2 }}>今日已发完 · 地图上不显示</div>}
    </div>
  );
}

export default function DropsPage() {
  const [params, setParams] = useSearchParams();
  const merchantId = params.get('merchant_id') ? Number(params.get('merchant_id')) : null;
  const type = (params.get('type') ?? '') as DropType | '';
  const status = (params.get('status') ?? '') as DropStatus | '';
  const page = Number(params.get('page') ?? 1);
  const { can } = useAuth();
  const writable = can('perks.write');
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const [editing, setEditing] = useState<Drop | 'new' | null>(null);

  const update = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null || v === '') next.delete(k);
      else next.set(k, v);
    }
    if (!('page' in patch)) next.delete('page');
    setParams(next, { replace: true });
  };

  const list = useQuery({
    queryKey: ['drops', 'list', merchantId, type, status, page],
    queryFn: () => perksApi.drops({ merchant_id: merchantId, type, status, page }),
    placeholderData: (p) => p,
  });
  // header totals: everything currently live (one page of 100 is plenty for a city)
  const live = useQuery({ queryKey: ['drops', 'live', merchantId], queryFn: () => perksApi.drops({ merchant_id: merchantId, status: 'active', page_size: 100 }) });
  const merchants = useQuery({ queryKey: ['perk-merchants'], queryFn: perksApi.merchantOptions, staleTime: 60_000 });
  const campaigns = useQuery({ queryKey: ['brand-campaigns', 'options'], queryFn: () => perksApi.campaigns({ page_size: 100 }), staleTime: 30_000 });
  /** "青柠茶铺 · 冬日暖跑" → "冬日暖跑" next to the merchant name. */
  const campaignTitle = (d: Drop) => {
    const t = campaigns.data?.items.find((c) => c.id === d.campaign_id)?.title ?? `活动 #${d.campaign_id}`;
    return t.startsWith(`${d.merchant.name} · `) ? t.slice(d.merchant.name.length + 3) : t;
  };

  const toggle = useMutation({
    mutationFn: ({ d, action }: { d: Drop; action: 'pause' | 'resume' }) => (action === 'pause' ? perksApi.pauseDrop(d.id) : perksApi.resumeDrop(d.id)),
    onSuccess: (d, { action }) => {
      qc.invalidateQueries({ queryKey: ['drops'] });
      qc.invalidateQueries({ queryKey: ['map-objects'] });
      toastOk(action === 'pause' ? `已暂停「${d.name}」` : `已恢复「${d.name}」，${d.status === 'active' ? '继续发券' : '到开始时间自动发券'}`);
    },
  });

  const confirmToggle = (d: Drop) => {
    const pause = d.status !== 'paused';
    modal.confirm({
      title: pause ? `暂停「${d.name}」？` : `恢复「${d.name}」？`,
      content: pause
        ? '暂停后不再发券，地图上不显示；已发出的券仍可在有效期内核销。'
        : `恢复后${d.type === 'supply' ? '补给站重新出现在地图上' : d.type === 'chest' ? '下次刷新时重新刷出宝箱' : '场馆签到重新发券'}${d.daily_cap > 0 ? `，今日上限按 ${num(d.daily_cap)} 张继续计算` : ''}。`,
      okText: pause ? '暂停' : '恢复',
      okButtonProps: pause ? { danger: true } : undefined,
      cancelText: '取消',
      onOk: () => toggle.mutateAsync({ d, action: pause ? 'pause' : 'resume' }),
    });
  };

  const liveItems = live.data?.items ?? [];
  const merchant = merchants.data?.items.find((m) => m.id === merchantId);
  const sum = (f: (d: Drop) => number) => liveItems.reduce((s, d) => s + f(d), 0);

  return (
    <>
      <PageHeader
        title="商户与活动"
        sub={`投放 · 补给站 / 宝箱 / 据点发券${merchant ? ` · ${merchant.name}` : ''}；权益规则在 App 内明示，不设付费抽取`}
        extra={<MerchantNav />}
      />
      <Row gutter={[12, 12]} style={{ marginBottom: 16 }}>
        <Col xs={12} md={6}>
          <Tile v={num(live.data?.total ?? liveItems.length)} l="发券中的投放" />
        </Col>
        <Col xs={12} md={6}>
          <Tile v={num(sum((d) => d.issued_today))} l={`今日发券 / 上限 ${num(sum((d) => d.daily_cap))}`} />
        </Col>
        <Col xs={12} md={6}>
          <Tile v={num(sum((d) => d.redeemed_today))} l="今日核销" />
        </Col>
        <Col xs={12} md={6}>
          <Tile v={num(liveItems.filter((d) => d.daily_cap > 0 && d.issued_today >= d.daily_cap).length)} l="今日已发完" warn={liveItems.some((d) => d.daily_cap > 0 && d.issued_today >= d.daily_cap)} />
        </Col>
      </Row>
      <Panel
        title="投放"
        extra={
          <Button type="primary" icon={<Glyph name="plus" />} disabled={!writable} onClick={() => setEditing('new')}>
            新建投放
          </Button>
        }
      >
        <Space wrap style={{ marginBottom: 14 }}>
          <Select
            allowClear
            showSearch
            optionFilterProp="label"
            placeholder="全部商户"
            style={{ width: 200 }}
            value={merchantId ?? undefined}
            onChange={(v) => update({ merchant_id: v ? String(v) : null })}
            options={(merchants.data?.items ?? []).map((m) => ({ value: m.id, label: m.name }))}
            aria-label="按商户筛选"
          />
          <Segmented
            value={type}
            onChange={(v) => update({ type: String(v) })}
            options={[{ label: '全部类型', value: '' }, ...DROP_TYPES.map((t) => ({ label: DROP_TYPE[t].label, value: t }))]}
          />
          <Select
            style={{ width: 130 }}
            value={status}
            onChange={(v) => update({ status: v })}
            options={[{ value: '', label: '全部状态' }, ...(Object.keys(DROP_STATUS) as DropStatus[]).map((s) => ({ value: s, label: DROP_STATUS[s].text }))]}
            aria-label="按状态筛选"
          />
        </Space>
        <Table<Drop>
          rowKey="id"
          loading={list.isFetching}
          dataSource={list.data?.items}
          scroll={{ x: 1160 }}
          pagination={{ current: page, pageSize: 20, total: list.data?.total ?? 0, showSizeChanger: false, onChange: (p) => update({ page: String(p) }) }}
          columns={[
            {
              title: '投放点',
              key: 'name',
              width: 270,
              render: (_, d) => (
                <div className="drop-cell">
                  <DropTypeBadge type={d.type} />
                  <div>
                    <b>{d.name}</b>
                    <div className="muted">
                      <Link to={`/merchant/drops?merchant_id=${d.merchant.id}`}>{d.merchant.name}</Link>
                      {d.campaign_id && (
                        <>
                          {' · '}
                          <Link to={`/merchant/campaigns?id=${d.campaign_id}`}>联名「{campaignTitle(d)}」</Link>
                        </>
                      )}
                    </div>
                  </div>
                </div>
              ),
            },
            {
              title: '权益',
              key: 'perk',
              width: 230,
              render: (_, d) => (
                <div>
                  <div>
                    <Tag bordered={false} color="lime" style={{ fontWeight: 700 }}>
                      {d.perk.value_text}
                    </Tag>
                    {d.perk.title}
                  </div>
                  <div className="muted" style={{ fontSize: 12 }}>
                    领取后 {d.perk.valid_days} 天有效{d.type !== 'stronghold' ? ` · 半径 ${d.radius_m} m` : ''}
                  </div>
                </div>
              ),
            },
            { title: '今日 发券 · 核销 / 上限', key: 'today', width: 200, render: (_, d) => <CapCell d={d} /> },
            {
              title: '有效期',
              key: 'time',
              width: 120,
              render: (_, d) => (
                <span className="num" style={{ fontSize: 12, whiteSpace: 'nowrap' }}>
                  {dt(d.start_time, 'MM-DD HH:mm')}
                  <br />
                  至 {dt(d.end_time, 'MM-DD HH:mm')}
                </span>
              ),
            },
            {
              title: '结算',
              key: 'settle',
              width: 100,
              render: (_, d) => (
                <Tooltip title={SETTLE_DIRECTION_TEXT[d.settle_direction]?.hint}>
                  <span className="num" style={{ whiteSpace: 'nowrap' }}>
                    {yuan(d.settle_price_amt)} / 张
                  </span>
                  <div className="muted" style={{ fontSize: 12 }}>
                    {SETTLE_DIRECTION_TEXT[d.settle_direction]?.short ?? d.settle_direction}
                  </div>
                </Tooltip>
              ),
            },
            { title: '状态', dataIndex: 'status', width: 90, render: (s: DropStatus) => <Tag bordered={false} color={DROP_STATUS[s]?.color}>{DROP_STATUS[s]?.text ?? s}</Tag> },
            {
              title: '操作',
              key: 'op',
              align: 'right',
              fixed: 'right',
              width: 130,
              render: (_, d) => (
                <Space>
                  <Button size="small" disabled={!writable || d.status === 'ended'} onClick={() => setEditing(d)}>
                    编辑
                  </Button>
                  {d.status !== 'ended' && (
                    <Button size="small" danger={d.status !== 'paused'} disabled={!writable} onClick={() => confirmToggle(d)}>
                      {d.status === 'paused' ? '恢复' : '暂停'}
                    </Button>
                  )}
                </Space>
              ),
            },
          ]}
        />
      </Panel>
      <DropWizard value={editing} defaultMerchantId={merchantId} onClose={() => setEditing(null)} />
    </>
  );
}
