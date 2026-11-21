import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/local_api.dart';
import '../../api/local_models.dart';

/// `booking.max_slots` (玩法配置); the contract allows 1–4 consecutive slots.
const maxBookingSlots = 4;

/// `booking.free_cancel_hours`.
const freeCancelHours = 2;

final myBookingsProvider =
    FutureProvider.autoDispose.family<List<Booking>, String>((ref, status) => ref.watch(localApiProvider).myBookings(status: status));

final bookingProvider = FutureProvider.autoDispose.family<Booking, int>((ref, id) => ref.watch(localApiProvider).booking(id));

final venueProvider = FutureProvider.autoDispose.family<Venue, int>((ref, id) => ref.watch(localApiProvider).venue(id));

/// Slots of a venue on a `YYYY-MM-DD` day.
final slotsProvider = FutureProvider.autoDispose.family<SlotDay, (int, String)>(
    (ref, k) => ref.watch(localApiProvider).slots(k.$1, k.$2));
