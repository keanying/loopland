import { Link, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import dayjs from 'dayjs';
import { DatePicker, Empty, Select, Space, Table, Tag, Tooltip } from 'antd';
import { merchantApi, type Redemption } from '../../api/merchant';
import { useAuth } from '../../auth/AuthContext';
import { PageHeader, Panel } from '../../components/ui';
import { dt } from '../../utils/format';
import { DROP_TYPE_LABEL } from './labels';
import { MerchantNav } from './nav';
import { urlParams, useMerchantOptions } from './util';

const PAGE = 20;

export default function RedemptionsPage() {
  const { can, admin } = useAuth();
  const staff = admin?.role === 'merchant';
  const [params, setParams] = useSearchParams();
  const update = urlParams(params, setParams);
  const merchantId = Number(params.get('merchant_id') ?? 0) || null;
  const from = params.get('from') ?? '';
  const to = params.get('to') ?? '';
  const page = Number(params.get('page') ?? 1);
  const merchants = useMerchantOptions(!staff && can('merchant.read'));

  const list = useQuery({
    queryKey: ['redemptions', 'list', merchantId, from, to, page],
    queryFn: () => merchantApi.redemptions({ merchant_id: merchantId, from, to, page }),
    placeholderData: (p) => p,
  });

  return (
    <>
      <PageHeader title={staff ? '核销记录' : '商户与活动'} sub="每一次到店核销；当天的运动记录事后被风控作废时，那天依赖它的核销标记「作废」，不进结算" extra={<MerchantNav />} />
      <Panel
        title="核销记录"
        extra={
          <Space wrap>
            {!staff && (
              <Select
                allowClear
                showSearch
                optionFilterProp="label"
                placeholder="全部商户"
                style={{ width: 180 }}
                value={merchantId ?? undefined}
                onChange={(v) => update({ merchant_id: v ?? null, page: null })}
                options={merchants.options}
              />
            )}
            <DatePicker.RangePicker
              value={from && to ? [dayjs(from), dayjs(to)] : null}
              disabledDate={(d) => d.isAfter(dayjs(), 'day')}
              presets={[
                { label: '今天', value: [dayjs(), dayjs()] },
                { label: '近 7 天', value: [dayjs().subtract(6, 'day'), dayjs()] },
                { label: '近 30 天', value: [dayjs().subtract(29, 'day'), dayjs()] },
              ]}
              onChange={(v) => update({ from: v?.[0]?.format('YYYY-MM-DD') ?? null, to: v?.[1]?.format('YYYY-MM-DD') ?? null, page: null })}
            />
          </Space>
        }
      >
        <Table<Redemption>
          rowKey="id"
          loading={list.isFetching}
          dataSource={list.data?.items}
          scroll={{ x: 1100 }}
          rowClassName={(r) => (r.voided ? 'row-disabled' : '')}
          locale={{ emptyText: <Empty description="没有核销记录" /> }}
          pagination={{ current: page, pageSize: PAGE, total: list.data?.total ?? 0, showSizeChanger: false, showTotal: (t) => `共 ${t} 次`, onChange: (p) => update({ page: p === 1 ? null : p }) }}
          columns={[
            { title: '核销时间', dataIndex: 'created_at', render: (v: string) => <span className="num">{dt(v, 'MM-DD HH:mm:ss')}</span> },
            { title: '券码', key: 'code', render: (_, r) => <span className="num">{r.coupon.code}</span> },
            {
              title: '权益',
              key: 'perk',
              render: (_, r) => (
                <Tooltip title={r.coupon.perk.description}>
                  <b>{r.coupon.perk.title}</b>
                </Tooltip>
              ),
            },
            { title: '用户', key: 'user', render: (_, r) => (can('users.read') ? <Link to={`/users?id=${r.user.id}`}>{r.user.nickname}</Link> : r.user.nickname) },
            ...(staff ? [] : [{ title: '商户', key: 'merchant', render: (_: unknown, r: Redemption) => r.coupon.merchant.name }]),
            { title: '门店', dataIndex: 'store', render: (v: string | null) => v ?? '—' },
            {
              title: '来源',
              key: 'source',
              render: (_, r) => (
                <span>
                  <Tag bordered={false}>{DROP_TYPE_LABEL[r.coupon.source.type] ?? r.coupon.source.type}</Tag>
                  <span className="muted" style={{ fontSize: 12 }}>
                    {r.coupon.source.name}
                  </span>
                </span>
              ),
            },
            { title: '领取时间', key: 'obtained', render: (_, r) => <span className="num muted">{dt(r.coupon.obtained_at, 'MM-DD HH:mm')}</span> },
            {
              title: '状态',
              key: 'status',
              render: (_, r) =>
                r.voided ? (
                  <Tooltip title="当天的运动记录被风控作废，这次核销不结算">
                    <Tag color="error" bordered={false}>
                      风控作废
                    </Tag>
                  </Tooltip>
                ) : (
                  <Tag color="success" bordered={false}>
                    有效
                  </Tag>
                ),
            },
          ]}
        />
      </Panel>
    </>
  );
}
