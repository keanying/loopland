import { useEffect, useRef, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { App, Button, Col, Empty, Input, InputNumber, Row, Segmented, Skeleton, Space, Switch, Table, Tag, Timeline, Tooltip } from 'antd';
import { MinusOutlined, PlusOutlined, SearchOutlined } from '@ant-design/icons';
import { api, PAGE_SIZE } from '../api/admin';
import type { Territory, TerritoryEvent, TerritoryListItem, TerritoryStatusFilter } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import { useAdminNames } from '../hooks/useAdminNames';
import TerritoryMap, { HAS_AMAP } from '../components/map';
import { ownerColor } from '../components/map/colors';
import { PageHeader, Panel, Tile } from '../components/ui';
import { ago, area, dt, km2 } from '../utils/format';
import { TERRITORY_EVENT } from '../utils/labels';
import { toastOk } from '../utils/notify';

type BBox = [number, number, number, number];

// /territories/geo needs a bbox of at most 2°; without a basemap we view one city at a time.
const CITIES: { key: string; name: string; lng: number; lat: number }[] = [
  { key: 'sh', name: '上海', lng: 121.47, lat: 31.23 },
  { key: 'hz', name: '杭州', lng: 120.16, lat: 30.27 },
  { key: 'bj', name: '北京', lng: 116.4, lat: 39.9 },
  { key: 'sz', name: '深圳', lng: 114.06, lat: 22.54 },
];
const HALF = 0.9;
const boxAround = (c: { lng: number; lat: number }): BBox => [c.lng - HALF, c.lat - HALF, c.lng + HALF, c.lat + HALF];
const inBox = (b: BBox, p: { lng: number; lat: number }) => p.lng >= b[0] && p.lng <= b[2] && p.lat >= b[1] && p.lat <= b[3];
/** AMap viewport bounds can exceed the server's 2° limit when zoomed out. */
function clampBox(b: BBox): BBox {
  const cx = (b[0] + b[2]) / 2;
  const cy = (b[1] + b[3]) / 2;
  const hx = Math.min((b[2] - b[0]) / 2, 0.99);
  const hy = Math.min((b[3] - b[1]) / 2, 0.99);
  return [cx - hx, cy - hy, cx + hx, cy + hy];
}

function statusTag(t: { frozen: boolean; owner: unknown; changes_today?: number }) {
  if (t.frozen) return <Tag color="blue" bordered={false}>已冻结</Tag>;
  if (!t.owner) return <Tag bordered={false}>无主</Tag>;
  if ((t.changes_today ?? 0) > 0) return <Tag color="red" bordered={false}>争夺中</Tag>;
  return <Tag color="success" bordered={false}>正常</Tag>;
}

export default function TerritoriesPage() {
  const [params, setParams] = useSearchParams();
  const status = (params.get('status') as TerritoryStatusFilter) || 'all';
  const q = params.get('q') ?? '';
  const page = Number(params.get('page') ?? 1);
  const selectedId = params.get('id') ? Number(params.get('id')) : null;
  const [kw, setKw] = useState(q);
  const [focus, setFocus] = useState<{ lat: number; lng: number; n: number } | null>(null);
  const [center, setCenter] = useState<{ lng: number; lat: number }>(CITIES[0]);
  const [amapBox, setAmapBox] = useState<BBox | null>(null);
  const bbox: BBox = HAS_AMAP && amapBox ? clampBox(amapBox) : boxAround(center);
  const mapRef = useRef<HTMLDivElement | null>(null);

  const update = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null || v === '') next.delete(k);
      else next.set(k, v);
    }
    setParams(next, { replace: true });
  };

  const geo = useQuery({
    queryKey: ['territories', 'geo', bbox.map((n) => n.toFixed(3)).join(',')],
    queryFn: () => api.territoriesGeo(bbox),
    placeholderData: (prev) => prev,
  });
  const list = useQuery({
    queryKey: ['territories', 'list', status, q, page],
    queryFn: () => api.territories({ status, q, page }),
    placeholderData: (prev) => prev,
  });

  const locate = (t: TerritoryListItem) => {
    update({ id: String(t.id) });
    if (!HAS_AMAP && !inBox(bbox, t.center)) setCenter(t.center);
    setFocus({ ...t.center, n: Date.now() });
    mapRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  const total = geo.data?.items.length ?? 0;

  return (
    <>
      <PageHeader
        title="地图与领地"
        sub={`当前视野领地 ${total} 块 · 点选地块查看详情，按归属方着色`}
        extra={
          <Segmented
            value={CITIES.find((c) => c.lng === center.lng && c.lat === center.lat)?.key ?? 'custom'}
            onChange={(k) => {
              const c = CITIES.find((x) => x.key === k);
              if (!c) return;
              setCenter(c);
              setFocus(HAS_AMAP ? { lng: c.lng, lat: c.lat, n: Date.now() } : null);
            }}
            options={[...CITIES.map((c) => ({ label: c.name, value: c.key })), ...(CITIES.some((c) => c.lng === center.lng && c.lat === center.lat) ? [] : [{ label: '定位处', value: 'custom' }])]}
          />
        }
      />
      <Row gutter={[20, 20]}>
        <Col xs={24} xl={15} ref={mapRef}>
          <Panel grey>
            {geo.data ? (
              <TerritoryMap items={geo.data.items} selectedId={selectedId} onSelect={(id) => update({ id: String(id) })} focus={focus} onBounds={setAmapBox} />
            ) : (
              <Skeleton.Node active style={{ width: '100%', height: 520 }} />
            )}
          </Panel>
        </Col>
        <Col xs={24} xl={9}>
          <TerritoryDetail id={selectedId} />
        </Col>
      </Row>

      <Panel
        title="领地列表"
        extra={
          <Space wrap>
            <Input
              allowClear
              prefix={<SearchOutlined />}
              placeholder="领地名、ID 或归属人"
              style={{ width: 220 }}
              value={kw}
              onChange={(e) => {
                setKw(e.target.value);
                if (!e.target.value) update({ q: null, page: null });
              }}
              onPressEnter={() => update({ q: kw.trim(), page: null })}
            />
            <Segmented
              value={status}
              onChange={(v) => update({ status: v === 'all' ? null : String(v), page: null })}
              options={[
                { label: '全部', value: 'all' },
                { label: '争夺中', value: 'contested' },
                { label: '已冻结', value: 'frozen' },
              ]}
            />
          </Space>
        }
      >
        <Table<TerritoryListItem>
          rowKey="id"
          loading={list.isFetching}
          dataSource={list.data?.items}
          scroll={{ x: 900 }}
          rowClassName={(r) => (r.id === selectedId ? 'row-active' : '')}
          pagination={{
            current: page,
            pageSize: PAGE_SIZE,
            total: list.data?.total ?? 0,
            showSizeChanger: false,
            showTotal: (t) => `共 ${t} 块`,
            onChange: (p) => update({ page: p === 1 ? null : String(p) }),
          }}
          columns={[
            {
              title: '领地',
              dataIndex: 'name',
              render: (v: string, r) => (
                <div>
                  <b>{v}</b>
                  <div className="muted num" style={{ fontSize: 12 }}>
                    #{r.id}
                  </div>
                </div>
              ),
            },
            {
              title: '归属',
              key: 'owner',
              render: (_, r) => (
                <span>
                  <span className="swatch" style={{ background: ownerColor(r.owner?.id), borderRadius: '50%' }} />
                  {r.owner ? r.owner.nickname : <span className="muted">无主</span>}
                  {r.crew && <span className="muted"> · {r.crew.name}</span>}
                </span>
              ),
            },
            { title: '面积 km²', dataIndex: 'area_m2', align: 'right', render: (v: number) => <span className="num">{km2(v, 3)}</span> },
            { title: '守卫', dataIndex: 'guard', align: 'right', render: (v: number) => <span className="num">{v}</span> },
            { title: '今日易手', dataIndex: 'changes_today', align: 'right', render: (v: number) => <span className="num">{v}</span> },
            { title: '建筑', dataIndex: 'building_count', align: 'right' },
            { title: '状态', key: 'status', render: (_, r) => statusTag(r) },
            { title: '更新', dataIndex: 'updated_at', render: (v: string) => <span className="muted">{ago(v)}</span> },
            {
              title: '操作',
              key: 'op',
              align: 'right',
              render: (_, r) => (
                <Button size="small" type={r.id === selectedId ? 'primary' : 'default'} onClick={() => locate(r)}>
                  {r.id === selectedId ? '已选中' : '定位'}
                </Button>
              ),
            },
          ]}
        />
      </Panel>
    </>
  );
}

