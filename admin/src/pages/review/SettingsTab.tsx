// 内容审核 · 敏感词与审核设置 (admin only): GET / PUT /admin/v1/moderation/settings.
import { useEffect, useMemo, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alert, Button, Col, Empty, Input, InputNumber, Modal, Row, Skeleton, Slider, Space, Tag } from 'antd';
import { PlusOutlined, SnippetsOutlined } from '@ant-design/icons';
import { api } from '../../api/admin';
import type { ModerationSettings } from '../../api/types';
import { Panel } from '../../components/ui';
import { toastOk } from '../../utils/notify';
import { RiskBadge } from './shared';

// ---- local copy of the server's text scoring (server/internal/moderation, Check) for the 试一试 box ----
const rePhone = /1[3-9]\d{9}/;
const reURL = /(https?:\/\/|www\.)\S+|\b[a-z0-9-]+\.(com|cn|net|top|xyz|vip)\b/i;
const reWeChat = /(微信|vx|v信|wx|weixin|加v|qq|扣扣)\s*[:：号]?\s*[a-z0-9_-]{5,}/i;
const normalize = (s: string) => s.toLowerCase().replace(/[\s.\-_*·|/\\\u3000]/g, '');

function score(text: string, s: ModerationSettings): { value: number; reasons: string[]; blocked: boolean } {
  const norm = normalize(text);
  let value = 0;
  const reasons: string[] = [];
  let blocked = false;
  const add = (v: number, why: string) => {
    value = Math.max(value, v);
    reasons.push(why);
  };
  const hitBlock = s.block_words.find((w) => normalize(w) && norm.includes(normalize(w)));
  if (hitBlock) {
    add(100, `命中拦截词「${hitBlock}」`);
    blocked = true;
  }
  const hitReview = s.review_words.find((w) => normalize(w) && norm.includes(normalize(w)));
  if (hitReview) add(70, `命中审核词「${hitReview}」`);
  if (rePhone.test(norm) || reURL.test(text) || reWeChat.test(norm)) add(50, '含联系方式或网址');
  return { value, reasons, blocked };
}

function splitWords(raw: string): string[] {
  return raw
    .split(/[\n,，、;；]+/)
    .map((w) => w.trim())
    .filter(Boolean);
}

function merge(list: string[], add: string[]): { next: string[]; added: number; dup: number } {
  const seen = new Set(list.map((w) => w.toLowerCase()));
  const next = [...list];
  let added = 0;
  for (const w of add) {
    if (seen.has(w.toLowerCase())) continue;
    seen.add(w.toLowerCase());
    next.push(w);
    added++;
  }
  return { next, added, dup: add.length - added };
}

