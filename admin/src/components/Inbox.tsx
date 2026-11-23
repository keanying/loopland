// V2 第六批 · 站内信: the bell next to the user chip (every page, via PageHeader) and its dropdown panel with the
// latest 8 messages. The full list is the /messages page (pages/MessagesPage.tsx).
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Button, Popover, Segmented, Spin, Tooltip } from 'antd';
import { api } from '../api/admin';
import type { AdminMessage } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import { MESSAGES_KEY, useMessageActions, useOpenMessage, useUnreadCount } from '../hooks/useMessages';
import { ago, dt } from '../utils/format';
import { MESSAGE_CATEGORY, MESSAGE_LEVEL } from '../utils/labels';
import { CategoryIcon, DoodleInbox, IconArrowRight, IconBell, IconCheckAll } from './icons';

const LATEST = 8;

function badgeText(n: number): string {
  return n > 99 ? '99+' : String(n);
}

/** One row of a message list (panel and page share the look). */
export function MessageRow({ m, onOpen, compact }: { m: AdminMessage; onOpen: (m: AdminMessage) => void; compact?: boolean }) {
  const level = MESSAGE_LEVEL[m.level] ?? MESSAGE_LEVEL.info;
  return (
    <button type="button" className={'msg-row' + (m.is_read ? '' : ' unread') + (compact ? ' compact' : '')} onClick={() => onOpen(m)}>
      <span className="msg-icon" style={{ color: level.color, background: level.bg }}>
        <CategoryIcon category={m.category} size={compact ? 18 : 20} />
      </span>
      <span className="msg-main">
        <span className="msg-title">{m.title}</span>
        {m.body && <span className="msg-body">{m.body}</span>}
        <span className="msg-meta">
          {MESSAGE_CATEGORY[m.category] ?? m.category}
          <span aria-hidden="true"> · </span>
          <Tooltip title={dt(m.created_at, 'YYYY-MM-DD HH:mm:ss')}>
            <span>{ago(m.created_at)}</span>
          </Tooltip>
        </span>
      </span>
      {!m.is_read && <span className="msg-dot" aria-label="未读" />}
    </button>
  );
}

export function EmptyMessages({ unreadOnly, small }: { unreadOnly: boolean; small?: boolean }) {
  return (
    <div className={'msg-empty' + (small ? ' small' : '')}>
      <DoodleInbox width={small ? 150 : 200} />
      <div className="msg-empty-title">{unreadOnly ? '没有未读消息' : '还没有消息'}</div>
      <div className="muted">{unreadOnly ? '新的通知会出现在这里' : '审核结果、活动邀请、结算单等通知会出现在这里'}</div>
    </div>
  );
}

function Panel({ onClose }: { onClose: () => void }) {
  const navigate = useNavigate();
  const [unreadOnly, setUnreadOnly] = useState(false);
  const unread = useUnreadCount();
  const count = unread.data?.count ?? 0;
  const latest = useQuery({
    queryKey: [...MESSAGES_KEY, 'latest', unreadOnly],
    queryFn: () => api.messages({ unread: unreadOnly, page: 1, page_size: LATEST }),
    refetchOnMount: 'always',
  });
  const { readAll } = useMessageActions();
  const open = useOpenMessage(onClose);
  const items = latest.data?.items ?? [];

  return (
    <div className="inbox-panel" role="dialog" aria-label="消息">
      <div className="inbox-head">
        <span className="inbox-title">消息</span>
        <Segmented
          size="small"
          value={unreadOnly ? 'unread' : 'all'}
          onChange={(v) => setUnreadOnly(v === 'unread')}
          options={[
            { value: 'all', label: '全部' },
            { value: 'unread', label: `未读${count ? ` ${badgeText(count)}` : ''}` },
          ]}
        />
        <span style={{ flex: 1 }} />
        <Button size="small" type="text" className="inbox-readall" icon={<IconCheckAll size={16} />} disabled={!count} loading={readAll.isPending} onClick={() => readAll.mutate('')}>
          全部已读
        </Button>
      </div>
      <div className="inbox-list">
        {latest.isLoading ? (
          <div className="inbox-loading">
            <Spin />
          </div>
        ) : items.length ? (
          items.map((m) => <MessageRow key={m.id} m={m} onOpen={open} compact />)
        ) : (
          <EmptyMessages unreadOnly={unreadOnly} small />
        )}
      </div>
      <button
        type="button"
        className="inbox-foot"
        onClick={() => {
          onClose();
          navigate(unreadOnly ? '/messages?unread=true' : '/messages');
        }}
      >
        查看全部 <IconArrowRight size={16} />
      </button>
    </div>
  );
}

/** Round grey bell button (原型 A1_总览) with the unread count. */
export function InboxBell() {
  const { admin } = useAuth();
  const [open, setOpen] = useState(false);
  const unread = useUnreadCount();
  if (!admin) return null;
  const n = unread.data?.count ?? 0;
  return (
    <Popover open={open} onOpenChange={setOpen} trigger="click" placement="bottomRight" arrow={false} content={<Panel onClose={() => setOpen(false)} />} styles={{ body: { padding: 0 } }} destroyOnHidden>
      <button type="button" className={'bell' + (open ? ' active' : '')} aria-label={n ? `消息，${n} 条未读` : '消息'} aria-haspopup="dialog" aria-expanded={open}>
        <IconBell size={20} />
        {n > 0 && <span className="bell-count num">{badgeText(n)}</span>}
      </button>
    </Popover>
  );
}
