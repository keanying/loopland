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
  | 'community.write';

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
];

const MATRIX: Record<AdminRole, Permission[]> = {
  admin: [...OPS, 'order.refund', 'gameplay.publish', 'admins.manage', 'settings.providers', 'moderation.settings'],
  ops: OPS,
  reviewer: ['users.read', 'user.write', 'risk.read', 'risk.resolve', 'review.read', 'review.write'],
  merchant: [],
};

export function can(role: AdminRole | undefined, p: Permission): boolean {
  if (!role) return false;
  return MATRIX[role]?.includes(p) ?? false;
}
