// Mock of V2 第二批「社区」管理端 (docs/api/v2-2-社区.md «管理端»): review queue, reports,
// posts, moderation settings, meetups, races. Validation mirrors the contract and
// server/internal/moderation; every write adds an audit entry through `log`.
import { ApiError } from '../api/client';
import type {
  AdminPost,
  AdminReport,
  AdminRef,
  AdminRole,
  Meetup,
  MeetupStatus,
  ModerationSettings,
  Place,
  Race,
  RaceEntry,
  RaceInput,
  RaceStatus,
  ReportReason,
  ReportTargetType,
  ReviewStats,
  ReviewStatus,
  ReviewTargetType,
  ReviewTask,
  UserBrief,
} from '../api/types';
import * as db from './data';
import { avatar, photo, promo } from './images';

type Ctx = { m: RegExpMatchArray; q: URLSearchParams; body: Record<string, unknown>; adminId: number; role: AdminRole };
type Handler = (ctx: Ctx) => unknown;
type Log = (adminId: number, action: string, target: string, detail?: Record<string, unknown>) => void;

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const NOW = Date.now();
const iso = (ms: number) => new Date(ms).toISOString();
const ago = (ms: number) => iso(NOW - ms);

function fail(status: number, code: string, message: string): never {
  throw new ApiError(status, code, message);
}
const clone = <T,>(x: T): T => JSON.parse(JSON.stringify(x)) as T;
function paginate<T>(items: T[], q: URLSearchParams) {
  const page = Math.max(1, Number(q.get('page') ?? 1));
  const size = Math.min(100, Math.max(1, Number(q.get('page_size') ?? 20)));
  return { items: items.slice((page - 1) * size, page * size), total: items.length };
}
function requireRole(role: AdminRole, allowed: AdminRole[]) {
  if (!allowed.includes(role)) fail(403, 'forbidden', '当前角色没有权限执行此操作');
}
const REVIEW_ROLES: AdminRole[] = ['admin', 'ops', 'reviewer'];
const COMMUNITY_ROLES: AdminRole[] = ['admin', 'ops'];

