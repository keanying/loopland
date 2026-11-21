import 'dart:math' as math;

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/auth/auth_controller.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/claim/geo.dart';
import 'package:loopland/core/providers.dart';

import '../api/api_client_test.dart' show FakeAdapter;
import '../api/fixtures.dart';

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

/// Overrides that make every screen render against canned data.
List<Override> fakeBackend({User? user, Map<String, Object?> extra = const {}}) {
  final adapter = FakeAdapter((o) {
    final p = o.path;
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
    return (404, {'error': {'code': 'not_found', 'message': ''}});
  });
  final u = user ?? sampleUser();
  return [
    tokenStoreProvider.overrideWithValue(MemoryTokenStore(access: 'A', refresh: 'R')),
    kvCacheProvider.overrideWithValue(MemoryCache()),
    apiClientProvider.overrideWithValue(ApiClient(tokens: MemoryTokenStore(access: 'A'), baseUrl: 'http://x', adapter: adapter)),
    userProvider.overrideWithValue(u),
  ];
}
