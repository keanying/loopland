// 内容审核 · 举报处理: GET /admin/v1/reports, POST /reports/{id}/handle (remove + mute / dismiss).
import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, Button, Drawer, Empty, Input, InputNumber, Modal, Segmented, Select, Space, Table, Tag, Typography } from 'antd';
import { FlagFilled } from '@ant-design/icons';
import { api, PAGE_SIZE } from '../../api/admin';
import type { AdminReport, ReportHandle, ReportStatus, ReportTargetType } from '../../api/types';
import { useAuth } from '../../auth/AuthContext';
import { useAdminNames } from '../../hooks/useAdminNames';
import { Panel } from '../../components/ui';
import { ago, dt } from '../../utils/format';
import { REPORT_REASON, REPORT_REMOVE_EFFECT, REPORT_STATUS, REPORT_TARGET } from '../../utils/labels';
import { toastOk } from '../../utils/notify';

const MUTE_PRESETS = [0, 1, 3, 7, 30];

function TargetCell({ r }: { r: AdminReport }) {
  return (
    <div style={{ maxWidth: 360 }}>
      <Space size={6} style={{ marginBottom: 2 }}>
        <Tag bordered={false} color={REPORT_TARGET[r.target_type]?.color} style={{ marginInlineEnd: 0 }}>
          {REPORT_TARGET[r.target_type]?.text ?? r.target_type}
        </Tag>
        <span className="muted num" style={{ fontSize: 12 }}>
          #{r.target_id}
        </span>
      </Space>
      <Typography.Paragraph ellipsis={{ rows: 2 }} style={{ margin: 0, fontSize: 13 }}>
        {r.target_preview || <span className="muted">（无摘要）</span>}
      </Typography.Paragraph>
    </div>
  );
}

