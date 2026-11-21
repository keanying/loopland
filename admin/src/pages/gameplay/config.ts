// Field descriptors, defaults, validation and diff for the gameplay config editor.
// V2 sections follow docs/api/v2-1-玩法.md 「玩法配置新增字段」.
import type {
  BossConf,
  BossRules,
  BuildingConf,
  ChestRules,
  CompanionRules,
  Config,
  DefenseRules,
  EnergyRule,
  MedalConf,
  RelayRules,
  RoleConf,
  SeasonTaskConf,
  SeasonTier,
} from '../../api/types';
import { MEDAL_TYPE, SEASON_TASK_TYPE, SPORT_LABEL, UNIT_LABEL } from '../../utils/labels';

export type Tab = 'buildings' | 'roles' | 'drops' | 'energy' | 'boss' | 'chest' | 'defense' | 'tiers' | 'tasks' | 'medals' | 'companion' | 'relay';

export const TABS: { value: Tab; label: string; v2?: boolean }[] = [
  { value: 'buildings', label: '建筑' },
  { value: 'roles', label: '角色' },
  { value: 'drops', label: '怪兽掉落' },
  { value: 'energy', label: '能量换算' },
  { value: 'boss', label: '怪兽', v2: true },
  { value: 'chest', label: '宝箱', v2: true },
  { value: 'defense', label: '守地', v2: true },
  { value: 'tiers', label: '赛季段位', v2: true },
  { value: 'tasks', label: '赛季任务', v2: true },
  { value: 'medals', label: '奖牌', v2: true },
  { value: 'companion', label: '伙伴养成', v2: true },
  { value: 'relay', label: '跑团接力', v2: true },
];

export interface NumField<K extends string = string> {
  key: K;
  label: string;
  unit?: string;
  min: number;
  max?: number;
  step?: number;
  precision?: number;
  hint?: string;
}

export const BOSS_GROUPS: { title: string; hint: string; fields: NumField<keyof Omit<BossRules, 'damage'>>[] }[] = [
  {
    title: '合击（投入能量）',
    hint: '在怪兽范围内点「合击」，每次消耗能量造成固定伤害',
    fields: [
      { key: 'strike_cost', label: '每次消耗能量', unit: '能量', min: 1, step: 10 },
      { key: 'strike_damage', label: '每次伤害', min: 1, step: 5 },
      { key: 'strike_cooldown_s', label: '冷却', unit: '秒', min: 0, step: 5 },
      { key: 'combo_window_s', label: '连击窗口', unit: '秒', min: 1, step: 30, hint: '同跑团成员在窗口内也出手过算连击' },
      { key: 'combo_pct', label: '每人连击加成', unit: '%', min: 0, max: 100 },
      { key: 'combo_max_pct', label: '连击加成上限', unit: '%', min: 0, max: 500 },
    ],
  },
  {
    title: '投放默认值',
    hint: '系统自动投放和运营手动召唤时的默认值',
    fields: [
      { key: 'default_hp', label: '血量', min: 1, step: 1000 },
      { key: 'radius_m', label: '范围半径', unit: 'm', min: 50, max: 5000, step: 100 },
      { key: 'duration_h', label: '持续时间', unit: '小时', min: 1, max: 336 },
      { key: 'auto_spawn_max', label: '自动投放上限', unit: '只', min: 0, max: 50, hint: '活跃怪兽少于这个数时每小时自动投放；0 = 不自动投放' },
      { key: 'engage_h', label: '出战有效期', unit: '小时', min: 1, max: 72, hint: '点「去运动出战」后，居家运动也计伤害的时长' },
    ],
  },
  {
    title: '结算',
    hint: '击败 / 到期时的奖励与返还',
    fields: [
      { key: 'top_extra_rolls', label: '前几名多掷一次', unit: '名', min: 0, max: 100 },
      { key: 'drop_energy', label: '掉落「能量」得', unit: '能量', min: 0, step: 10 },
      { key: 'expire_refund_pct', label: '到期返还合击花费', unit: '%', min: 0, max: 100 },
      { key: 'yield_penalty_pct', label: '范围内领地产能减少', unit: '%', min: 0, max: 100 },
    ],
  },
];

