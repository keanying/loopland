// 联名活动 (M-26): cards with time, store count, redemptions, new users, merchant investment and the
// target progress; create / edit; pause / resume / 提前上线 (with confirmations); detail with its drops.
// ?id= opens one campaign's detail (links from the 投放 page).
import { useEffect, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, App, Button, Col, DatePicker, Drawer, Empty, Form, Input, InputNumber, Modal, Pagination, Progress, Radio, Row, Segmented, Select, Skeleton, Space, Table, Tag } from 'antd';
import { PlusOutlined } from '@ant-design/icons';
import type { Dayjs } from 'dayjs';
import { perksApi, type BrandCampaign, type BrandCampaignInput, type BrandCampaignStatus, type Drop } from '../../api/perks';
import { useAuth } from '../../auth/AuthContext';
import { PageHeader, Panel, Tile } from '../../components/ui';
import { bigNumber, dayjs, dt, num, pct } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { MerchantNav } from './nav';
import { CAMPAIGN_STATUS, DROP_STATUS, DROP_TYPE, toFen, toYuan, yuanShort } from './perkLabels';
import { DropTypeBadge } from './perkShared';

const STATUS_TABS: { value: BrandCampaignStatus | ''; label: string }[] = [
  { value: '', label: '全部' },
  { value: 'running', label: '进行中' },
  { value: 'scheduled', label: '待上线' },
  { value: 'paused', label: '已暂停' },
  { value: 'draft', label: '草稿' },
  { value: 'ended', label: '已结束' },
];

const big = (n: number) => {
  const b = bigNumber(n);
  return `${b.value}${b.unit ? ' ' + b.unit : ''}`;
};

type Action = 'pause' | 'resume' | 'launch';

const ACTION_TEXT: Record<Action, { button: string; title: (c: BrandCampaign) => string; content: (c: BrandCampaign) => string; done: string; danger?: boolean }> = {
  pause: {
    button: '暂停',
    title: (c) => `暂停「${c.title}」？`,
    content: (c) => `活动下 ${c.drop_ids.length} 个投放会同时暂停：补给站和宝箱从地图上消失、据点签到不再发券。已发出的券仍可在有效期内核销。`,
    done: '活动已暂停，其下投放同时暂停',
    danger: true,
  },
  resume: {
    button: '恢复',
    title: (c) => `恢复「${c.title}」？`,
    content: (c) => `活动下 ${c.drop_ids.length} 个投放恢复发券（单独暂停过的投放保持暂停）。`,
    done: '活动已恢复',
  },
  launch: {
    button: '提前上线',
    title: (c) => `提前上线「${c.title}」？`,
    content: (c) => `开始时间会改为现在（原定 ${dt(c.start_time, 'MM-DD HH:mm')}），活动立即在 App「联名活动」里展示，其下 ${c.drop_ids.length} 个投放立即开始发券。`,
    done: '活动已上线',
  },
};

function actionsOf(c: BrandCampaign): Action[] {
  if (c.status === 'running') return ['pause'];
  if (c.status === 'paused') return ['resume'];
  if (c.status === 'scheduled') return ['launch', 'pause'];
  if (c.status === 'draft') return ['launch'];
  return [];
}

function useCampaignAction() {
  const qc = useQueryClient();
  const { modal } = App.useApp();
  const m = useMutation({
    mutationFn: ({ c, action }: { c: BrandCampaign; action: Action }) => perksApi.campaignAction(c.id, action),
    onSuccess: (_, { action }) => {
      qc.invalidateQueries({ queryKey: ['brand-campaigns'] });
      qc.invalidateQueries({ queryKey: ['drops'] });
      qc.invalidateQueries({ queryKey: ['map-objects'] });
      toastOk(ACTION_TEXT[action].done);
    },
  });
  return (c: BrandCampaign, action: Action) =>
    modal.confirm({
      title: ACTION_TEXT[action].title(c),
      content: ACTION_TEXT[action].content(c),
      okText: ACTION_TEXT[action].button,
      okButtonProps: ACTION_TEXT[action].danger ? { danger: true } : undefined,
      cancelText: '取消',
      onOk: () => m.mutateAsync({ c, action }),
    });
}

