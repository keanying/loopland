// Content-side models for docs/api/v2-2-社区.md: posts, comments, profiles,
// relations, media, share and replay. Parsing is tolerant like models.dart.
import '../claim/geo.dart';
import 'community_common.dart';
import 'models.dart';

/// `review_status`: pending (only the author sees it, 「审核中」), approved,
/// rejected (only the author sees it, with `reject_reason`).
enum ReviewStatus {
  pending,
  approved,
  rejected;

  static ReviewStatus parse(Object? v) => switch (v) {
        'pending' => ReviewStatus.pending,
        'rejected' => ReviewStatus.rejected,
        _ => ReviewStatus.approved,
      };
}

/// Post visibility: `public | fans | crew | private`.
const visibilityNames = {'public': '公开', 'fans': '仅粉丝', 'crew': '仅跑团', 'private': '仅自己'};

class PostImage {
  const PostImage({required this.url, this.width = 0, this.height = 0});
  final String url;
  final int width;
  final int height;

  double get aspect => width > 0 && height > 0 ? width / height : 1;

  factory PostImage.fromJson(Json j) =>
      PostImage(url: js(j['url']), width: ji(j['width']), height: ji(j['height']));
}

/// The run attached to a post (`activity`). `track` is `[lng, lat]` pairs,
/// ≤ 300 points, start / end 200 m already removed by the server.
class PostActivity {
  const PostActivity({
    required this.id,
    this.sport = 'run',
    this.distanceM = 0,
    this.durationSec = 0,
    this.paceSecPerKm,
    this.claimedAreaM2 = 0,
    this.startTime,
    this.track = const [],
  });
  final int id;
  final String sport;
  final double distanceM;
  final int durationSec;
  final double? paceSecPerKm;
  final double claimedAreaM2;
  final DateTime? startTime;
  final List<LatLng> track;

  /// Pace from the server, or derived from distance / duration.
  double? get pace => paceSecPerKm ?? (distanceM > 0 && durationSec > 0 ? durationSec / (distanceM / 1000) : null);

  factory PostActivity.fromJson(Json j) => PostActivity(
        id: ji(j['id']),
        sport: js(j['sport'], 'run'),
        distanceM: jd(j['distance_m']),
        // The contract uses duration_sec / pace_sec_per_km / start_time; the v1
        // Activity object uses duration_s / avg_pace_s_per_km / started_at.
        durationSec: ji(j['duration_sec'] ?? j['duration_s']),
        paceSecPerKm: jdn(j['pace_sec_per_km'] ?? j['avg_pace_s_per_km']),
        claimedAreaM2: jd(j['claimed_area_m2']),
        startTime: jdt(j['start_time'] ?? j['started_at']),
        track: parseTrack(j['track']),
      );

  /// Builds the attachment preview from a v1 [Activity] (composer).
  factory PostActivity.fromActivity(Activity a) => PostActivity(
        id: a.id,
        sport: a.sport,
        distanceM: a.distanceM,
        durationSec: a.durationS,
        paceSecPerKm: a.avgPaceSPerKm,
        claimedAreaM2: a.claimedAreaM2,
        startTime: a.startedAt,
        track: a.track,
      );
}

/// `[[lng, lat], …]`, or a GeoJSON LineString, or `[{lat, lng}]`.
List<LatLng> parseTrack(Object? v) {
  if (v is Map && v['coordinates'] is List) v = v['coordinates'];
  if (v is! List) return const [];
  final out = <LatLng>[];
  for (final p in v) {
    if (p is List && p.length >= 2 && p[0] is num && p[1] is num) {
      out.add(LatLng.fromGeoJson(p));
    } else if (p is Map && p['lat'] is num && p['lng'] is num) {
      out.add(LatLng.fromJson(p.cast<String, dynamic>()));
    }
  }
  return out;
}

