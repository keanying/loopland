import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/errors.dart';
import 'package:loopland/api/models.dart';

import 'fixtures.dart';

void main() {
  test('User', () {
    final u = User.fromJson(j(userJson));
    expect(u.id, 1);
    expect(u.nickname, '跑者1024');
    expect(u.isAdult, isNull);
    expect(u.isMinor, isFalse);
    expect(u.consents.privacyAccepted, isTrue);
    expect(u.consents.location, isTrue);
    expect(u.settings.trackVisibility, 'crew');
    expect(u.crew!.name, '城西跑团');
    expect(u.membership!.autoRenew, isTrue);
    expect(u.membership!.expiresAt, DateTime.parse('2026-12-20T02:00:00Z'));
    expect(u.stats.week.distanceM, 10000);
    expect(u.stats.territoryCount, 3);
  });

  test('User with null crew / membership, minor and deleting', () {
    final m = j(userJson)
      ..['crew'] = null
      ..['membership'] = null
      ..['is_adult'] = false
      ..['status'] = 'deleting'
      ..['delete_after'] = '2026-11-27T10:00:00+08:00';
    final u = User.fromJson(m);
    expect(u.crew, isNull);
    expect(u.membership, isNull);
    expect(u.isMinor, isTrue);
    expect(u.isDeleting, isTrue);
    expect(u.deleteAfter, isNotNull);
  });

  test('AuthResult', () {
    final a = AuthResult.fromJson(j(authResultJson));
    expect(a.accessToken, 'acc');
    expect(a.refreshToken, 'ref');
    expect(a.isNew, isTrue);
    expect(a.needBindPhone, isFalse);
    expect(a.user.level, 2);
  });

  test('Config', () {
    final c = GameConfig.fromJson(j(configJson));
    expect(c.slotsPerTerritory, 6);
    expect(c.minClaimAreaM2, 500);
    expect(c.levelThresholds.last, 3200);
    expect(c.energyFor('run')!.text, '10 能量 / km');
    expect(c.energyFor('strength')!.text, '5 能量 / 10 分钟');
    expect(c.building('campfire')!.cost, 80);
    expect(c.rolesFor('run').single.buffText, '领地守卫 +5%');
    expect(c.companions.single.hatchKm, 10);
    expect(c.medals.single.distanceKm, 100);
  });

  test('ActivityResult', () {
    final r = ActivityResult.fromJson(j(activityResultJson));
    expect(r.activity.distanceM, 5370);
    expect(r.activity.track, hasLength(2));
    expect(r.activity.track.first.lat, 31.23); // GeoJSON [lng, lat]
    expect(r.activity.track.first.lng, 121.47);
    final s = r.settlement;
    expect(s.status, 'settled');
    expect(s.claims.single.kind, 'claim');
    expect(s.claimedAreaM2, 5230.5);
    expect(s.attacks.single.owner!.nickname, '小鹿');
    expect(s.attacks.single.guardAfter, 67);
    expect(s.recruits.single.progress, 12.4);
    expect(s.eggs.single.hatchKm, 10);
    expect(s.medals.single.name, '百公里');
    expect(s.levelUp, isNull);
    expect(s.flags.single.rule, 'speed');
  });

  test('level_up shapes', () {
    expect(LevelUp.parse(3)!.to, 3);
    expect(LevelUp.parse({'from': 2, 'to': 3})!.from, 2);
    expect(LevelUp.parse({'level': 4})!.to, 4);
    expect(LevelUp.parse(null), isNull);
  });

  test('ClaimPreview', () {
    final p = ClaimPreview.fromJson(j(previewJson));
    expect(p.loops.single.ring, hasLength(4));
    expect(p.hintDistanceM, 120);
    expect(p.hintTarget!.lat, 31.23);
    expect(p.rawEnergy, 12);
  });

  test('TerritorySummary / Territory / BuildResult', () {
    final t = TerritorySummary.fromJson(j(territorySummaryJson));
    expect(t.isMine, isTrue);
    expect(t.polygons.single.single, hasLength(4));
    expect(t.polygons.single.single[1].lng, 121.48);
    final full = Territory.fromJson(j(territoryJson));
    expect(full.summary.crew, isNull);
    expect(full.dailyEnergy, 25);
    expect(full.slots[1].empty, isTrue);
    expect(full.builtCount, 1);
    expect(full.stationed.single.buffText, '领地守卫 +5%');
    expect(full.events.single.actor!.nickname, '小鹿');
    final b = BuildResult.fromJson({'territory': j(territoryJson), 'energy': 55});
    expect(b.energy, 55);
    expect(b.territory.id, 101);
  });

  test('Polygon (single) geometry is accepted too', () {
    final m = j(territorySummaryJson)
      ..['geometry'] = {
        'type': 'Polygon',
        'coordinates': [
          [[121.47, 31.23], [121.48, 31.23], [121.48, 31.24], [121.47, 31.23]]
        ]
      };
    expect(TerritorySummary.fromJson(m).polygons.single.single, hasLength(4));
  });

  test('Codex', () {
    final c = Codex.fromJson(j(codexJson));
    expect(c.progress['roles'], '2/8');
    expect(c.roles.first.obtained, isFalse);
    expect(c.roles[1].stationedAt, 101);
    expect(c.buildings[1].unlocked, isFalse);
    expect(c.companions.first.isEgg, isTrue);
    expect(c.companions[1].escort, isTrue);
    expect(c.obtainedCount, 3);
    expect(c.totalCount, 7);
  });

  test('Crew, members, applications', () {
    final c = Crew.fromJson(j(crewJson));
    expect(c.isLeader, isTrue);
    expect(c.weekRank.single.distanceM, 20000);
    final members = Paged.fromJson({
      'items': [
        {'user': {'id': 1, 'nickname': 'a'}, 'role': 'leader', 'joined_at': '2026-11-01T00:00:00Z'}
      ]
    }, CrewMember.fromJson);
    expect(members.items.single.role, 'leader');
    expect(members.total, 1);
    final apps = Paged.fromJson({
      'items': [
        {'user': {'id': 5, 'nickname': 'b'}, 'created_at': '2026-11-01T00:00:00Z'}
      ]
    }, CrewApplication.fromJson);
    expect(apps.items.single.user.id, 5);
  });

  test('Plans, Order, CreateOrderResult', () {
    final r = PlansResponse.fromJson({'items': [j(planJson)], 'minor_blocked': false});
    final p = r.items.single;
    expect(p.firstPriceFen, 1500);
    expect(p.entitlements, contains('crew_tools'));
    expect(PlansResponse.fromJson({'items': [], 'minor_blocked': true}).minorBlocked, isTrue);
    final o = Order.fromJson(j(orderJson));
    expect(o.isPaid, isFalse);
    expect(o.kind, 'purchase');
    final cr = CreateOrderResult.fromJson({
      'order': j(orderJson),
      'pay_params': {'product_id': 'com.loopland.member.auto_month', 'app_account_token': 'uuid'}
    });
    expect(cr.payParams['app_account_token'], 'uuid');
  });

  test('Inbox', () {
    final p = InboxPage.fromJson(j(inboxJson));
    expect(p.unread, 3);
    expect(p.items.single.territoryId, 101);
    expect(p.items.single.copyWith(read: true).read, isTrue);
  });

  test('ActivityUpload JSON round trip', () {
    final u = ActivityUpload(
      clientId: 'c1',
      sport: 'run',
      startedAt: DateTime.utc(2026, 11, 20, 11),
      endedAt: DateTime.utc(2026, 11, 20, 11, 30),
      durationS: 1800,
      goal: const Goal(type: 'target', territoryId: 12),
      points: const [TrackPoint(t: 1732000000000, lat: 31.23, lng: 121.47, acc: 5, spd: 2.9, src: 'mock')],
      device: const DeviceInfo(id: 'd', model: 'iPhone15,2', os: 'iOS 18.1'),
    );
    final m = u.toJson();
    expect(m['goal'], {'type': 'target', 'territory_id': 12});
    expect((m['points'] as List).single, {'t': 1732000000000, 'lat': 31.23, 'lng': 121.47, 'acc': 5.0, 'spd': 2.9, 'src': 'mock'});
    expect(m.containsKey('amount'), isFalse);
    expect(m['device']['multi_open'], false);
    final back = ActivityUpload.fromJson(m);
    expect(back.clientId, 'c1');
    expect(back.points.single.src, 'mock');
    expect(back.startedAt, u.startedAt);
  });

  test('errors: every contract code has a Chinese message', () {
    const codes = [
      'invalid_body', 'unauthorized', 'forbidden', 'not_found', 'conflict', 'rate_limited', 'internal', //
      'invalid_phone', 'invalid_code', 'code_expired', 'provider_error', 'account_banned', 'phone_required',
      'phone_taken', 'consent_required', 'realname_failed', 'realname_required', 'sport_not_supported', //
      'not_owner', 'frozen', 'slot_taken', 'invalid_slot', 'level_too_low', 'not_enough_energy',
      'unknown_building', 'role_not_owned', 'no_station_slot', //
      'already_in_crew', 'invite_only', 'leader_must_transfer', //
      'channel_not_allowed', 'minor_blocked', 'plan_off_sale', 'manage_in_app_store',
    ];
    for (final c in codes) {
      expect(errorMessages[c], isNotNull, reason: c);
      expect(ApiException(status: 400, code: c).message, errorMessages[c]);
    }
  });

  test('errors: server message wins; banned_until is shown', () {
    final e = ApiException.fromResponse(400, {
      'error': {'code': 'not_enough_energy', 'message': '需要 120，当前 80'}
    });
    expect(e.code, 'not_enough_energy');
    expect(e.message, '需要 120，当前 80');
    final b = ApiException.fromResponse(403, {
      'error': {'code': 'account_banned', 'message': '', 'banned_until': '2026-12-20T00:00:00+08:00'}
    });
    expect(b.displayMessage, contains('2026-12-20'));
    expect(ApiException.fromResponse(502, 'gateway').code, 'internal');
  });
}
