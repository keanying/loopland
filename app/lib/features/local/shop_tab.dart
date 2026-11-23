// 本地生活 ·「能量商城」tab (E-05): territory skins / avatar frames / map
// markers bought with energy; buy (with confirm) and equip / unequip.
// Energy only comes from exercise — no top-up, no transfer, no paid entry.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/perks_api.dart';
import '../../api/perks_models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/cosmetics.dart';
import '../../widgets/l_icons.dart';

/// 能量商城 tab body (scrolls by itself).
class ShopTab extends ConsumerStatefulWidget {
  const ShopTab({super.key});
  @override
  ConsumerState<ShopTab> createState() => _ShopTabState();
}

class _ShopTabState extends ConsumerState<ShopTab> {
  static const _tabs = ['全部', '领地皮肤', '头像框', '地图标记'];
  int _type = 0;
  ShopCatalog? _catalog;
  Object? _error;
  bool _loading = false;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final c = await ref.read(perksApiProvider).shopItems();
      if (!mounted) return;
      setState(() {
        _catalog = c;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _refreshUser() => ref.read(authProvider.notifier).refreshUser().ignore();

  void _replace(ShopItem item, {int? energy}) {
    final c = _catalog;
    if (c == null) return;
    setState(() {
      _catalog = ShopCatalog(
        energy: energy ?? c.energy,
        items: [
          for (final e in c.items)
            if (e.key == item.key)
              item
            else if (item.equipped && e.type == item.type && e.equipped)
              e.copyWith(equipped: false) // one equipped per type
            else
              e,
        ],
      );
    });
  }

  Future<void> _buy(ShopItem item) async {
    final energy = _catalog?.energy ?? 0;
    if (energy < item.priceEnergy) {
      toast(context, '能量不足，还差 ${item.priceEnergy - energy} 能量，去运动赚一点吧');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('兑换「${item.name}」'),
        content: Text('将消耗 ${Fmt.thousands(item.priceEnergy)} 能量，剩余 ${Fmt.thousands(energy - item.priceEnergy)}。\n'
            '装扮兑换后不退还；能量只能运动获得，不能充值、不能转让。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('再想想')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('确认兑换')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy.add(item.key));
    try {
      final r = await ref.read(perksApiProvider).buy(item.key);
      if (!mounted) return;
      _replace(r.item, energy: r.energy);
      _refreshUser();
      toast(context, '兑换成功！点「装备」就能用上');
    } on ApiException catch (e) {
      if (!mounted) return;
      switch (e.code) {
        case 'already_owned':
          _replace(item.copyWith(owned: true));
          toast(context, '你已经拥有「${item.name}」了，直接装备吧');
        case 'not_enough_energy':
          toast(context, '能量不足，去运动赚一点再来兑换吧');
          _load();
        default:
          showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(item.key));
    }
  }

  Future<void> _equip(ShopItem item, bool on) async {
    setState(() => _busy.add(item.key));
    try {
      final api = ref.read(perksApiProvider);
      final r = on ? await api.equip(item.key) : await api.unequip(item.key);
      if (!mounted) return;
      _replace(r);
      _refreshUser();
      toast(context, on ? '已装备「${item.name}」' : '已卸下「${item.name}」');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(item.key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _catalog;
    final energy = c?.energy ?? ref.watch(userProvider)?.energy ?? 0;
    final items = c == null
        ? const <ShopItem>[]
        : _type == 0
            ? c.items
            : c.items.where((e) => e.type == shopTypes[_type - 1]).toList();
    final counts = [
      '',
      for (final t in shopTypes) c == null ? '' : '${c.items.where((e) => e.type == t).length}',
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverList.list(children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: BoxDecoration(color: LL.lime, borderRadius: BorderRadius.circular(24)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('可用能量', style: TextStyle(color: LL.ink, fontSize: 12, fontWeight: FontWeight.w800)),
                      Row(children: [
                        const LIcon(LIcons.bolt, color: LL.ink, size: 24),
                        Text(Fmt.thousands(energy),
                            key: const Key('shop_energy'),
                            style: const TextStyle(color: LL.ink, fontSize: 28, fontWeight: FontWeight.w900)),
                      ]),
                    ]),
                  ),
                  const Text('跑步、球类、跟练\n都能赚能量',
                      textAlign: TextAlign.right, style: TextStyle(color: Color(0xFF2B300E), fontSize: 12, height: 1.5)),
                ]),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: LL.ink.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
                  child: const Row(children: [
                    LIcon(LIcons.info, size: 15, color: LL.ink),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text('能量只能运动获得，不能充值、不能转让',
                          style: TextStyle(color: LL.ink, fontSize: 12, fontWeight: FontWeight.w800)),
                    ),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            ChipTabs(labels: _tabs, trailing: counts, index: _type, onChanged: (i) => setState(() => _type = i)),
            const SizedBox(height: 12),
            if (c == null && _loading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
            if (c == null && _error != null) ErrorBox(error: _error!, onRetry: _load),
            if (c != null && items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Text('这一类暂时没有上架的装扮', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)),
              ),
          ]),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          sliver: SliverGrid(
            gridDelegate:
                const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, mainAxisExtent: 240),
            delegate: SliverChildBuilderDelegate(
              (_, i) => ShopItemCard(
                item: items[i],
                energy: energy,
                busy: _busy.contains(items[i].key),
                onBuy: () => _buy(items[i]),
                onEquip: (on) => _equip(items[i], on),
              ),
              childCount: items.length,
            ),
          ),
        ),
        const SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 32),
          sliver: SliverToBoxAdapter(
            child: Text('装扮只改变外观，不影响圈地、守卫和伤害 · 没有任何付费购买入口',
                textAlign: TextAlign.center, style: TextStyle(color: LL.text3, fontSize: 11)),
          ),
        ),
      ]),
    );
  }
}