class Post {
  const Post({
    required this.id,
    required this.author,
    this.content = '',
    this.images = const [],
    this.activity,
    this.visibility = 'public',
    this.reviewStatus = ReviewStatus.approved,
    this.rejectReason,
    this.likeCount = 0,
    this.commentCount = 0,
    this.collectCount = 0,
    this.shareCount = 0,
    this.liked = false,
    this.collected = false,
    this.createdAt,
  });
  final int id;
  final UserBrief author;
  final String content;
  final List<PostImage> images;
  final PostActivity? activity;
  final String visibility;
  final ReviewStatus reviewStatus;
  final String? rejectReason;
  final int likeCount;
  final int commentCount;
  final int collectCount;
  final int shareCount;
  final bool liked;
  final bool collected;
  final DateTime? createdAt;

  factory Post.fromJson(Json j) => Post(
        id: ji(j['id']),
        author: UserBrief.fromJson(jm(j['author'])),
        content: js(j['content']),
        images: jl(j['images'], PostImage.fromJson),
        activity: jmn(j['activity']) == null ? null : PostActivity.fromJson(jm(j['activity'])),
        visibility: js(j['visibility'], 'public'),
        reviewStatus: ReviewStatus.parse(j['review_status']),
        rejectReason: jsn(j['reject_reason']),
        likeCount: ji(j['like_count']),
        commentCount: ji(j['comment_count']),
        collectCount: ji(j['collect_count']),
        shareCount: ji(j['share_count']),
        liked: jb(j['liked']),
        collected: jb(j['collected']),
        createdAt: jdt(j['created_at']),
      );

  Post copyWith({
    int? likeCount,
    int? commentCount,
    int? collectCount,
    int? shareCount,
    bool? liked,
    bool? collected,
  }) =>
      Post(
        id: id,
        author: author,
        content: content,
        images: images,
        activity: activity,
        visibility: visibility,
        reviewStatus: reviewStatus,
        rejectReason: rejectReason,
        likeCount: likeCount ?? this.likeCount,
        commentCount: commentCount ?? this.commentCount,
        collectCount: collectCount ?? this.collectCount,
        shareCount: shareCount ?? this.shareCount,
        liked: liked ?? this.liked,
        collected: collected ?? this.collected,
        createdAt: createdAt,
      );
}

/// `POST /v1/posts` body.
class NewPost {
  const NewPost({this.content = '', this.imageIds = const [], this.activityId, this.visibility = 'public'});
  final String content;
  final List<int> imageIds;
  final int? activityId;
  final String visibility;

  Json toJson() => {
        'content': content,
        'image_ids': imageIds,
        'activity_id': activityId,
        'visibility': visibility,
      };
}

class Comment {
  const Comment({
    required this.id,
    required this.postId,
    required this.author,
    this.content = '',
    this.replyTo,
    this.parentId,
    this.likeCount = 0,
    this.liked = false,
    this.reviewStatus = ReviewStatus.approved,
    this.replyCount = 0,
    this.replies = const [],
    this.createdAt,
  });
  final int id;
  final int postId;
  final UserBrief author;
  final String content;

  /// Who a reply answers (null when replying to the top-level comment).
  final UserBrief? replyTo;

  /// null = top-level comment.
  final int? parentId;
  final int likeCount;
  final bool liked;
  final ReviewStatus reviewStatus;
  final int replyCount;

  /// The earliest 3 replies (top-level comments only).
  final List<Comment> replies;
  final DateTime? createdAt;

  bool get isTopLevel => parentId == null;

  factory Comment.fromJson(Json j) => Comment(
        id: ji(j['id']),
        postId: ji(j['post_id']),
        author: UserBrief.fromJson(jm(j['author'])),
        content: js(j['content']),
        replyTo: UserBrief.maybe(j['reply_to']),
        parentId: jin(j['parent_id']),
        likeCount: ji(j['like_count']),
        liked: jb(j['liked']),
        reviewStatus: ReviewStatus.parse(j['review_status']),
        replyCount: ji(j['reply_count']),
        replies: jl(j['replies'], Comment.fromJson),
        createdAt: jdt(j['created_at']),
      );

