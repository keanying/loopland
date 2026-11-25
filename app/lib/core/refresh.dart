// 数据刷新约定（见 app/README.md「数据刷新约定」）。
//
// 改了服务端状态的操作成功后，调用这里对应的 after…()，不要在页面里零散地
// invalidate。invalidate 一个没人在看的 autoDispose provider 几乎没有开销
// （下次打开页面时本来就会重新请求），所以这里宁可多刷，不要漏刷：标签页
// （IndexedStack）和压在栈底的页面一直在看自己的 provider，漏刷就会一直显示旧数据。
//
// 页面自己用 State 存的列表（CursorPager、地图上的领地等）没法被 invalidate，
// 它们在 build 里用 `ref.onDataChanged([DataTopic.x], _reload)` 订阅主题，
// after…() 会 bump 对应主题。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderOrFamily;

import '../auth/auth_controller.dart';
import '../features/ai/ai_providers.dart';
import '../features/community/community_page.dart' show crewApplicationsProvider, crewMembersProvider, crewProvider;
import '../features/community/gathering_providers.dart';
import '../features/local/local_providers.dart';
import '../features/local/perks_providers.dart';
import '../features/local/product_providers.dart';
import '../features/me/activity_pages.dart' show activityProvider;
import '../features/me/membership_page.dart' show membershipProvider, plansProvider;
import '../features/play/play_providers.dart';
import '../features/social/profile_pages.dart' show blocksProvider;
import '../features/social/social_providers.dart';
import '../pay/payment_service.dart';
import '../run/uploader.dart';
import 'providers.dart';

/// Data kept in page state (not in a provider) that a page reloads when the
/// topic is bumped.
enum DataTopic {
  /// Territories / map objects on the map (runs, captures, crew changes, skins).
  territory,


  /// Meetup / race lists (join, leave, signup, create, cancel).
  gathering,

  /// Feeds and post lists (block / unblock, deleted posts).
  social,

  /// The app came back after a longer absence: reload what is on screen.
  resume,
}

class DataVersion extends Notifier<int> {
  DataVersion(this.topic);
  final DataTopic topic;
  @override
  int build() => 0;
  void bump() => state++;
}

final dataVersionProvider = NotifierProvider.family<DataVersion, int, DataTopic>(DataVersion.new);

extension DataChangedRef on WidgetRef {
  /// Call in `build`: runs [reload] after any of [topics] was bumped.
  void onDataChanged(List<DataTopic> topics, void Function() reload) {
    for (final t in topics) {
      listen<int>(dataVersionProvider(t), (_, _) => reload());
    }
  }
}

final refreshProvider = Provider<Refresh>(Refresh.new);

/// Reusable "what to reload after X" helpers. All of them are safe to call
/// without awaiting; the returned future completes after `/v1/me` was
/// re-read (errors are swallowed: a failed refresh keeps the old data).
class Refresh {
  Refresh(this._ref);
  final Ref _ref;

  /// When the app was last sent to the background.
  DateTime? _pausedAt;

  /// Away at least this long → also reload the tabs' main data on resume.
  static const longAway = Duration(minutes: 2);

  void _invalidate(List<ProviderOrFamily> ps) {
    for (final p in ps) {
      _ref.invalidate(p);
    }
  }

  void bump(DataTopic t) => _ref.read(dataVersionProvider(t).notifier).bump();

  /// Re-reads `/v1/me` (energy, level, stats, membership, crew, equipped).
  Future<void> user() async {
    if (!_ref.read(authProvider).loggedIn) return;
    try {
      await _ref.read(authProvider.notifier).refreshUser();
    } catch (_) {}
  }

  /// Membership bought / restored / renewed / auto-renew toggled: user,
  /// membership card, AI quota (members are unlimited), replay export.
  Future<void> afterMembershipChange() {
    _invalidate([membershipProvider, aiInfoProvider, replayExportProvider]);
    return user();
  }

  /// Any order paid (membership, booking, product, race fee) — also used
  /// when the result arrives late (resume, re-check of an unsettled order).
  Future<void> afterPayment() {
    _invalidate([
      myBookingsProvider,
      bookingProvider,
      slotsProvider,
      myProductOrdersProvider,
      productOrderProvider,
      productProvider,
      myCouponsProvider,
      raceProvider,
      meetupProvider,
      myMeetupsProvider,
      communityHomeProvider,
    ]);
    bump(DataTopic.gathering);
    return afterMembershipChange();
  }

  /// Energy spent or earned outside a run (shop, building, feeding, chest,
  /// boss strike, venue check-in).
  Future<void> afterEnergyChange() => user();

