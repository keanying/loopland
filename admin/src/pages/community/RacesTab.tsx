// 组局与赛事 · 赛事管理: list / create / edit / cancel races, entries with offline 「标记完赛」.
import { useEffect, useMemo, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, App, Button, Col, DatePicker, Drawer, Empty, Form, Image, Input, InputNumber, Modal, Radio, Row, Select, Space, Switch, Table, Tag, Tooltip } from 'antd';
import type { Dayjs } from 'dayjs';
import { api, PAGE_SIZE } from '../../api/admin';
import type { Race, RaceEntry, RaceInput, RaceType } from '../../api/types';
import { useAuth } from '../../auth/AuthContext';
import { useWearableEnabled } from '../../hooks/useServerFeatures';
import SvgMap from '../../components/map/SvgMap';
import { Panel, Tile } from '../../components/ui';
import { dayjs, dt, duration, num, pace } from '../../utils/format';
import { RACE_ENTRY_STATUS, RACE_SPORTS, RACE_STATUS, RACE_TYPE, SPORT_LABEL } from '../../utils/labels';
import { toastOk } from '../../utils/notify';
import { RANGE_FORMAT } from '../operations/shared';
import { Glyph } from '../../components/Glyph';

const DEFAULT_CENTER = { lat: 31.232, lng: 121.505 };

function distanceText(m: number): string {
  const k = m / 1000;
  return `${Number.isInteger(k) ? k : k.toFixed(k * 10 === Math.round(k * 10) ? 1 : 3).replace(/0+$/, '')} km`;
}

/** "1:05:30" / "65:30" / "3930" → seconds. */
function parseHms(s: string): number | null {
  const t = s.trim();
  if (!t) return null;
  if (/^\d+$/.test(t)) return Number(t);
  const parts = t.split(/[:：]/).map((x) => x.trim());
  if (parts.length < 2 || parts.length > 3 || !parts.every((x) => /^\d+$/.test(x))) return null;
  const n = parts.map(Number);
  const [h, m, sec] = n.length === 3 ? n : [0, n[0], n[1]];
  if (sec >= 60 || (n.length === 3 && m >= 60)) return null;
  return h * 3600 + m * 60 + sec;
}