  Comment copyWith({int? likeCount, bool? liked, int? replyCount, List<Comment>? replies}) => Comment(
        id: id,
        postId: postId,
        author: author,
        content: content,
        replyTo: replyTo,
        parentId: parentId,
        likeCount: likeCount ?? this.likeCount,
        liked: liked ?? this.liked,
        reviewStatus: reviewStatus,
        replyCount: replyCount ?? this.replyCount,
        replies: replies ?? this.replies,
        createdAt: createdAt,
      );
}

class Relation {
  const Relation({this.following = false, this.followedBy = false, this.blocked = false, this.blockedBy = false});
  final bool following;
  final bool followedBy;

  /// I blocked them.
  final bool blocked;

  /// They blocked me: profile still shows, posts are empty, no follow / chat.
  final bool blockedBy;

  bool get anyBlock => blocked || blockedBy;

  factory Relation.fromJson(Json j) => Relation(
        following: jb(j['following']),
        followedBy: jb(j['followed_by']),
        blocked: jb(j['blocked']),
        blockedBy: jb(j['blocked_by']),
      );

  Relation copyWith({bool? following, bool? blocked}) => Relation(
      following: following ?? this.following,
      followedBy: blocked == true ? false : followedBy,
      blocked: blocked ?? this.blocked,
      blockedBy: blockedBy);
}

/// `GET /v1/users/{id}`.
class Profile {
  const Profile({
    required this.user,
    this.bio = '',
    this.followerCount = 0,
    this.followingCount = 0,
    this.likeReceivedCount = 0,
    this.totalDistanceM = 0,
    this.territoryCount = 0,
    this.territoryAreaM2 = 0,
    this.codexCount = 0,
    this.postCount,
    this.relation = const Relation(),
    this.isSelf = false,
  });
  final UserBrief user;
  final String bio;
  final int followerCount;
  final int followingCount;
  final int likeReceivedCount;
  final double totalDistanceM;
  final int territoryCount;
  final double territoryAreaM2;
  final int codexCount;

  /// Not in the contract (yet); shown when the server sends `post_count`.
  final int? postCount;
  final Relation relation;
  final bool isSelf;

  factory Profile.fromJson(Json j) => Profile(
        user: UserBrief.fromJson(jm(j['user'])),
        bio: js(j['bio']),
        followerCount: ji(j['follower_count']),
        followingCount: ji(j['following_count']),
        likeReceivedCount: ji(j['like_received_count']),
        totalDistanceM: jd(j['total_distance_m']),
        territoryCount: ji(j['territory_count']),
        territoryAreaM2: jd(j['territory_area_m2']),
        codexCount: ji(j['codex_count']),
        postCount: jin(j['post_count']),
        relation: Relation.fromJson(jm(j['relation'])),
        isSelf: jb(j['is_self']),
      );

  Profile copyWith({Relation? relation, int? followerCount}) => Profile(
        user: user,
        bio: bio,
        followerCount: followerCount ?? this.followerCount,
        followingCount: followingCount,
        likeReceivedCount: likeReceivedCount,
        totalDistanceM: totalDistanceM,
        territoryCount: territoryCount,
        territoryAreaM2: territoryAreaM2,
        codexCount: codexCount,
        postCount: postCount,
        relation: relation ?? this.relation,
        isSelf: isSelf,
      );
}

/// Followers / following list row. `following` = I follow this person.
class FollowEntry {
  const FollowEntry({required this.user, this.following = false, this.followedAt});
  final UserBrief user;
  final bool following;
  final DateTime? followedAt;

  factory FollowEntry.fromJson(Json j) => FollowEntry(
      user: UserBrief.fromJson(jm(j['user'])), following: jb(j['following']), followedAt: jdt(j['followed_at']));