export const CHEST_FIELDS: NumField<keyof ChestRules>[] = [
  { key: 'energy_min', label: '能量下限', unit: '能量', min: 1 },
  { key: 'energy_max', label: '能量上限', unit: '能量', min: 1 },
  { key: 'radius_m', label: '开启半径', unit: 'm', min: 10, max: 500, step: 10 },
  { key: 'daily_spawn', label: '每日刷新数量', unit: '个', min: 0, max: 1000 },
  { key: 'duration_h', label: '有效期', unit: '小时', min: 1, max: 168 },
];

export const DEFENSE_FIELDS: NumField<keyof DefenseRules>[] = [
  { key: 'window_h', label: '加固期限', unit: '小时', min: 1, max: 168, hint: '领地被攻击后，主人在期限内跑经这块地就能加固' },
  { key: 'max_guard', label: '守卫值上限', min: 1, max: 100000, step: 50, hint: '加固后的守卫值不超过这个数' },
];

export const COMPANION_FIELDS: NumField<keyof CompanionRules>[] = [
  { key: 'feed_cost', label: '喂食消耗', unit: '能量', min: 1, step: 10 },
  { key: 'feed_exp', label: '喂食获得经验', unit: '经验', min: 1 },
  { key: 'exp_per_100m', label: '陪跑每 100 m 经验', unit: '经验', min: 0.1, step: 0.5, precision: 1 },
  { key: 'exp_per_level', label: '每级所需经验', unit: '经验', min: 1, step: 10 },
];

export const RELAY_FIELDS: NumField<keyof RelayRules>[] = [
  { key: 'default_legs', label: '默认棒数', unit: '棒', min: 2, max: 50 },
  { key: 'leg_km', label: '单棒距离', unit: 'km', min: 0.5, max: 50, step: 0.5, precision: 1 },
  { key: 'duration_h', label: '限时', unit: '小时', min: 1, max: 720, step: 12 },
  { key: 'reward_energy', label: '完成奖励（每人）', unit: '能量', min: 0, step: 10 },
];

