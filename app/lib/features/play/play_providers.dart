import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../core/providers.dart';

final bossProvider = FutureProvider.autoDispose.family<Boss, int>((ref, id) => ref.watch(apiProvider).boss(id));

final seasonProvider = FutureProvider.autoDispose<SeasonOverview>((ref) => ref.watch(apiProvider).season());

/// '' = my crew's district.
final leagueProvider =
    FutureProvider.autoDispose.family<League, String>((ref, district) => ref.watch(apiProvider).league(district: district));

final campaignsProvider = FutureProvider.autoDispose<List<Campaign>>((ref) => ref.watch(apiProvider).campaigns());

final routesProvider = FutureProvider.autoDispose<List<CityRoute>>((ref) => ref.watch(apiProvider).routes());

final routeProvider = FutureProvider.autoDispose.family<CityRoute, int>((ref, id) => ref.watch(apiProvider).route(id));

final relayProvider =
    FutureProvider.autoDispose.family<Relay?, int>((ref, crewId) => ref.watch(apiProvider).currentRelay(crewId));
