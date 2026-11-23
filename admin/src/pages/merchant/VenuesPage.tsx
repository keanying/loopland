import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import dayjs from 'dayjs';
import type { Dayjs } from 'dayjs';
import {
  Alert,
  App,
  AutoComplete,
  Button,
  Col,
  Descriptions,
  Drawer,
  Empty,
  Form,
  Input,
  InputNumber,
  Row,
  Select,
  Skeleton,
  Space,
  Switch,
  Table,
  Tag,
  TimePicker,
  Tooltip,
} from 'antd';
import { merchantApi, type Venue, type VenueInput, type VenueSport } from '../../api/merchant';
import { useAuth } from '../../auth/AuthContext';
import { SingleImageUpload } from '../../components/ImageUpload';
import { Avatar, PageHeader, Panel } from '../../components/ui';
import { num, yuan } from '../../utils/format';
import { toastError, toastOk } from '../../utils/notify';
import { VENUE_SPORT, VENUE_SPORTS } from './labels';
import { MerchantNav } from './nav';
import { PointPicker } from './shared';
import { discountText, urlParams, useMerchantOptions } from './util';
import { downloadVenueQr, qrDataUrl } from './qr';
import { Glyph } from '../../components/Glyph';

const PAGE = 20;
const DISTRICTS = ['浦东新区', '黄浦区', '徐汇区', '长宁区', '静安区', '普陀区', '虹口区', '杨浦区', '闵行区', '宝山区', '嘉定区', '金山区', '松江区', '青浦区', '奉贤区', '崇明区'];
const sportText = (s: string) => VENUE_SPORT[s as VenueSport] ?? s;
/** 浦东新区 · 东方路 1217 号 (no repeat when the address already starts with the district). */
const placeText = (v: Venue) => (v.address.startsWith(v.district) ? v.address : [v.district, v.address].filter(Boolean).join(' · '));

