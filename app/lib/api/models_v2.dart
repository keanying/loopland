// V2 batch 1「玩法深化」models: docs/api/v2-1-玩法.md. Same tolerant parsing
// as the V1 models (shares their private helpers).
part of 'models.dart';

LatLng? _ll(Object? v) => v is Map ? LatLng.fromJson(v.cast<String, dynamic>()) : null;
UserRef? _user(Object? v) => v is Map ? UserRef.fromJson(v.cast<String, dynamic>()) : null;
CrewRef? _crew(Object? v) => v is Map ? CrewRef.fromJson(v.cast<String, dynamic>()) : null;
List<String> _strs(Object? v) => v is List ? [for (final e in v) if (e != null) '$e'] : const [];

/// Chinese names of the four monster kinds.
const monsterNames = {'sofa': '沙发怪', 'bat': '熬夜蝠', 'smog': '雾霾怪', 'sugar': '糖分怪'};

// ───────────────────────────── 玩法配置（V2） ─────────────────────────────

class DamageRule {
  const DamageRule({required this.sport, this.label = '', required this.per, required this.unit, required this.damage});
  final String sport;

  /// Display name; the config omits it (falls back to the sport name).
  final String label;
  final double per;

  /// `km | count | min`.
  final String unit;
  final int damage;

  factory DamageRule.fromJson(Json j) => DamageRule(
        sport: _s(j['sport']),
        label: _s(j['label']),
        per: _d(j['per'], 1),
        unit: _s(j['unit'], 'km'),
        damage: _i(j['damage']),
      );

  /// "每 1 km = 100 伤害", "每 100 个 = 30 伤害", "每 10 分钟 = 30 伤害".
  String get text {
    final p = per % 1 == 0 ? per.toInt().toString() : per.toString();
    final u = switch (unit) { 'km' => ' km', 'count' => ' 个', 'min' => ' 分钟', _ => ' $unit' };
    return '每 $p$u = $damage 伤害';
  }
}

class BossConfig {
  const BossConfig({
    this.strikeCost = 100,
    this.strikeDamage = 40,
    this.strikeCooldownS = 30,
    this.comboWindowS = 300,
    this.comboPct = 10,
    this.comboMaxPct = 50,
    this.damage = const [],
    this.defaultHp = 10000,
    this.radiusM = 1000,
    this.durationH = 48,
    this.engageH = 6,
    this.expireRefundPct = 20,
    this.topExtraRolls = 3,
    this.dropEnergy = 200,
    this.yieldPenaltyPct = 50,
  });
  final int strikeCost, strikeDamage, strikeCooldownS, comboWindowS, comboPct, comboMaxPct;
  final List<DamageRule> damage;
  final int defaultHp;
  final double radiusM;
  final int durationH, engageH, expireRefundPct, topExtraRolls, dropEnergy, yieldPenaltyPct;

  factory BossConfig.fromJson(Json j) => BossConfig(
        strikeCost: _i(j['strike_cost'], 100),
        strikeDamage: _i(j['strike_damage'], 40),
        strikeCooldownS: _i(j['strike_cooldown_s'], 30),
        comboWindowS: _i(j['combo_window_s'], 300),
        comboPct: _i(j['combo_pct'], 10),
        comboMaxPct: _i(j['combo_max_pct'], 50),
        damage: _l(j['damage'], DamageRule.fromJson),
        defaultHp: _i(j['default_hp'], 10000),
        radiusM: _d(j['radius_m'], 1000),
        durationH: _i(j['duration_h'], 48),
        engageH: _i(j['engage_h'], 6),
        expireRefundPct: _i(j['expire_refund_pct'], 20),
        topExtraRolls: _i(j['top_extra_rolls'], 3),
        dropEnergy: _i(j['drop_energy'], 200),
        yieldPenaltyPct: _i(j['yield_penalty_pct'], 50),
      );
}

class ChestConfig {
  const ChestConfig({this.energyMin = 20, this.energyMax = 60, this.radiusM = 50, this.dailySpawn = 20, this.durationH = 24});
  final int energyMin, energyMax;
  final double radiusM;
  final int dailySpawn, durationH;
  factory ChestConfig.fromJson(Json j) => ChestConfig(
        energyMin: _i(j['energy_min'], 20),
        energyMax: _i(j['energy_max'], 60),
        radiusM: _d(j['radius_m'], 50),
        dailySpawn: _i(j['daily_spawn'], 20),
        durationH: _i(j['duration_h'], 24),
      );
}

class DefenseConfig {
  const DefenseConfig({this.windowH = 24, this.maxGuard = 2000});
  final int windowH, maxGuard;
  factory DefenseConfig.fromJson(Json j) =>
      DefenseConfig(windowH: _i(j['window_h'], 24), maxGuard: _i(j['max_guard'], 2000));
}

