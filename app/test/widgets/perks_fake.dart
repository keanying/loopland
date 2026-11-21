// Method-aware, stateful fake of the V2 batch 4 perks endpoints
// (docs/api/v2-4-本地生活与商户.md: brand campaigns, coupons + QR, supply
// claim, energy shop). Plug into fakeBackend(handlers: [fake.handle]).
import 'package:dio/dio.dart';
import 'package:loopland/claim/geo.dart';

import '../api/fixtures.dart';
import '../api/fixtures_v2.dart';
import 'fake_backend.dart' show origin;

typedef J = Map<String, dynamic>;

/// [x] / [y] metres east / north of [origin] as `{"lat","lng"}`.
J at(double x, double y) {
  final ll = Projection(origin).inverse(Point(x, y));
  return {'lat': ll.lat, 'lng': ll.lng};
}

J perkJson(String title, String value, {String desc = '', String rules = '到店出示券码，店员扫码核销；需要当天有一条运动记录'}) =>
    {'title': title, 'description': desc, 'value_text': value, 'valid_days': 7, 'rules': rules};

const luckin = {'id': 5, 'name': '瑞幸咖啡'};
const decathlon = {'id': 6, 'name': '迪卡侬'};

J couponJson(int id,
        {String status = 'unused',
        String code = '8K2D9QXW',
        J? perk,
        Map<String, Object> merchant = luckin,
        String source = 'supply',
        String sourceName = '补给站 · 瑞幸滨江店'}) =>
    {
      'id': id,
      'code': code,
      'perk': perk ?? perkJson('美式咖啡 5 折', '5 折', desc: '限滨江店，每人每天 1 次'),
      'merchant': merchant,
      'source': {'type': source, 'drop_id': 4, 'name': sourceName},
      'status': status,
      'obtained_at': '2026-11-21T08:10:00',
      'expires_at': '2026-11-28T23:59:59',
      'used_at': status == 'used' ? '2026-11-22T14:30:00' : null,
      'used_store': status == 'used' ? '滨江店' : null,
    };

J shopItem(String key, String name, String type, int price,
        {bool owned = false, bool equipped = false, J? preview, String desc = '', String? limitedUntil}) =>
    {
      'key': key,
      'name': name,
      'type': type,
      'price_energy': price,
      'image_url': null,
      'preview': preview ?? {'fill': '#D9F26B', 'stroke': '#A0D911', 'pattern': 'grid'},
      'description': desc,
      'owned': owned,
      'equipped': equipped,
      'limited_until': limitedUntil,
    };

/// A supply ~60 m east of origin (radius 80 m).
J supplyJson({int id = 4, bool claimed = false}) => {
      'id': id,
      'name': '补给站 · 瑞幸滨江店',
      'center': at(60, 0),
      'radius_m': 80,
      'perk_title': '美式咖啡 5 折',
      'claimed_today': claimed,
    };

class PerksFake {
  int energy = 1280;
  final calls = <RequestOptions>[];
  int qrCount = 0;
  final claimed = <int>{};

  /// Drop ids that answer `sold_out`.
  final soldOut = <int>{};

  late final items = <J>[
    shopItem('skin_neon', '霓虹领地皮肤', 'territory_skin', 800, desc: '荧光绿网格，夜里也显眼'),
    shopItem('skin_aurora', '极光领地皮肤', 'territory_skin', 1500,
        preview: {'fill': '#B4A3F5', 'stroke': '#6FD3E8', 'pattern': 'waves'}, desc: '地块变成流动的极光色', limitedUntil: '2026-12-31T20:00:00'),
    shopItem('frame_gold', '金色头像框', 'avatar_frame', 500, desc: '赛季王者同款金边'),
    shopItem('frame_neon', '霓虹头像框', 'avatar_frame', 300, owned: true, desc: '发光的荧光绿描边'),
    shopItem('marker_bolt', '闪电标记', 'map_marker', 200, owned: true, equipped: true,
        preview: {'fill': '#DCF26A', 'stroke': null, 'pattern': null}, desc: '地图上你的位置变成一道闪电'),
    shopItem('marker_star', '星星标记', 'map_marker', 2000, preview: {'fill': '#FFC857', 'stroke': null, 'pattern': null}, desc: '金色星星'),
  ];

  late final coupons = <String, List<J>>{
    'unused': [
      couponJson(77),
      couponJson(78,
          code: 'Q7TT3KPA',
          perk: perkJson('运动饮料买一送一', '买一送一'),
          merchant: decathlon,
          source: 'chest',
          sourceName: '迪卡侬宝箱'),
    ],
    'used': [couponJson(70, status: 'used', code: 'ZZ88AA11')],
    'expired': [couponJson(60, status: 'expired', code: 'EXP00001', perk: perkJson('拿铁立减 5 元', '-¥5'))],
  };