// Own seeded RNG so the V1 / V2-1 fixtures (and their screenshots) stay unchanged.
let seed = 20261121;
function rnd() {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const int = (lo: number, hi: number) => Math.floor(lo + rnd() * (hi - lo + 1));

function brief(i: number): UserBrief {
  const u = db.users[i % db.users.length];
  return { id: u.id, nickname: u.nickname, avatar_url: null, crew: u.crew ? { ...u.crew } : null };
}
const adminRef = (id: number): AdminRef => {
  const a = db.admins.find((x) => x.id === id)!;
  return { id: a.id, username: a.username };
};

const CENTER = { lng: 121.505, lat: 31.232 };

function loopTrack(k: number): number[][] {
  const cx = CENTER.lng - 0.03 + (k % 7) * 0.01;
  const cy = CENTER.lat - 0.02 + (k % 5) * 0.008;
  const pts: number[][] = [];
  for (let j = 0; j <= 40; j++) {
    const a = (j / 40) * Math.PI * 2;
    const r = 0.006 + Math.sin(a * 3 + k) * 0.0015;
    pts.push([+(cx + Math.cos(a) * r * 1.2).toFixed(6), +(cy + Math.sin(a) * r).toFixed(6)]);
  }
  return pts.slice(3, -3);
}

// ---------------- settings ----------------

export const settings: ModerationSettings = {
  block_words: ['代刷', '刷单返利', '赌博', '博彩', '裸聊', '发票代开'],
  review_words: ['代跑', '代练', '出二手', '扫码进群', '领福利', '垃圾', '加V', '兼职', '笑死', '傻'],
  auto_approve_below: 30,
  report_auto_hide: 3,
};

// ---------------- posts ----------------

interface PostSeed {
  content: string;
  images?: string[];
  promo?: string;
  sport?: string;
  km?: number;
  vis?: AdminPost['visibility'];
  st?: ReviewStatus;
  reject?: string;
  deleted?: boolean;
  /** Review task for this post: risk score + reasons (pending posts need one). */
  risk?: [number, string[]];
  reports?: number;
}

const POST_SEEDS: PostSeed[] = [
  { content: '今天世纪公园 10K 配速 5\'20"，想找固定搭子一起练，加我微信 run_lulu88', images: ['世纪公园晨跑', '配速截图'], km: 10.2, st: 'pending', risk: [50, ['含联系方式：疑似微信号']] },
  { content: '代跑代练圈地，包月 30 元，领地保底 20 块，私聊下单', km: 0, st: 'pending', risk: [70, ['命中审核词：代跑', '命中审核词：代练']], reports: 2 },
  { content: '滨江夜跑团招新！每周三、六晚 8 点东昌路渡口集合，扫码进群', promo: '滨江夜跑团招新', km: 6.4, st: 'pending', risk: [90, ['命中审核词：扫码进群', '新用户发图 +20']] },
  { content: '出二手佳明 255，9 成新，带原装充电线，价格私信可小刀', images: ['手表正面'], st: 'pending', risk: [70, ['命中审核词：出二手']] },
  { content: '这破 App 圈的地天天被抢，做得什么玩意儿', km: 3.1, st: 'pending', risk: [0, ['被 3 人举报']], reports: 3 },
  { content: '第一次夜跑外滩，灯光太美了，详情看主页 www.runjoy.top', images: ['外滩夜景', '万国建筑', '自拍'], km: 5.6, st: 'pending', risk: [70, ['含联系方式：网址', '新用户发图 +20']] },
  { content: '兼职日结，每天跑步打卡 200 元，有意者看简介', st: 'pending', risk: [70, ['命中审核词：兼职']], reports: 1 },
  { content: '下雨天也要跑！徐汇滨江 8 公里，鞋全湿了', images: ['雨中滨江'], km: 8.0, st: 'approved' },
  { content: '终于把小区旁边那块地抢回来了，守卫值拉满', km: 4.3, st: 'approved', vis: 'fans' },
  { content: '跑团周三夜跑集结，签到 6 人，伤害加成到手', images: ['集结合影', '路线'], km: 7.5, st: 'approved', vis: 'crew' },
  { content: '新年目标：全年 2026 公里，今天打卡第一天', km: 5.0, st: 'approved' },
  { content: '骑行去奉贤海湾，来回 86 公里，腿已经不是自己的了', images: ['海湾大道', '补给站'], sport: 'ride', km: 86.2, st: 'approved' },
  { content: '和沙发怪打了 3 次合击，终于拿到图纸了', km: 6.1, st: 'approved' },
  { content: '晨跑看到的苏州河，安静得像一幅画', images: ['苏州河清晨'], km: 6.8, st: 'approved' },
  { content: '今天只走了 4 公里，膝盖有点不舒服，休息两天', sport: 'walk', km: 4.1, st: 'approved', vis: 'private' },
  { content: '世纪公园一圈 5 公里，新手友好，推荐给刚开始跑的朋友', images: ['公园地图'], km: 5.1, st: 'approved' },
  { content: '加微信 xiaoma_run 送跑步计划，前 50 名免费', st: 'rejected', reject: '含联系方式', risk: [50, ['含联系方式：疑似微信号']] },
  { content: '刷单返利日赚 500，详情私聊', st: 'rejected', reject: '含广告或引流', risk: [70, ['命中审核词：兼职']] },
  { content: '徐汇这边谁在抢我地？有种出来单挑', km: 3.3, st: 'approved', deleted: true, reports: 4 },
  { content: '周末带娃在前滩公园慢跑，小朋友比我还能跑', images: ['前滩公园', '亲子跑'], km: 3.0, st: 'approved' },
  { content: '配速突破 5 分了！感谢跑团各位大佬带', km: 10.0, st: 'approved', vis: 'crew' },
  { content: '图鉴收集到 23 个了，还差雾霾怪的蛋', st: 'approved' },
  { content: '夜跑兔今天又破纪录了，22 公里', images: ['夜跑兔', '奖牌'], km: 22.0, st: 'approved' },
  { content: '来张江跑步的程序员们，下班一起跑啊', km: 5.4, st: 'pending', risk: [30, ['新用户发图 +20', '含联系方式：疑似手机号片段']], images: ['张江夜色'] },
];

let postSeq = 100;
export const posts: AdminPost[] = POST_SEEDS.map((s, i) => {
  const id = ++postSeq;
  const sport = s.sport ?? 'run';
  const distance = Math.round((s.km ?? 0) * 1000);
  const pace = sport === 'run' ? int(290, 400) : sport === 'walk' ? int(560, 720) : null;
  const duration = distance ? Math.round(sport === 'ride' ? (distance / 1000) * int(130, 170) : (distance / 1000) * (pace ?? 360)) : 0;
  const started = NOW - (i * 5 + 2) * HOUR - int(0, 50) * MIN;
  const imgs = s.promo ? [promo(i, s.promo)] : (s.images ?? []).map((c, k) => photo(i * 3 + k, c));
  const approvedSocial = s.st === 'approved';
  return {
    id,
    author: brief(i * 3 + 1),
    content: s.content,
    images: imgs.map((url) => ({ url, width: 1080, height: 1440 })),
    activity: distance
      ? { id: 5000 + i, sport, distance_m: distance, duration_sec: duration, pace_sec_per_km: pace, claimed_area_m2: sport === 'run' ? int(0, 40) * 1000 : 0, start_time: iso(started), track: loopTrack(i) }
      : null,
    visibility: s.vis ?? 'public',
    review_status: s.st ?? 'approved',
    reject_reason: s.reject ?? null,
    like_count: approvedSocial ? int(2, 260) : 0,
    comment_count: approvedSocial ? int(0, 40) : 0,
    collect_count: approvedSocial ? int(0, 30) : 0,
    share_count: approvedSocial ? int(0, 12) : 0,
    created_at: iso(started + duration * 1000 + 10 * MIN),
    deleted: !!s.deleted,
  };
});

// ---------------- review tasks ----------------

let taskSeq = 30;
export const tasks: ReviewTask[] = [];

function addTask(t: Partial<ReviewTask> & Pick<ReviewTask, 'target_type' | 'target_id' | 'user' | 'risk_score'>) {
  tasks.push({
    id: ++taskSeq,
    text: null,
    images: null,
    risk_reasons: [],
    report_count: 0,
    status: 'pending',
    reject_reason: null,
    reviewer: null,
    reviewed_at: null,
    created_at: ago(int(10, 600) * MIN),
    ...t,
  });
}

posts.forEach((p, i) => {
  const s = POST_SEEDS[i];
  if (!s.risk) return;
  const decided = p.review_status !== 'pending';
  addTask({
    target_type: 'post',
    target_id: p.id,
    user: { id: p.author.id, nickname: p.author.nickname },
    text: p.content,
    images: p.images.map((x) => x.url),
    risk_score: s.risk[0],
    risk_reasons: s.risk[1],
    report_count: s.reports ?? 0,
    status: p.review_status,
    reject_reason: p.reject_reason,
    reviewer: decided ? adminRef(i % 2 ? 3 : 1) : null,
    reviewed_at: decided ? ago(int(1, 30) * HOUR) : null,
    created_at: p.created_at,
  });
});

interface OtherSeed {
  type: ReviewTargetType;
  text?: string;
  img?: string;
  score: number;
  reasons?: string[];
  reports?: number;
  st?: ReviewStatus;
  reject?: string;
  /** Reviewed this many hours ago (history only). */
  h?: number;
}

const OTHER_SEEDS: OtherSeed[] = [
  { type: 'comment', text: '跑成这样还好意思发，垃圾', score: 70, reasons: ['命中审核词：垃圾'], reports: 1 },
  { type: 'comment', text: '想要同款跑鞋的加 V：xiezi_2026，内部价', score: 70, reasons: ['命中审核词：加V', '含联系方式：疑似微信号'] },
  { type: 'comment', text: '加 qq 3302581146 带你刷段位', score: 50, reasons: ['含联系方式：疑似 QQ 号'] },
  { type: 'comment', text: '楼主是傻吗，地都守不住', score: 70, reasons: ['命中审核词：傻'], reports: 3 },
  { type: 'comment', text: '笑死，这配速走路都比你快', score: 70, reasons: ['命中审核词：笑死'] },
  { type: 'nickname', text: '加V看主页领福利', score: 70, reasons: ['命中审核词：领福利', '命中审核词：加V'] },
  { type: 'nickname', text: '外滩追风少年', score: 0 },
  { type: 'nickname', text: '跑步代练-接单', score: 70, reasons: ['命中审核词：代练'] },
  { type: 'nickname', text: '陆家嘴晨跑小王', score: 0 },
  { type: 'avatar', img: 'avatar', score: 0 },
  { type: 'avatar', img: 'promo:扫码领跑鞋', score: 20, reasons: ['新用户 +20'] },
  { type: 'avatar', img: 'avatar', score: 0 },
  { type: 'crew_name', text: '免费领跑鞋福利群', score: 70, reasons: ['命中审核词：领福利'] },
  { type: 'crew_name', text: '张江夜跑联盟', score: 0 },
  { type: 'crew_avatar', img: 'photo:跑团合影', score: 0 },
  { type: 'crew_avatar', img: 'promo:进群返现', score: 0, reports: 2 },
  { type: 'bio', text: '商务合作 vx：lpl_run2026', score: 50, reasons: ['含联系方式：疑似微信号'] },
  { type: 'bio', text: '每天 5 公里，坚持第 300 天', score: 0 },
  { type: 'meetup', text: '周日奉贤海湾骑行 60km\n有意者加微信 ride_fx 拉群，自备头盔', score: 50, reasons: ['含联系方式：疑似微信号'] },
  { type: 'meetup', text: '周六外滩约跑\n跑完去吃火锅，AA，顺便介绍兼职', score: 70, reasons: ['命中审核词：兼职'] },
  // history
  { type: 'comment', text: '加油！下次一起跑', score: 30, reasons: ['新用户 +20'], st: 'approved', h: 2 },
  { type: 'comment', text: '代刷段位，便宜', score: 70, reasons: ['命中审核词：代跑'], st: 'rejected', reject: '含广告或引流', h: 3 },
  { type: 'nickname', text: '闵行小飞', score: 0, st: 'approved', h: 1 },
  { type: 'nickname', text: '博彩老司机', score: 70, reasons: ['命中审核词：博彩'], st: 'rejected', reject: '昵称或头像不合规', h: 5 },
  { type: 'avatar', img: 'avatar', score: 0, st: 'approved', h: 4 },
  { type: 'crew_name', text: '徐汇跑鞋团', score: 0, st: 'approved', h: 26 },
  { type: 'crew_avatar', img: 'promo:日赚五百', score: 0, st: 'rejected', reject: '含广告或引流', h: 30 },
  { type: 'bio', text: '想跑全马的来找我，vx: mara_shanghai', score: 50, reasons: ['含联系方式：疑似微信号'], st: 'rejected', reject: '含联系方式', h: 6 },
  { type: 'meetup', text: '周三晚世纪公园约跑\n配速 6 分左右，跑 10 公里', score: 30, reasons: ['新用户 +20'], st: 'approved', h: 8 },
  { type: 'comment', text: '这条路线我也跑过，风景很好', score: 30, reasons: ['被 3 人举报'], st: 'approved', h: 50 },
];

OTHER_SEEDS.forEach((s, i) => {
  const u = brief(i * 5 + 2);
  const img =
    s.img === undefined ? null : s.img === 'avatar' ? avatar(i, u.nickname.slice(0, 1)) : s.img.startsWith('promo:') ? promo(i, s.img.slice(6)) : photo(i, s.img.slice(6), 1080, 1080);
  const decided = !!s.st && s.st !== 'pending';
  const targetId = s.type === 'comment' ? 900 + i : s.type === 'crew_name' || s.type === 'crew_avatar' ? [3, 5, 8, 9][i % 4] : s.type === 'meetup' ? (s.text?.startsWith('周日奉贤') ? 10 : 40 + i) : u.id;
  addTask({
    target_type: s.type,
    target_id: targetId,
    user: { id: u.id, nickname: u.nickname },
    text: s.text ?? null,
    images: img ? [img] : null,
    risk_score: s.score,
    risk_reasons: s.reasons ?? [],
    report_count: s.reports ?? 0,
    status: s.st ?? 'pending',
    reject_reason: s.reject ?? null,
    reviewer: decided ? adminRef(i % 3 === 0 ? 1 : 3) : null,
    reviewed_at: decided ? ago((s.h ?? 1) * HOUR) : null,
    created_at: decided ? ago((s.h ?? 1) * HOUR + int(5, 90) * MIN) : ago(int(8, 900) * MIN),
  });
});

function reviewStats(): ReviewStats {
  const pending = tasks.filter((t) => t.status === 'pending');
  const by_type: ReviewStats['by_type'] = {};
  for (const t of pending) by_type[t.target_type] = (by_type[t.target_type] ?? 0) + 1;
  const start = new Date();
  start.setHours(0, 0, 0, 0);
  const today_done = tasks.filter((t) => t.reviewed_at && Date.parse(t.reviewed_at) >= start.getTime()).length + 37;
  return { pending: pending.length, today_done, by_type };
}

/** Number shown on 总览 (M-01). */
export function pendingReviews(): number {
  return tasks.filter((t) => t.status === 'pending').length;
}

function decide(t: ReviewTask, approve: boolean, reason: string, adminId: number) {
  t.status = approve ? 'approved' : 'rejected';
  t.reject_reason = approve ? null : reason;
  t.reviewer = adminRef(adminId);
  t.reviewed_at = new Date().toISOString();
  if (t.target_type === 'post') {
    const p = posts.find((x) => x.id === t.target_id);
    if (p) {
      p.review_status = t.status;
      p.reject_reason = t.reject_reason;
    }
  }
  if (t.target_type === 'meetup') {
    const mt = meetups.find((x) => x.id === t.target_id);
    if (mt) mt.review_status = t.status;
  }
}

// ---------------- reports ----------------

interface ReportRow extends AdminReport {
  /** Author of the reported object, for mute_days. */
  author_id: number;
}

const REPORT_SEEDS: { type: ReportTargetType; target: number | 'post'; preview: string; reason: ReportReason; detail?: string; n?: number; st?: AdminReport['status']; h?: number }[] = [
  { type: 'post', target: 102, preview: POST_SEEDS[1].content, reason: 'spam', detail: '天天发广告', n: 2 },
  { type: 'post', target: 105, preview: POST_SEEDS[4].content, reason: 'abuse', n: 3 },
  { type: 'post', target: 107, preview: POST_SEEDS[6].content, reason: 'fraud', detail: '兼职刷单骗局，别信' },
  { type: 'comment', target: 903, preview: '楼主是傻吗，地都守不住', reason: 'abuse', detail: '人身攻击', n: 3 },
  { type: 'comment', target: 900, preview: '跑成这样还好意思发，垃圾', reason: 'abuse' },
  { type: 'user', target: 0, preview: '昵称「加V看主页领福利」 · 简介「每天带你赚零花」', reason: 'spam', detail: '私信给我发广告' },
  { type: 'crew', target: 9, preview: '跑团「免费领跑鞋福利群」 · 12 名成员', reason: 'fraud', detail: '进群要先交 99 元押金' },
  { type: 'message', target: 7781, preview: '私信：「小哥哥周末有空吗，加个微信聊聊」', reason: 'porn', detail: '陌生人骚扰' },
  { type: 'message', target: 7790, preview: '群聊「周六世纪公园约跑」：「代买 nike 内部价，需要的私我」', reason: 'spam' },
  { type: 'post', target: 119, preview: POST_SEEDS[18].content, reason: 'abuse', n: 4, st: 'handled', h: 20 },
  { type: 'post', target: 112, preview: POST_SEEDS[11].content, reason: 'other', detail: '感觉是骑电动车', st: 'dismissed', h: 30 },
  { type: 'comment', target: 921, preview: '这条路线我也跑过，风景很好', reason: 'spam', st: 'dismissed', h: 50 },
  { type: 'user', target: 0, preview: '昵称「博彩老司机」', reason: 'illegal', st: 'handled', h: 5 },
  { type: 'post', target: 110, preview: POST_SEEDS[9].content, reason: 'other', detail: '照片里有我，没经过同意', st: 'dismissed', h: 70 },
];

let reportSeq = 4;
export const reports: ReportRow[] = [];
REPORT_SEEDS.forEach((s, i) => {
  const n = s.n ?? 1;
  const post = typeof s.target === 'number' && s.type === 'post' ? posts.find((p) => p.id === s.target) : undefined;
  const author = post ? post.author.id : brief(i * 7 + 4).id;
  const targetId = s.type === 'user' ? author : (s.target as number);
  for (let k = 0; k < n; k++) {
    const handled = s.st && s.st !== 'pending';
    reports.push({
      id: ++reportSeq,
      target_type: s.type,
      target_id: targetId,
      target_preview: s.preview,
      reporter: { id: brief(i * 3 + k * 11 + 5).id, nickname: brief(i * 3 + k * 11 + 5).nickname },
      reason: k === 0 ? s.reason : (['spam', 'abuse', 'other'] as ReportReason[])[k % 3],
      detail: k === 0 ? s.detail ?? null : null,
      status: s.st ?? 'pending',
      handled_by: handled ? adminRef(i % 2 ? 3 : 1) : null,
      handled_at: handled ? ago((s.h ?? 1) * HOUR) : null,
      created_at: ago(((s.h ?? 0) + 2 + k * 3 + i) * HOUR - int(0, 50) * MIN),
      report_count: n,
      author_id: author,
    });
  }
});

const publicReport = (r: ReportRow): AdminReport => {
  const { author_id: _omit, ...rest } = r;
  void _omit;
  return clone(rest);
};

// ---------------- meetups ----------------

const PLACES: (Place & { district: string })[] = [
  { name: '世纪公园 3 号门', lat: 31.2195, lng: 121.5455, district: '浦东新区' },
  { name: '徐家汇公园', lat: 31.1955, lng: 121.4385, district: '徐汇区' },
  { name: '东昌路渡口', lat: 31.2365, lng: 121.5005, district: '浦东新区' },
  { name: '苏州河梦清园', lat: 31.2445, lng: 121.4415, district: '普陀区' },
  { name: '江湾体育场', lat: 31.3045, lng: 121.5145, district: '杨浦区' },
  { name: '前滩公园', lat: 31.1525, lng: 121.4795, district: '浦东新区' },
  { name: '静安雕塑公园', lat: 31.2385, lng: 121.4615, district: '静安区' },
  { name: '奉贤海湾森林公园', lat: 30.8645, lng: 121.6855, district: '奉贤区' },
];

const MEETUP_SEEDS: { type: Meetup['type']; title: string; desc: string; req?: string; inH: number; dur: number; cap: number; joined: number; st?: MeetupStatus; rs?: ReviewStatus }[] = [
  { type: 'run', title: '周六世纪公园约跑', desc: '配速 6 分左右，跑 10 公里，跑完一起吃早饭', req: '配速 5\'30"–6\'30"', inH: 40, dur: 2, cap: 10, joined: 6 },
  { type: 'run', title: '徐汇滨江夜跑 8K', desc: '下班后轻松跑，新手友好', inH: 6, dur: 1.5, cap: 12, joined: 12 },
  { type: 'ride', title: '周日奉贤海湾骑行 60km', desc: '有意者加微信 ride_fx 拉群，自备头盔', req: '均速 25km/h 以上', inH: 64, dur: 5, cap: 8, joined: 3, rs: 'pending' },
  { type: 'ball', title: '江湾体育场篮球半场 3v3', desc: '缺两个人，水平随意', inH: 28, dur: 2, cap: 6, joined: 4 },
  { type: 'run', title: '苏州河晨跑打卡', desc: '早上 6 点半梦清园集合，沿河跑 6 公里', inH: 15, dur: 1, cap: 15, joined: 9 },
  { type: 'run', title: '前滩公园亲子慢跑', desc: '带小朋友一起，3 公里慢跑 + 野餐', inH: 90, dur: 3, cap: 20, joined: 7 },
  { type: 'ball', title: '静安羽毛球双打', desc: '场地已订好，AA 场地费', req: '会基本发球', inH: 50, dur: 2, cap: 4, joined: 4 },
  { type: 'ride', title: '夜骑外滩 - 陆家嘴环线', desc: '20 公里慢骑看夜景', inH: 30, dur: 2, cap: 15, joined: 2, st: 'cancelled' },
  { type: 'run', title: '东昌路渡口拉练 15K', desc: '备战半马，配速 5 分', req: '近一个月周跑量 30km 以上', inH: -30, dur: 2, cap: 10, joined: 8, st: 'ended' },
  { type: 'run', title: '周三晚世纪公园约跑', desc: '配速 6 分左右，跑 10 公里', inH: 54, dur: 2, cap: 10, joined: 1 },
  { type: 'ball', title: '杨浦足球 7 人制', desc: '周末下午踢一场，缺守门员', inH: -50, dur: 2, cap: 14, joined: 14, st: 'ended' },
  { type: 'run', title: '新年第一跑 5K', desc: '元旦早上一起跑，跑完合影', inH: 960, dur: 1, cap: 50, joined: 23 },
];

let meetupSeq = 7;
export const meetups: Meetup[] = MEETUP_SEEDS.map((s, i) => {
  const p = PLACES[[0, 1, 7, 4, 3, 5, 6, 2, 2, 0, 4, 0][i] ?? 0];
  const start = Math.round((NOW + s.inH * HOUR) / (15 * MIN)) * 15 * MIN;
  const { district, ...place } = p;
  const status: MeetupStatus = s.st ?? (s.joined >= s.cap ? 'full' : 'open');
  return {
    id: ++meetupSeq,
    type: s.type,
    title: s.title,
    description: s.desc,
    start_time: iso(start),
    end_time: iso(start + s.dur * HOUR),
    place,
    district,
    capacity: s.cap,
    joined_count: s.joined,
    requirement: s.req ?? null,
    creator: brief(i * 4 + 3),
    status,
    review_status: s.rs ?? 'approved',
    conversation_id: 300 + i,
    created_at: ago((i + 1) * 7 * HOUR),
  };
});

// ---------------- races ----------------

interface RaceRow extends Omit<Race, 'status' | 'signed_count'> {
  cancelled: boolean;
  entries: RaceEntry[];
}

function raceStatus(r: RaceRow, now = Date.now()): RaceStatus {
  if (r.cancelled) return 'cancelled';
  if (now < Date.parse(r.signup_end_time) && now < Date.parse(r.start_time)) return 'signup';
  if (now < Date.parse(r.start_time)) return 'upcoming';
  if (now < Date.parse(r.end_time)) return 'running';
  return 'finished';
}

function raceOut(r: RaceRow): Race {
  const { cancelled: _c, entries, ...rest } = r;
  void _c;
  return clone({ ...rest, signed_count: entries.length, status: raceStatus(r) });
}

const dayAt = (d: number, h: number, m = 0) => {
  const x = new Date(NOW + d * DAY);
  x.setHours(h, m, 0, 0);
  return x.getTime();
};

function makeEntries(n: number, finished: number, base: number, startMs: number, endMs: number, online: boolean): RaceEntry[] {
  return Array.from({ length: n }, (_, k) => {
    const u = k < db.users.length ? brief(k * 13) : { id: 200000 + k, nickname: `跑者${200000 + k}`, avatar_url: null, crew: null };
    const done = k < finished;
    const res = done ? base + int(-600, 1800) : null;
    return {
      user: { id: u.id, nickname: u.nickname },
      status: done ? 'finished' : Date.now() > endMs ? 'dnf' : 'signed',
      result_sec: res,
      finished_at: done ? iso(Math.min(endMs, startMs + (res ?? 0) * 1000 + int(0, 3) * HOUR)) : null,
      activity_id: done && online ? 80000 + k : null,
      signed_at: iso(startMs - int(1, 20) * DAY - int(0, 600) * MIN),
    };
  });
}

let raceSeq = 1;
const mkRace = (r: Omit<RaceRow, 'id' | 'entries' | 'cancelled'> & { cancelled?: boolean }, entries: (row: RaceRow) => RaceEntry[]): RaceRow => {
  const row: RaceRow = { id: ++raceSeq, cancelled: false, entries: [], ...r };
  row.entries = entries(row);
  return row;
};
const MEDAL_IMG = (i: number, t: string) => photo(i + 11, t, 600, 600);

export const races: RaceRow[] = [
  mkRace(
    {
      type: 'online', title: '城市 10K 线上赛', cover_url: photo(21, '城市 10K', 1200, 675), description: '时间窗内单次跑满 10 公里即完赛，按用时排名。需要佩戴手表或手环上传心率。',
      sport: 'run', distance_m: 10000, start_time: iso(dayAt(3, 0)), end_time: iso(dayAt(10, 23, 59)), signup_end_time: iso(dayAt(2, 23, 59)),
      place: null, capacity: 5000, requires_wearable: true, medal: { key: 'race_2026_city10k', name: '城市 10K 完赛奖牌', image_url: MEDAL_IMG(1, '10K') }, published: true,
    },
    () => makeEntries(64, 0, 3300, dayAt(3, 0), dayAt(10, 23, 59), true),
  ),
  mkRace(
    {
      type: 'online', title: '滨江夜骑 30K', cover_url: photo(22, '滨江夜骑', 1200, 675), description: '每晚 19 点后出发，单次骑满 30 公里。',
      sport: 'ride', distance_m: 30000, start_time: iso(dayAt(-2, 0)), end_time: iso(dayAt(5, 23, 59)), signup_end_time: iso(dayAt(-3, 23, 59)),
      place: null, capacity: 2000, requires_wearable: false, medal: { key: 'race_2026_night_ride', name: '夜骑勋章', image_url: MEDAL_IMG(2, '夜骑') }, published: true,
    },
    () => makeEntries(46, 18, 4200, dayAt(-2, 0), dayAt(5, 23, 59), true),
  ),
  mkRace(
    {
      type: 'offline', title: '双十一 11.11K 世纪公园站', cover_url: photo(23, '11.11K', 1200, 675), description: '线下赛，世纪公园 3 号门起终点。成绩以计时芯片为准，运营在后台标记完赛。',
      sport: 'run', distance_m: 11110, start_time: iso(dayAt(-10, 7, 30)), end_time: iso(dayAt(-10, 10, 30)), signup_end_time: iso(dayAt(-13, 23, 59)),
      place: { name: '世纪公园 3 号门', lat: 31.2195, lng: 121.5455 }, capacity: 300, requires_wearable: false, medal: { key: 'race_2026_1111k', name: '11.11K 完赛奖牌', image_url: MEDAL_IMG(3, '11.11K') }, published: true,
    },
    (r) => makeEntries(28, 9, 3900, Date.parse(r.start_time), Date.parse(r.end_time), false).map((e, k) => (k >= 9 && k < 20 ? { ...e, status: 'signed' as const } : e)),
  ),
  mkRace(
    {
      type: 'offline', title: '苏州河半程马拉松', cover_url: photo(24, '苏州河半马', 1200, 675), description: '沿苏州河往返，限 21.0975 公里。需提前领取号码布。',
      sport: 'run', distance_m: 21097, start_time: iso(dayAt(18, 7, 0)), end_time: iso(dayAt(18, 11, 0)), signup_end_time: iso(dayAt(11, 23, 59)),
      place: { name: '苏州河梦清园', lat: 31.2445, lng: 121.4415 }, capacity: 800, requires_wearable: false, medal: { key: 'race_2026_suzhou_half', name: '苏州河半马奖牌', image_url: MEDAL_IMG(4, '半马') }, published: true,
    },
    (r) => makeEntries(35, 0, 0, Date.parse(r.start_time), Date.parse(r.end_time), false),
  ),
  mkRace(
    {
      type: 'online', title: '新年第一跑 5K', cover_url: null, description: '元旦当天跑满 5 公里。',
      sport: 'run', distance_m: 5000, start_time: iso(new Date(new Date(NOW).getFullYear() + 1, 0, 1, 0, 0).getTime()), end_time: iso(new Date(new Date(NOW).getFullYear() + 1, 0, 1, 23, 59).getTime()),
      signup_end_time: iso(new Date(new Date(NOW).getFullYear(), 11, 31, 23, 59).getTime()),
      place: null, capacity: 10000, requires_wearable: false, medal: { key: 'race_2027_newyear5k', name: '新年第一跑', image_url: null }, published: false,
    },
    () => [],
  ),
  mkRace(
    {
      type: 'offline', title: '徐汇滨江健走 6K', cover_url: photo(25, '滨江健走', 1200, 675), description: '因场地施工取消。',
      sport: 'walk', distance_m: 6000, start_time: iso(dayAt(6, 8, 0)), end_time: iso(dayAt(6, 11, 0)), signup_end_time: iso(dayAt(4, 23, 59)),
      place: { name: '徐汇滨江龙美术馆', lat: 31.1725, lng: 121.4595 }, capacity: 200, requires_wearable: false, medal: null, published: true, cancelled: true,
    },
    (r) => makeEntries(12, 0, 0, Date.parse(r.start_time), Date.parse(r.end_time), false),
  ),
];

function raceInput(body: Record<string, unknown>, base?: RaceRow): Omit<RaceRow, 'id' | 'entries' | 'cancelled'> {
  const merged = { ...(base ? raceOut(base) : {}), ...body } as Record<string, unknown>;
  const type = merged.type as RaceInput['type'];
  if (type !== 'online' && type !== 'offline') fail(400, 'invalid_body', 'type 只能是 online / offline');
  const title = String(merged.title ?? '').trim();
  if (!title || title.length > 30) fail(400, 'invalid_body', '赛事名称 1–30 字');
  const sport = String(merged.sport ?? '');
  if (!['run', 'ride', 'hike', 'walk', 'swim'].includes(sport)) fail(400, 'invalid_body', '运动类型无效');
  const distance = Number(merged.distance_m);
  if (!Number.isInteger(distance) || distance <= 0) fail(400, 'invalid_body', '距离必须是正整数（米）');
  const start = Date.parse(String(merged.start_time ?? ''));
  const end = Date.parse(String(merged.end_time ?? ''));
  const signup = Date.parse(String(merged.signup_end_time ?? ''));
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) fail(400, 'invalid_body', '结束时间必须晚于开始时间');
  if (!Number.isFinite(signup)) fail(400, 'invalid_body', '报名截止时间必填');
  if (signup > end) fail(400, 'invalid_body', '报名截止不能晚于赛事结束');
  if (type === 'offline' && signup > start) fail(400, 'invalid_body', '线下赛报名截止不能晚于开赛');
  const capacity = Number(merged.capacity);
  if (!Number.isInteger(capacity) || capacity < 1) fail(400, 'invalid_body', '名额至少 1 人');
  if (base && capacity < base.entries.length) fail(400, 'invalid_body', `已有 ${base.entries.length} 人报名，名额不能少于报名人数`);
  let place: Place | null = null;
  if (type === 'offline') {
    const p = (merged.place ?? null) as Place | null;
    if (!p || !String(p.name ?? '').trim() || !Number.isFinite(Number(p.lat)) || !Number.isFinite(Number(p.lng))) fail(400, 'invalid_body', '线下赛需要集合地点（名称和坐标）');
    place = { name: String(p.name).trim(), lat: Number(p.lat), lng: Number(p.lng) };
  }
  let medal: RaceInput['medal'] = null;
  const md = merged.medal as RaceInput['medal'];
  if (md && (md.key || md.name)) {
    if (!/^[a-z0-9_]{3,48}$/.test(String(md.key ?? ''))) fail(400, 'invalid_body', '奖牌 key 只能用小写字母、数字和下划线（3–48 位）');
    if (!String(md.name ?? '').trim()) fail(400, 'invalid_body', '奖牌名称必填');
    const clash = races.find((x) => x.id !== base?.id && x.medal?.key === md.key);
    if (clash) fail(409, 'medal_key_taken', `奖牌 key 已被「${clash.title}」使用`);
    medal = { key: md.key, name: String(md.name).trim(), image_url: md.image_url || null };
  }
  return {
    type, title, sport, distance_m: distance, place, capacity, medal,
    cover_url: (merged.cover_url as string) || null,
    description: String(merged.description ?? ''),
    start_time: iso(start), end_time: iso(end), signup_end_time: iso(signup),
    requires_wearable: type === 'online' && !!merged.requires_wearable,
    published: !!merged.published,
  };
}

