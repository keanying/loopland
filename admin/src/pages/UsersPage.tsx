import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { App, Button, Col, Drawer, Empty, Input, Modal, Row, Segmented, Skeleton, Space, Table, Tag, Tooltip } from 'antd';
import { EyeOutlined, RobotOutlined, SearchOutlined } from '@ant-design/icons';
import { api, PAGE_SIZE } from '../api/admin';
import type { UserAction, UserDetail, UserFilter, UserListItem } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import { Avatar, PageHeader, Panel, Stat, Tile } from '../components/ui';
import { ago, bigNumber, date, dt, km, num, pct } from '../utils/format';
import { RISK_TYPE, SOURCE_LABEL, USER_STATUS } from '../utils/labels';
import { toastOk } from '../utils/notify';
import AIMessagesDrawer from './users/AIMessagesDrawer';

function StatusTag({ status, deleteAfter }: { status: UserListItem['status']; deleteAfter?: string | null }) {
  const s = USER_STATUS[status] ?? { text: status, color: 'default' };
  return (
    <Tooltip title={status === 'deleting' && deleteAfter ? `${date(deleteAfter)} 到期删除，期间可撤回` : undefined}>
      <Tag color={s.color} bordered={false}>
        {s.text}
      </Tag>
    </Tooltip>
  );
}

