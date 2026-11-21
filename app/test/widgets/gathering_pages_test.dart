// V2 batch 2「社区」gatherings & messages: community home, 消息, 聊天 (incl.
// realtime), 组局, 集结跑签到, 赛事, 跑团邀请码 / 编辑, settlement extras.
// With LOOPLAND_SCREENSHOTS=1 they write PNGs to app/screenshots/v2/.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:loopland/api/models.dart' show ActivityResult;
import 'package:loopland/core/theme.dart';
import 'package:loopland/features/chat/pick_image.dart';
import 'package:loopland/features/community/community_page.dart';
import 'package:loopland/features/community/crew_pages.dart';
import 'package:loopland/features/community/gathering_routes.dart';
import 'package:loopland/features/inbox/inbox_page.dart';
import 'package:loopland/features/run/result_page.dart';
import 'package:loopland/map/territory_map.dart';
import 'package:loopland/realtime/realtime_client.dart';
import 'package:loopland/realtime/realtime_providers.dart';
import 'package:loopland/run/location_source.dart';
import 'package:loopland/run/run_controller.dart';
import 'package:material_ui/material_ui.dart';

import '../api/fixtures.dart';
import '../realtime/realtime_client_test.dart' show FakeChannel;
import 'fake_backend.dart';
import 'gathering_fake.dart';
import 'screens_test.dart' show fixAt;
import 'test_helpers.dart';
import 'v2_pages_test.dart' show fakeRealtime;

/// Pages owned by other features, shown as a stub with their location.
class _Stub extends StatelessWidget {
  const _Stub(this.loc);
  final String loc;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            IconButton(onPressed: () => Navigator.of(context).maybePop(), icon: const Icon(Icons.arrow_back_ios_new_rounded)),
            Expanded(child: Center(child: Text('STUB $loc'))),
          ]),
        ),
      );
}

GoRoute _stub(String path) => GoRoute(path: path, builder: (_, s) => _Stub(s.uri.toString()));

