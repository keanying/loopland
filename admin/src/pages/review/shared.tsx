// Pieces shared by the 内容审核 tabs: risk badge, image thumbnails with a
// click-to-enlarge preview, a reason dialog with preset reasons, the track sketch.
import { useEffect, useState, type ReactNode } from 'react';
import { Alert, Image, Input, Modal, Tag } from 'antd';
import { BRAND } from '../../theme';
import { REVIEW_TARGET } from '../../utils/labels';
import { previewState } from './preview';
import { Glyph } from '../../components/Glyph';

function riskLevel(score: number): 0 | 1 | 2 | 3 {
  if (score >= 70) return 3;
  if (score >= 50) return 2;
  if (score >= 30) return 1;
  return 0;
}

export function RiskBadge({ score, large }: { score: number; large?: boolean }) {
  const lv = riskLevel(score);
  return (
    <span className={`risk-badge lv${lv}${large ? ' lg' : ''} num`} title="风险分 0–100">
      {lv >= 2 && <Glyph name="warning" size="1em" />}风险 {score}
    </span>
  );
}

export function TargetTag({ type }: { type: string }) {
  const t = REVIEW_TARGET[type];
  return (
    <Tag bordered={false} color={t?.color} style={{ marginInlineEnd: 0 }}>
      {t?.text ?? type}
    </Tag>
  );
}

/** Thumbnails; click one to open a gallery preview of all of them. */
export function Thumbs({ urls, size = 56, max = 4, more = true }: { urls: string[] | null | undefined; size?: number; max?: number; more?: boolean }) {
  const list = urls ?? [];
  if (!list.length) return null;
  const shown = list.slice(0, max);
  return (
    <div className="thumbs" onClick={(e) => e.stopPropagation()} onKeyDown={(e) => e.stopPropagation()}>
      <Image.PreviewGroup
        items={list}
        preview={{
          onVisibleChange: (v) => {
            previewState.open = Math.max(0, previewState.open + (v ? 1 : -1));
          },
        }}
      >
        {shown.map((u, i) => (
          <Image key={i} src={u} width={size} height={size} alt={`图片 ${i + 1}`} />
        ))}
      </Image.PreviewGroup>
      {more && list.length > max && <span className="thumb-more" style={{ width: size, height: size }}>+{list.length - max}</span>}
    </div>
  );
}

/**
 * Asks for a reason: preset chips (single choice) plus free text. The reason sent
 * is "预设" / "预设：补充" / "补充".
 */
export function ReasonModal({
  open,
  title,
  presets,
  okText,
  cancelText = '取消',
  danger = true,
  loading,
  effect,
  required = true,
  extra,
  onCancel,
  onOk,
}: {
  open: boolean;
  title: ReactNode;
  presets: string[];
  okText: string;
  cancelText?: string;
  danger?: boolean;
  loading?: boolean;
  effect?: ReactNode;
  required?: boolean;
  extra?: ReactNode;
  onCancel: () => void;
  onOk: (reason: string) => void;
}) {
  const [preset, setPreset] = useState<string | null>(null);
  const [text, setText] = useState('');
  const [tried, setTried] = useState(false);
  // Reset when opening (not in afterOpenChange: that fires after the animation and would undo a quick click).
  useEffect(() => {
    if (open) {
      setPreset(null);
      setText('');
      setTried(false);
    }
  }, [open]);
  const reason = [preset, text.trim()].filter(Boolean).join('：');
  const missing = required && !reason;
  return (
    <Modal
      open={open}
      title={title}
      okText={okText}
      cancelText={cancelText}
      okButtonProps={{ danger, loading }}
      onCancel={onCancel}
      onOk={() => {
        setTried(true);
        if (!missing) onOk(reason);
      }}
      destroyOnHidden
    >
      {effect && <Alert type="warning" showIcon style={{ marginBottom: 12 }} message={effect} />}
      <div className="muted" style={{ fontSize: 12, marginBottom: 6 }}>
        原因{required ? '（必选或填写其一，会通知作者）' : '（可选）'}
      </div>
      <div className="reason-presets" role="radiogroup" aria-label="预设原因">
        {presets.map((p) => (
          <Tag.CheckableTag key={p} checked={preset === p} onChange={(c) => setPreset(c ? p : null)}>
            {p}
          </Tag.CheckableTag>
        ))}
      </div>
      <Input.TextArea
        rows={3}
        maxLength={160}
        showCount
        placeholder={preset ? '补充说明（可选，Ctrl + Enter 提交）' : '或者直接写原因（Ctrl + Enter 提交）'}
        value={text}
        status={tried && missing ? 'error' : undefined}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
            setTried(true);
            if (!missing) onOk(reason);
          }
        }}
      />
      {tried && missing && (
        <div className="danger-text" style={{ fontSize: 12, marginTop: 4 }}>
          请选择或填写原因
        </div>
      )}
      {reason && (
        <div className="muted" style={{ fontSize: 12, marginTop: 8 }}>
          将发送：{reason}
        </div>
      )}
      {extra}
    </Modal>
  );
}

/** Small SVG sketch of a [lng, lat] track (endpoints already trimmed by the server). */
export function TrackSketch({ track, width = 160, height = 110 }: { track: number[][]; width?: number; height?: number }) {
  if (track.length < 2) return <div className="muted" style={{ width, fontSize: 12 }}>无轨迹</div>;
  const xs = track.map((p) => p[0]);
  const ys = track.map((p) => p[1]);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const k = Math.cos((((minY + maxY) / 2) * Math.PI) / 180);
  const s = Math.min((width - 16) / Math.max((maxX - minX) * k, 1e-9), (height - 16) / Math.max(maxY - minY, 1e-9));
  const ox = (width - (maxX - minX) * k * s) / 2;
  const oy = (height - (maxY - minY) * s) / 2;
  const d = track.map(([lng, lat], i) => `${i ? 'L' : 'M'}${(ox + (lng - minX) * k * s).toFixed(1)} ${(oy + (maxY - lat) * s).toFixed(1)}`).join(' ');
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} role="img" aria-label="轨迹缩略图" style={{ flexShrink: 0, background: '#fff', borderRadius: 12 }}>
      <path d={d} fill="none" stroke={BRAND.ink} strokeWidth={2.4} strokeLinejoin="round" strokeLinecap="round" />
    </svg>
  );
}

/** "#7 阿梅" style user line. */
export function UserLine({ user }: { user: { id: number; nickname: string } }) {
  return (
    <span>
      {user.nickname} <span className="muted num">#{user.id}</span>
    </span>
  );
}
