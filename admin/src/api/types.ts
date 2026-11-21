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

export type TodoType = 'risk' | 'refund' | 'renew_failed';

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
  [extra: string]: unknown;
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

export interface MapObjects {
  bosses: MapBoss[];
  chests: MapChest[];
  checkpoints: MapCheckpoint[];
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