// Contract defaults, used to add a section that a pre-V2 config does not have yet.
export const DEFAULTS: {
  boss: BossRules;
  chest: ChestRules;
  defense: DefenseRules;
  season: { tiers: SeasonTier[] };
  season_tasks: SeasonTaskConf[];
  medals: MedalConf[];
  companion: CompanionRules;
  relay: RelayRules;
} = {
  boss: {
    strike_cost: 100, strike_damage: 40, strike_cooldown_s: 30, combo_window_s: 300, combo_pct: 10, combo_max_pct: 50,
    damage: [
      { sport: 'run', per: 1, unit: 'km', damage: 100 },
      { sport: 'ride', per: 1, unit: 'km', damage: 100 },
      { sport: 'hike', per: 1, unit: 'km', damage: 100 },
      { sport: 'walk', per: 1, unit: 'km', damage: 100 },
      { sport: 'rope', per: 100, unit: 'count', damage: 30 },
      { sport: 'strength', per: 10, unit: 'min', damage: 30 },
      { sport: 'yoga', per: 10, unit: 'min', damage: 30 },
      { sport: 'hiit', per: 10, unit: 'min', damage: 30 },
    ],
    default_hp: 10000, radius_m: 1000, duration_h: 48, auto_spawn_max: 3, engage_h: 6, expire_refund_pct: 20, top_extra_rolls: 3, drop_energy: 200, yield_penalty_pct: 50,
  },
  chest: { energy_min: 20, energy_max: 60, radius_m: 50, daily_spawn: 20, duration_h: 24 },
  defense: { window_h: 24, max_guard: 2000 },
  season: {
    tiers: [
      { name: '青铜', min_km2: 0 },
      { name: '白银', min_km2: 0.5 },
      { name: '黄金', min_km2: 3.6 },
      { name: '铂金', min_km2: 8 },
      { name: '钻石', min_km2: 15 },
    ],
  },
  season_tasks: [
    { key: 'weekly_runs', name: '本周运动 3 次', type: 'weekly_count', target: 3, reward_energy: 60 },
    { key: 'weekly_area', name: '本周圈地 2 万 m²', type: 'weekly_area_m2', target: 20000, reward_energy: 80 },
    { key: 'weekly_distance', name: '本周跑够 15 km', type: 'weekly_distance_km', target: 15, reward_energy: 80 },
    { key: 'new_sport', name: '尝试一项本赛季没做过的运动', type: 'new_sport', target: 1, reward_energy: 50 },
  ],
  medals: [
    { key: 'distance_100', name: '百公里', type: 'distance_km', target: 100, distance_km: 100 },
    { key: 'guardian', name: '守护者', type: 'defends', target: 5 },
    { key: 'ten_loops', name: '一夜十圈', type: 'loops_single', target: 10 },
    { key: 'monster_hunter', name: '怪兽猎人', type: 'boss_defeats', target: 5 },
    { key: 'treasure', name: '寻宝人', type: 'chests', target: 20 },
    { key: 'orienteer', name: '城市定向家', type: 'routes', target: 3 },
  ],
  companion: { feed_cost: 50, feed_exp: 10, exp_per_100m: 1, exp_per_level: 100 },
  relay: { default_legs: 6, leg_km: 3, duration_h: 168, reward_energy: 100 },
};

export const clone = <T,>(c: T): T => JSON.parse(JSON.stringify(c)) as T;

/** V1 medals only have distance_km; give them type/target so the editor and diff see one shape. */
export function normalize(c: Config): Config {
  const n = clone(c);
  if (n.medals) n.medals = n.medals.map((m) => ({ ...m, type: m.type ?? 'distance_km', target: m.target ?? m.distance_km ?? 0 }));
  return n;
}

// ---------------- diff ----------------

export interface Change {
  path: string;
  label: string;
  from: string | number;
  to: string | number;
  tab: Tab;
}

export const TOP_FIELDS: { key: string; label: string }[] = [
  { key: 'daily_energy_cap', label: '每人每日能量上限' },
  { key: 'slots_per_territory', label: '每块领地建造位' },
  { key: 'base_station_slots', label: '基础驻扎位' },
  { key: 'min_claim_area_m2', label: '最小圈地面积 m²' },
  { key: 'boss_strike_cost', label: '攻打怪兽消耗能量' },
];
export const BUILDING_FIELDS: { key: keyof BuildingConf; label: string }[] = [
  { key: 'cost', label: '建造能量' },
  { key: 'guard', label: '守卫 +' },
  { key: 'daily_energy', label: '每日产能量' },
  { key: 'unlock_level', label: '解锁等级' },
];
export const ROLE_FIELDS: { key: keyof RoleConf; label: string }[] = [
  { key: 'threshold', label: '招募门槛' },
  { key: 'buff_value', label: '加成数值' },
  { key: 'buff_text', label: '加成说明' },
];
export const ENERGY_FIELDS: { key: keyof EnergyRule; label: string }[] = [
  { key: 'per', label: '换算单位量' },
  { key: 'energy', label: '换得能量' },
];

const EGG_NAMES: Record<string, string> = { firetail: '火尾蜥蛋', nightnewt: '夜行蝾螈蛋', axolotl: '六角龙蛋', frog: '雨蛙蛋', gecko: '闪电壁虎蛋' };

