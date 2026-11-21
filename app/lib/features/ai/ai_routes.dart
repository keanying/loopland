import 'package:go_router/go_router.dart';

import '../../api/ai_models.dart';
import 'ai_page.dart';

/// V2 batch 3「AI」routes.
///
/// | path | page |
/// | --- | --- |
/// | `/ai` | AI 助手圈圈 (E-08) |
/// | `/ai?context=territory\|boss&id=<id>&name=<name>` | 「问 AI」带着对象打开 (A-04) |
///
/// AI routes open the run setup with `extra: AIRouteLaunch` (`/start/gps`).
List<RouteBase> aiRoutes() => [
      GoRoute(
        path: '/ai',
        builder: (_, s) {
          final q = s.uri.queryParameters;
          final type = q['context'];
          final id = int.tryParse(q['id'] ?? '');
          final ctx = (type == 'territory' || type == 'boss') && id != null
              ? AIContext(type: type!, id: id, name: q['name'] ?? '')
              : (s.extra is AIContext ? s.extra! as AIContext : null);
          return AIAssistantPage(initialContext: ctx);
        },
      ),
    ];
