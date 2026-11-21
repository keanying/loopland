// V2 batch 4「本地生活与商户」— venues, check-in, owners (馆主), slots and
// bookings (docs/api/v2-4-本地生活与商户.md: C-07, C-08, E-03, D-11, D-12).
// Coupons / drops / brand campaigns / energy shop are perks_models.dart.
import '../claim/geo.dart';
import 'community_common.dart';
import 'models.dart' show Json;
import 'perks_models.dart' show Coupon;

/// `sports` keys → Chinese names, in the order the app shows them.
const venueSportNames = {
  'badminton': '羽毛球',
  'pickleball': '匹克球',
  'tennis': '网球',
  'basketball': '篮球',
  'football': '足球',
  'swimming': '游泳',
  'climbing': '攀岩',
  'gym': '健身房',
};

String venueSportName(String key) => venueSportNames[key] ?? key;

/// `{id, name}` — the venue's merchant, or the venue inside a booking.
class IdName {
  const IdName({required this.id, required this.name});
  final int id;
  final String name;
  static IdName? maybe(Object? v) {
    final j = jmn(v);
    return j == null ? null : IdName(id: ji(j['id']), name: js(j['name']));
  }
}

/// `owner`: this week's 馆主.
class VenueOwner {
  const VenueOwner({required this.user, this.points = 0, this.since});
  final UserBrief user;
  final int points;

  /// `YYYY-MM-DD` (week start).
  final String? since;

  static VenueOwner? maybe(Object? v) {
    final j = jmn(v);
    if (j == null || jmn(j['user']) == null) return null;
    return VenueOwner(user: UserBrief.fromJson(jm(j['user'])), points: ji(j['points']), since: jsn(j['since']));
  }
}

class VenueRankEntry {
  const VenueRankEntry({required this.rank, required this.user, required this.points});
  final int rank;
  final UserBrief user;
  final int points;
  factory VenueRankEntry.fromJson(Json j) =>
      VenueRankEntry(rank: ji(j['rank']), user: UserBrief.fromJson(jm(j['user'])), points: ji(j['points']));
}

/// `Venue`. `bookable=false` venues are check-in only (`merchant` may be null).
class Venue {
  const Venue({
    required this.id,
    required this.name,
    this.merchant,
    this.sports = const [],
    this.lat = 0,
    this.lng = 0,
    this.address = '',
    this.district = '',
    this.tags = const [],
    this.coverUrl,
    this.checkinRadiusM = 150,
    this.bookable = false,
    this.priceAmt = 0,
    this.priceUnit = 'hour',
    this.owner,
    this.ownerDiscountRate,
    this.distanceM,
    this.myWeekPoints = 0,
    this.checkedInToday = false,
    this.weekRank = const [],
  });
  final int id;
  final String name;
  final IdName? merchant;
  final List<String> sports;
  final double lat, lng;
  final String address, district;
  final List<String> tags;
  final String? coverUrl;
  final double checkinRadiusM;
  final bool bookable;

  /// Price per [priceUnit] in 分.
  final int priceAmt;
  final String priceUnit;
  final VenueOwner? owner;

  /// 0.8 = 八折 for the owner; null = no discount.
  final double? ownerDiscountRate;
  final double? distanceM;
  final int myWeekPoints;
  final bool checkedInToday;

  /// Only from `GET /v1/venues/{id}` (top 10 this week).
  final List<VenueRankEntry> weekRank;

  String get sportsText => sports.map(venueSportName).join(' · ');
  String get priceUnitText => switch (priceUnit) { 'hour' => '小时', 'session' => '场', _ => priceUnit };

  /// 「八折」, 「85 折」.
  String? get discountText {
    final r = ownerDiscountRate;
    if (r == null || r <= 0 || r >= 1) return null;
    final n = (r * 100).round();
    return n % 10 == 0 ? '${_cn[n ~/ 10]}折' : '$n 折';
  }

  static const _cn = ['', '一', '二', '三', '四', '五', '六', '七', '八', '九'];

