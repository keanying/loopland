// Types for the admin API, written by hand from docs/api/v1.md (「管理端」).
// Times are RFC3339 strings, money is in 分 (fen), distance in metres, area in m².

export interface ApiErrorBody {
  error: { code: string; message: string };
}

export interface Paged<T> {
  items: T[];
  total: number;
}

export interface Items<T> {
  items: T[];
}

export interface LatLng {
  lat: number;
  lng: number;
}

// ---------- auth ----------

export type AdminRole = 'admin' | 'ops' | 'reviewer' | 'merchant';

export interface AdminMe {
  id: number;
  username: string;
  role: AdminRole;
  /** V2 第四批: the merchant a `merchant` account is bound to (omitted for other roles). */
  merchant_id?: number | null;
}

export interface LoginRequest {
  username: string;
  password: string;
}

export interface LoginResponse {
  token: string;
  admin: AdminMe;
}

// ---------- dashboard ----------

export interface DashboardMetrics {
  active_users: number;
  activities: number;
  new_territories: number;
  pending_risk: number;
}

export type TodoType =
  | 'risk'
  | 'refund'
  | 'renew_failed'
  | 'review'
  // V2 第四批 M-04
  | 'merchant_review'
  | 'booking_refund'
  | 'statement_confirm';

export interface DashboardTodo {
  type: TodoType;
  title: string;
  count: number;
  priority: number;
  link: string;
}

export interface Dashboard {
  today: DashboardMetrics;
  last_week: DashboardMetrics;
  trend: {
    days: string[];
    active_users: number[];
    distance_km: number[];
    new_territories: number[];
  };
  todos: DashboardTodo[];
  /** V2 第二批 M-01: content waiting in the review queue. */
  pending_reviews?: number;
  /** Week-over-week change of pending_reviews as a ratio (0.2 = +20%); null when last week was 0. */
  pending_reviews_wow?: number | null;
}

// ---------- users ----------

export type UserStatus = 'active' | 'muted' | 'banned' | 'deleting';

export interface UserStats {
  total: number;
  today_new: number;
  retention_7d: number;
  members: number;
  sources: { provider: string; count: number }[];
}

export type UserFilter = 'all' | 'member' | 'today' | 'abnormal';

export interface UserListItem {
  id: number;
  nickname: string;
  phone_masked: string | null;
  source: string;
  created_at: string;
  member: boolean;
  status: UserStatus;
  delete_after: string | null;
}

export interface Membership {
  active: boolean;
  plan_code?: string;
  plan_name?: string;
  expires_at?: string;
  auto_renew?: boolean;
  next_charge_at?: string | null;
  channel?: string;
}

export interface User {
  id: number;
  nickname: string;
  avatar_url: string | null;
  level: number;
  energy: number;
  energy_today: number;
  daily_energy_cap: number;
  phone_masked: string | null;
  realname_verified: boolean;
  is_adult: boolean | null;
  status: UserStatus;
  muted_until: string | null;
  delete_after: string | null;
  consents: { privacy_version: string; location: boolean; health: boolean } | null;
  settings?: Record<string, unknown>;
  crew: { id: number; name: string } | null;
  membership: Membership | null;
  stats: {
    total_distance_m: number;
    activity_count: number;
    territory_count: number;
    territory_area_m2: number;
    week?: { count: number; distance_m: number; duration_s: number; energy: number };
  };
  created_at: string;
}

export interface UserDetail extends User {
  source: string;
  last_login_at: string | null;
  codex_count: number;
  risk_alerts: RiskAlert[];
}

export type UserAction = 'gift_member_7d' | 'notify' | 'mute_7d' | 'unmute' | 'ban' | 'unban';

export interface UserActionRequest {
  action: UserAction;
  message?: string;
}

// ---------- plans & orders ----------

export interface Entitlement {
  key: string;
  name: string;
  locked: boolean;
}

export type PlanPeriod = 'month' | 'quarter' | 'year';

export interface Plan {
  code: string;
  name: string;
  period: PlanPeriod;
  auto_renew: boolean;
  price_fen: number;
  /** null = no introductory price (server returns null for plans without one). */
  first_price_fen: number | null;
  renew_price_fen: number;
  seats: number;
  recommended: boolean;
  apple_product_id: string | null;
  entitlements: string[];
  on_sale: boolean;
  sort: number;
}

