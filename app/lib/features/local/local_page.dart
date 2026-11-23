import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../auth/auth_controller.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import 'booking_tab.dart';
import 'campaigns_tab.dart';
import 'product_pages.dart' show PromotionStrip;
import 'shop_tab.dart';

/// Tab keys for `/local?tab=`.
const localTabs = ['booking', 'campaigns', 'shop'];

/// 本地生活（设计稿 08）：订场 · 联名活动 · 能量商城.
class LocalPage extends ConsumerStatefulWidget {
  const LocalPage({super.key, this.tab = 'booking', this.sport = '', this.now});
  final String tab;

  /// Preselected sport chip of 订场 (`/local?sport=pickleball`).
  final String sport;
  final DateTime Function()? now;

  @override
  ConsumerState<LocalPage> createState() => _LocalPageState();
}

class _LocalPageState extends ConsumerState<LocalPage> {
  late int _tab = localTabs.indexOf(widget.tab).clamp(0, 2);

  /// Tabs are built on first visit (each loads its own data), then kept.
  late final _visited = <int>{_tab};

  @override
  Widget build(BuildContext context) {
    final energy = ref.watch(userProvider)?.energy ?? 0;
    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
            child: Row(children: [
              IconButton(
                onPressed: () => context.canPop() ? context.pop() : context.go('/me'),
                icon: const LIcon(LIcons.back),
              ),
              const SizedBox(width: 4),
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('本地生活', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                  Text('订场 · 品牌联名 · 用能量换福利', style: TextStyle(color: LL.text2, fontSize: 13)),
                ]),
              ),
              EnergyBadge(energy: energy),
            ]),
          ),
          // V2 batch 5: running official promotions (hidden when none).
          const PromotionStrip(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(children: [
              Expanded(
                child: PillTabs(labels: const ['订场', '联名活动', '能量商城'], index: _tab, onChanged: (i) => setState(() {
                  _tab = i;
                  _visited.add(i);
                })),
              ),
            ]),
          ),
          if (_tab == 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton.icon(
                  key: const Key('my_bookings'),
                  onPressed: () => context.push('/me/bookings'),
                  icon: const LIcon(LIcons.receipt, size: 18),
                  label: const Text('我的订场'),
                ),
              ]),
            ),
          Expanded(
            child: IndexedStack(index: _tab, children: [
              if (_visited.contains(0)) BookingTab(initialSport: widget.sport, now: widget.now) else const SizedBox.shrink(),
              if (_visited.contains(1)) const CampaignsTab() else const SizedBox.shrink(),
              if (_visited.contains(2)) const ShopTab() else const SizedBox.shrink(),
            ]),
          ),
        ]),
      ),
    );
  }
}
