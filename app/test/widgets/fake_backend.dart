import 'dart:math' as math;

import 'package:dio/dio.dart' show HttpClientAdapter, RequestOptions;

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/auth/auth_controller.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/claim/geo.dart';
import 'package:loopland/core/providers.dart';

import '../api/api_client_test.dart' show FakeAdapter;
import '../api/fixtures.dart';
import '../api/fixtures_v2.dart';

const origin = LatLng(31.2304, 121.4737);

/// A blob-shaped polygon (GeoJSON [lng, lat]) around [cx],[cy] metres.
List<List<double>> blob(double cx, double cy, double r, int seed) {
  final p = Projection(origin);
  final rnd = math.Random(seed);
  final ring = <List<double>>[];
  for (var i = 0; i < 7; i++) {
    final a = i / 7 * 2 * math.pi;
    final rr = r * (0.75 + rnd.nextDouble() * 0.5);
    final ll = p.inverse(Point(cx + rr * math.cos(a), cy + rr * math.sin(a)));
    ring.add([ll.lng, ll.lat]);
  }
  ring.add(ring.first);
  return ring;
}

Map<String, dynamic> territory(int id, String name, String relation, double x, double y, double r, int guard) {
  final p = Projection(origin).inverse(Point(x, y));
  return {
    'id': id,
    'name': name,
    'relation': relation,
    'owner': relation == 'unowned' ? null : {'id': id, 'nickname': relation == 'mine' ? '阿杰' : '小鹿'},
    'crew': relation == 'crew' ? {'id': 3, 'name': '城西跑团'} : null,
    'geometry': {
      'type': 'MultiPolygon',
      'coordinates': [
        [blob(x, y, r, id)]
      ]
    },
    'center': {'lat': p.lat, 'lng': p.lng},
    'area_m2': math.pi * r * r,
    'guard': guard,
    'frozen': false,
  };
}

final sampleTerritories = [
  territory(1, '滨江公园', 'mine', 0, -120, 230, 68),
  territory(2, '老街口', 'mine', -260, 260, 150, 120),
  territory(3, '云杉坡', 'crew', 280, 300, 210, 90),
  territory(4, '西岸草坪', 'enemy', -380, -60, 170, 42),
  territory(5, '东港步道', 'enemy', 380, -60, 180, 150),
  territory(6, '南湖步道', 'unowned', 60, -520, 140, 0),
];

User sampleUser() {
  final m = j(userJson)
    ..['nickname'] = '阿杰'
    ..['level'] = 7
    ..['energy'] = 1280
    ..['energy_today'] = 320;
  (m['stats'] as Map)['territory_area_m2'] = 2360000;
  return User.fromJson(m);
}

const featuresJson = {
  'login': ['apple', 'oneclick', 'sms', 'wechat'],
  'pay': ['alipay_app', 'apple_iap', 'mock', 'wechat_app'],
  'captcha': false,
};

/// [AuthController] that starts signed in as [user] (for tests that watch
/// `refreshUser()` / `setUser()` reach the screens; see `liveUser`).
class SeededAuth extends AuthController {
  SeededAuth(this.user);
  final User user;
  @override
  AuthState build() {
    super.build();
    return AuthState(status: AuthStatus.loggedIn, user: user);
  }
}

/// Overrides that make every screen render against canned data.
///
/// By default [userProvider] is pinned to [user]. With [liveUser] the user
/// lives in [authProvider] instead (signed in as [user]), so `GET /v1/me`
/// answered by a handler updates every screen like in the app.
///
/// [handlers] are consulted first, in order; a handler returns null to pass
/// (e.g. `communityHandler` in community_fake.dart, method-aware and stateful).
/// [wrapAdapter] can put an adapter in front of the JSON fake (e.g. the SSE
/// stream of ai_fake.dart).
List<Override> fakeBackend({
  User? user,
  Map<String, Object?> extra = const {},
  List<(int, Object?)? Function(RequestOptions o)> handlers = const [],
  HttpClientAdapter Function(HttpClientAdapter inner)? wrapAdapter,
  bool liveUser = false,
}) {
  final adapter = FakeAdapter((o) {
    final p = o.path;
    for (final h in handlers) {
      final r = h(o);
      if (r != null) return r;
    }
    if (extra.containsKey(p)) {
      final v = extra[p];
      return v is (int, Object?) ? v : (200, v);
    }
    if (p == '/v1/territories') return (200, {'items': sampleTerritories});
    if (p == '/v1/config/features') return (200, featuresJson);
    if (p == '/v1/inbox') return (200, j(inboxJson));
    if (p == '/v1/codex') return (200, j(codexJson));
    if (p == '/v1/config/gameplay') return (200, j(configJson));
    if (p.startsWith('/v1/territories/')) return (200, j(territoryJson));
    // V2 玩法
    if (p == '/v1/map/objects') return (200, j(mapObjectsJson));
    if (p == '/v1/bosses/3') return (200, j(bossJson));
    if (p == '/v1/bosses/3/strike') return (200, j(strikeJson));
    if (p == '/v1/bosses/3/engage') return (200, {'engaged_until': '2099-11-21T20:00:00+08:00'});
    if (p == '/v1/chests/9/open') return (200, {'energy': 40, 'bonus': true});
    if (p == '/v1/season') return (200, j(seasonJson));
    if (p == '/v1/league') return (200, j(leagueJson));
    if (p == '/v1/campaigns') {
      return (200, {
        'items': [
          j(campaignJson),
          j(campaignJson)
            ..['id'] = 6
            ..['title'] = '十公里挑战'
            ..['type'] = 'distance'
            ..['rules'] = {'min_distance_km': 10}
            ..['completed'] = true
            ..['reward_medal'] = null,
        ]
      });
    }
    if (p == '/v1/routes') return (200, {'items': [j(routeJson)]});
    if (p == '/v1/routes/2') return (200, j(routeJson));
    if (p == '/v1/crews/3/relays/current') return (200, j(relayJson));
    if (p == '/v1/codex/companions/frog/feed') return (200, j(codexJson));
    return (404, {'error': {'code': 'not_found', 'message': ''}});
  });
  final u = user ?? sampleUser();
  return [
    tokenStoreProvider.overrideWithValue(MemoryTokenStore(access: 'A', refresh: 'R')),
    kvCacheProvider.overrideWithValue(MemoryCache()),
    apiClientProvider.overrideWithValue(ApiClient(
        tokens: MemoryTokenStore(access: 'A'), baseUrl: 'http://x', adapter: wrapAdapter == null ? adapter : wrapAdapter(adapter))),
    if (liveUser) authProvider.overrideWith(() => SeededAuth(u)) else userProvider.overrideWithValue(u),
  ];
}
