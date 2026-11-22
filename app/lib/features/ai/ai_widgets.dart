import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/ai_models.dart';
import '../../core/features.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../social/social_widgets.dart';
import 'ai_providers.dart';

/// 「内容由 AI 生成」 — required next to every AI-written text
/// (《人工智能生成合成内容标识办法》).
class AILabel extends StatelessWidget {
  const AILabel({super.key, this.color = LL.text3, this.text = '内容由 AI 生成'});
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) => Semantics(
        label: text,
        excludeSemantics: true,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_awesome_rounded, size: 12, color: color),
          const SizedBox(width: 3),
          Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Round lavender "AI" badge (assistant avatar).
class AIBadge extends StatelessWidget {
  const AIBadge({super.key, this.size = 44});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: const BoxDecoration(color: LL.lavender, shape: BoxShape.circle),
        child: Text('AI', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: size * 0.32)),
      );
}

/// 「圈圈」入口的图标：星芒加一个小「AI」角标，一眼能认出是 AI 助手。
class AIMark extends StatelessWidget {
  const AIMark({super.key, this.size = 22, this.color = LL.ink});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: Stack(clipBehavior: Clip.none, children: [
          Icon(Icons.auto_awesome_rounded, size: size, color: color),
          Positioned(
            right: -size * 0.45,
            top: -size * 0.3,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: size * 0.14, vertical: size * 0.02),
              decoration: BoxDecoration(
                color: LL.ink,
                borderRadius: BorderRadius.circular(size),
                border: Border.all(color: LL.lime, width: 1),
              ),
              child: Text('AI',
                  style: TextStyle(color: LL.lime, fontSize: size * 0.4, fontWeight: FontWeight.w900, height: 1.1)),
            ),
          ),
        ]),
      );
}

IconData aiRouteIcon(String type) => switch (type) {
      'capture' => Icons.flag_outlined,
      'defend' => Icons.shield_outlined,
      'boss' => Icons.whatshot_rounded,
      _ => Icons.loop_rounded,
    };

Color aiRouteColor(String type) => switch (type) {
      'capture' => LL.pink,
      'defend' => LL.lavender,
      'boss' => LL.orange,
      _ => LL.lime,
    };

String aiRouteStats(AIRoute r) => [
      '${Fmt.km(r.distanceM, digits: 1)} km',
      if (r.estDurationSec > 0) '约 ${(r.estDurationSec / 60).round()} 分钟',
      if (r.estAreaM2 > 0) '可圈 ${(r.estAreaM2 / 1e6).toStringAsFixed(2)} km²',
    ].join(' · ');

/// 「问 AI」 opens the assistant about [aiContext]. Hidden when AI is off.
class AskAIButton extends ConsumerWidget {
  const AskAIButton({super.key, required this.aiContext, this.compact = false, this.beforeOpen});
  final AIContext aiContext;

  /// Pill for headers; otherwise a full-width outlined button.
  final bool compact;

  /// E.g. close the bottom sheet first.
  final VoidCallback? beforeOpen;

  static String location(AIContext c) =>
      '/ai?context=${c.type}&id=${c.id}${c.name.isEmpty ? '' : '&name=${Uri.encodeComponent(c.name)}'}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(aiEnabledProvider)) return const SizedBox.shrink();
    void open() {
      final router = GoRouter.of(context);
      beforeOpen?.call();
      router.push(location(aiContext));
    }

    if (compact) {
      return Semantics(
        button: true,
        label: '问 AI',
        excludeSemantics: true,
        child: Material(
          color: LL.lavender,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: open,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.auto_awesome_rounded, color: LL.ink, size: 16),
                SizedBox(width: 4),
                Text('问 AI', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: 13)),
              ]),
            ),
          ),
        ),
      );
    }
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(foregroundColor: LL.lavender, side: const BorderSide(color: LL.lavender)),
      onPressed: open,
      icon: const Icon(Icons.auto_awesome_rounded),
      label: const Text('问 AI'),
    );
  }
}