export interface PlanUpdate {
  name: string;
  price_fen: number;
  /** Server: 0 clears the introductory price; null leaves it unchanged. */
  first_price_fen: number | null;
  renew_price_fen: number;
  on_sale: boolean;
  recommended: boolean;
  sort: number;
}

export type OrderStatus = 'created' | 'paid' | 'refund_requested' | 'refunded' | 'closed' | 'renew_failed';

export interface Order {
  order_no: string;
  plan_code: string;
  plan_name: string;
  amount_fen: number;
  channel: string;
  /** purchase | renewal | gift (not in the contract; the server sends it). */
  kind?: string;
  status: OrderStatus;
  created_at: string;
  paid_at: string | null;
  refunded_at?: string | null;
  trade_no?: string | null;
}

export interface AdminOrder extends Order {
  user: { id: number; nickname: string };
}

export interface OrderStats {
  month_revenue_fen: number;
  active_members: number;
  renew_success_rate: number;
  refund_rate_today: number;
}

// ---------- territories ----------

export interface UserRef {
  id: number;
  nickname: string;
  avatar_url?: string | null;
}

export interface CrewRef {
  id: number;
  name: string;
}

export type TerritoryStatusFilter = 'all' | 'contested' | 'frozen';

export interface TerritoryListItem {
  id: number;
  name: string;
  owner: UserRef | null;
  crew: CrewRef | null;
  area_m2: number;
  guard: number;
  frozen: boolean;
  changes_today: number;
  building_count: number;
  center: LatLng;
  updated_at: string;
}

export interface MultiPolygon {
  type: 'MultiPolygon';
  coordinates: number[][][][]; // [polygon][ring][point][lng, lat]
}

export interface Polygon {
  type: 'Polygon';
  coordinates: number[][][];
}

export interface TerritorySummary {
  id: number;
  name: string;
  relation: 'mine' | 'crew' | 'enemy' | 'unowned';
  owner: UserRef | null;
  crew: CrewRef | null;
  geometry: MultiPolygon | Polygon;
  center: LatLng;
  area_m2: number;
  guard: number;
  frozen: boolean;
  updated_at?: string;
}

export interface TerritoryEvent {
  kind: string;
  actor: UserRef | null;
  prev_owner?: UserRef | null;
  new_owner?: UserRef | null;
  prev_guard?: number | null;
  new_guard?: number | null;
  /** Server sends the admin's id; an object is accepted too. */
  admin?: number | { id: number; username: string } | null;
  created_at: string;
}

export interface Territory extends TerritorySummary {
  daily_energy: number;
  slots: { slot: number; building: string | null; name: string | null }[];
  station_slots: number;
  stationed: { role: string; name: string; buff_text: string }[];
  captured_at: string | null;
  events: TerritoryEvent[];
}

// ---------- risk ----------

export type RiskType = 'speed' | 'mock_location' | 'teleport' | 'missing_device_data' | 'multi_account' | 'device_tamper';
export type RiskStatus = 'open' | 'resolved';
export type RiskAction = 'void' | 'warn' | 'ban_30d' | 'false_positive';

/** `resolution` is `null` while open; the server sends the action string (void|warn|…) once resolved. */
export type RiskResolution = null | string | { action?: string; note?: string; admin?: string | { username: string }; resolved_at?: string };

export interface RiskAlert {
  id: number;
  activity_id: number | null;
  user: { id: number; nickname: string };
  type: RiskType;
  confidence: number;
  detail: string;
  status: RiskStatus;
  resolution: RiskResolution;
  /** Resolution note (server field, not in the contract). */
  note?: string | null;
  created_at: string;
}

export interface Activity {
  id: number;
  sport: string;
  status: string;
  started_at: string;
  ended_at: string;
  distance_m: number;
  duration_s: number;
  avg_pace_s_per_km: number | null;
  amount: number;
  energy_granted: number;
  claimed_area_m2: number;
  track?: { type: 'LineString'; coordinates: number[][] } | null;
  claims?: { territory_id: number; kind: string; area_m2: number }[];
}

/** Everything except `alert` and `history` is absent when the alert has no activity. */
export interface RiskAlertDetail {
  alert: RiskAlert;
  activity?: Activity | null;
  speeds?: { t: number; kmh: number; over: boolean }[];
  teleports?: { from: LatLng; to: LatLng; distance_m: number; gap_s: number }[];
  device?: { id: string; model: string; os: string; rooted: boolean; emulator: boolean; multi_open: boolean } | null;
  sources?: { gps: number; network: number; mock: number };
  cadence_avg?: number | null;
  hr_avg?: number | null;
  same_device_accounts?: number;
  history: RiskAlert[];
}

