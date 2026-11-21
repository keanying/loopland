import { BOSS_KIND } from './labels';
import { BRAND } from '../theme';
import { dayjs } from './format';

export function bossKindName(kind: string, fallback?: string): string {
  return BOSS_KIND[kind]?.name ?? fallback ?? kind;
}

export function bossColor(kind: string): string {
  return BOSS_KIND[kind]?.color ?? BRAND.lavender;
}

/** "还剩 5 小时 12 分" / "已结束". */
export function timeLeft(until: string | null | undefined): string {
  if (!until) return '—';
  const ms = dayjs(until).diff(dayjs());
  if (ms <= 0) return '已结束';
  const h = Math.floor(ms / 3_600_000);
  const m = Math.floor((ms % 3_600_000) / 60_000);
  if (h >= 48) return `还剩 ${Math.floor(h / 24)} 天 ${h % 24} 小时`;
  return h ? `还剩 ${h} 小时 ${m} 分` : `还剩 ${m} 分钟`;
}

/** 360 → "6:00" */
export function mmss(s: number | null | undefined): string {
  if (s === null || s === undefined || !Number.isFinite(s)) return '—';
  return `${Math.floor(s / 60)}:${String(Math.round(s % 60)).padStart(2, '0')}`;
}

/** "6:00" / "6'00" / "6" → 360; null when unparseable. */
export function parseMmss(v: string): number | null {
  const m = /^\s*(\d{1,2})\s*(?:[:'：]\s*(\d{1,2}))?\s*"?\s*$/.exec(v);
  if (!m) return null;
  const sec = m[2] === undefined ? 0 : Number(m[2]);
  if (sec >= 60) return null;
  return Number(m[1]) * 60 + sec;
}
