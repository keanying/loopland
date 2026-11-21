// 内容审核 · 动态管理: GET /admin/v1/posts (keyword / user / review status), view, DELETE (下架 with reason).
import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Button, Col, Drawer, Empty, Input, InputNumber, Row, Select, Space, Table, Tag, Tooltip } from 'antd';
import { CommentOutlined, HeartOutlined, ShareAltOutlined, StarOutlined } from '@ant-design/icons';
import { api, PAGE_SIZE } from '../../api/admin';
import type { AdminPost, ReviewStatus } from '../../api/types';
import { useAuth } from '../../auth/AuthContext';
import { Avatar, Panel } from '../../components/ui';
import { area, dt, duration, km, num, pace } from '../../utils/format';
import { REVIEW_STATUS, SPORT_LABEL, VISIBILITY } from '../../utils/labels';
import { toastOk } from '../../utils/notify';
import { ReasonModal, Thumbs, TrackSketch } from './shared';

const TAKEDOWN_REASONS = ['含广告或引流', '含联系方式', '色情低俗', '辱骂攻击', '涉嫌诈骗', '违法违规', '侵犯他人隐私或肖像', '虚假运动数据'];

function activityLine(a: AdminPost['activity']): string {
  if (!a) return '';
  const parts = [SPORT_LABEL[a.sport] ?? a.sport, km(a.distance_m, 2), duration(a.duration_sec)];
  if (a.pace_sec_per_km) parts.push(`${pace(a.pace_sec_per_km)}/km`);
  return parts.join(' · ');
}

function ReviewTag({ p }: { p: AdminPost }) {
  const t = REVIEW_STATUS[p.review_status];
  const tag = (
    <Tag bordered={false} color={t?.color} style={{ marginInlineEnd: 0 }}>
      {p.review_status === 'rejected' ? '未通过' : t?.text ?? p.review_status}
    </Tag>
  );
  return p.reject_reason ? <Tooltip title={`原因：${p.reject_reason}`}>{tag}</Tooltip> : tag;
}