export interface RiskRules {
  run_max_kmh: number;
  ride_max_kmh: number;
  hike_max_kmh: number;
  walk_max_kmh: number;
  teleport_m: number;
  gap_s: number;
  require_wearable_for_events: boolean;
}

// ---------- gameplay config ----------

export interface EnergyRule {
  sport: string;
  name: string;
  unit: string;
  per: number;
  energy: number;
  pending?: boolean;
}

export interface BuildingConf {
  key: string;
  name: string;
  note: string;
  cost: number;
  guard: number;
  daily_energy: number;
  unlock_level: number;
  station_slots?: number;
  /** V2: owning this building's blueprint (boss drop) lets the player build it regardless of level. */
  blueprint_bypass_level?: boolean;
}

export interface RoleConf {
  key: string;
  name: string;
  sport: string;
  threshold: number;
  unit: string;
  buff: string;
  buff_value: number;
  buff_text: string;
}

export interface BossDrop {
  item: string;
  kind: string; // role | blueprint | egg | energy
  percent: number;
}

export interface BossConf {
  key: string;
  name: string;
  drops: BossDrop[];
}

/**
 * Gameplay Config. The contract lists some fields, the server struct some others,
 * so everything beyond the edited arrays is optional and passed through untouched.
 */
export interface Config {
  version: string;
  slots_per_territory?: number;
  base_station_slots?: number;
  daily_energy_cap: number;
  min_claim_area_m2?: number;
  boss_strike_cost?: number;
  level_thresholds?: number[];
  energy: EnergyRule[];
  buildings: BuildingConf[];
  roles: RoleConf[];
  companions?: { key: string; name: string; hatch_km: number }[];
  medals?: MedalConf[];
  bosses: BossConf[];
  // ---- V2 batch 1 (docs/api/v2-1-玩法.md); absent on configs published before V2 ----
  boss?: BossRules;
  chest?: ChestRules;
  defense?: DefenseRules;
  season?: { tiers: SeasonTier[] };
  season_tasks?: SeasonTaskConf[];
  companion?: CompanionRules;
  relay?: RelayRules;
  // ---- V2 batch 3 (docs/api/v2-3-AI.md 「玩法配置新增」) ----
  workouts?: WorkoutConf[];
  ai?: AIRules;
  [extra: string]: unknown;
}

/** jump-跳绳/开合跳 squat-深蹲 pushup-俯卧撑 crunch-卷腹 none-只计时 */
export type WorkoutPose = 'jump' | 'squat' | 'pushup' | 'crunch' | 'none';
export type WorkoutLevel = 'beginner' | 'intermediate' | 'advanced';

export interface WorkoutStep {
  key: string;
  name: string;
  /** count-按次数 time-按时长 */
  mode: 'count' | 'time';
  /** Reps (count) or seconds (time). */
  target: number;
  rest_sec: number;
  sets: number;
  pose: WorkoutPose | string;
  cue: string;
  demo_url?: string | null;
  [extra: string]: unknown;
}

export interface WorkoutConf {
  key: string;
  name: string;
  /** rope / hiit / yoga / strength */
  sport: string;
  level: WorkoutLevel | string;
  cover_url?: string | null;
  est_minutes: number;
  camera: boolean;
  steps: WorkoutStep[];
  [extra: string]: unknown;
}

export interface AIRules {
  route_max_km: number;
  report_max_chars: number;
  chat_history_turns: number;
}

export interface BossDamageRule {
  sport: string;
  per: number;
  unit: string;
  damage: number;
}

export interface BossRules {
  strike_cost: number;
  strike_damage: number;
  strike_cooldown_s: number;
  combo_window_s: number;
  combo_pct: number;
  combo_max_pct: number;
  damage: BossDamageRule[];
  default_hp: number;
  radius_m: number;
  duration_h: number;
  auto_spawn_max: number;
  engage_h: number;
  expire_refund_pct: number;
  top_extra_rolls: number;
  drop_energy: number;
  yield_penalty_pct: number;
}

export interface ChestRules {
  energy_min: number;
  energy_max: number;
  radius_m: number;
  daily_spawn: number;
  duration_h: number;
}

