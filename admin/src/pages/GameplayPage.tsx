import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, App, Badge, Button, Checkbox, Col, Empty, Input, InputNumber, Row, Segmented, Select, Skeleton, Space, Table, Tag, Tooltip } from 'antd';
import { ArrowDownOutlined, ArrowUpOutlined, CheckCircleOutlined, DeleteOutlined, PlusOutlined, RollbackOutlined } from '@ant-design/icons';
import { Link } from 'react-router-dom';
import { api } from '../api/admin';
import type { BuildingConf, Config, EnergyRule, GameplayState, MedalConf, MedalType, RoleConf, SeasonTaskConf, SeasonTaskType, WorkoutConf } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import { useAdminNames } from '../hooks/useAdminNames';
import { PageHeader, Panel } from '../components/ui';
import { dt } from '../utils/format';
import { DROP_KIND, MEDAL_TYPE, SEASON_TASK_TYPE, SPORT_LABEL, UNIT_LABEL, WORKOUT_LEVEL, WORKOUT_POSE, WORKOUT_SPORTS } from '../utils/labels';
import {
  AI_FIELDS,
  BOSS_GROUPS,
  BUILDING_FIELDS,
  CHEST_FIELDS,
  clone,
  COMPANION_FIELDS,
  DEFAULTS,
  DEFENSE_FIELDS,
  diff,
  dropItemName,
  dropSum,
  normalize,
  RELAY_FIELDS,
  TABS,
  validate,
  workoutMinutes,
  type NumField,
  type Tab,
} from './gameplay/config';
import { toastOk } from '../utils/notify';
import { BRAND } from '../theme';

