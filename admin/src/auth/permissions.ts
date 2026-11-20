import type { AdminRole } from '../api/types';

/**
 * What each back-office role may see and do in the UI. The contract only fixes
 * the admin-only actions (publish gameplay, refund, manage admins); the rest
 * mirrors the server's route guards (server/internal/admin/api.go):
 *   reviewer → users list/detail/actions and risk; merchant → dashboard only (V1).
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
  | 'audit.read'
  | 'admins.manage';

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
  'audit.read',
];

const MATRIX: Record<AdminRole, Permission[]> = {
  admin: [...OPS, 'order.refund', 'gameplay.publish', 'admins.manage'],
  ops: OPS,
  reviewer: ['users.read', 'user.write', 'risk.read', 'risk.resolve'],
  merchant: [],
};

export function can(role: AdminRole | undefined, p: Permission): boolean {
  if (!role) return false;
  return MATRIX[role]?.includes(p) ?? false;
}
