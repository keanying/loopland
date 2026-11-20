import dayjs from 'dayjs';
import relativeTime from 'dayjs/plugin/relativeTime';
import 'dayjs/locale/zh-cn';

dayjs.extend(relativeTime);
dayjs.locale('zh-cn');

export { dayjs };

/** 1800 → "¥18"，1550 → "¥15.5" */
export function yuan(fen: number | null | undefined): string {
  if (fen === null || fen === undefined) return '—';
  const v = fen / 100;
  return `¥${Number.isInteger(v) ? v.toLocaleString('zh-CN') : v.toLocaleString('zh-CN', { maximumFractionDigits: 2 })}`;
}

/** Big numbers with 万: 48000 → { value: "4.8", unit: "万" } */
export function bigNumber(n: number): { value: string; unit: string } {
  if (Math.abs(n) >= 10000) {
    const v = n / 10000;
    return { value: v.toLocaleString('zh-CN', { maximumFractionDigits: v >= 100 ? 0 : 2 }), unit: '万' };
  }
  return { value: n.toLocaleString('zh-CN', { maximumFractionDigits: 1 }), unit: '' };
}

export function num(n: number | null | undefined, digits = 0): string {
  if (n === null || n === undefined || Number.isNaN(n)) return '—';
  return n.toLocaleString('zh-CN', { maximumFractionDigits: digits, minimumFractionDigits: 0 });
}

export function pct(ratio: number | null | undefined, digits = 1): string {
  if (ratio === null || ratio === undefined || Number.isNaN(ratio)) return '—';
  return `${(ratio * 100).toFixed(digits).replace(/\.0+$/, '')}%`;
}

/** Week-over-week change; null when last week was zero. */
export function change(now: number, before: number): number | null {
  if (!before) return null;
  return (now - before) / before;
}

export function km(m: number | null | undefined, digits = 1): string {
  if (m === null || m === undefined) return '—';
  return `${(m / 1000).toFixed(digits)} km`;
}

export function km2(m2: number | null | undefined, digits = 2): string {
  if (m2 === null || m2 === undefined) return '—';
  return (m2 / 1e6).toFixed(digits);
}

export function area(m2: number | null | undefined): string {
  if (m2 === null || m2 === undefined) return '—';
  if (m2 >= 100000) return `${(m2 / 1e6).toFixed(2)} km²`;
  return `${Math.round(m2).toLocaleString('zh-CN')} m²`;
}

export function dt(s: string | null | undefined, fmt = 'YYYY-MM-DD HH:mm'): string {
  if (!s) return '—';
  const d = dayjs(s);
  return d.isValid() ? d.format(fmt) : s;
}

export function date(s: string | null | undefined): string {
  return dt(s, 'YYYY-MM-DD');
}

export function ago(s: string | null | undefined): string {
  if (!s) return '—';
  const d = dayjs(s);
  return d.isValid() ? d.fromNow() : s;
}

export function duration(s: number | null | undefined): string {
  if (s === null || s === undefined) return '—';
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = Math.floor(s % 60);
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}` : `${m}:${String(sec).padStart(2, '0')}`;
}

export function pace(sPerKm: number | null | undefined): string {
  if (!sPerKm) return '—';
  return `${Math.floor(sPerKm / 60)}'${String(Math.round(sPerKm % 60)).padStart(2, '0')}"`;
}
