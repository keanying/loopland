// API models for docs/api/v1.md (App sections). Hand-written so the parsing
// is tolerant: unknown fields are ignored, missing optional fields default.
import '../claim/geo.dart';

typedef Json = Map<String, dynamic>;

double _d(Object? v, [double def = 0]) => v is num ? v.toDouble() : def;
double? _dn(Object? v) => v is num ? v.toDouble() : null;
int _i(Object? v, [int def = 0]) => v is num ? v.toInt() : def;
int? _in(Object? v) => v is num ? v.toInt() : null;
String _s(Object? v, [String def = '']) => v is String ? v : (v?.toString() ?? def);
String? _sn(Object? v) => v is String ? v : null;
bool _b(Object? v, [bool def = false]) => v is bool ? v : def;
DateTime? _dt(Object? v) => v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;
Json _m(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
Json? _mn(Object? v) => v is Map ? v.cast<String, dynamic>() : null;
List<T> _l<T>(Object? v, T Function(Json) f) =>
    v is List ? [for (final e in v) if (e is Map) f(e.cast<String, dynamic>())] : <T>[];

/// `{"items":[...],"total":n}`.
class Paged<T> {
  const Paged(this.items, this.total);
  final List<T> items;
  final int total;

  factory Paged.fromJson(Json j, T Function(Json) f) {
    final items = _l(j['items'], f);
    return Paged(items, _i(j['total'], items.length));
  }
}

// ───────────────────────────── 账号 ─────────────────────────────

class UserRef {
  const UserRef({required this.id, required this.nickname, this.avatarUrl});
  final int id;
  final String nickname;
  final String? avatarUrl;

  factory UserRef.fromJson(Json j) => UserRef(
      id: _i(j['id']), nickname: _s(j['nickname']), avatarUrl: _sn(j['avatar_url']));
}

class Consents {
  const Consents({this.privacyVersion, this.location = false, this.health = false});
  final String? privacyVersion;
  final bool location;
  final bool health;

  bool get privacyAccepted => (privacyVersion ?? '').isNotEmpty;

  factory Consents.fromJson(Json j) => Consents(
      privacyVersion: _sn(j['privacy_version']),
      location: _b(j['location']),
      health: _b(j['health']));
}

class UserSettings {
  const UserSettings({
    this.trackVisibility = 'public',
    this.hideEndpoints = true,
    this.showAvatarOnMap = true,
    this.personalized = true,
  });
  final String trackVisibility;
  final bool hideEndpoints;
  final bool showAvatarOnMap;
  final bool personalized;

  factory UserSettings.fromJson(Json j) => UserSettings(
        trackVisibility: _s(j['track_visibility'], 'public'),
        hideEndpoints: _b(j['hide_endpoints'], true),
        showAvatarOnMap: _b(j['show_avatar_on_map'], true),
        personalized: _b(j['personalized'], true),
      );

  Json toJson() => {
        'track_visibility': trackVisibility,
        'hide_endpoints': hideEndpoints,
        'show_avatar_on_map': showAvatarOnMap,
        'personalized': personalized,
      };
}

class CrewRef {
  const CrewRef({required this.id, required this.name});
  final int id;
  final String name;
  factory CrewRef.fromJson(Json j) => CrewRef(id: _i(j['id']), name: _s(j['name']));
}

class Membership {
  const Membership({
    this.active = false,
    this.planCode,
    this.planName,
    this.expiresAt,
    this.autoRenew = false,
    this.nextChargeAt,
    this.channel,
  });
  final bool active;
  final String? planCode;
  final String? planName;
  final DateTime? expiresAt;
  final bool autoRenew;
  final DateTime? nextChargeAt;
  final String? channel;

  bool get isApple => channel == 'apple_iap';

  factory Membership.fromJson(Json j) => Membership(
        active: _b(j['active']),
        planCode: _sn(j['plan_code']),
        planName: _sn(j['plan_name']),
        expiresAt: _dt(j['expires_at']),
        autoRenew: _b(j['auto_renew']),
        nextChargeAt: _dt(j['next_charge_at']),
        channel: _sn(j['channel']),
      );
}

class WeekStats {
  const WeekStats({this.count = 0, this.distanceM = 0, this.durationS = 0, this.energy = 0});
  final int count;
  final double distanceM;
  final int durationS;
  final int energy;
  factory WeekStats.fromJson(Json j) => WeekStats(
      count: _i(j['count']),
      distanceM: _d(j['distance_m']),
      durationS: _i(j['duration_s']),
      energy: _i(j['energy']));
}

class UserStats {
  const UserStats({
    this.totalDistanceM = 0,
    this.activityCount = 0,
    this.territoryCount = 0,
    this.territoryAreaM2 = 0,
    this.week = const WeekStats(),
  });
  final double totalDistanceM;
  final int activityCount;
  final int territoryCount;
  final double territoryAreaM2;
  final WeekStats week;

  factory UserStats.fromJson(Json j) => UserStats(
        totalDistanceM: _d(j['total_distance_m']),
        activityCount: _i(j['activity_count']),
        territoryCount: _i(j['territory_count']),
        territoryAreaM2: _d(j['territory_area_m2']),
        week: WeekStats.fromJson(_m(j['week'])),
      );
}

class User {
  const User({
    required this.id,
    required this.nickname,
    this.avatarUrl,
    this.level = 1,
    this.energy = 0,
    this.energyToday = 0,
    this.dailyEnergyCap = 600,
    this.phoneMasked,
    this.realnameVerified = false,
    this.isAdult,
    this.status = 'active',
    this.mutedUntil,
    this.deleteAfter,
    this.consents = const Consents(),
    this.settings = const UserSettings(),
    this.crew,
    this.membership,
    this.stats = const UserStats(),
    this.createdAt,
  });

  final int id;
  final String nickname;
  final String? avatarUrl;
  final int level;
  final int energy;
  final int energyToday;
  final int dailyEnergyCap;
  final String? phoneMasked;
  final bool realnameVerified;

  /// null = unknown (not verified yet), false = minor.
  final bool? isAdult;
  final String status;
  final DateTime? mutedUntil;
  final DateTime? deleteAfter;
  final Consents consents;
  final UserSettings settings;
  final CrewRef? crew;
  final Membership? membership;
  final UserStats stats;
  final DateTime? createdAt;

  /// 未成年时不展示任何付费入口。
  bool get isMinor => isAdult == false;
  bool get isDeleting => status == 'deleting';

  factory User.fromJson(Json j) => User(
        id: _i(j['id']),
        nickname: _s(j['nickname']),
        avatarUrl: _sn(j['avatar_url']),
        level: _i(j['level'], 1),
        energy: _i(j['energy']),
        energyToday: _i(j['energy_today']),
        dailyEnergyCap: _i(j['daily_energy_cap'], 600),
        phoneMasked: _sn(j['phone_masked']),
        realnameVerified: _b(j['realname_verified']),
        isAdult: j['is_adult'] is bool ? j['is_adult'] as bool : null,
        status: _s(j['status'], 'active'),
        mutedUntil: _dt(j['muted_until']),
        deleteAfter: _dt(j['delete_after']),
        consents: Consents.fromJson(_m(j['consents'])),
        settings: UserSettings.fromJson(_m(j['settings'])),
        crew: _mn(j['crew']) == null ? null : CrewRef.fromJson(_m(j['crew'])),
        membership:
            _mn(j['membership']) == null ? null : Membership.fromJson(_m(j['membership'])),
        stats: UserStats.fromJson(_m(j['stats'])),
        createdAt: _dt(j['created_at']),
      );
}

class AuthResult {
  const AuthResult({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.isNew,
    required this.needBindPhone,
    required this.user,
  });
  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final bool isNew;
  final bool needBindPhone;
  final User user;

  factory AuthResult.fromJson(Json j) => AuthResult(
        accessToken: _s(j['access_token']),
        refreshToken: _s(j['refresh_token']),
        expiresIn: _i(j['expires_in'], 7200),
        isNew: _b(j['is_new']),
        needBindPhone: _b(j['need_bind_phone']),
        user: User.fromJson(_m(j['user'])),
      );
}

// ───────────────────────────── 玩法配置 ─────────────────────────────

class EnergyRule {
  const EnergyRule({required this.sport, required this.name, required this.unit, required this.per, required this.energy});
  final String sport;
  final String name;
  final String unit;
  final double per;
  final int energy;

  factory EnergyRule.fromJson(Json j) => EnergyRule(
      sport: _s(j['sport']),
      name: _s(j['name']),
      unit: _s(j['unit']),
      per: _d(j['per'], 1),
      energy: _i(j['energy']));

  /// "10 能量 / km", "5 能量 / 10 分钟".
  String get text {
    final p = per == 1 ? '' : '${per % 1 == 0 ? per.toInt() : per} ';
    final u = switch (unit) { 'min' => '分钟', 'count' => '次', 'checkin' => '次', _ => unit };
    return '$energy 能量 / $p$u';
  }
}

class BuildingDef {
  const BuildingDef({
    required this.key,
    required this.name,
    this.note = '',
    required this.cost,
    required this.guard,
    required this.dailyEnergy,
    required this.unlockLevel,
    this.stationSlots = 0,
  });
  final String key;
  final String name;
  final String note;
  final int cost;
  final int guard;
  final int dailyEnergy;
  final int unlockLevel;
  final int stationSlots;

  factory BuildingDef.fromJson(Json j) => BuildingDef(
        key: _s(j['key']),
        name: _s(j['name']),
        note: _s(j['note']),
        cost: _i(j['cost']),
        guard: _i(j['guard']),
        dailyEnergy: _i(j['daily_energy']),
        unlockLevel: _i(j['unlock_level'], 1),
        stationSlots: _i(j['station_slots']),
      );
}

class RoleDef {
  const RoleDef({
    required this.key,
    required this.name,
    required this.sport,
    required this.threshold,
    required this.unit,
    this.buff = '',
    this.buffValue = 0,
    this.buffText = '',
  });
  final String key;
  final String name;
  final String sport;
  final double threshold;
  final String unit;
  final String buff;
  final double buffValue;
  final String buffText;

  factory RoleDef.fromJson(Json j) => RoleDef(
        key: _s(j['key']),
        name: _s(j['name']),
        sport: _s(j['sport']),
        threshold: _d(j['threshold']),
        unit: _s(j['unit']),
        buff: _s(j['buff']),
        buffValue: _d(j['buff_value']),
        buffText: _s(j['buff_text']),
      );
}

class CompanionDef {
  const CompanionDef({required this.key, required this.name, required this.hatchKm});
  final String key;
  final String name;
  final double hatchKm;
  factory CompanionDef.fromJson(Json j) =>
      CompanionDef(key: _s(j['key']), name: _s(j['name']), hatchKm: _d(j['hatch_km']));
}

class MedalDef {
  const MedalDef({required this.key, required this.name, this.distanceKm});
  final String key;
  final String name;
  final double? distanceKm;
  factory MedalDef.fromJson(Json j) =>
      MedalDef(key: _s(j['key']), name: _s(j['name']), distanceKm: _dn(j['distance_km']));
}

class GameConfig {
  const GameConfig({
    this.version = '',
    this.slotsPerTerritory = 6,
    this.baseStationSlots = 1,
    this.dailyEnergyCap = 600,
    this.minClaimAreaM2 = 500,
    this.levelThresholds = const [0, 200, 600, 1200, 2000, 3200],
    this.energy = const [],
    this.buildings = const [],
    this.roles = const [],
    this.companions = const [],
    this.medals = const [],
  });
  final String version;
  final int slotsPerTerritory;
  final int baseStationSlots;
  final int dailyEnergyCap;
  final double minClaimAreaM2;
  final List<int> levelThresholds;
  final List<EnergyRule> energy;
  final List<BuildingDef> buildings;
  final List<RoleDef> roles;
  final List<CompanionDef> companions;
  final List<MedalDef> medals;

  factory GameConfig.fromJson(Json j) => GameConfig(
        version: _s(j['version']),
        slotsPerTerritory: _i(j['slots_per_territory'], 6),
        baseStationSlots: _i(j['base_station_slots'], 1),
        dailyEnergyCap: _i(j['daily_energy_cap'], 600),
        minClaimAreaM2: _d(j['min_claim_area_m2'], 500),
        levelThresholds: j['level_thresholds'] is List
            ? [for (final v in j['level_thresholds'] as List) _i(v)]
            : const [0, 200, 600, 1200, 2000, 3200],
        energy: _l(j['energy'], EnergyRule.fromJson),
        buildings: _l(j['buildings'], BuildingDef.fromJson),
        roles: _l(j['roles'], RoleDef.fromJson),
        companions: _l(j['companions'], CompanionDef.fromJson),
        medals: _l(j['medals'], MedalDef.fromJson),
      );

  EnergyRule? energyFor(String sport) {
    for (final e in energy) {
      if (e.sport == sport) return e;
    }
    return null;
  }

  BuildingDef? building(String? key) {
    for (final b in buildings) {
      if (b.key == key) return b;
    }
    return null;
  }

  RoleDef? role(String key) {
    for (final r in roles) {
      if (r.key == key) return r;
    }
    return null;
  }

  /// Roles recruited by a sport ("招募哪个角色").
  List<RoleDef> rolesFor(String sport) => [for (final r in roles) if (r.sport == sport) r];
}

// ───────────────────────────── 运动 ─────────────────────────────

class TrackPoint {
  const TrackPoint({
    required this.t,
    required this.lat,
    required this.lng,
    this.acc,
    this.spd,
    this.hr,
    this.cad,
    this.src = 'gps',
  });

  /// Milliseconds since epoch.
  final int t;
  final double lat;
  final double lng;
  final double? acc;
  final double? spd;
  final int? hr;
  final int? cad;

  /// `gps | network | mock`.
  final String src;

  LatLng get latLng => LatLng(lat, lng);

  factory TrackPoint.fromJson(Json j) => TrackPoint(
        t: _i(j['t']),
        lat: _d(j['lat']),
        lng: _d(j['lng']),
        acc: _dn(j['acc']),
        spd: _dn(j['spd']),
        hr: _in(j['hr']),
        cad: _in(j['cad']),
        src: _s(j['src'], 'gps'),
      );

  Json toJson() => {
        't': t,
        'lat': lat,
        'lng': lng,
        if (acc != null) 'acc': acc,
        if (spd != null) 'spd': spd,
        if (hr != null) 'hr': hr,
        if (cad != null) 'cad': cad,
        'src': src,
      };
}

class Goal {
  const Goal({this.type = 'free', this.value, this.territoryId});

  /// `free | distance | time | target`. distance in m, time in s.
  final String type;
  final num? value;
  final int? territoryId;

  factory Goal.fromJson(Json j) =>
      Goal(type: _s(j['type'], 'free'), value: j['value'] as num?, territoryId: _in(j['territory_id']));

  Json toJson() => {
        'type': type,
        if (value != null) 'value': value,
        if (territoryId != null) 'territory_id': territoryId,
      };
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    this.model = '',
    this.os = '',
    this.rooted = false,
    this.emulator = false,
    this.multiOpen = false,
  });
  final String id;
  final String model;
  final String os;
  final bool rooted;
  final bool emulator;
  final bool multiOpen;

  factory DeviceInfo.fromJson(Json j) => DeviceInfo(
        id: _s(j['id']),
        model: _s(j['model']),
        os: _s(j['os']),
        rooted: _b(j['rooted']),
        emulator: _b(j['emulator']),
        multiOpen: _b(j['multi_open']),
      );

  Json toJson() => {
        'id': id,
        'model': model,
        'os': os,
        'rooted': rooted,
        'emulator': emulator,
        'multi_open': multiOpen,
      };
}

