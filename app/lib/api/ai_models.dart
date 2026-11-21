// V2 batch 3「AI」(docs/api/v2-3-AI.md): assistant (E-08 / A-04), route
// suggestions (C-04) and battle reports (C-05 / D-05). Every AI-written text
// carries `ai_generated`; the UI must label it「内容由 AI 生成」.
import '../claim/geo.dart';
import 'community_common.dart';
import 'models.dart';

LatLng? _ll(Object? v) {
  final m = jmn(v);
  if (m == null) return null;
  final lat = jdn(m['lat']), lng = jdn(m['lng']);
  return lat == null || lng == null ? null : LatLng(lat, lng);
}

/// `[[lng, lat], …]` (GeoJSON order) → points; also accepts `{lat, lng}`.
List<LatLng> _line(Object? v) {
  if (v is! List) return const [];
  final out = <LatLng>[];
  for (final e in v) {
    if (e is List && e.length >= 2 && e[0] is num && e[1] is num) {
      out.add(LatLng((e[1] as num).toDouble(), (e[0] as num).toDouble()));
    } else {
      final p = _ll(e);
      if (p != null) out.add(p);
    }
  }
  return out;
}

/// Weekly assistant quota. `remaining == null` when [unlimited].
class AIQuota {
  const AIQuota({this.unlimited = false, this.weeklyFree = 3, this.used = 0, this.remaining, this.resetsAt});
  final bool unlimited;
  final int weeklyFree;
  final int used;
  final int? remaining;
  final DateTime? resetsAt;

  bool get exhausted => !unlimited && remaining != null && remaining! <= 0;

  factory AIQuota.fromJson(Json j) => AIQuota(
        unlimited: jb(j['unlimited']),
        weeklyFree: ji(j['weekly_free'], 3),
        used: ji(j['used']),
        remaining: jin(j['remaining']),
        resetsAt: jdt(j['resets_at']),
      );

  static AIQuota? maybe(Object? v) => v is Map ? AIQuota.fromJson(v.cast<String, dynamic>()) : null;
}

/// `GET /v1/ai/info`.
class AIInfo {
  const AIInfo({
    this.enabled = true,
    this.modelName = '',
    this.registrationNo = '',
    this.vision = false,
    this.disclaimer = '内容由 AI 生成，仅供参考',
    this.quota = const AIQuota(),
  });
  final bool enabled;
  final String modelName;
  final String registrationNo;

  /// A vision model is configured: photos can be sent.
  final bool vision;
  final String disclaimer;
  final AIQuota quota;

  factory AIInfo.fromJson(Json j) => AIInfo(
        enabled: jb(j['enabled'], true),
        modelName: js(j['model_name']),
        registrationNo: js(j['registration_no']),
        vision: jb(j['vision']),
        disclaimer: js(j['disclaimer'], '内容由 AI 生成，仅供参考'),
        quota: AIQuota.maybe(j['quota']) ?? const AIQuota(),
      );

  AIInfo copyWith({AIQuota? quota, bool? vision}) => AIInfo(
        enabled: enabled,
        modelName: modelName,
        registrationNo: registrationNo,
        vision: vision ?? this.vision,
        disclaimer: disclaimer,
        quota: quota ?? this.quota,
      );
}

/// `GET /v1/ai/greeting` (template text, not model output).
class AIGreeting {
  const AIGreeting({required this.text, this.suggestions = const [], this.aiGenerated = false});
  final String text;
  final List<String> suggestions;
  final bool aiGenerated;

  factory AIGreeting.fromJson(Json j) => AIGreeting(
        text: js(j['text']),
        suggestions: [
          if (j['suggestions'] is List)
            for (final s in j['suggestions'] as List)
              if (s is String && s.isNotEmpty) s,
        ],
        aiGenerated: jb(j['ai_generated']),
      );
}

/// A place a route passes: `territory | boss | chest`.
class AIRouteTarget {
  const AIRouteTarget({required this.type, required this.id, required this.name, this.center, this.note = ''});
  final String type;
  final int id;
  final String name;
  final LatLng? center;
  final String note;

