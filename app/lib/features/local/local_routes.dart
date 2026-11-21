import 'package:go_router/go_router.dart';

import 'local_page.dart';
import 'my_bookings_page.dart';
import 'venue_pages.dart';

/// V2 本地生活 · 订场 / 场馆 / 签到（docs/api/v2-4-本地生活与商户.md）.
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
    GoRoute(path: '/me/bookings/:id', builder: (_, s) => BookingDetailPage(bookingId: id(s))),
    GoRoute(path: '/v/:payload', builder: (_, s) => VenueLinkPage(payload: s.pathParameters['payload'] ?? '')),
  ];
}