  /// Copy with a fresh check-in state (the server returns the updated venue
  /// in the check-in result, but list items may lack `distance_m` there).
  Venue mergeFrom(Venue v) => Venue(
        id: id,
        name: v.name.isEmpty ? name : v.name,
        merchant: v.merchant ?? merchant,
        sports: v.sports.isEmpty ? sports : v.sports,
        lat: v.lat == 0 ? lat : v.lat,
        lng: v.lng == 0 ? lng : v.lng,
        address: v.address.isEmpty ? address : v.address,
        district: v.district.isEmpty ? district : v.district,
        tags: v.tags.isEmpty ? tags : v.tags,
        coverUrl: v.coverUrl ?? coverUrl,
        checkinRadiusM: v.checkinRadiusM,
        bookable: v.bookable,
        priceAmt: v.priceAmt,
        priceUnit: v.priceUnit,
        owner: v.owner,
        ownerDiscountRate: v.ownerDiscountRate,
        distanceM: v.distanceM ?? distanceM,
        myWeekPoints: v.myWeekPoints,
        checkedInToday: v.checkedInToday,
        weekRank: v.weekRank.isEmpty ? weekRank : v.weekRank,
      );

  factory Venue.fromJson(Json j) {
    final c = jm(j['center']);
    return Venue(
      id: ji(j['id']),
      name: js(j['name']),
      merchant: IdName.maybe(j['merchant']),
      sports: j['sports'] is List ? [for (final s in j['sports'] as List) if (s != null) '$s'] : const [],
      lat: jd(c['lat']),
      lng: jd(c['lng']),
      address: js(j['address']),
      district: js(j['district']),
      tags: j['tags'] is List ? [for (final s in j['tags'] as List) if (s != null) '$s'] : const [],
      coverUrl: jsn(j['cover_url']),
      checkinRadiusM: jd(j['checkin_radius_m'], 150),
      bookable: jb(j['bookable']),
      priceAmt: ji(j['price_amt']),
      priceUnit: js(j['price_unit'], 'hour'),
      owner: VenueOwner.maybe(j['owner']),
      ownerDiscountRate: jdn(j['owner_discount_rate']),
      distanceM: jdn(j['distance_m']),
      myWeekPoints: ji(j['my_week_points']),
      checkedInToday: jb(j['checked_in_today']),
      weekRank: jl(j['week_rank'], VenueRankEntry.fromJson),
    );
  }
}

/// `BookingSlot`. `ownerPriceAmt` is only set when I am this week's 馆主.
class BookingSlot {
  const BookingSlot({required this.start, required this.end, this.priceAmt = 0, this.ownerPriceAmt, this.available = true});
  final DateTime start, end;
  final int priceAmt;
  final int? ownerPriceAmt;
  final bool available;

  int get payAmt => ownerPriceAmt ?? priceAmt;

  /// The raw `start_time` string is sent back unchanged in `POST /v1/bookings`.
  static BookingSlot? maybe(Json j) {
    final s = jdt(j['start_time']), e = jdt(j['end_time']);
    if (s == null) return null;
    return BookingSlot(
      start: s,
      end: e ?? s.add(const Duration(hours: 1)),
      priceAmt: ji(j['price_amt']),
      ownerPriceAmt: jin(j['owner_price_amt']),
      available: jb(j['available'], true),
    );
  }
}

/// `GET /v1/venues/{id}/slots?date=`.
class SlotDay {
  const SlotDay({required this.date, this.items = const []});
  final String date;
  final List<BookingSlot> items;
  factory SlotDay.fromJson(Json j) => SlotDay(
        date: js(j['date']),
        items: [
          if (j['items'] is List)
            for (final e in j['items'] as List)
              if (e is Map) ?BookingSlot.maybe(e.cast<String, dynamic>()),
        ],
      );
}

/// A run of consecutive slots the user picked (1–[maxSlots]).
class SlotSelection {
  const SlotSelection(this.slots);
  final List<BookingSlot> slots;

  bool get isEmpty => slots.isEmpty;
  int get count => slots.length;
  DateTime get start => slots.first.start;
  DateTime get end => slots.last.end;
  int get amount => slots.fold(0, (s, x) => s + x.payAmt);
  int get originalAmount => slots.fold(0, (s, x) => s + x.priceAmt);
  bool get discounted => amount < originalAmount;

