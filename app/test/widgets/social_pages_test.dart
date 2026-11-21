// V2 batch 2「社区」content side: feed, detail + comments, composer, profile,
// replay. With LOOPLAND_SCREENSHOTS=1 they write PNGs to app/screenshots/v2/.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:loopland/api/community_models.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/features/me/me_page.dart';
import 'package:loopland/features/social/media_picker.dart';
import 'package:loopland/features/social/share_sheet.dart';
import 'package:loopland/features/social/social_routes.dart';
import 'package:material_ui/material_ui.dart';

import '../api/fixtures.dart';
import 'community_fake.dart';
import 'fake_backend.dart';
import 'test_helpers.dart';

class FakePicker implements MediaPicker {
  int picks = 0;
  // A 1×1 PNG.
  static final png = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
    0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ]);
  @override
  Future<List<PickedImage>> pickImages(int max) async {
    picks++;
    return [for (var i = 0; i < 2 && i < max; i++) (bytes: png, name: 'p$i.png')];
  }

  @override
  Future<PickedImage?> pickOne() async => (bytes: png, name: 'avatar.png');
}

/// The app's social routes plus a stand-in for the chat route (owned by the
/// messaging side) and a launcher page for pushes that pop a result.
Widget routed(String initial, List<Override> overrides) {
  final router = GoRouter(initialLocation: initial, routes: [
    ...socialRoutes(),
    GoRoute(path: '/chat/direct/:userId', builder: (_, s) => Scaffold(body: Text('chat with ${s.pathParameters['userId']}'))),
    GoRoute(path: '/me', builder: (_, _) => const MePage()),
  ]);
  return RepaintBoundary(
    key: const Key('shot'),
    child: ProviderScope(
      overrides: overrides,
      retry: (_, _) => null,
      child: MaterialApp.router(theme: buildTheme(), routerConfig: router, debugShowCheckedModeBanner: false),
    ),
  );
}

Future<void> shot(WidgetTester t, String name) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await t.pump();
  await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/$name.png');
}

