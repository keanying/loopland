// V2 batch 4「本地生活与商户」· 联名权益 / 卡券包 / 能量商城 models
// (docs/api/v2-4-本地生活与商户.md, sections A-16 / E-04 / E-05 / M-26).
// The 订场 / 场馆 models live elsewhere. Same tolerant parsing as the other
// model files (helpers from community_common.dart).
import '../claim/geo.dart';
import 'community_common.dart';
import 'models.dart';

LatLng? _ll(Object? v) => v is Map ? LatLng.fromJson(v.cast<String, dynamic>()) : null;

/// `{ "id": 5, "name": "瑞幸咖啡" }`.
class PerkMerchant {
  const PerkMerchant({required this.id, required this.name});
  final int id;
  final String name;
  static PerkMerchant? maybe(Object? v) => v is Map ? PerkMerchant(id: ji(v['id']), name: js(v['name'])) : null;
}

/// Perk: the template of a coupon (权益).
class Perk {
  const Perk({required this.title, this.description = '', this.valueText = '', this.validDays = 0, this.rules = ''});
  final String title;
  final String description;

  /// Short big text on the coupon face, e.g. 「5 折」.
  final String valueText;
  final int validDays;
  final String rules;

  factory Perk.fromJson(Json j) => Perk(
        title: js(j['title']),
        description: js(j['description']),
        valueText: js(j['value_text']),
        validDays: ji(j['valid_days']),
        rules: js(j['rules']),
      );
  static Perk? maybe(Object? v) => v is Map ? Perk.fromJson(v.cast<String, dynamic>()) : null;
}

/// Chinese name of a drop type.
String dropTypeName(String type) => switch (type) {
      'supply' => '补给站',
      'chest' => '商户宝箱',
      'stronghold' => '据点',
      _ => '投放点',
    };

/// How a coupon is obtained from a drop of [type] (shown on 联名活动).
String dropHowTo(String type, {double radiusM = 0}) => switch (type) {
      'supply' => '跑步轨迹经过补给站${radiusM > 0 ? ' ${radiusM.round()} 米' : ''}范围自动领取，或人在范围内时在地图上点「领取」；每个补给站每天 1 张',
      'chest' => '地图上刷出的商户宝箱，走到附近或跑步经过即可开启，宝箱里是这家的券',
      'stronghold' => '到合作场馆签到（定位或扫场馆码），签到即得券',
      _ => '运动即可免费获得',
    };

/// Drop (投放点), public fields as returned inside `BrandCampaign.drops`.
class PerkDrop {
  const PerkDrop({
    required this.id,
    required this.type,
    required this.name,
    this.merchant,
    this.campaignId,
    this.center,
    this.radiusM = 0,
    this.venueId,
    this.perk,
    this.dailyCap = 0,
    this.issuedToday = 0,
    this.startTime,
    this.endTime,
    this.status = 'active',
  });
  final int id;

  /// `supply | chest | stronghold`.
  final String type;
  final String name;
  final PerkMerchant? merchant;
  final int? campaignId;
  final LatLng? center;
  final double radiusM;
  final int? venueId;
  final Perk? perk;
  final int dailyCap, issuedToday;
  final DateTime? startTime, endTime;

  /// `scheduled | active | paused | ended`.
  final String status;

  bool get soldOutToday => dailyCap > 0 && issuedToday >= dailyCap;

  factory PerkDrop.fromJson(Json j) => PerkDrop(
        id: ji(j['id']),
        type: js(j['type'], 'supply'),
        name: js(j['name']),
        merchant: PerkMerchant.maybe(j['merchant']),
        campaignId: jin(j['campaign_id']),
        center: _ll(j['center']),
        radiusM: jd(j['radius_m']),
        venueId: jin(j['venue_id']),
        perk: Perk.maybe(j['perk']),
        dailyCap: ji(j['daily_cap']),
        issuedToday: ji(j['issued_today']),
        startTime: jdt(j['start_time']),
        endTime: jdt(j['end_time']),
        status: js(j['status'], 'active'),
      );
}

/// `BrandCampaign` as the App sees it (no investment amount).
class BrandCampaign {
  const BrandCampaign({
    required this.id,
    required this.title,
    this.merchant,
    this.description = '',
    this.coverUrl,
    this.startTime,
    this.endTime,
    this.status = 'running',
    this.storeCount = 0,
    this.drops = const [],
    this.issued = 0,
    this.redeemed = 0,
  });
  final int id;
  final String title;
  final PerkMerchant? merchant;
  final String description;
  final String? coverUrl;
  final DateTime? startTime, endTime;

  /// `draft | scheduled | running | paused | ended`.
  final String status;
  final int storeCount;
  final List<PerkDrop> drops;
  final int issued, redeemed;

