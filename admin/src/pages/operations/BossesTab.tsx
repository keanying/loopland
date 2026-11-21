import { useMemo } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { App, Button, Col, Drawer, Empty, Row, Segmented, Skeleton, Space, Table, Tag, Tooltip } from 'antd';
import { EnvironmentOutlined } from '@ant-design/icons';
import { api, PAGE_SIZE } from '../../api/admin';
import type { BossDetail, BossListItem, BossReward, BossStatus, RewardItem } from '../../api/types';
import { useAuth } from '../../auth/AuthContext';
import { useAdminNames } from '../../hooks/useAdminNames';
import { BossBadge, HpBar } from '../../components/gameplay';
import { bossKindName, timeLeft } from '../../utils/gameplay';
import { Panel, Tile } from '../../components/ui';
import { dt, num } from '../../utils/format';
import { BOSS_STATUS, DROP_KIND, SPORT_LABEL, UNIT_LABEL } from '../../utils/labels';
import { toastOk } from '../../utils/notify';
import { BRAND } from '../../theme';

function rewardText(it: RewardItem | string): string {
  if (typeof it === 'string') return it;
  const name = it.name ?? it.item;
  if (it.kind === 'energy') return `${it.energy ?? it.converted_energy ?? ''} 能量`.trim();
  return it.converted_energy ? `${name}（重复，折 ${it.converted_energy} 能量）` : name;
}

function useEndBoss(onDone?: () => void) {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const end = useMutation({
    mutationFn: (id: number) => api.endBoss(id),
    onSuccess: (b) => {
      qc.invalidateQueries({ queryKey: ['bosses'] });
      qc.invalidateQueries({ queryKey: ['map-objects'] });
      if (b && typeof b === 'object' && 'id' in b) qc.setQueryData(['bosses', 'detail', b.id], b);
      toastOk('已提前结束，按到期处理：参与者返还部分合击能量');
      onDone?.();
    },
  });
  const confirm = (b: { id: number; name: string; participants: number }) =>
    modal.confirm({
      title: `提前结束「${b.name}」？`,
      content: `按到期未击败处理：怪兽从地图消失，${b.participants} 位参与者返还部分合击能量，不发掉落。此操作不可撤销。`,
      okText: '提前结束',
      okButtonProps: { danger: true },
      cancelText: '取消',
      onOk: () => end.mutateAsync(b.id),
    });
  return { confirm, pending: end.isPending };
}

export default function BossesTab() {
  const [params, setParams] = useSearchParams();
  const status = (params.get('status') as BossStatus) || 'active';
  const page = Number(params.get('page') ?? 1);
  const bossId = params.get('boss') ? Number(params.get('boss')) : null;
  const { can } = useAuth();
  const editable = can('ops.write');
  const adminName = useAdminNames();
  const end = useEndBoss();

  const set = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null) next.delete(k);
      else next.set(k, v);
    }
    setParams(next, { replace: true });
  };

  const list = useQuery({ queryKey: ['bosses', status, page], queryFn: () => api.bosses({ status, page }), placeholderData: (p) => p });

  return (
    <>
      <Panel
        title="城市怪兽"
        extra={
          <Space wrap>
            <Segmented
              value={status}
              onChange={(v) => set({ status: v === 'active' ? null : String(v), page: null })}
              options={[
                { label: '进行中', value: 'active' },
                { label: '已击败', value: 'defeated' },
                { label: '已到期', value: 'expired' },
              ]}
            />
            <Link to="/territories">
              <Button icon={<EnvironmentOutlined />}>去地图召唤</Button>
            </Link>
          </Space>
        }
      >
        <Table<BossListItem>
          rowKey="id"
          loading={list.isFetching}
          dataSource={list.data?.items}
          scroll={{ x: 1000 }}
          rowClassName={(r) => (r.id === bossId ? 'row-active' : '')}
          onRow={(r) => ({ onClick: () => set({ boss: String(r.id) }), style: { cursor: 'pointer' } })}
          locale={{ emptyText: <Empty description={status === 'active' ? '现在没有进行中的怪兽' : '暂无记录'} /> }}
          pagination={{
            current: page,
            pageSize: PAGE_SIZE,
            total: list.data?.total ?? 0,
            showSizeChanger: false,
            showTotal: (t) => `共 ${t} 只`,
            onChange: (p) => set({ page: p === 1 ? null : String(p) }),
          }}
          columns={[
            {
              title: '怪兽',
              key: 'name',
              render: (_, b) => (
                <Space>
                  <BossBadge kind={b.kind} />
                  <div>
                    <b>{b.name || bossKindName(b.kind)}</b> <span className="muted num">Lv.{b.level}</span>
                    <div className="muted num" style={{ fontSize: 12 }}>
                      #{b.id}
                    </div>
                  </div>
                </Space>
              ),
            },
            { title: '地点', dataIndex: 'location_name' },
            { title: '血量', key: 'hp', width: 200, render: (_, b) => <HpBar hp={b.hp} max={b.hp_max} compact /> },
            { title: '参与', dataIndex: 'participants', align: 'right', render: (v: number) => <span className="num">{num(v)} 人</span> },
            { title: '来源', dataIndex: 'spawned_by', render: (v: number | null) => (v === null || v === undefined ? <Tag bordered={false}>系统自动</Tag> : <span>运营 {adminName(v)}</span>) },
            { title: '投放', dataIndex: 'spawned_at', render: (v: string) => <span className="muted num">{dt(v, 'MM-DD HH:mm')}</span> },
            {
              title: status === 'active' ? '剩余' : '到期',
              dataIndex: 'expires_at',
              render: (v: string) => (status === 'active' ? <span className="num">{timeLeft(v).replace('还剩 ', '')}</span> : <span className="muted num">{dt(v, 'MM-DD HH:mm')}</span>),
            },
            {
              title: '操作',
              key: 'op',
              align: 'right',
              render: (_, b) => (
                <Space onClick={(e) => e.stopPropagation()}>
                  <Button size="small" onClick={() => set({ boss: String(b.id) })}>
                    详情
                  </Button>
                  {status === 'active' && (
                    <Button size="small" danger disabled={!editable} onClick={() => end.confirm(b)}>
                      提前结束
                    </Button>
                  )}
                </Space>
              ),
            },
          ]}
        />
      </Panel>
      <BossDrawer id={bossId} onClose={() => set({ boss: null })} />
    </>
  );
}

