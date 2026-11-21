import 'package:go_router/go_router.dart';

import '../../api/gathering_models.dart';
import '../chat/chat_page.dart';
import '../chat/conversations_page.dart';
import '../meetups/meetup_pages.dart';
import '../races/race_pages.dart';
import 'crew_extras.dart';

/// V2 社区 · 组局 / 集结跑 / 赛事 / 消息 / 聊天 / 跑团补充. `/inbox` (消息)
/// and `/crews/:id` stay in app.dart. Literal paths come before `:id` ones.
List<RouteBase> gatheringRoutes() {
  int id(GoRouterState s, [String key = 'id']) => int.tryParse(s.pathParameters[key] ?? '') ?? 0;
  return [
    GoRoute(path: '/meetups', builder: (_, _) => const MeetupsPage()),
    GoRoute(path: '/meetups/new', builder: (_, _) => const MeetupCreatePage()),
    GoRoute(path: '/meetups/:id', builder: (_, s) => MeetupDetailPage(meetupId: id(s))),
    GoRoute(path: '/races', builder: (_, _) => const RacesPage()),
    GoRoute(path: '/races/:id', builder: (_, s) => RaceDetailPage(raceId: id(s))),
    GoRoute(path: '/conversations', builder: (_, _) => const ConversationsPage()),
    GoRoute(path: '/chat/direct/:userId', builder: (_, s) => DirectChatPage(userId: id(s, 'userId'))),
    GoRoute(
      path: '/chat/:conversationId',
      builder: (_, s) => ChatPage(
        conversationId: id(s, 'conversationId'),
        initial: s.extra is Conversation ? s.extra! as Conversation : null,
      ),
    ),
    GoRoute(path: '/crews/join-code', builder: (_, s) => JoinByCodePage(code: s.uri.queryParameters['code'])),
    GoRoute(path: '/crews/:id/edit', builder: (_, s) => CrewEditPage(crewId: id(s))),
  ];
}