function Goal({ c }: { c: BrandCampaign }) {
  const rate = c.stats.progress_rate;
  return (
    <div>
      <div className="bc-goal">
        <span>
          核销目标 <span className="num">{big(c.target_redemptions)}</span>
        </span>
        <b className="num">{pct(rate, 0)}</b>
      </div>
      <Progress percent={Math.round(rate * 100)} showInfo={false} size="small" strokeColor={c.status === 'running' ? '#141414' : '#A9A9AF'} trailColor="#ECECEF" aria-label="核销目标进度" />
    </div>
  );
}

function CampaignCard({ c, writable, onDetail, onEdit, onAction }: { c: BrandCampaign; writable: boolean; onDetail: () => void; onEdit: () => void; onAction: (a: Action) => void }) {
  const notStarted = c.status === 'draft' || c.status === 'scheduled';
  return (
    <article className={`bc-card ${c.status}`}>
      <div className="bc-head">
        <div>
          <div className="bc-title">{c.title}</div>
          <div className="bc-meta num">
            {dt(c.start_time, 'MM/DD')} – {dt(c.end_time, 'MM/DD')} · {c.store_count} 店 · {c.drop_ids.length} 个投放
          </div>
        </div>
        <Tag bordered={false} color={CAMPAIGN_STATUS[c.status].color}>
          {CAMPAIGN_STATUS[c.status].text}
        </Tag>
      </div>
      <div className="bc-desc">{c.description || <span className="muted">（无说明）</span>}</div>
      <div className="bc-stats">
        <div>
          <b className="num">{notStarted ? '—' : big(c.stats.redeemed)}</b>
          <span>核销</span>
        </div>
        <div>
          <b className="num">{notStarted ? '—' : big(c.stats.new_users)}</b>
          <span>拉新</span>
        </div>
        <div>
          <b className="num">{yuanShort(c.merchant_investment_amt)}</b>
          <span>商户投入</span>
        </div>
      </div>
      <Goal c={c} />
      <div className="bc-actions">
        <Button size="small" onClick={onDetail}>
          详情
        </Button>
        <Button size="small" disabled={!writable || c.status === 'ended'} onClick={onEdit}>
          编辑
        </Button>
        {actionsOf(c).map((a) => (
          <Button key={a} size="small" type={a === 'launch' ? 'primary' : 'default'} danger={a === 'pause'} disabled={!writable} onClick={() => onAction(a)}>
            {ACTION_TEXT[a].button}
          </Button>
        ))}
      </div>
    </article>
  );
}

