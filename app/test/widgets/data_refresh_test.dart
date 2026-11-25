// 数据刷新约定 (app/README.md): an action that changes server state refreshes
// every screen that shows it — including tabs kept alive in the shell and
// pages further down the stack — without restarting the app.
import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/core/refresh.dart';
import 'package:loopland/core/sdk_config.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/features/ai/ai_routes.dart';
import 'package:loopland/features/community/community_page.dart';
import 'package:loopland/features/community/crew_pages.dart';
import 'package:loopland/features/local/local_page.dart';
import 'package:loopland/features/map/map_page.dart';
import 'package:loopland/features/me/me_page.dart';
import 'package:loopland/features/me/membership_page.dart';
import 'package:loopland/map/territory_map.dart';
import 'package:loopland/realtime/realtime_providers.dart';
import 'package:loopland/run/location_source.dart';
import 'package:loopland/run/run_controller.dart' show locationSourceProvider;
import 'package:loopland/widgets/data_sync.dart';
import 'package:loopland/widgets/toast.dart';
import 'package:material_ui/material_ui.dart';

import '../api/fixtures.dart';
import 'ai_fake.dart';
import 'fake_backend.dart';
import 'perks_fake.dart';
import 'screens_test.dart' show fixAt;
import 'test_helpers.dart';
import 'v2_pages_test.dart' show fakeRealtime;

typedef Handler = (int, Object?)? Function(RequestOptions o);

/// What `GET /v1/me` returns right now.
Map<String, dynamic> me({bool member = false, int energy = 1280, int territories = 3, bool crew = true}) {
  final m = j(userJson)
    ..['nickname'] = '阿杰'
    ..['energy'] = energy;
  if (!member) m['membership'] = {'active': false};
  if (!crew) m['crew'] = null;
  (m['stats'] as Map)['territory_count'] = territories;
  return m;
}

/// The routes under test (real pages), optionally inside a StatefulShellRoute
/// like the app's tabs (kept alive in an IndexedStack).
Widget app(String initial, List<Override> overrides,
    {List<RouteBase> routes = const [], List<StatefulShellBranch> tabs = const [], bool sync = false}) {
  final router = GoRouter(initialLocation: initial, routes: [
    if (tabs.isNotEmpty) StatefulShellRoute.indexedStack(builder: (_, _, shell) => shell, branches: tabs),
    ...routes,
  ]);
  return ProviderScope(
    overrides: overrides,
    retry: (_, _) => null,
    child: MaterialApp.router(
      theme: buildTheme(),
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      builder: sync ? (_, child) => DataSync(child: child!) : null,
    ),
  );
}

StatefulShellBranch tab(String path, Widget page) => StatefulShellBranch(routes: [GoRoute(path: path, builder: (_, _) => page)]);