export default function ReportsTab() {
  const qc = useQueryClient();
  const { can } = useAuth();
  const writable = can('review.write');
  const adminName = useAdminNames();
  const [params, setParams] = useSearchParams();
  const status = (['handled', 'dismissed'].includes(params.get('status') ?? '') ? params.get('status') : 'pending') as ReportStatus;
  const type = (params.get('type') ?? '') as ReportTargetType | '';
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

  const list = useQuery({ queryKey: ['reports', status, type, page], queryFn: () => api.reports({ status, target_type: type, page }), placeholderData: (p) => p });
  const pendingTotal = useQuery({ queryKey: ['reports', 'pending', '', 1], queryFn: () => api.reports({ status: 'pending', page: 1 }) });
  const [viewing, setViewing] = useState<AdminReport | null>(null);
  const [handling, setHandling] = useState<{ r: AdminReport; action: ReportHandle['action'] } | null>(null);

  return (
    <Panel
      title="举报处理"
      extra={
        <Space wrap>
          <Select
            style={{ width: 140 }}
            value={type}
            onChange={(v) => set({ type: v || null, page: null })}
            options={[{ label: '全部对象', value: '' }, ...Object.entries(REPORT_TARGET).map(([value, t]) => ({ value, label: t.text }))]}
          />
          <Segmented
            value={status}
            onChange={(v) => set({ status: v === 'pending' ? null : String(v), page: null })}
            options={[
              { label: `待处理${pendingTotal.data ? ` ${pendingTotal.data.total}` : ''}`, value: 'pending' },
              { label: '已下架', value: 'handled' },
              { label: '已驳回', value: 'dismissed' },
            ]}
          />
        </Space>
      }
    >
      <div className="panel-hint" style={{ marginTop: -6, marginBottom: 10 }}>
        下架会一并处理同一对象的其他举报；被 3 个不同用户举报的动态、评论已自动转入审核队列（阈值见「敏感词与审核设置」）。
      </div>
      <Table<AdminReport>
        rowKey="id"
        loading={list.isFetching}
        dataSource={list.data?.items}
        scroll={{ x: 1100 }}
        onRow={(r) => ({ onClick: () => setViewing(r), style: { cursor: 'pointer' } })}
        locale={{ emptyText: <Empty description={pending ? '没有待处理的举报' : '暂无记录'} /> }}
        pagination={{
          current: page,
          pageSize: PAGE_SIZE,
          total: list.data?.total ?? 0,
          showSizeChanger: false,
          showTotal: (t) => `共 ${t} 条`,
          onChange: (p) => set({ page: p === 1 ? null : String(p) }),
        }}
        columns={[
          { title: '被举报对象', key: 'target', render: (_, r) => <TargetCell r={r} /> },
          {
            title: '原因',
            key: 'reason',
            render: (_, r) => (
              <div style={{ maxWidth: 200 }}>
                <b>{REPORT_REASON[r.reason] ?? r.reason}</b>
                {r.detail && (
                  <div className="muted" style={{ fontSize: 12 }}>
                    {r.detail}
                  </div>
                )}
              </div>
            ),
          },
          {
            title: '同对象举报',
            dataIndex: 'report_count',
            align: 'right',
            render: (v: number) => (
              <span className={`num${v >= 3 ? ' danger-text' : ''}`} style={{ fontWeight: v >= 3 ? 700 : 400 }}>
                {v >= 3 && <FlagFilled style={{ marginRight: 4 }} />}
                {v} 人
              </span>
            ),
          },
          { title: '举报人', key: 'reporter', render: (_, r) => <span>{r.reporter.nickname} <span className="muted num">#{r.reporter.id}</span></span> },
          { title: '举报时间', dataIndex: 'created_at', render: (v: string) => <span className="muted num" title={dt(v)}>{ago(v)}</span> },
          ...(pending
            ? []
            : [
                {
                  title: '处理',
                  key: 'handled',
                  render: (_: unknown, r: AdminReport) => (
                    <div>
                      <Tag bordered={false} color={REPORT_STATUS[r.status]?.color}>
                        {REPORT_STATUS[r.status]?.text ?? r.status}
                      </Tag>
                      <div className="muted" style={{ fontSize: 12 }}>
                        {adminName(r.handled_by)} · {dt(r.handled_at, 'MM-DD HH:mm')}
                      </div>
                    </div>
                  ),
                },
              ]),
          {
            title: '操作',
            key: 'op',
            align: 'right',
            render: (_, r) =>
              r.status === 'pending' ? (
                <Space onClick={(e) => e.stopPropagation()}>
                  <Button size="small" danger disabled={!writable} onClick={() => setHandling({ r, action: 'remove' })}>
                    下架
                  </Button>
                  <Button size="small" disabled={!writable} onClick={() => setHandling({ r, action: 'dismiss' })}>
                    驳回
                  </Button>
                </Space>
              ) : (
                <Button size="small" type="link" onClick={(e) => {
                    e.stopPropagation();
                    setViewing(r);
                  }}>
                  查看
                </Button>
              ),
          },
        ]}
      />

      <Drawer open={viewing !== null} onClose={() => setViewing(null)} width={480} title={viewing ? `举报 #${viewing.id}` : ''}>
        {viewing && (
          <>
            <div className="tile" style={{ marginBottom: 14 }}>
              <div className="muted" style={{ fontSize: 12, marginBottom: 6 }}>
                被举报的{REPORT_TARGET[viewing.target_type]?.text ?? '对象'} #{viewing.target_id}
              </div>
              <div className="rv-detail-text">{viewing.target_preview || '（无摘要）'}</div>
              {viewing.target_type === 'post' && (
                <Link to={`/review?tab=posts&q=${encodeURIComponent((viewing.target_preview ?? '').slice(0, 20))}&post=${viewing.target_id}`} style={{ fontSize: 12 }}>
                  在动态管理中查看完整动态
                </Link>
              )}
            </div>
            <div className="kv">
              <span>原因</span>
              <span>{REPORT_REASON[viewing.reason] ?? viewing.reason}</span>
              <span>补充说明</span>
              <span>{viewing.detail || '—'}</span>
              <span>举报人</span>
              <span>
                {viewing.reporter.nickname} #{viewing.reporter.id}
              </span>
              <span>同一对象被举报</span>
              <span className={viewing.report_count >= 3 ? 'danger-text' : ''}>{viewing.report_count} 人</span>
              <span>举报时间</span>
              <span>{dt(viewing.created_at)}</span>
              <span>状态</span>
              <span>
                <Tag bordered={false} color={REPORT_STATUS[viewing.status]?.color} style={{ marginInlineEnd: 0 }}>
                  {REPORT_STATUS[viewing.status]?.text}
                </Tag>
              </span>
              {viewing.status !== 'pending' && (
                <>
                  <span>处理人</span>
                  <span>
                    {adminName(viewing.handled_by)} · {dt(viewing.handled_at)}
                  </span>
                </>
              )}
            </div>
            {viewing.status === 'pending' && (
              <Space style={{ marginTop: 20 }}>
                <Button danger type="primary" disabled={!writable} onClick={() => setHandling({ r: viewing, action: 'remove' })}>
                  下架
                </Button>
                <Button disabled={!writable} onClick={() => setHandling({ r: viewing, action: 'dismiss' })}>
                  驳回
                </Button>
              </Space>
            )}
          </>
        )}
      </Drawer>

      <HandleModal
        value={handling}
        onClose={() => setHandling(null)}
        onDone={() => {
          setHandling(null);
          setViewing(null);
          qc.invalidateQueries({ queryKey: ['reports'] });
          qc.invalidateQueries({ queryKey: ['posts'] });
          qc.invalidateQueries({ queryKey: ['reviews'] });
        }}
      />
    </Panel>
  );
}

function HandleModal({ value, onClose, onDone }: { value: { r: AdminReport; action: ReportHandle['action'] } | null; onClose: () => void; onDone: () => void }) {
  const [mute, setMute] = useState<number>(0);
  const [note, setNote] = useState('');
  const handle = useMutation({
    mutationFn: (body: ReportHandle) => api.handleReport(value!.r.id, body),
    onSuccess: (_, body) => {
      toastOk(body.action === 'remove' ? `已下架${body.mute_days ? `，作者禁言 ${body.mute_days} 天` : ''}` : '已驳回举报');
      onDone();
    },
  });
  const open = value !== null;
  useEffect(() => {
    if (open) {
      setMute(0);
      setNote('');
    }
  }, [open]);
  const r = value?.r;
  const remove = value?.action === 'remove';
  const author = r && (r.target_type === 'user' ? '该用户' : r.target_type === 'crew' ? '团长' : '作者');
  return (
    <Modal
      open={value !== null}
      title={r ? `${remove ? '下架' : '驳回举报'}：${REPORT_TARGET[r.target_type]?.text ?? ''} #${r.target_id}` : ''}
      okText={remove ? '下架' : '驳回'}
      cancelText="取消"
      okButtonProps={{ danger: remove, loading: handle.isPending }}
      onCancel={onClose}
      onOk={() => handle.mutate({ action: value!.action, mute_days: remove ? mute : 0, note: note.trim() })}
    >
      {r && (
        <>
          <div className="tile" style={{ marginBottom: 12, fontSize: 13 }}>
            {r.target_preview || '（无摘要）'}
          </div>
          {remove ? (
            <>
              <Alert
                type="warning"
                showIcon
                style={{ marginBottom: 12 }}
                message={`${REPORT_REMOVE_EFFECT[r.target_type] ?? '下架该对象'}${r.report_count > 1 ? `；同一对象的 ${r.report_count} 条举报一起标记为已处理` : ''}。`}
              />
              <div style={{ marginBottom: 6 }}>同时禁言{author}</div>
              <Space wrap style={{ marginBottom: 12 }}>
                <Segmented value={MUTE_PRESETS.includes(mute) ? mute : -1} onChange={(v) => Number(v) >= 0 && setMute(Number(v))} options={[...MUTE_PRESETS.map((d) => ({ label: d ? `${d} 天` : '不禁言', value: d })), ...(MUTE_PRESETS.includes(mute) ? [] : [{ label: `${mute} 天`, value: -1 }])]} />
                <InputNumber className="num" min={0} max={365} precision={0} value={mute} onChange={(v) => setMute(v ?? 0)} suffix="天" style={{ width: 120 }} aria-label="禁言天数" />
              </Space>
            </>
          ) : (
            <p className="muted" style={{ fontSize: 13 }}>
              判定举报不成立，对象保持原样，只关闭这一条举报。
            </p>
          )}
          <Input.TextArea rows={2} maxLength={200} showCount placeholder="备注（可选，写入审计日志）" value={note} onChange={(e) => setNote(e.target.value)} />
        </>
      )}
    </Modal>
  );
}
