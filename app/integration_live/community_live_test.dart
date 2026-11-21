// The app's community content API layer (lib/api/community_api.dart) against
// a live dev backend:
//
//   LOOPLAND_LIVE_API=http://localhost:8080 flutter test integration_live
//
// Skipped when LOOPLAND_LIVE_API is not set.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/community_api.dart';
import 'package:loopland/api/community_models.dart';
import 'package:loopland/api/errors.dart';
import 'package:loopland/api/loopland_api.dart';
import 'package:loopland/auth/token_store.dart';

import 'live_api_test.dart' show run;

// A 1×1 PNG.
final png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
  0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  final base = Platform.environment['LOOPLAND_LIVE_API'];
  final skip = base == null ? 'set LOOPLAND_LIVE_API to run' : false;
  final rnd = math.Random().nextInt(90000000) + 10000000;

  Future<(LooplandApi, CommunityApi, int)> login(String phone) async {
    final c = ApiClient(tokens: MemoryTokenStore(), baseUrl: base, platform: 'android');
    final a = LooplandApi(c);
    await a.sendSms(phone);
    final auth = await a.login('sms', {'phone': phone, 'code': '000000'});
    await a.setConsents(privacyVersion: '2026-11', location: true, health: true);
    return (a, CommunityApi(c), auth.user.id);
  }

  test('posts, feed, comments, follow, block, profile, replay against the live backend', () async {
    final (aApi, a, aId) = await login('137$rnd');
    final (_, b, bId) = await login('136$rnd');

    // A runs a loop and posts it with a photo.
    final square = [
      [0.0, 0.0], [400.0, 0.0], [400.0, 400.0], [200.0, 400.0], [200.0, -50.0]
    ].map((p) => [p[0] + rnd % 50 * 1000.0, p[1] + 3000]).toList();
    final res = await aApi.uploadActivity(run(square));
    expect(res.settlement.status, 'settled');
    final actId = res.activity.id;

    var sent = 0;
    final img = await a.uploadMedia(png, filename: 'run.png', onProgress: (s, _) => sent = s);
    expect(img.id, greaterThan(0));
    expect(img.url, isNotEmpty);
    expect(sent, greaterThan(0));

    final post = await a.createPost(NewPost(content: '今晚绕了一圈 #夜跑', imageIds: [img.id], activityId: actId));
    expect(post.author.id, aId);
    expect(post.images.single.url, img.url);
    expect(post.activity!.id, actId);
    expect(post.activity!.distanceM, greaterThan(1000));
    expect(post.visibility, 'public');
    // A brand-new account posting a photo scores 20, which is the default
    // auto-approve line (< 20 passes): it waits for review.
    expect(post.reviewStatus, ReviewStatus.pending);

    // Contact info scores 50: queued for review, visible to the author only.
    final pending = await a.createPost(const NewPost(content: '一起跑步加我电话 13912345678'));
    expect(pending.reviewStatus, ReviewStatus.pending);
    await expectLater(b.post(pending.id), throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)));

    // B sees A's post in 推荐 and can page with the cursor.
    final rec = await b.feed('recommend');
    expect(rec.items.map((p) => p.id), contains(post.id));
    if (rec.hasMore) await b.feed('recommend', cursor: rec.nextCursor);
    final seen = rec.items.firstWhere((p) => p.id == post.id);
    expect(seen.activity!.track.length, greaterThanOrEqualTo(0));

    // Like / collect / share.
    expect((await b.likePost(post.id, true)).on, isTrue);
    final unlike = await b.likePost(post.id, false);
    expect(unlike.on, isFalse);
    expect((await b.likePost(post.id, true)).count, 1);
    expect((await b.collectPost(post.id, true)).count, 1);
    expect((await b.collections()).items.map((p) => p.id), contains(post.id));
    final share = await b.share(post.id, 'poster');
    expect(share.shareCount, 1);
    expect(share.url, contains('${post.id}'));

    // Two-level comments: B comments, A replies, B replies to A's reply.
    final c1 = await b.addComment(post.id, '厉害');
    expect(c1.isTopLevel, isTrue);
    final r1 = await a.addComment(post.id, '谢谢', parentId: c1.id);
    expect(r1.parentId, c1.id);
    expect(r1.replyTo, isNull);
    final r2 = await b.addComment(post.id, '下次带我', parentId: c1.id, replyToUserId: aId);
    expect(r2.replyTo?.id, aId);
    final list = await a.comments(post.id);
    final top = list.items.firstWhere((c) => c.id == c1.id);
    expect(top.replyCount, 2);
    expect(top.replies.map((r) => r.id), [r1.id, r2.id]);
    expect((await a.replies(c1.id)).items.length, 2);
    expect((await a.likeComment(c1.id, true)).count, 1);
    expect((await a.post(post.id)).commentCount, 3);
    await b.deleteComment(r2.id);

    // Report (idempotent per reporter).
    final rep = await b.report('post', post.id, 'spam', detail: '测试');
    expect(await b.report('post', post.id, 'spam'), rep);

    // Follow → 关注 feed, followers, relation.
    expect(await b.follow(aId, true), isTrue);
    final prof = await b.profile(aId);
    expect(prof.relation.following, isTrue);
    expect(prof.isSelf, isFalse);
    expect(prof.followerCount, 1);
    expect(prof.likeReceivedCount, greaterThanOrEqualTo(1));
    expect(prof.totalDistanceM, greaterThan(1000));
    expect((await a.followers(aId)).items.single.user.id, bId);
    expect((await b.following(bId)).items.single.user.id, aId);
    expect((await b.feed('following')).items.map((p) => p.id), contains(post.id));
    expect((await b.userPosts(aId)).items.map((p) => p.id), contains(post.id));
    final self = await a.profile(aId);
    expect(self.isSelf, isTrue);
    await expectLater(a.follow(aId, true), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_target')));

    // Replays.
    final replays = await b.replays();
    final rp = replays.items.where((r) => r.postId == post.id).firstOrNull;
    expect(rp, isNotNull);
    expect(rp!.points, isNotEmpty);
    expect(rp.playback.inSeconds, inInclusiveRange(15, 30));
    final single = await b.activityReplay(actId);
    expect(single.activity.id, actId);

    // Profile edits: bio and avatar (post-moderation: immediate).
    final u = await a.updateProfile(bio: '每天 5 公里');
    expect(u.id, aId);
    expect((await b.profile(aId)).bio, '每天 5 公里');
    final av = await a.uploadMedia(png, filename: 'me.png', purpose: 'avatar');
    final u2 = await a.updateProfile(avatarUrl: av.url);
    expect(u2.avatarUrl, av.url);

    // Block: follows are dropped both ways; following back is refused.
    await a.block(bId, true);
    expect((await a.blocks()).single.user.id, bId);
    expect((await b.profile(aId)).relation.blockedBy, isTrue);
    expect((await b.userPosts(aId)).items, isEmpty);
    await expectLater(b.follow(aId, true), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'blocked')));
    await a.block(bId, false);
    expect(await a.blocks(), isEmpty);

    await a.deletePost(post.id);
    await expectLater(b.post(post.id), throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