class TierDef {
  const TierDef({required this.name, required this.minM2});
  final String name;

  /// Lower bound in m². The config uses `min_km2`, GET /v1/season `min_m2`.
  final double minM2;
  factory TierDef.fromJson(Json j) =>
      TierDef(name: _s(j['name']), minM2: _dn(j['min_m2']) ?? _d(j['min_km2']) * 1e6);
}

class SeasonTaskDef {
  const SeasonTaskDef({required this.key, required this.name, required this.type, required this.target, this.rewardEnergy = 0});
  final String key, name, type;
  final double target;
  final int rewardEnergy;
  factory SeasonTaskDef.fromJson(Json j) => SeasonTaskDef(
      key: _s(j['key']), name: _s(j['name']), type: _s(j['type']), target: _d(j['target'], 1), rewardEnergy: _i(j['reward_energy']));
}

class CompanionConfig {
  const CompanionConfig({this.feedCost = 50, this.feedExp = 10, this.expPer100m = 1, this.expPerLevel = 100});
  final int feedCost, feedExp, expPer100m, expPerLevel;
  factory CompanionConfig.fromJson(Json j) => CompanionConfig(
        feedCost: _i(j['feed_cost'], 50),
        feedExp: _i(j['feed_exp'], 10),
        expPer100m: _i(j['exp_per_100m'], 1),
        expPerLevel: _i(j['exp_per_level'], 100),
      );
}

class RelayConfig {
  const RelayConfig({this.defaultLegs = 6, this.legKm = 3, this.durationH = 168, this.rewardEnergy = 100});
  final int defaultLegs;
  final double legKm;
  final int durationH, rewardEnergy;
  factory RelayConfig.fromJson(Json j) => RelayConfig(
        defaultLegs: _i(j['default_legs'], 6),
        legKm: _d(j['leg_km'], 3),
        durationH: _i(j['duration_h'], 168),
        rewardEnergy: _i(j['reward_energy'], 100),
      );
}

// ───────────────────────────── 地图玩法对象 ─────────────────────────────

class MapBoss {
  const MapBoss({
    required this.id,
    required this.kind,
    required this.name,
    this.level = 1,
    required this.center,
    this.radiusM = 1000,
    this.hp = 0,
    this.hpMax = 1,
    this.expiresAt,
    this.locationName = '',
  });
  final int id;

  /// `sofa | bat | smog | sugar`.
  final String kind;
  final String name;
  final int level;
  final LatLng center;
  final double radiusM;
  final int hp, hpMax;
  final DateTime? expiresAt;
  final String locationName;

  double get hpFraction => hpMax <= 0 ? 0 : (hp / hpMax).clamp(0.0, 1.0);

  factory MapBoss.fromJson(Json j) => MapBoss(
        id: _i(j['id']),
        kind: _s(j['kind'], 'sofa'),
        name: _s(j['name'], monsterNames[_s(j['kind'])] ?? '怪兽'),
        level: _i(j['level'], 1),
        center: _ll(j['center']) ?? const LatLng(0, 0),
        radiusM: _d(j['radius_m'], 1000),
        hp: _i(j['hp']),
        hpMax: _i(j['hp_max'], 1),
        expiresAt: _dt(j['expires_at']),
        locationName: _s(j['location_name']),
      );
}

class MapChest {
  const MapChest({required this.id, required this.center, this.radiusM = 50, this.expiresAt, this.merchant, this.perk});
  final int id;
  final LatLng center;
  final double radiusM;
  final DateTime? expiresAt;

  /// V2 batch 4 (A-16): a merchant chest (opens a coupon instead of energy):
  /// `merchant` + `perk_title` in map objects (not in the contract text yet).
  final PerkMerchant? merchant;
  final Perk? perk;
  bool get isMerchant => merchant != null || perk != null;

  factory MapChest.fromJson(Json j) => MapChest(
      id: _i(j['id']),
      center: _ll(j['center']) ?? const LatLng(0, 0),
      radiusM: _d(j['radius_m'], 50),
      expiresAt: _dt(j['expires_at']),
      merchant: PerkMerchant.maybe(j['merchant']),
      // The server sends `perk_title` on merchant chests; a full `perk` also works.
      perk: Perk.maybe(j['perk']) ?? (j['perk_title'] is String ? Perk(title: j['perk_title'] as String) : null));
}

class MapCheckpoint {
  const MapCheckpoint({
    required this.routeId,
    required this.index,
    required this.name,
    required this.center,
    this.radiusM = 60,
    this.state = 'todo',
  });
  final int routeId, index;
  final String name;
  final LatLng center;
  final double radiusM;

  /// `next | done | todo`.
  final String state;
  bool get isNext => state == 'next';
  bool get isDone => state == 'done';

