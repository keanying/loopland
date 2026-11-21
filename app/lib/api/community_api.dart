import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import 'api_client.dart';
import 'community_common.dart';
import 'community_models.dart';
import 'errors.dart';
import 'models.dart';

final communityApiProvider = Provider<CommunityApi>((ref) => CommunityApi(ref.watch(apiClientProvider)));

/// Content-side endpoints of docs/api/v2-2-社区.md: media, posts, feed,
/// comments, reports, follow / block / profiles, replays.
class CommunityApi {
  CommunityApi(this.c);
  final ApiClient c;

  // ── 图片上传 ──

  /// `POST /v1/media` (multipart). purpose: `post | avatar | crew_avatar | chat`.
  /// Errors: 400 `invalid_media`, 429 `rate_limited` (200 / day).
  Future<MediaUpload> uploadMedia(
    Uint8List bytes, {
    required String filename,
    String purpose = 'post',
    void Function(int sent, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    final form = FormData.fromMap({
      'purpose': purpose,
      'file': MultipartFile.fromBytes(bytes, filename: filename, contentType: _mime(filename)),
    });
    try {
      final r = await c.dio.post<dynamic>('/v1/media', data: form, onSendProgress: onProgress, cancelToken: cancel);
      return MediaUpload.fromJson(jm(r.data));
    } catch (e) {
      throw ApiException.from(e);
    }
  }

  static DioMediaType _mime(String name) {
    final ext = name.toLowerCase().split('.').last;
    return switch (ext) {
      'png' => DioMediaType('image', 'png'),
      'webp' => DioMediaType('image', 'webp'),
      'heic' || 'heif' => DioMediaType('image', 'heic'),
      _ => DioMediaType('image', 'jpeg'),
    };
  }

  // ── 动态 ──

  /// tab: `following | recommend`.
  Future<CursorPage<Post>> feed(String tab, {String? cursor, int? limit}) =>
      getCursorPage(c, '/v1/feed', Post.fromJson, cursor: cursor, limit: limit, query: {'tab': tab});

  /// Errors: 400 `content_blocked` / `invalid_media` / `not_in_crew`, 403 `muted`, 429.
  Future<Post> createPost(NewPost p) async => Post.fromJson(jm(await c.post('/v1/posts', p.toJson())));

  Future<Post> post(int id) async => Post.fromJson(jm(await c.get('/v1/posts/$id')));

  Future<void> deletePost(int id) => c.delete('/v1/posts/$id');

  Future<ToggleResult> likePost(int id, bool on) async {
    final r = jm(on ? await c.post('/v1/posts/$id/like') : await c.delete('/v1/posts/$id/like'));
    return ToggleResult(jb(r['liked'], on), ji(r['like_count']));
  }

  Future<ToggleResult> collectPost(int id, bool on) async {
    final r = jm(on ? await c.post('/v1/posts/$id/collect') : await c.delete('/v1/posts/$id/collect'));
    return ToggleResult(jb(r['collected'], on), ji(r['collect_count']));
  }

  /// channel: `wechat | moments | poster | link`.
  Future<PostShare> share(int id, String channel) async =>
      PostShare.fromJson(jm(await c.post('/v1/posts/$id/share', {'channel': channel})));

  Future<CursorPage<Post>> collections({String? cursor}) =>
      getCursorPage(c, '/v1/me/collections', Post.fromJson, cursor: cursor);

  Future<CursorPage<Post>> userPosts(int userId, {String? cursor}) =>
      getCursorPage(c, '/v1/users/$userId/posts', Post.fromJson, cursor: cursor);

  // ── 评论 ──

  Future<CursorPage<Comment>> comments(int postId, {String? cursor}) =>
      getCursorPage(c, '/v1/posts/$postId/comments', Comment.fromJson, cursor: cursor);

  Future<CursorPage<Comment>> replies(int commentId, {String? cursor}) =>
      getCursorPage(c, '/v1/comments/$commentId/replies', Comment.fromJson, cursor: cursor);

  /// Top-level when [parentId] is null; [replyToUserId] when answering a reply.
  Future<Comment> addComment(int postId, String content, {int? parentId, int? replyToUserId}) async =>
      Comment.fromJson(jm(await c.post('/v1/posts/$postId/comments', {
        'content': content,
        'parent_id': ?parentId,
        'reply_to_user_id': ?replyToUserId,
      })));

  Future<void> deleteComment(int id) => c.delete('/v1/comments/$id');

  Future<ToggleResult> likeComment(int id, bool on) async {
    final r = jm(on ? await c.post('/v1/comments/$id/like') : await c.delete('/v1/comments/$id/like'));
    return ToggleResult(jb(r['liked'], on), ji(r['like_count']));
  }

  // ── 举报 ──

  /// target_type: `post | comment | user | crew | message`. Returns the report id.
  Future<int> report(String targetType, int targetId, String reason, {String? detail}) async {
    final r = jm(await c.post('/v1/reports', {
      'target_type': targetType,
      'target_id': targetId,
      'reason': reason,
      if (detail != null && detail.trim().isNotEmpty) 'detail': detail.trim(),
    }));
    return ji(r['id']);
  }

  // ── 关注、拉黑、主页 ──

  Future<Profile> profile(int userId) async => Profile.fromJson(jm(await c.get('/v1/users/$userId')));

  /// Errors: 400 `invalid_target` (self), 403 `blocked`.
  Future<bool> follow(int userId, bool on) async {
    final r = jm(on ? await c.post('/v1/users/$userId/follow') : await c.delete('/v1/users/$userId/follow'));
    return jb(r['following'], on);
  }

  Future<CursorPage<FollowEntry>> followers(int userId, {String? cursor}) =>
      getCursorPage(c, '/v1/users/$userId/followers', FollowEntry.fromJson, cursor: cursor);

  Future<CursorPage<FollowEntry>> following(int userId, {String? cursor}) =>
      getCursorPage(c, '/v1/users/$userId/following', FollowEntry.fromJson, cursor: cursor);

  Future<void> block(int userId, bool on) =>
      on ? c.post('/v1/users/$userId/block') : c.delete('/v1/users/$userId/block');

  Future<List<BlockEntry>> blocks() async => jl(jm(await c.get('/v1/me/blocks'))['items'], BlockEntry.fromJson);

  /// `PATCH /v1/me` with the community fields (bio ≤ 60; nickname / avatar /
  /// bio take effect immediately and are reviewed afterwards).
  Future<User> updateProfile({String? nickname, String? bio, String? avatarUrl}) async =>
      User.fromJson(jm(await c.patch('/v1/me', {
        'nickname': ?nickname,
        'bio': ?bio,
        'avatar_url': ?avatarUrl,
      })));

  // ── 轨迹回放 ──

  Future<CursorPage<Replay>> replays({String? cursor}) =>
      getCursorPage(c, '/v1/replays', Replay.fromJson, cursor: cursor);

  Future<Replay> activityReplay(int activityId) async =>
      Replay.fromJson(jm(await c.get('/v1/activities/$activityId/replay')));
}
