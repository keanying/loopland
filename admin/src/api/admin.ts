// One function per endpoint in docs/api/v1.md 「管理端」 (and docs/api/系统配置.md, v2-1-玩法.md, v2-2-社区.md, v2-3-AI.md).
import { ADMIN_PREFIX } from '../config';
import { http, upload } from './client';
import type {
  AdminPost,
  AdminReport,
  AICall,
  AIMessage,
  AIUsage,
  ModerationEstimate,
  ReviewDecide,
  ReviewDecideResult,
  Meetup,
  MeetupStatus,
  MeetupType,
  ModerationSettings,
  Race,
  RaceEntry,
  RaceInput,
  ReportHandle,
  ReportStatus,
  ReportTargetType,
  ReviewBatch,
  ReviewStats,
  ReviewStatus,
  ReviewTargetType,
  ReviewTask,
  AdminAccount,
  AdminCreate,
  AdminMe,
  AdminMessage,
  MediaPurpose,
  MessageCategory,
  MessageList,
  UnreadCount,
  UploadedMedia,
  AdminOrder,
  AdminPatch,
  AuditItem,
  BossCreate,
  BossDetail,
  BossListItem,
  BossStatus,
  Campaign,
  CampaignInput,
  ChestCreate,
  ChestListItem,
  ChestScatter,
  ChestStatus,
  Dashboard,
  District,
  League,
  MapObjects,
  OrienteeringRoute,
  RouteInput,
  Season,
  SeasonInput,
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
  Provider,
  ProviderCheck,
  ProviderSave,
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

const A = ADMIN_PREFIX;

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

  // V2 玩法运营 (docs/api/v2-1-玩法.md)
  mapObjects: (bbox: [number, number, number, number]) => http.get<MapObjects>(`${A}/map/objects`, { bbox: bbox.map((n) => n.toFixed(6)).join(',') }),
  bosses: (p: { status?: BossStatus; page?: number; page_size?: number }) =>
    http.get<Paged<BossListItem>>(`${A}/bosses`, { page_size: PAGE_SIZE, ...p }),
  boss: (id: number) => http.get<BossDetail>(`${A}/bosses/${id}`),
  createBoss: (body: BossCreate) => http.post<BossDetail>(`${A}/bosses`, body),
  endBoss: (id: number) => http.post<BossDetail>(`${A}/bosses/${id}/end`),
  chests: (p: { status?: ChestStatus; page?: number; page_size?: number }) =>
    http.get<Paged<ChestListItem>>(`${A}/chests`, { page_size: PAGE_SIZE, ...p }),
  createChest: (body: ChestCreate) => http.post<ChestListItem>(`${A}/chests`, body),
  scatterChests: (body: ChestScatter) => http.post<{ placed?: number; created?: number; items?: ChestListItem[] }>(`${A}/chests/scatter`, body),
  deleteChest: (id: number) => http.del<unknown>(`${A}/chests/${id}`),
  seasons: () => http.get<Items<Season> & { total?: number }>(`${A}/seasons`, { page_size: 100 }),
  createSeason: (body: SeasonInput) => http.post<Season>(`${A}/seasons`, body),
  updateSeason: (id: number, body: SeasonInput) => http.patch<Season>(`${A}/seasons/${id}`, body),
  settleSeason: (id: number) => http.post<Season>(`${A}/seasons/${id}/settle`),
  campaigns: () => http.get<Items<Campaign> & { total?: number }>(`${A}/campaigns`, { page_size: 100 }),
  createCampaign: (body: CampaignInput) => http.post<Campaign>(`${A}/campaigns`, body),
  updateCampaign: (id: number, body: CampaignInput) => http.patch<Campaign>(`${A}/campaigns/${id}`, body),
  deleteCampaign: (id: number) => http.del<unknown>(`${A}/campaigns/${id}`),
  routes: () => http.get<Items<OrienteeringRoute> & { total?: number }>(`${A}/routes`, { page_size: 100 }),
  createRoute: (body: RouteInput) => http.post<OrienteeringRoute>(`${A}/routes`, body),
  updateRoute: (id: number, body: RouteInput) => http.patch<OrienteeringRoute>(`${A}/routes/${id}`, body),
  deleteRoute: (id: number) => http.del<unknown>(`${A}/routes/${id}`),
  districts: () => http.get<Items<District>>(`${A}/districts`),
  league: (p: { district?: string; week_start?: string }) => http.get<League>(`${A}/league`, p),

  // V2 第二批「社区」(docs/api/v2-2-社区.md 「管理端」)
  reviews: (p: { status?: ReviewStatus; target_type?: ReviewTargetType | ''; page?: number; page_size?: number }) =>
    http.get<Paged<ReviewTask>>(`${A}/reviews`, { page_size: PAGE_SIZE, ...p }),
  reviewStats: () => http.get<ReviewStats>(`${A}/reviews/stats`),
  approveReview: (id: number) => http.post<ReviewTask>(`${A}/reviews/${id}/approve`),
  rejectReview: (id: number, reason: string) => http.post<ReviewTask>(`${A}/reviews/${id}/reject`, { reason }),
  batchReview: (body: ReviewBatch) => http.post<{ done: number }>(`${A}/reviews/batch`, body),
  reports: (p: { status?: ReportStatus; target_type?: ReportTargetType | ''; page?: number; page_size?: number }) =>
    http.get<Paged<AdminReport>>(`${A}/reports`, { page_size: PAGE_SIZE, ...p }),
  handleReport: (id: number, body: ReportHandle) => http.post<Record<string, never>>(`${A}/reports/${id}/handle`, body),
  posts: (p: { q?: string; user_id?: number | null; review_status?: ReviewStatus | ''; page?: number; page_size?: number }) =>
    http.get<Paged<AdminPost>>(`${A}/posts`, { page_size: PAGE_SIZE, ...p }),
  deletePost: (id: number, reason: string) => http.del<Record<string, never>>(`${A}/posts/${id}`, { reason }),
  moderationSettings: () => http.get<ModerationSettings>(`${A}/moderation/settings`),
  saveModerationSettings: (body: ModerationSettings) => http.put<ModerationSettings>(`${A}/moderation/settings`, body),
  meetups: (p: { status?: MeetupStatus | ''; type?: MeetupType | ''; page?: number; page_size?: number }) =>
    http.get<Paged<Meetup>>(`${A}/meetups`, { page_size: PAGE_SIZE, ...p }),
  cancelMeetup: (id: number, reason: string) => http.post<Meetup>(`${A}/meetups/${id}/cancel`, { reason }),
  races: (p: { page?: number; page_size?: number }) => http.get<Paged<Race>>(`${A}/races`, { page_size: PAGE_SIZE, ...p }),
  createRace: (body: RaceInput) => http.post<Race>(`${A}/races`, body),
  updateRace: (id: number, body: Partial<RaceInput>) => http.patch<Race>(`${A}/races/${id}`, body),
  cancelRace: (id: number) => http.post<Race>(`${A}/races/${id}/cancel`),
  raceEntries: (id: number, p: { page?: number; page_size?: number }) =>
    http.get<Paged<RaceEntry>>(`${A}/races/${id}/entries`, { page_size: PAGE_SIZE, ...p }),
  finishRaceEntry: (id: number, userId: number, result_sec: number) =>
    http.post<Record<string, never>>(`${A}/races/${id}/entries/${userId}/finish`, { result_sec }),

  // V2 第三批「AI」(docs/api/v2-3-AI.md 「内容审核升级」「管理端 · AI 用量」)
  /** `targetType` narrows the returned `next` to the same 对象类型 (the queue's type filter). */
  decideReview: (id: number, body: ReviewDecide, targetType?: string) =>
    http.post<ReviewDecideResult>(`${A}/reviews/${id}/decide${targetType ? `?target_type=${encodeURIComponent(targetType)}` : ''}`, body),
  moderationEstimate: (p: { auto_approve_below: number; auto_reject_above: number }) => http.get<ModerationEstimate>(`${A}/moderation/estimate`, p),
  aiUsage: (days: number) => http.get<AIUsage>(`${A}/ai/usage`, { days }),
  aiCalls: (p: { feature?: string; status?: string; page?: number; page_size?: number }) =>
    http.get<Paged<AICall>>(`${A}/ai/calls`, { page_size: PAGE_SIZE, ...p }),
  userAiMessages: (id: number, page: number) => http.get<Paged<AIMessage>>(`${A}/users/${id}/ai-messages`, { page, page_size: PAGE_SIZE }),

  // audit & admins
  audit: (p: { admin_id?: number; page?: number; page_size?: number }) =>
    http.get<Paged<AuditItem>>(`${A}/audit`, { page_size: PAGE_SIZE, ...p }),
  admins: () => http.get<Items<AdminAccount>>(`${A}/admins`),
  createAdmin: (body: AdminCreate) => http.post<AdminAccount>(`${A}/admins`, body),
  patchAdmin: (id: number, body: AdminPatch) => http.patch<AdminAccount>(`${A}/admins/${id}`, body),

  // 系统配置 · 第三方服务 (docs/api/系统配置.md)
  providers: () => http.get<Items<Provider>>(`${A}/providers`),
  saveProvider: (code: string, body: ProviderSave) => http.put<Provider>(`${A}/providers/${encodeURIComponent(code)}`, body),
  testProvider: (code: string, input?: string) =>
    http.post<ProviderCheck>(`${A}/providers/${encodeURIComponent(code)}/test`, input ? { input } : {}),

  // V2 第六批 (docs/api/v2-6-管理端图片上传与站内信.md): 图片上传
  uploadMedia: (file: File | Blob, purpose: MediaPurpose, opts?: { onProgress?: (percent: number) => void; signal?: AbortSignal }) => {
    const form = new FormData();
    form.append('purpose', purpose);
    form.append('file', file, file instanceof File ? file.name : 'image');
    return upload<UploadedMedia>(`${A}/media`, form, opts);
  },

  // 站内信 (every admin account; only its own messages, newest first)
  messages: (p: { category?: MessageCategory | ''; unread?: boolean; page?: number; page_size?: number }) =>
    http.get<MessageList>(`${A}/messages`, { page_size: PAGE_SIZE, ...p, unread: p.unread ? true : undefined }),
  unreadCount: () => http.get<UnreadCount>(`${A}/messages/unread-count`),
  readMessage: (id: number) => http.post<AdminMessage>(`${A}/messages/${id}/read`),
  readAllMessages: (category?: MessageCategory | '') => http.post<{ updated: number }>(`${A}/messages/read-all`, category ? { category } : {}),
};