  factory MapCheckpoint.fromJson(Json j) => MapCheckpoint(
        routeId: _i(j['route_id']),
        index: _i(j['index']),
        name: _s(j['name']),
        center: _ll(j['center']) ?? const LatLng(0, 0),
        radiusM: _d(j['radius_m'], 60),
        state: _s(j['state'], 'todo'),
      );
}

/// `GET /v1/map/objects`.
class MapObjects {
  const MapObjects({
    this.bosses = const [],
    this.chests = const [],
    this.checkpoints = const [],
    this.supplies = const [],
    this.venues = const [],
  });
  final List<MapBoss> bosses;
  final List<MapChest> chests;
  final List<MapCheckpoint> checkpoints;

  /// V2 batch 4 (A-16): 补给站.
  final List<MapSupply> supplies;

  /// V2 batch 4 (C-08): venues (据点) with the 馆主's avatar.
  final List<MapVenue> venues;

  bool get isEmpty => bosses.isEmpty && chests.isEmpty && checkpoints.isEmpty && supplies.isEmpty && venues.isEmpty;

  factory MapObjects.fromJson(Json j) => MapObjects(
        bosses: _l(j['bosses'], MapBoss.fromJson),
        chests: _l(j['chests'], MapChest.fromJson),
        checkpoints: _l(j['checkpoints'], MapCheckpoint.fromJson),
        supplies: _l(j['supplies'], MapSupply.fromJson),
        venues: _l(j['venues'], MapVenue.fromJson),
      );
}

// ───────────────────────────── 城市怪兽 ─────────────────────────────

class BossStrikeInfo {
  const BossStrikeInfo({this.cost = 100, this.damage = 40, this.cooldownS = 30, this.availableInS = 0});
  final int cost, damage, cooldownS, availableInS;
  factory BossStrikeInfo.fromJson(Json j) => BossStrikeInfo(
      cost: _i(j['cost'], 100), damage: _i(j['damage'], 40), cooldownS: _i(j['cooldown_s'], 30), availableInS: _i(j['available_in_s']));
}

class BossRankEntry {
  const BossRankEntry({required this.rank, required this.user, required this.damage});
  final int rank;
  final UserRef user;
  final int damage;
  factory BossRankEntry.fromJson(Json j) => BossRankEntry(
      rank: _i(j['rank']), user: _user(j['user']) ?? const UserRef(id: 0, nickname: ''), damage: _i(j['damage']));
}

class BossMe {
  const BossMe({this.damage = 0, this.rank, this.engagedUntil});
  final int damage;
  final int? rank;
  final DateTime? engagedUntil;
  factory BossMe.fromJson(Json j) =>
      BossMe(damage: _i(j['damage']), rank: _in(j['rank']), engagedUntil: _dt(j['engaged_until']));
}

class BossDrop {
  const BossDrop({required this.item, required this.kind, required this.name, required this.percent});
  final String item;

  /// `role | blueprint | egg | energy`.
  final String kind;
  final String name;
  final double percent;
  factory BossDrop.fromJson(Json j) =>
      BossDrop(item: _s(j['item']), kind: _s(j['kind']), name: _s(j['name']), percent: _d(j['percent']));
}

class BossReward {
  const BossReward({required this.item, required this.kind, required this.name, this.convertedEnergy});
  final String item, kind, name;

  /// Set when a duplicate role / blueprint was converted to energy.
  final int? convertedEnergy;
  factory BossReward.fromJson(Json j) => BossReward(
      item: _s(j['item']), kind: _s(j['kind']), name: _s(j['name']), convertedEnergy: _in(j['converted_energy']));
}

/// `GET /v1/bosses/{id}`.
class Boss {
  const Boss({
    required this.id,
    required this.kind,
    required this.name,
    this.level = 1,
    this.description = '',
    this.locationName = '',
    this.center,
    this.radiusM = 1000,
    this.hp = 0,
    this.hpMax = 1,
    this.status = 'active',
    this.spawnedAt,
    this.expiresAt,
    this.defeatedAt,
    this.occupiedTerritories = 0,
    this.effectText = '',
    this.damageRules = const [],
    this.strike = const BossStrikeInfo(),
    this.participants = 0,
    this.rank = const [],
    this.me = const BossMe(),
    this.drops = const [],
    this.myRewards = const [],
  });
  final int id;
  final String kind, name;
  final int level;
  final String description, locationName;
  final LatLng? center;
  final double radiusM;
  final int hp, hpMax;

  /// `active | defeated | expired`.
  final String status;
  final DateTime? spawnedAt, expiresAt, defeatedAt;
  final int occupiedTerritories;
  final String effectText;
  final List<DamageRule> damageRules;
  final BossStrikeInfo strike;
  final int participants;
  final List<BossRankEntry> rank;
  final BossMe me;
  final List<BossDrop> drops;
  final List<BossReward> myRewards;

