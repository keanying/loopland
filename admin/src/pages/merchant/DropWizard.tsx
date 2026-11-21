// 新建 / 编辑投放 (M-25): 类型与商户 → 位置 → 权益 → 发放与结算, with a live preview of the coupon in the App.
import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, Button, Col, DatePicker, Drawer, Empty, Form, Input, InputNumber, Radio, Row, Select, Space, Steps, Tag } from 'antd';
import { AimOutlined, MinusOutlined, PlusOutlined } from '@ant-design/icons';
import type { Dayjs } from 'dayjs';
import { perksApi, type Drop, type DropInput, type DropType, type SettleDirection } from '../../api/perks';
import { api } from '../../api/admin';
import SvgMap from '../../components/map/SvgMap';
import { dayjs, dt, num } from '../../utils/format';
import { toastOk } from '../../utils/notify';
import { MERCHANT_STATUS } from './labels';
import { CAMPAIGN_STATUS, DROP_TYPE, DROP_TYPES, NO_PAID_DRAW, SETTLE_DIRECTION_TEXT, toFen, toYuan } from './perkLabels';
import { CouponPreview, DropTypeBadge } from './perkShared';

const DEFAULT_CENTER = { lat: 31.232, lng: 121.505 };
const RANGE_FORMAT = 'YYYY-MM-DD HH:mm';
const DEFAULT_RADIUS: Record<DropType, number> = { supply: 80, chest: 60, stronghold: 150 };
const RULES_DEFAULT = '到店出示券码，店员扫码核销；需要当天有一条运动记录';
const RULES_STRONGHOLD = '前台出示券码，店员扫码核销；需要当天有一条运动记录（场馆签到也算）';

interface FormValues {
  type: DropType;
  merchant_id: number;
  campaign_id: number | null;
  place: string;
  lat?: number;
  lng?: number;
  radius_m: number;
  venue_id?: number;
  perk: { title: string; value_text: string; description: string; valid_days: number; rules: string };
  daily_cap: number;
  range: [Dayjs, Dayjs];
  settle_price: number;
  settle_direction: SettleDirection;
}

const STEPS = [
  { title: '类型与商户', fields: ['type', 'merchant_id', 'campaign_id'] },
  { title: '位置', fields: ['place', 'lat', 'lng', 'radius_m', 'venue_id'] },
  { title: '权益', fields: [['perk', 'title'], ['perk', 'value_text'], ['perk', 'description'], ['perk', 'valid_days'], ['perk', 'rules']] },
  { title: '发放与结算', fields: ['daily_cap', 'range', 'settle_price', 'settle_direction'] },
] as const;

/** "补给站 · 滨江大道 · 东昌路口" → "滨江大道 · 东昌路口". */
function placeOf(d: Drop): string {
  const prefix = `${DROP_TYPE[d.type].label} · `;
  return d.name.startsWith(prefix) ? d.name.slice(prefix.length) : d.name;
}

