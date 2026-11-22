// V2 第五批 · 开放平台 pieces shared by the merchant's 开放平台 page and the admin's 商户详情 (docs/api/v2-5「开放平台」):
// one-time secret dialog, signing guide, call log and webhook delivery tables, the admin's per-merchant app list.
import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, App, Button, Empty, Modal, Space, Table, Tag, Tooltip, Typography } from 'antd';
import { ApiOutlined, ExclamationCircleFilled, PoweroffOutlined, ReloadOutlined, SendOutlined } from '@ant-design/icons';
import { commerceApi, type OpenApp, type OpenAppWithSecret, type OpenCall, type WebhookDelivery } from '../../api/commerce';
import { useAuth } from '../../auth/AuthContext';
import { dt, num } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { DELIVERY_STATUS, OPEN_ERROR, OPEN_SCOPE, WEBHOOK_EVENT } from './commerceLabels';

const PAGE = 20;
const DOC = 'docs/api/v2-5-商户商品与开放平台.md';

export function AppStatusTag({ status }: { status: OpenApp['status'] }) {
  return (
    <Tag bordered={false} color={status === 'active' ? 'success' : 'default'} style={{ marginInlineEnd: 0 }}>
      {status === 'active' ? '启用' : '已停用'}
    </Tag>
  );
}

export function ScopeTags({ scopes }: { scopes: string[] }) {
  return (
    <Space size={[4, 4]} wrap>
      {scopes.map((s) => (
        <Tooltip key={s} title={OPEN_SCOPE[s as keyof typeof OPEN_SCOPE]?.hint}>
          <Tag bordered={false} style={{ marginInlineEnd: 0 }}>
            {OPEN_SCOPE[s as keyof typeof OPEN_SCOPE]?.text ?? s}
          </Tag>
        </Tooltip>
      ))}
    </Space>
  );
}

/** Shows app_id + app_secret once (create / reset); closes only through 「我已保存」. */
export function SecretModal({ app, reset, onClose }: { app: OpenAppWithSecret | null; reset?: boolean; onClose: () => void }) {
  return (
    <Modal
      open={!!app}
      title={reset ? '新的 App Secret' : '应用已创建'}
      closable={false}
      maskClosable={false}
      keyboard={false}
      footer={
        <Button type="primary" onClick={onClose}>
          我已保存
        </Button>
      }
      width={600}
    >
      {app && (
        <Space direction="vertical" size={14} style={{ width: '100%' }}>
          <Alert
            type="warning"
            showIcon
            icon={<ExclamationCircleFilled />}
            message="App Secret 只显示这一次，关闭后无法再查看"
            description={`请立即复制并保存到你的系统配置里（不要发到聊天群或写进代码仓库）。丢失只能重置，重置后旧密钥立即失效。${reset ? '使用旧密钥的系统需要马上换成新的。' : ''}`}
          />
          <div>
            <div className="muted" style={{ fontSize: 12, marginBottom: 4 }}>
              App ID
            </div>
            <div className="secret-box">
              <Typography.Text copyable={{ text: app.app_id, tooltips: ['复制', '已复制'] }}>{app.app_id}</Typography.Text>
            </div>
          </div>
          <div>
            <div className="muted" style={{ fontSize: 12, marginBottom: 4 }}>
              App Secret
            </div>
            <div className="secret-box">
              <Typography.Text copyable={{ text: app.app_secret, tooltips: ['复制', '已复制'] }} strong>
                {app.app_secret}
              </Typography.Text>
            </div>
          </div>
        </Space>
      )}
    </Modal>
  );
}

const PY_SAMPLE = `import hashlib, hmac, time, secrets, requests
def call(method, path, query="", body=b""):
    ts, nonce = str(int(time.time())), secrets.token_hex(8)
    s = "\\n".join([method, path, query, ts, nonce, hashlib.sha256(body).hexdigest()])
    sig = hmac.new(APP_SECRET.encode(), s.encode(), hashlib.sha256).hexdigest()
    h = {"X-Loop-App-Id": APP_ID, "X-Loop-Timestamp": ts, "X-Loop-Nonce": nonce, "X-Loop-Signature": sig, "Content-Type": "application/json"}
    return requests.request(method, BASE + path + ("?" + query if query else ""), data=body, headers=h)`;