  bool get isActive => status == 'active';
  bool get isDefeated => status == 'defeated';
  double get hpFraction => hpMax <= 0 ? 0 : (hp / hpMax).clamp(0.0, 1.0);

  Boss copyWith({int? hp, String? status, BossStrikeInfo? strike, BossMe? me}) => Boss(
        id: id,
        kind: kind,
        name: name,
        level: level,
        description: description,
        locationName: locationName,
        center: center,
        radiusM: radiusM,
        hp: hp ?? this.hp,
        hpMax: hpMax,
        status: status ?? this.status,
        spawnedAt: spawnedAt,
        expiresAt: expiresAt,
        defeatedAt: defeatedAt,
        occupiedTerritories: occupiedTerritories,
        effectText: effectText,
        damageRules: damageRules,
        strike: strike ?? this.strike,
        participants: participants,
        rank: rank,
        me: me ?? this.me,
        drops: drops,
        myRewards: myRewards,
      );

  factory Boss.fromJson(Json j) => Boss(
        id: _i(j['id']),
        kind: _s(j['kind'], 'sofa'),
        name: _s(j['name'], monsterNames[_s(j['kind'])] ?? '怪兽'),
        level: _i(j['level'], 1),
        description: _s(j['description']),
        locationName: _s(j['location_name']),
        center: _ll(j['center']),
        radiusM: _d(j['radius_m'], 1000),
        hp: _i(j['hp']),
        hpMax: _i(j['hp_max'], 1),
        status: _s(j['status'], 'active'),
        spawnedAt: _dt(j['spawned_at']),
        expiresAt: _dt(j['expires_at']),
        defeatedAt: _dt(j['defeated_at']),
        occupiedTerritories: _i(j['occupied_territories']),
        effectText: _s(j['effect_text']),
        damageRules: _l(j['damage_rules'], DamageRule.fromJson),
        strike: BossStrikeInfo.fromJson(_m(j['strike'])),
        participants: _i(j['participants']),
        rank: _l(j['rank'], BossRankEntry.fromJson),
        me: BossMe.fromJson(_m(j['me'])),
        drops: _l(j['drops'], BossDrop.fromJson),
        myRewards: _l(j['my_rewards'], BossReward.fromJson),
      );
}

/// `POST /v1/bosses/{id}/strike`.
class StrikeResult {
  const StrikeResult({required this.damage, this.comboPct = 0, required this.energy, required this.bossId, required this.hp, required this.status});
  final int damage, comboPct, energy, bossId, hp;
  final String status;
  factory StrikeResult.fromJson(Json j) {
    final b = _m(j['boss']);
    return StrikeResult(
      damage: _i(j['damage']),
      comboPct: _i(j['combo_pct']),
      energy: _i(j['energy']),
      bossId: _i(b['id']),
      hp: _i(b['hp']),
      status: _s(b['status'], 'active'),
    );
  }
}

/// `POST /v1/chests/{id}/open`.
class ChestOpenResult {
  const ChestOpenResult({required this.energy, this.bonus = false, this.coupon});
  final int energy;
  final bool bonus;

  /// V2 batch 4: merchant chests give a coupon instead of energy.
  final Coupon? coupon;
  factory ChestOpenResult.fromJson(Json j) =>
      ChestOpenResult(energy: _i(j['energy']), bonus: _b(j['bonus']), coupon: Coupon.maybe(j['coupon']));
}

// ───────────────────────────── 守地挑战 ─────────────────────────────

class TerritoryDefense {
  const TerritoryDefense({this.deadline, this.attackedBy});
  final DateTime? deadline;
  final UserRef? attackedBy;
  factory TerritoryDefense.fromJson(Json j) => TerritoryDefense(deadline: _dt(j['deadline']), attackedBy: _user(j['attacked_by']));
  static TerritoryDefense? parse(Object? v) => v is Map ? TerritoryDefense.fromJson(v.cast<String, dynamic>()) : null;
}

// ───────────────────────────── 赛季 / 联赛 ─────────────────────────────

class SeasonInfo {
  const SeasonInfo({required this.id, required this.name, this.startsAt, this.endsAt, this.daysLeft = 0});
  final int id;
  final String name;
  final DateTime? startsAt, endsAt;
  final int daysLeft;

  /// "S3" from "S3 冬季赛".
  String get shortName => name.split(' ').first;

  factory SeasonInfo.fromJson(Json j) => SeasonInfo(
      id: _i(j['id']), name: _s(j['name']), startsAt: _dt(j['starts_at']), endsAt: _dt(j['ends_at']), daysLeft: _i(j['days_left']));
}

