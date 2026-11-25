import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/card_art.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import '../play/defense_banner.dart';
import '../../widgets/sound_refresh.dart';
import '../../audio/audio.dart';
import '../../core/refresh.dart';

/// 建城：6 个建造位、建筑选择、角色驻扎，实时显示守卫值和每日能量。
class CityPage extends ConsumerStatefulWidget {
  const CityPage({super.key, required this.territoryId});
  final int territoryId;
  @override
  ConsumerState<CityPage> createState() => _CityPageState();
}

class _CityPageState extends ConsumerState<CityPage> {
  Territory? _local;

  void _apply(Territory t) => setState(() => _local = t);

  Future<void> _pickBuilding(Territory t, int slot) async {
    final cfg = await ref.read(configProvider.future);
    if (!mounted) return;
    final key = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => BuildingPicker(config: cfg),
    );
    if (key == null || !mounted) return;
    final r = await runGuarded(context, () => ref.read(apiProvider).build(t.id, slot, key));
    if (r == null || !mounted) return;
    _apply(r.territory);
    ref.read(audioProvider)
      ..play(Sounds.buildingDone)
      ..haptic(HapticKind.medium);
    toast(context, '建造完成，剩余能量 ${r.energy}');
    ref.read(refreshProvider).afterTerritoryChange(t.id).ignore();
  }

  Future<void> _station(Territory t) async {
    final codex = await runGuarded(context, () => ref.read(apiProvider).codex());
    if (codex == null || !mounted) return;
    final here = t.stationed.map((s) => s.role).toSet();
    final roles = codex.roles.where((r) => r.obtained && !here.contains(r.key)).toList();
    final role = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (c) => _RolePicker(roles: roles, currentTerritory: t.id),
    );
    if (role == null || !mounted) return;
    final nt = await runGuarded(context, () => ref.read(apiProvider).station(t.id, role));
    if (nt != null) {
      _apply(nt);
      ref.read(refreshProvider).afterTerritoryChange(t.id).ignore();
    }
  }

  Future<void> _unstation(Territory t, String role) async {
    final nt = await runGuarded(context, () => ref.read(apiProvider).unstation(t.id, role));
    if (nt != null) {
      _apply(nt);
      ref.read(refreshProvider).afterTerritoryChange(t.id).ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(territoryProvider(widget.territoryId));
    final user = ref.watch(userProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          BackHeader(
            title: '建城',
            subtitle: '在你的领地上盖建筑、派角色驻守',
            trailing: EnergyBadge(energy: user?.energy ?? 0),
          ),
          Expanded(
            child: AsyncBody<Territory>(
              value: async,
              onRetry: () => ref.invalidate(territoryProvider(widget.territoryId)),
              data: (fetched) => _body(_local ?? fetched),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _body(Territory t) {
    final cfg = ref.watch(configProvider).value;
    final mine = t.summary.isMine;
    final editable = mine && !t.summary.frozen;
    final slotCount = math.max(t.slots.length, cfg?.slotsPerTerritory ?? 6);
    final slots = [
      for (var i = 0; i < slotCount; i++) t.slots.firstWhere((s) => s.slot == i, orElse: () => Slot(slot: i)),
    ];
    return SoundRefresh(
      onRefresh: () async {
        _local = null;
        ref.invalidate(territoryProvider(widget.territoryId));
      },
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: LL.lime, borderRadius: BorderRadius.circular(32)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${t.summary.name} · ${Fmt.area(t.summary.areaM2)}',
                style: const TextStyle(color: Color(0xFF3A3F1A), fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: Text(t.summary.name,
                    style: const TextStyle(color: LL.ink, fontSize: 28, fontWeight: FontWeight.w900)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: LL.ink, borderRadius: BorderRadius.circular(16)),
                child: Text('${t.builtCount}/$slotCount 已建',
                    style: const TextStyle(color: LL.lime, fontWeight: FontWeight.w800)),
              ),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _MiniStat(value: '${t.summary.guard}', label: '守卫值')),
              const SizedBox(width: 8),
              Expanded(child: _MiniStat(value: '+${t.dailyEnergy}', label: '能量 / 天')),
              const SizedBox(width: 8),
              Expanded(child: _MiniStat(value: '${t.stationed.length}/${t.stationSlots}', label: '驻守角色')),
            ]),
          ]),
        ),
        if (mine && t.defense != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: DefenseBanner(defense: t.defense!)),
        if (!mine)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LLCard(child: Text('这块地已经不属于你了，只能查看。', style: TextStyle(color: LL.text2))),
          )
        else if (t.summary.frozen)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LLCard(child: Text('领地已被冻结，暂时无法建造或派驻。', style: TextStyle(color: LL.text2))),
          ),
        const SizedBox(height: 22),
        Row(children: [
          const Text('建造位', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const Spacer(),
          Text('${t.builtCount} / $slotCount 已建', style: const TextStyle(color: LL.text2)),
        ]),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.72,
          children: [
            for (final s in slots)
              s.empty
                  ? _EmptySlot(onTap: editable ? () => _pickBuilding(t, s.slot) : null)
                  : _BuiltSlot(slot: s),
          ],
        ),
        const SizedBox(height: 26),
        Row(children: [
          const Text('驻守角色', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const Spacer(),
          OutlinedButton(
            onPressed: editable && t.stationed.length < t.stationSlots ? () => _station(t) : null,
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            child: const Text('派遣角色'),
          ),
        ]),
        const SizedBox(height: 12),
        if (t.stationed.isEmpty)
          Text(
              t.stationed.length < t.stationSlots
                  ? '还没有角色驻守。派驻图鉴里的角色可以获得加成。'
                  : '驻扎位已满。建造营帐、民居可以增加驻扎位。',
              style: const TextStyle(color: LL.text3))
        else
          for (final s in t.stationed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: LLCard(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  CardArt(artKey: s.role, width: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      Text(s.buffText, style: const TextStyle(color: LL.lime, fontSize: 13)),
                    ]),
                  ),
                  if (editable)
                    TextButton(
                        onPressed: () => _unstation(t, s.role),
                        child: const Text('撤下', style: TextStyle(color: LL.text2))),
                ]),
              ),
            ),
        if (t.stationed.length >= t.stationSlots && t.stationed.isNotEmpty)
          const Text('驻扎位已满。建造营帐、民居可以增加驻扎位。', style: TextStyle(color: LL.text3, fontSize: 12)),
      ]),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.value, required this.label});
  final String value, label;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0x14000000), borderRadius: BorderRadius.circular(18)),
        child: StatBox(value: value, label: label, dark: true),
      );
}

