import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/ai_models.dart';
import '../../api/errors.dart';
import '../../api/models.dart';
import '../../api/perks_models.dart';
import '../../auth/auth_controller.dart';
import '../../claim/geo.dart';
import '../../core/features.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/sdk_config.dart';
import '../../core/theme.dart';
import '../../map/territory_map.dart';
import '../../run/location_source.dart';
import '../../run/run_controller.dart';
import '../../widgets/common.dart';
import '../../widgets/cosmetics.dart';
import '../../widgets/l_icons.dart';
import '../../widgets/nav_shell.dart';
import '../ai/ai_providers.dart';
import '../ai/ai_widgets.dart';
import '../local/supply_sheet.dart';
import '../play/chest_sheet.dart';
import '../play/defense_banner.dart';
import '../play/play_providers.dart';

/// 领地地图（App 首页）。
class MapPage extends ConsumerStatefulWidget {
  const MapPage({super.key});
  @override
  ConsumerState<MapPage> createState() => _MapPageState();
}

class _MapPageState extends ConsumerState<MapPage> {
  final _map = TerritoryMapController();
  static const _scopes = ['all', 'mine', 'crew'];
  int _scope = 0;
  List<TerritorySummary> _items = const [];
  MapObjects _objects = const MapObjects();
  MapBounds? _bounds;
  Timer? _debounce;
  Object? _error;
  bool _loading = false;
  int? _selected;
  LatLng? _me;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    final u = ref.read(userProvider);
    final focus = ref.read(mapFocusProvider);
    if (focus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focus(focus));
    } else if (u?.consents.location == true) {
      _locate(move: true, ask: false);
    }
  }

  /// Centres a territory picked in the AI assistant.
  void _focus(MapFocus f) {
    if (!mounted) return;
    ref.read(mapFocusProvider.notifier).clear();
    setState(() => _selected = f.territoryId);
    _map.moveTo(f.center, zoom: 16.5);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onBounds(MapBounds b) {
    _bounds = b;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  Future<void> _load() async {
    final b = _bounds;
    if (b == null) return;
    final id = ++_req;
    setState(() => _loading = true);
    _loadObjects(b, id);
    try {
      final items = await ref.read(apiProvider).territories(
          minLng: b.minLng, minLat: b.minLat, maxLng: b.maxLng, maxLat: b.maxLat, scope: _scopes[_scope]);
      if (!mounted || id != _req) return;
      setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (mounted && id == _req) setState(() => _error = e);
    } finally {
      if (mounted && id == _req) setState(() => _loading = false);
    }
  }

  /// Bosses / chests / checkpoints; best effort (the map works without).
  Future<void> _loadObjects(MapBounds b, int id) async {
    try {
      final o = await ref
          .read(apiProvider)
          .mapObjects(minLng: b.minLng, minLat: b.minLat, maxLng: b.maxLng, maxLat: b.maxLat);
      if (mounted && id == _req) setState(() => _objects = o);
    } catch (_) {}
  }

  Future<void> _openObject(MapObjectHit hit) async {
    switch (hit) {
      case BossHit(:final boss):
        context.push('/bosses/${boss.id}');
      case CheckpointHit(:final checkpoint):
        context.push('/routes/${checkpoint.routeId}');
      case ChestHit(:final chest):
        final gone = await showModalBottomSheet<bool>(context: context, builder: (_) => ChestSheet(chest: chest));
        if (gone == true && mounted) {
          setState(() => _objects = MapObjects(
                bosses: _objects.bosses,
                chests: [for (final c in _objects.chests) if (c.id != chest.id) c],
                checkpoints: _objects.checkpoints,
                supplies: _objects.supplies,
                venues: _objects.venues,
              ));
        }
      case SupplyHit(:final supply):
        final s = await showModalBottomSheet<MapSupply>(
            context: context, isScrollControlled: true, builder: (_) => SupplySheet(supply: supply, myLocation: _me));
        if (s != null && mounted) {
          setState(() => _objects = MapObjects(
                bosses: _objects.bosses,
                chests: _objects.chests,
                checkpoints: _objects.checkpoints,
                supplies: [for (final e in _objects.supplies) e.id == s.id ? s : e],
                venues: _objects.venues,
              ));
        }
      case VenueHit(:final venue):
        context.push('/venues/${venue.id}');
    }
  }

  Future<void> _locate({bool move = true, bool ask = true}) async {
    final src = ref.read(locationSourceProvider);
    if (ask) {
      final p = await src.ensurePermission();
      if (p != LocationPermissionResult.granted) {
        if (mounted) toast(context, '需要定位权限才能回到你的位置', kind: ToastKind.warning);
        return;
      }
    }
    final f = await src.current();
    if (f == null || !mounted) return;
    setState(() => _me = LatLng(f.lat, f.lng));
    if (move) _map.moveTo(_me!, zoom: 16);
  }

  void _openTerritory(TerritorySummary? t) {
    setState(() => _selected = t?.id);
    if (t == null) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => TerritorySheet(territory: t),
    ).whenComplete(() {
      if (mounted) setState(() => _selected = null);
    });
  }

  void _goCity() {
    final mine = _items.where((t) => t.isMine).toList();
    if (mine.isNotEmpty) {
      context.push('/city/${mine.first.id}');
      return;
    }
    final u = ref.read(userProvider);
    if ((u?.stats.territoryCount ?? 0) > 0) {
      setState(() => _scope = 1);
      _load();
      toast(context, '切到「我的」，点一块你的领地去建设');
    } else {
      toast(context, '还没有领地，先去跑一圈圈地吧');
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    final unread = ref.watch(inboxUnreadProvider).value ?? 0;
    final season = ref.watch(seasonProvider).value?.season;
    final top = MediaQuery.paddingOf(context).top;
    final bottom = NavShell.bottomInset(context);
    final ai = ref.watch(aiEnabledProvider);
    ref.listen<MapFocus?>(mapFocusProvider, (_, f) {
      if (f != null) _focus(f);
    });
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: TerritoryMapView(
            controller: _map,
            initialCenter: _me ?? const LatLng(31.2304, 121.4737),
            layers: MapLayers(
                territories: _items, objects: _objects, myLocation: _me, selectedId: _selected, myMarker: user?.equipped.mapMarker),
            onBoundsChanged: _onBounds,
            onTerritoryTap: _openTerritory,
            onObjectTap: _openObject,
          ),
        ),
        // Header
        Positioned(
          left: 16,
          right: 16,
          top: top + 8,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              FramedAvatar(
                  frameKey: user?.equipped.avatarFrame, size: 56, child: (s) => Avatar(name: user?.nickname ?? '', size: s)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('嗨，${user?.nickname ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                  Row(children: [
                    const LIcon(LIcons.bolt, color: LL.yellow, size: 16),
                    Text(' 今日能量 ${user?.energyToday ?? 0} · LV.${user?.level ?? 1}',
                        style: const TextStyle(color: LL.text2, fontSize: 13)),
                  ]),
                ]),
              ),
              RoundIconButton(
                icon: LIcons.bell,
                size: 52,
                badge: unread > 0,
                tooltip: '消息',
                onTap: () => context.push('/inbox'),
              ),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              PillTabs(
                labels: const ['全城', '我的', '跑团'],
                index: _scope,
                expand: false,
                onChanged: (i) {
                  setState(() => _scope = i);
                  _load();
                },
              ),
              const Spacer(),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              if (season != null)
                Semantics(
                  button: true,
                  label: '赛季',
                  child: GestureDetector(
                    onTap: () => context.push('/season'),
                    child: Container(
                      height: 50,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: LL.card.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(25)),
                      child: Text.rich(TextSpan(children: [
                        TextSpan(text: season.shortName, style: const TextStyle(color: LL.lime, fontWeight: FontWeight.w900)),
                        TextSpan(text: ' 剩 ${season.daysLeft} 天', style: const TextStyle(fontWeight: FontWeight.w700)),
                      ]), style: const TextStyle(fontSize: 15)),
                    ),
                  ),
                ),
            ]),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: LLCard(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  onTap: _load,
                  child: Text('领地加载失败：${errorText(_error!)} · 点此重试',
                      style: const TextStyle(color: LL.text2, fontSize: 12)),
                ),
              ),
          ]),
        ),
        // Right-side actions
        Positioned(
          right: 16,
          top: top + 150,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _SideButton(icon: LIcons.castle, label: '建城', color: LL.lime, fg: LL.ink, onTap: _goCity),
            const SizedBox(height: 10),
            _SideButton(
                icon: LIcons.gamepad, label: '玩法', color: LL.card, fg: LL.text, onTap: () => context.push('/games')),
            if (ai) ...[
              const SizedBox(height: 10),
              _SideButton(
                  icon: LIcons.quan,
                  leading: const AIMark(),
                  label: '圈圈',
                  color: LL.lavender,
                  fg: LL.ink,
                  onTap: () => context.push('/ai')),
            ],
          ]),
        ),
        Positioned(
          right: 16,
          bottom: bottom + 92,
          child: Column(children: [
            RoundIconButton(icon: LIcons.plus, size: 52, tooltip: '放大', onTap: _map.zoomIn),
            const SizedBox(height: 10),
            RoundIconButton(icon: LIcons.minus, size: 52, tooltip: '缩小', onTap: _map.zoomOut),
            const SizedBox(height: 10),
            RoundIconButton(icon: LIcons.locate, size: 52, tooltip: '回到我的位置', onTap: _locate),
          ]),
        ),
        // Bottom stats
        Positioned(
          left: 16,
          right: 16,
          bottom: bottom,
          child: Row(children: [
            Expanded(
              child: _StatCard(
                color: LL.lavender,
                title: '我的领地',
                value: Fmt.area(user?.stats.territoryAreaM2 ?? 0),
                sub: '${user?.stats.territoryCount ?? 0} 块',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatCard(
                color: const Color(0xFFEBC9F7),
                title: '本周运动',
                value: '${Fmt.km(user?.stats.week.distanceM ?? 0, digits: 1)} km',
                sub: '${user?.stats.week.count ?? 0} 次 · ${user?.stats.week.energy ?? 0} 能量',
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _SideButton extends StatelessWidget {
  const _SideButton({required this.icon, this.leading, required this.label, required this.color, required this.fg, required this.onTap});
  final LGlyph icon;
  final Widget? leading; // 替代 icon（如「圈圈」的带 AI 角标图标）
  final String label;
  final Color color, fg;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            leading ?? LIcon(icon, color: fg, size: 22),
            SizedBox(width: leading != null ? 14 : 8),
            Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w900, fontSize: 17)),
          ]),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.color, required this.title, required this.value, required this.sub});
  final Color color;
  final String title, value, sub;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(24)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w800, fontSize: 13)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: 26)),
        ),
        Text(sub, style: const TextStyle(color: Color(0xFF3B3355), fontSize: 12)),
      ]),
    );
  }
}

