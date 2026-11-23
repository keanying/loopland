// V2 第五批 · 开放平台（商户账号，openapi.manage）(docs/api/v2-5「开放平台」): API credentials for the merchant's
// own systems (POS, ERP, booking): create (the secret is shown once), edit scopes / IP allowlist / webhook, reset
// the secret, enable / disable, delete; call log and webhook deliveries (redeliver, test ping); signing guide.
import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, App, Button, Checkbox, Descriptions, Drawer, Empty, Form, Input, Select, Space, Table, Tabs, Tag, Tooltip, Typography } from 'antd';
import { commerceApi, type OpenApp, type OpenAppInput, type OpenAppWithSecret, type OpenScope } from '../../api/commerce';
import { useAuth } from '../../auth/AuthContext';
import { PageHeader, Panel } from '../../components/ui';
import { dt } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { OPEN_SCOPE, OPEN_SCOPES, WEBHOOK_EVENT, WEBHOOK_EVENTS } from './commerceLabels';
import { MerchantNav } from './nav';
import { AppStatusTag, CallsTable, DeliveriesTable, ScopeTags, SecretModal, SigningGuide } from './openApps';
import { urlParams } from './util';
import { Glyph } from '../../components/Glyph';

const MAX_APPS = 5;
const IP_RE = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}(\/([12]?\d|3[0-2]))?$/;

export default function OpenAppsPage() {
  const { admin } = useAuth();
  const staff = admin?.role === 'merchant';
  const [params, setParams] = useSearchParams();
  const update = urlParams(params, setParams);
  const openId = Number(params.get('id') ?? 0) || null;
  const [editing, setEditing] = useState<OpenApp | 'new' | null>(null);
  const [secret, setSecret] = useState<{ app: OpenAppWithSecret; reset: boolean } | null>(null);
  const [guide, setGuide] = useState(false);
  const apps = useQuery({ queryKey: ['open-apps', 'list', 'mine'], queryFn: () => commerceApi.openApps() });
  const items = apps.data?.items ?? [];
  const opened = items.find((a) => a.id === openId) ?? null;

  return (
    <>
      <PageHeader
        title={staff ? '开放平台' : '商户与活动'}
        sub="给收银、ERP、自有订场系统用的接口凭证：外部系统用签名调用 /open/v1 管理商品、查订单 / 订场 / 结算、在收银台核销、同步线下订场占场；平台用 Webhook 推送订单、核销等事件。每个商户最多 5 个应用"
        extra={<MerchantNav />}
      />
      <Panel
        title="应用"
        extra={
          <Space wrap>
            <Button icon={<Glyph name="doc" />} onClick={() => setGuide(true)}>
              签名说明
            </Button>
            {staff && (
              <Tooltip title={items.length >= MAX_APPS ? `最多 ${MAX_APPS} 个应用，先删掉不用的` : undefined}>
                <Button type="primary" icon={<Glyph name="plus" />} disabled={items.length >= MAX_APPS} onClick={() => setEditing('new')}>
                  新建应用
                </Button>
              </Tooltip>
            )}
          </Space>
        }
      >
        <Table<OpenApp>
          rowKey="id"
          loading={apps.isFetching}
          dataSource={items}
          pagination={false}
          scroll={{ x: 1100 }}
          onRow={(a) => ({ onClick: () => update({ id: a.id }), style: { cursor: 'pointer' } })}
          locale={{ emptyText: <Empty description={staff ? '还没有应用，点「新建应用」拿到 App ID 和 Secret' : '没有应用'} /> }}
          columns={[
            {
              title: '应用',
              key: 'name',
              width: 220,
              render: (_, a) => (
                <span>
                  <b>{a.name}</b>
                  {!staff && a.merchant && <span className="muted"> · {a.merchant.name}</span>}
                  <div onClick={(e) => e.stopPropagation()}>
                    <Typography.Text className="num" type="secondary" style={{ fontSize: 12 }} copyable={{ text: a.app_id, tooltips: ['复制 App ID', '已复制'] }}>
                      {a.app_id}
                    </Typography.Text>
                  </div>
                </span>
              ),
            },
            { title: '接口权限', dataIndex: 'scopes', width: 260, render: (s: string[]) => <ScopeTags scopes={s} /> },
            { title: 'IP 白名单', dataIndex: 'ip_allowlist', width: 160, render: (v: string[]) => (v.length ? <span className="num" style={{ fontSize: 12 }}>{v.join('、')}</span> : <span className="muted">不限</span>) },
            {
              title: 'Webhook',
              key: 'webhook',
              width: 240,
              render: (_, a) =>
                a.webhook_url ? (
                  <span style={{ fontSize: 12 }}>
                    <span className="num" style={{ wordBreak: 'break-all' }}>{a.webhook_url}</span>
                    <div className="muted">订阅 {a.webhook_events.length} 种事件</div>
                  </span>
                ) : (
                  <span className="muted">未设置</span>
                ),
            },
            { title: '最近调用', dataIndex: 'last_used_at', width: 120, render: (v: string | null) => <span className="num">{v ? dt(v, 'MM-DD HH:mm') : '从未'}</span> },
            { title: '状态', dataIndex: 'status', width: 80, render: (s: OpenApp['status']) => <AppStatusTag status={s} /> },
            {
              title: '操作',
              key: 'op',
              width: 90,
              align: 'right',
              fixed: 'right',
              render: (_, a) => (
                <Button
                  size="small"
                  onClick={(e) => {
                    e.stopPropagation();
                    update({ id: a.id });
                  }}
                >
                  管理
                </Button>
              ),
            },
          ]}
        />
      </Panel>
      <AppDrawer app={opened} open={openId !== null} writable={staff} onClose={() => update({ id: null })} onEdit={(a) => setEditing(a)} onSecret={(app) => setSecret({ app, reset: true })} />
      {staff && (
        <AppForm
          value={editing}
          onClose={() => setEditing(null)}
          onCreated={(app) => setSecret({ app, reset: false })}
        />
      )}
      <SecretModal
        app={secret?.app ?? null}
        reset={secret?.reset}
        onClose={() => {
          // A new app opens in the drawer once the secret is saved (not before: the drawer would cover the dialog).
          if (secret && !secret.reset) update({ id: secret.app.id });
          setSecret(null);
        }}
      />
      <SigningGuide open={guide} onClose={() => setGuide(false)} />
    </>
  );
}

