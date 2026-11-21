import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/gathering_api.dart';
import '../../api/gathering_models.dart';
import '../../api/models.dart';
import '../../realtime/realtime_providers.dart';

final communityHomeProvider =
    FutureProvider.autoDispose<CommunityHome>((ref) => ref.watch(gatheringApiProvider).communityHome());

final inboxSummaryProvider =
    FutureProvider.autoDispose<InboxSummary>((ref) => ref.watch(gatheringApiProvider).inboxSummary());

final meetupProvider =
    FutureProvider.autoDispose.family<Meetup, int>((ref, id) => ref.watch(gatheringApiProvider).meetup(id));

final myMeetupsProvider = FutureProvider.autoDispose<List<Meetup>>((ref) => ref.watch(gatheringApiProvider).myMeetups());

final ralliesProvider =
    FutureProvider.autoDispose.family<List<Rally>, int>((ref, crewId) => ref.watch(gatheringApiProvider).rallies(crewId));

final raceProvider = FutureProvider.autoDispose.family<Race, int>((ref, id) => ref.watch(gatheringApiProvider).race(id));

/// `chat_message` / `conversation_read` pushes from the app WebSocket.
final chatEventsProvider = StreamProvider<ChatEvent>((ref) => ref
    .watch(realtimeClientProvider)
    .events
    .where((e) => e is UnknownEvent)
    .map((e) => ChatEvent.parse((e as UnknownEvent).raw))
    .where((e) => e != null)
    .cast<ChatEvent>());
