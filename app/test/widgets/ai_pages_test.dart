// V2 batch 3「AI」(App part 1): assistant (streaming, cards, quota, errors,
// photos, history, 问 AI), AI routes on the 开跑 page + guide on the run page,
// AI 战报 on the settlement page + composer. With LOOPLAND_SCREENSHOTS=1 they
// write PNGs to app/screenshots/v2/ai_*.png.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:loopland/api/community_models.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/features/ai/ai_providers.dart';
import 'package:loopland/features/ai/ai_routes.dart';
import 'package:loopland/features/chat/pick_image.dart';
import 'package:loopland/features/map/map_page.dart';
import 'package:loopland/features/play/boss_page.dart';
import 'package:loopland/features/run/result_page.dart';
import 'package:loopland/features/run/run_page.dart';
import 'package:loopland/features/social/post_card.dart';
import 'package:loopland/features/social/social_routes.dart';
import 'package:loopland/features/start/gps_setup_page.dart';
import 'package:loopland/map/territory_map.dart';
import 'package:loopland/run/location_source.dart';
import 'package:loopland/run/run_controller.dart';
import 'package:material_ui/material_ui.dart';

import '../api/fixtures.dart' show activityResultJson, j;
import 'ai_fake.dart';
import 'community_fake.dart';
import 'fake_backend.dart';
import 'screens_test.dart' show fixAt;
import 'social_pages_test.dart' show FakePicker;
import 'test_helpers.dart';

class _MapStub extends ConsumerWidget {
  const _MapStub();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ref.watch(mapFocusProvider);
    return Scaffold(body: Center(child: Text('map focus ${f?.territoryId}')));
  }
}