function WordEditor({
  title,
  hint,
  words,
  saved,
  other,
  otherName,
  onChange,
}: {
  title: string;
  hint: string;
  words: string[];
  saved: string[];
  other: string[];
  otherName: string;
  onChange: (w: string[]) => void;
}) {
  const [input, setInput] = useState('');
  const [filter, setFilter] = useState('');
  const [pasting, setPasting] = useState(false);
  const [paste, setPaste] = useState('');
  useEffect(() => {
    if (pasting) setPaste('');
  }, [pasting]);
  const savedSet = useMemo(() => new Set(saved), [saved]);
  const otherSet = useMemo(() => new Set(other.map((w) => w.toLowerCase())), [other]);
  const removed = saved.filter((w) => !words.includes(w));
  const shown = filter ? words.filter((w) => w.toLowerCase().includes(filter.toLowerCase())) : words;
  const dups = words.filter((w) => otherSet.has(w.toLowerCase()));

  const addInput = () => {
    const ws = splitWords(input);
    if (!ws.length) return;
    onChange(merge(words, ws).next);
    setInput('');
  };
  const pasted = splitWords(paste);
  const preview = merge(words, pasted);

  return (
    <Panel
      title={
        <div>
          <h2 className="panel-title">
            {title} <span className="muted num" style={{ fontSize: 13, fontWeight: 500 }}>{words.length} 个</span>
          </h2>
          <div className="panel-hint">{hint}</div>
        </div>
      }
      extra={
        <Button size="small" icon={<SnippetsOutlined />} onClick={() => setPasting(true)}>
          批量粘贴
        </Button>
      }
    >
      <Space.Compact style={{ width: '100%', marginBottom: 10 }}>
        <Input placeholder="输入一个词，回车添加（逗号分隔可一次加多个）" value={input} maxLength={40} onChange={(e) => setInput(e.target.value)} onPressEnter={addInput} aria-label={`添加${title}`} />
        <Button icon={<PlusOutlined />} onClick={addInput} disabled={!input.trim()}>
          添加
        </Button>
      </Space.Compact>
      {words.length > 20 && <Input size="small" allowClear placeholder="在列表里查找" value={filter} onChange={(e) => setFilter(e.target.value)} style={{ marginBottom: 8, width: 200 }} />}
      <div className="word-box">
        {shown.length === 0 ? (
          <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description={filter ? '没有匹配的词' : '还没有词'} style={{ margin: '8px auto' }} />
        ) : (
          shown.map((w) => (
            <Tag
              key={w}
              closable
              className={otherSet.has(w.toLowerCase()) ? 'dup' : savedSet.has(w) ? '' : 'added'}
              onClose={(e) => {
                e.preventDefault();
                onChange(words.filter((x) => x !== w));
              }}
            >
              {w}
            </Tag>
          ))
        )}
      </div>
      <div className="muted" style={{ fontSize: 12, marginTop: 8, display: 'flex', gap: 12, flexWrap: 'wrap' }}>
        {words.filter((w) => !savedSet.has(w)).length > 0 && <span style={{ color: 'var(--green)' }}>新增 {words.filter((w) => !savedSet.has(w)).length} 个（绿色）</span>}
        {removed.length > 0 && (
          <span className="danger-text">
            将删除 {removed.length} 个：{removed.slice(0, 8).join('、')}
            {removed.length > 8 ? '…' : ''}
          </span>
        )}
        {dups.length > 0 && <span className="danger-text">红色的词同时在「{otherName}」里，按更严的处理</span>}
        <span>不区分大小写，忽略空格和 . - _ * · 等分隔符（「微 信」也能命中「微信」）</span>
      </div>

      <Modal
        open={pasting}
        title={`批量粘贴${title}`}
        okText={preview.added ? `添加 ${preview.added} 个` : '添加'}
        okButtonProps={{ disabled: !preview.added }}
        cancelText="取消"
        onCancel={() => setPasting(false)}
        destroyOnHidden
        onOk={() => {
          onChange(preview.next);
          setPasting(false);
          toastOk(`已添加 ${preview.added} 个${preview.dup ? `，跳过重复 ${preview.dup} 个` : ''}，记得保存`);
        }}
      >
        <Input.TextArea rows={10} value={paste} onChange={(e) => setPaste(e.target.value)} placeholder={'每行一个词，也可以用逗号、顿号分隔\n例如：\n代跑\n刷单\n加微信'} autoFocus />
        <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>
          识别到 {pasted.length} 个，新增 {preview.added} 个{preview.dup ? `，已存在或重复 ${preview.dup} 个` : ''}
        </div>
      </Modal>
    </Panel>
  );
}

