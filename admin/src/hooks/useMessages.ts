// V2 第六批 · 站内信 queries shared by the header bell and the /messages page.
import { useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '../api/admin';
import type { AdminMessage, MessageCategory } from '../api/types';
import { useAuth } from '../auth/AuthContext';

export const MESSAGES_KEY = ['messages'] as const;

/**
 * Unread count for the bell: polled every 30 s. TanStack pauses interval refetches while the tab is hidden
 * (refetchIntervalInBackground: false) and refetches when the window gets focus again.
 */
export function useUnreadCount() {
  const { admin } = useAuth();
  return useQuery({
    queryKey: [...MESSAGES_KEY, 'unread-count', admin?.id],
    queryFn: api.unreadCount,
    enabled: !!admin,
    refetchInterval: 30_000,
    refetchIntervalInBackground: false,
    refetchOnWindowFocus: 'always',
    staleTime: 10_000,
    // A failing poll should not toast every 30 s; the next poll retries.
    meta: { silent: true },
  });
}

/** Mark-one / mark-all mutations; both refresh every message query (bell, panel, page). */
export function useMessageActions() {
  const qc = useQueryClient();
  const refresh = useCallback(() => qc.invalidateQueries({ queryKey: MESSAGES_KEY }), [qc]);
  const read = useMutation({
    mutationFn: (id: number) => api.readMessage(id),
    onSuccess: refresh,
  });
  const readAll = useMutation({
    mutationFn: (category?: MessageCategory | '') => api.readAllMessages(category),
    onSuccess: refresh,
  });
  return { read, readAll, refresh };
}

/** Click on a message: mark it read (if unread) and open its link. */
export function useOpenMessage(after?: () => void) {
  const navigate = useNavigate();
  const { read } = useMessageActions();
  return (m: AdminMessage) => {
    if (!m.is_read) read.mutate(m.id);
    after?.();
    const link = m.link?.trim();
    if (!link) return;
    if (/^https?:\/\//.test(link)) window.open(link, '_blank', 'noopener');
    else navigate(link);
  };
}
