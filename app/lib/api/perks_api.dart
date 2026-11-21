// V2 batch 4「本地生活与商户」· 联名权益 / 卡券包 / 能量商城 endpoints
// (docs/api/v2-4-本地生活与商户.md). 订场 / 场馆 endpoints live elsewhere.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../claim/geo.dart';
import '../core/providers.dart';
import 'api_client.dart';
import 'community_common.dart';
import 'perks_models.dart';

class PerksApi {
  PerksApi(this.c);
  final ApiClient c;

  // ── 联名活动（M-26，App 只读进行中的） ──
  Future<List<BrandCampaign>> brandCampaigns() async =>
      jl(jm(await c.get('/v1/brand-campaigns'))['items'], BrandCampaign.fromJson);

  // ── 卡券包（E-04） ──
  /// status: `unused | used | expired`.
  Future<List<Coupon>> myCoupons(String status) async =>
      jl(jm(await c.get('/v1/me/coupons', query: {'status': status}))['items'], Coupon.fromJson);

  /// The QR payload shown at the store; valid for `expires_in_sec` (60 s).
  Future<CouponQr> couponQr(int id) async => CouponQr.fromJson(jm(await c.get('/v1/coupons/$id/qr')));

  /// 补给站手动领取. Errors: 400 `too_far`, 409 `already_claimed`, 409 `sold_out`.
  Future<Coupon> claimDrop(int dropId, LatLng at) async =>
      Coupon.fromJson(jm(await c.post('/v1/drops/$dropId/claim', at.toJson())));

  // ── 能量商城（E-05） ──
  /// type: `territory_skin | avatar_frame | map_marker`, null = all.
  Future<ShopCatalog> shopItems({String? type}) async => ShopCatalog.fromJson(jm(await c.get('/v1/shop/items', query: {
        if (type != null && type.isNotEmpty) 'type': type,
      })));

  /// Errors: 409 `not_enough_energy`, 409 `already_owned`.
  Future<ShopBuyResult> buy(String key) async => ShopBuyResult.fromJson(jm(await c.post('/v1/shop/items/$key/buy')));

  Future<ShopItem> equip(String key) async => ShopItem.fromJson(jm(await c.post('/v1/shop/items/$key/equip')));

  Future<ShopItem> unequip(String key) async => ShopItem.fromJson(jm(await c.delete('/v1/shop/items/$key/equip')));
}

final perksApiProvider = Provider<PerksApi>((ref) => PerksApi(ref.watch(apiClientProvider)));
