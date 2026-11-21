import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQueries, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, App, Button, Col, Descriptions, Drawer, Empty, Form, Image, Input, InputNumber, Modal, Radio, Row, Segmented, Select, Space, Table, Tag, Tooltip } from 'antd';
import { DeleteOutlined, EditOutlined, EyeOutlined, LinkOutlined, PlusOutlined, SearchOutlined, UserAddOutlined } from '@ant-design/icons';
import { merchantApi, type Merchant, type MerchantDetail, type MerchantInput, type MerchantStatus, type MerchantType } from '../../api/merchant';
import { useAuth } from '../../auth/AuthContext';
import { PageHeader, Panel, Tile } from '../../components/ui';
import { date, dt, num, pct, yuan } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { DROP_STATUS_LABEL, DROP_TYPE_LABEL, MERCHANT_STATUS, MERCHANT_STATUS_ORDER, MERCHANT_TYPE, VENUE_SPORT } from './labels';
import { MerchantNav } from './nav';
import { MerchantIcon, MerchantStatusTag } from './shared';
import { IMAGE_URL, urlParams } from './util';

const PAGE = 20;

export default function MerchantsPage() {
  const { can } = useAuth();
  const [params, setParams] = useSearchParams();
  const update = urlParams(params, setParams);
  const status = (params.get('status') ?? '') as MerchantStatus | '';
  const q = params.get('q') ?? '';
  const page = Number(params.get('page') ?? 1);
  const openId = Number(params.get('id') ?? 0) || null;
  const [kw, setKw] = useState(q);
  const [editing, setEditing] = useState<Merchant | 'new' | null>(null);

  const list = useQuery({ queryKey: ['merchants', 'list', status, q, page], queryFn: () => merchantApi.merchants({ status, q, page }), placeholderData: (p) => p });
  // Per-status totals for the filter and the header line.
  const counts = useQueries({
    queries: MERCHANT_STATUS_ORDER.map((s) => ({ queryKey: ['merchants', 'count', s], queryFn: () => merchantApi.merchants({ status: s, page_size: 1 }), staleTime: 30_000 })),
  });
  const countOf = (s: MerchantStatus) => counts[MERCHANT_STATUS_ORDER.indexOf(s)]?.data?.total;
  const items = list.data?.items ?? [];

  return (
    <>
      <PageHeader
        title="商户与活动"
        sub={
          <>
            合作商户 <b>{countOf('partner') ?? '—'}</b> 家 · 资质审核 <b>{countOf('reviewing') ?? '—'}</b> 家 · 待签约 <b>{countOf('pending_sign') ?? '—'}</b> 家
          </>
        }
        extra={<MerchantNav />}
      />
      <Panel
        title="商户"
        extra={
          <Space wrap>
            <Input
              allowClear
              prefix={<SearchOutlined />}
              placeholder="商户名称、联系人或 ID"
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
              onChange={(v) => update({ status: String(v) || null, page: null })}
              options={[
                { label: '全部', value: '' },
                ...MERCHANT_STATUS_ORDER.map((s) => ({ label: `${MERCHANT_STATUS[s].text}${countOf(s) !== undefined ? ' ' + countOf(s) : ''}`, value: s })),
              ]}
            />
            {can('merchant.write') && (
              <Button type="primary" icon={<PlusOutlined />} onClick={() => setEditing('new')}>
                新建商户
              </Button>
            )}
          </Space>
        }
      >
        <Table<Merchant>
          rowKey="id"
          loading={list.isFetching}
          dataSource={items}
          scroll={{ x: 1100 }}
          onRow={(m) => ({ onClick: () => update({ id: m.id }), style: { cursor: 'pointer' } })}
          locale={{ emptyText: <Empty description={q || status ? '没有符合条件的商户' : '还没有商户，点「新建商户」录入'} /> }}
          pagination={{ current: page, pageSize: PAGE, total: list.data?.total ?? 0, showSizeChanger: false, showTotal: (t) => `共 ${t} 家`, onChange: (p) => update({ page: p === 1 ? null : p }) }}
          columns={[
            {
              title: '商户',
              key: 'name',
              width: 240,
              render: (_, m) => (
                <div className="mer-cell">
                  <MerchantIcon type={m.type} />
                  <div>
                    <b>{m.name}</b>
                    <div className="muted" style={{ fontSize: 12 }}>
                      {MERCHANT_TYPE[m.type] ?? m.type} · #{m.id}
                    </div>
                  </div>
                </div>
              ),
            },
            { title: '状态', dataIndex: 'status', render: (v: MerchantStatus) => <MerchantStatusTag status={v} /> },
            { title: '场馆', dataIndex: 'venue_count', align: 'right', render: (v: number) => <span className="num">{num(v)}</span> },
            { title: '投放点', dataIndex: 'drop_count', align: 'right', render: (v: number) => <span className="num">{num(v)}</span> },
            { title: '今日核销', dataIndex: 'today_redemptions', align: 'right', render: (v: number) => <b className="num">{num(v)}</b> },
            { title: '订场佣金', dataIndex: 'booking_commission_rate', align: 'right', render: (v: number, m) => <span className="num">{m.type === 'venue' || v ? pct(v) : '—'}</span> },
            {
              title: '联系人',
              key: 'contact',
              render: (_, m) => (
                <span style={{ whiteSpace: 'nowrap' }}>
                  {m.contact_name ?? '—'}
                  {m.contact_phone && <span className="num muted"> {m.contact_phone}</span>}
                </span>
              ),
            },
            { title: '录入时间', dataIndex: 'created_at', render: (v: string) => <span className="num">{date(v)}</span> },
            {
              title: '操作',
              key: 'op',
              align: 'right',
              fixed: 'right',
              render: (_, m) => (
                <Space onClick={(e) => e.stopPropagation()}>
                  <Button size="small" onClick={() => update({ id: m.id })}>
                    查看
                  </Button>
                  {can('merchant.write') && (
                    <Button size="small" icon={<EditOutlined />} onClick={() => setEditing(m)}>
                      编辑
                    </Button>
                  )}
                </Space>
              ),
            },
          ]}
        />
      </Panel>
      <MerchantDetailDrawer id={openId} onClose={() => update({ id: null })} onEdit={(m) => setEditing(m)} />
      <MerchantForm value={editing} onClose={() => setEditing(null)} onSaved={(m) => update({ id: m.id })} />
    </>
  );
}

