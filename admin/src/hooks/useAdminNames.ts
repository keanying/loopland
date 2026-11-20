import { useCallback } from 'react';
import { useQuery } from '@tanstack/react-query';
import { api } from '../api/admin';
import { useAuth } from '../auth/AuthContext';

/**
 * The server refers to back-office accounts by id (territory events, gameplay
 * published_by). Admins can resolve names via /admins; other roles see "#id".
 */
export function useAdminNames(): (who: number | string | { username: string } | null | undefined) => string {
  const { can, admin } = useAuth();
  const q = useQuery({ queryKey: ['admins'], queryFn: api.admins, enabled: can('admins.manage'), staleTime: 60_000 });
  return useCallback(
    (who) => {
      if (who === null || who === undefined) return '系统';
      if (typeof who === 'string') return who;
      if (typeof who === 'object') return who.username;
      if (admin && who === admin.id) return admin.username;
      return q.data?.items.find((a) => a.id === who)?.username ?? `#${who}`;
    },
    [q.data, admin],
  );
}
