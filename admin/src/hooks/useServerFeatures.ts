import { useQuery } from '@tanstack/react-query';
import { http } from '../api/client';

/**
 * 穿戴设备数据的预留口子（服务端 features.wearable，默认关闭，见 docs/设备接入预留.md）。
 * 关着时管理端不出现「要求穿戴设备数据」等用不上的选项；读不到（假数据模式、旧后端）按关闭处理。
 */
export function useWearableEnabled(): boolean {
  const q = useQuery({
    queryKey: ['server-features'],
    queryFn: () => http.get<{ wearable?: boolean }>('/v1/config/features').catch(() => ({}) as { wearable?: boolean }),
    staleTime: 5 * 60_000,
    meta: { silent: true },
  });
  return q.data?.wearable === true;
}