/// The real gathering routes inside a GoRouter, plus stubs for the routes
/// owned elsewhere (posts / users / city / bosses / feed / league / start).
Widget routedApp(String initial, List<Override> overrides) {
  final router = GoRouter(initialLocation: initial, routes: [
    GoRoute(path: '/community', builder: (_, _) => const CommunityPage()),
    GoRoute(path: '/inbox', builder: (_, _) => const InboxPage()),
    ...gatheringRoutes(),
    GoRoute(path: '/crews/search', builder: (_, _) => const CrewSearchPage()),
    GoRoute(path: '/crews/:id', builder: (_, s) => CrewDetailPage(crewId: int.parse(s.pathParameters['id']!))),
    for (final p in ['/posts/:id', '/users/:id', '/city/:id', '/bosses/:id', '/community/feed', '/league', '/start', '/crews/new'])
      _stub(p),
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

late GatheringFake fake;
late RealtimeClient rt;
late List<FakeChannel> chans;

List<Override> overrides({LocationSource? loc, Map<String, Object?> extra = const {}}) => [
      ...fakeBackend(handlers: [fake.handle], extra: extra),
      realtimeClientProvider.overrideWithValue(rt),
      locationSourceProvider.overrideWithValue(loc ?? FakeLocationSource([fixAt(0, 0, 0)])),
      singleImagePickerProvider.overrideWithValue(({bool camera = false}) async => (bytes: Uint8List(16), name: 'a.jpg')),
    ];

Future<void> shot(WidgetTester t, String name) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await t.pump();
  await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/$name.png');
}

/// Taps the BackHeader back button of the top page.
Future<void> back(WidgetTester t) async {
  await t.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).last);
  await idle(t, 2);
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> tapAndIdle(WidgetTester t, Finder f, [int rounds = 3]) async {
  // Floating snackbars from the previous action would swallow taps on the
  // bottom buttons.
  for (final m in t.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
    m.removeCurrentSnackBar();
  }
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 100));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await idle(t, rounds);
  // Finish route / sheet transitions.
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(() async {
    TerritoryMapView.forceFallback = true;
    await loadFonts();
  });

  setUp(() {
    fake = GatheringFake();
    final r = fakeRealtime();
    rt = r.$1;
    chans = r.$2;
  });

  tearDown(() async {
    await rt.dispose();
  });

  testWidgets('社区首页: crew card, entries with unread, rallies / meetups / races; entries navigate', (t) async {
    await phone(t, size: const Size(390, 1500));
    await t.pumpWidget(routedApp('/community', overrides()));
    await idle(t);
    expect(fake.calls, contains('GET /v1/community/home'));
    expect(find.text('城西跑团'), findsWidgets);
    expect(find.text('团内 #2'), findsOneWidget);
    expect(find.text('0.05 km²'), findsOneWidget);
    expect(find.text('组局'), findsOneWidget);
    expect(find.text('已报名 1 个局'), findsOneWidget);
    expect(find.text('动态'), findsOneWidget);
    expect(find.text('赛事 · 城市 10K 线上赛'), findsOneWidget);
    expect(find.text('3 条互动 · 5 条私信'), findsOneWidget);
    expect(find.text('8'), findsOneWidget); // unread badge 3 + 5
    expect(find.text('跑团集结跑'), findsOneWidget);
    expect(find.text('周三夜跑'), findsOneWidget);
    expect(find.text('我报名的组局'), findsOneWidget);
    expect(find.text('周六世纪公园约跑'), findsOneWidget);
    expect(find.text('已报名'), findsOneWidget);
    await shot(t, 'community_home');

    await tapAndIdle(t, find.byKey(const Key('entry_feed')));
    expect(find.text('STUB /community/feed'), findsOneWidget);
    await back(t);
    await idle(t, 1);
    await tapAndIdle(t, find.byKey(const Key('entry_races')));
    expect(find.text('赛事中心'), findsOneWidget);
    await settle(t);
  });

  testWidgets('社区首页 without a crew: join / create / invite code CTA', (t) async {
    await phone(t);
    fake.home = {...fake.home, 'crew': null, 'rallies': [], 'meetups': [], 'races': [], 'unread': {'interaction': 0, 'chat': 0}};
    await t.pumpWidget(routedApp('/community', overrides()));
    await idle(t);
    expect(find.text('还没有跑团'), findsOneWidget);
    expect(find.text('找跑团'), findsOneWidget);
    expect(find.text('创建跑团'), findsOneWidget);
    expect(find.text('约跑 · 约球 · 约骑'), findsOneWidget);
    await tapAndIdle(t, find.text('有邀请码？输入加入'));
    expect(find.text('邀请码加入'), findsOneWidget);
    // Wrong code → server message; right code → crew page.
    await t.enterText(find.byKey(const Key('invite_input')), 'zzzz99');
    await tapAndIdle(t, find.text('加入跑团'));
    expect(find.text('邀请码无效或已过期'), findsWidgets);
    await t.enterText(find.byKey(const Key('invite_input')), '8k2d9q');
    await tapAndIdle(t, find.text('加入跑团'));
    expect(fake.bodies['POST /v1/crews/join-by-code'], {'code': '8K2D9Q'});
    expect(find.text('管理跑团'), findsOneWidget); // crew detail (leader)
    await settle(t);
  });

  testWidgets('消息: category unread counts, filters, conversations, navigation by data.type', (t) async {
    await phone(t, size: const Size(390, 1300));
    await t.pumpWidget(routedApp('/inbox', overrides()));
    await idle(t);
    expect(find.text('消息'), findsOneWidget);
    expect(find.text('6 条未读'), findsOneWidget); // 2 + 1 + 0 + 0 notifications, 3 chat
    expect(find.text('互动'), findsOneWidget);
    expect(find.text('领地'), findsOneWidget);
    expect(find.text('怪兽'), findsOneWidget);
    expect(find.text('系统'), findsOneWidget);
    expect(find.text('周六世纪公园约跑 · 群聊'), findsOneWidget);
    expect(find.text('小鹿：周六 06:50 东门集合'), findsOneWidget);
    expect(find.text('Kai'), findsOneWidget);
    expect(find.text('Kai 赞了你的动态'), findsOneWidget);
    expect(find.text('回关'), findsOneWidget);
    expect(find.text('沙发怪出现在你附近'), findsOneWidget);
    await shot(t, 'inbox');

    // 互动 filter.
    await tapAndIdle(t, find.byKey(const Key('cat_interaction')));
    expect(find.text('互动通知'), findsOneWidget);
    expect(find.text('沙发怪出现在你附近'), findsNothing);
    expect(find.text('阿珍 关注了你'), findsOneWidget);

    // like_post → /posts/101 (marks read first).
    await tapAndIdle(t, find.text('Kai 赞了你的动态'));
    expect(fake.bodies['POST /v1/inbox/read'], {'ids': [31]});
    expect(find.text('STUB /posts/101'), findsOneWidget);
    await back(t);
    await idle(t, 1);
    // follow → /users/11.
    await tapAndIdle(t, find.text('阿珍 关注了你'));
    expect(find.text('STUB /users/11'), findsOneWidget);
    await back(t);
    await idle(t, 1);

    // Back to 全部 → monster item → /bosses/3; race_finished → /races/2.
    await tapAndIdle(t, find.byKey(const Key('cat_interaction')));
    await tapAndIdle(t, find.text('沙发怪出现在你附近'));
    expect(find.text('STUB /bosses/3'), findsOneWidget);
    await back(t);
    await idle(t, 1);

    // A new chat message over the socket refreshes the summary.
    final before = fake.calls.where((c) => c == 'GET /v1/inbox/summary').length;
    await t.runAsync(() async => rt.start());
    await idle(t, 1);
    chans.single.push({
      'type': 'chat_message',
      'message': {'id': 90, 'conversation_id': 6, 'sender': gKai, 'type': 'text', 'content': '在吗', 'payload': {}, 'created_at': '2026-11-21T10:00:00Z'},
    });
    await idle(t);
    expect(fake.calls.where((c) => c == 'GET /v1/inbox/summary').length, greaterThan(before));

    // Conversation list page.
    await tapAndIdle(t, find.text('全部'));
    expect(find.text('私信 · 群聊'), findsOneWidget);
    expect(find.text('周三夜跑 · 群聊'), findsOneWidget);
    await settle(t);
  });

  testWidgets('聊天: history, system / post / text bubbles, send, errors, realtime message, read receipt, mute, leave', (t) async {
    await phone(t);
    await t.pumpWidget(routedApp('/chat/4', overrides()));
    await t.runAsync(() async => rt.start());
    await idle(t);
    // Header found from the conversation list (no GET /v1/conversations/{id}).
    expect(fake.calls, contains('GET /v1/conversations'));
    expect(find.text('周六世纪公园约跑'), findsOneWidget);
    expect(find.text('组局群聊'), findsOneWidget);
    expect(find.text('周六 06:50 东门集合'), findsOneWidget);
    expect(find.text('Kai 加入了群聊'), findsOneWidget);
    expect(find.text('分享了一条动态'), findsOneWidget);
    expect(find.text('我带两瓶水'), findsOneWidget);
    // Marked read up to the newest message.
    expect(fake.bodies['POST /v1/conversations/4/read'], {'message_id': 77});
    await shot(t, 'chat');

    // Send a text.
    await t.enterText(find.byKey(const Key('chat_input')), '我也来！');
    await tapAndIdle(t, find.byTooltip('发送'));
    expect(fake.bodies['POST /v1/conversations/4/messages'], {'type': 'text', 'content': '我也来！'});
    expect(find.text('我也来！'), findsOneWidget);

    // content_blocked keeps the text and shows the reason.
    await t.enterText(find.byKey(const Key('chat_input')), '加我微信 abc');
    await tapAndIdle(t, find.byTooltip('发送'));
    expect(find.byKey(const Key('chat_error')), findsOneWidget);
    expect(find.textContaining('消息包含联系方式，未发送'), findsOneWidget);
    expect(find.text('加我微信 abc'), findsOneWidget);

    // Image: pick → upload (purpose chat) → send image_id.
    await tapAndIdle(t, find.byTooltip('发图片'));
    expect(fake.calls, contains('POST /v1/media'));
    expect(fake.bodies['POST /v1/conversations/4/messages'], {'type': 'image', 'image_id': 12});

    // Realtime: a message from 小鹿 arrives and is marked read.
    chans.single.push({
      'type': 'chat_message',
      'message': {'id': 2000, 'conversation_id': 4, 'sender': gDeer, 'type': 'text', 'content': '记得带头灯', 'payload': {}, 'created_at': DateTime.now().toUtc().toIso8601String()},
    });
    // …and one for another conversation is ignored here.
    chans.single.push({
      'type': 'chat_message',
      'message': {'id': 2001, 'conversation_id': 6, 'sender': gKai, 'type': 'text', 'content': '别的会话', 'payload': {}, 'created_at': DateTime.now().toUtc().toIso8601String()},
    });
    await idle(t);
    expect(find.text('记得带头灯'), findsOneWidget);
    expect(find.text('别的会话'), findsNothing);
    expect(fake.bodies['POST /v1/conversations/4/read'], {'message_id': 2000});

    // Mute via the menu.
    await tapAndIdle(t, find.byTooltip('更多'));
    await t.pumpAndSettle();
    await tapAndIdle(t, find.text('消息免打扰'));
    expect(fake.bodies['POST /v1/conversations/4/mute'], {'muted': true});
    expect(find.text('组局群聊 · 免打扰'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));

    // Leave the group.
    await tapAndIdle(t, find.byTooltip('更多'));
    await t.pumpAndSettle();
    await tapAndIdle(t, find.text('退出群聊'));
    await t.pumpAndSettle();
    expect(find.textContaining('组局报名也会一并取消'), findsOneWidget);
    await tapAndIdle(t, find.text('退出'));
    expect(fake.calls, contains('DELETE /v1/conversations/4'));
    await settle(t);
  });

  testWidgets('私信: older pages with before, read receipt from conversation_read', (t) async {
    await phone(t);
    await t.pumpWidget(routedApp('/chat/6', overrides()));
    await t.runAsync(() async => rt.start());
    await idle(t);
    expect(find.text('Kai'), findsWidgets);
    expect(find.text('桥下那条线你跑过吗'), findsOneWidget);
    // My newest message (id 299) is delivered, not yet read.
    expect(find.text('已送达'), findsOneWidget);
    chans.single.push({'type': 'conversation_read', 'conversation_id': 6, 'user_id': 7, 'message_id': 299});
    await idle(t, 2);
    expect(find.text('已读'), findsOneWidget);
    expect(find.text('已送达'), findsNothing);

    // Scroll up → GET …/messages?before=271.
    await t.drag(find.byType(ListView), const Offset(0, 3000));
    await idle(t);
    await t.drag(find.byType(ListView), const Offset(0, 3000));
    await idle(t);
    expect(find.text('更早的第 1 条'), findsOneWidget);
    await settle(t);
  });

  testWidgets('私信 from a profile: /chat/direct/:userId, stranger_limit and blocked', (t) async {
    await phone(t);
    await t.pumpWidget(routedApp('/chat/direct/11', overrides()));
    await idle(t);
    expect(fake.bodies['POST /v1/conversations/direct'], {'user_id': 11});
    expect(find.text('阿珍'), findsOneWidget);
    expect(find.text('打个招呼吧'), findsOneWidget);
    for (var i = 1; i <= 4; i++) {
      await t.enterText(find.byKey(const Key('chat_input')), '你好 $i');
      await tapAndIdle(t, find.byTooltip('发送'), 2);
    }
    expect(find.text('你好 3'), findsOneWidget);
    expect(find.textContaining('对方回复前最多发 3 条消息'), findsOneWidget);
    expect(find.textContaining('对方回复或关注你之后'), findsOneWidget);
    await settle(t);

    await t.pumpWidget(routedApp('/chat/direct/66', overrides()));
    await idle(t);
    expect(find.text('对方已把你拉黑，无法私信'), findsOneWidget);
    await settle(t);
  });

  testWidgets('组局: nearby with distance, type filter, join, detail with members, 进群聊; my meetups', (t) async {
    await phone(t, size: const Size(390, 1100));
    await t.pumpWidget(routedApp('/meetups', overrides()));
    await idle(t, 4);
    final q = fake.calls.where((c) => c == 'GET /v1/meetups');
    expect(q, isNotEmpty);
    expect(find.text('周六世纪公园约跑'), findsOneWidget);
    expect(find.textContaining('世纪公园 3 号门 · 3.20 km'), findsOneWidget);
    expect(find.text('匹克球双打 · 还差 2 人'), findsOneWidget);
    expect(find.text('已满员'), findsOneWidget);
    await shot(t, 'meetups');

    await tapAndIdle(t, find.text('约球').first);
    expect(find.text('周六世纪公园约跑'), findsNothing);
    expect(find.text('匹克球双打 · 还差 2 人'), findsOneWidget);
    await tapAndIdle(t, find.text('加入'));
    expect(fake.calls, contains('POST /v1/meetups/9/join'));
    expect(find.text('已报名'), findsOneWidget);

    await tapAndIdle(t, find.text('全部'));
    await tapAndIdle(t, find.text('周六世纪公园约跑'));
    expect(find.text('约跑 · 组局'), findsOneWidget);
    expect(find.text('配速 6 分左右，跑 10 公里，跑完一起吃早饭'), findsOneWidget);
    expect(find.text('小鹿·发起'), findsOneWidget);
    expect(find.text('阿珍'), findsOneWidget);
    expect(find.text('报名加入'), findsOneWidget);
    await shot(t, 'meetup_detail');
    await tapAndIdle(t, find.text('报名加入'));
    expect(find.text('进群聊'), findsOneWidget);
    expect(find.text('退出'), findsOneWidget);
    await tapAndIdle(t, find.text('进群聊'));
    expect(find.byKey(const Key('chat_input')), findsOneWidget);
    await back(t);
    await idle(t, 1);
    await back(t);
    await idle(t, 1);

    await tapAndIdle(t, find.text('我的'));
    expect(fake.calls, contains('GET /v1/me/meetups'));
    expect(find.text('周六世纪公园约跑'), findsOneWidget);
    await settle(t);
  });

  testWidgets('发起组局: form, map place picker, validation, review-pending result', (t) async {
    await phone(t, size: const Size(390, 1000));
    await t.pumpWidget(routedApp('/meetups/new', overrides()));
    await idle(t);
    expect(find.text('发起组局'), findsOneWidget);
    await tapAndIdle(t, find.text('发起'));
    expect(find.text('请在地图上选择集合地点'), findsOneWidget);

    await tapAndIdle(t, find.byKey(const Key('meetup_place')));
    expect(find.text('拖动地图，让图钉对准集合点'), findsOneWidget);
    await shot(t, 'place_picker');
    await t.enterText(find.byKey(const Key('place_name')), '徐家汇公园东门');
    await tapAndIdle(t, find.text('确定'));
    expect(find.text('徐家汇公园东门'), findsOneWidget);

    await tapAndIdle(t, find.text('发起'));
    expect(find.text('请填写标题'), findsOneWidget);
    await tapAndIdle(t, find.text('约骑'));
    await t.enterText(find.byKey(const Key('meetup_title')), '周日骑行');
    await t.enterText(find.byKey(const Key('meetup_desc')), '联系我 13800000000');
    await shot(t, 'meetup_create');
    await tapAndIdle(t, find.text('发起'));
    final body = fake.bodies['POST /v1/meetups']! as Map;
    expect(body['type'], 'ride');
    expect(body['title'], '周日骑行');
    expect(body['capacity'], 10);
    expect((body['place'] as Map)['name'], '徐家汇公园东门');
    expect(DateTime.parse(body['end_time'] as String).difference(DateTime.parse(body['start_time'] as String)),
        const Duration(hours: 2));
    expect(find.text('已提交，审核通过后会出现在附近列表'), findsOneWidget);
    await settle(t);
  });

  testWidgets('集结跑 in the crew page: bonus state, check-in errors and success, leader create, invite code', (t) async {
    await phone(t, size: const Size(390, 2000));
    // Far from the 徐家汇公园 meeting point (50, 40) first.
    final loc = _MovableLocation(fixAt(2000, 2000, 0));
    await t.pumpWidget(routedApp('/crews/3', overrides(loc: loc)));
    await idle(t, 4);
    expect(find.text('集结跑'), findsWidgets);
    expect(find.text('周三夜跑'), findsOneWidget);
    expect(find.text('周末长距离'), findsOneWidget);
    expect(find.byKey(const Key('rally_bonus_off')), findsNWidgets(2));
    expect(find.text('签到满 2 人激活加成（当前 1 人）'), findsOneWidget);
    expect(find.text('邀请成员'), findsOneWidget);
    expect(find.text('编辑跑团'), findsOneWidget);
    await shot(t, 'crew_rally');

    await tapAndIdle(t, find.text('到场签到'));
    await t.pumpAndSettle();
    expect(find.text('暂时不能签到'), findsOneWidget);
    expect(find.textContaining('走到 300 米内再签到'), findsOneWidget);
    await t.tap(find.text('知道了'));
    await t.pumpAndSettle();

    loc.fix = fixAt(60, 40, 0);
    await tapAndIdle(t, find.text('到场签到'));
    final b = fake.bodies['POST /v1/rallies/5/checkin']! as Map;
    expect(b.keys, containsAll(['lat', 'lng']));
    expect(find.text('已签到'), findsOneWidget);
    expect(find.byKey(const Key('rally_bonus_on')), findsOneWidget);
    expect(find.textContaining('集结加成生效'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));

    // 报名 the other rally.
    await tapAndIdle(t, find.text('报名'));
    expect(fake.calls, contains('POST /v1/rallies/6/join'));

    // Invite code sheet.
    await tapAndIdle(t, find.text('邀请成员'));
    await t.pumpAndSettle();
    expect(find.text('8K2D9Q'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    await t.tapAt(const Offset(20, 20));
    await t.pumpAndSettle();

    // Leader creates a rally.
    await tapAndIdle(t, find.byKey(const Key('rally_new')));
    expect(find.text('发起集结跑'), findsOneWidget);
    await t.enterText(find.byKey(const Key('rally_title')), '周五晨跑');
    await tapAndIdle(t, find.byKey(const Key('rally_place')));
    await t.enterText(find.byKey(const Key('place_name')), '徐家汇公园');
    await tapAndIdle(t, find.text('确定'));
    await tapAndIdle(t, find.text('10 km'));
    await tapAndIdle(t, find.text('发起'));
    final rb = fake.bodies['POST /v1/crews/3/rallies']! as Map;
    expect(rb['title'], '周五晨跑');
    expect(rb['distance_goal_m'], 10000);
    expect(find.text('周五晨跑'), findsOneWidget);
    await settle(t);
  });

  testWidgets('编辑跑团: name, avatar upload (crew_avatar), join mode; post-moderation note', (t) async {
    await phone(t);
    await t.pumpWidget(routedApp('/crews/3/edit', overrides()));
    await idle(t);
    expect(find.textContaining('名称和头像修改后立即生效'), findsOneWidget);
    await t.enterText(find.byKey(const Key('crew_name')), '城西夜跑团');
    await tapAndIdle(t, find.byIcon(Icons.photo_camera_outlined));
    expect(fake.calls, contains('POST /v1/media'));
    await tapAndIdle(t, find.text('申请'));
    await tapAndIdle(t, find.text('保存'));
    expect(fake.bodies['PATCH /v1/crews/3'], {'name': '城西夜跑团', 'avatar_id': 12, 'join_mode': 'apply'});
    await settle(t);
  });

  testWidgets('赛事: list by status, detail (rules, wearable, medal, leaderboard), signup / cancel, my result', (t) async {
    await phone(t, size: const Size(390, 1400));
    await t.pumpWidget(routedApp('/races', overrides()));
    await idle(t);
    expect(find.text('赛事中心'), findsOneWidget);
    expect(find.text('城区联赛'), findsOneWidget);
    expect(find.text('城市 10K 线上赛'), findsOneWidget);
    expect(find.text('滨江半程马拉松'), findsNothing); // 报名中 only
    await shot(t, 'races');
    await tapAndIdle(t, find.text('全部'));
    expect(find.text('滨江半程马拉松'), findsOneWidget);
    expect(find.text('秋季 5K'), findsOneWidget);

    await tapAndIdle(t, find.text('城市 10K 线上赛'));
    expect(find.text('需穿戴设备'), findsOneWidget);
    expect(find.byKey(const Key('race_wearable')), findsOneWidget);
    expect(find.text('城市 10K 完赛奖牌'), findsOneWidget);
    expect(find.text('排行榜 · 用时'), findsOneWidget);
    expect(find.text('40:00'), findsOneWidget);
    expect(find.text('10 km'), findsOneWidget);
    await shot(t, 'race_detail');
    await tapAndIdle(t, find.text('立即报名（免费）'));
    expect(fake.calls, contains('POST /v1/races/2/signup'));
    expect(find.byKey(const Key('race_my_entry')), findsOneWidget);
    expect(find.text('取消报名'), findsOneWidget);
    await tapAndIdle(t, find.text('取消报名'));
    expect(fake.calls, contains('DELETE /v1/races/2/signup'));
    expect(find.text('立即报名（免费）'), findsOneWidget);
    await back(t);
    await idle(t, 1);

    await tapAndIdle(t, find.text('秋季 5K'));
    expect(find.text('我的成绩 · 完赛 27:30'), findsOneWidget);
    expect(find.textContaining('第 35 名'), findsOneWidget);
    expect(find.text('阿杰（我）'), findsOneWidget);
    expect(find.text('已完赛'), findsOneWidget);
    await settle(t);
  });

  testWidgets('settlement shows the rally bonus and finished races', (t) async {
    await phone(t, size: const Size(390, 1800));
    final m = j(activityResultJson);
    (m['settlement'] as Map).addAll(<String, dynamic>{
      'rally': {'id': 5, 'bonus_rate': 0.2},
      'races': [
        {'id': 2, 'title': '城市 10K 线上赛', 'result_sec': 3120, 'medal': {'key': 'race_2026_city10k', 'name': '城市 10K 完赛奖牌', 'image_url': null}},
      ],
    });
    final r = ActivityResult.fromJson(m);
    expect(r.settlement.rally!.bonusRate, 0.2);
    expect(r.settlement.races.single.medalName, '城市 10K 完赛奖牌');
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(ResultPage(args: ResultArgs(result: r)), overrides: overrides()),
    ));
    await idle(t);
    expect(find.text('集结跑加成'), findsOneWidget);
    expect(find.text('这次运动的合击伤害和能量 ×1.2'), findsOneWidget);
    expect(find.text('+20%'), findsOneWidget);
    expect(find.text('赛事完赛'), findsOneWidget);
    expect(find.text('城市 10K 线上赛 完赛！'), findsOneWidget);
    expect(find.text('成绩 52:00 · 获得「城市 10K 完赛奖牌」'), findsOneWidget);
    await settle(t);
  });
}

/// Location source whose fix the test can move.
class _MovableLocation implements LocationSource {
  _MovableLocation(this.fix);
  Fix fix;
  @override
  Future<LocationPermissionResult> ensurePermission() async => LocationPermissionResult.granted;
  @override
  Stream<Fix> watch() => Stream.value(fix);
  @override
  Future<Fix?> current() async => fix;
  @override
  Future<void> openSettings() async {}
}