  factory AIRouteTarget.fromJson(Json j) {
    final lat = jdn(j['lat']), lng = jdn(j['lng']);
    return AIRouteTarget(
      type: js(j['type'], 'territory'),
      id: ji(j['id']),
      name: js(j['name']),
      center: lat != null && lng != null ? LatLng(lat, lng) : _ll(j['center']),
      note: js(j['note']),
    );
  }
}

/// C-04 route suggestion (also embedded in assistant cards).
class AIRoute {
  const AIRoute({
    required this.id,
    this.type = 'loop',
    this.title = '',
    this.subtitle = '',
    this.reason = '',
    this.distanceM = 0,
    this.estDurationSec = 0,
    this.estAreaM2 = 0,
    this.waypoints = const [],
    this.polyline = const [],
    this.targets = const [],
    this.aiGenerated = false,
  });

  /// Opaque, e.g. `r_8f2c1a`.
  final String id;

  /// `loop | capture | defend | boss`.
  final String type;
  final String title;
  final String subtitle;

  /// One sentence; model-written when [aiGenerated], else a template.
  final String reason;
  final double distanceM;
  final int estDurationSec;
  final double estAreaM2;
  final List<LatLng> waypoints;

  /// Road-snapped path (or straight lines between waypoints).
  final List<LatLng> polyline;
  final List<AIRouteTarget> targets;
  final bool aiGenerated;

  /// What to draw: the polyline, else the waypoints.
  List<LatLng> get path => polyline.length >= 2 ? polyline : waypoints;

  factory AIRoute.fromJson(Json j) => AIRoute(
        id: js(j['id']),
        type: js(j['type'], 'loop'),
        title: js(j['title']),
        subtitle: js(j['subtitle']),
        reason: js(j['reason']),
        distanceM: jd(j['distance_m']),
        estDurationSec: ji(j['est_duration_sec']),
        estAreaM2: jd(j['est_area_m2']),
        waypoints: _line(j['waypoints']),
        polyline: _line(j['polyline']),
        targets: jl(j['targets'], AIRouteTarget.fromJson),
        aiGenerated: jb(j['ai_generated']),
      );
}

/// `GET /v1/ai/routes`.
class AIRoutes {
  const AIRoutes({this.items = const [], this.aiGenerated = false});
  final List<AIRoute> items;
  final bool aiGenerated;
  factory AIRoutes.fromJson(Json j) => AIRoutes(items: jl(j['items'], AIRoute.fromJson), aiGenerated: jb(j['ai_generated']));
}

class AITerritoryRef {
  const AITerritoryRef({required this.id, required this.name, this.owner, this.crew, this.guard = 0, this.center});
  final int id;
  final String name;
  final UserRef? owner;
  final CrewRef? crew;
  final int guard;
  final LatLng? center;

  factory AITerritoryRef.fromJson(Json j) => AITerritoryRef(
        id: ji(j['id']),
        name: js(j['name']),
        owner: jmn(j['owner']) == null ? null : UserRef.fromJson(jm(j['owner'])),
        crew: jmn(j['crew']) == null ? null : CrewRef.fromJson(jm(j['crew'])),
        guard: ji(j['guard']),
        center: _ll(j['center']),
      );
}

class AIBossRef {
  const AIBossRef({required this.id, required this.name, this.hp = 0, this.maxHp = 1, this.center, this.endsAt});
  final int id;
  final String name;
  final int hp, maxHp;
  final LatLng? center;
  final DateTime? endsAt;

  double get hpFraction => maxHp <= 0 ? 0 : (hp / maxHp).clamp(0.0, 1.0);

  factory AIBossRef.fromJson(Json j) => AIBossRef(
        id: ji(j['id']),
        name: js(j['name']),
        hp: ji(j['hp']),
        maxHp: ji(j['max_hp'], 1),
        center: _ll(j['center']),
        endsAt: jdt(j['ends_at']),
      );
}

/// A tappable card in an assistant answer. Unknown types are kept (and not
/// rendered) so newer servers do not break older apps.
class AICard {
  const AICard({required this.type, this.route, this.territory, this.boss});
  final String type;
  final AIRoute? route;
  final AITerritoryRef? territory;
  final AIBossRef? boss;

