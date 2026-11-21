import 'package:go_router/go_router.dart';

import '../../coach/workout.dart';
import 'coach_home_page.dart';
import 'coach_session_page.dart';

/// AI 跟练 (C-09): `/coach?sport=` course list, `/coach/:key` session
/// (`extra`: the [Workout]).
List<RouteBase> coachRoutes() => [
      GoRoute(path: '/coach', builder: (_, s) => CoachHomePage(sport: s.uri.queryParameters['sport'])),
      GoRoute(
        path: '/coach/:key',
        builder: (_, s) => CoachSessionPage(
          workoutKey: s.pathParameters['key'] ?? '',
          workout: s.extra is Workout ? s.extra! as Workout : null,
        ),
      ),
    ];