  /// Distinct perks of the campaign's drops (by title).
  List<Perk> get perks {
    final seen = <String>{};
    return [
      for (final d in drops)
        if (d.perk != null && seen.add(d.perk!.title)) d.perk!,
    ];
  }

  /// Drop types present, in a fixed order.
  List<String> get dropTypes => [
        for (final t in const ['supply', 'chest', 'stronghold'])
          if (drops.any((d) => d.type == t)) t,
      ];

  factory BrandCampaign.fromJson(Json j) {
    final stats = jm(j['stats']);
    return BrandCampaign(
      id: ji(j['id']),
      title: js(j['title']),
      merchant: PerkMerchant.maybe(j['merchant']),
      description: js(j['description']),
      coverUrl: jsn(j['cover_url']),
      startTime: jdt(j['start_time']),
      endTime: jdt(j['end_time']),
      status: js(j['status'], 'running'),
      storeCount: ji(j['store_count']),
      drops: jl(j['drops'], PerkDrop.fromJson),
      issued: ji(stats['issued']),
      redeemed: ji(stats['redeemed']),
    );
  }
}

/// Where a coupon came from.
class CouponSource {
  const CouponSource({required this.type, this.dropId, this.name = '', this.productId, this.orderId});

  /// `supply | chest | stronghold`, or `product` (bought, V2 batch 5).
  final String type;
  final int? dropId;
  final String name;

  /// `product` coupons: the product and its ProductOrder.
  final int? productId, orderId;

  bool get isProduct => type == 'product';

  static CouponSource? maybe(Object? v) => v is Map
      ? CouponSource(
          type: js(v['type']),
          dropId: jin(v['drop_id']),
          name: js(v['name']),
          productId: jin(v['product_id']),
          orderId: jin(v['order_id']),
        )
      : null;
}

/// A coupon in my wallet (卡券包).
class Coupon {
  const Coupon({
    required this.id,
    required this.code,
    required this.perk,
    this.merchant,
    this.source,
    this.status = 'unused',
    this.obtainedAt,
    this.expiresAt,
    this.usedAt,
    this.usedStore,
    this.usesTotal = 1,
    this.usesLeft = 1,
  });
  final int id;
  final String code;
  final Perk perk;
  final PerkMerchant? merchant;
  final CouponSource? source;

  /// `unused | used | expired | voided | refunded`.
  final String status;
  final DateTime? obtainedAt, expiresAt, usedAt;
  final String? usedStore;

  /// Uses of a 次卡 (`uses_total` > 1); 1 / 1 for every other coupon.
  final int usesTotal, usesLeft;

  bool get isUnused => status == 'unused';

  /// Bought with money (商品券): no same-day run needed to redeem.
  bool get isProduct => source?.isProduct ?? false;

  /// A 次卡 with more than one use.
  bool get isPass => usesTotal > 1;

  /// 「剩余 3/10 次」.
  String get usesText => '剩余 $usesLeft/$usesTotal 次';

  String get statusText => switch (status) {
        'unused' => '未使用',
        'used' => '已使用',
        'expired' => '已过期',
        'voided' => '已作废',
        'refunded' => '已退款',
        _ => status,
      };

  factory Coupon.fromJson(Json j) => Coupon(
        id: ji(j['id']),
        code: js(j['code']),
        perk: Perk.fromJson(jm(j['perk'])),
        merchant: PerkMerchant.maybe(j['merchant']),
        source: CouponSource.maybe(j['source']),
        status: js(j['status'], 'unused'),
        obtainedAt: jdt(j['obtained_at']),
        expiresAt: jdt(j['expires_at']),
        usedAt: jdt(j['used_at']),
        usedStore: jsn(j['used_store']),
        usesTotal: ji(j['uses_total'], 1),
        usesLeft: ji(j['uses_left'], ji(j['uses_total'], 1)),
      );
  static Coupon? maybe(Object? v) => v is Map ? Coupon.fromJson(v.cast<String, dynamic>()) : null;
}

/// `GET /v1/coupons/{id}/qr`.
class CouponQr {
  const CouponQr({required this.payload, this.expiresInSec = 60});
  final String payload;
  final int expiresInSec;
  factory CouponQr.fromJson(Json j) => CouponQr(payload: js(j['payload']), expiresInSec: ji(j['expires_in_sec'], 60));
}

// ───────────────────────────── 能量商城 ─────────────────────────────

/// Shop item types, in tab order.
const shopTypes = ['territory_skin', 'avatar_frame', 'map_marker'];

String shopTypeName(String type) => switch (type) {
      'territory_skin' => '领地皮肤',
      'avatar_frame' => '头像框',
      'map_marker' => '地图标记',
      _ => '装扮',
    };

