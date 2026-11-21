import type { Dayjs } from 'dayjs';
import { dayjs } from '../../utils/format';

export type Phase = 'upcoming' | 'active' | 'ended';

export function phaseOf(starts: string, ends: string, now = Date.now()): Phase {
  if (Date.parse(starts) > now) return 'upcoming';
  if (Date.parse(ends) > now) return 'active';
  return 'ended';
}

export const PHASE_TAG: Record<Phase, { text: string; color: string }> = {
  upcoming: { text: '未开始', color: 'blue' },
  active: { text: '进行中', color: 'green' },
  ended: { text: '已结束', color: 'default' },
};

export const RANGE_FORMAT = 'YYYY-MM-DD HH:mm';

export function toRange(starts: string, ends: string): [Dayjs, Dayjs] {
  return [dayjs(starts), dayjs(ends)];
}

export function fromRange(r: [Dayjs, Dayjs]): { starts_at: string; ends_at: string } {
  return { starts_at: r[0].second(0).millisecond(0).format(), ends_at: r[1].second(0).millisecond(0).format() };
}

export function days(starts: string, ends: string): number {
  return Math.round((Date.parse(ends) - Date.parse(starts)) / 86_400_000);
}