  /// Equipped / bought cosmetics: avatar frame on profiles, skins on the map.
  Future<void> afterCosmeticsChange() {
    _invalidate([myProfileProvider, profileProvider]);
    bump(DataTopic.territory);
    return afterEnergyChange();
  }

  /// A run / home training / coach session was settled (also offline runs
  /// uploaded later): energy, level, stats, territories, codex, season tasks,
  /// medals, league, campaigns, routes, relay, race progress, coupons won.
  Future<void> afterRunSettled() {
    _invalidate([
      pendingUploadsProvider,
      codexProvider,
      territoryProvider,
      myProfileProvider,
      recentRunsProvider,
      activityProvider,
      seasonProvider,
      leagueProvider,
      campaignsProvider,
      routesProvider,
      routeProvider,
      relayProvider,
      bossProvider,
      raceProvider,
      communityHomeProvider,
      crewProvider,
      myCouponsProvider,
      brandCampaignsProvider,
      inboxUnreadProvider,
      inboxSummaryProvider,
    ]);
    bump(DataTopic.territory);
    bump(DataTopic.gathering);
    return user();
  }

  /// Territory changed in place (building, stationing): codex shows where
  /// roles are stationed, the map shows the territory.
  Future<void> afterTerritoryChange(int territoryId) {
    _ref.invalidate(territoryProvider(territoryId));
    _invalidate([codexProvider]);
    bump(DataTopic.territory);
    return afterEnergyChange();
  }

  /// Joined / left / created / edited a crew, membership decided, kicked,
  /// transferred: 社区 home card, crew pages, my crew on the user, crew
  /// territories on the map, league / relay.
  Future<void> afterCrewChange() {
    _invalidate([
      communityHomeProvider,
      crewProvider,
      crewMembersProvider,
      crewApplicationsProvider,
      ralliesProvider,
      relayProvider,
      leagueProvider,
    ]);
    bump(DataTopic.territory);
    return user();
  }

  /// Meetup / rally / race joined, left, created, cancelled, signed up.
  void afterGatheringChange() {
    _invalidate([communityHomeProvider, myMeetupsProvider, meetupProvider, ralliesProvider, raceProvider]);
    bump(DataTopic.gathering);
  }

  /// Followed / unfollowed someone: my following count. (Their profile page
  /// adjusts its own counts.)
  void afterFollowChange() => _invalidate([myProfileProvider]);

  /// Blocked / unblocked someone: counts, the block list, feeds that still
  /// show their posts.
  void afterBlockChange() {
    _invalidate([myProfileProvider, blocksProvider]);
    bump(DataTopic.social);
  }

  /// Posted / deleted a post, changed my nickname / avatar / bio / settings:
  /// my profile (counts, header). Feeds update through [postCacheProvider].
  void afterProfileChange() {
    _invalidate([myProfileProvider]);
    final me = _ref.read(userProvider)?.id;
    if (me != null) _ref.invalidate(profileProvider(me));
  }

  /// Notifications / conversations read: every unread badge.
  void afterInboxRead() => _invalidate([inboxUnreadProvider, inboxSummaryProvider, communityHomeProvider]);

  /// Coupon claimed / used (supply drop, campaign).
  void afterCouponChange() => _invalidate([myCouponsProvider, brandCampaignsProvider]);

  /// Real-name verified (adult / minor decides paid entries), deletion
  /// requested / withdrawn.
  Future<void> afterAccountChange() {
    _invalidate([plansProvider, membershipProvider]);
    return user();
  }

  void paused() => _pausedAt = DateTime.now();

  /// App back in the foreground: the user may have paid in the WeChat /
  /// Alipay app, renewed, or been away long enough for data to move.
  Future<void> resumed() async {
    final away = _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);
    _pausedAt = null;
    if (!_ref.read(authProvider).loggedIn) return;
    // Cheap and the usual suspects after a payment / renewal.
    _invalidate([
      aiInfoProvider,
      membershipProvider,
      replayExportProvider,
      inboxUnreadProvider,
      inboxSummaryProvider,
      myBookingsProvider,
      bookingProvider,
      myProductOrdersProvider,
      productOrderProvider,
      raceProvider,
    ]);
    if (away >= longAway) {
      _invalidate([codexProvider, communityHomeProvider, seasonProvider, myProfileProvider]);
      bump(DataTopic.resume);
    }
    var paid = false;
    try {
      paid = (await _ref.read(paymentServiceProvider).recheckUnsettled()).isNotEmpty;
    } catch (_) {}
    return paid ? afterPayment() : user();
  }
}