/// `preview` of a shop item / `skin` of a territory: colours as `#RRGGBB`
/// (or `#AARRGGBB`), `pattern` e.g. `grid | stripes | dots | waves`.
class CosmeticStyle {
  const CosmeticStyle({this.key, this.fill, this.stroke, this.pattern});
  final String? key;
  final String? fill, stroke, pattern;

  factory CosmeticStyle.fromJson(Json j) =>
      CosmeticStyle(key: jsn(j['key']), fill: jsn(j['fill']), stroke: jsn(j['stroke']), pattern: jsn(j['pattern']));
  static CosmeticStyle? maybe(Object? v) => v is Map ? CosmeticStyle.fromJson(v.cast<String, dynamic>()) : null;

  @override
  bool operator ==(Object other) =>
      other is CosmeticStyle && other.key == key && other.fill == fill && other.stroke == stroke && other.pattern == pattern;
  @override
  int get hashCode => Object.hash(key, fill, stroke, pattern);
}

class ShopItem {
  const ShopItem({
    required this.key,
    required this.name,
    required this.type,
    this.priceEnergy = 0,
    this.imageUrl,
    this.preview = const CosmeticStyle(),
    this.description = '',
    this.owned = false,
    this.equipped = false,
    this.limitedUntil,
  });
  final String key;
  final String name;

  /// `territory_skin | avatar_frame | map_marker`.
  final String type;
  final int priceEnergy;
  final String? imageUrl;
  final CosmeticStyle preview;
  final String description;
  final bool owned, equipped;
  final DateTime? limitedUntil;

  ShopItem copyWith({bool? owned, bool? equipped}) => ShopItem(
        key: key,
        name: name,
        type: type,
        priceEnergy: priceEnergy,
        imageUrl: imageUrl,
        preview: preview,
        description: description,
        owned: owned ?? this.owned,
        equipped: equipped ?? this.equipped,
        limitedUntil: limitedUntil,
      );

  factory ShopItem.fromJson(Json j) => ShopItem(
        key: js(j['key']),
        name: js(j['name']),
        type: js(j['type'], 'territory_skin'),
        priceEnergy: ji(j['price_energy']),
        imageUrl: jsn(j['image_url']),
        preview: CosmeticStyle.maybe(j['preview']) ?? const CosmeticStyle(),
        description: js(j['description']),
        owned: jb(j['owned']),
        equipped: jb(j['equipped']),
        limitedUntil: jdt(j['limited_until']),
      );
}

/// `GET /v1/shop/items`.
class ShopCatalog {
  const ShopCatalog({this.items = const [], this.energy = 0});
  final List<ShopItem> items;
  final int energy;
  factory ShopCatalog.fromJson(Json j) => ShopCatalog(items: jl(j['items'], ShopItem.fromJson), energy: ji(j['energy']));
}

/// `POST /v1/shop/items/{key}/buy`.
class ShopBuyResult {
  const ShopBuyResult({required this.item, required this.energy});
  final ShopItem item;
  final int energy;
  factory ShopBuyResult.fromJson(Json j) => ShopBuyResult(item: ShopItem.fromJson(jm(j['item'])), energy: ji(j['energy']));
}

/// `GET /v1/me` → `equipped`: keys of what I wear. Tolerates either a key
/// string or an object with `key` per slot.
class EquippedItems {
  const EquippedItems({this.territorySkin, this.avatarFrame, this.mapMarker});
  final String? territorySkin, avatarFrame, mapMarker;

  static String? _key(Object? v) => v is String && v.isNotEmpty ? v : (v is Map ? jsn(v['key']) : null);

  factory EquippedItems.fromJson(Json j) => EquippedItems(
        territorySkin: _key(j['territory_skin']),
        avatarFrame: _key(j['avatar_frame']),
        mapMarker: _key(j['map_marker']),
      );
}

// ───────────────────────────── 地图：补给站 ─────────────────────────────

/// `GET /v1/map/objects` → `supplies[]`.
class MapSupply {
  const MapSupply({
    required this.id,
    required this.name,
    required this.center,
    this.radiusM = 80,
    this.perkTitle = '',
    this.claimedToday = false,
  });
  final int id;
  final String name;
  final LatLng center;
  final double radiusM;
  final String perkTitle;
  final bool claimedToday;

  MapSupply copyWith({bool? claimedToday}) => MapSupply(
      id: id, name: name, center: center, radiusM: radiusM, perkTitle: perkTitle, claimedToday: claimedToday ?? this.claimedToday);

  factory MapSupply.fromJson(Json j) => MapSupply(
        id: ji(j['id']),
        name: js(j['name']),
        center: _ll(j['center']) ?? const LatLng(0, 0),
        radiusM: jd(j['radius_m'], 80),
        perkTitle: js(j['perk_title']),
        claimedToday: jb(j['claimed_today']),
      );
}