  bool get known =>
      (type == 'route' && route != null) || (type == 'territory' && territory != null) || (type == 'boss' && boss != null);

  factory AICard.fromJson(Json j) => AICard(
        type: js(j['type']),
        route: jmn(j['route']) == null ? null : AIRoute.fromJson(jm(j['route'])),
        territory: jmn(j['territory']) == null ? null : AITerritoryRef.fromJson(jm(j['territory'])),
        boss: jmn(j['boss']) == null ? null : AIBossRef.fromJson(jm(j['boss'])),
      );
}

class AIMessage {
  const AIMessage({
    required this.id,
    required this.role,
    this.content = '',
    this.imageUrl,
    this.cards = const [],
    this.aiGenerated = false,
    this.createdAt,
  });
  final int id;

  /// `user | assistant`.
  final String role;
  final String content;
  final String? imageUrl;
  final List<AICard> cards;
  final bool aiGenerated;
  final DateTime? createdAt;

  bool get isUser => role == 'user';

  factory AIMessage.fromJson(Json j) => AIMessage(
        id: ji(j['id']),
        role: js(j['role'], 'assistant'),
        content: js(j['content']),
        imageUrl: jsn(j['image_url']),
        cards: jl(j['cards'], AICard.fromJson),
        aiGenerated: jb(j['ai_generated']),
        createdAt: jdt(j['created_at']),
      );

  AIMessage copyWith({int? id, String? content, List<AICard>? cards, bool? aiGenerated}) => AIMessage(
        id: id ?? this.id,
        role: role,
        content: content ?? this.content,
        imageUrl: imageUrl,
        cards: cards ?? this.cards,
        aiGenerated: aiGenerated ?? this.aiGenerated,
        createdAt: createdAt,
      );
}

/// 「问 AI」: the object the question is about.
class AIContext {
  const AIContext({required this.type, required this.id, this.name = ''});

  /// `territory | boss`.
  final String type;
  final int id;

  /// Display only (not sent).
  final String name;

  Json toJson() => {'type': type, 'id': id};
}

/// `POST /v1/ai/chat` result (JSON mode, or the `done` event).
class AIChatResult {
  const AIChatResult({required this.message, this.userMessage, this.quota});
  final AIMessage message;
  final AIMessage? userMessage;
  final AIQuota? quota;

  factory AIChatResult.fromJson(Json j) => AIChatResult(
        message: AIMessage.fromJson(jm(j['message'])),
        userMessage: jmn(j['user_message']) == null ? null : AIMessage.fromJson(jm(j['user_message'])),
        quota: AIQuota.maybe(j['quota']),
      );
}

/// One event of the streamed answer.
sealed class AIChatEvent {
  const AIChatEvent();
}

class AIDelta extends AIChatEvent {
  const AIDelta(this.text);
  final String text;
}

class AICardEvent extends AIChatEvent {
  const AICardEvent(this.card);
  final AICard card;
}

class AIDone extends AIChatEvent {
  const AIDone(this.result);
  final AIChatResult result;
}

/// `event: error` (`ai_unavailable`, …); the stream ends after it.
class AIError extends AIChatEvent {
  const AIError(this.code, this.message);
  final String code;
  final String message;
}

/// C-05 / D-05 `POST /v1/activities/{id}/ai-report`.
class AIReport {
  const AIReport({
    required this.activityId,
    required this.text,
    this.modelName = '',
    this.aiGenerated = true,
    this.generatedAt,
    this.regenerateLeft = 0,
  });
  final int activityId;
  final String text;
  final String modelName;
  final bool aiGenerated;
  final DateTime? generatedAt;
  final int regenerateLeft;

  factory AIReport.fromJson(Json j) => AIReport(
        activityId: ji(j['activity_id']),
        text: js(j['text']),
        modelName: js(j['model_name']),
        aiGenerated: jb(j['ai_generated'], true),
        generatedAt: jdt(j['generated_at']),
        regenerateLeft: ji(j['regenerate_left']),
      );
}