class TierRef {
  const TierRef({required this.name, this.level = ''});
  final String name;

  /// `III | II | I` (may be empty for the top tier).
  final String level;
  String get text => level.isEmpty ? name : '$name $level';
  factory TierRef.fromJson(Json j) => TierRef(name: _s(j['name']), level: _s(j['level']));
}

class SeasonMe {
  const SeasonMe({this.areaM2 = 0, this.tier, this.next, this.needM2, this.rank});
  final double areaM2;
  final TierRef? tier;
  final TierRef? next;

  /// Area still needed for [next].
  final double? needM2;
  final int? rank;
  factory SeasonMe.fromJson(Json j) {
    final next = _mn(j['next']);
    return SeasonMe(
      areaM2: _d(j['area_m2']),
      tier: _mn(j['tier']) == null ? null : TierRef.fromJson(_m(j['tier'])),
      next: next == null ? null : TierRef.fromJson(next),
      needM2: next == null ? null : _dn(next['need_m2']),
      rank: _in(j['rank']),
    );
  }
}

class SeasonCrew {
  const SeasonCrew({required this.id, required this.name, this.areaM2 = 0, this.rank});
  final int id;
  final String name;
  final double areaM2;
  final int? rank;
  factory SeasonCrew.fromJson(Json j) =>
      SeasonCrew(id: _i(j['id']), name: _s(j['name']), areaM2: _d(j['area_m2']), rank: _in(j['rank']));
}

class SeasonTopEntry {
  const SeasonTopEntry({required this.rank, this.user, this.crew, this.areaM2 = 0});
  final int rank;
  final UserRef? user;
  final CrewRef? crew;
  final double areaM2;
  String get name => user?.nickname ?? crew?.name ?? '';
  factory SeasonTopEntry.fromJson(Json j) =>
      SeasonTopEntry(rank: _i(j['rank']), user: _user(j['user']), crew: _crew(j['crew']), areaM2: _d(j['area_m2']));
}

class SeasonTask {
  const SeasonTask({
    required this.key,
    required this.name,
    this.type = '',
    this.progress = 0,
    this.target = 1,
    this.rewardEnergy = 0,
    this.completed = false,
  });
  final String key, name, type;
  final double progress, target;
  final int rewardEnergy;
  final bool completed;

  double get fraction => target <= 0 ? 0 : (progress / target).clamp(0.0, 1.0);

  /// "2 / 3 次", "1.2 / 2 万 m²", "8.4 / 15 km".
  String get progressText {
    String n(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);
    return switch (type) {
      'weekly_area_m2' => '${n(progress / 10000)} / ${n(target / 10000)} 万 m²',
      'weekly_distance_km' => '${n(progress)} / ${n(target)} km',
      'weekly_count' => '${n(progress)} / ${n(target)} 次',
      _ => '${n(progress)} / ${n(target)}',
    };
  }

  factory SeasonTask.fromJson(Json j) => SeasonTask(
        key: _s(j['key']),
        name: _s(j['name']),
        type: _s(j['type']),
        progress: _d(j['progress']),
        target: _d(j['target'], 1),
        rewardEnergy: _i(j['reward_energy']),
        completed: _b(j['completed']),
      );
}

class SeasonMedal {
  const SeasonMedal({required this.key, required this.name, this.type = '', this.progress = 0, this.target = 1, this.obtained = false, this.obtainedAt});
  final String key, name, type;
  final double progress, target;
  final bool obtained;
  final DateTime? obtainedAt;
  double get fraction => obtained ? 1 : (target <= 0 ? 0 : (progress / target).clamp(0.0, 1.0));
  String get progressText {
    String n(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);
    return '${n(progress)}/${n(target)}';
  }

  factory SeasonMedal.fromJson(Json j) => SeasonMedal(
        key: _s(j['key']),
        name: _s(j['name']),
        type: _s(j['type']),
        progress: _d(j['progress']),
        target: _d(j['target'], 1),
        obtained: _b(j['obtained']),
        obtainedAt: _dt(j['obtained_at']),
      );
}

/// `GET /v1/season`.
class SeasonOverview {
  const SeasonOverview({
    this.season,
    this.me = const SeasonMe(),
    this.crew,
    this.tiers = const [],
    this.top = const [],
    this.crewTop = const [],
    this.tasks = const [],
    this.medals = const [],
  });
  final SeasonInfo? season;
  final SeasonMe me;
  final SeasonCrew? crew;
  final List<TierDef> tiers;
  final List<SeasonTopEntry> top, crewTop;
  final List<SeasonTask> tasks;
  final List<SeasonMedal> medals;

