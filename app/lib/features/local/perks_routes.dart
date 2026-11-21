import 'package:go_router/go_router.dart';

import '../../api/perks_models.dart';
import 'coupons_pages.dart';

/// V2 本地生活 · 卡券包 (E-04). The /local page itself (订场 / 联名活动 /
/// 能量商城 tabs) is registered with the booking routes.
List<RouteBase> perksRoutes() => [
      GoRoute(
        path: '/me/coupons',
        builder: (_, s) => CouponsPage(initialStatus: s.uri.queryParameters['status'] ?? 'unused'),
      ),
      GoRoute(
        path: '/me/coupons/:id',
        builder: (_, s) => CouponDetailPage(
          couponId: int.tryParse(s.pathParameters['id'] ?? '') ?? 0,
          coupon: s.extra is Coupon ? s.extra! as Coupon : null,
        ),
      ),
    ];