export default function PostsTab() {
  const qc = useQueryClient();
  const { can } = useAuth();
  const writable = can('review.write');
  const [params, setParams] = useSearchParams();
  const q = params.get('q') ?? '';
  const userId = params.get('user_id') ? Number(params.get('user_id')) : null;
  const reviewStatus = (params.get('review_status') ?? '') as ReviewStatus | '';
  const page = Number(params.get('page') ?? 1);
  const postId = params.get('post') ? Number(params.get('post')) : null;
  const set = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null || v === '') next.delete(k);
      else next.set(k, v);
    }
    setParams(next, { replace: true });
  };

  const [kw, setKw] = useState(q);
  useEffect(() => setKw(q), [q]);
  const [uid, setUid] = useState<number | null>(userId);
  useEffect(() => setUid(userId), [userId]);

  const list = useQuery({
    queryKey: ['posts', q, userId, reviewStatus, page],
    queryFn: () => api.posts({ q, user_id: userId, review_status: reviewStatus, page }),
    placeholderData: (p) => p,
  });
  const viewing = list.data?.items.find((p) => p.id === postId) ?? null;
  const [removing, setRemoving] = useState<AdminPost | null>(null);
  const remove = useMutation({
    mutationFn: ({ id, reason }: { id: number; reason: string }) => api.deletePost(id, reason),
    onSuccess: () => {
      setRemoving(null);
      qc.invalidateQueries({ queryKey: ['posts'] });
      qc.invalidateQueries({ queryKey: ['reports'] });
      toastOk('已下架，作者会收到通知');
    },
  });

  return (
    <Panel
      title="动态管理"
      extra={
        <Space wrap>
          <Input.Search
            allowClear
            style={{ width: 220 }}
            placeholder="正文关键词"
            value={kw}
            onChange={(e) => setKw(e.target.value)}
            onSearch={(v) => set({ q: v.trim() || null, page: null, post: null })}
          />
          <InputNumber
            className="num"
            style={{ width: 150 }}
            placeholder="作者用户 ID"
            min={1}
            precision={0}
            value={uid}
            onChange={(v) => setUid(v)}
            onPressEnter={() => set({ user_id: uid ? String(uid) : null, page: null, post: null })}
            onBlur={() => uid !== userId && set({ user_id: uid ? String(uid) : null, page: null, post: null })}
          />
          <Select
            style={{ width: 120 }}
            value={reviewStatus}
            onChange={(v) => set({ review_status: v || null, page: null, post: null })}
            options={[
              { label: '全部状态', value: '' },
              { label: '待审核', value: 'pending' },
              { label: '已通过', value: 'approved' },
              { label: '未通过', value: 'rejected' },
            ]}
          />
        </Space>
      }
    >
      <Table<AdminPost>
        rowKey="id"
        loading={list.isFetching}
        dataSource={list.data?.items}
        scroll={{ x: 1240 }}
        rowClassName={(p) => (p.id === postId ? 'row-active' : '')}
        onRow={(p) => ({ onClick: () => set({ post: String(p.id) }), style: { cursor: 'pointer', opacity: p.deleted ? 0.6 : 1 } })}
        locale={{ emptyText: <Empty description="没有符合条件的动态" /> }}
        pagination={{
          current: page,
          pageSize: PAGE_SIZE,
          total: list.data?.total ?? 0,
          showSizeChanger: false,
          showTotal: (t) => `共 ${t} 条`,
          onChange: (p) => set({ page: p === 1 ? null : String(p), post: null }),
        }}
        columns={[
          {
            title: '动态',
            key: 'post',
            render: (_, p) => (
              <div className="post-cell">
                <Thumbs urls={p.images.map((i) => i.url)} size={48} max={1} more={false} />
                <div style={{ minWidth: 0 }}>
                  <div className="rv-text">{p.content || <span className="muted">（无文字）</span>}</div>
                  <div className="muted num" style={{ fontSize: 12 }}>
                    #{p.id}
                    {p.images.length > 0 && ` · ${p.images.length} 张图`}
                  </div>
                </div>
              </div>
            ),
          },
          {
            title: '作者',
            key: 'author',
            render: (_, p) => (
              <div style={{ whiteSpace: 'nowrap' }}>
                {p.author.nickname}
                <div className="muted num" style={{ fontSize: 12 }}>
                  #{p.author.id}
                </div>
              </div>
            ),
          },
          { title: '运动', key: 'activity', render: (_, p) => (p.activity ? <span className="num" style={{ fontSize: 12 }}>{activityLine(p.activity)}</span> : <span className="muted">—</span>) },
          { title: '可见范围', dataIndex: 'visibility', render: (v: string) => <span style={{ whiteSpace: 'nowrap' }}>{VISIBILITY[v] ?? v}</span> },
          { title: '审核', key: 'review', render: (_, p) => <ReviewTag p={p} /> },
          {
            title: '互动',
            key: 'social',
            render: (_, p) => (
              <span className="num muted" style={{ fontSize: 12, whiteSpace: 'nowrap' }}>
                <HeartOutlined /> {p.like_count} <CommentOutlined style={{ marginLeft: 6 }} /> {p.comment_count} <StarOutlined style={{ marginLeft: 6 }} /> {p.collect_count}
              </span>
            ),
          },
          { title: '发布时间', dataIndex: 'created_at', render: (v: string) => <span className="muted num">{dt(v, 'MM-DD HH:mm')}</span> },
          { title: '状态', dataIndex: 'deleted', render: (v: boolean) => (v ? <Tag bordered={false}>已下架</Tag> : <Tag bordered={false} color="green">正常</Tag>) },
          {
            title: '操作',
            key: 'op',
            align: 'right',
            render: (_, p) => (
              <Space onClick={(e) => e.stopPropagation()}>
                <Button size="small" onClick={() => set({ post: String(p.id) })}>
                  查看
                </Button>
                <Button size="small" danger disabled={!writable || p.deleted} onClick={() => setRemoving(p)}>
                  下架
                </Button>
              </Space>
            ),
          },
        ]}
      />

      <Drawer
        open={viewing !== null}
        onClose={() => set({ post: null })}
        width={560}
        title={viewing ? `动态 #${viewing.id}` : ''}
        extra={
          viewing && (
            <Button danger disabled={!writable || viewing.deleted} onClick={() => setRemoving(viewing)}>
              {viewing.deleted ? '已下架' : '下架'}
            </Button>
          )
        }
      >
        {viewing && <PostDetail p={viewing} />}
      </Drawer>

      <ReasonModal
        open={removing !== null}
        title={removing ? `下架动态 #${removing.id}` : ''}
        presets={TAKEDOWN_REASONS}
        okText="下架"
        loading={remove.isPending}
        effect="下架后所有人（包括作者的粉丝和跑团）都看不到这条动态，作者会收到站内信和下架原因。"
        onCancel={() => setRemoving(null)}
        onOk={(reason) => removing && remove.mutate({ id: removing.id, reason })}
      />
    </Panel>
  );
}