function BossDrawer({ id, onClose }: { id: number | null; onClose: () => void }) {
  const { can } = useAuth();
  const adminName = useAdminNames();
  const q = useQuery({ queryKey: ['bosses', 'detail', id], queryFn: () => api.boss(id!), enabled: id !== null });
  const b: BossDetail | undefined = q.data;
  const end = useEndBoss();
  const rewards = useMemo(() => new Map<number, BossReward>((b?.rewards ?? []).map((r) => [r.user.id, r])), [b]);
  const totalDamage = useMemo(() => (b?.rank ?? []).reduce((s, r) => s + r.damage, 0), [b]);

  return (
    <Drawer
      open={id !== null}
      onClose={onClose}
      width={760}
      title={b ? `${b.name || bossKindName(b.kind)} · #${b.id}` : '怪兽详情'}
      extra={
        b?.status === 'active' && (
          <Button danger disabled={!can('ops.write')} loading={end.pending} onClick={() => end.confirm(b)}>
            提前结束
          </Button>
        )
      }
    >
      {!b ? (
        q.isError ? <Empty description="加载失败" /> : <Skeleton active paragraph={{ rows: 12 }} />
      ) : (
        <>
          <div style={{ display: 'flex', gap: 14, alignItems: 'center' }}>
            <BossBadge kind={b.kind} size={56} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 20, fontWeight: 800 }}>
                {b.name || bossKindName(b.kind)} <span className="muted num">Lv.{b.level}</span>{' '}
                <Tag bordered={false} color={BOSS_STATUS[b.status]?.color}>
                  {BOSS_STATUS[b.status]?.text ?? b.status}
                </Tag>
              </div>
              <div className="muted" style={{ fontSize: 12 }}>
                {b.location_name} · {b.center.lat.toFixed(5)}, {b.center.lng.toFixed(5)} · {b.spawned_by === null || b.spawned_by === undefined ? '系统自动投放' : `运营 ${adminName(b.spawned_by)} 投放`}
              </div>
            </div>
          </div>
          {b.description && <div style={{ marginTop: 10, fontSize: 13, color: '#3a3a40' }}>{b.description}</div>}

          <div style={{ marginTop: 16 }}>
            <HpBar hp={b.hp} max={b.hp_max} />
          </div>
          <Row gutter={8} style={{ marginTop: 14 }}>
            <Col span={6}>
              <Tile v={num(b.participants)} l="参与人数" />
            </Col>
            <Col span={6}>
              <Tile v={`${b.radius_m} m`} l="范围半径" />
            </Col>
            <Col span={6}>
              <Tile v={b.occupied_territories ?? '—'} l="范围内领地" />
            </Col>
            <Col span={6}>
              <Tile
                v={b.status === 'active' ? timeLeft(b.expires_at).replace('还剩 ', '') : dt(b.defeated_at ?? b.expires_at, 'MM-DD HH:mm')}
                l={b.status === 'active' ? '剩余时间' : b.status === 'defeated' ? '击败于' : '到期于'}
              />
            </Col>
          </Row>
          <div className="muted" style={{ fontSize: 12, marginTop: 8 }}>
            投放 {dt(b.spawned_at)} · 到期 {dt(b.expires_at)}
            {b.effect_text ? ` · ${b.effect_text}` : ''}
          </div>

          <h3 style={{ margin: '22px 0 8px', fontSize: 15 }}>伤害排名（全部参与者）</h3>
          <Table
            size="small"
            rowKey={(r) => r.user.id}
            dataSource={b.rank}
            pagination={b.rank.length > 10 ? { pageSize: 10, showSizeChanger: false, size: 'small' } : false}
            locale={{ emptyText: '还没有人出手' }}
            columns={[
              { title: '#', dataIndex: 'rank', width: 48, render: (v: number) => <b className="num">{v}</b> },
              { title: '用户', key: 'user', render: (_, r) => <Link to={`/users?id=${r.user.id}`}>{r.user.nickname}</Link> },
              { title: '伤害', dataIndex: 'damage', align: 'right', render: (v: number) => <span className="num">{num(v)}</span> },
              { title: '占比', key: 'share', align: 'right', width: 70, render: (_, r) => <span className="muted num">{totalDamage ? `${((r.damage / totalDamage) * 100).toFixed(1)}%` : '—'}</span> },
              {
                title: b.status === 'expired' ? '返还' : '奖励',
                key: 'reward',
                render: (_, r) => {
                  const rw = rewards.get(r.user.id);
                  if (!rw) return <span className="muted">{b.status === 'active' ? '结束后发放' : '—'}</span>;
                  const energy = rw.energy ?? rw.refund_energy;
                  if (rw.items.length === 0) return energy ? <span className="num">{b.status === 'expired' ? '返还' : '+'} {energy} 能量</span> : <span className="muted">—</span>;
                  return (
                    <Space size={4} wrap>
                      {rw.items.map((it, i) => (
                        <Tag key={i} bordered={false} color={typeof it !== 'string' && it.kind === 'egg' ? 'purple' : typeof it !== 'string' && it.kind === 'energy' ? 'gold' : 'default'}>
                          {rewardText(it)}
                        </Tag>
                      ))}
                    </Space>
                  );
                },
              },
            ]}
          />

          <Row gutter={20} style={{ marginTop: 22 }}>
            <Col xs={24} md={13}>
              <h3 style={{ margin: '0 0 8px', fontSize: 15 }}>掉落表（App 公示）</h3>
              <Table
                size="small"
                rowKey="item"
                pagination={false}
                dataSource={b.drops}
                columns={[
                  { title: '物品', key: 'name', render: (_, d) => d.name ?? d.item },
                  { title: '类型', dataIndex: 'kind', render: (v: string) => <span className="muted">{DROP_KIND[v] ?? v}</span> },
                  {
                    title: '概率',
                    dataIndex: 'percent',
                    align: 'right',
                    render: (v: number, d) => (
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8, justifyContent: 'flex-end' }}>
                        <div className="bar-track" style={{ width: 70 }}>
                          <div className="bar-fill" style={{ width: `${Math.min(100, v)}%`, background: d.kind === 'egg' ? BRAND.lavender : BRAND.ink }} />
                        </div>
                        <span className="num" style={{ width: 40 }}>
                          {v}%
                        </span>
                      </div>
                    ),
                  },
                ]}
              />
              <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>
                每位参与者掷 1 次，伤害前几名多掷 1 次；随机数由怪兽 id + 用户 id 决定，可复现审计。
              </div>
            </Col>
            <Col xs={24} md={11}>
              <h3 style={{ margin: '0 0 8px', fontSize: 15 }}>伤害规则</h3>
              <Table
                size="small"
                rowKey="sport"
                pagination={false}
                dataSource={b.damage_rules ?? []}
                locale={{ emptyText: '—' }}
                columns={[
                  { title: '运动', key: 'sport', render: (_, r) => r.label ?? SPORT_LABEL[r.sport] ?? r.sport },
                  { title: '规则', key: 'rule', align: 'right', render: (_, r) => <span className="num">每 {r.per} {UNIT_LABEL[r.unit] ?? r.unit} = {r.damage}</span> },
                ]}
              />
              {b.strike && (
                <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>
                  合击：{b.strike.cost} 能量造成 {b.strike.damage} 伤害，冷却 {b.strike.cooldown_s} 秒
                </div>
              )}
            </Col>
          </Row>
          {b.status === 'active' && (
            <Tooltip title="到期未击败也按这个规则处理">
              <div className="muted" style={{ fontSize: 12, marginTop: 16 }}>
                提前结束 = 按到期处理：参与者按配置比例返还合击花费，不掷掉落。
              </div>
            </Tooltip>
          )}
        </>
      )}
    </Drawer>
  );
}