  J campaign() => {
        'id': 2,
        'merchant': luckin,
        'title': '跑完来杯咖啡',
        'description': '冬季联名：跑步经过瑞幸门店旁的补给站，领一张美式 5 折券；开瑞幸宝箱还能拿到拿铁券。',
        'cover_url': null,
        'start_time': '2026-11-20T00:00:00+08:00',
        'end_time': '2026-12-31T23:59:59+08:00',
        'status': 'running',
        'store_count': 12,
        'drop_ids': [4, 5],
        'target_redemptions': 5000,
        'stats': {'issued': 3200, 'redeemed': 1800, 'new_users': 420, 'progress_rate': 0.36},
        'drops': [
          {
            'id': 4,
            'merchant': luckin,
            'campaign_id': 2,
            'type': 'supply',
            'name': '补给站 · 瑞幸滨江店',
            'center': at(60, 0),
            'radius_m': 80,
            'venue_id': null,
            'perk': perkJson('美式咖啡 5 折', '5 折', desc: '限滨江店，每人每天 1 次'),
            'daily_cap': 100,
            'issued_today': 12,
            'start_time': '2026-11-20T00:00:00+08:00',
            'end_time': '2026-12-31T23:59:59+08:00',
            'status': 'active',
          },
          {
            'id': 5,
            'merchant': luckin,
            'campaign_id': 2,
            'type': 'chest',
            'name': '瑞幸宝箱 · 外滩',
            'center': at(-300, 200),
            'radius_m': 50,
            'perk': perkJson('拿铁立减 5 元', '-¥5'),
            'daily_cap': 50,
            'issued_today': 50,
            'status': 'active',
          },
        ],
      };

  int count(String method, String path) => calls.where((o) => o.method == method && o.path == path).length;

  (int, Object?) _err(int status, String code, [String message = '']) => (status, {
        'error': {'code': code, 'message': message}
      });

  (int, Object?)? handle(RequestOptions o) {
    final p = o.path;
    final m = o.method;
    if (!(p.startsWith('/v1/brand-campaigns') ||
        p.startsWith('/v1/me/coupons') ||
        p.startsWith('/v1/coupons/') ||
        p.startsWith('/v1/drops/') ||
        p.startsWith('/v1/shop/') ||
        p == '/v1/map/objects')) {
      return null;
    }
    calls.add(o);
    if (p == '/v1/map/objects') {
      return (200, j(mapObjectsJson)..['supplies'] = [supplyJson(claimed: claimed.contains(4))]);
    }
    if (p == '/v1/brand-campaigns') return (200, {'items': [campaign()]});
    if (p == '/v1/me/coupons') return (200, {'items': coupons['${o.queryParameters['status'] ?? 'unused'}'] ?? []});
    final qr = RegExp(r'^/v1/coupons/(\d+)/qr$').firstMatch(p);
    if (qr != null) {
      qrCount++;
      return (200, {'payload': 'LPC.${qr.group(1)}.$qrCount.sig$qrCount', 'expires_in_sec': 60});
    }
    final claim = RegExp(r'^/v1/drops/(\d+)/claim$').firstMatch(p);
    if (claim != null && m == 'POST') {
      final id = int.parse(claim.group(1)!);
      if (soldOut.contains(id)) return _err(409, 'sold_out');
      if (!claimed.add(id)) return _err(409, 'already_claimed');
      final c = couponJson(90 + id, code: 'NEWC0DE$id');
      coupons['unused']!.insert(0, c);
      return (200, c);
    }
    if (p == '/v1/shop/items') {
      final type = o.queryParameters['type'];
      return (200, {
        'items': [for (final i in items) if (type == null || i['type'] == type) i],
        'energy': energy,
      });
    }
    final shop = RegExp(r'^/v1/shop/items/([\w-]+)/(buy|equip)$').firstMatch(p);
    if (shop != null) {
      final key = shop.group(1)!;
      final item = items.firstWhere((i) => i['key'] == key);
      if (shop.group(2) == 'buy') {
        if (item['owned'] == true) return _err(409, 'already_owned');
        final price = item['price_energy'] as int;
        if (energy < price) return _err(409, 'not_enough_energy');
        energy -= price;
        item['owned'] = true;
        return (200, {'item': item, 'energy': energy});
      }
      if (item['owned'] != true) return _err(409, 'not_owned');
      if (m == 'POST') {
        for (final i in items) {
          if (i['type'] == item['type']) i['equipped'] = false;
        }
        item['equipped'] = true;
      } else {
        item['equipped'] = false;
      }
      return (200, item);
    }
    return null;
  }
}
