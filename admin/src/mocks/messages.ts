// Mock of V2 第六批「管理端站内信」(docs/api/v2-6-管理端图片上传与站内信.md): one in-memory inbox per admin
// account. Merchant messages go to every enabled staff account of the merchant (`shop` → 跑野运动馆 #2);
// platform messages to every enabled admin / ops account (review ones to reviewer too). Read state lives here
// for the page session. Seeds are built lazily on the first request from the other mocks' data, so links point
// at products, statements, orders and apps that exist (mocks/messageSeeds.ts); the commerce / merchant mocks push
// new messages when the matching event happens (submit → review, review decided, ban, statements).
import { ApiError } from '../api/client';
import type { AdminMessage, AdminRole, MessageCategory, MessageLevel } from '../api/types';
import * as db from './data';
import { merchantOf } from './merchant';

type Ctx = { m: RegExpMatchArray; q: URLSearchParams; body: Record<string, unknown>; adminId: number; role: AdminRole };
type Handler = (ctx: Ctx) => unknown;

export interface MessageDraft {
  category: MessageCategory;
  level: MessageLevel;
  title: string;
  body?: string | null;
  link?: string | null;
}

const MIN = 60_000;
const CATEGORIES: MessageCategory[] = ['product', 'promotion', 'settlement', 'openapi', 'review', 'system'];

interface Row extends AdminMessage {
  admin_id: number;
}

const rows: Row[] = [];
let seq = 100;
let seeded = false;

function fail(status: number, code: string, message: string): never {
  throw new ApiError(status, code, message);
}

/** ¥1,801.35 / ¥69 */
export function yuanText(fen: number): string {
  const y = fen / 100;
  return '¥' + y.toLocaleString('zh-CN', { minimumFractionDigits: Number.isInteger(y) ? 0 : 2, maximumFractionDigits: 2 });
}

/** Put one message into each inbox (seeds pass a past time and the read state). */
export function addMessages(adminIds: number[], d: MessageDraft, at = Date.now(), read = false) {
  for (const admin_id of adminIds) {
    rows.push({
      id: ++seq,
      admin_id,
      category: d.category,
      level: d.level,
      title: d.title.slice(0, 80),
      body: d.body ? d.body.slice(0, 300) : null,
      link: d.link ?? null,
      is_read: read,
      read_at: read ? new Date(at + 20 * MIN).toISOString() : null,
      created_at: new Date(at).toISOString(),
    });
  }
}

/** Enabled admin accounts with one of the roles. */
export const enabled = (roles: AdminRole[]) => db.admins.filter((a) => !a.disabled && roles.includes(a.role)).map((a) => a.id);
/** Enabled staff accounts of a merchant. */
export const staffOf = (merchantId: number) => db.admins.filter((a) => !a.disabled && a.role === 'merchant' && merchantOf(a.id) === merchantId).map((a) => a.id);

/** A message to every enabled staff account of a merchant. */
export function notifyMerchant(merchantId: number, d: MessageDraft) {
  ensureSeeded();
  addMessages(staffOf(merchantId), d);
}

/** A platform message to admin + ops (and reviewer for the review category). */
export function notifyPlatform(d: MessageDraft) {
  ensureSeeded();
  addMessages(enabled(d.category === 'review' ? ['admin', 'ops', 'reviewer'] : ['admin', 'ops']), d);
}

let seeder: (() => void) | null = null;

/** Seeds come from mocks/messageSeeds.ts (it reads the commerce / merchant mocks; importing them here would be a cycle). */
export function setInboxSeeder(fn: () => void) {
  seeder = fn;
}

function ensureSeeded() {
  if (seeded) return;
  seeded = true;
  seeder?.();
  rows.sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at));
}

function mine(adminId: number) {
  ensureSeeded();
  return rows.filter((r) => r.admin_id === adminId);
}

const out = ({ admin_id: _admin, ...m }: Row): AdminMessage => ({ ...m });

export function messageRoutes(): [string, RegExp, Handler][] {
  return [
    ['GET', /^\/messages\/unread-count$/, ({ adminId }) => {
      const unread = mine(adminId).filter((r) => !r.is_read);
      const by_category: Partial<Record<MessageCategory, number>> = {};
      for (const r of unread) by_category[r.category] = (by_category[r.category] ?? 0) + 1;
      return { count: unread.length, by_category };
    }],
    ['GET', /^\/messages$/, ({ adminId, q }) => {
      const category = q.get('category') ?? '';
      if (category && !CATEGORIES.includes(category as MessageCategory)) fail(400, 'invalid_query', `category 取值错误：${category}`);
      const all = mine(adminId);
      let list = all.filter((r) => !category || r.category === category);
      if (q.get('unread') === 'true') list = list.filter((r) => !r.is_read);
      list = [...list].sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at) || b.id - a.id);
      const page = Math.max(1, Number(q.get('page') ?? 1));
      const size = Math.min(100, Math.max(1, Number(q.get('page_size') ?? 20)));
      return { items: list.slice((page - 1) * size, page * size).map(out), total: list.length, unread_count: all.filter((r) => !r.is_read).length };
    }],
    ['POST', /^\/messages\/read-all$/, ({ adminId, body }) => {
      const category = String(body.category ?? '');
      if (category && !CATEGORIES.includes(category as MessageCategory)) fail(400, 'invalid_body', `category 取值错误：${category}`);
      const now = new Date().toISOString();
      let updated = 0;
      for (const r of mine(adminId)) {
        if (r.is_read || (category && r.category !== category)) continue;
        r.is_read = true;
        r.read_at = now;
        updated++;
      }
      return { updated };
    }],
    ['POST', /^\/messages\/(\d+)\/read$/, ({ adminId, m }) => {
      const r = mine(adminId).find((x) => x.id === Number(m[1]));
      if (!r) fail(404, 'not_found', '消息不存在');
      if (!r.is_read) {
        r.is_read = true;
        r.read_at = new Date().toISOString();
      }
      return out(r);
    }],
  ];
}
