import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/errors.dart';
import '../core/providers.dart';
import 'workout.dart';

/// `GET /v1/ai/workouts`. Counting runs on the phone and needs no model, so
/// when the AI endpoints are off (503 `ai_unavailable`), the request fails
/// (offline) or the server sends an empty list, the bundled
/// [builtinWorkouts] are used instead.
final workoutCatalogProvider = FutureProvider.autoDispose<WorkoutCatalog>((ref) async {
  try {
    final raw = await ref.watch(apiClientProvider).get('/v1/ai/workouts');
    final c = WorkoutCatalog.fromJson(raw is Map ? raw.cast<String, dynamic>() : const {});
    if (c.items.isNotEmpty) return c;
  } catch (e) {
    final ex = ApiException.from(e);
    // Session problems are handled by the client (refresh / logout); still
    // show something useful instead of an error page.
    debugPrint('workouts: ${ex.status} ${ex.code}');
  }
  return const WorkoutCatalog(items: builtinWorkouts, builtin: true);
});
