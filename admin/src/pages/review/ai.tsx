// AI verdict pieces for the 内容审核 queue (docs/api/v2-3-AI.md 「内容审核升级」).
import { Tag, Tooltip } from 'antd';
import type { ReviewAI, ReviewTask } from '../../api/types';
import { AI_LABEL, AI_SUGGESTION } from '../../utils/labels';
import { RiskBadge } from './shared';
import { Glyph } from '../../components/Glyph';

export function SuggestionTag({ s }: { s: string }) {
  const x = AI_SUGGESTION[s] ?? { text: s, color: 'default' };
  return (
    <Tag bordered={false} color={x.color} style={{ marginInlineEnd: 0 }}>
      {x.text}
    </Tag>
  );
}

/** Compact "AI 85 · 建议拒绝" chip for the queue list. */
export function AIChip({ ai }: { ai: ReviewAI | null | undefined }) {
  if (!ai) return null;
  const x = AI_SUGGESTION[ai.suggestion] ?? { text: ai.suggestion, color: 'default' };
  return (
    <Tooltip title={`${ai.model_name} 判定 · 置信度 ${Math.round(ai.confidence * 100)}%`}>
      <Tag bordered={false} color={x.color} icon={<Glyph name="quan" size={12} />} style={{ marginInlineEnd: 0 }} className="num">
        AI {ai.risk_score} · {x.text.replace('建议', '')}
      </Tag>
    </Tooltip>
  );
}

/** Full AI verdict box shown next to the rule reasons. */
export function AIVerdict({ t }: { t: ReviewTask }) {
  const ai = t.ai;
  if (!ai) {
    return (
      <div className="panel ai-box" style={{ padding: 14, height: '100%' }}>
        <b>
          <Glyph name="quan" size="1em" /> AI 判定
        </b>
        <div className="muted" style={{ fontSize: 13, padding: '6px 0' }}>
          {t.ai === undefined ? '服务端没有返回 AI 判定字段' : '没有 AI 判定：AI 审核未开启，或这次调用超时 / 失败，已先按规则分处理，后台会补打分'}
        </div>
      </div>
    );
  }
  const conf = Math.round(Math.max(0, Math.min(1, ai.confidence)) * 100);
  return (
    <div className="panel ai-box" style={{ padding: 14, height: '100%' }} aria-label="AI 判定">
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <b>
          <Glyph name="quan" size="1em" /> AI 判定
        </b>
        <RiskBadge score={ai.risk_score} />
        <SuggestionTag s={ai.suggestion} />
        <span className="muted" style={{ marginLeft: 'auto', fontSize: 12 }}>
          {ai.model_name}
        </span>
      </div>
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 10 }}>
        {ai.labels?.length ? (
          ai.labels.map((l) => (
            <Tag key={l} bordered={false} color="volcano" style={{ marginInlineEnd: 0 }}>
              {AI_LABEL[l] ?? l}
            </Tag>
          ))
        ) : (
          <span className="muted" style={{ fontSize: 12 }}>
            未发现违规类型
          </span>
        )}
      </div>
      <div className="ai-reason">{ai.reason || <span className="muted">（模型没有给出理由）</span>}</div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12 }}>
        <span className="muted" style={{ whiteSpace: 'nowrap' }}>
          置信度
        </span>
        <div className="bar-track" style={{ flex: 1 }} role="meter" aria-valuenow={conf} aria-valuemin={0} aria-valuemax={100} aria-label="置信度">
          <div className="bar-fill" style={{ width: `${conf}%`, background: conf >= 80 ? 'var(--ink)' : '#8a8a90' }} />
        </div>
        <b className="num">{conf}%</b>
      </div>
      <div className="muted" style={{ fontSize: 11, marginTop: 6 }}>
        内容由 AI 生成，仅供参考；最终风险分取规则分与 AI 分的较高者
      </div>
    </div>
  );
}