// ------------------------------------------------------------ detail

function MerchantDetailDrawer({ id, onClose, onEdit }: { id: number | null; onClose: () => void; onEdit: (m: Merchant) => void }) {
  const { can } = useAuth();
  const { modal } = App.useApp();
  const detail = useQuery({ queryKey: ['merchants', 'detail', id], queryFn: () => merchantApi.merchant(id!), enabled: id !== null });
  const [phone, setPhone] = useState<{ id: number; phone: string } | null>(null);
  const [staffOpen, setStaffOpen] = useState(false);
  const reveal = useMutation({ mutationFn: (mid: number) => merchantApi.revealMerchantPhone(mid), onSuccess: (r, mid) => setPhone({ id: mid, phone: r.phone }) });
  const m = detail.data;
  const revealed = m && phone?.id === m.id ? phone.phone : null;

  return (
    <Drawer
      open={id !== null}
      onClose={onClose}
      width={920}
      title={
        m ? (
          <Space>
            <MerchantIcon type={m.type} />
            {m.name}
            <MerchantStatusTag status={m.status} />
          </Space>
        ) : (
          '商户详情'
        )
      }
      extra={
        m &&
        can('merchant.write') && (
          <Button icon={<EditOutlined />} onClick={() => onEdit(m)}>
            编辑
          </Button>
        )
      }
      loading={detail.isLoading}
    >
      {m && (
        <Space direction="vertical" size={18} style={{ width: '100%' }}>
          <Row gutter={[10, 10]}>
            <Col xs={12} md={6}>
              <Tile v={num(m.today_redemptions)} l="今日核销" />
            </Col>
            <Col xs={12} md={6}>
              <Tile v={num(m.venues.length)} l="场馆" />
            </Col>
            <Col xs={12} md={6}>
              <Tile v={num(m.drops.filter((d) => d.status === 'active').length)} l="发券中的投放" />
            </Col>
            <Col xs={12} md={6}>
              <Tile v={m.type === 'venue' || m.booking_commission_rate ? pct(m.booking_commission_rate) : '—'} l="订场佣金" />
            </Col>
          </Row>
          {m.status === 'suspended' && <Alert type="warning" showIcon message="已暂停合作" description={MERCHANT_STATUS.suspended.hint} />}

          <Descriptions size="small" column={2} bordered>
            <Descriptions.Item label="类型">{MERCHANT_TYPE[m.type] ?? m.type}</Descriptions.Item>
            <Descriptions.Item label="录入时间">{dt(m.created_at)}</Descriptions.Item>
            <Descriptions.Item label="联系人">{m.contact_name ?? '—'}</Descriptions.Item>
            <Descriptions.Item label="联系电话">
              <Space wrap>
                <span className="num">{revealed ?? m.contact_phone ?? '未登记'}</span>
                {m.contact_phone && !revealed && can('merchant.reveal_phone') && (
                  <Tooltip title="查看完整号码会记入审计日志">
                    <Button size="small" icon={<EyeOutlined />} loading={reveal.isPending} onClick={() => reveal.mutate(m.id)}>
                      查看完整号码
                    </Button>
                  </Tooltip>
                )}
                {revealed && <span className="muted" style={{ fontSize: 12 }}>已记入审计日志</span>}
              </Space>
            </Descriptions.Item>
          </Descriptions>

          <section>
            <h3 className="mer-h3">资质图片</h3>
            {m.license_images.length ? (
              <Image.PreviewGroup>
                <Space wrap className="thumbs">
                  {m.license_images.map((u, i) => (
                    <Image key={i} src={u} width={132} height={92} alt={`资质 ${i + 1}`} />
                  ))}
                </Space>
              </Image.PreviewGroup>
            ) : (
              <span className="muted">还没有上传资质（营业执照、食品经营许可证等），资质审核前需要补齐</span>
            )}
          </section>

          <section>
            <div className="mer-h3-row">
              <h3 className="mer-h3">场馆 · {m.venues.length}</h3>
              {can('venue.read') && <Link to={`/merchant/venues?merchant_id=${m.id}`}>去场馆页管理</Link>}
            </div>
            <Table
              size="small"
              rowKey="id"
              pagination={false}
              dataSource={m.venues}
              locale={{ emptyText: '没有场馆' }}
              scroll={{ x: 640 }}
              columns={[
                { title: '场馆', dataIndex: 'name', render: (v: string, x) => (can('venue.read') ? <Link to={`/merchant/venues?merchant_id=${m.id}&id=${x.id}`}>{v}</Link> : v) },
                { title: '运动', dataIndex: 'sports', render: (v: string[]) => v.map((s) => VENUE_SPORT[s as keyof typeof VENUE_SPORT] ?? s).join('、') },
                { title: '城区', dataIndex: 'district' },
                { title: '预订', key: 'book', render: (_, x) => (x.is_disabled ? <Tag>已停用</Tag> : x.bookable ? <span className="num">{yuan(x.price_amt)}/小时</span> : <span className="muted">只签到</span>) },
                { title: '本周馆主', key: 'owner', render: (_, x) => x.owner?.user.nickname ?? <span className="muted">暂无</span> },
              ]}
            />
          </section>

          <section>
            <div className="mer-h3-row">
              <h3 className="mer-h3">投放点 · {m.drops.length}</h3>
              <Link to={`/merchant/drops?merchant_id=${m.id}`}>
                <LinkOutlined /> 去投放页新建 / 管理
              </Link>
            </div>
            {m.drops.length === 0 ? (
              <span className="muted">还没有投放</span>
            ) : (
              <div className="mer-drops">
                {m.drops.map((d) => (
                  <Link key={d.id} className="mer-drop" to={`/merchant/drops?merchant_id=${m.id}&id=${d.id}`}>
                    <div className="mer-drop-head">
                      <Tag bordered={false}>{DROP_TYPE_LABEL[d.type] ?? d.type}</Tag>
                      <b className="mer-drop-name">{d.name}</b>
                      <Tag bordered={false} color={DROP_STATUS_LABEL[d.status]?.color} style={{ marginLeft: 'auto', marginInlineEnd: 0 }}>
                        {DROP_STATUS_LABEL[d.status]?.text ?? d.status}
                      </Tag>
                    </div>
                    <div>{d.perk.title}</div>
                    <div className="muted num" style={{ fontSize: 12 }}>
                      今日核销 {num(d.redeemed_today)} / 上限 {num(d.daily_cap)} · 至 {date(d.end_time)}
                    </div>
                  </Link>
                ))}
              </div>
            )}
          </section>

          <section>
            <div className="mer-h3-row">
              <h3 className="mer-h3">员工账号 · {m.staff.length}</h3>
              {can('merchant.staff') ? (
                <Button size="small" icon={<UserAddOutlined />} onClick={() => setStaffOpen(true)}>
                  新建员工账号
                </Button>
              ) : (
                <span className="muted" style={{ fontSize: 12 }}>只有管理员可以新建员工账号</span>
              )}
            </div>
            {m.staff.length === 0 ? (
              <span className="muted">还没有员工账号。员工用「商户对接」角色登录，只能核销本店的券、看本商户的订场和结算单</span>
            ) : (
              <Space wrap>
                {m.staff.map((s) => (
                  <Tag key={s.id} bordered={false} color={s.is_disabled ? 'default' : 'blue'} style={{ padding: '4px 10px' }}>
                    {s.username}
                    {s.is_disabled && ' · 已停用'}
                  </Tag>
                ))}
              </Space>
            )}
          </section>
          <StaffModal
            merchant={staffOpen ? m : null}
            onClose={() => setStaffOpen(false)}
            onDone={(username) => {
              setStaffOpen(false);
              modal.success({ title: '员工账号已创建', content: `「${username}」可以用刚才设置的密码登录管理端，登录后直接进入核销台。请通过安全渠道把密码交给商户。` });
            }}
          />
        </Space>
      )}
    </Drawer>
  );
}

