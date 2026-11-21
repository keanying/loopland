import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/ai_api.dart';
import '../../api/ai_models.dart';
import '../../api/errors.dart';
import '../../claim/geo.dart';
import '../../run/run_controller.dart';

/// `GET /v1/ai/info` (model disclosure, vision, quota).
final aiInfoProvider = FutureProvider.autoDispose<AIInfo>((ref) => ref.watch(aiApiProvider).info());

/// Key for [aiRoutesProvider]; lat / lng rounded (~10 m) so GPS jitter does
/// not refetch.
typedef AIRoutesQuery = ({double lat, double lng, String sport, int distanceKm});

AIRoutesQuery aiRoutesQuery(LatLng at, String sport, int distanceKm) => (
      lat: (at.lat * 10000).roundToDouble() / 10000,
      lng: (at.lng * 10000).roundToDouble() / 10000,
      sport: sport,
      distanceKm: distanceKm,
    );

/// C-04 suggestions for the 开跑 page.
final aiRoutesProvider = FutureProvider.autoDispose.family<AIRoutes, AIRoutesQuery>(
  (ref, q) => ref.watch(aiApiProvider).routes(lat: q.lat, lng: q.lng, sport: q.sport, distanceKm: q.distanceKm),
);

/// An AI route as a run guide (dashed line + numbered targets).
RunGuide guideOf(AIRoute r) => RunGuide(
      title: r.title.isNotEmpty ? r.title : 'AI 路线',
      path: r.path,
      targets: [
        for (final t in r.targets)
          if (t.center != null) GuideTarget(name: t.name, center: t.center!, type: t.type),
      ],
    );

/// What the「一键开跑」/ route cards pass to `/start/gps` as `extra`.
class AIRouteLaunch {
  const AIRouteLaunch(this.route, {this.autostart = false});
  final AIRoute route;

  /// Start right away (after the usual consent / permission checks).
  final bool autostart;
}

/// A request to centre the territory map (assistant territory cards).
class MapFocus {
  const MapFocus(this.center, {this.territoryId});
  final LatLng center;
  final int? territoryId;
}

class MapFocusNotifier extends Notifier<MapFocus?> {
  @override
  MapFocus? build() => null;

  // ignore: use_setters_to_change_properties
  void focus(MapFocus f) => state = f;
  void clear() => state = null;
}

/// Read and cleared by the map page.
final mapFocusProvider = NotifierProvider<MapFocusNotifier, MapFocus?>(MapFocusNotifier.new);

/// State of the C-05 battle report on the settlement page / composer.
class AIReportState {
  const AIReportState({this.report, this.loading = false, this.error, this.regenerating = false});
  final AIReport? report;
  final bool loading;
  final Object? error;
  final bool regenerating;

  bool get busy => loading || regenerating;
}

/// Battle report per activity: generated on first watch, kept while watched.
class AIReportNotifier extends Notifier<AIReportState> {
  AIReportNotifier(this.activityId);
  final int activityId;

  @override
  AIReportState build() {
    Future.microtask(load);
    return const AIReportState(loading: true);
  }

  Future<void> load() async {
    state = AIReportState(report: state.report, loading: true);
    try {
      final r = await ref.read(aiApiProvider).report(activityId);
      if (ref.mounted) state = AIReportState(report: r);
    } catch (e) {
      if (ref.mounted) state = AIReportState(report: state.report, error: e);
    }
  }

  /// 「换一换」. Returns the error (e.g. `regenerate_limit`) instead of
  /// replacing the current report with it.
  Future<ApiException?> regenerate() async {
    final cur = state.report;
    if (state.busy) return null;
    state = AIReportState(report: cur, regenerating: true);
    try {
      final r = await ref.read(aiApiProvider).report(activityId, regenerate: true);
      if (ref.mounted) state = AIReportState(report: r);
      return null;
    } catch (e) {
      final ex = ApiException.from(e);
      if (ref.mounted) {
        // Out of regenerations: keep the text, disable the button.
        final keep = ex.code == 'regenerate_limit' && cur != null
            ? AIReport(
                activityId: cur.activityId,
                text: cur.text,
                modelName: cur.modelName,
                aiGenerated: cur.aiGenerated,
                generatedAt: cur.generatedAt,
              )
            : cur;
        state = AIReportState(report: keep);
      }
      return ex;
    }
  }
}

final aiReportProvider =
    NotifierProvider.autoDispose.family<AIReportNotifier, AIReportState, int>(AIReportNotifier.new);
