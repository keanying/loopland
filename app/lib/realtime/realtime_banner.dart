import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../core/theme.dart';
import '../widgets/l_icons.dart';
import 'realtime_providers.dart';

/// What a banner shows and where tapping it goes.
class BannerData {
  const BannerData({required this.icon, required this.color, required this.title, required this.body, required this.path});
  final LGlyph icon;
  final Color color;
  final String title, body;
  final String path;

  /// Banner for a push, or null for events that do not need one.
  static BannerData? from(RealtimeEvent e) => switch (e) {
        TerritoryAttackedEvent(:final territoryId, :final captured, :final guardAfter) => captured
            ? BannerData(
                icon: LIcons.flagFilled,
                color: LL.red,
                title: '领地 #$territoryId 被抢走了',
                body: '去看看，跑一圈把它夺回来',
                path: '/city/$territoryId',
              )
            : BannerData(
                icon: LIcons.shield,
                color: LL.orange,
                title: '领地 #$territoryId 正在被攻击',
                body: '守卫降到 $guardAfter · 24 小时内跑一圈经过这里即可加固',
                path: '/city/$territoryId',
              ),
        RallyEvent(:final bossId, :final by) => BannerData(
            icon: LIcons.bolt,
            color: const Color(0xFFFF6A3D),
            title: '合击召集',
            body: '${by?.nickname ?? '团友'} 正在合击怪兽，快来一起出手！',
            path: '/bosses/$bossId',
          ),
        _ => null,
      };
}

/// Shows a top banner for `territory_attacked` and `rally` pushes; tapping
/// it opens the territory / boss page.
class RealtimeBannerHost extends ConsumerStatefulWidget {
  const RealtimeBannerHost({super.key, required this.child, required this.onOpen});
  final Widget child;
  final ValueChanged<String> onOpen;

  @override
  ConsumerState<RealtimeBannerHost> createState() => _RealtimeBannerHostState();
}

class _RealtimeBannerHostState extends ConsumerState<RealtimeBannerHost> {
  BannerData? _shown;
  Timer? _hide;

  void _show(BannerData b) {
    _hide?.cancel();
    setState(() => _shown = b);
    _hide = Timer(const Duration(seconds: 6), _dismiss);
  }

  void _dismiss() {
    _hide?.cancel();
    if (mounted) setState(() => _shown = null);
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<RealtimeEvent>>(realtimeEventsProvider, (_, next) {
      final e = next.value;
      final b = e == null ? null : BannerData.from(e);
      if (b != null) _show(b);
    });
    final b = _shown;
    final top = MediaQuery.paddingOf(context).top;
    return Stack(children: [
      widget.child,
      AnimatedPositioned(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        left: 12,
        right: 12,
        top: b == null ? -140 : top + 8,
        child: b == null
            ? const SizedBox.shrink()
            : Dismissible(
                key: ValueKey(b),
                direction: DismissDirection.up,
                onDismissed: (_) => _dismiss(),
                child: Material(
                  color: LL.card2,
                  elevation: 8,
                  shadowColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: BorderSide(color: b.color, width: 1.5)),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      _dismiss();
                      widget.onOpen(b.path);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(color: b.color, shape: BoxShape.circle),
                          child: LIcon(b.icon, color: LL.ink),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text(b.title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: LL.text)),
                            const SizedBox(height: 2),
                            Text(b.body, style: const TextStyle(color: LL.text2, fontSize: 12)),
                          ]),
                        ),
                        const LIcon(LIcons.chevronRight, color: LL.text3),
                      ]),
                    ),
                  ),
                ),
              ),
      ),
    ]);
  }
}