export interface DefenseRules {
  window_h: number;
  max_guard: number;
}

export interface SeasonTier {
  name: string;
  min_km2: number;
}

export type SeasonTaskType = 'weekly_count' | 'weekly_area_m2' | 'weekly_distance_km' | 'new_sport';

export interface SeasonTaskConf {
  key: string;
  name: string;
  type: SeasonTaskType;
  target: number;
  reward_energy: number;
}

export type MedalType = 'distance_km' | 'defends' | 'loops_single' | 'boss_defeats' | 'chests' | 'routes';

/** V1 medals only had `distance_km`; V2 adds type + target (distance_km kept for compatibility). */
export interface MedalConf {
  key: string;
  name: string;
  type?: MedalType;
  target?: number;
  distance_km?: number;
}

export interface CompanionRules {
  feed_cost: number;
  feed_exp: number;
  exp_per_100m: number;
  exp_per_level: number;
}

export interface RelayRules {
  default_legs: number;
  leg_km: number;
  duration_h: number;
  reward_energy: number;
}

/** Server sends the admin id (null for the seed version); a username string is accepted too. */
export type PublishedBy = number | string | null;

export interface GameplayVersion {
  version: string;
  rollout_pct: number;
  body: Config;
  note: string;
  published_by?: PublishedBy;
  published_at: string;
}

export interface GameplayHistoryItem {
  version: string;
  note: string;
  rollout_pct: number;
  published_by: PublishedBy;
  published_at: string;
}

export interface GameplayState {
  current: GameplayVersion;
  previous: GameplayVersion | null;
  history: GameplayHistoryItem[];
}

export interface PublishRequest {
  body: Config;
  note: string;
  rollout_pct: number;
}

// ---------- V2 玩法运营 (docs/api/v2-1-玩法.md 「管理端」) ----------

export type BossKind = 'sofa' | 'bat' | 'smog' | 'sugar';
export type BossStatus = 'active' | 'defeated' | 'expired';

export interface MapBoss {
  id: number;
  kind: BossKind | string;
  name: string;
  level: number;
  center: LatLng;
  radius_m: number;
  hp: number;
  hp_max: number;
  expires_at: string;
  location_name: string;
}

export interface MapChest {
  id: number;
  center: LatLng;
  radius_m: number;
  expires_at: string;
}

export interface MapCheckpoint {
  route_id: number;
  index: number;
  name: string;
  center: LatLng;
  radius_m: number;
  /** App only; the admin view is not per-user. */
  state?: 'next' | 'done' | 'todo';
}

/** V2 第四批: an active 补给站 (supply drop) on the map (docs/api/v2-4-本地生活与商户.md 「地图」). */
export interface MapSupply {
  id: number;
  name: string;
  center: LatLng;
  radius_m: number;
  perk_title: string;
  claimed_today?: boolean;
}

export interface MapObjects {
  bosses: MapBoss[];
  chests: MapChest[];
  checkpoints: MapCheckpoint[];
  /** V2 第四批 补给站. */
  supplies?: MapSupply[];
}

export interface BossListItem {
  id: number;
  kind: BossKind | string;
  name: string;
  level: number;
  location_name: string;
  hp: number;
  hp_max: number;
  participants: number;
  /** Admin id, or null when spawned by the system job. */
  spawned_by: number | null;
  spawned_at: string;
  expires_at: string;
  status?: BossStatus;
  center?: LatLng;
  radius_m?: number;
  defeated_at?: string | null;
}

export interface BossRankRow {
  rank: number;
  user: UserRef;
  damage: number;
}

/** A dropped item; the contract leaves the admin `rewards[].items` shape open, so strings are accepted too. */
export interface RewardItem {
  item: string;
  kind?: string;
  name?: string;
  converted_energy?: number | null;
  energy?: number | null;
}

export interface BossReward {
  user: UserRef;
  rank: number;
  items: (RewardItem | string)[];
  damage?: number;
  /** Energy credited with the rewards (drop energy / expiry refund); server field, not in the contract. */
  energy?: number | null;
  /** Mock-only alias of `energy` for expiry refunds. */
  refund_energy?: number | null;
}