export default function DropWizard({ value, defaultMerchantId, onClose }: { value: Drop | 'new' | null; defaultMerchantId?: number | null; onClose: () => void }) {
  const [form] = Form.useForm<FormValues>();
  const qc = useQueryClient();
  const editing = value && value !== 'new' ? value : null;
  const open = value !== null;
  const [step, setStep] = useState(0);

  const type = (Form.useWatch('type', form) ?? 'supply') as DropType;
  const merchantId = Form.useWatch('merchant_id', form) as number | undefined;
  const campaignId = Form.useWatch('campaign_id', form) as number | null | undefined;
  const venueId = Form.useWatch('venue_id', form) as number | undefined;
  const lat = Form.useWatch('lat', form);
  const lng = Form.useWatch('lng', form);
  const radius = Form.useWatch('radius_m', form) as number | undefined;
  const place = Form.useWatch('place', form) as string | undefined;
  const perk = Form.useWatch('perk', form) ?? {};
  const dailyCap = Form.useWatch('daily_cap', form) as number | undefined;
  const range = Form.useWatch('range', form) as [Dayjs, Dayjs] | undefined;
  const settlePrice = Form.useWatch('settle_price', form) as number | undefined;
  const direction = Form.useWatch('settle_direction', form) as SettleDirection | undefined;

  const merchants = useQuery({ queryKey: ['perk-merchants'], queryFn: perksApi.merchantOptions, enabled: open, staleTime: 60_000 });
  const campaigns = useQuery({ queryKey: ['brand-campaigns', 'options'], queryFn: () => perksApi.campaigns({ page_size: 100 }), enabled: open, staleTime: 30_000 });
  const venues = useQuery({
    queryKey: ['perk-venues', merchantId ?? 0],
    queryFn: () => perksApi.venueOptions(merchantId),
    enabled: open && type === 'stronghold' && !!merchantId,
    staleTime: 60_000,
  });
  const merchant = merchants.data?.items.find((m) => m.id === merchantId);
  const merchantCampaigns = (campaigns.data?.items ?? []).filter((c) => c.merchant.id === merchantId && c.status !== 'ended');
  const campaign = merchantCampaigns.find((c) => c.id === campaignId);
  const venue = venues.data?.items.find((v) => v.id === venueId);

  const point = type === 'stronghold' ? venue?.center ?? null : typeof lat === 'number' && typeof lng === 'number' ? { lat, lng } : null;
  const shownRadius = type === 'stronghold' ? venue?.checkin_radius_m ?? DEFAULT_RADIUS.stronghold : radius ?? DEFAULT_RADIUS[type];
  const bbox = useMemo<[number, number, number, number]>(() => {
    const c = point ?? DEFAULT_CENTER;
    return [+(c.lng - 0.02).toFixed(3), +(c.lat - 0.015).toFixed(3), +(c.lng + 0.02).toFixed(3), +(c.lat + 0.015).toFixed(3)];
    // eslint-disable-next-line react-hooks/exhaustive-deps -- refetch when the point moves noticeably
  }, [point ? `${point.lat.toFixed(2)},${point.lng.toFixed(2)}` : '']);
  const geo = useQuery({ queryKey: ['territories', 'geo', bbox.join(',')], queryFn: () => api.territoriesGeo(bbox), enabled: open && step === 1, placeholderData: (p) => p });
  // other live drops, drawn around the point for context
  const nearby = useQuery({ queryKey: ['drops', 'live', null], queryFn: () => perksApi.drops({ status: 'active', page_size: 100 }), enabled: open && step === 1, staleTime: 30_000 });
  const others = (nearby.data?.items ?? []).filter((d) => d.id !== editing?.id);

  const save = useMutation({
    mutationFn: (body: DropInput) => {
      if (!editing) return perksApi.createDrop(body);
      const { type: _t, merchant_id: _m, ...patch } = body;
      return perksApi.updateDrop(editing.id, patch);
    },
    onSuccess: (d) => {
      qc.invalidateQueries({ queryKey: ['drops'] });
      qc.invalidateQueries({ queryKey: ['brand-campaigns'] });
      qc.invalidateQueries({ queryKey: ['map-objects'] });
      toastOk(editing ? `已保存「${d.name}」` : `已创建「${d.name}」，${d.status === 'active' ? '现在开始发券' : '到开始时间自动发券'}`);
      onClose();
    },
  });

  // Keep the stronghold's place in step with the chosen venue.
  useEffect(() => {
    if (type === 'stronghold' && venue) form.setFieldsValue({ place: venue.name });
  }, [type, venue, form]);

  const reset = () => {
    setStep(0);
    form.resetFields();
    if (editing) {
      form.setFieldsValue({
        type: editing.type,
        merchant_id: editing.merchant.id,
        campaign_id: editing.campaign_id,
        place: placeOf(editing),
        lat: editing.center.lat,
        lng: editing.center.lng,
        radius_m: editing.radius_m,
        venue_id: editing.venue_id ?? undefined,
        perk: { ...editing.perk },
        daily_cap: editing.daily_cap,
        range: [dayjs(editing.start_time), dayjs(editing.end_time)],
        settle_price: toYuan(editing.settle_price_amt),
        settle_direction: editing.settle_direction,
      });
    } else {
      // separate dayjs instances: derived ones share a config object that the form's deep compare flags as circular
      const start = dayjs().add(1, 'hour').startOf('hour');
      form.setFieldsValue({
        type: 'supply',
        merchant_id: defaultMerchantId ?? undefined,
        campaign_id: null,
        radius_m: DEFAULT_RADIUS.supply,
        perk: { title: '', value_text: '', description: '', valid_days: 7, rules: RULES_DEFAULT },
        daily_cap: 200,
        range: [start, dayjs(start.add(30, 'day').endOf('day').second(0).toDate())],
        settle_price: 2,
        settle_direction: 'merchant_pays',
      });
    }
  };

  // Fill the form as soon as it opens (not after the animation, so early clicks are kept).
  useEffect(() => {
    if (value !== null) reset();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- once per open
  }, [value]);

  // setFieldsValue, not setFieldValue: the latter resets the field's meta in a way antd's deep compare
  // reports as "There may be circular references".
  const setPerk = (patch: Partial<FormValues['perk']>) => form.setFieldsValue({ perk: { ...form.getFieldValue('perk'), ...patch } });

  const pickType = (t: DropType) => {
    if (editing) return;
    const prevRules = form.getFieldValue(['perk', 'rules']);
    form.setFieldsValue({ type: t, radius_m: DEFAULT_RADIUS[t] });
    if (prevRules === RULES_DEFAULT || prevRules === RULES_STRONGHOLD) setPerk({ rules: t === 'stronghold' ? RULES_STRONGHOLD : RULES_DEFAULT });
    if (t !== 'stronghold' && form.getFieldValue('venue_id')) form.setFieldsValue({ venue_id: undefined, place: '' });
  };

  const goto = async (to: number) => {
    if (to > step) {
      try {
        for (let s = step; s < to; s++) await form.validateFields(STEPS[s].fields as unknown as string[]);
      } catch {
        return;
      }
    }
    setStep(to);
  };

  const submit = async () => {
    try {
      await form.validateFields();
    } catch (e) {
      // jump to the first step with an error
      const errs = (e as { errorFields?: { name: (string | number)[] }[] }).errorFields ?? [];
      const first = STEPS.findIndex((s) => errs.some((f) => (s.fields as readonly unknown[]).some((n) => JSON.stringify(Array.isArray(n) ? n : [n]) === JSON.stringify(f.name))));
      if (first >= 0) setStep(first);
      return;
    }
    const v = form.getFieldsValue(true) as FormValues;
    const t = v.type;
    save.mutate({
      merchant_id: v.merchant_id,
      campaign_id: v.campaign_id ?? null,
      type: t,
      name: `${DROP_TYPE[t].label} · ${v.place.trim()}`,
      center: t === 'stronghold' ? null : { lat: v.lat!, lng: v.lng! },
      radius_m: t === 'stronghold' ? venue?.checkin_radius_m ?? DEFAULT_RADIUS.stronghold : v.radius_m,
      venue_id: t === 'stronghold' ? v.venue_id ?? null : null,
      perk: {
        title: v.perk.title.trim(),
        value_text: v.perk.value_text.trim(),
        description: (v.perk.description ?? '').trim(),
        valid_days: v.perk.valid_days,
        rules: v.perk.rules.trim(),
      },
      daily_cap: v.daily_cap,
      start_time: v.range[0].second(0).millisecond(0).format(),
      end_time: v.range[1].second(0).millisecond(0).format(),
      settle_price_amt: toFen(v.settle_price),
      settle_direction: v.settle_direction,
    });
  };

  const presets = [
    { label: '7 天', value: [dayjs().startOf('minute'), dayjs().add(7, 'day').endOf('day').second(0)] as [Dayjs, Dayjs] },
    { label: '30 天', value: [dayjs().startOf('minute'), dayjs().add(30, 'day').endOf('day').second(0)] as [Dayjs, Dayjs] },
    { label: '90 天', value: [dayjs().startOf('minute'), dayjs().add(90, 'day').endOf('day').second(0)] as [Dayjs, Dayjs] },
    ...(campaign ? [{ label: '跟联名活动一致', value: [dayjs(campaign.start_time), dayjs(campaign.end_time)] as [Dayjs, Dayjs] }] : []),
  ];

  const settleText =
    typeof settlePrice === 'number' && direction
      ? settlePrice > 0
        ? `每张有效核销 ${direction === 'merchant_pays' ? '商户付平台' : '平台补贴商户'} ¥${settlePrice.toFixed(2)}；按日上限满额核销，每天最多 ¥${num((settlePrice * (dailyCap ?? 0)), 2)}`
        : '结算单价为 0：只发券，不产生结算金额'
      : '';

  const shown = (i: number) => ({ display: step === i ? undefined : 'none' });
  const merchantName = merchant?.name ?? editing?.merchant.name;

  return (
    <Drawer
      open={open}
      onClose={onClose}
      width={1080}
      forceRender
      title={editing ? `编辑投放 · ${editing.name}` : '新建投放'}
      footer={
        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
          <span className="muted" style={{ fontSize: 12, alignSelf: 'center' }}>
            {editing ? '修改后立即生效；已发出的券按领取时的权益和有效期使用' : `第 ${step + 1} / ${STEPS.length} 步`}
          </span>
          <Space>
            <Button onClick={onClose}>取消</Button>
            {step > 0 && <Button onClick={() => setStep(step - 1)}>上一步</Button>}
            {step < STEPS.length - 1 && (
              <Button type={editing ? 'default' : 'primary'} onClick={() => goto(step + 1)}>
                下一步
              </Button>
            )}
            {(editing || step === STEPS.length - 1) && (
              <Button type="primary" loading={save.isPending} onClick={submit}>
                {editing ? '保存' : '创建投放'}
              </Button>
            )}
          </Space>
        </div>
      }
    >
      <Steps size="small" current={step} onChange={(s) => goto(s)} items={STEPS.map((s) => ({ title: s.title }))} style={{ marginBottom: 20 }} />
      <div className="wizard-grid">
        <Form<FormValues> form={form} layout="vertical" requiredMark={false} preserve>
          {/* ---- 1 类型与商户 ---- */}
          <div style={shown(0)}>
            <Form.Item name="type" hidden>
              <Input />
            </Form.Item>
            <Form.Item label="投放类型" required extra={editing ? '类型创建后不能修改' : undefined}>
              <div className="type-cards" role="radiogroup" aria-label="投放类型">
                {DROP_TYPES.map((t) => (
                  <button
                    key={t}
                    type="button"
                    role="radio"
                    aria-checked={type === t}
                    className={`type-card${type === t ? ' on' : ''}`}
                    disabled={!!editing && type !== t}
                    onClick={() => pickType(t)}
                  >
                    <span className="type-name">
                      <DropTypeBadge type={t} size={28} /> {DROP_TYPE[t].label}
                    </span>
                    <span className="muted">{DROP_TYPE[t].how}</span>
                  </button>
                ))}
              </div>
            </Form.Item>
            <Row gutter={12}>
              <Col xs={24} md={12}>
                <Form.Item name="merchant_id" label="商户" rules={[{ required: true, message: '请选择商户' }]} extra={editing ? '商户创建后不能修改' : '只有「合作中」的商户可以新建投放'}>
                  <Select
                    showSearch
                    optionFilterProp="label"
                    placeholder="选择合作商户"
                    loading={merchants.isLoading}
                    disabled={!!editing}
                    onChange={() => form.setFieldsValue({ campaign_id: null, venue_id: undefined })}
                    options={(merchants.data?.items ?? []).map((m) => ({
                      value: m.id,
                      label: m.name,
                      disabled: m.status !== 'partner',
                      title: m.status !== 'partner' ? MERCHANT_STATUS[m.status as keyof typeof MERCHANT_STATUS]?.text : undefined,
                    }))}
                    optionRender={(o) => {
                      const m = merchants.data?.items.find((x) => x.id === o.value);
                      return (
                        <span style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
                          {o.label}
                          {m && m.status !== 'partner' && <span className="muted">{MERCHANT_STATUS[m.status as keyof typeof MERCHANT_STATUS]?.text ?? m.status}</span>}
                        </span>
                      );
                    }}
                  />
                </Form.Item>
              </Col>
              <Col xs={24} md={12}>
                <Form.Item name="campaign_id" label="联名活动（可选）" extra="挂在活动下的投放跟随活动状态：暂停活动 = 暂停其下所有投放">
                  <Select
                    allowClear
                    placeholder={merchantId ? (merchantCampaigns.length ? '不挂活动' : '这个商户没有未结束的联名活动') : '先选商户'}
                    disabled={!merchantId}
                    onClear={() => form.setFieldsValue({ campaign_id: null })}
                    options={merchantCampaigns.map((c) => ({ value: c.id, label: `${c.title}（${CAMPAIGN_STATUS[c.status].text}）` }))}
                  />
                </Form.Item>
              </Col>
            </Row>
            <Alert type="info" showIcon message={`${DROP_TYPE[type].label}：${DROP_TYPE[type].short}`} />
          </div>

          {/* ---- 2 位置 ---- */}
          <div style={shown(1)}>
            {type === 'stronghold' ? (
              <>
                <Form.Item name="venue_id" label="绑定场馆" rules={[{ required: type === 'stronghold', message: '据点需要绑定一个场馆' }]} extra="用户在这个场馆签到（定位或扫场馆二维码）即得券，签到范围沿用场馆设置">
                  <Select
                    placeholder={merchantId ? '选择场馆' : '先在第 1 步选商户'}
                    loading={venues.isLoading}
                    disabled={!merchantId}
                    notFoundContent={
                      <Empty
                        image={Empty.PRESENTED_IMAGE_SIMPLE}
                        description={
                          <span>
                            这个商户还没有场馆，先去 <Link to="/merchant/venues">场馆</Link> 录入
                          </span>
                        }
                      />
                    }
                    options={(venues.data?.items ?? []).map((v) => ({ value: v.id, label: v.name }))}
                    optionRender={(o) => {
                      const v = venues.data?.items.find((x) => x.id === o.value);
                      return (
                        <div>
                          {o.label}
                          {v && <div className="muted" style={{ fontSize: 12 }}>{[v.district, v.address].filter(Boolean).join(' · ')}</div>}
                        </div>
                      );
                    }}
                  />
                </Form.Item>
                <Form.Item name="place" hidden rules={[{ required: true, message: '请选择场馆' }]}>
                  <Input />
                </Form.Item>
                {venue && (
                  <div className="muted" style={{ fontSize: 12, marginBottom: 8 }}>
                    {venue.address ?? '—'} · 签到半径 <span className="num">{venue.checkin_radius_m ?? DEFAULT_RADIUS.stronghold}</span> m
                  </div>
                )}
              </>
            ) : (
              <>
                <Form.Item name="place" label="地点名称" rules={[{ required: true, whitespace: true, message: '请填写地点，如「滨江大道 · 东昌路口」' }, { max: 24, message: '最多 24 字' }]} extra={`App 显示为「${DROP_TYPE[type].label} · ${place?.trim() || '地点名称'}」`}>
                  <Input maxLength={24} placeholder="滨江大道 · 东昌路口" />
                </Form.Item>
                <div className="muted" style={{ fontSize: 12, margin: '-4px 0 8px' }}>
                  <AimOutlined /> 在地图上点击选点，或直接填坐标（GCJ-02）
                </div>
                <Row gutter={8}>
                  <Col span={8}>
                    <Form.Item name="lat" label="纬度 lat" rules={[{ required: true, message: '请选点或填写' }]}>
                      <InputNumber className="num" min={-90} max={90} step={0.0005} precision={6} style={{ width: '100%' }} placeholder="31.233800" />
                    </Form.Item>
                  </Col>
                  <Col span={8}>
                    <Form.Item name="lng" label="经度 lng" rules={[{ required: true, message: '请选点或填写' }]}>
                      <InputNumber className="num" min={-180} max={180} step={0.0005} precision={6} style={{ width: '100%' }} placeholder="121.507800" />
                    </Form.Item>
                  </Col>
                  <Col span={8}>
                    <Form.Item name="radius_m" label="半径" rules={[{ required: true, message: '请填写半径' }]} extra={type === 'supply' ? '轨迹经过这个圆即领取' : '靠近到这个范围内可开启'}>
                      <InputNumber className="num" min={20} max={500} step={10} suffix="m" style={{ width: '100%' }} />
                    </Form.Item>
                  </Col>
                </Row>
              </>
            )}
            <div className="drop-map race-place">
              {step === 1 && (
                <SvgMap
                  items={geo.data?.items ?? []}
                  selectedId={null}
                  onSelect={() => undefined}
                  focus={null}
                  objects={{
                    bosses: [],
                    chests: others.filter((d) => d.type === 'chest').map((d) => ({ id: d.id, center: d.center, radius_m: d.radius_m, expires_at: d.end_time })),
                    checkpoints: point ? [{ route_id: 0, index: 0, name: place?.trim() || DROP_TYPE[type].label, center: point, radius_m: shownRadius }] : [],
                    supplies: others.filter((d) => d.type === 'supply').map((d) => ({ id: d.id, name: d.name, center: d.center, radius_m: d.radius_m, perk_title: d.perk.title })),
                  }}
                  layers={{ territories: true, bosses: false, chests: true, checkpoints: true, supplies: true }}
                  fallbackCenter={DEFAULT_CENTER}
                  checkpointLabel="本次投放"
                  preview
                  picking={type !== 'stronghold'}
                  onPick={(p) => form.setFieldsValue({ lat: +p.lat.toFixed(6), lng: +p.lng.toFixed(6) })}
                />
              )}
            </div>
          </div>

          {/* ---- 3 权益 ---- */}
          <div style={shown(2)}>
            <Row gutter={12}>
              <Col xs={24} md={15}>
                <Form.Item name={['perk', 'title']} label="权益标题" rules={[{ required: true, whitespace: true, message: '请填写权益标题' }, { max: 24, message: '最多 24 字' }]}>
                  <Input maxLength={24} showCount placeholder="当日跑满 3 km 送中杯热饮" />
                </Form.Item>
              </Col>
              <Col xs={24} md={9}>
                <Form.Item name={['perk', 'value_text']} label="面值文字" rules={[{ required: true, whitespace: true, message: '如「5 折」「免费」' }, { max: 10, message: '最多 10 字' }]} extra="券左侧的大字">
                  <Input maxLength={10} placeholder="5 折 / 免费 / 减 10 元" />
                </Form.Item>
              </Col>
            </Row>
            <Form.Item name={['perk', 'description']} label="权益说明" rules={[{ max: 60, message: '最多 60 字' }]}>
              <Input maxLength={60} showCount placeholder="限滨江店，每人每天 1 次" />
            </Form.Item>
            <Form.Item name={['perk', 'valid_days']} label="券有效天数（领取后）" rules={[{ required: true, message: '请填写有效天数' }]}>
              <InputNumber className="num" min={1} max={90} suffix="天" style={{ width: 180 }} />
            </Form.Item>
            <Space size={6} style={{ margin: '-14px 0 16px' }}>
              {[3, 7, 14, 30].map((d) => (
                <Tag.CheckableTag key={d} checked={perk.valid_days === d} onChange={() => setPerk({ valid_days: d })}>
                  {d} 天
                </Tag.CheckableTag>
              ))}
            </Space>
            <Form.Item name={['perk', 'rules']} label="使用规则（App 内明示）" rules={[{ required: true, whitespace: true, message: '使用规则必须在 App 内明示' }, { max: 200, message: '最多 200 字' }]}>
              <Input.TextArea rows={3} maxLength={200} showCount />
            </Form.Item>
            <div className="fixed-note">
              <b>不设付费抽取</b>（固定说明，App 券详情里同样展示）：{NO_PAID_DRAW}权益规则与有效期需在 App 内明示。
            </div>
          </div>

          {/* ---- 4 发放与结算 ---- */}
          <div style={shown(3)}>
            <Form.Item label="每日核销上限" required extra="每天最多发出的券数；发完当天不再发，地图上不显示，App 显示「今日已领完」">
              <div className="cap-stepper">
                <Button shape="circle" icon={<MinusOutlined />} aria-label="减少 10" onClick={() => form.setFieldsValue({ daily_cap: Math.max(1, (dailyCap ?? 0) - 10) })} />
                <Form.Item name="daily_cap" noStyle rules={[{ required: true, message: '请填写每日上限' }]}>
                  <InputNumber className="num" min={1} max={100000} aria-label="每日核销上限" />
                </Form.Item>
                <Button shape="circle" icon={<PlusOutlined />} aria-label="增加 10" onClick={() => form.setFieldsValue({ daily_cap: Math.min(100000, (dailyCap ?? 0) + 10) })} />
                <span className="muted">张 / 天</span>
              </div>
            </Form.Item>
            <Form.Item
              name="range"
              label="有效期（投放时间）"
              rules={[
                { required: true, message: '请选择投放时间' },
                {
                  validator: (_, r: [Dayjs, Dayjs] | undefined) =>
                    !r || r[1].isAfter(r[0]) ? (!editing && r && r[1].isBefore(dayjs()) ? Promise.reject(new Error('结束时间已过')) : Promise.resolve()) : Promise.reject(new Error('结束时间需晚于开始时间')),
                },
              ]}
              extra={campaign ? `所属活动 ${dt(campaign.start_time, 'MM-DD')} – ${dt(campaign.end_time, 'MM-DD')}；活动没开始时投放也不发券` : '到开始时间自动发券，到结束时间下线'}
            >
              <DatePicker.RangePicker showTime={{ format: 'HH:mm' }} format={RANGE_FORMAT} presets={presets} style={{ width: '100%', maxWidth: 420 }} />
            </Form.Item>
            <Row gutter={12}>
              <Col xs={24} md={9}>
                <Form.Item name="settle_price" label="结算单价（每张有效核销）" rules={[{ required: true, message: '请填写结算单价' }]}>
                  <InputNumber className="num" min={0} max={1000} step={0.5} precision={2} prefix="¥" style={{ width: '100%' }} />
                </Form.Item>
              </Col>
              <Col xs={24} md={15}>
                <Form.Item name="settle_direction" label="结算方向" rules={[{ required: true }]}>
                  <Radio.Group>
                    {(['merchant_pays', 'platform_pays'] as SettleDirection[]).map((d) => (
                      <Radio key={d} value={d}>
                        {SETTLE_DIRECTION_TEXT[d].text}
                      </Radio>
                    ))}
                  </Radio.Group>
                </Form.Item>
              </Col>
            </Row>
            {settleText && <Alert type="info" showIcon message={settleText} description="每周一生成结算单，风控作废的核销不结算。" />}
          </div>
        </Form>

        <aside className="wizard-side">
          <CouponPreview
            perk={perk}
            merchant={merchantName}
            type={type}
            place={place?.trim()}
            dailyCap={dailyCap}
            until={range?.[1] ? range[1].format('MM 月 DD 日') : undefined}
          />
          <div className="fixed-note">
            <b>{DROP_TYPE[type].label}</b> · {merchantName ?? '未选商户'}
            {campaign && <> · {campaign.title}</>}
            <br />
            {point ? (
              <span className="num">
                {point.lat.toFixed(5)}, {point.lng.toFixed(5)} · 半径 {shownRadius} m
              </span>
            ) : (
              '未选位置'
            )}
          </div>
        </aside>
      </div>
    </Drawer>
  );
}