const STRING_TO_SIGN = `METHOD                     # GET / POST …
/open/v1/products          # 路径
a=1&b=2                    # query 按 key 字典序排序后 urlencode 拼接；没有为空行
1732240000                 # X-Loop-Timestamp
6f1c0a9e2b7d4c31           # X-Loop-Nonce
<hex(SHA256(请求体原始字节))>  # 没有请求体时为空串的 SHA256`;

/** 签名说明: headers, the string to sign, the Python sample of the contract, webhook verification. */
export function SigningGuide({ open, onClose }: { open: boolean; onClose: () => void }) {
  return (
    <Modal open={open} onCancel={onClose} footer={null} width={760} title="接口签名说明">
      <Space direction="vertical" size={12} style={{ width: '100%' }}>
        <div>
          每个请求带 4 个头：<Typography.Text code>X-Loop-App-Id</Typography.Text> <Typography.Text code>X-Loop-Timestamp</Typography.Text>（Unix 秒，与服务器相差 ≤ 300 秒）
          <Typography.Text code>X-Loop-Nonce</Typography.Text>（16–64 位随机串，10 分钟内不可重复）<Typography.Text code>X-Loop-Signature</Typography.Text> = hex(HMAC-SHA256(app_secret, 待签名串))。
        </div>
        <div>
          <b>待签名串</b>（6 行，用 \n 连接）
          <pre className="code-block" style={{ marginTop: 6 }}>{STRING_TO_SIGN}</pre>
        </div>
        <div>
          <b>Python 示例</b>
          <pre className="code-block" style={{ marginTop: 6 }}>{PY_SAMPLE}</pre>
        </div>
        <div>
          <b>Webhook 验签</b>：平台 POST 到你的地址，带 <Typography.Text code>X-Loop-Event</Typography.Text> <Typography.Text code>X-Loop-Delivery</Typography.Text> <Typography.Text code>X-Loop-Timestamp</Typography.Text>{' '}
          <Typography.Text code>X-Loop-Signature</Typography.Text> = hex(HMAC-SHA256(app_secret, timestamp + &quot;.&quot; + body))。10 秒内返回 2xx 算成功，否则按 1 分钟、5 分钟、30 分钟、2 小时、6 小时重试；同一事件 id 可能重复投递，请按 id 去重。
        </div>
        <Alert
          type="info"
          showIcon
          message="限流：每个应用每分钟 120 次；POST 可带 Idempotency-Key（24 小时内同 key 返回第一次的结果）"
          description={
            <>
              完整接口、错误码和 Go / Java / Node 示例见接口文档 <Typography.Text code copyable={{ text: DOC }}>{DOC}</Typography.Text>「开放平台」一节。
            </>
          }
        />
      </Space>
    </Modal>
  );
}

export function CallsTable({ app }: { app: OpenApp }) {
  const [page, setPage] = useState(1);
  const q = useQuery({ queryKey: ['open-apps', 'calls', app.id, page], queryFn: () => commerceApi.appCalls(app.id, page), placeholderData: (p) => p });
  return (
    <Table<OpenCall>
      size="small"
      rowKey="id"
      loading={q.isFetching}
      dataSource={q.data?.items}
      scroll={{ x: 760 }}
      locale={{ emptyText: <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="最近 7 天没有调用" /> }}
      pagination={{ current: page, pageSize: PAGE, total: q.data?.total ?? 0, size: 'small', showSizeChanger: false, showTotal: (t) => `最近 7 天 ${t} 次`, onChange: setPage }}
      columns={[
        { title: '时间', dataIndex: 'created_at', width: 120, render: (v: string) => <span className="num">{dt(v, 'MM-DD HH:mm:ss')}</span> },
        {
          title: '接口',
          key: 'path',
          render: (_, c) => (
            <span className="num" style={{ whiteSpace: 'nowrap' }}>
              <b>{c.method}</b> {c.path}
            </span>
          ),
        },
        {
          title: '结果',
          key: 'status',
          width: 200,
          render: (_, c) =>
            c.status_code < 400 ? (
              <Tag bordered={false} color="success">
                {c.status_code}
              </Tag>
            ) : (
              <Tooltip title={OPEN_ERROR[c.error_code ?? ''] ?? c.error_code}>
                <Tag bordered={false} color="error">
                  {c.status_code} {c.error_code}
                </Tag>
              </Tooltip>
            ),
        },
        { title: '耗时', dataIndex: 'latency_ms', width: 80, align: 'right', render: (v: number) => <span className="num">{num(v)} ms</span> },
        { title: 'IP', dataIndex: 'ip', width: 130, render: (v: string) => <span className="num">{v}</span> },
      ]}
    />
  );
}