/// Body of `POST /v1/activities`. Also what is persisted for offline retry.
class ActivityUpload {
  const ActivityUpload({
    required this.clientId,
    required this.sport,
    required this.startedAt,
    required this.endedAt,
    required this.durationS,
    this.goal = const Goal(),
    this.points = const [],
    this.amount,
    required this.device,
    this.wearableBrand,
  });
  final String clientId;
  final String sport;
  final DateTime startedAt;
  final DateTime endedAt;
  final int durationS;
  final Goal goal;
  final List<TrackPoint> points;
  final num? amount;
  final DeviceInfo device;
  final String? wearableBrand;

  bool get isGps => points.isNotEmpty;

  factory ActivityUpload.fromJson(Json j) => ActivityUpload(
        clientId: _s(j['client_id']),
        sport: _s(j['sport']),
        startedAt: _dt(j['started_at']) ?? DateTime.now(),
        endedAt: _dt(j['ended_at']) ?? DateTime.now(),
        durationS: _i(j['duration_s']),
        goal: Goal.fromJson(_m(j['goal'])),
        points: _l(j['points'], TrackPoint.fromJson),
        amount: j['amount'] as num?,
        device: DeviceInfo.fromJson(_m(j['device'])),
        wearableBrand: _sn(_m(j['wearable'])['brand']),
      );