  /// Tapping [tapped] in [all] (sorted by start): extends a contiguous run at
  /// either end, shrinks it from an end, or starts a new run. Unavailable
  /// slots and gaps break runs; never more than [max] slots.
  static SlotSelection toggle(SlotSelection cur, List<BookingSlot> all, BookingSlot tapped, {int max = 4}) {
    if (!tapped.available) return cur;
    final sel = cur.slots;
    final idx = all.indexWhere((s) => s.start == tapped.start);
    if (idx < 0) return cur;
    if (sel.isEmpty) return SlotSelection([tapped]);
    final first = all.indexWhere((s) => s.start == sel.first.start);
    final last = all.indexWhere((s) => s.start == sel.last.start);
    bool adjacent(BookingSlot a, BookingSlot b) => !a.end.isBefore(b.start) && !a.end.isAfter(b.start);
    if (idx == first && idx == last) return const SlotSelection([]);
    if (idx == first) return SlotSelection(sel.sublist(1));
    if (idx == last) return SlotSelection(sel.sublist(0, sel.length - 1));
    if (idx > first && idx < last) return SlotSelection([tapped]);
    if (idx == last + 1 && adjacent(all[last], tapped) && sel.length < max) return SlotSelection([...sel, tapped]);
    if (idx == first - 1 && adjacent(tapped, all[first]) && sel.length < max) return SlotSelection([tapped, ...sel]);
    return SlotSelection([tapped]);
  }
}

const bookingStatusNames = {
  'pending_pay': '待支付',
  'paid': '已支付',
  'cancelled': '已取消',
  'refunding': '退款中',
  'refunded': '已退款',
  'completed': '已完成',
  'expired': '已过期',
};

/// `Booking`.
class Booking {
  const Booking({
    required this.id,
    this.bookingNo = '',
    this.venue,
    this.start,
    this.end,
    this.courtQty = 1,
    this.amountAmt = 0,
    this.originalAmt = 0,
    this.discountType = 'none',
    this.status = 'pending_pay',
    this.meetupId,
    this.orderNo,
    this.channel,
    this.cancelDeadline,
    this.createdAt,
  });
  final int id;
  final String bookingNo;
  final IdName? venue;
  final DateTime? start, end;
  final int courtQty;
  final int amountAmt, originalAmt;

  /// `owner | none`.
  final String discountType;

  /// `pending_pay | paid | cancelled | refunding | refunded | completed | expired`.
  final String status;
  final int? meetupId;
  final String? orderNo, channel;
  final DateTime? cancelDeadline, createdAt;

  String get statusName => bookingStatusNames[status] ?? status;
  bool get isPendingPay => status == 'pending_pay';
  bool get isPaid => status == 'paid';
  bool get isActive => status == 'pending_pay' || status == 'paid';

  /// Free cancellation is possible (server is the judge: `cancel_too_late`).
  bool canCancelAt(DateTime now) =>
      (status == 'paid' || status == 'pending_pay') && (cancelDeadline == null || now.isBefore(cancelDeadline!));

  factory Booking.fromJson(Json j) {
    final pay = jm(j['pay']);
    return Booking(
      id: ji(j['id']),
      bookingNo: js(j['booking_no']),
      venue: IdName.maybe(j['venue']),
      start: jdt(j['start_time']),
      end: jdt(j['end_time']),
      courtQty: ji(j['court_qty'], 1),
      amountAmt: ji(j['amount_amt']),
      originalAmt: ji(j['original_amt']),
      discountType: js(j['discount_type'], 'none'),
      status: js(j['status'], 'pending_pay'),
      meetupId: jin(j['meetup_id']),
      orderNo: jsn(pay['order_no']),
      channel: jsn(pay['channel']),
      cancelDeadline: jdt(j['cancel_deadline']),
      createdAt: jdt(j['created_at']),
    );
  }
}

