import { useMemo, useState, type ReactNode } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, App, Button, Col, Drawer, Empty, Form, Input, InputNumber, Modal, Row, Segmented, Select, Skeleton, Space, Switch, Tag, Tooltip, Typography } from 'antd';
import type { Rule } from 'antd/es/form';
import {
  AlipayCircleOutlined,
  ApiOutlined,
  AppleOutlined,
  CheckCircleFilled,
  CloseCircleFilled,
  CloudOutlined,
  EditOutlined,
  EnvironmentOutlined,
  IdcardOutlined,
  LinkOutlined,
  LockOutlined,
  MailOutlined,
  MessageOutlined,
  MobileOutlined,
  PayCircleOutlined,
  RobotOutlined,
  SafetyCertificateOutlined,
  WechatOutlined,
} from '@ant-design/icons';
import { api } from '../api/admin';
import type { Items, Provider, ProviderCheck, ProviderField, ProviderSave, ProviderSecret } from '../api/types';
import { PageHeader, Panel, Tile } from '../components/ui';
import { useAdminNames } from '../hooks/useAdminNames';
import { ago, dt } from '../utils/format';
import { PROVIDER_GROUPS, PROVIDER_SOURCE } from '../utils/labels';
import { errorMessage, toastOk } from '../utils/notify';

// 系统配置 · 第三方服务 (docs/api/系统配置.md). Secrets never reach the browser in plain text:
// the list gives {set, hint}; what the admin types is sent once on save and the inputs are
// dropped with the drawer. Nothing here is logged or written to browser storage.

const QK = ['providers'];

const ICON: Record<string, ReactNode> = {
  aliyun: <CloudOutlined />,
  sms: <MessageOutlined />,
  captcha: <SafetyCertificateOutlined />,
  oneclick: <MobileOutlined />,
  realname: <IdcardOutlined />,
  wechat_login: <WechatOutlined />,
  wechat_pay: <PayCircleOutlined />,
  alipay: <AlipayCircleOutlined />,
  apple: <AppleOutlined />,
  ai: <RobotOutlined />,
  email: <MailOutlined />,
  amap: <EnvironmentOutlined />,
};

/** Tests that make a real (possibly paid) call; the input's own text comes from test_input. */
const TEST_INPUT: Record<string, { placeholder: string; optional?: boolean; note: string; rule?: Rule }> = {
  sms: {
    placeholder: '13800000000',
    optional: true,
    note: '留空只验证 AccessKey 和签名、不发短信；填了手机号会真实发送一条验证码短信（123456），按条计费。',
    rule: { pattern: /^1\d{10}$/, message: '请输入 11 位手机号' },
  },
  realname: {
    placeholder: '张三,110101199001011234',
    note: '每次测试都是一次真实的收费调用。请用英文逗号分隔姓名和身份证号。',
    rule: { pattern: /^[^,，]+[,，]\s*\d{17}[\dXx]$/, message: '格式：姓名,身份证号' },
  },
  email: {
    placeholder: 'ops@example.com',
    note: '会用当前配置真实发送一封测试邮件。',
    rule: { type: 'email', message: '请输入正确的邮箱地址' },
  },
};

const isSecretValue = (v: unknown): v is ProviderSecret => typeof v === 'object' && v !== null && 'set' in v;

function plainValue(p: Provider, key: string): string {
  const v = p.values[key];
  return typeof v === 'string' ? v : '';
}

function secretValue(p: Provider, key: string): ProviderSecret {
  const v = p.values[key];
  return isSecretValue(v) ? v : { set: false };
}

/** "qwen-通义千问 deepseek-DeepSeek …" → { qwen: '通义千问', … } when help names the options. */
function optionLabels(f: ProviderField): Record<string, string> {
  const out: Record<string, string> = {};
  for (const tok of (f.help ?? '').split(/\s+/)) {
    const i = tok.indexOf('-');
    if (i > 0 && f.options?.includes(tok.slice(0, i))) out[tok.slice(0, i)] = tok.slice(i + 1);
  }
  return out;
}