  Json toJson() => {
        'client_id': clientId,
        'sport': sport,
        'started_at': startedAt.toUtc().toIso8601String(),
        'ended_at': endedAt.toUtc().toIso8601String(),
        'duration_s': durationS,
        'goal': goal.toJson(),
        if (points.isNotEmpty) 'points': [for (final p in points) p.toJson()],
        if (amount != null) 'amount': amount,
        'device': device.toJson(),
        if (wearableBrand != null) 'wearable': {'brand': wearableBrand},
      };
}

class ClaimRecord {
  const ClaimRecord({required this.territoryId, required this.kind, required this.areaM2});
  final int territoryId;

  /// `claim | capture`.
  final String kind;
  final double areaM2;
  factory ClaimRecord.fromJson(Json j) => ClaimRecord(
      territoryId: _i(j['territory_id']), kind: _s(j['kind'], 'claim'), areaM2: _d(j['area_m2']));
}

class AttackRecord {
  const AttackRecord({
    required this.territoryId,
    this.owner,
    required this.captured,
    required this.guardBefore,
    required this.guardAfter,
    required this.areaM2,
  });
  final int territoryId;
  final UserRef? owner;
  final bool captured;
  final int guardBefore;
  final int guardAfter;
  final double areaM2;
  factory AttackRecord.fromJson(Json j) => AttackRecord(
        territoryId: _i(j['territory_id']),
        owner: _mn(j['owner']) == null ? null : UserRef.fromJson(_m(j['owner'])),
        captured: _b(j['captured']),
        guardBefore: _i(j['guard_before']),
        guardAfter: _i(j['guard_after']),
        areaM2: _d(j['area_m2']),
      );
}

