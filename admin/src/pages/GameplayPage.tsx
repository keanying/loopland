import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, App, Badge, Button, Col, Empty, Input, InputNumber, Row, Segmented, Skeleton, Space, Table, Tag, Tooltip } from 'antd';
import { CheckCircleOutlined, RollbackOutlined } from '@ant-design/icons';
import { api } from '../api/admin';
import type { BossConf, BuildingConf, Config, EnergyRule, GameplayState, RoleConf } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import { useAdminNames } from '../hooks/useAdminNames';
import { PageHeader, Panel } from '../components/ui';
import { dt } from '../utils/format';
import { DROP_KIND, SPORT_LABEL, UNIT_LABEL } from '../utils/labels';
import { toastOk } from '../utils/notify';
import { BRAND } from '../theme';

type Tab = 'buildings' | 'roles' | 'drops' | 'energy';

interface Change {
  path: string;
  label: string;
  from: string | number;
  to: string | number;
}

const TOP_FIELDS: { key: string; label: string }[] = [
  { key: 'daily_energy_cap', label: '每人每日能量上限' },
  { key: 'slots_per_territory', label: '每块领地建造位' },
  { key: 'base_station_slots', label: '基础驻扎位' },
  { key: 'min_claim_area_m2', label: '最小圈地面积 m²' },
  { key: 'boss_strike_cost', label: '攻打怪兽消耗能量' },
];
const BUILDING_FIELDS: { key: keyof BuildingConf; label: string }[] = [
  { key: 'cost', label: '建造能量' },
  { key: 'guard', label: '守卫 +' },
  { key: 'daily_energy', label: '每日产能量' },
  { key: 'unlock_level', label: '解锁等级' },
];
const ROLE_FIELDS: { key: keyof RoleConf; label: string }[] = [
  { key: 'threshold', label: '招募门槛' },
  { key: 'buff_value', label: '加成数值' },
  { key: 'buff_text', label: '加成说明' },
];
const ENERGY_FIELDS: { key: keyof EnergyRule; label: string }[] = [
  { key: 'per', label: '换算单位量' },
  { key: 'energy', label: '换得能量' },
];

const EGG_NAMES: Record<string, string> = { firetail: '火尾蜥蛋', nightnewt: '夜行蝾螈蛋', axolotl: '六角龙蛋', frog: '雨蛙蛋', gecko: '闪电壁虎蛋' };

function dropItemName(c: Config, item: string, kind: string): string {
  if (kind === 'energy') return '能量';
  if (kind === 'role') return c.roles.find((r) => r.key === item)?.name ?? item;
  if (kind === 'blueprint') return `${c.buildings.find((x) => x.key === item)?.name ?? item}图纸`;
  if (kind === 'egg') return c.companions?.find((x) => x.key === item)?.name ?? EGG_NAMES[item] ?? item;
  return item;
}

function byKey<T>(arr: T[] | undefined, key: (x: T) => string): Map<string, T> {
  return new Map((arr ?? []).map((x) => [key(x), x]));
}

/** Old → new list over the fields this page edits. */
function diff(base: Config, draft: Config): Change[] {
  const out: Change[] = [];
  const push = (path: string, label: string, a: unknown, b: unknown) => {
    if (a !== b) out.push({ path, label, from: a as string | number, to: b as string | number });
  };
  for (const f of TOP_FIELDS) push(f.key, f.label, base[f.key], draft[f.key]);
  const bb = byKey(base.buildings, (b) => b.key);
  for (const b of draft.buildings) for (const f of BUILDING_FIELDS) push(`buildings.${b.key}.${f.key}`, `${b.name} · ${f.label}`, bb.get(b.key)?.[f.key], b[f.key]);
  const rr = byKey(base.roles, (r) => r.key);
  for (const r of draft.roles) for (const f of ROLE_FIELDS) push(`roles.${r.key}.${f.key}`, `${r.name} · ${f.label}`, rr.get(r.key)?.[f.key], r[f.key]);
  const bo = byKey(base.bosses, (b) => b.key);
  for (const b of draft.bosses) {
    const old = byKey(bo.get(b.key)?.drops, (d) => d.item);
    for (const d of b.drops) push(`bosses.${b.key}.${d.item}`, `${b.name} · ${dropItemName(draft, d.item, d.kind)} 掉率 %`, old.get(d.item)?.percent, d.percent);
  }
  const ee = byKey(base.energy, (e) => e.sport);
  for (const e of draft.energy) for (const f of ENERGY_FIELDS) push(`energy.${e.sport}.${f.key}`, `${e.name} · ${f.label}`, ee.get(e.sport)?.[f.key], e[f.key]);
  return out;
}