  /// Progress inside the current tier (to the next tier's minimum).
  double get tierProgress {
    final t = me.tier;
    if (t == null || tiers.isEmpty) return 0;
    final i = tiers.indexWhere((x) => x.name == t.name);
    if (i < 0) return 0;
    if (i == tiers.length - 1) return 1;
    final lo = tiers[i].minM2, hi = tiers[i + 1].minM2;
    return hi <= lo ? 1 : ((me.areaM2 - lo) / (hi - lo)).clamp(0.0, 1.0);
  }

  factory SeasonOverview.fromJson(Json j) => SeasonOverview(
        season: _mn(j['season']) == null ? null : SeasonInfo.fromJson(_m(j['season'])),
        me: SeasonMe.fromJson(_m(j['me'])),
        crew: _mn(j['crew']) == null ? null : SeasonCrew.fromJson(_m(j['crew'])),
        tiers: _l(j['tiers'], TierDef.fromJson),
        top: _l(j['top'], SeasonTopEntry.fromJson),
        crewTop: _l(j['crew_top'], SeasonTopEntry.fromJson),
        tasks: _l(j['tasks'], SeasonTask.fromJson),
        medals: _l(j['medals'], SeasonMedal.fromJson),
      );
}

class LeagueEntry {
  const LeagueEntry({required this.rank, this.crew, this.scoreM2 = 0, this.activeMembers});
  final int rank;
  final CrewRef? crew;
  final double scoreM2;
  final int? activeMembers;
  factory LeagueEntry.fromJson(Json j) => LeagueEntry(
      rank: _i(j['rank']), crew: _crew(j['crew']), scoreM2: _d(j['score_m2']), activeMembers: _in(j['active_members']));
}

/// `GET /v1/league`.
class League {
  const League({this.weekStart = '', this.district = '', this.standings = const [], this.myCrew, this.lastWeek = const []});
  final String weekStart, district;
  final List<LeagueEntry> standings;
  final LeagueEntry? myCrew;
  final List<LeagueEntry> lastWeek;
  factory League.fromJson(Json j) => League(
        weekStart: _s(j['week_start']),
        district: _s(j['district']),
        standings: _l(j['standings'], LeagueEntry.fromJson),
        myCrew: _mn(j['my_crew']) == null ? null : LeagueEntry.fromJson(_m(j['my_crew'])),
        lastWeek: _l(j['last_week'], LeagueEntry.fromJson),
      );
}

// ───────────────────────────── 限时活动 / 城市定向 ─────────────────────────────

class CampaignRules {
  const CampaignRules({this.minDistanceKm, this.maxPaceSPerKm, this.startHourFrom, this.startHourTo, this.raw = const {}});
  final double? minDistanceKm;
  final double? maxPaceSPerKm;
  final int? startHourFrom, startHourTo;
  final Json raw;

  /// Rules in Chinese, one line each.
  List<String> get lines {
    String pace(double s) => "${s ~/ 60}'${(s % 60).round().toString().padLeft(2, '0')}\"";
    String km(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);
    return [
      if (minDistanceKm != null) '单次运动距离不少于 ${km(minDistanceKm!)} km',
      if (maxPaceSPerKm != null) '平均配速快于 ${pace(maxPaceSPerKm!)} / km',
      if (startHourFrom != null && startHourTo != null)
        '在 ${startHourFrom.toString().padLeft(2, '0')}:00 – ${startHourTo.toString().padLeft(2, '0')}:00 之间开始'
      else if (startHourFrom != null)
        '${startHourFrom.toString().padLeft(2, '0')}:00 之后开始'
      else if (startHourTo != null)
        '${startHourTo.toString().padLeft(2, '0')}:00 之前开始',
    ];
  }

  factory CampaignRules.fromJson(Json j) => CampaignRules(
        minDistanceKm: _dn(j['min_distance_km']),
        maxPaceSPerKm: _dn(j['max_pace_s_per_km']),
        startHourFrom: _in(j['start_hour_from']),
        startHourTo: _in(j['start_hour_to']),
        raw: j,
      );
}

class Campaign {
  const Campaign({
    required this.id,
    required this.title,
    this.type = '',
    this.description = '',
    this.rules = const CampaignRules(),
    this.startsAt,
    this.endsAt,
    this.rewardEnergy = 0,
    this.rewardMedal,
    this.completed = false,
    this.participants = 0,
  });
  final int id;
  final String title;

  /// `pace | night_run | distance`.
  final String type;
  final String description;
  final CampaignRules rules;
  final DateTime? startsAt, endsAt;
  final int rewardEnergy;
  final MedalRef? rewardMedal;
  final bool completed;
  final int participants;

  String get typeName => switch (type) { 'pace' => '配速挑战', 'night_run' => '夜跑专场', 'distance' => '距离挑战', _ => '限时活动' };