export default function VenuesPage() {
  const { can } = useAuth();
  const [params, setParams] = useSearchParams();
  const update = urlParams(params, setParams);
  const merchantId = Number(params.get('merchant_id') ?? 0) || null;
  const sport = (params.get('sport') ?? '') as VenueSport | '';
  const q = params.get('q') ?? '';
  const page = Number(params.get('page') ?? 1);
  const openId = Number(params.get('id') ?? 0) || null;
  const [kw, setKw] = useState(q);
  const [editing, setEditing] = useState<Venue | 'new' | null>(null);
  const merchants = useMerchantOptions();

  const list = useQuery({
    queryKey: ['venues', 'list', merchantId, sport, q, page],
    queryFn: () => merchantApi.venues({ merchant_id: merchantId, sport, q, page }),
    placeholderData: (p) => p,
  });
  const items = list.data?.items ?? [];
  // The contract has no GET /venues/{id}: the drawer opens from the loaded page (or a direct id lookup in the list).
  const opened = items.find((v) => v.id === openId) ?? null;

  return (
    <>
      <PageHeader title="商户与活动" sub="场馆签到据点和可预订场馆：位置、签到半径、订场价格和时段、馆主折扣，签到二维码" extra={<MerchantNav />} />
      <Panel
        title="场馆"
        extra={
          <Space wrap>
            <Input
              allowClear
              prefix={<Glyph name="search" />}
              placeholder="场馆名称、地址或城区"
              style={{ width: 210 }}
              value={kw}
              onChange={(e) => {
                setKw(e.target.value);
                if (!e.target.value) update({ q: null, page: null });
              }}
              onPressEnter={() => update({ q: kw.trim(), page: null })}
            />
            <Select
              allowClear
              showSearch
              optionFilterProp="label"
              placeholder="全部商户"
              style={{ width: 180 }}
              value={merchantId ?? undefined}
              onChange={(v) => update({ merchant_id: v ?? null, page: null })}
              options={merchants.options}
              loading={merchants.isLoading}
            />
            <Select
              allowClear
              placeholder="全部运动"
              style={{ width: 120 }}
              value={sport || undefined}
              onChange={(v) => update({ sport: v ?? null, page: null })}
              options={VENUE_SPORTS.map((s) => ({ value: s, label: VENUE_SPORT[s] }))}
            />
            {can('venue.write') && (
              <Button type="primary" icon={<Glyph name="plus" />} onClick={() => setEditing('new')}>
                新建场馆
              </Button>
            )}
          </Space>
        }
      >
        <Table<Venue>
          rowKey="id"
          loading={list.isFetching}
          dataSource={items}
          scroll={{ x: 1250 }}
          onRow={(v) => ({ onClick: () => update({ id: v.id }), style: { cursor: 'pointer' } })}
          rowClassName={(v) => (v.is_disabled ? 'row-disabled' : '')}
          locale={{ emptyText: <Empty description="没有符合条件的场馆" /> }}
          pagination={{ current: page, pageSize: PAGE, total: list.data?.total ?? 0, showSizeChanger: false, showTotal: (t) => `共 ${t} 个`, onChange: (p) => update({ page: p === 1 ? null : p }) }}
          columns={[
            {
              title: '场馆',
              key: 'name',
              width: 260,
              render: (_, v) => (
                <div>
                  <b>{v.name}</b> {v.is_disabled && <Tag>已停用</Tag>}
                  <div className="muted" style={{ fontSize: 12 }}>
                    {placeText(v)}
                  </div>
                </div>
              ),
            },
            {
              title: '商户',
              key: 'merchant',
              render: (_, v) => (v.merchant ? <Link to={`/merchant/merchants?id=${v.merchant.id}`} onClick={(e) => e.stopPropagation()}>{v.merchant.name}</Link> : <span className="muted">非合作 · 只签到</span>),
            },
            { title: '运动', dataIndex: 'sports', render: (v: string[]) => <Space size={[4, 4]} wrap>{v.map((s) => <Tag key={s} bordered={false}>{sportText(s)}</Tag>)}</Space> },
            {
              title: '预订',
              key: 'book',
              render: (_, v) =>
                v.bookable ? (
                  <span className="num">
                    {yuan(v.price_amt)}/小时
                    <div className="muted" style={{ fontSize: 12 }}>
                      {v.open_time ?? '—'}–{v.close_time ?? '—'} · {v.court_qty ?? '—'} 片场 · 每段 {v.slot_minutes ?? 60} 分钟
                    </div>
                  </span>
                ) : (
                  <span className="muted">只签到</span>
                ),
            },
            {
              title: '本周馆主',
              key: 'owner',
              render: (_, v) =>
                v.owner ? (
                  <Space size={6}>
                    <Avatar name={v.owner.user.nickname} />
                    <span>
                      {v.owner.user.nickname}
                      <div className="muted num" style={{ fontSize: 12 }}>
                        {num(v.owner.points)} 分{v.bookable && ` · 订场${discountText(v.owner_discount_rate)}`}
                      </div>
                    </span>
                  </Space>
                ) : (
                  <span className="muted">暂无馆主</span>
                ),
            },
            { title: '签到半径', dataIndex: 'checkin_radius_m', align: 'right', render: (v: number) => <span className="num">{num(v)} m</span> },
            {
              title: '操作',
              key: 'op',
              align: 'right',
              fixed: 'right',
              render: (_, v) => (
                <Space onClick={(e) => e.stopPropagation()}>
                  <Button size="small" icon={<Glyph name="qr" size={14} />} onClick={() => update({ id: v.id })}>
                    二维码
                  </Button>
                  {can('venue.write') && (
                    <Button size="small" icon={<Glyph name="pencil" size={14} />} onClick={() => setEditing(v)}>
                      编辑
                    </Button>
                  )}
                </Space>
              ),
            },
          ]}
        />
      </Panel>
      <VenueDrawer venue={opened} open={openId !== null} loading={list.isLoading} onClose={() => update({ id: null })} onEdit={(v) => setEditing(v)} />
      <VenueForm value={editing} onClose={() => setEditing(null)} />
    </>
  );
}

// ------------------------------------------------------------ detail: QR + 馆主

