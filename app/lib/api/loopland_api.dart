import 'package:dio/dio.dart';

import '../claim/geo.dart';
import 'api_client.dart';
import 'models.dart';

/// Typed endpoints from docs/api/v1.md (App).
class LooplandApi {
  LooplandApi(this.c);
  final ApiClient c;

  static Json _j(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

  // ── 账号 ──
  Future<int> sendSms(String phone, {String? captchaToken}) async {
    final r = _j(await c.post('/v1/auth/sms/send', {
      'phone': phone,
      'captcha_token': ?captchaToken,
    }));
    return (r['cooldown_s'] as num?)?.toInt() ?? 60;
  }

  /// provider: `sms | oneclick | wechat | apple`.
  Future<AuthResult> login(String provider, Json credential) async {
    final deviceId = await c.tokens.deviceId();
    final r = AuthResult.fromJson(_j(await c.post('/v1/auth/login', {
      'provider': provider,
      'credential': credential,
      'device_id': deviceId,
      'platform': c.platform,
    })));
    await c.tokens.save(r.accessToken, r.refreshToken);
    return r;
  }

  Future<void> logout() async {
    final rt = await c.tokens.refreshToken;
    try {
      if (rt != null) await c.post('/v1/auth/logout', {'refresh_token': rt});
    } finally {
      await c.tokens.clear();
    }
  }

  Future<User> me() async => User.fromJson(_j(await c.get('/v1/me')));

  Future<User> updateMe({String? nickname, String? avatarUrl, Json? settings}) async =>
      User.fromJson(_j(await c.patch('/v1/me', {
        'nickname': ?nickname,
        'avatar_url': ?avatarUrl,
        'settings': ?settings,
      })));

  Future<User> bindPhone({String? phone, String? code, String? oneclickToken}) async =>
      User.fromJson(_j(await c.post('/v1/me/phone', {
        if (oneclickToken != null) 'oneclick_token': oneclickToken else ...{'phone': phone, 'code': code},
      })));

  Future<User> setConsents({required String privacyVersion, required bool location, required bool health}) async =>
      User.fromJson(_j(await c.post('/v1/me/consents', {
        'privacy_version': privacyVersion,
        'location': location,
        'health': health,
      })));

  Future<User> realname(String name, String idNumber) async =>
      User.fromJson(_j(await c.post('/v1/me/realname', {'name': name, 'id_number': idNumber})));

  Future<DateTime?> requestDeletion() async {
    final r = _j(await c.post('/v1/me/deletion'));
    return DateTime.tryParse('${r['delete_after']}');
  }

  Future<User> cancelDeletion() async => User.fromJson(_j(await c.delete('/v1/me/deletion')));

  /// Raw JSON text of the export file.
  Future<String> exportData() async {
    final r = await c.request('GET', '/v1/me/export', responseType: ResponseType.plain);
    return r is String ? r : '$r';
  }

  // ── 玩法配置 ──
  Future<GameConfig> gameplay() async => GameConfig.fromJson(_j(await c.get('/v1/config/gameplay')));

  // ── 运动 ──
  Future<ActivityResult> uploadActivity(ActivityUpload a) async =>
      ActivityResult.fromJson(_j(await c.post('/v1/activities', a.toJson())));

  Future<Paged<Activity>> activities({int page = 1, int pageSize = 20}) async => Paged.fromJson(
      _j(await c.get('/v1/activities', query: {'page': page, 'page_size': pageSize})), Activity.fromJson);

  Future<Activity> activity(int id) async => Activity.fromJson(_j(await c.get('/v1/activities/$id')));

  Future<ClaimPreview> previewClaims(String sport, List<LatLng> points) async =>
      ClaimPreview.fromJson(_j(await c.post('/v1/claims/preview', {
        'sport': sport,
        'points': [for (final p in points) p.toJson()],
      })));

  // ── 领地 ──
  /// bbox = minLng,minLat,maxLng,maxLat; scope = all | mine | crew.
  Future<List<TerritorySummary>> territories(
      {required double minLng,
      required double minLat,
      required double maxLng,
      required double maxLat,
      String scope = 'all'}) async {
    final r = _j(await c.get('/v1/territories', query: {
      'bbox': [minLng, minLat, maxLng, maxLat].map((v) => v.toStringAsFixed(6)).join(','),
      'scope': scope,
    }));
    return Paged.fromJson(r, TerritorySummary.fromJson).items;
  }

  Future<Territory> territory(int id) async => Territory.fromJson(_j(await c.get('/v1/territories/$id')));

  Future<BuildResult> build(int territoryId, int slot, String building) async => BuildResult.fromJson(
      _j(await c.post('/v1/territories/$territoryId/buildings', {'slot': slot, 'building': building})));

  Future<Territory> station(int territoryId, String role) async =>
      Territory.fromJson(_j(await c.post('/v1/territories/$territoryId/stationed', {'role': role})));

  Future<Territory> unstation(int territoryId, String role) async =>
      Territory.fromJson(_j(await c.delete('/v1/territories/$territoryId/stationed/$role')));

  // ── 图鉴 ──
  Future<Codex> codex() async => Codex.fromJson(_j(await c.get('/v1/codex')));

  Future<Codex> setEscort(String key) async =>
      Codex.fromJson(_j(await c.post('/v1/codex/companions/$key/escort')));

  // ── 跑团 ──
  Future<Crew> createCrew({required String name, required String district, required String joinMode}) async =>
      Crew.fromJson(_j(await c.post('/v1/crews', {
        'name': name,
        'district': district,
        'join_mode': joinMode,
        'avatar_url': null,
      })));

  Future<Paged<Crew>> crews({String q = '', String district = '', int page = 1}) async => Paged.fromJson(
      _j(await c.get('/v1/crews', query: {
        if (q.isNotEmpty) 'q': q,
        if (district.isNotEmpty) 'district': district,
        'page': page,
      })),
      Crew.fromJson);

  Future<Crew> crew(int id) async => Crew.fromJson(_j(await c.get('/v1/crews/$id')));

  Future<List<CrewMember>> crewMembers(int id) async =>
      Paged.fromJson(_j(await c.get('/v1/crews/$id/members')), CrewMember.fromJson).items;

  Future<List<CrewApplication>> crewApplications(int id) async =>
      Paged.fromJson(_j(await c.get('/v1/crews/$id/applications')), CrewApplication.fromJson).items;

  /// Returns `joined | applied`.
  Future<String> joinCrew(int id) async => '${_j(await c.post('/v1/crews/$id/join'))['status']}';

  Future<void> approveApplication(int crewId, int userId) =>
      c.post('/v1/crews/$crewId/applications/$userId/approve');

  Future<void> rejectApplication(int crewId, int userId) =>
      c.post('/v1/crews/$crewId/applications/$userId/reject');

  Future<void> leaveCrew(int id) => c.post('/v1/crews/$id/leave');

  Future<void> kick(int crewId, int userId) => c.delete('/v1/crews/$crewId/members/$userId');

  Future<Crew> transfer(int crewId, int userId) async =>
      Crew.fromJson(_j(await c.post('/v1/crews/$crewId/transfer', {'user_id': userId})));

  // ── 会员与支付 ──
  Future<PlansResponse> plans() async => PlansResponse.fromJson(_j(await c.get('/v1/plans')));

  Future<CreateOrderResult> createOrder(String planCode, String channel) async =>
      CreateOrderResult.fromJson(_j(await c.post('/v1/orders', {'plan_code': planCode, 'channel': channel})));

  Future<Order> order(String orderNo) async => Order.fromJson(_j(await c.get('/v1/orders/$orderNo')));

  Future<User> verifyApple(String signedTransaction) async =>
      User.fromJson(_j(await c.post('/v1/iap/apple', {'signed_transaction': signedTransaction})));

  Future<Membership> membership() async => Membership.fromJson(_j(await c.get('/v1/membership')));

  Future<Membership> setAutoRenew(bool enabled) async =>
      Membership.fromJson(_j(await c.post('/v1/membership/auto-renew', {'enabled': enabled})));

  /// Dev only: simulate the payment callback.
  Future<Order> devPay(String orderNo) async => Order.fromJson(_j(await c.post('/v1/dev/orders/$orderNo/pay')));

  // ── V2 玩法 ──
  static String _bbox(double minLng, double minLat, double maxLng, double maxLat) =>
      [minLng, minLat, maxLng, maxLat].map((v) => v.toStringAsFixed(6)).join(',');

  /// Bosses, chests (not yet opened by me) and route checkpoints in the bbox.
  Future<MapObjects> mapObjects(
          {required double minLng, required double minLat, required double maxLng, required double maxLat}) async =>
      MapObjects.fromJson(_j(await c.get('/v1/map/objects', query: {'bbox': _bbox(minLng, minLat, maxLng, maxLat)})));

  Future<Boss> boss(int id) async => Boss.fromJson(_j(await c.get('/v1/bosses/$id')));

  /// Errors: `out_of_range`, `not_enough_energy`, `cooldown` (429, `retry_after_s`), `boss_not_active`.
  Future<StrikeResult> strike(int id, LatLng at) async =>
      StrikeResult.fromJson(_j(await c.post('/v1/bosses/$id/strike', at.toJson())));

  /// Returns `engaged_until`.
  Future<DateTime?> engage(int id, LatLng at) async =>
      DateTime.tryParse('${_j(await c.post('/v1/bosses/$id/engage', at.toJson()))['engaged_until']}');

  /// Errors: `out_of_range`, `already_opened`, `chest_expired`.
  Future<ChestOpenResult> openChest(int id, LatLng at) async =>
      ChestOpenResult.fromJson(_j(await c.post('/v1/chests/$id/open', at.toJson())));

  Future<SeasonOverview> season() async => SeasonOverview.fromJson(_j(await c.get('/v1/season')));

  Future<League> league({String? district}) async => League.fromJson(_j(await c.get('/v1/league', query: {
        if (district != null && district.isNotEmpty) 'district': district,
      })));

  Future<List<Campaign>> campaigns() async =>
      Paged.fromJson(_j(await c.get('/v1/campaigns')), Campaign.fromJson).items;

  Future<List<CityRoute>> routes() async => Paged.fromJson(_j(await c.get('/v1/routes')), CityRoute.fromJson).items;

  Future<CityRoute> route(int id) async => CityRoute.fromJson(_j(await c.get('/v1/routes/$id')));

  /// Errors: `companion_not_hatched`, `not_enough_energy`.
  Future<Codex> feedCompanion(String key) async =>
      Codex.fromJson(_j(await c.post('/v1/codex/companions/$key/feed')));

  /// Leader only; 409 `relay_running` when one is in progress.
  Future<Relay> startRelay(int crewId, {required int legs, required double legKm}) async =>
      Relay.fromJson(_j(await c.post('/v1/crews/$crewId/relays', {'legs': legs, 'leg_km': legKm})));

  /// The running (or last) relay, or null.
  Future<Relay?> currentRelay(int crewId) async {
    final r = await c.get('/v1/crews/$crewId/relays/current');
    return r is Map && r.isNotEmpty ? Relay.fromJson(_j(r)) : null;
  }

  // ── 消息 ──
  Future<InboxPage> inbox({String category = 'all', int page = 1}) async =>
      InboxPage.fromJson(_j(await c.get('/v1/inbox', query: {'category': category, 'page': page})));

  Future<int> markRead({List<int>? ids, bool all = false}) async {
    final r = _j(await c.post('/v1/inbox/read', all ? {'all': true} : {'ids': ids ?? const []}));
    return (r['unread'] as num?)?.toInt() ?? 0;
  }
}