class RecruitProgress {
  const RecruitProgress({
    required this.role,
    required this.name,
    required this.progress,
    required this.threshold,
    required this.unit,
    required this.recruited,
  });
  final String role;
  final String name;
  final double progress;
  final double threshold;
  final String unit;
  final bool recruited;
  factory RecruitProgress.fromJson(Json j) => RecruitProgress(
        role: _s(j['role']),
        name: _s(j['name']),
        progress: _d(j['progress']),
        threshold: _d(j['threshold'], 1),
        unit: _s(j['unit']),
        recruited: _b(j['recruited']),
      );
}

class EggProgress {
  const EggProgress({
    required this.key,
    required this.name,
    required this.progressKm,
    required this.hatchKm,
    required this.hatched,
  });
  final String key;
  final String name;
  final double progressKm;
  final double hatchKm;
  final bool hatched;
  factory EggProgress.fromJson(Json j) => EggProgress(
        key: _s(j['key']),
        name: _s(j['name']),
        progressKm: _d(j['progress_km']),
        hatchKm: _d(j['hatch_km'], 1),
        hatched: _b(j['hatched']),
      );
}

class MedalRef {
  const MedalRef({required this.key, required this.name});
  final String key;
  final String name;
  factory MedalRef.fromJson(Json j) => MedalRef(key: _s(j['key']), name: _s(j['name']));
}

class RiskFlag {
  const RiskFlag({required this.rule, required this.detail});
  final String rule;
  final String detail;
  factory RiskFlag.fromJson(Json j) => RiskFlag(rule: _s(j['rule']), detail: _s(j['detail']));
}

/// `level_up` is only shown as `null` in the contract. Assumed shape:
/// `{"from":2,"to":3}` or a bare new level number; both are accepted.
class LevelUp {
  const LevelUp({this.from, required this.to});
  final int? from;
  final int to;

  static LevelUp? parse(Object? v) {
    if (v is num) return LevelUp(to: v.toInt());
    if (v is Map) {
      final m = v.cast<String, dynamic>();
      final to = _in(m['to']) ?? _in(m['level']);
      if (to == null) return null;
      return LevelUp(from: _in(m['from']), to: to);
    }
    return null;
  }
}

