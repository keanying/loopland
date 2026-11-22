import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/perks_api.dart';
import '../../api/perks_models.dart';

/// Running brand campaigns (联名活动 tab).
final brandCampaignsProvider =
    FutureProvider.autoDispose<List<BrandCampaign>>((ref) => ref.watch(perksApiProvider).brandCampaigns());

/// My coupons by status: `unused | used | expired | refunded`. The contract's
/// filter knows the first three; `refunded` (bought coupons refunded, V2
/// batch 5) is picked out of the full list (no `status`).
final myCouponsProvider = FutureProvider.autoDispose.family<List<Coupon>, String>((ref, status) async {
  final api = ref.watch(perksApiProvider);
  if (status == 'refunded') return [for (final c in await api.myCoupons('')) if (c.status == 'refunded') c];
  return api.myCoupons(status);
});

/// Coupon wallet tabs.
const couponStatuses = ['unused', 'used', 'expired', 'refunded'];
const couponStatusNames = ['未使用', '已使用', '已过期', '已退款'];
