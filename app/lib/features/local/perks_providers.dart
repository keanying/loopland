import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/perks_api.dart';
import '../../api/perks_models.dart';

/// Running brand campaigns (联名活动 tab).
final brandCampaignsProvider =
    FutureProvider.autoDispose<List<BrandCampaign>>((ref) => ref.watch(perksApiProvider).brandCampaigns());

/// My coupons by status: `unused | used | expired`.
final myCouponsProvider =
    FutureProvider.autoDispose.family<List<Coupon>, String>((ref, status) => ref.watch(perksApiProvider).myCoupons(status));

/// Coupon wallet tabs.
const couponStatuses = ['unused', 'used', 'expired'];
const couponStatusNames = ['未使用', '已使用', '已过期'];