export function dropItemName(c: Config, item: string, kind: string): string {
  if (kind === 'energy') return '能量';
  if (kind === 'role') return c.roles.find((r) => r.key === item)?.name ?? item;
  if (kind === 'blueprint') return `${c.buildings.find((x) => x.key === item)?.name ?? item}图纸`;
  if (kind === 'egg') return c.companions?.find((x) => x.key === item)?.name ?? EGG_NAMES[item] ?? item;
  return item;
}

function byKey<T>(arr: T[] | undefined, key: (x: T) => string): Map<string, T> {
  return new Map((arr ?? []).map((x) => [key(x), x]));
}

const show = (v: unknown): string | number => {
  if (v === undefined || v === null) return '—';
  if (typeof v === 'boolean') return v ? '是' : '否';
  return v as string | number;
};

/** Old → new list over every field this page edits. */
export function diff(base: Config, draft: Config): Change[] {
  const out: Change[] = [];
  const push = (tab: Tab, path: string, label: string, a: unknown, b: unknown) => {
    if ((a ?? null) !== (b ?? null) && !(a === undefined && b === false)) out.push({ tab, path, label, from: show(a), to: show(b) });
  };
  const list = <T,>(tab: Tab, section: string, title: string, a: T[] | undefined, b: T[] | undefined, key: (x: T, i: number) => string, name: (x: T) => string, fields: { key: keyof T; label: string }[]) => {
    const old = new Map((a ?? []).map((x, i) => [key(x, i), x]));
    const now = new Map((b ?? []).map((x, i) => [key(x, i), x]));
    for (const [k, x] of now) {
      const o = old.get(k);
      if (!o) out.push({ tab, path: `${section}.${k}`, label: `${title} · 新增「${name(x)}」`, from: '—', to: '新增' });
      else for (const f of fields) push(tab, `${section}.${k}.${String(f.key)}`, `${title} · ${name(x)} · ${f.label}`, o[f.key], x[f.key]);
    }
    for (const [k, x] of old) if (!now.has(k)) out.push({ tab, path: `${section}.${k}`, label: `${title} · 删除「${name(x)}」`, from: name(x), to: '删除' });
  };

  for (const f of TOP_FIELDS) push(f.key === 'daily_energy_cap' ? 'energy' : 'buildings', f.key, f.label, base[f.key], draft[f.key]);
  const bb = byKey(base.buildings, (b) => b.key);
  for (const b of draft.buildings) {
    for (const f of BUILDING_FIELDS) push('buildings', `buildings.${b.key}.${f.key}`, `${b.name} · ${f.label}`, bb.get(b.key)?.[f.key], b[f.key]);
    push('buildings', `buildings.${b.key}.blueprint_bypass_level`, `${b.name} · 图纸可越级建造`, bb.get(b.key)?.blueprint_bypass_level, b.blueprint_bypass_level);
  }
  const rr = byKey(base.roles, (r) => r.key);
  for (const r of draft.roles) for (const f of ROLE_FIELDS) push('roles', `roles.${r.key}.${f.key}`, `${r.name} · ${f.label}`, rr.get(r.key)?.[f.key], r[f.key]);
  const bo = byKey(base.bosses, (b) => b.key);
  for (const b of draft.bosses) {
    const old = byKey(bo.get(b.key)?.drops, (d) => d.item);
    for (const d of b.drops) push('drops', `bosses.${b.key}.${d.item}`, `${b.name} · ${dropItemName(draft, d.item, d.kind)} 掉率 %`, old.get(d.item)?.percent, d.percent);
  }
  const ee = byKey(base.energy, (e) => e.sport);
  for (const e of draft.energy) for (const f of ENERGY_FIELDS) push('energy', `energy.${e.sport}.${f.key}`, `${e.name} · ${f.label}`, ee.get(e.sport)?.[f.key], e[f.key]);

  // V2 sections
  if (draft.boss) {
    for (const g of BOSS_GROUPS) for (const f of g.fields) push('boss', `boss.${f.key}`, `怪兽 · ${f.label}`, base.boss?.[f.key], draft.boss[f.key]);
    const od = byKey(base.boss?.damage, (d) => d.sport);
    for (const d of draft.boss.damage) {
      const name = SPORT_LABEL[d.sport] ?? d.sport;
      push('boss', `boss.damage.${d.sport}.per`, `怪兽伤害 · ${name} · 每 ${UNIT_LABEL[d.unit] ?? d.unit}`, od.get(d.sport)?.per, d.per);
      push('boss', `boss.damage.${d.sport}.damage`, `怪兽伤害 · ${name} · 伤害`, od.get(d.sport)?.damage, d.damage);
    }
  }
  if (draft.chest) for (const f of CHEST_FIELDS) push('chest', `chest.${f.key}`, `宝箱 · ${f.label}`, base.chest?.[f.key], draft.chest[f.key]);
  if (draft.defense) for (const f of DEFENSE_FIELDS) push('defense', `defense.${f.key}`, `守地 · ${f.label}`, base.defense?.[f.key], draft.defense[f.key]);
  if (draft.companion) for (const f of COMPANION_FIELDS) push('companion', `companion.${f.key}`, `伙伴 · ${f.label}`, base.companion?.[f.key], draft.companion[f.key]);
  if (draft.relay) for (const f of RELAY_FIELDS) push('relay', `relay.${f.key}`, `接力 · ${f.label}`, base.relay?.[f.key], draft.relay[f.key]);
  list('tiers', 'season.tiers', '段位', base.season?.tiers, draft.season?.tiers, (_, i) => String(i), (t) => t.name || '（未命名）', [
    { key: 'name', label: '名称' },
    { key: 'min_km2', label: '最低 km²' },
  ]);
  list('tasks', 'season_tasks', '赛季任务', base.season_tasks, draft.season_tasks, (t, i) => t.key || `#${i}`, (t) => t.name || t.key || '（未命名）', [
    { key: 'name', label: '名称' },
    { key: 'type', label: '类型' },
    { key: 'target', label: '目标' },
    { key: 'reward_energy', label: '奖励能量' },
  ]);
  list('medals', 'medals', '奖牌', base.medals, draft.medals, (m, i) => m.key || `#${i}`, (m) => m.name || m.key || '（未命名）', [
    { key: 'name', label: '名称' },
    { key: 'type', label: '类型' },
    { key: 'target', label: '目标' },
  ]);
  return out;
}

