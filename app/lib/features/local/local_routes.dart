import 'package:go_router/go_router.dart';

import 'local_page.dart';
import 'my_bookings_page.dart';
import 'product_orders_pages.dart';
import 'product_pages.dart';
import 'venue_pages.dart';

/// V2 本地生活 · 订场 / 场馆 / 签到（docs/api/v2-4-本地生活与商户.md）and
/// 团购 / 套餐、商品订单、官方活动（docs/api/v2-5-商户商品与开放平台.md）.
/// `/v/<content>` is the venue QR's universal link
/// (`https://<links.universal_link_domain>/v/LPV.<id>.<签名>`).
List<RouteBase> localRoutes() {
  int id(GoRouterState s) => int.tryParse(s.pathParameters['id'] ?? '') ?? 0;
  return [
    GoRoute(
      path: '/local',
      builder: (_, s) => LocalPage(tab: s.uri.queryParameters['tab'] ?? 'booking', sport: s.uri.queryParameters['sport'] ?? ''),
    ),
    GoRoute(path: '/venues/:id', builder: (_, s) => VenueDetailPage(venueId: id(s))),
    GoRoute(path: '/me/bookings', builder: (_, _) => const MyBookingsPage()),
    GoRoute(path: '/me/orders', builder: (_, s) => MyBookingsPage(initialKind: s.uri.queryParameters['type'] ?? 'booking')),
    GoRoute(path: '/me/product-orders/:id', builder: (_, s) => ProductOrderDetailPage(orderId: id(s))),
    // V2 batch 5 · 团购 / 套餐 and 官方活动
    GoRoute(path: '/products/:id', builder: (_, s) => ProductDetailPage(productId: id(s))),
    GoRoute(
      path: '/merchants/:id',
      builder: (_, s) => MerchantProductsPage(merchantId: id(s), name: s.extra is String ? s.extra! as String : null),
    ),
    GoRoute(path: '/promotions', builder: (_, _) => const PromotionsPage()),
    GoRoute(path: '/promotions/:id', builder: (_, s) => PromotionDetailPage(promotionId: id(s))),
    GoRoute(path: '/me/bookings/:id', builder: (_, s) => BookingDetailPage(bookingId: id(s))),
    GoRoute(path: '/v/:payload', builder: (_, s) => VenueLinkPage(payload: s.pathParameters['payload'] ?? '')),
  ];
}
