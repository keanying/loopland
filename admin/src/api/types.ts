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
  medals?: { key: string; name: string; distance_km: number }[];
  bosses: BossConf[];
  [extra: string]: unknown;
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
