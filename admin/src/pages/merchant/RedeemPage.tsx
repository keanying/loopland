import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { IScannerControls } from '@zxing/browser';
import dayjs from 'dayjs';
import { Alert, Button, Collapse, Empty, Input, Space, Tag } from 'antd';
import { CameraOutlined, CheckCircleFilled, CloseCircleFilled, ExclamationCircleFilled, ReloadOutlined, StopOutlined } from '@ant-design/icons';
import { ApiError } from '../../api/client';
import { merchantApi, type RedeemBody, type Redemption } from '../../api/merchant';
import { useAuth } from '../../auth/AuthContext';
import { MOCK } from '../../config';
import { PageHeader } from '../../components/ui';
import { REDEEM_ERROR } from './labels';
import { MerchantNav } from './nav';

type Outcome = { ok: true; redemption: Redemption } | { ok: false; code: string; title: string; message: string; hint: string; status: number };

/** Mock-mode test codes (src/mocks/merchant.ts); never shown against a real backend. */
const MOCK_CODES: { code: string; expect: string; payload?: number }[] = [
  { code: '8K2D9QXW', expect: '可核销', payload: 77 },
  { code: 'P2X7MNQR', expect: '可核销', payload: 83 },
  { code: '7HM3QPLA', expect: '已核销过' },
  { code: '5RT8WXYZ', expect: '已过期' },
  { code: '3NB6KDFE', expect: '今天没运动' },
  { code: '6LK4JHGF', expect: '其他商户的券' },
];

/** What the staff typed or the camera read → request body. QR content is LPC.<id>.<ts>.<sig> (or a link ending in it). */
function toBody(raw: string): RedeemBody | null {
  const text = raw.trim();
  if (!text) return null;
  const m = /(LPC\.[A-Za-z0-9._-]+)$/.exec(text);
  if (m) return { payload: m[1] };
  return { code: text.toUpperCase().replace(/[\s-]/g, '') };
}

function outcomeOf(err: unknown): Outcome {
  if (err instanceof ApiError) {
    const known = REDEEM_ERROR[err.code];
    return { ok: false, code: err.code, status: err.status, title: known?.title ?? '核销失败', message: err.message, hint: known?.hint ?? '请稍后重试，或联系运营' };
  }
  return { ok: false, code: 'unknown', status: 0, title: '核销失败', message: err instanceof Error ? err.message : '未知错误', hint: '请稍后重试' };
}

function cameraError(e: unknown): string {
  const name = e instanceof DOMException || e instanceof Error ? e.name : '';
  if (name === 'NotAllowedError' || name === 'SecurityError') return '没有相机权限：请在浏览器地址栏允许使用相机，或改用下面的手输券码';
  if (name === 'NotFoundError' || name === 'OverconstrainedError') return '没有找到可用的摄像头，请改用手输券码';
  if (name === 'NotReadableError') return '摄像头被其他应用占用，关掉后重试';
  return `打开相机失败${e instanceof Error && e.message ? `：${e.message}` : ''}`;
}