function PostDetail({ p }: { p: AdminPost }) {
  const a = p.activity;
  return (
    <>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 14 }}>
        <Avatar name={p.author.nickname} size="lg" />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 16, fontWeight: 800 }}>
            <Link to={`/users?id=${p.author.id}`}>{p.author.nickname}</Link> <span className="muted num" style={{ fontSize: 12, fontWeight: 400 }}>#{p.author.id}</span>
          </div>
          <div className="muted" style={{ fontSize: 12 }}>
            {dt(p.created_at)} · {VISIBILITY[p.visibility] ?? p.visibility}
            {p.author.crew ? ` · ${p.author.crew.name}` : ''}
          </div>
        </div>
        <Space direction="vertical" align="end" size={4}>
          <ReviewTag p={p} />
          {p.deleted && <Tag bordered={false}>已下架</Tag>}
        </Space>
      </div>
      {p.reject_reason && (
        <div className="tile warn" style={{ marginBottom: 12, fontSize: 13 }}>
          未通过原因：{p.reject_reason}
        </div>
      )}
      <div className="rv-detail-text" style={{ marginBottom: 12 }}>
        {p.content || <span className="muted">（无文字）</span>}
      </div>
      {p.images.length > 0 && (
        <div style={{ marginBottom: 14 }}>
          <Thumbs urls={p.images.map((i) => i.url)} size={150} max={9} />
        </div>
      )}
      {a ? (
        <div className="track-card" style={{ marginBottom: 14 }}>
          <TrackSketch track={a.track} />
          <div style={{ flex: 1, minWidth: 0 }}>
            <b>附带运动 #{a.id}</b>
            <div className="kv" style={{ marginTop: 8 }}>
              <span>类型</span>
              <span>{SPORT_LABEL[a.sport] ?? a.sport}</span>
              <span>距离</span>
              <span className="num">{km(a.distance_m, 2)}</span>
              <span>用时</span>
              <span className="num">{duration(a.duration_sec)}</span>
              {a.pace_sec_per_km ? (
                <>
                  <span>配速</span>
                  <span className="num">{pace(a.pace_sec_per_km)} /km</span>
                </>
              ) : null}
              <span>圈地</span>
              <span className="num">{area(a.claimed_area_m2)}</span>
              <span>开始</span>
              <span className="num">{dt(a.start_time, 'MM-DD HH:mm')}</span>
            </div>
            <div className="muted" style={{ fontSize: 11, marginTop: 6 }}>
              轨迹已按作者设置去掉起终点附近的点
            </div>
          </div>
        </div>
      ) : (
        <div className="tile muted" style={{ marginBottom: 14, fontSize: 13 }}>
          没有附带运动
        </div>
      )}
      <Row gutter={[8, 8]}>
        {[
          { icon: <HeartOutlined />, l: '点赞', v: p.like_count },
          { icon: <CommentOutlined />, l: '评论', v: p.comment_count },
          { icon: <StarOutlined />, l: '收藏', v: p.collect_count },
          { icon: <ShareAltOutlined />, l: '分享', v: p.share_count },
        ].map((x) => (
          <Col span={6} key={x.l}>
            <div className="tile" style={{ textAlign: 'center' }}>
              <div className="tile-v num">{num(x.v)}</div>
              <div className="tile-l">
                {x.icon} {x.l}
              </div>
            </div>
          </Col>
        ))}
      </Row>
    </>
  );
}