export default function BrandCampaignsPage() {
  const [params, setParams] = useSearchParams();
  const status = (params.get('status') ?? '') as BrandCampaignStatus | '';
  const page = Number(params.get('page') ?? 1);
  const detailId = params.get('id') ? Number(params.get('id')) : null;
  const { can } = useAuth();
  const writable = can('perks.write');
  const [editing, setEditing] = useState<BrandCampaign | 'new' | null>(null);
  const act = useCampaignAction();

  const set = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null || v === '') next.delete(k);
      else next.set(k, v);
    }
    setParams(next, { replace: true });
  };

  const list = useQuery({ queryKey: ['brand-campaigns', 'list', status, page], queryFn: () => perksApi.campaigns({ status, page, page_size: 12 }), placeholderData: (p) => p });
  // all campaigns (for the header totals and ?id= deep links)
  const all = useQuery({ queryKey: ['brand-campaigns', 'options'], queryFn: () => perksApi.campaigns({ page_size: 100 }), staleTime: 30_000 });
  const items = list.data?.items ?? [];
  const running = (all.data?.items ?? []).filter((c) => c.status === 'running');
  const detail = detailId ? all.data?.items.find((c) => c.id === detailId) ?? items.find((c) => c.id === detailId) ?? null : null;

  return (
    <>
      <PageHeader
        title="商户与活动"
        sub={
          all.data
            ? `联名活动 · 进行中 ${running.length} 个 · 累计核销 ${big(running.reduce((s, c) => s + c.stats.redeemed, 0))} · 拉新 ${big(running.reduce((s, c) => s + c.stats.new_users, 0))}`
            : '联名活动'
        }
        extra={<MerchantNav />}
      />
      <Panel
        title="联名活动"
        extra={
          <Button type="primary" icon={<PlusOutlined />} disabled={!writable} onClick={() => setEditing('new')}>
            新建联名活动
          </Button>
        }
      >
        <div style={{ overflowX: 'auto', maxWidth: '100%', marginBottom: 14 }}>
          <Segmented value={status} onChange={(v) => set({ status: String(v), page: null })} options={STATUS_TABS} />
        </div>
        {list.isLoading ? (
          <Skeleton active />
        ) : items.length === 0 ? (
          <Empty description="没有这个状态的联名活动" />
        ) : (
          <div className="bc-grid">
            {items.map((c) => (
              <CampaignCard key={c.id} c={c} writable={writable} onDetail={() => set({ id: String(c.id) })} onEdit={() => setEditing(c)} onAction={(a) => act(c, a)} />
            ))}
          </div>
        )}
        {(list.data?.total ?? 0) > 12 && (
          <Pagination style={{ marginTop: 16, textAlign: 'right' }} current={page} pageSize={12} total={list.data?.total ?? 0} showSizeChanger={false} onChange={(p) => set({ page: String(p) })} />
        )}
      </Panel>
      <CampaignDetail c={detail} open={detailId !== null} writable={writable} onClose={() => set({ id: null })} onEdit={(c) => setEditing(c)} onAction={act} />
      <CampaignModal value={editing} onClose={() => setEditing(null)} />
    </>
  );
}

// ------------------------------------------------------------ detail

