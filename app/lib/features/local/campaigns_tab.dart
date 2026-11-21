// 本地生活 ·「联名活动」tab (A-16 / M-26): running brand campaigns with their
// perks, rules, how to get the coupon (补给站 / 商户宝箱 / 据点) and the drop
// locations (tap → centre the territory map there).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/perks_models.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../ai/ai_providers.dart';
import '../social/social_widgets.dart' show mediaUrl;
import 'perks_providers.dart';

const _cardColors = [LL.lime, LL.pink, LL.sky, LL.lavender, LL.yellow];

IconData dropIcon(String type) => switch (type) {
      'supply' => Icons.local_cafe_rounded,
      'chest' => Icons.inventory_2_rounded,
      'stronghold' => Icons.sports_tennis_rounded,
      _ => Icons.place_rounded,
    };

Color dropColor(String type) => switch (type) {
      'supply' => LL.pink,
      'chest' => LL.yellow,
      'stronghold' => LL.sky,
      _ => LL.lime,
    };

String _range(DateTime? a, DateTime? b) {
  final f = DateFormat('M.d');
  if (a == null && b == null) return '';
  if (b == null) return '${f.format(a!.toLocal())} 起';
  if (a == null) return '至 ${f.format(b.toLocal())}';
  return '${f.format(a.toLocal())} – ${f.format(b.toLocal())}';
}

/// 联名活动 tab body (scrolls by itself; the /local page provides the header
/// and the tab switcher).
class CampaignsTab extends ConsumerWidget {
  const CampaignsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(brandCampaignsProvider);
    final unused = ref.watch(myCouponsProvider('unused')).value;
    return RefreshIndicator(
      onRefresh: () {
        ref.invalidate(myCouponsProvider('unused'));
        return ref.refresh(brandCampaignsProvider.future);
      },
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        LLCard(
          onTap: () => context.push('/me/coupons'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(color: LL.pink, shape: BoxShape.circle),
              child: const Icon(Icons.confirmation_number_outlined, color: LL.ink, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('我的卡券包', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                Text(unused == null ? '到店出示二维码核销' : '${unused.length} 张可用 · 到店出示二维码核销',
                    style: const TextStyle(color: LL.text2, fontSize: 12)),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: LL.text3),
          ]),
        ),
        const SizedBox(height: 12),
        AsyncBody<List<BrandCampaign>>(
          value: v,
          onRetry: () => ref.invalidate(brandCampaignsProvider),
          data: (items) => items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Text('现在没有进行中的联名活动，过几天再来看看', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)),
                )
              : Column(children: [
                  for (var i = 0; i < items.length; i++) ...[
                    BrandCampaignCard(campaign: items[i], color: _cardColors[i % _cardColors.length]),
                    const SizedBox(height: 12),
                  ],
                ]),
        ),
        const SizedBox(height: 4),
        const Text('所有券都只能通过运动、签到免费获得，不设付费抽取 · 券不能转让、不能兑现',
            textAlign: TextAlign.center, style: TextStyle(color: LL.text3, fontSize: 11)),
      ]),
    );
  }
}

class BrandCampaignCard extends ConsumerWidget {
  const BrandCampaignCard({super.key, required this.campaign, this.color = LL.lime});
  final BrandCampaign campaign;
  final Color color;