/// Bottom sheet when a territory is tapped.
class TerritorySheet extends ConsumerWidget {
  const TerritorySheet({super.key, required this.territory});
  final TerritorySummary territory;

  String get _relationText => switch (territory.relation) {
        'mine' => '我的领地',
        'crew' => '跑团领地',
        'enemy' => '对手领地',
        _ => '无主之地',
      };

  Future<void> _navigate(BuildContext context) async {
    final c = centerOf(territory);
    if (c == null) return;
    // AMap URI API (works in the AMap app or the browser), GCJ-02 coordinates.
    // Base URL: `amap.navigation_url` in config/app.yaml.
    final base = SdkConfig.current.amapNavigationUrl;
    final uri = Uri.parse('$base${base.contains('?') ? '&' : '?'}'
        'to=${c.lng},${c.lat},${Uri.encodeComponent(territory.name)}'
        '&mode=walk&coordinate=gaode&callnative=1');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = territory;
    final color = relationColor(t.relation);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text(_relationText, style: TextStyle(color: color, fontWeight: FontWeight.w800)),
            if (t.frozen) ...[const SizedBox(width: 8), const ComingSoon(text: '已冻结')],
            const Spacer(),
            // A-04「问 AI」 on others' territories (hidden when AI is off).
            if (!t.isMine)
              AskAIButton(
                aiContext: AIContext(type: 'territory', id: t.id, name: t.name),
                compact: true,
                beforeOpen: () => Navigator.pop(context),
              ),
          ]),
          const SizedBox(height: 8),
          Text(t.name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text(
            [
              if (t.owner != null) '领主 ${t.owner!.nickname}' else '暂无领主',
              if (t.crew != null) '「${t.crew!.name}」',
            ].join(' · '),
            style: const TextStyle(color: LL.text2),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: LLCard(child: StatBox(value: Fmt.area(t.areaM2), label: '面积'))),
            const SizedBox(width: 10),
            Expanded(child: LLCard(child: StatBox(value: '${t.guard}', label: '守卫值'))),
          ]),
          if (t.isMine)
            Consumer(builder: (context, ref, _) {
              final d = ref.watch(territoryProvider(t.id)).value?.defense;
              if (d == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: DefenseBanner(
                  defense: d,
                  onGo: () {
                    Navigator.pop(context);
                    context.push('/start/gps?sport=run');
                  },
                ),
              );
            }),
          const SizedBox(height: 18),
          if (t.isMine)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                context.push('/city/${t.id}');
              },
              icon: const LIcon(LIcons.castle),
              label: const Text('去建设'),
            )
          else ...[
            FilledButton.icon(
              onPressed: t.frozen
                  ? null
                  : () {
                      Navigator.pop(context);
                      context.push('/start/gps?sport=run&target=${t.id}&name=${Uri.encodeComponent(t.name)}');
                    },
              icon: const LIcon(LIcons.flag),
              label: Text(t.relation == 'unowned' ? '去圈下这块地' : '导航去抢'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _navigate(context),
              icon: const LIcon(LIcons.navigate),
              label: const Text('用高德地图导航过去'),
            ),
            const SizedBox(height: 8),
            Text(
              t.relation == 'unowned'
                  ? '跑一圈把它围起来就能圈下。'
                  : '本次运动的能量要超过守卫值 ${t.guard} 才能抢下，否则只会削弱守卫。',
              textAlign: TextAlign.center,
              style: const TextStyle(color: LL.text3, fontSize: 12),
            ),
          ],
        ]),
      ),
    );
  }
}