export default function UsersPage() {
  const [params, setParams] = useSearchParams();
  const filter = (params.get('filter') as UserFilter) || 'all';
  const q = params.get('q') ?? '';
  const page = Number(params.get('page') ?? 1);
  const openId = params.get('id') ? Number(params.get('id')) : null;
  const [kw, setKw] = useState(q);

  const update = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null || v === '') next.delete(k);
      else next.set(k, v);
    }
    setParams(next, { replace: true });
  };

  const { can: canDo } = useAuth();
  const stats = useQuery({ queryKey: ['users', 'stats'], queryFn: api.userStats, enabled: canDo('users.stats') });
  const list = useQuery({
    queryKey: ['users', 'list', filter, q, page],
    queryFn: () => api.users({ filter, q, page }),
    placeholderData: (prev) => prev,
  });

  const s = stats.data;
  const srcTotal = s?.sources.reduce((a, b) => a + b.count, 0) ?? 0;

  return (
    <>
      <PageHeader title="用户管理" sub="手机号默认脱敏显示，查看完整号码会记录审计日志" />

      <Row gutter={[16, 16]}>
        {s ? (
          <>
            <Col xs={12} lg={6} xl={4}>
              <Stat value={bigNumber(s.total).value} unit={bigNumber(s.total).unit} label="注册用户" />
            </Col>
            <Col xs={12} lg={6} xl={4}>
              <Stat value={num(s.today_new)} label="今日新增注册" />
            </Col>
            <Col xs={12} lg={6} xl={4}>
              <Stat value={(s.retention_7d * 100).toFixed(0)} unit="%" label="新用户 7 日留存" sub="注册后第 7 天仍有运动" />
            </Col>
            <Col xs={12} lg={6} xl={4}>
              <Stat value={bigNumber(s.members).value} unit={bigNumber(s.members).unit} label="付费会员" sub={`付费率 ${pct(s.total ? s.members / s.total : 0)}`} />
            </Col>
            <Col xs={24} xl={8}>
              <Panel
                title={<h2 className="panel-title" style={{ fontSize: 15 }}>近 30 天注册来源</h2>}
                extra={<span className="panel-hint">共 {bigNumber(srcTotal).value + bigNumber(srcTotal).unit}</span>}
                style={{ padding: '14px 20px' }}
              >
                {s.sources.map((x) => {
                  const r = srcTotal ? x.count / srcTotal : 0;
                  return (
                    <div className="bar-row" key={x.provider} style={{ margin: '6px 0' }}>
                      <span>{SOURCE_LABEL[x.provider] ?? x.provider}</span>
                      <div className="bar-track">
                        <div className="bar-fill" style={{ width: `${r * 100}%` }} />
                      </div>
                      <b className="num" style={{ textAlign: 'right' }}>
                        {pct(r, 0)}
                      </b>
                    </div>
                  );
                })}
              </Panel>
            </Col>
          </>
        ) : canDo('users.stats') ? (
          <Col span={24}>
            <Skeleton active />
          </Col>
        ) : null}
      </Row>

      <Panel
        title="注册用户"
        extra={
          <Space wrap>
            <Input
              allowClear
              prefix={<SearchOutlined />}
              placeholder="昵称、用户 ID 或手机尾号"
              style={{ width: 260 }}
              value={kw}
              onChange={(e) => {
                setKw(e.target.value);
                if (!e.target.value) update({ q: null, page: null });
              }}
              onPressEnter={() => update({ q: kw.trim(), page: null })}
            />
            <Segmented
              value={filter}
              onChange={(v) => update({ filter: v === 'all' ? null : String(v), page: null })}
              options={[
                { label: '全部', value: 'all' },
                { label: '会员', value: 'member' },
                { label: '今日新注册', value: 'today' },
                { label: '异常', value: 'abnormal' },
              ]}
            />
          </Space>
        }
      >
        <Table<UserListItem>
          rowKey="id"
          loading={list.isFetching}
          dataSource={list.data?.items}
          scroll={{ x: 820 }}
          onRow={(r) => ({ onClick: () => update({ id: String(r.id) }), style: { cursor: 'pointer' } })}
          rowClassName={(r) => (r.id === openId ? 'row-active' : '')}
          pagination={{
            current: page,
            pageSize: PAGE_SIZE,
            total: list.data?.total ?? 0,
            showSizeChanger: false,
            showTotal: (t) => `共 ${t} 人`,
            onChange: (p) => update({ page: p === 1 ? null : String(p) }),
          }}
          columns={[
            {
              title: '用户',
              key: 'user',
              render: (_, r) => (
                <Space>
                  <Avatar name={r.nickname} />
                  <div>
                    <div style={{ fontWeight: 700 }}>{r.nickname}</div>
                    <div className="muted num" style={{ fontSize: 12 }}>
                      ID {r.id}
                    </div>
                  </div>
                </Space>
              ),
            },
            { title: '手机号', dataIndex: 'phone_masked', render: (v: string | null) => <span className="num">{v ?? '未绑定'}</span> },
            {
              title: '注册',
              key: 'created',
              render: (_, r) => (
                <div>
                  <div className="num">{date(r.created_at)}</div>
                  <div className="muted" style={{ fontSize: 12 }}>
                    {SOURCE_LABEL[r.source] ?? r.source}
                  </div>
                </div>
              ),
            },
            { title: '会员', dataIndex: 'member', render: (v: boolean) => (v ? <Tag color="purple" bordered={false}>会员</Tag> : <span className="muted">—</span>) },
            { title: '状态', key: 'status', render: (_, r) => <StatusTag status={r.status} deleteAfter={r.delete_after} /> },
            {
              title: '操作',
              key: 'op',
              align: 'right',
              render: (_, r) => (
                <Button size="small" type={r.id === openId ? 'primary' : 'default'} onClick={() => update({ id: String(r.id) })}>
                  {r.id === openId ? '查看中' : '查看'}
                </Button>
              ),
            },
          ]}
        />
      </Panel>

      <UserDrawer id={openId} onClose={() => update({ id: null })} />
    </>
  );
}