export default function RacesTab() {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const { can } = useAuth();
  const writable = can('community.write');
  const [page, setPage] = useState(1);
  const list = useQuery({ queryKey: ['races', page], queryFn: () => api.races({ page }), placeholderData: (p) => p });
  const wearableOn = useWearableEnabled();
  const [editing, setEditing] = useState<Race | 'new' | null>(null);
  const [entriesOf, setEntriesOf] = useState<Race | null>(null);
  const cancel = useMutation({
    mutationFn: (id: number) => api.cancelRace(id),
    onSuccess: (r) => {
      qc.invalidateQueries({ queryKey: ['races'] });
      toastOk(`已取消「${r?.title ?? ''}」，已通知报名者`);
    },
  });

  return (
    <Panel
      title="赛事"
      extra={
        <Button type="primary" icon={<Glyph name="plus" />} disabled={!writable} onClick={() => setEditing('new')}>
          新建赛事
        </Button>
      }
    >
      <Table<Race>
        rowKey="id"
        loading={list.isFetching}
        dataSource={list.data?.items}
        scroll={{ x: 1480 }}
        locale={{ emptyText: <Empty description="还没有赛事" /> }}
        pagination={{ current: page, pageSize: PAGE_SIZE, total: list.data?.total ?? 0, showSizeChanger: false, hideOnSinglePage: true, onChange: setPage }}
        columns={[
          {
            title: '赛事',
            key: 'title',
            render: (_, r) => (
              <Space align="start">
                {r.cover_url ? <img className="race-cover" src={r.cover_url} alt="" /> : <div className="race-cover" />}
                <div style={{ maxWidth: 220 }}>
                  <b>{r.title}</b> <span className="muted num" style={{ fontSize: 12 }}>#{r.id}</span>
                  <div className="muted" style={{ fontSize: 12, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {r.type === 'offline' ? r.place?.name ?? '—' : r.description || '—'}
                  </div>
                </div>
              </Space>
            ),
          },
          { title: '类型', dataIndex: 'type', render: (v: string) => <Tag bordered={false} color={RACE_TYPE[v]?.color}>{RACE_TYPE[v]?.text ?? v}</Tag> },
          { title: '项目', key: 'sport', render: (_, r) => <span className="num" style={{ whiteSpace: 'nowrap' }}>{SPORT_LABEL[r.sport] ?? r.sport} {distanceText(r.distance_m)}</span> },
          {
            title: '比赛时间',
            key: 'time',
            render: (_, r) => (
              <div className="num" style={{ fontSize: 12, whiteSpace: 'nowrap' }}>
                {dt(r.start_time, 'MM-DD HH:mm')} – {dt(r.end_time, dayjs(r.end_time).isSame(r.start_time, 'day') ? 'HH:mm' : 'MM-DD HH:mm')}
                <div className="muted">报名截止 {dt(r.signup_end_time, 'MM-DD HH:mm')}</div>
              </div>
            ),
          },
          {
            title: '报名',
            key: 'signed',
            align: 'right',
            render: (_, r) => (
              <span className="num">
                {num(r.signed_count)} <span className="muted">/ {num(r.capacity)}</span>
              </span>
            ),
          },
          {
            title: '奖牌',
            key: 'medal',
            render: (_, r) =>
              r.medal ? (
                <Space size={6} style={{ whiteSpace: 'nowrap' }}>
                  {r.medal.image_url ? <Image src={r.medal.image_url} width={28} height={28} style={{ borderRadius: 14, objectFit: 'cover' }} alt="" /> : <Glyph name="medal" size="1em" />}
                  <span style={{ fontSize: 12 }}>{r.medal.name}</span>
                </Space>
              ) : (
                <span className="muted">—</span>
              ),
          },
          // 穿戴设备是预留口子：开关打开、或已有赛事设过时才显示这一列
          ...(wearableOn || (list.data?.items ?? []).some((r) => r.requires_wearable)
            ? [{ title: '穿戴设备', width: 96, dataIndex: 'requires_wearable', render: (v: boolean, r: Race) => (r.type === 'online' ? (v ? <Tag bordered={false} color="purple">必须</Tag> : <span className="muted">不要求</span>) : <span className="muted">—</span>) }]
            : []),
          { title: '发布', dataIndex: 'published', render: (v: boolean) => (v ? <Tag bordered={false} color="green">已发布</Tag> : <Tag bordered={false}>草稿</Tag>) },
          { title: '状态', dataIndex: 'status', render: (v: string) => <Tag bordered={false} color={RACE_STATUS[v]?.color}>{RACE_STATUS[v]?.text ?? v}</Tag> },
          {
            title: '操作',
            key: 'op',
            align: 'right',
            render: (_, r) => {
              const closed = r.status === 'cancelled' || r.status === 'finished';
              return (
                <Space>
                  <Button size="small" onClick={() => setEntriesOf(r)}>
                    报名名单
                  </Button>
                  <Tooltip title={closed ? '已取消或已结束的赛事不能修改' : undefined}>
                    <Button size="small" disabled={!writable || closed} onClick={() => setEditing(r)}>
                      编辑
                    </Button>
                  </Tooltip>
                  <Button
                    size="small"
                    danger
                    disabled={!writable || closed}
                    onClick={() =>
                      modal.confirm({
                        title: `取消「${r.title}」？`,
                        content: `已报名的 ${r.signed_count} 人会收到「赛事取消」通知，之后不再接受报名，也不再判定完赛。此操作不可撤销。`,
                        okText: '取消赛事',
                        okButtonProps: { danger: true },
                        cancelText: '返回',
                        onOk: () => cancel.mutateAsync(r.id),
                      })
                    }
                  >
                    取消
                  </Button>
                </Space>
              );
            },
          },
        ]}
      />
      <RaceDrawer value={editing} onClose={() => setEditing(null)} />
      <EntriesDrawer race={entriesOf} onClose={() => setEntriesOf(null)} writable={writable} />
    </Panel>
  );
}

// ------------------------------------------------------------ create / edit

interface FormValues {
  type: RaceType;
  title: string;
  sport: string;
  distance_km: number;
  description?: string;
  cover_url?: string;
  range: [Dayjs, Dayjs];
  signup_end: Dayjs;
  capacity: number;
  requires_wearable: boolean;
  medal_key?: string;
  medal_name?: string;
  medal_image_url?: string;
  published: boolean;
  place_name?: string;
  lat?: number | null;
  lng?: number | null;
}

const minute = (d: Dayjs) => d.second(0).millisecond(0).format();

function RaceDrawer({ value, onClose }: { value: Race | 'new' | null; onClose: () => void }) {
  const [form] = Form.useForm<FormValues>();
  const qc = useQueryClient();
  const editing = value && value !== 'new' ? value : null;
  const running = editing?.status === 'running';
  const type = Form.useWatch('type', form) ?? 'online';
  const wearableOn = useWearableEnabled();
  const requiresWearable = Form.useWatch('requires_wearable', form);
  const lat = Form.useWatch('lat', form);
  const lng = Form.useWatch('lng', form);
  const placeName = Form.useWatch('place_name', form);
  const cover = Form.useWatch('cover_url', form);
  const medalImg = Form.useWatch('medal_image_url', form);
  const point = typeof lat === 'number' && typeof lng === 'number' ? { lat, lng } : null;

  const bbox = useMemo<[number, number, number, number]>(() => {
    const c = point ?? DEFAULT_CENTER;
    return [+(c.lng - 0.02).toFixed(3), +(c.lat - 0.015).toFixed(3), +(c.lng + 0.02).toFixed(3), +(c.lat + 0.015).toFixed(3)];
    // eslint-disable-next-line react-hooks/exhaustive-deps -- refetch when the point moves noticeably
  }, [point ? `${point.lat.toFixed(2)},${point.lng.toFixed(2)}` : '']);
  const geo = useQuery({ queryKey: ['territories', 'geo', bbox.join(',')], queryFn: () => api.territoriesGeo(bbox), enabled: value !== null && type === 'offline', placeholderData: (p) => p });

  const save = useMutation({
    mutationFn: (body: RaceInput) => (editing ? api.updateRace(editing.id, body) : api.createRace(body)),
    onSuccess: (r) => {
      qc.invalidateQueries({ queryKey: ['races'] });
      toastOk(editing ? '赛事已更新' : r?.published ? '赛事已创建并发布' : '赛事已保存为草稿');
      onClose();
    },
  });

  const submit = (v: FormValues) => {
    save.mutate({
      type: v.type,
      title: v.title.trim(),
      sport: v.sport,
      distance_m: Math.round(v.distance_km * 1000),
      description: (v.description ?? '').trim(),
      cover_url: v.cover_url?.trim() || null,
      start_time: minute(v.range[0]),
      end_time: minute(v.range[1]),
      signup_end_time: minute(v.signup_end),
      place: v.type === 'offline' ? { name: (v.place_name ?? '').trim(), lat: Number(v.lat), lng: Number(v.lng) } : null,
      capacity: v.capacity,
      requires_wearable: v.type === 'online' && v.requires_wearable,
      medal: { key: (v.medal_key ?? '').trim(), name: (v.medal_name ?? '').trim(), image_url: v.medal_image_url?.trim() || null },
      published: v.published,
    });
  };

  return (
    <Drawer
      open={value !== null}
      onClose={onClose}
      width={960}
      forceRender
      title={editing ? `编辑「${editing.title}」` : '新建赛事'}
      extra={
        <Space>
          <Button onClick={onClose}>取消</Button>
          <Button type="primary" loading={save.isPending} onClick={() => form.submit()}>
            保存
          </Button>
        </Space>
      }
      afterOpenChange={(o) => {
        if (!o) return;
        form.resetFields();
        if (editing) {
          form.setFieldsValue({
            type: editing.type,
            title: editing.title,
            sport: editing.sport,
            distance_km: editing.distance_m / 1000,
            description: editing.description,
            cover_url: editing.cover_url ?? '',
            range: [dayjs(editing.start_time), dayjs(editing.end_time)],
            signup_end: dayjs(editing.signup_end_time),
            capacity: editing.capacity,
            requires_wearable: editing.requires_wearable,
            medal_key: editing.medal?.key ?? '',
            medal_name: editing.medal?.name ?? '',
            medal_image_url: editing.medal?.image_url ?? '',
            published: editing.published,
            place_name: editing.place?.name ?? '',
            lat: editing.place?.lat ?? null,
            lng: editing.place?.lng ?? null,
          });
        } else {
          const start = dayjs().add(7, 'day').startOf('day');
          form.setFieldsValue({
            type: 'online',
            sport: 'run',
            distance_km: 10,
            range: [start, start.add(7, 'day').subtract(1, 'minute')],
            signup_end: start.subtract(1, 'minute'),
            capacity: 1000,
            requires_wearable: false,
            published: false,
            lat: null,
            lng: null,
          });
        }
      }}
    >
      {running && <Alert type="warning" showIcon style={{ marginBottom: 12 }} message="赛事进行中：类型、运动、距离和开始时间不能再改；已报名的人会看到更新后的信息。" />}
      <Form<FormValues> form={form} layout="vertical" requiredMark={false} onFinish={submit}>
        <Row gutter={24}>
          <Col xs={24} lg={type === 'offline' ? 13 : 24}>
            <Row gutter={12}>
              <Col span={10}>
                <Form.Item name="type" label="类型">
                  <Radio.Group optionType="button" buttonStyle="solid" disabled={running} options={[{ label: '线上赛', value: 'online' }, { label: '线下赛', value: 'offline' }]} />
                </Form.Item>
              </Col>
              <Col span={14}>
                <Form.Item name="title" label="赛事名称" rules={[{ required: true, whitespace: true, message: '请填写名称' }]}>
                  <Input maxLength={40} showCount placeholder="城市 10K 线上赛" />
                </Form.Item>
              </Col>
              <Col span={10}>
                <Form.Item name="sport" label="运动">
                  <Select disabled={running} options={RACE_SPORTS.map((s) => ({ value: s, label: SPORT_LABEL[s] ?? s }))} />
                </Form.Item>
              </Col>
              <Col span={14}>
                <Form.Item name="distance_km" label="距离" rules={[{ required: true, message: '请填写距离' }, { type: 'number', min: 0.1, message: '至少 0.1 km' }]} extra={type === 'online' ? '时间窗内单次运动达到这个距离即完赛，用时按距离折算' : undefined}>
                  <InputNumber className="num" min={0.1} max={500} step={1} precision={3} suffix="km" style={{ width: '100%' }} disabled={running} />
                </Form.Item>
              </Col>
            </Row>
            <Form.Item
              name="range"
              label={type === 'online' ? '比赛时间窗' : '比赛时间'}
              rules={[
                { required: true, message: '请选择时间' },
                { validator: (_, r?: [Dayjs, Dayjs]) => (!r?.[0] || !r?.[1] || r[1].isAfter(r[0]) ? Promise.resolve() : Promise.reject(new Error('结束时间必须晚于开始时间'))) },
              ]}
            >
              <DatePicker.RangePicker showTime={{ format: 'HH:mm' }} format={RANGE_FORMAT} style={{ width: '100%' }} disabled={running ? [true, false] : false} />
            </Form.Item>
            <Row gutter={12}>
              <Col span={14}>
                <Form.Item
                  name="signup_end"
                  label="报名截止"
                  dependencies={['range', 'type']}
                  rules={[
                    { required: true, message: '请选择报名截止时间' },
                    ({ getFieldValue }) => ({
                      validator: (_, v?: Dayjs) => {
                        const r = getFieldValue('range') as [Dayjs, Dayjs] | undefined;
                        if (!v || !r?.[0] || !r?.[1]) return Promise.resolve();
                        if (v.isAfter(r[1])) return Promise.reject(new Error('不能晚于比赛结束'));
                        if (getFieldValue('type') === 'offline' && v.isAfter(r[0])) return Promise.reject(new Error('线下赛要在开赛前截止报名'));
                        return Promise.resolve();
                      },
                    }),
                  ]}
                  extra={type === 'online' ? '可以晚于开始时间（边比边报），但不能晚于结束' : undefined}
                >
                  <DatePicker showTime={{ format: 'HH:mm' }} format={RANGE_FORMAT} style={{ width: '100%' }} />
                </Form.Item>
              </Col>
              <Col span={10}>
                <Form.Item
                  name="capacity"
                  label="名额"
                  rules={[
                    { required: true, message: '请填写名额' },
                    { type: 'number', min: Math.max(1, editing?.signed_count ?? 1), message: editing?.signed_count ? `已有 ${editing.signed_count} 人报名，不能少于这个数` : '至少 1 人' },
                  ]}
                >
                  <InputNumber className="num" min={1} max={1_000_000} precision={0} suffix="人" style={{ width: '100%' }} />
                </Form.Item>
              </Col>
            </Row>
            {type === 'online' && (wearableOn || requiresWearable) && (
              <Form.Item name="requires_wearable" label="要求穿戴设备数据" valuePropName="checked" extra="打开后，只有带手表 / 手环数据（心率、步频）的运动才算完赛">
                <Switch />
              </Form.Item>
            )}
            <Form.Item name="description" label="说明（App 赛事详情展示）">
              <Input.TextArea rows={3} maxLength={500} showCount placeholder="比赛规则、领物方式、注意事项" />
            </Form.Item>
            <Row gutter={12} align="middle">
              <Col flex="auto">
                <Form.Item name="cover_url" label="封面图地址（可选）" rules={[{ pattern: /^(https?:\/\/|\/|data:image\/)/, message: '需要是 http(s) 地址或 /v1/media 路径' }]}>
                  <Input placeholder="https://cdn.../race/cover.jpg" allowClear />
                </Form.Item>
              </Col>
              {cover && (
                <Col>
                  <Image src={cover} width={96} height={54} style={{ objectFit: 'cover', borderRadius: 8 }} alt="封面预览" />
                </Col>
              )}
            </Row>

            <div className="tile" style={{ marginBottom: 16 }}>
              <b>完赛奖牌</b>
              <span className="muted" style={{ fontSize: 12, marginLeft: 8 }}>
                完赛即发（图鉴「奖牌」类），每场赛事一枚
              </span>
              <Row gutter={12} style={{ marginTop: 10 }}>
                  <Col span={12}>
                    <Form.Item
                      name="medal_key"
                      label="奖牌 key（图鉴 item）"
                      rules={[{ pattern: /^[a-z0-9_]{3,64}$/, message: '小写字母、数字、下划线，3–64 位' }]}
                      extra={editing ? '已有人完赛后不能再改' : '留空自动生成'}
                      style={{ marginBottom: 8 }}
                    >
                      <Input className="num" placeholder="race_2026_city10k" allowClear />
                    </Form.Item>
                  </Col>
                  <Col span={12}>
                    <Form.Item name="medal_name" label="奖牌名称" extra="留空为「赛事名称 完赛奖牌」" style={{ marginBottom: 8 }}>
                      <Input maxLength={30} placeholder="城市 10K 完赛奖牌" />
                    </Form.Item>
                  </Col>
                  <Col flex="auto">
                    <Form.Item name="medal_image_url" label="奖牌图片地址（可选）" style={{ marginBottom: 0 }}>
                      <Input placeholder="https://cdn.../medal.png" allowClear />
                    </Form.Item>
                  </Col>
                  {medalImg && (
                    <Col style={{ paddingTop: 26 }}>
                      <Image src={medalImg} width={44} height={44} style={{ borderRadius: 22, objectFit: 'cover' }} alt="奖牌预览" />
                    </Col>
                  )}
                </Row>
            </div>
            <Form.Item name="published" label="发布到 App" valuePropName="checked" extra="不发布时是草稿，App 看不到">
              <Switch checkedChildren="发布" unCheckedChildren="草稿" />
            </Form.Item>
          </Col>

          {type === 'offline' && (
            <Col xs={24} lg={11}>
              <b>集合地点</b>
              <div className="muted" style={{ fontSize: 12, margin: '2px 0 8px' }}>
                <Glyph name="locate" size="1em" /> 在地图上点击选点，或直接填坐标（GCJ-02）
              </div>
              <Form.Item name="place_name" label="地点名称" rules={[{ required: true, whitespace: true, message: '线下赛需要集合地点' }]}>
                <Input maxLength={30} placeholder="世纪公园 3 号门" />
              </Form.Item>
              <Row gutter={8}>
                <Col span={12}>
                  <Form.Item name="lat" label="纬度 lat" rules={[{ required: true, message: '请选点或填写' }]}>
                    <InputNumber className="num" min={-90} max={90} step={0.0005} precision={6} style={{ width: '100%' }} placeholder="31.219500" />
                  </Form.Item>
                </Col>
                <Col span={12}>
                  <Form.Item name="lng" label="经度 lng" rules={[{ required: true, message: '请选点或填写' }]}>
                    <InputNumber className="num" min={-180} max={180} step={0.0005} precision={6} style={{ width: '100%' }} placeholder="121.545500" />
                  </Form.Item>
                </Col>
              </Row>
              <div className="race-place route-preview">
                <SvgMap
                  items={geo.data?.items ?? []}
                  selectedId={null}
                  onSelect={() => undefined}
                  focus={null}
                  objects={{ bosses: [], chests: [], checkpoints: point ? [{ route_id: 0, index: 0, name: placeName || '集合点', center: point, radius_m: 80 }] : [] }}
                  layers={{ territories: true, bosses: false, chests: false, checkpoints: true }}
                  preview
                  picking
                  onPick={(p) => form.setFieldsValue({ lat: +p.lat.toFixed(6), lng: +p.lng.toFixed(6) })}
                />
              </div>
            </Col>
          )}
        </Row>
      </Form>
    </Drawer>
  );
}

// ------------------------------------------------------------ entries

function EntriesDrawer({ race, onClose, writable }: { race: Race | null; onClose: () => void; writable: boolean }) {
  const qc = useQueryClient();
  const [page, setPage] = useState(1);
  const id = race?.id ?? 0;
  const q = useQuery({ queryKey: ['races', 'entries', id, page], queryFn: () => api.raceEntries(id, { page }), enabled: !!race, placeholderData: (p) => p });
  const [finishing, setFinishing] = useState<RaceEntry | null>(null);
  const offline = race?.type === 'offline';
  const started = race ? Date.parse(race.start_time) <= Date.now() : false;
  const canFinish = writable && offline && started && race?.status !== 'cancelled';
  const items = q.data?.items ?? [];

  return (
    <Drawer
      open={race !== null}
      onClose={onClose}
      width={980}
      title={race ? `报名名单 · ${race.title}` : ''}
      afterOpenChange={(o) => o && setPage(1)}
    >
      {race && (
        <>
          <Row gutter={[10, 10]} style={{ marginBottom: 14 }}>
            <Col xs={12} md={6}>
              <Tile v={`${num(race.signed_count)} / ${num(race.capacity)}`} l="报名 / 名额" />
            </Col>
            <Col xs={12} md={6}>
              <Tile v={`${SPORT_LABEL[race.sport] ?? race.sport} ${distanceText(race.distance_m)}`} l={RACE_TYPE[race.type]?.text ?? race.type} />
            </Col>
            <Col xs={12} md={6}>
              <Tile v={<span style={{ fontSize: 15 }}>{dt(race.start_time, 'MM-DD HH:mm')}</span>} l={`至 ${dt(race.end_time, 'MM-DD HH:mm')}`} />
            </Col>
            <Col xs={12} md={6}>
              <Tile v={<span style={{ fontSize: 15 }}>{race.medal?.name ?? '—'}</span>} l={RACE_STATUS[race.status]?.text ?? race.status} />
            </Col>
          </Row>
          {offline ? (
            <Alert
              type="info"
              showIcon
              style={{ marginBottom: 12 }}
              message={started ? '线下赛：按计时成绩逐个「标记完赛」，标记后立刻发奖牌和站内信。' : '线下赛开赛后才能标记完赛。'}
            />
          ) : (
            <Alert type="info" showIcon style={{ marginBottom: 12 }} message="线上赛：运动结算时自动判定完赛，这里只能查看。" />
          )}
          <Table<RaceEntry>
            rowKey={(e) => e.user.id}
            size="small"
            loading={q.isFetching}
            dataSource={items}
            scroll={{ x: 860 }}
            locale={{ emptyText: <Empty description="还没有人报名" /> }}
            pagination={{ current: page, pageSize: PAGE_SIZE, total: q.data?.total ?? 0, showSizeChanger: false, showTotal: (t) => `共 ${t} 人`, onChange: setPage }}
            columns={[
              {
                title: '用户',
                key: 'user',
                render: (_, e) => (
                  <span>
                    {e.user.nickname} <span className="muted num">#{e.user.id}</span>
                  </span>
                ),
              },
              { title: '状态', dataIndex: 'status', render: (v: string) => <Tag bordered={false} color={RACE_ENTRY_STATUS[v]?.color}>{RACE_ENTRY_STATUS[v]?.text ?? v}</Tag> },
              { title: '成绩', dataIndex: 'result_sec', align: 'right', render: (v: number | null) => <b className="num">{v ? duration(v) : '—'}</b> },
              { title: '配速', key: 'pace', align: 'right', render: (_, e) => <span className="num muted">{e.result_sec ? `${pace(e.result_sec / (race.distance_m / 1000))}/km` : '—'}</span> },
              { title: '完赛时间', dataIndex: 'finished_at', render: (v: string | null) => <span className="num muted">{dt(v, 'MM-DD HH:mm')}</span> },
              { title: '运动记录', dataIndex: 'activity_id', render: (v: number | null) => (v ? <span className="num">#{v}</span> : <span className="muted">{offline ? '线下' : '—'}</span>) },
              { title: '报名时间', dataIndex: 'signed_at', render: (v: string) => <span className="num muted">{dt(v, 'MM-DD HH:mm')}</span> },
              ...(offline
                ? [
                    {
                      title: '操作',
                      key: 'op',
                      align: 'right' as const,
                      render: (_: unknown, e: RaceEntry) =>
                        e.status === 'finished' ? (
                          <Tooltip title="已发奖牌；改成绩不会重复发">
                            <Button size="small" disabled={!canFinish} onClick={() => setFinishing(e)}>
                              改成绩
                            </Button>
                          </Tooltip>
                        ) : (
                          <Tooltip title={!started ? '开赛后才能标记' : undefined}>
                            <Button size="small" type="primary" disabled={!canFinish} onClick={() => setFinishing(e)}>
                              标记完赛
                            </Button>
                          </Tooltip>
                        ),
                    },
                  ]
                : []),
            ]}
          />
          <FinishModal
            race={race}
            entry={finishing}
            onClose={() => setFinishing(null)}
            onDone={() => {
              setFinishing(null);
              qc.invalidateQueries({ queryKey: ['races', 'entries', id] });
            }}
          />
        </>
      )}
    </Drawer>
  );
}

function FinishModal({ race, entry, onClose, onDone }: { race: Race; entry: RaceEntry | null; onClose: () => void; onDone: () => void }) {
  const [text, setText] = useState('');
  const [tried, setTried] = useState(false);
  const open = entry !== null;
  useEffect(() => {
    if (open) {
      setText(entry?.result_sec ? duration(entry.result_sec) : '');
      setTried(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- reset only when the dialog opens
  }, [open]);
  const sec = parseHms(text);
  const valid = sec !== null && sec > 0 && sec <= 24 * 3600;
  const finish = useMutation({
    mutationFn: (s: number) => api.finishRaceEntry(race.id, entry!.user.id, s),
    onSuccess: () => {
      toastOk(entry?.status === 'finished' ? `已修改 ${entry.user.nickname} 的成绩` : `已标记 ${entry?.user.nickname} 完赛，发放「${race.medal?.name ?? '完赛奖牌'}」`);
      onDone();
    },
  });
  const submit = () => {
    setTried(true);
    if (valid) finish.mutate(sec);
  };
  return (
    <Modal
      open={entry !== null}
      title={entry ? `${entry.status === 'finished' ? '修改成绩' : '标记完赛'}：${entry.user.nickname}` : ''}
      okText={entry?.status === 'finished' ? '保存成绩' : '标记完赛'}
      cancelText="取消"
      okButtonProps={{ loading: finish.isPending }}
      onCancel={onClose}
      onOk={submit}
    >
      <div style={{ marginBottom: 6 }}>
        完赛用时（{SPORT_LABEL[race.sport] ?? race.sport} {distanceText(race.distance_m)}）
      </div>
      <Input
        className="num"
        size="large"
        autoFocus
        placeholder="时:分:秒，例如 1:05:30"
        value={text}
        status={tried && !valid ? 'error' : undefined}
        onChange={(e) => setText(e.target.value)}
        onPressEnter={submit}
        aria-label="完赛用时"
      />
      <div style={{ fontSize: 12, marginTop: 6 }} className={tried && !valid ? 'danger-text' : 'muted'}>
        {valid
          ? `= ${duration(sec)} · 平均配速 ${pace(sec / (race.distance_m / 1000))}/km`
          : tried
            ? '格式为 时:分:秒 或 分:秒，最长 24 小时'
            : '也可以输入分:秒（如 52:10）或总秒数'}
      </div>
      <div className="muted" style={{ fontSize: 12, marginTop: 10 }}>
        {entry?.status === 'finished' ? '只更新成绩，不会重复发奖牌。' : `标记后发放奖牌「${race.medal?.name ?? '完赛奖牌'}」并给用户发站内信，不能撤销。`}
      </div>
    </Modal>
  );
}