export default function GameplayPage() {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const { can } = useAuth();
  const canEdit = can('gameplay.edit');
  const canPublish = can('gameplay.publish');
  const adminName = useAdminNames();
  const [params, setParams] = useSearchParams();
  const tab = (TABS.find((t) => t.value === params.get('tab'))?.value ?? 'buildings') as Tab;
  const q = useQuery({ queryKey: ['gameplay'], queryFn: api.gameplay });
  const [draft, setDraft] = useState<Config | null>(null);
  const [rollout, setRollout] = useState<10 | 100>(10);
  const [note, setNote] = useState('');

  const current = q.data?.current;
  useEffect(() => {
    if (current) setDraft(normalize(current.body));
  }, [current]);

  const base = useMemo(() => (current ? normalize(current.body) : null), [current]);
  const changes = useMemo(() => (base && draft ? diff(base, draft) : []), [base, draft]);
  const changed = useMemo(() => new Set(changes.map((c) => c.path)), [changes]);
  const problems = useMemo(() => (draft ? validate(draft) : []), [draft]);
  const badTabs = new Set(problems.map((p) => p.tab));
  const changedTabs = new Set(changes.map((c) => c.tab));

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
      : problems.length
        ? problems[0].text
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

  const fieldGrid = <K extends string>(section: string, obj: Record<K, number>, fields: NumField<K>[], onChange: (k: K, v: number) => void) => (
    <Row gutter={[16, 16]}>
      {fields.map((f) => (
        <Col xs={24} sm={12} xxl={8} key={f.key}>
          <div className="field-cell">
            <div style={{ fontWeight: 600, fontSize: 13 }}>{f.label}</div>
            <Space style={{ marginTop: 6 }}>
              {cell(`${section}.${f.key}`, obj[f.key], (v) => onChange(f.key, v), { min: f.min, max: f.max, step: f.step, precision: f.precision ?? 0, width: 120 })}
              {f.unit && <span className="muted">{f.unit}</span>}
            </Space>
            {f.hint && (
              <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
                {f.hint}
              </div>
            )}
          </div>
        </Col>
      ))}
    </Row>
  );

  /** A pre-V2 config has no such section yet: offer to add it with the contract defaults. */
  const missing = (title: string, add: () => void) => (
    <Panel title={title}>
      <Empty description="线上配置还没有这一部分（V2 之前发布的版本）">
        <Button type="primary" disabled={!canEdit} onClick={add}>
          按默认值添加
        </Button>
      </Empty>
    </Panel>
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
          scroll={{ x: 760 }}
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
            {
              title: (
                <Tooltip title="拥有这个建筑的图纸（怪兽掉落）就可以无视解锁等级建造">
                  <span>图纸可越级建造</span>
                </Tooltip>
              ),
              key: 'blueprint_bypass_level',
              align: 'center' as const,
              render: (_: unknown, b: BuildingConf, i: number) => (
                <span className={changed.has(`buildings.${b.key}.blueprint_bypass_level`) ? 'check-changed' : undefined}>
                  <Checkbox
                    disabled={!canEdit}
                    checked={!!b.blueprint_bypass_level}
                    aria-label={`${b.name} 图纸可越级建造`}
                    onChange={(e) => set((c) => (c.buildings[i].blueprint_bypass_level = e.target.checked))}
                  />
                </span>
              ),
            },
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

    boss: !draft.boss
      ? missing('怪兽', () => set((c) => (c.boss = clone(DEFAULTS.boss))))
      : (
          <Panel title="怪兽" extra={<span className="panel-hint">掉落表在「怪兽掉落」；这里是伤害、合击、投放与结算规则</span>}>
            {BOSS_GROUPS.map((g) => (
              <div key={g.title} style={{ marginBottom: 20 }}>
                <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 10 }}>
                  <b style={{ fontSize: 15 }}>{g.title}</b>
                  <span className="muted" style={{ fontSize: 12 }}>
                    {g.hint}
                  </span>
                </div>
                {fieldGrid('boss', draft.boss as unknown as Record<string, number>, g.fields, (k, v) => set((c) => ((c.boss as unknown as Record<string, number>)[k] = v)))}
              </div>
            ))}
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 10 }}>
              <b style={{ fontSize: 15 }}>运动伤害</b>
              <span className="muted" style={{ fontSize: 12 }}>
                GPS 运动按轨迹落在范围内的距离计；居家运动需先「出战」，按数量计
              </span>
            </div>
            <Table
              rowKey="sport"
              size="small"
              pagination={false}
              dataSource={draft.boss.damage}
              columns={[
                { title: '运动', dataIndex: 'sport', render: (v: string) => <b>{SPORT_LABEL[v] ?? v}</b> },
                {
                  title: '伤害规则',
                  key: 'rule',
                  render: (_, d, i) => (
                    <Space wrap>
                      <span>每</span>
                      {cell(`boss.damage.${d.sport}.per`, d.per, (v) => set((c) => (c.boss!.damage[i].per = v)), { min: 0.1, precision: 1, width: 84 })}
                      <span>{UNIT_LABEL[d.unit] ?? d.unit} =</span>
                      {cell(`boss.damage.${d.sport}.damage`, d.damage, (v) => set((c) => (c.boss!.damage[i].damage = v)), { width: 84 })}
                      <span>伤害</span>
                    </Space>
                  ),
                },
                { title: 'GPS', dataIndex: 'unit', align: 'center', render: (u: string) => (u === 'km' || u === 'm' ? <Tag bordered={false} color="green">自动</Tag> : <Tag bordered={false}>需出战</Tag>) },
              ]}
            />
          </Panel>
        ),

    chest: !draft.chest
      ? missing('宝箱', () => set((c) => (c.chest = clone(DEFAULTS.chest))))
      : (
          <Panel title="宝箱" extra={<span className="panel-hint">每天 06:00 刷新；深夜 23:00–05:00 不刷新；宝箱能量不计入每日上限</span>}>
            {fieldGrid('chest', draft.chest as unknown as Record<string, number>, CHEST_FIELDS, (k, v) => set((c) => ((c.chest as unknown as Record<string, number>)[k] = v)))}
            <Alert style={{ marginTop: 16 }} type="info" showIcon={false} message={`每个宝箱随机给 ${draft.chest.energy_min}–${draft.chest.energy_max} 能量；药剂师有概率翻倍。`} />
          </Panel>
        ),

    defense: !draft.defense
      ? missing('守地', () => set((c) => (c.defense = clone(DEFAULTS.defense))))
      : (
          <Panel title="守地挑战" extra={<span className="panel-hint">加固：守卫值 += 本次运动能量</span>}>
            {fieldGrid('defense', draft.defense as unknown as Record<string, number>, DEFENSE_FIELDS, (k, v) => set((c) => ((c.defense as unknown as Record<string, number>)[k] = v)))}
          </Panel>
        ),

    tiers: !draft.season
      ? missing('赛季段位', () => set((c) => (c.season = clone(DEFAULTS.season))))
      : (
          <Panel
            title="赛季段位"
            extra={
              <Button size="small" icon={<PlusOutlined />} disabled={!canEdit || draft.season.tiers.length >= 10} onClick={() => set((c) => c.season!.tiers.push({ name: '', min_km2: (c.season!.tiers.at(-1)?.min_km2 ?? 0) + 5 }))}>
                添加段位
              </Button>
            }
          >
            <Table
              rowKey="_row"
              size="small"
              pagination={false}
              dataSource={draft.season.tiers.map((x, i) => ({ ...x, _row: i }))}
              columns={[
                { title: '#', key: 'i', width: 40, render: (_, __, i) => <span className="muted num">{i + 1}</span> },
                {
                  title: '段位名称',
                  key: 'name',
                  render: (_, t, i) => (
                    <Input
                      disabled={!canEdit}
                      value={t.name}
                      maxLength={6}
                      style={{ width: 120 }}
                      status={!t.name.trim() ? 'error' : undefined}
                      className={changed.has(`season.tiers.${i}.name`) ? 'cell-changed' : undefined}
                      onChange={(e) => set((c) => (c.season!.tiers[i].name = e.target.value))}
                    />
                  ),
                },
                {
                  title: '赛季内新圈面积 ≥',
                  key: 'min',
                  render: (_, t, i) => {
                    const prev = draft.season!.tiers[i - 1];
                    const wrong = i === 0 ? t.min_km2 !== 0 : !(t.min_km2 > prev.min_km2);
                    return (
                      <Space>
                        <InputNumber
                          className={`num${changed.has(`season.tiers.${i}.min_km2`) && !wrong ? ' cell-changed' : ''}`}
                          disabled={!canEdit || i === 0}
                          min={0}
                          step={0.5}
                          precision={2}
                          value={t.min_km2}
                          status={wrong ? 'error' : undefined}
                          style={{ width: 110 }}
                          onChange={(v) => set((c) => (c.season!.tiers[i].min_km2 = v ?? 0))}
                        />
                        <span className="muted">km²</span>
                      </Space>
                    );
                  },
                },
                {
                  title: 'III / II / I 起点',
                  key: 'sub',
                  render: (_, t, i) => {
                    const next = draft.season!.tiers[i + 1];
                    if (!next) return <span className="muted">最高段位，不再细分</span>;
                    const step = (next.min_km2 - t.min_km2) / 3;
                    if (!(step > 0)) return <span className="danger-text">须小于下一段</span>;
                    return <span className="num muted">{[0, 1, 2].map((k) => (t.min_km2 + step * k).toFixed(2)).join(' / ')}</span>;
                  },
                },
                {
                  title: '',
                  key: 'op',
                  align: 'right',
                  render: (_, __, i) => (
                    <Button size="small" type="text" danger icon={<DeleteOutlined />} aria-label="删除段位" disabled={!canEdit || i === 0 || draft.season!.tiers.length <= 2} onClick={() => set((c) => c.season!.tiers.splice(i, 1))} />
                  ),
                },
              ]}
            />
            <div className="muted" style={{ fontSize: 12, marginTop: 10 }}>
              第一个段位从 0 开始，之后必须逐段递增。每段按最低面积到下一段最低面积平均分成 III / II / I。
            </div>
          </Panel>
        ),

    tasks: !draft.season_tasks
      ? missing('赛季任务', () => set((c) => (c.season_tasks = clone(DEFAULTS.season_tasks))))
      : (
          <Panel
            title="赛季任务"
            extra={
              <Space>
                <span className="panel-hint">每周一刷新</span>
                <Button size="small" icon={<PlusOutlined />} disabled={!canEdit} onClick={() => set((c) => c.season_tasks!.push({ key: '', name: '', type: 'weekly_count', target: 1, reward_energy: 50 }))}>
                  添加任务
                </Button>
              </Space>
            }
          >
            <Table<SeasonTaskConf>
              rowKey="_row"
              size="small"
              pagination={false}
              dataSource={draft.season_tasks.map((x, i) => ({ ...x, _row: i }))}
              scroll={{ x: 760 }}
              columns={[
                {
                  title: 'key',
                  key: 'key',
                  render: (_, t, i) => (
                    <Input disabled={!canEdit} value={t.key} style={{ width: 140, fontFamily: 'monospace' }} status={!/^[a-z][a-z0-9_]*$/.test(t.key) ? 'error' : undefined} placeholder="weekly_runs" onChange={(e) => set((c) => (c.season_tasks![i].key = e.target.value.trim()))} />
                  ),
                },
                {
                  title: '名称（App 展示）',
                  key: 'name',
                  render: (_, t, i) => (
                    <Input disabled={!canEdit} value={t.name} style={{ width: 200 }} className={changed.has(`season_tasks.${t.key}.name`) ? 'cell-changed' : undefined} status={!t.name.trim() ? 'error' : undefined} onChange={(e) => set((c) => (c.season_tasks![i].name = e.target.value))} />
                  ),
                },
                {
                  title: '类型',
                  key: 'type',
                  render: (_, t, i) => (
                    <Select<SeasonTaskType>
                      disabled={!canEdit}
                      value={t.type}
                      style={{ width: 150 }}
                      className={changed.has(`season_tasks.${t.key}.type`) ? 'cell-changed' : undefined}
                      options={Object.entries(SEASON_TASK_TYPE).map(([k, v]) => ({ value: k as SeasonTaskType, label: v.text }))}
                      onChange={(v) => set((c) => (c.season_tasks![i].type = v))}
                    />
                  ),
                },
                {
                  title: '目标',
                  key: 'target',
                  render: (_, t, i) => (
                    <Space>
                      {cell(`season_tasks.${t.key}.target`, t.target, (v) => set((c) => (c.season_tasks![i].target = v)), { min: 0, precision: t.type === 'weekly_distance_km' ? 1 : 0, width: 100, step: t.type === 'weekly_area_m2' ? 5000 : 1 })}
                      <span className="muted">{SEASON_TASK_TYPE[t.type]?.unit}</span>
                    </Space>
                  ),
                },
                { title: '奖励能量', key: 'reward', render: (_, t, i) => cell(`season_tasks.${t.key}.reward_energy`, t.reward_energy, (v) => set((c) => (c.season_tasks![i].reward_energy = v)), { step: 10, width: 90 }) },
                {
                  title: '',
                  key: 'op',
                  align: 'right',
                  render: (_, __, i) => <Button size="small" type="text" danger icon={<DeleteOutlined />} aria-label="删除任务" disabled={!canEdit} onClick={() => set((c) => c.season_tasks!.splice(i, 1))} />,
                },
              ]}
            />
            <div className="muted" style={{ fontSize: 12, marginTop: 10 }}>
              任务奖励能量不计入每日上限。key 是稳定标识，上线后不要改，改了相当于删掉旧任务、新建一个。
            </div>
          </Panel>
        ),

    medals: (
      <Panel
        title="奖牌"
        extra={
          <Button size="small" icon={<PlusOutlined />} disabled={!canEdit} onClick={() => set((c) => (c.medals = [...(c.medals ?? []), { key: '', name: '', type: 'distance_km', target: 1, distance_km: 1 }]))}>
            添加奖牌
          </Button>
        }
      >
        {!draft.medals?.length ? (
          <Empty description="还没有奖牌">
            <Button disabled={!canEdit} onClick={() => set((c) => (c.medals = clone(DEFAULTS.medals)))}>
              按默认值添加
            </Button>
          </Empty>
        ) : (
          <Table<MedalConf>
            rowKey="_row"
            size="small"
            pagination={false}
            dataSource={draft.medals.map((x, i) => ({ ...x, _row: i }))}
            scroll={{ x: 680 }}
            columns={[
              {
                title: 'key',
                key: 'key',
                render: (_, m, i) => (
                  <Input disabled={!canEdit} value={m.key} style={{ width: 150, fontFamily: 'monospace' }} status={!/^[a-z][a-z0-9_]*$/.test(m.key) ? 'error' : undefined} placeholder="distance_100" onChange={(e) => set((c) => (c.medals![i].key = e.target.value.trim()))} />
                ),
              },
              {
                title: '名称',
                key: 'name',
                render: (_, m, i) => (
                  <Input disabled={!canEdit} value={m.name} style={{ width: 140 }} className={changed.has(`medals.${m.key}.name`) ? 'cell-changed' : undefined} status={!m.name.trim() ? 'error' : undefined} onChange={(e) => set((c) => (c.medals![i].name = e.target.value))} />
                ),
              },
              {
                title: '类型',
                key: 'type',
                render: (_, m, i) => (
                  <Select<MedalType>
                    disabled={!canEdit}
                    value={m.type ?? 'distance_km'}
                    style={{ width: 150 }}
                    className={changed.has(`medals.${m.key}.type`) ? 'cell-changed' : undefined}
                    options={Object.entries(MEDAL_TYPE).map(([k, v]) => ({ value: k as MedalType, label: v.text }))}
                    onChange={(v) =>
                      set((c) => {
                        const x = c.medals![i];
                        x.type = v;
                        if (v === 'distance_km') x.distance_km = x.target;
                        else delete x.distance_km;
                      })
                    }
                  />
                ),
              },
              {
                title: '目标',
                key: 'target',
                render: (_, m, i) => (
                  <Space>
                    {cell(`medals.${m.key}.target`, m.target ?? 0, (v) =>
                      set((c) => {
                        const x = c.medals![i];
                        x.target = v;
                        if ((x.type ?? 'distance_km') === 'distance_km') x.distance_km = v; // legacy field kept in sync
                      }),
                      { width: 100 },
                    )}
                    <span className="muted">{MEDAL_TYPE[m.type ?? 'distance_km']?.unit}</span>
                  </Space>
                ),
              },
              {
                title: '',
                key: 'op',
                align: 'right',
                render: (_, __, i) => <Button size="small" type="text" danger icon={<DeleteOutlined />} aria-label="删除奖牌" disabled={!canEdit} onClick={() => set((c) => c.medals!.splice(i, 1))} />,
              },
            ]}
          />
        )}
        <div className="muted" style={{ fontSize: 12, marginTop: 10 }}>
          成就奖牌带进度，达到目标即获得；赛季段位奖牌在赛季结算时按最终段位自动发放，不在这里配置。累计里程类型同时写旧字段 distance_km 以兼容旧版 App。
        </div>
      </Panel>
    ),

    companion: !draft.companion
      ? missing('伙伴养成', () => set((c) => (c.companion = clone(DEFAULTS.companion))))
      : (
          <Panel title="跑步伙伴养成" extra={<span className="panel-hint">伙伴仍然不提供对抗加成</span>}>
            {fieldGrid('companion', draft.companion as unknown as Record<string, number>, COMPANION_FIELDS, (k, v) => set((c) => ((c.companion as unknown as Record<string, number>)[k] = v)))}
            <Alert
              style={{ marginTop: 16 }}
              type="success"
              showIcon={false}
              message={
                <span>
                  示例：陪跑 5 km 得 <b className="num">{Math.round(draft.companion.exp_per_100m * 50 * 10) / 10}</b> 经验，升 1 级约需陪跑{' '}
                  <b className="num">{draft.companion.exp_per_100m > 0 ? ((draft.companion.exp_per_level / draft.companion.exp_per_100m) * 0.1).toFixed(1) : '—'}</b> km 或喂{' '}
                  <b className="num">{draft.companion.feed_exp > 0 ? Math.ceil(draft.companion.exp_per_level / draft.companion.feed_exp) : '—'}</b> 次
                </span>
              }
            />
          </Panel>
        ),

    relay: !draft.relay
      ? missing('跑团接力', () => set((c) => (c.relay = clone(DEFAULTS.relay))))
      : (
          <Panel title="跑团接力" extra={<span className="panel-hint">团长发起；每位成员一次 GPS 运动跑满单棒距离算一棒</span>}>
            {fieldGrid('relay', draft.relay as unknown as Record<string, number>, RELAY_FIELDS, (k, v) => set((c) => ((c.relay as unknown as Record<string, number>)[k] = v)))}
            <Alert
              style={{ marginTop: 16 }}
              type="info"
              showIcon={false}
              message={`默认 ${draft.relay.default_legs} 棒 × ${draft.relay.leg_km} km = ${Math.round(draft.relay.default_legs * draft.relay.leg_km * 10) / 10} km，${Math.round(draft.relay.duration_h / 24)} 天内完成，全员各得 ${draft.relay.reward_energy} 能量。`}
            />
          </Panel>
        ),

    workouts: !draft.workouts
      ? missing('AI 跟练', () => set((c) => (c.workouts = clone(DEFAULTS.workouts))))
      : (
          <Panel
            title="AI 跟练动作库"
            extra={
              <Space>
                <span className="panel-hint">App 端姿态识别计次，画面不上传；只换能量、不圈地</span>
                <Button
                  size="small"
                  icon={<PlusOutlined />}
                  disabled={!canEdit || draft.workouts.length >= 30}
                  onClick={() =>
                    set((c) =>
                      c.workouts!.push({ key: '', name: '', sport: 'rope', level: 'beginner', cover_url: null, est_minutes: 10, camera: true, steps: [{ key: 'step_1', name: '', mode: 'count', target: 20, sets: 3, rest_sec: 30, pose: 'jump', cue: '', demo_url: null }] }),
                    )
                  }
                >
                  添加一套
                </Button>
              </Space>
            }
          >
            {draft.workouts.length === 0 && (
              <Empty description="动作库是空的，App 里不会显示跟练入口">
                <Button disabled={!canEdit} onClick={() => set((c) => (c.workouts = clone(DEFAULTS.workouts)))}>
                  按默认值添加
                </Button>
              </Empty>
            )}
            {draft.workouts.map((w, wi) => (
              <WorkoutCard
                key={wi}
                w={w}
                wi={wi}
                canEdit={canEdit}
                changed={changed}
                cell={cell}
                onChange={(fn) => set((c) => fn(c.workouts![wi]))}
                onDelete={() =>
                  modal.confirm({
                    title: `删除「${w.name || w.key || '未命名'}」？`,
                    content: '发布后 App 里不再显示这套跟练；已完成的训练记录不受影响。',
                    okText: '删除',
                    okButtonProps: { danger: true },
                    cancelText: '取消',
                    onOk: () => set((c) => c.workouts!.splice(wi, 1)),
                  })
                }
              />
            ))}
            <div className="muted" style={{ fontSize: 12, marginTop: 12 }}>
              按次数的动作由摄像头姿态识别自动计次（跳跃 / 深蹲 / 俯卧撑 / 卷腹），识别不稳或没给摄像头权限时退回手动计次；按时长的动作目标单位是秒。上报次数比识别次数多 20% 以上进入风控复核。key 是稳定标识，上线后不要改。
            </div>
          </Panel>
        ),

    ai: !draft.ai
      ? missing('AI', () => set((c) => (c.ai = clone(DEFAULTS.ai))))
      : (
          <Panel title="AI" extra={<span className="panel-hint">模型、Key、单价、免费次数在「系统配置 → AI 大模型」</span>}>
            {fieldGrid('ai', draft.ai as unknown as Record<string, number>, AI_FIELDS, (k, v) => set((c) => ((c.ai as unknown as Record<string, number>)[k] = v)))}
            <Alert
              style={{ marginTop: 16 }}
              type="info"
              showIcon={false}
              message={
                <span>
                  助手每次带最近 <b className="num">{draft.ai.chat_history_turns}</b> 轮对话；路线建议不超过 <b className="num">{draft.ai.route_max_km}</b> km；战报不超过{' '}
                  <b className="num">{draft.ai.report_max_chars}</b> 字。各功能的调用量和费用见 <Link to="/ai-usage">AI 用量</Link>。
                </span>
              }
            />
          </Panel>
        ),
  };

  return (
    <>
      <PageHeader
        title="玩法配置"
        sub={`线上版本 ${current.version}${current.rollout_pct < 100 ? `（灰度 ${current.rollout_pct}%）` : ''} · 改动先灰度再全量，可一键回滚`}
      />
      <div className="tab-strip">
        <Segmented
          value={tab}
          onChange={(v) => setParams(v === 'buildings' ? {} : { tab: String(v) })}
          options={TABS.map((t) => ({
            value: t.value,
            label: (
              <span>
                {t.label}
                {badTabs.has(t.value) ? <span className="tab-dot bad" /> : changedTabs.has(t.value) ? <span className="tab-dot" /> : null}
              </span>
            ),
          }))}
        />
      </div>
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
            {problems.length > 0 && (
              <Alert
                style={{ marginTop: 12 }}
                type="error"
                showIcon
                message={`${problems.length} 处需要修正才能发布`}
                description={
                  <ul style={{ margin: 0, paddingLeft: 16, maxHeight: 160, overflow: 'auto' }}>
                    {problems.map((p, i) => (
                      <li key={i}>
                        <a onClick={() => setParams(p.tab === 'buildings' ? {} : { tab: p.tab })}>{TABS.find((t) => t.value === p.tab)?.label}</a>：{p.text}
                      </li>
                    ))}
                  </ul>
                }
              />
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
            <Button block style={{ marginTop: 10 }} disabled={changes.length === 0} onClick={() => setDraft(normalize(current.body))}>
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

type CellFn = (path: string, value: number, onChange: (v: number) => void, opts?: { min?: number; max?: number; step?: number; precision?: number; width?: number }) => ReactNode;

/** One workout of the AI 跟练 library: header fields + its steps. */
function WorkoutCard({
  w,
  wi,
  canEdit,
  changed,
  cell,
  onChange,
  onDelete,
}: {
  w: WorkoutConf;
  wi: number;
  canEdit: boolean;
  changed: Set<string>;
  cell: CellFn;
  onChange: (fn: (w: WorkoutConf) => void) => void;
  onDelete: () => void;
}) {
  const wk = w.key || `#${wi}`;
  const cls = (path: string) => (changed.has(path) ? 'cell-changed' : undefined);
  const isNew = changed.has(`workouts.${wk}`);
  const est = workoutMinutes(w);
  const keyBad = (k: string) => !/^[a-z][a-z0-9_]*$/.test(k);
  const move = (i: number, d: -1 | 1) =>
    onChange((x) => {
      const [s] = x.steps.splice(i, 1);
      x.steps.splice(i + d, 0, s);
    });
  return (
    <div className="wk-card" data-workout={w.key} style={isNew ? { background: '#f4fbd2' } : undefined}>
      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'flex-end' }}>
        <label className="wk-field">
          <span>key</span>
          <Input disabled={!canEdit} value={w.key} placeholder="rope_basic" style={{ width: 140, fontFamily: 'monospace' }} status={keyBad(w.key) ? 'error' : undefined} onChange={(e) => onChange((x) => (x.key = e.target.value.trim()))} aria-label="跟练 key" />
        </label>
        <label className="wk-field">
          <span>名称（App 展示）</span>
          <Input disabled={!canEdit} value={w.name} maxLength={12} style={{ width: 150 }} className={cls(`workouts.${wk}.name`)} status={!w.name.trim() ? 'error' : undefined} onChange={(e) => onChange((x) => (x.name = e.target.value))} aria-label="跟练名称" />
        </label>
        <label className="wk-field">
          <span>运动</span>
          <Select disabled={!canEdit} value={w.sport} style={{ width: 100 }} className={cls(`workouts.${wk}.sport`)} options={WORKOUT_SPORTS.map((x) => ({ value: x, label: x === 'yoga' ? '普拉提·瑜伽' : SPORT_LABEL[x] ?? x }))} onChange={(v) => onChange((x) => (x.sport = v))} popupMatchSelectWidth={false} />
        </label>
        <label className="wk-field">
          <span>难度</span>
          <Select disabled={!canEdit} value={w.level} style={{ width: 86 }} className={cls(`workouts.${wk}.level`)} options={Object.entries(WORKOUT_LEVEL).map(([k, v]) => ({ value: k, label: v }))} onChange={(v) => onChange((x) => (x.level = v))} />
        </label>
        <label className="wk-field">
          <span>预计时长</span>
          <Space size={4}>
            {cell(`workouts.${wk}.est_minutes`, w.est_minutes, (v) => onChange((x) => (x.est_minutes = v)), { min: 1, max: 180, width: 72 })}
            <span className="muted">分钟</span>
          </Space>
        </label>
        <span className={changed.has(`workouts.${wk}.camera`) ? 'check-changed' : undefined} style={{ paddingBottom: 7 }}>
          <Checkbox disabled={!canEdit} checked={w.camera} onChange={(e) => onChange((x) => (x.camera = e.target.checked))}>
            摄像头计次
          </Checkbox>
        </span>
        <span style={{ flex: 1 }} />
        <Button size="small" type="text" danger icon={<DeleteOutlined />} disabled={!canEdit} onClick={onDelete} aria-label={`删除跟练 ${w.name}`} style={{ marginBottom: 6 }}>
          删除
        </Button>
      </div>
      <div className="muted" style={{ fontSize: 12, margin: '6px 0 8px' }}>
        {w.steps.length} 个动作 · 动作本身约 {est} 分钟（不含热身和转换）
        {!w.camera && ' · 关闭后全部手动计次 / 只计时'}
      </div>
      <div className="wk-steps">
        {w.steps.map((x, i) => {
          const sp = `workouts.${wk}.steps.${x.key}`;
          return (
            <div className={`wk-step${changed.has(sp) ? ' added' : ''}`} key={i} data-step={x.key}>
              <span className="wk-no num">{i + 1}</span>
              <div className="wk-row">
                <Input size="small" disabled={!canEdit} value={x.name} maxLength={12} placeholder="动作名称" style={{ width: 120 }} className={cls(`${sp}.name`)} status={!x.name.trim() ? 'error' : undefined} onChange={(e) => onChange((y) => (y.steps[i].name = e.target.value))} aria-label="动作名称" />
                <Select
                  size="small"
                  disabled={!canEdit}
                  value={x.mode}
                  style={{ width: 70 }}
                  className={cls(`${sp}.mode`)}
                  options={[
                    { value: 'count', label: '计次' },
                    { value: 'time', label: '计时' },
                  ]}
                  onChange={(v) =>
                    onChange((y) => {
                      const st = y.steps[i];
                      st.mode = v;
                      if (v === 'time' && st.pose !== 'none' && st.pose !== 'jump') st.pose = 'none';
                    })
                  }
                  aria-label="方式"
                />
                <Space size={4}>
                  {cell(`${sp}.target`, x.target, (v) => onChange((y) => (y.steps[i].target = v)), { min: 1, max: 3600, width: 70, step: x.mode === 'time' ? 5 : 1 })}
                  <span className="muted">{x.mode === 'time' ? '秒' : '次'} ×</span>
                  {cell(`${sp}.sets`, x.sets, (v) => onChange((y) => (y.steps[i].sets = v)), { min: 1, max: 20, width: 56 })}
                  <span className="muted">组</span>
                </Space>
                <Space size={4}>
                  <span className="muted">组间休息</span>
                  {cell(`${sp}.rest_sec`, x.rest_sec, (v) => onChange((y) => (y.steps[i].rest_sec = v)), { min: 0, max: 600, step: 5, width: 64 })}
                  <span className="muted">秒</span>
                </Space>
              </div>
              <div className="wk-row">
                <Input size="small" disabled={!canEdit} value={x.key} placeholder="step_key" style={{ width: 120, fontFamily: 'monospace' }} status={keyBad(x.key) ? 'error' : undefined} onChange={(e) => onChange((y) => (y.steps[i].key = e.target.value.trim()))} aria-label="动作 key" />
                <Tooltip title={WORKOUT_POSE[x.pose]?.hint ?? 'App 用哪种姿态规则自动计次'}>
                  <Select
                    size="small"
                    disabled={!canEdit || !w.camera}
                    value={x.pose}
                    style={{ width: 136 }}
                    className={cls(`${sp}.pose`)}
                    popupMatchSelectWidth={false}
                    options={Object.entries(WORKOUT_POSE).map(([k, v]) => ({ value: k, label: `识别：${v.text}` }))}
                    onChange={(v) => onChange((y) => (y.steps[i].pose = v))}
                    aria-label="姿态识别"
                  />
                </Tooltip>
                <Input size="small" disabled={!canEdit} value={x.cue} maxLength={40} placeholder="语音提示，跟练时播报" style={{ flex: 1, minWidth: 160 }} className={cls(`${sp}.cue`)} onChange={(e) => onChange((y) => (y.steps[i].cue = e.target.value))} aria-label="语音提示" />
              </div>
              <Space size={0} className="wk-ops">
                <Button size="small" type="text" icon={<ArrowUpOutlined />} aria-label="上移" disabled={!canEdit || i === 0} onClick={() => move(i, -1)} />
                <Button size="small" type="text" icon={<ArrowDownOutlined />} aria-label="下移" disabled={!canEdit || i === w.steps.length - 1} onClick={() => move(i, 1)} />
                <Button size="small" type="text" danger icon={<DeleteOutlined />} aria-label="删除动作" disabled={!canEdit || w.steps.length <= 1} onClick={() => onChange((y) => y.steps.splice(i, 1))} />
              </Space>
            </div>
          );
        })}
      </div>
      <Button
        size="small"
        type="dashed"
        icon={<PlusOutlined />}
        style={{ marginTop: 8 }}
        disabled={!canEdit || w.steps.length >= 20}
        onClick={() =>
          onChange((y) => {
            let n = y.steps.length + 1;
            while (y.steps.some((x) => x.key === `step_${n}`)) n++;
            y.steps.push({ key: `step_${n}`, name: '', mode: 'count', target: 20, sets: 3, rest_sec: 30, pose: y.camera ? 'squat' : 'none', cue: '', demo_url: null });
          })
        }
      >
        添加动作
      </Button>
    </div>
  );
}
