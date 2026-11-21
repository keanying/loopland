// V2 batch 2「社区」— the gatherings & messages side (docs/api/v2-2-社区.md):
// community home, inbox summary, conversations / messages, meetups (组局),
// rallies (集结跑), races (赛事) and crew invites. Media uploads
// (MediaUpload) are in community_models.dart.
// Shared pieces (UserBrief, CursorPage, JSON helpers) are in
// community_common.dart.
import '../claim/geo.dart';
import 'community_common.dart';
import 'local_models.dart' show MeetupBooking;
import 'models.dart';

/// `{name, lat, lng}` (GCJ-02).
class Place {
  const Place({required this.name, required this.lat, required this.lng});
  final String name;
  final double lat, lng;

  LatLng get latLng => LatLng(lat, lng);

  static Place? maybe(Object? v) {
    final j = jmn(v);
    if (j == null) return null;
    return Place(name: js(j['name']), lat: jd(j['lat']), lng: jd(j['lng']));
  }

  Json toJson() => {'name': name, 'lat': lat, 'lng': lng};
}

// ───────────────────────────── 私信与群聊 ─────────────────────────────

/// `Message`. `type`: `text | image | post | system`; system messages have
/// no sender.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    this.sender,
    this.type = 'text',
    this.content = '',
    this.payload = const {},
    this.createdAt,
  });
  final int id;
  final int conversationId;
  final UserBrief? sender;
  final String type;
  final String content;
  final Json payload;
  final DateTime? createdAt;

  bool get isSystem => type == 'system' || sender == null;
  String? get imageUrl => jsn(payload['url']);
  int? get imageWidth => jin(payload['width']);
  int? get imageHeight => jin(payload['height']);
  int? get postId => jin(payload['post_id']);

  /// One-line preview for conversation lists.
  String get preview => switch (type) {
        'image' => '[图片]',
        'post' => '[分享动态]',
        _ => content,
      };

  factory ChatMessage.fromJson(Json j) => ChatMessage(
        id: ji(j['id']),
        conversationId: ji(j['conversation_id']),
        sender: UserBrief.maybe(j['sender']),
        type: js(j['type'], 'text'),
        content: js(j['content']),
        payload: jm(j['payload']),
        createdAt: jdt(j['created_at']),
      );
}

/// `Conversation`. `type`: `direct | group`; `refType`: `meetup | rally`.
class Conversation {
  const Conversation({
    required this.id,
    this.type = 'direct',
    this.title = '',
    this.avatarUrl,
    this.peer,
    this.refType,
    this.refId,
    this.lastMessage,
    this.unreadCount = 0,
    this.muted = false,
    this.peerReadMessageId = 0,
    this.updatedAt,
  });
  final int id;
  final String type;
  final String title;
  final String? avatarUrl;
  final UserBrief? peer;
  final String? refType;
  final int? refId;
  final ChatMessage? lastMessage;
  final int unreadCount;
  final bool muted;

  /// 私信里对方已读到的消息 id（群聊为 0）。
  final int peerReadMessageId;
  final DateTime? updatedAt;

  bool get isGroup => type == 'group';
  String get displayTitle => title.isNotEmpty ? title : (peer?.nickname ?? (isGroup ? '群聊' : '私信'));

  Conversation copyWith({ChatMessage? lastMessage, int? unreadCount, bool? muted, DateTime? updatedAt}) => Conversation(
        id: id,
        type: type,
        title: title,
        avatarUrl: avatarUrl,
        peer: peer,
        refType: refType,
        refId: refId,
        lastMessage: lastMessage ?? this.lastMessage,
        unreadCount: unreadCount ?? this.unreadCount,
        muted: muted ?? this.muted,
        peerReadMessageId: peerReadMessageId,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  factory Conversation.fromJson(Json j) {
    final ref = jmn(j['ref']);
    final last = jmn(j['last_message']);
    return Conversation(
      id: ji(j['id']),
      type: js(j['type'], 'direct'),
      title: js(j['title']),
      avatarUrl: jsn(j['avatar_url']),
      peer: UserBrief.maybe(j['peer']),
      refType: ref == null ? null : jsn(ref['type']),
      refId: ref == null ? null : jin(ref['id']),
      lastMessage: last == null ? null : ChatMessage.fromJson(last),
      unreadCount: ji(j['unread_count']),
      peerReadMessageId: ji(j['peer_read_message_id']),
      muted: jb(j['muted']),
      updatedAt: jdt(j['updated_at']),
    );
  }
}

/// WebSocket `chat_message` / `conversation_read` (parsed from the raw
/// event so the shared RealtimeEvent type stays untouched).
sealed class ChatEvent {
  const ChatEvent();