  void _focus(BuildContext context, WidgetRef ref, PerkDrop d) {
    final c = d.center;
    if (c == null) return;
    ref.read(mapFocusProvider.notifier).focus(MapFocus(c));
    context.go('/map');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = campaign;
    final perks = c.perks;
    final rules = <String>{
      for (final p in perks)
        if (p.rules.isNotEmpty) p.rules,
    };
    final header = Container(
      color: color,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('品牌联名${c.merchant == null ? '' : ' · ${c.merchant!.name}'}',
                style: const TextStyle(color: LL.ink, fontSize: 12, fontWeight: FontWeight.w800)),
          ),
          if (c.status == 'paused') const ComingSoon(text: '暂停中'),
        ]),
        const SizedBox(height: 4),
        Text(c.title, style: const TextStyle(color: LL.ink, fontSize: 20, fontWeight: FontWeight.w900)),
      ]),
    );
    return Container(
      decoration: BoxDecoration(color: LL.card, borderRadius: BorderRadius.circular(24), border: Border.all(color: LL.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (c.coverUrl != null)
          Stack(children: [
            Image.network(mediaUrl(c.coverUrl!), height: 140, width: double.infinity, fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink()),
          ]),
        header,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.schedule_rounded, size: 15, color: LL.text2),
              const SizedBox(width: 4),
              Text(
                [
                  _range(c.startTime, c.endTime),
                  if (c.storeCount > 0) '${c.storeCount} 家门店',
                  if (c.issued > 0) '已发 ${Fmt.thousands(c.issued)} 张',
                ].where((e) => e.isNotEmpty).join(' · '),
                style: const TextStyle(color: LL.text2, fontSize: 12),
              ),
            ]),
            if (c.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(c.description, style: const TextStyle(color: Color(0xFFC9C9D1), fontSize: 13, height: 1.6)),
            ],
            if (perks.isNotEmpty) ...[
              const _Label('权益'),
              for (final p in perks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    Container(
                      constraints: const BoxConstraints(minWidth: 52),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
                      alignment: Alignment.center,
                      child: Text(p.valueText.isEmpty ? '券' : p.valueText,
                          style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: 13)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                        if (p.description.isNotEmpty || p.validDays > 0)
                          Text(
                            [if (p.description.isNotEmpty) p.description, if (p.validDays > 0) '领取后 ${p.validDays} 天有效'].join(' · '),
                            style: const TextStyle(color: LL.text2, fontSize: 12),
                          ),
                      ]),
                    ),
                  ]),
                ),
            ],
            if (c.dropTypes.isNotEmpty) ...[
              const _Label('怎么领'),
              for (final t in c.dropTypes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(dropIcon(t), size: 18, color: dropColor(t)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: '${dropTypeName(t)}：', style: TextStyle(color: dropColor(t), fontWeight: FontWeight.w800)),
                          TextSpan(
                              text: dropHowTo(t,
                                  radiusM: c.drops.where((d) => d.type == t).map((d) => d.radiusM).firstOrNull ?? 0)),
                        ]),
                        style: const TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ),
                  ]),
                ),
            ],
            if (c.drops.isNotEmpty) ...[
              const _Label('投放点 · 点一下在地图上看'),
              for (final d in c.drops) _DropRow(drop: d, onTap: d.center == null ? null : () => _focus(context, ref, d)),
            ],
            const _Label('规则'),
            for (final r in rules) _RuleLine(r),
            const _RuleLine('到店出示卡券包里的二维码，由店员扫码核销；核销需要当天有一条运动记录'),
            const _RuleLine('每张券只能用一次，过期作废；每个投放点每天发放有上限，发完当天不再发'),
          ]),
        ),
      ]),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: Text(text, style: const TextStyle(color: LL.text2, fontSize: 13, fontWeight: FontWeight.w800)),
      );
}

class _RuleLine extends StatelessWidget {
  const _RuleLine(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('· ', style: TextStyle(color: LL.text3)),
          Expanded(child: Text(text, style: const TextStyle(color: LL.text2, fontSize: 12, height: 1.5))),
        ]),
      );
}

class _DropRow extends StatelessWidget {
  const _DropRow({required this.drop, this.onTap});
  final PerkDrop drop;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final d = drop;
    final color = dropColor(d.type);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: LL.card2,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
                child: Icon(dropIcon(d.type), size: 18, color: LL.ink),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                  Text(
                    [
                      dropTypeName(d.type),
                      if (d.perk != null) d.perk!.title,
                      if (d.soldOutToday) '今日已发完' else if (d.status == 'paused') '暂停中',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: d.soldOutToday ? LL.orange : LL.text2, fontSize: 12),
                  ),
                ]),
              ),
              if (onTap != null) const Icon(Icons.map_outlined, color: LL.text3, size: 20),
            ]),
          ),
        ),
      ),
    );
  }
}
