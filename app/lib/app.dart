import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'auth/auth_controller.dart';
import 'core/env.dart';
import 'core/format.dart';
import 'core/privacy.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'features/city/city_page.dart';
import 'features/codex/codex_page.dart';
import 'features/community/community_page.dart';
import 'features/community/crew_pages.dart';
import 'features/debug/env_check_page.dart';
import 'features/inbox/inbox_page.dart';
import 'features/login/bind_phone_page.dart';
import 'features/login/consent_page.dart';
import 'features/login/login_page.dart';
import 'features/login/sms_login_page.dart';
import 'features/map/map_page.dart';
import 'features/me/activity_pages.dart';
import 'features/me/me_page.dart';
import 'features/me/membership_page.dart';
import 'features/me/settings_page.dart';
import 'features/play/boss_page.dart';
import 'features/play/games_page.dart';
import 'features/play/routes_pages.dart';
import 'features/play/season_page.dart';
import 'features/run/home_training_page.dart';
import 'features/run/result_page.dart';
import 'features/run/run_page.dart';
import 'features/start/gps_setup_page.dart';
import 'features/start/start_page.dart';
import 'run/run_controller.dart';
import 'run/uploader.dart';
import 'widgets/card_art.dart';
import 'widgets/common.dart';
import 'realtime/realtime_banner.dart';
import 'widgets/nav_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authProvider, (_, _) => refresh.value++);
  ref.listen(launchPrivacyProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  int? id(GoRouterState s) => int.tryParse(s.pathParameters['id'] ?? '');

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final a = ref.read(authProvider);
      final loc = state.matchedLocation;
      // 「环境检查」 works before login (dev builds only).
      if (loc == '/dev/env') return Env.isDev ? null : '/splash';
      // First launch: privacy dialog before anything (and any SDK) else.
      final privacy = ref.read(launchPrivacyProvider);
      if (privacy == null) return loc == '/splash' ? null : '/splash';
      if (privacy == false) return loc == '/welcome' ? null : '/welcome';
      if (loc == '/welcome') return '/splash';
      if (a.status == AuthStatus.unknown) return loc == '/splash' ? null : '/splash';
      final onLogin = loc.startsWith('/login');
      if (!a.loggedIn) return onLogin ? null : '/login';
      if (a.needBindPhone) return loc == '/bind-phone' ? null : '/bind-phone';
      if (a.needConsent) return loc == '/consent' ? null : '/consent';
      if (onLogin || loc == '/splash' || loc == '/bind-phone' || loc == '/consent') return '/map';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashPage()),
      GoRoute(path: '/welcome', builder: (_, _) => const LaunchPrivacyPage()),
      GoRoute(path: '/dev/env', builder: (_, _) => const EnvCheckPage()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage(), routes: [
        GoRoute(path: 'sms', builder: (_, _) => const SmsLoginPage()),
      ]),
      GoRoute(path: '/bind-phone', builder: (_, _) => const BindPhonePage()),
      GoRoute(path: '/consent', builder: (_, _) => const ConsentPage()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => StartupGate(child: NavShell(shell: shell)),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/map', builder: (_, _) => const MapPage())]),
          StatefulShellBranch(routes: [GoRoute(path: '/codex', builder: (_, _) => const CodexPage())]),
          StatefulShellBranch(routes: [GoRoute(path: '/start', builder: (_, _) => const StartPage())]),
          StatefulShellBranch(routes: [GoRoute(path: '/community', builder: (_, _) => const CommunityPage())]),
          StatefulShellBranch(routes: [GoRoute(path: '/me', builder: (_, _) => const MePage())]),
        ],
      ),
      GoRoute(
        path: '/start/gps',
        builder: (_, s) => GpsSetupPage(
          sport: s.uri.queryParameters['sport'] ?? 'run',
          targetId: int.tryParse(s.uri.queryParameters['target'] ?? ''),
          targetName: s.uri.queryParameters['name'],
        ),
      ),
      GoRoute(path: '/run', builder: (_, _) => const RunPage()),
      GoRoute(path: '/train/:sport', builder: (_, s) => HomeTrainingPage(sport: s.pathParameters['sport']!)),
      GoRoute(
        path: '/result',
        builder: (_, s) => s.extra is ResultArgs
            ? ResultPage(args: s.extra! as ResultArgs)
            : const _Missing(text: '结算结果已失效，可在「运动记录」中查看'),
      ),
      GoRoute(path: '/city/:id', builder: (_, s) => CityPage(territoryId: id(s) ?? 0)),
      GoRoute(path: '/inbox', builder: (_, _) => const InboxPage()),
      GoRoute(path: '/activities', builder: (_, _) => const ActivitiesPage()),
      GoRoute(path: '/activities/:id', builder: (_, s) => ActivityDetailPage(id: id(s) ?? 0)),
      GoRoute(path: '/membership', builder: (_, _) => const MembershipPage()),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
      GoRoute(path: '/realname', builder: (_, _) => const RealnamePage()),
      GoRoute(path: '/crews/search', builder: (_, _) => const CrewSearchPage()),
      GoRoute(path: '/crews/new', builder: (_, _) => const CrewCreatePage()),
      GoRoute(path: '/crews/:id', builder: (_, s) => CrewDetailPage(crewId: id(s) ?? 0)),
      GoRoute(path: '/crews/:id/manage', builder: (_, s) => CrewManagePage(crewId: id(s) ?? 0)),
      // V2 玩法
      GoRoute(path: '/bosses/:id', builder: (_, s) => BossPage(bossId: id(s) ?? 0)),
      GoRoute(path: '/games', builder: (_, s) => GamesPage(initial: s.uri.queryParameters['game'] ?? 'war')),
      GoRoute(path: '/season', builder: (_, _) => const SeasonPage()),
      GoRoute(path: '/league', builder: (_, s) => LeaguePage(district: s.uri.queryParameters['district'] ?? '')),
      GoRoute(path: '/routes', builder: (_, _) => const RoutesPage()),
      GoRoute(path: '/routes/:id', builder: (_, s) => RouteDetailPage(routeId: id(s) ?? 0)),
      GoRoute(path: '/campaigns', builder: (_, _) => const CampaignsPage()),
    ],
  );
});

