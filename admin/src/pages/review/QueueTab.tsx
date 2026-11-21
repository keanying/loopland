// 内容审核 · 审核队列 (M-16): GET /admin/v1/reviews, approve / reject / batch, stats header.
import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { App, Button, Checkbox, Col, Empty, Pagination, Row, Segmented, Skeleton, Space, Tag, Tooltip } from 'antd';
import { CheckOutlined, CloseOutlined, FlagFilled, WarningFilled } from '@ant-design/icons';
import { api, PAGE_SIZE } from '../../api/admin';
import type { ReviewStatus, ReviewTargetType, ReviewTask } from '../../api/types';
import { useAuth } from '../../auth/AuthContext';
import { Avatar, Panel, Stat } from '../../components/ui';
import { ago, dt } from '../../utils/format';
import { REJECT_EFFECT, REJECT_REASONS, REVIEW_STATUS, REVIEW_TARGET, REVIEW_TARGET_ORDER } from '../../utils/labels';
import { toastOk } from '../../utils/notify';
import { previewState } from './preview';
import { ReasonModal, RiskBadge, TargetTag, Thumbs } from './shared';

/** How the reviewed text reads for each target type. */
const TEXT_LABEL: Record<string, string> = {
  post: '动态正文',
  comment: '评论内容',
  nickname: '新昵称',
  avatar: '新头像',
  crew_name: '新跑团名称',
  crew_avatar: '新跑团头像',
  bio: '新简介',
  meetup: '组局标题和说明',
};

/** Image-only targets show a bigger thumbnail in the list. */
const IMAGE_ONLY = new Set(['avatar', 'crew_avatar']);

function isTyping(el: EventTarget | null): boolean {
  const t = el as HTMLElement | null;
  if (!t) return false;
  return t.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(t.tagName);
}