// ---------------- routes ----------------

export function communityRoutes(log: Log): [string, RegExp, Handler][] {
  return [
    // 审核队列
    ['GET', /^\/reviews$/, ({ q, role }) => {
      requireRole(role, REVIEW_ROLES);
      const status = (q.get('status') || 'pending') as ReviewStatus;
      if (!['pending', 'approved', 'rejected'].includes(status)) fail(400, 'invalid_status', 'status 取值 pending / approved / rejected');
      const type = q.get('target_type') || '';
      let list = tasks.filter((t) => t.status === status && (!type || t.target_type === type));
      list =
        status === 'pending'
          ? list.sort((a, b) => b.risk_score - a.risk_score || Date.parse(a.created_at) - Date.parse(b.created_at))
          : list.sort((a, b) => Date.parse(b.reviewed_at ?? '') - Date.parse(a.reviewed_at ?? ''));
      return paginate(list.map(clone), q);
    }],
    ['GET', /^\/reviews\/stats$/, ({ role }) => {
      requireRole(role, REVIEW_ROLES);
      return reviewStats();
    }],
    ['POST', /^\/reviews\/(\d+)\/(approve|reject)$/, ({ m, body, role, adminId }) => {
      requireRole(role, REVIEW_ROLES);
      const t = tasks.find((x) => x.id === Number(m[1]));
      if (!t) fail(404, 'not_found', '审核任务不存在');
      if (t.status !== 'pending') fail(409, 'already_reviewed', '这条内容已经被审核过了');
      const approve = m[2] === 'approve';
      const reason = String(body.reason ?? '').trim();
      if (!approve && !reason) fail(400, 'invalid_body', '请填写拒绝原因');
      if (reason.length > 200) fail(400, 'invalid_body', '拒绝原因最多 200 字');
      decide(t, approve, reason, adminId);
      log(adminId, approve ? 'review.approve' : 'review.reject', `${t.target_type}:${t.target_id}`, approve ? { task_id: t.id } : { task_id: t.id, reason });
      return clone(t);
    }],
    ['POST', /^\/reviews\/batch$/, ({ body, role, adminId }) => {
      requireRole(role, REVIEW_ROLES);
      const ids = Array.isArray(body.ids) ? body.ids.map(Number) : [];
      const action = body.action;
      if (!ids.length || ids.length > 100 || !ids.every(Number.isInteger)) fail(400, 'invalid_body', 'ids 需要 1–100 个');
      if (action !== 'approve' && action !== 'reject') fail(400, 'invalid_body', 'action 只能是 approve / reject');
      const reason = String(body.reason ?? '').trim();
      if (action === 'reject' && !reason) fail(400, 'invalid_body', '批量拒绝需要填写原因');
      let done = 0;
      for (const id of ids) {
        const t = tasks.find((x) => x.id === id);
        if (!t || t.status !== 'pending') continue;
        decide(t, action === 'approve', reason, adminId);
        done++;
      }
      log(adminId, 'review.batch', `reviews:${ids.join(',')}`, { action, done, reason: reason || undefined });
      return { done };
    }],

    // 举报
    ['GET', /^\/reports$/, ({ q, role }) => {
      requireRole(role, REVIEW_ROLES);
      const status = q.get('status') || 'pending';
      if (!['pending', 'handled', 'dismissed'].includes(status)) fail(400, 'invalid_status', 'status 取值 pending / handled / dismissed');
      const type = q.get('target_type') || '';
      const list = reports
        .filter((r) => r.status === status && (!type || r.target_type === type))
        .sort((a, b) => (status === 'pending' ? b.report_count - a.report_count || Date.parse(b.created_at) - Date.parse(a.created_at) : Date.parse(b.handled_at ?? '') - Date.parse(a.handled_at ?? '')));
      return paginate(list.map(publicReport), q);
    }],
    ['POST', /^\/reports\/(\d+)\/handle$/, ({ m, body, role, adminId }) => {
      requireRole(role, REVIEW_ROLES);
      const r = reports.find((x) => x.id === Number(m[1]));
      if (!r) fail(404, 'not_found', '举报不存在');
      if (r.status !== 'pending') fail(409, 'already_handled', '这条举报已经处理过了');
      const action = body.action;
      if (action !== 'remove' && action !== 'dismiss') fail(400, 'invalid_body', 'action 只能是 remove / dismiss');
      const mute = Number(body.mute_days ?? 0);
      if (!Number.isInteger(mute) || mute < 0 || mute > 30) fail(400, 'invalid_body', '禁言天数应在 0–30 之间');
      const note = String(body.note ?? '').trim();
      const now = new Date().toISOString();
      const who = adminRef(adminId);
      if (action === 'dismiss') {
        Object.assign(r, { status: 'dismissed', handled_by: who, handled_at: now });
        log(adminId, 'report.dismiss', `${r.target_type}:${r.target_id}`, { report_id: r.id, note: note || undefined });
        return {};
      }
      const same = reports.filter((x) => x.status === 'pending' && x.target_type === r.target_type && x.target_id === r.target_id);
      for (const x of same) Object.assign(x, { status: 'handled', handled_by: who, handled_at: now });
      if (r.target_type === 'post') {
        const p = posts.find((x) => x.id === r.target_id);
        if (p) p.deleted = true;
      }
      if (mute > 0) {
        const u = db.users.find((x) => x.id === r.author_id);
        if (u && u.status !== 'banned') {
          u.status = 'muted';
          u.muted_until = new Date(Date.now() + mute * DAY).toISOString();
        }
      }
      log(adminId, 'report.remove', `${r.target_type}:${r.target_id}`, { report_ids: same.map((x) => x.id), mute_days: mute, note: note || undefined });
      return {};
    }],

    // 动态管理
    ['GET', /^\/posts$/, ({ q, role }) => {
      requireRole(role, REVIEW_ROLES);
      const kw = (q.get('q') ?? '').trim();
      const uid = Number(q.get('user_id') ?? 0);
      const rs = q.get('review_status') ?? '';
      if (rs && !['pending', 'approved', 'rejected'].includes(rs)) fail(400, 'invalid_status', 'review_status 取值 pending / approved / rejected');
      const list = posts
        .filter((p) => (!kw || p.content.includes(kw) || String(p.id) === kw.replace(/^#/, '')) && (!uid || p.author.id === uid) && (!rs || p.review_status === rs))
        .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));
      return paginate(list.map(clone), q);
    }],
    ['DELETE', /^\/posts\/(\d+)$/, ({ m, body, role, adminId }) => {
      requireRole(role, REVIEW_ROLES);
      const p = posts.find((x) => x.id === Number(m[1]));
      if (!p) fail(404, 'not_found', '动态不存在');
      if (p.deleted) fail(409, 'already_deleted', '这条动态已经下架');
      const reason = String(body.reason ?? '').trim();
      if (!reason) fail(400, 'invalid_body', '请填写下架原因');
      p.deleted = true;
      log(adminId, 'post.delete', `post:${p.id}`, { reason });
      return {};
    }],

    // 敏感词与审核设置
    ['GET', /^\/moderation\/settings$/, ({ role }) => {
      requireRole(role, ['admin']);
      return clone(settings);
    }],
    ['PUT', /^\/moderation\/settings$/, ({ body, role, adminId }) => {
      requireRole(role, ['admin']);
      const clean = (ws: unknown) => {
        const out: string[] = [];
        const seen = new Set<string>();
        for (const w of Array.isArray(ws) ? ws : []) {
          const t = String(w).trim();
          if (t && !seen.has(t.toLowerCase())) {
            seen.add(t.toLowerCase());
            out.push(t);
          }
        }
        return out;
      };
      const auto = Number(body.auto_approve_below);
      const hide = Number(body.report_auto_hide);
      if (!Number.isInteger(auto) || auto < 0 || auto > 100) fail(400, 'invalid_body', '自动通过阈值应在 0–100 之间');
      if (!Number.isInteger(hide) || hide < 1) fail(400, 'invalid_body', '举报自动隐藏次数至少为 1');
      const next: ModerationSettings = { block_words: clean(body.block_words), review_words: clean(body.review_words), auto_approve_below: auto, report_auto_hide: hide };
      const diff = (a: string[], b: string[]) => b.filter((w) => !a.includes(w)).length;
      log(adminId, 'moderation.settings', 'moderation', {
        block_added: diff(settings.block_words, next.block_words),
        block_removed: diff(next.block_words, settings.block_words),
        review_added: diff(settings.review_words, next.review_words),
        review_removed: diff(next.review_words, settings.review_words),
        auto_approve_below: auto,
        report_auto_hide: hide,
      });
      Object.assign(settings, next);
      return clone(settings);
    }],

    // 组局
    ['GET', /^\/meetups$/, ({ q, role }) => {
      requireRole(role, COMMUNITY_ROLES);
      const status = q.get('status') ?? '';
      const type = q.get('type') ?? '';
      if (status && !['open', 'full', 'cancelled', 'ended'].includes(status)) fail(400, 'invalid_status', 'status 取值 open / full / cancelled / ended');
      const list = meetups.filter((x) => (!status || x.status === status) && (!type || x.type === type)).sort((a, b) => Date.parse(a.start_time) - Date.parse(b.start_time));
      // upcoming first, then the past ones (most recent first)
      const now = Date.now();
      const upcoming = list.filter((x) => Date.parse(x.end_time) > now);
      const past = list.filter((x) => Date.parse(x.end_time) <= now).reverse();
      return paginate([...upcoming, ...past].map(clone), q);
    }],
    ['POST', /^\/meetups\/(\d+)\/cancel$/, ({ m, body, role, adminId }) => {
      requireRole(role, COMMUNITY_ROLES);
      const x = meetups.find((t) => t.id === Number(m[1]));
      if (!x) fail(404, 'not_found', '组局不存在');
      if (x.status !== 'open' && x.status !== 'full') fail(409, 'meetup_closed', '组局已取消或已结束');
      x.status = 'cancelled';
      log(adminId, 'meetup.cancel', `meetup:${x.id}`, { reason: String(body.reason ?? '') });
      return clone(x);
    }],

    // 赛事
    ['GET', /^\/races$/, ({ q, role }) => {
      requireRole(role, COMMUNITY_ROLES);
      const list = [...races].sort((a, b) => Date.parse(b.start_time) - Date.parse(a.start_time));
      return paginate(list.map(raceOut), q);
    }],
    ['POST', /^\/races$/, ({ body, role, adminId }) => {
      requireRole(role, COMMUNITY_ROLES);
      const v = raceInput(body);
      if (Date.parse(v.start_time) < Date.now() - HOUR) fail(400, 'invalid_body', '开始时间不能早于现在');
      const r: RaceRow = { id: ++raceSeq, cancelled: false, entries: [], ...v };
      races.push(r);
      log(adminId, 'race.create', `race:${r.id}`, { title: r.title, published: r.published });
      return raceOut(r);
    }],
    ['PATCH', /^\/races\/(\d+)$/, ({ m, body, role, adminId }) => {
      requireRole(role, COMMUNITY_ROLES);
      const r = races.find((x) => x.id === Number(m[1]));
      if (!r) fail(404, 'not_found', '赛事不存在');
      const st = raceStatus(r);
      if (st === 'cancelled') fail(409, 'race_cancelled', '赛事已取消，不能修改');
      if (st === 'finished') fail(409, 'race_finished', '赛事已结束，不能修改');
      const v = raceInput(body, r);
      if (st === 'running' && (v.type !== r.type || v.sport !== r.sport || v.distance_m !== r.distance_m || v.start_time !== r.start_time)) fail(409, 'race_started', '赛事已开始，不能修改类型、运动、距离和开始时间');
      Object.assign(r, v);
      log(adminId, 'race.update', `race:${r.id}`, { fields: Object.keys(body) });
      return raceOut(r);
    }],
    ['POST', /^\/races\/(\d+)\/cancel$/, ({ m, role, adminId }) => {
      requireRole(role, COMMUNITY_ROLES);
      const r = races.find((x) => x.id === Number(m[1]));
      if (!r) fail(404, 'not_found', '赛事不存在');
      const st = raceStatus(r);
      if (st === 'cancelled' || st === 'finished') fail(409, 'race_closed', '赛事已取消或已结束');
      r.cancelled = true;
      log(adminId, 'race.cancel', `race:${r.id}`, { signed: r.entries.length });
      return raceOut(r);
    }],
    ['GET', /^\/races\/(\d+)\/entries$/, ({ m, q, role }) => {
      requireRole(role, COMMUNITY_ROLES);
      const r = races.find((x) => x.id === Number(m[1]));
      if (!r) fail(404, 'not_found', '赛事不存在');
      const order = { finished: 0, signed: 1, dnf: 2 } as const;
      const list = [...r.entries].sort((a, b) => order[a.status] - order[b.status] || (a.result_sec ?? 0) - (b.result_sec ?? 0) || Date.parse(a.signed_at) - Date.parse(b.signed_at));
      return paginate(list.map(clone), q);
    }],
    ['POST', /^\/races\/(\d+)\/entries\/(\d+)\/finish$/, ({ m, body, role, adminId }) => {
      requireRole(role, COMMUNITY_ROLES);
      const r = races.find((x) => x.id === Number(m[1]));
      if (!r) fail(404, 'not_found', '赛事不存在');
      if (r.type !== 'offline') fail(400, 'not_offline', '只有线下赛可以手动标记完赛');
      if (r.cancelled) fail(409, 'race_cancelled', '赛事已取消');
      if (Date.now() < Date.parse(r.start_time)) fail(409, 'race_not_started', '赛事还没开始');
      const e = r.entries.find((x) => x.user.id === Number(m[2]));
      if (!e) fail(404, 'not_found', '该用户没有报名这场赛事');
      if (e.status === 'finished') fail(409, 'already_finished', '该用户已经完赛');
      const sec = Number(body.result_sec);
      if (!Number.isInteger(sec) || sec <= 0 || sec > 24 * 3600) fail(400, 'invalid_body', '成绩应为 1 秒到 24 小时之间的整数秒');
      Object.assign(e, { status: 'finished', result_sec: sec, finished_at: new Date().toISOString() });
      log(adminId, 'race.finish', `race:${r.id}`, { user_id: e.user.id, result_sec: sec, medal: r.medal?.key });
      return {};
    }],
  ];
}
