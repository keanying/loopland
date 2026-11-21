import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../claim/geo.dart';
import '../core/providers.dart';
import 'api_client.dart';
import 'community_common.dart';
import 'errors.dart';
import 'gathering_models.dart';
import 'models.dart';

final gatheringApiProvider = Provider<GatheringApi>((ref) => GatheringApi(ref.watch(apiClientProvider)));

/// Typed endpoints for the gatherings & messages half of docs/api/v2-2-社区.md:
/// community home, inbox summary, conversations, meetups, rallies, races,
/// crew invites / editing. Image upload (`POST /v1/media`) is
/// `CommunityApi.uploadMedia` in community_api.dart.
class GatheringApi {
  GatheringApi(this.c);
  final ApiClient c;

  static Json _j(Object? v) => jm(v);

  // ── 社区首页 / 消息 ──
  Future<CommunityHome> communityHome() async => CommunityHome.fromJson(_j(await c.get('/v1/community/home')));

  Future<InboxSummary> inboxSummary() async => InboxSummary.fromJson(_j(await c.get('/v1/inbox/summary')));

  /// `category`: `all | interaction | territory | monster | system`.
  Future<InboxPage> inbox({String category = 'all', int page = 1}) async =>
      InboxPage.fromJson(_j(await c.get('/v1/inbox', query: {'category': category, 'page': page})));

  // ── 私信与群聊 ──
  Future<CursorPage<Conversation>> conversations({String? cursor, int? limit}) =>
      getCursorPage(c, '/v1/conversations', Conversation.fromJson, cursor: cursor, limit: limit);

  /// Opens (or returns the existing) direct conversation. 403 `blocked`.
  Future<Conversation> openDirect(int userId) async =>
      Conversation.fromJson(_j(await c.post('/v1/conversations/direct', {'user_id': userId})));

  /// `GET /v1/conversations/{id}`; null when it doesn't exist or I'm not a member.
  Future<Conversation?> findConversation(int id) async {
    try {
      return Conversation.fromJson(_j(await c.get('/v1/conversations/$id')));
    } on ApiException catch (e) {
      if (e.status == 404 || e.status == 403) return null;
      rethrow;
    }
  }

  /// Newest first; [before] is the `next_cursor` of the previous page (the id
  /// of the oldest message loaded).
  Future<CursorPage<ChatMessage>> messages(int conversationId, {String? before, int limit = 30}) async =>
      CursorPage.fromJson(
          await c.get('/v1/conversations/$conversationId/messages', query: {
            if (before != null && before.isNotEmpty) 'before': before,
            'limit': limit,
          }),
          ChatMessage.fromJson);

  /// Errors: 400 `content_blocked`, 403 `stranger_limit` / `blocked` / `muted`
  /// / `forbidden` (left the group), 429 `rate_limited`.
  Future<ChatMessage> sendText(int conversationId, String text) => _send(conversationId, {'type': 'text', 'content': text});

  Future<ChatMessage> sendImage(int conversationId, int imageId) =>
      _send(conversationId, {'type': 'image', 'image_id': imageId});

  Future<ChatMessage> sendPost(int conversationId, int postId) =>
      _send(conversationId, {'type': 'post', 'post_id': postId});

  Future<ChatMessage> _send(int id, Json body) async =>
      ChatMessage.fromJson(_j(await c.post('/v1/conversations/$id/messages', body)));

  Future<void> markConversationRead(int id, int messageId) =>
      c.post('/v1/conversations/$id/read', {'message_id': messageId});

  Future<void> muteConversation(int id, bool muted) => c.post('/v1/conversations/$id/mute', {'muted': muted});

  /// Direct: hide until a new message; group: leave (and cancel the meetup signup).
  Future<void> deleteConversation(int id) => c.delete('/v1/conversations/$id');

  // ── 组局 ──
  /// `type`: `run | ball | ride` or empty for all. With [near] the list is
  /// sorted by distance and items carry `distance_m`.
  Future<CursorPage<Meetup>> meetups({String type = '', LatLng? near, int radiusM = 10000, String? cursor}) =>
      getCursorPage(c, '/v1/meetups', Meetup.fromJson, cursor: cursor, query: {
        if (type.isNotEmpty) 'type': type,
        if (near != null) ...{
          'lat': near.lat.toStringAsFixed(6),
          'lng': near.lng.toStringAsFixed(6),
          'radius_m': radiusM,
        },
      });