class _EmptySlot extends StatelessWidget {
  const _EmptySlot({this.onTap});
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '空建造位',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: CustomPaint(
          painter: _DashedBorder(),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              LIcon(LIcons.plus, size: 34, color: onTap == null ? LL.text3 : LL.text2),
              const SizedBox(height: 6),
              Text('建造', style: TextStyle(color: onTap == null ? LL.text3 : LL.text2)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(22)));
    final p = Paint()
      ..color = LL.text3.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 10) {
        canvas.drawPath(m.extractPath(d, d + 5), p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BuiltSlot extends StatelessWidget {
  const _BuiltSlot({required this.slot});
  final Slot slot;
  @override
  Widget build(BuildContext context) {
    return LLCard(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
      radius: 22,
      child: Column(children: [
        Expanded(child: LayoutBuilder(builder: (c, box) => CardArt(artKey: slot.building!, width: box.maxHeight / 1.2))),
        const SizedBox(height: 6),
        Text(slot.name ?? slot.building!, style: const TextStyle(fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

/// Building picker: cost / guard / yield / unlock level.
class BuildingPicker extends ConsumerWidget {
  const BuildingPicker({super.key, required this.config});
  final GameConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProvider);
    final level = user?.level ?? 1;
    final energy = user?.energy ?? 0;
    // V2: a blueprint (boss drop) lifts the level requirement. Codex
    // buildings may carry `blueprint: true`; otherwise the server's
    // level_too_low error is the source of truth.
    final blueprints = {
      for (final b in ref.watch(codexProvider).value?.buildings ?? const <CodexBuilding>[])
        if (b.blueprint) b.key,
    };
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.92,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Row(children: [
            const Text('选择建筑', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const Spacer(),
            EnergyBadge(energy: energy),
          ]),
          const SizedBox(height: 4),
          Text('当前 Lv.$level · 建造后守卫值增加（含角色加成）', style: const TextStyle(color: LL.text3, fontSize: 12)),
          const SizedBox(height: 12),
          for (final b in config.buildings)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _BuildingRow(
                b: b,
                blueprint: blueprints.contains(b.key) && b.unlockLevel > level,
                locked: b.unlockLevel > level && !blueprints.contains(b.key),
                affordable: energy >= b.cost,
                onTap: () => Navigator.pop(context, b.key),
              ),
            ),
        ],
      ),
    );
  }
}

class _BuildingRow extends StatelessWidget {
  const _BuildingRow({required this.b, required this.locked, required this.affordable, required this.onTap, this.blueprint = false});
  final BuildingDef b;
  final bool locked, affordable;

  /// Above my level but buildable thanks to a blueprint.
  final bool blueprint;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final enabled = !locked && affordable;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: LLCard(
        color: LL.card2,
        padding: const EdgeInsets.all(10),
        onTap: enabled ? onTap : null,
        child: Row(children: [
          CardArt(artKey: b.key, width: 56, locked: locked),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(b.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                const SizedBox(width: 8),
                if (b.note.isNotEmpty) Text(b.note, style: const TextStyle(color: LL.text3, fontSize: 12)),
                if (blueprint) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: LL.sky, borderRadius: BorderRadius.circular(8)),
                    child: const Text('图纸可建', style: TextStyle(color: LL.ink, fontSize: 11, fontWeight: FontWeight.w900)),
                  ),
                ],
              ]),
              const SizedBox(height: 4),
              Wrap(spacing: 10, children: [
                Text('守卫 +${b.guard}', style: const TextStyle(color: LL.lavender, fontSize: 13)),
                Text('产能 +${b.dailyEnergy}/天', style: const TextStyle(color: LL.lime, fontSize: 13)),
                if (b.stationSlots > 0) Text('驻扎 +${b.stationSlots}', style: const TextStyle(color: LL.sky, fontSize: 13)),
              ]),
              if (locked)
                Text('Lv.${b.unlockLevel} 解锁', style: const TextStyle(color: LL.orange, fontSize: 12))
              else if (!affordable)
                const Text('能量不足', style: TextStyle(color: LL.orange, fontSize: 12)),
            ]),
          ),
          Row(children: [
            const LIcon(LIcons.bolt, color: LL.yellow, size: 18),
            Text('${b.cost}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
          ]),
        ]),
      ),
    );
  }
}

class _RolePicker extends StatelessWidget {
  const _RolePicker({required this.roles, required this.currentTerritory});
  final List<CodexRole> roles;
  final int currentTerritory;
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('派遣角色', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          const Text('每个角色同一时间只能驻扎在一块领地，再次派驻会从原领地移走。',
              style: TextStyle(color: LL.text3, fontSize: 12)),
          const SizedBox(height: 12),
          if (roles.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('还没有可派遣的角色。去运动招募角色吧！', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)),
            )
          else
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final r in roles)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    leading: CardArt(artKey: r.key, width: 44),
                    title: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Text(
                        r.stationedAt != null && r.stationedAt != currentTerritory
                            ? '${r.buffText} · 当前驻扎在领地 #${r.stationedAt}'
                            : r.buffText,
                        style: const TextStyle(color: LL.text2)),
                    trailing: const LIcon(LIcons.chevronRight),
                    onTap: () => Navigator.pop(context, r.key),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }
}