function CampaignDetail({
  c,
  open,
  writable,
  onClose,
  onEdit,
  onAction,
}: {
  c: BrandCampaign | null;
  open: boolean;
  writable: boolean;
  onClose: () => void;
  onEdit: (c: BrandCampaign) => void;
  onAction: (c: BrandCampaign, a: Action) => void;
}) {
  const drops = useQuery({
    queryKey: ['drops', 'merchant', c?.merchant.id ?? 0],
    queryFn: () => perksApi.drops({ merchant_id: c!.merchant.id, page_size: 100 }),
    enabled: !!c,
  });
  const own = (drops.data?.items ?? []).filter((d) => c?.drop_ids.includes(d.id) || d.campaign_id === c?.id);
  const s = c?.stats;
  const costPer = c && s && s.redeemed > 0 ? c.merchant_investment_amt / s.redeemed : null;

  return (
    <Drawer
      open={open}
      onClose={onClose}
      width={980}
      title={c ? c.title : '联名活动'}
      extra={
        c && (
          <Space>
            <Button disabled={!writable || c.status === 'ended'} onClick={() => onEdit(c)}>
              编辑
            </Button>
            {actionsOf(c).map((a) => (
              <Button key={a} type={a === 'launch' ? 'primary' : 'default'} danger={a === 'pause'} disabled={!writable} onClick={() => onAction(c, a)}>
                {ACTION_TEXT[a].button}
              </Button>
            ))}
          </Space>
        )
      }
    >
      {!c ? (
        <Empty description="活动不存在或已被删除" />
      ) : (
        <>
          <Space wrap style={{ marginBottom: 12 }}>
            <Tag bordered={false} color={CAMPAIGN_STATUS[c.status].color}>
              {CAMPAIGN_STATUS[c.status].text}
            </Tag>
            <Link to={`/merchant/drops?merchant_id=${c.merchant.id}`}>{c.merchant.name}</Link>
            <span className="muted num">
              {dt(c.start_time)} – {dt(c.end_time)} · {c.store_count} 家门店
            </span>
          </Space>
          {c.status === 'paused' && <Alert type="warning" showIcon style={{ marginBottom: 12 }} message="活动已暂停：其下所有投放暂停发券，已发出的券仍可核销" />}
          {c.description && <p style={{ marginTop: 0, color: '#55555b' }}>{c.description}</p>}
          <Row gutter={[10, 10]} style={{ marginBottom: 14 }}>
            <Col xs={12} md={4}>
              <Tile v={num(s!.issued)} l="发券" />
            </Col>
            <Col xs={12} md={4}>
              <Tile v={num(s!.redeemed)} l={`核销 · 核销率 ${s!.issued ? pct(s!.redeemed / s!.issued, 0) : '—'}`} />
            </Col>
            <Col xs={12} md={4}>
              <Tile v={num(s!.new_users)} l="拉新" />
            </Col>
            <Col xs={12} md={6}>
              <Tile v={yuanShort(c.merchant_investment_amt)} l="商户投入" />
            </Col>
            <Col xs={24} md={6}>
              <Tile v={costPer !== null ? `¥ ${(costPer / 100).toFixed(2)}` : '—'} l="每次核销的商户投入" />
            </Col>
          </Row>
          <div className="field-cell" style={{ marginBottom: 14, height: 'auto' }}>
            <Goal c={c} />
            <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>
              已核销 <span className="num">{num(s!.redeemed)}</span> / 目标 <span className="num">{num(c.target_redemptions)}</span>；拉新 = 活动期间注册、并在注册后 7 天内领到本活动券的用户数
            </div>
          </div>
          <div className="panel-head" style={{ marginBottom: 8 }}>
            <h2 className="panel-title">活动下的投放</h2>
            <Link to={`/merchant/drops?merchant_id=${c.merchant.id}`}>去投放页管理 →</Link>
          </div>
          <Table<Drop>
            rowKey="id"
            size="small"
            loading={drops.isFetching}
            dataSource={own}
            pagination={false}
            scroll={{ x: 760 }}
            locale={{ emptyText: '这个活动下还没有投放；在「投放」新建时选择这个活动，或编辑活动勾选已有投放' }}
            columns={[
              {
                title: '投放点',
                key: 'n',
                render: (_, d) => (
                  <div className="drop-cell" style={{ minWidth: 200 }}>
                    <DropTypeBadge type={d.type} size={28} />
                    <div>
                      <b>{d.name}</b>
                      <div className="muted">{d.perk.title}</div>
                    </div>
                  </div>
                ),
              },
              { title: '类型', key: 't', render: (_, d) => DROP_TYPE[d.type].label },
              {
                title: '今日 发券 / 核销 / 上限',
                key: 'today',
                render: (_, d) => (
                  <span className="num">
                    {num(d.issued_today)} / {num(d.redeemed_today)} <span className="muted">/ {num(d.daily_cap)}</span>
                  </span>
                ),
              },
              { title: '状态', dataIndex: 'status', render: (st: Drop['status']) => <Tag bordered={false} color={DROP_STATUS[st].color}>{DROP_STATUS[st].text}</Tag> },
            ]}
          />
        </>
      )}
    </Drawer>
  );
}

// ------------------------------------------------------------ create / edit

interface FormValues {
  merchant_id: number;
  title: string;
  description: string;
  cover_url: string;
  range: [Dayjs, Dayjs];
  store_count: number;
  target_redemptions: number;
  investment_yuan: number;
  drop_ids: number[];
  status: 'draft' | 'scheduled';
}