  bool isLive(DateTime now) => (startsAt == null || !now.isBefore(startsAt!)) && (endsAt == null || now.isBefore(endsAt!));

  factory Campaign.fromJson(Json j) => Campaign(
        id: _i(j['id']),
        title: _s(j['title']),
        type: _s(j['type']),
        description: _s(j['description']),
        rules: CampaignRules.fromJson(_m(j['rules'])),
        startsAt: _dt(j['starts_at']),
        endsAt: _dt(j['ends_at']),
        rewardEnergy: _i(j['reward_energy']),
        rewardMedal: _mn(j['reward_medal']) == null ? null : MedalRef.fromJson(_m(j['reward_medal'])),
        completed: _b(j['completed']),
        participants: _i(j['participants']),
      );
}

class RouteCheckpoint {
  const RouteCheckpoint({required this.index, required this.name, this.center, this.radiusM = 60, this.state = 'todo'});
  final int index;
  final String name;
  final LatLng? center;
  final double radiusM;

  /// `done | next | todo`.
  final String state;
  bool get isDone => state == 'done';
  bool get isNext => state == 'next';
  factory RouteCheckpoint.fromJson(Json j) => RouteCheckpoint(
      index: _i(j['index']), name: _s(j['name']), center: _ll(j['center']), radiusM: _d(j['radius_m'], 60), state: _s(j['state'], 'todo'));
}

/// `GET /v1/routes/{id}`.
class CityRoute {
  const CityRoute({
    required this.id,
    required this.name,
    this.description = '',
    this.rewardEnergy = 0,
    this.startsAt,
    this.endsAt,
    this.checkpoints = const [],
    this.completed = false,
    this.completedAt,
  });
  final int id;
  final String name, description;
  final int rewardEnergy;
  final DateTime? startsAt, endsAt;
  final List<RouteCheckpoint> checkpoints;
  final bool completed;
  final DateTime? completedAt;

  int get doneCount => checkpoints.where((c) => c.isDone).length;
  RouteCheckpoint? get next => checkpoints.where((c) => c.isNext).firstOrNull;

  factory CityRoute.fromJson(Json j) => CityRoute(
        id: _i(j['id']),
        name: _s(j['name']),
        description: _s(j['description']),
        rewardEnergy: _i(j['reward_energy']),
        startsAt: _dt(j['starts_at']),
        endsAt: _dt(j['ends_at']),
        checkpoints: _l(j['checkpoints'], RouteCheckpoint.fromJson)..sort((a, b) => a.index.compareTo(b.index)),
        completed: _b(j['completed']),
        completedAt: _dt(j['completed_at']),
      );
}

// ───────────────────────────── 图鉴 · 怪兽 / 跑团接力 ─────────────────────────────

class CodexMonster {
  const CodexMonster({required this.key, required this.name, this.strikes = 0, this.defeats = 0, this.bestRank, this.seen = false});
  final String key, name;
  final int strikes, defeats;
  final int? bestRank;
  final bool seen;
  factory CodexMonster.fromJson(Json j) => CodexMonster(
        key: _s(j['key']),
        name: _s(j['name'], monsterNames[_s(j['key'])] ?? ''),
        strikes: _i(j['strikes']),
        defeats: _i(j['defeats']),
        bestRank: _in(j['best_rank']),
        seen: _b(j['seen']),
      );
}

class RelayRun {
  const RelayRun({required this.leg, this.user, this.activityId, this.distanceM = 0, this.at});
  final int leg;
  final UserRef? user;
  final int? activityId;
  final double distanceM;
  final DateTime? at;
  factory RelayRun.fromJson(Json j) => RelayRun(
      leg: _i(j['leg']), user: _user(j['user']), activityId: _in(j['activity_id']), distanceM: _d(j['distance_m']), at: _dt(j['at']));
}

/// `GET /v1/crews/{id}/relays/current`.
class Relay {
  const Relay({required this.id, this.legs = 6, this.legKm = 3, this.status = 'running', this.startedAt, this.expiresAt, this.runs = const []});
  final int id, legs;
  final double legKm;

  /// `running | completed | expired`.
  final String status;
  final DateTime? startedAt, expiresAt;
  final List<RelayRun> runs;
  bool get isRunning => status == 'running';
  RelayRun? leg(int n) => runs.where((r) => r.leg == n).firstOrNull;

  factory Relay.fromJson(Json j) => Relay(
        id: _i(j['id']),
        legs: _i(j['legs'], 6),
        legKm: _d(j['leg_km'], 3),
        status: _s(j['status'], 'running'),
        startedAt: _dt(j['started_at']),
        expiresAt: _dt(j['expires_at']),
        runs: _l(j['runs'], RelayRun.fromJson),
      );
}

// ───────────────────────────── 结算新增 ─────────────────────────────

