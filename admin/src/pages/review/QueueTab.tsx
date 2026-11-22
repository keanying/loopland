// 内容审核 · 审核队列 (M-16 ~ M-18): GET /admin/v1/reviews, POST /reviews/{id}/decide (auto-advance
// to `next`), batch approve / reject, stats header, AI verdict next to the rule reasons.
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { App, Button, Checkbox, Col, Empty, InputNumber, Pagination, Row, Segmented, Select, Skeleton, Space, Tag, Tooltip } from 'antd';
import { CheckOutlined, CloseOutlined, EyeInvisibleOutlined, FlagFilled, HighlightOutlined, StopOutlined, WarningFilled } from '@ant-design/icons';
import { api, PAGE_SIZE } from '../../api/admin';
import type { ReviewDecideAction, ReviewStatus, ReviewTargetType, ReviewTask } from '../../api/types';
import { useAuth } from '../../auth/AuthContext';
import { Avatar, Panel, Stat } from '../../components/ui';
import { ago, dt } from '../../utils/format';
import { AI_SUGGESTION, SUGGESTED_ACTION, REJECT_EFFECT, REJECT_REASONS, REVIEW_DECISION, REVIEW_STATUS, REVIEW_TARGET, REVIEW_TARGET_ORDER } from '../../utils/labels';
import { toastOk } from '../../utils/notify';
import { previewState } from './preview';
import { ReasonModal, RiskBadge, TargetTag, Thumbs } from './shared';
import { AIChip, AIVerdict } from './ai';

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
const PROFILE = ['nickname', 'avatar', 'crew_name', 'crew_avatar', 'bio'];

/** What 「打码后通过」 does to each kind of object. */
function maskEffect(type: string): string {
  if (IMAGE_ONLY.has(type)) return type === 'avatar' ? '恢复默认头像后通过' : '跑团头像恢复默认后通过';
  if (type === 'post') return '正文里命中的敏感词和联系方式替换为 *，AI 标记的违规图片从动态里移除，然后通过';
  return '命中的敏感词和联系方式替换为 * 后通过';
}

type AIFilter = '' | 'reject' | 'review' | 'approve' | 'mask' | 'hide_endpoints' | 'none';
type Sort = 'risk' | 'ai' | 'confidence' | 'time';

const SORTS: Record<Sort, { label: string; cmp: (a: ReviewTask, b: ReviewTask) => number }> = {
  risk: { label: '按风险分', cmp: (a, b) => b.risk_score - a.risk_score || Date.parse(a.created_at) - Date.parse(b.created_at) },
  ai: { label: '按 AI 分', cmp: (a, b) => (b.ai?.risk_score ?? -1) - (a.ai?.risk_score ?? -1) || b.risk_score - a.risk_score },
  confidence: { label: '按 AI 置信度', cmp: (a, b) => (b.ai?.confidence ?? -1) - (a.ai?.confidence ?? -1) || b.risk_score - a.risk_score },
  time: { label: '先提交的在前', cmp: (a, b) => Date.parse(a.created_at) - Date.parse(b.created_at) },
};

function isTyping(el: EventTarget | null): boolean {
  const t = el as HTMLElement | null;
  if (!t) return false;
  return t.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(t.tagName);
}

type Rejecting = 'one' | 'mute' | 'batch' | null;