function UserDrawer({ id, onClose }: { id: number | null; onClose: () => void }) {
  const { modal } = App.useApp();
  const { can } = useAuth();
  const qc = useQueryClient();
  const [phone, setPhone] = useState<{ id: number; phone: string } | null>(null);
  const detail = useQuery({ queryKey: ['users', 'detail', id], queryFn: () => api.user(id!), enabled: id !== null });

  const reveal = useMutation({
    mutationFn: (uid: number) => api.revealPhone(uid),
    onSuccess: (r, uid) => setPhone({ id: uid, phone: r.phone }),
  });

  const act = useMutation({
    mutationFn: (v: { action: UserAction; message?: string }) => api.userAction(id!, v),
    onSuccess: (u) => {
      qc.setQueryData(['users', 'detail', id], u);
      qc.invalidateQueries({ queryKey: ['users', 'list'] });
      toastOk('操作已完成');
    },
  });

  const u: UserDetail | undefined = detail.data;
  const canWrite = can('user.write');

  const confirm = (action: UserAction, title: string, content: string, danger = false) =>
    modal.confirm({
      title,
      content,
      okText: '确认',
      cancelText: '取消',
      okButtonProps: { danger },
      onOk: () => act.mutateAsync({ action }),
    });

  const [notifyOpen, setNotifyOpen] = useState(false);
  const [notifyText, setNotifyText] = useState('');
  const notify = () => {
    setNotifyText('');
    setNotifyOpen(true);
  };

  const revealed = phone && u && phone.id === u.id ? phone.phone : null;
  const [aiOpen, setAiOpen] = useState(false);
  useEffect(() => setAiOpen(false), [id]);
  const viewAI = () =>
    modal.confirm({
      title: `查看 ${u?.nickname ?? ''} 的 AI 对话？`,
      content: '仅用于处理投诉核查。查看会记入审计日志（谁、什么时候、看了哪个用户）。',
      okText: '确认查看',
      cancelText: '取消',
      onOk: () => setAiOpen(true),
    });

  return (
    <Drawer open={id !== null} onClose={onClose} width={480} title="用户详情" destroyOnHidden>
      <Modal
        open={notifyOpen}
        title={`给 ${u?.nickname ?? ''} 发站内通知`}
        okText="发送"
        cancelText="取消"
        okButtonProps={{ disabled: !notifyText.trim(), loading: act.isPending }}
        onCancel={() => setNotifyOpen(false)}
        onOk={() => act.mutate({ action: 'notify', message: notifyText.trim() }, { onSuccess: () => setNotifyOpen(false) })}
      >
        <Input.TextArea rows={4} maxLength={500} showCount placeholder="通知内容（必填）" value={notifyText} onChange={(e) => setNotifyText(e.target.value)} />
      </Modal>
      {!u ? (
        detail.isError ? <Empty description="加载失败" /> : <Skeleton active avatar paragraph={{ rows: 10 }} />
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <div style={{ display: 'flex', gap: 14, alignItems: 'center' }}>
            <Avatar name={u.nickname} size="lg" />
            <div>
              <div style={{ fontSize: 20, fontWeight: 800 }}>{u.nickname}</div>
              <div className="muted" style={{ fontSize: 12 }}>
                ID {u.id} · Lv.{u.level}
                {u.crew ? ` · ${u.crew.name}` : ''}
              </div>
            </div>
          </div>
          <Space size={6} wrap>
            <StatusTag status={u.status} deleteAfter={u.delete_after} />
            {u.status === 'muted' && u.muted_until && <Tag bordered={false}>禁言至 {dt(u.muted_until)}</Tag>}
            {u.status === 'deleting' && u.delete_after && <Tag bordered={false}>{date(u.delete_after)} 到期删除</Tag>}
            <Tag bordered={false} color={u.realname_verified ? 'success' : 'default'}>
              {u.realname_verified ? '已实名' : '未实名'}
            </Tag>
            <Tag bordered={false} color={u.is_adult === false ? 'error' : 'default'}>
              {u.is_adult === null ? '年龄未知' : u.is_adult ? '成年' : '未成年'}
            </Tag>
          </Space>

          <div className="tile" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div>
              <div className="tile-l">手机号</div>
              <div className="num" style={{ fontWeight: 700, fontSize: 16 }}>
                {revealed ?? u.phone_masked ?? '未绑定'}
              </div>
            </div>
            {u.phone_masked && can('user.reveal_phone') && !revealed && (
              <Tooltip title="查看会记录到审计日志">
                <Button icon={<EyeOutlined />} loading={reveal.isPending} onClick={() => reveal.mutate(u.id)}>
                  查看完整号码
                </Button>
              </Tooltip>
            )}
          </div>

          <Row gutter={[8, 8]}>
            <Col span={6}>
              <Tile v={num(u.stats.total_distance_m / 1000, 0)} l="累计 km" />
            </Col>
            <Col span={6}>
              <Tile v={u.stats.territory_count} l="领地" />
            </Col>
            <Col span={6}>
              <Tile v={u.codex_count} l="图鉴" />
            </Col>
            <Col span={6}>
              <Tile v={u.stats.activity_count} l="运动次数" />
            </Col>
          </Row>

          <div className="tile">
            <div className="kv">
              <span>会员</span>
              <span>{u.membership?.active ? u.membership.plan_name ?? u.membership.plan_code : '非会员'}</span>
              {u.membership?.active && (
                <>
                  <span>到期</span>
                  <span>{date(u.membership.expires_at)}</span>
                  <span>自动续费</span>
                  <span>{u.membership.auto_renew ? `已开启（下次扣费 ${date(u.membership.next_charge_at)}）` : '未开启'}</span>
                </>
              )}
              <span>跑团</span>
              <span>{u.crew?.name ?? '—'}</span>
              <span>能量</span>
              <span>
                {u.energy}（今日 {u.energy_today}/{u.daily_energy_cap}）
              </span>
              <span>本周</span>
              <span>{u.stats.week ? `${u.stats.week.count} 次 · ${km(u.stats.week.distance_m)}` : '—'}</span>
              <span>注册 / 最近登录</span>
              <span>
                {date(u.created_at)}（{SOURCE_LABEL[u.source] ?? u.source}）/ {ago(u.last_login_at)}
              </span>
              <span>隐私授权</span>
              <span>{u.consents?.privacy_version ? `${u.consents.privacy_version} 版` : '未同意'}</span>
            </div>
          </div>

          <div>
            <div style={{ fontWeight: 700, marginBottom: 8 }}>风控记录</div>
            {u.risk_alerts.length === 0 ? (
              <div className="muted">无</div>
            ) : (
              u.risk_alerts.map((a) => (
                <div key={a.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '6px 0', borderBottom: '1px dashed #e6e6ea' }}>
                  <span>
                    <Link to={`/risk?alert=${a.id}`}>{RISK_TYPE[a.type] ?? a.type}</Link> <span className="muted">置信 {a.confidence.toFixed(2)}</span>
                  </span>
                  <span>
                    <Tag bordered={false} color={a.status === 'open' ? 'warning' : 'default'}>
                      {a.status === 'open' ? '待确认' : '已处理'}
                    </Tag>
                    <span className="muted">{date(a.created_at)}</span>
                  </span>
                </div>
              ))
            )}
          </div>

          {can('user.ai_messages') && (
            <div className="tile" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 12 }}>
              <div>
                <div style={{ fontWeight: 700 }}>AI 助手对话</div>
                <div className="tile-l">投诉核查用，仅管理员可看，查看记审计</div>
              </div>
              <Button icon={<RobotOutlined />} onClick={viewAI}>
                查看 AI 对话
              </Button>
            </div>
          )}

          {canWrite ? (
            <Space wrap>
              <Button type="primary" onClick={() => confirm('gift_member_7d', '赠送 7 天会员？', `给 ${u.nickname} 赠送 7 天会员，已是会员则顺延 7 天。`)}>
                赠送 7 天会员
              </Button>
              <Button onClick={notify}>发站内通知</Button>
              {u.status === 'muted' ? (
                <Button onClick={() => confirm('unmute', '解除禁言？', `${u.nickname} 将可以重新发言。`)}>解除禁言</Button>
              ) : (
                <Button disabled={u.status === 'banned'} onClick={() => confirm('mute_7d', '禁言 7 天？', `${u.nickname} 7 天内不能发言、改昵称和头像。`)}>
                  禁言 7 天
                </Button>
              )}
              {u.status === 'banned' ? (
                <Button onClick={() => confirm('unban', '解封账号？', '解封后名下领地同时解冻。')}>解封</Button>
              ) : (
                <Button danger onClick={() => confirm('ban', `封禁 ${u.nickname}？`, '封禁后不能登录，名下领地全部冻结（不可被抢、不可建设）。', true)}>
                  封禁账号
                </Button>
              )}
            </Space>
          ) : (
            <div className="muted">当前角色只能查看，不能处置用户。</div>
          )}
        </div>
      )}
      <AIMessagesDrawer user={u ? { id: u.id, nickname: u.nickname } : null} open={aiOpen && !!u} onClose={() => setAiOpen(false)} />
    </Drawer>
  );
}