export default function QueueTab() {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const { can } = useAuth();
  const writable = can('review.write');
  const [params, setParams] = useSearchParams();
  const status = (['approved', 'rejected'].includes(params.get('status') ?? '') ? params.get('status') : 'pending') as ReviewStatus;
  const type = (params.get('type') ?? '') as ReviewTargetType | '';
  const page = Number(params.get('page') ?? 1);
  const pending = status === 'pending';

  const set = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) {
      if (v === null || v === '') next.delete(k);
      else next.set(k, v);
    }
    setParams(next, { replace: true });
  };

  const list = useQuery({
    queryKey: ['reviews', status, type, page],
    queryFn: () => api.reviews({ status, target_type: type, page }),
    placeholderData: (p) => p,
  });
  const stats = useQuery({ queryKey: ['reviews', 'stats'], queryFn: api.reviewStats });
  const items = useMemo(() => list.data?.items ?? [], [list.data]);

  const [activeId, setActiveId] = useState<number | null>(null);
  const [checked, setChecked] = useState<Set<number>>(new Set());
  const [rejecting, setRejecting] = useState<'one' | 'batch' | null>(null);
  const active = items.find((t) => t.id === activeId) ?? items[0] ?? null;

  useEffect(() => {
    setChecked(new Set());
    setActiveId(null);
  }, [status, type, page]);
  // Drop selections that left the page (decided elsewhere / refetched).
  useEffect(() => {
    setChecked((c) => {
      const ids = new Set(items.map((t) => t.id));
      const next = new Set([...c].filter((id) => ids.has(id)));
      return next.size === c.size ? c : next;
    });
  }, [items]);

  const listRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    if (active) listRef.current?.querySelector(`[data-id="${active.id}"]`)?.scrollIntoView({ block: 'nearest' });
  }, [active]);

  const nextAfter = (id: number): number | null => {
    const i = items.findIndex((t) => t.id === id);
    const rest = items.filter((_t, k) => k !== i);
    return (rest[i] ?? rest[i - 1] ?? null)?.id ?? null;
  };

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['reviews'] });
    qc.invalidateQueries({ queryKey: ['dashboard'] });
  };

  const decide = useMutation({
    mutationFn: ({ task, approve, reason }: { task: ReviewTask; approve: boolean; reason: string }) =>
      approve ? api.approveReview(task.id) : api.rejectReview(task.id, reason),
    onSuccess: (t, v) => {
      setActiveId(nextAfter(v.task.id));
      setRejecting(null);
      refresh();
      toastOk(`${v.approve ? '已通过' : '已拒绝'}：${REVIEW_TARGET[t?.target_type ?? v.task.target_type]?.text ?? ''} · ${v.task.user.nickname}`);
    },
    onError: () => refresh(),
  });

  const batch = useMutation({
    mutationFn: ({ approve, reason }: { approve: boolean; reason: string }) => api.batchReview({ ids: [...checked], action: approve ? 'approve' : 'reject', reason }),
    onSuccess: (r, v) => {
      setRejecting(null);
      setChecked(new Set());
      setActiveId(null);
      refresh();
      toastOk(`已批量${v.approve ? '通过' : '拒绝'} ${r.done} 条${r.done < checked.size ? `（${checked.size - r.done} 条已被别人处理）` : ''}`);
    },
    onError: () => refresh(),
  });

  const busy = decide.isPending || batch.isPending;

  const approveOne = (t: ReviewTask) => !busy && decide.mutate({ task: t, approve: true, reason: '' });
  const toggle = (id: number) =>
    setChecked((c) => {
      const n = new Set(c);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
  const confirmBatchApprove = () =>
    modal.confirm({
      title: `通过选中的 ${checked.size} 条内容？`,
      content: '通过后立即对其他用户可见（昵称、头像等本来就已生效，只是结束审核）。',
      okText: '全部通过',
      cancelText: '取消',
      onOk: () => batch.mutateAsync({ approve: true, reason: '' }),
    });

  // Keyboard: J/K or ↓/↑ move, A approve, R reject, X select.
  const keyState = useRef({ items, active, pending, writable, busy, rejecting, approveOne, toggle });
  keyState.current = { items, active, pending, writable, busy, rejecting, approveOne, toggle };
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const s = keyState.current;
      if (e.metaKey || e.ctrlKey || e.altKey || isTyping(e.target) || s.rejecting || previewState.open > 0) return;
      if (document.querySelector('.ant-modal-wrap:not([style*="display: none"]) .ant-modal')) return;
      const i = s.active ? s.items.findIndex((t) => t.id === s.active!.id) : -1;
      const k = e.key.toLowerCase();
      if (k === 'j' || e.key === 'ArrowDown') {
        const n = s.items[Math.min(s.items.length - 1, i + 1)];
        if (n) setActiveId(n.id);
        e.preventDefault();
      } else if (k === 'k' || e.key === 'ArrowUp') {
        const n = s.items[Math.max(0, i - 1)];
        if (n) setActiveId(n.id);
        e.preventDefault();
      } else if (!s.pending || !s.writable || !s.active || s.busy) {
        return;
      } else if (k === 'a') {
        s.approveOne(s.active);
      } else if (k === 'r') {
        setRejecting('one');
        e.preventDefault();
      } else if (k === 'x') {
        s.toggle(s.active.id);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const st = stats.data;
  const high = items.filter((t) => t.risk_score >= 70).length;
  const oldest = pending && items.length ? items.reduce((m, t) => (Date.parse(t.created_at) < Date.parse(m.created_at) ? t : m)) : null;
  const allChecked = items.length > 0 && items.every((t) => checked.has(t.id));
  const typeCount = (t: string) => st?.by_type?.[t as ReviewTargetType] ?? 0;

  return (
    <>
      <Row gutter={[16, 16]}>
        <Col xs={12} xl={6}>
          <Stat value={st?.pending ?? '—'} unit="条" label="待审核" sub={st ? REVIEW_TARGET_ORDER.filter((t) => typeCount(t)).map((t) => `${REVIEW_TARGET[t].text} ${typeCount(t)}`).join(' · ') || '队列已清空' : undefined} />
        </Col>
        <Col xs={12} xl={6}>
          <Stat value={st?.today_done ?? '—'} unit="条" label="今日已处理" sub="通过 + 拒绝，全部审核员" />
        </Col>
        <Col xs={12} xl={6}>
          <Stat value={pending ? high : '—'} unit={pending ? '条' : undefined} label="高风险（≥ 70）" sub={pending ? '仅统计本页' : '切到「待审核」查看'} />
        </Col>
        <Col xs={12} xl={6}>
          <Stat value={oldest ? ago(oldest.created_at).replace('前', '') : '—'} label="本页最早一条已等待" sub={oldest ? dt(oldest.created_at, 'MM-DD HH:mm') + ' 提交' : undefined} />
        </Col>
      </Row>

      <Row gutter={[20, 20]}>
        <Col xs={24} xl={10}>
          <Panel
            title="审核队列"
            extra={
              <Segmented
                size="small"
                value={status}
                onChange={(v) => set({ status: v === 'pending' ? null : String(v), page: null })}
                options={[
                  { label: `待审核${st ? ` ${st.pending}` : ''}`, value: 'pending' },
                  { label: '已通过', value: 'approved' },
                  { label: '已拒绝', value: 'rejected' },
                ]}
              />
            }
          >
            <div className="tab-strip" style={{ marginBottom: 10 }}>
              <Segmented
                size="small"
                value={type}
                onChange={(v) => set({ type: String(v) || null, page: null })}
                options={[
                  { label: `全部${pending && st ? ` ${st.pending}` : ''}`, value: '' },
                  ...REVIEW_TARGET_ORDER.map((t) => ({ label: `${REVIEW_TARGET[t].text}${pending && typeCount(t) ? ` ${typeCount(t)}` : ''}`, value: t })),
                ]}
              />
            </div>
            {pending && (
              <div className="rv-toolbar">
                <Checkbox
                  checked={allChecked}
                  indeterminate={checked.size > 0 && !allChecked}
                  disabled={!items.length || !writable}
                  onChange={(e) => setChecked(e.target.checked ? new Set(items.map((t) => t.id)) : new Set())}
                >
                  全选本页
                </Checkbox>
                {checked.size > 0 && <b>已选 {checked.size} 条</b>}
                <Button size="small" icon={<CheckOutlined />} disabled={!checked.size || !writable} loading={batch.isPending && !rejecting} onClick={confirmBatchApprove}>
                  批量通过
                </Button>
                <Button size="small" danger icon={<CloseOutlined />} disabled={!checked.size || !writable} onClick={() => setRejecting('batch')}>
                  批量拒绝
                </Button>
                <span className="rv-keys">
                  <kbd>J</kbd>/<kbd>K</kbd> 上下 · <kbd>A</kbd> 通过 · <kbd>R</kbd> 拒绝 · <kbd>X</kbd> 勾选
                </span>
              </div>
            )}
            <div className="panel-hint" style={{ marginBottom: 6 }}>
              {pending ? '按风险分从高到低，同分先提交的在前' : '按审核时间倒序'}
            </div>
            <div ref={listRef}>
              {list.isLoading ? (
                <Skeleton active />
              ) : items.length === 0 ? (
                <Empty description={pending ? '队列已清空，辛苦了' : '暂无记录'} style={{ padding: 40 }} />
              ) : (
                items.map((t) => (
                  <QueueItem
                    key={t.id}
                    t={t}
                    active={t.id === active?.id}
                    checked={checked.has(t.id)}
                    selectable={pending && writable}
                    onClick={() => setActiveId(t.id)}
                    onCheck={() => toggle(t.id)}
                  />
                ))
              )}
            </div>
            {(list.data?.total ?? 0) > PAGE_SIZE && (
              <Pagination
                size="small"
                style={{ marginTop: 12, textAlign: 'right' }}
                current={page}
                pageSize={PAGE_SIZE}
                total={list.data?.total}
                showSizeChanger={false}
                showTotal={(n) => `共 ${n} 条`}
                onChange={(p) => set({ page: p === 1 ? null : String(p) })}
              />
            )}
          </Panel>
        </Col>
        <Col xs={24} xl={14}>
          {active ? (
            <TaskDetail
              t={active}
              writable={writable}
              busy={busy}
              onApprove={() => approveOne(active)}
              onReject={() => setRejecting('one')}
            />
          ) : (
            <Panel grey>
              <Empty description={list.isLoading ? '加载中' : '选择左侧的一条内容'} style={{ padding: 80 }} />
            </Panel>
          )}
        </Col>
      </Row>

      <ReasonModal
        open={rejecting !== null}
        title={rejecting === 'batch' ? `拒绝选中的 ${checked.size} 条内容` : `拒绝${active ? `「${REVIEW_TARGET[active.target_type]?.text ?? ''}」· ${active.user.nickname}` : ''}`}
        presets={REJECT_REASONS}
        okText="拒绝"
        loading={busy}
        effect={
          rejecting === 'batch'
            ? '拒绝后作者会收到站内信；昵称、头像、跑团名称和头像会恢复默认值。'
            : active
              ? `${REJECT_EFFECT[active.target_type] ?? ''}，作者会收到站内信。`
              : undefined
        }
        onCancel={() => setRejecting(null)}
        onOk={(reason) => {
          if (rejecting === 'batch') batch.mutate({ approve: false, reason });
          else if (active) decide.mutate({ task: active, approve: false, reason });
        }}
      />
    </>
  );
}

function QueueItem({ t, active, checked, selectable, onClick, onCheck }: { t: ReviewTask; active: boolean; checked: boolean; selectable: boolean; onClick: () => void; onCheck: () => void }) {
  const imageOnly = IMAGE_ONLY.has(t.target_type);
  return (
    <div
      className={`rv-item${active ? ' active' : ''}${checked ? ' checked' : ''}`}
      data-id={t.id}
      role="button"
      tabIndex={0}
      aria-label={`${REVIEW_TARGET[t.target_type]?.text ?? t.target_type} ${t.user.nickname} 风险 ${t.risk_score}`}
      onClick={onClick}
      onKeyDown={(e) => e.key === 'Enter' && onClick()}
    >
      {selectable && (
        <span onClick={(e) => e.stopPropagation()} style={{ paddingTop: 2 }}>
          <Checkbox checked={checked} onChange={onCheck} aria-label="勾选" />
        </span>
      )}
      <div className="rv-main">
        <div className="rv-meta">
          <TargetTag type={t.target_type} />
          <RiskBadge score={t.risk_score} />
          {t.report_count > 0 && (
            <Tag bordered={false} color="red" icon={<FlagFilled />} style={{ marginInlineEnd: 0 }}>
              被举报 {t.report_count}
            </Tag>
          )}
          <span className="muted" style={{ marginLeft: 'auto' }}>
            {ago(t.created_at)}
          </span>
        </div>
        <div style={{ fontSize: 12 }}>
          <b>{t.user.nickname}</b> <span className="muted num">#{t.user.id}</span>
        </div>
        {!imageOnly && <div className={`rv-text${t.text ? '' : ' empty'}`}>{t.text || '（无文字）'}</div>}
        <Thumbs urls={t.images} size={imageOnly ? 64 : 48} />
        {t.status !== 'pending' && (
          <div className="rv-meta">
            <Tag bordered={false} color={REVIEW_STATUS[t.status]?.color} style={{ marginInlineEnd: 0 }}>
              {REVIEW_STATUS[t.status]?.text}
            </Tag>
            {t.reject_reason && <span className="danger-text">{t.reject_reason}</span>}
            <span className="muted">
              {t.reviewer?.username ?? '系统'} · {dt(t.reviewed_at, 'MM-DD HH:mm')}
            </span>
          </div>
        )}
      </div>
    </div>
  );
}

function TaskDetail({ t, writable, busy, onApprove, onReject }: { t: ReviewTask; writable: boolean; busy: boolean; onApprove: () => void; onReject: () => void }) {
  const pending = t.status === 'pending';
  const reasons = t.risk_reasons ?? [];
  const imageOnly = IMAGE_ONLY.has(t.target_type);
  const [title, ...rest] = t.target_type === 'meetup' && t.text ? t.text.split('\n') : [null];
  return (
    <Panel grey style={{ height: 'auto', position: 'sticky', top: 24 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 14 }}>
        <Avatar name={t.user.nickname} size="lg" />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 18, fontWeight: 800 }}>
            {REVIEW_TARGET[t.target_type]?.text ?? t.target_type} · <Link to={`/users?id=${t.user.id}`}>{t.user.nickname}</Link>
          </div>
          <div className="muted" style={{ fontSize: 12 }}>
            用户 #{t.user.id} · 对象 #{t.target_id} · 任务 #{t.id} · {dt(t.created_at)} 提交
            {t.target_type === 'post' && (
              <>
                {' · '}
                <Link to={`/review?tab=posts&q=${t.target_id}`}>在动态管理中查看</Link>
              </>
            )}
          </div>
        </div>
        <RiskBadge score={t.risk_score} large />
      </div>

      <Row gutter={[12, 12]}>
        <Col span={24}>
          <div className="panel" style={{ padding: 16 }}>
            <div className="muted" style={{ fontSize: 12, marginBottom: 6 }}>
              {TEXT_LABEL[t.target_type] ?? '内容'}
              {['nickname', 'avatar', 'crew_name', 'crew_avatar', 'bio'].includes(t.target_type) && '（已先生效，拒绝后恢复默认）'}
            </div>
            {!imageOnly &&
              (t.target_type === 'meetup' && title ? (
                <div className="rv-detail-text">
                  <b>{title}</b>
                  {rest.length > 0 && '\n' + rest.join('\n')}
                </div>
              ) : (
                <div className="rv-detail-text">{t.text || <span className="muted">（无文字）</span>}</div>
              ))}
            {(t.images?.length ?? 0) > 0 && (
              <div style={{ marginTop: imageOnly ? 0 : 12 }}>
                <Thumbs urls={t.images} size={imageOnly ? 200 : 132} max={9} />
                <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>
                  点击图片放大，左右切换
                </div>
              </div>
            )}
          </div>
        </Col>
        <Col xs={24} md={14}>
          <div className="panel" style={{ padding: 14, height: '100%' }}>
            <b>风险原因</b>
            <div style={{ marginTop: 6 }}>
              {reasons.length ? (
                reasons.map((r, i) => (
                  <div className="rv-reason" key={i}>
                    <WarningFilled style={{ color: t.risk_score >= 70 ? 'var(--red)' : '#d99a0b' }} />
                    {r}
                  </div>
                ))
              ) : (
                <div className="muted" style={{ fontSize: 13, padding: '6px 0' }}>
                  {['nickname', 'avatar', 'crew_name', 'crew_avatar', 'bio'].includes(t.target_type) ? '未命中规则；资料类改动全部人工复核' : '未命中规则'}
                </div>
              )}
            </div>
          </div>
        </Col>
        <Col xs={24} md={10}>
          <div className={`tile${t.report_count >= 3 ? ' warn' : ''}`} style={{ height: '100%' }}>
            <div className="tile-v num">{t.report_count}</div>
            <div className="tile-l">举报人数{t.report_count >= 3 ? '（已自动转入审核）' : ''}</div>
            {t.report_count > 0 && (
              <Link to={`/review?tab=reports`} style={{ fontSize: 12 }}>
                去举报处理查看
              </Link>
            )}
          </div>
        </Col>
      </Row>

      {pending ? (
        <div style={{ display: 'flex', gap: 10, marginTop: 16, flexWrap: 'wrap', alignItems: 'center' }}>
          <Tooltip title="快捷键 A">
            <Button type="primary" size="large" icon={<CheckOutlined />} disabled={!writable} loading={busy} onClick={onApprove}>
              通过 <span className="kbd" style={{ marginLeft: 6, color: 'var(--ink)' }}>A</span>
            </Button>
          </Tooltip>
          <Tooltip title="快捷键 R">
            <Button size="large" danger icon={<CloseOutlined />} disabled={!writable || busy} onClick={onReject}>
              拒绝 <span className="kbd" style={{ marginLeft: 6 }}>R</span>
            </Button>
          </Tooltip>
          <span className="muted" style={{ fontSize: 12 }}>
            {writable ? `拒绝后：${REJECT_EFFECT[t.target_type] ?? '对其他人隐藏'}` : '当前角色不能审核'}
          </span>
        </div>
      ) : (
        <div className="tile" style={{ marginTop: 16 }}>
          <Space wrap>
            <Tag bordered={false} color={REVIEW_STATUS[t.status]?.color}>
              {REVIEW_STATUS[t.status]?.text}
            </Tag>
            {t.reject_reason && <b className="danger-text">{t.reject_reason}</b>}
            <span>
              审核人 <b>{t.reviewer?.username ?? '系统'}</b> · {dt(t.reviewed_at)}
            </span>
          </Space>
        </div>
      )}
    </Panel>
  );
}