function AppDrawer({ app, open, writable, onClose, onEdit, onSecret }: { app: OpenApp | null; open: boolean; writable: boolean; onClose: () => void; onEdit: (a: OpenApp) => void; onSecret: (a: OpenAppWithSecret) => void }) {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const [tab, setTab] = useState('info');
  useEffect(() => {
    if (open) setTab('info');
  }, [open, app?.id]);
  const refresh = () => qc.invalidateQueries({ queryKey: ['open-apps'] });
  const toggle = useMutation({
    mutationFn: (a: OpenApp) => (a.status === 'active' ? commerceApi.disableApp(a.id) : commerceApi.enableApp(a.id)),
    onSuccess: (a) => {
      refresh();
      toastOk(a.status === 'active' ? '已启用' : '已停用：接口返回 403 app_disabled，Webhook 停发');
    },
  });
  const reset = useMutation({
    mutationFn: (a: OpenApp) => commerceApi.resetSecret(a.id),
    onSuccess: (a) => {
      refresh();
      onSecret(a);
    },
  });
  const del = useMutation({
    mutationFn: (a: OpenApp) => commerceApi.deleteOpenApp(a.id),
    onSuccess: () => {
      refresh();
      onClose();
      toastOk('应用已删除');
    },
  });
  const confirmReset = (a: OpenApp) =>
    modal.confirm({
      title: `重置「${a.name}」的 App Secret？`,
      content: '旧密钥立即失效，正在使用它的系统会马上调用失败（401 invalid_signature），直到换上新密钥。',
      okText: '下一步',
      okButtonProps: { danger: true },
      cancelText: '取消',
      onOk: () => {
        modal.confirm({
          title: '再次确认重置',
          content: (
            <>
              确认重置 <b>{a.app_id}</b> 的密钥？新密钥只显示一次。
            </>
          ),
          okText: '确认重置',
          okButtonProps: { danger: true },
          cancelText: '取消',
          onOk: () => reset.mutateAsync(a),
        });
      },
    });
  const confirmDelete = (a: OpenApp) =>
    modal.confirm({
      title: `删除「${a.name}」？`,
      content: '删除后这个 App ID 不能再调用接口，Webhook 停发，调用和投递记录一并删除。不可恢复。',
      okText: '删除',
      okButtonProps: { danger: true },
      cancelText: '取消',
      onOk: () => del.mutateAsync(a),
    });

  return (
    <Drawer
      open={open}
      onClose={onClose}
      width={920}
      title={
        app ? (
          <Space>
            {app.name}
            <AppStatusTag status={app.status} />
          </Space>
        ) : (
          '应用'
        )
      }
      extra={
        app &&
        writable && (
          <Space>
            <Button icon={<Glyph name="pencil" />} onClick={() => onEdit(app)}>
              编辑
            </Button>
            <Button icon={<Glyph name="key" />} loading={reset.isPending} onClick={() => confirmReset(app)}>
              重置密钥
            </Button>
            <Button icon={<Glyph name="power" />} danger={app.status === 'active'} loading={toggle.isPending} onClick={() => toggle.mutate(app)}>
              {app.status === 'active' ? '停用' : '启用'}
            </Button>
            <Button danger icon={<Glyph name="trash" />} aria-label="删除应用" onClick={() => confirmDelete(app)} />
          </Space>
        )
      }
    >
      {app && (
        <Tabs
          activeKey={tab}
          onChange={setTab}
          items={[
            {
              key: 'info',
              label: '设置',
              children: (
                <Space direction="vertical" size={14} style={{ width: '100%' }}>
                  {app.status === 'disabled' && <Alert type="warning" showIcon message="应用已停用" description="接口调用返回 403 app_disabled，Webhook 停发；启用后恢复。" />}
                  <Descriptions size="small" column={1} bordered>
                    <Descriptions.Item label="App ID">
                      <Typography.Text className="num" copyable={{ tooltips: ['复制', '已复制'] }}>
                        {app.app_id}
                      </Typography.Text>
                    </Descriptions.Item>
                    <Descriptions.Item label="App Secret">
                      <span className="muted">只在创建和重置时显示一次；丢了请重置</span>
                    </Descriptions.Item>
                    <Descriptions.Item label="接口权限">
                      <ScopeTags scopes={app.scopes} />
                    </Descriptions.Item>
                    <Descriptions.Item label="IP 白名单">{app.ip_allowlist.length ? <span className="num">{app.ip_allowlist.join('、')}</span> : <span className="muted">不限（建议填写收银机 / 服务器的出口 IP）</span>}</Descriptions.Item>
                    <Descriptions.Item label="Webhook 地址">{app.webhook_url ? <span className="num">{app.webhook_url}</span> : <span className="muted">未设置</span>}</Descriptions.Item>
                    <Descriptions.Item label="订阅事件">
                      {app.webhook_events.length ? (
                        <Space size={[4, 4]} wrap>
                          {app.webhook_events.map((e) => (
                            <Tooltip key={e} title={e}>
                              <Tag bordered={false} style={{ marginInlineEnd: 0 }}>
                                {WEBHOOK_EVENT[e]?.text ?? e}
                              </Tag>
                            </Tooltip>
                          ))}
                        </Space>
                      ) : (
                        <span className="muted">没有订阅</span>
                      )}
                    </Descriptions.Item>
                    <Descriptions.Item label="最近调用">
                      <span className="num">{app.last_used_at ? dt(app.last_used_at) : '从未调用'}</span>
                    </Descriptions.Item>
                    <Descriptions.Item label="创建时间">
                      <span className="num">{dt(app.created_at)}</span>
                    </Descriptions.Item>
                  </Descriptions>
                </Space>
              ),
            },
            { key: 'calls', label: '调用记录', children: <CallsTable app={app} /> },
            { key: 'deliveries', label: 'Webhook 投递', children: <DeliveriesTable app={app} writable={writable} /> },
          ]}
        />
      )}
    </Drawer>
  );
}