class Settlement {
  const Settlement({
    required this.status,
    this.energyRaw = 0,
    this.energyGranted = 0,
    this.energyCapped = false,
    this.claims = const [],
    this.attacks = const [],
    this.recruits = const [],
    this.eggs = const [],
    this.medals = const [],
    this.levelUp,
    this.flags = const [],
  });

  /// `settled | review | voided`.
  final String status;
  final int energyRaw;
  final int energyGranted;
  final bool energyCapped;
  final List<ClaimRecord> claims;
  final List<AttackRecord> attacks;
  final List<RecruitProgress> recruits;
  final List<EggProgress> eggs;
  final List<MedalRef> medals;
  final LevelUp? levelUp;
  final List<RiskFlag> flags;

  double get claimedAreaM2 => claims.fold(0.0, (s, c) => s + c.areaM2);

  factory Settlement.fromJson(Json j) => Settlement(
        status: _s(j['status'], 'settled'),
        energyRaw: _i(j['energy_raw']),
        energyGranted: _i(j['energy_granted']),
        energyCapped: _b(j['energy_capped']),
        claims: _l(j['claims'], ClaimRecord.fromJson),
        attacks: _l(j['attacks'], AttackRecord.fromJson),
        recruits: _l(j['recruits'], RecruitProgress.fromJson),
        eggs: _l(j['eggs'], EggProgress.fromJson),
        medals: _l(j['medals'], MedalRef.fromJson),
        levelUp: LevelUp.parse(j['level_up']),
        flags: _l(j['flags'], RiskFlag.fromJson),
      );
}

/// GeoJSON LineString in [lng, lat].
List<LatLng> parseLineString(Object? geo) {
  final g = _m(geo);
  final c = g['coordinates'];
  if (c is! List) return const [];
  return [for (final p in c) if (p is List && p.length >= 2) LatLng.fromGeoJson(p)];
}

/// GeoJSON Polygon / MultiPolygon → list of polygons, each a list of rings.
List<List<List<LatLng>>> parsePolygons(Object? geo) {
  final g = _m(geo);
  final c = g['coordinates'];
  if (c is! List) return const [];
  List<List<LatLng>> poly(List rings) => [
        for (final r in rings)
          if (r is List) [for (final p in r) if (p is List && p.length >= 2) LatLng.fromGeoJson(p)]
      ];
  if (g['type'] == 'Polygon') return [poly(c)];
  return [for (final p in c) if (p is List) poly(p)];
}

class Activity {
  const Activity({
    required this.id,
    required this.sport,
    required this.status,
    this.startedAt,
    this.endedAt,
    this.distanceM = 0,
    this.durationS = 0,
    this.avgPaceSPerKm,
    this.amount,
    this.energyGranted = 0,
    this.claimedAreaM2 = 0,
    this.track = const [],
    this.claims = const [],
  });
  final int id;
  final String sport;
  final String status;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final double distanceM;
  final int durationS;
  final double? avgPaceSPerKm;
  final double? amount;
  final int energyGranted;
  final double claimedAreaM2;
  final List<LatLng> track;
  final List<ClaimRecord> claims;

  factory Activity.fromJson(Json j) => Activity(
        id: _i(j['id']),
        sport: _s(j['sport']),
        status: _s(j['status'], 'settled'),
        startedAt: _dt(j['started_at']),
        endedAt: _dt(j['ended_at']),
        distanceM: _d(j['distance_m']),
        durationS: _i(j['duration_s']),
        avgPaceSPerKm: _dn(j['avg_pace_s_per_km']),
        amount: _dn(j['amount']),
        energyGranted: _i(j['energy_granted']),
        claimedAreaM2: _d(j['claimed_area_m2']),
        track: parseLineString(j['track']),
        claims: _l(j['claims'], ClaimRecord.fromJson),
      );
}

class ActivityResult {
  const ActivityResult({required this.activity, required this.settlement});
  final Activity activity;
  final Settlement settlement;
  factory ActivityResult.fromJson(Json j) => ActivityResult(
      activity: Activity.fromJson(_m(j['activity'])),
      settlement: Settlement.fromJson(_m(j['settlement'])));
}

class PreviewLoop {
  const PreviewLoop({required this.ring, required this.areaM2, required this.perimeterM, required this.closedAt});
  final List<LatLng> ring;
  final double areaM2;
  final double perimeterM;
  final int closedAt;
  factory PreviewLoop.fromJson(Json j) => PreviewLoop(
        ring: _l(j['ring'], LatLng.fromJson),
        areaM2: _d(j['area_m2']),
        perimeterM: _d(j['perimeter_m']),
        closedAt: _i(j['closed_at']),
      );
}

/// `POST /v1/claims/preview` response.
class ClaimPreview {
  const ClaimPreview({
    this.loops = const [],
    this.totalAreaM2 = 0,
    this.discarded = 0,
    this.hintDistanceM,
    this.hintTarget,
    this.distanceKm = 0,
    this.rawEnergy = 0,
  });
  final List<PreviewLoop> loops;
  final double totalAreaM2;
  final int discarded;
  final double? hintDistanceM;
  final LatLng? hintTarget;
  final double distanceKm;
  final int rawEnergy;