export interface BossDetail {
  id: number;
  kind: BossKind | string;
  name: string;
  level: number;
  description?: string;
  location_name: string;
  center: LatLng;
  radius_m: number;
  hp: number;
  hp_max: number;
  status: BossStatus;
  spawned_at: string;
  expires_at: string;
  defeated_at: string | null;
  spawned_by?: number | null;
  occupied_territories?: number;
  effect_text?: string;
  damage_rules?: (BossDamageRule & { label?: string })[];
  strike?: { cost: number; damage: number; cooldown_s: number };
  participants: number;
  rank: BossRankRow[];
  drops: { item: string; kind: string; name?: string; percent: number }[];
  rewards?: BossReward[];
}

export interface BossCreate {
  kind: BossKind;
  lat: number;
  lng: number;
  location_name: string;
  level?: number;
  hp?: number;
  radius_m?: number;
  duration_h?: number;
}

/** `GET /admin/v1/chests?status=` accepts exactly these (anything else → 400 invalid_status). */
export type ChestStatus = 'active' | 'expired' | 'removed';

/** Contract: 「位置、能量范围、开启人数、来源」; exact field names are not fixed, so most are optional. */
export interface ChestListItem {
  id: number;
  center: LatLng;
  radius_m?: number;
  energy_min: number;
  energy_max: number;
  /** Server field name; `opened_count` accepted too. */
  opens?: number;
  opened_count?: number;
  /** system (daily refresh) | scatter | admin — or an admin id. */
  source?: string | number | null;
  /** removed = 下架. */
  status?: ChestStatus;
  created_at?: string;
  expires_at?: string;
  [extra: string]: unknown;
}

export interface ChestCreate {
  lat: number;
  lng: number;
  energy_min: number;
  energy_max: number;
  duration_h: number;
  radius_m: number;
}

export interface ChestScatter {
  /** "minLng,minLat,maxLng,maxLat", same format as the bbox query parameter (server decodes a string). */
  bbox: string;
  count: number;
  duration_h: number;
}

export interface Season {
  id: number;
  name: string;
  starts_at: string;
  ends_at: string;
  /** Not in the contract; derived from the dates / settled_at when absent. */
  status?: 'upcoming' | 'active' | 'ended' | 'settled';
  settled_at?: string | null;
}

export interface SeasonInput {
  name: string;
  starts_at: string;
  ends_at: string;
}

export type CampaignType = 'pace' | 'night_run' | 'distance';

export interface CampaignRules {
  min_distance_km?: number;
  max_pace_s_per_km?: number;
  start_hour_from?: number;
  start_hour_to?: number;
}

export interface Campaign {
  id: number;
  title: string;
  type: CampaignType;
  description: string;
  rules: CampaignRules;
  starts_at: string;
  ends_at: string;
  reward_energy: number;
  reward_medal: { key: string; name: string } | null;
  reward_medal_name?: string | null;
  participants?: number;
  completed_count?: number;
}

export interface CampaignInput {
  title: string;
  type: CampaignType;
  description: string;
  rules: CampaignRules;
  starts_at: string;
  ends_at: string;
  reward_energy: number;
  reward_medal_name: string | null;
}

/** Admin writes checkpoints flat ({name, lat, lng, radius_m}); App reads them with `center`. Both are accepted. */
export interface RouteCheckpoint {
  index?: number;
  name: string;
  lat?: number;
  lng?: number;
  center?: LatLng;
  radius_m: number;
}

export interface OrienteeringRoute {
  id: number;
  name: string;
  description: string;
  checkpoints: RouteCheckpoint[];
  reward_energy: number;
  starts_at: string;
  ends_at: string;
  /** Number of users who completed the route (server: `finishers`). */
  finishers?: number;
  completed_count?: number;
}

export interface RouteInput {
  name: string;
  description: string;
  checkpoints: { name: string; lat: number; lng: number; radius_m: number }[];
  reward_energy: number;
  starts_at: string;
  ends_at: string;
}

export interface LeagueRow {
  rank: number;
  crew: CrewRef;
  score_m2: number;
  active_members: number;
}

export interface League {
  week_start: string;
  district: string;
  standings: LeagueRow[];
}

/** `GET /admin/v1/districts`: districts that have crews (league selector). */
export interface District {
  name: string;
  crews: number;
}

// ---------- audit & admins ----------

export interface AuditItem {
  id: number;
  admin: { id: number; username: string };
  action: string;
  target: string;
  detail: Record<string, unknown>;
  created_at: string;
}

export interface AdminAccount {
  id: number;
  username: string;
  role: AdminRole;
  disabled: boolean;
  created_at: string;
}