class BossDamageRecord {
  const BossDamageRecord({required this.bossId, required this.name, required this.damage, this.defeated = false});
  final int bossId;
  final String name;
  final int damage;
  final bool defeated;
  factory BossDamageRecord.fromJson(Json j) =>
      BossDamageRecord(bossId: _i(j['boss_id']), name: _s(j['name']), damage: _i(j['damage']), defeated: _b(j['defeated']));
}

class ChestRecord {
  const ChestRecord({required this.chestId, required this.energy});
  final int chestId, energy;
  factory ChestRecord.fromJson(Json j) => ChestRecord(chestId: _i(j['chest_id']), energy: _i(j['energy']));
}

class DefendedRecord {
  const DefendedRecord({required this.territoryId, required this.guardBefore, required this.guardAfter});
  final int territoryId, guardBefore, guardAfter;
  factory DefendedRecord.fromJson(Json j) =>
      DefendedRecord(territoryId: _i(j['territory_id']), guardBefore: _i(j['guard_before']), guardAfter: _i(j['guard_after']));
}

class RouteRecord {
  const RouteRecord({required this.routeId, required this.name, this.reached = const [], this.completed = false});
  final int routeId;
  final String name;
  final List<String> reached;
  final bool completed;
  factory RouteRecord.fromJson(Json j) =>
      RouteRecord(routeId: _i(j['route_id']), name: _s(j['name']), reached: _strs(j['reached']), completed: _b(j['completed']));
}

class CampaignRecord {
  const CampaignRecord({required this.campaignId, required this.title, this.rewardEnergy = 0});
  final int campaignId;
  final String title;
  final int rewardEnergy;
  factory CampaignRecord.fromJson(Json j) =>
      CampaignRecord(campaignId: _i(j['campaign_id']), title: _s(j['title']), rewardEnergy: _i(j['reward_energy']));
}

class CompanionRecord {
  const CompanionRecord({required this.key, required this.exp, required this.level, this.levelUp = false});
  final String key;
  final int exp, level;
  final bool levelUp;
  static CompanionRecord? parse(Object? v) {
    if (v is! Map) return null;
    final j = v.cast<String, dynamic>();
    return CompanionRecord(key: _s(j['key']), exp: _i(j['exp']), level: _i(j['level'], 1), levelUp: _b(j['level_up']));
  }
}

class RelayRecord {
  const RelayRecord({required this.relayId, required this.leg, required this.legs, this.completed = false});
  final int relayId, leg, legs;
  final bool completed;
  static RelayRecord? parse(Object? v) {
    if (v is! Map) return null;
    final j = v.cast<String, dynamic>();
    return RelayRecord(relayId: _i(j['relay_id']), leg: _i(j['leg']), legs: _i(j['legs']), completed: _b(j['completed']));
  }
}

// ───────────────────────────── 实时推送 ─────────────────────────────

/// One server → client WebSocket message.
sealed class RealtimeEvent {
  const RealtimeEvent();

  /// Unknown types are returned as [UnknownEvent]; non-objects as null.
  static RealtimeEvent? parse(Object? v) {
    if (v is! Map) return null;
    final j = v.cast<String, dynamic>();
    return switch (_s(j['type'])) {
      'boss' => BossHpEvent.fromJson(j),
      'territory_attacked' => TerritoryAttackedEvent(
          territoryId: _i(j['territory_id']), captured: _b(j['captured']), guardAfter: _i(j['guard_after'])),
      'rally' => RallyEvent(bossId: _i(j['boss_id']), by: _user(j['by'])),
      'ping' => const PingEvent(),
      _ => UnknownEvent(j),
    };
  }
}

class BossHpEvent extends RealtimeEvent {
  const BossHpEvent({required this.bossId, required this.hp, required this.status, this.by, this.damage = 0});
  final int bossId, hp;
  final String status;
  final UserRef? by;
  final int damage;
  factory BossHpEvent.fromJson(Json j) {
    final b = _m(j['boss']);
    return BossHpEvent(bossId: _i(b['id']), hp: _i(b['hp']), status: _s(b['status'], 'active'), by: _user(j['by']), damage: _i(j['damage']));
  }
}

class TerritoryAttackedEvent extends RealtimeEvent {
  const TerritoryAttackedEvent({required this.territoryId, required this.captured, required this.guardAfter});
  final int territoryId;
  final bool captured;
  final int guardAfter;
}

class RallyEvent extends RealtimeEvent {
  const RallyEvent({required this.bossId, this.by});
  final int bossId;
  final UserRef? by;
}

class PingEvent extends RealtimeEvent {
  const PingEvent();
}

class UnknownEvent extends RealtimeEvent {
  const UnknownEvent(this.raw);
  final Json raw;
}
