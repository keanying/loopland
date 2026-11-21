import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../claim/geo.dart';
import '../core/providers.dart';
import 'api_client.dart';
import 'community_common.dart';
import 'local_models.dart';

final localApiProvider = Provider<LocalApi>((ref) => LocalApi(ref.watch(apiClientProvider)));

/// Venues, check-in and bookings of docs/api/v2-4-本地生活与商户.md (C-07,
/// C-08, E-03, D-11). Race fees (D-12) are in GatheringApi.
class LocalApi {
  LocalApi(this.c);
  final ApiClient c;

  /// `GET /v1/venues` — by distance when [near] is given.
  Future<CursorPage<Venue>> venues({
    String sport = '',
    LatLng? near,
    int radiusM = 10000,
    bool? bookable,
    String? cursor,
  }) =>
      getCursorPage(c, '/v1/venues', Venue.fromJson, cursor: cursor, query: {
        if (sport.isNotEmpty) 'sport': sport,
        if (near != null) ...{
          'lat': near.lat.toStringAsFixed(6),
          'lng': near.lng.toStringAsFixed(6),
          'radius_m': radiusM,
        },
        if (bookable != null) 'bookable': '$bookable',
      });

  /// With `week_rank` (top 10 this week). [near] adds `distance_m`.
  Future<Venue> venue(int id, {LatLng? near}) async => Venue.fromJson(jm(await c.get('/v1/venues/$id', query: {
        if (near != null) ...{'lat': near.lat.toStringAsFixed(6), 'lng': near.lng.toStringAsFixed(6)},
      })));

  /// [date] `YYYY-MM-DD` (Asia/Shanghai). Past slots are not returned.
  Future<SlotDay> slots(int venueId, String date) async =>
      SlotDay.fromJson(jm(await c.get('/v1/venues/$venueId/slots', query: {'date': date})));

  /// Either [at] (inside `checkin_radius_m`) or [qr] (scanned venue code).
  /// Errors: 400 `checkin_not_allowed`, 409 `already_checked_in`, 429 `rate_limited`.
  Future<CheckinResult> checkin(int venueId, {LatLng? at, String? qr}) async =>
      CheckinResult.fromJson(jm(await c.post('/v1/venues/$venueId/checkin', {
        if (at != null) ...{'lat': at.lat, 'lng': at.lng},
        if (qr != null && qr.isNotEmpty) 'qr': qr,
      })));

  /// Errors: 403 `realname_required` / `minor_not_allowed`, 409 `slot_unavailable`.
  /// [startTime] is sent as the slot's own ISO string (with its offset).
  Future<BookingCreated> createBooking({
    required int venueId,
    required DateTime startTime,
    required int slots,
    required String channel,
    int? meetupId,
  }) async =>
      BookingCreated.fromJson(jm(await c.post('/v1/bookings', {
        'venue_id': venueId,
        'start_time': isoWithOffset(startTime),
        'slots': slots,
        'channel': channel,
        'meetup_id': meetupId,
      })));

  Future<List<Booking>> myBookings({String status = ''}) async =>
      jl(jm(await c.get('/v1/me/bookings', query: {if (status.isNotEmpty) 'status': status}))['items'], Booking.fromJson);

  Future<Booking> booking(int id) async => Booking.fromJson(jm(await c.get('/v1/bookings/$id')));

  /// 409 `cancel_too_late` within 2 hours of the start.
  Future<Booking> cancelBooking(int id) async => Booking.fromJson(jm(await c.post('/v1/bookings/$id/cancel')));
}

/// `2026-11-21T18:00:00+08:00` — the slot times are Asia/Shanghai; the
/// server accepts any offset, but keeping +08:00 matches the contract.
String isoWithOffset(DateTime t) {
  final s = t.toUtc().add(const Duration(hours: 8));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${s.year}-${two(s.month)}-${two(s.day)}T${two(s.hour)}:${two(s.minute)}:${two(s.second)}+08:00';
}

/// `YYYY-MM-DD` of [t] in Asia/Shanghai (the slot API's calendar).
String shanghaiDate(DateTime t) {
  final s = t.toUtc().add(const Duration(hours: 8));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${s.year}-${two(s.month)}-${two(s.day)}';
}

/// Wall clock of [t] in Asia/Shanghai, as a (UTC-flagged) DateTime whose
/// fields read like Beijing time; for labels like「18:00」.
DateTime shanghaiClock(DateTime t) => t.toUtc().add(const Duration(hours: 8));
