import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../core/providers.dart';
import '../core/refresh.dart';
import '../features/community/gathering_providers.dart';
import '../realtime/realtime_client.dart';
import '../realtime/realtime_providers.dart';

/// Keeps cached data fresh without user action (see「数据刷新约定」in
/// app/README.md):
/// - back from the background (WeChat / Alipay app, App Store sheet, a long
///   break) → [Refresh.resumed]: user, membership, AI quota, unread counts,
///   orders, unsettled payments; after [Refresh.longAway] the tabs too;
/// - WebSocket pushes: a territory attacked / captured, a rally, a chat
///   message update the pages that show them; a reconnect re-reads what may
///   have been missed while offline.
class DataSync extends ConsumerStatefulWidget {
  const DataSync({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<DataSync> createState() => _DataSyncState();
}

class _DataSyncState extends ConsumerState<DataSync> {
  late final AppLifecycleListener _life;
  bool _left = false;
  Timer? _chat;
  RealtimeStatus? _status;
  bool _connectedOnce = false;

  Refresh get _refresh => ref.read(refreshProvider);

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(
      onHide: () {
        _left = true;
        _refresh.paused();
      },
      onResume: () {
        // inactive → resumed alone (a system dialog, the notification shade)
        // is not "coming back".
        if (!_left) return;
        _left = false;
        _refresh.resumed();
      },
    );
  }

  @override
  void dispose() {
    _life.dispose();
    _chat?.cancel();
    super.dispose();
  }

  void _onEvent(RealtimeEvent e) {
    switch (e) {
      case TerritoryAttackedEvent(:final territoryId, :final captured):
        ref.invalidate(territoryProvider(territoryId));
        _refresh.bump(DataTopic.territory);
        if (captured) _refresh.user(); // territory count / area
      case RallyEvent():
        ref.invalidate(ralliesProvider);
        ref.invalidate(communityHomeProvider);
      case UnknownEvent(:final raw) when raw['type'] == 'chat_message' || raw['type'] == 'conversation_read':
        // Unread badges; coalesce a burst of messages into one reload.
        _chat?.cancel();
        _chat = Timer(const Duration(seconds: 2), () {
          if (!mounted) return;
          ref.invalidate(inboxSummaryProvider);
          ref.invalidate(communityHomeProvider);
        });
      default:
        break;
    }
  }

  void _onStatus(RealtimeStatus s) {
    final was = _status;
    _status = s;
    if (s != RealtimeStatus.connected || was == RealtimeStatus.connected) return;
    // Reconnected after a drop: pushes sent meanwhile are lost.
    if (_connectedOnce) {
      ref.invalidate(inboxSummaryProvider);
      ref.invalidate(inboxUnreadProvider);
      _refresh.bump(DataTopic.territory);
    }
    _connectedOnce = true;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<RealtimeEvent>>(realtimeEventsProvider, (_, next) {
      final e = next.value;
      if (e != null) _onEvent(e);
    });
    ref.listen<AsyncValue<RealtimeStatus>>(realtimeStatusProvider, (_, next) {
      final s = next.value;
      if (s != null) _onStatus(s);
    });
    return widget.child;
  }
}