export default function ProvidersPage() {
  const { modal, message } = App.useApp();
  const qc = useQueryClient();
  const [params, setParams] = useSearchParams();
  const list = useQuery({ queryKey: QK, queryFn: api.providers });
  const items = useMemo(() => list.data?.items ?? [], [list.data]);
  const byCode = useMemo(() => new Map(items.map((p) => [p.code, p])), [items]);
  const names = useAdminNames();

  const groups = useMemo(() => {
    const seen = [...PROVIDER_GROUPS];
    for (const p of items) if (!seen.includes(p.group)) seen.push(p.group);
    return seen.filter((g) => items.some((p) => p.group === g));
  }, [items]);
  const group = groups.includes(params.get('group') ?? '') ? params.get('group')! : 'all';

  const [editing, setEditing] = useState<string | null>(null);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [testing, setTesting] = useState<Provider | null>(null);
  const [testingCode, setTestingCode] = useState<string | null>(null);

  const replaceItem = (item: Provider) =>
    qc.setQueryData<Items<Provider>>(QK, (old) => (old ? { items: old.items.map((p) => (p.code === item.code ? item : p)) } : old));

  const toggle = useMutation({
    mutationFn: ({ code, enabled }: { code: string; enabled: boolean }) => api.saveProvider(code, { enabled, values: {}, clear: [] }),
    onSuccess: (item) => {
      replaceItem(item);
      qc.invalidateQueries({ queryKey: QK });
      toastOk(`已${item.enabled ? '启用' : '停用'}「${item.name}」`);
    },
  });

  const runTest = async (p: Provider, input?: string) => {
    setTestingCode(p.code);
    try {
      const res = await api.testProvider(p.code, input?.trim() || undefined);
      showResult(p, res);
    } catch (err) {
      modal.error({ title: `「${p.name}」测试失败`, content: errorMessage(err), okText: '知道了' });
    } finally {
      setTestingCode(null);
      qc.invalidateQueries({ queryKey: QK });
    }
  };

  const showResult = (p: Provider, res: ProviderCheck) => {
    if (res.status === 'ok') message.success(`「${p.name}」${res.message || '连接正常'}`);
    else
      modal.error({
        title: `「${p.name}」测试未通过`,
        content: <div style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-all' }}>{res.message}</div>,
        okText: '知道了',
      });
  };

  const onTest = (p: Provider) => (p.test_input ? setTesting(p) : runTest(p));

  const onToggle = (p: Provider, on: boolean) =>
    modal.confirm({
      title: `${on ? '启用' : '停用'}「${p.name}」？`,
      content: (
        <>
          {on ? '启用前会校验必填项和依赖的服务。' : '停用后 App 和后端立即不再使用这个服务。'}
          {p.source !== 'db' && <div style={{ marginTop: 8 }}>这是第一次在管理端保存，当前生效的配置会一起写入数据库，之后以管理端为准。</div>}
        </>
      ),
      okText: on ? '启用' : '停用',
      okButtonProps: { danger: !on },
      cancelText: '取消',
      // The error (e.g. 400 invalid_config) is shown verbatim by the global toast.
      onOk: () => toggle.mutateAsync({ code: p.code, enabled: on }).catch(() => undefined),
    });

  const total = items.length;
  const enabledCount = items.filter((p) => p.enabled).length;
  const unconfigured = items.filter((p) => !p.configured).length;
  const failing = items.filter((p) => p.last_check?.status === 'fail').length;
  const fromConfig = items.filter((p) => p.source === 'config').length;

  const shown = group === 'all' ? groups : [group];
  const editingProvider = editing ? byCode.get(editing) ?? null : null;

  return (
    <>
      <PageHeader
        title="系统配置"
        sub="第三方服务的 Key 加密存库、接口不返回明文；保存后本实例立即生效，其他实例 30 秒内生效，不用重启"
        extra={
          groups.length > 0 && (
            <Segmented
              size="large"
              value={group}
              onChange={(v) => setParams(v === 'all' ? {} : { group: String(v) }, { replace: true })}
              options={[{ label: '全部', value: 'all' }, ...groups.map((g) => ({ label: g, value: g }))]}
            />
          )
        }
      />

      {list.isLoading ? (
        <Panel>
          <Skeleton active paragraph={{ rows: 8 }} />
        </Panel>
      ) : list.isError ? (
        <Panel>
          <Empty description={`加载失败：${errorMessage(list.error)}`}>
            <Button onClick={() => list.refetch()}>重试</Button>
          </Empty>
        </Panel>
      ) : (
        <>
          <Row gutter={[12, 12]}>
            <Col xs={12} md={6}>
              <Tile v={`${enabledCount} / ${total}`} l="已启用" />
            </Col>
            <Col xs={12} md={6}>
              <Tile v={unconfigured} l="必填项未填全" />
            </Col>
            <Col xs={12} md={6}>
              <Tile v={failing} l="最近测试未通过" warn={failing > 0} />
            </Col>
            <Col xs={12} md={6}>
              <Tile v={fromConfig} l="仍在用配置文件" />
            </Col>
          </Row>
          {shown.map((g) => (
            <Panel key={g} title={g} extra={<span className="panel-hint">{items.filter((p) => p.group === g).length} 个服务</span>}>
              <Row gutter={[16, 16]}>
                {items
                  .filter((p) => p.group === g)
                  .map((p) => (
                    <Col key={p.code} xs={24} lg={12} xxl={8}>
                      <ProviderCard
                        p={p}
                        uses={p.uses ? byCode.get(p.uses) : undefined}
                        who={p.updated_by !== null ? names(p.updated_by) : ''}
                        testing={testingCode === p.code}
                        toggling={toggle.isPending && toggle.variables?.code === p.code}
                        onEdit={() => {
                          setEditing(p.code);
                          setDrawerOpen(true);
                        }}
                        onTest={() => onTest(p)}
                        onToggle={(on) => onToggle(p, on)}
                      />
                    </Col>
                  ))}
              </Row>
            </Panel>
          ))}
        </>
      )}

      <ProviderDrawer
        provider={editingProvider}
        uses={editingProvider?.uses ? byCode.get(editingProvider.uses) : undefined}
        open={drawerOpen}
        onClose={() => setDrawerOpen(false)}
        afterClose={() => setEditing(null)}
        onSaved={(item) => {
          replaceItem(item);
          qc.invalidateQueries({ queryKey: QK });
          setDrawerOpen(false);
          toastOk(`已保存「${item.name}」${item.enabled ? '' : '（停用）'}`);
        }}
      />

      <TestModal
        provider={testing}
        onClose={() => setTesting(null)}
        onRun={(p, input) => {
          setTesting(null);
          void runTest(p, input);
        }}
      />
    </>
  );
}