  factory ClaimPreview.fromJson(Json j) {
    final hint = _mn(j['hint']);
    final target = hint == null ? null : _mn(hint['target']);
    return ClaimPreview(
      loops: _l(j['loops'], PreviewLoop.fromJson),
      totalAreaM2: _d(j['total_area_m2']),
      discarded: _i(j['discarded']),
      hintDistanceM: hint == null ? null : _dn(hint['distance_m']),
      hintTarget: target == null ? null : LatLng.fromJson(target),
      distanceKm: _d(j['distance_km']),
      rawEnergy: _i(j['raw_energy']),
    );
  }
}

// ───────────────────────────── 领地 ─────────────────────────────

class TerritorySummary {
  const TerritorySummary({
    required this.id,
    required this.name,
    required this.relation,
    this.owner,
    this.crew,
    this.polygons = const [],
    this.center,
    this.areaM2 = 0,
    this.guard = 0,
    this.frozen = false,
  });
  final int id;
  final String name;

  /// `mine | crew | enemy | unowned`.
  final String relation;
  final UserRef? owner;
  final CrewRef? crew;
  final List<List<List<LatLng>>> polygons;
  final LatLng? center;
  final double areaM2;
  final int guard;
  final bool frozen;

  bool get isMine => relation == 'mine';

  static TerritorySummary fromJson(Json j) => TerritorySummary(
        id: _i(j['id']),
        name: _s(j['name']),
        relation: _s(j['relation'], 'unowned'),
        owner: _mn(j['owner']) == null ? null : UserRef.fromJson(_m(j['owner'])),
        crew: _mn(j['crew']) == null ? null : CrewRef.fromJson(_m(j['crew'])),
        polygons: parsePolygons(j['geometry']),
        center: _mn(j['center']) == null ? null : LatLng.fromJson(_m(j['center'])),
        areaM2: _d(j['area_m2']),
        guard: _i(j['guard']),
        frozen: _b(j['frozen']),
      );
}

class Slot {
  const Slot({required this.slot, this.building, this.name});
  final int slot;
  final String? building;
  final String? name;
  bool get empty => building == null;
  factory Slot.fromJson(Json j) =>
      Slot(slot: _i(j['slot']), building: _sn(j['building']), name: _sn(j['name']));
}

class Stationed {
  const Stationed({required this.role, required this.name, this.buffText = ''});
  final String role;
  final String name;
  final String buffText;
  factory Stationed.fromJson(Json j) =>
      Stationed(role: _s(j['role']), name: _s(j['name']), buffText: _s(j['buff_text']));
}

class TerritoryEvent {
  const TerritoryEvent({required this.kind, this.actor, this.createdAt});
  final String kind;
  final UserRef? actor;
  final DateTime? createdAt;
  factory TerritoryEvent.fromJson(Json j) => TerritoryEvent(
        kind: _s(j['kind']),
        actor: _mn(j['actor']) == null ? null : UserRef.fromJson(_m(j['actor'])),
        createdAt: _dt(j['created_at']),
      );
}

class Territory {
  const Territory({
    required this.summary,
    this.dailyEnergy = 0,
    this.slots = const [],
    this.stationSlots = 1,
    this.stationed = const [],
    this.capturedAt,
    this.events = const [],
  });
  final TerritorySummary summary;
  final int dailyEnergy;
  final List<Slot> slots;
  final int stationSlots;
  final List<Stationed> stationed;
  final DateTime? capturedAt;
  final List<TerritoryEvent> events;

  int get id => summary.id;
  int get builtCount => slots.where((s) => !s.empty).length;

  factory Territory.fromJson(Json j) => Territory(
        summary: TerritorySummary.fromJson(j),
        dailyEnergy: _i(j['daily_energy']),
        slots: _l(j['slots'], Slot.fromJson),
        stationSlots: _i(j['station_slots'], 1),
        stationed: _l(j['stationed'], Stationed.fromJson),
        capturedAt: _dt(j['captured_at']),
        events: _l(j['events'], TerritoryEvent.fromJson),
      );
}

class BuildResult {
  const BuildResult({required this.territory, required this.energy});
  final Territory territory;

  /// Remaining energy after building.
  final int energy;
  factory BuildResult.fromJson(Json j) =>
      BuildResult(territory: Territory.fromJson(_m(j['territory'])), energy: _i(j['energy']));
}

// ───────────────────────────── 图鉴 ─────────────────────────────

class CodexRole {
  const CodexRole({
    required this.key,
    required this.name,
    required this.sport,
    required this.threshold,
    required this.unit,
    this.progress = 0,
    this.obtained = false,
    this.obtainedAt,
    this.buffText = '',
    this.stationedAt,
  });
  final String key;
  final String name;
  final String sport;
  final double threshold;
  final String unit;
  final double progress;
  final bool obtained;
  final DateTime? obtainedAt;
  final String buffText;

  /// Territory id where the role is stationed. The contract only shows
  /// `null`; a number (territory id) or `{"id":..}` object are both accepted.
  final int? stationedAt;