function StaffModal({ merchant, onClose, onDone }: { merchant: MerchantDetail | null; onClose: () => void; onDone: (username: string) => void }) {
  const qc = useQueryClient();
  const [form] = Form.useForm<{ username: string; password: string }>();
  const create = useMutation({
    mutationFn: (v: { username: string; password: string }) => merchantApi.createStaff(merchant!.id, v),
    onSuccess: (_r, v) => {
      qc.invalidateQueries({ queryKey: ['merchants', 'detail', merchant?.id] });
      qc.invalidateQueries({ queryKey: ['admins'] });
      form.resetFields();
      onDone(v.username);
    },
  });
  return (
    <Modal open={merchant !== null} title={`新建员工账号 · ${merchant?.name ?? ''}`} okText="创建" cancelText="取消" confirmLoading={create.isPending} onCancel={onClose} onOk={() => form.submit()} destroyOnHidden>
      <Alert type="info" showIcon style={{ marginBottom: 14 }} message="角色为「商户对接」，绑定这个商户" description="只能看到本商户的核销台、核销记录、场馆预订和结算单。" />
      <Form form={form} layout="vertical" onFinish={(v) => create.mutate({ username: v.username.trim(), password: v.password })}>
        <Form.Item name="username" label="用户名" rules={[{ required: true, message: '请填写用户名' }, { pattern: /^[a-zA-Z0-9_.-]{3,32}$/, message: '3–32 位字母、数字、下划线' }]}>
          <Input placeholder="如 paoye_front" autoComplete="off" />
        </Form.Item>
        <Form.Item name="password" label="初始密码" rules={[{ required: true, message: '请设置密码' }, { min: 10, message: '后台账号密码至少 10 位' }]}>
          <Input.Password autoComplete="new-password" />
        </Form.Item>
      </Form>
    </Modal>
  );
}