  static ChatEvent? parse(Json j) => switch (js(j['type'])) {
        'chat_message' => jmn(j['message']) == null ? null : ChatMessageEvent(ChatMessage.fromJson(jm(j['message']))),
        'conversation_read' => ConversationReadEvent(
            conversationId: ji(j['conversation_id']), userId: ji(j['user_id']), messageId: ji(j['message_id'])),
        _ => null,
      };
}

class ChatMessageEvent extends ChatEvent {
  const ChatMessageEvent(this.message);
  final ChatMessage message;
}

class ConversationReadEvent extends ChatEvent {
  const ConversationReadEvent({required this.conversationId, required this.userId, required this.messageId});
  final int conversationId, userId, messageId;
}

// ───────────────────────────── 组局 ─────────────────────────────

const meetupTypeNames = {'run': '约跑', 'ball': '约球', 'ride': '约骑'};

/// `Meetup`. `status`: `open | full | cancelled | ended`.
class Meetup {
  const Meetup({
    required this.id,
    this.type = 'run',
    this.title = '',
    this.description = '',
    this.startTime,
    this.endTime,
    this.place,
    this.district = '',
    this.capacity = 0,
    this.joinedCount = 0,
    this.requirement = '',
    this.creator,
    this.status = 'open',
    this.reviewStatus = 'approved',
    this.joined = false,
    this.conversationId,
    this.distanceM,
    this.createdAt,
    this.members = const [],
    this.booking,
  });
  final int id;
  final String type;
  final String title, description;
  final DateTime? startTime, endTime;
  final Place? place;
  final String district;
  final int capacity, joinedCount;
  final String requirement;
  final UserBrief? creator;
  final String status;
  final String reviewStatus;
  final bool joined;
  final int? conversationId;
  final double? distanceM;
  final DateTime? createdAt;

  /// Only from `GET /v1/meetups/{id}`.
  final List<UserBrief> members;

  /// D-11: the venue booked for this meetup (field name not in the contract;
  /// read from `booking` when present).
  final MeetupBooking? booking;

  String get typeName => meetupTypeNames[type] ?? type;
  bool get isOpen => status == 'open';
  bool get isPending => reviewStatus == 'pending';
  bool get isRejected => reviewStatus == 'rejected';
  bool isCreator(int? userId) => userId != null && creator?.id == userId;

  /// Keeps the list's `distance_m` when a join / leave response (not a
  /// location query) comes back without it.
  Meetup withDistance(double? d) => distanceM != null || d == null
      ? this
      : Meetup(
          id: id,
          type: type,
          title: title,
          description: description,
          startTime: startTime,
          endTime: endTime,
          place: place,
          district: district,
          capacity: capacity,
          joinedCount: joinedCount,
          requirement: requirement,
          creator: creator,
          status: status,
          reviewStatus: reviewStatus,
          joined: joined,
          conversationId: conversationId,
          distanceM: d,
          createdAt: createdAt,
          members: members,
          booking: booking,
        );

