// V2 第六批 · 消息 (/messages): every message of the signed-in account, by category, unread only, paged
// (docs/api/v2-6-管理端图片上传与站内信.md「管理端站内信」). Same list-page layout as the others: the card fills the
// screen and the table scrolls inside it.
import { useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Button, Segmented, Space, Switch, Table, Tooltip } from 'antd';
import { api, PAGE_SIZE } from '../api/admin';
import type { AdminMessage, MessageCategory } from '../api/types';
import { EmptyMessages } from '../components/Inbox';
import { CategoryIcon, IconArrowRight, IconCheckAll } from '../components/icons';
import { PageHeader, Panel } from '../components/ui';
import { MESSAGES_KEY, useMessageActions, useOpenMessage, useUnreadCount } from '../hooks/useMessages';
import { ago, dt } from '../utils/format';
import { MESSAGE_CATEGORIES, MESSAGE_CATEGORY, MESSAGE_LEVEL } from '../utils/labels';
import { toastOk } from '../utils/notify';
import { urlParams } from './merchant/util';

export default function MessagesPage() {
  const [params, setParams] = useSearchParams();
  const update = urlParams(params, setParams);
  const category = (MESSAGE_CATEGORIES.includes(params.get('category') as MessageCategory) ? params.get('category') : '') as MessageCategory | '';
  const unreadOnly = params.get('unread') === 'true';
  const page = Math.max(1, Number(params.get('page') ?? 1) || 1);

  const unread = useUnreadCount();
  const byCat = unread.data?.by_category ?? {};
  const list = useQuery({
    queryKey: [...MESSAGES_KEY, 'list', category, unreadOnly, page],
    queryFn: () => api.messages({ category, unread: unreadOnly, page }),
    placeholderData: (p) => p,
  });
  const { read, readAll } = useMessageActions();
  const open = useOpenMessage();
  // Unread in the current filter: the category's count, or the total.
  const unreadHere = category ? byCat[category] ?? 0 : unread.data?.count ?? list.data?.unread_count ?? 0;

  return (
    <>
      <PageHeader title="消息" sub="与你相关的通知：商品审核、官方活动邀请与报名、结算单、开放平台异常等。点一条标为已读并打开相关页面；消息保留 180 天" />
      <Panel
        title={
          <Segmented
            value={category}
            onChange={(v) => update({ category: String(v) || null, page: null })}
            options={[
              { value: '', label: `全部${unread.data?.count ? ` ${unread.data.count}` : ''}` },
              ...MESSAGE_CATEGORIES.map((c) => ({ value: c, label: `${MESSAGE_CATEGORY[c]}${byCat[c] ? ` ${byCat[c]}` : ''}` })),
            ]}
          />
        }
        extra={
          <Space size={16} wrap>
            <label className="msg-switch">
              <Switch size="small" checked={unreadOnly} onChange={(v) => update({ unread: v ? 'true' : null, page: null })} />
              只看未读
            </label>
            <Button
              icon={<IconCheckAll size={16} />}
              disabled={!unreadHere}
              loading={readAll.isPending}
              onClick={() => readAll.mutate(category, { onSuccess: (r) => toastOk(r.updated ? `已将 ${r.updated} 条标为已读` : '没有未读消息') })}
            >
              {category ? `${MESSAGE_CATEGORY[category]}全部已读` : '全部已读'}
            </Button>
          </Space>
        }
      >
        <Table<AdminMessage>
          rowKey="id"
          loading={list.isFetching && !list.data}
          dataSource={list.data?.items}
          scroll={{ x: 860 }}
          rowClassName={(m) => (m.is_read ? '' : 'msg-unread-row')}
          onRow={(m) => ({ onClick: () => open(m), style: { cursor: m.link ? 'pointer' : 'default' } })}
          locale={{ emptyText: <EmptyMessages unreadOnly={unreadOnly} /> }}
          pagination={{
            current: page,
            pageSize: PAGE_SIZE,
            total: list.data?.total ?? 0,
            showSizeChanger: false,
            hideOnSinglePage: false,
            showTotal: (t) => `共 ${t} 条`,
            onChange: (p) => update({ page: p === 1 ? null : p }),
          }}
          columns={[
            {
              title: '消息',
              key: 'title',
              render: (_, m) => {
                const level = MESSAGE_LEVEL[m.level] ?? MESSAGE_LEVEL.info;
                return (
                  <div className="msg-cell">
                    <span className="msg-icon" style={{ color: level.color, background: level.bg }}>
                      <CategoryIcon category={m.category} size={20} />
                    </span>
                    <div style={{ minWidth: 0 }}>
                      <div className="msg-cell-title">
                        {!m.is_read && <span className="msg-dot inline" aria-label="未读" />}
                        {m.title}
                      </div>
                      {m.body && <div className="msg-cell-body">{m.body}</div>}
                    </div>
                  </div>
                );
              },
            },
            { title: '分类', dataIndex: 'category', width: 110, render: (c: MessageCategory) => MESSAGE_CATEGORY[c] ?? c },
            {
              title: '级别',
              dataIndex: 'level',
              width: 90,
              render: (l: AdminMessage['level']) => {
                const x = MESSAGE_LEVEL[l] ?? MESSAGE_LEVEL.info;
                return (
                  <span className="msg-level" style={{ color: x.color, background: x.bg }}>
                    {x.text}
                  </span>
                );
              },
            },
            {
              title: '时间',
              dataIndex: 'created_at',
              width: 170,
              render: (v: string) => (
                <Tooltip title={ago(v)}>
                  <span className="num">{dt(v)}</span>
                </Tooltip>
              ),
            },
            {
              title: '',
              key: 'op',
              width: 130,
              align: 'right',
              render: (_, m) => (
                <Space size={4} onClick={(e) => e.stopPropagation()}>
                  {!m.is_read && (
                    <Button size="small" type="text" loading={read.isPending && read.variables === m.id} onClick={() => read.mutate(m.id)}>
                      标为已读
                    </Button>
                  )}
                  {m.link && (
                    <Tooltip title="打开">
                      <Button size="small" type="text" aria-label="打开" icon={<IconArrowRight size={16} />} onClick={() => open(m)} />
                    </Tooltip>
                  )}
                </Space>
              ),
            },
          ]}
        />
      </Panel>
    </>
  );
}