export default function RedeemPage() {
  const { admin } = useAuth();
  const staff = admin?.role === 'merchant';
  const qc = useQueryClient();
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const controls = useRef<IScannerControls | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const [scanning, setScanning] = useState(false);
  const [starting, setStarting] = useState(false);
  const [camError, setCamError] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const [outcome, setOutcome] = useState<Outcome | null>(null);

  const own = useQuery({ queryKey: ['merchants', 'detail', admin?.merchant_id], queryFn: () => merchantApi.merchant(admin!.merchant_id!), enabled: staff && !!admin?.merchant_id, staleTime: 5 * 60_000 });
  const today = dayjs().format('YYYY-MM-DD');
  const recent = useQuery({ queryKey: ['redemptions', 'recent', today], queryFn: () => merchantApi.redemptions({ from: today, to: today, page_size: 10 }), refetchInterval: 30_000 });

  const stopCamera = useCallback(() => {
    controls.current?.stop();
    controls.current = null;
    setScanning(false);
  }, []);
  useEffect(() => stopCamera, [stopCamera]);

  const redeem = useMutation({
    mutationFn: (body: RedeemBody) => merchantApi.redeem(body),
    meta: { inlineError: true },
    onSuccess: (r) => {
      setOutcome({ ok: true, redemption: r.redemption });
      setCode('');
      navigator.vibrate?.(60);
      qc.invalidateQueries({ queryKey: ['redemptions'] });
      qc.invalidateQueries({ queryKey: ['settlement'] });
    },
    onError: (e) => {
      setOutcome(outcomeOf(e));
      navigator.vibrate?.([40, 60, 40]);
    },
  });

  const submit = (raw: string) => {
    const body = toBody(raw);
    if (!body || redeem.isPending) return;
    setOutcome(null);
    redeem.mutate(body);
  };

  const startCamera = async () => {
    setCamError(null);
    setOutcome(null);
    if (!navigator.mediaDevices?.getUserMedia) {
      setCamError(window.isSecureContext ? '这个浏览器不支持调用相机，请改用手输券码' : '需要 HTTPS 才能使用相机（或用 localhost 访问），请改用手输券码');
      return;
    }
    setStarting(true);
    try {
      const { BrowserQRCodeReader } = await import('@zxing/browser');
      const reader = new BrowserQRCodeReader(undefined, { delayBetweenScanAttempts: 150 });
      setScanning(true);
      controls.current = await reader.decodeFromConstraints({ video: { facingMode: { ideal: 'environment' } } }, videoRef.current ?? undefined, (result, _err, c) => {
        if (!result) return;
        c.stop();
        controls.current = null;
        setScanning(false);
        const text = result.getText();
        if (!/LPC\.[A-Za-z0-9._-]+$/.test(text.trim())) {
          setOutcome({ ok: false, code: 'invalid_coupon', status: 400, title: '不是圈圈的券码', message: `扫到的内容：${text.slice(0, 60)}`, hint: '请让顾客在圈圈 App「我的卡券」里打开这张券的二维码' });
          return;
        }
        submit(text);
      });
    } catch (e) {
      setScanning(false);
      controls.current = null;
      setCamError(cameraError(e));
    } finally {
      setStarting(false);
    }
  };

  const again = () => {
    setOutcome(null);
    setTimeout(() => inputRef.current?.focus(), 0);
  };

  const items = recent.data?.items ?? [];

  return (
    <div className="redeem-page">
      <PageHeader title="核销台" sub={staff ? own.data?.name ?? '本店' : '运营代核销：可以核销任意商户的券'} extra={<MerchantNav />} />

      <div className="redeem-grid">
        <section className="redeem-card">
          {outcome && <ResultView outcome={outcome} onAgain={again} onScan={startCamera} />}
          {/* Always mounted: the camera attaches to this <video> right after a result is dismissed. */}
          <div className="redeem-scan" hidden={!!outcome}>
              <div className={`redeem-video${scanning ? ' on' : ''}`}>
                <video ref={videoRef} muted playsInline aria-label="相机取景" />
                {scanning ? (
                  <div className="redeem-frame" aria-hidden />
                ) : (
                  <div className="redeem-video-idle">
                    <CameraOutlined style={{ fontSize: 36 }} />
                    <div>扫顾客 App 里的券二维码</div>
                    <div className="muted" style={{ fontSize: 12 }}>二维码 60 秒刷新一次，截图无效</div>
                  </div>
                )}
              </div>
              {scanning ? (
                <Button block size="large" icon={<StopOutlined />} onClick={stopCamera}>
                  关闭相机
                </Button>
              ) : (
                <Button block size="large" type="primary" icon={<CameraOutlined />} loading={starting} onClick={startCamera}>
                  扫码核销
                </Button>
              )}
              {camError && <Alert type="warning" showIcon message={camError} />}
              {redeem.isPending && <Alert type="info" showIcon message="正在核销…" />}
          </div>

          <div className="redeem-manual">
            <div className="redeem-label">或手输券码</div>
            <Space.Compact style={{ width: '100%' }}>
              <Input
                ref={(el) => {
                  inputRef.current = el?.input ?? null;
                }}
                size="large"
                className="num redeem-input"
                placeholder="8 位券码，如 8K2D9QXW"
                value={code}
                maxLength={120}
                autoComplete="off"
                autoCapitalize="characters"
                spellCheck={false}
                enterKeyHint="done"
                onChange={(e) => setCode(e.target.value)}
                onPressEnter={() => submit(code)}
                aria-label="券码"
              />
              <Button size="large" type="primary" disabled={!code.trim()} loading={redeem.isPending} onClick={() => submit(code)}>
                核销
              </Button>
            </Space.Compact>
            <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>
              手输券码不校验二维码时效；扫码枪扫出的内容直接回车也可以。核销需要顾客当天有一条运动记录。
            </div>
          </div>

          {MOCK && (
            <Collapse
              size="small"
              ghost
              items={[
                {
                  key: 'mock',
                  label: <span className="muted">假数据模式 · 测试券码</span>,
                  children: (
                    <Space size={[6, 6]} wrap>
                      {MOCK_CODES.map((c) => (
                        <Tag key={c.code} className="num" style={{ cursor: 'pointer' }} onClick={() => setCode(c.code)}>
                          {c.code} · {c.expect}
                        </Tag>
                      ))}
                      <Tag
                        color="purple"
                        style={{ cursor: 'pointer' }}
                        onClick={() => setCode(`LPC.77.${Math.floor(Date.now() / 1000)}.mockSig`)}
                      >
                        模拟扫码内容（60 秒内有效）
                      </Tag>
                    </Space>
                  ),
                },
              ]}
            />
          )}
        </section>

        <section className="redeem-card">
          <div className="mer-h3-row">
            <h3 className="mer-h3">今天的核销 · {recent.data?.total ?? 0}</h3>
            <Link to="/merchant/redemptions">全部记录</Link>
          </div>
          {items.length === 0 ? (
            <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description={recent.isLoading ? '加载中' : '今天还没有核销'} />
          ) : (
            <ul className="redeem-list">
              {items.map((r) => (
                <li key={r.id} className={r.voided ? 'voided' : ''}>
                  <span className="num redeem-time">{dayjs(r.created_at).format('HH:mm')}</span>
                  <span className="redeem-what">
                    <b>{r.coupon.perk.title}</b>
                    <span className="muted">
                      {r.user.nickname} · <span className="num">{r.coupon.code}</span>
                      {!staff && ` · ${r.coupon.merchant.name}`}
                    </span>
                  </span>
                  {r.voided && <Tag color="error" bordered={false}>作废</Tag>}
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </div>
  );
}

function ResultView({ outcome, onAgain, onScan }: { outcome: Outcome; onAgain: () => void; onScan: () => void }) {
  if (outcome.ok) {
    const r = outcome.redemption;
    return (
      <div className="redeem-result ok" role="status">
        <CheckCircleFilled className="redeem-icon" />
        <div className="redeem-title">核销成功</div>
        <div className="redeem-perk">{r.coupon.perk.title}</div>
        <div className="redeem-meta">
          <span>{r.user.nickname}</span>
          <span className="num">{r.coupon.code}</span>
          {r.store && <span>{r.store}</span>}
          <span className="num">{dayjs(r.created_at).format('HH:mm:ss')}</span>
        </div>
        {r.coupon.perk.description && <div className="muted" style={{ fontSize: 13 }}>{r.coupon.perk.description}</div>}
        <Space style={{ marginTop: 8 }} wrap>
          <Button size="large" type="primary" icon={<CameraOutlined />} onClick={onScan}>
            继续扫码
          </Button>
          <Button size="large" icon={<ReloadOutlined />} onClick={onAgain}>
            手输下一张
          </Button>
        </Space>
      </div>
    );
  }
  const warn = outcome.code === 'no_activity_today' || outcome.code === 'daily_cap_reached';
  return (
    <div className={`redeem-result ${warn ? 'warn' : 'err'}`} role="alert">
      {warn ? <ExclamationCircleFilled className="redeem-icon" /> : <CloseCircleFilled className="redeem-icon" />}
      <div className="redeem-title">{outcome.title}</div>
      {outcome.message && !outcome.message.startsWith(outcome.title) && <div className="redeem-perk">{outcome.message}</div>}
      <div className="muted" style={{ fontSize: 13 }}>{outcome.hint}</div>
      <Space style={{ marginTop: 8 }} wrap>
        <Button size="large" type="primary" icon={<CameraOutlined />} onClick={onScan}>
          重新扫码
        </Button>
        <Button size="large" icon={<ReloadOutlined />} onClick={onAgain}>
          手输券码
        </Button>
      </Space>
    </div>
  );
}