function VenueDrawer({ venue, open, loading, onClose, onEdit }: { venue: Venue | null; open: boolean; loading: boolean; onClose: () => void; onEdit: (v: Venue) => void }) {
  const { can } = useAuth();
  return (
    <Drawer
      open={open}
      onClose={onClose}
      width={760}
      title={venue ? venue.name : '场馆'}
      extra={
        venue &&
        can('venue.write') && (
          <Button icon={<Glyph name="pencil" />} onClick={() => onEdit(venue)}>
            编辑
          </Button>
        )
      }
    >
      {!venue ? (
        loading ? <Skeleton active /> : <Empty description="这一页里没有这个场馆，换个筛选条件试试" />
      ) : (
        <Space direction="vertical" size={18} style={{ width: '100%' }}>
          {venue.is_disabled && <Alert type="warning" showIcon message="场馆已停用" description="App 不显示、不能签到和预订。" />}
          <Descriptions size="small" column={2} bordered>
            <Descriptions.Item label="商户">{venue.merchant?.name ?? '非合作场馆（只签到）'}</Descriptions.Item>
            <Descriptions.Item label="运动">{venue.sports.map(sportText).join('、')}</Descriptions.Item>
            <Descriptions.Item label="地址" span="filled">
              {placeText(venue)}
              <div className="muted num" style={{ fontSize: 12 }}>
                <Glyph name="locate" size="1em" /> {venue.center.lat.toFixed(6)}, {venue.center.lng.toFixed(6)} · 签到半径 {venue.checkin_radius_m} m
              </div>
            </Descriptions.Item>
            <Descriptions.Item label="预订">{venue.bookable ? `${yuan(venue.price_amt)}/小时 · 每段 ${venue.slot_minutes ?? 60} 分钟 · ${venue.court_qty ?? '—'} 片场` : '不开放预订'}</Descriptions.Item>
            <Descriptions.Item label="营业时间">{venue.open_time && venue.close_time ? `${venue.open_time}–${venue.close_time}` : '—'}</Descriptions.Item>
            <Descriptions.Item label="馆主折扣">{discountText(venue.owner_discount_rate)}</Descriptions.Item>
            <Descriptions.Item label="标签">{venue.tags.length ? venue.tags.map((t) => <Tag key={t} bordered={false}>{t}</Tag>) : '—'}</Descriptions.Item>
          </Descriptions>
          <Row gutter={[16, 16]}>
            <Col xs={24} md={11}>
              <VenueQrCard venue={venue} />
            </Col>
            <Col xs={24} md={13}>
              <OwnerHistory venue={venue} />
            </Col>
          </Row>
        </Space>
      )}
    </Drawer>
  );
}

function VenueQrCard({ venue }: { venue: Venue }) {
  const { can } = useAuth();
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const qr = useQuery({ queryKey: ['venues', 'qr', venue.id], queryFn: () => merchantApi.venueQr(venue.id) });
  const [img, setImg] = useState<string | null>(null);
  const [downloading, setDownloading] = useState(false);
  const text = qr.data?.url || qr.data?.payload || '';

  useEffect(() => {
    let alive = true;
    setImg(null);
    if (text) qrDataUrl(text).then((u) => alive && setImg(u), (e) => toastError(e));
    return () => {
      alive = false;
    };
  }, [text]);

  const rotate = useMutation({
    mutationFn: () => merchantApi.rotateVenueQr(venue.id),
    onSuccess: (r) => {
      qc.setQueryData(['venues', 'qr', venue.id], r);
      toastOk('已换码，旧二维码立即失效');
    },
  });

  return (
    <div className="qr-card">
      <div className="qr-card-head">
        <b>签到二维码</b>
        <span className="muted" style={{ fontSize: 12 }}>App 扫一扫或手机相机</span>
      </div>
      <div className="qr-box">{img ? <img src={img} alt={`${venue.name} 签到二维码`} /> : <Skeleton.Image active style={{ width: 220, height: 220 }} />}</div>
      <Tooltip title={qr.data?.url}>
        <div className="qr-payload num">{qr.data?.payload ?? '…'}</div>
      </Tooltip>
      <Space wrap style={{ justifyContent: 'center', width: '100%' }}>
        <Button
          type="primary"
          icon={<Glyph name="download" />}
          disabled={!text}
          loading={downloading}
          onClick={async () => {
            setDownloading(true);
            try {
              await downloadVenueQr(text, venue.name, venue.id);
            } catch (e) {
              toastError(e);
            } finally {
              setDownloading(false);
            }
          }}
        >
          下载 PNG
        </Button>
        {can('venue.write') && (
          <Button
            danger
            icon={<Glyph name="refresh" />}
            loading={rotate.isPending}
            onClick={() =>
              modal.confirm({
                title: '换一个签到码？',
                content: '换码后旧二维码立即失效，场馆里已经张贴的二维码需要重新打印更换。一般只在二维码外泄（被拍下来远程签到）时使用。',
                okText: '确认换码',
                okButtonProps: { danger: true },
                cancelText: '取消',
                onOk: () => rotate.mutateAsync(),
              })
            }
          >
            换码
          </Button>
        )}
      </Space>
    </div>
  );
}