export function DeliveriesTable({ app, writable }: { app: OpenApp; writable: boolean }) {
  const qc = useQueryClient();
  const [page, setPage] = useState(1);
  const q = useQuery({ queryKey: ['open-apps', 'deliveries', app.id, page], queryFn: () => commerceApi.appDeliveries(app.id, page), placeholderData: (p) => p });
  const refresh = () => qc.invalidateQueries({ queryKey: ['open-apps', 'deliveries', app.id] });
  const redeliver = useMutation({
    mutationFn: (d: WebhookDelivery) => commerceApi.redeliver(app.id, d.id),
    onSuccess: (d) => {
      refresh();
      toastOk(d.status === 'succeeded' ? '重发成功，对方返回 2xx' : `重发失败：${d.last_error ?? d.last_status_code ?? ''}`);
    },
  });
  const ping = useMutation({
    mutationFn: () => commerceApi.testWebhook(app.id),
    onSuccess: (d) => {
      setPage(1);
      refresh();
      toastOk(d.status === 'succeeded' ? '测试 ping 已送达，对方返回 2xx' : `测试 ping 没有成功：${d.last_error ?? d.last_status_code ?? ''}，会按策略重试`);
    },
  });
  const disabled = app.status !== 'active' || !app.webhook_url;
  return (
    <>
      <div className="mer-h3-row">
        <span className="muted num" style={{ fontSize: 12 }}>
          {app.webhook_url ? `POST ${app.webhook_url}` : '还没有设置 Webhook 地址'}
        </span>
        {writable && (
          <Tooltip title={app.status !== 'active' ? '应用已停用，Webhook 停发' : !app.webhook_url ? '先在设置里填 Webhook 地址' : '发一条 ping 事件，检查地址和验签'}>
            <Button size="small" icon={<SendOutlined />} disabled={disabled} loading={ping.isPending} onClick={() => ping.mutate()}>
              发送测试 ping
            </Button>
          </Tooltip>
        )}
      </div>
      <Table<WebhookDelivery>
        size="small"
        rowKey="id"
        loading={q.isFetching}
        dataSource={q.data?.items}
        scroll={{ x: 820 }}
        locale={{ emptyText: <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="还没有投递记录" /> }}
        pagination={{ current: page, pageSize: PAGE, total: q.data?.total ?? 0, size: 'small', showSizeChanger: false, showTotal: (t) => `共 ${t} 条`, onChange: setPage }}
        columns={[
          { title: '时间', dataIndex: 'created_at', width: 110, render: (v: string) => <span className="num">{dt(v, 'MM-DD HH:mm')}</span> },
          {
            title: '事件',
            key: 'event',
            render: (_, d) => (
              <span>
                {WEBHOOK_EVENT[d.event_type]?.text ?? d.event_type}
                <div className="muted num" style={{ fontSize: 12 }}>
                  {d.event_type} · {d.event_id}
                </div>
              </span>
            ),
          },
          {
            title: '结果',
            key: 'status',
            width: 190,
            render: (_, d) => (
              <span>
                <Tag bordered={false} color={DELIVERY_STATUS[d.status]?.color}>
                  {DELIVERY_STATUS[d.status]?.text ?? d.status}
                </Tag>
                <span className="num muted" style={{ fontSize: 12 }}>
                  {d.last_status_code ?? '—'} · 第 {d.attempt_qty} 次
                </span>
                {d.last_error && <div className="danger-text" style={{ fontSize: 12 }}>{d.last_error}</div>}
                {d.next_retry_at && <div className="muted num" style={{ fontSize: 12 }}>下次重试 {dt(d.next_retry_at, 'HH:mm')}</div>}
              </span>
            ),
          },
          {
            title: '操作',
            key: 'op',
            width: 90,
            align: 'right',
            render: (_, d) =>
              writable && d.status !== 'succeeded' ? (
                <Button size="small" icon={<ReloadOutlined />} disabled={disabled} loading={redeliver.isPending && redeliver.variables?.id === d.id} onClick={() => redeliver.mutate(d)}>
                  重发
                </Button>
              ) : (
                <span className="muted">—</span>
              ),
          },
        ]}
      />
    </>
  );
}

