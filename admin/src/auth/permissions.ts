import type { AdminRole } from '../api/types';

/**
 * What each back-office role may see and do in the UI. The contract only fixes
 * the admin-only actions (publish gameplay, refund, manage admins); the rest
 * mirrors the server's route guards (server/internal/admin/api.go):
 *   reviewer → users list/detail/actions and risk; merchant → dashboard only (V1).
 *   V2 玩法运营 (bosses, chests, seasons, campaigns, routes, league) → admin + ops.
 *   系统配置 · 第三方服务 (docs/api/系统配置.md) → admin only.
 *   V2 社区 (docs/api/v2-2-社区.md): 内容审核 / 举报 / 动态管理 → admin + ops + reviewer;
 *   敏感词与审核设置 → admin; 组局 / 赛事 → admin + ops.
 *   V2 AI (docs/api/v2-3-AI.md): AI 用量 → admin + ops; 查看用户 AI 对话 → admin (audited).
 *   V2 本地生活与商户 (docs/api/v2-4-本地生活与商户.md): 商户 / 场馆 / 订场 → admin + ops
 *   (完整联系电话、商户员工账号、订场退款 → admin); 核销结算 → admin; 核销台 / 核销记录 → admin + ops +
 *   merchant; merchant 只看本商户的核销、订场和结算单，看不到总览。投放 / 联名活动 / 能量商城 → admin + ops。
 * The server stays the final judge (403 forbidden).
 */
export type Permission =
  | 'users.read'
  | 'users.stats'
  | 'user.write'
  | 'user.reveal_phone'
  | 'plans.read'
  | 'plan.write'
  | 'order.refund'
  | 'order.remind'
  | 'territories.read'
  | 'territory.write'
  | 'risk.read'
  | 'risk.resolve'
  | 'risk.rules'
  | 'gameplay.read'
  | 'gameplay.edit'
  | 'gameplay.publish'
  /** V2 玩法运营: bosses, chests, seasons, campaigns, routes, league. */
  | 'ops.read'
  | 'ops.write'
  | 'audit.read'
  | 'admins.manage'
  /** 系统配置 · 第三方服务: view and edit provider keys, run connection tests. */
  | 'settings.providers'
  /** V2 社区 · 内容审核: review queue, reports and posts (view). */
  | 'review.read'
  /** Approve / reject, handle reports, take posts down. */
  | 'review.write'
  /** 敏感词与审核设置. */
  | 'moderation.settings'
  /** V2 社区 · 组局与赛事 (view). */
  | 'community.read'
  /** Cancel meetups; create / edit / cancel races; mark offline finishes. */
  | 'community.write'
  /** V2 AI · AI 用量: daily usage, per-feature stats, call log (metadata only). */
  | 'ai.usage'
  /** Read a user's assistant conversation (complaint checks; audited). */
  | 'user.ai_messages'
  /** 总览 (every role except merchant staff, who land on 核销台). */
  | 'dashboard.read'
  /** V2 本地生活 · 商户 (M-24): list / detail (venues, drops, staff). */
  | 'merchant.read'
  | 'merchant.write'
  /** Full contact phone of a merchant (audited). */
  | 'merchant.reveal_phone'
  /** Create merchant-role staff accounts bound to a merchant. */
  | 'merchant.staff'
  /** 场馆: list, edit, QR code, 馆主 history. */
  | 'venue.read'
  | 'venue.write'
  /** 订场 (merchant: own venues only). */
  | 'booking.read'
  | 'booking.refund'
  /** 核销结算 (M-27; merchant: own statements, read only). */
  | 'settlement.read'
  /** Confirm / mark paid / generate statements. */
  | 'settlement.write'
  /** 核销台: redeem a coupon by QR payload or code. */
  | 'redeem'
  | 'redemption.read'
  /** 投放 (M-25) / 联名活动 (M-26) / 能量商城 (E-05): view. */
  | 'perks.read'
  /** Create / edit / pause / resume drops, brand campaigns and shop items. */
  | 'perks.write';

const OPS: Permission[] = [
  'users.read',
  'users.stats',
  'user.write',
  'user.reveal_phone',
  'plans.read',
  'plan.write',
  'order.remind',
  'territories.read',
  'territory.write',
  'risk.read',
  'risk.resolve',
  'risk.rules',
  'gameplay.read',
  'gameplay.edit',
  'ops.read',
  'ops.write',
  'audit.read',
  'review.read',
  'review.write',
  'community.read',
  'community.write',
  'ai.usage',
  'dashboard.read',
  'merchant.read',
  'merchant.write',
  'venue.read',
  'venue.write',
  'booking.read',
  'redeem',
  'redemption.read',
  'perks.read',
  'perks.write',
];

const MATRIX: Record<AdminRole, Permission[]> = {
  admin: [...OPS, 'order.refund', 'gameplay.publish', 'admins.manage', 'settings.providers', 'moderation.settings', 'user.ai_messages', 'merchant.reveal_phone', 'merchant.staff', 'booking.refund', 'settlement.read', 'settlement.write'],
  ops: OPS,
  reviewer: ['dashboard.read', 'users.read', 'user.write', 'risk.read', 'risk.resolve', 'review.read', 'review.write'],
  merchant: ['redeem', 'redemption.read', 'booking.read', 'settlement.read'],
};

export function can(role: AdminRole | undefined, p: Permission): boolean {
  if (!role) return false;
  return MATRIX[role]?.includes(p) ?? false;
}