export interface AdminCreate {
  username: string;
  password: string;
  role: AdminRole;
}

export interface AdminPatch {
  role?: AdminRole;
  disabled?: boolean;
  password?: string;
}

// ---------- 系统配置 · 第三方服务 (docs/api/系统配置.md, admin role only) ----------

export type ProviderCode =
  | 'aliyun'
  | 'sms'
  | 'captcha'
  | 'oneclick'
  | 'realname'
  | 'wechat_login'
  | 'wechat_pay'
  | 'alipay'
  | 'apple'
  | 'ai'
  | 'email'
  | 'amap';

/** 账号与安全 / 支付 / AI / 通知 / 地图 */
export type ProviderGroup = string;

/** text 单行 / textarea 多行 / number 整数 / bool 开关（"true"/"false"）/ select 下拉 / url 地址 */
export type ProviderFieldKind = 'text' | 'textarea' | 'number' | 'bool' | 'select' | 'url';

export interface ProviderField {
  key: string;
  label: string;
  help?: string;
  kind: ProviderFieldKind;
  /** Secret fields only come back as {set, hint}, never in plain text. */
  secret: boolean;
  /** Required to enable the service. */
  required: boolean;
  options?: string[];
  default?: string;
}

export interface ProviderSecret {
  set: boolean;
  /** "前2位****后2位", or "****" for short values; omitted when not set. */
  hint?: string;
}

/** db-管理端保存的 config-来自配置文件/环境变量 none-未配置 */
export type ProviderSource = 'db' | 'config' | 'none';

export interface ProviderCheck {
  status: 'ok' | 'fail';
  message: string;
  time: string;
}

export interface Provider {
  code: ProviderCode | string;
  name: string;
  group: ProviderGroup;
  description: string;
  /** Code of the service whose credentials this one reuses (e.g. sms → aliyun). */
  uses?: string;
  /** When set, the test needs an extra input; the text is its label. */
  test_input?: string;
  /** null for services without their own fields (oneclick, realname). */
  fields: ProviderField[] | null;
  enabled: boolean;
  configured: boolean;
  source: ProviderSource;
  /** Plain fields are strings (defaults filled in); secret fields are {set, hint}. */
  values: Record<string, string | ProviderSecret>;
  last_check: ProviderCheck | null;
  updated_by: number | null;
  update_time: string | null;
}

export interface ProviderSave {
  enabled: boolean;
  /** Only the changed fields; an empty secret keeps the stored value. */
  values: Record<string, string>;
  /** Fields to empty (used to delete a secret). */
  clear: string[];
}

// ---------- V2 第二批「社区」(docs/api/v2-2-社区.md 「管理端」) ----------

/** UserBrief in the contract; admin endpoints may send only id + nickname. */
export interface UserBrief {
  id: number;
  nickname: string;
  avatar_url?: string | null;
  crew?: { id: number; name: string } | null;
}

export interface AdminRef {
  id: number;
  username: string;
}

/** pending-待审核 approved-已通过 rejected-未通过 */
export type ReviewStatus = 'pending' | 'approved' | 'rejected';

/** post-动态 comment-评论 nickname-昵称 avatar-头像 crew_name-跑团名称 crew_avatar-跑团头像 bio-简介 meetup-组局 */
export type ReviewTargetType = 'post' | 'comment' | 'nickname' | 'avatar' | 'crew_name' | 'crew_avatar' | 'bio' | 'meetup';

export interface ReviewTask {
  id: number;
  target_type: ReviewTargetType;
  target_id: number;
  user: UserBrief;
  text: string | null;
  images: string[] | null;
  risk_score: number;
  risk_reasons: string[] | null;
  report_count: number;
  status: ReviewStatus;
  reject_reason: string | null;
  reviewer: AdminRef | null;
  reviewed_at: string | null;
  created_at: string;
  // ---- V2 第三批「AI」(docs/api/v2-3-AI.md 「内容审核升级」); absent on older servers ----
  /** AI verdict; null when the model was not asked, timed out or failed (scored by rules only). */
  ai?: ReviewAI | null;
  /** How many of the author's contents were rejected / taken down before. */
  user_violation_count?: number;
  /** The post carries an activity (so 「隐藏起终点后通过」 applies). */
  has_activity?: boolean;
}