  factory CodexRole.fromJson(Json j) => CodexRole(
        key: _s(j['key']),
        name: _s(j['name']),
        sport: _s(j['sport']),
        threshold: _d(j['threshold'], 1),
        unit: _s(j['unit']),
        progress: _d(j['progress']),
        obtained: _b(j['obtained']),
        obtainedAt: _dt(j['obtained_at']),
        buffText: _s(j['buff_text']),
        stationedAt: _in(j['stationed_at']) ?? _in(_m(j['stationed_at'])['id']),
      );
}

class CodexBuilding {
  const CodexBuilding({
    required this.key,
    required this.name,
    required this.unlockLevel,
    required this.unlocked,
    this.cost = 0,
    this.guard = 0,
    this.dailyEnergy = 0,
  });
  final String key;
  final String name;
  final int unlockLevel;
  final bool unlocked;
  final int cost;
  final int guard;
  final int dailyEnergy;
  factory CodexBuilding.fromJson(Json j) => CodexBuilding(
        key: _s(j['key']),
        name: _s(j['name']),
        unlockLevel: _i(j['unlock_level'], 1),
        unlocked: _b(j['unlocked']),
        cost: _i(j['cost']),
        guard: _i(j['guard']),
        dailyEnergy: _i(j['daily_energy']),
      );
}

class CodexCompanion {
  const CodexCompanion({
    required this.key,
    required this.name,
    this.state = 'none',
    this.progressKm = 0,
    this.hatchKm = 10,
    this.escort = false,
  });
  final String key;
  final String name;

  /// `none | egg | hatched`.
  final String state;
  final double progressKm;
  final double hatchKm;
  final bool escort;
  bool get hatched => state == 'hatched';
  bool get isEgg => state == 'egg';
  factory CodexCompanion.fromJson(Json j) => CodexCompanion(
        key: _s(j['key']),
        name: _s(j['name']),
        state: _s(j['state'], 'none'),
        progressKm: _d(j['progress_km']),
        hatchKm: _d(j['hatch_km'], 10),
        escort: _b(j['escort']),
      );
}

class CodexMedal {
  const CodexMedal({required this.key, required this.name, this.obtained = false, this.obtainedAt});
  final String key;
  final String name;
  final bool obtained;
  final DateTime? obtainedAt;
  factory CodexMedal.fromJson(Json j) => CodexMedal(
      key: _s(j['key']), name: _s(j['name']), obtained: _b(j['obtained']), obtainedAt: _dt(j['obtained_at']));
}

class Codex {
  const Codex({
    this.progress = const {},
    this.roles = const [],
    this.buildings = const [],
    this.companions = const [],
    this.medals = const [],
  });

  /// e.g. {"roles": "2/8"}.
  final Map<String, String> progress;
  final List<CodexRole> roles;
  final List<CodexBuilding> buildings;
  final List<CodexCompanion> companions;
  final List<CodexMedal> medals;

  int get obtainedCount =>
      roles.where((r) => r.obtained).length +
      buildings.where((b) => b.unlocked).length +
      companions.where((c) => c.hatched).length +
      medals.where((m) => m.obtained).length;

  int get totalCount => roles.length + buildings.length + companions.length + medals.length;

  factory Codex.fromJson(Json j) => Codex(
        progress: {for (final e in _m(j['progress']).entries) e.key: _s(e.value)},
        roles: _l(j['roles'], CodexRole.fromJson),
        buildings: _l(j['buildings'], CodexBuilding.fromJson),
        companions: _l(j['companions'], CodexCompanion.fromJson),
        medals: _l(j['medals'], CodexMedal.fromJson),
      );
}

// ───────────────────────────── 跑团 ─────────────────────────────

class WeekRankEntry {
  const WeekRankEntry({required this.user, this.distanceM = 0, this.areaM2 = 0});
  final UserRef user;
  final double distanceM;
  final double areaM2;
  factory WeekRankEntry.fromJson(Json j) => WeekRankEntry(
      user: UserRef.fromJson(_m(j['user'])), distanceM: _d(j['distance_m']), areaM2: _d(j['area_m2']));
}

class Crew {
  const Crew({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.district = '',
    this.joinMode = 'open',
    this.leader,
    this.memberCount = 0,
    this.territoryCount = 0,
    this.territoryAreaM2 = 0,
    this.myRole,
    this.weekRank = const [],
  });
  final int id;
  final String name;
  final String? avatarUrl;
  final String district;

  /// `open | apply | invite`.
  final String joinMode;
  final UserRef? leader;
  final int memberCount;
  final int territoryCount;
  final double territoryAreaM2;

  /// `leader | member | applicant | null`.
  final String? myRole;
  final List<WeekRankEntry> weekRank;

  bool get isLeader => myRole == 'leader';
  bool get isMember => myRole == 'leader' || myRole == 'member';

  factory Crew.fromJson(Json j) => Crew(
        id: _i(j['id']),
        name: _s(j['name']),
        avatarUrl: _sn(j['avatar_url']),
        district: _s(j['district']),
        joinMode: _s(j['join_mode'], 'open'),
        leader: _mn(j['leader']) == null ? null : UserRef.fromJson(_m(j['leader'])),
        memberCount: _i(j['member_count']),
        territoryCount: _i(j['territory_count']),
        territoryAreaM2: _d(j['territory_area_m2']),
        myRole: _sn(j['my_role']),
        weekRank: _l(j['week_rank'], WeekRankEntry.fromJson),
      );
}

