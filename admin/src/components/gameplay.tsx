import { BRAND } from '../theme';
import { num } from '../utils/format';
import { bossColor, bossKindName } from '../utils/gameplay';

/** Remaining-HP bar, red when under 25%. */
export function HpBar({ hp, max, width, compact }: { hp: number; max: number; width?: number | string; compact?: boolean }) {
  const ratio = max > 0 ? Math.max(0, Math.min(1, hp / max)) : 0;
  const color = ratio < 0.25 ? BRAND.red : ratio < 0.6 ? '#D99A0B' : BRAND.green;
  return (
    <div style={{ width: width ?? '100%', minWidth: 80 }}>
      <div className="hp-track" style={{ height: compact ? 8 : 12 }}>
        <div className="hp-fill" style={{ width: `${ratio * 100}%`, background: color }} />
      </div>
      <div className="num" style={{ fontSize: 12, marginTop: 2, display: 'flex', justifyContent: 'space-between', gap: 8 }}>
        <span>
          <b>{num(hp)}</b>
          <span className="muted"> / {num(max)}</span>
        </span>
        <span className="muted">{Math.round(ratio * 100)}%</span>
      </div>
    </div>
  );
}

export function BossBadge({ kind, size = 36 }: { kind: string; size?: number }) {
  return (
    <span
      style={{
        width: size,
        height: size,
        borderRadius: size / 3,
        background: bossColor(kind),
        border: '1.5px solid #141414',
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        fontWeight: 800,
        fontSize: size * 0.42,
        flexShrink: 0,
      }}
      aria-hidden="true"
    >
      {bossKindName(kind).slice(0, 1)}
    </span>
  );
}