// ---------------------------------------------------------------- card

function StatusTags({ p }: { p: Provider }) {
  const src = PROVIDER_SOURCE[p.source] ?? PROVIDER_SOURCE.none;
  return (
    <Space size={4} wrap>
      {p.enabled ? (
        <Tag color="success" bordered={false}>
          启用
        </Tag>
      ) : (
        <Tag bordered={false}>停用</Tag>
      )}
      {p.configured ? (
        <Tag color="processing" bordered={false}>
          已配置
        </Tag>
      ) : (
        <Tag color="warning" bordered={false}>
          未配置
        </Tag>
      )}
      <Tooltip title={src.hint}>
        <Tag color={src.color} bordered={false}>
          {src.text}
        </Tag>
      </Tooltip>
    </Space>
  );
}

function CheckLine({ c }: { c: ProviderCheck | null }) {
  if (!c) return <span className="muted">还没测试过</span>;
  const okay = c.status === 'ok';
  return (
    <div className="prov-check">
      <span className={okay ? 'prov-ok' : 'danger-text'}>
        {okay ? <CheckCircleFilled /> : <CloseCircleFilled />} {okay ? '通过' : '未通过'}
      </span>
      <Tooltip title={dt(c.time, 'YYYY-MM-DD HH:mm:ss')}>
        <span className="muted num"> · {ago(c.time)}</span>
      </Tooltip>
      {c.message && (
        <Typography.Paragraph className={okay ? 'prov-msg muted' : 'prov-msg danger-text'} ellipsis={{ rows: 2, tooltip: c.message }}>
          {c.message}
        </Typography.Paragraph>
      )}
    </div>
  );
}