class CrewMember {
  const CrewMember({required this.user, required this.role, this.joinedAt});
  final UserRef user;
  final String role;
  final DateTime? joinedAt;
  factory CrewMember.fromJson(Json j) => CrewMember(
      user: UserRef.fromJson(_m(j['user'])), role: _s(j['role'], 'member'), joinedAt: _dt(j['joined_at']));
}

class CrewApplication {
  const CrewApplication({required this.user, this.createdAt});
  final UserRef user;
  final DateTime? createdAt;
  factory CrewApplication.fromJson(Json j) =>
      CrewApplication(user: UserRef.fromJson(_m(j['user'])), createdAt: _dt(j['created_at']));
}

// ───────────────────────────── 会员与支付 ─────────────────────────────

class Plan {
  const Plan({
    required this.code,
    required this.name,
    required this.period,
    this.autoRenew = false,
    required this.priceFen,
    this.firstPriceFen,
    this.renewPriceFen,
    this.seats = 1,
    this.recommended = false,
    this.appleProductId,
    this.entitlements = const [],
  });
  final String code;
  final String name;
  final String period;
  final bool autoRenew;
  final int priceFen;
  final int? firstPriceFen;
  final int? renewPriceFen;
  final int seats;
  final bool recommended;
  final String? appleProductId;
  final List<String> entitlements;

  String get periodText => switch (period) {
        'month' => '月',
        'quarter' => '季',
        'year' => '年',
        _ => period,
      };

  factory Plan.fromJson(Json j) => Plan(
        code: _s(j['code']),
        name: _s(j['name']),
        period: _s(j['period'], 'month'),
        autoRenew: _b(j['auto_renew']),
        priceFen: _i(j['price_fen']),
        firstPriceFen: _in(j['first_price_fen']),
        renewPriceFen: _in(j['renew_price_fen']),
        seats: _i(j['seats'], 1),
        recommended: _b(j['recommended']),
        appleProductId: _sn(j['apple_product_id']),
        entitlements: j['entitlements'] is List
            ? [for (final e in j['entitlements'] as List) _s(e)]
            : const [],
      );
}

class PlansResponse {
  const PlansResponse({required this.items, required this.minorBlocked});
  final List<Plan> items;
  final bool minorBlocked;
  factory PlansResponse.fromJson(Json j) =>
      PlansResponse(items: _l(j['items'], Plan.fromJson), minorBlocked: _b(j['minor_blocked']));
}

class Order {
  const Order({
    required this.orderNo,
    required this.planCode,
    this.planName = '',
    required this.amountFen,
    required this.channel,
    this.kind = 'purchase',
    required this.status,
    this.createdAt,
    this.paidAt,
  });
  final String orderNo;
  final String planCode;
  final String planName;
  final int amountFen;
  final String channel;

  /// `purchase | renewal`.
  final String kind;

  /// `created | paid | refund_requested | refunded | closed | renew_failed`.
  final String status;
  final DateTime? createdAt;
  final DateTime? paidAt;

  bool get isPaid => status == 'paid';
  bool get isFinal => status != 'created';

  factory Order.fromJson(Json j) => Order(
        orderNo: _s(j['order_no']),
        planCode: _s(j['plan_code']),
        planName: _s(j['plan_name']),
        amountFen: _i(j['amount_fen']),
        channel: _s(j['channel']),
        kind: _s(j['kind'], 'purchase'),
        status: _s(j['status'], 'created'),
        createdAt: _dt(j['created_at']),
        paidAt: _dt(j['paid_at']),
      );
}

class CreateOrderResult {
  const CreateOrderResult({required this.order, required this.payParams});
  final Order order;
  final Json payParams;
  factory CreateOrderResult.fromJson(Json j) =>
      CreateOrderResult(order: Order.fromJson(_m(j['order'])), payParams: _m(j['pay_params']));
}

// ───────────────────────────── 消息 ─────────────────────────────

class InboxItem {
  const InboxItem({
    required this.id,
    required this.category,
    required this.title,
    this.body = '',
    this.data = const {},
    this.read = false,
    this.createdAt,
  });
  final int id;

  /// `territory | system | interaction`.
  final String category;
  final String title;
  final String body;
  final Json data;
  final bool read;
  final DateTime? createdAt;

  int? get territoryId => _in(data['territory_id']);

  InboxItem copyWith({bool? read}) => InboxItem(
      id: id, category: category, title: title, body: body, data: data, read: read ?? this.read, createdAt: createdAt);

  factory InboxItem.fromJson(Json j) => InboxItem(
        id: _i(j['id']),
        category: _s(j['category'], 'system'),
        title: _s(j['title']),
        body: _s(j['body']),
        data: _m(j['data']),
        read: _b(j['read']),
        createdAt: _dt(j['created_at']),
      );
}

class InboxPage {
  const InboxPage({required this.items, required this.total, required this.unread});
  final List<InboxItem> items;
  final int total;
  final int unread;
  factory InboxPage.fromJson(Json j) {
    final items = _l(j['items'], InboxItem.fromJson);
    return InboxPage(items: items, total: _i(j['total'], items.length), unread: _i(j['unread']));
  }
}