/** 商户详情 · 开放平台 (admin): the merchant's apps; admin can disable / enable them. */
export function OpenAppsSection({ merchantId }: { merchantId: number }) {
  const { modal } = App.useApp();
  const { can } = useAuth();
  const qc = useQueryClient();
  const apps = useQuery({ queryKey: ['open-apps', 'list', merchantId], queryFn: () => commerceApi.openApps(merchantId) });
  const [logOf, setLogOf] = useState<OpenApp | null>(null);
  const toggle = useMutation({
    mutationFn: (a: OpenApp) => (a.status === 'active' ? commerceApi.disableApp(a.id) : commerceApi.enableApp(a.id)),
    onSuccess: (a) => {
      qc.invalidateQueries({ queryKey: ['open-apps'] });
      toastOk(a.status === 'active' ? `「${a.name}」已启用` : `「${a.name}」已停用，接口返回 app_disabled，Webhook 停发`);
    },
  });
  const items = apps.data?.items ?? [];
  return (
    <section>
      <div className="mer-h3-row">
        <h3 className="mer-h3">
          <ApiOutlined /> 开放平台应用 · {items.length}
        </h3>
        <span className="muted" style={{ fontSize: 12 }}>商户在自己的「开放平台」页创建；平台只能停用</span>
      </div>
      <Table<OpenApp>
        size="small"
        rowKey="id"
        loading={apps.isLoading}
        pagination={false}
        dataSource={items}
        scroll={{ x: 760 }}
        locale={{ emptyText: '没有开放平台应用' }}
        columns={[
          {
            title: '应用',
            key: 'name',
            render: (_, a) => (
              <span>
                <b>{a.name}</b>
                <div className="muted num" style={{ fontSize: 12 }}>
                  {a.app_id}
                </div>
              </span>
            ),
          },
          { title: '权限', dataIndex: 'scopes', render: (s: string[]) => <ScopeTags scopes={s} /> },
          { title: '最近调用', dataIndex: 'last_used_at', width: 110, render: (v: string | null) => <span className="num">{v ? dt(v, 'MM-DD HH:mm') : '从未'}</span> },
          { title: '状态', dataIndex: 'status', width: 70, render: (s: OpenApp['status']) => <AppStatusTag status={s} /> },
          {
            title: '操作',
            key: 'op',
            width: 150,
            align: 'right',
            render: (_, a) => (
              <Space size={4}>
                <Button size="small" onClick={() => setLogOf(a)}>
                  记录
                </Button>
                {can('openapi.manage') && (
                  <Button
                    size="small"
                    danger={a.status === 'active'}
                    icon={<PoweroffOutlined />}
                    onClick={() =>
                      modal.confirm({
                        title: `${a.status === 'active' ? '停用' : '启用'}「${a.name}」？`,
                        content: a.status === 'active' ? '停用后这个应用的接口调用返回 403 app_disabled，Webhook 停发；商户会在开放平台页看到已停用。' : '启用后应用恢复调用和 Webhook 推送。',
                        okText: a.status === 'active' ? '停用' : '启用',
                        okButtonProps: { danger: a.status === 'active' },
                        cancelText: '取消',
                        onOk: () => toggle.mutateAsync(a),
                      })
                    }
                  >
                    {a.status === 'active' ? '停用' : '启用'}
                  </Button>
                )}
              </Space>
            ),
          },
        ]}
      />
      <Modal open={!!logOf} onCancel={() => setLogOf(null)} footer={null} width={900} title={logOf ? `${logOf.name} · 调用与投递记录` : ''} destroyOnHidden>
        {logOf && (
          <Space direction="vertical" size={16} style={{ width: '100%' }}>
            <div>
              <h3 className="mer-h3">Webhook 投递</h3>
              <DeliveriesTable app={logOf} writable={false} />
            </div>
            <div>
              <h3 className="mer-h3">调用记录（最近 7 天）</h3>
              <CallsTable app={logOf} />
            </div>
          </Space>
        )}
      </Modal>
    </section>
  );
}
