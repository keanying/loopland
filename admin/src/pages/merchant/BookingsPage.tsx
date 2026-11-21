import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import dayjs from 'dayjs';
import { Alert, App, Button, DatePicker, Descriptions, Drawer, Empty, Input, Modal, Select, Space, Table, Tag, Tooltip } from 'antd';
import { merchantApi, type Booking, type BookingStatus } from '../../api/merchant';
import { useAuth } from '../../auth/AuthContext';
import { PageHeader, Panel } from '../../components/ui';
import { dt, yuan } from '../../utils/format';
import { CHANNEL_LABEL } from '../../utils/labels';
import { toastOk } from '../../utils/notify';
import { BOOKING_STATUS, BOOKING_STATUS_ORDER } from './labels';
import { MerchantNav } from './nav';
import { BookingStatusTag } from './shared';
import { urlParams } from './util';

const PAGE = 20;
const REFUNDABLE: BookingStatus[] = ['paid', 'completed'];

function slotText(b: Booking): string {
  const s = dayjs(b.start_time);
  return `${s.format('MM/DD ddd HH:mm')}–${dayjs(b.end_time).format('HH:mm')}`;
}

export default function BookingsPage() {
  const { can, admin } = useAuth();
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const staff = admin?.role === 'merchant';
  const [params, setParams] = useSearchParams();
  const update = urlParams(params, setParams);
  const venueId = Number(params.get('venue_id') ?? 0) || null;
  const status = (params.get('status') ?? '') as BookingStatus | '';
  const day = params.get('date') ?? '';
  const page = Number(params.get('page') ?? 1);
  const [detail, setDetail] = useState<Booking | null>(null);
  const [refund, setRefund] = useState<Booking | null>(null);
  const [reason, setReason] = useState('');

  // Venue filter: admin / ops list all venues; merchant staff see their merchant's venues (GET /merchants/{id}).
  const allVenues = useQuery({ queryKey: ['venues', 'options'], queryFn: () => merchantApi.venues({ page_size: 100 }), enabled: can('venue.read'), staleTime: 60_000 });
  const own = useQuery({ queryKey: ['merchants', 'detail', admin?.merchant_id], queryFn: () => merchantApi.merchant(admin!.merchant_id!), enabled: staff && !!admin?.merchant_id, staleTime: 60_000 });
  const venueOptions = (staff ? own.data?.venues : allVenues.data?.items)?.filter((v) => v.bookable || v.id === venueId).map((v) => ({ value: v.id, label: v.name })) ?? [];

  const list = useQuery({
    queryKey: ['bookings', 'list', venueId, status, day, page],
    queryFn: () => merchantApi.bookings({ venue_id: venueId, status, date: day, page }),
    placeholderData: (p) => p,
  });

  const doRefund = useMutation({
    mutationFn: ({ b, r }: { b: Booking; r: string }) => merchantApi.refundBooking(b.id, r),
    onSuccess: (b) => {
      toastOk('已发起退款，款项原路退回（到账后状态变为「已退款」）');
      qc.invalidateQueries({ queryKey: ['bookings'] });
      qc.invalidateQueries({ queryKey: ['dashboard'] });
      setDetail((d) => (d && d.id === b.id ? { ...d, ...b } : d));
    },
  });

  const secondConfirm = (b: Booking, r: string) => {
    setRefund(null);
    modal.confirm({
      title: '再次确认退款',
      content: (
        <div>
          将向 <b>{b.user?.nickname ?? '用户'}</b> 退回 <b>{yuan(b.amount_amt)}</b>（{CHANNEL_LABEL[b.pay?.channel ?? ''] ?? b.pay?.channel ?? '原支付渠道'}原路退回），并释放 {b.venue.name} {slotText(b)} 的场地。此操作不可撤销。
          <div className="muted" style={{ marginTop: 8 }}>
            原因：{r}
          </div>
        </div>
      ),
      okText: '确认退款',
      okButtonProps: { danger: true },
      cancelText: '取消',
      onOk: () => doRefund.mutateAsync({ b, r }),
    });
  };

  const refundButton = (b: Booking, size: 'small' | 'middle' = 'small') =>
    REFUNDABLE.includes(b.status) &&
    (can('booking.refund') ? (
      <Button
        size={size}
        danger
        onClick={(e) => {
          e.stopPropagation();
          setReason(dayjs(b.cancel_deadline).isBefore(dayjs()) ? '开场前 2 小时内取消，客服同意退款' : '');
          setRefund(b);
        }}
      >
        退款
      </Button>
    ) : staff ? null : (
      <Tooltip title="只有管理员可以退款">
        <Button size={size} disabled>
          退款
        </Button>
      </Tooltip>
    ));

  return (
    <>
      <PageHeader
        title={staff ? '场馆预订' : '商户与活动'}
        sub={staff ? '本商户场馆的预订；退款请联系平台运营' : '合作场馆的订场：开始前 2 小时以上用户可自助免费取消；不足 2 小时由客服判断，管理员在这里退款'}
        extra={<MerchantNav />}
      />
      <Panel
        title="订场"
        extra={
          <Space wrap>
            <Select allowClear showSearch optionFilterProp="label" placeholder="全部场馆" style={{ width: 220 }} value={venueId ?? undefined} onChange={(v) => update({ venue_id: v ?? null, page: null })} options={venueOptions} />
            <DatePicker placeholder="开场日期" value={day ? dayjs(day) : null} onChange={(d) => update({ date: d ? d.format('YYYY-MM-DD') : null, page: null })} />
            <Select
              allowClear
              placeholder="全部状态"
              style={{ width: 130 }}
              value={status || undefined}
              onChange={(v) => update({ status: v ?? null, page: null })}
              options={BOOKING_STATUS_ORDER.map((s) => ({ value: s, label: BOOKING_STATUS[s].text }))}
            />
          </Space>
        }
      >
        <Table<Booking>
          rowKey="id"
          loading={list.isFetching}
          dataSource={list.data?.items}
          scroll={{ x: 1200 }}
          onRow={(b) => ({ onClick: () => setDetail(b), style: { cursor: 'pointer' } })}
          locale={{ emptyText: <Empty description="没有符合条件的预订" /> }}
          pagination={{ current: page, pageSize: PAGE, total: list.data?.total ?? 0, showSizeChanger: false, showTotal: (t) => `共 ${t} 笔`, onChange: (p) => update({ page: p === 1 ? null : p }) }}
          columns={[
            { title: '预订号', dataIndex: 'booking_no', width: 190, render: (v: string) => <span className="num">{v}</span> },
            { title: '场馆', key: 'venue', width: 160, render: (_, b) => b.venue.name },
            {
              title: '时段',
              key: 'slot',
              width: 190,
              render: (_, b) => (
                <span className="num">
                  {slotText(b)}
                  {b.court_qty > 1 && <span className="muted"> × {b.court_qty} 片</span>}
                </span>
              ),
            },
            { title: '用户', key: 'user', width: 130, render: (_, b) => (b.user ? can('users.read') ? <Link to={`/users?id=${b.user.id}`} onClick={(e) => e.stopPropagation()}>{b.user.nickname}</Link> : b.user.nickname : '—') },
            {
              title: '金额',
              key: 'amt',
              width: 120,
              align: 'right',
              render: (_, b) => (
                <span className="num">
                  <b>{yuan(b.amount_amt)}</b>
                  {b.discount_type === 'owner' && (
                    <div style={{ fontSize: 12 }}>
                      <Tag bordered={false} color="gold" style={{ marginInlineEnd: 4 }}>
                        馆主价
                      </Tag>
                      <s className="muted">{yuan(b.original_amt)}</s>
                    </div>
                  )}
                </span>
              ),
            },
            { title: '状态', dataIndex: 'status', width: 96, render: (v: BookingStatus) => <BookingStatusTag status={v} /> },
            { title: '组局', dataIndex: 'meetup_id', width: 90, render: (v: number | null) => (v ? <Tag bordered={false} color="purple">约球 #{v}</Tag> : <span className="muted">—</span>) },
            { title: '下单时间', dataIndex: 'created_at', width: 140, render: (v: string) => <span className="num">{dt(v)}</span> },
            { title: '操作', key: 'op', width: 90, align: 'right', fixed: 'right', render: (_, b) => refundButton(b) || <span className="muted">—</span> },
          ]}
        />
      </Panel>

      <Drawer open={detail !== null} onClose={() => setDetail(null)} width={560} title={detail ? `预订 ${detail.booking_no}` : ''} extra={detail && refundButton(detail, 'middle')}>
        {detail && (
          <Space direction="vertical" size={16} style={{ width: '100%' }}>
            <Descriptions size="small" column={1} bordered>
              <Descriptions.Item label="状态">
                <BookingStatusTag status={detail.status} />
              </Descriptions.Item>
              <Descriptions.Item label="场馆">{detail.venue.name}</Descriptions.Item>
              <Descriptions.Item label="时段">
                <span className="num">
                  {dayjs(detail.start_time).format('YYYY-MM-DD ddd HH:mm')}–{dayjs(detail.end_time).format('HH:mm')} · {detail.court_qty} 片场
                </span>
              </Descriptions.Item>
              <Descriptions.Item label="用户">{detail.user ? `${detail.user.nickname}（ID ${detail.user.id}）` : '—'}</Descriptions.Item>
              <Descriptions.Item label="实付">
                <b className="num">{yuan(detail.amount_amt)}</b>
                {detail.discount_type === 'owner' && <span className="muted num">（原价 {yuan(detail.original_amt)}，馆主折扣）</span>}
              </Descriptions.Item>
              <Descriptions.Item label="支付">
                {detail.pay ? (
                  <span className="num">
                    {CHANNEL_LABEL[detail.pay.channel] ?? detail.pay.channel} · {detail.pay.order_no}
                  </span>
                ) : (
                  '—'
                )}
              </Descriptions.Item>
              <Descriptions.Item label="免费取消截止">
                <span className="num">{dt(detail.cancel_deadline)}</span>
              </Descriptions.Item>
              <Descriptions.Item label="约球组局">{detail.meetup_id ? (can('community.read') ? <Link to={`/community`}>组局 #{detail.meetup_id}</Link> : `组局 #${detail.meetup_id}`) : '—'}</Descriptions.Item>
              <Descriptions.Item label="下单时间">
                <span className="num">{dt(detail.created_at)}</span>
              </Descriptions.Item>
            </Descriptions>
            {detail.status === 'pending_pay' && <Alert type="info" showIcon message="待支付：下单 15 分钟内未支付会自动取消并释放时段" />}
            {detail.status === 'refunding' && <Alert type="warning" showIcon message="退款处理中：等待支付渠道回调，到账后变为「已退款」" />}
          </Space>
        )}
      </Drawer>

      <Modal
        open={!!refund}
        title="订场退款（第 1 步，共 2 步）"
        okText="下一步"
        cancelText="取消"
        okButtonProps={{ disabled: !reason.trim() }}
        onCancel={() => setRefund(null)}
        onOk={() => refund && secondConfirm(refund, reason.trim())}
      >
        {refund && (
          <Space direction="vertical" style={{ width: '100%' }}>
            <Alert
              type="warning"
              showIcon
              message={`${refund.booking_no} · ${refund.venue.name} · ${yuan(refund.amount_amt)}`}
              description={`${slotText(refund)}。全额原路退回，场地时段释放。${dayjs(refund.cancel_deadline).isBefore(dayjs()) ? '已过免费取消时间（开场前 2 小时），属于客服特批退款。' : ''}`}
            />
            <Input.TextArea rows={3} maxLength={200} showCount placeholder="退款原因（必填，会写入审计日志）" value={reason} onChange={(e) => setReason(e.target.value)} />
          </Space>
        )}
      </Modal>
    </>
  );
}