export default function SettingsTab() {
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['moderation', 'settings'], queryFn: api.moderationSettings });
  const [draft, setDraft] = useState<ModerationSettings | null>(null);
  const [probe, setProbe] = useState('加我微信 run_lulu88 一起代跑');
  useEffect(() => {
    if (q.data) setDraft(q.data);
  }, [q.data]);
  const save = useMutation({
    mutationFn: (s: ModerationSettings) => api.saveModerationSettings(s),
    onSuccess: (s) => {
      qc.setQueryData(['moderation', 'settings'], s);
      setDraft(s);
      toastOk('已保存，立即对新发布的内容生效');
    },
  });

  if (!draft || !q.data) return <Panel>{q.isError ? <Empty description="加载失败" /> : <Skeleton active paragraph={{ rows: 8 }} />}</Panel>;
  const saved = q.data;
  const dirty = JSON.stringify(draft) !== JSON.stringify(saved);
  const t = draft.auto_approve_below;
  const verdict = (v: number) => (v >= 100 ? <Tag color="red" bordered={false}>直接拒绝</Tag> : v >= t ? <Tag color="gold" bordered={false}>进入审核</Tag> : <Tag color="green" bordered={false}>直接通过</Tag>);
  const p = score(probe, draft);

  return (
    <>
      <Panel style={{ height: 'auto' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
          <div style={{ flex: 1, minWidth: 260 }}>
            <b>保存即生效</b>
            <span className="muted" style={{ fontSize: 13, marginLeft: 8 }}>
              只影响之后发布的动态、评论、消息、组局和资料修改；已在队列里的内容不重新打分。
            </span>
          </div>
          {dirty && <Tag color="lime">有未保存的改动</Tag>}
          <Button disabled={!dirty} onClick={() => setDraft(saved)}>
            撤销
          </Button>
          <Button type="primary" disabled={!dirty} loading={save.isPending} onClick={() => save.mutate(draft)}>
            保存设置
          </Button>
        </div>
      </Panel>

      <Row gutter={[20, 20]}>
        <Col xs={24} xl={12}>
          <WordEditor
            title="拦截词"
            hint="命中即风险分 100：发布直接失败，提示「内容包含违规信息」（不回显是哪个词）"
            words={draft.block_words}
            saved={saved.block_words}
            other={draft.review_words}
            otherName="审核词"
            onChange={(w) => setDraft({ ...draft, block_words: w })}
          />
        </Col>
        <Col xs={24} xl={12}>
          <WordEditor
            title="审核词"
            hint="命中即风险分 70：动态、评论进入审核队列；私信和群聊消息直接拒绝发送"
            words={draft.review_words}
            saved={saved.review_words}
            other={draft.block_words}
            otherName="拦截词"
            onChange={(w) => setDraft({ ...draft, review_words: w })}
          />
        </Col>

        <Col xs={24} xl={12}>
          <Panel title="审核阈值">
            <div className="rule-card" style={{ height: 'auto', ...(draft.auto_approve_below !== saved.auto_approve_below ? { background: '#f4fbd2' } : {}) }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 12 }}>
                <span style={{ fontSize: 13 }}>
                  风险分低于这个值的动态、评论<b>直接通过</b>
                </span>
                <InputNumber className="num" min={0} max={100} precision={0} value={draft.auto_approve_below} onChange={(v) => setDraft({ ...draft, auto_approve_below: v ?? 0 })} style={{ width: 90 }} aria-label="自动通过阈值" />
              </div>
              <Slider min={0} max={100} step={5} value={draft.auto_approve_below} onChange={(v) => setDraft({ ...draft, auto_approve_below: v })} marks={{ 0: '0', 30: '30 默认', 50: '50', 70: '70', 100: '100' }} />
              <div className="muted" style={{ fontSize: 12 }}>
                {t === 0 ? '设为 0：所有动态、评论都要人工审核。' : t > 70 ? '高于 70：命中审核词的内容也会直接发布，请谨慎。' : '昵称、头像、跑团名称和头像、简介不受阈值影响，全部先生效后审核。'}
              </div>
            </div>
            <div className="rule-card" style={{ height: 'auto', marginTop: 12, ...(draft.report_auto_hide !== saved.report_auto_hide ? { background: '#f4fbd2' } : {}) }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 12 }}>
                <span style={{ fontSize: 13 }}>被几个不同用户举报后，动态 / 评论自动转为待审核（对他人隐藏）</span>
                <InputNumber className="num" min={1} max={50} precision={0} value={draft.report_auto_hide} onChange={(v) => setDraft({ ...draft, report_auto_hide: v ?? 1 })} suffix="人" style={{ width: 110 }} aria-label="举报自动隐藏人数" />
              </div>
            </div>
          </Panel>
        </Col>
        <Col xs={24} xl={12}>
          <Panel title="打分规则与结果" extra={<span className="panel-hint">按当前阈值 {t}</span>}>
            {[
              { l: '命中拦截词', v: 100 },
              { l: '命中审核词', v: 70 },
              { l: '手机号、微信号、QQ 号、网址等联系方式', v: 50 },
              { l: '注册不满 24 小时的新用户发带图动态', v: 20, plus: true },
              { l: '其他', v: 0 },
            ].map((r) => (
              <div className="score-row" key={r.l}>
                <span>{r.l}</span>
                <span className="num" style={{ textAlign: 'right' }}>
                  {r.plus ? '+' : ''}
                  {r.v}
                </span>
                <span style={{ textAlign: 'right' }}>{r.plus ? <span className="muted" style={{ fontSize: 12 }}>叠加</span> : verdict(r.v)}</span>
              </div>
            ))}
            <div style={{ marginTop: 14 }}>
              <b style={{ fontSize: 13 }}>试一试</b>
              <span className="muted" style={{ fontSize: 12, marginLeft: 6 }}>
                用未保存的词表在本地估算，最终以服务端为准
              </span>
              <Input.TextArea rows={2} value={probe} onChange={(e) => setProbe(e.target.value)} style={{ marginTop: 6 }} maxLength={500} aria-label="试一试文本" />
              <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginTop: 8, flexWrap: 'wrap' }}>
                <RiskBadge score={p.value} />
                {verdict(p.value)}
                <span className="muted" style={{ fontSize: 12 }}>
                  {p.reasons.join('；') || '未命中规则'}
                </span>
              </div>
            </div>
          </Panel>
        </Col>
      </Row>
      {draft.block_words.length === 0 && draft.review_words.length === 0 && <Alert type="info" showIcon message="词表为空时只按联系方式和新用户规则打分。" />}
    </>
  );
}