/// Lets dialogs / routes animate (pumpAndSettle would wait on spinners).
Future<void> ui(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

GoRouter routerOf(WidgetTester t) => GoRouter.of(t.element(find.byType(Scaffold).last));

Future<void> done(WidgetTester t) async {
  dismissToast();
  await t.pump(const Duration(milliseconds: 400));
  await settle(t);
}

void main() {
  late SdkConfig saved;

  setUpAll(() async {
    TerritoryMapView.forceFallback = true;
    await loadFonts();
  });

  setUp(() {
    saved = SdkConfig.current;
    // Dev build: the mock payment channel is offered.
    SdkConfig.current = SdkConfig.fromMap(const {'LOOPLAND_ENV': 'dev'}, platform: 'android');
  });
  tearDown(() => SdkConfig.current = saved);

  /// Membership + mock payment endpoints; [onPaid] flips the server state.
  Handler membershipBackend({required bool Function() member, required void Function() onPaid}) => (o) {
        final p = o.path, m = o.method;
        Map<String, Object?> order(String status) =>
            {...j(orderJson), 'order_no': 'LP1', 'channel': 'mock', 'status': status};
        if (p == '/v1/me' && m == 'GET') return (200, me(member: member()));
        if (p == '/v1/plans') return (200, {'items': [j(planJson)], 'minor_blocked': false});
        if (p == '/v1/membership') return (200, member() ? j(userJson)['membership'] : {'active': false});
        if (p == '/v1/orders' && m == 'POST') return (200, {'order': order('created'), 'pay_params': <String, Object?>{}});
        if (p == '/v1/dev/orders/LP1/pay') {
          onPaid();
          return (200, order('paid'));
        }
        if (p == '/v1/orders/LP1') return (200, order(member() ? 'paid' : 'created'));
        return null;
      };

  testWidgets('会员: bought from the AI quota wall → the chat works right away, no restart', (t) async {
    await phone(t);
    final ai = AiFake(remaining: 0);
    var member = false;
    final pay = membershipBackend(member: () => member, onPaid: () {
      member = true;
      ai.unlimited = true; // members ask without limit
    });
    final (rt, _) = fakeRealtime();
    addTearDown(rt.dispose);
    await t.pumpWidget(app(
      '/ai',
      [
        ...fakeBackend(handlers: [pay, ai.handle], wrapAdapter: ai.adapter, user: User.fromJson(me()), liveUser: true),
        locationSourceProvider.overrideWithValue(FakeLocationSource([fixAt(0, 0, 0)])),
        realtimeClientProvider.overrideWithValue(rt),
      ],
      routes: [...aiRoutes(), GoRoute(path: '/membership', builder: (_, _) => const MembershipPage())],
    ));
    await idle(t);
    expect(find.text('本周剩 0 次'), findsOneWidget);

    // Quota used up → upsell → 开通会员.
    await t.enterText(find.byKey(const Key('ai-input')), '帮我排个计划');
    await t.tap(find.byTooltip('发送'));
    await ui(t);
    expect(find.text('本周免费次数已用完'), findsOneWidget);
    expect(ai.chats, isEmpty);
    await t.tap(find.text('开通会员'));
    await idle(t);
    expect(find.byType(MembershipPage), findsOneWidget);

    // Pay (mock channel in dev).
    await t.tap(find.textContaining('立即开通'));
    await idle(t);
    expect(member, isTrue);
    expect(find.textContaining('开通成功'), findsWidgets);
    expect(find.text('连续包月'), findsWidgets); // the member card

    // Back to the assistant: the quota was re-read, the wall is gone.
    routerOf(t).pop();
    await ui(t);
    await idle(t);
    expect(find.text('不限次数'), findsOneWidget);
    expect(find.text('本周剩 0 次'), findsNothing);
    await t.tap(find.byTooltip('发送'));
    await idle(t);
    expect(ai.chats, hasLength(1));
    expect(find.text('本周免费次数已用完'), findsNothing);
    expect(find.textContaining('往东绕滨江公园'), findsWidgets);
    await done(t);
  });

  testWidgets('会员 paid outside the app (WeChat / renewal) → coming back to the app re-reads quota and user', (t) async {
    await phone(t);
    final ai = AiFake(remaining: 0);
    var member = false;
    final (rt, _) = fakeRealtime();
    addTearDown(rt.dispose);
    await t.pumpWidget(app(
      '/ai',
      [
        ...fakeBackend(
            handlers: [membershipBackend(member: () => member, onPaid: () {}), ai.handle],
            wrapAdapter: ai.adapter,
            user: User.fromJson(me()),
            liveUser: true),
        locationSourceProvider.overrideWithValue(FakeLocationSource([fixAt(0, 0, 0)])),
        realtimeClientProvider.overrideWithValue(rt),
      ],
      routes: aiRoutes(),
      sync: true,
    ));
    await idle(t);
    expect(find.text('本周剩 0 次'), findsOneWidget);

    // Paid in the WeChat app; the server knows, the app does not yet.
    member = true;
    ai.unlimited = true;
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pump();
    expect(find.text('本周剩 0 次'), findsOneWidget);
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await idle(t);
    expect(find.text('不限次数'), findsOneWidget);
    await done(t);
  });

  testWidgets('能量商城: buying on the shop updates the energy on 我的 (kept in the stack)', (t) async {
    await phone(t, size: const Size(390, 1600));
    final perks = PerksFake();
    final (rt, _) = fakeRealtime();
    addTearDown(rt.dispose);
    await t.pumpWidget(app(
      '/me',
      [
        ...fakeBackend(
          handlers: [
            (o) => o.path == '/v1/me' && o.method == 'GET' ? (200, me(energy: perks.energy)) : null,
            perks.handle,
          ],
          user: User.fromJson(me()),
          liveUser: true,
        ),
        realtimeClientProvider.overrideWithValue(rt),
      ],
      tabs: [tab('/me', const MePage())],
      routes: [GoRoute(path: '/local', builder: (_, s) => LocalPage(tab: s.uri.queryParameters['tab'] ?? 'booking'))],
    ));
    await idle(t);
    expect(find.textContaining('1280 能量'), findsOneWidget);

    await t.tap(find.text('能量商城'));
    await idle(t);
    await t.tap(find.byKey(const Key('buy:skin_neon')));
    await ui(t);
    await t.tap(find.text('确认兑换'));
    await idle(t);
    expect(perks.energy, 480);
    routerOf(t).pop();
    await ui(t);
    await idle(t);
    expect(find.textContaining('480 能量'), findsOneWidget);
    expect(find.textContaining('1280 能量'), findsNothing);
    await done(t);
  });

  testWidgets('跑团: joining on the crew page shows the crew on the 社区 tab', (t) async {
    await phone(t, size: const Size(390, 1400));
    var inCrew = false;
    Map<String, Object?> crew() => {...j(crewJson), 'my_role': inCrew ? 'member' : null, 'week_rank': <Object>[]};
    final (rt, _) = fakeRealtime();
    addTearDown(rt.dispose);
    await t.pumpWidget(app(
      '/community',
      [
        ...fakeBackend(handlers: [
          (o) {
            final p = o.path, m = o.method;
            if (p == '/v1/me' && m == 'GET') return (200, me(crew: inCrew));
            if (p == '/v1/community/home') {
              return (200, {
                'crew': inCrew
                    ? {'id': 3, 'name': '城西跑团', 'avatar_url': null, 'member_count': 13, 'week_area_m2': 0, 'my_rank': 13}
                    : null,
                'unread': {'interaction': 0, 'chat': 0},
                'rallies': <Object>[],
                'meetups': <Object>[],
                'races': <Object>[],
              });
            }
            if (p == '/v1/crews/3' && m == 'GET') return (200, crew());
            if (p == '/v1/crews/3/members') return (200, {'items': <Object>[]});
            if (p == '/v1/crews/3/rallies') return (200, {'items': <Object>[]});
            if (p == '/v1/crews/3/join' && m == 'POST') {
              inCrew = true;
              return (200, {'status': 'joined'});
            }
            return null;
          },
        ], user: User.fromJson(me(crew: false)), liveUser: true),
        realtimeClientProvider.overrideWithValue(rt),
      ],
      tabs: [tab('/community', const CommunityPage())],
      routes: [GoRoute(path: '/crews/:id', builder: (_, s) => CrewDetailPage(crewId: int.parse(s.pathParameters['id']!)))],
    ));
    await idle(t);
    expect(find.text('还没有跑团'), findsOneWidget);

    routerOf(t).push('/crews/3');
    await idle(t);
    await t.ensureVisible(find.text('加入跑团'));
    await t.tap(find.text('加入跑团'));
    await idle(t);
    expect(inCrew, isTrue);
    routerOf(t).pop();
    await ui(t);
    await idle(t);
    expect(find.text('还没有跑团'), findsNothing);
    expect(find.text('城西跑团'), findsOneWidget);
    expect(find.text('13 名成员'), findsOneWidget);
    await done(t);
  });

  testWidgets('运动结算: 我的 stats and the 领地 map (both tabs kept alive) update', (t) async {
    await phone(t, size: const Size(390, 1400));
    var settled = false;
    var territoryCalls = 0, codexCalls = 0;
    final (rt, _) = fakeRealtime();
    addTearDown(rt.dispose);
    await t.pumpWidget(app(
      '/map',
      [
        ...fakeBackend(handlers: [
          (o) {
            final p = o.path;
            if (p == '/v1/me' && o.method == 'GET') return (200, me(territories: settled ? 4 : 3));
            if (p == '/v1/territories') {
              territoryCalls++;
              return (200, {
                'items': [...sampleTerritories, if (settled) territory(7, '新地块', 'mine', 0, 400, 150, 100)],
              });
            }
            if (p == '/v1/codex') codexCalls++;
            return null;
          },
        ], user: User.fromJson(me()), liveUser: true),
        locationSourceProvider.overrideWithValue(FakeLocationSource([fixAt(-40, -60, 0)])),
        realtimeClientProvider.overrideWithValue(rt),
      ],
      tabs: [tab('/map', const MapPage()), tab('/me', const MePage())],
    ));
    // locate → move → bounds debounce → load
    for (var i = 0; i < 3; i++) {
      await idle(t, 1);
      await t.pump(const Duration(milliseconds: 400));
    }
    expect(territoryCalls, greaterThan(0));
    routerOf(t).go('/me');
    await idle(t);
    expect(find.textContaining('我的领地 · 3 块'), findsOneWidget);
    final mapCalls = territoryCalls, codex = codexCalls;

    // What the run / home training / coach pages and the offline uploader
    // call after POST /v1/activities.
    settled = true;
    final c = ProviderScope.containerOf(t.element(find.byType(MePage)));
    await t.runAsync(() => c.read(refreshProvider).afterRunSettled());
    await idle(t);
    expect(find.textContaining('我的领地 · 4 块'), findsOneWidget);
    expect(codexCalls, greaterThan(codex)); // 我的图鉴 card
    expect(territoryCalls, greaterThan(mapCalls)); // the map tab reloaded while hidden
    await done(t);
  });
}