function CampaignModal({ value, onClose }: { value: BrandCampaign | 'new' | null; onClose: () => void }) {
  const [form] = Form.useForm<FormValues>();
  const qc = useQueryClient();
  const editing = value && value !== 'new' ? value : null;
  const open = value !== null;
  const merchantId = Form.useWatch('merchant_id', form) as number | undefined;
  const merchants = useQuery({ queryKey: ['perk-merchants'], queryFn: perksApi.merchantOptions, enabled: open, staleTime: 60_000 });
  const drops = useQuery({ queryKey: ['drops', 'merchant', merchantId ?? 0], queryFn: () => perksApi.drops({ merchant_id: merchantId, page_size: 100 }), enabled: open && !!merchantId });
  const dropOptions = useMemo(
    () =>
      (drops.data?.items ?? [])
        .filter((d) => d.status !== 'ended' && (!d.campaign_id || d.campaign_id === editing?.id))
        .map((d) => ({ value: d.id, label: d.name })),
    [drops.data, editing],
  );

  const save = useMutation({
    mutationFn: (body: BrandCampaignInput) => {
      if (!editing) return perksApi.createCampaign(body);
      const { merchant_id: _m, ...patch } = body;
      return perksApi.updateCampaign(editing.id, patch);
    },
    onSuccess: (c) => {
      qc.invalidateQueries({ queryKey: ['brand-campaigns'] });
      qc.invalidateQueries({ queryKey: ['drops'] });
      toastOk(editing ? `已保存「${c.title}」` : `已创建「${c.title}」（${CAMPAIGN_STATUS[c.status].text}）`);
      onClose();
    },
  });

  const submit = (v: FormValues) =>
    save.mutate({
      merchant_id: v.merchant_id,
      title: v.title.trim(),
      description: (v.description ?? '').trim(),
      cover_url: v.cover_url?.trim() || null,
      start_time: v.range[0].second(0).millisecond(0).format(),
      end_time: v.range[1].second(0).millisecond(0).format(),
      store_count: v.store_count,
      target_redemptions: v.target_redemptions,
      merchant_investment_amt: toFen(v.investment_yuan),
      drop_ids: v.drop_ids ?? [],
      ...(canDraft ? { status: v.status } : {}),
    });

  const started = editing ? editing.status === 'running' || editing.status === 'paused' : false;
  // 草稿 ↔ 发布 only before the campaign goes live
  const canDraft = !editing || editing.status === 'draft' || editing.status === 'scheduled';

  // Fill the form as soon as it opens (not after the animation, so early clicks are kept).
  useEffect(() => {
    if (value === null) return;
    form.resetFields();
    if (editing) {
      form.setFieldsValue({
        merchant_id: editing.merchant.id,
        title: editing.title,
        description: editing.description,
        cover_url: editing.cover_url ?? '',
        range: [dayjs(editing.start_time), dayjs(editing.end_time)],
        store_count: editing.store_count,
        target_redemptions: editing.target_redemptions,
        investment_yuan: toYuan(editing.merchant_investment_amt),
        drop_ids: editing.drop_ids,
        status: editing.status === 'draft' ? 'draft' : 'scheduled',
      });
    } else {
      const start = dayjs().add(1, 'day').startOf('day');
      form.setFieldsValue({ range: [start, dayjs(start.add(30, 'day').endOf('day').second(0).toDate())], store_count: 1, target_redemptions: 1000, investment_yuan: 0, drop_ids: [], status: 'scheduled' });
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps -- once per open
  }, [value]);

  return (
    <Modal
      open={open}
      title={editing ? `编辑「${editing.title}」` : '新建联名活动'}
      width={680}
      forceRender
      okText="保存"
      cancelText="取消"
      confirmLoading={save.isPending}
      onCancel={onClose}
      onOk={() => form.submit()}
    >
      {started && <Alert type="warning" showIcon style={{ marginBottom: 12 }} message="活动已经开始：开始时间不能再改；改目标和投入只影响统计展示" />}
      <Form<FormValues> form={form} layout="vertical" requiredMark={false} onFinish={submit}>
        <Row gutter={12}>
          <Col span={10}>
            <Form.Item name="merchant_id" label="商户" rules={[{ required: true, message: '请选择商户' }]} extra={editing ? '商户创建后不能修改' : undefined}>
              <Select
                showSearch
                optionFilterProp="label"
                placeholder="选择商户"
                disabled={!!editing}
                onChange={() => form.setFieldsValue({ drop_ids: [] })}
                options={(merchants.data?.items ?? []).map((m) => ({ value: m.id, label: m.name, disabled: m.status === 'suspended' || m.status === 'reviewing' }))}
              />
            </Form.Item>
          </Col>
          <Col span={14}>
            <Form.Item name="title" label="活动标题" rules={[{ required: true, whitespace: true, message: '请填写标题' }, { max: 30, message: '最多 30 字' }]}>
              <Input maxLength={30} placeholder="青柠茶铺 · 冬日暖跑" />
            </Form.Item>
          </Col>
        </Row>
        <Form.Item name="description" label="活动说明（App「联名活动」展示）" rules={[{ max: 200, message: '最多 200 字' }]}>
          <Input.TextArea rows={2} maxLength={200} showCount placeholder="跑步路过补给站领热饮，每家门店每人每天限 1 张" />
        </Form.Item>
        <Form.Item name="cover_url" label="封面图地址（可选）" rules={[{ pattern: /^https?:\/\//, message: '需要是 http(s) 地址' }]}>
          <Input placeholder="https://cdn.../campaign.jpg" allowClear />
        </Form.Item>
        <Row gutter={12}>
          <Col span={16}>
            <Form.Item name="range" label="活动时间" rules={[{ required: true, message: '请选择活动时间' }, { validator: (_, r?: [Dayjs, Dayjs]) => (!r || r[1].isAfter(r[0]) ? Promise.resolve() : Promise.reject(new Error('结束时间需晚于开始时间'))) }]}>
              <DatePicker.RangePicker showTime={{ format: 'HH:mm' }} format="YYYY-MM-DD HH:mm" style={{ width: '100%' }} disabled={started ? [true, false] : false} />
            </Form.Item>
          </Col>
          <Col span={8}>
            <Form.Item name="store_count" label="参与门店数" rules={[{ required: true, message: '请填写门店数' }]}>
              <InputNumber className="num" min={0} max={10000} suffix="店" style={{ width: '100%' }} />
            </Form.Item>
          </Col>
        </Row>
        <Row gutter={12}>
          <Col span={12}>
            <Form.Item name="target_redemptions" label="核销目标" rules={[{ required: true, message: '请填写核销目标' }]} extra="用于目标进度条">
              <InputNumber className="num" min={1} max={10_000_000} suffix="次" style={{ width: '100%' }} />
            </Form.Item>
          </Col>
          <Col span={12}>
            <Form.Item name="investment_yuan" label="商户投入" rules={[{ required: true, message: '请填写商户投入' }]} extra="商户为活动投入的权益成本（元）">
              <InputNumber className="num" min={0} max={100_000_000} precision={2} prefix="¥" style={{ width: '100%' }} />
            </Form.Item>
          </Col>
        </Row>
        <Form.Item name="drop_ids" label="活动下的投放" extra="可勾选这个商户未挂活动的投放；投放跟随活动状态（暂停活动 = 暂停其下所有投放）">
          <Select mode="multiple" placeholder={merchantId ? (dropOptions.length ? '选择投放' : '这个商户还没有可用的投放') : '先选商户'} disabled={!merchantId} options={dropOptions} loading={drops.isFetching} />
        </Form.Item>
        {canDraft && (
          <Form.Item name="status" label="发布" extra="草稿不会上线，其下投放也不发券；发布后到开始时间自动上线，也可以在列表「提前上线」" style={{ marginBottom: 0 }}>
            <Radio.Group
              options={[
                { value: 'scheduled', label: '发布（到开始时间自动上线）' },
                { value: 'draft', label: '存为草稿' },
              ]}
            />
          </Form.Item>
        )}
      </Form>
    </Modal>
  );
}