// ------------------------------------------------------------ create / edit

interface FormValues {
  name: string;
  type: MerchantType;
  status: MerchantStatus;
  contact_name?: string;
  contact_phone?: string;
  license_images: { url: string }[];
  commission_pct: number;
}

function MerchantForm({ value, onClose, onSaved }: { value: Merchant | 'new' | null; onClose: () => void; onSaved: (m: Merchant) => void }) {
  const qc = useQueryClient();
  const [form] = Form.useForm<FormValues>();
  const editing = value && value !== 'new' ? value : null;
  const images = Form.useWatch('license_images', form) ?? [];
  const status = Form.useWatch('status', form);
  const type = Form.useWatch('type', form);

  useEffect(() => {
    if (!value) return;
    form.resetFields();
    form.setFieldsValue(
      editing
        ? {
            name: editing.name,
            type: editing.type,
            status: editing.status,
            contact_name: editing.contact_name ?? '',
            contact_phone: '',
            license_images: editing.license_images.map((url) => ({ url })),
            commission_pct: +(editing.booking_commission_rate * 100).toFixed(2),
          }
        : { type: 'venue', status: 'reviewing', license_images: [{ url: '' }], commission_pct: 10 },
    );
  }, [value, editing, form]);

  const save = useMutation({
    mutationFn: (body: MerchantInput) => (editing ? merchantApi.updateMerchant(editing.id, body) : merchantApi.createMerchant(body)),
    onSuccess: (m) => {
      toastOk(editing ? '商户已保存' : '商户已录入');
      qc.invalidateQueries({ queryKey: ['merchants'] });
      onClose();
      onSaved(m);
    },
  });

  const submit = (v: FormValues) => {
    const body: MerchantInput = {
      name: v.name.trim(),
      type: v.type,
      status: v.status,
      contact_name: v.contact_name?.trim() || null,
      license_images: (v.license_images ?? []).map((x) => x.url?.trim()).filter(Boolean),
      booking_commission_rate: +((v.commission_pct ?? 0) / 100).toFixed(4),
    };
    const phone = v.contact_phone?.trim();
    if (phone) body.contact_phone = phone;
    else if (!editing) body.contact_phone = null;
    save.mutate(body);
  };

  const noLicense = !images.some((x) => x?.url?.trim());

  return (
    <Drawer
      open={value !== null}
      onClose={onClose}
      width={620}
      title={editing ? `编辑商户 · ${editing.name}` : '新建商户'}
      extra={
        <Space>
          <Button onClick={onClose}>取消</Button>
          <Button type="primary" loading={save.isPending} onClick={() => form.submit()}>
            保存
          </Button>
        </Space>
      }
    >
      <Form form={form} layout="vertical" onFinish={submit} requiredMark="optional">
        <Form.Item name="name" label="商户名称" rules={[{ required: true, whitespace: true, message: '请填写商户名称' }, { max: 40, message: '最多 40 字' }]}>
          <Input placeholder="如 城南全民健身中心" />
        </Form.Item>
        <Row gutter={12}>
          <Col xs={24} sm={12}>
            <Form.Item name="type" label="类型" rules={[{ required: true }]}>
              <Radio.Group optionType="button" options={(Object.keys(MERCHANT_TYPE) as MerchantType[]).map((t) => ({ value: t, label: MERCHANT_TYPE[t] }))} />
            </Form.Item>
          </Col>
          <Col xs={24} sm={12}>
            <Form.Item name="status" label="合作状态" rules={[{ required: true }]} extra={status ? MERCHANT_STATUS[status as MerchantStatus]?.hint : undefined}>
              <Select options={MERCHANT_STATUS_ORDER.map((s) => ({ value: s, label: MERCHANT_STATUS[s].text }))} />
            </Form.Item>
          </Col>
        </Row>
        <Row gutter={12}>
          <Col xs={24} sm={12}>
            <Form.Item name="contact_name" label="联系人" rules={[{ max: 20, message: '最多 20 字' }]}>
              <Input placeholder="王经理" />
            </Form.Item>
          </Col>
          <Col xs={24} sm={12}>
            <Form.Item
              name="contact_phone"
              label="联系电话"
              extra={editing?.contact_phone ? `已登记 ${editing.contact_phone}，留空不修改` : '加密存储，列表只显示脱敏号码'}
              rules={[{ pattern: /^1[3-9]\d{9}$/, message: '11 位手机号' }]}
            >
              <Input className="num" maxLength={11} placeholder={editing?.contact_phone ?? '13800000000'} autoComplete="off" />
            </Form.Item>
          </Col>
        </Row>
        <Form.Item
          name="commission_pct"
          label="订场佣金"
          extra={type === 'venue' ? '用户订场付款后，平台按这个比例抽佣，其余结算给商户' : '非场馆商户一般没有订场，填 0'}
          rules={[{ required: true, message: '请填写佣金比例' }]}
        >
          <InputNumber className="num" min={0} max={100} step={1} precision={2} suffix="%" style={{ width: 180 }} />
        </Form.Item>

        <div className="ant-form-item-label" style={{ paddingBottom: 8 }}>
          <label>资质图片（营业执照、经营许可证等，最多 9 张）</label>
        </div>
        <Form.List name="license_images">
          {(fields, { add, remove }) => (
            <Space direction="vertical" style={{ width: '100%' }}>
              {fields.map((f, i) => {
                const url = images[i]?.url?.trim();
                return (
                  <div key={f.key} className="mer-img-row">
                    <div className="mer-img-thumb">{url && IMAGE_URL.test(url) ? <Image src={url} width={64} height={46} alt="" /> : <span className="muted">预览</span>}</div>
                    <Form.Item name={[f.name, 'url']} style={{ flex: 1, marginBottom: 0 }} rules={[{ pattern: IMAGE_URL, message: '需要是 http(s) 图片地址' }]}>
                      <Input placeholder="https://… 图片地址（先上传到对象存储）" allowClear />
                    </Form.Item>
                    <Button aria-label="删除这张" icon={<DeleteOutlined />} onClick={() => remove(f.name)} />
                  </div>
                );
              })}
              <Button icon={<PlusOutlined />} disabled={fields.length >= 9} onClick={() => add({ url: '' })}>
                添加一张
              </Button>
            </Space>
          )}
        </Form.List>
        {status === 'partner' && noLicense && <Alert style={{ marginTop: 14 }} type="warning" showIcon message="合作中的商户还没有资质图片" description="建议先补齐营业执照等资质再改为「合作中」。" />}
      </Form>
    </Drawer>
  );
}