function dropSum(b: BossConf): number {
  return Math.round(b.drops.reduce((s, d) => s + (Number(d.percent) || 0), 0) * 100) / 100;
}

const clone = (c: Config): Config => JSON.parse(JSON.stringify(c)) as Config;

export default function GameplayPage() {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const { can } = useAuth();
  const canEdit = can('gameplay.edit');
  const canPublish = can('gameplay.publish');
  const adminName = useAdminNames();
  const [params, setParams] = useSearchParams();
  const tab = (params.get('tab') as Tab) || 'buildings';
  const q = useQuery({ queryKey: ['gameplay'], queryFn: api.gameplay });
  const [draft, setDraft] = useState<Config | null>(null);
  const [rollout, setRollout] = useState<10 | 100>(10);
  const [note, setNote] = useState('');

  const current = q.data?.current;
  useEffect(() => {
    if (current) setDraft(clone(current.body));
  }, [current]);

  const changes = useMemo(() => (current && draft ? diff(current.body, draft) : []), [current, draft]);
  const changed = useMemo(() => new Set(changes.map((c) => c.path)), [changes]);
  const badBosses = (draft?.bosses ?? []).filter((b) => Math.abs(dropSum(b) - 100) > 1e-6);

  const onState = (msg: string) => (s: GameplayState) => {
    qc.setQueryData(['gameplay'], s);
    toastOk(msg);
  };
  const publish = useMutation({
    mutationFn: () => api.publishGameplay({ body: draft!, note: note.trim(), rollout_pct: rollout }),
    onSuccess: (s) => {
      setNote('');
      onState(`已发布 ${s.current.version}，${s.current.rollout_pct < 100 ? `先对 ${s.current.rollout_pct}% 用户生效` : '全量生效'}`)(s);
    },
  });
  const rolloutAll = useMutation({ mutationFn: () => api.rolloutGameplay(100), onSuccess: onState('已推到全量') });
  const rollback = useMutation({ mutationFn: () => api.rollbackGameplay(), onSuccess: (s) => onState(`已回滚到 ${s.current.version}`)(s) });

  if (!q.data || !draft || !current) {
    return (
      <>
        <PageHeader title="玩法配置" />
        <Skeleton active paragraph={{ rows: 14 }} />
      </>
    );
  }
  const state = q.data;

  const disabledReason = !canPublish
    ? '只有管理员可以发布玩法配置'
    : changes.length === 0
      ? '没有未发布的改动'
      : badBosses.length
        ? `${badBosses.map((b) => b.name).join('、')} 掉落合计不是 100%`
        : !note.trim()
          ? '请填写发布说明'
          : null;

  const set = (fn: (c: Config) => void) =>
    setDraft((d) => {
      if (!d) return d;
      const n = clone(d);
      fn(n);
      return n;
    });

  const cell = (path: string, value: number, onChange: (v: number) => void, opts: { min?: number; max?: number; step?: number; precision?: number; width?: number } = {}) => (
    <InputNumber
      className={`num${changed.has(path) ? ' cell-changed' : ''}`}
      disabled={!canEdit}
      min={opts.min ?? 0}
      max={opts.max}
      step={opts.step ?? 1}
      precision={opts.precision ?? 0}
      value={value}
      style={{ width: opts.width ?? 96 }}
      onChange={(v) => onChange(v ?? 0)}
    />
  );

  const confirmPublish = () =>
    modal.confirm({
      title: rollout === 100 ? '全量发布玩法配置？' : '发布到 10% 用户？',
      content: (
        <div>
          共 {changes.length} 处改动，基于 {current.version}。{rollout === 100 ? '所有用户立即拿到新配置。' : '按用户 ID 分桶，10% 用户先拿到新版本，确认无误后再推到全量。'}
          怪兽掉落概率会同步到 App 公示。
        </div>
      ),
      okText: '发布',
      cancelText: '取消',
      onOk: () => publish.mutateAsync(),
    });

  const tabs: Record<Tab, ReactNode> = {
    buildings: (
      <Panel title="建筑" extra={<span className="panel-hint">每块领地 {draft.slots_per_territory ?? 6} 个建造位</span>}>
        <Table<BuildingConf>
          rowKey="key"
          pagination={false}
          dataSource={draft.buildings}
          scroll={{ x: 640 }}
          columns={[
            {
              title: '建筑',
              key: 'name',
              render: (_, b) => (
                <Space>
                  <span style={{ width: 40, height: 40, borderRadius: 10, background: BRAND.lavender, border: '1.5px solid #141414', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontWeight: 800 }}>{b.name.slice(0, 1)}</span>
                  <div>
                    <b>{b.name}</b>
                    <div className="muted" style={{ fontSize: 12 }}>
                      {b.note}
                    </div>
                  </div>
                </Space>
              ),
            },
            ...BUILDING_FIELDS.map((f) => ({
              title: f.label,
              key: f.key,
              align: 'center' as const,
              render: (_: unknown, b: BuildingConf, i: number) =>
                cell(`buildings.${b.key}.${f.key}`, b[f.key] as number, (v) => set((c) => ((c.buildings[i][f.key] as number) = v)), f.key === 'unlock_level' ? { min: 1, max: 20, width: 72 } : {}),
            })),
          ]}
        />
      </Panel>
    ),
    roles: (
      <Panel title="角色招募" extra={<span className="panel-hint">运动类型决定招募哪个角色</span>}>
        <Table<RoleConf>
          rowKey="key"
          pagination={false}
          dataSource={draft.roles}
          scroll={{ x: 720 }}
          columns={[
            { title: '角色', key: 'name', render: (_, r) => <b>{r.name}</b> },
            { title: '运动', dataIndex: 'sport', render: (v: string) => <Tag bordered={false}>{SPORT_LABEL[v] ?? v}</Tag> },
            {
              title: '招募需',
              key: 'threshold',
              render: (_, r, i) => (
                <Space>
                  {cell(`roles.${r.key}.threshold`, r.threshold, (v) => set((c) => (c.roles[i].threshold = v)), { min: 0.1, precision: 1 })}
                  <span className="muted">{UNIT_LABEL[r.unit] ?? r.unit}</span>
                </Space>
              ),
            },
            { title: '加成数值', key: 'buff_value', render: (_, r, i) => cell(`roles.${r.key}.buff_value`, r.buff_value, (v) => set((c) => (c.roles[i].buff_value = v)), { precision: 1, width: 80 }) },
            {
              title: '加成说明（App 展示）',
              key: 'buff_text',
              render: (_, r, i) => (
                <Input
                  disabled={!canEdit}
                  className={changed.has(`roles.${r.key}.buff_text`) ? 'cell-changed' : undefined}
                  value={r.buff_text}
                  style={{ width: 180 }}
                  onChange={(e) => set((c) => (c.roles[i].buff_text = e.target.value))}
                />
              ),
            },
          ]}
        />
      </Panel>
    ),
    drops: (
      <Panel title="怪兽掉落表" extra={<span className="panel-hint">每只怪兽合计必须等于 100% 才能发布</span>}>
        <Row gutter={[16, 16]}>
          {draft.bosses.map((b, bi) => {
            const sum = dropSum(b);
            const ok = Math.abs(sum - 100) < 1e-6;
            const nameOf = (item: string, kind: string) => dropItemName(draft, item, kind);
            return (
              <Col xs={24} xxl={12} key={b.key}>
                <div className="tile" style={{ background: '#fafafb', border: ok ? '1px solid #ececef' : `1.5px solid ${BRAND.red}`, borderRadius: 18 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
                    <b style={{ fontSize: 15 }}>{b.name}</b>
                    <span className={ok ? 'num' : 'num danger-text'} style={{ fontWeight: 700 }}>
                      合计 {sum}% {ok ? <CheckCircleOutlined style={{ color: BRAND.green }} /> : `· 差 ${Math.round((100 - sum) * 100) / 100}%`}
                    </span>
                  </div>
                  {b.drops.map((d, di) => (
                    <div key={d.item} style={{ display: 'grid', gridTemplateColumns: '1fr 64px 92px 80px', gap: 8, alignItems: 'center', padding: '4px 0' }}>
                      <span>{nameOf(d.item, d.kind)}</span>
                      <span className="muted" style={{ fontSize: 12 }}>
                        {DROP_KIND[d.kind] ?? d.kind}
                      </span>
                      {cell(`bosses.${b.key}.${d.item}`, d.percent, (v) => set((c) => (c.bosses[bi].drops[di].percent = v)), { max: 100, precision: 1, width: 88 })}
                      <div className="bar-track">
                        <div className="bar-fill" style={{ width: `${Math.min(100, d.percent)}%`, background: d.kind === 'egg' ? BRAND.lavender : BRAND.ink }} />
                      </div>
                    </div>
                  ))}
                </div>
              </Col>
            );
          })}
        </Row>
        <div className="muted" style={{ fontSize: 12, marginTop: 12 }}>
          按规定，随机掉落的概率会在 App 的怪兽页面原样公示，发布后自动同步。掉落只能通过运动获得，不提供付费抽取。
        </div>
      </Panel>
    ),
    energy: (() => {
      const run = draft.energy.find((e) => e.sport === 'run');
      const e5 = run ? Math.floor((5 / run.per) * run.energy) : 0;
      const affordable = draft.buildings.filter((b) => b.cost <= e5).map((b) => b.name);
      return (
        <Panel title="能量换算" extra={<span className="panel-hint">所有运动统一折算成能量，用来建城、攻打怪兽</span>}>
          <Table<EnergyRule>
            rowKey="sport"
            pagination={false}
            dataSource={draft.energy}
            columns={[
              {
                title: '运动',
                key: 'name',
                render: (_, e) => (
                  <Space>
                    <b>{e.name}</b>
                    {e.pending && (
                      <Tooltip title="产品文档尚未给出数值，暂用占位">
                        <Tag color="gold" bordered={false}>
                          待定
                        </Tag>
                      </Tooltip>
                    )}
                  </Space>
                ),
              },
              {
                title: '换算标准',
                key: 'rule',
                render: (_, e, i) => (
                  <Space wrap>
                    <span>每</span>
                    {cell(`energy.${e.sport}.per`, e.per, (v) => set((c) => (c.energy[i].per = v)), { min: 0.1, precision: 1, width: 84 })}
                    <span>{UNIT_LABEL[e.unit] ?? e.unit} =</span>
                    {cell(`energy.${e.sport}.energy`, e.energy, (v) => set((c) => (c.energy[i].energy = v)), { width: 80 })}
                    <span>能量</span>
                  </Space>
                ),
              },
            ]}
          />
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 16, flexWrap: 'wrap' }}>
            <b>每人每日能量上限</b>
            {cell('daily_energy_cap', draft.daily_energy_cap, (v) => set((c) => (c.daily_energy_cap = v)), { min: 1, step: 10, width: 110 })}
          </div>
          {run && (
            <Alert
              style={{ marginTop: 16 }}
              type="success"
              showIcon={false}
              message={
                <span>
                  示例：跑 5 km = <b className="num">{e5}</b> 能量，可建 {affordable.length ? <b>{affordable.join('、')}</b> : '（还不够建任何建筑）'}
                </span>
              }
            />
          )}
        </Panel>
      );
    })(),
  };

  return (
    <>
      <PageHeader
        title="玩法配置"
        sub={`线上版本 ${current.version}${current.rollout_pct < 100 ? `（灰度 ${current.rollout_pct}%）` : ''} · 改动先灰度再全量，可一键回滚`}
        extra={
          <Segmented
            size="large"
            value={tab}
            onChange={(v) => setParams(v === 'buildings' ? {} : { tab: String(v) })}
            options={[
              { label: '建筑', value: 'buildings' },
              { label: '角色', value: 'roles' },
              {
                label: (
                  <span>
                    怪兽掉落
                    {badBosses.length > 0 && <span style={{ display: 'inline-block', width: 7, height: 7, borderRadius: 4, background: BRAND.red, marginLeft: 4, verticalAlign: 'top' }} />}
                  </span>
                ),
                value: 'drops',
              },
              { label: '能量换算', value: 'energy' },
            ]}
          />
        }
      />
      {!canEdit && <Alert type="info" showIcon message="当前角色只能查看玩法配置" />}
      <Row gutter={[20, 20]}>
        <Col xs={24} xl={15} xxl={16}>
          {tabs[tab]}
        </Col>
        <Col xs={24} xl={9} xxl={8}>
          <Panel
            grey
            style={{ height: 'auto', position: 'sticky', top: 24 }}
            title="未发布改动"
            extra={<Badge count={changes.length} showZero color={changes.length ? BRAND.ink : '#bdbdc2'} />}
          >
            {changes.length === 0 ? (
              <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="没有改动，改一下左侧数值试试" />
            ) : (
              <div style={{ maxHeight: 300, overflow: 'auto' }}>
                {changes.map((c) => (
                  <div className="diff-row" key={c.path}>
                    <span>{c.label}</span>
                    <span className="num" style={{ whiteSpace: 'nowrap' }}>
                      <span className="diff-old">{String(c.from ?? '—')}</span> → <span className="diff-new">{String(c.to)}</span>
                    </span>
                  </div>
                ))}
              </div>
            )}
            {badBosses.length > 0 && (
              <Alert style={{ marginTop: 12 }} type="error" showIcon message={`${badBosses.map((b) => `${b.name} ${dropSum(b)}%`).join('、')}：掉落合计必须等于 100%`} />
            )}

            {canPublish ? (
              <>
            <Input.TextArea
              style={{ marginTop: 14 }}
              rows={2}
              maxLength={100}
              placeholder="发布说明（必填），例如：冬季赛季掉落调整"
              value={note}
              disabled={changes.length === 0}
              onChange={(e) => setNote(e.target.value)}
            />
            <Segmented
              block
              style={{ marginTop: 12 }}
              value={rollout}
              onChange={(v) => setRollout(v as 10 | 100)}
              options={[
                { label: '灰度 10%', value: 10 },
                { label: '全量', value: 100 },
              ]}
            />
            <Tooltip title={disabledReason}>
              <Button type="primary" size="large" block style={{ marginTop: 12 }} disabled={!!disabledReason} loading={publish.isPending} onClick={confirmPublish}>
                {rollout === 100 ? '全量发布' : '发布到 10% 用户'}
              </Button>
            </Tooltip>
              </>
            ) : (
              <Alert style={{ marginTop: 14 }} type="info" showIcon message="只有管理员可以发布玩法配置" description="可以在左侧试改数值查看差异，确认后请管理员发布（先 10% 灰度再全量）。" />
            )}
            <Button block style={{ marginTop: 10 }} disabled={changes.length === 0} onClick={() => setDraft(clone(current.body))}>
              撤销全部改动
            </Button>

            <div style={{ borderTop: '1px solid #dcdce0', margin: '20px 0 14px' }} />
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
              <div>
                <b>线上 {current.version}</b>{' '}
                <Tag bordered={false} color={current.rollout_pct < 100 ? 'gold' : 'success'}>
                  {current.rollout_pct < 100 ? `灰度 ${current.rollout_pct}%` : '全量'}
                </Tag>
                <div className="muted" style={{ fontSize: 12 }}>
                  {current.note || '—'} · {adminName(current.published_by)} · {dt(current.published_at)}
                </div>
              </div>
              <Space>
                {current.rollout_pct < 100 && (
                  <Button
                    type="primary"
                    size="small"
                    disabled={!canPublish}
                    loading={rolloutAll.isPending}
                    onClick={() =>
                      modal.confirm({ title: `把 ${current.version} 推到全量？`, content: '所有用户都会拿到这个版本。', okText: '推到全量', cancelText: '取消', onOk: () => rolloutAll.mutateAsync() })
                    }
                  >
                    推到全量
                  </Button>
                )}
                <Tooltip title={!state.previous ? '没有上一个版本' : !canPublish ? '只有管理员可以回滚' : `回到 ${state.previous.version}`}>
                  <Button
                    size="small"
                    icon={<RollbackOutlined />}
                    disabled={!canPublish || !state.previous}
                    loading={rollback.isPending}
                    onClick={() =>
                      modal.confirm({
                        title: `撤回 ${current.version}？`,
                        content: `回到上一个版本 ${state.previous?.version}（${state.previous?.note ?? ''}）。未发布的改动会被丢弃。`,
                        okText: '回滚',
                        okButtonProps: { danger: true },
                        cancelText: '取消',
                        onOk: () => rollback.mutateAsync(),
                      })
                    }
                  >
                    回滚
                  </Button>
                </Tooltip>
              </Space>
            </div>

            <div style={{ marginTop: 16 }}>
              <b>发布记录</b>
              {state.history.map((h) => (
                <div key={h.version + h.published_at} style={{ display: 'flex', gap: 8, fontSize: 13, padding: '6px 0', alignItems: 'baseline' }}>
                  <b className="num">{h.version}</b>
                  <span className="muted num" style={{ fontSize: 12 }}>
                    {dt(h.published_at, 'MM/DD')}
                  </span>
                  <span style={{ flex: 1 }}>
                    {h.note}
                    {h.rollout_pct < 100 && <Tag style={{ marginLeft: 6 }} bordered={false} color="gold">{h.rollout_pct}%</Tag>}
                  </span>
                  <span className="muted">{adminName(h.published_by)}</span>
                </div>
              ))}
            </div>
          </Panel>
        </Col>
      </Row>
    </>
  );
}