/// Preview of a cosmetic by type.
class ShopItemPreview extends ConsumerWidget {
  const ShopItemPreview({super.key, required this.item, this.height = 84});
  final ShopItem item;
  final double height;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (item.type) {
      case 'avatar_frame':
        final name = ref.watch(userProvider)?.nickname ?? '我';
        return Container(
          height: height,
          decoration: BoxDecoration(color: const Color(0xFF141418), borderRadius: BorderRadius.circular(16)),
          alignment: Alignment.center,
          child: FramedAvatar(
            frameKey: item.key,
            size: height * 0.86,
            child: (s) => Avatar(name: name, size: s, color: LL.lavender),
          ),
        );
      case 'map_marker':
        return MarkerPreview(markerKey: item.key, tint: parseHexColor(item.preview.fill), height: height);
      default:
        return SkinPreview(style: item.preview, height: height);
    }
  }
}

class ShopItemCard extends StatelessWidget {
  const ShopItemCard({
    super.key,
    required this.item,
    required this.energy,
    required this.onBuy,
    required this.onEquip,
    this.busy = false,
  });
  final ShopItem item;
  final int energy;
  final VoidCallback onBuy;
  final ValueChanged<bool> onEquip;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final it = item;
    final cant = !it.owned && energy < it.priceEnergy;
    final Widget button;
    if (it.equipped) {
      button = OutlinedButton(
        key: Key('unequip:${it.key}'),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(38), padding: EdgeInsets.zero),
        onPressed: busy ? null : () => onEquip(false),
        child: const Text('卸下', style: TextStyle(fontSize: 13)),
      );
    } else if (it.owned) {
      button = FilledButton(
        key: Key('equip:${it.key}'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(38), padding: EdgeInsets.zero),
        onPressed: busy ? null : () => onEquip(true),
        child: const Text('装备', style: TextStyle(fontSize: 13)),
      );
    } else {
      button = FilledButton.icon(
        key: Key('buy:${it.key}'),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(38),
          padding: EdgeInsets.zero,
          backgroundColor: cant ? LL.card2 : LL.text,
          foregroundColor: cant ? LL.text3 : LL.ink,
        ),
        onPressed: busy ? null : onBuy,
        icon: const LIcon(LIcons.bolt, size: 16),
        label: Text(cant ? '能量不足 ${Fmt.thousands(it.priceEnergy)}' : '${Fmt.thousands(it.priceEnergy)} 兑换',
            style: const TextStyle(fontSize: 13, fontFamily: 'Roboto')),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LL.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: it.equipped ? LL.lime : LL.border, width: it.equipped ? 1.5 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Stack(children: [
          ShopItemPreview(item: it),
          if (it.equipped || it.owned || it.limitedUntil != null)
            Positioned(
              left: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                    color: it.equipped ? LL.lime : (it.owned ? LL.lavender : LL.orange), borderRadius: BorderRadius.circular(8)),
                child: Text(
                  it.equipped
                      ? '已装备'
                      : it.owned
                          ? '已拥有'
                          : '限时 至${DateFormat('M.d').format(it.limitedUntil!.toLocal())}',
                  style: const TextStyle(color: LL.ink, fontSize: 10, fontWeight: FontWeight.w900),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 8),
        Text(shopTypeName(it.type), style: const TextStyle(color: LL.text3, fontSize: 11, fontWeight: FontWeight.w700)),
        Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
        const SizedBox(height: 2),
        Expanded(
          child: Text(it.description,
              maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 11, height: 1.4)),
        ),
        const SizedBox(height: 6),
        button,
      ]),
    );
  }
}