/// Assistant route card: mini map, stats, reason, 「一键开跑」.
class AIRouteCard extends StatelessWidget {
  const AIRouteCard({super.key, required this.route, this.onStart});
  final AIRoute route;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final r = route;
    final color = aiRouteColor(r.type);
    return Container(
      decoration: BoxDecoration(
        color: LL.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (r.path.length >= 2)
          SizedBox(
            height: 120,
            child: ColoredBox(color: const Color(0xFF141418), child: TrackView(track: r.path, color: color, padding: 18)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(aiRouteIcon(r.type), color: color, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(r.title.isEmpty ? 'AI 路线' : r.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
              ),
            ]),
            if (r.subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(r.subtitle, style: const TextStyle(color: LL.text2, fontSize: 12)),
            ],
            const SizedBox(height: 10),
            Row(children: [
              _Stat(Fmt.km(r.distanceM, digits: 1), 'km'),
              _Stat(r.estAreaM2 > 0 ? (r.estAreaM2 / 1e6).toStringAsFixed(2) : '-', '可圈 km²'),
              _Stat(r.estDurationSec > 0 ? '${(r.estDurationSec / 60).round()}' : '-', '分钟'),
            ]),
            if (r.reason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(r.reason, style: const TextStyle(color: Color(0xFFD6D6DD), fontSize: 12, height: 1.5)),
              if (r.aiGenerated) const Padding(padding: EdgeInsets.only(top: 4), child: AILabel()),
            ],
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44), backgroundColor: color, foregroundColor: LL.ink),
                onPressed: onStart,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('一键开跑'),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.label);
  final String value, label;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
          Text(label, style: const TextStyle(color: LL.text2, fontSize: 10)),
        ]),
      );
}

/// Assistant territory card → focus it on the map.
class AITerritoryCard extends StatelessWidget {
  const AITerritoryCard({super.key, required this.territory, this.onTap});
  final AITerritoryRef territory;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = territory;
    final weak = t.guard < 60;
    final color = weak ? LL.pink : LL.orange;
    final meta = [
      if (t.crew != null) '「${t.crew!.name}」' else if (t.owner != null) t.owner!.nickname else '无主之地',
      '守卫值 ${t.guard}',
    ].join(' · ');
    return Material(
      color: LL.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: LL.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                Text(meta, style: const TextStyle(color: LL.text2, fontSize: 11)),
              ]),
            ),
            Text('在地图上看', style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800)),
            Icon(Icons.chevron_right_rounded, color: color, size: 18),
          ]),
        ),
      ),
    );
  }
}

/// Assistant boss card → boss page.
class AIBossCard extends StatelessWidget {
  const AIBossCard({super.key, required this.boss, this.onTap});
  final AIBossRef boss;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final b = boss;
    final left = b.endsAt?.difference(DateTime.now());
    return Material(
      color: LL.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: LL.orange)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.whatshot_rounded, color: LL.orange, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text(b.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14))),
              if (left != null && left > Duration.zero)
                Text('剩 ${left.inHours > 0 ? '${left.inHours} 小时' : '${left.inMinutes.clamp(1, 59)} 分钟'}',
                    style: const TextStyle(color: LL.text2, fontSize: 11)),
              const SizedBox(width: 6),
              const Text('去出战', style: TextStyle(color: LL.orange, fontSize: 12, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: b.hpFraction,
                minHeight: 8,
                color: const Color(0xFFFF6A3D),
                backgroundColor: const Color(0xFF2A2A31),
              ),
            ),
            const SizedBox(height: 4),
            Text('血量 ${Fmt.thousands(b.hp)} / ${Fmt.thousands(b.maxHp)}', style: const TextStyle(color: LL.text2, fontSize: 11)),
          ]),
        ),
      ),
    );
  }
}

/// Opens [card]'s target: route → start with guide, territory → map focus,
/// boss → boss page.
void openAICard(BuildContext context, WidgetRef ref, AICard card) {
  switch (card.type) {
    case 'route':
      context.push('/start/gps?sport=run', extra: AIRouteLaunch(card.route!, autostart: true));
    case 'territory':
      final t = card.territory!;
      if (t.center != null) {
        ref.read(mapFocusProvider.notifier).focus(MapFocus(t.center!, territoryId: t.id));
        context.go('/map');
      } else {
        context.push('/city/${t.id}');
      }
    case 'boss':
      context.push('/bosses/${card.boss!.id}');
  }
}

/// D-05: a post's AI 战报, shown apart from the author's text.
class AIReportBlock extends StatelessWidget {
  const AIReportBlock({super.key, required this.text, this.aiGenerated = true, this.trailing, this.maxLines});
  final String text;
  final bool aiGenerated;
  final Widget? trailing;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(color: const Color(0xFF26223A), borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_awesome_rounded, size: 16, color: LL.lavender),
            const SizedBox(width: 6),
            const Text('AI 战报', style: TextStyle(color: LL.lavender, fontWeight: FontWeight.w900, fontSize: 13)),
            const Spacer(),
            ?trailing,
          ]),
          const SizedBox(height: 6),
          Text(text,
              maxLines: maxLines,
              overflow: maxLines == null ? null : TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, height: 1.55)),
          if (aiGenerated) const Padding(padding: EdgeInsets.only(top: 6), child: AILabel(color: Color(0xFF9C92C9))),
        ]),
      );
}
