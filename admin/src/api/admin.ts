// One function per endpoint in docs/api/v1.md 「管理端」.
import { http } from './client';
import type {
  AdminAccount,
  AdminCreate,
  AdminMe,
  AdminOrder,
  AdminPatch,
  AuditItem,
  Dashboard,
  Entitlement,
  GameplayState,
  Items,
  LoginRequest,
  LoginResponse,
  Order,
  OrderStats,
  OrderStatus,
  Paged,
  Plan,
  PlanUpdate,
  PublishRequest,
  RiskAction,
  RiskAlert,
  RiskAlertDetail,
  RiskRules,
  RiskStatus,
  RiskType,
  Territory,
  TerritoryListItem,
  TerritoryStatusFilter,
  TerritorySummary,
  UserActionRequest,
  UserDetail,
  UserFilter,
  UserListItem,
  UserStats,
} from './types';

const A = '/admin/v1';

export const PAGE_SIZE = 20;

export const api = {
  // auth
  login: (body: LoginRequest) => http.post<LoginResponse>(`${A}/login`, body),
  me: () => http.get<AdminMe>(`${A}/me`),

  // dashboard
  dashboard: () => http.get<Dashboard>(`${A}/dashboard`),

  // users
  userStats: () => http.get<UserStats>(`${A}/users/stats`),
  users: (p: { q?: string; filter?: UserFilter; page?: number; page_size?: number }) =>
    http.get<Paged<UserListItem>>(`${A}/users`, { page_size: PAGE_SIZE, ...p }),
  user: (id: number) => http.get<UserDetail>(`${A}/users/${id}`),
  revealPhone: (id: number) => http.post<{ phone: string }>(`${A}/users/${id}/reveal-phone`),
  userAction: (id: number, body: UserActionRequest) => http.post<UserDetail>(`${A}/users/${id}/actions`, body),

  // plans & orders
  entitlements: () => http.get<Items<Entitlement>>(`${A}/entitlements`),
  plans: () => http.get<Items<Plan>>(`${A}/plans`),
  updatePlan: (code: string, body: PlanUpdate) => http.put<Plan>(`${A}/plans/${encodeURIComponent(code)}`, body),
  updatePlanEntitlements: (code: string, entitlements: string[]) =>
    http.put<Plan>(`${A}/plans/${encodeURIComponent(code)}/entitlements`, { entitlements }),
  orders: (p: { status?: OrderStatus | ''; q?: string; page?: number; page_size?: number }) =>
    http.get<Paged<AdminOrder>>(`${A}/orders`, { page_size: PAGE_SIZE, ...p }),
  orderStats: () => http.get<OrderStats>(`${A}/orders/stats`),
  refund: (orderNo: string, reason: string) =>
    http.post<Order>(`${A}/orders/${encodeURIComponent(orderNo)}/refund`, { reason, confirm: true }),
  remind: (orderNo: string) => http.post<Record<string, never>>(`${A}/orders/${encodeURIComponent(orderNo)}/remind`),

  // territories
  territories: (p: { status?: TerritoryStatusFilter; q?: string; page?: number; page_size?: number }) =>
    http.get<Paged<TerritoryListItem>>(`${A}/territories`, { page_size: PAGE_SIZE, ...p }),
  territoriesGeo: (bbox?: [number, number, number, number]) =>
    http.get<Items<TerritorySummary>>(`${A}/territories/geo`, { bbox: bbox ? bbox.join(',') : undefined }),
  territory: (id: number) => http.get<Territory>(`${A}/territories/${id}`),
  setGuard: (id: number, guard: number) => http.post<Territory>(`${A}/territories/${id}/guard`, { guard }),
  freeze: (id: number, frozen: boolean) => http.post<Territory>(`${A}/territories/${id}/freeze`, { frozen }),
  resetTerritory: (id: number) => http.post<Territory>(`${A}/territories/${id}/reset`),

  // risk
  riskAlerts: (p: { status?: RiskStatus; type?: RiskType | ''; page?: number; page_size?: number }) =>
    http.get<Paged<RiskAlert>>(`${A}/risk/alerts`, { page_size: PAGE_SIZE, ...p }),
  riskAlert: (id: number) => http.get<RiskAlertDetail>(`${A}/risk/alerts/${id}`),
  resolveAlert: (id: number, action: RiskAction, note: string) =>
    http.post<RiskAlert>(`${A}/risk/alerts/${id}/resolve`, { action, note }),
  riskRules: () => http.get<RiskRules>(`${A}/risk/rules`),
  updateRiskRules: (body: RiskRules) => http.put<RiskRules>(`${A}/risk/rules`, body),

  // gameplay
  gameplay: () => http.get<GameplayState>(`${A}/gameplay`),
  publishGameplay: (body: PublishRequest) => http.post<GameplayState>(`${A}/gameplay/publish`, body),
  rolloutGameplay: (rollout_pct: number) => http.post<GameplayState>(`${A}/gameplay/rollout`, { rollout_pct }),
  rollbackGameplay: () => http.post<GameplayState>(`${A}/gameplay/rollback`),

  // audit & admins
  audit: (p: { admin_id?: number; page?: number; page_size?: number }) =>
    http.get<Paged<AuditItem>>(`${A}/audit`, { page_size: PAGE_SIZE, ...p }),
  admins: () => http.get<Items<AdminAccount>>(`${A}/admins`),
  createAdmin: (body: AdminCreate) => http.post<AdminAccount>(`${A}/admins`, body),
  patchAdmin: (id: number, body: AdminPatch) => http.patch<AdminAccount>(`${A}/admins/${id}`, body),
};
