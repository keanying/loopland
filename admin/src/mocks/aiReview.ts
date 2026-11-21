// Mock of the V2 第三批 AI moderation (docs/api/v2-3-AI.md 「内容审核升级」): a fake model verdict
// for each seeded review task, 「打码」 masking, and the threshold estimate from a fixed
// 7-day risk-score distribution.
import type { ReviewAI, ReviewTask } from '../api/types';

interface Rule {
  re: RegExp;
  score: number;
  labels: string[];
  suggestion: ReviewAI['suggestion'];
  reason: string;
  confidence: number;
}

// First match wins; order goes from the clearest violations to the mildest.
const TEXT_RULES: Rule[] = [
  { re: /代跑|代练|代刷|刷段位/, score: 94, labels: ['ad', 'fraud'], suggestion: 'reject', reason: '提供代跑、代练圈地服务并明码标价，属于作弊交易引流', confidence: 0.95 },
  { re: /兼职|日结|日赚|返利|返现/, score: 96, labels: ['fraud', 'ad'], suggestion: 'reject', reason: '以「跑步打卡赚钱」为诱饵的兼职刷单话术，典型诈骗引流', confidence: 0.93 },
  { re: /博彩|赌/, score: 98, labels: ['illegal'], suggestion: 'reject', reason: '涉及博彩，违法内容', confidence: 0.97 },
  { re: /福利|内部价|送跑步计划|前 ?50 ?名/, score: 88, labels: ['ad', 'contact'], suggestion: 'reject', reason: '以福利、内部价为名引导添加联系方式，商业引流', confidence: 0.9 },
  { re: /扫码进群/, score: 74, labels: ['ad'], suggestion: 'mask', reason: '跑团招新本身正常，但配图带二维码引导扫码进群，建议移除图片后通过', confidence: 0.81 },
  { re: /(微信|vx|wx|加 ?v|qq)\s*[:：]?\s*[a-z0-9_]{5,}/i, score: 68, labels: ['contact'], suggestion: 'mask', reason: '正文是正常的约跑交流，但留了个人微信 / QQ 号，打码联系方式后可以通过', confidence: 0.86 },
  { re: /www\.|\.top|\.com/i, score: 62, labels: ['contact', 'ad'], suggestion: 'mask', reason: '运动分享正常，结尾的外部网址疑似导流，建议打码网址后通过', confidence: 0.78 },
  { re: /傻|垃圾/, score: 72, labels: ['abuse'], suggestion: 'reject', reason: '对其他用户进行人身攻击', confidence: 0.88 },
  { re: /笑死/, score: 41, labels: ['abuse'], suggestion: 'review', reason: '带调侃语气评价他人配速，是否构成嘲讽需要结合上下文判断', confidence: 0.57 },
  { re: /出二手/, score: 46, labels: ['ad'], suggestion: 'review', reason: '个人闲置转让，含交易信息但没有联系方式，是否允许以社区规则为准', confidence: 0.62 },
  { re: /破 App|什么玩意/, score: 22, labels: [], suggestion: 'approve', reason: '对产品的负面评价，情绪化但不针对个人，不构成辱骂', confidence: 0.74 },
  { re: /家门口|楼下|小区/, score: 58, labels: ['privacy'], suggestion: 'hide_endpoints', reason: '正文提到从家门口 / 小区出发，附带轨迹的起终点可能暴露住址，建议隐藏起终点后通过', confidence: 0.83 },
];

const IMAGE_RULES: Rule[] = [
  { re: /进群返现|日赚五百/, score: 93, labels: ['fraud', 'ad'], suggestion: 'reject', reason: '图片是「进群返现」类诈骗广告', confidence: 0.94 },
  { re: /扫码领跑鞋/, score: 86, labels: ['ad'], suggestion: 'reject', reason: '头像是带二维码的跑鞋广告图', confidence: 0.91 },
];

/** Fixed per-task seed so the same task always gets the same verdict. */
const jitter = (id: number, span: number) => ((id * 2654435761) >>> 0) % (span * 2 + 1) - span;

export function aiVerdict(t: ReviewTask, imageHint: string | null, model: { text: string; vision: string }): ReviewAI | null {
  // A few tasks where the model timed out → scored by rules only (ai = null).
  if (t.id % 11 === 7 || t.text?.startsWith('楼主是傻吗')) return null;
  const text = t.text ?? '';
  const hit = (imageHint && IMAGE_RULES.find((r) => r.re.test(imageHint))) || TEXT_RULES.find((r) => r.re.test(text));
  const visual = !!imageHint && !!t.images?.length && !text;
  if (visual && !model.vision) return null;
  const model_name = visual ? `${model.text} VL` : model.text;
  if (!hit) {
    const score = Math.max(1, 6 + jitter(t.id, 4));
    return {
      risk_score: score,
      labels: [],
      reason: visual ? '普通头像 / 合影，没有发现违规元素' : t.target_type === 'nickname' || t.target_type === 'crew_name' ? '名称正常，与运动相关' : '正常的运动分享，没有发现违规',
      confidence: +(0.9 + jitter(t.id, 4) / 100).toFixed(2),
      suggestion: 'approve',
      model_name,
    };
  }
  return { risk_score: Math.min(100, hit.score + jitter(t.id, 2)), labels: hit.labels, reason: hit.reason, confidence: hit.confidence, suggestion: hit.suggestion, model_name };
}

const MASK_RES = [
  /(微信|vx|v信|wx|weixin|加\s*v|qq|扣扣)(\s*[:：号]?\s*)([a-z0-9_-]{5,})/gi,
  /1[3-9]\d{9}/g,
  /\d{6,11}/g,
  /(https?:\/\/|www\.)\S+|\b[a-z0-9-]+\.(com|cn|net|top|xyz|vip)\b/gi,
];

/** 「打码后通过」: contact details and hit words become *. */
export function maskText(text: string, words: string[]): string {
  let out = text;
  for (const re of MASK_RES) out = out.replace(re, (m) => '*'.repeat(m.length));
  for (const w of words) if (w) out = out.split(w).join('*'.repeat(w.length));
  return out;
}

// ---- 预计每天人工量 ----
// Share of the last 7 days' content at each final risk score 0–100 (most content scores
// near 0; a bump at 50 for contact details, at 70 for review words, a spike at 100).
const PER_DAY = 868;
const WEIGHTS: number[] = Array.from({ length: 101 }, (_, s) => {
  let w = 70 * Math.exp(-s / 3.2) + 6 * Math.exp(-((s - 14) ** 2) / 30);
  w += 1.6 * Math.exp(-((s - 50) ** 2) / 18) + 1.2 * Math.exp(-((s - 70) ** 2) / 14) + 0.35 * Math.exp(-((s - 88) ** 2) / 20);
  if (s === 100) w += 3.2;
  return w;
});
const SUM = WEIGHTS.reduce((a, b) => a + b, 0);

export function estimate(approveBelow: number, rejectAbove: number) {
  let a = 0;
  let r = 0;
  WEIGHTS.forEach((w, s) => {
    if (s < approveBelow) a += w;
    else if (s >= rejectAbove) r += w;
  });
  const k = PER_DAY / SUM;
  const round = (x: number) => Math.round(x * 10) / 10;
  const approve = round(a * k);
  const reject = round(r * k);
  return { per_day_manual: round(PER_DAY - approve - reject), per_day_auto_approve: approve, per_day_auto_reject: reject, days: 7 };
}