// ---------------- validation ----------------

export interface Problem {
  tab: Tab;
  text: string;
}

export function dropSum(b: BossConf): number {
  return Math.round(b.drops.reduce((s, d) => s + (Number(d.percent) || 0), 0) * 100) / 100;
}

const bad = (v: unknown, f: NumField) => typeof v !== 'number' || !Number.isFinite(v) || v < f.min || (f.max !== undefined && v > f.max);
const range = (f: NumField) => (f.max !== undefined ? `${f.min}–${f.max}` : f.min > 0 ? `≥ ${f.min}` : '≥ 0');

function checkFields<T extends object>(out: Problem[], tab: Tab, title: string, obj: T | undefined, fields: NumField[]) {
  if (!obj) return;
  for (const f of fields) {
    const v = (obj as Record<string, unknown>)[f.key];
    if (bad(v, f)) out.push({ tab, text: `${title}「${f.label}」须为 ${range(f)}` });
  }
}

const KEY_RE = /^[a-z][a-z0-9_]*$/;

export function validate(c: Config): Problem[] {
  const out: Problem[] = [];
  for (const b of c.bosses ?? []) if (Math.abs(dropSum(b) - 100) > 1e-6) out.push({ tab: 'drops', text: `${b.name} 掉落合计 ${dropSum(b)}%，必须等于 100%` });
  for (const b of c.buildings) if (!(b.cost > 0)) out.push({ tab: 'buildings', text: `${b.name} 建造能量必须大于 0` });
  for (const e of c.energy) if (!(e.per > 0)) out.push({ tab: 'energy', text: `${e.name} 换算单位量必须大于 0` });
  if (!(c.daily_energy_cap > 0)) out.push({ tab: 'energy', text: '每日能量上限必须大于 0' });

  if (c.boss) {
    for (const g of BOSS_GROUPS) checkFields(out, 'boss', '怪兽', c.boss, g.fields);
    if (c.boss.combo_max_pct < c.boss.combo_pct) out.push({ tab: 'boss', text: '怪兽「连击加成上限」不能小于每人连击加成' });
    for (const d of c.boss.damage ?? []) if (!(d.per > 0) || !(d.damage >= 0)) out.push({ tab: 'boss', text: `怪兽伤害规则「${SPORT_LABEL[d.sport] ?? d.sport}」须为正数` });
  }
  if (c.chest) {
    checkFields(out, 'chest', '宝箱', c.chest, CHEST_FIELDS);
    if (c.chest.energy_max < c.chest.energy_min) out.push({ tab: 'chest', text: '宝箱能量上限不能小于下限' });
  }
  checkFields(out, 'defense', '守地', c.defense, DEFENSE_FIELDS);
  checkFields(out, 'companion', '伙伴', c.companion, COMPANION_FIELDS);
  checkFields(out, 'relay', '接力', c.relay, RELAY_FIELDS);
  if (c.relay && !Number.isInteger(c.relay.default_legs)) out.push({ tab: 'relay', text: '接力棒数必须是整数' });

  const tiers = c.season?.tiers;
  if (tiers) {
    if (tiers.length < 2) out.push({ tab: 'tiers', text: '段位至少 2 个' });
    if (tiers[0] && tiers[0].min_km2 !== 0) out.push({ tab: 'tiers', text: `第一个段位「${tiers[0].name}」的最低面积必须是 0` });
    tiers.forEach((t, i) => {
      if (!t.name.trim()) out.push({ tab: 'tiers', text: `第 ${i + 1} 个段位缺少名称` });
      if (i > 0 && !(t.min_km2 > tiers[i - 1].min_km2)) out.push({ tab: 'tiers', text: `段位「${t.name || i + 1}」最低面积 ${t.min_km2} 必须大于「${tiers[i - 1].name}」的 ${tiers[i - 1].min_km2}` });
    });
    const names = tiers.map((t) => t.name.trim()).filter(Boolean);
    if (new Set(names).size !== names.length) out.push({ tab: 'tiers', text: '段位名称不能重复' });
  }
  const keyed = <T extends { key: string; name: string; target?: number }>(tab: Tab, title: string, arr: T[] | undefined) => {
    if (!arr) return;
    const seen = new Set<string>();
    arr.forEach((x, i) => {
      const who = x.name || x.key || `第 ${i + 1} 行`;
      if (!KEY_RE.test(x.key)) out.push({ tab, text: `${title}「${who}」的 key 须为小写字母开头的 a-z、0-9、_` });
      else if (seen.has(x.key)) out.push({ tab, text: `${title} key「${x.key}」重复` });
      seen.add(x.key);
      if (!x.name.trim()) out.push({ tab, text: `${title}「${x.key || i + 1}」缺少名称` });
      if (!(Number(x.target) > 0)) out.push({ tab, text: `${title}「${who}」的目标必须大于 0` });
    });
  };
  keyed('tasks', '赛季任务', c.season_tasks);
  for (const t of c.season_tasks ?? []) {
    if (!(t.type in SEASON_TASK_TYPE)) out.push({ tab: 'tasks', text: `赛季任务「${t.name}」类型无效` });
    if (!(t.reward_energy >= 0)) out.push({ tab: 'tasks', text: `赛季任务「${t.name}」奖励不能为负` });
  }
  keyed('medals', '奖牌', c.medals);
  for (const m of c.medals ?? []) if (m.type && !(m.type in MEDAL_TYPE)) out.push({ tab: 'medals', text: `奖牌「${m.name}」类型无效` });
  return out;
}