/** ad-广告引流 contact-联系方式 porn-色情 politics-涉政 abuse-辱骂 fraud-诈骗 illegal-违法 privacy-隐私泄露 minor-未成年人 other-其他 */
export type AILabel = 'ad' | 'contact' | 'porn' | 'politics' | 'abuse' | 'fraud' | 'illegal' | 'privacy' | 'minor' | 'other';
/** reject-建议拒绝 review-建议人工复核 approve-建议通过 mask-建议打码后通过 hide_endpoints-建议隐藏起终点后通过 */
export type AISuggestion = 'reject' | 'review' | 'approve' | 'mask' | 'hide_endpoints';

export interface ReviewAI {
  risk_score: number;
  labels: (AILabel | string)[];
  reason: string;
  /** 0–1 */
  confidence: number;
  suggestion: AISuggestion | string;
  model_name: string;
}

/** approve-通过 approve_masked-打码后通过 approve_hide_endpoints-隐藏起终点后通过 reject-驳回 reject_mute-驳回并禁言 */
export type ReviewDecideAction = 'approve' | 'approve_masked' | 'approve_hide_endpoints' | 'reject' | 'reject_mute';

export interface ReviewDecide {
  action: ReviewDecideAction;
  reason?: string;
  mute_days?: number;
}

/**
 * 「返回更新后的 ReviewTask 和 next」: read as {task, next}; a server that returns the
 * task's own fields plus `next` at the top level is accepted too.
 */
export type ReviewDecideResult = { task?: ReviewTask; next?: ReviewTask | null } & Partial<ReviewTask>;

export interface ModerationEstimate {
  per_day_manual: number;
  per_day_auto_approve: number;
  per_day_auto_reject: number;
  /** Days of history the estimate is based on. */
  days: number;
}

export interface ReviewStats {
  pending: number;
  today_done: number;
  /** Pending tasks per target type; types with none may be missing. */
  by_type: Partial<Record<ReviewTargetType, number>>;
}

export interface ReviewBatch {
  ids: number[];
  action: 'approve' | 'reject';
  reason: string;
}

/** pending-待处理 handled-已下架 dismissed-已驳回 */
export type ReportStatus = 'pending' | 'handled' | 'dismissed';
export type ReportTargetType = 'post' | 'comment' | 'user' | 'crew' | 'message';
/** spam-垃圾广告 porn-色情低俗 abuse-辱骂攻击 fraud-诈骗 illegal-违法违规 other-其他 */
export type ReportReason = 'spam' | 'porn' | 'abuse' | 'fraud' | 'illegal' | 'other';

export interface AdminReport {
  id: number;
  target_type: ReportTargetType;
  target_id: number;
  target_preview: string | null;
  reporter: UserBrief;
  reason: ReportReason | string;
  detail: string | null;
  status: ReportStatus;
  /** Admin who handled it; an id or {id, username} depending on the server. */
  handled_by: number | AdminRef | null;
  handled_at: string | null;
  created_at: string;
  /** Reports on the same object (all reporters). */
  report_count: number;
}

export interface ReportHandle {
  action: 'remove' | 'dismiss';
  mute_days: number;
  note: string;
}

/** public-公开 fans-仅粉丝 crew-仅跑团 private-仅自己 */
export type PostVisibility = 'public' | 'fans' | 'crew' | 'private';

export interface PostImage {
  url: string;
  width?: number;
  height?: number;
}

export interface PostActivity {
  id: number;
  sport: string;
  distance_m: number;
  duration_sec: number;
  pace_sec_per_km: number | null;
  claimed_area_m2: number;
  start_time: string;
  /** [lng, lat] pairs, endpoints already trimmed. */
  track: number[][];
}

export interface AdminPost {
  id: number;
  author: UserBrief;
  content: string;
  images: PostImage[];
  activity: PostActivity | null;
  visibility: PostVisibility;
  review_status: ReviewStatus;
  reject_reason: string | null;
  like_count: number;
  comment_count: number;
  collect_count: number;
  share_count: number;
  created_at: string;
  /** Taken down by an admin or deleted by the author. */
  deleted: boolean;
}

export interface ModerationSettings {
  block_words: string[];
  review_words: string[];
  /** Posts / comments scoring below this go live without review (0–100). */
  auto_approve_below: number;
  /** Reports from this many different users send a post / comment back to review. */
  report_auto_hide: number;
  /** V2 第三批: scoring ≥ this is rejected automatically (default 90). */
  auto_reject_above?: number;
  /** V2 第三批: ask the model to score content. */
  ai_enabled?: boolean;
}