/// `POST /v1/bookings` → `{"booking", "pay_params"}`.
class BookingCreated {
  const BookingCreated({required this.booking, this.payParams = const {}});
  final Booking booking;
  final Json payParams;
  factory BookingCreated.fromJson(Json j) =>
      BookingCreated(booking: Booking.fromJson(jm(j['booking'])), payParams: jm(j['pay_params']));
}

/// `POST /v1/venues/{id}/checkin` result.
class CheckinResult {
  const CheckinResult({this.activityId, this.energy = 0, this.points = 0, this.weekPoints = 0, this.coupon, this.venue});
  final int? activityId;
  final int energy, points, weekPoints;
  /// Stronghold (据点) coupon, shown with a link to the wallet `/me/coupons`.
  final Coupon? coupon;
  final Venue? venue;
  factory CheckinResult.fromJson(Json j) => CheckinResult(
        activityId: jin(j['activity_id']),
        energy: ji(j['energy']),
        points: ji(j['points']),
        weekPoints: ji(j['week_points']),
        coupon: Coupon.maybe(j['coupon']),
        venue: jmn(j['venue']) == null ? null : Venue.fromJson(jm(j['venue'])),
      );
}

/// The booked venue / time shown on a meetup (D-11). The contract does not
/// name the field on `Meetup`; the app reads `booking` (a Booking or a
/// `{venue, start_time, end_time, status}` subset) when the server sends it,
/// and otherwise looks the creator's own booking up by `meetup_id`.
class MeetupBooking {
  const MeetupBooking({this.venue, this.start, this.end, this.status});
  final IdName? venue;
  final DateTime? start, end;
  final String? status;
  static MeetupBooking? maybe(Object? v) {
    final j = jmn(v);
    if (j == null) return null;
    return MeetupBooking(
        venue: IdName.maybe(j['venue']), start: jdt(j['start_time']), end: jdt(j['end_time']), status: jsn(j['status']));
  }

  factory MeetupBooking.of(Booking b) => MeetupBooking(venue: b.venue, start: b.start, end: b.end, status: b.status);
}

// ── 场馆二维码 ──

/// The venue code inside a scanned QR: either the raw `LPV.<venue_id>.<sig>`
/// or the universal link `https://<domain>/v/<content>` (any host; the
/// server verifies the signature). Returns null for anything else.
VenueQr? parseVenueQr(String raw) {
  var s = raw.trim();
  final u = Uri.tryParse(s);
  if (u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty) {
    final seg = u.pathSegments;
    final i = seg.indexOf('v');
    if (i < 0 || i + 1 >= seg.length) return null;
    s = Uri.decodeComponent(seg[i + 1]);
  }
  final m = RegExp(r'^LPV\.(\d+)\.(\S+)$').firstMatch(s);
  if (m == null) return null;
  final id = int.tryParse(m.group(1)!);
  return id == null || id <= 0 ? null : VenueQr(venueId: id, payload: s);
}

class VenueQr {
  const VenueQr({required this.venueId, required this.payload});
  final int venueId;

  /// Sent as `qr` unchanged.
  final String payload;
}

/// `GET /v1/map/objects` → `venues[]` (据点): drawn with the 馆主's avatar.
class MapVenue {
  const MapVenue({
    required this.id,
    required this.name,
    required this.center,
    this.sports = const [],
    this.ownerAvatarUrl,
    this.ownerNickname,
    this.bookable = false,
  });
  final int id;
  final String name;
  final LatLng center;
  final List<String> sports;
  final String? ownerAvatarUrl, ownerNickname;
  final bool bookable;

  bool get hasOwner => ownerNickname != null || ownerAvatarUrl != null;

  factory MapVenue.fromJson(Json j) {
    final c = jm(j['center']);
    return MapVenue(
      id: ji(j['id']),
      name: js(j['name']),
      center: LatLng(jd(c['lat']), jd(c['lng'])),
      sports: j['sports'] is List ? [for (final s in j['sports'] as List) if (s != null) '$s'] : const [],
      ownerAvatarUrl: jsn(j['owner_avatar_url']),
      ownerNickname: jsn(j['owner_nickname']),
      bookable: jb(j['bookable']),
    );
  }
}