  factory Meetup.fromJson(Json j) => Meetup(
        id: ji(j['id']),
        type: js(j['type'], 'run'),
        title: js(j['title']),
        description: js(j['description']),
        startTime: jdt(j['start_time']),
        endTime: jdt(j['end_time']),
        place: Place.maybe(j['place']),
        district: js(j['district']),
        capacity: ji(j['capacity']),
        joinedCount: ji(j['joined_count']),
        requirement: js(j['requirement']),
        creator: UserBrief.maybe(j['creator']),
        status: js(j['status'], 'open'),
        reviewStatus: js(j['review_status'], 'approved'),
        joined: jb(j['joined']),
        conversationId: jin(j['conversation_id']),
        distanceM: jdn(j['distance_m']),
        createdAt: jdt(j['created_at']),
        members: jl(j['members'], UserBrief.fromJson),
        booking: MeetupBooking.maybe(j['booking']),
      );
}

/// Body of `POST /v1/meetups`.
class MeetupDraft {
  const MeetupDraft({
    required this.type,
    required this.title,
    this.description = '',
    required this.startTime,
    required this.endTime,
    required this.place,
    required this.capacity,
    this.requirement = '',
  });
  final String type, title, description, requirement;
  final DateTime startTime, endTime;
  final Place place;
  final int capacity;

  /// Client-side check of the contract limits; null when valid.
  String? validate({DateTime? now}) {
    final n = now ?? DateTime.now();
    if (title.trim().isEmpty) return '请填写标题';
    if (title.trim().runes.length > 30) return '标题最多 30 个字';
    if (description.runes.length > 300) return '说明最多 300 个字';
    if (place.name.trim().isEmpty) return '请选择地点并填写地点名称';
    if (startTime.isBefore(n.add(const Duration(hours: 1)))) return '开始时间需要在 1 小时之后';
    if (startTime.isAfter(n.add(const Duration(days: 30)))) return '开始时间需要在 30 天以内';
    if (!endTime.isAfter(startTime)) return '结束时间需要晚于开始时间';
    if (endTime.difference(startTime) > const Duration(hours: 12)) return '时长最多 12 小时';
    if (capacity < 2 || capacity > 50) return '人数需要在 2–50 之间';
    return null;
  }

  Json toJson() => {
        'type': type,
        'title': title.trim(),
        'description': description.trim(),
        'start_time': startTime.toUtc().toIso8601String(),
        'end_time': endTime.toUtc().toIso8601String(),
        'place': place.toJson(),
        'capacity': capacity,
        'requirement': requirement.trim(),
      };
}

// ───────────────────────────── 集结跑 ─────────────────────────────

/// `Rally`. `status`: `open | cancelled | ended`.
class Rally {
  const Rally({
    required this.id,
    this.crew,
    this.creator,
    this.title = '',
    this.startTime,
    this.place,
    this.distanceGoalM = 0,
    this.status = 'open',
    this.joinedCount = 0,
    this.checkedInCount = 0,
    this.joined = false,
    this.checkedIn = false,
    this.bonusActive = false,
    this.conversationId,
    this.createdAt,
  });
  final int id;
  final CrewRef? crew;
  final UserBrief? creator;
  final String title;
  final DateTime? startTime;
  final Place? place;
  final double distanceGoalM;
  final String status;
  final int joinedCount, checkedInCount;
  final bool joined, checkedIn, bonusActive;
  final int? conversationId;
  final DateTime? createdAt;

  bool get isOpen => status == 'open';

  factory Rally.fromJson(Json j) => Rally(
        id: ji(j['id']),
        crew: jmn(j['crew']) == null ? null : CrewRef.fromJson(jm(j['crew'])),
        creator: UserBrief.maybe(j['creator']),
        title: js(j['title']),
        startTime: jdt(j['start_time']),
        place: Place.maybe(j['place']),
        distanceGoalM: jd(j['distance_goal_m']),
        status: js(j['status'], 'open'),
        joinedCount: ji(j['joined_count']),
        checkedInCount: ji(j['checked_in_count']),
        joined: jb(j['joined']),
        checkedIn: jb(j['checked_in']),
        bonusActive: jb(j['bonus_active']),
        conversationId: jin(j['conversation_id']),
        createdAt: jdt(j['created_at']),
      );
}

// ───────────────────────────── 赛事 ─────────────────────────────

class RaceMedal {
  const RaceMedal({required this.key, required this.name, this.imageUrl});
  final String key, name;
  final String? imageUrl;
  static RaceMedal? maybe(Object? v) {
    final j = jmn(v);
    return j == null ? null : RaceMedal(key: js(j['key']), name: js(j['name']), imageUrl: jsn(j['image_url']));
  }
}

/// `my_entry`. `status`: `pending_pay | signed | finished | dnf`
/// (`pending_pay`: paid race, waiting for the payment; cancelled after 15 min).
class RaceEntry {
  const RaceEntry({required this.status, this.resultSec, this.finishedAt, this.rank, this.orderNo});
  final String status;
  final int? resultSec;
  final DateTime? finishedAt;
  final int? rank;

