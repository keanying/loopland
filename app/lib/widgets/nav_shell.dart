import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/providers.dart';
import '../core/theme.dart';
import 'card_art.dart';

/// Scaffold with the floating rounded bottom bar: 领地 / 图鉴 / 开始 / 社区 / 我的.
class NavShell extends ConsumerWidget {
  const NavShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const double barHeight = 76;

  /// Bottom padding pages should leave for the floating bar.
  static double bottomInset(BuildContext context) => barHeight + 28 + MediaQuery.paddingOf(context).bottom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final escort = ref.watch(codexProvider).value?.companions.where((c) => c.escort).firstOrNull;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(child: shell),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12 + bottom,
          child: _Bar(
            index: shell.currentIndex,
            onTap: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
            centerArt: escort?.key ?? 'gecko',
          ),
        ),
      ]),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.index, required this.onTap, required this.centerArt});
  final int index;
  final ValueChanged<int> onTap;
  final String centerArt;

  @override
  Widget build(BuildContext context) {
    Widget item(int i, IconData icon, String label) {
      final sel = index == i;
      return Expanded(
        child: Semantics(
          button: true,
          selected: sel,
          label: label,
          child: InkResponse(
            onTap: () => onTap(i),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, color: sel ? LL.text : LL.text3, size: 28),
              const SizedBox(height: 4),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: sel ? LL.lime : Colors.transparent, shape: BoxShape.circle),
              ),
            ]),
          ),
        ),
      );
    }

    return SizedBox(
      height: NavShell.barHeight + 18,
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.bottomCenter, children: [
        Container(
          height: NavShell.barHeight,
          decoration: BoxDecoration(
            color: const Color(0xF21B1B20),
            borderRadius: BorderRadius.circular(38),
            border: Border.all(color: LL.border),
            boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 24, offset: Offset(0, 8))],
          ),
          child: Row(children: [
            item(0, Icons.map_outlined, '领地'),
            item(1, Icons.content_copy_outlined, '图鉴'),
            const SizedBox(width: 88),
            item(3, Icons.groups_outlined, '社区'),
            item(4, Icons.person_outline_rounded, '我的'),
          ]),
        ),
        Positioned(
          bottom: 8,
          child: Semantics(
            button: true,
            label: '开始',
            child: GestureDetector(
              onTap: () => onTap(2),
              child: Container(
                width: 84,
                height: 84,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: LL.night,
                  border: Border.all(color: index == 2 ? LL.lime : LL.lavender.withValues(alpha: 0.7), width: 2),
                  boxShadow: [BoxShadow(color: LL.lavender.withValues(alpha: 0.35), blurRadius: 18)],
                ),
                child: ClipOval(
                  child: Container(
                    color: index == 2 ? LL.lime.withValues(alpha: 0.25) : LL.card,
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: CardArt(artKey: centerArt, width: 80),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