void main() {
  setUpAll(() async {
    await loadFonts();
    shareWeChatAvailable = () => false;
  });

  testWidgets('feed: tabs, cards, review badges, optimistic like, infinite scroll', (t) async {
    final sem = t.ensureSemantics();
    await phone(t);
    final fake = CommunityFake();
    await t.pumpWidget(routed('/community/feed', fakeBackend(handlers: [fake.handle])));
    await idle(t);
    expect(find.text('动态'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('Kai'), findsOneWidget);
    expect(find.textContaining('东港这一带今晚归我'), findsOneWidget);
    expect(find.text('10.4 km'), findsOneWidget);
    expect(find.text('+0.61 km²'), findsOneWidget);
    expect(find.text('128'), findsOneWidget);
    expect(fake.lastCall('GET', '/v1/feed')!.queryParameters['tab'], 'recommend');
    await shot(t, 'feed');

    // Optimistic like: count goes up immediately, then POST.
    await t.tap(find.bySemanticsLabel(RegExp('^点赞')).first);
    await t.pump();
    expect(find.text('129'), findsOneWidget);
    await idle(t, 1);
    expect(fake.countCalls('POST', '/v1/posts/101/like'), 1);
    expect(find.text('129'), findsOneWidget);
    // …and back.
    await t.tap(find.bySemanticsLabel(RegExp('^取消点赞')).first);
    await idle(t, 1);
    expect(find.text('128'), findsOneWidget);
    expect(fake.countCalls('DELETE', '/v1/posts/101/like'), 1);

    // My pending post carries 审核中.
    await t.drag(find.byType(ListView).first, const Offset(0, -900));
    await idle(t);
    expect(find.text('审核中'), findsOneWidget);
    // Scrolling near the end loads page 2 with the cursor.
    await t.drag(find.byType(ListView).first, const Offset(0, -2000));
    await idle(t);
    expect(fake.calls.any((o) => o.path == '/v1/feed' && o.queryParameters['cursor'] == 'c2'), isTrue);
    expect(find.text('第二页的动态'), findsOneWidget);

    // 关注 tab loads its own list; rejected own post shows the reason.
    await t.tap(find.text('关注'));
    await idle(t);
    expect(fake.calls.any((o) => o.path == '/v1/feed' && o.queryParameters['tab'] == 'following'), isTrue);
    expect(find.text('未通过：含联系方式'), findsOneWidget);
    await settle(t);
    sem.dispose();
  });

  testWidgets('detail: track, stats, two-level comments, more replies, reply to a reply, like, delete, report', (t) async {
    final sem = t.ensureSemantics();
    await phone(t, size: const Size(390, 1700));
    final fake = CommunityFake();
    await t.pumpWidget(routed('/posts/101', fakeBackend(handlers: [fake.handle])));
    await idle(t);
    expect(find.text('动态详情'), findsOneWidget);
    expect(find.text('轨迹回放'), findsOneWidget);
    expect(find.text('57:12'), findsOneWidget);
    expect(find.text('+0.61'), findsOneWidget);
    expect(find.text('评论 21'), findsOneWidget);
    expect(find.text('回关'), findsOneWidget); // Kai follows me, I don't follow back
    expect(find.text('东门那块我明早去补一圈，别得意'), findsOneWidget);
    expect(find.text('来啊，我等着'), findsOneWidget);
    expect(find.text('带我一个'), findsWidgets); // a reply and the quick chip
    expect(find.text('展开更多回复（2）'), findsOneWidget);
    await shot(t, 'detail');

    // 展开更多回复 → /replies, deduped.
    await t.tap(find.text('展开更多回复（2）'));
    await idle(t);
    expect(find.text('那就明早 6 点东门见'), findsOneWidget);
    expect(find.text('来啊，我等着'), findsOneWidget);
    expect(find.textContaining('展开更多回复'), findsNothing);

    // Reply to a reply: parent = top-level id, reply_to_user_id = its author.
    await t.tap(find.text('来啊，我等着'));
    await t.pump();
    expect(find.text('回复 @Kai'), findsOneWidget);
    await t.enterText(find.byType(TextField), '算我一个');
    await t.tap(find.text('发送'));
    await idle(t);
    final sent = fake.lastCall('POST', '/v1/posts/101/comments')!.data as Map;
    expect(sent['parent_id'], 9);
    expect(sent['reply_to_user_id'], 7);
    expect(find.text('算我一个'), findsOneWidget);
    expect(find.text('评论 22'), findsOneWidget);

    // Top-level comment via quick chip.
    await t.tap(find.widgetWithText(OutlinedButton, '加油！'));
    await idle(t);
    expect((fake.lastCall('POST', '/v1/posts/101/comments')!.data as Map)['parent_id'], isNull);

    // Comment like.
    await t.tap(find.bySemanticsLabel(RegExp('^点赞评论')).first);
    await idle(t, 1);
    expect(fake.countCalls('POST', '/v1/comments/9/like'), 1);
    expect(find.text('25'), findsOneWidget);

    // Delete my own comment.
    await t.longPress(find.text('厉害！'));
    await t.pumpAndSettle();
    await t.tap(find.text('删除'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, '删除'));
    await idle(t);
    expect(fake.countCalls('DELETE', '/v1/comments/11'), 1);
    expect(find.text('厉害！'), findsNothing);

    // Report someone else's comment.
    await t.longPress(find.text('轨迹好漂亮'));
    await t.pumpAndSettle();
    await t.tap(find.text('举报'));
    await t.pumpAndSettle();
    expect(find.text('举报评论'), findsOneWidget);
    await t.tap(find.text('垃圾广告'));
    await t.pump();
    await t.tap(find.text('提交举报'));
    await idle(t);
    final rep = fake.lastCall('POST', '/v1/reports')!.data as Map;
    expect(rep, {'target_type': 'comment', 'target_id': 10, 'reason': 'spam'});
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('举报已提交，我们会尽快处理'), findsOneWidget);

    // Follow the author (回关).
    await t.tap(find.text('回关'));
    await idle(t);
    expect(fake.countCalls('POST', '/v1/users/7/follow'), 1);
    expect(find.text('互相关注'), findsOneWidget);
    await settle(t);
    sem.dispose();
  });

  testWidgets('detail: share sheet records the share, copies the link and renders the poster', (t) async {
    final sem = t.ensureSemantics();
    await phone(t);
    final fake = CommunityFake();
    await t.pumpWidget(routed('/posts/101', fakeBackend(handlers: [fake.handle])));
    await idle(t);
    await t.tap(find.byTooltip('分享').first);
    await t.pumpAndSettle();
    // WeChat isn't configured in tests: those channels are hidden.
    expect(find.text('微信'), findsNothing);
    expect(find.text('生成海报'), findsOneWidget);
    await t.tap(find.text('生成海报'));
    await idle(t);
    await t.pumpAndSettle();
    expect((fake.lastCall('POST', '/v1/posts/101/share')!.data as Map)['channel'], 'poster');
    expect(find.text('分享海报'), findsOneWidget);
    expect(find.text('Kai 在东港圈了 0.61 km²'), findsOneWidget);
    await shot(t, 'poster');
    await settle(t);
    sem.dispose();
  });

  testWidgets('composer: counter, upload with progress, attach run, visibility, errors, publish', (t) async {
    final sem = t.ensureSemantics();
    await phone(t, size: const Size(390, 1100));
    final fake = CommunityFake();
    final picker = FakePicker();
    await t.pumpWidget(routed('/posts/new?activity=56', [
      ...fakeBackend(handlers: [fake.handle]),
      mediaPickerProvider.overrideWithValue(picker),
    ]));
    await idle(t);
    expect(find.text('发布动态'), findsOneWidget);
    expect(find.text('附上运动记录'), findsOneWidget);
    expect(find.text('5.2 km · 31:20'), findsOneWidget);
    expect(find.text('0/500'), findsOneWidget);
    expect(find.textContaining('200 m 内会自动隐藏'), findsOneWidget);
    expect(find.textContaining('动态先过审核'), findsOneWidget);

    await t.enterText(find.byKey(const Key('compose-text')), '今晚夜跑，滨江公园拿下 #夜跑');
    await t.pump();
    expect(find.text('15/500'), findsOneWidget);

    await t.tap(find.byKey(const Key('add-photo')));
    await idle(t);
    expect(picker.picks, 1);
    expect(fake.countCalls('POST', '/v1/media'), 2);
    final form = fake.lastCall('POST', '/v1/media')!.data as FormData;
    expect(form.fields.any((e) => e.key == 'purpose' && e.value == 'post'), isTrue);
    expect(form.files.single.key, 'file');
    expect(find.text('2/9'), findsOneWidget);

    await t.tap(find.text('仅粉丝'));
    await t.pump();
    await shot(t, 'composer');

    // content_blocked → dialog, nothing published.
    fake.postError = 'content_blocked';
    await t.tap(find.widgetWithText(FilledButton, '发布'));
    await idle(t);
    expect(find.text('内容未通过检查'), findsOneWidget);
    await t.tap(find.text('知道了'));
    await t.pumpAndSettle();

    // invalid_media → uploads dropped, tap to retry.
    fake.postError = 'invalid_media';
    await t.tap(find.widgetWithText(FilledButton, '发布'));
    await idle(t);
    expect(find.text('图片无效'), findsOneWidget);
    await t.tap(find.text('知道了'));
    await t.pumpAndSettle();
    expect(find.text('上传失败，点击重试'), findsNWidgets(2));
    await t.tap(find.text('上传失败，点击重试').first);
    await idle(t);
    expect(fake.countCalls('POST', '/v1/media'), 4);

    fake.postError = null;
    await t.tap(find.widgetWithText(FilledButton, '发布'));
    await idle(t);
    final body = fake.lastCall('POST', '/v1/posts')!.data as Map;
    expect(body['content'], '今晚夜跑，滨江公园拿下 #夜跑');
    expect(body['image_ids'], [202, 203]);
    expect(body['activity_id'], 56);
    expect(body['visibility'], 'fans');
    // Opened directly: lands on 关注 with the new post.
    expect(find.text('关注'), findsOneWidget);
    await settle(t);
    sem.dispose();
  });

  testWidgets('composer: muted shows the end time', (t) async {
    final sem = t.ensureSemantics();
    await phone(t);
    final fake = CommunityFake()..postError = 'muted';
    final u = User.fromJson(j(userJson)..['muted_until'] = '2099-01-02T10:00:00+08:00');
    await t.pumpWidget(routed('/posts/new', fakeBackend(user: u, handlers: [fake.handle])));
    await idle(t);
    await t.enterText(find.byKey(const Key('compose-text')), 'hi');
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, '发布'));
    await idle(t);
    expect(find.text('暂时不能发布'), findsOneWidget);
    expect(find.textContaining('解除时间'), findsOneWidget);
    await t.tap(find.text('知道了'));
    await t.pumpAndSettle();
    await settle(t);
    sem.dispose();
  });

  testWidgets('profile: header, counts, follow, 私信, block with confirm, followers list', (t) async {
    final sem = t.ensureSemantics();
    await phone(t, size: const Size(390, 1300));
    final fake = CommunityFake();
    await t.pumpWidget(routed('/users/7', fakeBackend(handlers: [fake.handle])));
    await idle(t);
    expect(find.text('Kai'), findsWidgets);
    expect(find.text('自由圈地爱好者，东港一带都是我的'), findsOneWidget);
    expect(find.text('3.2K'), findsOneWidget);
    expect(find.text('18.6K'), findsOneWidget);
    expect(find.text('6.12'), findsOneWidget);
    expect(find.text('1203.4'), findsOneWidget);
    expect(find.text('TA 的动态'), findsOneWidget);
    expect(find.textContaining('东港这一带今晚归我'), findsOneWidget);
    await shot(t, 'profile');

    await t.tap(find.text('回关'));
    await idle(t);
    expect(fake.countCalls('POST', '/v1/users/7/follow'), 1);
    expect(find.text('互相关注'), findsOneWidget);
    expect(find.text('3.2K'), findsOneWidget);

    await t.tap(find.text('私信'));
    await t.pumpAndSettle();
    expect(find.text('chat with 7'), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    // Block: confirm dialog, then posts disappear and 私信 / follow go away.
    await t.tap(find.byTooltip('更多').first);
    await t.pumpAndSettle();
    await t.tap(find.text('拉黑'));
    await t.pumpAndSettle();
    expect(find.text('拉黑 Kai？'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, '拉黑'));
    await idle(t);
    expect(fake.countCalls('POST', '/v1/users/7/block'), 1);
    expect(find.text('你已拉黑对方'), findsOneWidget);
    expect(find.text('你已拉黑对方，看不到 TA 的动态'), findsOneWidget);
    expect(find.text('私信'), findsNothing);

    // Followers list.
    await t.tap(find.text('粉丝'));
    await idle(t);
    expect(find.text('小鹿'), findsOneWidget);
    expect(find.text('小鹿'), findsOneWidget);
    await settle(t);
    sem.dispose();
  });

  testWidgets('me: E-01 counts and edit profile (avatar upload, bio)', (t) async {
    final sem = t.ensureSemantics();
    await phone(t, size: const Size(390, 1400));
    final fake = CommunityFake();
    final patched = <Map>[];
    await t.pumpWidget(routed('/me', [
      ...fakeBackend(handlers: [
        fake.handle,
        (o) {
          if (o.path == '/v1/me' && o.method == 'PATCH') {
            patched.add(o.data as Map);
            return (200, j(userJson)..['nickname'] = '阿杰');
          }
          return null;
        },
      ]),
      mediaPickerProvider.overrideWithValue(FakePicker()),
    ]));
    await idle(t);
    expect(find.text('关注'), findsOneWidget);
    expect(find.text('86'), findsOneWidget);
    expect(find.text('312'), findsOneWidget);
    expect(find.text('4.8K'), findsOneWidget);
    expect(find.text('发动态'), findsOneWidget);
    expect(find.text('黑名单'), findsOneWidget);
    await shot(t, 'me');

    await t.tap(find.text('编辑'));
    await idle(t);
    expect(find.text('编辑资料'), findsOneWidget);
    expect(find.text('每天 5 公里'), findsOneWidget);
    await t.tap(find.byIcon(Icons.photo_camera_outlined));
    await idle(t);
    expect((fake.lastCall('POST', '/v1/media')!.data as FormData).fields.any((e) => e.key == 'purpose' && e.value == 'avatar'), isTrue);
    expect(patched.single, {'avatar_url': 'http://x/media/200.jpg'});
    expect(find.textContaining('头像已更新，审核中'), findsWidgets);
    await t.enterText(find.byKey(const Key('edit-bio')), '每天 10 公里');
    await t.tap(find.text('保存'));
    await idle(t);
    expect(patched.last, {'bio': '每天 10 公里'});
    await settle(t);
    sem.dispose();
  });

  testWidgets('replay: vertical pages, animated track, like, member export', (t) async {
    final sem = t.ensureSemantics();
    await phone(t);
    final fake = CommunityFake();
    await t.pumpWidget(routed('/replays', fakeBackend(handlers: [fake.handle])));
    await idle(t);
    expect(find.text('轨迹回放'), findsOneWidget);
    expect(find.text('Kai'), findsOneWidget);
    expect(find.text('1.3K'), findsOneWidget);
    // Member (plan carries hd_replay_export) sees the export button.
    expect(find.text('导出 1080p 视频'), findsOneWidget);
    // 3432 s run → ~22 s playback; halfway the stats are about half.
    await t.pump(const Duration(seconds: 11));
    expect(find.textContaining(RegExp(r'^5\.\d\d km$')), findsOneWidget);
    await shot(t, 'replay');

    await t.tap(find.byTooltip('点赞'));
    await idle(t, 1);
    expect(fake.countCalls('POST', '/v1/posts/101/like'), 1);
    expect(find.byTooltip('取消点赞'), findsOneWidget);

    await t.tap(find.text('导出 1080p 视频'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('即将上线'), findsOneWidget);
    await t.tap(find.text('好的'));
    await t.pump(const Duration(milliseconds: 300));

    // Swipe up to the next replay.
    await t.drag(find.byType(PageView), const Offset(0, -700));
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('小鹿'), findsOneWidget);
    await settle(t);
    sem.dispose();
  });

  testWidgets('replay: non-members do not see export', (t) async {
    final sem = t.ensureSemantics();
    await phone(t);
    final fake = CommunityFake();
    final u = User.fromJson(j(userJson)..['membership'] = null);
    await t.pumpWidget(routed('/replays/activity/55', fakeBackend(user: u, handlers: [fake.handle])));
    await idle(t);
    expect(find.text('Kai'), findsOneWidget);
    expect(find.text('导出 1080p 视频'), findsNothing);
    expect(fake.countCalls('GET', '/v1/activities/55/replay'), 1);
    await settle(t);
    sem.dispose();
  });

  test('models parse the contract shapes', () {
    final fake = CommunityFake();
    final p = Post.fromJson(fake.posts[101]!);
    expect(p.author.nickname, 'Kai');
    expect(p.activity!.track.length, 120);
    expect(p.activity!.durationSec, 3432);
    final mine = Post.fromJson(fake.posts[105]!);
    expect(mine.reviewStatus, ReviewStatus.rejected);
    expect(mine.rejectReason, '含联系方式');
  });
}