class LooplandApp extends ConsumerStatefulWidget {
  const LooplandApp({super.key});
  @override
  ConsumerState<LooplandApp> createState() => _LooplandAppState();
}

class _LooplandAppState extends ConsumerState<LooplandApp> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(launchPrivacyProvider.notifier).load();
      await ref.read(authProvider.notifier).bootstrap();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: '圈圈 Loopland',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: ref.watch(routerProvider),
      // In-app banners for WebSocket pushes (领地被攻击 / 合击召集).
      builder: (context, child) => RealtimeBannerHost(
        onOpen: (path) => ref.read(routerProvider).push(path),
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}

class SplashPage extends StatelessWidget {
  const SplashPage({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            LoopMark(size: 64),
            SizedBox(height: 16),
            Text('圈圈', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
          ]),
        ),
      );
}

class _Missing extends StatelessWidget {
  const _Missing({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(text, style: const TextStyle(color: LL.text2)),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => context.go('/me'), child: const Text('返回')),
          ]),
        ),
      );
}

/// Runs once after login: retries unsent activities and offers to recover a
/// run that was interrupted (app killed / phone restarted).
class StartupGate extends ConsumerStatefulWidget {
  const StartupGate({super.key, required this.child});
  final Widget child;

  /// Tests disable the disk / network side effects.
  static bool enabled = true;

  @override
  ConsumerState<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<StartupGate> {
  @override
  void initState() {
    super.initState();
    if (StartupGate.enabled) WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    ref.read(configProvider.future).ignore();
    final store = ref.read(runStoreProvider);
    try {
      final snap = await store.loadInProgress();
      if (snap != null && mounted && ref.read(runControllerProvider).phase == RunPhase.idle) {
        final choice = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (c) => AlertDialog(
            title: const Text('发现未完成的运动'),
            content: Text('${snap.points.length} 个轨迹点，开始于 ${TimeOfDay.fromDateTime(snap.startedAt).format(c)}。要继续记录还是结束上传？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, 'discard'), child: const Text('放弃', style: TextStyle(color: LL.text2))),
              TextButton(onPressed: () => Navigator.pop(c, 'finish'), child: const Text('结束并上传')),
              FilledButton(onPressed: () => Navigator.pop(c, 'resume'), child: const Text('继续')),
            ],
          ),
        );
        final ctrl = ref.read(runControllerProvider.notifier);
        final cfg = ref.read(configProvider).value;
        if (choice == 'discard') {
          await ctrl.discard();
        } else if (choice != null) {
          ctrl.restore(snap, minClaimAreaM2: cfg?.minClaimAreaM2 ?? 500);
          if (!mounted) return;
          if (choice == 'resume') {
            context.push('/run');
          } else {
            final upload = await ctrl.finish();
            ctrl.reset();
            try {
              final r = await ref.read(uploaderProvider).submit(upload);
              if (mounted) context.push('/result', extra: ResultArgs(result: r));
            } catch (e) {
              if (mounted) showError(context, e);
            }
          }
        }
      }
      await _deletionNotice();
      final sent = await ref.read(uploaderProvider).flush();
      if (sent.isNotEmpty && mounted) {
        ref.invalidate(pendingUploadsProvider);
        ref.read(authProvider.notifier).refreshUser().ignore();
        toast(context, '已补传 ${sent.length} 条离线运动记录');
      }
    } catch (_) {
      // Startup housekeeping must never block the app.
    }
  }

  /// Accounts in the 7-day deletion cooling-off log in normally; remind the
  /// user and offer DELETE /v1/me/deletion.
  Future<void> _deletionNotice() async {
    final u = ref.read(userProvider);
    if (u == null || !u.isDeleting || !mounted) return;
    final undo = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('账号注销中'),
        content: Text('你的账号已申请注销，将于 ${Fmt.dateTime(u.deleteAfter)} 删除轨迹和个人信息，名下领地变为无主。冷静期内可以撤回。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('暂不')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('撤回注销')),
        ],
      ),
    );
    if (undo != true || !mounted) return;
    final nu = await runGuarded(context, () => ref.read(apiProvider).cancelDeletion());
    if (nu != null && mounted) {
      ref.read(authProvider.notifier).setUser(nu);
      toast(context, '已撤回注销，欢迎回来');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

