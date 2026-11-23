import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../core/theme.dart';
import '../../widgets/l_icons.dart';
import 'play_widgets.dart';

/// 守地挑战: shown on my territory after an attack, until the deadline.
class DefenseBanner extends StatelessWidget {
  const DefenseBanner({super.key, required this.defense, this.onGo});
  final TerritoryDefense defense;
  final VoidCallback? onGo;

  @override
  Widget build(BuildContext context) {
    final by = defense.attackedBy?.nickname;
    return Countdown(
      until: defense.deadline,
      builder: (context, left) {
        if (defense.deadline != null && left == Duration.zero) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF2A1A14),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: LL.orange, width: 1.5),
          ),
          child: Row(children: [
            const LIcon(LIcons.shield, color: LL.orange, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(by == null ? '守地挑战' : '守地挑战 · $by 攻击了这里',
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                const SizedBox(height: 2),
                const Text('24 小时内跑一圈经过这里即可加固', style: TextStyle(color: LL.text2, fontSize: 12)),
                const SizedBox(height: 2),
                Text('还剩 ${formatCountdown(left)}',
                    style: const TextStyle(color: LL.orange, fontWeight: FontWeight.w800, fontSize: 13)),
              ]),
            ),
            if (onGo != null)
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: LL.orange, minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 14)),
                onPressed: onGo,
                child: const Text('去守地'),
              ),
          ]),
        );
      },
    );
  }
}