export default function QueueTab() {
  const { modal } = App.useApp();
  const qc = useQueryClient();
  const { can } = useAuth();
  const writable = can('review.write');
  const [params, setParams] = useSearchParams();
  const status = (['approved', 'rejected'].includes(params.get('status') ?? '') ? params.get('status') : 'pending') as ReviewStatus;
  const type = (params.get('type') ?? '') as ReviewTargetType | '';
  const page = Number(params.get('page') ?? 1);
  const aiFilter = (params.get('ai') ?? '') as AIFilter;
  const sort = ((params.get('sort') ?? 'risk') in SORTS ? params.get('sort') ?? 'risk' : 'risk') as Sort;
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
  const raw = useMemo(() => list.data?.items ?? [], [list.data]);
  // AI filter / sort work on the loaded page (the list endpoint has no such parameters).
  const items = useMemo(() => {
    let l = raw;
    if (aiFilter === 'none') l = l.filter((t) => !t.ai);
    else if (aiFilter) l = l.filter((t) => t.ai?.suggestion === aiFilter);
    return pending && sort !== 'risk' ? [...l].sort(SORTS[sort].cmp) : l;
  }, [raw, aiFilter, sort, pending]);

  const [activeId, setActiveId] = useState<number | null>(null);
  /** The `next` task the server handed back; shown even before the refetched page contains it. */
  const [nextTask, setNextTask] = useState<ReviewTask | null>(null);
  const [checked, setChecked] = useState<Set<number>>(new Set());
  const [rejecting, setRejecting] = useState<Rejecting>(null);
  const [muteDays, setMuteDays] = useState(7);
  const active = items.find((t) => t.id === activeId) ?? (nextTask && nextTask.id === activeId && nextTask.status === 'pending' ? nextTask : null) ?? items[0] ?? null;

  useEffect(() => {
    setChecked(new Set());
    setActiveId(null);
    setNextTask(null);
  }, [status, type, page, aiFilter]);
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
    mutationFn: ({ task, action, reason, mute_days }: { task: ReviewTask; action: ReviewDecideAction; reason?: string; mute_days?: number }) =>
      api.decideReview(task.id, { action, ...(reason ? { reason } : {}), ...(action === 'reject_mute' ? { mute_days } : {}) }, type || undefined),
    onSuccess: (r, v) => {
      // Auto-advance: the server's `next`, else the next one on this page.
      const next = r.next ?? null;
      const shownNext = next && (!type || next.target_type === type) ? next : null;
      setNextTask(shownNext);
      setActiveId(shownNext?.id ?? nextAfter(v.task.id));
      setRejecting(null);
      refresh();
      const label = REVIEW_DECISION[v.action] ?? v.action;
      toastOk(`已${label}${v.action === 'reject_mute' ? ` ${v.mute_days} 天` : ''}：${REVIEW_TARGET[v.task.target_type]?.text ?? ''} · ${v.task.user.nickname}${next ? '' : ' · 队列已清空'}`);
    },
    onError: () => refresh(),
  });

  const batch = useMutation({
    mutationFn: ({ approve, reason }: { approve: boolean; reason: string }) => api.batchReview({ ids: [...checked], action: approve ? 'approve' : 'reject', reason }),
    onSuccess: (r, v) => {
      setRejecting(null);
      setChecked(new Set());
      setActiveId(null);
      setNextTask(null);
      refresh();
      toastOk(`已批量${v.approve ? '通过' : '驳回'} ${r.done} 条${r.done < checked.size ? `（${checked.size - r.done} 条已被别人处理）` : ''}`);
    },
    onError: () => refresh(),
  });

  const busy = decide.isPending || batch.isPending;

  const run = (t: ReviewTask, action: ReviewDecideAction) => {
    if (busy) return;
    if (action === 'approve_hide_endpoints' && !t.has_activity) return;
    if (action === 'reject') return setRejecting('one');
    if (action === 'reject_mute') {
      setMuteDays(7);
      return setRejecting('mute');
    }
    decide.mutate({ task: t, action });
  };
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

  // Keyboard: J/K or ↓/↑ move, A 通过, M 打码后通过, H 隐藏起终点后通过, R 驳回, B 驳回并禁言, X 勾选.
  const keyState = useRef({ items, active, pending, writable, busy, rejecting, run, toggle });
  keyState.current = { items, active, pending, writable, busy, rejecting, run, toggle };
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
        return;
      }
      if (k === 'k' || e.key === 'ArrowUp') {
        const n = s.items[Math.max(0, i - 1)];
        if (n) setActiveId(n.id);
        e.preventDefault();
        return;
      }
      if (!s.pending || !s.writable || !s.active || s.busy) return;
      const map: Record<string, ReviewDecideAction> = { a: 'approve', m: 'approve_masked', h: 'approve_hide_endpoints', r: 'reject', b: 'reject_mute' };
      if (map[k]) {
        s.run(s.active, map[k]);
        e.preventDefault();
      } else if (k === 'x') s.toggle(s.active.id);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const st = stats.data;
  const high = raw.filter((t) => t.risk_score >= 70).length;
  const oldest = pending && raw.length ? raw.reduce((m, t) => (Date.parse(t.created_at) < Date.parse(m.created_at) ? t : m)) : null;
  const allChecked = items.length > 0 && items.every((t) => checked.has(t.id));
  const typeCount = (t: string) => st?.by_type?.[t as ReviewTargetType] ?? 0;
  const aiCount = (f: AIFilter) => (f === 'none' ? raw.filter((t) => !t.ai).length : raw.filter((t) => t.ai?.suggestion === f).length);
  const hasAI = raw.some((t) => t.ai !== undefined);

  return (
    <>
      <Row gutter={[16, 16]}>
        <Col xs={12} xl={6}>
          <Stat value={st?.pending ?? '—'} unit="条" label="待审核" sub={st ? REVIEW_TARGET_ORDER.filter((t) => typeCount(t)).map((t) => `${REVIEW_TARGET[t].text} ${typeCount(t)}`).join(' · ') || '队列已清空' : undefined} />
        </Col>
        <Col xs={12} xl={6}>
          <Stat value={st?.today_done ?? '—'} unit="条" label="今日已处理" sub="人工处理，全部审核员" />
        </Col>
        <Col xs={12} xl={6}>
          <Stat value={pending ? high : '—'} unit={pending ? '条' : undefined} label="高风险（≥ 70）" sub={pending ? `仅统计本页${hasAI ? ` · AI 建议拒绝 ${aiCount('reject')} 条` : ''}` : '切到「待审核」查看'} />
        </Col>
        <Col xs={12} xl={6}>
          <Stat value={oldest ? ago(oldest.created_at).replace('前', '') : '—'} label="本页最早一条已等待" sub={oldest ? dt(oldest.created_at, 'MM-DD HH:mm') + ' 提交' : undefined} />
        </Col>
      </Row>

      <Row gutter={[20, 20]} className="split-fill">
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
            {hasAI && (
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center', marginBottom: 10 }}>
                <Select<AIFilter>
                  size="small"
                  value={aiFilter}
                  style={{ width: 196 }}
                  aria-label="按 AI 建议筛选"
                  onChange={(v) => set({ ai: v || null })}
                  options={[
                    { value: '', label: `AI 建议：全部（${raw.length}）` },
                    ...(['reject', 'review', 'mask', 'hide_endpoints', 'approve'] as const).map((s) => ({ value: s, label: `${AI_SUGGESTION[s].text}（${aiCount(s)}）` })),
                    { value: 'none', label: `没有 AI 判定（${aiCount('none')}）` },
                  ]}
                />
                {pending && (
                  <Select<Sort>
                    size="small"
                    value={sort}
                    style={{ width: 132 }}
                    aria-label="排序"
                    onChange={(v) => set({ sort: v === 'risk' ? null : v })}
                    options={(Object.keys(SORTS) as Sort[]).map((k) => ({ value: k, label: SORTS[k].label }))}
                  />
                )}
                <span className="muted" style={{ fontSize: 12 }}>
                  筛选和排序只作用于本页
                </span>
              </div>
            )}
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
                  批量驳回
                </Button>
                <span className="rv-keys">
                  <kbd>J</kbd>/<kbd>K</kbd> 上下 · <kbd>X</kbd> 勾选 · 处理快捷键见右侧按钮
                </span>
              </div>
            )}
            <div className="panel-hint" style={{ marginBottom: 6 }}>
              {pending ? (sort === 'risk' ? '按最终风险分（规则分与 AI 分取高）从高到低，同分先提交的在前' : `本页${SORTS[sort].label}`) : '按审核时间倒序'}
              {pending && ' · 处理后自动跳到下一条'}
            </div>
            <div ref={listRef} className="split-scroll">
              {list.isLoading ? (
                <Skeleton active />
              ) : items.length === 0 ? (
                <Empty description={raw.length ? '本页没有符合筛选的内容' : pending ? '队列已清空，辛苦了' : '暂无记录'} style={{ padding: 40 }} />
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
            <TaskDetail t={active} writable={writable} busy={busy} pendingAction={decide.isPending ? decide.variables?.action : undefined} onAction={(a) => run(active, a)} />
          ) : (
            <Panel grey>
              <Empty description={list.isLoading ? '加载中' : '选择左侧的一条内容'} style={{ padding: 80 }} />
            </Panel>
          )}
        </Col>
      </Row>

      <ReasonModal
        open={rejecting !== null}
        title={
          rejecting === 'batch'
            ? `驳回选中的 ${checked.size} 条内容`
            : `${rejecting === 'mute' ? '驳回并禁言' : '驳回'}${active ? `「${REVIEW_TARGET[active.target_type]?.text ?? ''}」· ${active.user.nickname}` : ''}`
        }
        presets={REJECT_REASONS}
        okText={rejecting === 'mute' ? `驳回并禁言 ${muteDays} 天` : '驳回'}
        loading={busy}
        effect={
          rejecting === 'batch'
            ? '驳回后作者会收到站内信；昵称、头像、跑团名称和头像会恢复默认值。'
            : active
              ? `${REJECT_EFFECT[active.target_type] ?? ''}，作者会收到站内信${rejecting === 'mute' ? `；${active.user.nickname} ${muteDays} 天内不能发言、改昵称和头像` : ''}。`
              : undefined
        }
        extra={
          rejecting === 'mute' && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 14 }}>
              <span>禁言</span>
              <InputNumber className="num" min={1} max={365} precision={0} value={muteDays} onChange={(v) => setMuteDays(v ?? 7)} aria-label="禁言天数" style={{ width: 90 }} />
              <span>天</span>
              <Space size={4}>
                {[1, 7, 30].map((d) => (
                  <Tag.CheckableTag key={d} checked={muteDays === d} onChange={() => setMuteDays(d)}>
                    {d} 天
                  </Tag.CheckableTag>
                ))}
              </Space>
              {active?.user_violation_count ? <span className="muted" style={{ fontSize: 12 }}>作者此前违规 {active.user_violation_count} 次</span> : null}
            </div>
          )
        }
        onCancel={() => setRejecting(null)}
        onOk={(reason) => {
          if (rejecting === 'batch') batch.mutate({ approve: false, reason });
          else if (active) decide.mutate({ task: active, action: rejecting === 'mute' ? 'reject_mute' : 'reject', reason, mute_days: muteDays });
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
          <AIChip ai={t.ai} />
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
          {(t.user_violation_count ?? 0) > 0 && (
            <span className={t.user_violation_count! >= 3 ? 'danger-text' : 'muted'} style={{ marginLeft: 6 }}>
              · 违规 {t.user_violation_count} 次
            </span>
          )}
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

function DecisionButton({
  action,
  label,
  hotkey,
  icon,
  tip,
  primary,
  danger,
  suggested,
  disabled,
  loading,
  onClick,
}: {
  action: ReviewDecideAction;
  label: string;
  hotkey: string;
  icon: ReactNode;
  tip: ReactNode;
  primary?: boolean;
  danger?: boolean;
  suggested: boolean;
  disabled: boolean;
  loading: boolean;
  onClick: () => void;
}) {
  return (
    <Tooltip title={<>{tip}（快捷键 {hotkey}）</>}>
      <span className={`decide-btn${suggested ? ' suggested' : ''}`} data-action={action}>
        <Button type={primary ? 'primary' : 'default'} danger={danger} icon={icon} disabled={disabled} loading={loading} onClick={onClick}>
          {label} <span className="kbd" style={{ marginLeft: 6 }}>{hotkey}</span>
        </Button>
        {suggested && <span className="decide-ai">AI 建议</span>}
      </span>
    </Tooltip>
  );
}

function TaskDetail({ t, writable, busy, pendingAction, onAction }: { t: ReviewTask; writable: boolean; busy: boolean; pendingAction?: ReviewDecideAction; onAction: (a: ReviewDecideAction) => void }) {
  const pending = t.status === 'pending';
  const reasons = t.risk_reasons ?? [];
  const imageOnly = IMAGE_ONLY.has(t.target_type);
  const [title, ...rest] = t.target_type === 'meetup' && t.text ? t.text.split('\n') : [null];
  const suggested = t.ai ? SUGGESTED_ACTION[t.ai.suggestion] : undefined;
  const violations = t.user_violation_count;
  const btn = (action: ReviewDecideAction, label: string, hotkey: string, icon: ReactNode, tip: ReactNode, o: { primary?: boolean; danger?: boolean } = {}) => (
    <DecisionButton
      action={action}
      label={label}
      hotkey={hotkey}
      icon={icon}
      tip={tip}
      {...o}
      suggested={suggested === action}
      disabled={!writable || (busy && pendingAction !== action)}
      loading={pendingAction === action}
      onClick={() => onAction(action)}
    />
  );
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
                <Link to={`/review?tab=posts&user_id=${t.user.id}&post=${t.target_id}`}>在动态管理中查看</Link>
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
              {PROFILE.includes(t.target_type) && '（已先生效，拒绝后恢复默认）'}
              {t.has_activity && <Tag bordered={false} color="blue" style={{ marginLeft: 8 }}>附带运动轨迹</Tag>}
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
        <Col xs={24} md={12}>
          <div className="panel" style={{ padding: 14, height: '100%' }}>
            <b>规则命中</b>
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
                  {PROFILE.includes(t.target_type) ? '未命中规则；资料类改动全部人工复核' : '未命中规则'}
                </div>
              )}
            </div>
          </div>
        </Col>
        <Col xs={24} md={12}>
          <AIVerdict t={t} />
        </Col>
        <Col xs={12}>
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
        <Col xs={12}>
          <div className={`tile${(violations ?? 0) >= 3 ? ' warn' : ''}`} style={{ height: '100%' }} aria-label="作者历史违规">
            <div className="tile-v num">{violations ?? '—'}</div>
            <div className="tile-l">作者历史违规（被拒绝 / 下架）{(violations ?? 0) >= 3 ? '，可考虑驳回并禁言' : ''}</div>
            <Link to={`/users?id=${t.user.id}`} style={{ fontSize: 12 }}>
              查看用户
            </Link>
          </div>
        </Col>
      </Row>

      {pending ? (
        <>
          <div className="decide-bar">
            {btn('approve', '通过', 'A', <CheckOutlined />, '直接通过', { primary: true })}
            {btn('approve_masked', '打码后通过', 'M', <HighlightOutlined />, maskEffect(t.target_type))}
            {t.has_activity && btn('approve_hide_endpoints', '隐藏起终点后通过', 'H', <EyeInvisibleOutlined />, '把这条动态附带运动的起终点隐藏半径设为 500 m 后通过，避免暴露住址')}
            {btn('reject', '驳回', 'R', <CloseOutlined />, '选择理由后驳回，通知作者', { danger: true })}
            {btn('reject_mute', '驳回并禁言', 'B', <StopOutlined />, '驳回并禁言作者（默认 7 天，可改）', { danger: true })}
          </div>
          <div className="muted" style={{ fontSize: 12, marginTop: 8 }}>
            {writable ? `驳回后：${REJECT_EFFECT[t.target_type] ?? '对其他人隐藏'}。处理后自动跳到下一条。` : '当前角色不能审核'}
            {t.ai?.suggestion === 'review' && ' AI 拿不准，建议人工判断。'}
          </div>
        </>
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
            {!t.reviewer && t.ai && <span className="muted">（按阈值自动处理）</span>}
          </Space>
        </div>
      )}
    </Panel>
  );
}