  Future<List<Meetup>> myMeetups() async => jl(_j(await c.get('/v1/me/meetups'))['items'], Meetup.fromJson);

  Future<Meetup> createMeetup(MeetupDraft d) async => Meetup.fromJson(_j(await c.post('/v1/meetups', d.toJson())));

  Future<Meetup> meetup(int id) async => Meetup.fromJson(_j(await c.get('/v1/meetups/$id')));

  /// 409 `meetup_full` / `meetup_started`.
  Future<Meetup> joinMeetup(int id) async => Meetup.fromJson(_j(await c.post('/v1/meetups/$id/join')));

  Future<Meetup> leaveMeetup(int id) async => Meetup.fromJson(_j(await c.post('/v1/meetups/$id/leave')));

  Future<Meetup> cancelMeetup(int id) async => Meetup.fromJson(_j(await c.post('/v1/meetups/$id/cancel')));

  // ── 集结跑 ──
  Future<List<Rally>> rallies(int crewId) async => jl(_j(await c.get('/v1/crews/$crewId/rallies'))['items'], Rally.fromJson);

  /// Leader only; at most 3 open rallies per crew.
  Future<Rally> createRally(int crewId,
          {required String title, required DateTime startTime, required Place place, required double distanceGoalM}) async =>
      Rally.fromJson(_j(await c.post('/v1/crews/$crewId/rallies', {
        'title': title,
        'start_time': startTime.toUtc().toIso8601String(),
        'place': place.toJson(),
        'distance_goal_m': distanceGoalM.round(),
      })));

  Future<Rally> joinRally(int id) async => Rally.fromJson(_j(await c.post('/v1/rallies/$id/join')));
  Future<Rally> leaveRally(int id) async => Rally.fromJson(_j(await c.post('/v1/rallies/$id/leave')));
  Future<Rally> cancelRally(int id) async => Rally.fromJson(_j(await c.post('/v1/rallies/$id/cancel')));

  /// 400 `checkin_not_allowed` (message says why: too early / late / far).
  Future<Rally> checkinRally(int id, LatLng at) async =>
      Rally.fromJson(_j(await c.post('/v1/rallies/$id/checkin', {'lat': at.lat, 'lng': at.lng})));

  // ── 赛事 ──
  /// `status`: `signup | upcoming | running | finished | cancelled`, or empty.
  Future<CursorPage<Race>> races({String status = '', String? cursor}) =>
      getCursorPage(c, '/v1/races', Race.fromJson, cursor: cursor, query: {if (status.isNotEmpty) 'status': status});

  Future<Race> race(int id) async => Race.fromJson(_j(await c.get('/v1/races/$id')));

  /// 409 `signup_closed` / `race_full`.
  Future<Race> signupRace(int id) async => Race.fromJson(_j(await c.post('/v1/races/$id/signup')));

  /// D-12 paid race: creates the fee order (`my_entry.status = pending_pay`).
  /// [channel] `wechat_app | alipay_app | mock`. Errors as [signupRace] plus
  /// 403 `realname_required` / `minor_not_allowed`.
  Future<RaceSignup> signupPaidRace(int id, String channel) async =>
      RaceSignup.fromJson(_j(await c.post('/v1/races/$id/signup', {'channel': channel})));

  /// Paid races are refunded to the original channel.
  Future<Race> cancelRaceSignup(int id) async => Race.fromJson(_j(await c.delete('/v1/races/$id/signup')));

  // ── 跑团补充 ──
  /// Leader; 7 days, reusable.
  Future<CrewInvite> createInvite(int crewId) async => CrewInvite.fromJson(_j(await c.post('/v1/crews/$crewId/invites')));

  /// Returns the joined crew id. 400 `invalid_invite`.
  Future<int> joinByCode(String code) async =>
      ji(_j(await c.post('/v1/crews/join-by-code', {'code': code.trim().toUpperCase()}))['crew_id']);

  /// Leader. Name / avatar take effect now and are reviewed afterwards.
  Future<Crew> updateCrew(int id, {String? name, int? avatarId, String? district, String? joinMode}) async =>
      Crew.fromJson(_j(await c.patch('/v1/crews/$id', {
        'name': ?name,
        'avatar_id': ?avatarId,
        'district': ?district,
        'join_mode': ?joinMode,
      })));
}
