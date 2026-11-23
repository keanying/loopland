// V2 第五批 · 商户自助改场馆 (docs/api/v2-5「商户自助改场馆」, venue.self): a merchant account sees only its own
// venues and may change only cover_url, tags, price_amt, slot_minutes, open_time, close_time, court_qty,
// owner_discount_rate and bookable; name, location, check-in radius and merchant stay with the platform.
import { useEffect, useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import dayjs from 'dayjs';
import type { Dayjs } from 'dayjs';
import { Alert, Button, Col, Descriptions, Drawer, Empty, Form, InputNumber, Row, Select, Space, Switch, Table, Tag, TimePicker } from 'antd';
import { merchantApi, type Venue, type VenueInput, type VenueSport } from '../../api/merchant';
import { SingleImageUpload } from '../../components/ImageUpload';
import { PageHeader, Panel } from '../../components/ui';
import { num, yuan } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { VENUE_SPORT } from './labels';
import { MerchantNav } from './nav';
import { discountText, toFen, toYuan, useOwnVenues } from './util';
import { Glyph } from '../../components/Glyph';

const sportText = (s: string) => VENUE_SPORT[s as VenueSport] ?? s;
/** The fields a merchant account may send (anything else → 403 field_not_allowed). */
type SelfFields = Pick<VenueInput, 'cover_url' | 'tags' | 'price_amt' | 'slot_minutes' | 'open_time' | 'close_time' | 'court_qty' | 'owner_discount_rate' | 'bookable'>;

export default function MyVenuesPage() {
  const own = useOwnVenues();
  const [editing, setEditing] = useState<Venue | null>(null);
  return (
    <>
      <PageHeader title="场馆" sub="本商户的场馆：可以自己改订场价格、营业时间、场地数、时段长度、馆主折扣、封面和标签，临时停订；名称、位置、签到范围等请联系平台运营修改" extra={<MerchantNav />} />
      <Panel title="场馆">
        <Table<Venue>
          rowKey="id"
          loading={own.isFetching}
          dataSource={own.venues}
          scroll={{ x: 1000 }}
          pagination={false}
          onRow={(v) => ({ onClick: () => setEditing(v), style: { cursor: 'pointer' } })}
          locale={{ emptyText: <Empty description="还没有场馆，请联系平台运营录入" /> }}
          columns={[
            {
              title: '场馆',
              key: 'name',
              width: 280,
              render: (_, v) => (
                <div className="prod-cell">
                  {v.cover_url ? <img className="prod-thumb" src={v.cover_url} alt="" /> : <span className="prod-thumb" />}
                  <div style={{ minWidth: 0 }}>
                    <div className="prod-title">{v.name}</div>
                    <div className="prod-sub">{v.address}</div>
                  </div>
                </div>
              ),
            },
            { title: '运动', dataIndex: 'sports', width: 160, render: (s: string[]) => <Space size={[4, 4]} wrap>{s.map((x) => <Tag key={x} bordered={false}>{sportText(x)}</Tag>)}</Space> },
            {
              title: '订场',
              key: 'book',
              width: 260,
              render: (_, v) =>
                v.bookable ? (
                  <span className="num">
                    <b>{yuan(v.price_amt)}</b>/小时
                    <div className="muted" style={{ fontSize: 12 }}>
                      {v.open_time ?? '—'}–{v.close_time ?? '—'} · {v.court_qty ?? '—'} 片场 · 每段 {v.slot_minutes ?? 60} 分钟
                    </div>
                  </span>
                ) : (
                  <Tag bordered={false}>暂停订场</Tag>
                ),
            },
            { title: '馆主折扣', dataIndex: 'owner_discount_rate', width: 100, render: (r: number | null) => discountText(r) },
            { title: '标签', dataIndex: 'tags', render: (t: string[]) => (t.length ? t.join('、') : <span className="muted">—</span>) },
            {
              title: '操作',
              key: 'op',
              width: 90,
              align: 'right',
              fixed: 'right',
              render: (_, v) => (
                <Button
                  size="small"
                  icon={<Glyph name="pencil" size={14} />}
                  onClick={(e) => {
                    e.stopPropagation();
                    setEditing(v);
                  }}
                >
                  修改
                </Button>
              ),
            },
          ]}
        />
      </Panel>
      <SelfVenueForm venue={editing} onClose={() => setEditing(null)} />
    </>
  );
}

interface FormValues {
  bookable: boolean;
  price_yuan?: number | null;
  slot_minutes: number;
  hours: [Dayjs, Dayjs];
  court_qty: number;
  owner_discount?: number | null;
  tags: string[];
  cover_url?: string;
}

function SelfVenueForm({ venue, onClose }: { venue: Venue | null; onClose: () => void }) {
  const qc = useQueryClient();
  const [form] = Form.useForm<FormValues>();
  const bookable = Form.useWatch('bookable', form);
  useEffect(() => {
    if (!venue) return;
    form.resetFields();
    form.setFieldsValue({
      bookable: venue.bookable,
      price_yuan: toYuan(venue.price_amt),
      slot_minutes: venue.slot_minutes ?? 60,
      hours: [dayjs(`2000-01-01T${venue.open_time ?? '08:00'}`), dayjs(`2000-01-01T${venue.close_time ?? '22:00'}`)],
      court_qty: venue.court_qty ?? 1,
      owner_discount: venue.owner_discount_rate === null ? null : +(venue.owner_discount_rate * 10).toFixed(1),
      tags: venue.tags,
      cover_url: venue.cover_url ?? '',
    });
  }, [venue, form]);
  const save = useMutation({
    mutationFn: (body: SelfFields) => merchantApi.updateVenue(venue!.id, body),
    onSuccess: () => {
      toastOk('场馆资料已保存，App 立即生效（已有订单不受影响）');
      qc.invalidateQueries({ queryKey: ['venues'] });
      onClose();
    },
  });
  const submit = (v: FormValues) =>
    save.mutate({
      bookable: !!v.bookable,
      price_amt: toFen(v.price_yuan ?? null),
      slot_minutes: v.slot_minutes,
      open_time: v.hours[0].format('HH:mm'),
      close_time: v.hours[1].format('HH:mm'),
      court_qty: v.court_qty,
      owner_discount_rate: v.owner_discount ? +(v.owner_discount / 10).toFixed(3) : null,
      tags: (v.tags ?? []).map((t) => t.trim()).filter(Boolean),
      cover_url: v.cover_url?.trim() || null,
    });
  return (
    <Drawer
      open={venue !== null}
      onClose={onClose}
      width={720}
      title={venue ? `修改场馆 · ${venue.name}` : ''}
      extra={
        <Space>
          <Button onClick={onClose}>取消</Button>
          <Button type="primary" loading={save.isPending} onClick={() => form.submit()}>
            保存
          </Button>
        </Space>
      }
    >
      {venue && (
        <>
          <Descriptions size="small" column={2} bordered style={{ marginBottom: 16 }} title={<span style={{ fontSize: 14 }}>平台维护（只读）</span>}>
            <Descriptions.Item label="名称" span={2}>{venue.name}</Descriptions.Item>
            <Descriptions.Item label="地址" span={2}>{[venue.district, venue.address].filter(Boolean).join(' · ')}</Descriptions.Item>
            <Descriptions.Item label="运动">{venue.sports.map(sportText).join('、')}</Descriptions.Item>
            <Descriptions.Item label="签到半径">
              <span className="num">{num(venue.checkin_radius_m)} m</span>
            </Descriptions.Item>
          </Descriptions>
          <Form form={form} layout="vertical" onFinish={submit} requiredMark="optional">
            <div className="venue-book">
              <Form.Item name="bookable" label="订场" valuePropName="checked" extra="关闭 = 临时停订：App 不能新订，已有订单不受影响">
                <Switch checkedChildren="开放预订" unCheckedChildren="暂停订场" />
              </Form.Item>
              <Row gutter={12}>
                <Col xs={12} sm={8}>
                  <Form.Item name="price_yuan" label="价格（元/小时）" rules={[{ required: !!bookable, message: '开放预订需要价格' }]}>
                    <InputNumber className="num" min={0} max={99999} precision={2} prefix="¥" style={{ width: '100%' }} />
                  </Form.Item>
                </Col>
                <Col xs={12} sm={8}>
                  <Form.Item name="slot_minutes" label="时段长度">
                    <Select options={[30, 60, 90, 120].map((m) => ({ value: m, label: `${m} 分钟` }))} />
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
                    <InputNumber className="num" min={1} max={9.9} step={0.5} precision={1} suffix="折" style={{ width: '100%' }} placeholder="不打折" />
                  </Form.Item>
                </Col>
              </Row>
            </div>
            <Form.Item name="tags" label="标签" style={{ marginTop: 16 }} extra="最多 8 个，回车添加" rules={[{ type: 'array', max: 8, message: '最多 8 个标签' }]}>
              <Select mode="tags" tokenSeparators={[',', '，', ' ']} placeholder="室内、可租拍" options={['室内', '室外', '可租拍', '夜场灯光', '空调', '新手友好', '有教练'].map((t) => ({ value: t }))} />
            </Form.Item>
            <Form.Item name="cover_url" label="封面图">
              <SingleImageUpload purpose="venue_cover" shape="cover" label="场馆封面" hint="建议 16:9" />
            </Form.Item>
            <Alert type="info" showIcon style={{ marginTop: 16 }} message="改价格、时段只影响之后的预订；已支付的订单按原价和原时段履约" />
          </Form>
        </>
      )}
    </Drawer>
  );
}
