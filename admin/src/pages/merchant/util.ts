import { useQuery } from '@tanstack/react-query';
import { merchantApi } from '../../api/merchant';

export const IMAGE_URL = /^(https?:\/\/|\/|data:image\/)/;

/** Merchant options for selects (admin / ops). */
export function useMerchantOptions(enabled = true) {
  const q = useQuery({ queryKey: ['merchants', 'options'], queryFn: () => merchantApi.merchants({ page_size: 100 }), enabled, staleTime: 60_000 });
  return { ...q, options: (q.data?.items ?? []).map((m) => ({ value: m.id, label: m.name, status: m.status })) };
}

/** The signed-in merchant account's own venues (GET /venues is scoped server-side for merchant accounts). */
export function useOwnVenues(enabled = true) {
  const q = useQuery({ queryKey: ['venues', 'mine'], queryFn: () => merchantApi.venues({ page_size: 100 }), enabled, staleTime: 60_000 });
  return { ...q, venues: q.data?.items ?? [], options: (q.data?.items ?? []).map((v) => ({ value: v.id, label: v.name })) };
}

/** ¥ input (yuan, 2 decimals) ⇄ fen. */
export const toFen = (yuan: number | null | undefined): number | null => (yuan === null || yuan === undefined ? null : Math.round(yuan * 100));
export const toYuan = (fen: number | null | undefined): number | null => (fen === null || fen === undefined ? null : fen / 100);

/** 0.8 → 八折, 0.85 → 8.5 折 */
export function discountText(rate: number | null | undefined): string {
  if (rate === null || rate === undefined) return '无折扣';
  const z = +(rate * 10).toFixed(1);
  const cn = ['', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
  return Number.isInteger(z) ? `${cn[z]}折` : `${z} 折`;
}

export function urlParams(params: URLSearchParams, setParams: (p: URLSearchParams, o?: { replace?: boolean }) => void) {
  return (patch: Record<string, string | number | null | undefined>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null || v === undefined || v === '') next.delete(k);
      else next.set(k, String(v));
    }
    setParams(next, { replace: true });
  };
}