  FollowEntry copyWith({bool? following}) =>
      FollowEntry(user: user, following: following ?? this.following, followedAt: followedAt);
}

class BlockEntry {
  const BlockEntry({required this.user, this.blockedAt});
  final UserBrief user;
  final DateTime? blockedAt;
  factory BlockEntry.fromJson(Json j) =>
      BlockEntry(user: UserBrief.fromJson(jm(j['user'])), blockedAt: jdt(j['blocked_at']));
}

/// `POST /v1/media` result.
class MediaUpload {
  const MediaUpload({required this.id, required this.url, this.width = 0, this.height = 0});
  final int id;
  final String url;
  final int width;
  final int height;
  factory MediaUpload.fromJson(Json j) =>
      MediaUpload(id: ji(j['id']), url: js(j['url']), width: ji(j['width']), height: ji(j['height']));
}

/// `POST /v1/posts/{id}/share` result.
class PostShare {
  const PostShare({this.shareCount = 0, this.url = '', this.posterTitle = '', this.posterSubtitle = '', this.posterImageUrl});
  final int shareCount;
  final String url;
  final String posterTitle;
  final String posterSubtitle;
  final String? posterImageUrl;
  factory PostShare.fromJson(Json j) {
    final p = jm(j['poster']);
    return PostShare(
      shareCount: ji(j['share_count']),
      url: js(j['url']),
      posterTitle: js(p['title']),
      posterSubtitle: js(p['subtitle']),
      posterImageUrl: jsn(p['image_url']),
    );
  }
}

/// `{"liked":true,"like_count":13}` / `{"collected":true,"collect_count":2}`.
class ToggleResult {
  const ToggleResult(this.on, this.count);
  final bool on;
  final int count;
}

class ReplayPoint {
  const ReplayPoint(this.lng, this.lat, this.t);
  final double lng;
  final double lat;

  /// Seconds since the start.
  final double t;

  LatLng get latLng => LatLng(lat, lng);

  factory ReplayPoint.fromJson(Json j) => ReplayPoint(jd(j['lng']), jd(j['lat']), jd(j['t']));
}

/// `GET /v1/replays` item.
class Replay {
  const Replay({
    required this.postId,
    required this.author,
    required this.activity,
    this.points = const [],
    this.likeCount = 0,
    this.liked = false,
    this.content = '',
  });
  final int postId;
  final UserBrief author;
  final PostActivity activity;
  final List<ReplayPoint> points;
  final int likeCount;
  final bool liked;

  /// Not in the contract; shown when present.
  final String content;

  /// Playback length: the run compressed into 15–30 s (longer runs play longer).
  Duration get playback {
    final d = activity.durationSec > 0 ? activity.durationSec : (points.isEmpty ? 0 : points.last.t.round());
    // 15 s for ≤ 10 min, 30 s for ≥ 2 h, linear in between.
    final f = ((d - 600) / (7200 - 600)).clamp(0.0, 1.0);
    return Duration(milliseconds: (15000 + 15000 * f).round());
  }

  factory Replay.fromJson(Json j) => Replay(
        postId: ji(j['post_id']),
        author: UserBrief.fromJson(jm(j['author'])),
        activity: PostActivity.fromJson(jm(j['activity'])),
        points: jl(j['points'], ReplayPoint.fromJson),
        likeCount: ji(j['like_count']),
        liked: jb(j['liked']),
        content: js(j['content']),
      );

  Replay copyWith({int? likeCount, bool? liked}) => Replay(
      postId: postId,
      author: author,
      activity: activity,
      points: points,
      likeCount: likeCount ?? this.likeCount,
      liked: liked ?? this.liked,
      content: content);
}

/// Report reasons (`POST /v1/reports`).
const reportReasons = {
  'spam': '垃圾广告',
  'porn': '色情低俗',
  'abuse': '辱骂攻击',
  'fraud': '欺诈骗钱',
  'illegal': '违法违规',
  'other': '其他',
};