function ProviderCard(props: {
  p: Provider;
  uses?: Provider;
  who: string;
  testing: boolean;
  toggling: boolean;
  onEdit: () => void;
  onTest: () => void;
  onToggle: (on: boolean) => void;
}) {
  const { p, uses, who, testing, toggling } = props;
  return (
    <div className={`prov-card${p.enabled ? '' : ' off'}`} data-code={p.code}>
      <div className="prov-head">
        <div className="prov-icon">{ICON[p.code] ?? <ApiOutlined />}</div>
        <div className="prov-title">
          <div className="prov-name">
            {p.name}
            <span className="prov-code">{p.code}</span>
          </div>
          <StatusTags p={p} />
        </div>
        <Tooltip title={p.enabled ? '停用' : '启用'}>
          <Switch checked={p.enabled} loading={toggling} onChange={props.onToggle} aria-label={`启用${p.name}`} />
        </Tooltip>
      </div>
      <div className="prov-desc">{p.description}</div>
      {p.uses && (
        <div className="prov-uses">
          <LinkOutlined /> 复用：{uses?.name ?? p.uses}
          {uses && !uses.configured && <span className="danger-text"> · 尚未配置，配好之前不能启用</span>}
        </div>
      )}
      <div className="prov-meta">
        <div className="prov-meta-l">最近测试</div>
        <CheckLine c={p.last_check} />
        <div className="prov-meta-l">最后保存</div>
        <div>
          {p.update_time ? (
            <span>
              <span className="num">{dt(p.update_time)}</span>
              {who && <span className="muted"> · {who}</span>}
            </span>
          ) : (
            <span className="muted">没在管理端保存过</span>
          )}
        </div>
      </div>
      <div className="prov-actions">
        <Button icon={<EditOutlined />} onClick={props.onEdit}>
          编辑配置
        </Button>
        <Button icon={<ApiOutlined />} loading={testing} onClick={props.onTest}>
          测试连接
        </Button>
        {p.code === 'ai' && (
          <Link to="/ai-usage" style={{ alignSelf: 'center', marginLeft: 4 }}>
            查看 AI 用量
          </Link>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- edit drawer

type FormValue = string | number | boolean | null | undefined;
interface FormValues {
  enabled: boolean;
  values: Record<string, FormValue>;
}

/** Form value → the string the API takes (bool "true"/"false", numbers as integers). */
function toApi(f: ProviderField, v: FormValue): string {
  if (f.kind === 'bool') return v ? 'true' : 'false';
  if (v === null || v === undefined) return '';
  return String(v).trim();
}

function initialFormValue(p: Provider, f: ProviderField): FormValue {
  if (f.secret) return '';
  const s = plainValue(p, f.key);
  if (f.kind === 'bool') return s === 'true';
  if (f.kind === 'number') return s === '' || Number.isNaN(Number(s)) ? null : Number(s);
  if (f.kind === 'select') return s || undefined;
  return s;
}

function defaultText(f: ProviderField, labels: Record<string, string>): string {
  if (!f.default) return '';
  if (f.kind === 'bool') return f.default === 'true' ? '开' : '关';
  return labels[f.default] ? `${labels[f.default]}（${f.default}）` : f.default;
}

function ProviderDrawer({
  provider,
  uses,
  open,
  onClose,
  afterClose,
  onSaved,
}: {
  provider: Provider | null;
  uses?: Provider;
  open: boolean;
  onClose: () => void;
  afterClose: () => void;
  onSaved: (p: Provider) => void;
}) {
  return (
    <Drawer
      open={open && !!provider}
      onClose={onClose}
      afterOpenChange={(o) => !o && afterClose()}
      width={640}
      destroyOnHidden
      title={provider ? `编辑 · ${provider.name}` : ''}
      footer={null}
    >
      {provider && <ProviderForm key={provider.code} p={provider} uses={uses} onCancel={onClose} onSaved={onSaved} />}
    </Drawer>
  );
}

function ProviderForm({ p, uses, onCancel, onSaved }: { p: Provider; uses?: Provider; onCancel: () => void; onSaved: (p: Provider) => void }) {
  const [form] = Form.useForm<FormValues>();
  const fields = useMemo(() => p.fields ?? [], [p.fields]);
  // Snapshot of the item as it was when the drawer opened: "changed" is relative to this.
  const [initial] = useState<FormValues>(() => ({
    enabled: p.enabled,
    values: Object.fromEntries(fields.map((f) => [f.key, initialFormValue(p, f)])),
  }));
  const [clearing, setClearing] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const watched = Form.useWatch([], form) as FormValues | undefined;

  const diff = (v: FormValues | undefined): ProviderSave => {
    const values: Record<string, string> = {};
    for (const f of fields) {
      const cur = v?.values?.[f.key];
      if (f.secret) {
        const s = toApi(f, cur);
        if (s && !clearing.includes(f.key)) values[f.key] = s;
      } else if (toApi(f, cur) !== toApi(f, initial.values[f.key])) {
        values[f.key] = toApi(f, cur);
      }
    }
    return { enabled: v?.enabled ?? initial.enabled, values, clear: [...clearing] };
  };

  const pending = diff(watched);
  const changedLabels = [
    ...(pending.enabled !== initial.enabled ? [pending.enabled ? '启用' : '停用'] : []),
    ...fields.filter((f) => f.key in pending.values).map((f) => f.label),
    ...fields.filter((f) => clearing.includes(f.key)).map((f) => `清除${f.label}`),
  ];

  const save = useMutation({
    mutationFn: (body: ProviderSave) => api.saveProvider(p.code, body),
    meta: { inlineError: true },
    gcTime: 0,
    onSuccess: (item) => {
      // Drop what was typed into secret inputs right away (the drawer also unmounts the form).
      form.setFieldsValue({ values: Object.fromEntries(fields.filter((f) => f.secret).map((f) => [f.key, ''])) });
      setClearing([]);
      save.reset();
      onSaved(item);
    },
    onError: (err) => {
      setError(errorMessage(err));
      save.reset();
    },
  });

  const submit = (v: FormValues) => {
    setError(null);
    save.mutate(diff(v));
  };

  const toggleClear = (key: string) => {
    setClearing((c) => (c.includes(key) ? c.filter((k) => k !== key) : [...c, key]));
  };

  return (
    <Form<FormValues> form={form} layout="vertical" initialValues={initial} onFinish={submit} autoComplete="off" className="prov-form">
      <div className="prov-desc" style={{ marginTop: 0 }}>
        {p.description}
      </div>
      <Space size={4} wrap style={{ margin: '10px 0 14px' }}>
        <StatusTags p={p} />
      </Space>

      {p.source === 'config' && (
        <Alert
          type="info"
          showIcon
          style={{ marginBottom: 12 }}
          message="当前生效的值来自配置文件 / 环境变量"
          description="第一次在这里保存时，当前生效的配置会连同你的修改一起写入数据库，之后以管理端为准。"
        />
      )}
      {p.uses && (
        <Alert
          type={uses && !uses.configured ? 'warning' : 'info'}
          showIcon
          icon={<LinkOutlined />}
          style={{ marginBottom: 12 }}
          message={`复用「${uses?.name ?? p.uses}」的凭证`}
          description={uses && !uses.configured ? `「${uses.name}」还没配置好，配好之前这个服务不能启用。` : undefined}
        />
      )}
      {error && <Alert type="error" showIcon style={{ marginBottom: 12 }} message="保存失败" description={error} closable onClose={() => setError(null)} />}

      <Form.Item name="enabled" label="启用" valuePropName="checked" extra="启用时校验必填项（带 * 的）和依赖的服务；停用时可以先保存不完整的配置。">
        <Switch />
      </Form.Item>

      {fields.length === 0 ? (
        <div className="field-cell muted" style={{ marginBottom: 16 }}>
          这个服务没有单独的配置项{p.uses ? `，直接复用「${uses?.name ?? p.uses}」的凭证` : ''}。在这里只需启用或停用。
        </div>
      ) : (
        fields.map((f) => (
          <FieldInput
            key={f.key}
            f={f}
            secret={f.secret ? secretValue(p, f.key) : undefined}
            clearing={clearing.includes(f.key)}
            onToggleClear={() => toggleClear(f.key)}
          />
        ))
      )}

      <div className="prov-footnote">
        <LockOutlined /> 敏感字段加密存库，页面和接口都不显示明文，审计日志只记字段名。「测试连接」用的是已保存的配置。
      </div>

      <div className="prov-drawer-foot">
        <span className="muted prov-changes">{changedLabels.length ? `将保存：${changedLabels.join('、')}` : '没有改动'}</span>
        <Space>
          <Button onClick={onCancel}>取消</Button>
          <Button type="primary" htmlType="submit" loading={save.isPending}>
            保存
          </Button>
        </Space>
      </div>
    </Form>
  );
}

function FieldInput({ f, secret, clearing, onToggleClear }: { f: ProviderField; secret?: ProviderSecret; clearing: boolean; onToggleClear: () => void }) {
  const labels = optionLabels(f);
  const labelled = f.options?.length ? f.options.every((o) => labels[o]) : false;
  const def = defaultText(f, labels);
  const extra = [labelled ? '' : f.help, def ? `默认：${def}` : ''].filter(Boolean).join(' · ') || undefined;
  const name = ['values', f.key];
  const rules: Rule[] = [];
  if (f.kind === 'url') rules.push({ pattern: /^https?:\/\/\S+$/, message: '必须是 http(s) 地址' });

  if (f.secret) {
    const placeholder = secret?.set ? `已设置（${secret.hint ?? '****'}）· 留空则不修改` : '未设置';
    return (
      <Form.Item label={f.label} required={f.required} extra={extra} className={clearing ? 'prov-clearing' : undefined}>
        <div className="prov-secret">
          {/* While clearing, the bound input stays mounted but hidden; what was typed is ignored on save. */}
          <div style={clearing ? { display: 'none' } : undefined}>
            <Form.Item name={name} noStyle>
              {f.kind === 'textarea' ? (
                <Input.TextArea
                  className="secret-input"
                  autoSize={{ minRows: 3, maxRows: 8 }}
                  placeholder={placeholder}
                  spellCheck={false}
                  autoComplete="off"
                  data-secret={clearing ? undefined : 'true'}
                />
              ) : (
                <Input.Password placeholder={placeholder} autoComplete="new-password" spellCheck={false} data-secret={clearing ? undefined : 'true'} />
              )}
            </Form.Item>
          </div>
          {clearing && <Input disabled placeholder="保存后清除" data-secret="true" />}
          {(secret?.set || clearing) && (
            <Button danger={!clearing} onClick={onToggleClear}>
              {clearing ? '撤销清除' : '清除'}
            </Button>
          )}
        </div>
      </Form.Item>
    );
  }

  let control: ReactNode;
  switch (f.kind) {
    case 'bool':
      return (
        <Form.Item name={name} label={f.label} required={f.required} extra={extra} valuePropName="checked">
          <Switch />
        </Form.Item>
      );
    case 'number':
      control = <InputNumber precision={0} style={{ width: 200 }} placeholder={f.default} />;
      break;
    case 'select':
      control = (
        <Select
          allowClear={!f.required}
          placeholder={def || '请选择'}
          options={(f.options ?? []).map((o) => ({ value: o, label: labels[o] ? `${labels[o]}（${o}）` : o }))}
        />
      );
      break;
    case 'textarea':
      control = <Input.TextArea autoSize={{ minRows: 3, maxRows: 8 }} placeholder={f.default} spellCheck={false} />;
      break;
    case 'url':
      control = <Input placeholder={f.default || 'https://'} inputMode="url" />;
      break;
    default:
      control = <Input placeholder={f.default} />;
  }
  return (
    <Form.Item name={name} label={f.label} required={f.required} extra={extra} rules={rules}>
      {control}
    </Form.Item>
  );
}

// ---------------------------------------------------------------- test input

function TestModal({ provider, onClose, onRun }: { provider: Provider | null; onClose: () => void; onRun: (p: Provider, input: string) => void }) {
  const [form] = Form.useForm<{ input: string }>();
  const meta = provider ? TEST_INPUT[provider.code] : undefined;
  const optional = meta?.optional ?? false;
  return (
    <Modal
      open={!!provider}
      title={provider ? `测试连接 · ${provider.name}` : ''}
      okText="开始测试"
      cancelText="取消"
      onCancel={onClose}
      onOk={() => form.submit()}
      destroyOnHidden
    >
      {provider && (
        <Form form={form} layout="vertical" autoComplete="off" onFinish={(v) => onRun(provider, v.input ?? '')} preserve={false}>
          <Alert
            type="warning"
            showIcon
            style={{ marginBottom: 16 }}
            message={provider.test_input}
            description={meta?.note ?? '这次测试会用当前生效的配置真实调用第三方服务。'}
          />
          <Form.Item
            name="input"
            label={provider.test_input}
            rules={[...(optional ? [] : [{ required: true, whitespace: true, message: `请填写${provider.test_input}` }]), ...(meta?.rule ? [meta.rule] : [])]}
            extra="只用于这次测试，不会保存。"
          >
            <Input placeholder={meta?.placeholder} autoComplete="off" spellCheck={false} />
          </Form.Item>
        </Form>
      )}
    </Modal>
  );
}