/// The AI routes plus the pages they lead to (stand-ins where the real page
/// is not under test).
Widget aiApp(String initial, List<Override> overrides, {Object? extra}) {
  final router = GoRouter(initialLocation: initial, initialExtra: extra, routes: [
    ...aiRoutes(),
    ...socialRoutes(),
    GoRoute(
      path: '/start/gps',
      builder: (_, s) => GpsSetupPage(
        sport: s.uri.queryParameters['sport'] ?? 'run',
        aiRoute: s.extra is AIRouteLaunch ? (s.extra! as AIRouteLaunch).route : null,
        autostart: s.extra is AIRouteLaunch && (s.extra! as AIRouteLaunch).autostart,
      ),
    ),
    GoRoute(path: '/run', builder: (_, _) => const RunPage()),
    GoRoute(path: '/map', builder: (_, _) => const _MapStub()),
    GoRoute(path: '/start', builder: (_, _) => const Scaffold(body: Text('开始页'))),
    GoRoute(path: '/me', builder: (_, _) => const Scaffold(body: Text('我的'))),
    GoRoute(path: '/bosses/:id', builder: (_, s) => Scaffold(body: Text('boss ${s.pathParameters['id']}'))),
    GoRoute(path: '/membership', builder: (_, _) => const Scaffold(body: Text('会员页'))),
    GoRoute(path: '/result', builder: (_, s) => ResultPage(args: s.extra! as ResultArgs)),
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

List<Override> aiBackend(AiFake ai, {List<Override> more = const [], CommunityFake? community}) => [
      ...fakeBackend(handlers: [ai.handle, ?community?.handle], wrapAdapter: ai.adapter),
      locationSourceProvider.overrideWithValue(FakeLocationSource([fixAt(0, 0, 0)])),
      ...more,
    ];

Future<void> shot(WidgetTester t, String name) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await t.pump();
  await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/$name.png');
}

/// Lets sheets / dialogs / routes animate (pumpAndSettle would wait forever
/// on the spinners and typing dots).
Future<void> ui(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void _back(WidgetTester t) => GoRouter.of(t.element(find.byType(Scaffold).last)).pop();

Uint8List _sse(String event, Object data) => utf8.encode('event: $event\ndata: ${jsonEncode(data)}\n\n');

void main() {
  setUpAll(() async {
    TerritoryMapView.forceFallback = true;
    await loadFonts();
  });

  testWidgets('assistant: greeting, disclosure, streamed answer with live deltas and cards, quota', (t) async {
    await phone(t);
    final ai = AiFake()..chatMode = 'manual';
    await t.pumpWidget(aiApp('/ai', aiBackend(ai)));
    await idle(t);

    expect(find.text('圈圈 · AI 助手'), findsOneWidget);
    expect(find.textContaining('晚上好阿杰'), findsOneWidget);
    expect(find.text('今晚去哪抢地'), findsOneWidget); // suggestion chip
    expect(find.text('本周剩 2 次'), findsOneWidget);
    expect(find.textContaining('模型：通义千问'), findsOneWidget);
    expect(find.byTooltip('发图片'), findsOneWidget); // vision=true

    // Model disclosure sheet.
    await t.tap(find.byKey(const Key('ai-disclosure')));
    await ui(t);
    expect(find.text('关于 AI 助手'), findsOneWidget);
    expect(find.text('Beijing-XXXX-20240101'), findsOneWidget);
    expect(find.text('内容由 AI 生成，仅供参考'), findsOneWidget);
    await t.tapAt(const Offset(10, 10));
    await ui(t);

    await t.enterText(find.byKey(const Key('ai-input')), '今晚去哪抢地？');
    await t.tap(find.byTooltip('发送'));
    await idle(t);
    expect(ai.chats.single['content'], '今晚去哪抢地？');
    expect(ai.chats.single['lat'], isNotNull);
    expect(find.bySemanticsLabel('AI 正在输入'), findsOneWidget);
    expect(find.text('今晚去哪抢地？'), findsOneWidget); // my bubble

    // Deltas appear as they arrive.
    ai.sse!.add(_sse('delta', {'text': '往东绕滨江'}));
    await idle(t, 2);
    expect(find.textContaining('往东绕滨江', findRichText: true), findsOneWidget);
    expect(find.bySemanticsLabel('AI 正在输入'), findsNothing);
    ai.sse!.add(_sse('delta', {'text': '公园一圈。'}));
    ai.sse!.add(_sse('card', ai.cards[0]));
    await idle(t, 2);
    expect(find.textContaining('往东绕滨江公园一圈。', findRichText: true), findsOneWidget);
    expect(find.text('一键开跑'), findsOneWidget);
    ai.sse!.add(_sse('done', ai.doneFor('往东绕滨江公园一圈。')));
    ai.sse!.close().ignore(); // done already cancelled the stream
    await idle(t);

    expect(find.text('AI 推荐闭环'), findsOneWidget);
    expect(find.text('西岸草坪'), findsOneWidget); // territory card
    expect(find.text('沙发怪'), findsOneWidget); // boss card
    expect(find.text('内容由 AI 生成'), findsWidgets);
    expect(find.text('本周剩 1 次'), findsOneWidget);
    await shot(t, 'ai_assistant');
    await settle(t);
  });

  testWidgets('assistant: done.message wins over streamed text (output moderation)', (t) async {
    await phone(t);
    final ai = AiFake()..chatMode = 'manual';
    await t.pumpWidget(aiApp('/ai', aiBackend(ai)));
    await idle(t);
    await t.enterText(find.byKey(const Key('ai-input')), '随便问问');
    await t.tap(find.byTooltip('发送'));
    await idle(t);
    ai.sse!.add(_sse('delta', {'text': '不该出现的话'}));
    ai.sse!.add(_sse('card', ai.cards[0]));
    await idle(t, 2);
    expect(find.textContaining('不该出现的话', findRichText: true), findsOneWidget);
    final done = ai.doneFor('x');
    (done['message'] as Map)
      ..['content'] = '这个问题圈圈暂时回答不了'
      ..['cards'] = <Object>[];
    ai.sse!.add(_sse('done', done));
    ai.sse!.close().ignore();
    await idle(t);
    expect(find.textContaining('不该出现的话', findRichText: true), findsNothing);
    expect(find.text('这个问题圈圈暂时回答不了'), findsOneWidget);
    expect(find.text('一键开跑'), findsNothing);
    await settle(t);
  });

  testWidgets('assistant cards: territory → map focus, boss → boss page, route → run with guide', (t) async {
    await phone(t);
    final ai = AiFake();
    await t.pumpWidget(aiApp('/ai', aiBackend(ai)));
    await idle(t);
    await t.tap(find.text('今晚去哪抢地')); // suggestion chip sends right away
    await idle(t);
    expect(ai.chats.single['content'], '今晚去哪抢地');
    expect(find.textContaining('能圈下约 0.4 km²', findRichText: true), findsOneWidget);

    await t.tap(find.text('沙发怪'));
    await ui(t);
    expect(find.text('boss 3'), findsOneWidget);
    _back(t);
    await ui(t);

    await t.scrollUntilVisible(find.text('西岸草坪'), -100, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('西岸草坪'));
    await ui(t);
    expect(find.text('map focus 4'), findsOneWidget);
    await settle(t);
  });

  testWidgets('assistant route card 一键开跑 starts a run with the route as guide', (t) async {
    await phone(t);
    final ai = AiFake();
    await t.pumpWidget(aiApp('/ai', aiBackend(ai)));
    await idle(t);
    await t.tap(find.text('规划圈地路线'));
    await idle(t);
    await t.scrollUntilVisible(find.text('一键开跑'), -100, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('一键开跑'));
    await idle(t);
    // Autostart → consent ok → countdown on the run page.
    expect(find.byType(RunPage), findsOneWidget);
    final container = ProviderScope.containerOf(t.element(find.byType(RunPage)));
    final s = container.read(runControllerProvider);
    expect(s.goal.toJson(), {'type': 'ai_route', 'route_id': 'r_loop', 'route_type': 'loop'});
    expect(s.guide!.path.length, greaterThan(10));
    await t.pump(const Duration(seconds: 4));
    await idle(t);
    final map = t.widget<TerritoryMapView>(find.byType(TerritoryMapView));
    expect(map.layers.routePath, isNotEmpty);
    expect(map.layers.objects.checkpoints.map((c) => c.name), contains('滨江公园'));
    expect(find.text('AI 推荐闭环'), findsOneWidget); // goal chip
    await shot(t, 'ai_run_guide');
    container.read(runControllerProvider.notifier).reset();
    await t.pump();
    await settle(t);
  });

  testWidgets('assistant: quota exceeded → membership upsell; blocked content keeps the draft', (t) async {
    await phone(t);
    final ai = AiFake()..chatMode = 'ai_quota_exceeded';
    await t.pumpWidget(aiApp('/ai', aiBackend(ai)));
    await idle(t);
    await t.enterText(find.byKey(const Key('ai-input')), '帮我排个计划');
    await t.tap(find.byTooltip('发送'));
    await idle(t);
    expect(find.text('本周免费次数已用完'), findsOneWidget);
    expect(find.textContaining('开通会员不限次数'), findsWidgets);
    await shot(t, 'ai_quota');
    await t.tap(find.text('开通会员'));
    await ui(t);
    expect(find.text('会员页'), findsOneWidget);
    _back(t);
    await ui(t);
    // The question is back in the box, the quota shows as used up and a new
    // send goes straight to the upsell.
    expect(find.text('帮我排个计划'), findsOneWidget);
    expect(find.text('本周剩 0 次'), findsOneWidget);
    await t.tap(find.byTooltip('发送'));
    await ui(t);
    expect(ai.chats, hasLength(1));
    await t.tap(find.text('知道了'));
    await ui(t);

    ai.chatMode = 'content_blocked';
    ai.remaining = 2;
    await settle(t);
  });

  testWidgets('assistant: content_blocked, ai_unavailable (SSE error) with retry, JSON fallback', (t) async {
    await phone(t);
    final ai = AiFake()..chatMode = 'content_blocked';
    await t.pumpWidget(aiApp('/ai', aiBackend(ai)));
    await idle(t);
    await t.enterText(find.byKey(const Key('ai-input')), '不好的话');
    await t.tap(find.byTooltip('发送'));
    await idle(t);
    expect(find.text('内容未通过检查'), findsOneWidget);
    await t.tap(find.text('知道了'));
    await ui(t);
    expect(find.text('不好的话'), findsOneWidget); // draft restored, no bubbles

    ai.chatMode = 'ai_unavailable';
    await t.enterText(find.byKey(const Key('ai-input')), '今晚去哪抢地？');
    await t.tap(find.byTooltip('发送'));
    await idle(t);
    expect(find.text('AI 暂时不可用，请稍后再试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('今晚去哪抢地？'), findsOneWidget); // question kept

    ai.chatMode = 'json'; // the server answers JSON even when asked to stream
    await t.tap(find.text('重试'));
    await idle(t);
    expect(find.text('重试'), findsNothing);
    expect(find.textContaining('往东绕滨江公园', findRichText: true), findsOneWidget);
    expect(ai.chats.where((c) => c['content'] == '今晚去哪抢地？'), hasLength(2));
    await settle(t);
  });

  testWidgets('assistant: photo (vision) upload, image_unsupported hides the camera; no camera without vision', (t) async {
    await phone(t);
    final ai = AiFake();
    final picked = <bool>[];
    await t.pumpWidget(aiApp('/ai', aiBackend(ai, more: [
      singleImagePickerProvider.overrideWithValue(({bool camera = false}) async {
        picked.add(camera);
        return (bytes: FakePicker.png, name: 'food.png');
      }),
    ])));
    await idle(t);
    await t.tap(find.byTooltip('发图片'));
    await ui(t);
    await t.tap(find.text('拍照'));
    await ui(t);
    await idle(t);
    expect(picked, [true]);
    expect(find.bySemanticsLabel('移除图片'), findsOneWidget);
    await t.tap(find.byTooltip('发送')); // empty text + photo → default question
    await idle(t);
    expect(ai.chats.single['image_id'], 77);
    expect(ai.chats.single['content'], '帮我看看这张图');

    // Server says the model cannot read images: camera disappears.
    ai.chatMode = 'ai_image_unsupported';
    await t.tap(find.byTooltip('发图片'));
    await ui(t);
    await t.tap(find.text('从相册选择'));
    await ui(t);
    await idle(t);
    await t.enterText(find.byKey(const Key('ai-input')), '这是什么');
    await t.tap(find.byTooltip('发送'));
    await idle(t);
    expect(find.text('暂不支持图片'), findsOneWidget);
    await t.tap(find.text('知道了'));
    await ui(t);
    expect(find.byTooltip('发图片'), findsNothing);
    await settle(t);

    final noVision = AiFake(vision: false);
    await t.pumpWidget(aiApp('/ai', aiBackend(noVision)));
    await idle(t);
    expect(find.byTooltip('发图片'), findsNothing);
    await settle(t);
  });

  testWidgets('assistant: history paging upward, clear conversation, 问 AI context', (t) async {
    await phone(t);
    final ai = AiFake(history: 40, unlimited: true);
    await t.pumpWidget(aiApp('/ai?context=territory&id=4&name=${Uri.encodeComponent('西岸草坪')}', aiBackend(ai)));
    await idle(t);
    expect(find.text('不限次数'), findsOneWidget);
    expect(find.text('历史回答 40'), findsOneWidget);
    expect(find.text('关于领地「西岸草坪」'), findsOneWidget);
    expect(find.text('这块地怎么抢下来？'), findsOneWidget); // prefilled

    // Scroll to the top: the second page is requested with before=<cursor>.
    await t.drag(find.byType(Scrollable).first, const Offset(0, 4000));
    await idle(t);
    await t.drag(find.byType(Scrollable).first, const Offset(0, 4000));
    await idle(t);
    expect(find.text('历史问题 1'), findsOneWidget);
    expect(find.textContaining('晚上好阿杰'), findsOneWidget); // greeting at the very top

    await t.tap(find.byTooltip('发送'));
    await idle(t);
    expect(ai.chats.single['context'], {'type': 'territory', 'id': 4});
    expect(find.text('关于领地「西岸草坪」'), findsNothing); // context used once

    await t.tap(find.byTooltip('更多'));
    await ui(t);
    await t.tap(find.text('清空对话'));
    await ui(t);
    await t.tap(find.text('清空'));
    await idle(t);
    expect(ai.cleared, 1);
    expect(find.text('历史回答 40'), findsNothing);
    expect(find.text('对话已清空'), findsOneWidget);
    await settle(t);
  });

  testWidgets('AI off: page says unavailable; 问 AI hidden on territory sheet; shown when on', (t) async {
    await phone(t);
    final off = AiFake(enabled: false);
    await t.pumpWidget(aiApp('/ai', aiBackend(off)));
    await idle(t);
    expect(find.text('AI 助手暂时不可用，请稍后再试'), findsOneWidget);
    await settle(t);

    final enemy = TerritorySummary.fromJson(sampleTerritories[3]);
    for (final on in [false, true]) {
      await t.pumpWidget(aiApp('/map', aiBackend(AiFake(enabled: on))));
      await idle(t);
      showModalBottomSheet<void>(
          context: t.element(find.byType(_MapStub)), builder: (_) => TerritorySheet(territory: enemy));
      await ui(t);
      await idle(t);
      expect(find.text('问 AI'), on ? findsOneWidget : findsNothing);
      if (on) {
        await t.tap(find.text('问 AI'));
        await ui(t);
        await idle(t);
        expect(find.text('关于领地「西岸草坪」'), findsOneWidget);
      }
      await settle(t);
    }
  });

  testWidgets('boss page shows 问 AI when AI is on', (t) async {
    await phone(t);
    final ai = AiFake();
    await t.pumpWidget(aiApp('/map', aiBackend(ai)));
    await idle(t);
    // Push the real boss page on top of the stub router.
    Navigator.of(t.element(find.byType(_MapStub))).push(MaterialPageRoute<void>(builder: (_) => const BossPage(bossId: 3)));
    await idle(t);
    expect(find.text('问 AI'), findsOneWidget);
    await settle(t);
  });

  testWidgets('开跑 page: AI route goals, distance choice, preview, start passes goal + guide', (t) async {
    await phone(t, size: const Size(390, 1500));
    final ai = AiFake();
    await t.pumpWidget(aiApp('/start/gps?sport=run', aiBackend(ai)));
    await idle(t);
    expect(find.text('自由圈地 · 推荐'), findsOneWidget);
    expect(find.text('AI 推荐闭环'), findsOneWidget);
    expect(find.text('夺回 西岸草坪'), findsOneWidget);
    expect(find.text('顺路打 沙发怪'), findsOneWidget);
    expect(find.text('刷新 AI 路线'), findsOneWidget);

    await t.tap(find.text('AI 推荐闭环'));
    await idle(t);
    expect(find.textContaining('配速 6\'10"'), findsOneWidget);
    expect(find.text('内容由 AI 生成'), findsOneWidget);
    expect(find.text('5.2 km · 约 32 分钟 · 可圈 0.40 km²'), findsOneWidget);
    final calls = ai.routesCalls;
    await t.tap(find.text('10 km'));
    await idle(t);
    expect(ai.routesCalls, calls + 1);
    expect(find.text('AI 推荐闭环'), findsWidgets); // same kind stays selected after refetch
    var map = t.widget<TerritoryMapView>(find.byType(TerritoryMapView));
    expect(map.layers.routePath, isNotEmpty);
    await shot(t, 'ai_routes');

    // Template reasons (ai_generated=false) carry no AI label.
    await t.tap(find.text('顺路打 沙发怪'));
    await idle(t);
    expect(find.text('跑进范围每公里造成 100 伤害。'), findsOneWidget);
    expect(find.text('内容由 AI 生成'), findsNothing);

    await t.tap(find.text('夺回 西岸草坪'));
    await idle(t);
    map = t.widget<TerritoryMapView>(find.byType(TerritoryMapView));
    expect(map.layers.objects.checkpoints.single.name, '西岸草坪');
    await t.ensureVisible(find.text('开始'));
    await t.pump();
    await t.tap(find.text('开始'));
    await idle(t);
    final container = ProviderScope.containerOf(t.element(find.byType(RunPage)));
    final s = container.read(runControllerProvider);
    expect(s.goal.type, 'ai_route');
    expect(s.goal.routeId, 'r_capture');
    expect(s.goal.routeType, 'capture');
    expect(s.guide!.targets.single.name, '西岸草坪');
    container.read(runControllerProvider.notifier).reset();
    await t.pump();
    await settle(t);
  });

  testWidgets('开跑 page: AI routes loading error with retry; still shown when AI is off', (t) async {
    await phone(t, size: const Size(390, 1300));
    final ai = AiFake();
    var fail = true;
    await t.pumpWidget(aiApp('/start/gps', [
      ...fakeBackend(handlers: [
        (o) => o.path == '/v1/ai/routes' && fail
            ? (500, {
                'error': {'code': 'internal', 'message': '服务器开小差了'}
              })
            : null,
        ai.handle,
      ]),
      locationSourceProvider.overrideWithValue(FakeLocationSource([fixAt(0, 0, 0)])),
    ]));
    await idle(t);
    expect(find.textContaining('AI 路线加载失败'), findsOneWidget);
    fail = false;
    await t.tap(find.text('重试'));
    await idle(t);
    expect(find.text('AI 推荐闭环'), findsOneWidget);
    await settle(t);

    await t.pumpWidget(aiApp('/start/gps', aiBackend(AiFake(enabled: false))));
    await idle(t);
    expect(find.text('自由圈地 · 推荐'), findsOneWidget);
    // Routes are rule-based: still offered when the model is off.
    expect(find.text('AI 推荐闭环'), findsOneWidget);
    expect(find.text('刷新 AI 路线'), findsOneWidget);
    await settle(t);
  });

  testWidgets('settlement: AI 战报 typed in, 换一换 until the limit, attached to the post', (t) async {
    await phone(t, size: const Size(390, 2400));
    final ai = AiFake()..regenerateLeft = 1;
    final community = CommunityFake();
    final r = ActivityResult.fromJson(j(activityResultJson));
    await t.pumpWidget(aiApp('/result', aiBackend(ai, community: community), extra: ResultArgs(result: r)));
    await idle(t);
    await t.pump(const Duration(seconds: 3)); // typing effect
    expect(find.text('AI 战报'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('一口气圈下滨江两块地')), findsOneWidget);
    expect(find.text('内容由 AI 生成 · 通义千问'), findsOneWidget);
    expect(ai.reports, ['get']);
    await shot(t, 'ai_report');

    await t.tap(find.text('换一换 · 剩 1 次'));
    await idle(t);
    await t.pump(const Duration(seconds: 3));
    expect(ai.reports, ['get', 'regenerate']);
    expect(find.bySemanticsLabel(RegExp('夜袭滨江')), findsOneWidget);
    expect(find.text('已换完'), findsOneWidget);

    await t.scrollUntilVisible(find.text('一键带上战报发动态'), 200, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('一键带上战报发动态'));
    await ui(t);
    await idle(t);
    expect(find.byKey(const Key('compose-ai-report')), findsOneWidget);
    expect(find.textContaining('夜袭滨江'), findsOneWidget);
    await shot(t, 'ai_compose');
    await t.enterText(find.byKey(const Key('compose-text')), '今晚的夜跑 #滨江');
    await t.pump();
    await t.tap(find.text('发布'));
    await idle(t);
    expect(ai.posts.single['ai_report'], isTrue);
    expect(ai.posts.single['activity_id'], r.activity.id);
    await settle(t);
  });

  testWidgets('composer: AI 写战报 for the chosen run; removing / switching runs detaches it', (t) async {
    await phone(t, size: const Size(390, 1200));
    final ai = AiFake();
    final community = CommunityFake();
    await t.pumpWidget(aiApp('/posts/new', aiBackend(ai, community: community)));
    await idle(t);
    expect(find.text('AI 写战报'), findsOneWidget);
    // Pick the first recent run, then ask for a report.
    final runChoice = find.textContaining('km ·').first;
    await t.tap(runChoice);
    await t.pump();
    await t.tap(find.text('AI 写战报'));
    await idle(t);
    expect(find.byKey(const Key('compose-ai-report')), findsOneWidget);
    expect(find.text('换一篇'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('移除 AI 战报'));
    await t.pump();
    expect(find.byKey(const Key('compose-ai-report')), findsNothing);
    await t.tap(find.text('AI 写战报'));
    await idle(t);
    await t.tap(runChoice); // deselect the run → report goes too
    await t.pump();
    expect(find.byKey(const Key('compose-ai-report')), findsNothing);
    await settle(t);
  });

  testWidgets('post card and detail show the AI 战报 block with the AI label', (t) async {
    await phone(t, size: const Size(390, 700));
    final post = Post.fromJson({
      ...postJson(5, kai, content: '今晚的夜跑', activity: activityJson(55)),
      'ai_report': {'text': '夜袭滨江！31 分钟连圈两块，配速稳得像节拍器。', 'ai_generated': true},
    });
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(Scaffold(body: ListView(padding: const EdgeInsets.all(16), children: [PostCard(post: post)])),
          overrides: fakeBackend()),
    ));
    await idle(t);
    expect(find.text('AI 战报'), findsOneWidget);
    expect(find.text('夜袭滨江！31 分钟连圈两块，配速稳得像节拍器。'), findsOneWidget);
    expect(find.text('内容由 AI 生成'), findsOneWidget);
    await shot(t, 'ai_post');
    await settle(t);
  });
}