interface FormValues {
  name: string;
  scopes: OpenScope[];
  ip_allowlist: string[];
  webhook_url?: string;
  webhook_events: string[];
}

function AppForm({ value, onClose, onCreated }: { value: OpenApp | 'new' | null; onClose: () => void; onCreated: (a: OpenAppWithSecret) => void }) {
  const qc = useQueryClient();
  const [form] = Form.useForm<FormValues>();
  const editing = value && value !== 'new' ? value : null;
  const scopes = Form.useWatch('scopes', form) ?? [];
  const url = Form.useWatch('webhook_url', form);
  useEffect(() => {
    if (!value) return;
    form.resetFields();
    form.setFieldsValue(
      editing
        ? { name: editing.name, scopes: editing.scopes, ip_allowlist: editing.ip_allowlist, webhook_url: editing.webhook_url ?? '', webhook_events: editing.webhook_events }
        : { scopes: ['products', 'orders', 'redemptions'], ip_allowlist: [], webhook_events: [] },
    );
  }, [value, editing, form]);
  const save = useMutation({
    mutationFn: (body: OpenAppInput) => (editing ? commerceApi.updateOpenApp(editing.id, body) : commerceApi.createOpenApp(body)),
    onSuccess: (a) => {
      qc.invalidateQueries({ queryKey: ['open-apps'] });
      onClose();
      if ('app_secret' in a && a.app_secret) onCreated(a as OpenAppWithSecret);
      else toastOk('应用已保存');
    },
  });
  const submit = (v: FormValues) => {
    const webhook = v.webhook_url?.trim() || null;
    save.mutate({
      name: v.name.trim(),
      scopes: v.scopes,
      ip_allowlist: (v.ip_allowlist ?? []).map((x) => x.trim()).filter(Boolean),
      webhook_url: webhook,
      // Only events the app has the scope for are pushed; keep the rest out.
      webhook_events: webhook ? (v.webhook_events ?? []).filter((e) => !WEBHOOK_EVENT[e]?.scope || v.scopes.includes(WEBHOOK_EVENT[e].scope!)) : [],
    });
  };
  return (
    <Drawer
      open={value !== null}
      onClose={onClose}
      width={720}
      title={editing ? `编辑应用 · ${editing.name}` : '新建应用'}
      extra={
        <Space>
          <Button onClick={onClose}>取消</Button>
          <Button type="primary" loading={save.isPending} onClick={() => form.submit()}>
            {editing ? '保存' : '创建'}
          </Button>
        </Space>
      }
    >
      {!editing && <Alert type="info" showIcon style={{ marginBottom: 16 }} message="创建后会显示一次 App Secret，请马上保存到你的系统配置里" />}
      <Form form={form} layout="vertical" onFinish={submit} requiredMark="optional">
        <Form.Item name="name" label="应用名称" rules={[{ required: true, whitespace: true, message: '请填写名称' }, { max: 30, message: '最多 30 字' }]}>
          <Input placeholder="收银系统" />
        </Form.Item>
        <Form.Item name="scopes" label="接口权限" rules={[{ required: true, type: 'array', min: 1, message: '至少选一个' }]} extra="只开需要的权限；没有权限的接口返回 403 scope_denied">
          <Checkbox.Group className="scope-grid">
            {OPEN_SCOPES.map((s) => (
              <Checkbox key={s} value={s}>
                <b>{OPEN_SCOPE[s].text}</b>
                <span className="muted">{OPEN_SCOPE[s].hint}</span>
              </Checkbox>
            ))}
          </Checkbox.Group>
        </Form.Item>
        <Form.Item
          name="ip_allowlist"
          label="IP 白名单"
          extra="IPv4 或 CIDR（如 203.0.113.0/24），回车添加；留空 = 不限，不在白名单的请求返回 403 ip_not_allowed"
          rules={[{ validator: (_, v?: string[]) => (!v || v.every((x) => IP_RE.test(x.trim())) ? Promise.resolve() : Promise.reject(new Error('有格式不对的 IP'))) }, { type: 'array', max: 20, message: '最多 20 条' }]}
        >
          <Select mode="tags" tokenSeparators={[',', '，', ' ']} placeholder="203.0.113.10" open={false} suffixIcon={null} />
        </Form.Item>
        <Form.Item name="webhook_url" label="Webhook 地址" rules={[{ pattern: /^https:\/\/\S+$/, message: '需要 https 地址' }]} extra="平台 POST 事件到这里，10 秒内返回 2xx 算成功">
          <Input placeholder="https://pos.example.com/loopland/webhook" allowClear />
        </Form.Item>
        <Form.Item name="webhook_events" label="订阅事件" extra={url ? '只推送应用有对应接口权限的事件' : '先填 Webhook 地址'}>
          <Checkbox.Group className="scope-grid" disabled={!url}>
            {WEBHOOK_EVENTS.map((e) => {
              const scope = WEBHOOK_EVENT[e].scope;
              const missing = !!scope && !scopes.includes(scope);
              return (
                <Checkbox key={e} value={e} disabled={missing}>
                  <b>{WEBHOOK_EVENT[e].text}</b>
                  <span className="muted num">
                    {e}
                    {missing && ` · 需要「${OPEN_SCOPE[scope!].text}」权限`}
                  </span>
                </Checkbox>
              );
            })}
          </Checkbox.Group>
        </Form.Item>
      </Form>
    </Drawer>
  );
}