function eventText(e: TerritoryEvent, adminName: (id: TerritoryEvent['admin']) => string): string {
  const parts: string[] = [];
  if (e.actor) parts.push(e.actor.nickname);
  if (e.prev_owner !== undefined && e.new_owner !== undefined && (e.prev_owner?.id ?? null) !== (e.new_owner?.id ?? null)) {
    parts.push(`归属 ${e.prev_owner?.nickname ?? '无主'} → ${e.new_owner?.nickname ?? '无主'}`);
  }
  if (e.prev_guard !== undefined && e.new_guard !== undefined && e.prev_guard !== null && e.new_guard !== null && e.prev_guard !== e.new_guard) {
    parts.push(`守卫 ${e.prev_guard} → ${e.new_guard}`);
  }
  if (e.admin) parts.push(`操作人 ${adminName(e.admin)}`);
  return parts.join(' · ');
}

function TerritoryDetail({ id }: { id: number | null }) {
  const { modal } = App.useApp();
  const { can } = useAuth();
  const qc = useQueryClient();
  const editable = can('territory.write');
  const adminName = useAdminNames();
  const q = useQuery({ queryKey: ['territories', 'detail', id], queryFn: () => api.territory(id!), enabled: id !== null });
  const t = q.data;
  const [guard, setGuard] = useState<number>(0);
  useEffect(() => {
    if (t) setGuard(t.guard);
  }, [t]);

  const onDone = (msg: string) => (next: Territory) => {
    qc.setQueryData(['territories', 'detail', id], next);
    qc.invalidateQueries({ queryKey: ['territories', 'list'] });
    qc.invalidateQueries({ queryKey: ['territories', 'geo'] });
    toastOk(msg);
  };
  const saveGuard = useMutation({ mutationFn: (g: number) => api.setGuard(id!, g), onSuccess: onDone('守卫值已更新') });
  const freeze = useMutation({ mutationFn: (f: boolean) => api.freeze(id!, f), onSuccess: (n) => onDone(n.frozen ? '已冻结' : '已解冻')(n) });
  const reset = useMutation({ mutationFn: () => api.resetTerritory(id!), onSuccess: onDone('已重置为无主，并通知原归属方') });

  if (id === null) {
    return (
      <Panel>
        <Empty description="在地图上点选一块领地，或在下方列表点「定位」" style={{ padding: '80px 0' }} />
      </Panel>
    );
  }
  if (!t) return <Panel>{q.isError ? <Empty description="加载失败" /> : <Skeleton active paragraph={{ rows: 10 }} />}</Panel>;

  const clamp = (g: number) => Math.min(2000, Math.max(0, Math.round(g / 50) * 50));
  const built = t.slots.filter((s) => s.building);

  return (
    <Panel>
      <div style={{ display: 'flex', gap: 14, alignItems: 'center' }}>
        <div style={{ width: 52, height: 52, borderRadius: 14, background: ownerColor(t.owner?.id), border: '1.5px solid #141414', flexShrink: 0 }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 20, fontWeight: 800 }}>{t.name}</div>
          <div className="muted" style={{ fontSize: 12 }}>
            归属：{t.owner ? <Link to={`/users?id=${t.owner.id}`}>{t.owner.nickname}</Link> : '无主'}
            {t.crew ? ` · ${t.crew.name}` : ''} · 领地 ID {t.id}
          </div>
        </div>
        {statusTag(t)}
      </div>

      <Row gutter={8} style={{ marginTop: 14 }}>
        <Col span={8}>
          <Tile v={km2(t.area_m2, 3)} l="面积 km²" />
        </Col>
        <Col span={8}>
          <Tile v={t.daily_energy} l="每日产能" />
        </Col>
        <Col span={8}>
          <Tile v={`${built.length}/${t.slots.length}`} l="建筑" />
        </Col>
      </Row>

      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 18, gap: 8 }}>
        <div>
          <b>守卫值</b>
          <div className="muted" style={{ fontSize: 12 }}>
            越高越难被抢，0–2000，步长 50
          </div>
        </div>
        <Space>
          <Button shape="circle" icon={<MinusOutlined />} disabled={!editable || guard <= 0} onClick={() => setGuard((g) => clamp(g - 50))} aria-label="守卫值 -50" />
          <InputNumber
            className="num"
            min={0}
            max={2000}
            step={50}
            value={guard}
            disabled={!editable}
            style={{ width: 90 }}
            onChange={(v) => setGuard(v ?? 0)}
            onBlur={() => setGuard((g) => clamp(g))}
          />
          <Button shape="circle" icon={<PlusOutlined />} disabled={!editable || guard >= 2000} onClick={() => setGuard((g) => clamp(g + 50))} aria-label="守卫值 +50" />
        </Space>
      </div>
      {guard !== t.guard && (
        <div style={{ textAlign: 'right', marginTop: 8 }}>
          <Space>
            <span className="muted">
              {t.guard} → {clamp(guard)}
            </span>
            <Button size="small" onClick={() => setGuard(t.guard)}>
              取消
            </Button>
            <Button size="small" type="primary" loading={saveGuard.isPending} onClick={() => saveGuard.mutate(clamp(guard))}>
              保存守卫值
            </Button>
          </Space>
        </div>
      )}

      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 16 }}>
        <div>
          <b>冻结领地</b>
          <div className="muted" style={{ fontSize: 12 }}>
            冻结后不可被抢、不可建设
          </div>
        </div>
        <Switch
          checked={t.frozen}
          disabled={!editable}
          loading={freeze.isPending}
          onChange={(v) =>
            modal.confirm({
              title: v ? `冻结「${t.name}」？` : `解冻「${t.name}」？`,
              content: v ? '冻结期间这块领地不能被抢占、不能建造。' : '解冻后恢复正常争夺和建设。',
              okText: '确认',
              cancelText: '取消',
              onOk: () => freeze.mutateAsync(v),
            })
          }
        />
      </div>

      <Space style={{ marginTop: 16 }} wrap>
        <Tooltip title={!t.owner ? '已经是无主领地' : undefined}>
          <Button
            danger
            disabled={!editable || !t.owner}
            loading={reset.isPending}
            onClick={() =>
              modal.confirm({
                title: `把「${t.name}」重置为无主？`,
                content: `领地变为无主，${built.length} 座建筑全部清空，并通知原归属方 ${t.owner?.nickname ?? ''}。此操作不可撤销。`,
                okText: '重置',
                okButtonProps: { danger: true },
                cancelText: '取消',
                onOk: () => reset.mutateAsync(),
              })
            }
          >
            重置为无主
          </Button>
        </Tooltip>
        {!editable && <span className="muted">当前角色只能查看</span>}
      </Space>

      <div style={{ marginTop: 18 }}>
        <b>建筑与驻扎</b>
        <div style={{ marginTop: 8, display: 'flex', flexWrap: 'wrap', gap: 6 }}>
          {t.slots.map((s) => (
            <Tag key={s.slot} bordered={false} color={s.building ? 'default' : undefined} style={{ opacity: s.building ? 1 : 0.5 }}>
              {s.slot + 1}. {s.name ?? '空位'}
            </Tag>
          ))}
        </div>
        <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>
          驻扎位 {t.station_slots}：{t.stationed.length ? t.stationed.map((s) => `${s.name}（${s.buff_text}）`).join('、') : '无'}
          {t.captured_at && ` · 占领于 ${dt(t.captured_at)}`} · {area(t.area_m2)}
        </div>
      </div>

      <div style={{ marginTop: 18 }}>
        <b>领地记录</b>
        <div style={{ maxHeight: 260, overflow: 'auto', marginTop: 12, paddingTop: 4 }}>
          {t.events.length === 0 ? (
            <div className="muted">暂无记录</div>
          ) : (
            <Timeline
              items={t.events.map((e, i) => ({
                key: i,
                color: e.admin ? 'blue' : e.kind === 'capture' || e.kind === 'attack' ? 'red' : 'gray',
                children: (
                  <div style={{ fontSize: 13 }}>
                    <b>{TERRITORY_EVENT[e.kind] ?? e.kind}</b> <span className="muted">{dt(e.created_at)}</span>
                    <div className="muted" style={{ fontSize: 12 }}>
                      {eventText(e, adminName)}
                    </div>
                  </div>
                ),
              }))}
            />
          )}
        </div>
      </div>
    </Panel>
  );
}