function OwnerHistory({ venue }: { venue: Venue }) {
  const owners = useQuery({ queryKey: ['venues', 'owners', venue.id], queryFn: () => merchantApi.venueOwners(venue.id) });
  return (
    <div>
      <div className="mer-h3-row">
        <h3 className="mer-h3">历任馆主</h3>
        <span className="muted" style={{ fontSize: 12 }}>每周一 00:00 按上周签到积分结算</span>
      </div>
      <Table
        size="small"
        rowKey="week_start"
        loading={owners.isLoading}
        dataSource={owners.data?.items ?? []}
        pagination={false}
        locale={{ emptyText: '还没有馆主' }}
        columns={[
          { title: '周', dataIndex: 'week_start', render: (v: string) => <span className="num">{dayjs(v).format('MM/DD')} 起</span> },
          {
            title: '馆主',
            key: 'user',
            render: (_, o) => (
              <Link to={`/users?id=${o.user.id}`}>
                {o.user.nickname}
              </Link>
            ),
          },
          { title: '积分', dataIndex: 'points', align: 'right', render: (v: number) => <span className="num">{num(v)}</span> },
        ]}
      />
    </div>
  );
}

// ------------------------------------------------------------ create / edit

interface FormValues {
  merchant_id?: number | null;
  name: string;
  sports: VenueSport[];
  address: string;
  district: string;
  tags: string[];
  cover_url?: string;
  lat?: number;
  lng?: number;
  checkin_radius_m: number;
  bookable: boolean;
  price_yuan?: number | null;
  slot_minutes: number;
  hours?: [Dayjs, Dayjs];
  court_qty: number;
  /** 8 = 八折; empty = no discount. */
  owner_discount?: number | null;
  is_disabled: boolean;
}