export interface Place {
  name: string;
  lat: number;
  lng: number;
}

/** run-约跑 ball-约球 ride-约骑 */
export type MeetupType = 'run' | 'ball' | 'ride';
/** open-报名中 full-已满员 cancelled-已取消 ended-已结束 */
export type MeetupStatus = 'open' | 'full' | 'cancelled' | 'ended';

export interface Meetup {
  id: number;
  type: MeetupType;
  title: string;
  description: string;
  start_time: string;
  end_time: string;
  place: Place;
  district: string | null;
  capacity: number;
  joined_count: number;
  requirement: string | null;
  creator: UserBrief;
  status: MeetupStatus;
  review_status: ReviewStatus;
  conversation_id?: number | null;
  created_at: string;
}

export type RaceType = 'online' | 'offline';
/** signup-报名中 upcoming-报名截止待开赛 running-进行中 finished-已结束 cancelled-已取消 */
export type RaceStatus = 'upcoming' | 'signup' | 'running' | 'finished' | 'cancelled';

export interface RaceMedal {
  key: string;
  name: string;
  image_url: string | null;
}

export interface Race {
  id: number;
  type: RaceType;
  title: string;
  cover_url: string | null;
  description: string;
  sport: string;
  distance_m: number;
  start_time: string;
  end_time: string;
  signup_end_time: string;
  place: Place | null;
  capacity: number;
  signed_count: number;
  requires_wearable: boolean;
  /** Always present: the server fills in a key / name when left empty. */
  medal: RaceMedal;
  status: RaceStatus;
  published: boolean;
}

export interface RaceInput {
  type: RaceType;
  title: string;
  cover_url: string | null;
  description: string;
  sport: string;
  distance_m: number;
  start_time: string;
  end_time: string;
  signup_end_time: string;
  place: Place | null;
  capacity: number;
  requires_wearable: boolean;
  /** Empty key → generated; empty name → "<title> 完赛奖牌". */
  medal: RaceMedal;
  published: boolean;
}

/** signed-已报名 finished-已完赛 dnf-未完赛 */
export type RaceEntryStatus = 'signed' | 'finished' | 'dnf';

export interface RaceEntry {
  user: UserBrief;
  status: RaceEntryStatus;
  result_sec: number | null;
  finished_at: string | null;
  activity_id: number | null;
  signed_at: string;
}

// ---------- V2 第三批「AI」(docs/api/v2-3-AI.md 「管理端 · AI 用量」) ----------

/** chat-助手对话 route-路线建议 report-运动战报 moderation-内容审核 workout-AI 跟练 */
export type AIFeature = 'chat' | 'route' | 'report' | 'moderation' | 'workout';

export interface AIUsageDay {
  date: string;
  calls: number;
  failed: number;
  prompt_tokens: number;
  completion_tokens: number;
  /** null when no unit price is set in 系统配置 → AI 大模型. */
  cost_fen: number | null;
}

export interface AIUsageFeature {
  feature: AIFeature | string;
  calls: number;
  failed: number;
  avg_latency_ms: number;
  prompt_tokens: number;
  completion_tokens: number;
  cost_fen: number | null;
}

export interface AIUsage {
  days: AIUsageDay[];
  by_feature: AIUsageFeature[];
  quota: { users_hit_limit_this_week: number };
}

export interface AICall {
  id: number;
  feature: AIFeature | string;
  /** null for calls not tied to a user (e.g. background re-scoring). */
  user: UserBrief | null;
  model: string;
  status: 'ok' | 'failed';
  error: string | null;
  prompt_tokens: number;
  completion_tokens: number;
  latency_ms: number;
  created_at: string;
}

/** Cards in assistant answers; only the fields the admin view shows are typed. */
export type AICard =
  | { type: 'route'; route: { id: string; type?: string; title: string; subtitle?: string; distance_m?: number } }
  | { type: 'territory'; territory: { id: number; name: string; guard?: number } }
  | { type: 'boss'; boss: { id: number; name: string; hp?: number; max_hp?: number } }
  | { type: string; [k: string]: unknown };

export interface AIMessage {
  id: number;
  role: 'user' | 'assistant';
  content: string;
  image_url: string | null;
  cards: AICard[];
  ai_generated: boolean;
  created_at: string;
  /** Soft-deleted by the user (「清空对话」); kept until the 180-day retention ends. */
  deleted?: boolean;
}