  /// The fee order (not in the contract; read when the server sends it).
  final String? orderNo;
  bool get finished => status == 'finished';
  bool get pendingPay => status == 'pending_pay';
  static RaceEntry? maybe(Object? v) {
    final j = jmn(v);
    return j == null
        ? null
        : RaceEntry(
            status: js(j['status'], 'signed'),
            resultSec: jin(j['result_sec']),
            finishedAt: jdt(j['finished_at']),
            rank: jin(j['rank']),
            orderNo: jsn(j['order_no']) ?? jsn(jm(j['order'])['order_no']));
  }
}

class RaceRankEntry {
  const RaceRankEntry({required this.rank, required this.user, required this.resultSec});
  final int rank;
  final UserBrief user;
  final int resultSec;
  factory RaceRankEntry.fromJson(Json j) =>
      RaceRankEntry(rank: ji(j['rank']), user: UserBrief.fromJson(jm(j['user'])), resultSec: ji(j['result_sec']));
}

const raceStatusNames = {
  'signup': '报名中',
  'upcoming': '即将开始',
  'running': '进行中',
  'finished': '已结束',
  'cancelled': '已取消',
};

/// `Race`. `type`: `online | offline`; `status`: `upcoming | signup |
/// running | finished | cancelled`.
class Race {
  const Race({
    required this.id,
    this.type = 'online',
    this.title = '',
    this.coverUrl,
    this.description = '',
    this.sport = 'run',
    this.distanceM = 0,
    this.startTime,
    this.endTime,
    this.signupEndTime,
    this.place,
    this.capacity = 0,
    this.signedCount = 0,
    this.requiresWearable = false,
    this.medal,
    this.status = 'signup',
    this.myEntry,
    this.leaderboard = const [],
    this.feeAmt = 0,
  });
  final int id;
  final String type, title;
  final String? coverUrl;
  final String description, sport;
  final double distanceM;
  final DateTime? startTime, endTime, signupEndTime;
  final Place? place;
  final int capacity, signedCount;
  final bool requiresWearable;
  final RaceMedal? medal;
  final String status;
  final RaceEntry? myEntry;

  /// Only from `GET /v1/races/{id}` (top 50).
  final List<RaceRankEntry> leaderboard;

  /// D-12 报名费（分）; 0 = free.
  final int feeAmt;
  bool get isPaid => feeAmt > 0;

  bool get isOnline => type == 'online';
  bool get signedUp => myEntry != null;
  String get statusName => raceStatusNames[status] ?? status;

  /// Signup is possible before `signup_end_time` and while not full. The
  /// server reports `running` (not `signup`) once the race window opened,
  /// even when the signup deadline is still ahead.
  bool canSignupAt(DateTime now) =>
      myEntry == null &&
      (capacity <= 0 || signedCount < capacity) &&
      (status == 'signup' || (status == 'running' && (signupEndTime?.isAfter(now) ?? false)));

  bool get canSignup => canSignupAt(DateTime.now());

  /// Cancel before the start (afterwards 409 `race_started`); a pending fee
  /// order can be dropped too.
  bool get canCancel =>
      (myEntry?.status == 'signed' || myEntry?.status == 'pending_pay') && (status == 'signup' || status == 'upcoming');