function VenueForm({ value, onClose }: { value: Venue | 'new' | null; onClose: () => void }) {
  const qc = useQueryClient();
  const [form] = Form.useForm<FormValues>();
  const editing = value && value !== 'new' ? value : null;
  const merchants = useMerchantOptions(value !== null);
  const lat = Form.useWatch('lat', form);
  const lng = Form.useWatch('lng', form);
  const name = Form.useWatch('name', form);
  const radius = Form.useWatch('checkin_radius_m', form);
  const merchantId = Form.useWatch('merchant_id', form);
  const bookable = Form.useWatch('bookable', form);
  const point = typeof lat === 'number' && typeof lng === 'number' ? { lat, lng } : null;

  useEffect(() => {
    if (!value) return;
    form.resetFields();
    const v = editing;
    form.setFieldsValue(
      v
        ? {
            merchant_id: v.merchant?.id ?? null,
            name: v.name,
            sports: v.sports,
            address: v.address,
            district: v.district,
            tags: v.tags,
            cover_url: v.cover_url ?? '',
            lat: v.center.lat,
            lng: v.center.lng,
            checkin_radius_m: v.checkin_radius_m,
            bookable: v.bookable,
            price_yuan: v.price_amt === null ? null : v.price_amt / 100,
            slot_minutes: v.slot_minutes ?? 60,
            hours: [dayjs(`2000-01-01T${v.open_time ?? '08:00'}`), dayjs(`2000-01-01T${v.close_time ?? '22:00'}`)],
            court_qty: v.court_qty ?? 1,
            owner_discount: v.owner_discount_rate === null ? null : +(v.owner_discount_rate * 10).toFixed(1),
            is_disabled: !!v.is_disabled,
          }
        : { merchant_id: null, sports: [], tags: [], checkin_radius_m: 150, bookable: false, slot_minutes: 60, hours: [dayjs('2000-01-01T08:00'), dayjs('2000-01-01T22:00')], court_qty: 1, owner_discount: 8, is_disabled: false },
    );
  }, [value, editing, form]);

  const save = useMutation({
    mutationFn: (body: VenueInput) => (editing ? merchantApi.updateVenue(editing.id, body) : merchantApi.createVenue(body)),
    onSuccess: () => {
      toastOk(editing ? '场馆已保存' : '场馆已创建，可以在详情里下载签到二维码');
      qc.invalidateQueries({ queryKey: ['venues'] });
      qc.invalidateQueries({ queryKey: ['merchants'] });
      onClose();
    },
  });

  const submit = (v: FormValues) => {
    const [open, close] = v.hours ?? [dayjs('2000-01-01T08:00'), dayjs('2000-01-01T22:00')];
    save.mutate({
      merchant_id: v.merchant_id ?? null,
      name: v.name.trim(),
      sports: v.sports,
      center: { lat: v.lat!, lng: v.lng! },
      address: v.address.trim(),
      district: v.district.trim(),
      tags: (v.tags ?? []).map((t) => t.trim()).filter(Boolean),
      cover_url: v.cover_url?.trim() || null,
      checkin_radius_m: v.checkin_radius_m,
      bookable: !!v.bookable,
      price_amt: v.price_yuan === null || v.price_yuan === undefined ? null : Math.round(v.price_yuan * 100),
      slot_minutes: v.slot_minutes,
      open_time: open.format('HH:mm'),
      close_time: close.format('HH:mm'),
      court_qty: v.court_qty,
      owner_discount_rate: v.owner_discount ? +(v.owner_discount / 10).toFixed(3) : null,
      is_disabled: !!v.is_disabled,
    });
  };

  return (
    <Drawer
      open={value !== null}
      onClose={onClose}
      width={980}
      title={editing ? `编辑场馆 · ${editing.name}` : '新建场馆'}
      extra={
        <Space>
          <Button onClick={onClose}>取消</Button>
          <Button type="primary" loading={save.isPending} onClick={() => form.submit()}>
            保存
          </Button>
        </Space>
      }
    >
      <Form form={form} layout="vertical" onFinish={submit} requiredMark="optional" onFinishFailed={({ errorFields }) => errorFields[0] && form.scrollToField(errorFields[0].name)}>
        <Row gutter={24}>
          <Col xs={24} lg={13}>
            <Form.Item name="merchant_id" label="所属商户" extra="不选 = 非合作场馆，只作为签到据点，不能开放预订">
              <Select
                allowClear
                showSearch
                optionFilterProp="label"
                placeholder="非合作场馆（只签到）"
                options={merchants.options}
                loading={merchants.isLoading}
                onChange={(v) => !v && form.setFieldValue('bookable', false)}
              />
            </Form.Item>
            <Form.Item name="name" label="场馆名称" rules={[{ required: true, whitespace: true, message: '请填写场馆名称' }, { max: 40, message: '最多 40 字' }]}>
              <Input placeholder="城南全民健身中心 · 匹克球" />
            </Form.Item>
            <Form.Item name="sports" label="运动" rules={[{ required: true, message: '至少选一个运动' }]}>
              <Select mode="multiple" placeholder="选择场馆支持的运动" options={VENUE_SPORTS.map((s) => ({ value: s, label: VENUE_SPORT[s] }))} />
            </Form.Item>
            <Row gutter={12}>
              <Col span={9}>
                <Form.Item name="district" label="城区" rules={[{ required: true, whitespace: true, message: '请填写城区' }]}>
                  <AutoComplete options={DISTRICTS.map((d) => ({ value: d }))} placeholder="徐汇区" filterOption={(i, o) => !!o?.value.includes(i)} />
                </Form.Item>
              </Col>
              <Col span={15}>
                <Form.Item name="address" label="地址" rules={[{ required: true, whitespace: true, message: '请填写地址' }, { max: 80, message: '最多 80 字' }]}>
                  <Input placeholder="龙华中路 600 号" />
                </Form.Item>
              </Col>
            </Row>
            <Form.Item name="tags" label="标签" extra="最多 8 个，回车添加，如 室内、可租拍、夜场灯光" rules={[{ type: 'array', max: 8, message: '最多 8 个标签' }]}>
              <Select mode="tags" tokenSeparators={[',', '，', ' ']} placeholder="室内、可租拍" options={['室内', '室外', '可租拍', '夜场灯光', '空调', '新手友好', '有教练', '免费'].map((t) => ({ value: t }))} />
            </Form.Item>
            <Form.Item name="cover_url" label="封面图（可选）">
              <SingleImageUpload purpose="venue_cover" shape="cover" label="场馆封面" hint="建议 16:9" />
            </Form.Item>

            <div className="venue-book">
              <Form.Item name="bookable" label="开放预订" valuePropName="checked" extra={!merchantId ? '非合作场馆不能开放预订' : '合作场馆按时段在 App 里售卖；商户暂停合作时自动不可预订'}>
                <Switch disabled={!merchantId} checkedChildren="可预订" unCheckedChildren="只签到" />
              </Form.Item>
              <Row gutter={12}>
                <Col xs={12} sm={8}>
                  <Form.Item name="price_yuan" label="价格（元/小时）" rules={[{ required: !!bookable, message: '开放预订需要价格' }]}>
                    <InputNumber className="num" min={0} max={99999} precision={2} style={{ width: '100%' }} disabled={!bookable} placeholder="60" />
                  </Form.Item>
                </Col>
                <Col xs={12} sm={8}>
                  <Form.Item name="slot_minutes" label="时段长度">
                    <Select disabled={!bookable} options={[30, 60, 90, 120].map((m) => ({ value: m, label: `${m} 分钟` }))} />
                  </Form.Item>
                </Col>
                <Col xs={12} sm={8}>
                  <Form.Item name="court_qty" label="场地数" rules={[{ required: true, message: '请填写场地数' }]} extra="每个时段可卖的片数">
                    <InputNumber className="num" min={1} max={50} precision={0} style={{ width: '100%' }} />
                  </Form.Item>
                </Col>
                <Col xs={12} sm={12}>
                  <Form.Item
                    name="hours"
                    label="营业时间"
                    rules={[
                      { required: true, message: '请选择营业时间' },
                      { validator: (_, v?: [Dayjs, Dayjs]) => (!v || v[0].isBefore(v[1]) ? Promise.resolve() : Promise.reject(new Error('开门要早于关门（不跨零点）'))) },
                    ]}
                  >
                    <TimePicker.RangePicker format="HH:mm" minuteStep={5} order={false} style={{ width: '100%' }} />
                  </Form.Item>
                </Col>
                <Col xs={12} sm={12}>
                  <Form.Item name="owner_discount" label="馆主订场折扣" extra="8 = 八折；留空不打折">
                    <InputNumber className="num" min={1} max={9.9} step={0.5} precision={1} suffix="折" style={{ width: '100%' }} disabled={!bookable} placeholder="不打折" />
                  </Form.Item>
                </Col>
              </Row>
            </div>
            <Form.Item name="is_disabled" label="停用" valuePropName="checked" extra="停用后 App 不显示，不能签到和预订（已有预订不受影响）" style={{ marginTop: 12 }}>
              <Switch checkedChildren="已停用" unCheckedChildren="正常" />
            </Form.Item>
          </Col>
          <Col xs={24} lg={11}>
            <b>位置与签到范围</b>
            <div className="muted" style={{ fontSize: 12, margin: '2px 0 8px' }}>
              <Glyph name="locate" size="1em" /> 在地图上点击选点（参考周边领地），或直接填坐标（GCJ-02）
            </div>
            <Row gutter={8}>
              <Col span={12}>
                <Form.Item name="lat" label="纬度 lat" rules={[{ required: true, message: '请选点或填写' }]}>
                  <InputNumber className="num" min={-90} max={90} step={0.0005} precision={6} style={{ width: '100%' }} placeholder="31.188500" />
                </Form.Item>
              </Col>
              <Col span={12}>
                <Form.Item name="lng" label="经度 lng" rules={[{ required: true, message: '请选点或填写' }]}>
                  <InputNumber className="num" min={-180} max={180} step={0.0005} precision={6} style={{ width: '100%' }} placeholder="121.437200" />
                </Form.Item>
              </Col>
            </Row>
            <PointPicker point={point} name={name ?? ''} radius={radius ?? 150} enabled={value !== null} onPick={(p) => form.setFieldsValue({ lat: p.lat, lng: p.lng })} />
            <Form.Item name="checkin_radius_m" label="签到半径" style={{ marginTop: 12 }} rules={[{ required: true, message: '请填写签到半径' }]} extra="在这个范围内定位即可签到；室内定位偏差大时适当放大">
              <InputNumber className="num" min={30} max={1000} step={10} precision={0} suffix="米" style={{ width: 180 }} />
            </Form.Item>
          </Col>
        </Row>
      </Form>
    </Drawer>
  );
}