  factory Race.fromJson(Json j) => Race(
        id: ji(j['id']),
        type: js(j['type'], 'online'),
        title: js(j['title']),
        coverUrl: jsn(j['cover_url']),
        description: js(j['description']),
        sport: js(j['sport'], 'run'),
        distanceM: jd(j['distance_m']),
        startTime: jdt(j['start_time']),
        endTime: jdt(j['end_time']),
        signupEndTime: jdt(j['signup_end_time']),
        place: Place.maybe(j['place']),
        capacity: ji(j['capacity']),
        signedCount: ji(j['signed_count']),
        requiresWearable: jb(j['requires_wearable']),
        medal: RaceMedal.maybe(j['medal']),
        status: js(j['status'], 'signup'),
        myEntry: RaceEntry.maybe(j['my_entry']),
        leaderboard: jl(j['leaderboard'], RaceRankEntry.fromJson),
        feeAmt: ji(j['fee_amt']),
      );
}

/// `POST /v1/races/{id}/signup` of a paid race: `{"race", "pay_params"}`.
/// The contract has no order number in it; the app reads `order.order_no`,
/// `order_no` or `my_entry.order_no` when present (needed to poll the order
/// and for `mock` payment).
class RaceSignup {
  const RaceSignup({required this.race, this.payParams = const {}, this.orderNo});
  final Race race;
  final Json payParams;
  final String? orderNo;
  factory RaceSignup.fromJson(Json j) {
    final race = Race.fromJson(jmn(j['race']) ?? j);
    return RaceSignup(
      race: race,
      payParams: jm(j['pay_params']),
      orderNo: jsn(jm(j['order'])['order_no']) ?? jsn(j['order_no']) ?? jsn(jm(j['pay_params'])['order_no']) ?? race.myEntry?.orderNo,
    );
  }
}

// ───────────────────────────── 消息与社区首页 ─────────────────────────────

/// `GET /v1/inbox/summary`: unread per category; `chat` = 私信 + 群聊.
class InboxSummary {
  const InboxSummary({this.interaction = 0, this.territory = 0, this.monster = 0, this.system = 0, this.chat = 0});
  final int interaction, territory, monster, system, chat;

  int get notifications => interaction + territory + monster + system;
  int get total => notifications + chat;

  int of(String category) => switch (category) {
        'interaction' => interaction,
        'territory' => territory,
        'monster' => monster,
        'system' => system,
        'chat' => chat,
        _ => notifications,
      };

  factory InboxSummary.fromJson(Json j) => InboxSummary(
        interaction: ji(j['interaction']),
        territory: ji(j['territory']),
        monster: ji(j['monster']),
        system: ji(j['system']),
        chat: ji(j['chat']),
      );
}

/// `crew` block of the community home.
class HomeCrew {
  const HomeCrew({required this.id, required this.name, this.avatarUrl, this.memberCount = 0, this.weekAreaM2 = 0, this.myRank});
  final int id;
  final String name;
  final String? avatarUrl;
  final int memberCount;
  final double weekAreaM2;
  final int? myRank;
  static HomeCrew? maybe(Object? v) {
    final j = jmn(v);
    return j == null
        ? null
        : HomeCrew(
            id: ji(j['id']),
            name: js(j['name']),
            avatarUrl: jsn(j['avatar_url']),
            memberCount: ji(j['member_count']),
            weekAreaM2: jd(j['week_area_m2']),
            myRank: jin(j['my_rank']),
          );
  }
}

/// `GET /v1/community/home`.
class CommunityHome {
  const CommunityHome({
    this.crew,
    this.unreadInteraction = 0,
    this.unreadChat = 0,
    this.rallies = const [],
    this.meetups = const [],
    this.races = const [],
  });
  final HomeCrew? crew;
  final int unreadInteraction, unreadChat;
  final List<Rally> rallies;
  final List<Meetup> meetups;
  final List<Race> races;

  factory CommunityHome.fromJson(Json j) {
    final u = jm(j['unread']);
    return CommunityHome(
      crew: HomeCrew.maybe(j['crew']),
      unreadInteraction: ji(u['interaction']),
      unreadChat: ji(u['chat']),
      rallies: jl(j['rallies'], Rally.fromJson),
      meetups: jl(j['meetups'], Meetup.fromJson),
      races: jl(j['races'], Race.fromJson),
    );
  }
}

// ───────────────────────────── 跑团补充 ─────────────────────────────

class CrewInvite {
  const CrewInvite({required this.code, this.expiresAt});
  final String code;
  final DateTime? expiresAt;
  factory CrewInvite.fromJson(Json j) => CrewInvite(code: js(j['code']), expiresAt: jdt(j['expires_at']));
}
